#import "V2Runner.h"

#import <signal.h>
#import <errno.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

/*
 * The iOS SDK has no <sys/ptrace.h>.  Request 11 is PT_DETACH.
 *
 * The helper calls ptrace(PT_TRACE_ME) as its first instruction, which makes
 * us its tracer and stops it before it runs anything.  Detaching is the whole
 * trick: the process keeps CS_DEBUGGED afterwards, which is what allows
 * mprotect(PROT_EXEC) on anonymous pages.
 */
extern int ptrace(int request, int pid, void *address, int data);
#define V2_PT_DETACH 11

@implementation V2Runner

+ (int)runGuest:(NSString *)elfPath
           root:(NSString *)root
        timeout:(NSTimeInterval)timeout
         output:(NSMutableString *)output
{
    return [self runGuest:elfPath root:root args:@[] timeout:timeout output:output];
}

+ (int)runGuest:(NSString *)elfPath
           root:(NSString *)root
           args:(NSArray<NSString *> *)args
        timeout:(NSTimeInterval)timeout
         output:(NSMutableString *)output
{
    NSString *helper = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@"Helpers/guest-runner"];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:helper]) {
        [output appendFormat:@"helper missing: %@\n", helper];
        return -1;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        [output appendString:@"pipe() failed\n"];
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);

    char *argv[24];
    int argument_count = 0;

    argv[argument_count++] = (char *)helper.UTF8String;
    argv[argument_count++] = (char *)"--root";
    argv[argument_count++] = (char *)root.UTF8String;
    argv[argument_count++] = (char *)elfPath.UTF8String;
    for (NSString *argument in args) {
        if (argument_count >= (int)(sizeof(argv) / sizeof(argv[0])) - 1) {
            break;
        }
        argv[argument_count++] = (char *)argument.UTF8String;
    }
    argv[argument_count] = NULL;
    pid_t child = 0;
    int status = posix_spawn(&child, helper.UTF8String, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (status != 0) {
        close(fds[0]);
        [output appendFormat:@"posix_spawn failed: %d\n", status];
        return -1;
    }

    for (int attempt = 0; attempt < 300; attempt++) {
        int state = 0;
        pid_t result = waitpid(child, &state, WUNTRACED | WNOHANG);

        if (result == child) {
            if (WIFSTOPPED(state)) {
                if (ptrace(V2_PT_DETACH, child, NULL, 0) != 0) {
                    [output appendFormat:@"[app] PT_DETACH failed: %d\n", errno];
                }
                kill(child, SIGCONT);
                for (int extra = 0; extra < 3; extra++) {
                    usleep(10 * 1000);
                    kill(child, SIGCONT);
                }
                [output appendString:@"[app] detached (CS_DEBUGGED)\n"];
            }
            break;
        }
        if (result < 0) {
            break;
        }
        usleep(10 * 1000);
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    char buffer[4096];
    while ([deadline timeIntervalSinceNow] > 0) {
        ssize_t got = read(fds[0], buffer, sizeof(buffer) - 1);
        if (got > 0) {
            buffer[got] = '\0';
            [output appendFormat:@"%s", buffer];
            continue;
        }
        break;
    }
    close(fds[0]);

    int termination = 0;
    for (int tries = 0; tries < 50; tries++) {
        pid_t result = waitpid(child, &termination, WNOHANG);
        if (result == child || result < 0) {
            break;
        }
        usleep(100 * 1000);
    }
    if (WIFEXITED(termination)) {
        [output appendFormat:@"\n[app] guest exited status=%d\n", WEXITSTATUS(termination)];
        return WEXITSTATUS(termination);
    }
    if (WIFSIGNALED(termination)) {
        [output appendFormat:@"\n[app] guest killed by signal %d\n", WTERMSIG(termination)];
        return -WTERMSIG(termination);
    }
    [output appendString:@"\n[app] guest still running at timeout\n"];
    kill(child, SIGKILL);
    return -2;
}

@end
