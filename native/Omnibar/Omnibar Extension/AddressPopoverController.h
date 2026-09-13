#import <SafariServices/SafariServices.h>

NS_ASSUME_NONNULL_BEGIN

@interface AddressPopoverController : SFSafariExtensionViewController

+ (instancetype)sharedController;
- (void)prepareForWindow:(SFSafariWindow *)window;
- (void)clearSession;

@end

NS_ASSUME_NONNULL_END
