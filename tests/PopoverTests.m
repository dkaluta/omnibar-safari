#import <AppKit/AppKit.h>
#import <SafariServices/SafariServices.h>
#import "AddressPopoverController.h"
#import "OmnibarURLResolver.h"
#import "SearchSettingsController.h"
#import "SettingsTestSupport.h"

// Exercise the real AppKit controller with deterministic Safari API stand-ins.
// No Safari windows, preferences, or websites are changed by this executable.
@interface AddressPopoverController (Testing)
- (void)navigate:(id)sender;
- (void)openInNewTab:(id)sender;
- (void)openExternalURL:(NSURL *)URL completionHandler:(void (^)(NSError *error))completionHandler;
- (void)getSafariApplicationURLWithCompletionHandler:(void (^)(NSURL *applicationURL))completionHandler;
- (void)openURL:(NSURL *)URL inApplicationAtURL:(NSURL *)applicationURL completionHandler:(void (^)(NSError *error))completionHandler;
- (void)controlTextDidChange:(NSNotification *)notification;
- (void)showSearchSettings:(id)sender;
- (void)closeSearchSettings;
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector;
@end

@interface SearchSettingsController (Testing)
- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row;
- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation;
- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation;
@end

// Exercise AppKit's drag callbacks without touching the system pasteboard.
@interface TestEnginePasteboard : NSObject
@property (strong) NSPasteboardItem *item;
@end
@implementation TestEnginePasteboard
- (NSString *)stringForType:(NSPasteboardType)type { return [self.item stringForType:type]; }
@end

@interface TestEngineDrag : NSObject
@property (strong) id draggingSource;
@property (strong) TestEnginePasteboard *draggingPasteboard;
@end
@implementation TestEngineDrag
@end

@interface TestApplication : NSApplication
@property (strong) NSEvent *testEvent;
@end
@implementation TestApplication
- (NSEvent *)currentEvent { return self.testEvent ?: [super currentEvent]; }
@end

@interface TestSettingsCredentials : OMTestCredentials
@property NSUInteger statusReads;
@end
@implementation TestSettingsCredentials
- (BOOL)hasPrivateKagiURLWithError:(NSError **)error {
    self.statusReads++;
    return [super hasPrivateKagiURLWithError:error];
}
@end

@interface TestPopover : AddressPopoverController
@property NSUInteger dismissals;
@property (strong) NSURL *externallyOpenedURL;
@property (strong) NSError *externalOpenError;
@property BOOL deferExternalOpen;
@property (copy) void (^externalReply)(NSError *);
@property (strong) NSURL *safariApplicationURL;
@property (strong) NSURL *safariOpenedURL;
@property (strong) NSURL *safariOpenApplicationURL;
@property (strong) NSError *safariOpenError;
@property BOOL deferSafariApplication;
@property BOOL deferSafariOpen;
@property (copy) void (^safariApplicationReply)(NSURL *);
@property (copy) void (^safariOpenReply)(NSError *);
@end
@implementation TestPopover
- (void)dismissPopover { self.dismissals++; [self clearSession]; }
- (void)openExternalURL:(NSURL *)URL completionHandler:(void (^)(NSError *error))completionHandler {
    self.externallyOpenedURL = URL;
    if (self.deferExternalOpen) self.externalReply = completionHandler;
    else completionHandler(self.externalOpenError);
}
- (void)getSafariApplicationURLWithCompletionHandler:(void (^)(NSURL *applicationURL))completionHandler {
    if (self.deferSafariApplication) self.safariApplicationReply = completionHandler;
    else completionHandler(self.safariApplicationURL);
}
- (void)openURL:(NSURL *)URL inApplicationAtURL:(NSURL *)applicationURL completionHandler:(void (^)(NSError *error))completionHandler {
    self.safariOpenedURL = URL;
    self.safariOpenApplicationURL = applicationURL;
    if (self.deferSafariOpen) self.safariOpenReply = completionHandler;
    else completionHandler(self.safariOpenError);
}
- (void)setPreferredContentSize:(NSSize)size {
    [super setPreferredContentSize:size];
    if (self.isViewLoaded && self.view.window) [self.view.window setContentSize:size];
}
@end

@interface TestProperties : NSObject
@property (strong) NSURL *url;
@property BOOL usesPrivateBrowsing;
@end
@implementation TestProperties
@end

@interface TestPage : NSObject
@property (strong) NSURL *url;
@property BOOL deferProperties;
@property BOOL usesPrivateBrowsing;
@property (copy) void (^reply)(SFSafariPageProperties *);
- (void)respond;
@end
@implementation TestPage
- (void)getPagePropertiesWithCompletionHandler:(void (^)(SFSafariPageProperties *))reply {
    self.reply = reply;
    if (!self.deferProperties) [self respond];
}
- (void)respond {
    TestProperties *properties = [TestProperties new];
    properties.url = self.url;
    properties.usesPrivateBrowsing = self.usesPrivateBrowsing;
    if (self.reply) self.reply((id)properties);
    self.reply = nil;
}
@end

@interface TestTab : NSObject
@property (strong) TestPage *page;
@property (strong) NSURL *navigatedURL;
@end
@implementation TestTab
- (void)getActivePageWithCompletionHandler:(void (^)(SFSafariPage *))reply { reply((id)self.page); }
- (void)navigateToURL:(NSURL *)url { self.navigatedURL = url; }
@end

@interface TestSafariWindow : NSObject
@property (strong) TestTab *tab;
@property (strong) NSURL *openedURL;
@property BOOL failOpen;
@property BOOL deferActiveTab;
@property (copy) void (^tabReply)(SFSafariTab *);
@end
@implementation TestSafariWindow
- (void)getActiveTabWithCompletionHandler:(void (^)(SFSafariTab *))reply {
    if (self.deferActiveTab) self.tabReply = reply;
    else reply((id)self.tab);
}
- (void)openTabWithURL:(NSURL *)url makeActiveIfPossible:(BOOL)active completionHandler:(void (^)(SFSafariTab *))reply {
    self.openedURL = url;
    reply(self.failOpen ? nil : (id)[TestTab new]);
}
@end

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static void Drain(void) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.035];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
}

