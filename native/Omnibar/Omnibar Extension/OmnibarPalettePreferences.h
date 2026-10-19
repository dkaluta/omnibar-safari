#import <Foundation/Foundation.h>

// This device-only preference is shared with the containing app. It is never
// written through browser storage or iCloud, and contains no palette activity.
NS_INLINE BOOL OmnibarShouldShowPaletteTips(NSUserDefaults *defaults) {
    id value = [defaults objectForKey:@"showPaletteTips"];
    return ![value isKindOfClass:NSNumber.class] || [value boolValue];
}

NS_INLINE void OmnibarSetShowPaletteTips(NSUserDefaults *defaults, BOOL show) {
    [defaults setObject:@(show) forKey:@"showPaletteTips"];
}
