#import "GuestLauncher.h"

#import <mach/arm/thread_status.h>
#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach/thread_status.h>
#import <mach/vm_map.h>
#import <CommonCrypto/CommonDigest.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

/* <sys/ptrace.h> is not in the iOS SDK; declare the one request we need. */
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);
#define GUEST_PT_DETACH 11

extern char **environ;

@interface GuestLauncher ()

- (void)dumpThreadsOfGuest:(pid_t)pid;
- (void)dumpGuestMemory:(mach_port_t)task
                address:(unsigned long long)address
                  words:(NSUInteger)count
                  label:(NSString *)label;
- (BOOL)readGuest64:(mach_port_t)task
            address:(unsigned long long)address
              value:(unsigned long long *)value;
- (void)logCacheStateAtRoot:(NSString *)rootPath;

@end

@implementation GuestLauncher {
    unsigned long long _guestTlsPointer;
    pid_t _guestPid;
}

- (void)log:(NSString *)line
{
    /*
     * The runner prints the guest thread pointer once glibc installs it
     * ("tls write value=0x...").  Remember it so the crash dump below can
     * read the guest's TLS block through vm_read_overwrite.
     */
    NSRange valueRange = [line rangeOfString:@"value=0x"];
    if (valueRange.location != NSNotFound &&
        ([line hasPrefix:@"[guest] tls"])) {
        NSString *tail = [line substringFromIndex:NSMaxRange(valueRange)];
        NSRange space = [tail rangeOfString:@" "];
        if (space.location != NSNotFound) {
            tail = [tail substringToIndex:space.location];
        }
        unsigned long long parsed = 0;
        NSScanner *scanner = [NSScanner scannerWithString:tail];
        if ([scanner scanHexLongLong:&parsed] && parsed != 0) {
            _guestTlsPointer = parsed;
        }
    }

    void (^handler)(NSString *) = self.logHandler;
    if (handler != nil) {
        handler(line);
    }
}

/*
 * apk keeps its downloaded indexes under <rootfs>/var/cache/apk.  The
 * 0.38.5 device log showed a successful download followed by an "IO ERROR"
 * when the cached copy was read back, so dump enough of each file to tell a
 * truncated download (size/magic) from a valid one.  The SHA-256 answers the
 * remaining question -- did the network deliver exactly the CDN bytes --
 * because the indexes are static for weeks at a time.
 */
- (void)logCacheStateAtRoot:(NSString *)rootPath
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray<NSString *> *directories = @[ @"var/cache/apk", @"etc/apk/cache" ];
    for (NSString *relative in directories) {
        NSString *directory =
            [rootPath stringByAppendingPathComponent:relative];
        NSArray<NSString *> *entries =
            [manager contentsOfDirectoryAtPath:directory error:NULL];
        for (NSString *entry in [entries sortedArrayUsingSelector:
                                 @selector(compare:)]) {
            NSString *file = [directory stringByAppendingPathComponent:entry];
            NSDictionary *attributes =
                [manager attributesOfItemAtPath:file error:NULL];
            unsigned long long size =
                [attributes[NSFileSize] unsignedLongLongValue];
            NSData *data = [NSData dataWithContentsOfFile:file];
            NSMutableString *head = [NSMutableString string];
            NSMutableString *tail = [NSMutableString string];
            if (data.length >= 8) {
                const uint8_t *bytes = data.bytes;
                for (NSUInteger index = 0; index < 4; index++) {
                    [head appendFormat:@"%02x", bytes[index]];
                }
                for (NSUInteger index = data.length - 4;
                     index < data.length;
                     index++) {
                    [tail appendFormat:@"%02x", bytes[index]];
                }
            }
            NSMutableString *digest = [NSMutableString string];
            unsigned char hash[CC_SHA256_DIGEST_LENGTH];
            if (data.length != 0 &&
                CC_SHA256(data.bytes, (CC_LONG)data.length, hash) != NULL) {
                for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
                    [digest appendFormat:@"%02x", hash[index]];
                }
            }
            [self log:[NSString stringWithFormat:
                @"cache %@/%@ size=%llu head=%@ tail=%@ sha256=%@",
                relative, entry, size, head, tail, digest]];
        }
    }
}

/*
 * The cache file names are derived from the repository URL
 * (APKINDEX.<first 4 bytes of SHA-1(url) hex>.tar.gz), so the two Alpine
 * repositories always map to the names below.  Copying them into a
 * file:// repository lets us run "apk update" with the exact same bytes but
 * no network, which separates a stream/TLS problem from a parser problem.
 */
