#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <notify.h>
#import <objc/message.h>
#import <os/proc.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/mman.h>
#import <sys/resource.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <unistd.h>
#import <xpc/xpc.h>

#import "ProbeChannels.h"
#import "ProbeExtension.h"
#import "ProbeMach.h"

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

extern char **environ;
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_check_in(mach_port_t bootstrap,
                                        const char *name,
                                        mach_port_t *port);
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

#pragma mark - Privilege-free channels

static void ProbeNotifyFormat(const char *format, int value)
{
    char buffer[160];
    snprintf(buffer, sizeof(buffer), format, value);
    CFStringRef name = CFStringCreateWithCString(kCFAllocatorDefault,
                                                 buffer,
                                                 kCFStringEncodingUTF8);
    if (name != NULL) {
        ProbeNotify(name);
        CFRelease(name);
    }
}

static void ProbePublishJSON(NSString *json, uint64_t sequence)
{
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return;
    }

    NSUInteger length = MIN(data.length, (NSUInteger)PROBE_NOTIFY_BYTES);

    /* 1. POSIX shared memory. */
    int fd = shm_open(PROBE_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        ProbeNotifyFormat("com.daixz.linux.probe.ext-shm-err-%d", errno);
    } else {
        if (ftruncate(fd, PROBE_SHM_SIZE) == 0) {
            void *memory = mmap(NULL,
                                PROBE_SHM_SIZE,
                                PROT_READ | PROT_WRITE,
                                MAP_SHARED,
                                fd,
                                0);
            if (memory != MAP_FAILED) {
                ProbeShmBlock *block = (ProbeShmBlock *)memory;
                block->magic = PROBE_SHM_MAGIC;
                block->length = (uint32_t)data.length;
                block->sequence = sequence;
                memcpy(block->json, data.bytes, data.length);
                msync(memory, PROBE_SHM_SIZE, MS_ASYNC);
                munmap(memory, PROBE_SHM_SIZE);
                ProbeNotify(CFSTR("com.daixz.linux.probe.ext-shm-ok"));
            } else {
                ProbeNotifyFormat("com.daixz.linux.probe.ext-shm-err-%d",
                                  errno);
            }
        } else {
            ProbeNotifyFormat("com.daixz.linux.probe.ext-shm-err-%d", errno);
        }
        close(fd);
    }

    /* 2. Darwin notify 64-bit state words. */
    const uint8_t *bytes = data.bytes;
    BOOL notifyOK = YES;
    for (int index = 0; index < PROBE_NOTIFY_CHUNKS; index++) {
        uint64_t word = 0;
        NSUInteger offset = (NSUInteger)index * 8;
        if (offset < length) {
            NSUInteger count = MIN((NSUInteger)8, length - offset);
            memcpy(&word, bytes + offset, count);
        }

        char name[96];
        snprintf(name, sizeof(name), PROBE_NOTIFY_PREFIX "%d", index);
        int token = 0;
        if (notify_register_check(name, &token) == NOTIFY_STATUS_OK) {
            notify_set_state(token, word);
            notify_cancel(token);
        } else {
            notifyOK = NO;
        }
    }

    int token = 0;
    if (notify_register_check(PROBE_NOTIFY_LEN, &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, (uint64_t)length);
        notify_cancel(token);
    } else {
        notifyOK = NO;
    }
    if (notify_register_check(PROBE_NOTIFY_DONE, &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, sequence);
        notify_cancel(token);
    } else {
        notifyOK = NO;
    }
    ProbeNotify(notifyOK
        ? CFSTR("com.daixz.linux.probe.ext-notify-ok")
        : CFSTR("com.daixz.linux.probe.ext-notify-err"));

    /* 3. General pasteboard (may require user approval on the host side). */
    @try {
        Class pasteboardClass = NSClassFromString(@"UIPasteboard");
        id pasteboard = pasteboardClass
            ? ((id (*)(id, SEL))objc_msgSend)(pasteboardClass,
                                              @selector(generalPasteboard))
            : nil;
        if (pasteboard != nil) {
            ((void (*)(id, SEL, id))objc_msgSend)(pasteboard,
                                                  @selector(setString:),
                                                  json);
            ProbeNotify(CFSTR("com.daixz.linux.probe.ext-paste-ok"));
        } else {
            ProbeNotify(CFSTR("com.daixz.linux.probe.ext-paste-missing"));
        }
    } @catch (__unused NSException *exception) {
        ProbeNotify(CFSTR("com.daixz.linux.probe.ext-paste-err"));
    }
}

static mach_port_t ProbeBootChannel(void)
{
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_check_in(bootstrap_port,
                                          PROBE_BOOT_SERVICE,
                                          &port);
    if (kr != KERN_SUCCESS || !MACH_PORT_VALID(port)) {
        ProbeNotifyFormat("com.daixz.linux.probe.ext-boot-err-%d", kr);
        return MACH_PORT_NULL;
    }
    ProbeNotify(CFSTR("com.daixz.linux.probe.ext-boot-ok"));

    ProbeMachMessage message;
    memset(&message, 0, sizeof(message));
    mach_msg_return_t result =
        mach_msg(&message.header,
                 MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                 0,
                 (mach_msg_size_t)sizeof(message),
                 port,
                 3000,
                 MACH_PORT_NULL);
    if (result == MACH_MSG_SUCCESS &&
        message.magic == PROBE_MACH_MAGIC &&
        MACH_PORT_VALID(message.header.msgh_local_port)) {
        ProbeNotify(CFSTR("com.daixz.linux.probe.ext-boot-connected"));
        return message.header.msgh_local_port;
    }

    ProbeNotifyFormat("com.daixz.linux.probe.ext-boot-recv-%d", result);
    mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    return MACH_PORT_NULL;
}

