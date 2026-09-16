#import "AddressPopoverController.h"
#import "OmnibarURLResolver.h"
#import "OmnibarSearchSettings.h"
#import "SearchSettingsController.h"
#import <AppKit/AppKit.h>

static NSString * const OmnibarKeyboardHint = @"Return to go · ⌘Return to open a new tab";
static const CGFloat OmnibarWidth = 520;
static const CGFloat OmnibarHeight = 100;

static BOOL OmnibarIsCommandReturn(NSEvent *event) {
    if (event.type != NSEventTypeKeyDown) return NO;
    NSEventModifierFlags modifiers = event.modifierFlags;
    BOOL commandOnly = (modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) == NSEventModifierFlagCommand;
    return commandOnly && (event.keyCode == 36 || event.keyCode == 76);
}

@interface OmnibarAddressField : NSTextField
@end

@interface OmnibarAddressContainer : NSView
@property (nonatomic, weak) NSTextField *addressField;
@end

@implementation OmnibarAddressContainer
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (self.window) {
        for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification]) {
            [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(focusChanged:) name:name object:self.window];
        }
    }
    self.needsDisplay = YES;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)focusChanged:(NSNotification *)notification { self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.addressField.enabled) return;
    [self.window makeFirstResponder:self.addressField];
    [self.addressField selectText:nil];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:9 yRadius:9];
    [NSColor.textBackgroundColor setFill];
    [shape fill];
    BOOL editing = self.window.isKeyWindow && self.addressField.currentEditor != nil;
    [(editing ? NSColor.controlAccentColor : NSColor.separatorColor) setStroke];
    shape.lineWidth = editing ? 2 : 1;
    [shape stroke];
}
@end

@interface AddressPopoverController () <NSTextFieldDelegate>
@property (nonatomic, strong) NSTextField *addressField;
@property (nonatomic, strong) NSButton *goButton;
@property (nonatomic, strong) NSPopUpButton *engineButton;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *settingsButton;
@property (nonatomic, strong) NSView *addressContent;
@property (nonatomic, strong) OmnibarSearchSettings *searchSettings;
@property (nonatomic, strong) SearchSettingsController *settingsController;
@property (nonatomic) BOOL showingSettings;
@property (nonatomic) BOOL privateBrowsing;
@property (nonatomic) BOOL resolvingNavigation;
@property (nonatomic, strong, nullable) SFSafariWindow *sessionWindow;
@property (nonatomic, strong, nullable) SFSafariTab *sessionTab;
@property (nonatomic) NSUInteger sessionGeneration;
@property (nonatomic) BOOL userEditedAddress;
@property (nonatomic) BOOL resolvedAddress;
@property (nonatomic) BOOL selectedAddress;
@property (nonatomic) BOOL openingTab;
@property (nonatomic) BOOL loadingTab;
- (void)openInNewTab:(id)sender;
- (void)navigateInNewTab:(BOOL)newTab;
@end

@implementation OmnibarAddressField

- (void)refreshFocusAppearance {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.superview.needsDisplay = YES; });
}

- (BOOL)becomeFirstResponder {
    BOOL accepted = [super becomeFirstResponder];
    [self refreshFocusAppearance];
    return accepted;
}

- (BOOL)resignFirstResponder {
    BOOL resigned = [super resignFirstResponder];
    [self refreshFocusAppearance];
    return resigned;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.currentEditor && OmnibarIsCommandReturn(event)) {
        return [NSApp sendAction:@selector(openInNewTab:) to:self.target from:self];
    }
    return [super performKeyEquivalent:event];
}

@end

@implementation AddressPopoverController

+ (instancetype)sharedController {
    static AddressPopoverController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] initWithNibName:nil bundle:nil];
    });
    return controller;
}

