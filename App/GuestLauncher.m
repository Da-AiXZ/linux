#import "GuestLauncher.h"

#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

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
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *runner = [bundle stringByAppendingPathComponent:
        @"Helpers/guest-runner"];
    NSString *guest = [bundle stringByAppendingPathComponent:
        @"guest-hello.elf"];

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

    char *argv[] = {
        (char *)runner.fileSystemRepresentation,
        (char *)guest.fileSystemRepresentation,
        NULL,
    };

    pid_t pid = 0;
    int result = posix_spawn(&pid,
                             runner.fileSystemRepresentation,
                             &actions,
                             NULL,
                             argv,
                             environ);
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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

        int status = 0;
        waitpid(pid, &status, 0);
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
