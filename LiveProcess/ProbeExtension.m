#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <os/proc.h>
#import <signal.h>
#import <spawn.h>
#import <sys/mman.h>
#import <sys/resource.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>

#import "ProbeXPCProtocol.h"

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

extern char **environ;
extern kern_return_t task_for_pid(mach_port_t target_task,
                                  int pid,
                                  mach_port_t *task);

@interface ProbeExtension : UIViewController <NSExtensionRequestHandling>
@end

@implementation ProbeExtension {
    NSXPCConnection *_connection;
}

- (void)loadView
{
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    @autoreleasepool {
        NSExtensionItem *item = context.inputItems.firstObject;
        NSDictionary *input = item.userInfo;
        id endpointObject = input[@"endpoint"];

        if (![endpointObject isKindOfClass:[NSXPCListenerEndpoint class]]) {
            NSLog(@"ProbeExtension: no NSXPCListenerEndpoint in input");
            [context completeRequestReturningItems:nil completionHandler:nil];
            return;
        }

        NSNumber *hostPidNumber = input[@"hostPid"];
        pid_t hostPid = hostPidNumber != nil ? hostPidNumber.intValue : 0;

        NSXPCConnection *connection =
            [[NSXPCConnection alloc] initWithListenerEndpoint:endpointObject];
        connection.remoteObjectInterface =
            [NSXPCInterface interfaceWithProtocol:@protocol(ProbeServiceProtocol)];
        connection.invalidationHandler = ^{
            NSLog(@"ProbeExtension: XPC connection invalidated");
        };
        connection.interruptionHandler = ^{
            NSLog(@"ProbeExtension: XPC connection interrupted");
        };
        [connection resume];
        _connection = connection;

        id<ProbeServiceProtocol> proxy =
            [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
                NSLog(@"ProbeExtension: XPC proxy error: %@", error);
            }];

        NSMutableDictionary *device = [NSMutableDictionary dictionary];
        device[@"stage"] = @"device";
        device[@"pid"] = @(getpid());
        device[@"hostPid"] = @(hostPid);
        device[@"device"] = [self deviceInfo];
        [self sendJSON:device proxy:proxy];

        /*
         * Each risky probe is its own stage, so a crash still leaves the
         * earlier results in the host's log.
         */
        [self sendJSON:@{@"stage": @"process",
                         @"process": [self processInfoWithHostPid:hostPid]}
                 proxy:proxy];

        [self sendJSON:@{@"stage": @"xpc",
                         @"xpc": [self xpcProbeWithProxy:proxy]}
                 proxy:proxy];

        /*
         * JIT is deliberately last. If executing the RX page faults, the
         * extension dies here and the host still has every earlier result.
         */
        [self sendJSON:@{@"stage": @"jit",
                         @"jit": [self jitProbe]}
                 proxy:proxy];

        [self sendDoneWithProxy:proxy context:context];
    }
}

#pragma mark - XPC transport

- (BOOL)sendJSON:(NSDictionary *)dictionary
           proxy:(id<ProbeServiceProtocol>)proxy
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary
                                                   options:0
                                                     error:NULL];
    if (data == nil || proxy == nil) {
        return NO;
    }

    NSString *json = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    if (json == nil) {
        return NO;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [proxy logJSON:json withReply:^{
        dispatch_semaphore_signal(semaphore);
    }];

    return dispatch_semaphore_wait(
               semaphore,
               dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)))
        == 0;
}

- (void)sendDoneWithProxy:(id<ProbeServiceProtocol>)proxy
                  context:(NSExtensionContext *)context
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"done": @YES}
                                                   options:0
                                                     error:NULL];
    NSString *json = data != nil
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"{\"done\":true}";

    __block BOOL completed = NO;
    void (^finish)(void) = ^{
        if (completed) {
            return;
        }
        completed = YES;
        [context completeRequestReturningItems:nil completionHandler:nil];
    };

    if (proxy != nil) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [proxy logJSON:json withReply:^{
            dispatch_semaphore_signal(semaphore);
            finish();
        }];
        dispatch_semaphore_wait(
            semaphore,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
    }

    finish();
    [_connection invalidate];
}

#pragma mark - Device

static NSString *ProbeSysctlString(const char *name)
{
    size_t size = 0;
    if (sysctlbyname(name, NULL, &size, NULL, 0) != 0 || size == 0) {
        return @"";
    }

    char *buffer = calloc(1, size + 1);
    if (buffer == NULL) {
        return @"";
    }

    int result = sysctlbyname(name, buffer, &size, NULL, 0);
    NSString *value = result == 0 ? [NSString stringWithUTF8String:buffer] : @"";
    free(buffer);
    return value ?: @"";
}

