#import <SafariServices/SafariServices.h>
@class OmnibarSearchSettings;
NS_ASSUME_NONNULL_BEGIN
@interface SafariWebExtensionHandler : NSObject <NSExtensionRequestHandling>
- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings;
- (NSDictionary *)responseForMessage:(nullable id)message;
@end
NS_ASSUME_NONNULL_END
