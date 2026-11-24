#import "bridge.h"

#import <AppKit/AppKit.h>
#import <AppKit/NSGlassEffectView.h>
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>
#import <stdatomic.h>

// ============================================================================
// Custom Hover-Interactive Pill Button (macOS 26 Liquid Glass Aesthetic)
// ============================================================================

@interface GcPillButton : NSButton
@property (nonatomic) BOOL isActiveState;
@property (nonatomic, strong, nullable) NSColor *activeTint;
@property (nonatomic) BOOL isHovered;
@property (nonatomic) CGFloat pillCornerRadius;
@end

@implementation GcPillButton

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.bordered = NO;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 15.0;
        self.layer.masksToBounds = YES;
        _pillCornerRadius = 15.0;
        _activeTint = [NSColor controlAccentColor];
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in [self.trackingAreas copy]) {
        [self removeTrackingArea:a];
    }
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _isHovered = YES;
    [self refreshVisuals];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _isHovered = NO;
    [self refreshVisuals];
}

- (void)setIsActiveState:(BOOL)isActiveState {
    _isActiveState = isActiveState;
    [self refreshVisuals];
}

- (void)setActiveTint:(NSColor *)activeTint {
    _activeTint = activeTint;
    [self refreshVisuals];
}

- (void)refreshVisuals {
    self.layer.cornerRadius = self.pillCornerRadius;
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.14];
    if (_isActiveState) {
        NSColor *tint = _activeTint ?: [NSColor controlAccentColor];
        self.layer.backgroundColor = [tint colorWithAlphaComponent:(_isHovered ? 0.36 : 0.26)].CGColor;
        self.contentTintColor = tint;
    } else if (_isHovered) {
        self.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.14].CGColor;
        self.contentTintColor = [NSColor whiteColor];
    } else {
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        self.contentTintColor = [NSColor colorWithWhite:0.92 alpha:0.90];
    }
    [CATransaction commit];
}

@end

// ============================================================================
// Live Audio Level Meter (Sleek Segmented Pill Bar)
// ============================================================================

@interface GcAudioMeterView : NSView
@property (nonatomic) float level; // 0.0 .. 1.0
@property (nonatomic) BOOL muted;
@end

@implementation GcAudioMeterView

- (BOOL)isFlipped { return YES; }

- (void)setLevel:(float)level {
    float clamped = fmaxf(0.0f, fminf(1.0f, level));
    if (fabsf(clamped - _level) > 0.008f) {
        _level = clamped;
        [self setNeedsDisplay:YES];
    }
}

- (void)setMuted:(BOOL)muted {
    if (_muted != muted) {
        _muted = muted;
        [self setNeedsDisplay:YES];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    const int segs = 10;
    CGFloat gap = 2.0;
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat segW = (w - gap * (segs - 1)) / (CGFloat)segs;
    CGFloat barH = fmin(6.0, h);
    CGFloat y = (h - barH) * 0.5;

    for (int i = 0; i < segs; i++) {
        CGFloat x = i * (segW + gap);
        float thresh = (float)(i + 1) / (float)segs;
        BOOL lit = (!_muted) && (_level >= thresh - 0.05f);

        NSColor *c;
        if (!lit) {
            c = [NSColor colorWithWhite:1.0 alpha:0.14];
        } else if (i >= 8) {
            c = [NSColor systemRedColor];
        } else if (i >= 6) {
            c = [NSColor systemOrangeColor];
        } else {
            c = [NSColor colorWithRed:0.25 green:0.88 blue:0.58 alpha:0.95];
        }
        [c setFill];
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, y, segW, barH) xRadius:1.5 yRadius:1.5];
        [p fill];
    }
}

@end

// ============================================================================
// Live Pipeline Latency Sparkline View (for Floating Glass HUD)
// ============================================================================

#define GC_SPARK_SAMPLES 36

@interface GcSparklineView : NSView {
    double _samples[GC_SPARK_SAMPLES];
    int _head;
    int _count;
}
- (void)pushSample:(double)ms;
@end

@implementation GcSparklineView

- (void)pushSample:(double)ms {
    _samples[_head] = fmax(0.0, fmin(80.0, ms));
    _head = (_head + 1) % GC_SPARK_SAMPLES;
    if (_count < GC_SPARK_SAMPLES) _count++;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (_count < 2) return;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    double maxVal = 16.0;
    for (int i = 0; i < _count; i++) {
        int idx = (_head - _count + i + GC_SPARK_SAMPLES) % GC_SPARK_SAMPLES;
        if (_samples[idx] > maxVal) maxVal = _samples[idx];
    }
    maxVal = fmax(16.0, maxVal * 1.15);

    NSBezierPath *line = [NSBezierPath bezierPath];
    NSBezierPath *fill = [NSBezierPath bezierPath];

    CGFloat stepX = w / (CGFloat)(GC_SPARK_SAMPLES - 1);
    CGFloat startX = w - stepX * (CGFloat)(_count - 1);

    for (int i = 0; i < _count; i++) {
        int idx = (_head - _count + i + GC_SPARK_SAMPLES) % GC_SPARK_SAMPLES;
        CGFloat x = startX + (CGFloat)i * stepX;
        CGFloat norm = (CGFloat)(_samples[idx] / maxVal);
        CGFloat y = 2.0 + norm * (h - 4.0);
        NSPoint pt = NSMakePoint(x, y);
        if (i == 0) {
            [line moveToPoint:pt];
            [fill moveToPoint:NSMakePoint(x, 0)];
            [fill lineToPoint:pt];
        } else {
            [line lineToPoint:pt];
            [fill lineToPoint:pt];
        }
        if (i == _count - 1) {
            [fill lineToPoint:NSMakePoint(x, 0)];
            [fill closePath];
        }
    }

    NSGradient *grad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.35 green:0.80 blue:1.0 alpha:0.28]
                                                     endingColor:[NSColor colorWithRed:0.35 green:0.80 blue:1.0 alpha:0.0]];
    [grad drawInBezierPath:fill angle:-90.0];

    [[NSColor colorWithRed:0.45 green:0.86 blue:1.0 alpha:0.92] setStroke];
    line.lineWidth = 1.4;
    line.lineCapStyle = NSLineCapStyleRound;
    line.lineJoinStyle = NSLineJoinStyleRound;
    [line stroke];
}

@end

// ============================================================================
// Live Glowing Status Dot View
// ============================================================================

@interface GcStatusDotView : NSView
@property (nonatomic, strong) NSColor *dotColor;
@end

@implementation GcStatusDotView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _dotColor = [NSColor systemGreenColor];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.widthAnchor constraintEqualToConstant:8].active = YES;
        [self.heightAnchor constraintEqualToConstant:8].active = YES;
    }
    return self;
}

- (void)setDotColor:(NSColor *)dotColor {
    _dotColor = dotColor;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    [_dotColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:r] fill];
}

@end

// ============================================================================
// Metal Canvas Host View
// ============================================================================

@interface GcMetalHostView : NSView
@property (nonatomic, strong, readonly) CAMetalLayer *metalLayer;
@property (nonatomic, copy, nullable) void (^onMouseActivity)(NSPoint pt);
@property (nonatomic, copy, nullable) void (^onDoubleClick)(void);
@property (nonatomic, copy, nullable) BOOL (^onKeyDown)(NSEvent *event);
@end

@implementation GcMetalHostView

+ (Class)layerClass { return [CAMetalLayer class]; }

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        CAMetalLayer *ml = [CAMetalLayer layer];
        ml.contentsScale = NSScreen.mainScreen.backingScaleFactor ?: 2.0;
        ml.backgroundColor = CGColorCreateGenericRGB(0.02, 0.02, 0.03, 1.0);
        self.layer = ml;
        _metalLayer = ml;
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)updateDrawableSize {
    CGFloat scale = self.window.backingScaleFactor ?: (NSScreen.mainScreen.backingScaleFactor ?: 2.0);
    self.metalLayer.contentsScale = scale;
    CGSize px = CGSizeMake(
        fmax(2.0, round(self.bounds.size.width * scale)),
        fmax(2.0, round(self.bounds.size.height * scale))
    );
    if (!CGSizeEqualToSize(self.metalLayer.drawableSize, px)) {
        self.metalLayer.drawableSize = px;
    }
}

- (void)setFrameSize:(NSSize)newSize { [super setFrameSize:newSize]; [self updateDrawableSize]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self updateDrawableSize]; [self updateTrackingAreas]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self updateDrawableSize]; }

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self.trackingAreas copy]) {
        [self removeTrackingArea:area];
    }
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

- (void)mouseMoved:(NSEvent *)event {
    if (self.onMouseActivity) self.onMouseActivity([self convertPoint:event.locationInWindow fromView:nil]);
}
- (void)mouseEntered:(NSEvent *)event {
    if (self.onMouseActivity) self.onMouseActivity([self convertPoint:event.locationInWindow fromView:nil]);
}
- (void)mouseDown:(NSEvent *)event {
    if (self.onMouseActivity) self.onMouseActivity([self convertPoint:event.locationInWindow fromView:nil]);
    if (event.clickCount == 2 && self.onDoubleClick) {
        self.onDoubleClick();
    } else {
        [super mouseDown:event];
    }
}
- (void)keyDown:(NSEvent *)event {
    if (self.onKeyDown && self.onKeyDown(event)) return;
    [super keyDown:event];
}

@end

// ============================================================================
// UI Factory Helpers
// ============================================================================

static NSImage *sfSymbol(NSString *name, CGFloat ptSize, NSFontWeight weight) {
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:ptSize weight:weight];
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
    return [img imageWithSymbolConfiguration:cfg];
}

static NSGlassEffectView *makeGlassPill(CGFloat cornerRadius, BOOL interactive) {
    NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    g.translatesAutoresizingMaskIntoConstraints = NO;
    g.cornerRadius = cornerRadius;
    g.style = NSGlassEffectViewStyleRegular;
    if (@available(macOS 27.0, *)) {
        g.effectIsInteractive = interactive;
    }
    return g;
}

static GcPillButton *makePillIconBtn(NSString *symbol, CGFloat iconPt, CGFloat size, NSString *tooltip, id target, SEL action) {
    GcPillButton *btn = [[GcPillButton alloc] initWithFrame:NSZeroRect];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.image = sfSymbol(symbol, iconPt, NSFontWeightMedium);
    btn.imagePosition = NSImageOnly;
    btn.target = target;
    btn.action = action;
    btn.toolTip = tooltip;
    btn.pillCornerRadius = size * 0.5;
    [btn.widthAnchor constraintEqualToConstant:size].active = YES;
    [btn.heightAnchor constraintEqualToConstant:size].active = YES;
    [btn refreshVisuals];
    return btn;
}

static NSPopUpButton *makeBorderlessPopup(CGFloat minW, CGFloat maxW, id target, SEL action) {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    p.translatesAutoresizingMaskIntoConstraints = NO;
    p.bordered = NO;
    p.controlSize = NSControlSizeRegular;
    p.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    p.contentTintColor = [NSColor colorWithWhite:0.96 alpha:0.95];
    p.target = target;
    p.action = action;
    [p.widthAnchor constraintGreaterThanOrEqualToConstant:minW].active = YES;
    [p.widthAnchor constraintLessThanOrEqualToConstant:maxW].active = YES;
    [p.heightAnchor constraintEqualToConstant:26].active = YES;
    return p;
}

static NSView *makeHairlineDivider(CGFloat height) {
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.wantsLayer = YES;
    v.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.16].CGColor;
    [v.widthAnchor constraintEqualToConstant:1.0].active = YES;
    [v.heightAnchor constraintEqualToConstant:height].active = YES;
    return v;
}

static NSTextField *makeLabel(NSString *text, CGFloat size, NSFontWeight weight, BOOL mono, NSColor *color) {
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = mono
        ? [NSFont monospacedDigitSystemFontOfSize:size weight:weight]
        : [NSFont systemFontOfSize:size weight:weight];
    lbl.textColor = color;
    lbl.lineBreakMode = NSLineBreakByTruncatingTail;
    return lbl;
}

static NSView *makeBadgeChip(NSTextField *label, NSColor *tint) {
    NSView *chip = [[NSView alloc] initWithFrame:NSZeroRect];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.wantsLayer = YES;
    chip.layer.cornerRadius = 6.0;
    chip.layer.backgroundColor = [tint colorWithAlphaComponent:0.22].CGColor;
    chip.layer.borderColor = [tint colorWithAlphaComponent:0.42].CGColor;
    chip.layer.borderWidth = 0.6;
    [chip addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-6],
        [label.topAnchor constraintEqualToAnchor:chip.topAnchor constant:2],
        [label.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-2],
    ]];
    return chip;
}

// ============================================================================
// Main App Controller
// ============================================================================

