#import <Foundation/Foundation.h>
#import "OmnibarBrowserSession.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void Wait(BOOL (^condition)(void), NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    Check(condition(), @"asynchronous browser callback completes within its bound");
}

@interface TestProperties : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *title;
@property (nonatomic) BOOL usesPrivateBrowsing;
@end
@implementation TestProperties
@end

@interface TestPage : NSObject
@property (nonatomic, strong) TestProperties *properties;
@property (nonatomic) NSUInteger reloads;
- (void)getPagePropertiesWithCompletionHandler:(void (^)(id))completion;
- (void)reload;
@end
@implementation TestPage
- (void)getPagePropertiesWithCompletionHandler:(void (^)(id))completion { completion(self.properties); }
- (void)reload { self.reloads++; }
@end

@interface TestTab : NSObject
@property (nonatomic, strong) TestPage *page;
@property (nonatomic) NSUInteger activations;
@property (nonatomic) NSUInteger closes;
@property (nonatomic) BOOL deferPage;
@property (nonatomic, copy) void (^pageReply)(id);
- (void)getActivePageWithCompletionHandler:(void (^)(id))completion;
- (void)activateWithCompletionHandler:(void (^)(void))completion;
- (void)close;
@end
@implementation TestTab
- (void)getActivePageWithCompletionHandler:(void (^)(id))completion {
    if (self.deferPage) self.pageReply = completion;
    else completion(self.page);
}
- (void)activateWithCompletionHandler:(void (^)(void))completion { self.activations++; completion(); }
- (void)close { self.closes++; }
@end

@interface TestWindow : NSObject
@property (nonatomic, strong) NSArray<TestTab *> *tabs;
@property (nonatomic, strong) TestTab *openedTab;
@property (nonatomic, strong) NSURL *openedURL;
@property (nonatomic) BOOL openedActive;
@property (nonatomic) NSUInteger openings;
@property (nonatomic) NSUInteger enumerations;
@property (nonatomic) BOOL backgroundCallbacks;
- (void)getAllTabsWithCompletionHandler:(void (^)(NSArray *))completion;
- (void)openTabWithURL:(NSURL *)URL makeActiveIfPossible:(BOOL)active completionHandler:(void (^)(id))completion;
@end
@implementation TestWindow
- (void)getAllTabsWithCompletionHandler:(void (^)(NSArray *))completion {
    self.enumerations++;
    if (self.backgroundCallbacks) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ completion(self.tabs); });
    else completion(self.tabs);
}
- (void)openTabWithURL:(NSURL *)URL makeActiveIfPossible:(BOOL)active completionHandler:(void (^)(id))completion {
    self.openings++;
    self.openedURL = URL;
    self.openedActive = active;
    completion(self.openedTab);
}
@end

static TestTab *Tab(NSString *title, NSString *URL, BOOL privateBrowsing) {
    TestTab *tab = [TestTab new];
    tab.page = [TestPage new];
    tab.page.properties = [TestProperties new];
    tab.page.properties.title = title;
    tab.page.properties.url = [NSURL URLWithString:URL];
    tab.page.properties.usesPrivateBrowsing = privateBrowsing;
    return tab;
}

static NSArray *Load(OmnibarBrowserSession *session, NSError **error) {
    __block BOOL done = NO;
    __block NSArray *result;
    __block NSError *failure;
    [session loadTabsWithCompletion:^(NSArray *tabs, NSError *replyError) {
        Check(NSThread.isMainThread, @"tab snapshots arrive on the main thread");
        result = tabs; failure = replyError; done = YES;
    }];
    Wait(^BOOL { return done; }, 2.5);
    if (error) *error = failure;
    return result;
}

static NSError *Command(OmnibarBrowserSession *session, NSString *identifier) {
    __block BOOL done = NO;
    __block NSError *error;
    [session performCommandWithIdentifier:identifier completion:^(NSError *replyError) {
        Check(NSThread.isMainThread, @"command completions arrive on the main thread");
        error = replyError; done = YES;
    }];
    Wait(^BOOL { return done; }, 3.5);
    return error;
}

