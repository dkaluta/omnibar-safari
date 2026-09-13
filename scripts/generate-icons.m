#import <AppKit/AppKit.h>

static NSColor *Color(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

static void DrawIcon(NSInteger size, NSString *path) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext setCurrentContext:context];
    [context setImageInterpolation:NSImageInterpolationHigh];
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:(CGFloat)size / 1024.0];
    [scale concat];

    NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(40, 40, 944, 944)
        xRadius:210 yRadius:210];
    NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:Color(0.12, 0.31, 0.75, 1)
        endingColor:Color(0.27, 0.52, 0.97, 1)];
    [gradient drawInBezierPath:tile angle:90];

    [Color(1, 1, 1, 0.96) setFill];
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(156, 408, 712, 208)
        xRadius:104 yRadius:104];
    [pill fill];

    [Color(0.19, 0.40, 0.81, 1) setStroke];
    NSBezierPath *lens = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(216, 480, 70, 70)];
    [lens setLineWidth:15];
    [lens stroke];
    NSBezierPath *handle = [NSBezierPath bezierPath];
    [handle moveToPoint:NSMakePoint(274, 488)];
    [handle lineToPoint:NSMakePoint(302, 460)];
    [handle setLineWidth:15];
    [handle setLineCapStyle:NSLineCapStyleRound];
    [handle stroke];

    [Color(0.28, 0.46, 0.77, 0.52) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(352, 498, 330, 28)
        xRadius:14 yRadius:14] fill];

    [Color(0.19, 0.40, 0.81, 1) setStroke];
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(738, 512)];
    [arrow lineToPoint:NSMakePoint(800, 512)];
    [arrow moveToPoint:NSMakePoint(778, 538)];
    [arrow lineToPoint:NSMakePoint(804, 512)];
    [arrow lineToPoint:NSMakePoint(778, 486)];
    [arrow setLineWidth:14];
    [arrow setLineCapStyle:NSLineCapStyleRound];
    [arrow setLineJoinStyle:NSLineJoinStyleRound];
    [arrow stroke];
    [NSGraphicsContext restoreGraphicsState];
    NSData *data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![data writeToFile:path atomically:YES]) {
        fprintf(stderr, "Could not write %s\n", path.fileSystemRepresentation);
        exit(1);
    }
}

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
            fprintf(stderr, "Usage: generate-icons OUTPUT_DIRECTORY\n");
            return 2;
        }
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
            withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSNumber *size in @[@16, @32, @48, @64, @96, @128, @256, @512, @1024]) {
            DrawIcon(size.integerValue, [directory stringByAppendingPathComponent:
                [NSString stringWithFormat:@"icon-%@.png", size]]);
        }
        DrawToolbarIcon([directory stringByAppendingPathComponent:@"Toolbar.pdf"]);
    }
    return 0;
}
