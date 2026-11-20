#import <Foundation/Foundation.h>

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

static NSString *ResultsPath = nil;

static void WriteAll(int fd, const void *bytes, size_t length)
{
    const uint8_t *cursor = (const uint8_t *)bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written <= 0) {
            return;
        }
        cursor += written;
        remaining -= (size_t)written;
    }
}

/*
 * Every line goes to stdout (captured by the host through a pipe) and to
 * the host's results file. Either channel alone is enough to read it.
 */
static void Emit(NSDictionary *payload)
{
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload
                                                   options:0
                                                     error:NULL];
    if (json == nil) {
        return;
    }

    NSMutableData *line = [json mutableCopy];
    const uint8_t newline = '\n';
    [line appendBytes:&newline length:1];

    WriteAll(STDOUT_FILENO, line.bytes, line.length);

    if (ResultsPath.length == 0) {
        return;
    }

    int fd = open(ResultsPath.fileSystemRepresentation,
                  O_WRONLY | O_APPEND);
    if (fd < 0) {
        return;
    }
    WriteAll(fd, line.bytes, line.length);
    fsync(fd);
    close(fd);
}

static NSString *SysctlString(const char *name)
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

static NSDictionary *DeviceInfo(NSString *resultsPath)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    info[@"pid"] = @(getpid());
    info[@"ppid"] = @(getppid());
    info[@"uid"] = @(getuid());
    info[@"gid"] = @(getgid());
    info[@"machine"] = SysctlString("hw.machine");
    info[@"osversion"] = SysctlString("kern.osversion");
    info[@"system"] = NSProcessInfo.processInfo.operatingSystemVersionString ?: @"";
    info[@"physicalMemory"] = @(NSProcessInfo.processInfo.physicalMemory);
    info[@"availableMemory"] = @(os_proc_available_memory());
    info[@"home"] = NSHomeDirectory() ?: @"";
    info[@"tmp"] = NSTemporaryDirectory() ?: @"";
    info[@"writableTmp"] =
        @([[NSFileManager defaultManager] isWritableFileAtPath:NSTemporaryDirectory()]);
    info[@"writableResults"] =
        @(resultsPath.length > 0 &&
          [[NSFileManager defaultManager] isWritableFileAtPath:resultsPath]);

    return info;
}

static NSDictionary *ProcessInfo(pid_t hostPid, const char *selfPath)
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

    errno = 0;
    pid_t child = 0;
    char *argv[] = { (char *)selfPath, "--nested", NULL };
    int spawnResult = posix_spawn(&child, selfPath, NULL, NULL, argv, environ);
    info[@"nestedSpawn"] = @(spawnResult);
    info[@"nestedSpawnErrno"] = @(errno);
    if (spawnResult == 0) {
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

static NSDictionary *IPCInfo(NSString *serviceName)
{
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"serviceName"] = serviceName ?: @"";

    if (serviceName.length == 0) {
        info[@"created"] = @NO;
        return info;
    }

    CFMessagePortRef port = CFMessagePortCreateRemote(
        kCFAllocatorDefault, (__bridge CFStringRef)serviceName);
    info[@"created"] = @(port != NULL);
    if (port == NULL) {
        return info;
    }

    NSDictionary *message = @{ @"stage": @"spawnIPC" };
    NSData *json = [NSJSONSerialization dataWithJSONObject:message
                                                   options:0
                                                     error:NULL];
    CFDataRef payload = CFDataCreate(kCFAllocatorDefault,
                                     json.bytes,
                                     (CFIndex)json.length);
    SInt32 status = kCFMessagePortTransportError;
    if (payload != NULL) {
        status = CFMessagePortSendRequest(port, 1, payload, 2.0, 2.0,
                                          NULL, NULL);
        CFRelease(payload);
    }
    info[@"sendStatus"] = @(status);

    CFMessagePortInvalidate(port);
    CFRelease(port);
    return info;
}

static NSDictionary *JITInfo(void)
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

int main(int argc, char *argv[])
{
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--nested") == 0) {
            return 0;
        }

        if (argc > 1) {
            ResultsPath = [NSString stringWithUTF8String:argv[1]];
        }
        pid_t hostPid = argc > 2 ? (pid_t)atoi(argv[2]) : 0;
        NSString *serviceName = argc > 3
            ? [NSString stringWithUTF8String:argv[3]]
            : nil;

        Emit(@{ @"stage": @"spawnDevice",
                @"spawnDevice": DeviceInfo(ResultsPath) });

        /*
         * Risky probes are ordered so a crash keeps everything above it.
         */
        Emit(@{ @"stage": @"spawnProcess",
                @"spawnProcess": ProcessInfo(hostPid, argv[0]) });
        Emit(@{ @"stage": @"spawnIPC",
                @"spawnIPC": IPCInfo(serviceName) });
        Emit(@{ @"stage": @"spawnJIT",
                @"spawnJIT": JITInfo() });
        Emit(@{ @"stage": @"spawnDone",
                @"spawnExit": @YES });
    }

    return 0;
}
