#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "OmnibarSearchSettings.h"

// This subclass never calls the production query. Every operation, including
// cleanup, is confined to one fresh test-only service and account.
@interface IsolatedKeychainStore : OmnibarKeychainStore
@property (nonatomic, copy, readonly) NSString *testService;
- (NSMutableDictionary *)query;
@end

@implementation IsolatedKeychainStore

- (instancetype)init {
    if ((self = [super init])) {
        _testService = [@"com.dkaluta.omnibar.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
    }
    return self;
}

- (NSMutableDictionary *)query {
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService: self.testService,
              (__bridge id)kSecAttrAccount: @"TEST_ONLY-private-session-url"} mutableCopy];
}

@end

static NSUInteger checkCount = 0;

static void Check(BOOL condition, NSString *step) {
    checkCount++;
    if (!condition) {
        // Step names are fixed strings. Never include returned data or URLs.
        @throw [NSException exceptionWithName:@"KeychainIntegrationFailure" reason:step userInfo:nil];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || strcmp(argv[1], "--run") != 0) {
            fprintf(stderr, "Opt in with scripts/test-keychain-integration.sh --run.\n");
            return 2;
        }

        // The production store uses the legacy macOS Keychain. Suppress optional
        // UI in this test process so a locked Keychain fails instead of waiting
        // for an unattended unlock prompt. This does not change system settings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        OSStatus interactionStatus = SecKeychainSetUserInteractionAllowed(false);
#pragma clang diagnostic pop
        if (interactionStatus != errSecSuccess) {
            fprintf(stderr, "Cannot run noninteractive Keychain test (status %d).\n", (int)interactionStatus);
            return 1;
        }

        IsolatedKeychainStore *store = [IsolatedKeychainStore new];
        NSString *first = @"https://kagi.com/search?token=TEST_ONLY_NEVER_VALID_FIRST&q=%s";
        NSString *second = @"https://kagi.com/search?token=TEST_ONLY_NEVER_VALID_SECOND&q=%s";
        BOOL passed = YES;

        @try {
            NSError *error = nil;
            BOOL present = [store hasPrivateKagiURLWithError:&error];
            Check(!present && error == nil, @"initial item is absent");
            NSString *value = [store privateKagiURLWithError:&error];
            Check(value == nil && error == nil, @"initial read is empty");

            BOOL saved = [store setPrivateKagiURL:first error:&error];
            Check(saved && error == nil, @"add test item");
            present = [store hasPrivateKagiURLWithError:&error];
            Check(present && error == nil, @"find added test item");
            value = [store privateKagiURLWithError:&error];
            Check([value isEqualToString:first] && error == nil, @"read added test item");

            saved = [store setPrivateKagiURL:second error:&error];
            Check(saved && error == nil, @"update test item");
            value = [store privateKagiURLWithError:&error];
            Check([value isEqualToString:second] && error == nil, @"read updated test item");

            BOOL removed = [store setPrivateKagiURL:nil error:&error];
            Check(removed && error == nil, @"delete test item");
            present = [store hasPrivateKagiURLWithError:&error];
            Check(!present && error == nil, @"deleted test item is absent");
            value = [store privateKagiURLWithError:&error];
            Check(value == nil && error == nil, @"deleted test item cannot be read");
            removed = [store setPrivateKagiURL:nil error:&error];
            Check(removed && error == nil, @"deleting absent test item succeeds");
        } @catch (NSException *exception) {
            passed = NO;
            // Only our fixed assertion labels are printed. Framework exception
            // descriptions could contain data, so replace those with a generic label.
            const char *step = [exception.name isEqualToString:@"KeychainIntegrationFailure"]
                ? exception.reason.UTF8String : "unexpected framework exception";
            fprintf(stderr, "FAIL: %s.\n", step);
        } @finally {
            OSStatus cleanup = SecItemDelete((__bridge CFDictionaryRef)[store query]);
            if (cleanup != errSecSuccess && cleanup != errSecItemNotFound) {
                passed = NO;
                fprintf(stderr, "Test item cleanup failed for service %s (status %d).\n",
                    store.testService.UTF8String, (int)cleanup);
            } else {
                NSMutableDictionary *query = [store query];
                query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
                OSStatus absent = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
                if (absent != errSecItemNotFound) {
                    passed = NO;
                    fprintf(stderr, "Could not verify test item cleanup for service %s (status %d).\n",
                        store.testService.UTF8String, (int)absent);
                }
            }
        }

        if (passed) printf("PASS: %lu real Keychain checks; isolated test item removed.\n", (unsigned long)checkCount);
        return passed ? 0 : 1;
    }
}
