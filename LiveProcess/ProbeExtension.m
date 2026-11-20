#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <os/proc.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/resource.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>

#import "ProbeExtension.h"
#import "ProbeMach.h"

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

extern char **environ;
extern kern_return_t task_for_pid(mach_port_t target_task,
                                  int pid,
                                  mach_port_t *task);

static mach_port_t ServicePort = MACH_PORT_NULL;

static void ProbeNotify(CFStringRef name)
{
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        name,
        NULL,
        NULL,
        true);
}

__attribute__((constructor))
static void ProbeExtensionDidLoad(void)
{
    ProbeNotify(CFSTR("com.daixz.linux.probe.ext-alive"));
}

#pragma mark - Mach output

static void ProbeSend(NSDictionary *payload)
{
    if (!MACH_PORT_VALID(ServicePort)) {
        return;
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:0
                                                     error:NULL];
    if (json == nil || json.length > PROBE_MACH_PAYLOAD_MAX) {
        return;
    }

    ProbeMachMessage message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits =
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_remote_port = ServicePort;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = 1;
    message.header.msgh_size = (mach_msg_size_t)(
        sizeof(mach_msg_header_t) + sizeof(uint32_t) * 2 + json.length);
    message.magic = PROBE_MACH_MAGIC;
    message.length = (uint32_t)json.length;
    memcpy(message.payload, json.bytes, json.length);

    mach_msg(&message.header,
             MACH_SEND_MSG | MACH_SEND_TIMEOUT,
             message.header.msgh_size,
             0,
             MACH_PORT_NULL,
             5000,
             MACH_PORT_NULL);
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

static NSDictionary *ProbeDeviceInfo(void)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    info[@"pid"] = @(getpid());
    info[@"ppid"] = @(getppid());
    info[@"uid"] = @(getuid());
    info[@"gid"] = @(getgid());
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

static NSDictionary *ProbeProcessInfo(pid_t hostPid)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    errno = 0;
    pid_t forked = fork();
    if (forked == 0) {
        _exit(0);
    }
    info[@"fork"] = @(forked);
    info[@"forkErrno"] = @(errno);
    if (forked > 0) {
        waitpid(forked, NULL, 0);
    }

    char selfPath[1024];
    uint32_t selfPathSize = sizeof(selfPath);
    _NSGetExecutablePath(selfPath, &selfPathSize);
    info[@"selfPath"] = [NSString stringWithUTF8String:selfPath] ?: @"";

    errno = 0;
    pid_t child = 0;
    char *argv[] = { selfPath, "--nested", NULL };
    int spawnResult = posix_spawn(&child, selfPath, NULL, NULL, argv, environ);
    info[@"nestedSpawn"] = @(spawnResult);
    info[@"nestedSpawnErrno"] = @(errno);
    if (spawnResult == 0) {
        waitpid(child, NULL, 0);
    }

    errno = 0;
    pid_t child2 = 0;
    char *lsArgv[] = { "/bin/ls", NULL };
    int lsResult = posix_spawn(&child2, "/bin/ls", NULL, NULL, lsArgv, environ);
    info[@"spawnLS"] = @(lsResult);
    info[@"spawnLSErrno"] = @(errno);
    if (lsResult == 0) {
        kill(child2, SIGKILL);
        waitpid(child2, NULL, 0);
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

static NSDictionary *ProbeJITInfo(void)
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

#pragma mark - Entry used by the custom NSExtensionMain

int ProbeExtensionRun(pid_t hostPid, mach_port_t servicePort)
{
    @autoreleasepool {
        ServicePort = servicePort;
        ProbeNotify(CFSTR("com.daixz.linux.probe.ext-run"));

        ProbeSend(@{ @"stage": @"hello",
                     @"pid": @(getpid()),
                     @"hostPid": @(hostPid) });

        NSDictionary *device = @{ @"stage": @"device",
                                  @"device": ProbeDeviceInfo() };
        ProbeSend(device);

        NSDictionary *process = @{ @"stage": @"process",
                                   @"process": ProbeProcessInfo(hostPid) };
        ProbeSend(process);

        ProbeSend(@{ @"stage": @"ipc",
                     @"ipc": @{ @"transport": @"mach",
                                @"hostPid": @(hostPid) } });

        /*
         * JIT is last: executing the RX page is the one probe that can
         * kill the process, and everything above is already delivered.
         */
        NSDictionary *jit = @{ @"stage": @"jit",
                               @"jit": ProbeJITInfo() };
        ProbeSend(jit);

        ProbeSend(@{ @"stage": @"done", @"done": @YES });
    }

    return 0;
}

/*
 * Present in the bundle so PlugInKit can validate the extension, but the
 * custom NSExtensionMain never uses this path.
 */
@interface ProbeExtension : UIViewController <NSExtensionRequestHandling>
@end

@implementation ProbeExtension

- (void)loadView
{
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
}

- (NSString *)jsonStringForObject:(id)object
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:NULL];
    if (data == nil) {
        return @"{}";
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: @"{}";
}

- (void)sendURLPayload:(NSDictionary *)payload
               context:(NSExtensionContext *)context
{
    if (![context respondsToSelector:
            @selector(openURL:completionHandler:)]) {
        NSLog(@"ProbeExtension: openURL is unavailable");
        return;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:0
                                                     error:NULL];
    if (data == nil) {
        return;
    }

    NSString *base64 = [data base64EncodedStringWithOptions:0];
    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"linuxprobe://results"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"payload" value:base64],
    ];

    NSURL *url = components.URL;
    if (url == nil) {
        return;
    }

    [context openURL:url completionHandler:^(BOOL success) {
        if (!success) {
            NSLog(@"ProbeExtension: openURL failed");
        }
    }];
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    @autoreleasepool {
        ProbeNotify(CFSTR("com.daixz.linux.probe.ext-begin"));

        NSDictionary *input = context.inputItems.firstObject.userInfo;
        NSNumber *hostPidNumber = input[@"hostPid"];
        pid_t hostPid = hostPidNumber != nil ? hostPidNumber.intValue : 0;

        [self sendURLPayload:@{ @"stage": @"hello",
                                @"pid": @(getpid()),
                                @"hostPid": @(hostPid) }
                     context:context];

        NSDictionary *device = @{ @"stage": @"device",
                                  @"device": ProbeDeviceInfo() };
        [self sendURLPayload:device context:context];

        NSDictionary *process = @{ @"stage": @"process",
                                   @"process": ProbeProcessInfo(hostPid) };
        [self sendURLPayload:process context:context];

        NSDictionary *ipc = @{ @"stage": @"ipc",
                               @"ipc": @{ @"transport": @"url",
                                          @"hostPid": @(hostPid) } };
        [self sendURLPayload:ipc context:context];

        /*
         * JIT is last: executing the RX page is the one probe that can
         * kill the process, and everything above is already delivered.
         */
        NSDictionary *jit = @{ @"stage": @"jit",
                               @"jit": ProbeJITInfo() };
        [self sendURLPayload:jit context:context];

        [self sendURLPayload:@{ @"stage": @"done", @"done": @YES }
                     context:context];

        NSExtensionItem *item = [NSExtensionItem new];
        item.userInfo = @{
            @"probeResult":
                [self jsonStringForObject:@[ device, process, ipc, jit ]],
        };
        [context completeRequestReturningItems:@[item] completionHandler:nil];
    }
}

@end
