#import "AppDelegate.h"
#import "ViewController.h"
#import "OmnibarSettingsLink.h"
#import "OmnibarSettingsRouteDiagnostics.h"

@interface AppDelegate ()
@property (strong) NSWindow *window;
@property BOOL pendingSettings;
@end

@implementation AppDelegate

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // Register before the first launch event. This app constructs NSApplication
    // directly, so receive Launch Services' Get URL event explicitly as well as
    // supporting AppKit's openURLs delegate callback.
    [NSAppleEventManager.sharedAppleEventManager setEventHandler:self
        andSelector:@selector(handleSettingsAppleEvent:withReplyEvent:)
        forEventClass:kInternetEventClass andEventID:kAEGetURL];
    OmnibarTraceSettingsRoute(200); // App registered Get URL receiver.
}

- (void)handleSettingsAppleEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply {
    OmnibarTraceSettingsRoute(210); // Get URL event received.
    NSString *value = [event paramDescriptorForKeyword:keyDirectObject].stringValue;
    NSURL *settingsURL = OmnibarSettingsURL(NSBundle.mainBundle.bundleIdentifier);
    if (settingsURL && [value isEqualToString:settingsURL.absoluteString]) {
        OmnibarTraceSettingsRoute(211); // Fixed settings URL matched.
        [self application:NSApp openURLs:@[settingsURL]];
    } else {
        OmnibarTraceSettingsRoute(212); // URL was absent or did not match.
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *applicationItem = [[NSMenuItem alloc] initWithTitle:@"Omnibar" action:NULL keyEquivalent:@""];
    NSMenu *applicationMenu = [[NSMenu alloc] initWithTitle:@"Omnibar"];
    [applicationMenu addItemWithTitle:@"About Omnibar" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *settings = [applicationMenu addItemWithTitle:@"Settings…" action:@selector(showSearchSettings:) keyEquivalent:@","];
    settings.target = self;
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    [applicationMenu addItemWithTitle:@"Hide Omnibar" action:@selector(hide:) keyEquivalent:@"h"];
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    [applicationMenu addItemWithTitle:@"Quit Omnibar" action:@selector(terminate:) keyEquivalent:@"q"];
    applicationItem.submenu = applicationMenu;
    [mainMenu addItem:applicationItem];
    NSApp.mainMenu = mainMenu;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Omnibar";
    self.window.releasedWhenClosed = NO;
    self.window.contentViewController = [[ViewController alloc] init];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    OmnibarTraceSettingsRoute(220); // App window is ready.
    if (self.pendingSettings) [self showSearchSettings:nil];
}

- (void)showSearchSettings:(id)sender {
    OmnibarTraceSettingsRoute(230); // Settings action entered.
    if (!self.window) { self.pendingSettings = YES; OmnibarTraceSettingsRoute(231); return; }
    self.pendingSettings = NO;
    [self.window makeKeyAndOrderFront:nil];
    [(ViewController *)self.window.contentViewController showSearchSettings:sender];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)URLs {
    OmnibarTraceSettingsRoute(240); // AppKit URL callback entered.
    for (NSURL *URL in URLs) {
        if (OmnibarIsSettingsURL(URL, NSBundle.mainBundle.bundleIdentifier)) {
            [self showSearchSettings:nil];
            return;
        }
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSAppleEventManager.sharedAppleEventManager removeEventHandlerForEventClass:kInternetEventClass andEventID:kAEGetURL];
    [(ViewController *)self.window.contentViewController closeSearchSettings];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    return YES;
}

@end
