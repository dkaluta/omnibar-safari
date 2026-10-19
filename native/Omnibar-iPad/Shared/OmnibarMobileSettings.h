#import <Foundation/Foundation.h>
#import "OmnibarSearchSettings.h"

NS_ASSUME_NONNULL_BEGIN
// iPad has no legacy macOS preference domain to import. Only explicit local
// settings and the optional shared Keychain credential are used.
FOUNDATION_EXPORT OmnibarSearchSettings * _Nullable OmnibarMobileSearchSettings(NSError **error);
FOUNDATION_EXPORT BOOL OmnibarMobileAcceptsSettingsURL(NSURL *URL, NSString *appIdentifier);
NS_ASSUME_NONNULL_END