int main(void) {
    @autoreleasepool {
        TestTab *origin = Tab(@"Original page", @"https://example.com/current?token=LOCAL_ONLY_SECRET#fragment", NO);
        TestTab *other = Tab(@"Second page", @"https://other.example/?q=UNSUBMITTED_QUERY", NO);
        TestTab *private = Tab(@"Private page", @"https://private.example/", YES);
        TestWindow *window = [TestWindow new];
        window.tabs = @[origin, other, private];
        window.openedTab = Tab(@"Opened page", @"https://example.com/", NO);
        OmnibarBrowserSession *session = [[OmnibarBrowserSession alloc] initWithWindow:(id)window tab:(id)origin];
        NSError *error;
        NSArray *rows = Load(session, &error);
        Check(!error && rows.count == 2, @"only tabs from the original browsing context are returned");
        Check([rows[0][@"title"] isEqual:@"Original page"] && [rows[0][@"current"] boolValue]
              && [rows[1][@"subtitle"] isEqual:@"other.example"], @"rows retain order, title, current state and host");
        Check(![[rows description] containsString:@"LOCAL_ONLY_SECRET"] && ![[rows description] containsString:@"UNSUBMITTED_QUERY"]
              && ![[rows description] containsString:@"fragment"], @"tab metadata excludes URL query, fragment and credentials");
        NSString *otherID = rows[1][@"id"];
        Check([Load(session, NULL)[1][@"id"] isEqual:otherID], @"tab identifiers stay stable only within their session");
        Check(session.commands.count == 3 && ![[session.commands valueForKey:@"id"] containsObject:@"duplicate-tab"]
              && ![[session.commands valueForKey:@"id"] containsObject:@"new-tab"],
              @"only supported commands are offered, without blank tabs or pretending to duplicate history");

        __block BOOL switched = NO;
        [session activateTabWithIdentifier:otherID completion:^(NSError *failure) { Check(!failure, @"captured tab can be activated"); switched = YES; }];
        Wait(^BOOL { return switched; }, 1);
        Check(other.activations == 1 && origin.activations == 0, @"switch acts on the chosen captured tab");
        Check(!Command(session, @"reload-tab") && origin.page.reloads == 1 && other.page.reloads == 0,
              @"reload retains the original tab after a different tab is activated");
        Check(Command(session, @"new-tab") != nil && window.openings == 0,
              @"unsupported blank-tab requests never reach Safari or an app-level fallback");
        Check(!Command(session, @"open-page-new-tab") && [window.openedURL isEqual:origin.page.properties.url] && window.openedActive,
              @"Open Page in New Tab uses the captured page address only after explicit action");
        Check(!Command(session, @"close-tab") && origin.closes == 1 && other.closes == 0,
              @"Close Tab retains the origin rather than following whichever tab is active");
        for (NSString *unsupported in @[@"pin-tab", @"mute-tab", @"go-back", @"go-forward", @"duplicate-tab", @"arbitrary"])
            Check(Command(session, unsupported) != nil, @"unsupported commands fail without any mutation");

        other.page.properties.usesPrivateBrowsing = YES;
        __block NSError *switchError;
        switched = NO;
        [session activateTabWithIdentifier:otherID completion:^(NSError *failure) { switchError = failure; switched = YES; }];
        Wait(^BOOL { return switched; }, 1);
        Check(switchError && other.activations == 1, @"activation revalidates private context after loading results");
        other.page.properties.usesPrivateBrowsing = NO;
        origin.page.properties.usesPrivateBrowsing = YES;
        Check(Load(session, &error).count == 0 && error, @"refresh cannot replace the original session’s private context");
        origin.page.properties.usesPrivateBrowsing = NO;
        otherID = Load(session, &error)[1][@"id"];

        other.deferPage = YES;
        switched = NO;
        [session activateTabWithIdentifier:otherID completion:^(NSError *failure) { switchError = failure; switched = YES; }];
        Check(other.pageReply != nil && !switched, @"action waits for asynchronous properties");
        window.tabs = @[origin];
        other.pageReply(other.page);
        Wait(^BOOL { return switched; }, 1);
        Check(switchError && other.activations == 1, @"a tab moved while metadata was loading cannot be activated elsewhere");
        window.tabs = @[other];
        NSUInteger openings = window.openings;
        Check(Command(session, @"open-page-new-tab") != nil && window.openings == openings,
              @"a removed original tab invalidates window actions");
        Check(Load(session, &error).count == 0 && error, @"stale snapshots reveal no replacement-window tabs");

        window.tabs = @[origin];
        origin.page.properties.url = [NSURL URLWithString:@"https://user:password@example.com/"];
        Check(Command(session, @"open-page-new-tab") != nil && window.openings == openings,
              @"credential-bearing addresses cannot be opened through the page-copy command");
        origin.page.properties = nil;
        rows = Load(session, &error);
        Check(!error && rows.count == 1 && [rows[0][@"title"] isEqual:@"Tab 1"],
              @"tabs without website access remain selectable by position");
        Check(Command(session, @"open-page-new-tab") != nil, @"missing page URL returns a clear error");
        Check(!Command(session, @"reload-tab") && origin.page.reloads == 2,
              @"reload uses its public API even when page properties are unavailable");
        window.openedTab = nil;
        origin.page.properties = [TestProperties new];
        origin.page.properties.url = [NSURL URLWithString:@"https://example.com/"];
        Check(Command(session, @"open-page-new-tab") != nil && window.openings == openings + 1,
              @"Safari rejection is reported without a different-window fallback");

        TestWindow *backgroundWindow = [TestWindow new];
        backgroundWindow.tabs = @[origin]; backgroundWindow.backgroundCallbacks = YES;
        OmnibarBrowserSession *backgroundSession = [[OmnibarBrowserSession alloc] initWithWindow:(id)backgroundWindow tab:(id)origin];
        Check(Load(backgroundSession, &error).count == 1 && !error, @"background Safari callbacks produce main-thread snapshots");
        Check(!Command(backgroundSession, @"reload-tab"), @"background Safari callbacks produce main-thread actions");
        [backgroundSession invalidate];

        origin.deferPage = YES;
        __block NSUInteger completions = 0;
        NSUInteger closes = origin.closes;
        [session performCommandWithIdentifier:@"close-tab" completion:^(NSError *failure) { Check(failure != nil, @"invalidated action reports cancellation"); completions++; }];
        Check(origin.pageReply != nil, @"pending native action has not yet executed");
        [session invalidate];
        origin.pageReply(origin.page);
        Check(completions == 1 && origin.closes == closes, @"closing the palette prevents a pending tab close");
        Check(Load(session, &error).count == 0 && error, @"invalidated sessions cannot list tabs");

        OmnibarBrowserSession *timedSession = [[OmnibarBrowserSession alloc] initWithWindow:(id)window tab:(id)origin];
        completions = 0;
        [timedSession performCommandWithIdentifier:@"close-tab" completion:^(NSError *failure) { Check(failure != nil, @"timed-out action returns an error"); completions++; }];
        Wait(^BOOL { return completions == 1; }, 3.5);
        origin.pageReply(origin.page);
        Check(completions == 1 && origin.closes == closes, @"late Safari metadata after timeout cannot perform the action");
        [timedSession invalidate];

        OmnibarBrowserSession *unavailable = [[OmnibarBrowserSession alloc] initWithWindow:(id)[NSObject new] tab:(id)origin];
        Check(Load(unavailable, &error).count == 0 && error, @"unsupported window objects fail gracefully");
        [unavailable invalidate];
        printf("All %lu native browser-session checks passed. Safari objects were simulated.\n", (unsigned long)checks);
    }
    return 0;
}