- (void)loadView {
    self.preferredContentSize = NSMakeSize(OmnibarWidth, OmnibarHeight);
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, OmnibarWidth, OmnibarHeight)];
    self.addressContent = [[NSView alloc] initWithFrame:self.view.bounds];
    self.addressContent.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.view addSubview:self.addressContent];
    if (!self.searchSettings) self.searchSettings = OmnibarSearchSettings.sharedSettings;

    OmnibarAddressContainer *entry = [[OmnibarAddressContainer alloc] initWithFrame:NSZeroRect];
    entry.translatesAutoresizingMaskIntoConstraints = NO;
    NSImageView *symbol = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil]];
    symbol.translatesAutoresizingMaskIntoConstraints = NO;
    symbol.contentTintColor = NSColor.secondaryLabelColor;
    symbol.accessibilityHidden = YES;

    NSTextField *address = [[OmnibarAddressField alloc] initWithFrame:NSZeroRect];
    address.translatesAutoresizingMaskIntoConstraints = NO;
    address.editable = YES;
    address.selectable = YES;
    address.bezeled = NO;
    address.drawsBackground = NO;
    address.focusRingType = NSFocusRingTypeNone;
    address.font = [NSFont systemFontOfSize:15];
    address.placeholderString = @"Search or enter website";
    address.lineBreakMode = NSLineBreakByClipping;
    address.cell.scrollable = YES;
    address.cell.wraps = NO;
    address.cell.usesSingleLineMode = YES;
    address.delegate = self;
    address.target = self;
    address.action = @selector(navigate:);
    address.accessibilityLabel = @"Website address or search";
    address.accessibilityHelp = @"Enter a website address or search, then press Return. Press Command Return to open in a new tab.";
    self.addressField = address;
    entry.addressField = address;

    NSButton *go = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.right" accessibilityDescription:@"Go"]
                                    target:self action:@selector(navigate:)];
    go.translatesAutoresizingMaskIntoConstraints = NO;
    go.bezelStyle = NSBezelStyleRecessed;
    go.showsBorderOnlyWhileMouseInside = YES;
    go.imagePosition = NSImageOnly;
    go.toolTip = @"Go (Return). Command-click to open in a new tab.";
    go.accessibilityLabel = @"Go";
    self.goButton = go;

    NSPopUpButton *engine = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    engine.translatesAutoresizingMaskIntoConstraints = NO;
    engine.bordered = NO;
    engine.font = [NSFont systemFontOfSize:12];
    [engine setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [engine setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    engine.target = self;
    engine.action = @selector(changeSearchEngine:);
    engine.accessibilityLabel = @"Search engine";
    engine.toolTip = @"Choose the engine for this search. Reorder engines in Settings to change the default.";
    self.engineButton = engine;

    NSTextField *hint = [NSTextField labelWithString:@"↵ Go     ⌘↵ New Tab"];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.alignment = NSTextAlignmentRight;
    hint.accessibilityLabel = OmnibarKeyboardHint;

    NSButton *settings = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Search Settings"]
                                          target:self action:@selector(showSearchSettings:)];
    settings.translatesAutoresizingMaskIntoConstraints = NO;
    settings.bezelStyle = NSBezelStyleRecessed;
    settings.showsBorderOnlyWhileMouseInside = YES;
    settings.imagePosition = NSImageOnly;
    settings.toolTip = @"Search Settings";
    settings.accessibilityLabel = @"Search Settings";
    self.settingsButton = settings;

    NSTextField *status = [NSTextField wrappingLabelWithString:OmnibarKeyboardHint];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.font = [NSFont systemFontOfSize:12];
    status.textColor = NSColor.secondaryLabelColor;
    status.maximumNumberOfLines = 2;
    status.hidden = YES;
    self.statusLabel = status;

    for (NSView *view in @[symbol, address, go]) [entry addSubview:view];
    for (NSView *view in @[entry, engine, hint, settings, status]) [self.addressContent addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [entry.leadingAnchor constraintEqualToAnchor:self.addressContent.leadingAnchor constant:14],
        [entry.trailingAnchor constraintEqualToAnchor:self.addressContent.trailingAnchor constant:-14],
        [entry.topAnchor constraintEqualToAnchor:self.addressContent.topAnchor constant:14],
        [entry.heightAnchor constraintEqualToConstant:40],
        [symbol.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:12],
        [symbol.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [symbol.widthAnchor constraintEqualToConstant:17],
        [symbol.heightAnchor constraintEqualToConstant:17],
        [address.leadingAnchor constraintEqualToAnchor:symbol.trailingAnchor constant:9],
        [address.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [address.heightAnchor constraintEqualToConstant:22],
        [address.trailingAnchor constraintEqualToAnchor:go.leadingAnchor constant:-6],
        [go.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-6],
        [go.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [go.widthAnchor constraintEqualToConstant:28],
        [go.heightAnchor constraintEqualToConstant:28],
        [engine.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor],
        [engine.topAnchor constraintEqualToAnchor:entry.bottomAnchor constant:8],
        [engine.widthAnchor constraintLessThanOrEqualToConstant:190],
        [engine.heightAnchor constraintEqualToConstant:24],
        [settings.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor],
        [settings.centerYAnchor constraintEqualToAnchor:engine.centerYAnchor],
        [settings.widthAnchor constraintEqualToConstant:28],
        [settings.heightAnchor constraintEqualToConstant:24],
        [hint.trailingAnchor constraintEqualToAnchor:settings.leadingAnchor constant:-12],
        [hint.leadingAnchor constraintGreaterThanOrEqualToAnchor:engine.trailingAnchor constant:12],
        [hint.centerYAnchor constraintEqualToAnchor:engine.centerYAnchor],
        [status.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:2],
        [status.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-2],
        [status.topAnchor constraintEqualToAnchor:engine.bottomAnchor constant:7],
    ]];
    address.nextKeyView = go;
    go.nextKeyView = engine;
    engine.nextKeyView = settings;
    settings.nextKeyView = address;
    [self restoreSearchEngine];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (!self.showingSettings && self.sessionWindow && !self.resolvedAddress && !self.userEditedAddress) {
        [self.view.window makeFirstResponder:self.addressField];
    }
    [self selectResolvedAddressIfNeeded];
}

- (void)prepareForWindow:(SFSafariWindow *)window {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self prepareForWindow:window]; });
        return;
    }
    (void)self.view;
    [self closeSearchSettings];
    NSUInteger generation = ++self.sessionGeneration;
    self.sessionWindow = window;
    self.sessionTab = nil;
    self.userEditedAddress = NO;
    self.resolvedAddress = NO;
    self.selectedAddress = NO;
    self.openingTab = NO;
    self.resolvingNavigation = NO;
    self.privateBrowsing = NO;
    self.loadingTab = YES;
    self.addressField.stringValue = @"";
    self.addressField.toolTip = nil;
    self.addressField.enabled = YES;
    self.engineButton.enabled = YES;
    self.settingsButton.enabled = YES;
    self.goButton.enabled = NO;
    [self restoreSearchEngine];
    [self setStatus:OmnibarKeyboardHint isError:NO];
    [self.view.window makeFirstResponder:self.addressField];

    __weak typeof(self) weakSelf = self;
    [window getActiveTabWithCompletionHandler:^(SFSafariTab *tab) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
            self.loadingTab = NO;
            self.sessionTab = tab;
            self.goButton.enabled = YES;
            [self setStatus:OmnibarKeyboardHint isError:NO];
            if (!tab) {
                [self finishLoadingURL:nil generation:generation];
                [self setStatus:@"No active tab. Addresses will open in a new tab." isError:NO];
                return;
            }
            [tab getActivePageWithCompletionHandler:^(SFSafariPage *page) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) self = weakSelf;
                    if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
                    if (!page) {
                        [self finishLoadingURL:nil generation:generation];
                        return;
                    }
                    [page getPagePropertiesWithCompletionHandler:^(SFSafariPageProperties *properties) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            typeof(self) self = weakSelf;
                            if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
                            self.privateBrowsing = properties ? properties.usesPrivateBrowsing : NO;
                            [weakSelf finishLoadingURL:properties.url generation:generation];
                        });
                    }];
                });
            }];
        });
    }];
}

