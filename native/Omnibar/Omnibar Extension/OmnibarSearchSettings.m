#import "OmnibarSearchSettings.h"
#import "OmnibarURLResolver.h"
#import <Security/Security.h>

static NSString * const SelectedEngineKey = @"searchEngine";
static NSString * const CustomEnginesKey = @"customSearchEngines";
static NSString * const EngineOrderKey = @"searchEngineOrder";
static NSString * const RemovedDefaultEngineIDsKey = @"removedDefaultSearchEngineIDs";

static void SettingsError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.dkaluta.omnibar.settings" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation OmnibarKeychainStore

- (NSMutableDictionary *)query {
    // A local generic-password item, scoped to this extension by the Keychain's
    // default code-signing ACL. No shared access group or iCloud synchronization.
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: @"com.dkaluta.omnibar.Extension.kagi",
              (__bridge id)kSecAttrAccount: @"private-session-url"} mutableCopy];
}

- (BOOL)checkStatus:(OSStatus)status error:(NSError **)error {
    if (status == errSecSuccess) return YES;
    // Do not include Keychain data, the session URL, or raw provider errors.
    SettingsError(error, @"Omnibar couldn’t access the saved private link. Unlock your Keychain and try again.");
    return NO;
}

- (BOOL)hasPrivateKagiURLWithError:(NSError **)error {
    if (error) *error = nil;
    NSMutableDictionary *query = [self query];
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    query[(__bridge id)kSecReturnAttributes] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (result) CFRelease(result);
    if (status == errSecItemNotFound) return NO;
    return [self checkStatus:status error:error];
}

- (NSString *)privateKagiURLWithError:(NSError **)error {
    if (error) *error = nil;
    NSMutableDictionary *query = [self query];
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = CFBridgingRelease(result);
    if (status == errSecItemNotFound) return nil;
    if (![self checkStatus:status error:error]) return nil;
    NSString *URL = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!URL.length) SettingsError(error, @"The saved private link could not be read. Save it again in Search Settings.");
    return URL.length ? URL : nil;
}

- (BOOL)setPrivateKagiURL:(NSString *)URL error:(NSError **)error {
    if (error) *error = nil;
    NSMutableDictionary *query = [self query];
    if (!URL) {
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        return status == errSecItemNotFound || [self checkStatus:status error:error];
    }
    NSDictionary *value = @{(__bridge id)kSecValueData: [URL dataUsingEncoding:NSUTF8StringEncoding]};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)value);
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:value];
        query[(__bridge id)kSecAttrLabel] = @"Omnibar — Kagi private session link";
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    return [self checkStatus:status error:error];
}

@end

@interface OmnibarSearchSettings ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) id<OmnibarCredentialStoring> credentialStore;
@end

@implementation OmnibarSearchSettings

+ (instancetype)sharedSettings {
    static OmnibarSearchSettings *settings;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        settings = [[self alloc] initWithDefaults:NSUserDefaults.standardUserDefaults credentialStore:[OmnibarKeychainStore new]];
    });
    return settings;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults credentialStore:(id<OmnibarCredentialStoring>)credentialStore {
    if ((self = [super init])) {
        _defaults = defaults;
        _credentialStore = credentialStore;
    }
    return self;
}

