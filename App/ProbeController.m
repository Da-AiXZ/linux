#import "ProbeController.h"

#import "ProbeMachPort.h"
#import "ProbeProtocol.h"

#import <mach/mach.h>
#import <mach/mach_error.h>
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

@interface ProbeController ()

@property (nonatomic, strong) id extension;
@property (nonatomic, strong) NSUUID *requestID;
@property (nonatomic, assign) mach_port_t receivePort;
@property (atomic, assign) BOOL running;

@end

@implementation ProbeController

- (instancetype)init
{
    self = [super init];
    if (self) {
        _receivePort = MACH_PORT_NULL;
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
                   error.localizedDescription ?: @"unknown error"]];
        return NO;
    }

    mach_port_t receivePort = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &receivePort);
    if (kr != KERN_SUCCESS) {
        [self log:[NSString stringWithFormat:@"mach_port_allocate failed: %s",
                   mach_error_string(kr)]];
        return NO;
    }

    mach_port_t sendPort = MACH_PORT_NULL;
    mach_msg_type_name_t sendType = 0;
    kr = mach_port_extract_right(mach_task_self(),
                                 receivePort,
                                 MACH_MSG_TYPE_MAKE_SEND,
                                 &sendPort,
                                 &sendType);
    if (kr != KERN_SUCCESS) {
        [self log:[NSString stringWithFormat:@"mach_port_extract_right failed: %s",
                   mach_error_string(kr)]];
        mach_port_destroy(mach_task_self(), receivePort);
        return NO;
    }

    ProbeMachPort *port = [[ProbeMachPort alloc] initWithPortName:sendPort];
    mach_port_deallocate(mach_task_self(), sendPort);
    if (port == nil) {
        [self log:@"Could not wrap the Mach send right."];
        mach_port_destroy(mach_task_self(), receivePort);
        return NO;
    }

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{
        @"port": port,
        @"hostPid": @(getpid()),
    };

    NSError *requestError = nil;
    NSUUID *request = [extension beginExtensionRequestWithInputItems:@[item]
                                                               error:&requestError];
    if (request == nil) {
        [self log:[NSString stringWithFormat:@"beginExtensionRequest failed: %@",
                   requestError.localizedDescription ?: @"unknown error"]];

        /*
         * Diagnostic fallback: launch the same extension with a plain
         * property-list item. If this succeeds, the extension itself is
         * healthy and the custom Mach-port object is the problem. If it
         * also fails, the extension bundle/signature/registration is the
         * problem.
         */
        NSExtensionItem *plainItem = [NSExtensionItem new];
        plainItem.userInfo = @{
            @"hostPid": @(getpid()),
            @"noPort": @YES,
        };
        NSError *plainError = nil;
        NSUUID *plainRequest =
            [extension beginExtensionRequestWithInputItems:@[plainItem]
                                                     error:&plainError];
        if (plainRequest != nil) {
            pid_t plainPid = [extension pidForRequestIdentifier:plainRequest];
            [self log:[NSString stringWithFormat:
                       @"plain launch succeeded (pid=%d); the Mach-port item is the problem.",
                       plainPid]];
            [extension _kill:SIGKILL];
        } else {
            [self log:[NSString stringWithFormat:
                       @"plain launch also failed: %@",
                       plainError.localizedDescription ?: @"unknown error"]];
        }

        mach_port_destroy(mach_task_self(), receivePort);
        return NO;
    }

    self.extension = extension;
    self.requestID = request;
    self.receivePort = receivePort;
    self.running = YES;

    pid_t extensionPid = [extension pidForRequestIdentifier:request];
    [self log:[NSString stringWithFormat:
               @"request=%@ extension=%@ pid=%d hostPid=%d",
               request.UUIDString,
               identifier,
               extensionPid,
               getpid()]];

    [NSThread detachNewThreadSelector:@selector(receiveLoop)
                             toTarget:self
                           withObject:nil];
    return YES;
}

- (void)stop
{
    self.running = NO;
    if (self.receivePort != MACH_PORT_NULL) {
        mach_port_destroy(mach_task_self(), self.receivePort);
        self.receivePort = MACH_PORT_NULL;
    }
}

- (void)receiveLoop
{
    @autoreleasepool {
        uint8_t buffer[sizeof(ProbeMessage) + 512];

        while (self.running) {
            memset(buffer, 0, sizeof(buffer));
            mach_msg_header_t *header = (mach_msg_header_t *)buffer;

            mach_msg_return_t mr = mach_msg(
                header,
                MACH_RCV_MSG
                    | MACH_RCV_TIMEOUT
                    | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)
                    | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                0,
                (mach_msg_size_t)sizeof(buffer),
                self.receivePort,
                5000,
                MACH_PORT_NULL);

            if (mr == MACH_RCV_TIMED_OUT) {
                [self log:@"receive timed out waiting for the extension."];
                break;
            }
            if (mr != MACH_MSG_SUCCESS) {
                [self log:[NSString stringWithFormat:@"mach_msg receive failed: %s",
                           mach_error_string(mr)]];
                break;
            }

            mach_msg_audit_trailer_t *trailer =
                (mach_msg_audit_trailer_t *)((uint8_t *)header
                                             + round_msg(header->msgh_size));
            pid_t senderPid = (pid_t)trailer->msgh_audit.val[5];

            if (header->msgh_id == PROBE_MSG_PING) {
                ProbeReply reply;
                memset(&reply, 0, sizeof(reply));
                reply.header.msgh_bits =
                    MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
                reply.header.msgh_remote_port = header->msgh_remote_port;
                reply.header.msgh_local_port = MACH_PORT_NULL;
                reply.header.msgh_id = header->msgh_id + 100;
                reply.header.msgh_size = sizeof(reply);
                reply.result = 42;
                mach_msg(&reply.header,
                         MACH_SEND_MSG,
                         sizeof(reply),
                         0,
                         MACH_PORT_NULL,
                         MACH_MSG_TIMEOUT_NONE,
                         MACH_PORT_NULL);
                continue;
            }

            if (header->msgh_id == PROBE_MSG_RESULT
                || header->msgh_id == PROBE_MSG_DONE) {
                ProbeMessage *message = (ProbeMessage *)header;
                if (message->length <= PROBE_PAYLOAD_MAX) {
                    NSString *json =
                        [[NSString alloc] initWithBytes:message->payload
                                                 length:message->length
                                               encoding:NSUTF8StringEncoding];
                    [self log:[NSString stringWithFormat:@"[ext pid %d] %@",
                               senderPid,
                               json ?: @"<invalid UTF-8>"]];
                }
                if (message->kind == PROBE_MSG_DONE
                    || header->msgh_id == PROBE_MSG_DONE) {
                    break;
                }
            }
        }

        self.running = NO;
        [self log:@"receive loop ended."];

        void (^completion)(void) = self.completionHandler;
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    }
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
