#import "V2Runner.h"

#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

@implementation V2Runner

+ (int)runGuest:(NSString *)elfPath
           root:(NSString *)root
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

    char *argv[] = {
        (char *)helper.UTF8String,
        (char *)"--root", (char *)root.UTF8String,
        (char *)elfPath.UTF8String,
        NULL,
    };
    pid_t child = 0;
    int status = posix_spawn(&child, helper.UTF8String, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (status != 0) {
        close(fds[0]);
        [output appendFormat:@"posix_spawn failed: %d\n", status];
        return -1;
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
