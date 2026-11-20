#import "ProbeController.h"

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <signal.h>
#import <spawn.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;
extern kern_return_t task_for_pid(mach_port_t target_task,
                                  int pid,
                                  mach_port_t *task);

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
- (void)beginExtensionRequestWithInputItems:(NSArray *)items
                                 completion:(id)completion;
- (void)set_requestPostCompletionBlockWithItems:(id)block;
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
@property (atomic, assign) BOOL launchAttempted;
@property (atomic, assign) BOOL helperFinished;
@property (atomic, assign) BOOL startCompleted;
@property (atomic, assign) pid_t helperPid;

- (void)handleJSON:(NSString *)json;
- (void)handleDarwinNotification:(NSString *)name;
- (BOOL)startExtensionWithResultsPath:(NSString *)resultsPath
                          serviceName:(NSString *)serviceName;
- (NSString *)describeExtensionAPI:(id)extension;
- (NSArray<NSString *> *)helperCandidates;
- (int)spawnHelperAtPath:(NSString *)path
             resultsPath:(NSString *)resultsPath
             serviceName:(NSString *)serviceName;
- (void)scheduleLivenessChecks:(pid_t)pid;
- (void)drainHelperBuffer:(NSMutableData *)buffer;

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

static void ProbeDarwinNotifyCallback(CFNotificationCenterRef center,
                                      void *observer,
                                      CFNotificationName name,
                                      const void *object,
                                      CFDictionaryRef userInfo)
{
    ProbeController *controller = (__bridge ProbeController *)observer;
    [controller handleDarwinNotification:(__bridge NSString *)name];
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

    self.running = YES;
    self.completed = NO;
    self.launchAttempted = NO;
    self.helperFinished = NO;
    self.startCompleted = NO;

    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    [self log:[NSString stringWithFormat:@"build %@ (%@)",
               info[@"CFBundleShortVersionString"] ?: @"?",
               info[@"CFBundleVersion"] ?: @"?"]];

    /*
     * The extension's file transport needs a path the extension can open.
     * The direct-spawn helper uses the same file, so either channel is
     * enough to read the results.
     */
    NSString *resultsPath =
        [NSTemporaryDirectory() stringByAppendingPathComponent:
            @"linux-probe-results.jsonl"];
    [[NSFileManager defaultManager] removeItemAtPath:resultsPath error:nil];
    [[NSFileManager defaultManager] createFileAtPath:resultsPath
                                             contents:[NSData data]
                                           attributes:nil];
    self.resultsPath = resultsPath;
    self.lineBuffer = [NSMutableData data];
    self.readOffset = 0;

    /*
     * The service name travels to the extension as a plain string. The
     * direct-spawn helper receives it as argv[3].
     */
    NSString *serviceName = @"com.daixz.linux.probe.results";
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
        [self log:@"warning: CFMessagePort unavailable."];
        serviceName = @"";
    }

    /*
     * Darwin notifications are the only channel that survives if both the
     * extension context handshake and every item transport fail.
     */
    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(darwin,
                                    (__bridge const void *)self,
                                    ProbeDarwinNotifyCallback,
                                    CFSTR("com.daixz.linux.probe.ext-alive"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(darwin,
                                    (__bridge const void *)self,
                                    ProbeDarwinNotifyCallback,
                                    CFSTR("com.daixz.linux.probe.ext-begin"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    [self log:@"darwin observers installed."];

    /*
     * Route A: spawn a plain executable from our own bundle. This needs no
     * PlugInKit registration and no extension item serializer.
     */
    [self spawnHelper:resultsPath serviceName:serviceName];

    /*
     * Route B: the NSExtension path, kept for comparison.
     */
    self.launchAttempted = [self startExtensionWithResultsPath:resultsPath
                                                   serviceName:serviceName];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(25.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ProbeController *controller = weakSelf;
        if (controller == nil || controller.completed) {
            return;
        }
        [controller log:@"probe timed out."];
        [controller finish];
    });

    self.startCompleted = YES;
    if (!self.launchAttempted && self.helperFinished) {
        [self finish];
    }

    return YES;
}

#pragma mark - Direct spawn route

- (NSArray<NSString *> *)helperCandidates
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *helpers = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Helpers"];

    BOOL isDirectory = NO;
    BOOL directoryExists = [manager fileExistsAtPath:helpers
                                         isDirectory:&isDirectory];
    NSError *listError = nil;
    NSArray *entries = directoryExists
        ? [manager contentsOfDirectoryAtPath:helpers error:&listError]
        : nil;
    [self log:[NSString stringWithFormat:
               @"helpers: %@ exists=%d isDir=%d entries=%@",
               helpers,
               directoryExists,
               isDirectory,
               entries ?: (listError.localizedDescription ?: @[])]];

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *firstExisting = nil;

    for (NSString *name in @[ @"probe-helper", @"probe-helper.dat" ]) {
        NSString *candidate = [helpers stringByAppendingPathComponent:name];
        BOOL exists = [manager fileExistsAtPath:candidate];
        BOOL executable = [manager isExecutableFileAtPath:candidate];
        NSDictionary *attributes = [manager attributesOfItemAtPath:candidate
                                                             error:NULL];
        [self log:[NSString stringWithFormat:
                   @"helper candidate %@ exists=%d exec=%d mode=%o size=%llu",
                   name,
                   exists,
                   executable,
                   [attributes[NSFilePosixPermissions] unsignedIntValue],
                   [attributes[NSFileSize] unsignedLongLongValue]]];

        if (!exists) {
            continue;
        }
        [candidates addObject:candidate];
        if (firstExisting == nil) {
            firstExisting = candidate;
        }
    }

    /*
     * Executing in place is tried first. The copy is only a fallback for
     * an install that lost the executable bit; iOS may refuse to exec it
     * because it lives in the data container.
     */
    if (firstExisting != nil) {
        NSString *copyPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"probe-helper-bin"];
        [manager removeItemAtPath:copyPath error:nil];
        NSError *copyError = nil;
        if ([manager copyItemAtPath:firstExisting
                             toPath:copyPath
                              error:&copyError]) {
            [manager setAttributes:@{ NSFilePosixPermissions: @0755 }
                        ofItemAtPath:copyPath
                               error:NULL];
            [candidates addObject:copyPath];
            [self log:[NSString stringWithFormat:@"helper copied to %@",
                       copyPath]];
        } else {
            [self log:[NSString stringWithFormat:@"helper copy failed: %@",
                       copyError.localizedDescription ?: @"unknown"]];
        }
    }

    return candidates;
}

