#import <AppKit/AppKit.h>

@class OmnibarSearchSettings;

NS_ASSUME_NONNULL_BEGIN

@interface SearchSettingsController : NSViewController
- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings;
@property (nonatomic, copy, nullable) void (^onDone)(void);
- (void)resetSensitiveFields;
@end

NS_ASSUME_NONNULL_END
