#import <Foundation/Foundation.h>

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

#import "ProbeMachPort.h"
#import "ProbeProtocol.h"

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

extern char **environ;
extern kern_return_t task_for_pid(mach_port_t target_task,
                                  int pid,
                                  mach_port_t *task);

@interface ProbeExtension : NSObject <NSExtensionRequestHandling>
@end

@implementation ProbeExtension

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    @autoreleasepool {
        NSExtensionItem *item = context.inputItems.firstObject;
        NSDictionary *input = item.userInfo;
        id portObject = input[@"port"];

        if (![portObject isKindOfClass:[ProbeMachPort class]]) {
            [context completeRequestReturningItems:nil completionHandler:nil];
            return;
        }

        ProbeMachPort *port = (ProbeMachPort *)portObject;
        mach_port_t hostPort = port.port;
        NSNumber *hostPidNumber = input[@"hostPid"];
        pid_t hostPid = hostPidNumber != nil ? hostPidNumber.intValue : 0;

        NSMutableDictionary *results = [NSMutableDictionary dictionary];

        results[@"stage"] = @"device";
        results[@"pid"] = @(getpid());
        results[@"hostPid"] = @(hostPid);
        results[@"device"] = [self deviceInfo];
        [self sendKind:PROBE_MSG_RESULT json:results toPort:hostPort];

        /*
         * Each risky probe is sent as its own stage, so a crash still leaves
         * the earlier results in the host's log.
         */
        [self sendKind:PROBE_MSG_RESULT
                  json:@{@"stage": @"process",
                         @"process": [self processInfoWithHostPid:hostPid]}
                toPort:hostPort];

        [self sendKind:PROBE_MSG_RESULT
                  json:@{@"stage": @"mach",
                         @"mach": [self machProbeWithPort:hostPort]}
                toPort:hostPort];

        /*
         * JIT is deliberately last. If executing the RX page faults, the
         * extension dies here and the host still has every earlier result.
         */
        [self sendKind:PROBE_MSG_RESULT
                  json:@{@"stage": @"jit",
                         @"jit": [self jitProbe]}
                toPort:hostPort];

        [self sendKind:PROBE_MSG_DONE json:@{@"done": @YES} toPort:hostPort];
        [context completeRequestReturningItems:nil completionHandler:nil];
    }
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

#pragma mark - Mach round trip

- (NSDictionary *)machProbeWithPort:(mach_port_t)hostPort
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    mach_port_t replyPort = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(),
                                          MACH_PORT_RIGHT_RECEIVE,
                                          &replyPort);
    if (kr != KERN_SUCCESS) {
        result[@"allocateError"] = @(kr);
        return result;
    }

    const int count = 10;
    int completed = 0;
    uint64_t started = mach_absolute_time();

    for (int index = 0; index < count; index++) {
        ProbeMessage message;
        memset(&message, 0, sizeof(message));
        message.header.msgh_bits =
            MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,
                           MACH_MSG_TYPE_MAKE_SEND_ONCE);
        message.header.msgh_remote_port = hostPort;
        message.header.msgh_local_port = replyPort;
        message.header.msgh_id = PROBE_MSG_PING;
        message.header.msgh_size = sizeof(message);
        message.kind = PROBE_MSG_PING;

        mach_msg_return_t mr = mach_msg(&message.header,
                                        MACH_SEND_MSG,
                                        sizeof(message),
                                        0,
                                        MACH_PORT_NULL,
                                        MACH_MSG_TIMEOUT_NONE,
                                        MACH_PORT_NULL);
        if (mr != MACH_MSG_SUCCESS) {
            result[@"sendError"] = @(mr);
            break;
        }

        ProbeReply reply;
        memset(&reply, 0, sizeof(reply));
        mr = mach_msg(&reply.header,
                      MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                      0,
                      sizeof(reply),
                      replyPort,
                      500,
                      MACH_PORT_NULL);
        if (mr != MACH_MSG_SUCCESS) {
            result[@"receiveError"] = @(mr);
            break;
        }
        if (reply.result != 42) {
            result[@"badReply"] = @(reply.result);
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

    mach_port_destroy(mach_task_self(), replyPort);
    return result;
}

#pragma mark - Mach send

- (void)sendKind:(uint32_t)kind
            json:(NSDictionary *)dictionary
          toPort:(mach_port_t)port
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary
                                                   options:0
                                                     error:NULL];
    if (data == nil) {
        return;
    }

    NSUInteger length = MIN(data.length, (NSUInteger)PROBE_PAYLOAD_MAX);
    ProbeMessage message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_remote_port = port;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = kind;
    message.kind = kind;
    message.length = (uint32_t)length;
    memcpy(message.payload, data.bytes, length);

    mach_msg_size_t size =
        (mach_msg_size_t)(offsetof(ProbeMessage, payload) + length);
    size = (size + 3u) & ~3u;
    message.header.msgh_size = size;

    mach_msg(&message.header,
             MACH_SEND_MSG,
             size,
             0,
             MACH_PORT_NULL,
             MACH_MSG_TIMEOUT_NONE,
             MACH_PORT_NULL);
}

@end
