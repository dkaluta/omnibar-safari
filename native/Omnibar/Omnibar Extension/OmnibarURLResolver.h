#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OmnibarURLResolver : NSObject

+ (nullable NSURL *)URLForInput:(NSString *)input
                  searchEngine:(NSString *)engine
                         error:(NSError * _Nullable * _Nullable)error;

+ (nullable NSURL *)URLForInput:(NSString *)input
                searchTemplate:(NSString *)searchTemplate
                         error:(NSError * _Nullable * _Nullable)error;

+ (nullable NSURL *)URLForInput:(NSString *)input
                searchTemplate:(NSString *)searchTemplate
                      isSearch:(BOOL * _Nullable)isSearch
                         error:(NSError * _Nullable * _Nullable)error;

+ (nullable NSURL *)URLForInput:(NSString *)input
                searchTemplate:(NSString *)searchTemplate
              defaultURLSuffix:(NSString *)defaultURLSuffix
                      isSearch:(BOOL * _Nullable)isSearch
                         error:(NSError * _Nullable * _Nullable)error;

// Accepts com or .co.uk and returns a lowercase, dot-prefixed DNS suffix.
+ (nullable NSString *)validatedDefaultURLSuffix:(NSString *)suffix
                                          error:(NSError * _Nullable * _Nullable)error;

+ (nullable NSString *)validatedSearchTemplate:(NSString *)searchTemplate
                                         error:(NSError * _Nullable * _Nullable)error;

+ (nullable NSString *)normalizedKagiPrivateURL:(NSString *)URL
                                         error:(NSError * _Nullable * _Nullable)error;

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)searchEngines;

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)searchEnginesForRegionCode:(nullable NSString *)regionCode;

@end

NS_ASSUME_NONNULL_END