- (void)spawnHelper:(NSString *)resultsPath serviceName:(NSString *)serviceName
{
    NSArray<NSString *> *candidates = [self helperCandidates];
    if (candidates.count == 0) {
        [self log:@"helper missing; direct-spawn route skipped."];
        self.helperFinished = YES;
        return;
    }

    for (NSString *candidate in candidates) {
        int result = [self spawnHelperAtPath:candidate
                                 resultsPath:resultsPath
                                 serviceName:serviceName];
        if (result == 0) {
            return;
        }
        [self log:[NSString stringWithFormat:
                   @"helper exec failed: %@ -> %d (%s)",
                   candidate.lastPathComponent,
                   result,
                   strerror(result)]];
    }

    [self log:@"all helper candidates failed; direct-spawn route skipped."];
    self.helperFinished = YES;
}

- (int)spawnHelperAtPath:(NSString *)path
             resultsPath:(NSString *)resultsPath
             serviceName:(NSString *)serviceName
{
    int fds[2] = { -1, -1 };
    if (pipe(fds) != 0) {
        return errno;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    char hostPid[16];
    snprintf(hostPid, sizeof(hostPid), "%d", getpid());

    char *argv[] = {
        (char *)path.fileSystemRepresentation,
        (char *)resultsPath.fileSystemRepresentation,
        hostPid,
        (char *)(serviceName.length > 0 ? serviceName.UTF8String : ""),
        NULL,
    };

    pid_t pid = 0;
    int result = posix_spawn(&pid,
                             path.fileSystemRepresentation,
                             &actions,
                             NULL,
                             argv,
                             environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);

    if (result != 0) {
        close(fds[0]);
        return result;
    }

    self.helperPid = pid;
    [self log:[NSString stringWithFormat:@"helper spawned: pid=%d from %@",
               pid, path.lastPathComponent]];

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    [self log:[NSString stringWithFormat:@"task_for_pid(helper)=%d", kr]];
    if (task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), task);
    }

    int readFD = fds[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[4096];

        for (;;) {
            ssize_t count = read(readFD, chunk, sizeof(chunk));
            if (count > 0) {
                [buffer appendBytes:chunk length:(NSUInteger)count];
                [self drainHelperBuffer:buffer];
                continue;
            }
            if (count < 0 && errno == EINTR) {
                continue;
            }
            break;
        }
        close(readFD);

        int status = 0;
        waitpid(pid, &status, 0);
        if (WIFEXITED(status)) {
            [self log:[NSString stringWithFormat:@"helper exited: status=%d",
                       WEXITSTATUS(status)]];
        } else if (WIFSIGNALED(status)) {
            [self log:[NSString stringWithFormat:@"helper signalled: signal=%d",
                       WTERMSIG(status)]];
        } else {
            [self log:@"helper exited: unknown status"];
        }

        self.helperFinished = YES;
        if (self.startCompleted && !self.launchAttempted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finish];
            });
        }
    });

    return 0;
}

