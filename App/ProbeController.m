#import "ProbeController.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <signal.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

/*
 * Private Foundation class. It is used by the system to launch embedded
 * app extensions. The host never links the class symbol directly, so the
 * app still builds when the private header is absent from the SDK.
 */
@interface NSExtension : NSObject
+ (nullable instancetype)extensionWithIdentifier:(NSString *)identifier
                                           error:(NSError **)error;
- (nullable NSUUID *)beginExtensionRequestWithInputItems:(NSArray *)items
                                                   error:(NSError **)error;
- (pid_t)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)sig;
@end

typedef char *(*ProbeIssueExtensionFn)(const char *extensionClass,
                                       const char *path,
                                       uint32_t flags);

@interface ProbeController ()

@property (nonatomic, strong) id extension;
@property (nonatomic, strong) NSUUID *requestID;
@property (nonatomic, copy) NSString *resultsPath;
@property (nonatomic, strong) NSMutableData *lineBuffer;
@property (nonatomic, assign) NSUInteger readOffset;
@property (nonatomic, assign) CFMessagePortRef localPort;
@property (atomic, assign) BOOL running;
@property (atomic, assign) BOOL completed;

- (void)handleJSON:(NSString *)json;

@end

static CFDataRef ProbeMessagePortCallback(CFMessagePortRef localPort,
                                          SInt32 messageID,
                                          CFDataRef data,
                                          void *info)
{
    ProbeController *controller = (__bridge ProbeController *)info;
    if (data != NULL) {
        NSString *json = [[NSString alloc] initWithData:(__bridge NSData *)data
                                               encoding:NSUTF8StringEncoding];
        [controller handleJSON:json];
    }
    return NULL;
}

@implementation ProbeController

- (instancetype)init
{
    self = [super init];
    if (self) {
        _lineBuffer = [NSMutableData data];
    }
    return self;
}

- (BOOL)start
{
    if (self.running) {
        return NO;
    }

    NSString *pluginsPath = NSBundle.mainBundle.builtInPlugInsPath;
    if (pluginsPath.length == 0) {
        [self log:@"No PlugIns directory in the app bundle."];
        return NO;
    }

    NSString *extensionPath =
        [pluginsPath stringByAppendingPathComponent:@"LiveProcess.appex"];
    NSBundle *extensionBundle = [NSBundle bundleWithPath:extensionPath];
    NSString *identifier = extensionBundle.bundleIdentifier
        ?: @"com.daixz.linux.probe.LiveProcess";

    id extensionClass = (id)NSClassFromString(@"NSExtension");
    if (extensionClass == nil) {
        [self log:@"NSExtension class is not available on this OS."];
        return NO;
    }

    NSError *error = nil;
    id extension = [extensionClass extensionWithIdentifier:identifier
                                                     error:&error];
    if (extension == nil) {
        [self log:[NSString stringWithFormat:@"extensionWithIdentifier failed: %@",
                   [self describeError:error]]];
        return NO;
    }

    /*
     * The extension item serializer on iPadOS 16.6.1 only accepts
     * property-list values. Custom Mach ports, NSFileHandle and
     * NSXPCListenerEndpoint all make PlugInKit fail with error 4097.
     *
     * Use a plain item and hand over a sandbox extension token for a
     * results file in the host's container. The extension consumes the
     * token and appends JSON lines; the host polls the file.
     */
    NSString *resultsPath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:
            @"linux-probe-results.jsonl"];
    [[NSFileManager defaultManager] removeItemAtPath:resultsPath error:nil];
    [[NSFileManager defaultManager] createFileAtPath:resultsPath
                                             contents:[NSData data]
                                           attributes:nil];

    ProbeIssueExtensionFn issue =
        (ProbeIssueExtensionFn)dlsym(RTLD_DEFAULT,
                                     "sandbox_extension_issue_file");
    char *rawToken = NULL;
    if (issue != NULL) {
        rawToken = issue("com.apple.app-sandbox.read-write",
                         resultsPath.fileSystemRepresentation,
                         0);
    }

    NSString *token = nil;
    if (rawToken != NULL) {
        token = [NSString stringWithUTF8String:rawToken];
        free(rawToken);
    }
    if (token.length == 0) {
        [self log:@"warning: could not issue a sandbox extension token."];
    }

    /*
     * Independent live channel. CFMessagePort only carries a service-name
     * string in the extension item, so it stays property-list safe. If the
     * bootstrap namespace is not shared, the results file below is used.
     */
    CFMessagePortContext portContext = {
        0, (__bridge void *)self, NULL, NULL, NULL
    };
    CFMessagePortRef localPort =
        CFMessagePortCreateLocal(kCFAllocatorDefault,
                                 CFSTR("com.daixz.linux.probe.results"),
                                 ProbeMessagePortCallback,
                                 &portContext,
                                 NULL);
    if (localPort != NULL) {
        CFRunLoopSourceRef source =
            CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, localPort, 0);
        if (source != NULL) {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               source,
                               kCFRunLoopDefaultMode);
            CFRelease(source);
        }
        self.localPort = localPort;
        [self log:@"message port ready."];
    } else {
        [self log:@"warning: CFMessagePort unavailable, file only."];
    }

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{
        @"resultsPath": resultsPath,
        @"resultsToken": token ?: @"",
        @"serviceName": @"com.daixz.linux.probe.results",
        @"hostPid": @(getpid()),
    };

    NSError *requestError = nil;
    NSUUID *request = [extension beginExtensionRequestWithInputItems:@[item]
                                                               error:&requestError];
    if (request == nil) {
        [self log:[NSString stringWithFormat:@"extension launch failed: %@",
                   [self describeError:requestError]]];
        if (self.localPort != NULL) {
            CFMessagePortInvalidate(self.localPort);
            CFRelease(self.localPort);
            self.localPort = NULL;
        }
        return NO;
    }

    self.extension = extension;
    self.requestID = request;
    self.resultsPath = resultsPath;
    self.lineBuffer = [NSMutableData data];
    self.readOffset = 0;
    self.running = YES;

    pid_t extensionPid = [extension pidForRequestIdentifier:request];
    [self log:[NSString stringWithFormat:
               @"launch ok: request=%@ pid=%d hostPid=%d",
               request.UUIDString,
               extensionPid,
               getpid()]];
    [self log:[NSString stringWithFormat:@"results: %@", resultsPath]];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakSelf.running) {
            [weakSelf log:@"probe timed out."];
            [weakSelf finish];
        }
    });

    [self pollResults];
    return YES;
}

