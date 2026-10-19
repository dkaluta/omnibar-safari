#import <UIKit/UIKit.h>
@class OmnibarSearchSettings;
NS_ASSUME_NONNULL_BEGIN
@interface SettingsViewController : UITableViewController
- (instancetype)initWithSettings:(nullable OmnibarSearchSettings *)settings;
- (void)clearSensitiveInput;
- (void)refreshSettings;
@end
NS_ASSUME_NONNULL_END
