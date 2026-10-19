#import "OmnibarBrowserSession.h"

static NSError *OMBrowserError(NSString *message) {
    return [NSError errorWithDomain:@"com.dkaluta.omnibar.browser-session" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void OMOnMain(dispatch_block_t work) {
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

@interface OmnibarBrowserSession ()
@property (nonatomic, strong, nullable) SFSafariWindow *window;
@property (nonatomic, strong, nullable) SFSafariTab *origin;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SFSafariTab *> *tabsByIdentifier;
@property (nonatomic, strong, nullable) NSNumber *privateBrowsing;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL valid;
@end

@implementation OmnibarBrowserSession

- (instancetype)initWithWindow:(SFSafariWindow *)window tab:(SFSafariTab *)tab {
    if ((self = [super init])) {
        _window = window;
        _origin = tab;
        _tabsByIdentifier = [NSMutableDictionary new];
        _valid = window != nil && tab != nil;
    }
    return self;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)commands {
    return @[
        @{@"id": @"open-page-new-tab", @"title": @"Open Page in New Tab", @"subtitle": @"Open this page’s address again", @"keywords": @"duplicate copy current page", @"symbol": @"square.on.square"},
        @{@"id": @"reload-tab", @"title": @"Reload Tab", @"subtitle": @"Reload the tab that opened Omnibar", @"keywords": @"refresh reload page", @"symbol": @"arrow.clockwise"},
        @{@"id": @"close-tab", @"title": @"Close Tab", @"subtitle": @"Close the tab that opened Omnibar", @"keywords": @"close current tab", @"symbol": @"xmark"},
    ];
}

- (void)invalidate {
    OMOnMain(^{
        self.valid = NO;
        self.generation++;
        self.window = nil;
        self.origin = nil;
        self.privateBrowsing = nil;
        [self.tabsByIdentifier removeAllObjects];
    });
}

- (BOOL)isCurrent:(NSUInteger)generation {
    return self.valid && self.generation == generation;
}

- (void)propertiesForTab:(SFSafariTab *)tab completion:(void (^)(SFSafariPage * _Nullable, SFSafariPageProperties * _Nullable))completion {
    if (![tab respondsToSelector:@selector(getActivePageWithCompletionHandler:)]) { completion(nil, nil); return; }
    [tab getActivePageWithCompletionHandler:^(SFSafariPage *page) {
        OMOnMain(^{
            if (![page respondsToSelector:@selector(getPagePropertiesWithCompletionHandler:)]) { completion(page, nil); return; }
            [page getPagePropertiesWithCompletionHandler:^(SFSafariPageProperties *properties) {
                OMOnMain(^{ completion(page, properties); });
            }];
        });
    }];
}

- (void)loadTabsWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, id> *> *, NSError * _Nullable))completion {
    OMOnMain(^{
        if (!self.valid) { completion(@[], OMBrowserError(@"Open Omnibar again to reconnect to this window.")); return; }
        NSUInteger generation = self.generation;
        __block BOOL finished = NO;
        __block NSMutableArray<NSMutableDictionary *> *rows;
        void (^finish)(NSError *) = ^(NSError *error) {
            if (finished) return;
            finished = YES;
            if (![self isCurrent:generation]) { completion(@[], OMBrowserError(@"This Omnibar session has closed.")); return; }
            NSMutableArray *safeRows = [NSMutableArray new];
            for (NSDictionary *row in rows) {
                if (self.tabsByIdentifier[row[@"id"]]) [safeRows addObject:row.copy];
            }
            completion(safeRows.copy, error);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            // A page without extension access may not provide metadata. Its
            // same-window tab remains selectable by its position.
            finish(rows ? nil : OMBrowserError(@"Safari could not list this window’s tabs. Try opening Omnibar again."));
        });
        if (![self.window respondsToSelector:@selector(getAllTabsWithCompletionHandler:)]) {
            finish(OMBrowserError(@"This Safari window cannot provide its tab list.")); return;
        }
        [self.window getAllTabsWithCompletionHandler:^(NSArray<SFSafariTab *> *tabs) {
            OMOnMain(^{
                if (finished) return;
                if (![self isCurrent:generation]) { finish(nil); return; }
                if (![tabs isKindOfClass:NSArray.class] || ![tabs containsObject:self.origin]) {
                    finish(OMBrowserError(@"The tab that opened Omnibar has closed or moved. Open Omnibar again.")); return;
                }
                NSDictionary *previous = self.tabsByIdentifier.copy;
                [self.tabsByIdentifier removeAllObjects];
                rows = [NSMutableArray new];
                for (NSUInteger index = 0; index < tabs.count; index++) {
                    SFSafariTab *tab = tabs[index];
                    NSString *identifier;
                    for (NSString *candidate in previous) if ([previous[candidate] isEqual:tab]) { identifier = candidate; break; }
                    if (!identifier) identifier = NSUUID.UUID.UUIDString;
                    self.tabsByIdentifier[identifier] = tab;
                    [rows addObject:[@{@"id": identifier, @"title": [NSString stringWithFormat:@"Tab %lu", (unsigned long)index + 1],
                        @"subtitle": @"Page details unavailable", @"current": @([tab isEqual:self.origin]), @"index": @(index)} mutableCopy]];
                }
                [self propertiesForTab:self.origin completion:^(SFSafariPage *page, SFSafariPageProperties *originProperties) {
                    if (finished) return;
                    if (![self isCurrent:generation]) { finish(nil); return; }
                    if (originProperties && self.privateBrowsing && originProperties.usesPrivateBrowsing != self.privateBrowsing.boolValue) {
                        [self.tabsByIdentifier removeAllObjects];
                        finish(OMBrowserError(@"The original tab’s browsing context has changed. Open Omnibar again.")); return;
                    }
                    if (originProperties && !self.privateBrowsing) self.privateBrowsing = @(originProperties.usesPrivateBrowsing);
                    __block NSUInteger remaining = tabs.count;
                    void (^received)(NSUInteger, SFSafariPageProperties *) = ^(NSUInteger index, SFSafariPageProperties *properties) {
                        if (finished) return;
                        if (![self isCurrent:generation]) { finish(nil); return; }
                        NSMutableDictionary *row = rows[index];
                        if (properties && self.privateBrowsing && properties.usesPrivateBrowsing != self.privateBrowsing.boolValue) {
                            [self.tabsByIdentifier removeObjectForKey:row[@"id"]];
                        } else if (properties) {
                            NSString *host = properties.url.host;
                            if (properties.title.length) row[@"title"] = properties.title;
                            else if (host.length) row[@"title"] = host;
                            row[@"subtitle"] = host.length ? host : @"Safari page";
                        }
                        if (--remaining == 0) finish(nil);
                    };
                    for (NSUInteger index = 0; index < tabs.count; index++) {
                        if ([tabs[index] isEqual:self.origin]) received(index, originProperties);
                        else [self propertiesForTab:tabs[index] completion:^(SFSafariPage *otherPage, SFSafariPageProperties *properties) { received(index, properties); }];
                    }
                }];
            });
        }];
    });
}

