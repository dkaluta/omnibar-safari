#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "OmnibarURLResolver.h"
#import "OmnibarPalettePreferences.h"
#import "SettingsTestSupport.h"

// Inspect query construction only; these tests never call the real Keychain.
@interface OmnibarKeychainStore (QueryTesting)
- (NSMutableDictionary *)query;
- (NSMutableDictionary *)queryForBundleIdentifier:(NSString *)bundleIdentifier;
- (NSMutableDictionary *)migrationQuery;
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier info:(NSDictionary *)info;
- (OSStatus)copyItemMatchingQuery:(NSDictionary *)query result:(id *)result;
- (OSStatus)updateItemMatchingQuery:(NSDictionary *)query attributes:(NSDictionary *)attributes;
- (OSStatus)addItemWithAttributes:(NSDictionary *)attributes;
- (OSStatus)deleteItemMatchingQuery:(NSDictionary *)query;
@end

@interface OmnibarSearchSettings (MigrationTesting)
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults legacyDefaults:(NSUserDefaults *)legacyDefaults
               originalExtension:(BOOL)originalExtension credentialStore:(id<OmnibarCredentialStoring>)credentialStore;
@end

@interface OMInMemoryKeychainStore : OmnibarKeychainStore
@property (nonatomic, strong) NSMutableDictionary *items;
@property (nonatomic, strong) NSMutableArray *requests;
@property (nonatomic) OSStatus failure;
@property (nonatomic) BOOL failSharedWrites;
@property (nonatomic) BOOL failLegacyDeletes;
@property (nonatomic, copy) void (^beforeAdd)(NSDictionary *attributes);
@end
@implementation OMInMemoryKeychainStore
- (NSString *)keyForQuery:(NSDictionary *)query {
    return [@[query[(__bridge id)kSecAttrService] ?: @"", query[(__bridge id)kSecAttrAccount] ?: @"",
              query[(__bridge id)kSecAttrAccessGroup] ?: @"legacy"] componentsJoinedByString:@"|"];
}
- (OSStatus)copyItemMatchingQuery:(NSDictionary *)query result:(id *)result {
    [self.requests addObject:query];
    if (self.failure) return self.failure;
    id data = self.items[[self keyForQuery:query]];
    if (!data) return errSecItemNotFound;
    if (result) *result = data;
    return errSecSuccess;
}
- (OSStatus)updateItemMatchingQuery:(NSDictionary *)query attributes:(NSDictionary *)attributes {
    [self.requests addObject:query];
    if (self.failure) return self.failure;
    if (self.failSharedWrites && query[(__bridge id)kSecAttrAccessGroup]) return errSecMissingEntitlement;
    NSString *key = [self keyForQuery:query];
    if (!self.items[key]) return errSecItemNotFound;
    self.items[key] = attributes[(__bridge id)kSecValueData];
    return errSecSuccess;
}
- (OSStatus)addItemWithAttributes:(NSDictionary *)attributes {
    if (self.beforeAdd) {
        void (^action)(NSDictionary *) = self.beforeAdd;
        self.beforeAdd = nil;
        action(attributes);
    }
    [self.requests addObject:attributes];
    if (self.failure) return self.failure;
    if (self.failSharedWrites && attributes[(__bridge id)kSecAttrAccessGroup]) return errSecMissingEntitlement;
    NSString *key = [self keyForQuery:attributes];
    if (self.items[key]) return errSecDuplicateItem;
    self.items[key] = attributes[(__bridge id)kSecValueData];
    return errSecSuccess;
}
- (OSStatus)deleteItemMatchingQuery:(NSDictionary *)query {
    [self.requests addObject:query];
    if (self.failure) return self.failure;
    if (self.failLegacyDeletes && !query[(__bridge id)kSecAttrAccessGroup]) return errSecInteractionNotAllowed;
    NSString *key = [self keyForQuery:query];
    if (!self.items[key]) return errSecItemNotFound;
    [self.items removeObjectForKey:key];
    return errSecSuccess;
}
@end

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static void TestCredentialIdentity(void) {
    OmnibarKeychainStore *store = [OmnibarKeychainStore new];
    NSDictionary *production = [store queryForBundleIdentifier:@"com.dkaluta.omnibar.Extension"];
    NSDictionary *development = [store queryForBundleIdentifier:@"com.dkaluta.omnibar.development.Extension"];
    NSDictionary *custom = [store queryForBundleIdentifier:@"com.example.omnibar.local.Extension"];
    NSDictionary *unbundled = [store queryForBundleIdentifier:nil];
    id serviceKey = (__bridge id)kSecAttrService;
    Check([production[serviceKey] isEqual:@"com.dkaluta.omnibar.Extension.kagi"],
          @"production retains the existing Kagi service without migration");
    Check([development[serviceKey] isEqual:@"com.dkaluta.omnibar.development.Extension.kagi"],
          @"development credentials use the development extension identity");
    Check(![production[serviceKey] isEqual:development[serviceKey]],
          @"local builds cannot match the production credential service");
    Check([custom[serviceKey] isEqual:@"com.example.omnibar.local.Extension.kagi"],
          @"custom local identities also get a separate credential service");
    Check([unbundled[serviceKey] isEqual:@"com.dkaluta.omnibar.tools.kagi"],
          @"unbundled tools use a stable service separate from production");
    Check([[store queryForBundleIdentifier:@""] isEqual:unbundled],
          @"empty and missing bundle identifiers use the same safe fallback");
    Check([[store query] isEqual:[store queryForBundleIdentifier:NSBundle.mainBundle.bundleIdentifier]],
          @"the live store derives its query from the main bundle identity");
    for (NSDictionary *query in @[production, development, custom, unbundled]) {
        Check([query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword]
              && [query[(__bridge id)kSecAttrAccount] isEqual:@"private-session-url"] && query.count == 3,
              @"credential identity isolation retains the account and local generic-password query");
    }
}

