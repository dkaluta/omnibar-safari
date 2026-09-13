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

@interface TestPopover : AddressPopoverController
@property NSUInteger dismissals;
@end
@implementation TestPopover
- (void)dismissPopover { self.dismissals++; [self clearSession]; }
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

        for (NSString *destination in @[@"about:blank", @"file:///tmp/Omnibar.html", @"mailto:person@example.com",
                                        @"tel:123", @"custom://open", @"javascript:void(0)", @"data:text/plain,Hello"]) {
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
            [controller prepareForWindow:(id)SafariWindow(@"https://example.com/a?one=1#section")];
            [panel center];
            [panel makeKeyAndOrderFront:nil];
            [app activateIgnoringOtherApps:YES];
            fflush(stdout);
            [app run];
        }
    }
    return 0;
}