- (void)finishLoadingURL:(NSURL *)URL generation:(NSUInteger)generation {
    if (generation != self.sessionGeneration || !self.sessionWindow) return;
    self.resolvedAddress = YES;
    if (!self.userEditedAddress) {
        self.addressField.stringValue = URL.absoluteString ?: @"";
        self.addressField.toolTip = self.addressField.stringValue.length ? self.addressField.stringValue : nil;
        if (!URL) {
            [self setStatus:@"Current address unavailable. Enter an address or search." isError:NO];
        }
        [self selectResolvedAddressIfNeeded];
    }
}

- (void)selectResolvedAddressIfNeeded {
    if (self.showingSettings || !self.sessionWindow || !self.resolvedAddress || self.selectedAddress || self.userEditedAddress || !self.view.window) return;
    self.selectedAddress = YES;
    [self.view.window makeFirstResponder:self.addressField];
    [self.addressField selectText:nil];
}

- (void)clearSession {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self clearSession]; });
        return;
    }
    ++self.sessionGeneration;
    [self.settingsController resetSensitiveFields];
    [self closeSearchSettings];
    self.sessionWindow = nil;
    self.sessionTab = nil;
    self.openingTab = NO;
    self.resolvingNavigation = NO;
    self.privateBrowsing = NO;
    self.loadingTab = NO;
    self.resolvedAddress = NO;
    self.selectedAddress = NO;
    self.userEditedAddress = NO;
    self.addressField.stringValue = @"";
    self.addressField.toolTip = nil;
    self.goButton.enabled = NO;
}

