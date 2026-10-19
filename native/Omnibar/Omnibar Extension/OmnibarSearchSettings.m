#import "OmnibarSearchSettings.h"
#import "OmnibarURLResolver.h"
#import "OmnibarPalettePreferences.h"
#import <Security/Security.h>

static NSString * const SelectedEngineKey = @"searchEngine";
static NSString * const CustomEnginesKey = @"customSearchEngines";
static NSString * const EngineOrderKey = @"searchEngineOrder";
static NSString * const RemovedDefaultEngineIDsKey = @"removedDefaultSearchEngineIDs";
static NSString * const DefaultURLSuffixKey = @"defaultURLSuffix";

static void SettingsError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.dkaluta.omnibar.settings" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString * const SharedPreferencesVersionKey = @"sharedSearchPreferencesVersion";

static BOOL ResolvedIdentifier(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0
        && [value rangeOfString:@"$"].location == NSNotFound;
}

@interface OmnibarKeychainStore ()
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *containingAppIdentifier;
@property (nonatomic, copy) NSString *accessGroup;
@property (nonatomic) BOOL sharedConfigurationRequested;
@property (nonatomic) BOOL validSharedConfiguration;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier info:(NSDictionary *)info;
- (NSMutableDictionary *)queryForBundleIdentifier:(NSString *)bundleIdentifier;
@end

@implementation OmnibarKeychainStore

static BOOL OmnibarOwnsSharedSettings(NSString *bundleIdentifier, NSString *appIdentifier) {
    return [bundleIdentifier isEqualToString:appIdentifier]
        || [bundleIdentifier isEqualToString:[appIdentifier stringByAppendingString:@".Extension"]]
        || [bundleIdentifier isEqualToString:[appIdentifier stringByAppendingString:@".Commands"]];
}

- (instancetype)init {
    return [self initWithBundleIdentifier:NSBundle.mainBundle.bundleIdentifier info:NSBundle.mainBundle.infoDictionary];
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier info:(NSDictionary *)info {
    if ((self = [super init])) {
        _bundleIdentifier = [bundleIdentifier copy];
        _containingAppIdentifier = [info[@"OmnibarContainingAppIdentifier"] copy];
        _accessGroup = [info[@"OmnibarKeychainGroup"] copy];
        _sharedConfigurationRequested = info[@"OmnibarKeychainGroup"] != nil || info[@"OmnibarSharedGroup"] != nil;
        _validSharedConfiguration = ResolvedIdentifier(_containingAppIdentifier) && ResolvedIdentifier(_accessGroup)
            && OmnibarOwnsSharedSettings(_bundleIdentifier, _containingAppIdentifier)
            && [_accessGroup hasSuffix:[@"." stringByAppendingString:[_containingAppIdentifier stringByAppendingString:@".shared"]]];
    }
    return self;
}

- (NSMutableDictionary *)query {
    if (!self.validSharedConfiguration) return [self queryForBundleIdentifier:self.bundleIdentifier];
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: [self.containingAppIdentifier stringByAppendingString:@".shared.kagi"],
              (__bridge id)kSecAttrAccount: @"private-session-url",
              (__bridge id)kSecAttrAccessGroup: self.accessGroup,
              (__bridge id)kSecUseDataProtectionKeychain: @YES,
              (__bridge id)kSecAttrSynchronizable: @NO} mutableCopy];
}

- (NSMutableDictionary *)queryForBundleIdentifier:(NSString *)bundleIdentifier {
    // Keep the original identity-scoped service for migration and unbundled
    // tools. Never broaden its ACL or look up another build's legacy service.
    NSString *service = [(bundleIdentifier.length ? bundleIdentifier : @"com.dkaluta.omnibar.tools")
        stringByAppendingString:@".kagi"];
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: service,
              (__bridge id)kSecAttrAccount: @"private-session-url"} mutableCopy];
}

- (NSMutableDictionary *)migrationQuery {
    NSMutableDictionary *query = [self query];
    query[(__bridge id)kSecAttrAccount] = @"legacy-migration-v1";
    return query;
}