@interface GcAppController : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic) GcCallbacks callbacks;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) GcMetalHostView *metalView;
@property (nonatomic, strong) NSView *shutterFlashView;
@property (nonatomic, strong) NSGlassEffectContainerView *glassContainer;

// Floating Liquid Glass Surfaces
@property (nonatomic, strong) NSGlassEffectView *topSourceGlass;
@property (nonatomic, strong) NSGlassEffectView *topUtilGlass;
@property (nonatomic, strong) NSGlassEffectView *hudGlass;
@property (nonatomic, strong) NSGlassEffectView *bottomDockGlass;
@property (nonatomic, strong) NSGlassEffectView *inspectorGlass;
@property (nonatomic, strong) NSGlassEffectView *noSignalGlass;
@property (nonatomic, strong) NSGlassEffectView *toastGlass;

// Top Source & Utility Controls
@property (nonatomic, strong) GcStatusDotView *sourceDot;
@property (nonatomic, strong) NSPopUpButton *videoDevicePopup;
@property (nonatomic, strong) NSPopUpButton *videoFormatPopup;
@property (nonatomic, strong) GcPillButton *hdrTopBadgeBtn;
@property (nonatomic, strong) GcPillButton *refreshBtn;
@property (nonatomic, strong) GcPillButton *cleanViewBtn;
@property (nonatomic, strong) GcPillButton *overlayBtn;
@property (nonatomic, strong) GcPillButton *hudBtn;
@property (nonatomic, strong) GcPillButton *pinBtn;
@property (nonatomic, strong) GcPillButton *fullscreenBtn;

// Bottom Dock Controls
@property (nonatomic, strong) NSSegmentedControl *frameGenSeg;
@property (nonatomic, strong) NSPopUpButton *upscalePopup;
@property (nonatomic, strong) GcPillButton *pauseBtn;
@property (nonatomic, strong) GcPillButton *shotBtn;
@property (nonatomic, strong) GcPillButton *recBtn;
@property (nonatomic, strong) GcPillButton *muteBtn;
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, strong) GcAudioMeterView *audioMeter;
@property (nonatomic, strong) GcPillButton *inspectorBtn;

// Tuning Inspector Controls (3-Tab Glass Inspector)
@property (nonatomic, strong) NSSegmentedControl *inspectorTabSeg;
@property (nonatomic, strong) NSView *tabDisplayView;
@property (nonatomic, strong) NSView *tabColorView;
@property (nonatomic, strong) NSView *tabAudioView;
@property (nonatomic, strong) NSSlider *sharpnessSlider;
@property (nonatomic, strong) NSTextField *sharpnessValueLabel;
@property (nonatomic, strong) NSSegmentedControl *aspectSeg;
@property (nonatomic, strong) NSSlider *overscanSlider;
@property (nonatomic, strong) NSTextField *overscanValueLabel;
@property (nonatomic, strong) NSSwitch *intLockSwitch;
@property (nonatomic, strong) NSSwitch *hdrSwitch;
@property (nonatomic, strong) NSTextField *hdrHintLabel;

// Color & A/B Tab Controls
@property (nonatomic, strong) NSSegmentedControl *colorRangeSeg;
@property (nonatomic, strong) NSSlider *contrastSlider;
@property (nonatomic, strong) NSTextField *contrastValLabel;
@property (nonatomic, strong) NSSlider *saturationSlider;
@property (nonatomic, strong) NSTextField *saturationValLabel;
@property (nonatomic, strong) NSSlider *gammaSlider;
@property (nonatomic, strong) NSTextField *gammaValLabel;
@property (nonatomic, strong) NSSwitch *abSplitSwitch;
@property (nonatomic, strong) NSSlider *abSplitSlider;

// Audio & Overlay Tab Controls
@property (nonatomic, strong) NSPopUpButton *audioDevicePopup;
@property (nonatomic, strong) NSSegmentedControl *glassStyleSeg;
@property (nonatomic, strong) NSSegmentedControl *overlayStyleSeg;
@property (nonatomic, strong) NSSwitch *sceneGuardSwitch;

// Performance HUD Controls
@property (nonatomic, strong) GcStatusDotView *hudDot;
@property (nonatomic, strong) NSTextField *hudFpsBigLabel;
@property (nonatomic, strong) NSTextField *hudResLabel;
@property (nonatomic, strong) NSTextField *hudFgChipLabel;
@property (nonatomic, strong) NSView *hudFgChip;
@property (nonatomic, strong) NSTextField *hudUpChipLabel;
@property (nonatomic, strong) NSView *hudUpChip;
@property (nonatomic, strong) NSTextField *hudHdrChipLabel;
@property (nonatomic, strong) NSView *hudHdrChip;
@property (nonatomic, strong) NSTextField *hudTimingLabel;
@property (nonatomic, strong) NSTextField *hudRecBadge;
@property (nonatomic, strong) GcSparklineView *sparkline;
@property (nonatomic, strong) NSTextField *toastLabel;

// Device UID Caches
@property (nonatomic, strong) NSMutableArray<NSString *> *videoDeviceUids;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *videoFormatIndices;
@property (nonatomic, strong) NSMutableArray<NSString *> *audioDeviceUids;

// UI State & Timers
@property (nonatomic, strong, nullable) NSTimer *hideTimer;
@property (nonatomic, strong, nullable) NSTimer *toastTimer;
@property (nonatomic, strong, nullable) NSTimer *overlayTrackTimer;
@property (nonatomic, strong, nullable) NSStatusItem *statusItem;
@property (nonatomic, strong, nullable) NSMenuItem *statusOverlayItem;
@property (nonatomic) BOOL chromeVisible;
@property (nonatomic) BOOL inspectorOpen;
@property (nonatomic) BOOL isFullScreen;
@property (nonatomic) BOOL cleanViewActive;
@property (nonatomic) int32_t activeOverlayMode;
@property (nonatomic) uint32_t overlayTargetWinId;
@property (nonatomic) int32_t overlayTargetPid;
@property (nonatomic) int overlayMissingTicks;
@property (nonatomic) NSRect savedNormalFrame;
@property (nonatomic) BOOL hasSavedNormalFrame;
@property (nonatomic) GcUiStateSnapshot currentState;
@property (nonatomic) BOOL suppressCallbacks;
@property (nonatomic) _Atomic bool windowVisible;
@property (nonatomic) _Atomic float screenEdrHeadroom;
- (void)onToggleOverlay:(nullable id)sender;
- (void)menuCycleFrameGen:(nullable id)sender;
- (void)onToggleHud:(nullable id)sender;
- (void)refreshScreenEdrHeadroom;
@end

static OSStatus gcGlobalHotKeyHandler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {
    (void)nextHandler;
    EventHotKeyID hkID;
    GetEventParameter(theEvent, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hkID), NULL, &hkID);
    GcAppController *ctrl = (__bridge GcAppController *)userData;
    if (!ctrl) return noErr;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hkID.id == 1) {
            [ctrl onToggleOverlay:nil];
        } else if (hkID.id == 2) {
            [ctrl menuCycleFrameGen:nil];
        } else if (hkID.id == 3) {
            [ctrl onToggleHud:nil];
        }
    });
    return noErr;
}

@implementation GcAppController

- (instancetype)initWithCallbacks:(GcCallbacks)cbs {
    self = [super init];
    if (self) {
        _callbacks = cbs;
        _videoDeviceUids = [NSMutableArray array];
        _videoFormatIndices = [NSMutableArray array];
        _audioDeviceUids = [NSMutableArray array];
        _chromeVisible = YES;
        _inspectorOpen = NO;
        atomic_store(&_windowVisible, true);
        atomic_store(&_screenEdrHeadroom, 1.0f);
        [self buildApplicationAndWindow];
        [self refreshScreenEdrHeadroom];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onScreenParamsChanged:)
                                                     name:NSApplicationDidChangeScreenParametersNotification
                                                   object:nil];
    }
    return self;
}

- (void)refreshScreenEdrHeadroom {
    NSScreen *scr = self.window.screen ?: NSScreen.mainScreen;
    float hr = scr ? (float)scr.maximumExtendedDynamicRangeColorComponentValue : 1.0f;
    if (hr < 1.0f) hr = 1.0f;
    atomic_store_explicit(&_screenEdrHeadroom, hr, memory_order_relaxed);
}

- (void)onScreenParamsChanged:(NSNotification *)note {
    (void)note;
    [self refreshScreenEdrHeadroom];
}

- (void)setTrafficLightsVisible:(BOOL)visible {
    NSWindowButton btns[3] = { NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton };
    for (int i = 0; i < 3; i++) {
        NSButton *b = [self.window standardWindowButton:btns[i]];
        if (b) {
            b.animator.alphaValue = visible ? 1.0 : 0.0;
        }
    }
}

- (void)emitAction:(GcUiAction)action intArg:(int32_t)i floatArg:(float)f strArg:(nullable NSString *)s {
    if (self.suppressCallbacks) return;
    if (self.callbacks.on_ui_action) {
        self.callbacks.on_ui_action(self.callbacks.ctx, (int32_t)action, i, f, s ? s.UTF8String : "");
    }
}

