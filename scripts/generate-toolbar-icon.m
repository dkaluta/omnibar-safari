#import <AppKit/AppKit.h>

static void DrawToolbarIcon(NSString *path) {
    CGRect bounds = CGRectMake(0, 0, 24, 24);
    CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
    CGContextRef pdf = CGPDFContextCreateWithURL(url, &bounds, NULL);
    CGPDFContextBeginPage(pdf, NULL);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:pdf flipped:NO]];
    [NSColor.blackColor setStroke];
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1, 5, 22, 14) xRadius:4 yRadius:4];
    pill.lineWidth = 1.7;
    [pill stroke];
    NSBezierPath *lens = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(5, 10, 4.5, 4.5)];
    lens.lineWidth = 1.4;
    [lens stroke];
    NSBezierPath *details = [NSBezierPath bezierPath];
    [details moveToPoint:NSMakePoint(9, 10.5)];
    [details lineToPoint:NSMakePoint(10.5, 9)];
    [details moveToPoint:NSMakePoint(14, 12)];
    [details lineToPoint:NSMakePoint(19, 12)];
    details.lineWidth = 1.4;
    details.lineCapStyle = NSLineCapStyleRound;
    [details stroke];
    [NSGraphicsContext restoreGraphicsState];
    CGPDFContextEndPage(pdf);
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: generate-toolbar-icon OUTPUT_DIRECTORY\n");
            return 2;
        }
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:NULL];
        DrawToolbarIcon([directory stringByAppendingPathComponent:@"Toolbar.pdf"]);
    }
    return 0;
}