static NSDictionary *SharedInfo(NSString *appIdentifier) {
    return @{@"OmnibarContainingAppIdentifier": appIdentifier,
             @"OmnibarSharedGroup": [@"group." stringByAppendingString:appIdentifier],
             @"OmnibarKeychainGroup": [@"TESTTEAM." stringByAppendingString:[appIdentifier stringByAppendingString:@".shared"]]};
}

static OMInMemoryKeychainStore *SharedStore(NSString *appIdentifier, NSString *suffix, NSMutableDictionary *items) {
    OMInMemoryKeychainStore *store = [[OMInMemoryKeychainStore alloc]
        initWithBundleIdentifier:[appIdentifier stringByAppendingString:suffix] info:SharedInfo(appIdentifier)];
    store.items = items ?: [NSMutableDictionary new];
    store.requests = [NSMutableArray new];
    return store;
}

static void TestSharedCredentialMigration(void) {
    NSString *appIdentifier = @"com.dkaluta.omnibar.development";
    OMInMemoryKeychainStore *original = SharedStore(appIdentifier, @".Extension", nil);
    OMInMemoryKeychainStore *companion = SharedStore(appIdentifier, @".Commands", original.items);
    OMInMemoryKeychainStore *app = SharedStore(appIdentifier, @"", original.items);
    NSDictionary *query = [original query];
    Check([query isEqual:[companion query]], @"both extension targets use the same shared credential identity");
    Check([query isEqual:[app query]], @"the exact containing app uses the extensions’ shared credential identity");
    Check([query[(__bridge id)kSecAttrService] isEqual:@"com.dkaluta.omnibar.development.shared.kagi"],
          @"shared credential service retains the development identity boundary");
    Check([query[(__bridge id)kSecAttrAccessGroup] isEqual:@"TESTTEAM.com.dkaluta.omnibar.development.shared"]
          && [query[(__bridge id)kSecUseDataProtectionKeychain] isEqual:@YES]
          && [query[(__bridge id)kSecAttrSynchronizable] isEqual:@NO],
          @"shared credentials explicitly use the entitled Data Protection group without iCloud sync");
    OMInMemoryKeychainStore *production = SharedStore(@"com.dkaluta.omnibar", @".Commands", original.items);
    Check(![[production query] isEqual:query], @"production and development shared groups are isolated");
    NSString *legacyKey = [original keyForQuery:[original queryForBundleIdentifier:[appIdentifier stringByAppendingString:@".Extension"]]];
    NSString *fakeURL = @"https://kagi.com/search?token=FAKE_MIGRATION_ONLY&q=%s";
    original.items[legacyKey] = [fakeURL dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    Check([companion privateKagiURLWithError:&error] == nil && !error,
          @"companion without a shared credential has no optional private link");
    Check([app privateKagiURLWithError:&error] == nil && !error,
          @"the containing app reports no saved shared link without requiring the original extension");
    for (NSDictionary *request in app.requests)
        Check(request[(__bridge id)kSecAttrAccessGroup] != nil, @"the app does not attempt the original extension’s legacy ACL");
    NSDictionary *beforeOptionalImport = original.items.copy;
    OMTestDefaults *optionalDefaults = [OMTestDefaults new];
    OmnibarSearchSettings *optionalSettings = [[OmnibarSearchSettings alloc] initWithDefaults:(id)optionalDefaults credentialStore:companion];
    NSURL *ordinaryPrivateSearch = [optionalSettings URLForInput:@"ordinary private search" searchEngine:@"kagi" privateBrowsing:YES error:&error];
    Check([ordinaryPrivateSearch.absoluteString isEqual:@"https://kagi.com/search?q=ordinary%20private%20search"] && !error,
          @"private Kagi search works normally without a saved shared link or the legacy extension");
    Check([beforeOptionalImport isEqual:original.items], @"ordinary private search never marks migration complete or writes a tombstone");
    for (NSDictionary *request in companion.requests) {
        Check(request[(__bridge id)kSecAttrAccessGroup] != nil, @"companion never attempts the original extension legacy ACL");
    }
    original.failSharedWrites = YES;
    Check([original privateKagiURLWithError:&error] == nil && error && original.items[legacyKey],
          @"failed shared migration preserves the original credential and reports failure");
    original.failSharedWrites = NO;
    Check([[original privateKagiURLWithError:&error] isEqual:fakeURL] && !error,
          @"original extension migrates its own legacy credential when first used");
    Check([[companion privateKagiURLWithError:&error] isEqual:fakeURL] && !error,
          @"companion reads the migrated credential");
    Check([[app privateKagiURLWithError:&error] isEqual:fakeURL] && !error,
          @"the settings app reads the same migrated credential");
    Check(original.items[legacyKey] != nil, @"successful migration leaves the old protected credential intact");
    Check([companion setPrivateKagiURL:nil error:&error], @"companion can remove the shared credential");
    Check([original privateKagiURLWithError:&error] == nil && !error && !original.items[legacyKey],
          @"removal marker prevents resurrection and the original extension cleans up its legacy credential");
    Check([companion privateKagiURLWithError:&error] == nil && !error,
          @"removed link has no pending migration error");
    original = SharedStore(appIdentifier, @".Extension", original.items);
    Check([original privateKagiURLWithError:&error] == nil && !error,
          @"removal survives reopening the credential store after cleanup");

    original.items[legacyKey] = [fakeURL dataUsingEncoding:NSUTF8StringEncoding];
    original.failLegacyDeletes = YES;
    Check(![original setPrivateKagiURL:nil error:&error] && error && original.items[legacyKey],
          @"native removal reports failure if the preserved legacy credential cannot be removed");
    Check([original privateKagiURLWithError:&error] == nil && error,
          @"a legacy cleanup failure is visible and still cannot resurrect the removed shared credential");
    original.failLegacyDeletes = NO;
    Check([original setPrivateKagiURL:nil error:&error] && !original.items[legacyKey],
          @"native Remove Link also deletes the original extension legacy credential");

    OMInMemoryKeychainStore *racing = SharedStore(appIdentifier, @".Extension", nil);
    OMInMemoryKeychainStore *racingCompanion = SharedStore(appIdentifier, @".Commands", racing.items);
    racing.items[legacyKey] = [fakeURL dataUsingEncoding:NSUTF8StringEncoding];
    racing.beforeAdd = ^(NSDictionary *attributes) {
        Check([racingCompanion setPrivateKagiURL:nil error:NULL], @"companion removal succeeds during pending legacy import");
    };
    Check([racing privateKagiURLWithError:&error] == nil && !error,
          @"a simultaneous removal wins against add-only legacy migration");
    racing = SharedStore(appIdentifier, @".Extension", nil);
    racingCompanion = SharedStore(appIdentifier, @".Commands", racing.items);
    racing.items[legacyKey] = [fakeURL dataUsingEncoding:NSUTF8StringEncoding];
    NSString *replacement = @"https://kagi.com/search?token=NEWER_LOCAL&q=%s";
    racing.beforeAdd = ^(NSDictionary *attributes) {
        Check([racingCompanion setPrivateKagiURL:replacement error:NULL], @"companion save succeeds during pending legacy import");
    };
    Check([[racing privateKagiURLWithError:&error] isEqual:replacement] && !error,
          @"an explicit replacement wins against add-only legacy migration");

    OMInMemoryKeychainStore *fresh = SharedStore(appIdentifier, @".Extension", nil);
    Check([fresh privateKagiURLWithError:&error] == nil && !error,
          @"original extension records completed migration when no legacy link exists");
    OMInMemoryKeychainStore *freshCompanion = SharedStore(appIdentifier, @".Commands", fresh.items);
    Check([freshCompanion privateKagiURLWithError:&error] == nil && !error,
          @"companion after a no-link migration uses ordinary Kagi search");
    OMInMemoryKeychainStore *explicit = SharedStore(appIdentifier, @".Commands", nil);
    Check([explicit setPrivateKagiURL:fakeURL error:&error], @"explicitly saving in a companion requires no legacy import");
    OMInMemoryKeychainStore *laterOriginal = SharedStore(appIdentifier, @".Extension", explicit.items);
    laterOriginal.items[legacyKey] = [@"https://kagi.com/search?token=OLD&q=%s" dataUsingEncoding:NSUTF8StringEncoding];
    Check([[laterOriginal privateKagiURLWithError:&error] isEqual:fakeURL],
          @"a newer shared credential is never overwritten by the preserved legacy credential");
    laterOriginal.failure = errSecInteractionNotAllowed;
    Check([laterOriginal privateKagiURLWithError:&error] == nil && error
          && ![error.localizedDescription containsString:fakeURL], @"locked Keychain errors remain visible and contain no secret");
    OMInMemoryKeychainStore *invalid = [[OMInMemoryKeychainStore alloc] initWithBundleIdentifier:[appIdentifier stringByAppendingString:@".Commands"]
        info:@{@"OmnibarContainingAppIdentifier": appIdentifier, @"OmnibarKeychainGroup": @"$(OMNIBAR_KEYCHAIN_GROUP)"}];
    invalid.items = [NSMutableDictionary new]; invalid.requests = [NSMutableArray new];
    Check([invalid privateKagiURLWithError:&error] == nil && error && invalid.requests.count == 0,
          @"unresolved build settings report unavailable storage without querying a fallback Keychain");
    OMInMemoryKeychainStore *unrelated = SharedStore(appIdentifier, @".Unrelated", nil);
    Check(![unrelated setPrivateKagiURL:fakeURL error:&error] && error && unrelated.requests.count == 0,
          @"an arbitrary bundle sharing the app prefix cannot use the shared credential configuration");
    OMInMemoryKeychainStore *freshApp = SharedStore(appIdentifier, @"", nil);
    OmnibarSearchSettings *freshSettings = [[OmnibarSearchSettings alloc] initWithDefaults:(id)[OMTestDefaults new] credentialStore:freshApp];
    Check([[freshSettings URLForInput:@"new install" searchEngine:@"kagi" privateBrowsing:YES error:&error].absoluteString
           isEqual:@"https://kagi.com/search?q=new%20install"] && !error && freshApp.items.count == 0,
          @"a fresh app-only installation can use private Kagi without any Keychain writes");
    Check([freshApp setPrivateKagiURL:fakeURL error:&error], @"app-only setup can explicitly save a new private link");
    OMInMemoryKeychainStore *freshCommands = SharedStore(appIdentifier, @".Commands", freshApp.items);
    Check([[freshCommands privateKagiURLWithError:&error] isEqual:fakeURL] && !error,
          @"a new link saved in the app works without ever enabling the legacy extension");
    Check([freshApp setPrivateKagiURL:nil error:&error]
          && [freshCommands privateKagiURLWithError:&error] == nil && !error,
          @"app removal is immediately respected by the primary extension");
    freshApp.items[legacyKey] = [fakeURL dataUsingEncoding:NSUTF8StringEncoding];
    OMInMemoryKeychainStore *cleanupOriginal = SharedStore(appIdentifier, @".Extension", freshApp.items);
    cleanupOriginal.failLegacyDeletes = YES;
    Check(![cleanupOriginal hasPrivateKagiURLWithError:&error] && error && cleanupOriginal.items[legacyKey],
          @"failed cleanup after app removal keeps the tombstone and reports the retained legacy item");
    cleanupOriginal.failLegacyDeletes = NO;
    [cleanupOriginal.requests removeAllObjects];
    Check(![cleanupOriginal hasPrivateKagiURLWithError:&error] && !error && !cleanupOriginal.items[legacyKey],
          @"the next original settings check finishes app-initiated removal without an enabled Remove button");
    BOOL deletedLegacy = NO;
    for (NSDictionary *request in cleanupOriginal.requests) {
        if (!request[(__bridge id)kSecAttrAccessGroup]) {
            deletedLegacy = YES;
            Check(request[(__bridge id)kSecReturnData] == nil, @"legacy cleanup does not read credential contents");
        }
    }
    Check(deletedLegacy && [freshCommands privateKagiURLWithError:&error] == nil && !error,
          @"cleanup deletes only the old local item and preserves the shared removal marker");
    for (NSDictionary *request in original.requests) {
        Check(![request[(__bridge id)kSecAttrService] isEqual:@"com.dkaluta.omnibar.Extension.kagi"],
              @"development migration never queries the production legacy service");
    }
}

static void TestSharedPreferenceMigration(void) {
    OMTestDefaults *legacy = [OMTestDefaults new], *shared = [OMTestDefaults new];
    legacy.values[@"searchEngine"] = @"kagi";
    legacy.values[@"customSearchEngines"] = @[@{@"id": @"custom:legacy", @"name": @"Local Reference", @"template": @"https://example.org/?q=%s"}];
    legacy.values[@"searchEngineOrder"] = @[@"kagi", @"custom:legacy", @"duckduckgo"];
    legacy.values[@"removedDefaultSearchEngineIDs"] = @[@"google"];
    legacy.values[@"history"] = @[@"NEVER_COPY_HISTORY"];
    legacy.values[@"lastQuery"] = @"NEVER_COPY_QUERY";
    OMTestCredentials *credentials = [OMTestCredentials new];
    OmnibarSearchSettings *companion = [[OmnibarSearchSettings alloc] initWithDefaults:(id)shared legacyDefaults:(id)legacy
        originalExtension:NO credentialStore:credentials];
    Check(companion.sharedPreferencesMigrationPending, @"companion explicitly reports pending preference migration");
    Check(companion.searchEngines.count > 0 && shared.values.count == 0,
          @"companion can display defaults without freezing them ahead of legacy migration");
    OmnibarSearchSettings *original = [[OmnibarSearchSettings alloc] initWithDefaults:(id)shared legacyDefaults:(id)legacy
        originalExtension:YES credentialStore:credentials];
    Check(!original.sharedPreferencesMigrationPending && !companion.sharedPreferencesMigrationPending,
          @"both settings objects observe completed original-extension migration");
    Check([original.selectedEngineID isEqual:@"kagi"] && original.customSearchEngines.count == 1
          && [[original.removedDefaultSearchEngines valueForKey:@"id"] containsObject:@"google"],
          @"migration preserves selection, engine order, custom definitions, and removals");
    Check(!shared.values[@"history"] && !shared.values[@"lastQuery"] && shared.values.count == 5,
          @"migration copies only four preference keys and its version marker");
    Check(credentials.reads == 0, @"preference migration never reads saved credentials");
    legacy.values[@"searchEngineOrder"] = @[@"bing"];
    original = [[OmnibarSearchSettings alloc] initWithDefaults:(id)shared legacyDefaults:(id)legacy originalExtension:YES credentialStore:credentials];
    Check([original.selectedEngineID isEqual:@"kagi"], @"preference migration runs once and never reimports stale settings");
    shared = [OMTestDefaults new];
    shared.values[@"searchEngineOrder"] = @[@"ecosia"];
    original = [[OmnibarSearchSettings alloc] initWithDefaults:(id)shared legacyDefaults:(id)legacy originalExtension:YES credentialStore:credentials];
    Check([original.selectedEngineID isEqual:@"ecosia"] && original.customSearchEngines.count == 1,
          @"existing shared preferences win while missing allowlisted preferences are imported");
    NSDictionary *beforeSearch = [shared.values copy];
    [original URLForInput:@"PRIVATE_QUERY_NOT_STORED" searchEngine:@"ecosia" privateBrowsing:NO error:NULL];
    Check([beforeSearch isEqual:shared.values], @"resolving a query persists no query, browsing history, or usage data");
}

static void TestPaletteTipsPreference(void) {
    OMTestDefaults *defaults = [OMTestDefaults new];
    OMTestCredentials *credentials = [OMTestCredentials new];
    credentials.fail = YES;
    OmnibarSearchSettings *settings = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check(settings.showPaletteTips && defaults.values.count == 0,
          @"first-open tips default to visible without writing activity or accessing credentials");
    settings.showPaletteTips = NO;
    Check([defaults.values isEqual:@{@"showPaletteTips": @NO}], @"dismissing tips writes exactly one local boolean");
    OmnibarSearchSettings *reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check(!reloaded.showPaletteTips, @"dismissed tips remain dismissed when native settings are reopened");
    OmnibarSetShowPaletteTips((id)defaults, YES);
    Check(reloaded.showPaletteTips && [defaults.values isEqual:@{@"showPaletteTips": @YES}],
          @"the containing app can reset the same shared local preference");
    settings.showPaletteTips = NO;
    [settings restoreDefaultSearchEngines];
    Check(!settings.showPaletteTips, @"restoring search engines does not reset independent palette tips");
    defaults.values[@"showPaletteTips"] = @"malformed";
    Check(settings.showPaletteTips, @"malformed onboarding preference uses the visible default");
    Check(credentials.reads == 0, @"tips never read private credentials");
}

static void TestDefaultEngineManagement(void) {
    OMTestDefaults *defaults;
    OMTestCredentials *credentials;
    OmnibarSearchSettings *settings = OMMakeTestSettings(&defaults, &credentials);
    NSArray *catalogIDs = [OmnibarURLResolver.searchEngines valueForKey:@"id"];
    NSArray *initialOrder = [settings.searchEngines valueForKey:@"id"];
    Check(settings.removedDefaultSearchEngines.count == 0, @"fresh settings have no removed defaults");
    [settings removeEngineWithIdentifier:@"missing"];
    [settings removeCustomEngineWithIdentifier:initialOrder.firstObject];
    Check([[settings.searchEngines valueForKey:@"id"] isEqual:initialOrder], @"invalid removal and custom-only API do not remove defaults");

    NSString *removedDefault = settings.selectedEngineID;
    [settings removeEngineWithIdentifier:removedDefault];
    Check([settings.selectedEngineID isEqual:initialOrder[1]], @"removing a built-in default promotes the next engine");
    Check([defaults.values[@"searchEngine"] isEqual:settings.selectedEngineID], @"removal persists the promoted selection");
    Check([[settings.removedDefaultSearchEngines valueForKey:@"id"] isEqual:@[removedDefault]], @"removed default is available to add back");
    NSArray *afterRemoval = [settings.searchEngines valueForKey:@"id"];
    [settings removeEngineWithIdentifier:removedDefault];
    [settings moveEngineWithIdentifier:removedDefault toIndex:0];
    Check([[settings.searchEngines valueForKey:@"id"] isEqual:afterRemoval], @"stale removal and reordering cannot resurrect an engine");
    OmnibarSearchSettings *reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check([[reloaded.searchEngines valueForKey:@"id"] isEqual:afterRemoval], @"removed defaults and order survive reopening settings");
    Check([[reloaded.removedDefaultSearchEngines valueForKey:@"id"] isEqual:@[removedDefault]], @"removed-default catalog survives reopening settings");
    NSError *error = nil;
    Check([settings URLForInput:@"query" searchEngine:removedDefault privateBrowsing:NO error:&error] == nil && error,
          @"a stale removed built-in cannot route a search");
    NSString *removedName = settings.removedDefaultSearchEngines.firstObject[@"name"];
    Check(![settings saveCustomEngine:nil name:removedName.lowercaseString template:@"https://example.com/?q=%s" error:&error] && error,
          @"removed built-in names remain reserved regardless of case");

    [settings restoreDefaultEngineWithIdentifier:removedDefault];
    NSArray *restoredOrder = [afterRemoval arrayByAddingObject:removedDefault];
    Check([[settings.searchEngines valueForKey:@"id"] isEqual:restoredOrder], @"adding a default appends it without reordering active engines");
    Check([settings.selectedEngineID isEqual:afterRemoval.firstObject] && settings.removedDefaultSearchEngines.count == 0,
          @"individual restore preserves the current default and updates the add-back list");
    [settings restoreDefaultEngineWithIdentifier:removedDefault];
    [settings restoreDefaultEngineWithIdentifier:@"missing"];
    Check([[settings.searchEngines valueForKey:@"id"] isEqual:restoredOrder], @"individual restore is idempotent and ignores unknown IDs");
    reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check([[reloaded.searchEngines valueForKey:@"id"] isEqual:restoredOrder], @"individual restore order persists");

    for (NSString *identifier in catalogIDs) [settings removeEngineWithIdentifier:identifier];
    Check(settings.searchEngines.count == 1, @"removal retains the final built-in engine");
    NSString *finalBuiltin = settings.selectedEngineID;
    [settings removeEngineWithIdentifier:finalBuiltin];
    Check([settings.selectedEngineID isEqual:finalBuiltin] && settings.searchEngines.count == 1, @"the final built-in removal is a no-op");
    NSMutableArray *expectedRemoved = [catalogIDs mutableCopy];
    [expectedRemoved removeObject:finalBuiltin];
    Check([[settings.removedDefaultSearchEngines valueForKey:@"id"] isEqual:expectedRemoved], @"add-back entries follow the regional catalog order");

    NSDictionary *firstCustom = [settings saveCustomEngine:nil name:@"Dictionary" template:@"https://example.com/?q=%s" error:&error];
    [settings removeEngineWithIdentifier:finalBuiltin];
    Check(settings.searchEngines.count == 1 && [settings.selectedEngineID isEqual:firstCustom[@"id"]],
          @"all built-ins can be removed when a custom engine remains");
    [settings removeEngineWithIdentifier:firstCustom[@"id"]];
    [settings removeCustomEngineWithIdentifier:firstCustom[@"id"]];
    Check(settings.customSearchEngines.count == 1 && [settings.selectedEngineID isEqual:firstCustom[@"id"]],
          @"both removal APIs retain a final custom engine");
    reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check(reloaded.searchEngines.count == 1 && reloaded.removedDefaultSearchEngines.count == catalogIDs.count,
          @"a custom-only configuration survives reopening without resurrecting defaults");
    [settings restoreDefaultEngineWithIdentifier:firstCustom[@"id"]];
    Check(settings.searchEngines.count == 1, @"the add-back API cannot restore custom engines");

    NSDictionary *secondCustom = [settings saveCustomEngine:nil name:@"Reference" template:@"https://example.org/?q=%s" error:&error];
    settings.selectedEngineID = secondCustom[@"id"];
    NSArray *customDefinitions = settings.customSearchEngines;
    Check([settings saveKagiPrivateURL:@"https://kagi.com/search?token=FAKE_RESTORE_TEST&q=%s" error:&error], @"restoration fixture stores a Kagi private link");
    NSString *privateURL = credentials.URL;
    NSUInteger credentialReads = credentials.reads;
    Check([settings URLForInput:@"query" searchEngine:@"kagi" privateBrowsing:YES error:&error] == nil && error,
          @"removed Kagi cannot route a private search");
    Check(credentials.reads == credentialReads, @"removed Kagi never reads the saved credential");
    [settings restoreDefaultEngineWithIdentifier:@"kagi"];
    [settings removeEngineWithIdentifier:@"kagi"];
    [settings restoreDefaultSearchEngines];
    NSArray *expectedOrder = [catalogIDs arrayByAddingObjectsFromArray:@[secondCustom[@"id"], firstCustom[@"id"]]];
    Check([[settings.searchEngines valueForKey:@"id"] isEqual:expectedOrder],
          @"full restore uses regional defaults followed by customs in their active relative order");
    Check([settings.selectedEngineID isEqual:catalogIDs.firstObject] && [defaults.values[@"searchEngine"] isEqual:catalogIDs.firstObject],
          @"full restore selects and persists the first regional default");
    Check([settings.customSearchEngines isEqual:customDefinitions], @"full restore preserves custom definitions");
    Check([credentials.URL isEqual:privateURL] && credentials.reads == credentialReads,
          @"Kagi removal and restoration preserve the saved credential without accessing it");
    Check(settings.removedDefaultSearchEngines.count == 0, @"full restore clears all removed defaults");
    [settings restoreDefaultSearchEngines];
    reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check([[reloaded.searchEngines valueForKey:@"id"] isEqual:expectedOrder], @"full restore is idempotent and persistent");
    [settings removeEngineWithIdentifier:firstCustom[@"id"]];
    Check(settings.customSearchEngines.count == 1 && [settings.customSearchEngines.firstObject[@"id"] isEqual:secondCustom[@"id"]],
          @"the general removal API deletes custom definitions");
}

static void TestCorruptRemovalPreferences(void) {
    OMTestDefaults *defaults;
    OmnibarSearchSettings *settings = OMMakeTestSettings(&defaults, NULL);
    NSArray *catalogIDs = [OmnibarURLResolver.searchEngines valueForKey:@"id"];
    defaults.values[@"removedDefaultSearchEngineIDs"] = @[@"kagi", @"kagi", @27, @{}, @"missing", @"custom:missing"];
    defaults.values[@"searchEngineOrder"] = @[@"kagi", @27, @"google", @"google"];
    Check(![[settings.searchEngines valueForKey:@"id"] containsObject:@"kagi"] && [settings.selectedEngineID isEqual:@"google"],
          @"stale order cannot resurrect a removed engine and invalid order values are ignored");
    Check([defaults.values[@"removedDefaultSearchEngineIDs"] isEqual:@[@"kagi"]], @"removed IDs are normalized to unique built-ins");
    defaults.values[@"customSearchEngines"] = @[
        @{@"id": @27, @"name": @"Invalid identity", @"template": @"https://example.com/?q=%s"},
        @{@"id": @"custom:valid", @"name": @"Reference", @"template": @"https://example.org/?q=%s"},
        @{@"id": @"custom:valid", @"name": @"Duplicate identity", @"template": @"https://example.net/?q=%s"}];
    Check(settings.customSearchEngines.count == 1 && [settings.customSearchEngines.firstObject[@"id"] isEqual:@"custom:valid"],
          @"stored customs still reject invalid and duplicate identities with removed defaults");
    defaults.values[@"removedDefaultSearchEngineIDs"] = catalogIDs;
    defaults.values[@"searchEngineOrder"] = @"invalid order";
    Check(settings.searchEngines.count == 1 && [settings.selectedEngineID isEqual:@"custom:valid"],
          @"invalid order does not restore removed defaults while a usable custom remains");
    defaults.values[@"customSearchEngines"] = @[@"invalid", @{@"id": @"custom:bad", @"name": @"Bad", @"template": @"no placeholder"}];
    Check(settings.searchEngines.count == 1 && [settings.selectedEngineID isEqual:catalogIDs.firstObject],
          @"corrupt all-removed state recovers one regional default when no valid custom remains");
    Check(settings.removedDefaultSearchEngines.count == catalogIDs.count - 1,
          @"corruption recovery preserves every other removed default");
    OmnibarSearchSettings *reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:[OMTestCredentials new]];
    Check(reloaded.searchEngines.count == 1 && [reloaded.selectedEngineID isEqual:catalogIDs.firstObject],
          @"the recovered minimum engine state is persisted");
    defaults.values[@"removedDefaultSearchEngineIDs"] = @"invalid removed list";
    Check(settings.searchEngines.count == catalogIDs.count && settings.removedDefaultSearchEngines.count == 0,
          @"a malformed removed-list container safely normalizes to no valid removals");
}