- (void)buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"GlassCapture"];
    [appMenu addItemWithTitle:@"About GlassCapture" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *tuneItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Tuning Inspector" action:@selector(onToggleInspector:) keyEquivalent:@"i"];
    tuneItem.target = self;
    [appMenu addItem:tuneItem];
    NSMenuItem *glassToggle = [[NSMenuItem alloc] initWithTitle:@"Toggle Clear / Regular Liquid Glass" action:@selector(menuToggleGlassStyle:) keyEquivalent:@","];
    glassToggle.target = self;
    [appMenu addItem:glassToggle];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit GlassCapture" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"Capture & Hardware"];

    NSMenuItem *fgItem = [[NSMenuItem alloc] initWithTitle:@"Cycle Neural Frame Generation" action:@selector(menuCycleFrameGen:) keyEquivalent:@"g"];
    fgItem.keyEquivalentModifierMask = 0; fgItem.target = self;
    [viewMenu addItem:fgItem];

    NSMenuItem *upItem = [[NSMenuItem alloc] initWithTitle:@"Cycle Upscaler" action:@selector(menuCycleUpscale:) keyEquivalent:@"u"];
    upItem.keyEquivalentModifierMask = 0; upItem.target = self;
    [viewMenu addItem:upItem];

    [viewMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hudItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Performance HUD" action:@selector(onToggleHud:) keyEquivalent:@"h"];
    hudItem.keyEquivalentModifierMask = 0; hudItem.target = self;
    [viewMenu addItem:hudItem];

    NSMenuItem *cleanItem = [[NSMenuItem alloc] initWithTitle:@"Clean View (Hide All UI & HUD)" action:@selector(onToggleCleanView:) keyEquivalent:@"c"];
    cleanItem.keyEquivalentModifierMask = 0; cleanItem.target = self;
    [viewMenu addItem:cleanItem];

    NSMenuItem *hdrItem = [[NSMenuItem alloc] initWithTitle:@"Toggle HDR / EDR Passthrough" action:@selector(onToggleHdr:) keyEquivalent:@"d"];
    hdrItem.keyEquivalentModifierMask = 0; hdrItem.target = self;
    [viewMenu addItem:hdrItem];

    NSMenuItem *pinItem = [[NSMenuItem alloc] initWithTitle:@"Always on Top (PiP)" action:@selector(onTogglePin:) keyEquivalent:@"t"];
    pinItem.keyEquivalentModifierMask = 0; pinItem.target = self;
    [viewMenu addItem:pinItem];

    NSMenuItem *fsItem = [[NSMenuItem alloc] initWithTitle:@"Toggle Full Screen" action:@selector(onToggleFullscreen:) keyEquivalent:@"f"];
    fsItem.keyEquivalentModifierMask = 0; fsItem.target = self;
    [viewMenu addItem:fsItem];

    [viewMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *shotItem = [[NSMenuItem alloc] initWithTitle:@"Save Screenshot (PNG)" action:@selector(onScreenshot:) keyEquivalent:@"s"];
    shotItem.keyEquivalentModifierMask = 0; shotItem.target = self;
    [viewMenu addItem:shotItem];

    NSMenuItem *recItem = [[NSMenuItem alloc] initWithTitle:@"Start / Stop HEVC Recording" action:@selector(onToggleRecord:) keyEquivalent:@"r"];
    recItem.keyEquivalentModifierMask = 0; recItem.target = self;
    [viewMenu addItem:recItem];

    viewItem.submenu = viewMenu;
    [NSApp setMainMenu:mainMenu];
}

- (void)buildApplicationAndWindow {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp setDelegate:self];
    [self buildMenuBar];

    NSRect frame = NSMakeRect(0, 0, 1280, 760);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable
                            | NSWindowStyleMaskFullSizeContentView;

    _window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"GlassCapture";
    _window.titleVisibility = NSWindowTitleHidden;
    _window.titlebarAppearsTransparent = YES;
    _window.movableByWindowBackground = YES;
    _window.backgroundColor = [NSColor colorWithRed:0.02 green:0.02 blue:0.03 alpha:1.0];
    _window.minSize = NSMakeSize(680, 400);
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _window.delegate = self;
    [_window center];

    NSView *root = [[NSView alloc] initWithFrame:frame];
    root.wantsLayer = YES;
    _window.contentView = root;

    // 1. Edge-to-edge Metal video canvas
    _metalView = [[GcMetalHostView alloc] initWithFrame:frame];
    _metalView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_metalView];
    [NSLayoutConstraint activateConstraints:@[
        [_metalView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_metalView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_metalView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_metalView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    __weak typeof(self) weakSelf = self;
    _metalView.onMouseActivity = ^(NSPoint pt) {
        (void)pt;
        [weakSelf revealChromeAndScheduleAutoHide];
    };
    _metalView.onDoubleClick = ^{
        [weakSelf emitAction:GC_ACTION_TOGGLE_FULLSCREEN intArg:0 floatArg:0 strArg:nil];
    };
    _metalView.onKeyDown = ^BOOL(NSEvent *ev) {
        return [weakSelf handleKeyEvent:ev];
    };

    // 2. Subtle camera shutter flash layer (normally alpha 0)
    _shutterFlashView = [[NSView alloc] initWithFrame:frame];
    _shutterFlashView.translatesAutoresizingMaskIntoConstraints = NO;
    _shutterFlashView.wantsLayer = YES;
    _shutterFlashView.layer.backgroundColor = [NSColor whiteColor].CGColor;
    _shutterFlashView.alphaValue = 0.0;
    [root addSubview:_shutterFlashView];
    [NSLayoutConstraint activateConstraints:@[
        [_shutterFlashView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_shutterFlashView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_shutterFlashView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_shutterFlashView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    // 3. Liquid Glass Container View hosting all sculpted floating capsules
    _glassContainer = [[NSGlassEffectContainerView alloc] initWithFrame:frame];
    _glassContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _glassContainer.spacing = 10.0;
    [root addSubview:_glassContainer];
    [NSLayoutConstraint activateConstraints:@[
        [_glassContainer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_glassContainer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_glassContainer.topAnchor constraintEqualToAnchor:root.topAnchor],
        [_glassContainer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    NSView *overlayCanvas = [[NSView alloc] initWithFrame:frame];
    overlayCanvas.translatesAutoresizingMaskIntoConstraints = NO;
    _glassContainer.contentView = overlayCanvas;
    [NSLayoutConstraint activateConstraints:@[
        [overlayCanvas.leadingAnchor constraintEqualToAnchor:_glassContainer.leadingAnchor],
        [overlayCanvas.trailingAnchor constraintEqualToAnchor:_glassContainer.trailingAnchor],
        [overlayCanvas.topAnchor constraintEqualToAnchor:_glassContainer.topAnchor],
        [overlayCanvas.bottomAnchor constraintEqualToAnchor:_glassContainer.bottomAnchor],
    ]];

    [self buildTopSourcePillIn:overlayCanvas];
    [self buildTopUtilityPillIn:overlayCanvas];
    [self buildPerformanceHudIn:overlayCanvas];
    [self buildBottomDockIn:overlayCanvas];
    [self buildInspectorCardIn:overlayCanvas];
    [self buildNoSignalCardIn:overlayCanvas];
    [self buildToastIn:overlayCanvas];
    [self buildStatusBarMenu];
    [self registerGlobalHotKeys];

    [self revealChromeAndScheduleAutoHide];
}

- (void)buildStatusBarMenu {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.button.image = sfSymbol(@"sparkles.tv", 14.0, NSFontWeightMedium);
    _statusItem.button.toolTip = @"GlassCapture — Hardware Frame Gen & Upscaling";

    NSMenu *menu = [[NSMenu alloc] init];
    _statusOverlayItem = [[NSMenuItem alloc] initWithTitle:@"Enter Game Overlay (⌘⇧O)" action:@selector(onToggleOverlay:) keyEquivalent:@""];
    _statusOverlayItem.target = self;
    [menu addItem:_statusOverlayItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *fg = [[NSMenuItem alloc] initWithTitle:@"Cycle Frame Gen (⌘⇧G)" action:@selector(menuCycleFrameGen:) keyEquivalent:@""];
    fg.target = self;
    [menu addItem:fg];

    NSMenuItem *up = [[NSMenuItem alloc] initWithTitle:@"Cycle Upscaler" action:@selector(menuCycleUpscale:) keyEquivalent:@""];
    up.target = self;
    [menu addItem:up];

    NSMenuItem *hud = [[NSMenuItem alloc] initWithTitle:@"Toggle Performance HUD (⌘⇧H)" action:@selector(onToggleHud:) keyEquivalent:@""];
    hud.target = self;
    [menu addItem:hud];

    NSMenuItem *clean = [[NSMenuItem alloc] initWithTitle:@"Hide / Show All UI (C)" action:@selector(onToggleCleanView:) keyEquivalent:@""];
    clean.target = self;
    [menu addItem:clean];

    NSMenuItem *hdr = [[NSMenuItem alloc] initWithTitle:@"Toggle HDR Passthrough (D)" action:@selector(onToggleHdr:) keyEquivalent:@""];
    hdr.target = self;
    [menu addItem:hdr];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *ref = [[NSMenuItem alloc] initWithTitle:@"Refresh Windows & Capture Cards" action:@selector(onRefreshDevices:) keyEquivalent:@""];
    ref.target = self;
    [menu addItem:ref];

    NSMenuItem *show = [[NSMenuItem alloc] initWithTitle:@"Show GlassCapture Window" action:@selector(onBringToFront:) keyEquivalent:@""];
    show.target = self;
    [menu addItem:show];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit GlassCapture" action:@selector(terminate:) keyEquivalent:@""];
    [menu addItem:quit];

    _statusItem.menu = menu;
}

- (void)registerGlobalHotKeys {
    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind = kEventHotKeyPressed;
    InstallApplicationEventHandler(&gcGlobalHotKeyHandler, 1, &eventType, (__bridge void *)self, NULL);

    EventHotKeyRef hkRef = NULL;
    EventHotKeyID hk1 = { 'GCHK', 1 }; // Cmd+Shift+O -> Toggle Overlay
    RegisterEventHotKey(kVK_ANSI_O, cmdKey | shiftKey, hk1, GetApplicationEventTarget(), 0, &hkRef);

    EventHotKeyID hk2 = { 'GCHK', 2 }; // Cmd+Shift+G -> Cycle Frame Gen
    RegisterEventHotKey(kVK_ANSI_G, cmdKey | shiftKey, hk2, GetApplicationEventTarget(), 0, &hkRef);

    EventHotKeyID hk3 = { 'GCHK', 3 }; // Cmd+Shift+H -> Toggle HUD
    RegisterEventHotKey(kVK_ANSI_H, cmdKey | shiftKey, hk3, GetApplicationEventTarget(), 0, &hkRef);
}

- (void)onBringToFront:(id)sender {
    (void)sender;
    if (self.activeOverlayMode != GC_OVERLAY_OFF) {
        [self emitAction:GC_ACTION_TOGGLE_OVERLAY intArg:0 floatArg:0 strArg:nil];
    }
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// ============================================================================
// Top-Center Sculpted Source Capsule
// ============================================================================

- (void)buildTopSourcePillIn:(NSView *)parent {
    _topSourceGlass = makeGlassPill(19.0, YES);
    [parent addSubview:_topSourceGlass];

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8.0;
    row.edgeInsets = NSEdgeInsetsMake(5, 13, 5, 8);
    row.translatesAutoresizingMaskIntoConstraints = NO;

    _sourceDot = [[GcStatusDotView alloc] initWithFrame:NSZeroRect];
    _sourceDot.dotColor = [NSColor colorWithRed:0.32 green:0.86 blue:0.98 alpha:1.0];
    [row addArrangedSubview:_sourceDot];

    _videoDevicePopup = makeBorderlessPopup(140, 240, self, @selector(onVideoDeviceChanged:));
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onVideoPopupWillOpen:)
                                                 name:NSPopUpButtonWillPopUpNotification
                                               object:_videoDevicePopup];
    [row addArrangedSubview:_videoDevicePopup];

    [row addArrangedSubview:makeHairlineDivider(16.0)];

    _videoFormatPopup = makeBorderlessPopup(108, 150, self, @selector(onVideoFormatChanged:));
    _videoFormatPopup.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    [row addArrangedSubview:_videoFormatPopup];

    // Luminous HDR Tag Badge (clickable toggle right on the top capsule!)
    _hdrTopBadgeBtn = [[GcPillButton alloc] initWithFrame:NSZeroRect];
    _hdrTopBadgeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    _hdrTopBadgeBtn.title = @"HDR";
    _hdrTopBadgeBtn.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightHeavy];
    _hdrTopBadgeBtn.pillCornerRadius = 7.0;
    _hdrTopBadgeBtn.activeTint = [NSColor colorWithRed:1.0 green:0.74 blue:0.20 alpha:1.0];
    _hdrTopBadgeBtn.target = self;
    _hdrTopBadgeBtn.action = @selector(onToggleHdr:);
    _hdrTopBadgeBtn.toolTip = @"Toggle HDR / EDR Passthrough (D)";
    [_hdrTopBadgeBtn.widthAnchor constraintGreaterThanOrEqualToConstant:38].active = YES;
    [_hdrTopBadgeBtn.heightAnchor constraintEqualToConstant:21].active = YES;
    _hdrTopBadgeBtn.layer.borderWidth = 0.8;
    _hdrTopBadgeBtn.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.20].CGColor;
    [_hdrTopBadgeBtn refreshVisuals];
    [row addArrangedSubview:_hdrTopBadgeBtn];

    _refreshBtn = makePillIconBtn(@"arrow.clockwise", 12.5, 28.0, @"Refresh Capture Devices", self, @selector(onRefreshDevices:));
    [row addArrangedSubview:_refreshBtn];

    _topSourceGlass.contentView = row;

    [NSLayoutConstraint activateConstraints:@[
        [_topSourceGlass.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
        [_topSourceGlass.topAnchor constraintEqualToAnchor:parent.topAnchor constant:12],
    ]];
}

// ============================================================================
// Top-Right Sculpted Window Utility Capsule
// ============================================================================

- (void)buildTopUtilityPillIn:(NSView *)parent {
    _topUtilGlass = makeGlassPill(19.0, YES);
    [parent addSubview:_topUtilGlass];

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 4.0;
    row.edgeInsets = NSEdgeInsetsMake(4, 6, 4, 6);
    row.translatesAutoresizingMaskIntoConstraints = NO;

    _cleanViewBtn = makePillIconBtn(@"eye.slash", 12.5, 30.0, @"Clean View — Hide All UI & HUD (C)", self, @selector(onToggleCleanView:));
    _overlayBtn = makePillIconBtn(@"rectangle.on.rectangle.angled", 13.0, 30.0, @"Overlay on Top of Game/App (O or ⌘⇧O)", self, @selector(onToggleOverlay:));
    _overlayBtn.activeTint = [NSColor colorWithRed:0.35 green:0.86 blue:1.0 alpha:1.0];
    _hudBtn = makePillIconBtn(@"gauge.with.dots.needle.67percent", 13.5, 30.0, @"Performance HUD (H)", self, @selector(onToggleHud:));
    _pinBtn = makePillIconBtn(@"pin", 13.0, 30.0, @"Always on Top / PiP (T)", self, @selector(onTogglePin:));
    _fullscreenBtn = makePillIconBtn(@"arrow.up.left.and.arrow.down.right", 12.5, 30.0, @"Full Screen (F)", self, @selector(onToggleFullscreen:));

    [row addArrangedSubview:_cleanViewBtn];
    [row addArrangedSubview:_overlayBtn];
    [row addArrangedSubview:_hudBtn];
    [row addArrangedSubview:_pinBtn];
    [row addArrangedSubview:_fullscreenBtn];

    _topUtilGlass.contentView = row;

    [NSLayoutConstraint activateConstraints:@[
        [_topUtilGlass.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-14],
        [_topUtilGlass.topAnchor constraintEqualToAnchor:parent.topAnchor constant:12],
    ]];
}

// ============================================================================
// Top-Left Floating Telemetry Card (Big FPS + Hardware Chips + Live Sparkline)
// ============================================================================

- (void)buildPerformanceHudIn:(NSView *)parent {
    _hudGlass = makeGlassPill(16.0, NO);
    [parent addSubview:_hudGlass];

    NSStackView *col = [[NSStackView alloc] init];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeLeading;
    col.spacing = 5.0;
    col.edgeInsets = NSEdgeInsetsMake(10, 13, 10, 13);
    col.translatesAutoresizingMaskIntoConstraints = NO;

    // Row 1: Dot + Hero FPS + REC badge
    NSStackView *headerRow = [[NSStackView alloc] init];
    headerRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headerRow.alignment = NSLayoutAttributeCenterY;
    headerRow.spacing = 7.0;

    _hudDot = [[GcStatusDotView alloc] initWithFrame:NSZeroRect];
    [headerRow addArrangedSubview:_hudDot];

    _hudFpsBigLabel = makeLabel(@"30 → 60 FPS", 14.5, NSFontWeightBold, YES, [NSColor whiteColor]);
    [headerRow addArrangedSubview:_hudFpsBigLabel];

    _hudRecBadge = makeLabel(@"", 10.5, NSFontWeightBold, YES, [NSColor systemRedColor]);
    _hudRecBadge.hidden = YES;
    [headerRow addArrangedSubview:_hudRecBadge];

    // Row 2: Resolution pipeline
    _hudResLabel = makeLabel(@"1920×1080  →  2560×1520", 10.5, NSFontWeightMedium, YES, [NSColor colorWithWhite:0.86 alpha:0.85]);

    // Row 3: Hardware engine chips
    NSStackView *chipRow = [[NSStackView alloc] init];
    chipRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    chipRow.alignment = NSLayoutAttributeCenterY;
    chipRow.spacing = 6.0;

    _hudFgChipLabel = makeLabel(@"VT Neural 2×", 10.0, NSFontWeightSemibold, NO, [NSColor colorWithRed:0.48 green:0.90 blue:1.0 alpha:1.0]);
    _hudFgChip = makeBadgeChip(_hudFgChipLabel, [NSColor colorWithRed:0.25 green:0.78 blue:1.0 alpha:1.0]);

    _hudUpChipLabel = makeLabel(@"MetalFX", 10.0, NSFontWeightSemibold, NO, [NSColor colorWithRed:0.78 green:0.68 blue:1.0 alpha:1.0]);
    _hudUpChip = makeBadgeChip(_hudUpChipLabel, [NSColor colorWithRed:0.62 green:0.45 blue:1.0 alpha:1.0]);

    _hudHdrChipLabel = makeLabel(@"HDR", 10.0, NSFontWeightHeavy, NO, [NSColor colorWithRed:1.0 green:0.80 blue:0.28 alpha:1.0]);
    _hudHdrChip = makeBadgeChip(_hudHdrChipLabel, [NSColor colorWithRed:1.0 green:0.70 blue:0.15 alpha:1.0]);
    _hudHdrChip.hidden = YES;

    [chipRow addArrangedSubview:_hudFgChip];
    [chipRow addArrangedSubview:_hudUpChip];
    [chipRow addArrangedSubview:_hudHdrChip];

    // Row 4: Live Latency Sparkline
    _sparkline = [[GcSparklineView alloc] initWithFrame:NSZeroRect];
    _sparkline.translatesAutoresizingMaskIntoConstraints = NO;
    [_sparkline.widthAnchor constraintEqualToConstant:210].active = YES;
    [_sparkline.heightAnchor constraintEqualToConstant:22].active = YES;

    // Row 5: Micro-timings
    _hudTimingLabel = makeLabel(@"VT 0.0ms  ·  GPU 0.0ms  ·  Lat 0.0ms", 9.5, NSFontWeightRegular, YES, [NSColor colorWithWhite:0.72 alpha:0.85]);

    [col addArrangedSubview:headerRow];
    [col addArrangedSubview:_hudResLabel];
    [col addArrangedSubview:chipRow];
    [col addArrangedSubview:_sparkline];
    [col addArrangedSubview:_hudTimingLabel];

    _hudGlass.contentView = col;

    [NSLayoutConstraint activateConstraints:@[
        [_hudGlass.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:14],
        [_hudGlass.topAnchor constraintEqualToAnchor:parent.topAnchor constant:54],
    ]];
}

// ============================================================================
// Bottom-Center Single-Row Sculpted Liquid Glass Control Dock
// ============================================================================

- (void)buildBottomDockIn:(NSView *)parent {
    _bottomDockGlass = makeGlassPill(26.0, YES);
    [parent addSubview:_bottomDockGlass];

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10.0;
    row.edgeInsets = NSEdgeInsetsMake(7, 14, 7, 12);
    row.translatesAutoresizingMaskIntoConstraints = NO;

    // Group 1: Neural Frame Gen + Upscaler
    NSImageView *fgIcon = [[NSImageView alloc] init];
    fgIcon.image = sfSymbol(@"sparkles", 13.0, NSFontWeightSemibold);
    fgIcon.contentTintColor = [NSColor colorWithRed:0.48 green:0.88 blue:1.0 alpha:0.95];
    fgIcon.toolTip = @"Apple VideoToolbox Neural Frame Generation";
    [row addArrangedSubview:fgIcon];

    _frameGenSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Off", @"2×", @"4×"]
                                                     trackingMode:NSSegmentSwitchTrackingSelectOne
                                                           target:self
                                                           action:@selector(onFrameGenChanged:)];
    _frameGenSeg.controlSize = NSControlSizeSmall;
    _frameGenSeg.segmentStyle = NSSegmentStyleCapsule;
    _frameGenSeg.selectedSegment = 1;
    _frameGenSeg.toolTip = @"Neural Frame Generation Multiplier (G)";
    [row addArrangedSubview:_frameGenSeg];

    _upscalePopup = makeBorderlessPopup(118, 152, self, @selector(onUpscaleChanged:));
    [_upscalePopup addItemsWithTitles:@[
        @"Native",
        @"MetalFX",
        @"Auto ML + FX",
        @"CAS Sharp",
        @"Pixel 1:1"
    ]];
    [_upscalePopup selectItemAtIndex:2];
    _upscalePopup.toolTip = @"Hardware Upscaling Pipeline (U)";
    [row addArrangedSubview:_upscalePopup];

    [row addArrangedSubview:makeHairlineDivider(22.0)];

    // Group 2: Transport & Capture Buttons
    _pauseBtn = makePillIconBtn(@"pause.fill", 14.0, 34.0, @"Freeze / Resume Video (Space)", self, @selector(onTogglePause:));
    _pauseBtn.activeTint = [NSColor systemYellowColor];

    _shotBtn = makePillIconBtn(@"camera.fill", 14.0, 34.0, @"Save Lossless PNG Screenshot (S)", self, @selector(onScreenshot:));

    _recBtn = makePillIconBtn(@"record.circle", 16.0, 34.0, @"Record Hardware HEVC Video (R)", self, @selector(onToggleRecord:));
    _recBtn.activeTint = [NSColor systemRedColor];

    [row addArrangedSubview:_pauseBtn];
    [row addArrangedSubview:_shotBtn];
    [row addArrangedSubview:_recBtn];

    [row addArrangedSubview:makeHairlineDivider(22.0)];

    // Group 3: Audio Mute + Volume + Meter + Inspector Trigger
    _muteBtn = makePillIconBtn(@"speaker.wave.2.fill", 13.5, 32.0, @"Mute / Unmute Capture Audio (M)", self, @selector(onToggleMute:));
    _muteBtn.activeTint = [NSColor systemOrangeColor];
    [row addArrangedSubview:_muteBtn];

    _volumeSlider = [NSSlider sliderWithValue:0.85 minValue:0.0 maxValue:1.0 target:self action:@selector(onVolumeChanged:)];
    _volumeSlider.controlSize = NSControlSizeSmall;
    _volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_volumeSlider.widthAnchor constraintEqualToConstant:72].active = YES;
    _volumeSlider.toolTip = @"Capture Audio Passthrough Volume";
    [row addArrangedSubview:_volumeSlider];

    _audioMeter = [[GcAudioMeterView alloc] initWithFrame:NSZeroRect];
    _audioMeter.translatesAutoresizingMaskIntoConstraints = NO;
    [_audioMeter.widthAnchor constraintEqualToConstant:52].active = YES;
    [_audioMeter.heightAnchor constraintEqualToConstant:12].active = YES;
    [row addArrangedSubview:_audioMeter];

    [row addArrangedSubview:makeHairlineDivider(22.0)];

    _inspectorBtn = makePillIconBtn(@"slider.horizontal.3", 14.0, 34.0, @"Display, Audio & Glass Tuning (I)", self, @selector(onToggleInspector:));
    [row addArrangedSubview:_inspectorBtn];

    _bottomDockGlass.contentView = row;

    [NSLayoutConstraint activateConstraints:@[
        [_bottomDockGlass.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
        [_bottomDockGlass.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-18],
    ]];
}

// ============================================================================
// Floating Liquid Glass Tuning Inspector Card (Expands Cleanly Above Dock)
// ============================================================================

- (NSStackView *)makeInspectorRowWithTitle:(NSString *)title control:(NSView *)ctrl trailing:(nullable NSView *)trail {
    NSStackView *r = [[NSStackView alloc] init];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 10.0;
    r.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *lbl = makeLabel(title, 11.5, NSFontWeightMedium, NO, [NSColor colorWithWhite:0.82 alpha:0.90]);
    [lbl.widthAnchor constraintEqualToConstant:92].active = YES;
    [r addArrangedSubview:lbl];
    [r addArrangedSubview:ctrl];
    if (trail) [r addArrangedSubview:trail];
    return r;
}

- (void)buildInspectorCardIn:(NSView *)parent {
    _inspectorGlass = makeGlassPill(20.0, YES);
    _inspectorGlass.alphaValue = 0.0;
    _inspectorGlass.hidden = YES;
    [parent addSubview:_inspectorGlass];

    NSStackView *outer = [[NSStackView alloc] init];
    outer.orientation = NSUserInterfaceLayoutOrientationVertical;
    outer.alignment = NSLayoutAttributeCenterX;
    outer.spacing = 11.0;
    outer.edgeInsets = NSEdgeInsetsMake(12, 16, 12, 16);
    outer.translatesAutoresizingMaskIntoConstraints = NO;

    // 3-Tab Header
    _inspectorTabSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Display", @"Color & A/B", @"Audio & Overlay"]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:self
                                                               action:@selector(onInspectorTabChanged:)];
    _inspectorTabSeg.controlSize = NSControlSizeSmall;
    _inspectorTabSeg.segmentStyle = NSSegmentStyleCapsule;
    _inspectorTabSeg.selectedSegment = 0;
    [outer addArrangedSubview:_inspectorTabSeg];

    // ---- TAB 0: Display & HDR ----
    NSStackView *dispCol = [[NSStackView alloc] init];
    dispCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    dispCol.alignment = NSLayoutAttributeLeading;
    dispCol.spacing = 9.0;
    dispCol.translatesAutoresizingMaskIntoConstraints = NO;

    _sharpnessSlider = [NSSlider sliderWithValue:0.35 minValue:0.0 maxValue:1.0 target:self action:@selector(onSharpnessChanged:)];
    _sharpnessSlider.controlSize = NSControlSizeSmall;
    _sharpnessSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_sharpnessSlider.widthAnchor constraintEqualToConstant:168].active = YES;
    _sharpnessValueLabel = makeLabel(@"35%", 11.0, NSFontWeightMedium, YES, [NSColor secondaryLabelColor]);
    [_sharpnessValueLabel.widthAnchor constraintEqualToConstant:36].active = YES;
    [dispCol addArrangedSubview:[self makeInspectorRowWithTitle:@"CAS Sharpness" control:_sharpnessSlider trailing:_sharpnessValueLabel]];

    _aspectSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Fit", @"Fill", @"16:9", @"4:3", @"Full"]
                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                         target:self
                                                         action:@selector(onAspectChanged:)];
    _aspectSeg.controlSize = NSControlSizeSmall;
    _aspectSeg.segmentStyle = NSSegmentStyleCapsule;
    [dispCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Aspect Ratio" control:_aspectSeg trailing:nil]];

    _overscanSlider = [NSSlider sliderWithValue:0.0 minValue:0.0 maxValue:0.08 target:self action:@selector(onOverscanChanged:)];
    _overscanSlider.controlSize = NSControlSizeSmall;
    _overscanSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_overscanSlider.widthAnchor constraintEqualToConstant:168].active = YES;
    _overscanValueLabel = makeLabel(@"0%", 11.0, NSFontWeightMedium, YES, [NSColor secondaryLabelColor]);
    [_overscanValueLabel.widthAnchor constraintEqualToConstant:36].active = YES;
    [dispCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Overscan Crop" control:_overscanSlider trailing:_overscanValueLabel]];

    _intLockSwitch = [[NSSwitch alloc] init];
    _intLockSwitch.controlSize = NSControlSizeSmall;
    _intLockSwitch.target = self;
    _intLockSwitch.action = @selector(onToggleIntLock:);
    NSTextField *intHint = makeLabel(@"Snap to crisp 1×/2×/3× pixels", 10.5, NSFontWeightRegular, NO, [NSColor secondaryLabelColor]);
    [dispCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Integer Scale" control:_intLockSwitch trailing:intHint]];

    _hdrSwitch = [[NSSwitch alloc] init];
    _hdrSwitch.controlSize = NSControlSizeSmall;
    _hdrSwitch.target = self;
    _hdrSwitch.action = @selector(onToggleHdr:);
    _hdrHintLabel = makeLabel(@"10-bit / XDR Extended Dynamic Range", 10.5, NSFontWeightRegular, NO, [NSColor secondaryLabelColor]);
    [dispCol addArrangedSubview:[self makeInspectorRowWithTitle:@"HDR Passthrough" control:_hdrSwitch trailing:_hdrHintLabel]];
    _tabDisplayView = dispCol;

    // ---- TAB 1: Color Grading & Split A/B Compare ----
    NSStackView *colorCol = [[NSStackView alloc] init];
    colorCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    colorCol.alignment = NSLayoutAttributeLeading;
    colorCol.spacing = 9.0;
    colorCol.translatesAutoresizingMaskIntoConstraints = NO;
    colorCol.hidden = YES;

    _colorRangeSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Auto", @"Limited", @"Full"]
                                                       trackingMode:NSSegmentSwitchTrackingSelectOne
                                                             target:self
                                                             action:@selector(onColorRangeChanged:)];
    _colorRangeSeg.controlSize = NSControlSizeSmall;
    _colorRangeSeg.segmentStyle = NSSegmentStyleCapsule;
    [colorCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Color Range" control:_colorRangeSeg trailing:nil]];

    _contrastSlider = [NSSlider sliderWithValue:1.0 minValue:0.7 maxValue:1.5 target:self action:@selector(onContrastChanged:)];
    _contrastSlider.controlSize = NSControlSizeSmall;
    _contrastSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_contrastSlider.widthAnchor constraintEqualToConstant:168].active = YES;
    _contrastValLabel = makeLabel(@"100%", 11.0, NSFontWeightMedium, YES, [NSColor secondaryLabelColor]);
    [_contrastValLabel.widthAnchor constraintEqualToConstant:38].active = YES;
    [colorCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Contrast" control:_contrastSlider trailing:_contrastValLabel]];

    _saturationSlider = [NSSlider sliderWithValue:1.0 minValue:0.0 maxValue:1.8 target:self action:@selector(onSaturationChanged:)];
    _saturationSlider.controlSize = NSControlSizeSmall;
    _saturationSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_saturationSlider.widthAnchor constraintEqualToConstant:168].active = YES;
    _saturationValLabel = makeLabel(@"100%", 11.0, NSFontWeightMedium, YES, [NSColor secondaryLabelColor]);
    [_saturationValLabel.widthAnchor constraintEqualToConstant:38].active = YES;
    [colorCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Saturation" control:_saturationSlider trailing:_saturationValLabel]];

    _gammaSlider = [NSSlider sliderWithValue:1.0 minValue:0.6 maxValue:1.6 target:self action:@selector(onGammaChanged:)];
    _gammaSlider.controlSize = NSControlSizeSmall;
    _gammaSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_gammaSlider.widthAnchor constraintEqualToConstant:168].active = YES;
    _gammaValLabel = makeLabel(@"1.00", 11.0, NSFontWeightMedium, YES, [NSColor secondaryLabelColor]);
    [_gammaValLabel.widthAnchor constraintEqualToConstant:38].active = YES;
    [colorCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Gamma" control:_gammaSlider trailing:_gammaValLabel]];

    NSStackView *abRow = [[NSStackView alloc] init];
    abRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    abRow.alignment = NSLayoutAttributeCenterY;
    abRow.spacing = 8.0;
    _abSplitSwitch = [[NSSwitch alloc] init];
    _abSplitSwitch.controlSize = NSControlSizeSmall;
    _abSplitSwitch.target = self;
    _abSplitSwitch.action = @selector(onToggleAbSplit:);
    _abSplitSlider = [NSSlider sliderWithValue:0.5 minValue:0.05 maxValue:0.95 target:self action:@selector(onAbSplitPosChanged:)];
    _abSplitSlider.controlSize = NSControlSizeSmall;
    _abSplitSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [_abSplitSlider.widthAnchor constraintEqualToConstant:112].active = YES;
    NSButton *resetBtn = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(onResetColor:)];
    resetBtn.bezelStyle = NSBezelStyleAccessoryBarAction;
    resetBtn.controlSize = NSControlSizeSmall;
    [abRow addArrangedSubview:_abSplitSwitch];
    [abRow addArrangedSubview:_abSplitSlider];
    [abRow addArrangedSubview:resetBtn];
    [colorCol addArrangedSubview:[self makeInspectorRowWithTitle:@"A/B Split (B)" control:abRow trailing:nil]];
    _tabColorView = colorCol;

    // ---- TAB 2: Audio, Overlay & Engine ----
    NSStackView *audCol = [[NSStackView alloc] init];
    audCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    audCol.alignment = NSLayoutAttributeLeading;
    audCol.spacing = 9.0;
    audCol.translatesAutoresizingMaskIntoConstraints = NO;
    audCol.hidden = YES;

    _audioDevicePopup = makeBorderlessPopup(180, 225, self, @selector(onAudioDeviceChanged:));
    [audCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Audio Input" control:_audioDevicePopup trailing:nil]];

    _overlayStyleSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Match Window", @"Full Screen"]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:self
                                                               action:@selector(onOverlayStyleChanged:)];
    _overlayStyleSeg.controlSize = NSControlSizeSmall;
    _overlayStyleSeg.segmentStyle = NSSegmentStyleCapsule;
    [audCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Game Overlay" control:_overlayStyleSeg trailing:nil]];

    _glassStyleSeg = [NSSegmentedControl segmentedControlWithLabels:@[@"Regular Glass", @"Clear Glass"]
                                                       trackingMode:NSSegmentSwitchTrackingSelectOne
                                                             target:self
                                                             action:@selector(onGlassStyleSegChanged:)];
    _glassStyleSeg.controlSize = NSControlSizeSmall;
    _glassStyleSeg.segmentStyle = NSSegmentStyleCapsule;
    [audCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Glass Style" control:_glassStyleSeg trailing:nil]];

    _sceneGuardSwitch = [[NSSwitch alloc] init];
    _sceneGuardSwitch.controlSize = NSControlSizeSmall;
    _sceneGuardSwitch.target = self;
    _sceneGuardSwitch.action = @selector(onToggleSceneGuard:);
    NSTextField *sgHint = makeLabel(@"Prevent cut morphing & save power on menus", 10.0, NSFontWeightRegular, NO, [NSColor secondaryLabelColor]);
    [audCol addArrangedSubview:[self makeInspectorRowWithTitle:@"Scene Guard" control:_sceneGuardSwitch trailing:sgHint]];
    _tabAudioView = audCol;

    [outer addArrangedSubview:_tabDisplayView];
    [outer addArrangedSubview:_tabColorView];
    [outer addArrangedSubview:_tabAudioView];

    NSTextField *keys = makeLabel(@"C Hide UI  ·  D HDR  ·  B A/B Split  ·  ⌘⇧O Overlay  ·  ⌘⇧G Frame Gen  ·  H HUD", 9.5, NSFontWeightRegular, NO, [NSColor colorWithWhite:0.65 alpha:0.85]);
    [outer addArrangedSubview:keys];

    _inspectorGlass.contentView = outer;

    [NSLayoutConstraint activateConstraints:@[
        [_inspectorGlass.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
        [_inspectorGlass.bottomAnchor constraintEqualToAnchor:_bottomDockGlass.topAnchor constant:-12],
    ]];
}

- (void)buildNoSignalCardIn:(NSView *)parent {
    _noSignalGlass = makeGlassPill(22.0, YES);
    _noSignalGlass.hidden = YES;
    [parent addSubview:_noSignalGlass];

    NSStackView *col = [[NSStackView alloc] init];
    col.orientation = NSUserInterfaceLayoutOrientationVertical;
    col.alignment = NSLayoutAttributeCenterX;
    col.spacing = 8.0;
    col.edgeInsets = NSEdgeInsetsMake(20, 26, 18, 26);
    col.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *icon = [[NSImageView alloc] init];
    icon.image = sfSymbol(@"video.slash", 28.0, NSFontWeightLight);
    icon.contentTintColor = [NSColor colorWithWhite:0.85 alpha:0.80];
    [col addArrangedSubview:icon];

    NSTextField *title = makeLabel(@"Waiting for Video Signal", 14.5, NSFontWeightSemibold, NO, [NSColor whiteColor]);
    NSTextField *sub = makeLabel(@"Check your capture card HDMI cable, or grant Camera / Screen Recording access.", 11.5, NSFontWeightRegular, NO, [NSColor secondaryLabelColor]);
    [col addArrangedSubview:title];
    [col addArrangedSubview:sub];

    NSStackView *btns = [[NSStackView alloc] init];
    btns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    btns.spacing = 10.0;
    NSButton *demoBtn = [NSButton buttonWithTitle:@"Switch to Demo Signal" target:self action:@selector(onUseTestSignal:)];
    demoBtn.bezelStyle = NSBezelStyleRounded;
    demoBtn.controlSize = NSControlSizeSmall;
    NSButton *privBtn = [NSButton buttonWithTitle:@"Open Privacy Settings" target:self action:@selector(onOpenPrivacy:)];
    privBtn.bezelStyle = NSBezelStyleRounded;
    privBtn.controlSize = NSControlSizeSmall;
    [btns addArrangedSubview:demoBtn];
    [btns addArrangedSubview:privBtn];
    [col addArrangedSubview:btns];

    _noSignalGlass.contentView = col;

    [NSLayoutConstraint activateConstraints:@[
        [_noSignalGlass.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
        [_noSignalGlass.centerYAnchor constraintEqualToAnchor:parent.centerYAnchor],
    ]];
}

// ============================================================================
// Floating Toast Pill
// ============================================================================

- (void)buildToastIn:(NSView *)parent {
    _toastGlass = makeGlassPill(16.0, NO);
    _toastGlass.alphaValue = 0.0;
    [parent addSubview:_toastGlass];

    NSStackView *box = [[NSStackView alloc] init];
    box.edgeInsets = NSEdgeInsetsMake(7, 15, 7, 15);
    box.translatesAutoresizingMaskIntoConstraints = NO;
    _toastLabel = makeLabel(@"", 12.0, NSFontWeightMedium, NO, [NSColor whiteColor]);
    [box addArrangedSubview:_toastLabel];
    _toastGlass.contentView = box;

    [NSLayoutConstraint activateConstraints:@[
        [_toastGlass.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor],
        [_toastGlass.topAnchor constraintEqualToAnchor:_topSourceGlass.bottomAnchor constant:12],
    ]];
}

// ============================================================================
// Auto-Hide & Micro-Animations
// ============================================================================

- (void)revealChromeAndScheduleAutoHide {
    if (self.cleanViewActive || self.activeOverlayMode != GC_OVERLAY_OFF) {
        return;
    }
    if (!self.chromeVisible) {
        self.chromeVisible = YES;
        self.topSourceGlass.hidden = NO;
        self.topUtilGlass.hidden = NO;
        self.bottomDockGlass.hidden = NO;
        if (self.currentState.hud_visible) {
            self.hudGlass.hidden = NO;
        }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.22;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.topSourceGlass.animator.alphaValue = 1.0;
            self.topUtilGlass.animator.alphaValue = 1.0;
            self.bottomDockGlass.animator.alphaValue = 1.0;
            if (self.currentState.hud_visible) {
                self.hudGlass.animator.alphaValue = 1.0;
            }
            [self setTrafficLightsVisible:YES];
        }];
    }
    [self.hideTimer invalidate];
    NSTimeInterval delay = self.isFullScreen ? 2.0 : 3.0;
    __weak typeof(self) weakSelf = self;
    self.hideTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf hideChromeIfNotHovering];
    }];
}

- (void)hideChromeIfNotHovering {
    if (!self.window || self.inspectorOpen || self.cleanViewActive || self.activeOverlayMode != GC_OVERLAY_OFF) return;
    NSPoint mouseScreen = [NSEvent mouseLocation];
    NSPoint mouseWin = [self.window convertPointFromScreen:mouseScreen];
    if (NSPointInRect(mouseWin, NSInsetRect(self.topSourceGlass.frame, -10, -10)) ||
        NSPointInRect(mouseWin, NSInsetRect(self.topUtilGlass.frame, -10, -10)) ||
        NSPointInRect(mouseWin, NSInsetRect(self.bottomDockGlass.frame, -10, -10))) {
        [self revealChromeAndScheduleAutoHide];
        return;
    }
    self.chromeVisible = NO;
    BOOL hideHudToo = self.isFullScreen;
    __weak typeof(self) weakSelf = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.34;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.topSourceGlass.animator.alphaValue = 0.0;
        self.topUtilGlass.animator.alphaValue = 0.0;
        self.bottomDockGlass.animator.alphaValue = 0.0;
        if (hideHudToo) {
            self.hudGlass.animator.alphaValue = 0.0;
        }
        [self setTrafficLightsVisible:NO];
    } completionHandler:^{
        // Actually set hidden = YES so invisible glass pills NEVER steal clicks or double-click fullscreen!
        if (!weakSelf.chromeVisible) {
            weakSelf.topSourceGlass.hidden = YES;
            weakSelf.topUtilGlass.hidden = YES;
            weakSelf.bottomDockGlass.hidden = YES;
            if (hideHudToo) weakSelf.hudGlass.hidden = YES;
        }
    }];
    if (self.isFullScreen && self.window.isKeyWindow) {
        [NSCursor setHiddenUntilMouseMoves:YES];
    }
}

- (void)setInspectorOpen:(BOOL)open animated:(BOOL)animated {
    _inspectorOpen = open;
    self.inspectorBtn.isActiveState = open;
    if (open) {
        [self revealChromeAndScheduleAutoHide];
        self.inspectorGlass.hidden = NO;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = animated ? 0.20 : 0.0;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.inspectorGlass.animator.alphaValue = 1.0;
        }];
    } else {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = animated ? 0.16 : 0.0;
            self.inspectorGlass.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (!self.inspectorOpen) self.inspectorGlass.hidden = YES;
        }];
        [self revealChromeAndScheduleAutoHide];
    }
}

