#import "ProbeController.h"

#import "ProbeMachPort.h"
#import "ProbeProtocol.h"

#import <errno.h>
#import <mach/mach.h>
#import <mach/mach_error.h>
#import <signal.h>
#import <string.h>
#import <sys/socket.h>
#import <unistd.h>

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
@property (nonatomic, assign) int socketReadFD;
@property (atomic, assign) BOOL running;
@property (atomic, assign) BOOL completed;

@end

@implementation ProbeController

- (instancetype)init
{
    self = [super init];
    if (self) {
        _receivePort = MACH_PORT_NULL;
        _socketReadFD = -1;
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

    [self log:[NSString stringWithFormat:@"extension bundle: %@", extensionPath]];

    /*
     * Attempt 1: raw Mach send right in NSExtensionItem.userInfo.
     */
    mach_port_t receivePort = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &receivePort);
    if (kr == KERN_SUCCESS) {
        mach_port_t sendPort = MACH_PORT_NULL;
        mach_msg_type_name_t sendType = 0;
        kr = mach_port_extract_right(mach_task_self(),
                                     receivePort,
                                     MACH_MSG_TYPE_MAKE_SEND,
                                     &sendPort,
                                     &sendType);
        if (kr == KERN_SUCCESS) {
            ProbeMachPort *port =
                [[ProbeMachPort alloc] initWithPortName:sendPort];
            mach_port_deallocate(mach_task_self(), sendPort);
            if (port != nil) {
                NSExtensionItem *item = [NSExtensionItem new];
                item.userInfo = @{
                    @"port": port,
                    @"hostPid": @(getpid()),
                };

                NSError *requestError = nil;
                NSUUID *request =
                    [extension beginExtensionRequestWithInputItems:@[item]
                                                             error:&requestError];
                if (request != nil) {
                    self.extension = extension;
                    self.requestID = request;
                    self.receivePort = receivePort;
                    self.running = YES;

                    pid_t extensionPid =
                        [extension pidForRequestIdentifier:request];
                    [self log:[NSString stringWithFormat:
                               @"mach launch ok: request=%@ pid=%d hostPid=%d",
                               request.UUIDString,
                               extensionPid,
                               getpid()]];
                    [NSThread detachNewThreadSelector:@selector(receiveLoop)
                                             toTarget:self
                                           withObject:nil];
                    return YES;
                }

                [self log:[NSString stringWithFormat:
                           @"Mach-port launch failed: %@",
                           requestError.localizedDescription ?: @"unknown error"]];
            }
        }
    }
    if (receivePort != MACH_PORT_NULL) {
        mach_port_destroy(mach_task_self(), receivePort);
    }

    /*
     * Attempt 2: Unix socketpair wrapped in NSFileHandle. This avoids custom
     * NSSecureCoding objects in NSExtensionItem.userInfo and is enough to get
     * all probe results back. The Mach-port path is only needed for the ping
     * latency test and for future task-port handoff.
     */
    int fds[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0) {
        NSFileHandle *writeHandle =
            [[NSFileHandle alloc] initWithFileDescriptor:fds[1]
                                         closeOnDealloc:YES];
        NSExtensionItem *socketItem = [NSExtensionItem new];
        socketItem.userInfo = @{
            @"socket": writeHandle,
            @"hostPid": @(getpid()),
        };

        NSError *socketError = nil;
        NSUUID *socketRequest =
            [extension beginExtensionRequestWithInputItems:@[socketItem]
                                                     error:&socketError];
        if (socketRequest != nil) {
            self.extension = extension;
            self.requestID = socketRequest;
            self.socketReadFD = fds[0];
            self.running = YES;

            pid_t extensionPid =
                [extension pidForRequestIdentifier:socketRequest];
            [self log:[NSString stringWithFormat:
                       @"socketpair launch ok: request=%@ pid=%d hostPid=%d",
                       socketRequest.UUIDString,
                       extensionPid,
                       getpid()]];
            [NSThread detachNewThreadSelector:@selector(socketReadLoop)
                                     toTarget:self
                                   withObject:nil];
            return YES;
        }

        [self log:[NSString stringWithFormat:
                   @"socketpair launch failed: %@",
                   socketError.localizedDescription ?: @"unknown error"]];
        close(fds[0]);
    } else {
        [self log:[NSString stringWithFormat:@"socketpair failed: %s",
                   strerror(errno)]];
    }

    /*
     * Attempt 3: plain property-list item, purely diagnostic. If this
     * succeeds, the extension itself is healthy and the transport object is
     * the problem. If it also fails, the appex registration/signature/config
     * is the problem.
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
                   @"plain launch succeeded (pid=%d); both transports are the problem.",
                   plainPid]];
        [extension _kill:SIGKILL];
    } else {
        [self log:[NSString stringWithFormat:
                   @"plain launch also failed: %@",
                   plainError.localizedDescription ?: @"unknown error"]];
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

    if (self.receivePort != MACH_PORT_NULL) {
        mach_port_destroy(mach_task_self(), self.receivePort);
        self.receivePort = MACH_PORT_NULL;
    }
    if (self.socketReadFD >= 0) {
        close(self.socketReadFD);
        self.socketReadFD = -1;
    }

    [self log:@"probe finished."];

    void (^completion)(void) = self.completionHandler;
    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

#pragma mark - Mach transport

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

        [self finish];
    }
}

#pragma mark - Socket transport

- (void)socketReadLoop
{
    @autoreleasepool {
        NSMutableData *pending = [NSMutableData data];
        uint8_t buffer[2048];

        while (self.running) {
            ssize_t count = read(self.socketReadFD, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) {
                continue;
            }
            if (count <= 0) {
                break;
            }

            [pending appendBytes:buffer length:(NSUInteger)count];

            const uint8_t newline = '\n';
            NSData *newlineData = [NSData dataWithBytes:&newline length:1];

            while (self.running) {
                NSRange range = [pending rangeOfData:newlineData
                                             options:0
                                               range:NSMakeRange(0, pending.length)];
                if (range.location == NSNotFound) {
                    break;
                }

                NSData *line = [pending subdataWithRange:NSMakeRange(0, range.location)];
                [pending replaceBytesInRange:NSMakeRange(0, range.location + 1)
                                   withBytes:NULL
                                      length:0];

                NSString *json = [[NSString alloc] initWithData:line
                                                       encoding:NSUTF8StringEncoding];
                [self log:[NSString stringWithFormat:@"[socket] %@",
                           json ?: @"<invalid UTF-8>"]];

                if ([json containsString:@"\"done\":true"]) {
                    [self finish];
                    return;
                }
            }
        }

        [self finish];
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
