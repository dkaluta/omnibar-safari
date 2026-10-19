#import "OmnibarMobileSettings.h"

static BOOL OMResolved(id value) {
    return [value isKindOfClass:NSString.class] && [value length] && [value rangeOfString:@"$"].location == NSNotFound;
}

OmnibarSearchSettings *OmnibarMobileSearchSettings(NSError **error) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *identifier = info[@"OmnibarContainingAppIdentifier"];
    NSString *group = info[@"OmnibarSharedGroup"];
    NSString *keychain = info[@"OmnibarKeychainGroup"];
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    BOOL valid = OMResolved(identifier) && OMResolved(group) && OMResolved(keychain)
        && [group isEqualToString:[@"group." stringByAppendingString:identifier]]
        && ([bundleID isEqualToString:identifier] || [bundleID isEqualToString:[identifier stringByAppendingString:@".Commands"]])
        && [keychain hasSuffix:[@"." stringByAppendingString:[identifier stringByAppendingString:@".shared"]]];
    if (error) *error = nil;
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"com.omnibar.mobile-settings" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Omnibar’s local settings are unavailable. Reinstall the app and try again."}];
        return nil;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:group];
    return [[OmnibarSearchSettings alloc] initWithDefaults:defaults credentialStore:[OmnibarKeychainStore new]];
}

BOOL OmnibarMobileAcceptsSettingsURL(NSURL *URL, NSString *appIdentifier) {
    return OMResolved(appIdentifier) && [URL.absoluteString isEqualToString:[appIdentifier stringByAppendingString:@"://settings"]];
}
