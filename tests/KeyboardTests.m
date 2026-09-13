#import <AppKit/AppKit.h>
#import <SafariServices/SafariServices.h>
#import "AddressPopoverController.h"
#import "SettingsTestSupport.h"

// Dispatch real NSEvents through AppKit's key-equivalent and field-editor paths.
// Only Safari's out-of-process API proxies are replaced; no live tab is modified.
@interface KeyboardApplication : NSApplication
@property (strong) NSEvent *testEvent;
@end
@implementation KeyboardApplication
- (NSEvent *)currentEvent { return self.testEvent ?: super.currentEvent; }
@end

@interface KeyboardPopover : AddressPopoverController
@property NSUInteger dismissals;
@end
@implementation KeyboardPopover
- (void)dismissPopover { self.dismissals++; [self clearSession]; }
@end

@interface KeyboardPage : NSObject
@property (strong) NSURL *url;
@property BOOL usesPrivateBrowsing;
@end
@implementation KeyboardPage
- (void)getPagePropertiesWithCompletionHandler:(void (^)(SFSafariPageProperties *))completion {
    completion((id)self);
}
@end

@interface KeyboardTab : NSObject
@property (strong) KeyboardPage *page;
@property (strong) NSURL *navigatedURL;
@end
@implementation KeyboardTab
- (void)getActivePageWithCompletionHandler:(void (^)(SFSafariPage *))completion { completion((id)self.page); }
- (void)navigateToURL:(NSURL *)URL { self.navigatedURL = URL; }
@end

@interface KeyboardSafariWindow : NSObject
@property (strong) KeyboardTab *tab;
@property (strong) NSURL *openedURL;
@property NSUInteger openedTabs;
@end
@implementation KeyboardSafariWindow
- (void)getActiveTabWithCompletionHandler:(void (^)(SFSafariTab *))completion { completion((id)self.tab); }
- (void)openTabWithURL:(NSURL *)URL makeActiveIfPossible:(BOOL)active completionHandler:(void (^)(SFSafariTab *))completion {
    self.openedURL = URL;
    self.openedTabs++;
    completion((id)[KeyboardTab new]);
}
@end

static NSUInteger checks;

static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void Drain(void) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.035];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
}

static KeyboardSafariWindow *Prepare(KeyboardPopover *controller) {
    KeyboardSafariWindow *window = [KeyboardSafariWindow new];
    window.tab = [KeyboardTab new];
    window.tab.page = [KeyboardPage new];
    window.tab.page.url = [NSURL URLWithString:@"https://example.com/current"];
    [controller prepareForWindow:(id)window];
    Drain();
    NSTextField *field = [controller valueForKey:@"addressField"];
    Check(field.currentEditor != nil, @"address field owns a real AppKit field editor");
    Check([field.currentEditor isKindOfClass:NSTextView.class], @"field editor is NSTextView");
    return window;
}

static NSEvent *KeyEvent(NSWindow *panel, NSString *characters, unsigned short keyCode, NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
        timestamp:0 windowNumber:panel.windowNumber context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
}

static BOOL SendKey(KeyboardApplication *app, NSWindow *panel, NSString *characters,
                    unsigned short keyCode, NSEventModifierFlags flags) {
    NSEvent *event = KeyEvent(panel, characters, keyCode, flags);
    app.testEvent = event;
    // A key equivalent gets first refusal. Unhandled events go to the focused field editor.
    BOOL handled = [panel performKeyEquivalent:event];
    if (!handled) [panel sendEvent:event];
    Drain();
    app.testEvent = nil;
    return handled;
}

static void EnterAddress(KeyboardPopover *controller) {
    NSTextField *field = [controller valueForKey:@"addressField"];
    [field selectText:nil];
    NSTextView *editor = (id)field.currentEditor;
    [editor insertText:@"apple.com" replacementRange:editor.selectedRange];
    Check([field.stringValue isEqualToString:@"apple.com"], @"field-editor text insertion updates submitted address");
}