// Narrow overridable operations let tests exercise migration entirely in memory.
- (OSStatus)copyItemMatchingQuery:(NSDictionary *)query result:(id *)result {
    CFTypeRef item = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &item);
    id value = CFBridgingRelease(item);
    if (result) *result = value;
    return status;
}
- (OSStatus)updateItemMatchingQuery:(NSDictionary *)query attributes:(NSDictionary *)attributes {
    return SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
}
- (OSStatus)addItemWithAttributes:(NSDictionary *)attributes {
    return SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
}
- (OSStatus)deleteItemMatchingQuery:(NSDictionary *)query {
    return SecItemDelete((__bridge CFDictionaryRef)query);
}

- (BOOL)checkStatus:(OSStatus)status error:(NSError **)error {
    if (status == errSecSuccess) return YES;
    SettingsError(error, @"Omnibar couldn’t access the saved private link. Unlock your Keychain and try again.");
    return NO;
}

- (BOOL)checkConfigurationWithError:(NSError **)error {
    if (!self.sharedConfigurationRequested || self.validSharedConfiguration) return YES;
    SettingsError(error, @"Omnibar’s shared private-link storage is unavailable. Reinstall the signed app and try again.");
    return NO;
}

- (OSStatus)readQuery:(NSDictionary *)query data:(NSData **)data {
    NSMutableDictionary *read = [query mutableCopy];
    read[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    read[(__bridge id)kSecReturnData] = @YES;
    id result = nil;
    OSStatus status = [self copyItemMatchingQuery:read result:&result];
    if (data) *data = [result isKindOfClass:NSData.class] ? result : nil;
    return status;
}

- (BOOL)writeData:(NSData *)data query:(NSDictionary *)query error:(NSError **)error {
    NSDictionary *value = @{(__bridge id)kSecValueData: data};
    OSStatus status = [self updateItemMatchingQuery:query attributes:value];
    if (status == errSecItemNotFound) {
        NSMutableDictionary *attributes = [query mutableCopy];
        [attributes addEntriesFromDictionary:value];
        attributes[(__bridge id)kSecAttrLabel] = @"Omnibar — Kagi private session link";
        if (self.validSharedConfiguration) attributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        status = [self addItemWithAttributes:attributes];
        // Another extension may have created the same item in the meantime.
        if (status == errSecDuplicateItem) status = [self updateItemMatchingQuery:query attributes:value];
    }
    return [self checkStatus:status error:error];
}

- (BOOL)recordMigrationWithError:(NSError **)error {
    if (!self.validSharedConfiguration) return YES;
    return [self writeData:[@"1" dataUsingEncoding:NSUTF8StringEncoding] query:[self migrationQuery] error:error];
}

- (BOOL)removeLegacyCredentialWithError:(NSError **)error {
    if (![self.bundleIdentifier isEqual:[self.containingAppIdentifier stringByAppendingString:@".Extension"]]) return YES;
    // Only the original extension may clean up its old ACL-protected item.
    // Delete directly: cleanup never reads or exposes the removed credential.
    OSStatus status = [self deleteItemMatchingQuery:[self queryForBundleIdentifier:self.bundleIdentifier]];
    return status == errSecItemNotFound || [self checkStatus:status error:error];
}

- (NSString *)privateKagiURLWithError:(NSError **)error {
    if (error) *error = nil;
    if (![self checkConfigurationWithError:error]) return nil;
    NSData *data = nil;
    OSStatus status = [self readQuery:[self query] data:&data];
    if (status != errSecSuccess && status != errSecItemNotFound) { [self checkStatus:status error:error]; return nil; }
    if (status == errSecItemNotFound && self.validSharedConfiguration) {
        OSStatus migrationStatus = [self readQuery:[self migrationQuery] data:NULL];
        if (migrationStatus == errSecSuccess) return nil;
        if (migrationStatus != errSecItemNotFound) { [self checkStatus:migrationStatus error:error]; return nil; }
        if (![self.bundleIdentifier isEqual:[self.containingAppIdentifier stringByAppendingString:@".Extension"]]) {
            // A new app/Commands installation needs no private link to search.
            // Leave migration undecided: only the original extension can import
            // its older credential later, and no marker or tombstone is saved.
            return nil;
        }
        // Only the original extension can read its original ACL-protected item.
        // Keep that item intact so a failed migration never destroys credentials.
        status = [self readQuery:[self queryForBundleIdentifier:self.bundleIdentifier] data:&data];
        if (status != errSecSuccess && status != errSecItemNotFound) { [self checkStatus:status error:error]; return nil; }
        if (status == errSecSuccess && !data.length) {
            SettingsError(error, @"The saved private link could not be read. Save it again in Search Settings.");
            return nil;
        }
        // Add-only migration never overwrites a save or removal made by the
        // companion after the initial read. Empty data is a local tombstone.
        NSMutableDictionary *attributes = [self query];
        attributes[(__bridge id)kSecValueData] = data ?: NSData.data;
        attributes[(__bridge id)kSecAttrLabel] = @"Omnibar — Kagi private session link";
        attributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        status = [self addItemWithAttributes:attributes];
        if (status == errSecDuplicateItem) status = [self readQuery:[self query] data:&data];
        if (![self checkStatus:status error:error] || ![self recordMigrationWithError:error]) return nil;
    } else if (status == errSecItemNotFound) return nil;
    if (self.validSharedConfiguration && !data.length) {
        // The app can remove the shared credential but cannot delete the old
        // extension's item. Finish that removal the next time its owner checks
        // the tombstone. Keep the tombstone even if cleanup must be retried.
        [self removeLegacyCredentialWithError:error];
        return nil;
    }
    NSString *URL = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!URL.length) SettingsError(error, @"The saved private link could not be read. Save it again in Search Settings.");
    return URL.length ? URL : nil;
}

