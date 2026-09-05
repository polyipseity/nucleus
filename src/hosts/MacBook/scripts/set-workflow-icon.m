/*
 * set-workflow-icon.m — Register a custom Finder icon for a .workflow bundle
 *
 * Calls NSWorkspace.setIcon:forFile:options: which:
 *   1. Registers the image with IconServices (system-level cache keyed by file path)
 *   2. Sets kHasCustomIcon + kHasBundle in the com.apple.FinderInfo xattr
 *
 * Must run AFTER the workflow is at its final path (~/Library/Services/),
 * because IconServices caches icons by exact file path.
 *
 * Compile: clang -fobjc-arc -fmodules -framework AppKit -framework Foundation \
 *          -Wno-deprecated-declarations -o set-workflow-icon set-workflow-icon.m
 * Usage:   set-workflow-icon <image-path> <target-path>
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface NSWorkspace (IconSet)
- (BOOL)setIcon:(NSImage *)image forFile:(NSString *)fullPath options:(NSUInteger)options;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s <image-path> <target-path>\n", argv[0]);
            return 1;
        }
        NSString *imagePath = [NSString stringWithUTF8String:argv[1]];
        NSString *targetPath = [NSString stringWithUTF8String:argv[2]];

        NSImage *image = [[NSImage alloc] initWithContentsOfFile:imagePath];
        if (!image) {
            fprintf(stderr, "Failed to load image: %s\n", argv[1]);
            return 1;
        }

        NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
        BOOL success = [workspace setIcon:image forFile:targetPath options:0];
        if (!success) {
            fprintf(stderr, "setIcon failed for: %s\n", argv[2]);
        }
        return success ? 0 : 1;
    }
}