static void ProbePublishDictionary(NSDictionary *info, uint64_t sequence)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:info
                                                   options:0
                                                     error:NULL];
    NSString *json = data != nil
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"{}";
    ProbePublishJSON(json, sequence);
}

static BOOL ProbeEntitlementBool(const char *name)
{
    typedef xpc_object_t (*ProbeCopyEntitlementFn)(const char *);
    ProbeCopyEntitlementFn copyEntitlement =
        (ProbeCopyEntitlementFn)dlsym(RTLD_DEFAULT,
                                      "xpc_copy_entitlement_for_self");
    if (copyEntitlement == NULL) {
        return NO;
    }

    xpc_object_t value = copyEntitlement(name);
    if (value == NULL || xpc_get_type(value) != XPC_TYPE_BOOL) {
        return NO;
    }
    return xpc_bool_get_value(value);
}

static NSMutableDictionary *ProbeBaseInfo(pid_t hostPid)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"machine"] = ProbeSysctlString("hw.machine");
    info[@"os"] = ProbeSysctlString("kern.osversion");
    info[@"pid"] = @(getpid());
    info[@"host"] = @(hostPid);
    info[@"jitEnt"] = @(ProbeEntitlementBool("com.apple.security.cs.allow-jit"));
    info[@"dynCs"] = @(ProbeEntitlementBool("dynamic-codesigning"));

    NSDictionary *process = ProbeProcessInfo(hostPid);
    info[@"fork"] = process[@"fork"] ?: @(-1);
    info[@"forkErrno"] = process[@"forkErrno"] ?: @(-1);
    info[@"spawn"] = process[@"nestedSpawn"] ?: @(-1);
    info[@"spawnErrno"] = process[@"nestedSpawnErrno"] ?: @(-1);
    info[@"ls"] = process[@"spawnLS"] ?: @(-1);
    info[@"lsErrno"] = process[@"spawnLSErrno"] ?: @(-1);
    info[@"tfSelf"] = process[@"taskForPidSelf"] ?: @(-1);
    info[@"tfHost"] = process[@"taskForPidHost"] ?: @(-1);
    info[@"tmpW"] =
        @([[NSFileManager defaultManager] isWritableFileAtPath:NSTemporaryDirectory()]);

    return info;
}

int ProbeExtensionChannelRun(pid_t hostPid)
{
    @autoreleasepool {
        mach_port_t hostPort = ProbeBootChannel();
        if (MACH_PORT_VALID(hostPort)) {
            ServicePort = hostPort;
        }

        NSMutableDictionary *info = ProbeBaseInfo(hostPid);
        ProbePublishDictionary(info, 1);

        /*
         * JIT is published in stages: mprotect result first, then the
         * execution result. Executing the page is the step that can kill
         * the process, so the mprotect answer survives even then.
         */
        size_t pageSize = (size_t)getpagesize();
        errno = 0;
        void *memory = mmap(NULL,
                            pageSize,
                            PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANON,
                            -1,
                            0);
        info[@"jitMmap"] = @(memory != MAP_FAILED);
        info[@"jitMmapErrno"] = @(errno);

        if (memory != MAP_FAILED) {
            const uint32_t code[] = { 0xD2800540u, 0xD65F03C0u };
            memcpy(memory, code, sizeof(code));

            errno = 0;
            int protectResult =
                mprotect(memory, pageSize, PROT_READ | PROT_EXEC);
            info[@"jitRX"] = @(protectResult == 0);
            info[@"jitErrno"] = @(errno);
            ProbePublishDictionary(info, 2);

            if (protectResult == 0) {
                int (*function)(void) = (int (*)(void))memory;
                int execResult = function();
                info[@"jitExec"] = @(execResult);
                ProbePublishDictionary(info, 3);
            }

            munmap(memory, pageSize);
        } else {
            ProbePublishDictionary(info, 2);
        }

        errno = 0;
        void *jitMemory = mmap(NULL,
                               pageSize,
                               PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANON | MAP_JIT,
                               -1,
                               0);
        info[@"jitJIT"] = @(jitMemory != MAP_FAILED);
        info[@"jitJITErrno"] = @(errno);
        if (jitMemory != MAP_FAILED) {
            munmap(jitMemory, pageSize);
        }
        ProbePublishDictionary(info, 4);

        info[@"done"] = @YES;
        ProbePublishDictionary(info, 5);
        ProbeNotify(CFSTR("com.daixz.linux.probe.ext-done"));
    }

    return 0;
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

        NSExtensionItem *inputItem = context.inputItems.firstObject;
        NSDictionary *input = inputItem.userInfo;
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
