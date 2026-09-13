#import "SafariExtensionHandler.h"
#import "AddressPopoverController.h"

@implementation SafariExtensionHandler

- (SFSafariExtensionViewController *)popoverViewController {
    return [AddressPopoverController sharedController];
}

- (void)popoverWillShowInWindow:(SFSafariWindow *)window {
    [[AddressPopoverController sharedController] prepareForWindow:window];
}

- (void)popoverDidCloseInWindow:(SFSafariWindow *)window {
    [[AddressPopoverController sharedController] clearSession];
}

- (void)validateToolbarItemInWindow:(SFSafariWindow *)window
                validationHandler:(void (^)(BOOL enabled, NSString *badgeText))validationHandler {
    // Keep navigation available on Start Page and on pages without URL access.
    validationHandler(YES, nil);
}

@end
