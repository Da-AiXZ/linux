#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <fcntl.h>
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

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif

extern char **environ;
extern kern_return_t task_for_pid(mach_port_t target_task,
                                  int pid,
                                  mach_port_t *task);

@interface ProbeExtension : UIViewController <NSExtensionRequestHandling>
@end

static void ProbePostDarwin(CFStringRef name)
{
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        name,
        NULL,
        NULL,
        true);
}

/*
 * Runs as soon as the extension binary is loaded, before NSExtensionMain
 * talks to the host. A Darwin notification is the only channel that does
 * not depend on the extension context handshake.
 */
__attribute__((constructor))
static void ProbeExtensionDidLoad(void)
{
    ProbePostDarwin(CFSTR("com.daixz.linux.probe.ext-alive"));
}

@implementation ProbeExtension {
    int _resultsFD;
    CFMessagePortRef _remotePort;
}

- (void)loadView
{
    self.view = [[UIView alloc] initWithFrame:CGRectZero];
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context
{
    @autoreleasepool {
        ProbePostDarwin(CFSTR("com.daixz.linux.probe.ext-begin"));
        /*
         * Liveness ping. This runs before anything else, so a silent run
         * tells us the request never reached this method.
         */
        [self sendURLPayload:@{ @"stage": @"hello", @"alive": @YES }
                     context:context];

        NSExtensionItem *item = context.inputItems.firstObject;
        NSDictionary *input = item.userInfo;

        NSString *resultsPath = input[@"resultsPath"];
        NSString *token = input[@"resultsToken"];
        NSString *serviceName = input[@"serviceName"];
        NSNumber *hostPidNumber = input[@"hostPid"];

        BOOL hasPath = [resultsPath isKindOfClass:[NSString class]]
            && resultsPath.length > 0;

        if ([serviceName isKindOfClass:[NSString class]]
            && serviceName.length > 0) {
            _remotePort = CFMessagePortCreateRemote(
                kCFAllocatorDefault,
                (__bridge CFStringRef)serviceName);
        }

        if (hasPath && [token isKindOfClass:[NSString class]]
            && token.length > 0) {
            typedef int64_t (*ProbeConsumeExtensionFn)(const char *);
            ProbeConsumeExtensionFn consume =
                (ProbeConsumeExtensionFn)dlsym(RTLD_DEFAULT,
                                               "sandbox_extension_consume");
            if (consume != NULL) {
                int64_t handle = consume(token.UTF8String);
                if (handle < 0) {
                    NSLog(@"ProbeExtension: sandbox_extension_consume failed");
                }
            }
        }

        _resultsFD = -1;
        if (hasPath) {
            _resultsFD = open(resultsPath.fileSystemRepresentation,
                              O_WRONLY | O_APPEND);
            if (_resultsFD < 0) {
                _resultsFD = open(resultsPath.fileSystemRepresentation,
                                  O_WRONLY | O_APPEND | O_CREAT,
                                  0644);
            }
            if (_resultsFD < 0) {
                NSLog(@"ProbeExtension: open results file failed: %s",
                      strerror(errno));
            }
        }

        pid_t hostPid = hostPidNumber != nil ? hostPidNumber.intValue : 0;
        NSMutableArray *stages = [NSMutableArray array];

        NSMutableDictionary *device = [NSMutableDictionary dictionary];
        device[@"stage"] = @"device";
        device[@"pid"] = @(getpid());
        device[@"hostPid"] = @(hostPid);
        device[@"device"] = [self deviceInfo];
        device[@"fileWritable"] = @(_resultsFD >= 0);
        device[@"portCreated"] = @(_remotePort != NULL);
        [stages addObject:device];
        [self sendJSON:device];
        [self sendURLPayload:@{ @"stage": @"device",
                                @"device": device }
                     context:context];

        /*
         * Each risky probe is its own stage, so a crash still leaves the
         * earlier results in the host's results file or message port.
         */
        NSDictionary *process = @{
            @"stage": @"process",
            @"process": [self processInfoWithHostPid:hostPid],
        };
        [stages addObject:process];
        [self sendJSON:process];
        [self sendURLPayload:@{ @"stage": @"process",
                                @"process": process }
                     context:context];

        /*
         * The plain-item launch path cannot carry a Mach port or XPC
         * endpoint on this OS, so the IPC latency probe is deferred to the
         * next milestone.
         */
        NSDictionary *ipc = @{
            @"stage": @"ipc",
            @"ipc": @{ @"transport": @"file",
                       @"skipped": @YES },
        };
        [stages addObject:ipc];
        [self sendJSON:ipc];
        [self sendURLPayload:@{ @"stage": @"ipc", @"ipc": ipc }
                     context:context];

        /*
         * JIT is deliberately last. If executing the RX page faults, the
         * extension dies here and the host still has every earlier result.
         */
        NSDictionary *jit = @{
            @"stage": @"jit",
            @"jit": [self jitProbe],
        };
        [stages addObject:jit];
        [self sendJSON:jit];
        [self sendURLPayload:@{ @"stage": @"jit", @"jit": jit }
                     context:context];

        [self sendURLPayload:@{ @"stage": @"done", @"done": @YES }
                     context:context];
        [self sendJSON:@{@"done": @YES}];

        /*
         * Canonical app-extension return channel. The host may receive
         * these items through its private NSExtension request completion
         * handler.
         */
        [self completeWithStages:stages context:context];

        if (_remotePort != NULL) {
            CFMessagePortInvalidate(_remotePort);
            CFRelease(_remotePort);
            _remotePort = NULL;
        }
        if (_resultsFD >= 0) {
            close(_resultsFD);
            _resultsFD = -1;
        }
    }
}

- (void)completeWithStages:(NSArray *)stages
                   context:(NSExtensionContext *)context
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"stages": stages,
        @"done": @YES,
    } options:0 error:NULL];
    NSString *text = data != nil
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        : @"{}";

    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{ @"probeResult": text ?: @"{}" };

    if ([context respondsToSelector:
            @selector(completeRequestReturningItems:completionHandler:)]) {
        [context completeRequestReturningItems:@[item]
                             completionHandler:nil];
    } else {
        [context completeRequestReturningItems:nil completionHandler:nil];
    }
}

#pragma mark - Results file

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
        NSLog(@"ProbeExtension: result URL is too large");
        return;
    }

    [context openURL:url completionHandler:^(BOOL success) {
        if (!success) {
            NSLog(@"ProbeExtension: openURL failed");
        }
    }];
}

- (BOOL)sendJSON:(NSDictionary *)dictionary
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary
                                                   options:0
                                                     error:NULL];
    if (data == nil) {
        return NO;
    }

    if (_remotePort != NULL) {
        CFDataRef payload = CFDataCreate(kCFAllocatorDefault,
                                         data.bytes,
                                         (CFIndex)data.length);
        if (payload != NULL) {
            SInt32 status = CFMessagePortSendRequest(_remotePort,
                                                     1,
                                                     payload,
                                                     2.0,
                                                     2.0,
                                                     NULL,
                                                     NULL);
            CFRelease(payload);
            if (status == kCFMessagePortSuccess) {
                return YES;
            }
        }
    }

    if (_resultsFD < 0) {
        return NO;
    }

    NSMutableData *line = [NSMutableData dataWithData:data];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];

    const uint8_t *bytes = line.bytes;
    size_t remaining = line.length;
    while (remaining > 0) {
        ssize_t written = write(_resultsFD, bytes, remaining);
        if (written <= 0) {
            return NO;
        }
        bytes += written;
        remaining -= (size_t)written;
    }

    fsync(_resultsFD);
    return YES;
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
