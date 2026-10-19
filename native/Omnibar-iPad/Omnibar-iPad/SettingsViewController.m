#import "SettingsViewController.h"
#import "OmnibarMobileSettings.h"
#import <SafariServices/SafariServices.h>

typedef NS_ENUM(NSInteger, OMSection) { OMSetup, OMEngines, OMManage, OMWebsites, OMPrivate, OMTips, OMSectionCount };

@interface SettingsViewController () <UITextFieldDelegate>
@property (strong) OmnibarSearchSettings *settings;
@property (copy) NSArray<NSDictionary *> *engines;
@property (strong) UITextField *suffixField;
@property (strong) UITextField *privateField;
@property (copy) NSString *privateStatus;
@property BOOL hasPrivateLink;
@property BOOL keychainBusy;
@property NSUInteger keychainGeneration;
@property (strong) dispatch_queue_t keychainQueue;
@end

@implementation SettingsViewController
- (instancetype)initWithSettings:(OmnibarSearchSettings *)settings {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _settings = settings;
        _engines = settings.searchEngines ?: @[];
        _privateStatus = @"No private link saved";
        _keychainQueue = dispatch_queue_create("com.omnibar.ipad.keychain", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (UITextField *)fieldWithPlaceholder:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.placeholder = placeholder;
    field.secureTextEntry = secure;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.smartQuotesType = UITextSmartQuotesTypeNo;
    field.smartDashesType = UITextSmartDashesTypeNo;
    field.keyboardType = UIKeyboardTypeURL;
    field.returnKeyType = UIReturnKeyDone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    field.accessibilityLabel = placeholder;
    field.delegate = self;
    return field;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Omnibar";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addEngine:)], self.editButtonItem];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    self.suffixField = [self fieldWithPlaceholder:@"Default website suffix" secure:NO];
    self.suffixField.text = self.settings.defaultURLSuffix ?: @".com";
    self.privateField = [self fieldWithPlaceholder:@"Kagi private session link" secure:YES];
    self.privateField.accessibilityHint = @"Saved links are never displayed. Paste a new link, then choose Save Link.";
    if (!self.settings) {
        self.navigationItem.rightBarButtonItems = @[];
        self.suffixField.enabled = self.privateField.enabled = NO;
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
    [self refreshSettings];
}
- (void)refreshSettings {
    if (!self.isViewLoaded) return;
    self.suffixField.text = self.settings.defaultURLSuffix ?: @".com";
    [self reloadEngines];
    [self refreshPrivateStatus];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasKagi { return [[self.engines valueForKey:@"id"] containsObject:@"kagi"]; }
- (void)reloadEngines {
    BOOL hadKagi = [self hasKagi];
    self.engines = self.settings.searchEngines ?: @[];
    if (![self hasKagi]) [self clearSensitiveInput];
    [self.tableView reloadData];
    if (!hadKagi && [self hasKagi]) [self refreshPrivateStatus];
}
- (void)clearSensitiveInput {
    self.privateField.text = @"";
    [self.privateField resignFirstResponder];
    ++self.keychainGeneration;
    self.keychainBusy = NO;
    self.privateField.enabled = self.settings != nil;
    if ([self.presentedViewController isKindOfClass:UIAlertController.class]) {
        for (UITextField *field in [(UIAlertController *)self.presentedViewController textFields]) field.text = @"";
        [self dismissViewControllerAnimated:NO completion:nil];
    }
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Omnibar" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)announce:(NSString *)message { UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return OMSectionCount; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == OMSetup) return 1;
    if (!self.settings) return 0;
    switch (section) {
        case OMEngines: return self.engines.count;
        case OMManage: return 2;
        case OMWebsites: return 2;
        case OMPrivate: return [self hasKagi] ? 4 : 0;
        case OMTips: return 1;
        default: return 0;
    }
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section != OMSetup && !self.settings) return nil;
    switch (section) {
        case OMSetup: return @"Safari extension";
        case OMEngines: return @"Search engines · first is default";
        case OMWebsites: return @"Websites";
        case OMPrivate: return [self hasKagi] ? @"Kagi Private Browsing" : nil;
        case OMTips: return @"Introduction";
        default: return nil;
    }
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == OMSetup) return self.settings
        ? @"Omnibar’s Safari palette requires a connected hardware keyboard. Enable Omnibar Commands in Safari’s Extensions settings, open a webpage, and press ⌘⇧P. Use ↑/↓ to select, Return to open, ⌘Return for a new tab, and Escape to close. Change search settings here in the Omnibar app."
        : @"Omnibar’s local settings could not be opened. Reinstall the signed app and try again. Safari setup is still available.";
    if (!self.settings) return nil;
    if (section == OMEngines) return @"Tap an engine to make it the default. Edit to reorder or remove engines; at least one remains. Use a custom engine’s info button to edit it. Keyboard: ⌘N adds an engine, ⌘E edits a selected custom engine, and ⌘⌥↑/↓ moves an engine.";
    if (section == OMWebsites) return [NSString stringWithFormat:@"A leading dot expands a website: .cnn → https://www.cnn%@/. A supplied suffix is kept: .bsky.app → https://www.bsky.app/. Multi-label suffixes such as .co.uk work too.", self.settings.defaultURLSuffix];
    if (section == OMPrivate && [self hasKagi]) return @"Optional. Saved only in this device’s Keychain, never displayed again or synced by Omnibar. Used only when you submit a Kagi search in Safari Private Browsing. Removing Kagi or restoring engines keeps the saved link.";
    if (section == OMTips) return @"The developer receives no extension data. Tab information and unsubmitted text stay in memory. Settings stay on this device. Submitted searches go to the provider you choose.";
    return nil;
}
- (UITableViewCell *)fieldCell:(UITextField *)field {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    [field removeFromSuperview];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
        [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        [field.heightAnchor constraintGreaterThanOrEqualToConstant:32]
    ]];
    return cell;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == OMWebsites && path.row == 0) return [self fieldCell:self.suffixField];
    if (path.section == OMPrivate && path.row == 0) return [self fieldCell:self.privateField];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory = cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = self.view.tintColor;
    BOOL enabled = YES;
    switch (path.section) {
        case OMSetup: cell.textLabel.text = @"Set Up in Safari…"; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; break;
        case OMEngines: {
            NSDictionary *engine = self.engines[path.row];
            cell.textLabel.text = engine[@"name"];
            cell.textLabel.textColor = UIColor.labelColor;
            cell.detailTextLabel.text = path.row == 0 ? @"Default search engine" : nil;
            cell.accessoryType = [engine[@"id"] hasPrefix:@"custom:"] ? UITableViewCellAccessoryDetailButton
                : path.row == 0 ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            cell.accessibilityHint = @"Activate to make this the default search engine.";
            break;
        }
        case OMManage: cell.textLabel.text = path.row == 0 ? @"Add Search Engine…" : @"Restore Built-in Engines"; break;
        case OMWebsites: cell.textLabel.text = @"Save Website Suffix"; break;
        case OMPrivate:
            if (path.row == 1) { cell.textLabel.text = @"Save Link"; enabled = !self.keychainBusy; }
            if (path.row == 2) { cell.textLabel.text = @"Remove Link"; enabled = !self.keychainBusy && self.hasPrivateLink; }
            if (path.row == 3) { cell.textLabel.text = self.privateStatus; cell.textLabel.textColor = UIColor.secondaryLabelColor; enabled = NO; }
            break;
        case OMTips: cell.textLabel.text = @"Show Palette Tips Again"; break;
    }
    if (!enabled) { cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.userInteractionEnabled = NO; cell.textLabel.textColor = UIColor.secondaryLabelColor; }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    if (path.section == OMSetup) { [self openSafariSettings:nil]; return; }
    if (!self.settings) return;
    if (path.section == OMEngines) {
        NSString *identifier = self.engines[path.row][@"id"];
        [self.settings moveEngineWithIdentifier:identifier toIndex:0]; [self reloadEngines];
        [self announce:@"Default search engine updated."];
    } else if (path.section == OMManage && path.row == 0) [self addEngine:nil];
    else if (path.section == OMManage) {
        [self.settings restoreDefaultSearchEngines]; [self reloadEngines]; [self announce:@"Built-in engines restored. Custom engines and the private link are kept."];
    } else if (path.section == OMWebsites && path.row == 1) [self saveSuffix];
    else if (path.section == OMPrivate && path.row == 1) [self savePrivateLink];
    else if (path.section == OMPrivate && path.row == 2) [self removePrivateLink];
    else if (path.section == OMTips) { self.settings.showPaletteTips = YES; [self showMessage:@"The introduction will appear the next time you open Omnibar in Safari."]; }
}
- (void)openSafariSettings:(id)sender {
    if (@available(iOS 26.2, *)) {
        NSString *identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".Commands"];
        [SFSafariSettings openExtensionsSettingsForIdentifiers:@[identifier] completionHandler:^(NSError *error) {
            if (error) dispatch_async(dispatch_get_main_queue(), ^{ [self showSetupInstructions]; });
        }];
    } else [self showSetupInstructions];
}
- (void)showSetupInstructions {
    [self showMessage:@"In Settings, open Apps → Safari → Extensions and enable Omnibar Commands. On older iPadOS versions, Safari is directly in Settings. Connect a hardware keyboard, open a webpage in Safari, and press ⌘⇧P. The iPad palette is available only through this keyboard shortcut."];
}
- (void)addEngine:(id)sender {
    if (!self.settings || self.presentedViewController) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Add Search Engine" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Custom Search Engine…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self dismissViewControllerAnimated:YES completion:^{ [self editEngine:nil]; }];
    }]];
    for (NSDictionary *engine in self.settings.removedDefaultSearchEngines) {
        [menu addAction:[UIAlertAction actionWithTitle:engine[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self.settings restoreDefaultEngineWithIdentifier:engine[@"id"]]; [self reloadEngines];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)editEngine:(NSDictionary *)engine {
    UIAlertController *editor = [UIAlertController alertControllerWithTitle:engine ? @"Edit Search Engine" : @"Custom Search Engine"
        message:@"Use %s where search terms belong. Do not put passwords or session tokens in a custom template." preferredStyle:UIAlertControllerStyleAlert];
    [editor addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Name"; field.text = engine[@"name"]; }];
    [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://example.com/search?q=%s"; field.text = engine[@"template"];
        field.keyboardType = UIKeyboardTypeURL; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo; field.smartQuotesType = UITextSmartQuotesTypeNo;
    }];
    [editor addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakEditor = editor;
    [editor addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSError *error = nil;
        NSArray<UITextField *> *fields = weakEditor.textFields;
        if (![self.settings saveCustomEngine:engine[@"id"] name:fields[0].text ?: @"" template:fields[1].text ?: @"" error:&error]) {
            NSString *message = error.localizedDescription ?: @"Check the engine name and search URL.";
            [self dismissViewControllerAnimated:YES completion:^{ [self showMessage:message]; }];
        } else [self reloadEngines];
    }]];
    [self presentViewController:editor animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)path {
    if (path.section == OMEngines) [self editEngine:self.engines[path.row]];
}
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path { return path.section == OMEngines && self.engines.count > 1; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)path { return path.section == OMEngines; }
- (NSIndexPath *)tableView:(UITableView *)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)source toProposedIndexPath:(NSIndexPath *)destination {
    if (destination.section == OMEngines) return destination;
    return [NSIndexPath indexPathForRow:destination.section < OMEngines ? 0 : self.engines.count - 1 inSection:OMEngines];
}
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)source toIndexPath:(NSIndexPath *)destination {
    [self.settings moveEngineWithIdentifier:self.engines[source.row][@"id"] toIndex:destination.row]; [self reloadEngines];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style == UITableViewCellEditingStyleDelete && path.section == OMEngines) {
        [self.settings removeEngineWithIdentifier:self.engines[path.row][@"id"]]; [self reloadEngines];
    }
}
- (void)saveSuffix {
    NSError *error = nil;
    if (![self.settings setDefaultURLSuffix:self.suffixField.text ?: @"" error:&error]) { [self showMessage:error.localizedDescription]; return; }
    self.suffixField.text = self.settings.defaultURLSuffix;
    [self.suffixField resignFirstResponder]; [self.tableView reloadData]; [self announce:@"Website suffix saved."];
}
- (BOOL)textFieldShouldReturn:(UITextField *)field {
    if (field == self.suffixField) [self saveSuffix];
    else if (field == self.privateField) [self savePrivateLink];
    return YES;
}
- (void)keychainOperation:(BOOL (^)(NSError **error))operation success:(NSString *)success {
    if (self.keychainBusy || ![self hasKagi]) return;
    self.keychainBusy = YES;
    NSUInteger generation = ++self.keychainGeneration;
    self.privateField.enabled = NO;
    self.privateStatus = @"Checking Keychain…";
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:OMPrivate] withRowAnimation:UITableViewRowAnimationNone];
    dispatch_async(self.keychainQueue, ^{
        NSError *error = nil;
        BOOL result = operation(&error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.keychainGeneration) return;
            self.keychainBusy = NO; self.privateField.enabled = YES;
            if (!error) self.hasPrivateLink = result;
            self.privateStatus = error ? ([@[@"com.dkaluta.omnibar.settings", @"com.omnibar.URLResolver"] containsObject:error.domain]
                ? error.localizedDescription : @"Couldn’t access Keychain. Unlock this iPad and try again.")
                : (success ?: (result ? @"Private link saved" : @"No private link saved"));
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:OMPrivate] withRowAnimation:UITableViewRowAnimationNone];
            [self announce:self.privateStatus];
        });
    });
}
- (void)refreshPrivateStatus {
    if (!self.settings || ![self hasKagi]) return;
    [self keychainOperation:^BOOL(NSError **error) { return [self.settings hasKagiPrivateURLWithError:error]; } success:nil];
}
- (void)savePrivateLink {
    if (self.keychainBusy || !self.privateField.text.length) return;
    NSString *link = self.privateField.text;
    self.privateField.text = @""; [self.privateField resignFirstResponder];
    [self keychainOperation:^BOOL(NSError **error) { return [self.settings saveKagiPrivateURL:link error:error]; } success:@"Private link saved"];
}
- (void)removePrivateLink {
    if (self.keychainBusy || !self.hasPrivateLink) return;
    self.privateField.text = @""; [self.privateField resignFirstResponder];
    [self keychainOperation:^BOOL(NSError **error) { [self.settings removeKagiPrivateURLWithError:error]; return NO; } success:@"No private link saved"];
}
- (NSArray<UIKeyCommand *> *)keyCommands {
    if (self.presentedViewController) return @[];
    NSMutableArray *commands = [NSMutableArray arrayWithArray:@[
        [UIKeyCommand keyCommandWithInput:@"n" modifierFlags:UIKeyModifierCommand action:@selector(addEngine:) discoverabilityTitle:@"Add Search Engine"],
        [UIKeyCommand keyCommandWithInput:@"," modifierFlags:UIKeyModifierCommand action:@selector(focusSettings:) discoverabilityTitle:@"Search Settings"],
        [UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(endEditing:) discoverabilityTitle:@"Finish Editing"]]];
    if (!self.suffixField.isFirstResponder && !self.privateField.isFirstResponder) {
        [commands addObjectsFromArray:@[
            [UIKeyCommand keyCommandWithInput:@"e" modifierFlags:UIKeyModifierCommand action:@selector(editSelectedEngine:) discoverabilityTitle:@"Edit Custom Engine"],
            [UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow modifierFlags:0 action:@selector(moveSelection:) discoverabilityTitle:@"Previous Setting"],
            [UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow modifierFlags:0 action:@selector(moveSelection:) discoverabilityTitle:@"Next Setting"],
            [UIKeyCommand keyCommandWithInput:@"\r" modifierFlags:0 action:@selector(activateSelection:) discoverabilityTitle:@"Choose Setting"],
            [UIKeyCommand keyCommandWithInput:UIKeyInputUpArrow modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate action:@selector(moveEngine:) discoverabilityTitle:@"Move Engine Up"],
            [UIKeyCommand keyCommandWithInput:UIKeyInputDownArrow modifierFlags:UIKeyModifierCommand | UIKeyModifierAlternate action:@selector(moveEngine:) discoverabilityTitle:@"Move Engine Down"]]];
    }
    return commands;
}
- (void)focusSettings:(id)sender {
    [self.view endEditing:YES];
    NSIndexPath *path = [NSIndexPath indexPathForRow:0 inSection:self.engines.count ? OMEngines : OMSetup];
    [self.tableView selectRowAtIndexPath:path animated:YES scrollPosition:UITableViewScrollPositionMiddle];
}
- (void)endEditing:(id)sender { [self.view endEditing:YES]; [self setEditing:NO animated:YES]; }
- (void)moveSelection:(UIKeyCommand *)command {
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray new];
    for (NSInteger section = 0; section < OMSectionCount; section++)
        for (NSInteger row = 0; row < [self tableView:self.tableView numberOfRowsInSection:section]; row++)
            if (!(section == OMPrivate && row == 3)) [paths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
    NSInteger index = [paths indexOfObject:self.tableView.indexPathForSelectedRow ?: [NSIndexPath indexPathForRow:0 inSection:OMSetup]];
    if (index == NSNotFound) index = 0;
    index = MAX(0, MIN((NSInteger)paths.count - 1, index + ([command.input isEqual:UIKeyInputUpArrow] ? -1 : 1)));
    [self.tableView selectRowAtIndexPath:paths[index] animated:YES scrollPosition:UITableViewScrollPositionMiddle];
}
- (void)activateSelection:(id)sender {
    NSIndexPath *path = self.tableView.indexPathForSelectedRow;
    if (!path) return;
    if (path.section == OMWebsites && path.row == 0) [self.suffixField becomeFirstResponder];
    else if (path.section == OMPrivate && path.row == 0) [self.privateField becomeFirstResponder];
    else [self tableView:self.tableView didSelectRowAtIndexPath:path];
}
- (void)moveEngine:(UIKeyCommand *)command {
    NSIndexPath *path = self.tableView.indexPathForSelectedRow;
    if (path.section != OMEngines || path.row >= (NSInteger)self.engines.count) return;
    NSInteger destination = MAX(0, MIN((NSInteger)self.engines.count - 1, path.row + ([command.input isEqual:UIKeyInputUpArrow] ? -1 : 1)));
    [self.settings moveEngineWithIdentifier:self.engines[path.row][@"id"] toIndex:destination]; [self reloadEngines];
    [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:destination inSection:OMEngines] animated:YES scrollPosition:UITableViewScrollPositionMiddle];
    [self announce:destination == 0 ? @"Engine moved to the default position." : @"Engine order updated."];
}
- (void)editSelectedEngine:(id)sender {
    NSIndexPath *path = self.tableView.indexPathForSelectedRow;
    if (path.section == OMEngines && path.row < (NSInteger)self.engines.count
        && [self.engines[path.row][@"id"] hasPrefix:@"custom:"]) [self editEngine:self.engines[path.row]];
}
@end
