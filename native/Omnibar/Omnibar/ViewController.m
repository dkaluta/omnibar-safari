#import "ViewController.h"
#import "OmnibarSettingsRouteDiagnostics.h"
#import "../Omnibar Extension/OmnibarPalettePreferences.h"
#import "../Omnibar Extension/OmnibarSearchSettings.h"
#import "../Omnibar Extension/SearchSettingsController.h"
#import <SafariServices/SafariServices.h>

static NSString *OmnibarExtensionIdentifier(NSString *suffix) {
    return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:suffix];
}

@interface ViewController ()
@property (strong) NSTextField *statusLabel;
@property (strong) NSTextField *commandsStatusLabel;
@property (strong) NSButton *paletteTipsButton;
@property (strong) NSView *setupContent;
@property (strong) NSTextField *migrationLabel;
@property (strong) SearchSettingsController *settingsController;
@end

@implementation ViewController

- (NSTextField *)label:(NSString *)text font:(NSFont *)font color:(NSColor *)color {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = font;
    label.textColor = color;
    label.alignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (NSStackView *)extensionSectionWithTitle:(NSString *)name
                             description:(NSString *)description
                                  status:(NSTextField *)status
                                  action:(SEL)action
                         secondaryButton:(NSButton *)secondaryButton {
    NSTextField *title = [self label:name
        font:[NSFont systemFontOfSize:15 weight:NSFontWeightSemibold] color:NSColor.labelColor];
    NSTextField *detail = [self label:description
        font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];
    NSButton *settings = [NSButton buttonWithTitle:[NSString stringWithFormat:@"Set Up %@…", name]
        target:self action:action];
    settings.bezelStyle = NSBezelStyleRounded;
    NSView *actions = settings;
    if (secondaryButton) {
        NSStackView *buttons = [NSStackView stackViewWithViews:@[settings, secondaryButton]];
        buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        buttons.spacing = 8;
        actions = buttons;
    }
    NSStackView *section = [NSStackView stackViewWithViews:@[title, detail, status, actions]];
    section.orientation = NSUserInterfaceLayoutOrientationVertical;
    section.alignment = NSLayoutAttributeCenterX;
    section.spacing = 5;
    section.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [detail.widthAnchor constraintEqualToAnchor:section.widthAnchor],
        [status.widthAnchor constraintEqualToAnchor:section.widthAnchor]
    ]];
    return section;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 560)];
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageNamed:NSImageNameApplicationIcon]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:56],
        [icon.heightAnchor constraintEqualToConstant:56]
    ]];

    NSTextField *title = [self label:@"Omnibar"
        font:[NSFont systemFontOfSize:26 weight:NSFontWeightBold] color:NSColor.labelColor];
    NSTextField *subtitle = [self label:@"Two Safari extensions in one app. Enable either or both."
        font:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];

    self.statusLabel = [self label:@"Checking extension status…"
        font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium] color:NSColor.secondaryLabelColor];
    self.commandsStatusLabel = [self label:@"Checking extension status…"
        font:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium] color:NSColor.secondaryLabelColor];
    self.paletteTipsButton = [NSButton buttonWithTitle:@"Show Palette Tips Again" target:self action:@selector(showPaletteTipsAgain:)];
    self.paletteTipsButton.bezelStyle = NSBezelStyleRounded;
    self.paletteTipsButton.toolTip = @"Show the introduction the next time you open the command palette on this Mac.";
    NSButton *searchSettings = [NSButton buttonWithTitle:@"Search Settings…" target:self action:@selector(showSearchSettings:)];
    searchSettings.bezelStyle = NSBezelStyleRounded;
    searchSettings.toolTip = @"Manage search engines, website suffix, and private search. Neither Safari extension needs to be enabled.";

    NSStackView *addressSection = [self extensionSectionWithTitle:@"Omnibar"
        description:@"The native toolbar palette for addresses, search, tabs, and commands. Allow website access to display the current address."
        status:self.statusLabel action:@selector(openSafariSettings:) secondaryButton:searchSettings];
    NSStackView *commandsSection = [self extensionSectionWithTitle:@"Omnibar Commands"
        description:@"Press ⌘⇧P on a webpage for the centered keyboard palette. This extension has no toolbar palette."
        status:self.commandsStatusLabel action:@selector(openCommandsSettings:) secondaryButton:nil];
    NSTextField *privacy = [self label:@"No analytics or browsing data is sent to the developer. Searches go to the search provider you choose."
        font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];
    NSTextField *toolbarHint = [self label:@"Use the native Omnibar toolbar button on Safari’s Start Page and other pages that block the keyboard palette."
        font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];
    self.migrationLabel = [self label:@"Upgrading from the original extension? Open its Search Settings once to import saved settings. You can also configure new settings here."
        font:[NSFont systemFontOfSize:11 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];
    self.migrationLabel.hidden = ![self searchSettings].sharedPreferencesMigrationPending;

    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, title, subtitle, addressSection, commandsSection, self.migrationLabel, self.paletteTipsButton, privacy, toolbarHint]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 9;
    [stack setCustomSpacing:17 afterView:subtitle];
    [stack setCustomSpacing:17 afterView:addressSection];
    [stack setCustomSpacing:17 afterView:commandsSection];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    self.setupContent = stack;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:44],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-44],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [subtitle.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [addressSection.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [commandsSection.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.migrationLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [privacy.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [toolbarHint.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshExtensionState)
        name:NSApplicationDidBecomeActiveNotification object:nil];
    [self refreshExtensionState];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)refreshStateForExtension:(NSString *)identifier name:(NSString *)name label:(NSTextField *)label {
    [SFSafariExtensionManager getStateOfSafariExtensionWithIdentifier:identifier
        completionHandler:^(SFSafariExtensionState *state, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || !state) {
                    label.stringValue = [NSString stringWithFormat:@"Enable %@ in Safari to get started.", name];
                    label.textColor = NSColor.secondaryLabelColor;
                } else if (state.enabled) {
                    label.stringValue = [NSString stringWithFormat:@"%@ is enabled in Safari.", name];
                    label.textColor = NSColor.systemGreenColor;
                } else {
                    label.stringValue = [NSString stringWithFormat:@"%@ is not enabled yet.", name];
                    label.textColor = NSColor.secondaryLabelColor;
                }
            });
        }];
}

