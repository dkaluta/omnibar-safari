#import "SafariWebExtensionHandler.h"
#import "OmnibarMobileSettings.h"

@interface SafariWebExtensionHandler ()
@property (strong) OmnibarSearchSettings *settings;
@end
@implementation SafariWebExtensionHandler
- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings {
    if ((self = [super init])) _settings = settings;
    return self;
}
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    id item = context.inputItems.firstObject;
    id message = [item isKindOfClass:NSExtensionItem.class] ? [item userInfo][SFExtensionMessageKey] : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSExtensionItem *reply = [NSExtensionItem new];
        reply.userInfo = @{SFExtensionMessageKey: [self responseForMessage:message]};
        [context completeRequestReturningItems:@[reply] completionHandler:nil];
    });
}
- (NSDictionary *)responseForMessage:(id)message {
    if (![message isKindOfClass:NSDictionary.class] || ![message[@"type"] isKindOfClass:NSString.class])
        return @{@"error": @"Omnibar received an invalid request."};
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"openSettings"]) {
        if ([message count] != 1) return @{@"error": @"Omnibar received an invalid settings request."};
        // Safari's iOS extension point has no documented containing-app launch
        // contract. Never use private responder-chain launch workarounds.
        return @{@"error": @"Open Omnibar from the Home Screen to change search settings."};
    }
    if (![@[@"settings", @"resolve", @"dismissPaletteTips"] containsObject:type])
        return @{@"error": @"This Omnibar request is not supported."};
    NSError *configurationError = nil;
    OmnibarSearchSettings *settings = self.settings ?: OmnibarMobileSearchSettings(&configurationError);
    if (!settings || configurationError || settings.sharedConfigurationError)
        return @{@"error": @"Omnibar’s local settings are unavailable. Open the Omnibar app and try again."};
    if ([type isEqualToString:@"settings"]) {
        if ([message count] != 1) return @{@"error": @"Omnibar received an invalid settings request."};
        NSMutableArray *engines = [NSMutableArray new];
        for (NSDictionary *engine in settings.searchEngines)
            [engines addObject:@{@"id": engine[@"id"], @"name": engine[@"name"]}];
        return @{@"engines": engines, @"selectedEngineID": settings.selectedEngineID,
            @"defaultURLSuffix": settings.defaultURLSuffix, @"showPaletteTips": @(settings.showPaletteTips), @"migrationPending": @NO};
    }
    if ([type isEqualToString:@"dismissPaletteTips"]) {
        if ([message count] != 1) return @{@"error": @"Omnibar received an invalid tips request."};
        settings.showPaletteTips = NO;
        return @{@"showPaletteTips": @NO};
    }
    id input = message[@"input"], engineID = message[@"engineID"], privateBrowsing = message[@"privateBrowsing"];
    if ([message count] != 4 || ![input isKindOfClass:NSString.class] || ![input length] || [input length] > 16384
        || ![engineID isKindOfClass:NSString.class] || ![engineID length] || [engineID length] > 256
        || ![privateBrowsing isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)privateBrowsing) != CFBooleanGetTypeID())
        return @{@"error": @"Enter an address or search and choose an available search engine."};
    NSError *error = nil;
    NSURL *URL = [settings URLForInput:input searchEngine:engineID privateBrowsing:[privateBrowsing boolValue] error:&error];
    if (URL) return @{@"url": URL.absoluteString};
    BOOL ownError = [@[@"com.dkaluta.omnibar.settings", @"com.omnibar.URLResolver"] containsObject:error.domain ?: @""];
    return @{@"error": ownError && error.localizedDescription.length ? error.localizedDescription
        : @"Omnibar could not open this address or search. Check your input and search settings."};
}
@end
