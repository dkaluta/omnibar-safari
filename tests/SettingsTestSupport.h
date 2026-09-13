#import "OmnibarSearchSettings.h"

@interface OMTestDefaults : NSObject
@property (strong) NSMutableDictionary *values;
- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)object forKey:(NSString *)key;
@end
@implementation OMTestDefaults
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary new]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setObject:(id)object forKey:(NSString *)key { self.values[key] = object; }
@end

@interface OMTestCredentials : NSObject <OmnibarCredentialStoring>
@property (copy) NSString *URL;
@property NSUInteger reads;
@property BOOL fail;
@end
@implementation OMTestCredentials
- (BOOL)checkError:(NSError **)error {
    if (error) *error = self.fail ? [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Test Keychain unavailable."}] : nil;
    return !self.fail;
}
- (NSString *)privateKagiURLWithError:(NSError **)error { self.reads++; return [self checkError:error] ? self.URL : nil; }
- (BOOL)hasPrivateKagiURLWithError:(NSError **)error { return [self checkError:error] && self.URL.length > 0; }
- (BOOL)setPrivateKagiURL:(NSString *)URL error:(NSError **)error {
    if (![self checkError:error]) return NO;
    self.URL = URL;
    return YES;
}
@end

static OmnibarSearchSettings *OMMakeTestSettings(OMTestDefaults **defaultsResult, OMTestCredentials **credentialsResult) {
    OMTestDefaults *defaults = [OMTestDefaults new];
    defaults.values[@"searchEngine"] = @"duckduckgo";
    OMTestCredentials *credentials = [OMTestCredentials new];
    if (defaultsResult) *defaultsResult = defaults;
    if (credentialsResult) *credentialsResult = credentials;
    return [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
}