- (BOOL)prepareLocalIndexRepositoryAtRoot:(NSString *)rootPath
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *cache = [rootPath stringByAppendingPathComponent:@"var/cache/apk"];
    NSArray<NSArray<NSString *> *> *repositories = @[
        @[ @"ee34dc71", @"main" ],
        @[ @"7db31bb6", @"community" ],
    ];

    BOOL ready = YES;
    NSMutableString *list = [NSMutableString string];
    for (NSArray<NSString *> *repository in repositories) {
        NSString *name = [NSString stringWithFormat:
            @"APKINDEX.%@.tar.gz", repository[0]];
        NSString *tag = repository[1];
        NSString *source = [cache stringByAppendingPathComponent:name];
        /*
         * 0.40.23: the cache is device state, and device state disappears --
         * a reinstall, an apk cache clean or a wiped rootfs leaves the local
         * repository with nothing to copy from, which used to strand the
         * whole offline test path (and push the run onto the network).
         * The two indexes are small and fixed for a release, so they ship in
         * the bundle as the fallback source.
         */
        if (![manager fileExistsAtPath:source]) {
            NSString *bundled = [[[NSBundle mainBundle] bundlePath]
                stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"Helpers/localrepo/%@", name]];
            if ([manager fileExistsAtPath:bundled]) {
                source = bundled;
            }
        }
        BOOL fromBundle = ![source hasPrefix:cache];
        NSString *directory = [[rootPath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"var/localrepo/%@/aarch64", tag]]
            copy];
        NSString *target = [directory stringByAppendingPathComponent:
            @"APKINDEX.tar.gz"];
        [manager createDirectoryAtPath:directory
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:NULL];
        [manager removeItemAtPath:target error:NULL];
        BOOL copied = [manager copyItemAtPath:source
                                       toPath:target
                                        error:NULL];
        NSDictionary *attributes =
            [manager attributesOfItemAtPath:target error:NULL];
        [self log:[NSString stringWithFormat:
            @"localrepo %@ %@ size=%@ from=%@", tag,
            copied ? @"ready" : @"missing source",
            attributes[NSFileSize] ?: @0,
            fromBundle ? @"bundle" : @"cache"]];
        if (!copied) {
            ready = NO;
        }
        [list appendFormat:@"file:///var/localrepo/%@\n", tag];
    }

    NSString *listPath = [rootPath stringByAppendingPathComponent:
        @"var/localrepo/repositories"];
    [list writeToFile:listPath
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:NULL];
    return ready;
}

- (BOOL)runBundledGuest
{
    return [self runGuestNamed:@"guest-hello.elf" arguments:@[]];
}

