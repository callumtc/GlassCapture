#import "bridge.h"

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTFrameProcessor.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencyFrameInterpolation.h>
#import <VideoToolbox/VTFrameProcessor_LowLatencySuperResolutionScaler.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <mach/mach_time.h>
#import <time.h>

// ============================================================================
// PixelBuffer & Time Helpers
// ============================================================================

void *gc_pixel_buffer_retain(void *pb) {
    if (!pb) return NULL;
    return (void *)CVPixelBufferRetain((CVPixelBufferRef)pb);
}

void gc_pixel_buffer_release(void *pb) {
    if (!pb) return;
    CVPixelBufferRelease((CVPixelBufferRef)pb);
}

uint32_t gc_pixel_buffer_width(void *pb) {
    if (!pb) return 0;
    return (uint32_t)CVPixelBufferGetWidth((CVPixelBufferRef)pb);
}

uint32_t gc_pixel_buffer_height(void *pb) {
    if (!pb) return 0;
    return (uint32_t)CVPixelBufferGetHeight((CVPixelBufferRef)pb);
}

double gc_monotonic_ms(void) {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) {
        mach_timebase_info(&tb);
    }
    uint64_t t = mach_absolute_time();
    return ((double)t * (double)tb.numer / (double)tb.denom) / 1e6;
}

