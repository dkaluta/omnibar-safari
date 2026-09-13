#import <Foundation/Foundation.h>
#import "OmnibarURLResolver.h"
#import "SettingsTestSupport.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
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
