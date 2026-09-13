#import "ViewController.h"
#import <SafariServices/SafariServices.h>

static NSString * const OmnibarExtensionIdentifier = @"com.dkaluta.omnibar.Extension";

@interface ViewController ()
@property (strong) NSTextField *statusLabel;
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

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 540, 500)];
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageNamed:NSImageNameApplicationIcon]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:80],
        [icon.heightAnchor constraintEqualToConstant:80]
    ]];

    NSTextField *title = [self label:@"Omnibar"
        font:[NSFont systemFontOfSize:28 weight:NSFontWeightBold] color:NSColor.labelColor];
    NSTextField *subtitle = [self label:@"Your tabs in the sidebar. Your address in the toolbar."
        font:[NSFont systemFontOfSize:14 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];
    NSTextField *instructions = [self label:
        @"Turn on Omnibar in Safari Settings → Extensions. Click its toolbar button to see the current address, open a website, or search."
        font:[NSFont systemFontOfSize:13 weight:NSFontWeightRegular] color:NSColor.labelColor];
    NSTextField *accessHint = [self label:
        @"Allow website access to display the current address. You can still open websites and search without it."
        font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];
    NSTextField *toolbarHint = [self label:
        @"If the button is hidden, choose View → Customize Toolbar in Safari and drag Omnibar into the toolbar."
        font:[NSFont systemFontOfSize:12 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];

    self.statusLabel = [self label:@"Checking extension status…"
        font:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium] color:NSColor.secondaryLabelColor];
    NSButton *settings = [NSButton buttonWithTitle:@"Open Safari Settings…" target:self action:@selector(openSafariSettings:)];
    settings.controlSize = NSControlSizeLarge;
    settings.bezelStyle = NSBezelStyleRounded;
    settings.keyEquivalent = @"\r";

    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, title, subtitle, instructions, accessHint, toolbarHint, self.statusLabel, settings]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 12;
    [stack setCustomSpacing:20 afterView:subtitle];
    [stack setCustomSpacing:20 afterView:toolbarHint];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:48],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-48],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [subtitle.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [instructions.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [accessHint.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [toolbarHint.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.statusLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
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

- (void)refreshExtensionState {
    [SFSafariExtensionManager getStateOfSafariExtensionWithIdentifier:OmnibarExtensionIdentifier
        completionHandler:^(SFSafariExtensionState *state, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error || !state) {
                    self.statusLabel.stringValue = @"Enable Omnibar in Safari to get started.";
                    self.statusLabel.textColor = NSColor.secondaryLabelColor;
                } else if (state.enabled) {
                    self.statusLabel.stringValue = @"Omnibar is enabled in Safari.";
                    self.statusLabel.textColor = NSColor.systemGreenColor;
                } else {
                    self.statusLabel.stringValue = @"Omnibar is not enabled yet.";
                    self.statusLabel.textColor = NSColor.secondaryLabelColor;
                }
            });
        }];
}

- (void)openSafariSettings:(id)sender {
    [SFSafariApplication showPreferencesForExtensionWithIdentifier:OmnibarExtensionIdentifier
        completionHandler:^(NSError *error) {
            if (!error) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Open Safari Settings";
                alert.informativeText = @"In Safari, choose Safari → Settings → Extensions, then turn on Omnibar. If it is missing, make sure this app is in your Applications folder and reopen it.";
                [alert addButtonWithTitle:@"OK"];
                [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
            });
        }];
}

@end
