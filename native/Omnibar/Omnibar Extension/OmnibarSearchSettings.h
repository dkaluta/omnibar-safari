#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol OmnibarCredentialStoring <NSObject>
- (nullable NSString *)privateKagiURLWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)hasPrivateKagiURLWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)setPrivateKagiURL:(nullable NSString *)URL error:(NSError * _Nullable * _Nullable)error;
@end

// The credential store is separate so tests never access personal Keychain items.
@interface OmnibarKeychainStore : NSObject <OmnibarCredentialStoring>
@end

@interface OmnibarSearchSettings : NSObject
+ (instancetype)sharedSettings;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults credentialStore:(id<OmnibarCredentialStoring>)credentialStore;
@property (nonatomic, copy) NSString *selectedEngineID;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *searchEngines;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *customSearchEngines;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *removedDefaultSearchEngines;
- (nullable NSDictionary<NSString *, NSString *> *)saveCustomEngine:(nullable NSString *)identifier
                                                            name:(NSString *)name
                                                        template:(NSString *)URLTemplate
                                                           error:(NSError * _Nullable * _Nullable)error;
- (void)removeCustomEngineWithIdentifier:(NSString *)identifier;
// The final remaining engine cannot be removed.
- (void)removeEngineWithIdentifier:(NSString *)identifier;
- (void)restoreDefaultEngineWithIdentifier:(NSString *)identifier;
// Restore the regional default order, retaining custom engines and credentials.
- (void)restoreDefaultSearchEngines;
- (void)moveEngineWithIdentifier:(NSString *)identifier toIndex:(NSUInteger)index;
- (BOOL)saveKagiPrivateURL:(NSString *)URL error:(NSError * _Nullable * _Nullable)error;
- (BOOL)removeKagiPrivateURLWithError:(NSError * _Nullable * _Nullable)error;
- (BOOL)hasKagiPrivateURLWithError:(NSError * _Nullable * _Nullable)error;
- (nullable NSURL *)URLForInput:(NSString *)input
                  searchEngine:(NSString *)identifier
               privateBrowsing:(BOOL)privateBrowsing
                         error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