- (void)restoreSearchEngine {
    NSString *identifier = self.searchSettings.selectedEngineID;
    [self.engineButton removeAllItems];
    for (NSDictionary *engine in self.searchSettings.searchEngines) {
        [self.engineButton addItemWithTitle:engine[@"name"]];
        self.engineButton.lastItem.representedObject = engine[@"id"];
    }
    NSMenuItem *selected = nil;
    for (NSMenuItem *item in self.engineButton.itemArray) {
        if ([item.representedObject isEqualToString:identifier]) selected = item;
    }
    if (selected) [self.engineButton selectItem:selected];
    else [self.engineButton selectItemAtIndex:0];
}

- (void)changeSearchEngine:(id)sender {
    // Choosing in the popover affects this search. The first engine in Settings
    // stays the default the next time Omnibar opens.
}

- (void)showSearchSettings:(id)sender {
    if (self.resolvingNavigation || self.openingTab) return;
    if (self.showingSettings) return;
    self.settingsController = [[SearchSettingsController alloc] initWithSettings:self.searchSettings];
    __weak typeof(self) weakSelf = self;
    self.settingsController.onDone = ^{ [weakSelf closeSearchSettings]; };
    [self addChildViewController:self.settingsController];
    NSView *settingsView = self.settingsController.view;
    // Start at the current bounds; autoresizing will follow the popover resize.
    settingsView.frame = self.view.bounds;
    settingsView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.showingSettings = YES;
    self.addressContent.hidden = YES;
    [self.view addSubview:settingsView];
    self.preferredContentSize = self.settingsController.preferredContentSize;
    [self.view.window makeFirstResponder:settingsView];
}

- (void)closeSearchSettings {
    if (!self.showingSettings) return;
    [self.settingsController resetSensitiveFields];
    [self.settingsController.view removeFromSuperview];
    [self.settingsController removeFromParentViewController];
    self.settingsController = nil;
    self.showingSettings = NO;
    self.addressContent.hidden = NO;
    [self restoreSearchEngine];
    self.preferredContentSize = NSMakeSize(OmnibarWidth, self.statusLabel.hidden ? OmnibarHeight : OmnibarHeight + 36);
    [self.view.window makeFirstResponder:self.addressField];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.addressField) return;
    self.userEditedAddress = YES;
    self.addressField.toolTip = nil;
    [self setStatus:OmnibarKeyboardHint isError:NO];
}

