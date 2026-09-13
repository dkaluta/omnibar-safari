#import "SearchSettingsController.h"
#import "OmnibarSearchSettings.h"

static NSPasteboardType const OmnibarEnginePasteboardType = @"com.omnibar.search-engine-id";

@interface OmnibarEngineCell : NSTableCellView
@property (nonatomic, strong) NSBox *defaultBadge;
@end
@implementation OmnibarEngineCell
@end

@interface SearchSettingsController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) OmnibarSearchSettings *settings;
@property (nonatomic, strong) NSTextField *headingLabel;
@property (nonatomic, strong) NSButton *doneButton;
@property (nonatomic, strong) NSSegmentedControl *paneControl;
@property (nonatomic, strong) NSView *contentHost;
@property (nonatomic, strong) NSView *enginesPane;
@property (nonatomic, strong) NSView *privatePane;
@property (nonatomic, strong) NSView *editorPane;
@property (nonatomic, strong) NSLayoutConstraint *paneTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *editorTopConstraint;
@property (nonatomic, strong) NSSecureTextField *privateLinkField;
@property (nonatomic, strong) NSButton *savePrivateButton;
@property (nonatomic, strong) NSButton *removePrivateButton;
@property (nonatomic, strong) NSTextField *privateStatus;
@property (nonatomic, strong) NSTableView *engineTable;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *templateField;
@property (nonatomic, strong) NSButton *editEngineButton;
@property (nonatomic, strong) NSButton *removeEngineButton;
@property (nonatomic, strong) NSButton *saveEngineButton;
@property (nonatomic, strong) NSButton *cancelEditorButton;
@property (nonatomic, strong) NSButton *moveUpButton;
@property (nonatomic, strong) NSButton *moveDownButton;
@property (nonatomic, strong) NSTextField *engineStatus;
@property (nonatomic, copy) NSArray<NSDictionary<NSString *, NSString *> *> *orderedEngines;
@property (nonatomic, copy, nullable) NSString *editingIdentifier;
@property (nonatomic) BOOL editingEngine;
@property (nonatomic, strong) dispatch_queue_t keychainQueue;
@property (nonatomic) NSUInteger keychainGeneration;
@property (nonatomic) BOOL keychainBusy;
@property (nonatomic) BOOL hasPrivateLink;
@end

@implementation SearchSettingsController

- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _settings = settings;
        _orderedEngines = @[];
        _keychainQueue = dispatch_queue_create("com.omnibar.search-settings.keychain", DISPATCH_QUEUE_SERIAL);
        self.preferredContentSize = NSMakeSize(520, 480);
    }
    return self;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight secondary:(BOOL)secondary {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = secondary ? NSColor.secondaryLabelColor : NSColor.labelColor;
    return label;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeRegular;
    button.font = [NSFont systemFontOfSize:13];
    return button;
}

- (NSTextField *)entry:(NSString *)placeholder {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.font = [NSFont systemFontOfSize:13];
    field.placeholderString = placeholder;
    field.cell.scrollable = YES;
    field.cell.wraps = NO;
    field.cell.usesSingleLineMode = YES;
    field.delegate = self;
    return field;
}

