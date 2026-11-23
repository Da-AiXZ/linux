#import <Foundation/Foundation.h>

@interface GuestLauncher : NSObject

@property (nonatomic, copy) void (^logHandler)(NSString *line);
@property (nonatomic, copy) void (^completionHandler)(int status);

/*
 * Experiment knobs, passed to guest-runner as environment variables.
 *
 * zlibVariant: "stock" or "zspy".  guest-runner copies
 *              <rootfs>/lib/libz.so.1.<variant> over libz.so.1 before the
 *              guest starts, so one install can test both libraries.
 * watchState:  arms an ARM64 hardware watchpoint on inflate_state.check and
 *              prints the faulting pc.  Requires the instrumented zlib,
 *              because only that build prints the state address.
 */
@property (nonatomic, copy) NSString *zlibVariant;
@property (nonatomic, assign) BOOL watchState;

- (BOOL)runBundledGuest;
- (BOOL)runGuestNamed:(NSString *)relativePath
            arguments:(NSArray<NSString *> *)arguments;

/*
 * Build an offline apk repository from the cached APKINDEX files so the
 * index parser can be exercised without any network in the loop.
 */
- (BOOL)prepareLocalIndexRepositoryAtRoot:(NSString *)rootPath;

@end
