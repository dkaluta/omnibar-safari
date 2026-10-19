#import "SafariWebExtensionHandler.h"
#import "SettingsTestSupport.h"
#import "../native/Omnibar/Omnibar/OmnibarSettingsLink.h"
#import <AppKit/AppKit.h>

@interface SafariWebExtensionHandler (OpeningConfigurationTests)
- (NSWorkspaceOpenConfiguration *)settingsOpenConfiguration;
@end

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

@interface OMRequestContext : NSExtensionContext
@property (nonatomic, strong) NSArray *requests;
@property (nonatomic, strong) NSArray *replies;
@property (nonatomic, strong) dispatch_semaphore_t completed;
@end
@implementation OMRequestContext
- (NSArray *)inputItems { return self.requests; }
- (void)completeRequestReturningItems:(NSArray *)items completionHandler:(void (^)(BOOL))completionHandler {
    self.replies = items;
    dispatch_semaphore_signal(self.completed);
}
@end

@interface OMOpeningHandler : SafariWebExtensionHandler
@property (strong) NSBundle *testBundle;
@property NSUInteger launches;
@property (strong) NSURL *openedURL;
@property (strong) NSURL *applicationURL;
@property BOOL succeeds;
@end
@implementation OMOpeningHandler
- (NSBundle *)extensionBundle { return self.testBundle; }
- (void)openSettingsURL:(NSURL *)URL applicationURL:(NSURL *)applicationURL completion:(void (^)(BOOL))completion {
    self.launches++; self.openedURL = URL; self.applicationURL = applicationURL;
    completion(self.succeeds);
}
@end

static NSDictionary *HandleRequest(SafariWebExtensionHandler *handler, id message) {
    __block NSDictionary *reply;
    [handler handleMessage:message completion:^(NSDictionary *result) { reply = result; }];
    return reply;
}

static NSBundle *SettingsBundle(NSURL *root, NSString *appID, NSString *extensionID, NSString *containingID, NSString *intermediate) {
    NSURL *appURL = [root URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"app"]];
    NSURL *appContents = [appURL URLByAppendingPathComponent:@"Contents"];
    NSURL *extensionURL = [appContents URLByAppendingPathComponent:[intermediate stringByAppendingPathComponent:@"Commands.appex"]];
    NSURL *extensionContents = [extensionURL URLByAppendingPathComponent:@"Contents"];
    [NSFileManager.defaultManager createDirectoryAtURL:extensionContents withIntermediateDirectories:YES attributes:nil error:NULL];
    [@{@"CFBundleIdentifier": appID, @"CFBundlePackageType": @"APPL", @"CFBundleExecutable": @"Omnibar"}
        writeToURL:[appContents URLByAppendingPathComponent:@"Info.plist"] atomically:YES];
    [@{@"CFBundleIdentifier": extensionID, @"CFBundlePackageType": @"XPC!", @"CFBundleExecutable": @"Commands", @"OmnibarContainingAppIdentifier": containingID}
        writeToURL:[extensionContents URLByAppendingPathComponent:@"Info.plist"] atomically:YES];
    return [NSBundle bundleWithURL:extensionURL];
}