float gc_pixel_buffer_luma_diff(void *pb_a, void *pb_b) {
    if (!pb_a || !pb_b) return -1.0f;
    CVPixelBufferRef a = (CVPixelBufferRef)pb_a;
    CVPixelBufferRef b = (CVPixelBufferRef)pb_b;
    size_t wa = CVPixelBufferGetWidth(a), ha = CVPixelBufferGetHeight(a);
    size_t wb = CVPixelBufferGetWidth(b), hb = CVPixelBufferGetHeight(b);
    if (wa != wb || ha != hb || wa < 64 || ha < 64) return -1.0f;

    OSType fa = CVPixelBufferGetPixelFormatType(a);
    OSType fb = CVPixelBufferGetPixelFormatType(b);
    BOOL is8a = (fa == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fa == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    BOOL is8b = (fb == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fb == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
    if (!is8a || !is8b) return -1.0f;

    if (CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return -1.0f;
    if (CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
        return -1.0f;
    }

    const uint8_t *pa = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(a, 0);
    const uint8_t *pb = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(b, 0);
    size_t sa = CVPixelBufferGetBytesPerRowOfPlane(a, 0);
    size_t sb = CVPixelBufferGetBytesPerRowOfPlane(b, 0);

    float meanDiff = -1.0f;
    if (pa && pb) {
        int sum = 0;
        size_t stepY = ha / 8;
        size_t stepX = wa / 8;
        size_t offY = stepY / 2;
        size_t offX = stepX / 2;
        for (int r = 0; r < 8; r++) {
            size_t row = offY + (size_t)r * stepY;
            const uint8_t *ra = pa + row * sa;
            const uint8_t *rb = pb + row * sb;
            for (int c = 0; c < 8; c++) {
                size_t col = offX + (size_t)c * stepX;
                int d = (int)ra[col] - (int)rb[col];
                sum += (d < 0) ? -d : d;
            }
        }
        meanDiff = (float)sum / 64.0f;
    }

    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return meanDiff;
}

void gc_format_local_timestamp(char *out_buf, size_t cap) {
    if (!out_buf || cap == 0) return;
    time_t now = time(NULL);
    struct tm lt;
    localtime_r(&now, &lt);
    strftime(out_buf, cap, "%Y-%m-%d_%H-%M-%S", &lt);
}

void *gc_create_nv12_pixel_buffer(
    uint32_t width,
    uint32_t height,
    const uint8_t *y_plane,
    size_t y_stride,
    const uint8_t *uv_plane,
    size_t uv_stride
) {
    if (width == 0 || height == 0 || !y_plane || !uv_plane) return NULL;

    NSDictionary *attrs = @{
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn cr = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        (__bridge CFDictionaryRef)attrs,
        &pb
    );
    if (cr != kCVReturnSuccess || !pb) return NULL;

    // Attach BT.709 color tags so VideoToolbox & Metal agree on colorimetry
    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    for (uint32_t row = 0; row < height; row++) {
        memcpy(dstY + row * dstYStride, y_plane + row * y_stride, width);
    }

    uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    uint32_t uvH = height / 2;
    for (uint32_t row = 0; row < uvH; row++) {
        memcpy(dstUV + row * dstUVStride, uv_plane + row * uv_stride, width);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return (void *)pb;
}

// ============================================================================
// Hardware Capability Query
// ============================================================================

void gc_hw_query_caps(GcHardwareCaps *out_caps) {
    if (!out_caps) return;
    memset(out_caps, 0, sizeof(*out_caps));
    @autoreleasepool {
        out_caps->llfi_supported = [VTLowLatencyFrameInterpolationConfiguration isSupported];
        out_caps->llsr_supported = [VTLowLatencySuperResolutionScalerConfiguration isSupported];
        out_caps->llfi_max_dim = 1920;
        out_caps->llfi_max_pixels = 1920ULL * 1080ULL;
        if (@available(macOS 27.0, *)) {
            NSInteger md = [VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1];
            NSInteger mp = [VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
            if (md > 0) out_caps->llfi_max_dim = (uint32_t)md;
            if (mp > 0) out_caps->llfi_max_pixels = (uint64_t)mp;
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (dev) {
            out_caps->metalfx_supported = [MTLFXSpatialScalerDescriptor supportsDevice:dev];
            snprintf(out_caps->gpu_name, sizeof(out_caps->gpu_name), "%s", dev.name.UTF8String ?: "Apple Silicon GPU");
        } else {
            snprintf(out_caps->gpu_name, sizeof(out_caps->gpu_name), "Unknown GPU");
        }
    }
}

// ============================================================================
// VideoToolbox Frame Processor Engine
// ============================================================================

@interface GcVtProcessor : NSObject
@property (nonatomic) GcCallbacks callbacks;
@property (nonatomic, strong) dispatch_queue_t fiQueue;
@property (nonatomic, strong) dispatch_queue_t srQueue;

// Frame Interpolation session state
@property (nonatomic, strong, nullable) VTFrameProcessor *fiProcessor;
@property (nonatomic) uint32_t fiWidth;
@property (nonatomic) uint32_t fiHeight;
@property (nonatomic) int32_t fiNumInterp; // 1 for 2x, 2 for 4x
@property (nonatomic) CVPixelBufferPoolRef fiDstPool;
@property (nonatomic) CVPixelBufferPoolRef fiConvertPool;
@property (nonatomic) VTPixelTransferSessionRef transferSession;
@property (nonatomic) uint32_t maxFiDim;
@property (nonatomic) uint64_t maxFiPixels;

// Super Resolution session state
@property (nonatomic, strong, nullable) VTFrameProcessor *srProcessor;
@property (nonatomic) uint32_t srSrcWidth;
@property (nonatomic) uint32_t srSrcHeight;
@property (nonatomic) float srScaleFactor;
@property (nonatomic) CVPixelBufferPoolRef srDstPool;
@end

@implementation GcVtProcessor

- (instancetype)initWithCallbacks:(GcCallbacks)cbs {
    self = [super init];
    if (self) {
        _callbacks = cbs;
        dispatch_queue_attr_t hiAttr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0
        );
        _fiQueue = dispatch_queue_create("com.glasscapture.vt.fi", hiAttr);
        _srQueue = dispatch_queue_create("com.glasscapture.vt.sr", hiAttr);
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &_transferSession);

        _maxFiDim = 1920;
        _maxFiPixels = 1920ULL * 1080ULL;
        if (@available(macOS 27.0, *)) {
            NSInteger md = [VTLowLatencyFrameInterpolationConfiguration maximumDimensionForSpatialScaleFactor:1];
            NSInteger mp = [VTLowLatencyFrameInterpolationConfiguration maximumPixelCountForSpatialScaleFactor:1];
            if (md > 0) _maxFiDim = (uint32_t)md;
            if (mp > 0) _maxFiPixels = (uint64_t)mp;
        }
    }
    return self;
}

- (void)dealloc {
    if (_fiProcessor) [_fiProcessor endSession];
    if (_srProcessor) [_srProcessor endSession];
    if (_fiDstPool) CVPixelBufferPoolRelease(_fiDstPool);
    if (_fiConvertPool) CVPixelBufferPoolRelease(_fiConvertPool);
    if (_srDstPool) CVPixelBufferPoolRelease(_srDstPool);
    if (_transferSession) {
        VTPixelTransferSessionInvalidate(_transferSession);
        CFRelease(_transferSession);
    }
}

- (void)computeFiTargetWidth:(uint32_t)srcW height:(uint32_t)srcH multiplier:(int32_t)multiplier outW:(uint32_t *)outW outH:(uint32_t *)outH {
    uint32_t w = srcW;
    uint32_t h = srcH;
    // Hardware-measured M3 Pro real-time budgets:
    // - 2x LLFI at 1920x1080 = ~12ms (fits 60fps -> 120fps)
    // - 4x LLFI at 1920x1080 = ~37ms (misses 30fps!), whereas 1280x720 = ~10.8ms (fits 30fps -> 120fps with 3x headroom!)
    uint32_t maxDim = (multiplier >= 4) ? (uint32_t)MIN(_maxFiDim, 1280u) : _maxFiDim;
    uint64_t maxPx  = (multiplier >= 4) ? MIN(_maxFiPixels, 1280ULL * 720ULL) : _maxFiPixels;

    double scale = 1.0;
    if (w > maxDim) scale = fmin(scale, (double)maxDim / (double)w);
    if (h > maxDim) scale = fmin(scale, (double)maxDim / (double)h);
    uint64_t px = (uint64_t)w * (uint64_t)h;
    if (px > maxPx) {
        scale = fmin(scale, sqrt((double)maxPx / (double)px));
    }
    if (scale < 1.0) {
        w = ((uint32_t)floor((double)w * scale)) & ~1u;
        h = ((uint32_t)floor((double)h * scale)) & ~1u;
    }
    if (w < 64) w = 64;
    if (h < 64) h = 64;
    *outW = w & ~1u;
    *outH = h & ~1u;
}

@end

// Clean standalone helper functions using Apple's recommended CVPixelBufferCreateResolvedAttributesDictionary
static CVPixelBufferPoolRef createPoolFromAttrs(NSDictionary *vtAttrs, uint32_t w, uint32_t h) {
    NSDictionary *appAttrs = @{
        (NSString *)kCVPixelBufferWidthKey: @(w),
        (NSString *)kCVPixelBufferHeightKey: @(h),
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
    };

    CFDictionaryRef resolved = NULL;
    if (vtAttrs) {
        NSArray *list = @[vtAttrs, appAttrs];
        CVPixelBufferCreateResolvedAttributesDictionary(
            kCFAllocatorDefault, (__bridge CFArrayRef)list, &resolved);
    }

    NSDictionary *poolAttrs = @{
        (NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @6,
        (NSString *)kCVPixelBufferPoolMaximumBufferAgeKey: @(1.0),
    };

    CVPixelBufferPoolRef pool = NULL;
    CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttrs,
        resolved ? resolved : (__bridge CFDictionaryRef)appAttrs,
        &pool
    );
    if (resolved) CFRelease(resolved);
    return pool;
}

static BOOL ensureFiSession(GcVtProcessor *self, uint32_t w, uint32_t h, int32_t numInterp) {
    if (self.fiProcessor && self.fiWidth == w && self.fiHeight == h && self.fiNumInterp == numInterp) {
        return YES;
    }
    if (self.fiProcessor) {
        [self.fiProcessor endSession];
        self.fiProcessor = nil;
    }
    if (self.fiDstPool) { CVPixelBufferPoolRelease(self.fiDstPool); self.fiDstPool = NULL; }
    if (self.fiConvertPool) { CVPixelBufferPoolRelease(self.fiConvertPool); self.fiConvertPool = NULL; }

    if (![VTLowLatencyFrameInterpolationConfiguration isSupported]) {
        return NO;
    }

    VTLowLatencyFrameInterpolationConfiguration *cfg = [[VTLowLatencyFrameInterpolationConfiguration alloc]
        initWithFrameWidth:(NSInteger)w
               frameHeight:(NSInteger)h
        numberOfInterpolatedFrames:(NSInteger)numInterp];
    if (!cfg) return NO;

    VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
    NSError *err = nil;
    if (![proc startSessionWithConfiguration:cfg error:&err]) {
        NSLog(@"[GlassCapture] VT LLFI startSession failed (%ux%u, interp=%d): %@", w, h, numInterp, err);
        return NO;
    }

    self.fiProcessor = proc;
    self.fiWidth = w;
    self.fiHeight = h;
    self.fiNumInterp = numInterp;
    self.fiDstPool = createPoolFromAttrs(cfg.destinationPixelBufferAttributes, w, h);
    self.fiConvertPool = createPoolFromAttrs(cfg.sourcePixelBufferAttributes, w, h);
    return (self.fiDstPool != NULL && self.fiConvertPool != NULL);
}

static CVPixelBufferRef ensure420vAtSize(GcVtProcessor *self, CVPixelBufferRef src, uint32_t w, uint32_t h) {
    OSType fmt = CVPixelBufferGetPixelFormatType(src);
    size_t sw = CVPixelBufferGetWidth(src);
    size_t sh = CVPixelBufferGetHeight(src);
    IOSurfaceRef surf = CVPixelBufferGetIOSurface(src);

    if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && sw == w && sh == h && surf != NULL) {
        return CVPixelBufferRetain(src);
    }
    if (!self.fiConvertPool || !self.transferSession) return NULL;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.fiConvertPool, &dst) != kCVReturnSuccess || !dst) {
        return NULL;
    }
    OSStatus st = VTPixelTransferSessionTransferImage(self.transferSession, src, dst);
    if (st != noErr) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    CVBufferPropagateAttachments(src, dst);
    return dst;
}

static BOOL ensureSrSession(GcVtProcessor *self, uint32_t w, uint32_t h, float *outScale) {
    if (![VTLowLatencySuperResolutionScalerConfiguration isSupported]) return NO;

    NSArray<NSNumber *> *factors = [VTLowLatencySuperResolutionScalerConfiguration
        supportedScaleFactorsForFrameWidth:(NSInteger)w frameHeight:(NSInteger)h];
    if (factors.count == 0) return NO;

    // Pick highest scale factor that keeps output <= 4K (prefers 2.0x or 1.5x for 720p->1080p)
    float chosen = 0.0f;
    for (NSNumber *f in factors) {
        float val = f.floatValue;
        if (val > chosen && (w * val) <= 3840.5f && (h * val) <= 2160.5f) {
            chosen = val;
        }
    }
    if (chosen <= 1.0f) return NO;
    if (outScale) *outScale = chosen;

    if (self.srProcessor && self.srSrcWidth == w && self.srSrcHeight == h && fabsf(self.srScaleFactor - chosen) < 0.01f) {
        return YES;
    }

    if (self.srProcessor) {
        [self.srProcessor endSession];
        self.srProcessor = nil;
    }
    if (self.srDstPool) { CVPixelBufferPoolRelease(self.srDstPool); self.srDstPool = NULL; }

    VTLowLatencySuperResolutionScalerConfiguration *cfg = [[VTLowLatencySuperResolutionScalerConfiguration alloc]
        initWithFrameWidth:(NSInteger)w frameHeight:(NSInteger)h scaleFactor:chosen];
    if (!cfg) return NO;

    VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
    NSError *err = nil;
    if (![proc startSessionWithConfiguration:cfg error:&err]) {
        NSLog(@"[GlassCapture] VT LLSR startSession failed (%ux%u %.1fx): %@", w, h, chosen, err);
        return NO;
    }

    uint32_t dstW = (uint32_t)lroundf((float)w * chosen);
    uint32_t dstH = (uint32_t)lroundf((float)h * chosen);
    self.srProcessor = proc;
    self.srSrcWidth = w;
    self.srSrcHeight = h;
    self.srScaleFactor = chosen;
    self.srDstPool = createPoolFromAttrs(cfg.destinationPixelBufferAttributes, dstW, dstH);
    return (self.srDstPool != NULL);
}

// ============================================================================
// C Bridge Entrypoints
// ============================================================================

void *gc_vt_create(const GcCallbacks *callbacks) {
    @autoreleasepool {
        GcVtProcessor *vt = [[GcVtProcessor alloc] initWithCallbacks:*callbacks];
        return (__bridge_retained void *)vt;
    }
}

void gc_vt_destroy(void *vt_ptr) {
    if (!vt_ptr) return;
    @autoreleasepool {
        GcVtProcessor *vt = (__bridge_transfer GcVtProcessor *)vt_ptr;
        dispatch_sync(vt.fiQueue, ^{
            if (vt.fiProcessor) { [vt.fiProcessor endSession]; vt.fiProcessor = nil; }
        });
        dispatch_sync(vt.srQueue, ^{
            if (vt.srProcessor) { [vt.srProcessor endSession]; vt.srProcessor = nil; }
        });
    }
}

bool gc_vt_submit_frame_gen(
    void *vt_ptr,
    uint64_t job_id,
    void *prev_pb_ptr,
    void *curr_pb_ptr,
    int32_t multiplier,
    bool also_ml_upscale,
    char *out_engine_label,
    size_t label_cap
) {
    if (!vt_ptr || !prev_pb_ptr || !curr_pb_ptr) return false;
    GcVtProcessor *vt = (__bridge GcVtProcessor *)vt_ptr;

    CVPixelBufferRef prevRef = CVPixelBufferRetain((CVPixelBufferRef)prev_pb_ptr);
    CVPixelBufferRef currRef = CVPixelBufferRetain((CVPixelBufferRef)curr_pb_ptr);

    uint32_t srcW = (uint32_t)CVPixelBufferGetWidth(currRef);
    uint32_t srcH = (uint32_t)CVPixelBufferGetHeight(currRef);
    uint32_t targetW = 0, targetH = 0;
    [vt computeFiTargetWidth:srcW height:srcH multiplier:multiplier outW:&targetW outH:&targetH];

    int32_t numInterp = (multiplier >= 4) ? 2 : 1;
    if (out_engine_label && label_cap > 0) {
        if (targetW < srcW || targetH < srcH) {
            snprintf(out_engine_label, label_cap, "VT Neural %dx (%up)", multiplier >= 4 ? 4 : 2, targetH);
        } else {
            snprintf(out_engine_label, label_cap, "VT Neural %dx", multiplier >= 4 ? 4 : 2);
        }
    }
    (void)also_ml_upscale;

    dispatch_async(vt.fiQueue, ^{
        @autoreleasepool {
            double t0 = gc_monotonic_ms();
            if (!ensureFiSession(vt, targetW, targetH, numInterp)) {
                CVPixelBufferRelease(prevRef);
                CVPixelBufferRelease(currRef);
                if (vt.callbacks.on_vt_result) {
                    vt.callbacks.on_vt_result(vt.callbacks.ctx, job_id, NULL, 0, 0, true, 0.0, -1);
                }
                return;
            }

            CVPixelBufferRef p0 = ensure420vAtSize(vt, prevRef, targetW, targetH);
            CVPixelBufferRef p1 = ensure420vAtSize(vt, currRef, targetW, targetH);
            CVPixelBufferRelease(prevRef);
            CVPixelBufferRelease(currRef);

            if (!p0 || !p1) {
                if (p0) CVPixelBufferRelease(p0);
                if (p1) CVPixelBufferRelease(p1);
                if (vt.callbacks.on_vt_result) {
                    vt.callbacks.on_vt_result(vt.callbacks.ctx, job_id, NULL, 0, 0, true, 0.0, -2);
                }
                return;
            }

            NSArray<NSNumber *> *phases = (numInterp == 2)
                ? @[@(0.25f), @(0.5f), @(0.75f)]
                : @[@(0.5f)];
            NSUInteger outCount = phases.count;

            NSMutableArray<VTFrameProcessorFrame *> *dstFrames = [NSMutableArray arrayWithCapacity:outCount];
            CVPixelBufferRef rawDsts[3] = {NULL, NULL, NULL};

            BOOL allocOk = YES;
            for (NSUInteger i = 0; i < outCount; i++) {
                CVPixelBufferRef d = NULL;
                if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, vt.fiDstPool, &d) != kCVReturnSuccess || !d) {
                    allocOk = NO;
                    break;
                }
                CVBufferPropagateAttachments(p1, d);
                rawDsts[i] = d;
                CMTime pts = CMTimeMake((int64_t)(job_id * 4 + i + 1), 240);
                VTFrameProcessorFrame *df = [[VTFrameProcessorFrame alloc] initWithBuffer:d presentationTimeStamp:pts];
                if (!df) { allocOk = NO; break; }
                [dstFrames addObject:df];
            }

            VTFrameProcessorFrame *f0 = [[VTFrameProcessorFrame alloc] initWithBuffer:p0 presentationTimeStamp:CMTimeMake((int64_t)(job_id * 4), 240)];
            VTFrameProcessorFrame *f1 = [[VTFrameProcessorFrame alloc] initWithBuffer:p1 presentationTimeStamp:CMTimeMake((int64_t)(job_id * 4 + 4), 240)];
            // VTFrameProcessorFrame retains p0, p1, and each rawDsts[i], so release our extra local refs now!
            CVPixelBufferRelease(p0);
            CVPixelBufferRelease(p1);
            for (NSUInteger i = 0; i < outCount; i++) {
                if (rawDsts[i]) CVPixelBufferRelease(rawDsts[i]);
            }

            if (!allocOk || !f0 || !f1) {
                if (vt.callbacks.on_vt_result) {
                    vt.callbacks.on_vt_result(vt.callbacks.ctx, job_id, NULL, 0, 0, true, 0.0, -3);
                }
                return;
            }

            VTLowLatencyFrameInterpolationParameters *params = [[VTLowLatencyFrameInterpolationParameters alloc]
                initWithSourceFrame:f1
                      previousFrame:f0
                 interpolationPhase:phases
                  destinationFrames:dstFrames];

            if (!params) {
                if (vt.callbacks.on_vt_result) {
                    vt.callbacks.on_vt_result(vt.callbacks.ctx, job_id, NULL, 0, 0, true, 0.0, -4);
                }
                return;
            }

            // Asynchronous completionHandler guarantees ALL destination frames ([0.5] or [0.25, 0.5, 0.75])
            // are 100% finished and strictly ordered before delivery (zero out-of-order/reference glitches!).
            [vt.fiProcessor processWithParameters:params completionHandler:^(id<VTFrameProcessorParameters> p, NSError *e) {
                double elapsed = gc_monotonic_ms() - t0;
                if (e) {
                    if (vt.callbacks.on_vt_result) {
                        vt.callbacks.on_vt_result(vt.callbacks.ctx, job_id, NULL, 0, 0, true, elapsed, (int32_t)e.code);
                    }
                    return;
                }
                VTLowLatencyFrameInterpolationParameters *fp = (VTLowLatencyFrameInterpolationParameters *)p;
                NSUInteger n = fp.destinationFrames.count;
                if (n > 3) n = 3;
                void *ptrs[3] = {NULL, NULL, NULL};
                for (NSUInteger k = 0; k < n; k++) {
                    ptrs[k] = (void *)fp.destinationFrames[k].buffer;
                }
                if (vt.callbacks.on_vt_result) {
                    vt.callbacks.on_vt_result(vt.callbacks.ctx, job_id, ptrs, (uint32_t)n, 0, true, elapsed, 0);
                }
            }];
        }
    });

    return true;
}