static TestSafariWindow *SafariWindow(NSString *url) {
    TestSafariWindow *window = [TestSafariWindow new];
    window.tab = [TestTab new];
    window.tab.page = [TestPage new];
    window.tab.page.url = url ? [NSURL URLWithString:url] : nil;
    return window;
}

static void Type(TestPopover *controller, NSString *value) {
    NSTextField *field = [controller valueForKey:@"addressField"];
    field.stringValue = value;
    [controller controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:field]];
}

static NSMenuItem *RestoreItem(SearchSettingsController *controller, NSString *identifier) {
    NSPopUpButton *button = [controller valueForKey:@"addEngineButton"];
    for (NSMenuItem *item in button.itemArray) {
        if ([item.representedObject isEqual:identifier]) return item;
    }
    return nil;
}

static void SelectEngine(SearchSettingsController *controller, OmnibarSearchSettings *settings, NSString *identifier) {
    NSUInteger row = [[settings.searchEngines valueForKey:@"id"] indexOfObject:identifier];
    Check(row != NSNotFound, @"engine to select is present in Settings");
    NSTableView *table = [controller valueForKey:@"engineTable"];
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

static void WaitForPrivateStatus(SearchSettingsController *controller) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    do { Drain(); } while ([[controller valueForKey:@"keychainBusy"] boolValue] && deadline.timeIntervalSinceNow > 0);
    Check(![[controller valueForKey:@"keychainBusy"] boolValue], @"fake credential status query completes");
}

static void CheckEngineFooterLayout(SearchSettingsController *controller) {
    [controller.view layoutSubtreeIfNeeded];
    CGFloat previousTrailing = -CGFLOAT_MAX;
    for (NSString *key in @[@"addEngineButton", @"editEngineButton", @"removeEngineButton", @"restoreDefaultsButton", @"moveUpButton", @"moveDownButton"]) {
        NSButton *button = [controller valueForKey:key];
        NSRect frame = [button convertRect:button.bounds toView:controller.view];
        Check(NSContainsRect(controller.view.bounds, frame), [key stringByAppendingString:@" fits inside the Settings popover"]);
        NSRect alignment = [button.superview convertRect:[button alignmentRectForFrame:button.frame] toView:controller.view];
        Check(NSMinX(alignment) >= previousTrailing, [key stringByAppendingString:@" does not overlap the preceding footer control"]);
        previousTrailing = NSMaxX(alignment);
    }
}