- (void)triggerShutterFlash {
    self.shutterFlashView.alphaValue = 0.55;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.24;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        self.shutterFlashView.animator.alphaValue = 0.0;
    }];
}

- (void)showToast:(NSString *)msg {
    self.toastLabel.stringValue = msg ?: @"";
    [self.toastTimer invalidate];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.18;
        self.toastGlass.animator.alphaValue = 1.0;
    }];
    __weak typeof(self) weakSelf = self;
    self.toastTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 repeats:NO block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.32;
            weakSelf.toastGlass.animator.alphaValue = 0.0;
        }];
    }];
}

// ============================================================================
// Keyboard Shortcuts
// ============================================================================

- (BOOL)handleKeyEvent:(NSEvent *)event {
    if ((event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0) {
        return NO;
    }
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
    if ([chars isEqualToString:@" "]) { [self onTogglePause:nil]; return YES; }
    if ([chars isEqualToString:@"f"]) { [self onToggleFullscreen:nil]; return YES; }
    if ([chars isEqualToString:@"h"]) { [self onToggleHud:nil]; return YES; }
    if ([chars isEqualToString:@"g"]) { [self menuCycleFrameGen:nil]; return YES; }
    if ([chars isEqualToString:@"u"]) { [self menuCycleUpscale:nil]; return YES; }
    if ([chars isEqualToString:@"m"]) { [self onToggleMute:nil]; return YES; }
    if ([chars isEqualToString:@"t"]) { [self onTogglePin:nil]; return YES; }
    if ([chars isEqualToString:@"s"]) { [self onScreenshot:nil]; return YES; }
    if ([chars isEqualToString:@"r"]) { [self onToggleRecord:nil]; return YES; }
    if ([chars isEqualToString:@"o"]) { [self onToggleOverlay:nil]; return YES; }
    if ([chars isEqualToString:@"d"]) { [self onToggleHdr:nil]; return YES; }
    if ([chars isEqualToString:@"c"]) { [self onToggleCleanView:nil]; return YES; }
    if ([chars isEqualToString:@"b"]) { [self onToggleAbSplit:nil]; return YES; }
    if ([chars isEqualToString:@"i"]) { [self onToggleInspector:nil]; return YES; }
    if (event.keyCode == 53) { // Esc
        if (self.cleanViewActive) { [self onToggleCleanView:nil]; return YES; }
        if (self.inspectorOpen) { [self setInspectorOpen:NO animated:YES]; return YES; }
    }
    return NO;
}

// ============================================================================
// Control Actions -> Rust Controller
// ============================================================================

- (void)onVideoDeviceChanged:(id)sender {
    (void)sender;
    NSInteger idx = self.videoDevicePopup.indexOfSelectedItem;
    if (idx >= 0 && (NSUInteger)idx < self.videoDeviceUids.count) {
        [self emitAction:GC_ACTION_SELECT_VIDEO_DEVICE intArg:0 floatArg:0 strArg:self.videoDeviceUids[(NSUInteger)idx]];
    }
}

- (void)onVideoFormatChanged:(id)sender {
    (void)sender;
    NSInteger idx = self.videoFormatPopup.indexOfSelectedItem;
    if (idx >= 0 && (NSUInteger)idx < self.videoFormatIndices.count) {
        int32_t fmtIdx = self.videoFormatIndices[(NSUInteger)idx].intValue;
        [self emitAction:GC_ACTION_SELECT_VIDEO_FORMAT intArg:fmtIdx floatArg:0 strArg:nil];
    }
}

- (void)onAudioDeviceChanged:(id)sender {
    (void)sender;
    NSInteger idx = self.audioDevicePopup.indexOfSelectedItem;
    if (idx >= 0 && (NSUInteger)idx < self.audioDeviceUids.count) {
        [self emitAction:GC_ACTION_SELECT_AUDIO_DEVICE intArg:0 floatArg:0 strArg:self.audioDeviceUids[(NSUInteger)idx]];
    }
}

- (void)onRefreshDevices:(id)sender { (void)sender; [self emitAction:GC_ACTION_REFRESH_DEVICES intArg:0 floatArg:0 strArg:nil]; }
- (void)onTogglePin:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_ALWAYS_ON_TOP intArg:0 floatArg:0 strArg:nil]; }
- (void)onToggleHud:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_HUD intArg:0 floatArg:0 strArg:nil]; }
- (void)onToggleFullscreen:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_FULLSCREEN intArg:0 floatArg:0 strArg:nil]; }
- (void)onToggleInspector:(id)sender { (void)sender; [self setInspectorOpen:!self.inspectorOpen animated:YES]; }
- (void)onFrameGenChanged:(id)sender { (void)sender; [self emitAction:GC_ACTION_SET_FRAMEGEN_MODE intArg:(int32_t)self.frameGenSeg.selectedSegment floatArg:0 strArg:nil]; }
- (void)onUpscaleChanged:(id)sender { (void)sender; [self emitAction:GC_ACTION_SET_UPSCALE_MODE intArg:(int32_t)self.upscalePopup.indexOfSelectedItem floatArg:0 strArg:nil]; }
- (void)onSharpnessChanged:(id)sender {
    (void)sender;
    float v = self.sharpnessSlider.floatValue;
    self.sharpnessValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
    [self emitAction:GC_ACTION_SET_SHARPNESS intArg:0 floatArg:v strArg:nil];
}
- (void)onAspectChanged:(id)sender { (void)sender; [self emitAction:GC_ACTION_SET_ASPECT_MODE intArg:(int32_t)self.aspectSeg.selectedSegment floatArg:0 strArg:nil]; }
- (void)onToggleIntLock:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_INTEGER_LOCK intArg:0 floatArg:0 strArg:nil]; }
- (void)onToggleMute:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_AUDIO_MUTE intArg:0 floatArg:0 strArg:nil]; }
- (void)onVolumeChanged:(id)sender { (void)sender; [self emitAction:GC_ACTION_SET_AUDIO_VOLUME intArg:0 floatArg:self.volumeSlider.floatValue strArg:nil]; }
- (void)onTogglePause:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_PAUSE intArg:0 floatArg:0 strArg:nil]; }
- (void)onScreenshot:(id)sender {
    (void)sender;
    [self triggerShutterFlash];
    [self emitAction:GC_ACTION_TAKE_SCREENSHOT intArg:0 floatArg:0 strArg:nil];
}
- (void)onToggleRecord:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_RECORDING intArg:0 floatArg:0 strArg:nil]; }
- (void)onGlassStyleSegChanged:(id)sender {
    (void)sender;
    [self emitAction:GC_ACTION_SET_GLASS_STYLE intArg:(int32_t)self.glassStyleSeg.selectedSegment floatArg:0 strArg:nil];
}
- (void)onVideoPopupWillOpen:(NSNotification *)note {
    (void)note;
    // Live-refresh open Mac windows & capture cards silently right before the dropdown opens!
    [self emitAction:GC_ACTION_REFRESH_DEVICES intArg:1 floatArg:0 strArg:nil];
}