void *gc_vt_ml_upscale_sync(
    void *vt_ptr,
    void *src_pb_ptr,
    float *out_scale_factor,
    double *out_proc_ms
) {
    if (!vt_ptr || !src_pb_ptr) return NULL;
    GcVtProcessor *vt = (__bridge GcVtProcessor *)vt_ptr;
    CVPixelBufferRef src = (CVPixelBufferRef)src_pb_ptr;

    if (CVPixelBufferGetPixelFormatType(src) != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        return NULL;
    }
    if (!CVPixelBufferGetIOSurface(src)) return NULL;

    uint32_t w = (uint32_t)CVPixelBufferGetWidth(src);
    uint32_t h = (uint32_t)CVPixelBufferGetHeight(src);
    // Quick fast-path rejection before grabbing queue: LLSR max dim is 1280
    if (w > 1280 || h > 1280) return NULL;

    __block CVPixelBufferRef resultBuf = NULL;
    __block float usedScale = 1.0f;
    __block double elapsed = 0.0;

    dispatch_sync(vt.srQueue, ^{
        @autoreleasepool {
            double t0 = gc_monotonic_ms();
            float scale = 1.0f;
            if (!ensureSrSession(vt, w, h, &scale)) {
                return;
            }
            CVPixelBufferRef dst = NULL;
            if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, vt.srDstPool, &dst) != kCVReturnSuccess || !dst) {
                return;
            }
            CVBufferPropagateAttachments(src, dst);

            VTFrameProcessorFrame *sf = [[VTFrameProcessorFrame alloc] initWithBuffer:src presentationTimeStamp:kCMTimeZero];
            VTFrameProcessorFrame *df = [[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:kCMTimeZero];
            if (!sf || !df) {
                CVPixelBufferRelease(dst);
                return;
            }
            VTLowLatencySuperResolutionScalerParameters *params = [[VTLowLatencySuperResolutionScalerParameters alloc]
                initWithSourceFrame:sf destinationFrame:df];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block NSError *err = nil;
            [vt.srProcessor processWithParameters:params completionHandler:^(id<VTFrameProcessorParameters> p, NSError *e) {
                (void)p;
                err = e;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

            elapsed = gc_monotonic_ms() - t0;
            if (!err) {
                resultBuf = dst; // retained for caller
                usedScale = scale;
            } else {
                CVPixelBufferRelease(dst);
            }
        }
    });

    if (out_scale_factor) *out_scale_factor = usedScale;
    if (out_proc_ms) *out_proc_ms = elapsed;
    return (void *)resultBuf;
}
