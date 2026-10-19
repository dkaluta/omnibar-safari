#import "AddressPopoverController.h"
#import "OmnibarURLResolver.h"
#import "OmnibarSearchSettings.h"
#import "SearchSettingsController.h"
#import "OmnibarPaletteModel.h"
#import "OmnibarBrowserSession.h"
#import <AppKit/AppKit.h>

static NSString * const OmnibarKeyboardHint = @"Return to go · ⌘Return to open a new tab";
static const CGFloat OmnibarWidth = 520;
static const CGFloat OmnibarHeight = 420;

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

@interface AddressPopoverController () <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTextField *addressField;
@property (nonatomic, strong) NSButton *goButton;
@property (nonatomic, strong) NSPopUpButton *engineButton;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *settingsButton;
@property (nonatomic, strong) NSView *addressContent;
@property (nonatomic, strong) NSImageView *modeImage;
@property (nonatomic, strong) NSTextField *modeLabel;
@property (nonatomic, strong) NSTextField *keyboardHint;
@property (nonatomic, strong) NSTextField *resultLabel;
@property (nonatomic, strong) NSTableView *resultsTable;
@property (nonatomic, strong) NSButton *tabsButton;
@property (nonatomic, strong) NSButton *commandsButton;
@property (nonatomic, strong) NSStackView *tipsView;
@property (nonatomic, strong) NSLayoutConstraint *tipsHeight;
@property (nonatomic, copy) NSString *paletteMode;
@property (nonatomic, copy) NSArray<NSDictionary *> *tabItems;
@property (nonatomic, copy) NSArray<NSDictionary *> *paletteResults;
@property (nonatomic, strong, nullable) NSDictionary *addressPreview;
@property (nonatomic, strong, nullable) OmnibarBrowserSession *browserSession;
@property (nonatomic) BOOL browserActionPending;
@property (nonatomic, copy, nullable) NSString *tabsError;
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
- (void)refreshResultsKeepingSelection:(BOOL)keepSelection;
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
    if (self.currentEditor && ![(NSTextView *)self.currentEditor hasMarkedText] && OmnibarIsCommandReturn(event)) {
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
    self.modeImage = symbol;
    NSTextField *modeLabel = [NSTextField labelWithString:@""];
    modeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    modeLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    modeLabel.textColor = NSColor.secondaryLabelColor;
    [modeLabel setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [modeLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.modeLabel = modeLabel;
    self.paletteMode = @"search";
    self.tabItems = @[];
    self.paletteResults = @[];
    self.tabsError = nil;

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
    self.keyboardHint = hint;

    NSButton *tabsButton = [NSButton buttonWithTitle:@"Tabs  @" target:self action:@selector(showTabs:)];
    NSButton *commandsButton = [NSButton buttonWithTitle:@"Commands  >" target:self action:@selector(showCommands:)];
    for (NSButton *button in @[tabsButton, commandsButton]) {
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.bezelStyle = NSBezelStyleRecessed;
        button.buttonType = NSButtonTypePushOnPushOff;
        button.font = [NSFont systemFontOfSize:12];
    }
    tabsButton.accessibilityLabel = @"Find tabs in this window";
    commandsButton.accessibilityLabel = @"Find a command for this tab";
    self.tabsButton = tabsButton;
    self.commandsButton = commandsButton;

    NSTextField *tipsText = [NSTextField wrappingLabelWithString:@"Use ↑ and ↓ to choose, then Return to open. Type @ for tabs or > for commands. Close with Escape or a click outside."];
    tipsText.font = [NSFont systemFontOfSize:11];
    tipsText.textColor = NSColor.secondaryLabelColor;
    NSButton *dismissTips = [NSButton buttonWithTitle:@"Got it" target:self action:@selector(dismissPaletteTips:)];
    dismissTips.bezelStyle = NSBezelStyleRounded;
    NSStackView *tipsView = [NSStackView stackViewWithViews:@[tipsText, dismissTips]];
    tipsView.translatesAutoresizingMaskIntoConstraints = NO;
    tipsView.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    tipsView.spacing = 8;
    self.tipsView = tipsView;
    self.tipsHeight = [tipsView.heightAnchor constraintEqualToConstant:0];

    NSTextField *resultLabel = [NSTextField labelWithString:@"Tabs in this window"];
    resultLabel.translatesAutoresizingMaskIntoConstraints = NO;
    resultLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    resultLabel.textColor = NSColor.secondaryLabelColor;
    self.resultLabel = resultLabel;
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"result"];
    [table addTableColumn:column];
    table.headerView = nil;
    table.rowHeight = 46;
    table.intercellSpacing = NSMakeSize(0, 3);
    table.style = NSTableViewStyleSourceList;
    table.backgroundColor = NSColor.clearColor;
    table.allowsEmptySelection = YES;
    table.allowsMultipleSelection = NO;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.action = @selector(selectResult:);
    table.doubleAction = @selector(activateResult:);
    table.accessibilityLabel = @"Omnibar suggestions";
    self.resultsTable = table;
    NSScrollView *resultsScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    resultsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    resultsScroll.borderType = NSNoBorder;
    resultsScroll.drawsBackground = NO;
    resultsScroll.hasVerticalScroller = YES;
    resultsScroll.autohidesScrollers = YES;
    resultsScroll.documentView = table;

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

    for (NSView *view in @[symbol, modeLabel, address, go]) [entry addSubview:view];
    for (NSView *view in @[entry, tabsButton, commandsButton, engine, hint, settings, status, tipsView, resultLabel, resultsScroll]) [self.addressContent addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [entry.leadingAnchor constraintEqualToAnchor:self.addressContent.leadingAnchor constant:14],
        [entry.trailingAnchor constraintEqualToAnchor:self.addressContent.trailingAnchor constant:-14],
        [entry.topAnchor constraintEqualToAnchor:self.addressContent.topAnchor constant:14],
        [entry.heightAnchor constraintEqualToConstant:40],
        [symbol.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:12],
        [symbol.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [symbol.widthAnchor constraintEqualToConstant:17],
        [symbol.heightAnchor constraintEqualToConstant:17],
        [modeLabel.leadingAnchor constraintEqualToAnchor:symbol.trailingAnchor constant:5],
        [modeLabel.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [address.leadingAnchor constraintEqualToAnchor:modeLabel.trailingAnchor constant:9],
        [address.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [address.heightAnchor constraintEqualToConstant:22],
        [address.trailingAnchor constraintEqualToAnchor:go.leadingAnchor constant:-6],
        [go.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-6],
        [go.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [go.widthAnchor constraintEqualToConstant:28],
        [go.heightAnchor constraintEqualToConstant:28],
        [tabsButton.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor],
        [tabsButton.topAnchor constraintEqualToAnchor:entry.bottomAnchor constant:8],
        [tabsButton.heightAnchor constraintEqualToConstant:24],
        [commandsButton.leadingAnchor constraintEqualToAnchor:tabsButton.trailingAnchor constant:6],
        [commandsButton.centerYAnchor constraintEqualToAnchor:tabsButton.centerYAnchor],
        [commandsButton.heightAnchor constraintEqualToConstant:24],
        [engine.leadingAnchor constraintGreaterThanOrEqualToAnchor:commandsButton.trailingAnchor constant:8],
        [engine.trailingAnchor constraintEqualToAnchor:settings.leadingAnchor constant:-6],
        [engine.topAnchor constraintEqualToAnchor:entry.bottomAnchor constant:8],
        [engine.widthAnchor constraintLessThanOrEqualToConstant:190],
        [engine.heightAnchor constraintEqualToConstant:24],
        [settings.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor],
        [settings.centerYAnchor constraintEqualToAnchor:engine.centerYAnchor],
        [settings.widthAnchor constraintEqualToConstant:28],
        [settings.heightAnchor constraintEqualToConstant:24],
        [hint.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor],
        [hint.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor],
        [hint.bottomAnchor constraintEqualToAnchor:self.addressContent.bottomAnchor constant:-12],
        [tipsView.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:2],
        [tipsView.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-2],
        [tipsView.topAnchor constraintEqualToAnchor:engine.bottomAnchor constant:6],
        self.tipsHeight,
        [resultLabel.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:4],
        [resultLabel.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-4],
        [resultLabel.topAnchor constraintEqualToAnchor:tipsView.bottomAnchor constant:8],
        [resultsScroll.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:-4],
        [resultsScroll.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:4],
        [resultsScroll.topAnchor constraintEqualToAnchor:resultLabel.bottomAnchor constant:6],
        [resultsScroll.bottomAnchor constraintEqualToAnchor:status.topAnchor constant:-6],
        [status.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:2],
        [status.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-2],
        [status.bottomAnchor constraintEqualToAnchor:hint.topAnchor constant:-6],
    ]];
    address.nextKeyView = go;
    go.nextKeyView = tabsButton;
    tabsButton.nextKeyView = commandsButton;
    commandsButton.nextKeyView = engine;
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
    [self.browserSession invalidate];
    self.browserSession = nil;
    self.browserActionPending = NO;
    self.paletteMode = @"search";
    self.tabItems = @[];
    self.paletteResults = @[];
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
    self.tipsView.hidden = !self.searchSettings.showPaletteTips;
    self.tipsHeight.constant = self.tipsView.hidden ? 0 : 48;
    [self refreshResultsKeepingSelection:NO];
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
    [self refreshResultsKeepingSelection:YES];
    if (!self.browserSession && self.sessionTab) {
        self.browserSession = [self newBrowserSessionForWindow:self.sessionWindow tab:self.sessionTab];
        __weak typeof(self) weakSelf = self;
        [self.browserSession loadTabsWithCompletion:^(NSArray<NSDictionary *> *tabs, NSError *error) {
            typeof(self) self = weakSelf;
            if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
            self.tabItems = tabs ?: @[];
            self.tabsError = error ? @"Safari could not list this window’s tabs. Reopen Omnibar to try again." : nil;
            [self refreshResultsKeepingSelection:YES];
        }];
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
    [self.browserSession invalidate];
    self.browserSession = nil;
    self.browserActionPending = NO;
    self.paletteMode = @"search";
    self.tabItems = @[];
    self.paletteResults = @[];
    self.addressPreview = nil;
    [self.resultsTable reloadData];
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
    [self refreshResultsKeepingSelection:YES];
}

- (OmnibarBrowserSession *)newBrowserSessionForWindow:(SFSafariWindow *)window tab:(SFSafariTab *)tab {
    return [[OmnibarBrowserSession alloc] initWithWindow:window tab:tab];
}

- (void)setPaletteMode:(NSString *)mode focus:(BOOL)focus {
    if (self.openingTab || self.resolvingNavigation || self.browserActionPending) return;
    self.paletteMode = mode;
    self.userEditedAddress = YES;
    [self refreshResultsKeepingSelection:NO];
    if (focus) [self.view.window makeFirstResponder:self.addressField];
}

- (void)showTabs:(id)sender {
    if (!self.userEditedAddress) self.addressField.stringValue = @"";
    [self setPaletteMode:[self.paletteMode isEqualToString:@"tabs"] ? @"search" : @"tabs" focus:YES];
}

- (void)showCommands:(id)sender {
    if (!self.userEditedAddress) self.addressField.stringValue = @"";
    [self setPaletteMode:[self.paletteMode isEqualToString:@"commands"] ? @"search" : @"commands" focus:YES];
}

- (void)dismissPaletteTips:(id)sender {
    self.searchSettings.showPaletteTips = NO;
    self.tipsView.hidden = YES;
    self.tipsHeight.constant = 0;
    [self.view.window makeFirstResponder:self.addressField];
}

- (NSDictionary *)selectedResult {
    NSInteger row = self.resultsTable.selectedRow;
    return row >= 0 && (NSUInteger)row < self.paletteResults.count ? self.paletteResults[row] : nil;
}

- (void)refreshResultsKeepingSelection:(BOOL)keepSelection {
    if (!self.addressField) return;
    NSString *selectedID = keepSelection ? [self selectedResult][@"id"] : nil;
    NSString *query = [self.addressField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL commands = [self.paletteMode isEqualToString:@"commands"];
    BOOL tabsOnly = [self.paletteMode isEqualToString:@"tabs"];
    self.addressPreview = !commands && !tabsOnly ? [OmnibarPaletteModel addressPreviewForInput:query defaultURLSuffix:self.searchSettings.defaultURLSuffix] : nil;
    NSString *modeName = commands ? @"> Commands" : tabsOnly ? @"@ Tabs" : self.addressPreview ? @"Website" : @"";
    self.modeLabel.stringValue = modeName;
    self.modeLabel.accessibilityLabel = modeName.length ? modeName : @"Search";
    NSString *symbolName = commands ? @"command" : tabsOnly ? @"square.on.square" : self.addressPreview ? @"globe" : @"magnifyingglass";
    self.modeImage.image = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
    self.addressField.placeholderString = commands ? @"Find a command for this tab" : tabsOnly ? @"Find a tab in this window" : @"Search or enter website";
    self.addressField.accessibilityLabel = commands ? @"Commands for this tab" : tabsOnly ? @"Tabs in this window" : @"Website address or search";
    self.tabsButton.state = tabsOnly ? NSControlStateValueOn : NSControlStateValueOff;
    self.commandsButton.state = commands ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL busy = self.openingTab || self.resolvingNavigation || self.browserActionPending;
    self.engineButton.enabled = !busy && !commands && !tabsOnly && !self.addressPreview;
    self.tabsButton.enabled = self.commandsButton.enabled = !busy;

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    if (commands) {
        [items addObject:@{@"id": @"choose-tab", @"kind": @"command", @"title": @"Switch to Tab…", @"subtitle": @"Find a tab in this window", @"keywords": @"select jump tabs", @"symbol": @"square.on.square"}];
        for (NSDictionary *command in self.browserSession.commands) {
            NSMutableDictionary *item = command.mutableCopy;
            item[@"kind"] = @"command";
            [items addObject:item];
        }
        [items addObject:@{@"id": @"settings", @"kind": @"command", @"title": @"Search Settings", @"subtitle": @"Manage engines, website suffix, and private search", @"keywords": @"preferences configure", @"symbol": @"gearshape"}];
        self.paletteResults = [OmnibarPaletteModel rankedItems:items query:query];
    } else {
        for (NSDictionary *tab in self.tabItems) {
            NSMutableDictionary *item = tab.mutableCopy;
            item[@"kind"] = @"tab";
            item[@"symbol"] = @"square.on.square";
            [items addObject:item];
        }
        NSString *tabQuery = query;
        if (self.addressPreview[@"destination"]) {
            tabQuery = [NSURL URLWithString:self.addressPreview[@"destination"]].host ?: query;
            if ([tabQuery.lowercaseString hasPrefix:@"www."]) tabQuery = [tabQuery substringFromIndex:4];
        }
        NSArray *matching = [OmnibarPaletteModel rankedItems:items query:tabQuery];
        NSMutableArray *results = matching.mutableCopy;
        if (!tabsOnly && query.length) {
            NSString *title = self.addressPreview[@"destination"] ?: query;
            NSString *subtitle = self.addressPreview ? ([self.addressPreview[@"valid"] boolValue] ? @"Open website" : @"Check this address before opening") : [NSString stringWithFormat:@"Search with %@", self.engineButton.titleOfSelectedItem ?: @"your search engine"];
            [results insertObject:@{@"id": @"navigate", @"kind": @"navigate", @"title": title, @"subtitle": subtitle, @"symbol": self.addressPreview ? @"globe" : @"magnifyingglass"} atIndex:0];
            if (results.count > 50) [results removeLastObject];
        }
        self.paletteResults = results;
    }
    [self.resultsTable reloadData];
    NSUInteger selected = NSNotFound;
    if (selectedID) selected = [self.paletteResults indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) { return [item[@"id"] isEqual:selectedID]; }];
    if (self.paletteResults.count) [self.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:selected == NSNotFound ? 0 : selected] byExtendingSelection:NO];
    else [self.resultsTable deselectAll:nil];
    NSString *label = commands ? @"Commands for this tab" : tabsOnly || !query.length ? @"Tabs in this window" : self.addressPreview ? @"Website and tabs" : @"Search and tabs";
    if (!self.paletteResults.count) label = commands ? @"No matching commands" : self.loadingTab ? @"Loading tabs…" : @"No matching tabs in this window";
    if (tabsOnly && self.tabsError && !self.paletteResults.count) label = @"Tabs unavailable · Reopen Omnibar to try again";
    self.resultLabel.stringValue = self.paletteResults.count == 50 ? [label stringByAppendingString:@" · Type to narrow results"] : label;
    [self updateKeyboardHint];
}

- (void)updateKeyboardHint {
    NSString *kind = [self selectedResult][@"kind"];
    NSString *hint = [kind isEqual:@"navigate"] ? @"↑ ↓ Select   ↵ Go   ⌘↵ New Tab" : [kind isEqual:@"command"] ? @"↑ ↓ Select   ↵ Run" : @"↑ ↓ Select   ↵ Switch";
    if ([self.addressPreview[@"shorthand"] boolValue] && [self.addressPreview[@"valid"] boolValue]) hint = [hint stringByAppendingString:@"   ⇥ Expand"];
    if (![self.paletteMode isEqual:@"search"] && !self.addressField.stringValue.length) hint = [hint stringByAppendingString:@"   ⌫ Search"];
    self.keyboardHint.stringValue = hint;
    self.keyboardHint.accessibilityLabel = hint;
    self.addressField.accessibilityHelp = [NSString stringWithFormat:@"%@. Escape closes Omnibar.", hint];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.paletteResults.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSDictionary *item = self.paletteResults[row];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"palette-result" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"palette-result";
        NSImageView *image = [[NSImageView alloc] initWithFrame:NSZeroRect];
        image.translatesAutoresizingMaskIntoConstraints = NO;
        image.contentTintColor = NSColor.secondaryLabelColor;
        image.accessibilityHidden = YES;
        NSTextField *title = [NSTextField labelWithString:@""];
        title.font = [NSFont systemFontOfSize:13];
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        NSTextField *subtitle = [NSTextField labelWithString:@""];
        subtitle.identifier = @"subtitle";
        subtitle.font = [NSFont systemFontOfSize:11];
        subtitle.textColor = NSColor.secondaryLabelColor;
        subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
        NSStackView *copy = [NSStackView stackViewWithViews:@[title, subtitle]];
        copy.translatesAutoresizingMaskIntoConstraints = NO;
        copy.orientation = NSUserInterfaceLayoutOrientationVertical;
        copy.alignment = NSLayoutAttributeLeading;
        copy.spacing = 2;
        [cell addSubview:image];
        [cell addSubview:copy];
        cell.imageView = image;
        cell.textField = title;
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
            [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [image.widthAnchor constraintEqualToConstant:20],
            [image.heightAnchor constraintEqualToConstant:20],
            [copy.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:10],
            [copy.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
            [copy.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [title.widthAnchor constraintEqualToAnchor:copy.widthAnchor],
            [subtitle.widthAnchor constraintEqualToAnchor:copy.widthAnchor],
        ]];
    }
    cell.textField.stringValue = item[@"title"] ?: @"Untitled Tab";
    NSStackView *copy = (id)cell.textField.superview;
    ((NSTextField *)copy.arrangedSubviews.lastObject).stringValue = item[@"subtitle"] ?: @"";
    cell.imageView.image = [NSImage imageWithSystemSymbolName:item[@"symbol"] ?: @"square.on.square" accessibilityDescription:nil];
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", item[@"title"] ?: @"Untitled Tab", item[@"subtitle"] ?: @""];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification { [self updateKeyboardHint]; }
- (void)selectResult:(id)sender { [self.view.window makeFirstResponder:self.addressField]; }
- (void)activateResult:(id)sender { [self navigate:nil]; }

- (void)showSearchSettings:(id)sender {
    if (self.resolvingNavigation || self.openingTab || self.browserActionPending) return;
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
    [self refreshResultsKeepingSelection:YES];
    [self.view.window makeFirstResponder:self.addressField];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != self.addressField) return;
    self.userEditedAddress = YES;
    self.addressField.toolTip = nil;
    NSTextView *editor = (id)self.addressField.currentEditor;
    if ([editor isKindOfClass:NSTextView.class] && editor.hasMarkedText) return;
    NSDictionary *parsed = [OmnibarPaletteModel parsedInput:self.addressField.stringValue];
    if (![parsed[@"mode"] isEqual:@"search"]) {
        self.paletteMode = parsed[@"mode"];
        self.addressField.stringValue = parsed[@"query"];
        if ([editor isKindOfClass:NSTextView.class]) editor.selectedRange = NSMakeRange(self.addressField.stringValue.length, 0);
    }
    [self setStatus:OmnibarKeyboardHint isError:NO];
    [self refreshResultsKeepingSelection:NO];
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
    if (textView.hasMarkedText) return NO;
    NSEventModifierFlags modifiers = NSApp.currentEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift);
    if (selector == @selector(cancelOperation:) && !modifiers) {
        [self dismissPopover];
        return YES;
    }
    if (self.openingTab || self.resolvingNavigation || self.browserActionPending) return NO;
    if (!modifiers && (selector == @selector(moveDown:) || selector == @selector(moveUp:))) {
        NSInteger count = self.paletteResults.count;
        if (count) {
            NSInteger direction = selector == @selector(moveDown:) ? 1 : -1;
            NSInteger row = (MAX(0, self.resultsTable.selectedRow) + direction + count) % count;
            [self.resultsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
            [self.resultsTable scrollRowToVisible:row];
        }
        return YES;
    }
    if (!modifiers && selector == @selector(deleteBackward:) && !self.addressField.stringValue.length && ![self.paletteMode isEqual:@"search"]) {
        [self setPaletteMode:@"search" focus:YES];
        return YES;
    }
    if (!modifiers && selector == @selector(insertTab:) && [self.addressPreview[@"shorthand"] boolValue] && [self.addressPreview[@"valid"] boolValue]) {
        self.addressField.stringValue = self.addressPreview[@"destination"];
        self.userEditedAddress = YES;
        [self refreshResultsKeepingSelection:NO];
        textView.selectedRange = NSMakeRange(self.addressField.stringValue.length, 0);
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
    if (self.openingTab || self.resolvingNavigation || self.browserActionPending || self.showingSettings) return;
    if (self.loadingTab) {
        [self setStatus:@"Reading Safari’s active tab. Press Return again in a moment." isError:NO];
        return;
    }
    if (!self.sessionWindow) {
        [self setStatus:@"Safari’s window is unavailable. Reopen Omnibar to try again." isError:YES];
        return;
    }

    NSDictionary *result = [self selectedResult];
    if (result && ![result[@"kind"] isEqual:@"navigate"]) {
        [self performBrowserResult:result];
        return;
    }
    if (![self.paletteMode isEqual:@"search"]) {
        [self setStatus:@"Choose a matching result, or press Backspace in an empty field to return to Search." isError:NO];
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
    self.tabsButton.enabled = self.commandsButton.enabled = NO;
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
            [self refreshResultsKeepingSelection:YES];
            if (!URL) {
                [self setStatus:error.localizedDescription ?: @"Enter a website address or search." isError:YES];
                [self.view.window makeFirstResponder:self.addressField];
                return;
            }
            [self navigateToURL:URL inNewTab:newTab];
        });
    });
}

- (void)performBrowserResult:(NSDictionary *)result {
    NSString *identifier = result[@"id"];
    if ([identifier isEqual:@"choose-tab"]) {
        self.addressField.stringValue = @"";
        [self setPaletteMode:@"tabs" focus:YES];
        return;
    }
    if ([identifier isEqual:@"settings"]) { [self showSearchSettings:nil]; return; }
    if (!self.browserSession) {
        [self setStatus:@"Safari’s tabs are still loading. Try again in a moment." isError:NO];
        return;
    }
    self.browserActionPending = YES;
    self.addressField.enabled = self.goButton.enabled = self.engineButton.enabled = self.settingsButton.enabled = NO;
    self.tabsButton.enabled = self.commandsButton.enabled = NO;
    NSUInteger generation = self.sessionGeneration;
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        typeof(self) self = weakSelf;
        if (!self || generation != self.sessionGeneration || !self.sessionWindow) return;
        self.browserActionPending = NO;
        self.addressField.enabled = self.goButton.enabled = self.settingsButton.enabled = YES;
        [self refreshResultsKeepingSelection:YES];
        if (!error) [self dismissPopover];
        else {
            [self setStatus:error.localizedDescription ?: @"Safari could not complete this action. Reopen Omnibar and try again." isError:YES];
            [self.view.window makeFirstResponder:self.addressField];
        }
    };
    if ([result[@"kind"] isEqual:@"tab"]) [self.browserSession activateTabWithIdentifier:identifier completion:completion];
    else [self.browserSession performCommandWithIdentifier:identifier completion:completion];
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
