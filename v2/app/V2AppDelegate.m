#import "V2AppDelegate.h"

#import "V2ViewController.h"

@implementation V2AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *navigation =
        [[UINavigationController alloc] initWithRootViewController:
            [[V2ViewController alloc] init]];
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