- (void)onInspectorTabChanged:(id)sender {
    (void)sender;
    NSInteger sel = self.inspectorTabSeg.selectedSegment;
    self.tabDisplayView.hidden = (sel != 0);
    self.tabColorView.hidden = (sel != 1);
    self.tabAudioView.hidden = (sel != 2);
}

- (void)onOverscanChanged:(id)sender {
    (void)sender;
    float v = self.overscanSlider.floatValue;
    self.overscanValueLabel.stringValue = [NSString stringWithFormat:@"%.1f%%", v * 100.0f];
    [self emitAction:GC_ACTION_SET_OVERSCAN intArg:0 floatArg:v strArg:nil];
}
- (void)onColorRangeChanged:(id)sender { (void)sender; [self emitAction:GC_ACTION_SET_COLOR_RANGE intArg:(int32_t)self.colorRangeSeg.selectedSegment floatArg:0 strArg:nil]; }
- (void)onContrastChanged:(id)sender {
    (void)sender;
    float v = self.contrastSlider.floatValue;
    self.contrastValLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
    [self emitAction:GC_ACTION_SET_CONTRAST intArg:0 floatArg:v strArg:nil];
}
- (void)onSaturationChanged:(id)sender {
    (void)sender;
    float v = self.saturationSlider.floatValue;
    self.saturationValLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", v * 100.0f];
    [self emitAction:GC_ACTION_SET_SATURATION intArg:0 floatArg:v strArg:nil];
}
- (void)onGammaChanged:(id)sender {
    (void)sender;
    float v = self.gammaSlider.floatValue;
    self.gammaValLabel.stringValue = [NSString stringWithFormat:@"%.2f", v];
    [self emitAction:GC_ACTION_SET_GAMMA intArg:0 floatArg:v strArg:nil];
}
- (void)onToggleAbSplit:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_AB_SPLIT intArg:0 floatArg:0 strArg:nil]; }
- (void)onAbSplitPosChanged:(id)sender { (void)sender; [self emitAction:GC_ACTION_SET_AB_SPLIT_POS intArg:0 floatArg:self.abSplitSlider.floatValue strArg:nil]; }
- (void)onResetColor:(id)sender { (void)sender; [self emitAction:GC_ACTION_RESET_COLOR intArg:0 floatArg:0 strArg:nil]; }
- (void)onToggleSceneGuard:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_SCENE_GUARD intArg:0 floatArg:0 strArg:nil]; }
- (void)onUseTestSignal:(id)sender { (void)sender; [self emitAction:GC_ACTION_USE_TEST_SIGNAL intArg:0 floatArg:0 strArg:nil]; }
- (void)onOpenPrivacy:(id)sender { (void)sender; [self emitAction:GC_ACTION_OPEN_PRIVACY intArg:0 floatArg:0 strArg:nil]; }

