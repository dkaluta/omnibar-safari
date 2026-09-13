#import <Foundation/Foundation.h>
#import "OmnibarURLResolver.h"

static NSUInteger checks = 0;
static NSUInteger failures = 0;

static void check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        failures++;
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    }
}

int main(void) {
    @autoreleasepool {
        NSArray<NSArray<NSString *> *> *addresses = @[
            @[@"https://example.com", @"https://example.com/"],
            @[@" HTTP://example.com/path?q=one#two ", @"http://example.com/path?q=one#two"],
            @[@"example.com", @"https://example.com/"],
            @[@"example.com:8443/path?q=hello#there", @"https://example.com:8443/path?q=hello#there"],
            @[@"example.com/search?q=hello world", @"https://example.com/search?q=hello%20world"],
            @[@"www.example.co.uk/path", @"https://www.example.co.uk/path"],
            @[@"bücher.de", @"https://xn--bcher-kva.de/"],
            @[@"localhost", @"http://localhost/"],
            @[@"localhost:3000/path", @"http://localhost:3000/path"],
            @[@"app.localhost:3000", @"http://app.localhost:3000/"],
            @[@"myserver:8080", @"http://myserver:8080/"],
            @[@"printer.local", @"http://printer.local/"],
            @[@"127.0.0.1:8080", @"http://127.0.0.1:8080/"],
            @[@"192.168.1.12", @"http://192.168.1.12/"],
            @[@"172.20.0.1", @"http://172.20.0.1/"],
            @[@"8.8.8.8", @"https://8.8.8.8/"],
            @[@"[::1]:3000/path", @"http://[::1]:3000/path"],
            @[@"::1", @"http://[::1]/"],
            @[@"2001:db8::1", @"https://[2001:db8::1]/"],
            @[@"[2001:db8::1]:8443", @"https://[2001:db8::1]:8443/"],
            @[@"https://localhost:3000", @"https://localhost:3000/"],
            @[@"//example.com/path", @"https://example.com/path"]
        ];
        for (NSArray<NSString *> *row in addresses) {
            NSError *error = nil;
            NSURL *url = [OmnibarURLResolver URLForInput:row[0] searchEngine:@"duckduckgo" error:&error];
            check([url.absoluteString isEqualToString:row[1]] && !error,
                  [NSString stringWithFormat:@"Address %@: expected %@, got %@ (%@)", row[0], row[1], url.absoluteString, error.localizedDescription]);
        }

        NSArray *queries = @[@"Safari compact mode", @"café near me", @"what is 2 + 2?", @"site:apple.com Safari",
                             @"site:apple.com", @"weather: London", @"notes: safari compact mode", @"example.com is it down",
                             @"test & unsafe=yes # fragment", @"C++ programming"];
        NSDictionary *hosts = @{ @"duckduckgo": @"duckduckgo.com", @"google": @"www.google.com", @"bing": @"www.bing.com",
            @"kagi": @"kagi.com", @"ecosia": @"www.ecosia.org", @"yandex": @"ya.ru", @"baidu": @"www.baidu.com",
            @"startpage": @"www.startpage.com", @"qwant": @"www.qwant.com", @"reddit": @"www.reddit.com",
            @"yahoo": @"search.yahoo.com", @"sogou": @"www.sogou.com", @"360search": @"www.so.com", @"yahoo-japan": @"search.yahoo.co.jp",
            @"naver": @"search.naver.com", @"seznam": @"search.seznam.cz",
            @"wolframalpha": @"www.wolframalpha.com", @"unknown": @"duckduckgo.com" };
        NSDictionary *queryNames = @{ @"yandex": @"text", @"baidu": @"wd", @"startpage": @"query", @"wolframalpha": @"i",
                                     @"yahoo": @"p", @"sogou": @"query", @"yahoo-japan": @"p", @"naver": @"query" };
        NSDictionary *encodings = @{ @"baidu": @"utf-8", @"sogou": @"utf8", @"360search": @"utf-8" };
        for (NSString *engine in hosts) {
            for (NSString *query in queries) {
                NSError *error = nil;
                NSURL *url = [OmnibarURLResolver URLForInput:query searchEngine:engine error:&error];
                NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
                NSString *queryName = queryNames[engine] ?: @"q";
                NSUInteger queryMatches = 0;
                BOOL retainedEncoding = encodings[engine] == nil;
                for (NSURLQueryItem *item in components.queryItems) {
                    if ([item.name isEqualToString:queryName] && [item.value isEqualToString:query]) queryMatches++;
                    if ([item.name isEqualToString:@"ie"] && [item.value isEqualToString:encodings[engine]]) retainedEncoding = YES;
                }
                NSUInteger expectedParameters = encodings[engine] ? 2 : 1;
                check(!error && [components.host isEqualToString:hosts[engine]] && components.queryItems.count == expectedParameters
                      && queryMatches == 1 && retainedEncoding
                      && ![components.percentEncodedQuery containsString:@"+"],
                      [NSString stringWithFormat:@"Search %@ with %@: %@ (%@)", query, engine, url, error.localizedDescription]);
            }
        }

        NSArray *invalidInputs = @[@"", @"   ", @"custom://[invalid",
            @"https://user:secret@example.com", @"user:secret@example.com", @"user@example.com", @"https://@example.com",
            @"https://example.com:99999", @"example.com:99999", @"999.999.999.999", @"https://", @"https://exa\nmple.com",
            @"https://exa mple.com", @"https://-invalid.example", @"[2001:::1]", @"https://example.com:abc",
            @"https://example.com:99999999999999999999999999999999999999"];
        for (NSString *input in invalidInputs) {
            NSError *error = nil;
            NSURL *url = [OmnibarURLResolver URLForInput:input searchEngine:@"duckduckgo" error:&error];
            check(!url && error.localizedDescription.length > 0,
                  [NSString stringWithFormat:@"Invalid input %@ should return a readable error, got %@", input, url]);
            check([OmnibarURLResolver URLForInput:input searchEngine:@"duckduckgo" error:NULL] == nil,
                  [NSString stringWithFormat:@"Invalid input %@ also handles a null error pointer", input]);
        }
        check([OmnibarURLResolver searchEngines].count == hosts.count - 1, @"All requested built-in engines are offered");
        for (NSDictionary *engine in [OmnibarURLResolver searchEngines]) {
            check([hosts.allKeys containsObject:engine[@"id"]] && [engine[@"name"] length] > 0,
                  @"Search engine entries have supported IDs and readable names");
            check([OmnibarURLResolver validatedSearchTemplate:engine[@"template"] error:NULL] != nil,
                  @"Every built-in engine provides a usable search template");
        }

        NSArray<NSArray<NSString *> *> *templates = @[
            @[@" https://example.com/search?q={searchTerms}&lang=de ", @"https://example.com/search?q=%s&lang=de"],
            @[@"https://example.com/find/%s?lang=en#results", @"https://example.com/find/%s?lang=en#results"],
            @[@"http://localhost:3000/search?q=%s", @"http://localhost:3000/search?q=%s"],
            @[@"https://bücher.de/?q=%s", @"https://xn--bcher-kva.de/?q=%s"],
            @[@"https://example.com/?fixed=a%2Bb&lang=中文&q=%s", @"https://example.com/?fixed=a%2Bb&lang=%E4%B8%AD%E6%96%87&q=%s"],
            @[@"https://example.com/?fixed=OmnibarSearchTermsPlaceholder&q=%s", @"https://example.com/?fixed=OmnibarSearchTermsPlaceholder&q=%s"]
        ];
        for (NSArray<NSString *> *row in templates) {
            NSError *error = nil;
            NSString *validated = [OmnibarURLResolver validatedSearchTemplate:row[0] error:&error];
            check([validated isEqualToString:row[1]] && !error, @"Custom search templates normalize without changing fixed parts");
        }

        NSArray<NSString *> *invalidTemplates = @[
            @"", @"https://example.com/", @"https://example.com/?q=%s&also=%s",
            @"https://example.com/?q=%s&also={searchTerms}", @"https://example.com/?q=%25s",
            @"https://%s.example.com/search", @"https://example.com:%s/search", @"https://example.com/#%s",
            @"https://user:pass@example.com/?q=%s", @"https://%s@example.com/search",
            @"javascript:%s", @"file:///search/%s", @"ftp://example.com/?q=%s",
            @"example.com/?q=%s", @"https://exa mple.com/?q=%s", @"https://example.com/?q=%s\n&x=1"
        ];
        for (NSString *value in invalidTemplates) {
            NSError *error = nil;
            NSString *result = [OmnibarURLResolver validatedSearchTemplate:value error:&error];
            check(!result && error.localizedDescription.length > 0, @"Invalid custom templates return a readable error");
            check([OmnibarURLResolver validatedSearchTemplate:value error:NULL] == nil, @"Template validation accepts a null error pointer");
        }

        NSString *specialQuery = @"café 中文 + & # / ? = %s";
        NSURL *customURL = [OmnibarURLResolver URLForInput:specialQuery
                                         searchTemplate:@"https://example.com/search?fixed=a%2Bb&q=%s&lang=de#results" error:NULL];
        NSURLComponents *customComponents = [NSURLComponents componentsWithURL:customURL resolvingAgainstBaseURL:NO];
        NSMutableDictionary<NSString *, NSString *> *customParameters = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in customComponents.queryItems) customParameters[item.name] = item.value;
        check(customComponents.queryItems.count == 3 && [customParameters[@"q"] isEqualToString:specialQuery]
              && [customParameters[@"fixed"] isEqualToString:@"a+b"] && [customParameters[@"lang"] isEqualToString:@"de"]
              && [customComponents.fragment isEqualToString:@"results"], @"Search text is encoded as one value and preserves fixed parameters and fragment");
        check([customComponents.percentEncodedQuery containsString:@"fixed=a%2Bb"] && ![customComponents.percentEncodedQuery containsString:@"+"],
              @"Fixed percent encoding is retained and literal search plus signs are escaped");
        NSURL *pathURL = [OmnibarURLResolver URLForInput:@"a/b + café" searchTemplate:@"https://example.com/find/%s?source=custom" error:NULL];
        NSURLComponents *pathComponents = [NSURLComponents componentsWithURL:pathURL resolvingAgainstBaseURL:NO];
        check([pathComponents.percentEncodedPath isEqualToString:@"/find/a%2Fb%20%2B%20caf%C3%A9"]
              && [pathComponents.queryItems.firstObject.value isEqualToString:@"custom"], @"Path search terms cannot create extra path segments");

        BOOL isSearch = YES;
        NSURL *direct = [OmnibarURLResolver URLForInput:@"example.com" searchTemplate:@"invalid template" isSearch:&isSearch error:NULL];
        check([direct.host isEqualToString:@"example.com"] && !isSearch, @"Direct addresses bypass search templates and report URL navigation");
        NSArray<NSArray<NSString *> *> *explicitURLs = @[
            @[@"about:blank", @"about:blank"],
            @[@" about:blank#section ", @"about:blank#section"],
            @[@"about:preferences", @"about:preferences"],
            @[@"file:///tmp/Omnibar%20Test.html", @"file:///tmp/Omnibar%20Test.html"],
            @[@"mailto:person@example.com?subject=Hello%20there", @"mailto:person@example.com?subject=Hello%20there"],
            @[@"tel:123", @"tel:123"],
            @[@"sms:+15551234567", @"sms:+15551234567"],
            @[@"ftp:21", @"ftp:21"],
            @[@"ftp://example.com/file", @"ftp://example.com/file"],
            @[@"custom://open/path?value=one#two", @"custom://open/path?value=one#two"],
            @[@"custom:open", @"custom:open"],
            @[@"my-app.v2+open:item", @"my-app.v2+open:item"],
            @[@"urn:isbn:9780140328721", @"urn:isbn:9780140328721"],
            @[@"javascript:alert(1)", @"javascript:alert(1)"],
            @[@"JavaScript: alert(1)", @"JavaScript:%20alert(1)"],
            @[@"data:text/plain,caf%C3%A9%20%26%20tea", @"data:text/plain,caf%C3%A9%20%26%20tea"],
            @[@"data:text/html,<p>Hello world</p>", @"data:text/html,%3Cp%3EHello%20world%3C/p%3E"]
        ];
        for (NSArray<NSString *> *row in explicitURLs) {
            NSError *error = nil;
            isSearch = YES;
            NSURL *URL = [OmnibarURLResolver URLForInput:row[0] searchTemplate:@"invalid template" isSearch:&isSearch error:&error];
            check([URL.absoluteString isEqualToString:row[1]] && !error && !isSearch,
                  [NSString stringWithFormat:@"Explicit URL %@ navigates directly without a search template, got %@", row[0], URL]);
        }
        [OmnibarURLResolver URLForInput:@"ordinary query" searchTemplate:@"https://example.com/?q=%s" isSearch:&isSearch error:NULL];
        check(isSearch, @"Actual queries report search classification");
        [OmnibarURLResolver URLForInput:@"custom://[invalid" searchTemplate:@"https://example.com/?q=%s" isSearch:&isSearch error:NULL];
        check(!isSearch, @"Malformed explicit URLs are never classified as a search");

        // All session links below contain deliberately fake test tokens.
        NSArray<NSArray<NSString *> *> *kagiLinks = @[
            @[@"https://kagi.com/search?token=FAKE_TEST_TOKEN", @"https://kagi.com/search?token=FAKE_TEST_TOKEN&q=%s"],
            @[@" kagi.com/?token=FAKE_TEST_TOKEN ", @"https://kagi.com/search?token=FAKE_TEST_TOKEN&q=%s"],
            @[@"https://www.kagi.com:443/?token=FAKE_TEST_TOKEN&q=old&q=another", @"https://kagi.com/search?token=FAKE_TEST_TOKEN&q=%s"],
            @[@"https://kagi.com/search?token=FAKE%2bTEST%2FTOKEN%3D&theme=dark&q=%s", @"https://kagi.com/search?token=FAKE%2bTEST%2FTOKEN%3D&theme=dark&q=%s"],
            @[@"https://kagi.com/search?token=FAKE%2bTEST%2FTOKEN%3D&theme=中文&q={searchTerms}", @"https://kagi.com/search?token=FAKE%2bTEST%2FTOKEN%3D&theme=%E4%B8%AD%E6%96%87&q=%s"],
            @[@"https://kagi.com/?token=FAKE_OmnibarKagiQueryPlaceholder", @"https://kagi.com/search?token=FAKE_OmnibarKagiQueryPlaceholder&q=%s"]
        ];
        for (NSArray<NSString *> *row in kagiLinks) {
            NSError *error = nil;
            NSString *normalized = [OmnibarURLResolver normalizedKagiPrivateURL:row[0] error:&error];
            check([normalized isEqualToString:row[1]] && !error, @"Kagi session link normalizes while preserving encoded fake token");
            NSURL *searched = [OmnibarURLResolver URLForInput:specialQuery searchTemplate:normalized error:NULL];
            NSURLComponents *components = [NSURLComponents componentsWithURL:searched resolvingAgainstBaseURL:NO];
            NSUInteger tokens = 0, terms = 0;
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"token"] && item.value.length) tokens++;
                if ([item.name isEqualToString:@"q"] && [item.value isEqualToString:specialQuery]) terms++;
            }
            check(tokens == 1 && terms == 1 && [components.host isEqualToString:@"kagi.com"]
                  && [components.path isEqualToString:@"/search"], @"Kagi search has one token and one correctly encoded query");
        }
        NSArray<NSString *> *invalidKagiLinks = @[
            @"", @"https://kagi.com/search", @"https://kagi.com/?token=", @"https://kagi.com/?token=%20",
            @"https://kagi.com/?token=FAKE_ONE&token=FAKE_TWO", @"https://kagi.com/?token=FAKE_ONE&%74oken=FAKE_TWO",
            @"http://kagi.com/?token=FAKE_TEST_TOKEN", @"https://example.com/?token=FAKE_TEST_TOKEN",
            @"https://kagi.com.example.com/?token=FAKE_TEST_TOKEN", @"https://user:pass@kagi.com/?token=FAKE_TEST_TOKEN",
            @"https://kagi.com/?token=FAKE_TEST_TOKEN#fragment", @"https://kagi.com:8443/?token=FAKE_TEST_TOKEN",
            @"https://kagi.com/?token=FAKE%ZZ",
            @"https://kagi.com:999999999999999999999999999999999999/?token=FAKE_TEST_TOKEN"
        ];
        for (NSString *value in invalidKagiLinks) {
            NSError *error = nil;
            NSString *result = [OmnibarURLResolver normalizedKagiPrivateURL:value error:&error];
            check(!result && error.localizedDescription.length > 0, @"Invalid Kagi links fail with a readable message");
            check(![error.localizedDescription containsString:@"FAKE_"] && ![error.localizedDescription containsString:@"pass"],
                  @"Validation errors never echo session links or credentials");
            check([OmnibarURLResolver normalizedKagiPrivateURL:value error:NULL] == nil, @"Kagi validation accepts a null error pointer");
        }

        NSArray<NSString *> *baseOrder = @[@"google", @"duckduckgo", @"bing", @"yahoo", @"ecosia", @"kagi",
            @"startpage", @"qwant", @"yandex", @"baidu", @"sogou", @"360search", @"yahoo-japan",
            @"naver", @"seznam", @"reddit", @"wolframalpha"];
        NSArray<NSDictionary<NSString *, NSString *> *> *baseCatalogue = [OmnibarURLResolver searchEnginesForRegionCode:@"US"];
        check([[baseCatalogue valueForKey:@"id"] isEqualToArray:baseOrder], @"General catalogue retains its established order");
        for (NSString *region in @[@"IL", @"GB", @"DE", @"", @"XX"]) {
            check([[OmnibarURLResolver searchEnginesForRegionCode:region] isEqualToArray:baseCatalogue],
                  @"Regions without an explicit preference use the general catalogue");
        }
        check([[OmnibarURLResolver searchEnginesForRegionCode:nil] isEqualToArray:baseCatalogue],
              @"A missing region uses the general catalogue");
        NSDictionary<NSString *, NSArray<NSString *> *> *regionalOrders = @{
            @"KR": @[@"naver"], @"CN": @[@"baidu", @"sogou", @"360search"],
            @"RU": @[@"yandex"], @"CZ": @[@"seznam"], @"JP": @[@"yahoo-japan"]
        };
        for (NSString *region in regionalOrders) {
            NSArray<NSString *> *promoted = regionalOrders[region];
            NSArray<NSDictionary<NSString *, NSString *> *> *catalogue = [OmnibarURLResolver searchEnginesForRegionCode:region];
            NSArray<NSString *> *identifiers = [catalogue valueForKey:@"id"];
            check([[identifiers subarrayWithRange:NSMakeRange(0, promoted.count)] isEqualToArray:promoted],
                  [NSString stringWithFormat:@"%@ promotes its regional engines in the intended order", region]);
            NSMutableArray<NSString *> *remaining = baseOrder.mutableCopy;
            [remaining removeObjectsInArray:promoted];
            check([[identifiers subarrayWithRange:NSMakeRange(promoted.count, identifiers.count - promoted.count)] isEqualToArray:remaining],
                  [NSString stringWithFormat:@"%@ preserves the relative order of all other engines", region]);
            check(identifiers.count == baseOrder.count && [NSSet setWithArray:identifiers].count == baseOrder.count,
                  [NSString stringWithFormat:@"%@ keeps every engine exactly once", region]);
            check([[NSSet setWithArray:catalogue] isEqualToSet:[NSSet setWithArray:baseCatalogue]],
                  [NSString stringWithFormat:@"%@ changes order without changing engine IDs, labels, or templates", region]);
            NSString *lowercaseRegion = [NSString stringWithFormat:@" %@ ", region.lowercaseString];
            check([[OmnibarURLResolver searchEnginesForRegionCode:lowercaseRegion] isEqualToArray:catalogue],
                  @"Explicit region codes accept lowercase and surrounding whitespace");
        }
        check([[OmnibarURLResolver searchEngines] isEqualToArray:
               [OmnibarURLResolver searchEnginesForRegionCode:NSLocale.currentLocale.countryCode]],
              @"Initial catalogue uses the current locale country code");
        fprintf(failures ? stderr : stdout, "%lu checks, %lu failures\n", (unsigned long)checks, (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
