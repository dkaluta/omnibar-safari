#import <Foundation/Foundation.h>
#import "OmnibarURLResolver.h"
#import "SettingsTestSupport.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
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

int main(void) {
    @autoreleasepool {
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
