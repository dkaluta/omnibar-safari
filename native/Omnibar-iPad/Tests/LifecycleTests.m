#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "SettingsViewController.h"
#import "OmnibarMobileSettings.h"

static NSUInteger checks, factoryCalls, settingsRoutes;
static BOOL finished;
static NSArray *(*originalPopToRoot)(id, SEL, BOOL);
static dispatch_block_t settingsDidAppear;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        fflush(stderr);
        exit(1);
    }
}

// The scene still uses the real route validator. Only settings construction and
// its view controller are replaced, keeping this app away from personal storage.
OmnibarSearchSettings *OMLifecycleTestSettings(NSError **error) {
    factoryCalls++;
    if (error) *error = nil;
    return nil;
}

@interface SettingsViewController ()
@property NSUInteger refreshes;
@property NSUInteger clears;
@property (copy) NSString *testInput;
@property BOOL appeared;
@end
@implementation SettingsViewController
- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)clearSensitiveInput { self.clears++; self.testInput = nil; }
- (void)refreshSettings { self.refreshes++; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.appeared = YES;
    if (settingsDidAppear) settingsDidAppear();
}
@end

@interface OMTestURLContext : NSObject
@property (strong) NSURL *URL;
@end
@implementation OMTestURLContext
@end
@interface OMTestConnectionOptions : NSObject
@property (strong) NSSet *URLContexts;
@end
@implementation OMTestConnectionOptions
@end

static NSSet<UIOpenURLContext *> *Contexts(NSString *URL) {
    OMTestURLContext *context = [OMTestURLContext new];
    context.URL = [NSURL URLWithString:URL];
    return (id)[NSSet setWithObject:context];
}
static UISceneConnectionOptions *Options(NSString *URL) {
    OMTestConnectionOptions *options = [OMTestConnectionOptions new];
    options.URLContexts = URL ? Contexts(URL) : [NSSet set];
    return (id)options;
}
static NSArray *CountSettingsRoute(id navigation, SEL selector, BOOL animated) {
    settingsRoutes++;
    return originalPopToRoot(navigation, selector, animated);
}