- (void)drainHelperBuffer:(NSMutableData *)buffer
{
    const uint8_t newline = '\n';
    NSData *newlineData = [NSData dataWithBytes:&newline length:1];

    for (;;) {
        NSRange range = [buffer rangeOfData:newlineData
                                    options:0
                                      range:NSMakeRange(0, buffer.length)];
        if (range.location == NSNotFound) {
            return;
        }

        NSData *line = [buffer subdataWithRange:
            NSMakeRange(0, range.location)];
        [buffer replaceBytesInRange:NSMakeRange(0, range.location + 1)
                          withBytes:NULL
                             length:0];

        NSString *json = [[NSString alloc] initWithData:line
                                               encoding:NSUTF8StringEncoding];
        if (json.length > 0) {
            [self log:[NSString stringWithFormat:@"[spawn] %@", json]];
        }
    }
}

#pragma mark - Extension route

- (BOOL)startExtensionWithResultsPath:(NSString *)resultsPath
                          serviceName:(NSString *)serviceName
{
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

    NSDictionary *extensionInfo = extensionBundle.infoDictionary[@"NSExtension"];
    [self log:[NSString stringWithFormat:@"extension plist: %@",
               extensionInfo ?: @"missing"]];
    [self log:[self describeExtensionAPI:extension]];

    /*
     * The extension item serializer on iPadOS 16.6.1 only accepts
     * property-list values. Custom Mach ports, NSFileHandle and
     * NSXPCListenerEndpoint all make PlugInKit fail with error 4097.
     *
     * Use a plain item and hand over a sandbox extension token for a
     * results file in the host's container. The extension consumes the
     * token and appends JSON lines; the host polls the file.
     */
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
    } else {
        [self log:[NSString stringWithFormat:@"sandbox token length: %lu",
                   (unsigned long)token.length]];
    }

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{
        @"resultsPath": resultsPath,
        @"resultsToken": token ?: @"",
        @"serviceName": serviceName ?: @"",
        @"hostPid": @(getpid()),
    };

    /*
     * The extension's returned items arrive through this private block.
     * Installing it before the request starts is what makes the extension
     * context handshake complete.
     */
    if ([extension respondsToSelector:
            @selector(set_requestPostCompletionBlockWithItems:)]) {
        [extension set_requestPostCompletionBlockWithItems:^(id items) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self log:[NSString stringWithFormat:@"[items] %@",
                           items ?: @[]]];
                [self finish];
            });
        }];
        [self log:@"request completion block installed."];
    } else {
        [self log:@"warning: request completion block unavailable."];
    }

    /*
     * The synchronous ...error: variant only creates the request record.
     * The async variant is the one that actually delivers the input item
     * to the extension and starts the context handshake.
     */
    if ([extension respondsToSelector:
            @selector(beginExtensionRequestWithInputItems:completion:)]) {
        [self log:@"using async beginExtensionRequest."];
        [extension beginExtensionRequestWithInputItems:@[item]
                                           completion:^(id first,
                                                         __unused id second) {
            NSUUID *request = [first isKindOfClass:[NSUUID class]]
                ? first
                : nil;
            NSError *launchError = [first isKindOfClass:[NSError class]]
                ? first
                : nil;

            dispatch_async(dispatch_get_main_queue(), ^{
                if (request == nil) {
                    [self log:[NSString stringWithFormat:
                               @"extension launch failed: %@",
                               [self describeError:launchError]]];
                    [self finish];
                    return;
                }

                self.extension = extension;
                self.requestID = request;

                pid_t extensionPid =
                    [extension pidForRequestIdentifier:request];
                [self log:[NSString stringWithFormat:
                           @"launch ok: request=%@ pid=%d hostPid=%d",
                           request.UUIDString,
                           extensionPid,
                           getpid()]];
                [self log:[NSString stringWithFormat:@"results: %@",
                           resultsPath]];

                [self scheduleLivenessChecks:extensionPid];
                [self pollResults];
            });
        }];
        return YES;
    }

    [self log:@"warning: async request API unavailable."];
    NSError *requestError = nil;
    NSUUID *request = [extension beginExtensionRequestWithInputItems:@[item]
                                                               error:&requestError];
    if (request == nil) {
        [self log:[NSString stringWithFormat:@"extension launch failed: %@",
                   [self describeError:requestError]]];
        return NO;
    }

    self.extension = extension;
    self.requestID = request;

    pid_t extensionPid = [extension pidForRequestIdentifier:request];
    [self log:[NSString stringWithFormat:
               @"launch ok (sync): request=%@ pid=%d hostPid=%d",
               request.UUIDString,
               extensionPid,
               getpid()]];
    [self log:[NSString stringWithFormat:@"results: %@", resultsPath]];

    [self scheduleLivenessChecks:extensionPid];
    [self pollResults];
    return YES;
}