- (void)onToggleOverlay:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_OVERLAY intArg:0 floatArg:0 strArg:nil]; }
- (void)onToggleHdr:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_HDR intArg:0 floatArg:0 strArg:nil]; }
- (void)onToggleCleanView:(id)sender { (void)sender; [self emitAction:GC_ACTION_TOGGLE_CLEAN_VIEW intArg:0 floatArg:0 strArg:nil]; }
- (void)onOverlayStyleChanged:(id)sender {
    (void)sender;
    int32_t mode = (self.overlayStyleSeg.selectedSegment == 1) ? GC_OVERLAY_FULLSCREEN : GC_OVERLAY_MATCH_WINDOW;
    [self emitAction:GC_ACTION_SET_OVERLAY_STYLE intArg:mode floatArg:0 strArg:nil];
}

- (void)menuCycleFrameGen:(id)sender {
    (void)sender;
    int32_t next = (self.currentState.framegen_mode + 1) % 3;
    [self emitAction:GC_ACTION_SET_FRAMEGEN_MODE intArg:next floatArg:0 strArg:nil];
}

- (void)menuCycleUpscale:(id)sender {
    (void)sender;
    int32_t next = (self.currentState.upscale_mode + 1) % 5;
    [self emitAction:GC_ACTION_SET_UPSCALE_MODE intArg:next floatArg:0 strArg:nil];
}