- (void)pollResults
{
    if (!self.running) {
        return;
    }

    NSData *data = [NSData dataWithContentsOfFile:self.resultsPath];
    if (data.length > self.readOffset) {
        NSData *chunk = [data subdataWithRange:
            NSMakeRange(self.readOffset, data.length - self.readOffset)];
        self.readOffset = data.length;
        [self.lineBuffer appendData:chunk];

        const uint8_t newline = '\n';
        NSData *newlineData = [NSData dataWithBytes:&newline length:1];

        while (self.running) {
            NSRange range = [self.lineBuffer rangeOfData:newlineData
                                                 options:0
                                                   range:NSMakeRange(0, self.lineBuffer.length)];
            if (range.location == NSNotFound) {
                break;
            }

            NSData *line = [self.lineBuffer subdataWithRange:
                NSMakeRange(0, range.location)];
            [self.lineBuffer replaceBytesInRange:
                NSMakeRange(0, range.location + 1)
                                       withBytes:NULL
                                          length:0];

            NSString *json = [[NSString alloc] initWithData:line
                                                   encoding:NSUTF8StringEncoding];
            if (json.length > 0) {
                [self log:[NSString stringWithFormat:@"[file] %@", json]];
            }

            if ([json containsString:@"\"done\":true"]) {
                [self finish];
                return;
            }
        }
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf pollResults];
    });
}

- (void)handleURL:(NSURL *)url
{
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *payloadString = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"payload"]) {
            payloadString = item.value;
            break;
        }
    }

    if (payloadString.length == 0) {
        return;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:payloadString
                                                       options:0];
    if (data == nil) {
        return;
    }

    id object = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:NULL];
    if (![object isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *payload = (NSDictionary *)object;
    NSArray *stages = payload[@"stages"];
    if ([stages isKindOfClass:[NSArray class]]) {
        for (id stage in stages) {
            if (![stage isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSData *stageData = [NSJSONSerialization dataWithJSONObject:stage
                                                               options:0
                                                                 error:NULL];
            NSString *json = stageData != nil
                ? [[NSString alloc] initWithData:stageData
                                        encoding:NSUTF8StringEncoding]
                : nil;
            [self log:[NSString stringWithFormat:@"[url] %@",
                       json ?: [stage description]]];
        }
    }

    if ([payload[@"done"] boolValue]) {
        [self finish];
    }
}

- (void)handleJSON:(NSString *)json
{
    if (json.length == 0) {
        return;
    }

    [self log:[NSString stringWithFormat:@"[port] %@", json]];

    if ([json containsString:@"\"done\":true"]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf finish];
        });
    }
}

- (void)stop
{
    [self finish];
}

- (void)finish
{
    if (self.completed) {
        return;
    }
    self.completed = YES;
    self.running = NO;

    if (self.localPort != NULL) {
        CFMessagePortInvalidate(self.localPort);
        CFRelease(self.localPort);
        self.localPort = NULL;
    }

    [self log:@"probe finished."];

    void (^completion)(void) = self.completionHandler;
    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

- (NSString *)describeError:(NSError *)error
{
    if (error == nil) {
        return @"unknown error";
    }
    return [NSString stringWithFormat:@"%@ [%@:%ld] %@",
            error.localizedDescription ?: @"error",
            error.domain,
            (long)error.code,
            error.userInfo ?: @{}];
}

- (void)log:(NSString *)line
{
    NSLog(@"[probe] %@", line);
    void (^handler)(NSString *) = self.logHandler;
    if (handler != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(line);
        });
    }
}

- (void)dealloc
{
    [self stop];
}

@end
