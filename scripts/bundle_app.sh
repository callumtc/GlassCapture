#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.cargo/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GlassCapture"
DIST_APP="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="$HOME/Applications/$APP_NAME.app"

echo "==> Building Rust release binary..."
cd "$ROOT"
cargo build --release

echo "==> Assembling $DIST_APP..."
rm -rf "$DIST_APP"
mkdir -p "$DIST_APP/Contents/MacOS" "$DIST_APP/Contents/Resources"

cp "$ROOT/target/release/glass_capture" "$DIST_APP/Contents/MacOS/glass_capture"
cp "$ROOT/resources/Info.plist" "$DIST_APP/Contents/Info.plist"

# Generate crisp Liquid Glass macOS icon (.icns) using native CoreGraphics
ICONSET_DIR="$ROOT/target/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

cat << 'EOF' > "$ROOT/target/gen_icon.m"
#import <AppKit/AppKit.h>

static void renderIcon(NSString *path, CGFloat px) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)px
                      pixelsHigh:(NSInteger)px
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext setCurrentContext:ctx];

    CGFloat pad = px * 0.08;
    NSRect box = NSMakeRect(pad, pad, px - pad * 2, px - pad * 2);
    CGFloat radius = box.size.width * 0.225;
    NSBezierPath *squircle = [NSBezierPath bezierPathWithRoundedRect:box xRadius:radius yRadius:radius];

    // Deep obsidian-indigo gradient backdrop
    NSGradient *bg = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithRed:0.06 green:0.09 blue:0.18 alpha:1.0],
        [NSColor colorWithRed:0.09 green:0.20 blue:0.36 alpha:1.0],
        [NSColor colorWithRed:0.14 green:0.36 blue:0.52 alpha:1.0],
    ]];
    [bg drawInBezierPath:squircle angle:-55.0];

    // Luminous cyan/violet liquid refraction orb
    NSRect glowRect = NSInsetRect(box, box.size.width * 0.16, box.size.height * 0.16);
    NSBezierPath *orb = [NSBezierPath bezierPathWithOvalInRect:glowRect];
    NSGradient *glow = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.36 green:0.86 blue:1.0 alpha:0.62]
                                                     endingColor:[NSColor colorWithRed:0.42 green:0.32 blue:0.95 alpha:0.0]];
    [glow drawInBezierPath:orb relativeCenterPosition:NSMakePoint(-0.18, 0.22)];

    // Frosted Liquid Glass inner lens pill
    NSRect lensRect = NSInsetRect(box, box.size.width * 0.20, box.size.height * 0.25);
    NSBezierPath *lens = [NSBezierPath bezierPathWithRoundedRect:lensRect
                                                         xRadius:lensRect.size.height * 0.32
                                                         yRadius:lensRect.size.height * 0.32];
    NSGradient *glassFill = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:1.0 alpha:0.34],
        [NSColor colorWithWhite:1.0 alpha:0.10],
        [NSColor colorWithRed:0.65 green:0.92 blue:1.0 alpha:0.22],
    ]];
    [glassFill drawInBezierPath:lens angle:-75.0];

    // Specular rim on glass lens
    [[NSColor colorWithWhite:1.0 alpha:0.65] setStroke];
    lens.lineWidth = fmax(1.5, px * 0.012);
    [lens stroke];

    // Crisp capture play/frame-gen chevron inside lens
    CGFloat cx = NSMidX(lensRect);
    CGFloat cy = NSMidY(lensRect);
    CGFloat r = lensRect.size.height * 0.26;
    NSBezierPath *tri = [NSBezierPath bezierPath];
    [tri moveToPoint:NSMakePoint(cx - r * 0.55, cy - r * 0.85)];
    [tri lineToPoint:NSMakePoint(cx + r * 0.95, cy)];
    [tri lineToPoint:NSMakePoint(cx - r * 0.55, cy + r * 0.85)];
    [tri closePath];
    [[NSColor colorWithWhite:1.0 alpha:0.95] setFill];
    [tri fill];

    // Outer specular glass bevel
    [[NSColor colorWithWhite:1.0 alpha:0.28] setStroke];
    squircle.lineWidth = fmax(1.0, px * 0.01);
    [squircle stroke];

    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 1;
        NSString *dir = [NSString stringWithUTF8String:argv[1]];
        int sizes[] = {16, 32, 64, 128, 256, 512};
        for (int i = 0; i < 6; i++) {
            int s = sizes[i];
            renderIcon([dir stringByAppendingFormat:@"/icon_%dx%d.png", s, s], s);
            renderIcon([dir stringByAppendingFormat:@"/icon_%dx%d@2x.png", s, s], s * 2);
        }
    }
    return 0;
}
EOF

clang -fobjc-arc "$ROOT/target/gen_icon.m" -framework AppKit -o "$ROOT/target/gen_icon"
"$ROOT/target/gen_icon" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$DIST_APP/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing $DIST_APP..."
codesign --force --deep --sign - "$DIST_APP"

echo "==> Installing to $INSTALL_APP..."
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL_APP"
cp -R "$DIST_APP" "$INSTALL_APP"

echo ""
echo "Done! Built and installed:"
echo "  $DIST_APP"
echo "  $INSTALL_APP"
echo "Binary size: $(du -h "$DIST_APP/Contents/MacOS/glass_capture" | awk '{print $1}')"
