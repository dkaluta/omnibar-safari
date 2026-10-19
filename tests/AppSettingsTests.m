#import <AppKit/AppKit.h>
#import "ViewController.h"
#import "AppDelegate.h"
#import "OmnibarSettingsLink.h"
#import "SearchSettingsController.h"
#import "SettingsTestSupport.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

@interface OMSettingsHost : ViewController
@property (strong) OmnibarSearchSettings *inMemorySettings;
@end
@implementation OMSettingsHost
- (OmnibarSearchSettings *)searchSettings { return self.inMemorySettings; }
- (void)refreshExtensionState {} // Never query real Safari registration in tests.
@end

@interface OMLinkDelegate : AppDelegate
@property NSUInteger settingsRequests;
@end
@implementation OMLinkDelegate
- (void)showSearchSettings:(id)sender { self.settingsRequests++; }
@end

static void DispatchSettingsEvent(NSString *value) {
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kInternetEventClass
        eventID:kAEGetURL targetDescriptor:nil returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    if (value) [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:value] forKeyword:keyDirectObject];
    AppleEvent reply = {typeNull, NULL};
    OSErr result = [NSAppleEventManager.sharedAppleEventManager dispatchRawAppleEvent:event.aeDesc
        withRawReply:&reply handlerRefCon:(SRefCon)&reply];
    AEDisposeDesc(&reply);
    Check(result == noErr, @"registered app handler receives the synthetic Get URL event locally");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        OMTestDefaults *defaults;
        OMTestCredentials *credentials;
        OmnibarSearchSettings *settings = OMMakeTestSettings(&defaults, &credentials);
        (void)settings.searchEngines; // Establish the existing engine-preference fixture.
        OMSettingsHost *host = [OMSettingsHost new];
        host.inMemorySettings = settings;
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 560)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.contentViewController = host;
        (void)host.view;
        NSDictionary *before = defaults.values.copy;
        [host showSearchSettings:nil];
        SearchSettingsController *controller = [host valueForKey:@"settingsController"];
        Check(controller != nil && [host.childViewControllers containsObject:controller],
              @"containing app hosts the existing settings controller without any Safari extension");
        Check([controller valueForKey:@"settings"] == settings, @"app UI edits its injected shared settings model");
        Check([before isEqual:defaults.values] && credentials.reads == 0,
              @"opening configured engine settings saves no activity and reads no credentials");
        [host showSearchSettings:nil];
        Check([host valueForKey:@"settingsController"] == controller && host.childViewControllers.count == 1,
              @"repeated settings links do not duplicate views or replace unsaved edits");
        NSTextField *suffix = [controller valueForKey:@"suffixField"];
        suffix.stringValue = @".co.uk";
        [(NSButton *)[controller valueForKey:@"saveSuffixButton"] performClick:nil];
        Check([settings.defaultURLSuffix isEqual:@".co.uk"], @"app-hosted suffix control saves to the shared model");
        NSSecureTextField *privateField = [controller valueForKey:@"privateLinkField"];
        privateField.stringValue = @"FAKE_UNSAVED_SECRET";
        [(NSButton *)[controller valueForKey:@"doneButton"] performClick:nil];
        Check([host valueForKey:@"settingsController"] == nil && host.childViewControllers.count == 0,
              @"Done returns from settings to setup");
        Check(privateField.stringValue.length == 0 && credentials.URL == nil,
              @"closing app settings clears unsaved private input without persisting it");
        [host showSearchSettings:nil];
        controller = [host valueForKey:@"settingsController"];
        privateField = [controller valueForKey:@"privateLinkField"];
        privateField.stringValue = @"FAKE_UNSAVED_SECRET";
        [host viewWillDisappear];
        Check(privateField.stringValue.length == 0, @"hiding or closing the host also clears private input");
        [host closeSearchSettings];

        OMLinkDelegate *delegate = [OMLinkDelegate new];
        NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
        Check(identifier.length > 0, @"settings test bundle has an isolated identity");
        [delegate application:NSApp openURLs:@[OmnibarSettingsURL(identifier)]];
        Check(delegate.settingsRequests == 1, @"the fixed app settings URL reaches the settings action");
        for (NSString *suffixText in @[@"?input=secret", @"#secret", @"/other"]) {
            NSURL *URL = [NSURL URLWithString:[OmnibarSettingsURL(identifier).absoluteString stringByAppendingString:suffixText]];
            [delegate application:NSApp openURLs:@[URL]];
        }
        [delegate application:NSApp openURLs:@[[NSURL URLWithString:@"com.dkaluta.omnibar://settings"]]];
        Check(delegate.settingsRequests == 1, @"app delegate ignores payload-bearing and other-build links");
        NSNotification *launch = [NSNotification notificationWithName:NSApplicationWillFinishLaunchingNotification object:NSApp];
        [delegate applicationWillFinishLaunching:launch];
        DispatchSettingsEvent(OmnibarSettingsURL(identifier).absoluteString);
        Check(delegate.settingsRequests == 2, @"Launch Services Get URL events reach settings before and after normal startup");
        DispatchSettingsEvent(nil);
        DispatchSettingsEvent([OmnibarSettingsURL(identifier).absoluteString stringByAppendingString:@"?input=secret"]);
        DispatchSettingsEvent(@"com.dkaluta.omnibar://settings");
        Check(delegate.settingsRequests == 2, @"raw Apple events retain exact URL validation and reject missing or foreign payloads");
        AppDelegate *coldDelegate = [AppDelegate new];
        [coldDelegate applicationWillFinishLaunching:launch];
        DispatchSettingsEvent(OmnibarSettingsURL(identifier).absoluteString);
        Check([[coldDelegate valueForKey:@"pendingSettings"] boolValue], @"a settings launch event is remembered until the app window exists");
        [coldDelegate applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
        [window close];
        printf("Passed %lu app-settings checks; Safari and credentials were simulated.\n", (unsigned long)checks);
    }
    return 0;
}