- (void)menuToggleGlassStyle:(id)sender {
    (void)sender;
    int32_t next = (self.currentState.glass_style == 0) ? 1 : 0;
    [self emitAction:GC_ACTION_SET_GLASS_STYLE intArg:next floatArg:0 strArg:nil];
}

// ============================================================================
// NSApplicationDelegate / Window Lifecycle
// ============================================================================

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.metalView];
    [NSApp activateIgnoringOtherApps:YES];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self emitAction:GC_ACTION_APP_WILL_TERMINATE intArg:0 floatArg:0 strArg:nil];
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
    (void)notification;
    bool visible = (self.window.occlusionState & NSWindowOcclusionStateVisible) != 0 && !self.window.isMiniaturized;
    atomic_store_explicit(&_windowVisible, visible, memory_order_relaxed);
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
    (void)notification;
    atomic_store_explicit(&_windowVisible, false, memory_order_relaxed);
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
    (void)notification;
    atomic_store_explicit(&_windowVisible, true, memory_order_relaxed);
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    (void)notification;
    self.isFullScreen = YES;
    [self revealChromeAndScheduleAutoHide];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    (void)notification;
    self.isFullScreen = NO;
    if (!self.cleanViewActive && self.currentState.hud_visible) {
        self.hudGlass.hidden = NO;
        self.hudGlass.alphaValue = 1.0;
    }
    [self revealChromeAndScheduleAutoHide];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    (void)notification;
    [self refreshScreenEdrHeadroom];
}

- (float)screenEdrHeadroomAtomic {
    return atomic_load_explicit(&_screenEdrHeadroom, memory_order_relaxed);
}

- (bool)isWindowVisibleAtomic {
    return atomic_load_explicit(&_windowVisible, memory_order_relaxed);
}

- (void)applyGlassStyle:(int32_t)style {
    NSGlassEffectViewStyle s = (style == 1) ? NSGlassEffectViewStyleClear : NSGlassEffectViewStyleRegular;
    self.topSourceGlass.style = s;
    self.topUtilGlass.style = s;
    self.hudGlass.style = s;
    self.bottomDockGlass.style = s;
    self.inspectorGlass.style = s;
    self.noSignalGlass.style = s;
    self.toastGlass.style = s;
}

@end

// ============================================================================
// C Bridge Functions
// ============================================================================

void *gc_app_create(const GcCallbacks *callbacks) {
    @autoreleasepool {
        GcAppController *ctrl = [[GcAppController alloc] initWithCallbacks:*callbacks];
        return (__bridge_retained void *)ctrl;
    }
}

void gc_app_run(void *app_ptr) {
    (void)app_ptr;
    @autoreleasepool { [NSApp run]; }
}

void *gc_app_get_metal_layer(void *app_ptr) {
    if (!app_ptr) return NULL;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    return (__bridge void *)ctrl.metalView.metalLayer;
}

void gc_app_set_devices(
    void *app_ptr,
    const GcDeviceInfo *video_devices, uint32_t video_count, const char *selected_video_uid,
    const GcVideoFormatInfo *formats, uint32_t format_count, int32_t selected_format_idx,
    const GcDeviceInfo *audio_devices, uint32_t audio_count, const char *selected_audio_uid
) {
    if (!app_ptr) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;

    NSMutableArray<NSDictionary *> *vList = [NSMutableArray arrayWithCapacity:video_count];
    for (uint32_t i = 0; i < video_count; i++) {
        [vList addObject:@{
            @"uid": [NSString stringWithUTF8String:video_devices[i].uid] ?: @"",
            @"name": [NSString stringWithUTF8String:video_devices[i].name] ?: @"Device",
            @"ext": @(video_devices[i].is_external)
        }];
    }
    NSString *selV = selected_video_uid ? [NSString stringWithUTF8String:selected_video_uid] : @"";

    NSMutableArray<NSDictionary *> *fList = [NSMutableArray arrayWithCapacity:format_count];
    for (uint32_t i = 0; i < format_count; i++) {
        [fList addObject:@{
            @"idx": @(formats[i].index),
            @"label": [NSString stringWithUTF8String:formats[i].label] ?: @"Auto"
        }];
    }

    NSMutableArray<NSDictionary *> *aList = [NSMutableArray arrayWithCapacity:audio_count];
    for (uint32_t i = 0; i < audio_count; i++) {
        [aList addObject:@{
            @"uid": [NSString stringWithUTF8String:audio_devices[i].uid] ?: @"",
            @"name": [NSString stringWithUTF8String:audio_devices[i].name] ?: @"Audio",
            @"ext": @(audio_devices[i].is_external)
        }];
    }
    NSString *selA = selected_audio_uid ? [NSString stringWithUTF8String:selected_audio_uid] : @"";

    dispatch_async(dispatch_get_main_queue(), ^{
        ctrl.suppressCallbacks = YES;

        [ctrl.videoDevicePopup removeAllItems];
        [ctrl.videoDeviceUids removeAllObjects];
        NSInteger vSel = 0;
        for (NSUInteger i = 0; i < vList.count; i++) {
            NSDictionary *d = vList[i];
            NSString *prefix = [d[@"ext"] boolValue] ? @"⚡ " : @"";
            [ctrl.videoDevicePopup addItemWithTitle:[prefix stringByAppendingString:d[@"name"]]];
            [ctrl.videoDeviceUids addObject:d[@"uid"]];
            if ([d[@"uid"] isEqualToString:selV]) vSel = (NSInteger)i;
        }
        if (ctrl.videoDevicePopup.numberOfItems > 0) [ctrl.videoDevicePopup selectItemAtIndex:vSel];

        [ctrl.videoFormatPopup removeAllItems];
        [ctrl.videoFormatIndices removeAllObjects];
        NSInteger fSel = 0;
        for (NSUInteger i = 0; i < fList.count; i++) {
            NSDictionary *f = fList[i];
            [ctrl.videoFormatPopup addItemWithTitle:f[@"label"]];
            [ctrl.videoFormatIndices addObject:f[@"idx"]];
            if ([f[@"idx"] intValue] == selected_format_idx) fSel = (NSInteger)i;
        }
        if (ctrl.videoFormatPopup.numberOfItems == 0) {
            [ctrl.videoFormatPopup addItemWithTitle:@"Auto"];
            [ctrl.videoFormatIndices addObject:@(-1)];
        }
        [ctrl.videoFormatPopup selectItemAtIndex:fSel];

        [ctrl.audioDevicePopup removeAllItems];
        [ctrl.audioDeviceUids removeAllObjects];
        [ctrl.audioDevicePopup addItemWithTitle:@"Audio Off"];
        [ctrl.audioDeviceUids addObject:@""];
        NSInteger aSel = 0;
        for (NSUInteger i = 0; i < aList.count; i++) {
            NSDictionary *d = aList[i];
            NSString *prefix = [d[@"ext"] boolValue] ? @"⚡ " : @"";
            [ctrl.audioDevicePopup addItemWithTitle:[prefix stringByAppendingString:d[@"name"]]];
            [ctrl.audioDeviceUids addObject:d[@"uid"]];
            if ([d[@"uid"] isEqualToString:selA]) aSel = (NSInteger)(i + 1);
        }
        [ctrl.audioDevicePopup selectItemAtIndex:aSel];

        ctrl.suppressCallbacks = NO;
    });
}

void gc_app_update_ui_state(void *app_ptr, const GcUiStateSnapshot *state_ptr) {
    if (!app_ptr || !state_ptr) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    GcUiStateSnapshot s = *state_ptr;

    dispatch_async(dispatch_get_main_queue(), ^{
        ctrl.suppressCallbacks = YES;
        ctrl.currentState = s;

        if (s.framegen_mode >= 0 && s.framegen_mode < 3) ctrl.frameGenSeg.selectedSegment = s.framegen_mode;
        if (s.upscale_mode >= 0 && s.upscale_mode < ctrl.upscalePopup.numberOfItems) [ctrl.upscalePopup selectItemAtIndex:s.upscale_mode];
        if (s.aspect_mode >= 0 && s.aspect_mode < 5) ctrl.aspectSeg.selectedSegment = s.aspect_mode;

        ctrl.sharpnessSlider.floatValue = s.sharpness;
        ctrl.sharpnessValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", s.sharpness * 100.0f];
        ctrl.overscanSlider.floatValue = s.overscan_crop;
        ctrl.overscanValueLabel.stringValue = [NSString stringWithFormat:@"%.1f%%", s.overscan_crop * 100.0f];
        if (s.color_range_mode >= 0 && s.color_range_mode < 3) ctrl.colorRangeSeg.selectedSegment = s.color_range_mode;
        ctrl.contrastSlider.floatValue = s.contrast;
        ctrl.contrastValLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", s.contrast * 100.0f];
        ctrl.saturationSlider.floatValue = s.saturation;
        ctrl.saturationValLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", s.saturation * 100.0f];
        ctrl.gammaSlider.floatValue = s.gamma;
        ctrl.gammaValLabel.stringValue = [NSString stringWithFormat:@"%.2f", s.gamma];
        ctrl.abSplitSwitch.state = s.ab_split_enabled ? NSControlStateValueOn : NSControlStateValueOff;
        ctrl.abSplitSlider.floatValue = s.ab_split_pos;
        ctrl.sceneGuardSwitch.state = s.scene_guard_enabled ? NSControlStateValueOn : NSControlStateValueOff;
        ctrl.volumeSlider.floatValue = s.audio_volume;
        ctrl.intLockSwitch.state = s.integer_lock ? NSControlStateValueOn : NSControlStateValueOff;

        ctrl.pinBtn.image = sfSymbol(s.always_on_top ? @"pin.fill" : @"pin", 13.0, NSFontWeightMedium);
        ctrl.pinBtn.isActiveState = s.always_on_top;

        ctrl.cleanViewActive = s.clean_view;
        ctrl.cleanViewBtn.isActiveState = s.clean_view;
        if (s.clean_view) {
            [ctrl setInspectorOpen:NO animated:NO];
            [ctrl.hideTimer invalidate];
            ctrl.chromeVisible = NO;
            __weak GcAppController *weakCtrl = ctrl;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = 0.25;
                ctrl.topSourceGlass.animator.alphaValue = 0.0;
                ctrl.topUtilGlass.animator.alphaValue = 0.0;
                ctrl.bottomDockGlass.animator.alphaValue = 0.0;
                ctrl.hudGlass.animator.alphaValue = 0.0;
                [ctrl setTrafficLightsVisible:NO];
            } completionHandler:^{
                if (weakCtrl.cleanViewActive) {
                    weakCtrl.topSourceGlass.hidden = YES;
                    weakCtrl.topUtilGlass.hidden = YES;
                    weakCtrl.bottomDockGlass.hidden = YES;
                    weakCtrl.hudGlass.hidden = YES;
                }
            }];
            if (ctrl.window.isKeyWindow) {
                [NSCursor setHiddenUntilMouseMoves:YES];
            }
        } else {
            ctrl.hudGlass.hidden = !s.hud_visible;
            if (s.hud_visible) ctrl.hudGlass.alphaValue = 1.0;
            if (ctrl.activeOverlayMode == GC_OVERLAY_OFF) {
                [ctrl revealChromeAndScheduleAutoHide];
            }
        }
        ctrl.hudBtn.isActiveState = s.hud_visible;

        ctrl.hdrSwitch.state = s.hdr_enabled ? NSControlStateValueOn : NSControlStateValueOff;
        ctrl.hdrTopBadgeBtn.isActiveState = s.hdr_enabled;
        ctrl.hdrTopBadgeBtn.layer.borderColor = s.hdr_enabled
            ? [NSColor colorWithRed:1.0 green:0.78 blue:0.25 alpha:0.75].CGColor
            : [NSColor colorWithWhite:1.0 alpha:0.18].CGColor;
        ctrl.hdrTopBadgeBtn.contentTintColor = s.hdr_enabled
            ? [NSColor colorWithRed:1.0 green:0.84 blue:0.32 alpha:1.0]
            : [NSColor colorWithWhite:0.75 alpha:0.65];
        if (!s.hdr_enabled) {
            ctrl.hudHdrChip.hidden = YES;
            ctrl.hdrTopBadgeBtn.title = @"HDR";
        }

        ctrl.muteBtn.image = sfSymbol(s.audio_muted ? @"speaker.slash.fill" : @"speaker.wave.2.fill", 13.5, NSFontWeightMedium);
        ctrl.muteBtn.isActiveState = s.audio_muted;
        ctrl.audioMeter.muted = s.audio_muted;

        ctrl.pauseBtn.image = sfSymbol(s.is_paused ? @"play.fill" : @"pause.fill", 14.0, NSFontWeightMedium);
        ctrl.pauseBtn.isActiveState = s.is_paused;

        ctrl.recBtn.image = sfSymbol(s.is_recording ? @"stop.circle.fill" : @"record.circle", 16.0, NSFontWeightSemibold);
        ctrl.recBtn.isActiveState = s.is_recording;

        ctrl.glassStyleSeg.selectedSegment = (s.glass_style == 1) ? 1 : 0;
        ctrl.overlayStyleSeg.selectedSegment = (s.preferred_overlay == GC_OVERLAY_FULLSCREEN) ? 1 : 0;
        ctrl.overlayBtn.isActiveState = (s.overlay_mode != GC_OVERLAY_OFF);
        ctrl.statusOverlayItem.title = (s.overlay_mode != GC_OVERLAY_OFF)
            ? @"Exit Game Overlay (⌘⇧O)"
            : @"Enter Game Overlay (⌘⇧O)";
        [ctrl applyGlassStyle:s.glass_style];

        ctrl.suppressCallbacks = NO;
    });
}

