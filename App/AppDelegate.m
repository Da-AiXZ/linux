#import "AppDelegate.h"
#import "ProbeViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:[ProbeViewController new]];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options
{
    if ([url.scheme isEqualToString:@"linuxprobe"]) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ProbeURLNotification"
                          object:nil
                        userInfo:@{ @"url": url }];
        return YES;
    }
    return NO;
}

@end
