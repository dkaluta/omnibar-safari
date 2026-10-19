#import "SceneDelegate.h"
#import "SettingsViewController.h"
#import "OmnibarMobileSettings.h"

@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:UIWindowScene.class]) return;

    NSError *error = nil;
    SettingsViewController *settings = [[SettingsViewController alloc] initWithSettings:OmnibarMobileSearchSettings(&error)];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:settings];
    [self.window makeKeyAndVisible];
    // A settings link may launch a new scene instead of reaching openURLContexts:.
    [self handleURLContexts:connectionOptions.URLContexts];
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [self handleURLContexts:URLContexts];
}
- (void)handleURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        if (OmnibarMobileAcceptsSettingsURL(context.URL, NSBundle.mainBundle.bundleIdentifier)) {
            [(UINavigationController *)self.window.rootViewController popToRootViewControllerAnimated:YES];
            break;
        }
    }
}
- (void)sceneWillResignActive:(UIScene *)scene {
    UINavigationController *navigation = (id)self.window.rootViewController;
    [(SettingsViewController *)navigation.viewControllers.firstObject clearSensitiveInput];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    UINavigationController *navigation = (id)self.window.rootViewController;
    [(SettingsViewController *)navigation.viewControllers.firstObject refreshSettings];
}
@end
