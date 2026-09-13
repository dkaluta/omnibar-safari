#import <AppKit/AppKit.h>

// Format conversion and aspect-preserving padding of the user-prepared capture.
// No Safari content, controls, or text are generated or changed.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "Usage: NormalizeSafariScreenshot CAPTURE STORE_IMAGE WEBSITE_IMAGE\n");
            return 1;
        }
        NSString *capturePath = @(argv[1]);
        NSData *sourceData = [NSData dataWithContentsOfFile:capturePath];
        NSBitmapImageRep *source = [[NSBitmapImageRep alloc] initWithData:sourceData];
        if (!source) return 2;
        const unsigned char *sourceBytes = sourceData.bytes;
        if (sourceData.length >= 2 && sourceBytes[0] == 0xff && sourceBytes[1] == 0xd8) {
            NSString *original = [[capturePath stringByDeletingPathExtension] stringByAppendingString:@"-original.jpg"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:original] && ![sourceData writeToFile:original atomically:YES]) return 3;
        }
        NSData *normalized = [source representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![normalized writeToFile:capturePath atomically:YES] || ![normalized writeToFile:@(argv[3]) atomically:YES]) return 4;

        NSBitmapImageRep *canvas = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1440 pixelsHigh:900
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:canvas];
        if (!context) return 5;
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];
        [[NSColor colorWithSRGBRed:0.95 green:0.95 blue:0.96 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, 0, 1440, 900));
        CGFloat scale = MIN(1400.0 / source.pixelsWide, 860.0 / source.pixelsHigh);
        NSSize fitted = NSMakeSize(source.pixelsWide * scale, source.pixelsHigh * scale);
        NSRect frame = NSMakeRect((1440 - fitted.width) / 2, (900 - fitted.height) / 2, fitted.width, fitted.height);
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(source.pixelsWide, source.pixelsHigh)];
        [image addRepresentation:source];
        [image drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1
            respectFlipped:NO hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];

        NSBitmapImageRep *opaque = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1440 pixelsHigh:900
            bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        for (NSInteger y = 0; y < 900; y++) {
            const unsigned char *row = canvas.bitmapData + y * canvas.bytesPerRow;
            unsigned char *destination = opaque.bitmapData + y * opaque.bytesPerRow;
            for (NSInteger x = 0; x < 1440; x++) {
                destination[x * 3] = row[x * 4];
                destination[x * 3 + 1] = row[x * 4 + 1];
                destination[x * 3 + 2] = row[x * 4 + 2];
            }
        }
        if (![[opaque representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[2]) atomically:YES]) return 6;
        printf("Preserved original JPEG; normalized two PNGs; exported opaque1440×900 PNG with full window at %.4fx.\n", scale);
    }
    return 0;
}