- (BOOL)validName:(id)name {
    return [name isKindOfClass:NSString.class] && [name length] > 0 && [name length] <= 80
        && [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)customSearchEngines {
    id saved = [self.defaults objectForKey:CustomEnginesKey];
    if (![saved isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *engines = [NSMutableArray new];
    NSMutableSet *identifiers = [NSMutableSet new];
    for (id entry in saved) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        id identifier = entry[@"id"], name = entry[@"name"], URLTemplate = entry[@"template"];
        if (![identifier isKindOfClass:NSString.class] || ![identifier hasPrefix:@"custom:"]
            || [identifiers containsObject:identifier] || ![self validName:name]
            || ![URLTemplate isKindOfClass:NSString.class]) continue;
        NSString *validated = [OmnibarURLResolver validatedSearchTemplate:URLTemplate error:NULL];
        if (!validated) continue;
        [engines addObject:@{@"id": identifier, @"name": name, @"template": validated}];
        [identifiers addObject:identifier];
    }
    return engines;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)availableSearchEngines {
    NSArray *catalog = OmnibarURLResolver.searchEngines;
    NSArray *catalogIDs = [catalog valueForKey:@"id"];
    id storedRemoved = [self.defaults objectForKey:RemovedDefaultEngineIDsKey];
    NSMutableArray *removed = [NSMutableArray new];
    if ([storedRemoved isKindOfClass:NSArray.class]) {
        for (id identifier in storedRemoved) {
            if ([identifier isKindOfClass:NSString.class] && [catalogIDs containsObject:identifier]
                && ![removed containsObject:identifier]) [removed addObject:identifier];
        }
    }
    NSMutableArray *available = [NSMutableArray new];
    for (NSDictionary *engine in catalog) {
        if (![removed containsObject:engine[@"id"]]) [available addObject:engine];
    }
    [available addObjectsFromArray:self.customSearchEngines];
    // Normal removals retain an engine. Recover just one regional default if
    // corrupt preferences otherwise leave no usable engine at all.
    if (!available.count && catalog.count) {
        NSDictionary *fallback = catalog.firstObject;
        [available addObject:fallback];
        [removed removeObject:fallback[@"id"]];
    }
    if (![removed isEqual:storedRemoved]) {
        [self.defaults setObject:removed forKey:RemovedDefaultEngineIDsKey];
    }
    return available;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)searchEngines {
    NSArray *available = [self availableSearchEngines];
    id storedOrder = [self.defaults objectForKey:EngineOrderKey];
    NSArray *order = [storedOrder isKindOfClass:NSArray.class] ? storedOrder : @[];
    // Preserve the preferred engine from versions that predate reordering.
    if (!storedOrder) {
        id legacy = [self.defaults objectForKey:SelectedEngineKey];
        if ([legacy isKindOfClass:NSString.class]) order = @[legacy];
    }
    NSMutableArray *ordered = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (id identifier in order) {
        if (![identifier isKindOfClass:NSString.class] || [seen containsObject:identifier]) continue;
        for (NSDictionary *engine in available) {
            if ([engine[@"id"] isEqualToString:identifier]) {
                [ordered addObject:engine];
                [seen addObject:identifier];
                break;
            }
        }
    }
    for (NSDictionary *engine in available) {
        if (![seen containsObject:engine[@"id"]]) [ordered addObject:engine];
    }
    // Freeze the initial regional order and append newly available engines once.
    // A later region change must never move the user's default or saved order.
    NSArray *normalizedOrder = [ordered valueForKey:@"id"];
    if (![normalizedOrder isEqual:storedOrder]) {
        [self.defaults setObject:normalizedOrder forKey:EngineOrderKey];
    }
    return ordered;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)removedDefaultSearchEngines {
    NSArray *activeIDs = [self.searchEngines valueForKey:@"id"];
    NSMutableArray *removed = [NSMutableArray new];
    for (NSDictionary *engine in OmnibarURLResolver.searchEngines) {
        if (![activeIDs containsObject:engine[@"id"]]) [removed addObject:engine];
    }
    return removed;
}

- (NSDictionary *)engineWithIdentifier:(NSString *)identifier {
    for (NSDictionary *engine in self.searchEngines) {
        if ([engine[@"id"] isEqualToString:identifier]) return engine;
    }
    return nil;
}

- (NSString *)selectedEngineID {
    return self.searchEngines.firstObject[@"id"] ?: @"duckduckgo";
}

- (void)setSelectedEngineID:(NSString *)identifier {
    [self moveEngineWithIdentifier:identifier toIndex:0];
}

- (void)moveEngineWithIdentifier:(NSString *)identifier toIndex:(NSUInteger)index {
    NSMutableArray *order = [[self.searchEngines valueForKey:@"id"] mutableCopy];
    if (![order containsObject:identifier]) return;
    [order removeObject:identifier];
    [order insertObject:identifier atIndex:MIN(index, order.count)];
    [self.defaults setObject:order forKey:EngineOrderKey];
    [self.defaults setObject:order.firstObject forKey:SelectedEngineKey];
}

- (NSDictionary *)saveCustomEngine:(NSString *)identifier name:(NSString *)name template:(NSString *)URLTemplate error:(NSError **)error {
    if (error) *error = nil;
    NSString *trimmedName = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![self validName:trimmedName]) {
        SettingsError(error, @"Enter a search engine name of 1–80 characters on one line.");
        return nil;
    }
    NSString *validated = [OmnibarURLResolver validatedSearchTemplate:URLTemplate error:error];
    if (!validated) return nil;
    NSMutableArray *engines = self.customSearchEngines.mutableCopy;
    NSUInteger index = NSNotFound;
    // Reserve all catalog names, including engines the user has removed, so
    // restoring a default never introduces a duplicate custom engine name.
    for (NSDictionary *engine in [OmnibarURLResolver.searchEngines arrayByAddingObjectsFromArray:engines]) {
        if ([engine[@"id"] isEqualToString:identifier]) continue;
        if ([engine[@"name"] caseInsensitiveCompare:trimmedName] == NSOrderedSame) {
            SettingsError(error, @"An engine with that name already exists. Choose another name.");
            return nil;
        }
    }
    if (identifier) {
        index = [engines indexOfObjectPassingTest:^BOOL(NSDictionary *engine, NSUInteger position, BOOL *stop) {
            return [engine[@"id"] isEqualToString:identifier];
        }];
        if (index == NSNotFound) {
            SettingsError(error, @"That custom engine is no longer available. Add it again.");
            return nil;
        }
    }
    NSDictionary *engine = @{@"id": identifier ?: [@"custom:" stringByAppendingString:NSUUID.UUID.UUIDString],
                             @"name": trimmedName, @"template": validated};
    if (index == NSNotFound) [engines addObject:engine];
    else engines[index] = engine;
    [self.defaults setObject:engines forKey:CustomEnginesKey];
    return engine;
}

- (void)removeCustomEngineWithIdentifier:(NSString *)identifier {
    if ([identifier hasPrefix:@"custom:"]) [self removeEngineWithIdentifier:identifier];
}

- (void)removeEngineWithIdentifier:(NSString *)identifier {
    NSMutableArray *order = [[self.searchEngines valueForKey:@"id"] mutableCopy];
    if (order.count <= 1 || ![order containsObject:identifier]) return;
    if ([[OmnibarURLResolver.searchEngines valueForKey:@"id"] containsObject:identifier]) {
        NSMutableArray *removed = [[self.defaults objectForKey:RemovedDefaultEngineIDsKey] mutableCopy];
        [removed addObject:identifier];
        [self.defaults setObject:removed forKey:RemovedDefaultEngineIDsKey];
    } else {
        NSMutableArray *custom = self.customSearchEngines.mutableCopy;
        NSIndexSet *matches = [custom indexesOfObjectsPassingTest:^BOOL(NSDictionary *engine, NSUInteger position, BOOL *stop) {
            return [engine[@"id"] isEqualToString:identifier];
        }];
        [custom removeObjectsAtIndexes:matches];
        [self.defaults setObject:custom forKey:CustomEnginesKey];
    }
    [order removeObject:identifier];
    [self.defaults setObject:order forKey:EngineOrderKey];
    [self.defaults setObject:order.firstObject forKey:SelectedEngineKey];
}

- (void)restoreDefaultEngineWithIdentifier:(NSString *)identifier {
    if (![[OmnibarURLResolver.searchEngines valueForKey:@"id"] containsObject:identifier]) return;
    NSMutableArray *order = [[self.searchEngines valueForKey:@"id"] mutableCopy];
    if ([order containsObject:identifier]) return;
    NSMutableArray *removed = [[self.defaults objectForKey:RemovedDefaultEngineIDsKey] mutableCopy];
    [removed removeObject:identifier];
    [self.defaults setObject:removed forKey:RemovedDefaultEngineIDsKey];
    [order addObject:identifier];
    [self.defaults setObject:order forKey:EngineOrderKey];
    [self.defaults setObject:order.firstObject forKey:SelectedEngineKey];
}

- (void)restoreDefaultSearchEngines {
    NSMutableArray *order = [[OmnibarURLResolver.searchEngines valueForKey:@"id"] mutableCopy];
    for (NSDictionary *engine in self.searchEngines) {
        if ([engine[@"id"] hasPrefix:@"custom:"]) [order addObject:engine[@"id"]];
    }
    [self.defaults setObject:@[] forKey:RemovedDefaultEngineIDsKey];
    [self.defaults setObject:order forKey:EngineOrderKey];
    [self.defaults setObject:order.firstObject forKey:SelectedEngineKey];
}

- (BOOL)saveKagiPrivateURL:(NSString *)URL error:(NSError **)error {
    NSString *validated = [OmnibarURLResolver normalizedKagiPrivateURL:URL error:error];
    return validated && [self.credentialStore setPrivateKagiURL:validated error:error];
}

- (BOOL)removeKagiPrivateURLWithError:(NSError **)error {
    return [self.credentialStore setPrivateKagiURL:nil error:error];
}

- (BOOL)hasKagiPrivateURLWithError:(NSError **)error {
    return [self.credentialStore hasPrivateKagiURLWithError:error];
}

- (NSURL *)URLForInput:(NSString *)input searchEngine:(NSString *)identifier privateBrowsing:(BOOL)privateBrowsing error:(NSError **)error {
    NSDictionary *engine = [self engineWithIdentifier:identifier];
    if (!engine) {
        SettingsError(error, @"That search engine is no longer available. Choose another engine.");
        return nil;
    }
    BOOL isSearch = NO;
    NSURL *URL = [OmnibarURLResolver URLForInput:input searchTemplate:engine[@"template"] isSearch:&isSearch error:error];
    if (!URL || !isSearch || !privateBrowsing || ![identifier isEqualToString:@"kagi"]) return URL;
    NSError *credentialError = nil;
    NSString *privateURL = [self.credentialStore privateKagiURLWithError:&credentialError];
    if (credentialError) {
        if (error) *error = credentialError;
        return nil;
    }
    if (!privateURL.length) return URL;
    NSString *validated = [OmnibarURLResolver normalizedKagiPrivateURL:privateURL error:error];
    if (!validated) return nil;
    return [OmnibarURLResolver URLForInput:input searchTemplate:validated error:error];
}

@end