int main(void) {
    @autoreleasepool {
        KeyboardApplication *app = (id)[KeyboardApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        KeyboardPopover *controller = [[KeyboardPopover alloc] initWithNibName:nil bundle:nil];
        [controller setValue:OMMakeTestSettings(NULL, NULL) forKey:@"searchSettings"];
        NSWindow *panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 100)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        panel.contentView = controller.view;

        KeyboardSafariWindow *normal = Prepare(controller);
        EnterAddress(controller);
        SendKey(app, panel, @"\r", 36, 0);
        Check([normal.tab.navigatedURL.absoluteString isEqualToString:@"https://apple.com/"], @"Return navigates originating tab through field-editor dispatch");
        Check(normal.openedTabs == 0, @"Return does not create a tab");

        KeyboardSafariWindow *commandReturn = Prepare(controller);
        EnterAddress(controller);
        Check(SendKey(app, panel, @"\r", 36, NSEventModifierFlagCommand), @"Command Return is a handled native key equivalent");
        Check(commandReturn.openedTabs == 1 && [commandReturn.openedURL.host isEqualToString:@"apple.com"], @"Command Return creates exactly one new tab");
        Check(commandReturn.tab.navigatedURL == nil, @"Command Return preserves originating tab");

        KeyboardSafariWindow *commandEnter = Prepare(controller);
        EnterAddress(controller);
        Check(SendKey(app, panel, @"\x03", 76, NSEventModifierFlagCommand | NSEventModifierFlagNumericPad), @"Command keypad Enter is a handled native key equivalent");
        Check(commandEnter.openedTabs == 1 && [commandEnter.openedURL.host isEqualToString:@"apple.com"], @"Command keypad Enter creates exactly one new tab");
        Check(commandEnter.tab.navigatedURL == nil, @"Command keypad Enter preserves originating tab");

        KeyboardSafariWindow *fieldEditorFallback = Prepare(controller);
        EnterAddress(controller);
        NSTextField *fallbackField = [controller valueForKey:@"addressField"];
        app.testEvent = KeyEvent(panel, @"\r", 36, NSEventModifierFlagCommand);
        // Some hosts deliver the event directly to text interpretation. AppKit maps this
        // event to noop:, so the controller must inspect the actual event in its fallback.
        [(NSTextView *)fallbackField.currentEditor interpretKeyEvents:@[app.testEvent]];
        Drain();
        app.testEvent = nil;
        Check(fieldEditorFallback.openedTabs == 1 && [fieldEditorFallback.openedURL.host isEqualToString:@"apple.com"],
              @"direct field-editor interpretation also handles Command Return");
        Check(fieldEditorFallback.tab.navigatedURL == nil, @"field-editor fallback preserves originating tab");

        KeyboardSafariWindow *editing = Prepare(controller);
        NSTextField *field = [controller valueForKey:@"addressField"];
        SendKey(app, panel, @"x", 7, 0);
        Check([field.stringValue isEqualToString:@"x"], @"normal typing replaces the selected URL");
        SendKey(app, panel, @"y", 16, 0);
        Check([field.stringValue isEqualToString:@"xy"], @"normal typing continues without selection being reset");
        SendKey(app, panel, @"\x7f", 51, 0);
        Check([field.stringValue isEqualToString:@"x"], @"Delete edits the address normally");
        Check(editing.tab.navigatedURL == nil && editing.openedTabs == 0, @"editing does not navigate or open tabs");
        NSUInteger dismissals = controller.dismissals;
        SendKey(app, panel, @"\x1b", 53, 0);
        Check(controller.dismissals == dismissals + 1, @"Escape dismisses through actual field-editor command dispatch");
        Check(field.stringValue.length == 0, @"Escape clears the address session");

        KeyboardSafariWindow *settingsWindow = Prepare(controller);
        EnterAddress(controller);
        NSUInteger dismissalsBeforeSettings = controller.dismissals;
        NSButton *settingsButton = [controller valueForKey:@"settingsButton"];
        [settingsButton performClick:nil];
        [panel setContentSize:controller.preferredContentSize];
        [controller.view layoutSubtreeIfNeeded];
        Check([[controller valueForKey:@"showingSettings"] boolValue], @"settings button opens the settings view");
        NSViewController *settingsController = [controller valueForKey:@"settingsController"];
        OmnibarSearchSettings *searchSettings = [controller valueForKey:@"searchSettings"];
        NSUInteger customCount = searchSettings.customSearchEngines.count;
        [NSApp sendAction:NSSelectorFromString(@"addEngine:") to:settingsController from:nil];
        NSTextField *nameField = [settingsController valueForKey:@"nameField"];
        Check([[settingsController valueForKey:@"editingEngine"] boolValue] && nameField.currentEditor != nil, @"Add opens the native engine editor and focuses its name field");
        [(NSTextView *)nameField.currentEditor insertText:@"Unsaved keyboard test" replacementRange:((NSTextView *)nameField.currentEditor).selectedRange];
        Check(SendKey(app, panel, @"\x1b", 53, 0), @"Escape invokes the engine editor's Cancel key equivalent");
        Check(![[settingsController valueForKey:@"editingEngine"] boolValue] && [[controller valueForKey:@"showingSettings"] boolValue], @"editor Escape returns to the engine list before closing settings");
        Check(searchSettings.customSearchEngines.count == customCount, @"editor Escape never saves the canceled engine");
        [NSApp sendAction:NSSelectorFromString(@"addEngine:") to:settingsController from:nil];
        [panel makeFirstResponder:nil];
        Check(SendKey(app, panel, @"\x1b", 53, 0) && ![[settingsController valueForKey:@"editingEngine"] boolValue], @"editor Escape also cancels without a focused text field");
        [panel makeFirstResponder:nil];
        Check(![panel.firstResponder isKindOfClass:NSTextView.class], @"settings Escape case begins without a focused text field");
        Check(SendKey(app, panel, @"\x1b", 53, 0), @"Escape is a handled settings key equivalent without field focus");
        Check(![[controller valueForKey:@"showingSettings"] boolValue], @"Escape returns from settings to the address view");
        Check(![[controller valueForKey:@"addressContent"] isHidden], @"address content is visible after settings Escape");
        Check(controller.dismissals == dismissalsBeforeSettings, @"settings Escape preserves the open address popover");
        Check([field.stringValue isEqualToString:@"apple.com"], @"settings Escape preserves the edited address");
        Check(settingsWindow.tab.navigatedURL == nil && settingsWindow.openedTabs == 0, @"settings Escape never navigates or opens a tab");

        printf("Passed %lu native keyboard checks using AppKit event dispatch. Safari calls were simulated.\n", (unsigned long)checks);
    }
    return 0;
}
