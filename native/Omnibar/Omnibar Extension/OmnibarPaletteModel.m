#import "OmnibarPaletteModel.h"
#import "OmnibarURLResolver.h"

const NSUInteger OmnibarPaletteMaximumResults = 50;

@implementation OmnibarPaletteModel

+ (NSDictionary<NSString *, NSString *> *)parsedInput:(NSString *)input {
    NSString *query = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *mode = @"search";
    if ([query hasPrefix:@">"] || [query hasPrefix:@"@"]) {
        mode = [query hasPrefix:@">"] ? @"commands" : @"tabs";
        query = [[query substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return @{ @"mode": mode, @"query": query };
}

+ (nullable NSDictionary<NSString *, id> *)addressPreviewForInput:(NSString *)input defaultURLSuffix:(NSString *)defaultURLSuffix {
    NSString *value = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) return nil;
    BOOL isSearch = NO;
    NSError *error = nil;
    // The inert search template lets the resolver classify ordinary text. Its
    // resulting search URL is discarded, and this method never opens any URL.
    NSURL *URL = [OmnibarURLResolver URLForInput:value searchTemplate:@"https://example.invalid/?q=%s"
                             defaultURLSuffix:defaultURLSuffix isSearch:&isSearch error:&error];
    if (isSearch) return nil;
    NSMutableDictionary<NSString *, id> *preview = [@{ @"isAddress": @YES, @"shorthand": @([value hasPrefix:@"."]),
                                                       @"valid": @(URL != nil) } mutableCopy];
    if (URL) preview[@"destination"] = URL.absoluteString;
    else preview[@"error"] = error.localizedDescription ?: @"Check this address before opening it.";
    return preview.copy;
}

+ (NSString *)normalizedText:(id)value {
    if (![value isKindOfClass:NSString.class]) return @"";
    NSString *text = [value decomposedStringWithCompatibilityMapping];
    text = [text stringByReplacingOccurrencesOfString:@"\\p{M}+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, text.length)];
    return text.lowercaseString;
}

+ (NSInteger)scoreWords:(NSArray<NSString *> *)words fields:(NSArray<NSString *> *)fields {
    NSInteger score = 0;
    for (NSString *word in words) {
        NSInteger best = -1;
        for (NSUInteger fieldIndex = 0; fieldIndex < fields.count; fieldIndex++) {
            NSString *field = fields[fieldIndex];
            NSRange match = [field rangeOfString:word];
            if (match.location != NSNotFound) {
                BOOL boundary = match.location == 0
                    || [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[field characterAtIndex:match.location - 1]]
                    || [NSCharacterSet.punctuationCharacterSet characterIsMember:[field characterAtIndex:match.location - 1]];
                NSInteger value = [field isEqual:word] ? 120 : match.location == 0 ? 100 : boundary ? 80 : 60;
                best = MAX(best, value - (NSInteger)fieldIndex * 5);
                continue;
            }
            // Short subsequences such as rld find Reload, below exact matches.
            NSUInteger position = 0, first = NSNotFound, lastEnd = 0;
            BOOL matched = YES;
            for (NSUInteger index = 0; index < word.length;) {
                NSRange characterRange = [word rangeOfComposedCharacterSequenceAtIndex:index];
                NSString *character = [word substringWithRange:characterRange];
                NSRange next = [field rangeOfString:character options:0 range:NSMakeRange(position, field.length - position)];
                if (next.location == NSNotFound) { matched = NO; break; }
                if (first == NSNotFound) first = next.location;
                lastEnd = NSMaxRange(next);
                position = lastEnd;
                index = NSMaxRange(characterRange);
            }
            if (matched && first != NSNotFound) {
                NSUInteger gap = lastEnd - first - word.length;
                best = MAX(best, 25 - (NSInteger)MIN(gap, 15) - (NSInteger)fieldIndex * 3);
            }
        }
        if (best < 0) return -1;
        score += best;
    }
    return score;
}

+ (NSArray<NSDictionary<NSString *, id> *> *)rankedItems:(NSArray<NSDictionary<NSString *, id> *> *)items query:(NSString *)query {
    NSArray<NSString *> *words = [[[self normalizedText:query] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *word, NSDictionary *bindings) { return word.length > 0; }]];
    NSMutableArray<NSDictionary *> *bestMatches = [NSMutableArray new];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSInteger score = words.count ? [self scoreWords:words fields:@[[self normalizedText:item[@"title"]],
            [self normalizedText:item[@"subtitle"]], [self normalizedText:item[@"keywords"]]]] : 0;
        if (score < 0) continue;
        // Keep only the best 50 while still visiting every input item. Equal
        // scores insert after existing matches, preserving source order.
        NSUInteger insertion = 0;
        while (insertion < bestMatches.count && [bestMatches[insertion][@"score"] integerValue] >= score) insertion++;
        if (insertion >= OmnibarPaletteMaximumResults) continue;
        [bestMatches insertObject:@{ @"item": item, @"score": @(score) } atIndex:insertion];
        if (bestMatches.count > OmnibarPaletteMaximumResults) [bestMatches removeLastObject];
    }
    return [bestMatches valueForKey:@"item"];
}

@end