- (NSDictionary *)deviceInfo
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    info[@"machine"] = ProbeSysctlString("hw.machine");
    info[@"osversion"] = ProbeSysctlString("kern.osversion");
    info[@"system"] = NSProcessInfo.processInfo.operatingSystemVersionString ?: @"";
    info[@"physicalMemory"] = @(NSProcessInfo.processInfo.physicalMemory);
    info[@"availableMemory"] = @(os_proc_available_memory());

    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0) {
        info[@"nofileCur"] = @(limit.rlim_cur);
        info[@"nofileMax"] = @(limit.rlim_max);
    }

    info[@"home"] = NSHomeDirectory() ?: @"";
    info[@"tmp"] = NSTemporaryDirectory() ?: @"";
    info[@"writableTmp"] =
        @([[NSFileManager defaultManager] isWritableFileAtPath:NSTemporaryDirectory()]);
    info[@"writableRoot"] =
        @([[NSFileManager defaultManager] isWritableFileAtPath:@"/"]);

    return info;
}

#pragma mark - Process model

- (NSDictionary *)processInfoWithHostPid:(pid_t)hostPid
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    info[@"pid"] = @(getpid());
    info[@"ppid"] = @(getppid());
    info[@"uid"] = @(getuid());
    info[@"gid"] = @(getgid());

    errno = 0;
    pid_t forked = fork();
    if (forked == 0) {
        _exit(0);
    }
    info[@"fork"] = @(forked);
    info[@"forkErrno"] = @(errno);

    errno = 0;
    pid_t child = 0;
    char *argv[] = { "/bin/ls", NULL };
    int spawnResult = posix_spawn(&child, "/bin/ls", NULL, NULL, argv, environ);
    info[@"posixSpawn"] = @(spawnResult);
    info[@"posixSpawnErrno"] = @(errno);
    if (spawnResult == 0) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
    }

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), getpid(), &task);
    info[@"taskForPidSelf"] = @(kr);
    if (task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), task);
    }

    task = MACH_PORT_NULL;
    kr = task_for_pid(mach_task_self(), hostPid, &task);
    info[@"taskForPidHost"] = @(kr);
    if (task != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), task);
    }

    void *foundation =
        dlopen("/System/Library/Frameworks/Foundation.framework/Foundation",
               RTLD_NOW);
    info[@"dlopenFoundation"] = @(foundation != NULL);
    if (foundation != NULL) {
        dlclose(foundation);
    }

    return info;
}

#pragma mark - JIT / RX

- (NSDictionary *)jitProbe
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    size_t pageSize = (size_t)getpagesize();

    errno = 0;
    void *memory = mmap(NULL,
                        pageSize,
                        PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANON,
                        -1,
                        0);
    result[@"mmapRW"] = @(memory != MAP_FAILED);
    if (memory == MAP_FAILED) {
        result[@"mmapErrno"] = @(errno);
        return result;
    }

    /* mov x0, #42 ; ret */
    const uint32_t code[] = { 0xD2800540u, 0xD65F03C0u };
    memcpy(memory, code, sizeof(code));

    errno = 0;
    int protectResult = mprotect(memory, pageSize, PROT_READ | PROT_EXEC);
    result[@"mprotectRX"] = @(protectResult == 0);
    result[@"mprotectErrno"] = @(errno);

    if (protectResult == 0) {
        int (*function)(void) = (int (*)(void))memory;
        result[@"execResult"] = @(function());
    }

    munmap(memory, pageSize);

    errno = 0;
    void *jitMemory = mmap(NULL,
                           pageSize,
                           PROT_READ | PROT_WRITE,
                           MAP_PRIVATE | MAP_ANON | MAP_JIT,
                           -1,
                           0);
    result[@"mmapJIT"] = @(jitMemory != MAP_FAILED);
    result[@"mmapJITErrno"] = @(errno);
    if (jitMemory != MAP_FAILED) {
        munmap(jitMemory, pageSize);
    }

    return result;
}

#pragma mark - XPC round trip

- (NSDictionary *)xpcProbeWithProxy:(id<ProbeServiceProtocol>)proxy
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    if (proxy == nil) {
        result[@"skipped"] = @"no XPC proxy";
        return result;
    }

    const int count = 10;
    int completed = 0;
    uint64_t started = mach_absolute_time();

    for (int index = 0; index < count; index++) {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block int64_t value = 0;

        [proxy pingWithReply:^(int64_t replyValue) {
            value = replyValue;
            dispatch_semaphore_signal(semaphore);
        }];

        dispatch_time_t timeout =
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC));
        if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
            result[@"timeoutAtIndex"] = @(index);
            break;
        }
        if (value != 42) {
            result[@"badReply"] = @(value);
            break;
        }
        completed++;
    }

    uint64_t ended = mach_absolute_time();
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double nanoseconds =
        (double)(ended - started) * (double)timebase.numer / (double)timebase.denom;

    result[@"roundTrips"] = @(completed);
    result[@"totalMicroseconds"] = @(nanoseconds / 1000.0);
    result[@"microsecondsPerRoundTrip"] =
        completed > 0 ? @(nanoseconds / 1000.0 / completed) : @0;

    return result;
}

@end

/*
 * The principal class is instantiated by name from Info.plist. Keep an
 * explicit reference so Release dead-code stripping cannot remove it.
 */
__attribute__((constructor))
static void ProbeExtensionKeepPrincipalClass(void)
{
    (void)[ProbeExtension class];
}