- (BOOL)hasPrivateKagiURLWithError:(NSError **)error {
    return [self privateKagiURLWithError:error].length > 0;
}

- (BOOL)setPrivateKagiURL:(NSString *)URL error:(NSError **)error {
    if (error) *error = nil;
    if (![self checkConfigurationWithError:error]) return NO;
    if (!URL) {
        // An empty shared item contains no credential and prevents add-only
        // migration from resurrecting a link, even during a concurrent import.
        if (self.validSharedConfiguration) {
            if (![self writeData:NSData.data query:[self query] error:error] || ![self recordMigrationWithError:error]) return NO;
            return [self removeLegacyCredentialWithError:error];
        }
        OSStatus status = [self deleteItemMatchingQuery:[self query]];
        return status == errSecItemNotFound || [self checkStatus:status error:error];
    }
    if (![self writeData:[URL dataUsingEncoding:NSUTF8StringEncoding] query:[self query] error:error]) return NO;
    return [self recordMigrationWithError:error];
}

@end

// Invalid signing/configuration must not open a different preference domain.
@interface OmnibarUnavailableDefaults : NSObject
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)object forKey:(NSString *)key;
@end
@implementation OmnibarUnavailableDefaults
- (id)objectForKey:(NSString *)key { return nil; }
- (void)setObject:(id)object forKey:(NSString *)key {}
@end

@interface OmnibarSearchSettings ()
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) id<OmnibarCredentialStoring> credentialStore;
@property (nonatomic) BOOL usesSharedPreferences;
@property (nonatomic, readwrite, nullable) NSError *sharedConfigurationError;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults legacyDefaults:(NSUserDefaults *)legacyDefaults
               originalExtension:(BOOL)originalExtension credentialStore:(id<OmnibarCredentialStoring>)credentialStore;
@end

@implementation OmnibarSearchSettings

