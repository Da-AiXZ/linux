#import <Foundation/Foundation.h>

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <stdio.h>
#import <unistd.h>
#import <xpc/xpc.h>

#import "ProbeExtension.h"
#import "ProbeMach.h"

/*
 * Private libxpc / liblaunch entry points. The extension process is
 * launched by PlugInKit but the host is not a real NSXPC extension host,
 * so the system NSExtensionMain would wait forever for a hub handshake
 * that never arrives. LiveContainer and Nyxian use the same approach:
 * replace the entry point, learn the host PID from the launch properties
 * and talk to a bootstrap service the host registered itself.
 */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bootstrap,
                                       const char *name,
                                       mach_port_t *port);

typedef xpc_object_t (*ProbeCopyPropertiesFn)(pid_t pid);

static void ProbePostNotification(CFStringRef name)
{
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        name,
        NULL,
        NULL,
        true);
}

__attribute__((constructor))
static void ProbeEntryLoaded(void)
{
    ProbePostNotification(CFSTR("com.daixz.linux.probe.ext-alive"));
}

int NSExtensionMain(int argc, char *argv[], char *envp[], char *apple[])
{
    @autoreleasepool {
        pid_t hostPid = 0;
        ProbeCopyPropertiesFn copyProperties =
            (ProbeCopyPropertiesFn)dlsym(RTLD_DEFAULT,
                                         "launch_copy_extension_properties_for_pid");
        xpc_object_t properties = copyProperties != NULL
            ? copyProperties(getpid())
            : NULL;
        if (properties != NULL && xpc_get_type(properties) == XPC_TYPE_DICTIONARY) {
            hostPid = (pid_t)xpc_dictionary_get_int64(properties,
                                                      "XPCExtensionHostPID");
        }
        NSLog(@"ProbeExtension: launch host pid=%d", hostPid);
        ProbePostNotification(CFSTR("com.daixz.linux.probe.ext-props"));

        char service[160] = { 0 };
        mach_port_t port = MACH_PORT_NULL;
        if (hostPid > 0) {
            ProbeMachServiceName(service, sizeof(service), hostPid);
            for (int attempt = 0; attempt < 5; attempt++) {
                kern_return_t kr = bootstrap_look_up(bootstrap_port,
                                                     service,
                                                     &port);
                if (kr == KERN_SUCCESS && MACH_PORT_VALID(port)) {
                    break;
                }
                usleep(100 * 1000);
            }
            NSLog(@"ProbeExtension: look_up %s -> %s",
                  service,
                  MACH_PORT_VALID(port) ? "ok" : "failed");
        }

        if (MACH_PORT_VALID(port)) {
            ProbePostNotification(CFSTR("com.daixz.linux.probe.ext-mach"));
            int result = ProbeExtensionRun(hostPid, port);
            mach_port_deallocate(mach_task_self(), port);
            return result;
        }

        ProbePostNotification(CFSTR("com.daixz.linux.probe.ext-nomatch"));

        int (*systemMain)(int, char **) =
            (int (*)(int, char **))dlsym(RTLD_NEXT, "NSExtensionMain");
        if (systemMain != NULL) {
            return systemMain(argc, argv);
        }
        return 1;
    }
}