- (void)scheduleLivenessChecks:(pid_t)pid
{
    [self log:[NSString stringWithFormat:@"watching pid=%d", pid]];

    NSArray *delays = @[ @1.0, @3.0, @6.0 ];
    for (NSUInteger index = 0; index < delays.count; index++) {
        double delay = [delays[index] doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            errno = 0;
            int result = pid > 0 ? kill(pid, 0) : -1;
            int errorNumber = errno;
            [self log:[NSString stringWithFormat:
                       @"pid %d check +%.0fs: kill=%d errno=%d",
                       pid,
                       delay,
                       result,
                       errorNumber]];

            if (index == 0) {
                mach_port_t task = MACH_PORT_NULL;
                kern_return_t kr =
                    task_for_pid(mach_task_self(), pid, &task);
                [self log:[NSString stringWithFormat:
                           @"task_for_pid(%d)=%d", pid, kr]];
                if (task != MACH_PORT_NULL) {
                    mach_port_deallocate(mach_task_self(), task);
                }
            }
        });
    }
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

- (void)handleDarwinNotification:(NSString *)name
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self log:[NSString stringWithFormat:@"[darwin] %@", name]];
    });
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

    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterRemoveObserver(darwin,
                                       (__bridge const void *)self,
                                       CFSTR("com.daixz.linux.probe.ext-alive"),
                                       NULL);
    CFNotificationCenterRemoveObserver(darwin,
                                       (__bridge const void *)self,
                                       CFSTR("com.daixz.linux.probe.ext-begin"),
                                       NULL);

    [self log:@"probe finished."];

    void (^completion)(void) = self.completionHandler;
    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

- (NSString *)describeExtensionAPI:(id)extension
{
    NSMutableArray *names = [NSMutableArray array];
    Class cls = [extension class];

    for (int level = 0; level < 2 && cls != Nil; level++) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name rangeOfString:@"egin"].location != NSNotFound ||
                [name rangeOfString:@"omplet"].location != NSNotFound ||
                [name rangeOfString:@"uest"].location != NSNotFound) {
                [names addObject:name];
            }
        }
        free(methods);
        cls = class_getSuperclass(cls);
    }

    [names sortUsingSelector:@selector(compare:)];
    if (names.count > 24) {
        names = [[names subarrayWithRange:NSMakeRange(0, 24)] mutableCopy];
    }

    return [NSString stringWithFormat:@"NSExtension API (%@): %@",
            NSStringFromClass([extension class]),
            [names componentsJoinedByString:@", "]];
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