- (void)controlTextDidBeginEditing:(NSNotification *)notification {
    if (notification.object != self.addressField) return;
    self.addressField.superview.needsDisplay = YES;
    NSTextView *editor = (NSTextView *)self.addressField.currentEditor;
    if (![editor isKindOfClass:NSTextView.class]) return;
    editor.automaticQuoteSubstitutionEnabled = NO;
    editor.automaticDashSubstitutionEnabled = NO;
    editor.automaticTextReplacementEnabled = NO;
    editor.automaticSpellingCorrectionEnabled = NO;
    editor.automaticLinkDetectionEnabled = NO;
    editor.continuousSpellCheckingEnabled = NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object == self.addressField) self.addressField.superview.needsDisplay = YES;
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (control != self.addressField) return NO;
    if (selector == @selector(cancelOperation:)) {
        [self dismissPopover];
        return YES;
    }
    if (selector == @selector(insertNewline:)) {
        [self navigate:control];
        return YES;
    }
    // AppKit's standard field editor can map Command-Return to noop: instead
    // of insertNewline:. Handle that event without changing editing bindings.
    if (selector == NSSelectorFromString(@"noop:") && OmnibarIsCommandReturn(NSApp.currentEvent)) {
        [self openInNewTab:control];
        return YES;
    }
    return NO;
}

- (void)cancelOperation:(id)sender {
    [self dismissPopover];
}

- (void)navigate:(id)sender {
    [self navigateInNewTab:(NSApp.currentEvent.modifierFlags & NSEventModifierFlagCommand) != 0];
}

- (void)openInNewTab:(id)sender {
    [self navigateInNewTab:YES];
}

- (void)navigateInNewTab:(BOOL)newTab {
    if (self.openingTab || self.resolvingNavigation || self.showingSettings) return;
    if (self.loadingTab) {
        [self setStatus:@"Reading Safari’s active tab. Press Return again in a moment." isError:NO];
        return;
    }
    if (!self.sessionWindow) {
        [self setStatus:@"Safari’s window is unavailable. Reopen Omnibar to try again." isError:YES];
        return;
    }

    NSString *engine = self.engineButton.selectedItem.representedObject ?: @"duckduckgo";
    if ([engine isEqualToString:@"kagi"] && !self.resolvedAddress) {
        [self setStatus:@"Checking Safari’s private browsing state. Try again in a moment." isError:NO];
        return;
    }
    NSString *input = self.addressField.stringValue;
    BOOL privateBrowsing = self.privateBrowsing;
    NSUInteger generation = self.sessionGeneration;
    OmnibarSearchSettings *settings = self.searchSettings;
    self.resolvingNavigation = YES;
    self.goButton.enabled = NO;
    self.addressField.enabled = NO;
    self.engineButton.enabled = NO;
    self.settingsButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    // Keychain access must not block AppKit's event loop.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *URL = [settings URLForInput:input searchEngine:engine privateBrowsing:privateBrowsing error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
            self.resolvingNavigation = NO;
            self.goButton.enabled = YES;
            self.addressField.enabled = YES;
            self.engineButton.enabled = YES;
            self.settingsButton.enabled = YES;
            if (!URL) {
                [self setStatus:error.localizedDescription ?: @"Enter a website address or search." isError:YES];
                [self.view.window makeFirstResponder:self.addressField];
                return;
            }
            [self navigateToURL:URL inNewTab:newTab];
        });
    });
}

- (void)navigateToURL:(NSURL *)URL inNewTab:(BOOL)newTab {
    NSString *destinationWithoutFragment = [URL.absoluteString componentsSeparatedByString:@"#"].firstObject;
    // Safari silently ignores about:blank in navigateToURL:. The tab-opening API
    // has a completion handler so rejection can be surfaced instead of dismissed.
    BOOL blankPage = [destinationWithoutFragment caseInsensitiveCompare:@"about:blank"] == NSOrderedSame;
    if (blankPage) newTab = YES;
    NSSet<NSString *> *browserSchemes = [NSSet setWithArray:@[
        @"http", @"https", @"about", @"file", @"data", @"blob", @"javascript",
        @"favorites", @"topsites", @"safari", @"safari-extension", @"safari-web-extension"
    ]];
    if (![browserSchemes containsObject:URL.scheme.lowercaseString]) {
        self.openingTab = YES;
        self.goButton.enabled = NO;
        NSUInteger generation = self.sessionGeneration;
        __weak typeof(self) weakSelf = self;
        [self openExternalURL:URL completionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
                self.openingTab = NO;
                self.goButton.enabled = YES;
                if (!error) [self dismissPopover];
                else [self setStatus:error.localizedDescription ?: @"macOS couldn’t open this link. Check its address and default app." isError:YES];
            });
        }];
        return;
    }

    if (!newTab && self.sessionTab) {
        [self.sessionTab navigateToURL:URL];
        [self dismissPopover];
        return;
    }

    self.openingTab = YES;
    self.goButton.enabled = NO;
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    [self.sessionWindow openTabWithURL:URL makeActiveIfPossible:YES completionHandler:^(SFSafariTab *tab) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
            if (!tab && blankPage) {
                [self openBlankURLInSafari:URL];
                return;
            }
            self.openingTab = NO;
            self.goButton.enabled = YES;
            if (tab) [self dismissPopover];
            else [self setStatus:@"Safari couldn’t open a new tab. Please try again." isError:YES];
        });
    }];
}

