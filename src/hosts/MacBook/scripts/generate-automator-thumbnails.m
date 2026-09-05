// generate-automator-thumbnails.m — Render SF Symbol to 256×256 PNG via AppKit.
//
// Usage: generate-automator-thumbnails <symbol-name> <output-path>
//
// Compiles with: $CC -fobjc-arc -fmodules -framework AppKit -framework Foundation
//
// WHY Objective-C instead of Swift: pkgs.swift 5.10.1 is incompatible with
// nixpkgs apple-sdk 14.4 — Foundation module references CoreFoundation.CGFloat
// which Nix doesn't export. ObjC + clang from stdenv works correctly.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s <symbol-name> <output-path>\n", argv[0]);
            return 1;
        }

        NSString *symbolName = [NSString stringWithUTF8String:argv[1]];
        NSString *outputPath = [NSString stringWithUTF8String:argv[2]];

        NSImage *image = [NSImage imageWithSystemSymbolName:symbolName
                                  accessibilityDescription:nil];
        if (!image) {
            fprintf(stderr, "Error: Could not create image for '%s'\n",
                    [symbolName UTF8String]);
            return 1;
        }

        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
            configurationWithPointSize:120 weight:NSFontWeightMedium scale:NSImageSymbolScaleMedium];
        NSImage *configuredImage = [image imageWithSymbolConfiguration:config];
        if (!configuredImage) {
            fprintf(stderr, "Error: Could not configure image\n");
            return 1;
        }

        NSSize size = NSMakeSize(256, 256);
        NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:size.width
            pixelsHigh:size.height
            bitsPerSample:8
            samplesPerPixel:4
            hasAlpha:YES
            isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace
            bytesPerRow:0
            bitsPerPixel:0];
        if (!bitmapRep) {
            fprintf(stderr, "Error: Could not create bitmap\n");
            return 1;
        }

        [NSGraphicsContext
            setCurrentContext:[NSGraphicsContext
                graphicsContextWithBitmapImageRep:bitmapRep]];
        [[NSColor whiteColor] set];
        NSRectFill(NSMakeRect(0, 0, size.width, size.height));
        [configuredImage drawInRect:NSMakeRect(0, 0, size.width, size.height)
                           fromRect:NSZeroRect
                          operation:NSCompositingOperationSourceOver
                           fraction:1.0];
        [NSGraphicsContext setCurrentContext:nil];

        NSData *data = [bitmapRep
            representationUsingType:NSBitmapImageFileTypePNG
                         properties:@{}];
        if (!data) {
            fprintf(stderr, "Error: Could not create PNG data\n");
            return 1;
        }

        NSError *error = nil;
        BOOL ok = [data writeToFile:outputPath options:NSDataWritingAtomic error:&error];
        if (!ok) {
            fprintf(stderr, "Error: Could not write to '%s': %s\n",
                    [outputPath UTF8String],
                    [[error localizedDescription] UTF8String]);
            return 1;
        }

        fprintf(stdout, "OK: %s (%lu bytes)\n",
                [outputPath UTF8String], (unsigned long)data.length);
    }
    return 0;
}
