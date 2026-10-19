#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSUInteger OmnibarPaletteMaximumResults;

// Pure local presentation logic: no preferences, Safari calls, credential
// access, network requests, or retained query/tab state.
@interface OmnibarPaletteModel : NSObject

// Returns mode (search, commands, or tabs) and query, consuming one leading
// > or @ marker. The controller decides when to apply a mode transition.
+ (NSDictionary<NSString *, NSString *> *)parsedInput:(NSString *)input;

// nil means ordinary search text or empty input. Address-shaped input returns
// isAddress, shorthand, valid, and either destination or a safe error string.
// Uses the authoritative native resolver without consulting a search engine.
+ (nullable NSDictionary<NSString *, id> *)addressPreviewForInput:(NSString *)input
                                               defaultURLSuffix:(NSString *)defaultURLSuffix;

// Searches every item, returning at most 50, best match first. Fields title,
// subtitle, and keywords are strings. Original item dictionaries and metadata
// are preserved; equally ranked items retain their original order.
+ (NSArray<NSDictionary<NSString *, id> *> *)rankedItems:(NSArray<NSDictionary<NSString *, id> *> *)items
                                                 query:(NSString *)query;

@end

NS_ASSUME_NONNULL_END
