#import "SafariWebExtensionHandler.h"
#import "OmnibarMobileSettings.h"
#import "SettingsTestSupport.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSDictionary *Resolve(SafariWebExtensionHandler *handler, NSString *input, NSString *engine, BOOL private) {
    return [handler responseForMessage:@{@"type": @"resolve", @"input": input, @"engineID": engine, @"privateBrowsing": @(private)}];
}
@interface OMRequestContext : NSExtensionContext
@property (strong) NSArray *requests;
@property (strong) NSArray *replies;
@property (strong) dispatch_semaphore_t completed;
@end
@implementation OMRequestContext
- (NSArray *)inputItems { return self.requests; }
- (void)completeRequestReturningItems:(NSArray *)items completionHandler:(void (^)(BOOL))completionHandler {
    self.replies = items;
    dispatch_semaphore_signal(self.completed);
}
@end

int main(void) {
    @autoreleasepool {
        OMTestDefaults *defaults;
        OMTestCredentials *credentials;
        OmnibarSearchSettings *settings = OMMakeTestSettings(&defaults, &credentials);
        SafariWebExtensionHandler *handler = [[SafariWebExtensionHandler alloc] initWithSettings:settings];
        NSDictionary *metadata = [handler responseForMessage:@{@"type": @"settings"}];
        Check([metadata[@"selectedEngineID"] isEqual:@"duckduckgo"], @"saved engine is returned");
        Check([metadata[@"migrationPending"] isEqual:@NO], @"iPad does not request impossible Mac legacy migration");
        Check([metadata[@"showPaletteTips"] isEqual:@YES], @"new installs show the introduction");
        Check([metadata[@"defaultURLSuffix"] isEqual:@".com"], @"default website suffix is returned");
        for (NSDictionary *engine in metadata[@"engines"])
            Check(engine.count == 2 && engine[@"id"] && engine[@"name"], @"engine metadata contains only id and name");
        Check(credentials.reads == 0, @"metadata does not access credentials");
        Check([settings setDefaultURLSuffix:@".co.uk" error:NULL], @"multi-label suffix can be saved");
        NSDictionary *saved = defaults.values.copy;
        Check([Resolve(handler, @".cnn", @"kagi", YES)[@"url"] isEqual:@"https://www.cnn.co.uk/"], @"shorthand uses saved suffix");
        Check([Resolve(handler, @".bsky.app", @"kagi", YES)[@"url"] isEqual:@"https://www.bsky.app/"], @"shorthand keeps explicit suffix");
        Check([Resolve(handler, @"example.com", @"kagi", YES)[@"url"] isEqual:@"https://example.com/"], @"address uses authoritative resolver");
        Check([Resolve(handler, @"hello world", @"kagi", NO)[@"url"] isEqual:@"https://kagi.com/search?q=hello%20world"], @"regular Kagi works without credentials");
        Check(credentials.reads == 0, @"addresses and regular searches do not access credentials");
        Check([Resolve(handler, @"hello world", @"kagi", YES)[@"url"] isEqual:@"https://kagi.com/search?q=hello%20world"], @"private Kagi works when optional link is absent");
        Check(credentials.reads == 1, @"only explicit private Kagi submission checks optional credential");
        credentials.URL = @"https://kagi.com/search?token=ISOLATED_TEST_SECRET&q=%s";
        NSString *privateURL = Resolve(handler, @"hello world", @"kagi", YES)[@"url"];
        Check([privateURL containsString:@"token=ISOLATED_TEST_SECRET"] && [privateURL containsString:@"q=hello%20world"], @"explicit private submission resolves saved link");
        NSUInteger reads = credentials.reads;
        Check(![[[handler responseForMessage:@{@"type": @"settings"}] description] containsString:@"ISOLATED_TEST_SECRET"], @"metadata never contains the saved private link");
        Check(credentials.reads == reads, @"reopening metadata does not access credentials");
        NSDictionary *openSettings = [handler responseForMessage:@{@"type": @"openSettings"}];
        Check(openSettings[@"opened"] == nil && [openSettings[@"error"] containsString:@"Home Screen"], @"unsupported app launch gives honest direct-app instructions");
        Check(credentials.reads == reads && [saved isEqual:defaults.values], @"settings instructions do not access credentials or save activity");
        for (id malformed in @[@[], @"settings", @{}, @{@"type": @1}, @{@"type": @"save"},
            @{@"type": @"settings", @"input": @"PRIVATE_TEST_INPUT"},
            @{@"type": @"openSettings", @"url": @"private://payload"},
            @{@"type": @"dismissPaletteTips", @"input": @"PRIVATE_TEST_INPUT"},
            @{@"type": @"resolve", @"input": @[], @"engineID": @"kagi", @"privateBrowsing": @YES},
            @{@"type": @"resolve", @"input": @"hello", @"engineID": @"kagi", @"privateBrowsing": @1},
            @{@"type": @"resolve", @"input": @"hello", @"engineID": @"kagi", @"privateBrowsing": @"true"},
            @{@"type": @"resolve", @"input": @"hello", @"engineID": @"kagi"},
            @{@"type": @"resolve", @"input": @"hello", @"engineID": @"kagi", @"privateBrowsing": @NO, @"extra": @1}])
            Check([handler responseForMessage:malformed][@"error"] != nil, @"malformed requests fail closed");
        Check([handler responseForMessage:nil][@"error"] != nil, @"missing message fails closed");
        Check(Resolve(handler, [@"x" stringByPaddingToLength:16385 withString:@"x" startingAtIndex:0], @"kagi", NO)[@"error"] != nil, @"oversized input is rejected");
        Check(Resolve(handler, @"hello", @"removed-engine", NO)[@"error"] != nil, @"unavailable engine is rejected");
        Check(Resolve(handler, @"https://user:secret@example.com", @"kagi", YES)[@"error"] != nil, @"credential-bearing address is rejected");
        credentials.fail = YES;
        NSDictionary *failed = Resolve(handler, @"hello", @"kagi", YES);
        Check(failed[@"url"] == nil && failed[@"error"] != nil && ![[failed description] containsString:@"ISOLATED_TEST_SECRET"], @"credential failure does not leak data or silently fall back");
        Check([saved isEqual:defaults.values], @"requests persist no query, URL, tab or activity data");
        reads = credentials.reads;
        Check([[handler responseForMessage:@{@"type": @"dismissPaletteTips"}][@"showPaletteTips"] isEqual:@NO], @"explicit dismissal changes tips preference");
        NSMutableDictionary *expected = saved.mutableCopy; expected[@"showPaletteTips"] = @NO;
        Check([expected isEqual:defaults.values] && credentials.reads == reads, @"tips dismissal persists only its boolean and reads no credential");
        NSString *appID = @"com.dkaluta.omnibar.development.ios";
        Check(OmnibarMobileAcceptsSettingsURL([NSURL URLWithString:[appID stringByAppendingString:@"://settings"]], appID), @"containing app accepts exact fixed settings route");
        for (NSString *URL in @[@"com.dkaluta.omnibar://settings", @"com.dkaluta.omnibar.development.ios://settings?input=secret",
            @"com.dkaluta.omnibar.development.ios://settings#secret", @"com.dkaluta.omnibar.development.ios://settings/other",
            @"com.dkaluta.omnibar.development.ios://user:secret@settings", @"https://settings"])
            Check(!OmnibarMobileAcceptsSettingsURL([NSURL URLWithString:URL], appID), @"app route rejects foreign identities and arbitrary data");
        NSError *configurationError = nil;
        Check(OmnibarMobileSearchSettings(&configurationError) == nil && configurationError != nil, @"unbundled configuration fails without touching standard defaults or Keychain");
        OMRequestContext *context = [OMRequestContext new];
        context.completed = dispatch_semaphore_create(0);
        NSExtensionItem *item = [NSExtensionItem new]; item.userInfo = @{SFExtensionMessageKey: @{@"type": @"settings"}};
        context.requests = @[item];
        [handler beginRequestWithExtensionContext:context];
        Check(dispatch_semaphore_wait(context.completed, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0, @"extension context completes asynchronously");
        Check([context.replies.firstObject userInfo][SFExtensionMessageKey][@"engines"] != nil, @"Safari receives native reply in expected envelope");
        printf("%lu iPad native bridge checks passed\n", (unsigned long)checks);
    }
    return 0;
}
