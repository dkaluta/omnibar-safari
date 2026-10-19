#import "SafariWebExtensionHandler.h"
#import "OmnibarSearchSettings.h"
#import "../Omnibar/OmnibarSettingsLink.h"
#import "../Omnibar/OmnibarSettingsRouteDiagnostics.h"
#import <AppKit/AppKit.h>

@interface SafariWebExtensionHandler ()
@property (nonatomic, strong) OmnibarSearchSettings *settings;
@end

@implementation SafariWebExtensionHandler

- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings {
    if ((self = [super init])) _settings = settings;
    return self;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    id item = context.inputItems.firstObject;
    id message = [item isKindOfClass:NSExtensionItem.class] ? [item userInfo][SFExtensionMessageKey] : nil;
    // Keychain access may wait for the user to unlock it. Keep Safari's request
    // thread free, and never log messages or resolved navigation URLs.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self handleMessage:message completion:^(NSDictionary *response) {
            NSExtensionItem *reply = [NSExtensionItem new];
            reply.userInfo = @{SFExtensionMessageKey: response};
            [context completeRequestReturningItems:@[reply] completionHandler:nil];
        }];
    });
}

- (NSBundle *)extensionBundle { return NSBundle.mainBundle; }

- (NSWorkspaceOpenConfiguration *)settingsOpenConfiguration {
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    // Keep Safari's popup/request alive until the settings URL reaches the app.
    // The receiving settings action activates the app after displaying its UI.
    configuration.activates = NO;
    configuration.allowsRunningApplicationSubstitution = NO;
    configuration.addsToRecentItems = NO;
    return configuration;
}

- (void)openSettingsURL:(NSURL *)URL applicationURL:(NSURL *)applicationURL completion:(void (^)(BOOL))completion {
    // Use the containing bundle's path, never a caller URL or a global lookup
    // that could select a different installed build of Omnibar.
    dispatch_async(dispatch_get_main_queue(), ^{
        OmnibarTraceSettingsRoute(120); // About to call Launch Services.
        [NSWorkspace.sharedWorkspace openURLs:@[URL] withApplicationAtURL:applicationURL
            configuration:[self settingsOpenConfiguration]
            completionHandler:^(NSRunningApplication *application, NSError *error) {
                if (application != nil && error == nil) OmnibarTraceSettingsRoute(121);
                else OmnibarTraceSettingsRoute(122);
                completion(application != nil && error == nil);
            }];
    });
}

- (void)handleMessage:(id)message completion:(void (^)(NSDictionary *))completion {
    if (![message isKindOfClass:NSDictionary.class] || ![message[@"type"] isEqual:@"openSettings"]) {
        completion([self responseForMessage:message]);
        return;
    }
    if ([message count] != 1) {
        completion(@{@"error": @"Omnibar received an invalid settings request."});
        return;
    }
    OmnibarTraceSettingsRoute(100); // Exact settings request accepted.
    NSBundle *bundle = [self extensionBundle];
    NSURL *applicationURL = OmnibarSettingsApplicationURL(bundle);
    NSURL *URL = OmnibarSettingsURL(bundle.infoDictionary[@"OmnibarContainingAppIdentifier"]);
    if (!applicationURL || !URL) {
        OmnibarTraceSettingsRoute(111); // Containing app validation failed.
        completion(@{@"error": @"Omnibar could not find its settings app. Open Omnibar from Applications and choose Search Settings."});
        return;
    }
    OmnibarTraceSettingsRoute(110); // Own containing app and fixed URL validated.
    [self openSettingsURL:URL applicationURL:applicationURL completion:^(BOOL opened) {
        completion(opened ? @{@"opened": @YES}
            : @{@"error": @"Omnibar could not open Search Settings. Open Omnibar from Applications and choose Search Settings."});
    }];
}

- (NSDictionary *)responseForMessage:(id)message {
    if (![message isKindOfClass:NSDictionary.class]) return @{@"error": @"Omnibar received an invalid request."};
    NSString *type = message[@"type"];
    if (![type isKindOfClass:NSString.class]) return @{@"error": @"Omnibar received an invalid request."};
    if (![type isEqualToString:@"settings"] && ![type isEqualToString:@"resolve"]
        && ![type isEqualToString:@"dismissPaletteTips"]) {
        return @{@"error": @"This Omnibar request is not supported."};
    }
    OmnibarSearchSettings *settings = self.settings ?: OmnibarSearchSettings.sharedSettings;
    if (settings.sharedConfigurationError) return @{@"error": settings.sharedConfigurationError.localizedDescription};
    if ([type isEqualToString:@"dismissPaletteTips"]) {
        if ([message count] != 1) return @{@"error": @"Omnibar received an invalid tips request."};
        // This is the only preference mutation exposed to the web palette.
        // It accepts no query, tab, URL, key, or caller-provided preference value.
        settings.showPaletteTips = NO;
        return @{@"showPaletteTips": @(settings.showPaletteTips)};
    }
    if ([type isEqualToString:@"settings"]) {
        NSMutableArray *engines = [NSMutableArray new];
        for (NSDictionary *engine in settings.searchEngines) {
            // The palette only receives display metadata. Templates and stored
            // credentials remain native until the user submits a navigation.
            [engines addObject:@{@"id": engine[@"id"], @"name": engine[@"name"]}];
        }
        // The first engine is selected. Reuse this coherent snapshot instead
        // of rebuilding the custom-engine catalog for selectedEngineID.
        return @{@"engines": engines, @"selectedEngineID": engines.firstObject[@"id"] ?: @"duckduckgo",
                 @"migrationPending": @(settings.sharedPreferencesMigrationPending),
                 @"defaultURLSuffix": settings.defaultURLSuffix,
                 @"showPaletteTips": @(settings.showPaletteTips)};
    }
    NSString *input = message[@"input"];
    NSString *engineID = message[@"engineID"];
    id privateBrowsing = message[@"privateBrowsing"];
    if (![input isKindOfClass:NSString.class] || input.length == 0 || input.length > 16384
        || ![engineID isKindOfClass:NSString.class] || engineID.length == 0 || engineID.length > 256
        || ![privateBrowsing isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)privateBrowsing) != CFBooleanGetTypeID()) {
        return @{@"error": @"Enter an address or search and choose an available search engine."};
    }
    // Resolve once for an explicit submission. This endpoint never persists
    // input, changes preferences, or performs a network request.
    NSError *error = nil;
    NSURL *URL = [settings URLForInput:input searchEngine:engineID privateBrowsing:[privateBrowsing boolValue] error:&error];
    if (!URL) {
        // Only our own static validation text crosses the boundary. Arbitrary
        // system errors can contain URLs or credential details.
        BOOL ownError = [error.domain isEqualToString:@"com.dkaluta.omnibar.settings"]
            || [error.domain isEqualToString:@"com.omnibar.URLResolver"];
        return @{@"error": ownError && error.localizedDescription.length ? error.localizedDescription
                  : @"Omnibar could not open this address or search. Check your input and Search Settings."};
    }
    return @{@"url": URL.absoluteString};
}
@end