static void TestEngineManagement(void) {
    OMTestDefaults *defaults = [OMTestDefaults new];
    defaults.values[@"searchEngine"] = @"duckduckgo";
    TestSettingsCredentials *credentials = [TestSettingsCredentials new];
    credentials.URL = @"https://kagi.com/search?token=RETAINED_FAKE_TEST_TOKEN&q=%s";
    NSString *savedCredential = credentials.URL;
    OmnibarSearchSettings *settings = [[OmnibarSearchSettings alloc] initWithDefaults:(id)defaults credentialStore:credentials];
    TestPopover *popover = [[TestPopover alloc] initWithNibName:nil bundle:nil];
    [popover setValue:settings forKey:@"searchSettings"];
    NSWindow *panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 100)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    panel.contentView = popover.view;
    [popover prepareForWindow:(id)SafariWindow(@"https://example.com/")]; Drain();
    Type(popover, @"preserved while managing engines");
    [popover showSearchSettings:nil]; Drain();
    SearchSettingsController *view = [popover valueForKey:@"settingsController"];
    CheckEngineFooterLayout(view);
    NSPopUpButton *add = [view valueForKey:@"addEngineButton"];
    Check(add.pullsDown && [add.title isEqual:@"Add"], @"Add uses a native pull-down menu");
    NSMenuItem *customItem = [add.menu itemWithTitle:@"Custom Search Engine…"];
    Check(customItem && customItem.target == view && customItem.action == NSSelectorFromString(@"addEngine:"),
          @"Add menu exposes the custom engine editor action");
    Check(settings.removedDefaultSearchEngines.count == 0 && RestoreItem(view, @"kagi") == nil,
          @"Add menu does not offer built-in engines already present");
    Check(credentials.statusReads == 0, @"opening engine settings does not query private credential status");

    NSString *removedDefault = settings.selectedEngineID;
    NSString *nextDefault = settings.searchEngines[1][@"id"];
    SelectEngine(view, settings, removedDefault);
    NSButton *remove = [view valueForKey:@"removeEngineButton"];
    Check(remove.enabled && ![(NSButton *)[view valueForKey:@"editEngineButton"] isEnabled],
          @"a built-in engine can be removed but not edited");
    [remove performClick:nil]; Drain();
    Check([settings.selectedEngineID isEqual:nextDefault] && ![[settings.searchEngines valueForKey:@"id"] containsObject:removedDefault],
          @"removing the first built-in engine promotes the next engine to default");
    NSMenuItem *restoreItem = RestoreItem(view, removedDefault);
    Check(restoreItem && restoreItem.target == view && restoreItem.action == NSSelectorFromString(@"restoreDefaultEngine:"),
          @"a removed built-in engine appears as an actionable Add menu item");
    [add.menu performActionForItemAtIndex:[add.menu indexOfItem:restoreItem]]; Drain();
    Check([[settings.searchEngines valueForKey:@"id"] containsObject:removedDefault] && [settings.selectedEngineID isEqual:nextDefault],
          @"the native Add menu restores a built-in without changing the default");
    NSUInteger countAfterRestore = settings.searchEngines.count;
    [NSApp sendAction:restoreItem.action to:restoreItem.target from:restoreItem];
    Check(settings.searchEngines.count == countAfterRestore && RestoreItem(view, removedDefault) == nil,
          @"restored built-ins disappear from Add and stale restore actions cannot duplicate them");

    SelectEngine(view, settings, @"kagi");
    NSSegmentedControl *panes = [view valueForKey:@"paneControl"];
    panes.selectedSegment = 1;
    [NSApp sendAction:panes.action to:panes.target from:panes];
    WaitForPrivateStatus(view);
    Check(credentials.statusReads > 0 && ![(NSView *)[view valueForKey:@"privatePane"] isHidden],
          @"Kagi private settings can read status while Kagi is present");
    ((NSTextField *)[view valueForKey:@"privateLinkField"]).stringValue = @"UNSAVED_SENSITIVE_TEST_INPUT";
    [NSApp sendAction:NSSelectorFromString(@"removeEngine:") to:view from:nil]; Drain();
    Check(panes.hidden && panes.selectedSegment == 0 && [(NSView *)[view valueForKey:@"privatePane"] isHidden]
          && ![(NSView *)[view valueForKey:@"enginesPane"] isHidden],
          @"removing Kagi hides its settings and returns to the engine list");
    Check([(NSTextField *)[view valueForKey:@"privateLinkField"] stringValue].length == 0 && [credentials.URL isEqual:savedCredential],
          @"removing Kagi clears typed sensitive input while preserving the saved private link");
    Check([(NSLayoutConstraint *)[view valueForKey:@"editorTopConstraint"] isActive]
          && ![(NSLayoutConstraint *)[view valueForKey:@"paneTopConstraint"] isActive],
          @"engine content reclaims the hidden Kagi tab space");
    CheckEngineFooterLayout(view);
    NSUInteger statusReadsWithoutKagi = credentials.statusReads;
    panes.selectedSegment = 1;
    [NSApp sendAction:panes.action to:panes.target from:panes];
    [view viewWillAppear]; Drain();
    Check(panes.selectedSegment == 0 && credentials.statusReads == statusReadsWithoutKagi
          && [(NSView *)[view valueForKey:@"privatePane"] isHidden],
          @"an absent Kagi pane cannot be activated or query credential status");
    [popover closeSearchSettings]; Drain();
    NSPopUpButton *engines = [popover valueForKey:@"engineButton"];
    Check(![[engines.itemArray valueForKey:@"representedObject"] containsObject:@"kagi"]
          && [engines.selectedItem.representedObject isEqual:settings.selectedEngineID],
          @"closing Settings removes Kagi from the popover dropdown and refreshes the default");
    Check([[(NSTextField *)[popover valueForKey:@"addressField"] stringValue] isEqual:@"preserved while managing engines"],
          @"engine management preserves the unfinished address or search");

    [popover showSearchSettings:nil]; Drain();
    view = [popover valueForKey:@"settingsController"];
    panes = [view valueForKey:@"paneControl"];
    add = [view valueForKey:@"addEngineButton"];
    Check(panes.hidden && [(NSView *)[view valueForKey:@"privatePane"] isHidden]
          && credentials.statusReads == statusReadsWithoutKagi, @"reopening Settings keeps absent Kagi controls hidden without a credential query");
    [add.menu performActionForItemAtIndex:[add.menu indexOfItemWithTitle:@"Custom Search Engine…"]];
    Check([[view valueForKey:@"editingEngine"] boolValue], @"native Add menu opens the custom editor without Kagi");
    [NSApp sendAction:NSSelectorFromString(@"cancelEditor:") to:view from:nil];
    Check(panes.hidden && [(NSView *)[view valueForKey:@"privatePane"] isHidden]
          && [(NSLayoutConstraint *)[view valueForKey:@"editorTopConstraint"] isActive],
          @"canceling a custom editor does not reveal absent Kagi controls or their tab space");
    restoreItem = RestoreItem(view, @"kagi");
    Check(restoreItem != nil, @"Kagi can be added back from the native menu");
    [add.menu performActionForItemAtIndex:[add.menu indexOfItem:restoreItem]]; Drain();
    Check(!panes.hidden && panes.selectedSegment == 0 && [(NSView *)[view valueForKey:@"privatePane"] isHidden]
          && [(NSLayoutConstraint *)[view valueForKey:@"paneTopConstraint"] isActive],
          @"adding Kagi back restores the section tabs without opening private settings");
    Check([credentials.URL isEqual:savedCredential] && credentials.statusReads == statusReadsWithoutKagi,
          @"adding Kagi back preserves its saved credential without querying it");
    panes.selectedSegment = 1;
    [NSApp sendAction:panes.action to:panes.target from:panes];
    WaitForPrivateStatus(view);
    Check([[view valueForKey:@"hasPrivateLink"] boolValue], @"restored Kagi settings recognize the retained private link");
    panes.selectedSegment = 0;
    [NSApp sendAction:panes.action to:panes.target from:panes];

    [add.menu performActionForItemAtIndex:[add.menu indexOfItemWithTitle:@"Custom Search Engine…"]];
    ((NSTextField *)[view valueForKey:@"nameField"]).stringValue = @"Retained Custom Engine";
    ((NSTextField *)[view valueForKey:@"templateField"]).stringValue = @"https://example.org/search?q=%s";
    [NSApp sendAction:NSSelectorFromString(@"saveEngine:") to:view from:nil];
    NSDictionary *custom = settings.customSearchEngines.firstObject;
    Check(custom != nil, @"custom engine is saved before restoring defaults");
    SelectEngine(view, settings, @"kagi");
    [(NSButton *)[view valueForKey:@"removeEngineButton"] performClick:nil];
    NSButton *restoreDefaults = [view valueForKey:@"restoreDefaultsButton"];
    Check(restoreDefaults.enabled && restoreDefaults.action == NSSelectorFromString(@"restoreDefaults:"),
          @"Restore Defaults is available after engine changes");
    [restoreDefaults performClick:nil]; Drain();
    NSMutableArray *expectedIDs = [[OmnibarURLResolver.searchEngines valueForKey:@"id"] mutableCopy];
    [expectedIDs addObject:custom[@"id"]];
    Check([[settings.searchEngines valueForKey:@"id"] isEqual:expectedIDs] && [settings.selectedEngineID isEqual:expectedIDs.firstObject],
          @"Restore Defaults reinstates built-in order and default while retaining custom engines at the end");
    Check([settings.customSearchEngines isEqual:@[custom]] && settings.removedDefaultSearchEngines.count == 0
          && [credentials.URL isEqual:savedCredential] && !panes.hidden,
          @"Restore Defaults preserves custom engine data and credentials and brings back Kagi settings");

    while (settings.searchEngines.count > 1) {
        SelectEngine(view, settings, settings.searchEngines.firstObject[@"id"]);
        [(NSButton *)[view valueForKey:@"removeEngineButton"] performClick:nil];
    }
    remove = [view valueForKey:@"removeEngineButton"];
    Check(!remove.enabled && [settings.selectedEngineID isEqual:custom[@"id"]], @"Remove is disabled for the final remaining engine, including a custom engine");
    [NSApp sendAction:NSSelectorFromString(@"removeEngine:") to:view from:nil];
    Check(settings.searchEngines.count == 1, @"a stale Remove action cannot delete the final search engine");
    [popover closeSearchSettings]; Drain();
    Check(engines.numberOfItems == 1 && [engines.selectedItem.representedObject isEqual:custom[@"id"]],
          @"popover dropdown reflects the final remaining custom engine after Settings closes");
    [popover showSearchSettings:nil];
    view = [popover valueForKey:@"settingsController"];
    [(NSButton *)[view valueForKey:@"restoreDefaultsButton"] performClick:nil];
    [popover closeSearchSettings]; Drain();
    Check([[engines.itemArray valueForKey:@"representedObject"] isEqual:expectedIDs]
          && [engines.selectedItem.representedObject isEqual:expectedIDs.firstObject],
          @"restored defaults and retained custom engines return to the popover dropdown");
    [popover clearSession];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TestApplication *app = (id)[TestApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        // Make automated checks independent of preferences changed in the preview.
        [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"searchEngine": @"duckduckgo"}
                                                       forName:NSArgumentDomain];
        TestPopover *controller = [[TestPopover alloc] initWithNibName:nil bundle:nil];
        OMTestCredentials *credentials;
        OmnibarSearchSettings *settings = OMMakeTestSettings(NULL, &credentials);
        [controller setValue:settings forKey:@"searchSettings"];
        NSWindow *panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 100)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        panel.contentView = controller.view;
        NSTextField *field = [controller valueForKey:@"addressField"];
        NSTextField *status = [controller valueForKey:@"statusLabel"];

        TestSafariWindow *first = SafariWindow(@"https://example.com/a?one=1#section");
        [controller prepareForWindow:(id)first]; Drain();
        NSDate *firstDeadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (![[controller valueForKey:@"resolvedAddress"] boolValue] && firstDeadline.timeIntervalSinceNow > 0) Drain();
        Check([field.stringValue isEqualToString:first.tab.page.url.absoluteString], @"shows full current URL including query and fragment");
        Check([field.accessibilityLabel isEqualToString:@"Website address or search"], @"address has an accessibility label");
        Check(((NSPopUpButton *)[controller valueForKey:@"engineButton"]).numberOfItems == (NSInteger)OmnibarURLResolver.searchEngines.count, @"all built-in search engines available");
        NSTextView *editor = (id)field.currentEditor;
        Check(editor && editor.selectedRange.length == field.stringValue.length, @"current URL is selected for replacement");

        TestTab *origin = first.tab;
        first.tab = [TestTab new]; // A different tab becomes active after opening.
        Type(controller, @"example.org/path");
        [controller navigate:nil]; Drain();
        Check([origin.navigatedURL.absoluteString isEqualToString:@"https://example.org/path"], @"navigation targets originating tab");
        Check(first.tab.navigatedURL == nil, @"newly active tab is untouched");
        Check(field.stringValue.length == 0, @"dismissal clears the address");

        TestSafariWindow *slow = SafariWindow(@"https://slow.example/");
        slow.tab.page.deferProperties = YES;
        [controller prepareForWindow:(id)slow]; Drain();
        Type(controller, @"already typing");
        [slow.tab.page respond]; Drain();
        Check([field.stringValue isEqualToString:@"already typing"], @"late URL response preserves user input");

        TestSafariWindow *older = SafariWindow(@"https://old.example/");
        older.tab.page.deferProperties = YES;
        [controller prepareForWindow:(id)older]; Drain();
        TestSafariWindow *latest = SafariWindow(@"https://latest.example/");
        [controller prepareForWindow:(id)latest]; Drain();
        [older.tab.page respond]; Drain();
        Check([field.stringValue isEqualToString:@"https://latest.example/"], @"stale session cannot overwrite a newer URL");

        TestSafariWindow *closed = SafariWindow(@"https://closed.example/");
        closed.tab.page.deferProperties = YES;
        [controller prepareForWindow:(id)closed]; Drain();
        [controller clearSession]; [closed.tab.page respond]; Drain();
        Check(field.stringValue.length == 0, @"late callback cannot restore a closed session address");

        TestSafariWindow *pending = SafariWindow(@"https://pending.example/");
        pending.deferActiveTab = YES;
        [controller prepareForWindow:(id)pending];
        Type(controller, @"example.net"); [controller navigate:nil]; Drain();
        Check(pending.openedURL == nil && pending.tab.navigatedURL == nil, @"Return while identifying originating tab cannot navigate another tab");
        pending.tabReply((id)pending.tab); pending.tabReply = nil; Drain();
        Check([field.stringValue isEqualToString:@"example.net"], @"early typing preserved after tab lookup");
        [controller navigate:nil]; Drain();
        Check([pending.tab.navigatedURL.host isEqualToString:@"example.net"], @"Return works once originating tab resolves");

        TestSafariWindow *unavailable = SafariWindow(nil);
        [controller prepareForWindow:(id)unavailable]; Drain();
        Check(field.stringValue.length == 0, @"unavailable URL has an empty editable field");
        Check(field.toolTip == nil && [status.stringValue containsString:@"unavailable"], @"unavailable URL clears its tooltip and explains that an address can still be entered");
        Type(controller, @"cats & dogs"); [controller navigate:nil]; Drain();
        Check([unavailable.tab.navigatedURL.host isEqualToString:@"duckduckgo.com"], @"search works even without website URL access");

        TestSafariWindow *kagi = SafariWindow(@"https://example.com/");
        [controller prepareForWindow:(id)kagi]; Drain();
        [(NSPopUpButton *)[controller valueForKey:@"engineButton"] selectItemWithTitle:@"Kagi"];
        Type(controller, @"safari vertical tabs"); [controller navigate:nil]; Drain();
        Check([kagi.tab.navigatedURL.host isEqualToString:@"kagi.com"] && [kagi.tab.navigatedURL.path isEqualToString:@"/search"], @"Kagi selection submits to Kagi search");

        credentials.URL = @"https://kagi.com/search?token=FAKE_TEST_TOKEN&q=%s";
        TestSafariWindow *privateKagi = SafariWindow(@"https://example.com/");
        privateKagi.tab.page.usesPrivateBrowsing = YES;
        [controller prepareForWindow:(id)privateKagi]; Drain();
        [(NSPopUpButton *)[controller valueForKey:@"engineButton"] selectItemWithTitle:@"Kagi"];
        Type(controller, @"a private search"); [controller navigate:nil]; Drain();
        Check([privateKagi.tab.navigatedURL.query containsString:@"token=FAKE_TEST_TOKEN"], @"Safari private browsing state selects the Kagi session link");
        [controller prepareForWindow:(id)kagi]; Drain();
        [(NSPopUpButton *)[controller valueForKey:@"engineButton"] selectItemWithTitle:@"Kagi"];
        Type(controller, @"a normal search"); [controller navigate:nil]; Drain();
        Check(![kagi.tab.navigatedURL.query containsString:@"token="], @"private state is reset between Safari sessions");

        [controller prepareForWindow:(id)kagi]; Drain(); Type(controller, @"unfinished search");
        [controller showSearchSettings:nil]; Drain();
        Check([[controller valueForKey:@"showingSettings"] boolValue], @"Search Settings opens inside popover");
        SearchSettingsController *settingsView = [controller valueForKey:@"settingsController"];
        Check(NSEqualRects(settingsView.view.frame, controller.view.bounds), @"settings view fits the resized popover without clipping");
        NSTableView *layoutTable = [settingsView valueForKey:@"engineTable"];
        NSScrollView *layoutScroll = layoutTable.enclosingScrollView;
        layoutScroll.scrollerStyle = NSScrollerStyleLegacy;
        layoutScroll.autohidesScrollers = NO;
        [layoutScroll tile];
        [settingsView.view layoutSubtreeIfNeeded];
        NSTableCellView *defaultCell = [layoutTable viewAtColumn:0 row:0 makeIfNecessary:YES];
        [defaultCell layoutSubtreeIfNeeded];
        NSBox *defaultBadge = [defaultCell valueForKey:@"defaultBadge"];
        NSRect badgeInTable = [defaultBadge convertRect:defaultBadge.bounds toView:layoutTable];
        Check(NSMaxX(badgeInTable) <= NSMaxX(layoutScroll.documentVisibleRect) - 12, @"Default badge fits with trailing clearance before an always-visible scroller");
        Check([(NSTextField *)[settingsView valueForKey:@"privateLinkField"] stringValue].length == 0, @"settings never preloads private session credential");
        Check(![(NSView *)[settingsView valueForKey:@"enginesPane"] isHidden] && [(NSView *)[settingsView valueForKey:@"privatePane"] isHidden] && [(NSView *)[settingsView valueForKey:@"editorPane"] isHidden], @"settings starts with an uncluttered engines list");
        Check(![(NSButton *)[settingsView valueForKey:@"editEngineButton"] isEnabled], @"built-in engine has no Edit action");
        NSArray *orderBeforeCancel = [settings.searchEngines valueForKey:@"id"];
        [NSApp sendAction:NSSelectorFromString(@"addEngine:") to:settingsView from:nil];
        Check([[settingsView valueForKey:@"editingEngine"] boolValue] && [(NSView *)[settingsView valueForKey:@"enginesPane"] isHidden], @"Add opens a dedicated engine editor");
        ((NSTextField *)[settingsView valueForKey:@"nameField"]).stringValue = @"Unsaved custom engine";
        [NSApp sendAction:NSSelectorFromString(@"cancelEditor:") to:settingsView from:nil];
        Check(settings.customSearchEngines.count == 0 && [[settings.searchEngines valueForKey:@"id"] isEqual:orderBeforeCancel], @"canceling Add preserves saved engines and order");
        [NSApp sendAction:NSSelectorFromString(@"addEngine:") to:settingsView from:nil];
        ((NSTextField *)[settingsView valueForKey:@"nameField"]).stringValue = @"Preview Test Engine";
        ((NSTextField *)[settingsView valueForKey:@"templateField"]).stringValue = @"https://example.org/?q=%s";
        [NSApp sendAction:NSSelectorFromString(@"saveEngine:") to:settingsView from:nil]; Drain();
        Check([settings.searchEngines.firstObject[@"name"] isEqual:@"Preview Test Engine"], @"Save Engine UI creates and selects custom default");
        Check(![[settingsView valueForKey:@"editingEngine"] boolValue], @"successful Add returns to the engine list");
        NSString *customID = settings.selectedEngineID;
        [NSApp sendAction:NSSelectorFromString(@"moveEngineDown:") to:settingsView from:nil]; Drain();
        Check(![settings.selectedEngineID isEqual:customID], @"Move Down UI changes default");
        NSString *defaultBeforeEditing = settings.selectedEngineID;
        [NSApp sendAction:NSSelectorFromString(@"editEngine:") to:settingsView from:nil];
        Check([((NSTextField *)[settingsView valueForKey:@"nameField"]).stringValue isEqual:@"Preview Test Engine"], @"Edit loads the selected custom engine");
        ((NSTextField *)[settingsView valueForKey:@"nameField"]).stringValue = @"Canceled edit";
        [NSApp sendAction:NSSelectorFromString(@"cancelEditor:") to:settingsView from:nil];
        Check([settings.customSearchEngines.firstObject[@"name"] isEqual:@"Preview Test Engine"] && [settings.selectedEngineID isEqual:defaultBeforeEditing], @"canceling Edit preserves the saved engine and default");
        [NSApp sendAction:NSSelectorFromString(@"editEngine:") to:settingsView from:nil];
        ((NSTextField *)[settingsView valueForKey:@"nameField"]).stringValue = @"Google";
        [NSApp sendAction:NSSelectorFromString(@"saveEngine:") to:settingsView from:nil];
        Check([[settingsView valueForKey:@"editingEngine"] boolValue] && [((NSTextField *)[settingsView valueForKey:@"nameField"]).stringValue isEqual:@"Google"], @"invalid edit keeps its editor and input");
        Check([((NSTextField *)[settingsView valueForKey:@"engineStatus"]).stringValue containsString:@"already exists"], @"duplicate name error explains how to fix the edit");
        ((NSTextField *)[settingsView valueForKey:@"nameField"]).stringValue = @"Edited Test Engine";
        [NSApp sendAction:NSSelectorFromString(@"saveEngine:") to:settingsView from:nil]; Drain();
        Check([settings.selectedEngineID isEqual:defaultBeforeEditing] && [settings.searchEngines[1][@"id"] isEqual:customID], @"editing a custom engine preserves its position and the default");
        NSTableView *engineTable = [settingsView valueForKey:@"engineTable"];
        TestEngineDrag *drag = [TestEngineDrag new];
        drag.draggingSource = engineTable;
        drag.draggingPasteboard = [TestEnginePasteboard new];
        drag.draggingPasteboard.item = (id)[settingsView tableView:engineTable pasteboardWriterForRow:1];
        Check(drag.draggingPasteboard.item.types.count == 1 && [[drag.draggingPasteboard.item stringForType:drag.draggingPasteboard.item.types.firstObject] isEqual:customID], @"drag payload contains only the stable engine identifier");
        Check([settingsView tableView:engineTable validateDrop:(id)drag proposedRow:0 proposedDropOperation:NSTableViewDropAbove] == NSDragOperationMove, @"native table accepts a local engine reorder");
        Check([settingsView tableView:engineTable acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove] && [settings.selectedEngineID isEqual:customID], @"dragging an engine to the top makes it default");
        Check([settingsView tableView:engineTable acceptDrop:(id)drag row:3 dropOperation:NSTableViewDropAbove] && [settings.searchEngines[2][@"id"] isEqual:customID], @"downward drag insertion accounts for the removed source row");
        NSArray *orderBeforeExternalDrag = [settings.searchEngines valueForKey:@"id"];
        drag.draggingSource = [NSObject new];
        Check([settingsView tableView:engineTable validateDrop:(id)drag proposedRow:0 proposedDropOperation:NSTableViewDropAbove] == NSDragOperationNone && ![settingsView tableView:engineTable acceptDrop:(id)drag row:0 dropOperation:NSTableViewDropAbove], @"external drag sources cannot change engine order");
        Check([[settings.searchEngines valueForKey:@"id"] isEqual:orderBeforeExternalDrag], @"rejected drag preserves saved order");
        [NSApp sendAction:NSSelectorFromString(@"moveEngineUp:") to:settingsView from:nil]; Drain();
        [NSApp sendAction:NSSelectorFromString(@"moveEngineUp:") to:settingsView from:nil]; Drain();
        Check([settings.selectedEngineID isEqual:customID], @"Move Up UI restores selected engine to default");
        [NSApp sendAction:NSSelectorFromString(@"removeEngine:") to:settingsView from:nil]; Drain();
        Check(settings.customSearchEngines.count == 0, @"Remove Engine UI deletes selected custom engine");
        NSSegmentedControl *paneControl = [settingsView valueForKey:@"paneControl"];
        paneControl.selectedSegment = 1;
        [NSApp sendAction:NSSelectorFromString(@"changePane:") to:settingsView from:paneControl]; Drain();
        Check(![(NSView *)[settingsView valueForKey:@"privatePane"] isHidden] && [(NSView *)[settingsView valueForKey:@"enginesPane"] isHidden], @"Kagi credentials have a separate pane");
        ((NSTextField *)[settingsView valueForKey:@"privateLinkField"]).stringValue = @"https://kagi.com/search?token=NEW_FAKE_TEST_TOKEN&q=%s";
        [NSApp sendAction:NSSelectorFromString(@"savePrivateLink:") to:settingsView from:nil]; Drain();
        Check([credentials.URL containsString:@"NEW_FAKE_TEST_TOKEN"], @"Save Link UI writes to credential store");
        Check([(NSTextField *)[settingsView valueForKey:@"privateLinkField"] stringValue].length == 0, @"Save Link clears sensitive field");
        [NSApp sendAction:NSSelectorFromString(@"removePrivateLink:") to:settingsView from:nil]; Drain();
        Check(credentials.URL == nil, @"Remove Link UI clears credential store");
        ((NSTextField *)[settingsView valueForKey:@"privateLinkField"]).stringValue = @"UNSAVED_TEST_INPUT";
        paneControl.selectedSegment = 0;
        [NSApp sendAction:NSSelectorFromString(@"changePane:") to:settingsView from:paneControl];
        Check([(NSTextField *)[settingsView valueForKey:@"privateLinkField"] stringValue].length == 0, @"leaving the Kagi pane clears an unsaved private link");
        ((NSTextField *)[settingsView valueForKey:@"privateLinkField"]).stringValue = @"UNSAVED_TEST_INPUT";
        [settings moveEngineWithIdentifier:@"kagi" toIndex:0];
        [controller closeSearchSettings]; Drain();
        Check([(NSTextField *)[settingsView valueForKey:@"privateLinkField"] stringValue].length == 0, @"closing settings clears unsaved private link");
        Check([field.stringValue isEqualToString:@"unfinished search"], @"returning from settings preserves typed input");
        Check([((NSPopUpButton *)[controller valueForKey:@"engineButton"]).selectedItem.representedObject isEqual:@"kagi"], @"reordering updates default engine in popover");
        settings.selectedEngineID = @"duckduckgo";

        TestSafariWindow *internal = SafariWindow(@"about:blank");
        [controller prepareForWindow:(id)internal]; Drain();
        Check([field.stringValue isEqualToString:@"about:blank"] && [field.toolTip isEqualToString:@"about:blank"],
              @"a provided internal URL is displayed in full rather than hidden by its scheme");
        Check(((NSTextView *)field.currentEditor).selectedRange.length == field.stringValue.length,
              @"a provided internal URL is selected for replacement like other addresses");
        Type(controller, @"custom://[invalid");
        NSUInteger before = controller.dismissals;
        [controller navigate:nil]; Drain();
        Check(internal.tab.navigatedURL == nil && before == controller.dismissals, @"malformed explicit URL stays open without navigation");
        Check(status.stringValue.length > 0, @"invalid address shows a readable message");

        for (NSString *destination in @[@"file:///tmp/Omnibar.html", @"javascript:void(0)", @"data:text/plain,Hello"]) {
            for (NSUInteger newTab = 0; newTab < 2; newTab++) {
                TestSafariWindow *schemeWindow = SafariWindow(@"https://example.com/");
                [controller prepareForWindow:(id)schemeWindow]; Drain(); Type(controller, destination);
                before = controller.dismissals;
                if (newTab) [controller openInNewTab:nil];
                else [controller navigate:nil];
                Drain();
                NSURL *navigatedURL = newTab ? schemeWindow.openedURL : schemeWindow.tab.navigatedURL;
                Check([navigatedURL.absoluteString isEqualToString:destination] && controller.dismissals == before + 1,
                      @"explicit scheme is forwarded unchanged to Safari's current-tab or new-tab navigation API");
                Check(newTab ? schemeWindow.tab.navigatedURL == nil : schemeWindow.openedURL == nil,
                      @"explicit scheme preserves the requested destination tab");
            }
        }

        for (NSString *destination in @[@"about:blank", @"about:blank#section"]) {
            TestSafariWindow *blankWindow = SafariWindow(@"https://example.com/");
            [controller prepareForWindow:(id)blankWindow]; Drain(); Type(controller, destination);
            before = controller.dismissals; [controller navigate:nil]; Drain();
            Check([blankWindow.openedURL.absoluteString isEqualToString:destination] && blankWindow.tab.navigatedURL == nil
                  && controller.dismissals == before + 1, @"about:blank uses Safari's tab-opening API with completion reporting");
            Check(controller.safariOpenedURL == nil, @"a successful Safari tab opening needs no application-opening fallback");
        }
        TestSafariWindow *rejectedBlank = SafariWindow(@"https://example.com/"); rejectedBlank.failOpen = YES;
        [controller prepareForWindow:(id)rejectedBlank]; Drain(); Type(controller, @"about:blank");
        before = controller.dismissals; [controller navigate:nil]; Drain();
        Check(controller.dismissals == before && [status.stringValue containsString:@"unavailable"] && field.stringValue.length > 0,
              @"an unavailable Safari host keeps the blank-page input visible and reports failure");
        Check(controller.safariOpenedURL == nil && ((NSButton *)[controller valueForKey:@"goButton"]).enabled,
              @"a missing Safari application never falls back to the system default browser and permits retry");
        controller.safariApplicationURL = [NSURL fileURLWithPath:@"/Applications/Safari Technology Preview.app"];
        [controller navigate:nil]; Drain();
        Check(controller.dismissals == before + 1 && [controller.safariOpenedURL.absoluteString isEqualToString:@"about:blank"]
              && [controller.safariOpenApplicationURL isEqual:controller.safariApplicationURL],
              @"a rejected blank tab is handed to the connected Safari application through the workspace API");

        [controller prepareForWindow:(id)rejectedBlank]; Drain(); Type(controller, @"about:blank#section");
        controller.safariOpenError = [NSError errorWithDomain:@"test" code:2
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Safari rejected the blank page."}];
        before = controller.dismissals; [controller navigate:nil]; Drain();
        Check(controller.dismissals == before && [status.stringValue containsString:@"rejected"]
              && [controller.safariOpenedURL.absoluteString isEqualToString:@"about:blank#section"],
              @"Safari application-opening errors remain visible and preserve the complete blank-page URL");
        controller.safariOpenError = nil;
        controller.safariOpenedURL = nil;
        controller.deferSafariApplication = YES;
        [controller navigate:nil]; Drain();
        Check(!((NSButton *)[controller valueForKey:@"goButton"]).enabled, @"Safari application lookup disables repeated submission");
        [controller clearSession];
        [controller prepareForWindow:(id)SafariWindow(@"https://later-session.example/")]; Drain();
        before = controller.dismissals;
        controller.safariApplicationReply(controller.safariApplicationURL); controller.safariApplicationReply = nil;
        controller.deferSafariApplication = NO; Drain();
        Check(controller.safariOpenedURL == nil && controller.dismissals == before
              && [field.stringValue isEqualToString:@"https://later-session.example/"],
              @"a late Safari application lookup cannot open a URL after the original popover closes");

        [controller prepareForWindow:(id)rejectedBlank]; Drain(); Type(controller, @"about:blank");
        controller.deferSafariOpen = YES;
        [controller navigate:nil]; Drain();
        [controller clearSession];
        [controller prepareForWindow:(id)SafariWindow(@"https://another-session.example/")]; Drain();
        before = controller.dismissals;
        controller.safariOpenReply(nil); controller.safariOpenReply = nil; controller.deferSafariOpen = NO; Drain();
        Check(controller.dismissals == before && [field.stringValue isEqualToString:@"https://another-session.example/"],
              @"a late Safari application-open completion cannot dismiss a subsequent popover");

        for (NSString *destination in @[@"mailto:person@example.com", @"tel:123", @"custom://open"]) {
            for (NSUInteger newTab = 0; newTab < 2; newTab++) {
                TestSafariWindow *externalWindow = SafariWindow(@"https://example.com/");
                [controller prepareForWindow:(id)externalWindow]; Drain(); Type(controller, destination);
                before = controller.dismissals;
                if (newTab) [controller openInNewTab:nil];
                else [controller navigate:nil];
                Drain();
                Check([controller.externallyOpenedURL.absoluteString isEqualToString:destination] && controller.dismissals == before + 1,
                      @"external links use the system handler for Return and Command-Return");
                Check(externalWindow.tab.navigatedURL == nil && externalWindow.openedURL == nil,
                      @"external app links do not navigate or create Safari tabs");
            }
        }

        TestSafariWindow *failedExternal = SafariWindow(@"https://example.com/");
        [controller prepareForWindow:(id)failedExternal]; Drain(); Type(controller, @"custom://open");
        controller.externalOpenError = [NSError errorWithDomain:@"test" code:1
                                                      userInfo:@{NSLocalizedDescriptionKey: @"No application is registered for this URL type."}];
        before = controller.dismissals; [controller navigate:nil]; Drain();
        Check(before == controller.dismissals && [status.stringValue containsString:@"No application"],
              @"system handler failures keep the popover open and show the error");
        Check(field.stringValue.length > 0 && ((NSButton *)[controller valueForKey:@"goButton"]).enabled,
              @"a failed external link retains editable input and allows another attempt");
        Check(failedExternal.tab.navigatedURL == nil && failedExternal.openedURL == nil,
              @"failed external links never fall back to a search");
        controller.externalOpenError = nil;
        controller.deferExternalOpen = YES;
        [controller navigate:nil]; Drain();
        Check(!((NSButton *)[controller valueForKey:@"goButton"]).enabled, @"external opening disables repeated submission until completion");
        [controller clearSession];
        [controller prepareForWindow:(id)SafariWindow(@"https://new-session.example/")]; Drain();
        before = controller.dismissals;
        controller.externalReply(nil); controller.externalReply = nil; controller.deferExternalOpen = NO; Drain();
        Check(before == controller.dismissals && [field.stringValue isEqualToString:@"https://new-session.example/"],
              @"a late external-open callback cannot dismiss or mutate a later popover session");

        TestSafariWindow *command = SafariWindow(@"https://example.com/");
        [controller prepareForWindow:(id)command]; Drain(); Type(controller, @"apple.com");
        app.testEvent = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
            modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:0 context:nil
            characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        Check([controller control:field textView:nil doCommandBySelector:@selector(insertNewline:)], @"Return command handled by address field");
        Drain(); app.testEvent = nil;
        Check([command.openedURL.host isEqualToString:@"apple.com"] && command.tab.navigatedURL == nil, @"Command Return opens a new tab in the originating window");

        TestSafariWindow *noTab = SafariWindow(nil); noTab.tab = nil; noTab.failOpen = YES;
        [controller prepareForWindow:(id)noTab]; Drain(); Type(controller, @"apple.com");
        before = controller.dismissals; [controller navigate:nil]; Drain();
        Check(before == controller.dismissals && [status.stringValue containsString:@"couldn’t"], @"failed new tab stays open with an error");
        Check(((NSButton *)[controller valueForKey:@"goButton"]).enabled, @"new tab failure re-enables Go");
        Check([controller control:field textView:nil doCommandBySelector:@selector(cancelOperation:)], @"Escape dismisses popover");
        Check(controller.dismissals == before + 1 && field.stringValue.length == 0, @"Escape clears session address");

        TestEngineManagement();
        printf("Passed %lu native popover checks. Safari API calls were simulated.\n", (unsigned long)checks);
        if (argc > 2 && [@(argv[2]) isEqualToString:@"--preview"]) {
            [[NSUserDefaults standardUserDefaults] removeVolatileDomainForName:NSArgumentDomain];
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            panel.styleMask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable;
            panel.title = @"Omnibar Popover Preview";
            panel.backgroundColor = NSColor.windowBackgroundColor;
            BOOL darkPreview = [NSProcessInfo.processInfo.arguments containsObject:@"--dark"];
            controller.view.appearance = [NSAppearance appearanceNamed:darkPreview ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
            panel.appearance = controller.view.appearance;
            BOOL previewWithoutKagi = [NSProcessInfo.processInfo.arguments containsObject:@"--preview-no-kagi"];
            if (previewWithoutKagi) [settings removeEngineWithIdentifier:@"kagi"];
            [controller prepareForWindow:(id)SafariWindow(@"https://example.com/a?one=1#section")];
            if (previewWithoutKagi || [NSProcessInfo.processInfo.arguments containsObject:@"--preview-settings"]) {
                Drain();
                [controller showSearchSettings:nil];
            }
            [panel center];
            [panel makeKeyAndOrderFront:nil];
            [app activateIgnoringOtherApps:YES];
            fflush(stdout);
            [app run];
        }
    }
    return 0;
}
