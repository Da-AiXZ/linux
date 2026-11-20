#import <Foundation/Foundation.h>

#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <stdio.h>
#import <string.h>
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
typedef xpc_object_t (*ProbeCopyEntitlementFn)(const char *entitlement);

static mach_port_t ProbeLookUpBroker(void)
{
    mach_port_t port = MACH_PORT_NULL;

    ProbeCopyEntitlementFn copyEntitlement =
        (ProbeCopyEntitlementFn)dlsym(RTLD_DEFAULT,
                                      "xpc_copy_entitlement_for_self");
    xpc_object_t groups = copyEntitlement != NULL
        ? copyEntitlement("com.apple.security.application-groups")
        : NULL;

    if (groups != NULL && xpc_get_type(groups) == XPC_TYPE_ARRAY) {
        size_t count = xpc_array_get_count(groups);
        for (size_t index = 0; index < count; index++) {
            const char *group = xpc_array_get_string(groups, index);
            if (group == NULL || group[0] == '\0') {
                continue;
            }

            char name[192] = { 0 };
            ProbeMachServiceNameForGroup(name, sizeof(name), group);
            kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &port);
            NSLog(@"ProbeExtension: look_up %s -> %d", name, kr);
            if (kr == KERN_SUCCESS && MACH_PORT_VALID(port)) {
                return port;
            }
            port = MACH_PORT_NULL;
        }
    }

    kern_return_t kr = bootstrap_look_up(bootstrap_port,
                                         PROBE_MACH_SERVICE,
                                         &port);
    NSLog(@"ProbeExtension: look_up %s -> %d", PROBE_MACH_SERVICE, kr);
    return (kr == KERN_SUCCESS && MACH_PORT_VALID(port)) ? port : MACH_PORT_NULL;
}

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
    if (argc > 1 && strcmp(argv[1], "--nested") == 0) {
        return 0;
    }

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

        mach_port_t port = ProbeLookUpBroker();

        if (MACH_PORT_VALID(port)) {
            ProbePostNotification(CFSTR("com.daixz.linux.probe.ext-mach"));
            int result = ProbeExtensionRun(hostPid, port);
            mach_port_deallocate(mach_task_self(), port);
            return result;
        }

        ProbePostNotification(CFSTR("com.daixz.linux.probe.ext-nomatch"));

        /*
         * The host cannot register a Mach service (BOOTSTRAP_NOT_PRIVILEGED),
         * so run the privilege-free channel probe instead.
         */
        return ProbeExtensionChannelRun(hostPid);
    }
}
