#import "GuestLauncher.h"

#import <mach/arm/thread_status.h>
#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach/thread_status.h>
#import <mach/vm_map.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

@interface GuestLauncher ()

- (void)dumpThreadsOfGuest:(pid_t)pid;

@end

@implementation GuestLauncher

- (void)log:(NSString *)line
{
    void (^handler)(NSString *) = self.logHandler;
    if (handler != nil) {
        handler(line);
    }
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
    NSString *guest = [bundle stringByAppendingPathComponent:relativePath];

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

    pid_t pid = 0;
    int result = posix_spawn(&pid,
                             runner.fileSystemRepresentation,
                             &actions,
                             NULL,
                             argv,
                             environ);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);

    if (result != 0) {
        close(fds[0]);
        [self log:[NSString stringWithFormat:@"guest spawn failed: %d (%s)",
                   result, strerror(result)]];
        return NO;
    }

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
                [self log:[NSString stringWithFormat:@"guest waitpid failed: %s",
                           strerror(errno)]];
                status = 0;
                break;
            }

            if (WIFSTOPPED(status)) {
                [self log:[NSString stringWithFormat:@"guest stopped: signal=%d",
                           WSTOPSIG(status)]];
                [self dumpThreadsOfGuest:pid];
                kill(pid, SIGKILL);
                continue;
            }
            break;
        }

        if (WIFEXITED(status)) {
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
            [self log:[NSString stringWithFormat:
                @"guest thread %u pc=0x%llx lr=0x%llx sp=0x%llx fp=0x%llx "
                @"x0=0x%llx x8=0x%llx",
                (unsigned)index,
                (unsigned long long)state.__pc,
                (unsigned long long)state.__lr,
                (unsigned long long)state.__sp,
                (unsigned long long)state.__fp,
                (unsigned long long)state.__x[0],
                (unsigned long long)state.__x[8]]];
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
