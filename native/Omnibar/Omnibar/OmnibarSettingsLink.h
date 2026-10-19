#import <Foundation/Foundation.h>

// A settings link contains no user input or preference values. Each build has
// its own scheme so development builds cannot open a production installation.
NS_INLINE NSURL * _Nullable OmnibarSettingsURL(NSString * _Nullable identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return nil;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    if ([identifier rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    NSURL *URL = [NSURL URLWithString:[identifier stringByAppendingString:@"://settings"]];
    return URL.scheme.length && [URL.host isEqualToString:@"settings"] ? URL : nil;
}

NS_INLINE BOOL OmnibarIsSettingsURL(NSURL * _Nullable URL, NSString * _Nullable identifier) {
    NSURL *expected = OmnibarSettingsURL(identifier);
    return expected && [URL.absoluteString isEqualToString:expected.absoluteString];
}

NS_INLINE NSURL * _Nullable OmnibarSettingsApplicationURL(NSBundle * _Nullable extension) {
    NSString *identifier = extension.infoDictionary[@"OmnibarContainingAppIdentifier"];
    if (!OmnibarSettingsURL(identifier)
        || ![extension.bundleIdentifier isEqualToString:[identifier stringByAppendingString:@".Commands"]]) return nil;
    NSURL *URL = extension.bundleURL.URLByStandardizingPath.URLByResolvingSymlinksInPath;
    if (![URL.pathExtension isEqualToString:@"appex"]) return nil;
    URL = URL.URLByDeletingLastPathComponent;
    if (![URL.lastPathComponent isEqualToString:@"PlugIns"]) return nil;
    URL = URL.URLByDeletingLastPathComponent;
    if (![URL.lastPathComponent isEqualToString:@"Contents"]) return nil;
    URL = URL.URLByDeletingLastPathComponent;
    if (![URL.pathExtension isEqualToString:@"app"]) return nil;

    // A Safari extension can read its own signed bundle, but its sandbox can
    // deny even Info.plist in the containing app. NSBundle then returns nil
    // for a valid parent. Use the signed extension's app identifier and exact
    // .app/Contents/PlugIns/.appex ancestry in that specific permission case.
    // The launch still targets only this parent URL, never a global app lookup.
    NSURL *infoURL = [URL URLByAppendingPathComponent:@"Contents/Info.plist"];
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:infoURL options:0 error:&readError];
    if (!data) {
        return [readError.domain isEqualToString:NSCocoaErrorDomain]
            && readError.code == NSFileReadNoPermissionError ? URL : nil;
    }
    id info = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![info isKindOfClass:NSDictionary.class]
        || ![info[@"CFBundleIdentifier"] isEqual:identifier]
        || ![info[@"CFBundlePackageType"] isEqual:@"APPL"]) return nil;
    return URL;
}
