#import "ProbeMachPort.h"

#import <xpc/xpc.h>

/*
 * These two libxpc entry points are SPI and are not declared by the public
 * SDK headers. They are the transport used by the system XPC layer itself.
 */
extern void xpc_dictionary_set_mach_send(xpc_object_t dictionary,
                                         const char *key,
                                         mach_port_t port);
extern mach_port_t xpc_dictionary_copy_mach_send(xpc_object_t dictionary,
                                                 const char *key);

/*
 * NSCoder's XPC bridge is the only supported way to move a real Mach send
 * right through an NSExtensionItem. It is private SPI, but it is exactly what
 * the system XPC layer uses internally and it is what Nyxian-style runtimes
 * rely on.
 */
@interface NSCoder (ProbeXPC)
- (void)encodeXPCObject:(xpc_object_t)object forKey:(NSString *)key;
- (xpc_object_t)decodeXPCObjectOfType:(xpc_type_t)type forKey:(NSString *)key;
@end

@implementation ProbeMachPort

+ (BOOL)supportsSecureCoding
{
    return YES;
}

+ (instancetype)portWithPortName:(mach_port_name_t)port
                        sendOnce:(BOOL)sendOnce
{
    ProbeMachPort *wrapper = [[self alloc] initWithPortName:port];
    wrapper.sendOnce = sendOnce;
    return wrapper;
}

- (instancetype)initWithPortName:(mach_port_name_t)port
{
    if (port == MACH_PORT_NULL) {
        return nil;
    }

    self = [super init];
    if (self == nil) {
        return nil;
    }

    kern_return_t kr = mach_port_mod_refs(mach_task_self(),
                                          port,
                                          MACH_PORT_RIGHT_SEND,
                                          1);
    if (kr != KERN_SUCCESS) {
        return nil;
    }

    _port = port;
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
    if (dictionary == NULL) {
        return;
    }

    mach_port_t port = _port;
    if (_sendOnce) {
        mach_port_t extracted = MACH_PORT_NULL;
        mach_msg_type_name_t type = 0;
        kern_return_t kr = mach_port_extract_right(mach_task_self(),
                                                   _port,
                                                   MACH_MSG_TYPE_MAKE_SEND_ONCE,
                                                   &extracted,
                                                   &type);
        if (kr != KERN_SUCCESS) {
            return;
        }
        port = extracted;
    } else {
        kern_return_t kr = mach_port_mod_refs(mach_task_self(),
                                              _port,
                                              MACH_PORT_RIGHT_SEND,
                                              1);
        if (kr != KERN_SUCCESS) {
            return;
        }
    }

    xpc_dictionary_set_mach_send(dictionary, "port", port);
    [(id)coder encodeXPCObject:dictionary forKey:@"port"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    xpc_object_t dictionary = [(id)coder decodeXPCObjectOfType:XPC_TYPE_DICTIONARY
                                                        forKey:@"port"];
    if (dictionary == NULL) {
        return nil;
    }

    mach_port_t port = xpc_dictionary_copy_mach_send(dictionary, "port");
    if (port == MACH_PORT_NULL) {
        return nil;
    }

    self = [super init];
    if (self == nil) {
        mach_port_deallocate(mach_task_self(), port);
        return nil;
    }

    _port = port;
    return self;
}

- (void)dealloc
{
    if (_port != MACH_PORT_NULL) {
        mach_port_deallocate(mach_task_self(), _port);
        _port = MACH_PORT_NULL;
    }
}

@end