- (NSView *)pane {
    NSView *pane = [[NSView alloc] initWithFrame:NSZeroRect];
    pane.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentHost addSubview:pane];
    [NSLayoutConstraint activateConstraints:@[
        [pane.leadingAnchor constraintEqualToAnchor:self.contentHost.leadingAnchor],
        [pane.trailingAnchor constraintEqualToAnchor:self.contentHost.trailingAnchor],
        [pane.topAnchor constraintEqualToAnchor:self.contentHost.topAnchor],
        [pane.bottomAnchor constraintEqualToAnchor:self.contentHost.bottomAnchor],
    ]];
    return pane;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 480)];
    self.headingLabel = [self label:@"Search Settings" size:15 weight:NSFontWeightSemibold secondary:NO];
    self.doneButton = [self button:@"Done" action:@selector(done:)];
    self.doneButton.keyEquivalent = @"\033";
    self.doneButton.keyEquivalentModifierMask = 0;
    self.paneControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Search Engines", @"Kagi Private Browsing"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changePane:)];
    self.paneControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.paneControl.segmentStyle = NSSegmentStyleRounded;
    self.paneControl.font = [NSFont systemFontOfSize:13];
    self.paneControl.selectedSegment = 0;
    self.paneControl.accessibilityLabel = @"Search settings section";
    self.contentHost = [[NSView alloc] initWithFrame:NSZeroRect];
    self.contentHost.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in @[self.headingLabel, self.doneButton, self.paneControl, self.contentHost]) [self.view addSubview:view];
    self.paneTopConstraint = [self.contentHost.topAnchor constraintEqualToAnchor:self.paneControl.bottomAnchor constant:20];
    self.editorTopConstraint = [self.contentHost.topAnchor constraintEqualToAnchor:self.doneButton.bottomAnchor constant:20];
    [NSLayoutConstraint activateConstraints:@[
        [self.headingLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.headingLabel.centerYAnchor constraintEqualToAnchor:self.doneButton.centerYAnchor],
        [self.doneButton.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [self.doneButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.doneButton.widthAnchor constraintEqualToConstant:72],
        [self.doneButton.heightAnchor constraintEqualToConstant:28],
        [self.paneControl.topAnchor constraintEqualToAnchor:self.doneButton.bottomAnchor constant:18],
        [self.paneControl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.paneControl.widthAnchor constraintEqualToConstant:360],
        [self.paneControl.heightAnchor constraintEqualToConstant:28],
        [self.contentHost.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.contentHost.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [self.contentHost.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-20],
        self.paneTopConstraint,
    ]];
    self.enginesPane = [self pane];
    self.privatePane = [self pane];
    self.editorPane = [self pane];
    [self buildEnginesPane];
    [self buildPrivatePane];
    [self buildEditorPane];
    self.privatePane.hidden = YES;
    self.editorPane.hidden = YES;
    [self reloadEnginesSelecting:self.settings.selectedEngineID];
    [self updatePrivateControls];
}

- (void)buildEnginesPane {
    NSView *pane = self.enginesPane;
    NSTextField *hint = [self label:@"First engine is default. Drag to reorder." size:13 weight:NSFontWeightRegular secondary:YES];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.autoresizingMask = NSViewWidthSizable;
    table.headerView = nil;
    table.style = NSTableViewStyleInset;
    table.rowHeight = 32;
    table.allowsMultipleSelection = NO;
    table.allowsEmptySelection = YES;
    table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.doubleAction = @selector(editEngine:);
    table.accessibilityLabel = @"Search engines in order. The first engine is the default.";
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    column.width = 320;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [table addTableColumn:column];
    [table registerForDraggedTypes:@[OmnibarEnginePasteboardType]];
    [table setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    [table setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];
    scroll.documentView = table;
    self.engineTable = table;
    NSButton *add = [self button:@"Add…" action:@selector(addEngine:)];
    self.editEngineButton = [self button:@"Edit…" action:@selector(editEngine:)];
    self.removeEngineButton = [self button:@"Remove" action:@selector(removeEngine:)];
    self.moveUpButton = [self button:@"" action:@selector(moveEngineUp:)];
    self.moveDownButton = [self button:@"" action:@selector(moveEngineDown:)];
    self.moveUpButton.image = [NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Move up"];
    self.moveDownButton.image = [NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Move down"];
    self.moveUpButton.imagePosition = NSImageOnly;
    self.moveDownButton.imagePosition = NSImageOnly;
    self.moveUpButton.accessibilityLabel = @"Move selected engine up";
    self.moveDownButton.accessibilityLabel = @"Move selected engine down";
    self.moveUpButton.toolTip = @"Move up. The first engine is the default.";
    self.moveDownButton.toolTip = @"Move down. The first engine is the default.";
    add.accessibilityLabel = @"Add custom search engine";
    self.editEngineButton.accessibilityLabel = @"Edit selected custom search engine";
    self.removeEngineButton.accessibilityLabel = @"Remove selected custom search engine";
    for (NSView *view in @[hint, scroll, add, self.editEngineButton, self.removeEngineButton, self.moveUpButton, self.moveDownButton]) [pane addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [hint.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [hint.topAnchor constraintEqualToAnchor:pane.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:12],
        [scroll.bottomAnchor constraintEqualToAnchor:add.topAnchor constant:-12],
        [add.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [add.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor],
        [add.widthAnchor constraintEqualToConstant:70],
        [add.heightAnchor constraintEqualToConstant:28],
        [self.editEngineButton.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:8],
        [self.editEngineButton.widthAnchor constraintEqualToConstant:70],
        [self.removeEngineButton.leadingAnchor constraintEqualToAnchor:self.editEngineButton.trailingAnchor constant:8],
        [self.removeEngineButton.widthAnchor constraintEqualToConstant:84],
        [self.moveDownButton.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [self.moveDownButton.widthAnchor constraintEqualToConstant:32],
        [self.moveUpButton.trailingAnchor constraintEqualToAnchor:self.moveDownButton.leadingAnchor constant:-6],
        [self.moveUpButton.widthAnchor constraintEqualToConstant:32],
    ]];
    for (NSButton *button in @[self.editEngineButton, self.removeEngineButton, self.moveUpButton, self.moveDownButton]) {
        [NSLayoutConstraint activateConstraints:@[
            [button.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
            [button.heightAnchor constraintEqualToAnchor:add.heightAnchor],
        ]];
    }
}

- (void)buildPrivatePane {
    NSView *pane = self.privatePane;
    NSTextField *note = [self label:@"Save your Kagi session link to search in private Safari windows. The link is stored in Keychain and used only for private Kagi searches." size:13 weight:NSFontWeightRegular secondary:YES];
    NSTextField *label = [self label:@"Session link" size:13 weight:NSFontWeightMedium secondary:NO];
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.bezelStyle = NSTextFieldRoundedBezel;
    field.controlSize = NSControlSizeLarge;
    field.font = [NSFont systemFontOfSize:13];
    field.cell.sendsActionOnEndEditing = NO;
    field.cell.allowsUndo = NO;
    field.placeholderString = @"Paste Kagi session link";
    field.accessibilityLabel = @"Kagi private session link";
    field.accessibilityHelp = @"Paste your Kagi session link. An existing saved link is never displayed.";
    field.delegate = self;
    field.target = self;
    field.action = @selector(savePrivateLink:);
    self.privateLinkField = field;
    self.savePrivateButton = [self button:@"Save Link" action:@selector(savePrivateLink:)];
    self.removePrivateButton = [self button:@"Remove Link" action:@selector(removePrivateLink:)];
    self.privateStatus = [self label:@"Checking Keychain…" size:13 weight:NSFontWeightRegular secondary:YES];
    for (NSView *view in @[note, label, field, self.savePrivateButton, self.removePrivateButton, self.privateStatus]) [pane addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [note.topAnchor constraintEqualToAnchor:pane.topAnchor],
        [note.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [note.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [note.heightAnchor constraintEqualToConstant:52],
        [label.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:20],
        [label.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [field.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:8],
        [field.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [field.heightAnchor constraintEqualToConstant:32],
        [self.savePrivateButton.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:12],
        [self.savePrivateButton.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [self.savePrivateButton.widthAnchor constraintEqualToConstant:92],
        [self.savePrivateButton.heightAnchor constraintEqualToConstant:28],
        [self.removePrivateButton.trailingAnchor constraintEqualToAnchor:self.savePrivateButton.leadingAnchor constant:-8],
        [self.removePrivateButton.centerYAnchor constraintEqualToAnchor:self.savePrivateButton.centerYAnchor],
        [self.removePrivateButton.widthAnchor constraintEqualToConstant:108],
        [self.removePrivateButton.heightAnchor constraintEqualToAnchor:self.savePrivateButton.heightAnchor],
        [self.privateStatus.topAnchor constraintEqualToAnchor:self.savePrivateButton.bottomAnchor constant:16],
        [self.privateStatus.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [self.privateStatus.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
    ]];
}

- (void)buildEditorPane {
    NSView *pane = self.editorPane;
    NSTextField *nameLabel = [self label:@"Name" size:13 weight:NSFontWeightMedium secondary:NO];
    self.nameField = [self entry:@"Search engine name"];
    self.nameField.accessibilityLabel = @"Custom search engine name";
    NSTextField *URLLabel = [self label:@"Search URL" size:13 weight:NSFontWeightMedium secondary:NO];
    self.templateField = [self entry:@"https://example.com/search?q=%s"];
    self.templateField.accessibilityLabel = @"Custom search URL template";
    self.templateField.accessibilityHelp = @"Use percent s where the search terms belong.";
    NSTextField *hint = [self label:@"Use %s where the search terms belong.\nFor example: https://example.com/search?q=%s" size:13 weight:NSFontWeightRegular secondary:YES];
    self.engineStatus = [self label:@"" size:13 weight:NSFontWeightRegular secondary:YES];
    self.saveEngineButton = [self button:@"Add Engine" action:@selector(saveEngine:)];
    self.saveEngineButton.keyEquivalent = @"\r";
    self.saveEngineButton.keyEquivalentModifierMask = 0;
    self.cancelEditorButton = [self button:@"Cancel" action:@selector(cancelEditor:)];
    self.cancelEditorButton.keyEquivalent = @"\033";
    self.cancelEditorButton.keyEquivalentModifierMask = 0;
    for (NSView *view in @[nameLabel, self.nameField, URLLabel, self.templateField, hint, self.engineStatus, self.cancelEditorButton, self.saveEngineButton]) [pane addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [nameLabel.topAnchor constraintEqualToAnchor:pane.topAnchor],
        [nameLabel.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [self.nameField.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:8],
        [self.nameField.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [self.nameField.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [self.nameField.heightAnchor constraintEqualToConstant:28],
        [URLLabel.topAnchor constraintEqualToAnchor:self.nameField.bottomAnchor constant:20],
        [URLLabel.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [self.templateField.topAnchor constraintEqualToAnchor:URLLabel.bottomAnchor constant:8],
        [self.templateField.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [self.templateField.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [self.templateField.heightAnchor constraintEqualToConstant:28],
        [hint.topAnchor constraintEqualToAnchor:self.templateField.bottomAnchor constant:8],
        [hint.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [hint.heightAnchor constraintEqualToConstant:40],
        [self.engineStatus.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:16],
        [self.engineStatus.leadingAnchor constraintEqualToAnchor:pane.leadingAnchor],
        [self.engineStatus.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [self.engineStatus.bottomAnchor constraintLessThanOrEqualToAnchor:self.saveEngineButton.topAnchor constant:-16],
        [self.saveEngineButton.trailingAnchor constraintEqualToAnchor:pane.trailingAnchor],
        [self.saveEngineButton.bottomAnchor constraintEqualToAnchor:pane.bottomAnchor],
        [self.saveEngineButton.widthAnchor constraintEqualToConstant:112],
        [self.saveEngineButton.heightAnchor constraintEqualToConstant:28],
        [self.cancelEditorButton.trailingAnchor constraintEqualToAnchor:self.saveEngineButton.leadingAnchor constant:-8],
        [self.cancelEditorButton.centerYAnchor constraintEqualToAnchor:self.saveEngineButton.centerYAnchor],
        [self.cancelEditorButton.widthAnchor constraintEqualToConstant:84],
        [self.cancelEditorButton.heightAnchor constraintEqualToAnchor:self.saveEngineButton.heightAnchor],
    ]];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    if (self.paneControl.selectedSegment == 1 && !self.keychainBusy) [self refreshPrivateStatus];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    // A legacy scrollbar reduces the clip view width. Keep the single column
    // inside that width, including AppKit's inset table-style margins.
    NSScrollView *scroll = self.engineTable.enclosingScrollView;
    CGFloat width = NSWidth(scroll.contentView.bounds);
    if (width > 0) {
        NSSize size = self.engineTable.frame.size;
        if (size.width != width) [self.engineTable setFrameSize:NSMakeSize(width, size.height)];
        [self.engineTable sizeLastColumnToFit];
    }
}

- (void)changePane:(id)sender {
    if (self.editingEngine) return;
    BOOL privatePane = self.paneControl.selectedSegment == 1;
    self.enginesPane.hidden = privatePane;
    self.privatePane.hidden = !privatePane;
    if (privatePane) [self refreshPrivateStatus];
    else [self resetSensitiveFields];
}

- (void)updatePrivateControls {
    self.privateLinkField.enabled = !self.keychainBusy;
    self.savePrivateButton.enabled = !self.keychainBusy && self.privateLinkField.stringValue.length > 0;
    self.removePrivateButton.enabled = !self.keychainBusy && self.hasPrivateLink;
}

- (void)status:(NSTextField *)label message:(NSString *)message error:(BOOL)error announce:(BOOL)announce {
    label.stringValue = message;
    label.textColor = error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    if (announce) {
        NSAccessibilityPostNotificationWithUserInfo(label, NSAccessibilityAnnouncementRequestedNotification, @{
            NSAccessibilityAnnouncementKey: message,
            NSAccessibilityPriorityKey: @(error ? NSAccessibilityPriorityHigh : NSAccessibilityPriorityMedium)
        });
    }
}

- (void)refreshPrivateStatus {
    if (self.keychainBusy) return;
    self.keychainBusy = YES;
    NSUInteger generation = ++self.keychainGeneration;
    [self updatePrivateControls];
    OmnibarSearchSettings *settings = self.settings;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.keychainQueue, ^{
        NSError *error = nil;
        BOOL hasLink = [settings hasKagiPrivateURLWithError:&error];
        BOOL failed = error != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.keychainGeneration) return;
            self.keychainBusy = NO;
            self.hasPrivateLink = hasLink;
            [self status:self.privateStatus message:failed ? @"Couldn’t check Keychain access." : hasLink ? @"Private link saved" : @"No private link saved" error:failed announce:NO];
            [self updatePrivateControls];
        });
    });
}

- (void)savePrivateLink:(id)sender {
    if (self.keychainBusy || !self.privateLinkField.stringValue.length) return;
    NSString *link = self.privateLinkField.stringValue;
    self.privateLinkField.stringValue = @"";
    self.privateLinkField.currentEditor.string = @"";
    self.keychainBusy = YES;
    NSUInteger generation = ++self.keychainGeneration;
    [self updatePrivateControls];
    [self status:self.privateStatus message:@"Saving to Keychain…" error:NO announce:NO];
    OmnibarSearchSettings *settings = self.settings;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.keychainQueue, ^{
        NSError *error = nil;
        BOOL saved = [settings saveKagiPrivateURL:link error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.keychainGeneration) return;
            self.keychainBusy = NO;
            if (saved) self.hasPrivateLink = YES;
            [self status:self.privateStatus message:saved ? @"Private link saved" : @"Couldn’t save the link. Check the link and Keychain access." error:!saved announce:YES];
            [self updatePrivateControls];
        });
    });
}

- (void)removePrivateLink:(id)sender {
    if (self.keychainBusy) return;
    self.privateLinkField.stringValue = @"";
    self.privateLinkField.currentEditor.string = @"";
    self.keychainBusy = YES;
    NSUInteger generation = ++self.keychainGeneration;
    [self updatePrivateControls];
    [self status:self.privateStatus message:@"Removing from Keychain…" error:NO announce:NO];
    OmnibarSearchSettings *settings = self.settings;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.keychainQueue, ^{
        NSError *error = nil;
        BOOL removed = [settings removeKagiPrivateURLWithError:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || generation != self.keychainGeneration) return;
            self.keychainBusy = NO;
            if (removed) self.hasPrivateLink = NO;
            [self status:self.privateStatus message:removed ? @"No private link saved" : @"Couldn’t remove the link. Check Keychain access and try again." error:!removed announce:YES];
            [self updatePrivateControls];
        });
    });
}

- (void)resetSensitiveFields {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self resetSensitiveFields]; });
        return;
    }
    ++self.keychainGeneration;
    self.keychainBusy = NO;
    self.privateLinkField.stringValue = @"";
    self.privateLinkField.currentEditor.string = @"";
    [self updatePrivateControls];
}

- (nullable NSString *)selectedIdentifier {
    NSInteger row = self.engineTable.selectedRow;
    return row >= 0 && row < (NSInteger)self.orderedEngines.count ? self.orderedEngines[row][@"id"] : nil;
}

- (nullable NSDictionary<NSString *, NSString *> *)customEngineWithIdentifier:(nullable NSString *)identifier {
    for (NSDictionary<NSString *, NSString *> *engine in self.settings.customSearchEngines) {
        if ([engine[@"id"] isEqualToString:identifier]) return engine;
    }
    return nil;
}

- (void)reloadEnginesSelecting:(nullable NSString *)identifier {
    self.orderedEngines = self.settings.searchEngines;
    [self.engineTable reloadData];
    NSUInteger index = [self.orderedEngines indexOfObjectPassingTest:^BOOL(NSDictionary *engine, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        return [engine[@"id"] isEqualToString:identifier];
    }];
    if (index != NSNotFound) [self.engineTable selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    else [self.engineTable deselectAll:nil];
    [self updateSelectedActions];
}

- (void)updateSelectedActions {
    NSInteger row = self.engineTable.selectedRow;
    BOOL selected = row >= 0 && row < (NSInteger)self.orderedEngines.count;
    BOOL custom = [self customEngineWithIdentifier:self.selectedIdentifier] != nil;
    self.editEngineButton.enabled = custom;
    self.removeEngineButton.enabled = custom;
    self.moveUpButton.enabled = selected && row > 0;
    self.moveDownButton.enabled = selected && row < (NSInteger)self.orderedEngines.count - 1;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.orderedEngines.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    OmnibarEngineCell *cell = [tableView makeViewWithIdentifier:@"EngineCell" owner:self];
    if (!cell) {
        cell = [[OmnibarEngineCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"EngineCell";
        NSTextField *name = [NSTextField labelWithString:@""];
        name.translatesAutoresizingMaskIntoConstraints = NO;
        name.font = [NSFont systemFontOfSize:13];
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:name];
        cell.textField = name;
        NSBox *badge = [[NSBox alloc] initWithFrame:NSZeroRect];
        badge.translatesAutoresizingMaskIntoConstraints = NO;
        badge.boxType = NSBoxCustom;
        badge.borderWidth = 0;
        badge.cornerRadius = 4;
        badge.fillColor = NSColor.quaternaryLabelColor;
        badge.contentViewMargins = NSZeroSize;
        NSTextField *badgeText = [NSTextField labelWithString:@"Default"];
        badgeText.translatesAutoresizingMaskIntoConstraints = NO;
        badgeText.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        badgeText.textColor = NSColor.secondaryLabelColor;
        [badge.contentView addSubview:badgeText];
        [cell addSubview:badge];
        cell.defaultBadge = badge;
        [NSLayoutConstraint activateConstraints:@[
            [name.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
            [name.trailingAnchor constraintEqualToAnchor:badge.leadingAnchor constant:-8],
            [name.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [badge.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-12],
            [badge.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [badge.widthAnchor constraintEqualToConstant:58],
            [badge.heightAnchor constraintEqualToConstant:20],
            [badgeText.centerXAnchor constraintEqualToAnchor:badge.contentView.centerXAnchor],
            [badgeText.centerYAnchor constraintEqualToAnchor:badge.contentView.centerYAnchor],
        ]];
    }
    NSString *name = self.orderedEngines[row][@"name"] ?: @"";
    cell.textField.stringValue = name;
    cell.defaultBadge.hidden = row != 0;
    cell.textField.accessibilityLabel = row == 0 ? [name stringByAppendingString:@", default search engine"] : name;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateSelectedActions];
}

- (nullable id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.orderedEngines.count) return nil;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:self.orderedEngines[row][@"id"] forType:OmnibarEnginePasteboardType];
    return item;
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation {
    if (info.draggingSource != self.engineTable || row < 0 || row > (NSInteger)self.orderedEngines.count) return NSDragOperationNone;
    NSString *identifier = [info.draggingPasteboard stringForType:OmnibarEnginePasteboardType];
    if (!identifier || ![[self.orderedEngines valueForKey:@"id"] containsObject:identifier]) return NSDragOperationNone;
    [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation {
    if (info.draggingSource != self.engineTable || row < 0 || row > (NSInteger)self.orderedEngines.count || operation != NSTableViewDropAbove) return NO;
    NSString *identifier = [info.draggingPasteboard stringForType:OmnibarEnginePasteboardType];
    NSUInteger source = [[self.orderedEngines valueForKey:@"id"] indexOfObject:identifier ?: @""];
    if (source == NSNotFound) return NO;
    NSUInteger destination = (NSUInteger)row;
    if (destination > source) destination--;
    [self.settings moveEngineWithIdentifier:identifier toIndex:destination];
    [self reloadEnginesSelecting:identifier];
    [self.engineTable scrollRowToVisible:self.engineTable.selectedRow];
    [self announce:destination == 0 ? @"Search engine moved to the top and set as default." : @"Search engine order updated."];
    return YES;
}

- (void)announce:(NSString *)message {
    NSAccessibilityPostNotificationWithUserInfo(self.view, NSAccessibilityAnnouncementRequestedNotification, @{
        NSAccessibilityAnnouncementKey: message,
        NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)
    });
}

- (void)moveEngineUp:(id)sender {
    NSInteger row = self.engineTable.selectedRow;
    if (row <= 0 || row >= (NSInteger)self.orderedEngines.count) return;
    NSString *identifier = self.orderedEngines[row][@"id"];
    [self.settings moveEngineWithIdentifier:identifier toIndex:(NSUInteger)row - 1];
    [self reloadEnginesSelecting:identifier];
    [self.engineTable scrollRowToVisible:self.engineTable.selectedRow];
    [self announce:row == 1 ? @"Search engine moved to the top and set as default." : @"Search engine moved up."];
}

- (void)moveEngineDown:(id)sender {
    NSInteger row = self.engineTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.orderedEngines.count - 1) return;
    NSString *identifier = self.orderedEngines[row][@"id"];
    [self.settings moveEngineWithIdentifier:identifier toIndex:(NSUInteger)row + 1];
    [self reloadEnginesSelecting:identifier];
    [self.engineTable scrollRowToVisible:self.engineTable.selectedRow];
    [self announce:@"Search engine moved down."];
}

- (void)showEditorForEngine:(nullable NSDictionary<NSString *, NSString *> *)engine {
    self.editingEngine = YES;
    self.editingIdentifier = engine[@"id"];
    self.nameField.stringValue = engine[@"name"] ?: @"";
    self.templateField.stringValue = engine[@"template"] ?: @"";
    self.headingLabel.stringValue = engine ? @"Edit Search Engine" : @"Add Search Engine";
    self.doneButton.hidden = YES;
    self.saveEngineButton.title = engine ? @"Save Changes" : @"Add Engine";
    self.paneControl.hidden = YES;
    self.enginesPane.hidden = YES;
    self.privatePane.hidden = YES;
    self.editorPane.hidden = NO;
    self.paneTopConstraint.active = NO;
    self.editorTopConstraint.active = YES;
    [self status:self.engineStatus message:@"" error:NO announce:NO];
    [self.view.window makeFirstResponder:self.nameField];
    [self.nameField selectText:nil];
}

- (void)cancelEditor:(id)sender {
    if (!self.editingEngine) return;
    self.editingEngine = NO;
    self.editingIdentifier = nil;
    self.nameField.stringValue = @"";
    self.templateField.stringValue = @"";
    self.headingLabel.stringValue = @"Search Settings";
    self.doneButton.hidden = NO;
    self.editorPane.hidden = YES;
    self.enginesPane.hidden = NO;
    self.privatePane.hidden = YES;
    self.paneControl.hidden = NO;
    self.paneControl.selectedSegment = 0;
    self.editorTopConstraint.active = NO;
    self.paneTopConstraint.active = YES;
    [self.view.window makeFirstResponder:self.engineTable];
}

- (void)addEngine:(id)sender {
    if (!self.editingEngine) [self showEditorForEngine:nil];
}

- (void)editEngine:(id)sender {
    if (self.editingEngine) return;
    NSDictionary *engine = [self customEngineWithIdentifier:self.selectedIdentifier];
    if (engine) [self showEditorForEngine:engine];
}

- (void)saveEngine:(id)sender {
    if (!self.editingEngine) return;
    BOOL newEngine = self.editingIdentifier == nil;
    NSError *error = nil;
    NSDictionary *saved = [self.settings saveCustomEngine:self.editingIdentifier name:self.nameField.stringValue template:self.templateField.stringValue error:&error];
    if (!saved) {
        [self status:self.engineStatus message:error.localizedDescription ?: @"Enter a name and a search URL containing %s." error:YES announce:YES];
        return;
    }
    if (newEngine) self.settings.selectedEngineID = saved[@"id"];
    [self reloadEnginesSelecting:saved[@"id"]];
    [self cancelEditor:nil];
    [self announce:newEngine ? @"Search engine added and set as default." : @"Search engine saved."];
}

- (void)removeEngine:(id)sender {
    NSString *identifier = self.selectedIdentifier;
    if (![self customEngineWithIdentifier:identifier]) return;
    [self.settings removeCustomEngineWithIdentifier:identifier];
    [self reloadEnginesSelecting:self.settings.selectedEngineID];
    [self announce:@"Search engine removed."];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.privateLinkField) [self updatePrivateControls];
    else [self status:self.engineStatus message:@"" error:NO announce:NO];
}

- (void)controlTextDidBeginEditing:(NSNotification *)notification {
    NSTextField *field = notification.object;
    NSTextView *editor = (NSTextView *)field.currentEditor;
    if (![editor isKindOfClass:NSTextView.class]) return;
    editor.automaticQuoteSubstitutionEnabled = NO;
    editor.automaticDashSubstitutionEnabled = NO;
    editor.automaticTextReplacementEnabled = NO;
    editor.automaticSpellingCorrectionEnabled = NO;
    editor.continuousSpellCheckingEnabled = NO;
    editor.allowsUndo = field != self.privateLinkField;
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (selector == @selector(cancelOperation:)) {
        [self done:control];
        return YES;
    }
    if (selector == @selector(insertNewline:)) {
        if (control == self.privateLinkField) [self savePrivateLink:control];
        else if (self.editingEngine) [self saveEngine:control];
        return YES;
    }
    return NO;
}

- (void)cancelOperation:(id)sender {
    [self done:sender];
}

- (void)done:(id)sender {
    if (self.editingEngine) {
        [self cancelEditor:sender];
        return;
    }
    [self resetSensitiveFields];
    if (self.onDone) self.onDone();
}

@end
