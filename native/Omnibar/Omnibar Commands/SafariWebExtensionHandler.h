#import <SafariServices/SafariServices.h>

@class OmnibarSearchSettings;

NS_ASSUME_NONNULL_BEGIN

@interface SafariWebExtensionHandler : NSObject <NSExtensionRequestHandling>
- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings;
// The request boundary is separate from Safari's transport for isolated tests.
- (NSDictionary *)responseForMessage:(nullable id)message;
- (void)handleMessage:(nullable id)message completion:(void (^)(NSDictionary *response))completion;
@end

NS_ASSUME_NONNULL_END