static void TestDefaultURLSuffix(void) {
    OMTestDefaults *defaults = [OMTestDefaults new];
    OMTestCredentials *credentials = [OMTestCredentials new];
    OmnibarSearchSettings *settings = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check([settings.defaultURLSuffix isEqual:@".com"] && defaults.values.count == 0 && credentials.reads == 0,
          @"Reading the default website suffix neither writes preferences nor reads credentials");
    NSError *error = nil;
    Check([settings setDefaultURLSuffix:@" CO.UK " error:&error] && !error
          && [defaults.values[@"defaultURLSuffix"] isEqual:@".co.uk"] && defaults.values.count == 1,
          @"Saving a website suffix stores only its canonical local preference");
    OmnibarSearchSettings *reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    Check([reloaded.defaultURLSuffix isEqual:@".co.uk"], @"Website suffix survives reopening settings");
    Check(![settings setDefaultURLSuffix:@".com/path" error:&error] && error && [settings.defaultURLSuffix isEqual:@".co.uk"],
          @"Invalid website suffix preserves the existing setting");
    Check(![settings setDefaultURLSuffix:@".co.123" error:&error] && error && [settings.defaultURLSuffix isEqual:@".co.uk"],
          @"Numeric final suffix labels are rejected before storing unusable website defaults");
    credentials.fail = YES;
    NSURL *URL = [settings URLForInput:@".cnn/news?topic=world#latest" searchEngine:@"kagi" privateBrowsing:YES error:&error];
    Check([URL.absoluteString isEqual:@"https://www.cnn.co.uk/news?topic=world#latest"] && !error && credentials.reads == 0,
          @"Configured shorthand navigates directly without reading a private Kagi credential");
    Check(![defaults.values.description containsString:@"topic=world"] && ![defaults.values.description containsString:@"cnn"],
          @"Resolving shorthand does not store its hostname, path, query, or fragment");
    URL = [settings URLForInput:@".bsky.app" searchEngine:@"google" privateBrowsing:NO error:&error];
    Check([URL.absoluteString isEqual:@"https://www.bsky.app/"] && !error,
          @"A supplied website suffix overrides the configured default");
    for (id corrupt in @[@27, @[], @".com/path", @"", @"..com"]) {
        defaults.values[@"defaultURLSuffix"] = corrupt;
        Check([settings.defaultURLSuffix isEqual:@".com"] && [defaults.values[@"defaultURLSuffix"] isEqual:corrupt],
              @"Corrupt stored suffix falls back safely without writing on read");
    }
    OMTestDefaults *shared = [OMTestDefaults new];
    OMTestDefaults *legacy = [OMTestDefaults new];
    legacy.values[@"defaultURLSuffix"] = @".legacy";
    OmnibarSearchSettings *companion = [[OmnibarSearchSettings alloc] initWithDefaults:(id)shared legacyDefaults:(id)legacy
        originalExtension:NO credentialStore:credentials];
    Check([companion.defaultURLSuffix isEqual:@".com"] && shared.values.count == 0,
          @"New suffix preference does not import unallowlisted legacy data or force migration");
    Check([companion setDefaultURLSuffix:@".co.uk" error:&error], @"New shared website preference can be configured independently");
    OmnibarSearchSettings *original = [[OmnibarSearchSettings alloc] initWithDefaults:(id)shared legacyDefaults:(id)legacy
        originalExtension:YES credentialStore:credentials];
    Check([original.defaultURLSuffix isEqual:@".co.uk"] && [companion.defaultURLSuffix isEqual:@".co.uk"],
          @"Both extensions share the explicit suffix without legacy migration overwriting it");
}