static void TestSettingsRoute(OmnibarSearchSettings *settings, OMTestDefaults *defaults, OMTestCredentials *credentials) {
    NSString *identifier = @"com.dkaluta.omnibar.development";
    NSURL *root = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    OMOpeningHandler *handler = [[OMOpeningHandler alloc] initWithSettings:settings];
    NSWorkspaceOpenConfiguration *configuration = [handler settingsOpenConfiguration];
    Check(!configuration.activates, @"URL handoff does not close Safari's popup by activating setup before settings receives its event");
    Check(!configuration.allowsRunningApplicationSubstitution, @"settings handoff keeps the verified containing app path even if another copy is running");
    Check(!configuration.addsToRecentItems, @"fixed settings handoff creates no recent-item entry");
    handler.testBundle = SettingsBundle(root, identifier, [identifier stringByAppendingString:@".Commands"], identifier, @"PlugIns");
    handler.succeeds = YES;
    NSDictionary *before = defaults.values.copy;
    NSUInteger reads = credentials.reads;
    Check([HandleRequest(handler, @{@"type": @"openSettings"})[@"opened"] isEqual:@YES], @"explicit open-settings request completes through the public launch boundary");
    Check(handler.launches == 1 && [handler.openedURL.absoluteString isEqual:@"com.dkaluta.omnibar.development://settings"],
          @"the route contains only the fixed build-specific settings destination");
    Check([handler.applicationURL isEqual:handler.testBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent],
          @"the launcher targets the verified containing bundle instead of global app registration");
    for (NSString *key in @[@"url", @"input", @"path", @"engineID", @"settings"]) {
        Check(HandleRequest(handler, @{@"type": @"openSettings", key: @"CALLER_DATA_NEVER_USED"})[@"error"] != nil && handler.launches == 1,
              @"settings route rejects all caller data without launching");
    }
    handler.succeeds = NO;
    NSDictionary *failed = HandleRequest(handler, @{@"type": @"openSettings"});
    Check(failed[@"error"] != nil && failed[@"opened"] == nil, @"launch failure is shown rather than reported as success");
    Check(![[failed description] containsString:root.path], @"launch failure never exposes a system path");
    NSUInteger launches = handler.launches;
    for (NSArray *configuration in @[
        @[@"com.dkaluta.omnibar", [identifier stringByAppendingString:@".Commands"], identifier, @"PlugIns"],
        @[identifier, [identifier stringByAppendingString:@".Extension"], identifier, @"PlugIns"],
        @[identifier, [identifier stringByAppendingString:@".Commands"], @"$(APP_ID)", @"PlugIns"],
        @[identifier, [identifier stringByAppendingString:@".Commands"], identifier, @"Elsewhere"]]) {
        handler.testBundle = SettingsBundle(root, configuration[0], configuration[1], configuration[2], configuration[3]);
        Check(HandleRequest(handler, @{@"type": @"openSettings"})[@"error"] != nil && handler.launches == launches,
              @"mismatched identities and non-containing app paths cannot launch settings");
    }
    for (id invalidInfo in @[@{@"CFBundleIdentifier": identifier, @"CFBundlePackageType": @"XPC!"},
        @{@"CFBundleIdentifier": @123, @"CFBundlePackageType": @"APPL"},
        @[@"not an app dictionary"], @"not a property list", NSNull.null]) {
        handler.testBundle = SettingsBundle(root, identifier, [identifier stringByAppendingString:@".Commands"], identifier, @"PlugIns");
        NSURL *app = handler.testBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSURL *infoURL = [app URLByAppendingPathComponent:@"Contents/Info.plist"];
        if (invalidInfo == NSNull.null) [NSFileManager.defaultManager removeItemAtURL:infoURL error:NULL];
        else if ([invalidInfo isKindOfClass:NSString.class]) [(NSString *)invalidInfo writeToURL:infoURL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        else [invalidInfo writeToURL:infoURL atomically:YES];
        Check(HandleRequest(handler, @{@"type": @"openSettings"})[@"error"] != nil && handler.launches == launches,
              @"readable invalid metadata and missing parent metadata never use the sandbox-permission fallback");
    }
    Check(OmnibarIsSettingsURL(OmnibarSettingsURL(identifier), identifier), @"app accepts its exact settings link");
    for (NSString *URL in @[@"com.dkaluta.omnibar://settings", @"com.dkaluta.omnibar.development://settings?input=secret",
        @"com.dkaluta.omnibar.development://settings#secret", @"com.dkaluta.omnibar.development://settings/other",
        @"com.dkaluta.omnibar.development://user:secret@settings", @"https://settings", @"com.dkaluta.omnibar.development://elsewhere"])
        Check(!OmnibarIsSettingsURL([NSURL URLWithString:URL], identifier), @"app rejects foreign schemes and any settings-link payload");
    Check([before isEqual:defaults.values] && credentials.reads == reads, @"opening settings changes no preferences and reads no credentials in the extension");
    [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
}

static NSDictionary *Resolve(SafariWebExtensionHandler *handler, NSString *input, NSString *engine, BOOL private) {
    return [handler responseForMessage:@{@"type": @"resolve", @"input": input, @"engineID": engine, @"privateBrowsing": @(private)}];
}

int main(void) {
    @autoreleasepool {
        OMTestDefaults *defaults;
        OMTestCredentials *credentials;
        OmnibarSearchSettings *settings = OMMakeTestSettings(&defaults, &credentials);
        TestSettingsRoute(settings, defaults, credentials);
        credentials.URL = @"https://kagi.com/search?token=ISOLATED_TEST_SECRET&q=%s";
        SafariWebExtensionHandler *handler = [[SafariWebExtensionHandler alloc] initWithSettings:settings];
        NSDictionary *metadata = [handler responseForMessage:@{@"type": @"settings"}];
        Check([metadata[@"selectedEngineID"] isEqual:@"duckduckgo"], @"native engine choice is shared");
        Check([metadata[@"engines"] count] > 1, @"engine metadata is returned");
        Check([metadata[@"showPaletteTips"] isEqual:@YES], @"first-open tips are included as a boolean preference");
        Check([metadata[@"defaultURLSuffix"] isEqual:@".com"], @"default website suffix is shared with the palette");
        for (NSDictionary *engine in metadata[@"engines"]) {
            Check(engine.count == 2 && engine[@"id"] && engine[@"name"], @"only id and name cross the metadata boundary");
        }
        Check(credentials.reads == 0, @"opening settings never reads credentials");
        Check([settings setDefaultURLSuffix:@".co.uk" error:NULL], @"native website suffix can be configured");
        Check([[[handler responseForMessage:@{@"type": @"settings"}] objectForKey:@"defaultURLSuffix"] isEqual:@".co.uk"],
              @"palette metadata includes the saved multi-label suffix");
        NSDictionary *saved = defaults.values.copy;
        Check([Resolve(handler, @".cnn", @"kagi", YES)[@"url"] isEqual:@"https://www.cnn.co.uk/"],
              @"dot shorthand uses the saved suffix at the native message boundary");
        Check([Resolve(handler, @".bsky.app", @"kagi", YES)[@"url"] isEqual:@"https://www.bsky.app/"],
              @"dot shorthand preserves an explicitly supplied suffix");
        Check([Resolve(handler, @"example.com", @"kagi", YES)[@"url"] isEqual:@"https://example.com/"], @"addresses resolve without reading Kagi");
        Check(credentials.reads == 0, @"direct navigation never reads credentials");
        Check([Resolve(handler, @"hello world", @"kagi", NO)[@"url"] isEqual:@"https://kagi.com/search?q=hello%20world"], @"ordinary Kagi search never attaches private token");
        Check(credentials.reads == 0, @"regular searches never read private credentials");
        NSString *privateURL = Resolve(handler, @"hello world", @"kagi", YES)[@"url"];
        Check([privateURL containsString:@"token=ISOLATED_TEST_SECRET"] && [privateURL containsString:@"q=hello%20world"], @"only explicit private Kagi submission resolves a token URL");
        Check(credentials.reads == 1, @"private Kagi submission reads once");
        Check(Resolve(handler, @"hello", @"removed-engine", NO)[@"error"] != nil, @"stale engines fail instead of falling back");
        Check(Resolve(handler, @"https://user:secret@example.com", @"duckduckgo", NO)[@"error"] != nil, @"credential-bearing direct address fails validation");
        credentials.fail = YES;
        Check(Resolve(handler, @"hello", @"kagi", YES)[@"url"] == nil, @"credential failure never triggers ordinary fallback navigation");
        Check(![[Resolve(handler, @"hello", @"kagi", YES) description] containsString:@"ISOLATED_TEST_SECRET"], @"failures contain no credential");
        for (id malformed in @[@[], @"resolve", @{}, @{@"type": @1}, @{@"type": @"save"},
              @{@"type": @"resolve", @"input": @[], @"engineID": @"kagi", @"privateBrowsing": @YES},
              @{@"type": @"resolve", @"input": @"hello", @"engineID": @"kagi", @"privateBrowsing": @"true"},
              @{@"type": @"resolve", @"input": @"hello", @"engineID": @"kagi", @"privateBrowsing": @1},
              @{@"type": @"resolve", @"input": @"hello", @"engineID": @"kagi"}]) {
            Check([handler responseForMessage:malformed][@"error"] != nil, @"malformed native request fails closed");
        }
        Check([handler responseForMessage:nil][@"error"] != nil, @"missing message is handled");
        Check(Resolve(handler, [@"x" stringByPaddingToLength:16385 withString:@"x" startingAtIndex:0], @"kagi", NO)[@"error"] != nil, @"oversized input is rejected");
        Check([saved isEqual:defaults.values], @"requests do not save query, address, tab, or activity data");
        Check([handler responseForMessage:@{@"type": @"dismissPaletteTips", @"input": @"NOT_STORED"}][@"error"] != nil,
              @"tip dismissal rejects unrelated caller data");
        Check([saved isEqual:defaults.values], @"malformed dismissal cannot change preferences");
        NSUInteger readsBeforeTips = credentials.reads;
        Check([[handler responseForMessage:@{@"type": @"dismissPaletteTips"}][@"showPaletteTips"] isEqual:@NO],
              @"explicit dismissal persists the local tip preference");
        NSMutableDictionary *expectedAfterTips = saved.mutableCopy;
        expectedAfterTips[@"showPaletteTips"] = @NO;
        Check([expectedAfterTips isEqual:defaults.values], @"dismissal saves exactly the tip boolean, never input or activity");
        Check([[[handler responseForMessage:@{@"type": @"settings"}] objectForKey:@"showPaletteTips"] isEqual:@NO],
              @"later palette settings preserve dismissal");
        Check(credentials.reads == readsBeforeTips, @"onboarding preferences do not read the Keychain");

        OMRequestContext *context = [OMRequestContext new];
        NSExtensionItem *item = [NSExtensionItem new];
        item.userInfo = @{SFExtensionMessageKey: @{@"type": @"settings"}};
        context.requests = @[item];
        context.completed = dispatch_semaphore_create(0);
        [handler beginRequestWithExtensionContext:context];
        Check(dispatch_semaphore_wait(context.completed, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"Safari transport completes asynchronously");
        Check([context.replies.firstObject userInfo][SFExtensionMessageKey][@"engines"] != nil, @"reply uses Safari message envelope");
        [settings setValue:[NSError errorWithDomain:@"com.dkaluta.omnibar.settings" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Shared settings are unavailable."}] forKey:@"sharedConfigurationError"];
        Check([handler responseForMessage:@{@"type": @"settings"}][@"engines"] == nil, @"invalid shared configuration cannot return alternate engine defaults");
        Check(Resolve(handler, @"hello", @"duckduckgo", NO)[@"url"] == nil, @"invalid shared configuration prevents navigation");
        Check([handler responseForMessage:@{@"type": @"dismissPaletteTips"}][@"error"] != nil,
              @"invalid shared configuration cannot report saved tip preferences");
        printf("All %lu native web-extension checks passed.\n", (unsigned long)checks);
    }
    return 0;
}
