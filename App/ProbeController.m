#import "ProbeController.h"

#import "ProbeXPCProtocol.h"

#import <signal.h>

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

@class ProbeController;

@interface ProbeController (ProbeInternal)
- (void)log:(NSString *)line;
- (void)finish;
@end

#pragma mark - XPC service

@interface ProbeService : NSObject <ProbeServiceProtocol, NSXPCListenerDelegate>

@property (nonatomic, weak) ProbeController *controller;
@property (nonatomic, strong) NSXPCConnection *connection;

@end

@implementation ProbeService

- (BOOL)listener:(NSXPCListener *)listener
    shouldAcceptNewConnection:(NSXPCConnection *)newConnection
{
    newConnection.exportedInterface =
        [NSXPCInterface interfaceWithProtocol:@protocol(ProbeServiceProtocol)];
    newConnection.exportedObject = self;
    [newConnection resume];
    self.connection = newConnection;
    return YES;
}

- (void)logJSON:(NSString *)json withReply:(void (^)(void))reply
{
    [self.controller log:[NSString stringWithFormat:@"[xpc] %@", json]];

    if (reply != nil) {
        reply();
    }

    if ([json containsString:@"\"done\":true"]) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf.controller finish];
        });
    }
}

- (void)pingWithReply:(void (^)(int64_t value))reply
{
    if (reply != nil) {
        reply(42);
    }
}

@end

#pragma mark - Controller

@interface ProbeController ()

@property (nonatomic, strong) id extension;
@property (nonatomic, strong) NSUUID *requestID;
@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic, strong) ProbeService *service;
@property (atomic, assign) BOOL running;
@property (atomic, assign) BOOL completed;

@end

@implementation ProbeController

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

    [self log:[NSString stringWithFormat:@"extension bundle: %@", extensionPath]];

    /*
     * NSXPCListenerEndpoint is the one transport object that the extension
     * item serializer accepts. It is the same mechanism Nyxian uses for its
     * PEEndpoint. Custom NSSecureCoding objects and NSFileHandle both make
     * PlugInKit fail with NSCocoaErrorDomain 4097.
     */
    NSXPCListener *listener = [NSXPCListener anonymousListener];
    ProbeService *service = [ProbeService new];
    service.controller = self;
    listener.delegate = service;
    [listener resume];

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{
        @"endpoint": listener.endpoint,
        @"hostPid": @(getpid()),
    };

    NSError *requestError = nil;
    NSUUID *request = [extension beginExtensionRequestWithInputItems:@[item]
                                                               error:&requestError];
    if (request != nil) {
        self.extension = extension;
        self.requestID = request;
        self.listener = listener;
        self.service = service;
        self.running = YES;

        pid_t extensionPid = [extension pidForRequestIdentifier:request];
        [self log:[NSString stringWithFormat:
                   @"xpc launch ok: request=%@ pid=%d hostPid=%d",
                   request.UUIDString,
                   extensionPid,
                   getpid()]];

        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(20.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (weakSelf.running) {
                [weakSelf log:@"probe timed out."];
                [weakSelf finish];
            }
        });
        return YES;
    }

    [self log:[NSString stringWithFormat:@"xpc launch failed: %@",
               [self describeError:requestError]]];
    [listener invalidate];

    /*
     * Diagnostic fallback: plain property-list item. This should still
     * launch; if it does, the extension is healthy and only the transport
     * object is the problem.
     */
    NSExtensionItem *plainItem = [NSExtensionItem new];
    plainItem.userInfo = @{
        @"hostPid": @(getpid()),
        @"noTransport": @YES,
    };

    NSError *plainError = nil;
    NSUUID *plainRequest =
        [extension beginExtensionRequestWithInputItems:@[plainItem]
                                                 error:&plainError];
    if (plainRequest != nil) {
        pid_t plainPid = [extension pidForRequestIdentifier:plainRequest];
        [self log:[NSString stringWithFormat:
                   @"plain launch succeeded (pid=%d); the XPC endpoint is the problem.",
                   plainPid]];
        [extension _kill:SIGKILL];
    } else {
        [self log:[NSString stringWithFormat:
                   @"plain launch also failed: %@",
                   [self describeError:plainError]]];
    }

    return NO;
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

    [self.listener invalidate];
    self.listener = nil;

    [self.service.connection invalidate];
    self.service = nil;

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