- (BOOL)runGuestNamed:(NSString *)relativePath
            arguments:(NSArray<NSString *> *)arguments
{
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *runner = [bundle stringByAppendingPathComponent:
        @"Helpers/guest-runner"];
    /*
     * Most actions pass a bundle-relative path.  "Run Installed Hello" passes
     * an absolute host path inside the guest rootfs instead.
     */
    NSString *guest = [relativePath isAbsolutePath]
        ? relativePath
        : [bundle stringByAppendingPathComponent:relativePath];

    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager isExecutableFileAtPath:runner]) {
        [self log:[NSString stringWithFormat:@"guest runner missing: %@",
                   runner]];
        return NO;
    }
    if (![manager fileExistsAtPath:guest]) {
        [self log:[NSString stringWithFormat:@"guest ELF missing: %@", guest]];
        return NO;
    }

    int fds[2] = { -1, -1 };
    if (pipe(fds) != 0) {
        [self log:@"guest pipe failed"];
        return NO;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    NSMutableArray<NSString *> *all = [NSMutableArray arrayWithObject:runner];
    [all addObject:guest];
    [all addObjectsFromArray:arguments];

    char **argv = calloc(all.count + 1, sizeof(char *));
    if (argv == NULL) {
        posix_spawn_file_actions_destroy(&actions);
        close(fds[0]);
        close(fds[1]);
        [self log:@"guest argv allocation failed"];
        return NO;
    }
    for (NSUInteger index = 0; index < all.count; index++) {
        argv[index] = (char *)all[index].fileSystemRepresentation;
    }
    argv[all.count] = NULL;

    /*
     * The helper runs unsandboxed, so it cannot derive the app container on
     * its own (NSHomeDirectory resolves to /var/mobile).  Pass the writable
     * guest root explicitly; it is the app's Documents/rootfs.  TrollStore
     * apps are unsandboxed too, so derive the container from TMPDIR, which
     * still points at <container>/tmp.
     */
    NSString *temporary = NSTemporaryDirectory();
    NSString *documents = nil;
    if ([temporary containsString:@"/Containers/Data/Application/"]) {
        documents = [[temporary stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"Documents"];
    }
    if (documents.length == 0) {
        documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    }
    NSString *rootPath = [documents stringByAppendingPathComponent:@"rootfs"];
    [manager createDirectoryAtPath:rootPath
       withIntermediateDirectories:YES
                        attributes:nil
                             error:NULL];

    size_t environmentCount = 0;
    while (environ[environmentCount] != NULL) {
        environmentCount++;
    }
    char **environment = calloc(environmentCount + 4, sizeof(char *));
    if (environment == NULL) {
        free(argv);
        posix_spawn_file_actions_destroy(&actions);
        close(fds[0]);
        close(fds[1]);
        [self log:@"guest environment allocation failed"];
        return NO;
    }
    for (size_t index = 0; index < environmentCount; index++) {
        environment[index] = environ[index];
    }
    NSString *rootVariable = [NSString stringWithFormat:
        @"LINUXPROBE_ROOT=%@", rootPath];
    /*
     * OpenSSL looks for OPENSSLDIR/cert.pem by default.  Point it at the
     * Alpine CA bundle explicitly so apk's HTTPS fetches verify even if the
     * bundle layout changes.
     *
     * These must be GUEST paths.  The guest opens them through the syscall
     * layer, which prepends LINUXPROBE_ROOT; passing a host path here made
     * the guest look for <rootfs>/var/mobile/... and left OpenSSL with an
     * empty trust store ("certificate verify failed").
     */
    NSString *certificateFile = @"SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt";
    NSString *certificateDirectory = @"SSL_CERT_DIR=/etc/ssl/certs";
    environment[environmentCount] = (char *)rootVariable.fileSystemRepresentation;
    environment[environmentCount + 1] =
        (char *)certificateFile.fileSystemRepresentation;
    environment[environmentCount + 2] =
        (char *)certificateDirectory.fileSystemRepresentation;
    environment[environmentCount + 3] = NULL;

    pid_t pid = 0;
    int result = posix_spawn(&pid,
                             runner.fileSystemRepresentation,
                             &actions,
                             NULL,
                             argv,
                             environment);
    free(environment);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);

    if (result != 0) {
        close(fds[0]);
        [self log:[NSString stringWithFormat:@"guest spawn failed: %d (%s)",
                   result, strerror(result)]];
        return NO;
    }

    _guestPid = pid;

    [self log:[NSString stringWithFormat:@"guest runner pid=%d", pid]];

    int readFD = fds[0];
    dispatch_queue_t queue =
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    dispatch_async(queue, ^{
        NSMutableData *buffer = [NSMutableData data];
        uint8_t chunk[4096];

        for (;;) {
            ssize_t count = read(readFD, chunk, sizeof(chunk));
            if (count > 0) {
                [buffer appendBytes:chunk length:(NSUInteger)count];
                [self drain:buffer];
                continue;
            }
            if (count < 0 && errno == EINTR) {
                continue;
            }
            break;
        }
        close(readFD);
    });

    /*
     * guest-runner 用 PT_TRACE_ME 换 CS_DEBUGGED，所以它处于被调试状态：
     * 任何致命信号都会让整个任务停住等调试器，它自己的 signal handler 和
     * watchdog 都不会跑。这里必须由父进程（本 App）以 WUNTRACED 收停止
     * 事件，再从宿主侧读取线程现场，然后杀掉它。
     */
    dispatch_async(queue, ^{
        int status = 0;
        for (;;) {
            pid_t waited = waitpid(pid, &status, WUNTRACED);
            if (waited < 0) {
                if (errno == EINTR) {
                    continue;
                }
                if (errno == ECHILD) {
                    /*
                     * guest-runner detached itself after patching so its own
                     * signal handler could report faults; we are no longer
                     * its tracer and cannot wait for it.
                     */
                    [self log:@"guest detached: see in-process logs"];
                    void (^completion)(int) = self.completionHandler;
                    if (completion != nil) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completion(0);
                        });
                    }
                    return;
                }
                [self log:[NSString stringWithFormat:@"guest waitpid failed: %s",
                           strerror(errno)]];
                status = 0;
                break;
            }

            if (WIFSTOPPED(status)) {
                int stopSignal = WSTOPSIG(status);
                [self log:[NSString stringWithFormat:@"guest stopped: signal=%d",
                           stopSignal]];
                if (stopSignal == SIGSTOP) {
                    /*
                     * guest-runner stops itself exactly once, right after
                     * patching the image, so that we -- its tracer -- can
                     * detach it (XNU only allows detaching a stopped
                     * tracee).  Do not wait for the "ready for detach" log
                     * line: the pipe reader runs on another queue and the
                     * stop can be reaped first, which used to leave the
                     * runner stopped forever.  Any SIGSTOP here is the
                     * handshake, so just detach unconditionally.
                     */
                    errno = 0;
                    int detachResult = ptrace(GUEST_PT_DETACH,
                                              pid,
                                              NULL,
                                              SIGCONT);
                    int detachErrno = errno;
                    [self log:[NSString stringWithFormat:
                        @"parent ptrace(PT_DETACH) rc=%d errno=%d",
                        detachResult, detachErrno]];
                    /*
                     * Delivering the stop and resuming are racy; keep
                     * nudging with SIGCONT when the detach itself failed
                     * (not traced any more) or as a belt and braces.
                     */
                    dispatch_async(
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            for (int attempt = 0; attempt < 4; attempt++) {
                                kill(pid, SIGCONT);
                                usleep(50 * 1000);
                            }
                        });
                    continue;
                }
                [self dumpThreadsOfGuest:pid];
                kill(pid, SIGKILL);
                continue;
            }

            if (WIFCONTINUED(status)) {
                [self log:@"guest continued"];
                continue;
            }
            break;
        }

        if (WIFEXITED(status)) {
            [self logCacheStateAtRoot:rootPath];
            [self log:[NSString stringWithFormat:@"guest exited: status=%d",
                       WEXITSTATUS(status)]];
        } else if (WIFSIGNALED(status)) {
            [self log:[NSString stringWithFormat:@"guest signalled: signal=%d",
                       WTERMSIG(status)]];
        } else {
            [self log:@"guest exited: unknown status"];
        }

        void (^completion)(int) = self.completionHandler;
        if (completion != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(status);
            });
        }
    });

    return YES;
}

