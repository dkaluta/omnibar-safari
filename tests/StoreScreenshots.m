#import <AppKit/AppKit.h>
#import <SafariServices/SafariServices.h>
#import "AddressPopoverController.h"
#import "SearchSettingsController.h"
#import "SettingsTestSupport.h"

// Actual native controls, deterministic example data, and in-memory preferences.
// This renderer never asks Safari for a window and never reads the real Keychain.
@interface ScreenshotPage : NSObject
@property (strong) NSURL *url;
@property BOOL usesPrivateBrowsing;
@end
@implementation ScreenshotPage
- (void)getPagePropertiesWithCompletionHandler:(void (^)(SFSafariPageProperties *))reply { reply((id)self); }
@end

@interface ScreenshotTab : NSObject
@property (strong) ScreenshotPage *page;
@end
@implementation ScreenshotTab
- (void)getActivePageWithCompletionHandler:(void (^)(SFSafariPage *))reply { reply((id)self.page); }
@end

@interface ScreenshotSafariWindow : NSObject
@property (strong) ScreenshotTab *tab;
@end
@implementation ScreenshotSafariWindow
- (void)getActiveTabWithCompletionHandler:(void (^)(SFSafariTab *))reply { reply((id)self.tab); }
@end

@interface ScreenshotBackground : NSView
@end
@implementation ScreenshotBackground
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(dirtyRect);
}
@end

static void Fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

static void Drain(void) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.08];
    while (deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
    }
}

static NSWindow *Host(NSViewController *controller, NSSize size) {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    ScreenshotBackground *background = [[ScreenshotBackground alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    controller.view.frame = background.bounds;
    controller.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    controller.view.appearance = window.appearance;
    [background addSubview:controller.view];
    window.contentView = background;
    [background layoutSubtreeIfNeeded];
    Drain();
    return window;
}

static NSBitmapImageRep *Capture(NSWindow *window, NSString *path) {
    NSView *view = window.contentView;
    [window makeFirstResponder:nil];
    [view layoutSubtreeIfNeeded];
    [view displayIfNeeded];
    NSSize size = view.bounds.size;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(size.width * 2) pixelsHigh:(NSInteger)(size.height * 2)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = size;
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSData *data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!data || ![data writeToFile:path atomically:YES]) Fail(@"Could not write a native view capture.");
    return rep;
}

static void Text(NSString *text, NSRect rect, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineSpacing = 7;
    [text drawInRect:rect withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph
    }];
}

static void Compose(NSBitmapImageRep *native, NSString *title, NSString *detail, NSString *path, BOOL address) {
    NSBitmapImageRep *canvas = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1440 pixelsHigh:900
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    canvas.size = NSMakeSize(1440, 900);
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
    if (!graphics) Fail(@"Could not create a native canvas graphics context.");
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];
    NSColor *background = [NSColor colorWithSRGBRed:0.954 green:0.961 blue:0.974 alpha:1];
    NSColor *ink = [NSColor colorWithSRGBRed:0.12 green:0.15 blue:0.19 alpha:1];
    NSColor *secondary = [NSColor colorWithSRGBRed:0.40 green:0.44 blue:0.49 alpha:1];
    [background setFill];
    NSRectFill(NSMakeRect(0, 0, 1440, 900));
    CGFloat left = address ? 200 : 72;
    Text(@"OMNIBAR FOR SAFARI", NSMakeRect(left, 798, 480, 28), 17, NSFontWeightSemibold, secondary);
    if (address) {
        Text(title, NSMakeRect(left, 606, 1040, 145), 62, NSFontWeightSemibold, ink);
        Text(detail, NSMakeRect(left, 518, 1040, 72), 24, NSFontWeightRegular, secondary);
    } else {
        Text(title, NSMakeRect(left, 538, 450, 205), 50, NSFontWeightSemibold, ink);
        Text(detail, NSMakeRect(left, 340, 445, 160), 23, NSFontWeightRegular, secondary);
    }
    NSRect frame = address ? NSMakeRect(200, 274, 1040, 200) : NSMakeRect(614, 90, 754, 696);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.16];
    shadow.shadowBlurRadius = 32;
    shadow.shadowOffset = NSMakeSize(0, -10);
    [shadow set];
    [NSColor.windowBackgroundColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:frame xRadius:18 yRadius:18] fill];
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRoundedRect:frame xRadius:18 yRadius:18] addClip];
    NSImage *image = [[NSImage alloc] initWithSize:native.size];
    [image addRepresentation:native];
    [image drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext restoreGraphicsState];
    // AppKit draws into RGBA contexts. The opaque store export contains RGB only.
    NSBitmapImageRep *opaque = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1440 pixelsHigh:900
        bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    for (NSInteger y = 0; y < 900; y++) {
        const unsigned char *source = canvas.bitmapData + y * canvas.bytesPerRow;
        unsigned char *destination = opaque.bitmapData + y * opaque.bytesPerRow;
        for (NSInteger x = 0; x < 1440; x++) {
            destination[x * 3] = source[x * 4];
            destination[x * 3 + 1] = source[x * 4 + 1];
            destination[x * 3 + 2] = source[x * 4 + 2];
        }
    }
    NSData *data = [opaque representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!data || ![data writeToFile:path atomically:YES]) Fail(@"Could not write an App Store image.");
}