- (void)executeOnTab:(SFSafariTab *)target action:(void (^)(SFSafariTab *, SFSafariPage * _Nullable, SFSafariPageProperties * _Nullable, void (^)(NSError * _Nullable)))action completion:(void (^)(NSError * _Nullable))completion {
    OMOnMain(^{
        if (!self.valid || !target) { completion(OMBrowserError(@"Open Omnibar again to reconnect to this tab.")); return; }
        NSUInteger generation = self.generation;
        __block BOOL finished = NO;
        void (^finish)(NSError *) = ^(NSError *error) {
            if (finished) return;
            finished = YES;
            completion([self isCurrent:generation] ? error : OMBrowserError(@"This Omnibar session has closed."));
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            finish(OMBrowserError(@"Safari did not confirm this action. Check the tab before trying again."));
        });
        if (![self.window respondsToSelector:@selector(getAllTabsWithCompletionHandler:)]) {
            finish(OMBrowserError(@"Safari could not verify this tab’s window.")); return;
        }
        [self.window getAllTabsWithCompletionHandler:^(NSArray<SFSafariTab *> *tabs) {
            OMOnMain(^{
                if (finished) return;
                if (![self isCurrent:generation]) { finish(nil); return; }
                if (![tabs isKindOfClass:NSArray.class] || ![tabs containsObject:self.origin] || ![tabs containsObject:target]) {
                    finish(OMBrowserError(@"This tab has closed or moved to another window. Open Omnibar again.")); return;
                }
                [self propertiesForTab:target completion:^(SFSafariPage *page, SFSafariPageProperties *properties) {
                    if (finished) return;
                    if (![self isCurrent:generation]) { finish(nil); return; }
                    if (properties && self.privateBrowsing && properties.usesPrivateBrowsing != self.privateBrowsing.boolValue) {
                        finish(OMBrowserError(@"This tab is in a different browsing context. Open Omnibar again.")); return;
                    }
                    if (properties && !self.privateBrowsing && [target isEqual:self.origin]) self.privateBrowsing = @(properties.usesPrivateBrowsing);
                    // Metadata callbacks may take time. Recheck membership
                    // immediately before any mutation, including after a tab
                    // has moved while its properties were loading.
                    [self.window getAllTabsWithCompletionHandler:^(NSArray<SFSafariTab *> *latestTabs) {
                        OMOnMain(^{
                            if (finished) return;
                            if (![self isCurrent:generation]) { finish(nil); return; }
                            if (![latestTabs isKindOfClass:NSArray.class] || ![latestTabs containsObject:self.origin] || ![latestTabs containsObject:target]) {
                                finish(OMBrowserError(@"This tab has closed or moved to another window. Open Omnibar again.")); return;
                            }
                            action(target, page, properties, ^(NSError *error) { OMOnMain(^{ finish(error); }); });
                        });
                    }];
                }];
            });
        }];
    });
}