- (void)dumpGuestMemory:(mach_port_t)task
                address:(unsigned long long)address
                  words:(NSUInteger)count
                  label:(NSString *)label
{
    if (address == 0 || count == 0 || count > 8) {
        return;
    }
    uint64_t buffer[8] = { 0 };
    vm_size_t size = 0;
    kern_return_t result = vm_read_overwrite(task,
                                             (vm_address_t)address,
                                             (vm_size_t)(count * sizeof(uint64_t)),
                                             (vm_address_t)buffer,
                                             &size);
    NSMutableString *text = [NSMutableString stringWithFormat:
        @"guest mem %@ 0x%llx:", label, address];
    if (result != KERN_SUCCESS) {
        [text appendFormat:@" read=%d", result];
    } else {
        for (NSUInteger index = 0; index < count; index++) {
            [text appendFormat:@" %016llx",
                (unsigned long long)buffer[index]];
        }
    }
    [self log:text];
}

- (BOOL)readGuest64:(mach_port_t)task
            address:(unsigned long long)address
              value:(unsigned long long *)value
{
    uint64_t buffer = 0;
    vm_size_t size = 0;
    kern_return_t result = vm_read_overwrite(task,
                                             (vm_address_t)address,
                                             sizeof(buffer),
                                             (vm_address_t)&buffer,
                                             &size);
    if (result != KERN_SUCCESS) {
        return NO;
    }
    if (value != NULL) {
        *value = buffer;
    }
    return YES;
}