- (void)refreshExtensionState {
    self.migrationLabel.hidden = ![self searchSettings].sharedPreferencesMigrationPending;
    self.paletteTipsButton.title = @"Show Palette Tips Again";
    self.paletteTipsButton.enabled = YES;
    [self refreshStateForExtension:OmnibarExtensionIdentifier(@".Extension") name:@"Omnibar" label:self.statusLabel];
    [self refreshStateForExtension:OmnibarExtensionIdentifier(@".Commands") name:@"Omnibar Commands" label:self.commandsStatusLabel];
}

- (OmnibarSearchSettings *)searchSettings { return OmnibarSearchSettings.sharedSettings; }

- (void)showSearchSettings:(id)sender {
    (void)self.view;
    if (self.settingsController) { OmnibarTraceSettingsRoute(250); return; }
    OmnibarSearchSettings *settings = [self searchSettings];
    if (settings.sharedConfigurationError) {
        OmnibarTraceSettingsRoute(251); // Shared configuration rejected.
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Search Settings Unavailable";
        alert.informativeText = @"Omnibar’s shared settings could not be opened. Reinstall the signed app and try again.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
        return;
    }
    self.settingsController = [[SearchSettingsController alloc] initWithSettings:settings];
    __weak typeof(self) weakSelf = self;
    self.settingsController.onDone = ^{ [weakSelf closeSearchSettings]; };
    [self addChildViewController:self.settingsController];
    NSView *view = self.settingsController.view;
    view.frame = self.view.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.setupContent.hidden = YES;
    [self.view addSubview:view];
    self.view.window.title = @"Omnibar — Search Settings";
    OmnibarTraceSettingsRoute(252); // Settings view installed in app window.
}

- (void)closeSearchSettings {
    if (!self.settingsController) return;
    [self.settingsController resetSensitiveFields];
    self.settingsController.onDone = nil;
    [self.settingsController.view removeFromSuperview];
    [self.settingsController removeFromParentViewController];
    self.settingsController = nil;
    self.setupContent.hidden = NO;
    self.migrationLabel.hidden = ![self searchSettings].sharedPreferencesMigrationPending;
    self.view.window.title = @"Omnibar";
}

- (void)viewWillDisappear {
    [self.settingsController resetSensitiveFields];
    [super viewWillDisappear];
}

- (void)showPaletteTipsAgain:(id)sender {
    NSString *group = NSBundle.mainBundle.infoDictionary[@"OmnibarSharedGroup"];
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (![group isKindOfClass:NSString.class] || !identifier.length
        || ![group isEqual:[@"group." stringByAppendingString:identifier]]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Palette Settings Unavailable";
        alert.informativeText = @"Omnibar’s shared settings could not be opened. Reinstall the signed app and try again.";
        [alert addButtonWithTitle:@"OK"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
        return;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:group];
    OmnibarSetShowPaletteTips(defaults, YES);
    self.paletteTipsButton.title = @"Tips Will Show Next Time";
    self.paletteTipsButton.enabled = NO;
}

- (void)showSettingsForExtension:(NSString *)identifier name:(NSString *)name {
    [SFSafariApplication showPreferencesForExtensionWithIdentifier:identifier
        completionHandler:^(NSError *error) {
            if (!error) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Open Safari Settings";
                alert.informativeText = [NSString stringWithFormat:@"In Safari, choose Safari → Settings → Extensions, then turn on %@. If it is missing, make sure this app is in your Applications folder and reopen it.", name];
                [alert addButtonWithTitle:@"OK"];
                [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
            });
        }];
}

- (void)openSafariSettings:(id)sender {
    [self showSettingsForExtension:OmnibarExtensionIdentifier(@".Extension") name:@"Omnibar"];
}

- (void)openCommandsSettings:(id)sender {
    [self showSettingsForExtension:OmnibarExtensionIdentifier(@".Commands") name:@"Omnibar Commands"];
}

@end