@interface OMLifecycleSceneDelegate : SceneDelegate <UINavigationControllerDelegate>
@property BOOL scheduledTests;
@property (copy) void (^afterShow)(UIViewController *);
@end
@implementation OMLifecycleSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    Method method = class_getInstanceMethod(UINavigationController.class, @selector(popToRootViewControllerAnimated:));
    originalPopToRoot = (void *)method_setImplementation(method, (IMP)CountSettingsRoute);
    __weak OMLifecycleSceneDelegate *weakSelf = self;
    settingsDidAppear = ^{ [weakSelf scheduleChecks:scene]; };
    NSString *route = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@"://settings"];
    [super scene:scene willConnectToSession:session options:Options(route)];
    Check(self.window.windowScene == scene, @"startup window belongs to the connecting UIKit scene");
    Check(self.window.rootViewController != nil && !self.window.hidden, @"startup presents a root controller");
    Check(factoryCalls == 1, @"startup constructs settings once using isolated storage");
    Check(settingsRoutes == 1, @"cold-launch settings URL reaches navigation");
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    [super sceneDidBecomeActive:scene];
    [self scheduleChecks:scene];
}
- (void)scheduleChecks:(UIScene *)scene {
    if (self.scheduledTests) return;
    SettingsViewController *settings = (id)[(UINavigationController *)self.window.rootViewController viewControllers].firstObject;
    if (!settings.appeared || scene.activationState != UISceneActivationStateForegroundActive) return;
    self.scheduledTests = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ [self runChecks:scene]; });
}
- (void)navigationController:(UINavigationController *)navigation didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (self.afterShow) self.afterShow(viewController);
}
- (void)runChecks:(UIScene *)scene {
    UINavigationController *navigation = (id)self.window.rootViewController;
    Check([navigation isKindOfClass:UINavigationController.class], @"startup provides settings navigation");
    SettingsViewController *settings = (id)navigation.viewControllers.firstObject;
    Check([settings isKindOfClass:SettingsViewController.class], @"settings is the root controller");
    Check(settings.refreshes > 0, @"UIKit activation reaches settings refresh");
    NSUInteger refreshes = settings.refreshes;
    [self sceneDidBecomeActive:scene];
    Check(settings.refreshes == refreshes + 1, @"subsequent activation refreshes settings");

    // Wait for UIKit's navigation delegate, including nonanimated transitions,
    // before asking it to pop. An immediate push/pop can be ignored by UIKit.
    UIViewController *detail = [UIViewController new];
    navigation.delegate = self;
    __weak OMLifecycleSceneDelegate *weakSelf = self;
    self.afterShow = ^(UIViewController *shown) {
        if (shown != detail) return;
        weakSelf.afterShow = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf checkWarmRoute:scene]; });
    };
    [navigation pushViewController:detail animated:NO];
}
- (void)checkWarmRoute:(UIScene *)scene {
    UINavigationController *navigation = (id)self.window.rootViewController;
    SettingsViewController *settings = (id)navigation.viewControllers.firstObject;
    Check(navigation.viewControllers.count == 2, @"detail navigation has completed before lifecycle checks");
    settings.testInput = @"ISOLATED_TEST_INPUT";
    NSUInteger clears = settings.clears;
    [self sceneWillResignActive:scene];
    Check(settings.clears == clears + 1 && settings.testInput == nil, @"deactivation clears root settings input while another controller is visible");

    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *route = [identifier stringByAppendingString:@"://settings"];
    NSUInteger routes = settingsRoutes;
    __weak OMLifecycleSceneDelegate *weakSelf = self;
    self.afterShow = ^(UIViewController *shown) {
        if (shown != settings) return;
        weakSelf.afterShow = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishChecks:scene]; });
    };
    [self scene:scene openURLContexts:Contexts(route)];
    Check(settingsRoutes == routes + 1, @"warm settings URL invokes navigation to the settings root");
}
- (void)finishChecks:(UIScene *)scene {
    UINavigationController *navigation = (id)self.window.rootViewController;
    SettingsViewController *settings = (id)navigation.viewControllers.firstObject;
    Check(navigation.viewControllers.count == 1, @"warm settings URL finishes navigation to the settings root");
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *route = [identifier stringByAppendingString:@"://settings"];
    NSUInteger routes;

    NSArray *invalidURLs = @[@"https://settings", @"com.dkaluta.omnibar://settings",
        [route stringByAppendingString:@"?input=secret"],
        [route stringByAppendingString:@"#secret"],
        [route stringByAppendingString:@"/other"],
        [identifier stringByAppendingString:@"://user:secret@settings"]];
    for (NSString *URL in invalidURLs) {
        UIViewController *detail = [UIViewController new];
        [navigation setViewControllers:@[settings, detail] animated:NO];
        routes = settingsRoutes;
        [self scene:scene openURLContexts:Contexts(URL)];
        Check(settingsRoutes == routes && navigation.topViewController == detail, @"warm foreign or data-bearing URL leaves navigation unchanged");
    }
    routes = settingsRoutes;
    [self scene:scene openURLContexts:[NSSet set]];
    Check(settingsRoutes == routes, @"empty URL contexts are ignored");
    [navigation setViewControllers:@[settings] animated:NO];

    SceneDelegate *other = [SceneDelegate new];
    routes = settingsRoutes;
    [other scene:scene willConnectToSession:scene.session options:Options(@"https://settings")];
    Check(other.window.windowScene == scene && factoryCalls == 2, @"new scene connection constructs its own window and settings");
    Check(settingsRoutes == routes, @"cold-launch foreign URL is ignored");
    other.window.hidden = YES;
    other.window = nil;
    [self.window makeKeyAndVisible];

    SceneDelegate *nonWindow = [SceneDelegate new];
    [nonWindow scene:(id)[NSObject new] willConnectToSession:scene.session options:Options(route)];
    Check(nonWindow.window == nil && factoryCalls == 2, @"non-window scenes do not construct settings or a window");

    finished = YES;
    printf("%lu iPad scene lifecycle checks passed\n", (unsigned long)checks);
    fflush(stdout);
    exit(0);
}
@end

@interface OMLifecycleAppDelegate : AppDelegate
@end
@implementation OMLifecycleAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Check(finished, @"UIKit connects and activates the test scene before timeout");
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(OMLifecycleAppDelegate.class));
    }
}