- (void)dumpThreadsOfGuest:(pid_t)pid
{
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t result = task_for_pid(mach_task_self(), pid, &task);
    if (result != KERN_SUCCESS) {
        [self log:[NSString stringWithFormat:@"guest task_for_pid=%d", result]];
        return;
    }

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    result = task_threads(task, &threads, &count);
    if (result != KERN_SUCCESS) {
        [self log:[NSString stringWithFormat:@"guest task_threads=%d", result]];
        mach_port_deallocate(mach_task_self(), task);
        return;
    }

    for (mach_msg_type_number_t index = 0; index < count; index++) {
        arm_thread_state64_t state;
        mach_msg_type_number_t stateCount = ARM_THREAD_STATE64_COUNT;
        kern_return_t stateResult = thread_get_state(threads[index],
                                                     ARM_THREAD_STATE64,
                                                     (thread_state_t)&state,
                                                     &stateCount);
        if (stateResult == KERN_SUCCESS) {
            arm_exception_state64_t exceptionState;
            mach_msg_type_number_t exceptionCount = ARM_EXCEPTION_STATE64_COUNT;
            kern_return_t exceptionResult =
                thread_get_state(threads[index],
                                 ARM_EXCEPTION_STATE64,
                                 (thread_state_t)&exceptionState,
                                 &exceptionCount);
            [self log:[NSString stringWithFormat:
                @"guest thread %u pc=0x%llx lr=0x%llx sp=0x%llx fp=0x%llx "
                @"x0=0x%llx x1=0x%llx x2=0x%llx x3=0x%llx x4=0x%llx "
                @"x5=0x%llx x6=0x%llx x7=0x%llx x8=0x%llx x9=0x%llx "
                @"far=0x%llx esr=0x%x state=%d",
                (unsigned)index,
                (unsigned long long)state.__pc,
                (unsigned long long)state.__lr,
                (unsigned long long)state.__sp,
                (unsigned long long)state.__fp,
                (unsigned long long)state.__x[0],
                (unsigned long long)state.__x[1],
                (unsigned long long)state.__x[2],
                (unsigned long long)state.__x[3],
                (unsigned long long)state.__x[4],
                (unsigned long long)state.__x[5],
                (unsigned long long)state.__x[6],
                (unsigned long long)state.__x[7],
                (unsigned long long)state.__x[8],
                (unsigned long long)state.__x[9],
                exceptionResult == KERN_SUCCESS
                    ? (unsigned long long)exceptionState.__far
                    : 0ULL,
                exceptionResult == KERN_SUCCESS
                    ? (unsigned)exceptionState.__esr
                    : 0U,
                exceptionResult]];

            if (state.__pc >= 16) {
                uint8_t code[32];
                vm_size_t codeSize = 0;
                kern_return_t codeResult =
                    vm_read_overwrite(task,
                                      (vm_address_t)(state.__pc - 16),
                                      (vm_size_t)sizeof(code),
                                      (vm_address_t)code,
                                      &codeSize);
                if (codeResult == KERN_SUCCESS && codeSize == sizeof(code)) {
                    const uint32_t *words = (const uint32_t *)code;
                    [self log:[NSString stringWithFormat:
                        @"guest thread %u code: %08x %08x %08x %08x "
                        @"%08x %08x %08x %08x (fault word is 5th)",
                        (unsigned)index,
                        words[0], words[1], words[2], words[3],
                        words[4], words[5], words[6], words[7]]];
                }
            }

            if (index == 0 && _guestTlsPointer != 0) {
                [self dumpGuestMemory:task
                              address:_guestTlsPointer
                                words:8
                                label:@"tp"];
                unsigned long long slot = 0;
                if ([self readGuest64:task
                              address:_guestTlsPointer + 0x10
                                value:&slot]) {
                    [self log:[NSString stringWithFormat:
                        @"guest tls slot=0x%llx", slot]];
                    [self dumpGuestMemory:task
                                  address:slot
                                    words:4
                                    label:@"slot"];
                } else {
                    [self log:@"guest tls slot unreadable"];
                }
                unsigned long long slot2 = 0;
                if ([self readGuest64:task
                              address:_guestTlsPointer + 0x18
                                value:&slot2]) {
                    [self log:[NSString stringWithFormat:
                        @"guest tls slot2=0x%llx", slot2]];
                    [self dumpGuestMemory:task
                                  address:slot2
                                    words:4
                                    label:@"slot2"];
                } else {
                    [self log:@"guest tls slot2 unreadable"];
                }
                [self dumpGuestMemory:task
                              address:state.__x[0]
                                words:4
                                label:@"x0"];
            }
        } else {
            [self log:[NSString stringWithFormat:@"guest thread %u state=%d",
                       (unsigned)index, stateResult]];
        }
        mach_port_deallocate(mach_task_self(), threads[index]);
    }

    vm_deallocate(mach_task_self(),
                  (vm_address_t)threads,
                  count * sizeof(thread_act_t));
    mach_port_deallocate(mach_task_self(), task);
}

- (void)drain:(NSMutableData *)buffer
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

        NSData *line = [buffer subdataWithRange:NSMakeRange(0, range.location)];
        [buffer replaceBytesInRange:NSMakeRange(0, range.location + 1)
                          withBytes:NULL
                             length:0];
        NSString *text = [[NSString alloc] initWithData:line
                                               encoding:NSUTF8StringEncoding];
        if (text.length > 0) {
            [self log:text];
        }
    }
}

@end