- (void)openBlankURLInSafari:(NSURL *)URL {
    self.openingTab = YES;
    self.goButton.enabled = NO;
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    [self getSafariApplicationURLWithCompletionHandler:^(NSURL *applicationURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
            if (!applicationURL) {
                self.openingTab = NO;
                self.goButton.enabled = YES;
                [self setStatus:@"Safari’s application is unavailable. Reopen Omnibar to try again." isError:YES];
                return;
            }
            [self openURL:URL inApplicationAtURL:applicationURL completionHandler:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    typeof(self) self = weakSelf;
                    if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
                    self.openingTab = NO;
                    self.goButton.enabled = YES;
                    if (!error) [self dismissPopover];
                    else [self setStatus:error.localizedDescription ?: @"Safari couldn’t open the blank page." isError:YES];
                });
            }];
        });
    }];
}

- (void)getSafariApplicationURLWithCompletionHandler:(void (^)(NSURL *applicationURL))completionHandler {
    // Use the connected browser, including Safari Technology Preview, rather than
    // the system default browser or a hard-coded application path.
    [SFSafariApplication getHostApplicationWithCompletionHandler:^(NSRunningApplication *application) {
        completionHandler(application.bundleURL);
    }];
}

- (void)openURL:(NSURL *)URL inApplicationAtURL:(NSURL *)applicationURL completionHandler:(void (^)(NSError *error))completionHandler {
    [NSWorkspace.sharedWorkspace openURLs:@[URL] withApplicationAtURL:applicationURL
                            configuration:NSWorkspaceOpenConfiguration.configuration
                        completionHandler:^(NSRunningApplication *application, NSError *error) {
        if (!application && !error) {
            error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError
                                   userInfo:@{NSLocalizedDescriptionKey: @"Safari couldn’t open the blank page."}];
        }
        completionHandler(error);
    }];
}

- (void)openExternalURL:(NSURL *)URL completionHandler:(void (^)(NSError *error))completionHandler {
    // Launch Services opens mailto, tel, and app-specific links in their default handler.
    // Keep the system's default prompting behavior and report failures in the popover.
    [NSWorkspace.sharedWorkspace openURL:URL configuration:NSWorkspaceOpenConfiguration.configuration
                      completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (!app && !error) {
            error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError
                                   userInfo:@{NSLocalizedDescriptionKey: @"macOS couldn’t open this link. Check its address and default app."}];
        }
        completionHandler(error);
    }];
}

- (void)setStatus:(NSString *)message isError:(BOOL)isError {
    self.statusLabel.stringValue = message;
    self.statusLabel.textColor = isError ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    self.statusLabel.hidden = [message isEqualToString:OmnibarKeyboardHint];
    if (!self.showingSettings) {
        NSSize size = NSMakeSize(OmnibarWidth, self.statusLabel.hidden ? OmnibarHeight : OmnibarHeight + 36);
        // Safari hosts this view remotely. Avoid refreshing its popover geometry
        // while AppKit is presenting input-method UI for the current text edit.
        if (!NSEqualSizes(self.preferredContentSize, size)) self.preferredContentSize = size;
    }
    if (isError) {
        NSAccessibilityPostNotificationWithUserInfo(self.statusLabel, NSAccessibilityAnnouncementRequestedNotification, @{
            NSAccessibilityAnnouncementKey: message,
            NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh)
        });
    }
}

@end