+ (instancetype)sharedSettings {
    static OmnibarSearchSettings *settings;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSString *group = info[@"OmnibarSharedGroup"];
        NSString *appIdentifier = info[@"OmnibarContainingAppIdentifier"];
        OmnibarKeychainStore *credentialStore = [OmnibarKeychainStore new];
        BOOL requested = info[@"OmnibarSharedGroup"] != nil || info[@"OmnibarKeychainGroup"] != nil;
        BOOL shared = ResolvedIdentifier(group) && ResolvedIdentifier(appIdentifier)
            && [group isEqual:[@"group." stringByAppendingString:appIdentifier]]
            && OmnibarOwnsSharedSettings(NSBundle.mainBundle.bundleIdentifier, appIdentifier)
            && credentialStore.validSharedConfiguration;
        NSUserDefaults *defaults = shared ? [[NSUserDefaults alloc] initWithSuiteName:group] : NSUserDefaults.standardUserDefaults;
        if (requested && !shared) {
            settings = [[self alloc] initWithDefaults:(id)[OmnibarUnavailableDefaults new] credentialStore:credentialStore];
            NSError *error = nil;
            SettingsError(&error, @"Omnibar’s shared search settings are unavailable. Reinstall the signed app and try again.");
            settings.sharedConfigurationError = error;
            return;
        }
        if (shared) {
            BOOL original = [NSBundle.mainBundle.bundleIdentifier isEqual:[appIdentifier stringByAppendingString:@".Extension"]];
            settings = [[self alloc] initWithDefaults:defaults legacyDefaults:NSUserDefaults.standardUserDefaults
                                    originalExtension:original credentialStore:credentialStore];
        } else {
            settings = [[self alloc] initWithDefaults:defaults credentialStore:credentialStore];
        }
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

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults legacyDefaults:(NSUserDefaults *)legacyDefaults
               originalExtension:(BOOL)originalExtension credentialStore:(id<OmnibarCredentialStoring>)credentialStore {
    if ((self = [self initWithDefaults:defaults credentialStore:credentialStore])) {
        _usesSharedPreferences = YES;
        if (originalExtension && self.sharedPreferencesMigrationPending) {
            // Copy only user-configured engine preferences. Never copy the
            // domain wholesale: it may contain unrelated browsing metadata.
            for (NSString *key in @[SelectedEngineKey, CustomEnginesKey, EngineOrderKey, RemovedDefaultEngineIDsKey]) {
                id value = [legacyDefaults objectForKey:key];
                if (value && ![defaults objectForKey:key]) [defaults setObject:value forKey:key];
            }
            [defaults setObject:@1 forKey:SharedPreferencesVersionKey];
        }
    }
    return self;
}

- (BOOL)sharedPreferencesMigrationPending {
    return self.usesSharedPreferences && ![[self.defaults objectForKey:SharedPreferencesVersionKey] isEqual:@1];
}

- (BOOL)showPaletteTips {
    return OmnibarShouldShowPaletteTips(self.defaults);
}

- (void)setShowPaletteTips:(BOOL)showPaletteTips {
    OmnibarSetShowPaletteTips(self.defaults, showPaletteTips);
}

- (NSString *)defaultURLSuffix {
    id saved = [self.defaults objectForKey:DefaultURLSuffixKey];
    return [OmnibarURLResolver validatedDefaultURLSuffix:saved error:NULL] ?: @".com";
}

- (BOOL)setDefaultURLSuffix:(NSString *)suffix error:(NSError **)error {
    if (self.sharedConfigurationError) {
        if (error) *error = self.sharedConfigurationError;
        return NO;
    }
    NSString *validated = [OmnibarURLResolver validatedDefaultURLSuffix:suffix error:error];
    if (!validated) return NO;
    [self.defaults setObject:validated forKey:DefaultURLSuffixKey];
    return YES;
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
    if (!self.sharedPreferencesMigrationPending && ![removed isEqual:storedRemoved]) {
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
    if (!self.sharedPreferencesMigrationPending && ![normalizedOrder isEqual:storedOrder]) {
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
    if (self.sharedConfigurationError) {
        if (error) *error = self.sharedConfigurationError;
        return nil;
    }
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
    if (self.sharedConfigurationError) {
        if (error) *error = self.sharedConfigurationError;
        return nil;
    }
    NSDictionary *engine = [self engineWithIdentifier:identifier];
    if (!engine) {
        SettingsError(error, @"That search engine is no longer available. Choose another engine.");
        return nil;
    }
    BOOL isSearch = NO;
    NSURL *URL = [OmnibarURLResolver URLForInput:input searchTemplate:engine[@"template"] defaultURLSuffix:self.defaultURLSuffix isSearch:&isSearch error:error];
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
    return [OmnibarURLResolver URLForInput:input searchTemplate:validated defaultURLSuffix:self.defaultURLSuffix isSearch:NULL error:error];
}

@end
