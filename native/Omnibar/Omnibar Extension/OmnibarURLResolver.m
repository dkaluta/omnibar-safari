#import "OmnibarURLResolver.h"
#import <arpa/inet.h>

@implementation OmnibarURLResolver

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)searchEngines {
    return [self searchEnginesForRegionCode:NSLocale.currentLocale.countryCode];
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)searchEnginesForRegionCode:(nullable NSString *)regionCode {
    NSArray<NSDictionary<NSString *, NSString *> *> *catalogue = @[
        @{ @"id": @"google", @"name": @"Google", @"template": @"https://www.google.com/search?q=%s" },
        @{ @"id": @"duckduckgo", @"name": @"DuckDuckGo", @"template": @"https://duckduckgo.com/?q=%s" },
        @{ @"id": @"bing", @"name": @"Bing", @"template": @"https://www.bing.com/search?q=%s" },
        @{ @"id": @"yahoo", @"name": @"Yahoo", @"template": @"https://search.yahoo.com/search?p=%s" },
        @{ @"id": @"ecosia", @"name": @"Ecosia", @"template": @"https://www.ecosia.org/search?q=%s" },
        @{ @"id": @"kagi", @"name": @"Kagi", @"template": @"https://kagi.com/search?q=%s" },
        @{ @"id": @"startpage", @"name": @"Startpage", @"template": @"https://www.startpage.com/sp/search?query=%s" },
        @{ @"id": @"qwant", @"name": @"Qwant", @"template": @"https://www.qwant.com/?q=%s" },
        @{ @"id": @"yandex", @"name": @"Yandex", @"template": @"https://ya.ru/search/?text=%s" },
        @{ @"id": @"baidu", @"name": @"Baidu", @"template": @"https://www.baidu.com/s?ie=utf-8&wd=%s" },
        @{ @"id": @"sogou", @"name": @"Sogou", @"template": @"https://www.sogou.com/web?ie=utf8&query=%s" },
        @{ @"id": @"360search", @"name": @"360 Search", @"template": @"https://www.so.com/s?ie=utf-8&q=%s" },
        @{ @"id": @"yahoo-japan", @"name": @"Yahoo Japan", @"template": @"https://search.yahoo.co.jp/search?p=%s" },
        @{ @"id": @"naver", @"name": @"Naver", @"template": @"https://search.naver.com/search.naver?query=%s" },
        @{ @"id": @"seznam", @"name": @"Seznam", @"template": @"https://search.seznam.cz/?q=%s" },
        @{ @"id": @"reddit", @"name": @"Reddit", @"template": @"https://www.reddit.com/search/?q=%s" },
        @{ @"id": @"wolframalpha", @"name": @"WolframAlpha", @"template": @"https://www.wolframalpha.com/input?i=%s" }
    ];
    NSString *region = [[regionCode stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    NSDictionary<NSString *, NSArray<NSString *> *> *regionalEngines = @{
        @"KR": @[@"naver"],
        @"CN": @[@"baidu", @"sogou", @"360search"],
        @"RU": @[@"yandex"],
        @"CZ": @[@"seznam"],
        @"JP": @[@"yahoo-japan"]
    };
    NSArray<NSString *> *promoted = region.length ? regionalEngines[region] : nil;
    if (!promoted.count) return catalogue;

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *ordered = [NSMutableArray arrayWithCapacity:catalogue.count];
    for (NSString *identifier in promoted) {
        for (NSDictionary<NSString *, NSString *> *engine in catalogue) {
            if ([engine[@"id"] isEqualToString:identifier]) {
                [ordered addObject:engine];
                break;
            }
        }
    }
    for (NSDictionary<NSString *, NSString *> *engine in catalogue) {
        if (![promoted containsObject:engine[@"id"]]) [ordered addObject:engine];
    }
    return ordered.copy;
}

+ (BOOL)string:(NSString *)string matches:(NSString *)pattern {
    return [string rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}

+ (nullable NSURL *)fail:(NSString *)message error:(NSError * _Nullable * _Nullable)error {
    if (error) {
        *error = [NSError errorWithDomain:@"com.omnibar.URLResolver" code:1
                                userInfo:@{ NSLocalizedDescriptionKey: message }];
    }
    return nil;
}

+ (NSString *)unbracketedHost:(NSString *)host {
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"]) {
        return [host substringWithRange:NSMakeRange(1, host.length - 2)];
    }
    return host;
}

+ (BOOL)validHostname:(NSString *)hostname {
    NSString *host = [self unbracketedHost:hostname];
    if ([host containsString:@":"]) {
        struct in6_addr address;
        return inet_pton(AF_INET6, host.UTF8String, &address) == 1;
    }
    if ([self string:host matches:@"^[0-9.]+$"]) {
        struct in_addr address;
        return inet_pton(AF_INET, host.UTF8String, &address) == 1;
    }
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if (host.length == 0 || host.length > 253) return NO;
    NSMutableCharacterSet *hostnameCharacters = [NSCharacterSet alphanumericCharacterSet].mutableCopy;
    [hostnameCharacters addCharactersInString:@"-"];
    NSCharacterSet *allowed = hostnameCharacters.invertedSet;
    for (NSString *label in [host componentsSeparatedByString:@"."]) {
        if (label.length == 0 || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"]
            || [label rangeOfCharacterFromSet:allowed].location != NSNotFound) return NO;
    }
    return YES;
}

+ (BOOL)localHostname:(NSString *)hostname {
    NSString *host = [self unbracketedHost:hostname.lowercaseString];
    if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    if ([host isEqualToString:@"localhost"] || [host hasSuffix:@".localhost"] || [host hasSuffix:@".local"]) return YES;
    struct in6_addr ipv6;
    if (inet_pton(AF_INET6, host.UTF8String, &ipv6) == 1) {
        return IN6_IS_ADDR_LOOPBACK(&ipv6) || IN6_IS_ADDR_LINKLOCAL(&ipv6) || (ipv6.s6_addr[0] & 0xfe) == 0xfc;
    }
    struct in_addr ipv4;
    if (inet_pton(AF_INET, host.UTF8String, &ipv4) == 1) {
        uint32_t address = ntohl(ipv4.s_addr);
        return (address >> 24) == 127 || (address >> 24) == 10
            || (address >> 16) == 0xc0a8 || (address >> 20) == 0xac1
            || (address >> 16) == 0xa9fe;
    }
    return ![host containsString:@"."] && ![host containsString:@":"];
}

+ (BOOL)looksLikeAddress:(NSString *)value {
    NSString *authority = [value componentsSeparatedByCharactersInSet:
                           [NSCharacterSet characterSetWithCharactersInString:@"/?#"]].firstObject;
    if (!authority.length || [authority rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return NO;
    NSString *hostAndPort = [authority componentsSeparatedByString:@"@"].lastObject;
    if ([self string:hostAndPort matches:@"^\\[[0-9a-fA-F:.]+\\](?::[0-9]*)?$"]) return YES;
    NSString *host = [hostAndPort stringByReplacingOccurrencesOfString:@":[0-9]*$" withString:@""
                                                              options:NSRegularExpressionSearch range:NSMakeRange(0, hostAndPort.length)];
    if ([host containsString:@":"]) return NO;
    if ([host.lowercaseString isEqualToString:@"localhost"] || [host.lowercaseString isEqualToString:@"localhost."]) return YES;
    if ([self string:hostAndPort matches:@"^[\\p{L}\\p{N}-]+:[0-9]+$"]) return YES;
    return [self string:host matches:@"^[\\p{L}\\p{N}](?:[\\p{L}\\p{N}-]*[\\p{L}\\p{N}])?(?:\\.[\\p{L}\\p{N}](?:[\\p{L}\\p{N}-]*[\\p{L}\\p{N}])?)+\\.?$"];
}

+ (nullable NSURL *)checkedAddress:(NSString *)address
                    inferProtocol:(BOOL)inferProtocol
                            error:(NSError * _Nullable * _Nullable)error {
    NSURLComponents *components = [NSURLComponents componentsWithString:address];
    if (!components || !components.host.length || ![self validHostname:components.host]) {
        return [self fail:@"That address is not valid. Check the hostname and port." error:error];
    }
    if (![components.scheme.lowercaseString isEqualToString:@"https"] && ![components.scheme.lowercaseString isEqualToString:@"http"]) {
        return [self fail:@"Only http:// and https:// addresses can be opened." error:error];
    }
    if (components.user != nil || components.password != nil) {
        return [self fail:@"Addresses containing a username or password cannot be opened." error:error];
    }
    // Inspect the text because NSURLComponents.port is nil for numbers too large for NSNumber.
    NSRange portRange = components.rangeOfPort;
    if (portRange.location != NSNotFound) {
        NSString *portText = [components.string substringWithRange:portRange];
        NSUInteger port = 0;
        for (NSUInteger index = 0; index < portText.length; index++) {
            unichar digit = [portText characterAtIndex:index];
            if (digit < '0' || digit > '9' || (port = port * 10 + digit - '0') > 65535) {
                return [self fail:@"The port must be between 0 and 65535." error:error];
            }
        }
    }
    if (inferProtocol) components.scheme = [self localHostname:components.host] ? @"http" : @"https";
    else components.scheme = components.scheme.lowercaseString;
    if (!components.path.length) components.path = @"/";
    NSURL *url = components.URL;
    if (!url) return [self fail:@"That address is not valid. Check the hostname and port." error:error];
    return url;
}

+ (nullable NSURL *)URLForInput:(NSString *)input
                  searchEngine:(NSString *)engine
                         error:(NSError * _Nullable * _Nullable)error {
    NSArray<NSDictionary<NSString *, NSString *> *> *engines = self.searchEngines;
    // Keep this compatibility API's historical unknown-ID fallback. Saved user ordering
    // and the default for new installations are managed by the engine store.
    NSString *searchTemplate = @"https://duckduckgo.com/?q=%s";
    for (NSDictionary<NSString *, NSString *> *item in engines) {
        if ([item[@"id"] isEqualToString:engine]) {
            searchTemplate = item[@"template"];
            break;
        }
    }
    return [self URLForInput:input searchTemplate:searchTemplate error:error];
}

+ (nullable NSURL *)URLForInput:(NSString *)input
                searchTemplate:(NSString *)searchTemplate
                         error:(NSError * _Nullable * _Nullable)error {
    return [self URLForInput:input searchTemplate:searchTemplate isSearch:NULL error:error];
}

+ (nullable NSURL *)explicitURL:(NSString *)value error:(NSError * _Nullable * _Nullable)error {
    NSURL *URL = [NSURL URLWithString:value];
    if (!URL.scheme.length) return [self fail:@"That URL is not valid. Check the address." error:error];
    // Safari owns scheme handling and any permission or external-app prompts.
    return URL;
}

+ (nullable NSURL *)URLForInput:(NSString *)input
                searchTemplate:(NSString *)searchTemplate
                      isSearch:(BOOL * _Nullable)isSearch
                         error:(NSError * _Nullable * _Nullable)error {
    if (error) *error = nil;
    if (isSearch) *isSearch = NO;
    NSString *value = [[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                      precomposedStringWithCanonicalMapping];
    if (!value.length) return [self fail:@"Enter an address or search terms." error:error];
    if ([value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return [self fail:@"Remove line breaks or control characters from the address." error:error];
    }
    if ([self string:value matches:@"(?i)^https?:"]) {
        return [self checkedAddress:value inferProtocol:NO error:error];
    }
    if ([value hasPrefix:@"//"]) {
        return [self checkedAddress:[@"https:" stringByAppendingString:value] inferProtocol:NO error:error];
    }
    NSRange schemeRange = [value rangeOfString:@"(?i)^[a-z][a-z0-9+.-]*:" options:NSRegularExpressionSearch];
    NSString *scheme = schemeRange.location != NSNotFound ? [[value substringToIndex:schemeRange.length - 1] lowercaseString] : nil;
    NSSet *knownSchemes = [NSSet setWithArray:@[
        @"javascript", @"data", @"file", @"vbscript", @"about", @"blob", @"mailto", @"tel", @"sms",
        @"ftp", @"ftps", @"ssh", @"sftp", @"ws", @"wss", @"chrome", @"chrome-extension",
        @"safari-extension", @"safari-web-extension", @"moz-extension", @"view-source"
    ]];
    // Known schemes take precedence over ambiguous host:port text such as "tel:123".
    // This is not an allowlist: other explicit schemes are handled below.
    if (scheme && [knownSchemes containsObject:scheme]) {
        return [self explicitURL:value error:error];
    }
    BOOL bareIPv6 = [self string:value matches:@"^[0-9a-fA-F:]+$"] && [value componentsSeparatedByString:@":"].count >= 3;
    NSString *address = bareIPv6 ? [NSString stringWithFormat:@"[%@]", value] : value;
    if (bareIPv6 || [self looksLikeAddress:address]) {
        return [self checkedAddress:[@"https://" stringByAppendingString:address] inferProtocol:YES error:error];
    }
    if (schemeRange.location != NSNotFound) {
        NSString *remainder = [value substringFromIndex:schemeRange.length];
        NSSet *operators = [NSSet setWithArray:@[
            @"site", @"intitle", @"inurl", @"intext", @"allintitle", @"allinurl", @"allintext", @"filetype",
            @"ext", @"before", @"after", @"related", @"define", @"cache", @"source"
        ]];
        BOOL ordinaryPhrase = [remainder rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound;
        if ([remainder hasPrefix:@"//"]
            || (![operators containsObject:scheme] && !ordinaryPhrase)) {
            return [self explicitURL:value error:error];
        }
    }
    if (isSearch) *isSearch = YES;
    NSString *validated = [self validatedSearchTemplate:searchTemplate error:error];
    if (!validated) return nil;
    // Encode as one URL component, including +, /, &, and #. This works in paths and queries
    // without letting search text create another parameter, path segment, or fragment.
    NSCharacterSet *unreserved = [NSCharacterSet characterSetWithCharactersInString:
                                 @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSString *encoded = [value stringByAddingPercentEncodingWithAllowedCharacters:unreserved];
    if (!encoded) return [self fail:@"The search text could not be encoded." error:error];
    NSString *destination = [validated stringByReplacingOccurrencesOfString:@"%s" withString:encoded];
    return [self checkedAddress:destination inferProtocol:NO error:error];
}

+ (nullable NSString *)validatedSearchTemplate:(NSString *)searchTemplate
                                         error:(NSError * _Nullable * _Nullable)error {
    if (error) *error = nil;
    NSString *value = [searchTemplate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        [self fail:@"Enter a search URL containing one %s or {searchTerms} placeholder." error:error];
        return nil;
    }
    value = [value stringByReplacingOccurrencesOfString:@"{searchTerms}" withString:@"%s"];
    if ([value componentsSeparatedByString:@"%s"].count != 2) {
        [self fail:@"The search URL must contain exactly one %s or {searchTerms} placeholder." error:error];
        return nil;
    }
    NSString *marker = @"OmnibarSearchTermsPlaceholder";
    while ([value containsString:marker]) marker = [marker stringByAppendingString:@"X"];
    NSString *probe = [value stringByReplacingOccurrencesOfString:@"%s" withString:marker];
    if ([self string:probe matches:@"%(?![0-9a-fA-F]{2})"]) {
        [self fail:@"Use valid percent escapes in the search URL, apart from the %s placeholder." error:error];
        return nil;
    }
    // Foundation re-encodes existing escapes when it also encounters raw Unicode or
    // spaces. Encode those characters first while retaining existing escapes and URL delimiters.
    NSMutableCharacterSet *URLCharacters = NSCharacterSet.URLFragmentAllowedCharacterSet.mutableCopy;
    [URLCharacters addCharactersInString:@"%#[]"];
    probe = [probe stringByAddingPercentEncodingWithAllowedCharacters:URLCharacters];
    NSURL *URL = [self checkedAddress:probe inferProtocol:NO error:error];
    if (!URL) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (![components.percentEncodedPath containsString:marker] && ![components.percentEncodedQuery containsString:marker]) {
        [self fail:@"Put the search placeholder in the URL path or query, after the website name." error:error];
        return nil;
    }
    // Reassigning the decoded host canonicalizes a Unicode hostname to its IDN form.
    components.host = components.host;
    return [components.URL.absoluteString stringByReplacingOccurrencesOfString:marker withString:@"%s"];
}

+ (nullable NSString *)normalizedKagiPrivateURL:(NSString *)URLString
                                         error:(NSError * _Nullable * _Nullable)error {
    if (error) *error = nil;
    NSString *value = [URLString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *message = @"Enter a private session link from Kagi with one nonempty token, using https://kagi.com.";
    if (!value.length || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        [self fail:message error:error];
        return nil;
    }
    if ([self string:value matches:@"(?i)^(?:www\\.)?kagi\\.com(?:[/?]|$)"]) {
        value = [@"https://" stringByAppendingString:value];
    }
    NSRange questionMark = [value rangeOfString:@"?"];
    NSString *base = questionMark.location == NSNotFound ? value : [value substringToIndex:questionMark.location];
    NSString *rawQuery = questionMark.location == NSNotFound ? @"" : [value substringFromIndex:questionMark.location + 1];
    if ([value containsString:@"#"]) {
        [self fail:message error:error];
        return nil;
    }
    // Parse the base separately: an existing q=%s placeholder makes Foundation treat the
    // whole query as unescaped text, which would otherwise double-encode the session token.
    rawQuery = [[rawQuery stringByReplacingOccurrencesOfString:@"%s" withString:@"%25s"]
                stringByReplacingOccurrencesOfString:@"{searchTerms}" withString:@"%7BsearchTerms%7D"];
    if ([self string:rawQuery matches:@"%(?![0-9a-fA-F]{2})"]) {
        [self fail:message error:error];
        return nil;
    }
    NSMutableCharacterSet *queryCharacters = NSCharacterSet.URLQueryAllowedCharacterSet.mutableCopy;
    [queryCharacters addCharactersInString:@"%"];
    NSString *encodedQuery = [rawQuery stringByAddingPercentEncodingWithAllowedCharacters:queryCharacters];
    NSURLComponents *components = [NSURLComponents componentsWithString:base];
    components.percentEncodedQuery = encodedQuery;
    NSString *host = components.host.lowercaseString;
    if (!components || ![components.scheme.lowercaseString isEqualToString:@"https"]
        || (![@"kagi.com" isEqualToString:host] && ![@"www.kagi.com" isEqualToString:host])
        || components.user != nil || components.password != nil || components.fragment != nil
        || (components.rangeOfPort.location != NSNotFound && ![components.port isEqualToNumber:@443])) {
        [self fail:message error:error];
        return nil;
    }

    NSUInteger tokens = 0;
    NSMutableArray<NSString *> *parameters = [NSMutableArray array];
    for (NSString *pair in [components.percentEncodedQuery componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSRange separator = [pair rangeOfString:@"="];
        NSString *encodedName = separator.location == NSNotFound ? pair : [pair substringToIndex:separator.location];
        NSString *name = encodedName.stringByRemovingPercentEncoding;
        if ([name isEqualToString:@"q"]) continue;
        if ([name isEqualToString:@"token"]) {
            tokens++;
            NSString *token = separator.location == NSNotFound ? @"" : [pair substringFromIndex:separator.location + 1];
            NSString *decoded = token.stringByRemovingPercentEncoding;
            if (![[decoded stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) {
                [self fail:message error:error];
                return nil;
            }
        }
        [parameters addObject:pair];
    }
    if (tokens != 1) {
        [self fail:message error:error];
        return nil;
    }
    components.scheme = @"https";
    components.host = @"kagi.com";
    components.port = nil;
    components.path = @"/search";
    // Keep the original percent-encoded token rather than decoding and re-encoding it.
    // Kagi documents this format at help.kagi.com/kagi/privacy/private-browser-sessions.html.
    NSString *marker = @"OmnibarKagiQueryPlaceholder";
    while ([value containsString:marker]) marker = [marker stringByAppendingString:@"X"];
    [parameters addObject:[@"q=" stringByAppendingString:marker]];
    components.percentEncodedQuery = [parameters componentsJoinedByString:@"&"];
    NSString *normalized = [components.URL.absoluteString stringByReplacingOccurrencesOfString:
                            marker withString:@"%s"];
    return [self validatedSearchTemplate:normalized error:error];
}

@end