int main(void) {
    @autoreleasepool {
        TestCredentialIdentity();
        TestSharedCredentialMigration();
        TestSharedPreferenceMigration();
        TestPaletteTipsPreference();
        TestDefaultURLSuffix();
        TestDefaultEngineManagement();
        TestCorruptRemovalPreferences();
        OMTestDefaults *freshDefaults = [OMTestDefaults new];
        OmnibarSearchSettings *fresh = [[OmnibarSearchSettings alloc] initWithDefaults:(id)freshDefaults credentialStore:[OMTestCredentials new]];
        Check([fresh.selectedEngineID isEqual:OmnibarURLResolver.searchEngines.firstObject[@"id"]], @"fresh install uses the current region's first engine");
        Check([freshDefaults.values[@"searchEngineOrder"] isEqual:[OmnibarURLResolver.searchEngines valueForKey:@"id"]], @"regional initial order is persisted on first use");
        OMTestDefaults *defaults;
        OMTestCredentials *credentials;
        OmnibarSearchSettings *settings = OMMakeTestSettings(&defaults, &credentials);
        Check([settings.selectedEngineID isEqualToString:@"duckduckgo"], @"legacy selected engine migrates to first");
        Check([settings.searchEngines.firstObject[@"id"] isEqual:settings.selectedEngineID], @"first engine is default");
        Check([defaults.values[@"searchEngineOrder"] isEqual:[settings.searchEngines valueForKey:@"id"]], @"initial order is saved before any manual reordering");
        [settings moveEngineWithIdentifier:@"kagi" toIndex:0];
        Check([settings.selectedEngineID isEqualToString:@"kagi"], @"moving engine to top changes default");
        OmnibarSearchSettings *reloaded = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
        Check([reloaded.selectedEngineID isEqualToString:@"kagi"], @"order survives reopening settings store");
        [settings moveEngineWithIdentifier:@"kagi" toIndex:1];
        Check(![settings.selectedEngineID isEqualToString:@"kagi"], @"moving default down makes next engine default");

        NSError *error = nil;
        NSDictionary *custom = [settings saveCustomEngine:nil name:@"Dictionary" template:@"https://example.com/find/{searchTerms}?lang=en" error:&error];
        Check(custom != nil && error == nil, @"custom engine saved");
        NSString *identifier = custom[@"id"];
        settings.selectedEngineID = identifier;
        Check([settings.searchEngines.firstObject[@"id"] isEqual:identifier], @"custom engine can become default");
        NSURL *URL = [settings URLForInput:@"café & tea" searchEngine:identifier privateBrowsing:NO error:&error];
        Check([URL.host isEqualToString:@"example.com"] && [URL.path containsString:@"café & tea"], @"custom engine substitutes encoded search text");
        NSDictionary *edited = [settings saveCustomEngine:identifier name:@"Dictionary 2" template:@"https://example.org/?word=%s" error:&error];
        Check([edited[@"id"] isEqual:identifier] && settings.customSearchEngines.count == 1, @"editing keeps stable identity");
        Check([settings.selectedEngineID isEqual:identifier], @"editing preserves ordering/default");
        Check([settings saveCustomEngine:nil name:@"Google" template:@"https://example.com/?q=%s" error:&error] == nil && error != nil, @"duplicate builtin names rejected");
        Check([settings saveCustomEngine:nil name:@"Broken" template:@"https://example.com/" error:&error] == nil, @"missing search placeholder rejected");
        [settings removeCustomEngineWithIdentifier:identifier];
        Check(settings.customSearchEngines.count == 0 && ![settings.selectedEngineID isEqual:identifier], @"removing default promotes next engine");
        Check([settings URLForInput:@"query" searchEngine:identifier privateBrowsing:NO error:&error] == nil, @"removed engine does not silently search elsewhere");

        Check([settings saveKagiPrivateURL:@"https://kagi.com/search?token=FAKE_TEST_TOKEN&q=%s" error:&error], @"Kagi session-link format accepted");
        Check([settings hasKagiPrivateURLWithError:&error] && credentials.URL != nil, @"private link stored only in credential store");
        Check(![[defaults.values description] containsString:@"FAKE_TEST_TOKEN"], @"private token absent from preferences");
        NSUInteger reads = credentials.reads;
        URL = [settings URLForInput:@"private query" searchEngine:@"kagi" privateBrowsing:YES error:&error];
        NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
        Check([components.host isEqualToString:@"kagi.com"] && [components.query containsString:@"token=FAKE_TEST_TOKEN"], @"private Kagi search carries configured token");
        Check(credentials.reads == reads + 1, @"private Kagi search reads credential once");
        URL = [settings URLForInput:@"normal query" searchEngine:@"kagi" privateBrowsing:NO error:&error];
        Check(![URL.query containsString:@"token="], @"normal Kagi search excludes private token");
        [settings URLForInput:@"query" searchEngine:@"google" privateBrowsing:YES error:&error];
        URL = [settings URLForInput:@"example.com" searchEngine:@"kagi" privateBrowsing:YES error:&error];
        Check([URL.host isEqualToString:@"example.com"] && credentials.reads == reads + 1, @"other engines and direct URLs do not access Kagi credential");
        credentials.fail = YES;
        NSUInteger directReads = credentials.reads;
        for (NSString *input in @[@"about:blank", @"file:///tmp/Omnibar.html", @"mailto:person@example.com",
                                  @"tel:123", @"custom://open", @"javascript:void(0)", @"data:text/plain,Hello"]) {
            URL = [settings URLForInput:input searchEngine:@"kagi" privateBrowsing:YES error:&error];
            Check([URL.absoluteString isEqualToString:input] && !error && credentials.reads == directReads,
                  @"explicit schemes navigate directly even when the private Kagi credential is unavailable");
        }
        Check([settings URLForInput:@"private query" searchEngine:@"kagi" privateBrowsing:YES error:&error] == nil && error != nil, @"credential errors are surfaced instead of silently falling back");
        credentials.fail = NO;
        Check(![settings saveKagiPrivateURL:@"https://elsewhere.example/?token=FAKE_TEST_TOKEN" error:&error], @"session URL cannot send token to another host");
        Check([credentials.URL containsString:@"kagi.com"], @"invalid replacement preserves existing credential");
        Check([settings removeKagiPrivateURLWithError:&error] && ![settings hasKagiPrivateURLWithError:&error], @"private link can be removed");
        URL = [settings URLForInput:@"private query" searchEngine:@"kagi" privateBrowsing:YES error:&error];
        Check(URL && ![URL.query containsString:@"token="], @"private Kagi search works normally without a configured link");

        defaults.values[@"customSearchEngines"] = @[@"invalid", @{@"id": @"google", @"name": @"Hijack", @"template": @"https://elsewhere.example/?q=%s"}];
        defaults.values[@"searchEngineOrder"] = @[@"removed", @"kagi", @"kagi", @27];
        Check(settings.customSearchEngines.count == 0, @"corrupt custom entries cannot replace builtins");
        Check(settings.searchEngines.count == OmnibarURLResolver.searchEngines.count, @"stale/duplicate saved order still includes every engine once");
        Check([settings.selectedEngineID isEqualToString:@"kagi"], @"first valid ordered engine remains default");
        printf("Passed %lu search-settings checks; credentials and preferences were in memory.\n", (unsigned long)checks);
    }
    return 0;
}