static inline void setLabelIfChanged(NSTextField *lbl, NSString *val) {
    if (![lbl.stringValue isEqualToString:val]) {
        lbl.stringValue = val;
    }
}

void gc_app_update_hud_metrics(void *app_ptr, const GcHudMetrics *metrics_ptr) {
    if (!app_ptr || !metrics_ptr) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    GcHudMetrics m = *metrics_ptr;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Update audio meter only while chrome is visible
        if (ctrl.chromeVisible) {
            ctrl.audioMeter.level = fminf(1.0f, m.audio_peak * 1.45f);
        }

        // Live status indicator colors
        NSColor *dotColor;
        if (m.is_recording) {
            dotColor = [NSColor systemRedColor];
        } else if (m.is_paused) {
            dotColor = [NSColor systemYellowColor];
        } else if (m.is_test_pattern) {
            dotColor = [NSColor colorWithRed:0.32 green:0.86 blue:0.98 alpha:1.0];
        } else {
            dotColor = [NSColor colorWithRed:0.25 green:0.90 blue:0.55 alpha:1.0];
        }
        if (ctrl.sourceDot.dotColor != dotColor) {
            ctrl.sourceDot.dotColor = dotColor;
            ctrl.hudDot.dotColor = dotColor;
        }

        // Show sleek No-Signal Liquid Glass card when no frames arrive for >2.5s (and not in game overlay)
        BOOL showNoSignal = m.no_signal && (ctrl.activeOverlayMode == GC_OVERLAY_OFF) && !ctrl.cleanViewActive;
        if (ctrl.noSignalGlass.hidden == showNoSignal) {
            ctrl.noSignalGlass.hidden = !showNoSignal;
        }

        // Update HDR tags & headroom readout
        if (m.hdr_active) {
            NSString *tag = [NSString stringWithUTF8String:m.hdr_tag];
            if (!tag || tag.length == 0) tag = @"HDR";
            NSString *shortTag = m.hdr_source_10bit ? @"HDR10" : @"HDR";
            if (![ctrl.hdrTopBadgeBtn.title isEqualToString:shortTag]) {
                ctrl.hdrTopBadgeBtn.title = shortTag;
            }
            setLabelIfChanged(ctrl.hudHdrChipLabel, tag);
            ctrl.hudHdrChip.hidden = NO;
            setLabelIfChanged(ctrl.hdrHintLabel, m.edr_headroom > 1.05f
                ? [NSString stringWithFormat:@"Active · %.1f× XDR Peak", m.edr_headroom]
                : @"Active (SDR Display)");
        } else {
            ctrl.hudHdrChip.hidden = YES;
            setLabelIfChanged(ctrl.hdrHintLabel, m.edr_headroom > 1.05f
                ? [NSString stringWithFormat:@"Display supports %.1f× XDR", m.edr_headroom]
                : @"10-bit / XDR Extended Dynamic Range");
        }

        // Skip HUD layout/redraw work completely when HUD is hidden
        if (ctrl.hudGlass.hidden || ctrl.hudGlass.alphaValue < 0.05) return;

        NSString *fg = [NSString stringWithUTF8String:m.fg_engine] ?: @"Off";
        NSString *up = [NSString stringWithUTF8String:m.up_engine] ?: @"Native";

        setLabelIfChanged(ctrl.hudFpsBigLabel, [NSString stringWithFormat:@"%.0f → %.0f FPS", m.source_fps, m.output_fps]);
        setLabelIfChanged(ctrl.hudResLabel, [NSString stringWithFormat:@"%u×%u  →  %u×%u",
            m.source_width, m.source_height, m.output_width, m.output_height]);
        setLabelIfChanged(ctrl.hudFgChipLabel, [NSString stringWithFormat:@"FG %@", fg]);
        setLabelIfChanged(ctrl.hudUpChipLabel, up);
        setLabelIfChanged(ctrl.hudTimingLabel, [NSString stringWithFormat:@"VT %.1fms · GPU %.1fms · Lat %.1fms",
            m.vt_proc_ms, m.gpu_render_ms, m.total_latency_ms]);

        [ctrl.sparkline pushSample:m.total_latency_ms];

        if (m.is_recording) {
            int mins = (int)(m.recording_secs / 60.0);
            int secs = ((int)m.recording_secs) % 60;
            setLabelIfChanged(ctrl.hudRecBadge, [NSString stringWithFormat:@"● REC %02d:%02d", mins, secs]);
            ctrl.hudRecBadge.textColor = [NSColor systemRedColor];
            ctrl.hudRecBadge.hidden = NO;
        } else if (m.is_paused) {
            setLabelIfChanged(ctrl.hudRecBadge, @"PAUSED");
            ctrl.hudRecBadge.textColor = [NSColor systemYellowColor];
            ctrl.hudRecBadge.hidden = NO;
        } else {
            ctrl.hudRecBadge.hidden = YES;
        }
    });
}

void gc_app_show_toast(void *app_ptr, const char *message) {
    if (!app_ptr || !message) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    NSString *str = [NSString stringWithUTF8String:message];
    dispatch_async(dispatch_get_main_queue(), ^{ [ctrl showToast:str]; });
}

void gc_app_set_always_on_top(void *app_ptr, bool enabled) {
    if (!app_ptr) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (enabled) {
            ctrl.window.level = NSFloatingWindowLevel;
            ctrl.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorCanJoinAllSpaces;
        } else {
            ctrl.window.level = NSNormalWindowLevel;
            ctrl.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        }
    });
}

void gc_app_toggle_fullscreen(void *app_ptr) {
    if (!app_ptr) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    dispatch_async(dispatch_get_main_queue(), ^{ [ctrl.window toggleFullScreen:nil]; });
}

void gc_app_set_window_title(void *app_ptr, const char *title) {
    if (!app_ptr || !title) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    NSString *t = [NSString stringWithUTF8String:title];
    dispatch_async(dispatch_get_main_queue(), ^{ ctrl.window.title = t; });
}

bool gc_app_is_visible(void *app_ptr) {
    if (!app_ptr) return true;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    return [ctrl isWindowVisibleAtomic];
}

float gc_app_get_screen_edr_headroom(void *app_ptr) {
    if (!app_ptr) return 1.0f;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;
    return [ctrl screenEdrHeadroomAtomic];
}

void gc_app_open_privacy_settings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"];
        if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    });
}

void gc_app_set_overlay_mode(void *app_ptr, int32_t overlay_mode, uint32_t target_window_id, int32_t target_pid) {
    if (!app_ptr) return;
    GcAppController *ctrl = (__bridge GcAppController *)app_ptr;

    dispatch_async(dispatch_get_main_queue(), ^{
        [ctrl.overlayTrackTimer invalidate];
        ctrl.overlayTrackTimer = nil;
        ctrl.activeOverlayMode = overlay_mode;
        ctrl.overlayTargetWinId = target_window_id;
        ctrl.overlayTargetPid = target_pid;
        ctrl.overlayMissingTicks = 0;

        if (overlay_mode == GC_OVERLAY_OFF) {
            ctrl.window.ignoresMouseEvents = NO;
            ctrl.window.hasShadow = YES;
            ctrl.window.styleMask = NSWindowStyleMaskTitled
                                  | NSWindowStyleMaskClosable
                                  | NSWindowStyleMaskMiniaturizable
                                  | NSWindowStyleMaskResizable
                                  | NSWindowStyleMaskFullSizeContentView;
            ctrl.window.titleVisibility = NSWindowTitleHidden;
            ctrl.window.titlebarAppearsTransparent = YES;
            ctrl.window.movableByWindowBackground = YES;
            ctrl.window.level = ctrl.currentState.always_on_top ? NSFloatingWindowLevel : NSNormalWindowLevel;
            ctrl.window.collectionBehavior = ctrl.currentState.always_on_top
                ? (NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorCanJoinAllSpaces)
                : NSWindowCollectionBehaviorFullScreenPrimary;
            if (ctrl.hasSavedNormalFrame) {
                [ctrl.window setFrame:ctrl.savedNormalFrame display:YES animate:YES];
            }
            ctrl.topSourceGlass.hidden = NO;
            ctrl.topUtilGlass.hidden = NO;
            ctrl.bottomDockGlass.hidden = NO;
            [ctrl setTrafficLightsVisible:YES];
            [ctrl revealChromeAndScheduleAutoHide];
            [ctrl.window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
            return;
        }

        // Entering Click-Through Game/App Overlay Mode!
        if (!ctrl.hasSavedNormalFrame) {
            ctrl.savedNormalFrame = ctrl.window.frame;
            ctrl.hasSavedNormalFrame = YES;
        }
        [ctrl setInspectorOpen:NO animated:NO];
        [ctrl.hideTimer invalidate];
        ctrl.topSourceGlass.hidden = YES;
        ctrl.topUtilGlass.hidden = YES;
        ctrl.bottomDockGlass.hidden = YES;
        ctrl.noSignalGlass.hidden = YES;

        ctrl.window.styleMask = NSWindowStyleMaskBorderless;
        ctrl.window.hasShadow = NO;
        ctrl.window.ignoresMouseEvents = YES;
        ctrl.window.level = NSFloatingWindowLevel;
        ctrl.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                       | NSWindowCollectionBehaviorFullScreenAuxiliary
                                       | NSWindowCollectionBehaviorStationary;

        if (overlay_mode == GC_OVERLAY_FULLSCREEN) {
            NSScreen *scr = ctrl.window.screen ?: NSScreen.mainScreen;
            if (scr) {
                [ctrl.window setFrame:scr.frame display:YES];
            }
        } else if (overlay_mode == GC_OVERLAY_MATCH_WINDOW && target_window_id != 0) {
            double x = 0, y = 0, w = 0, h = 0;
            if (gc_screen_get_window_frame(target_window_id, &x, &y, &w, &h)) {
                [ctrl.window setFrame:NSMakeRect(x, y, w, h) display:YES];
            }
            // Smart focus-aware window tracker (15 Hz):
            // 1. Sticks pixel-for-pixel to target game window as it moves/resizes
            // 2. Automatically hides when you Cmd+Tab to another app & restores when you Cmd+Tab back!
            // 3. Auto-exits Overlay Mode if the target game window closes!
            __weak GcAppController *weakCtrl = ctrl;
            ctrl.overlayTrackTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 15.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
                GcAppController *strong = weakCtrl;
                if (!strong || strong.activeOverlayMode != GC_OVERLAY_MATCH_WINDOW) {
                    [timer invalidate];
                    return;
                }
                double tx = 0, ty = 0, tw = 0, th = 0;
                if (gc_screen_get_window_frame(strong.overlayTargetWinId, &tx, &ty, &tw, &th)) {
                    strong.overlayMissingTicks = 0;
                    if (strong.overlayTargetPid > 0) {
                        pid_t frontPid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
                        pid_t myPid = NSRunningApplication.currentApplication.processIdentifier;
                        BOOL targetActive = (frontPid == (pid_t)strong.overlayTargetPid || frontPid == myPid);
                        if (!targetActive) {
                            if (strong.window.isVisible) [strong.window orderOut:nil];
                            return;
                        } else if (!strong.window.isVisible) {
                            [strong.window orderFrontRegardless];
                        }
                    }
                    NSRect targetRect = NSMakeRect(tx, ty, tw, th);
                    if (!NSEqualRects(strong.window.frame, targetRect)) {
                        [strong.window setFrame:targetRect display:YES];
                    }
                } else {
                    strong.overlayMissingTicks++;
                    if (strong.overlayMissingTicks >= 10) {
                        // Target game closed -> auto-exit overlay safely!
                        [timer invalidate];
                        [strong onToggleOverlay:nil];
                    }
                }
            }];
        }

        [ctrl.window orderFrontRegardless];

        if (target_pid > 0) {
            NSRunningApplication *targetApp = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)target_pid];
            if (targetApp) {
                [targetApp activateWithOptions:0];
            }
        }
    });
}