static void VerifyRowHitTesting(SearchSettingsController *controller) {
    NSTableView *table = [controller valueForKey:@"engineTable"];
    [controller.view layoutSubtreeIfNeeded];
    NSRect row = [table rectOfRow:2];
    NSPoint tablePoint = NSMakePoint(NSMinX(row) + 100, NSMidY(row));
    NSPoint parentPoint = [table convertPoint:tablePoint toView:controller.view.superview];
    NSView *hit = [controller.view hitTest:parentPoint];
    BOOL reachesTable = hit == table || [hit isDescendantOf:table];
    if (!reachesTable) Fail([NSString stringWithFormat:@"Engine row hit test missed the table: %@", hit.class]);
    printf("Engine row hit test reaches %s inside NSTableView; hidden panes do not cover the row.\n", NSStringFromClass(hit.class).UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (argc != 2) Fail(@"Usage: StoreScreenshots OUTPUT_DIRECTORY");
        NSString *output = @(argv[1]);
        NSString *raw = [output stringByAppendingPathComponent:@"native"];
        [[NSFileManager defaultManager] createDirectoryAtPath:raw withIntermediateDirectories:YES attributes:nil error:nil];
        OmnibarSearchSettings *settings = OMMakeTestSettings(NULL, NULL);
        AddressPopoverController *address = [[AddressPopoverController alloc] initWithNibName:nil bundle:nil];
        [address setValue:settings forKey:@"searchSettings"];
        NSWindow *addressWindow = Host(address, NSMakeSize(520, 100));
        ScreenshotSafariWindow *safari = [ScreenshotSafariWindow new];
        safari.tab = [ScreenshotTab new];
        safari.tab.page = [ScreenshotPage new];
        safari.tab.page.url = [NSURL URLWithString:@"https://example.com/notes"];
        [address prepareForWindow:(id)safari];
        Drain();
        NSBitmapImageRep *addressImage = Capture(addressWindow, [raw stringByAppendingPathComponent:@"address-native.png"]);
        if (![[NSFileManager defaultManager] fileExistsAtPath:[output stringByAppendingPathComponent:@"safari-window.png"]]) {
            Compose(addressImage, @"A clearer place to go.", @"View the current address. Open a website. Search the web.",
                [output stringByAppendingPathComponent:@"01-address.png"], YES);
        }

        SearchSettingsController *search = [[SearchSettingsController alloc] initWithSettings:settings];
        NSWindow *settingsWindow = Host(search, NSMakeSize(520, 480));
        VerifyRowHitTesting(search);
        NSBitmapImageRep *enginesImage = Capture(settingsWindow, [raw stringByAppendingPathComponent:@"engines-native.png"]);
        Compose(enginesImage, @"Search\nyour way.", @"Choose your default.\nKeep your favorites close.",
            [output stringByAppendingPathComponent:@"02-search-engines.png"], NO);

        [NSApp sendAction:NSSelectorFromString(@"addEngine:") to:search from:nil];
        ((NSTextField *)[search valueForKey:@"nameField"]).stringValue = @"Example Search";
        ((NSTextField *)[search valueForKey:@"templateField"]).stringValue = @"https://example.com/search?q=%s";
        NSBitmapImageRep *customImage = Capture(settingsWindow, [raw stringByAppendingPathComponent:@"custom-native.png"]);
        Compose(customImage, @"Bring your\nown search.", @"Add a custom search URL\nwith a %s placeholder.",
            [output stringByAppendingPathComponent:@"03-custom-engines.png"], NO);

        [NSApp sendAction:NSSelectorFromString(@"cancelEditor:") to:search from:nil];
        NSSegmentedControl *panes = [search valueForKey:@"paneControl"];
        panes.selectedSegment = 1;
        [NSApp sendAction:NSSelectorFromString(@"changePane:") to:search from:panes];
        Drain();
        NSBitmapImageRep *privateImage = Capture(settingsWindow, [raw stringByAppendingPathComponent:@"kagi-native.png"]);
        Compose(privateImage, @"Kagi, in\nprivate windows.", @"Keep your Kagi session link\nsecurely in Keychain.",
            [output stringByAppendingPathComponent:@"04-kagi-private.png"], NO);
        [search resetSensitiveFields];
        printf("Rendered native UI captures and App Store PNGs, preserving any authentic Safari-window first image.\n");
    }
    return 0;
}
