#import <SafariServices/SafariServices.h>

NS_ASSUME_NONNULL_BEGIN

// One native palette session. All tab references and metadata live only in
// memory and are released on invalidation; no browser-global lookup is used.
@interface OmnibarBrowserSession : NSObject
- (instancetype)initWithWindow:(SFSafariWindow *)window tab:(SFSafariTab *)tab;
// Each command has id, title, subtitle, keywords, and an SF Symbol name.
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *commands;
// Rows have id (session-only), title, subtitle (host only), current, and index.
// UI updates and all action completions arrive on the main queue.
- (void)loadTabsWithCompletion:(void (^)(NSArray<NSDictionary<NSString *, id> *> *tabs, NSError * _Nullable error))completion;
- (void)activateTabWithIdentifier:(NSString *)identifier completion:(void (^)(NSError * _Nullable error))completion;
- (void)performCommandWithIdentifier:(NSString *)identifier completion:(void (^)(NSError * _Nullable error))completion;
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END