- (void)activateTabWithIdentifier:(NSString *)identifier completion:(void (^)(NSError * _Nullable))completion {
    OMOnMain(^{
        SFSafariTab *target = self.tabsByIdentifier[identifier];
        [self executeOnTab:target action:^(SFSafariTab *tab, SFSafariPage *page, SFSafariPageProperties *properties, void (^finish)(NSError *)) {
            if (![tab respondsToSelector:@selector(activateWithCompletionHandler:)]) { finish(OMBrowserError(@"Safari could not switch to this tab.")); return; }
            [tab activateWithCompletionHandler:^{ finish(nil); }];
        } completion:completion];
    });
}

- (void)performCommandWithIdentifier:(NSString *)identifier completion:(void (^)(NSError * _Nullable))completion {
    OMOnMain(^{
        if (![[self.commands valueForKey:@"id"] containsObject:identifier]) {
            completion(OMBrowserError(@"This command is not supported by Safari’s native extension API.")); return;
        }
        [self executeOnTab:self.origin action:^(SFSafariTab *tab, SFSafariPage *page, SFSafariPageProperties *properties, void (^finish)(NSError *)) {
            if ([identifier isEqualToString:@"close-tab"]) {
                if (![tab respondsToSelector:@selector(close)]) { finish(OMBrowserError(@"Safari could not close this tab.")); return; }
                [tab close]; finish(nil); return;
            }
            if ([identifier isEqualToString:@"reload-tab"]) {
                if (![page respondsToSelector:@selector(reload)]) { finish(OMBrowserError(@"Safari could not reload this page.")); return; }
                [page reload]; finish(nil); return;
            }
            NSURL *URL = properties.url;
            NSString *scheme = URL.scheme.lowercaseString;
            if (!URL.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) || URL.user || URL.password) {
                finish(OMBrowserError(@"Safari could not provide a website address to open again. Check website access for Omnibar.")); return;
            }
            [self openURL:URL completion:finish];
        } completion:completion];
    });
}

- (void)openURL:(NSURL *)URL completion:(void (^)(NSError * _Nullable))completion {
    if (![self.window respondsToSelector:@selector(openTabWithURL:makeActiveIfPossible:completionHandler:)]) {
        completion(OMBrowserError(@"Safari could not open a tab in this window.")); return;
    }
    [self.window openTabWithURL:URL makeActiveIfPossible:YES completionHandler:^(SFSafariTab *tab) {
        OMOnMain(^{ completion(tab ? nil : OMBrowserError(@"Safari could not open this page in a new tab.")); });
    }];
}

@end
