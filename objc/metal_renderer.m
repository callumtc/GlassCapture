#import "bridge.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <simd/simd.h>
#import <stdatomic.h>

static NSString *const kGlassCaptureMetalSource = @R"(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct PresentUniforms {
    float2 scale;       // NDC scale for aspect ratio / integer lock
    float  sharpness;   // 0.0 .. 1.0 CAS sharpening strength
    uint   flags;       // bit0: nearest, bit1: fullRange, bit2: CAS, bit3: hdrOut, bit4: inLinear, bit5: inPQ, bit6: inHLG
    float2 texSize;     // source texture width, height
    float  edrHeadroom; // display EDR headroom (>= 1.0)
    float  _pad;
};

vertex VertexOut gc_quad_vs(uint vid [[vertex_id]], constant PresentUniforms &u [[buffer(0)]]) {
    const float2 pos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = float4(pos[vid] * u.scale, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

// BT.709 YCbCr -> RGB
inline float3 ycbcr709_to_rgb(float y, float2 cbcr, bool fullRange) {
    float yAdj = fullRange ? y : (y - (16.0 / 255.0)) * (255.0 / 219.0);
    float2 uv = fullRange ? (cbcr - 0.5) : (cbcr - (128.0 / 255.0)) * (255.0 / 224.0);
    float r = yAdj + 1.5748 * uv.y;
    float g = yAdj - 0.187324 * uv.x - 0.468124 * uv.y;
    float b = yAdj + 1.8556 * uv.x;
    return saturate(float3(r, g, b));
}

// BT.2020 YCbCr (10-bit normalized) -> BT.2020 non-linear RGB
inline float3 ycbcr2020_to_rgb(float y, float2 cbcr, bool fullRange) {
    float yAdj = fullRange ? y : (y - (64.0 / 1023.0)) * (1023.0 / 876.0);
    float2 uv = fullRange ? (cbcr - 0.5) : (cbcr - (512.0 / 1023.0)) * (1023.0 / 896.0);
    float r = yAdj + 1.4746 * uv.y;
    float g = yAdj - 0.164553 * uv.x - 0.571353 * uv.y;
    float b = yAdj + 1.8814 * uv.x;
    return saturate(float3(r, g, b));
}

// Exact sRGB EOTF (perceptual -> linear)
inline float3 srgb_to_linear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow(max((c + 0.055) / 1.055, 0.0), 2.4);
    return select(hi, lo, c <= 0.04045);
}

// SMPTE ST 2084 PQ EOTF -> linear EDR (where 1.0 = 203 nits SDR reference white)
inline float3 pq_to_linear_edr(float3 pq) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = (2523.0 / 4096.0) * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = (2413.0 / 4096.0) * 32.0;
    const float c3 = (2392.0 / 4096.0) * 32.0;
    float3 p = pow(max(pq, 0.0), 1.0 / m2);
    float3 num = max(p - c1, 0.0);
    float3 den = max(c2 - c3 * p, 1e-6);
    float3 nits = pow(num / den, 1.0 / m1) * 10000.0;
    return nits / 203.0;
}

// ARIB STD-B67 HLG EOTF -> linear EDR
inline float3 hlg_to_linear_edr(float3 hlg, float headroom) {
    const float a = 0.17883277;
    const float b = 0.28466892;
    const float c = 0.55991073;
    float3 lo = (hlg * hlg) / 3.0;
    float3 hi = (exp((hlg - c) / a) + b) / 12.0;
    float3 lin = select(hi, lo, hlg <= 0.5);
    return lin * max(headroom, 1.5);
}

// BT.2020 linear -> Extended Linear sRGB/Rec.709 (preserves wide gamut via negative/extended values)
inline float3 bt2020_to_ext_srgb(float3 c) {
    return float3(
         1.6604910 * c.r - 0.5876411 * c.g - 0.0728499 * c.b,
        -0.1245505 * c.r + 1.1328999 * c.g - 0.0083494 * c.b,
        -0.0181508 * c.r - 0.1005789 * c.g + 1.1187297 * c.b
    );
}

// Smooth inverse tone-map for SDR sources when HDR/XDR Passthrough is enabled on an EDR display
inline float3 expand_sdr_to_edr(float3 sdrPerceptual, float headroom) {
    float3 lin = srgb_to_linear(saturate(sdrPerceptual));
    if (headroom <= 1.05) return lin;
    float targetPeak = min(headroom, 2.25);
    float luma = dot(lin, float3(0.2126, 0.7152, 0.0722));
    // Keep shadows & midtones 100% faithful; smoothly expand bright specular highlights into XDR headroom
    float t = smoothstep(0.55, 1.0, luma);
    float boost = mix(1.0, targetPeak, t * t);
    return lin * boost;
}

inline float3 finalize_color_output(float3 rgb, uint flags, float headroom) {
    bool hdrOut = (flags & 8u) != 0u;
    bool inLinear = (flags & 16u) != 0u;
    bool inPQ = (flags & 32u) != 0u;
    bool inHLG = (flags & 64u) != 0u;

    if (!hdrOut) {
        if (inLinear) {
            // Simple Reinhard tone-map to SDR if linear HDR arrives while HDR output is off
            float3 mapped = rgb / (1.0 + max(rgb, 0.0));
            return pow(saturate(mapped), 1.0 / 2.2);
        }
        return saturate(rgb);
    }

    if (inLinear) {
        return max(rgb, -0.5);
    }
    if (inPQ) {
        float3 lin2020 = pq_to_linear_edr(rgb);
        float3 ext = bt2020_to_ext_srgb(lin2020);
        return min(ext, float3(max(headroom, 1.0)));
    }
    if (inHLG) {
        float3 lin2020 = hlg_to_linear_edr(rgb, headroom);
        float3 ext = bt2020_to_ext_srgb(lin2020);
        return min(ext, float3(max(headroom, 1.0)));
    }
    return expand_sdr_to_edr(rgb, headroom);
}

struct ConvertParams {
    uint flags;
    float headroom;
};

kernel void gc_nv12_to_rgba_cs(
    texture2d<float, access::read>   yTex   [[texture(0)]],
    texture2d<float, access::sample> uvTex  [[texture(1)]],
    texture2d<float, access::write>  dstTex [[texture(2)]],
    constant ConvertParams &cp              [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= dstTex.get_width() || gid.y >= dstTex.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float y = yTex.read(gid).r;
    float2 uvCoord = (float2(gid) + 0.5) / float2(dstTex.get_width(), dstTex.get_height());
    float2 cbcr = uvTex.sample(s, uvCoord).rg;

    bool fullRange = (cp.flags & 2u) != 0u;
    bool is2020 = ((cp.flags & 32u) != 0u) || ((cp.flags & 64u) != 0u);
    float3 rgb = is2020 ? ycbcr2020_to_rgb(y, cbcr, fullRange) : ycbcr709_to_rgb(y, cbcr, fullRange);
    float3 outRgb = finalize_color_output(rgb, cp.flags, cp.headroom);
    dstTex.write(float4(outRgb, 1.0), gid);
}

inline float3 apply_cas_rgb(texture2d<float> tex, sampler s, float2 uv, float2 invSize, float strength) {
    float3 c  = tex.sample(s, uv).rgb;
    float3 n  = tex.sample(s, uv + float2(0.0, -invSize.y)).rgb;
    float3 so = tex.sample(s, uv + float2(0.0,  invSize.y)).rgb;
    float3 w  = tex.sample(s, uv + float2(-invSize.x, 0.0)).rgb;
    float3 e  = tex.sample(s, uv + float2( invSize.x, 0.0)).rgb;

    float3 mn = min(c, min(min(n, so), min(w, e)));
    float3 mx = max(c, max(max(n, so), max(w, e)));
    float3 amp = saturate(min(max(mn, 0.0), max(1.0 - mx, 0.0)) / max(mx, float3(1e-4)));
    amp = sqrt(amp);
    float peak = -1.0 / mix(8.0, 5.0, strength);
    float3 weight = amp * peak;
    return (c + (n + so + w + e) * weight) / (1.0 + 4.0 * weight);
}

fragment float4 gc_present_rgba_fs(
    VertexOut in [[stage_in]],
    texture2d<float> colorTex [[texture(0)]],
    constant PresentUniforms &u [[buffer(0)]]
) {
    constexpr sampler sLinear(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler sNearest(coord::normalized, filter::nearest, address::clamp_to_edge);

    float3 rgb;
    if ((u.flags & 1u) != 0u) {
        rgb = colorTex.sample(sNearest, in.uv).rgb;
    } else if ((u.flags & 4u) != 0u && u.sharpness > 0.01) {
        float2 inv = 1.0 / max(u.texSize, float2(1.0));
        rgb = apply_cas_rgb(colorTex, sLinear, in.uv, inv, u.sharpness);
    } else {
        rgb = colorTex.sample(sLinear, in.uv).rgb;
    }
    return float4(finalize_color_output(rgb, u.flags, u.edrHeadroom), 1.0);
}

fragment float4 gc_present_nv12_fs(
    VertexOut in [[stage_in]],
    texture2d<float> yTex  [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]],
    constant PresentUniforms &u [[buffer(0)]]
) {
    constexpr sampler sLinear(coord::normalized, filter::linear, address::clamp_to_edge);
    constexpr sampler sNearest(coord::normalized, filter::nearest, address::clamp_to_edge);
    bool nearest = (u.flags & 1u) != 0u;
    bool fullRange = (u.flags & 2u) != 0u;
    bool useCas = (u.flags & 4u) != 0u && u.sharpness > 0.01;
    bool is2020 = ((u.flags & 32u) != 0u) || ((u.flags & 64u) != 0u);

    float y;
    float2 cbcr;
    if (nearest) {
        y = yTex.sample(sNearest, in.uv).r;
        cbcr = uvTex.sample(sNearest, in.uv).rg;
    } else {
        cbcr = uvTex.sample(sLinear, in.uv).rg;
        y = yTex.sample(sLinear, in.uv).r;
        if (useCas) {
            float2 inv = 1.0 / max(u.texSize, float2(1.0));
            float yn = yTex.sample(sLinear, in.uv + float2(0.0, -inv.y)).r;
            float ys = yTex.sample(sLinear, in.uv + float2(0.0,  inv.y)).r;
            float yw = yTex.sample(sLinear, in.uv + float2(-inv.x, 0.0)).r;
            float ye = yTex.sample(sLinear, in.uv + float2( inv.x, 0.0)).r;
            float mn = min(y, min(min(yn, ys), min(yw, ye)));
            float mx = max(y, max(max(yn, ys), max(yw, ye)));
            float amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
            float peak = -1.0 / mix(8.0, 5.0, u.sharpness);
            float w = amp * peak;
            y = saturate((y + (yn + ys + yw + ye) * w) / (1.0 + 4.0 * w));
        }
    }

    float3 rgb = is2020 ? ycbcr2020_to_rgb(y, cbcr, fullRange) : ycbcr709_to_rgb(y, cbcr, fullRange);
    return float4(finalize_color_output(rgb, u.flags, u.edrHeadroom), 1.0);
}
)";

typedef struct {
    simd_float2 scale;
    float       sharpness;
    uint32_t    flags;
    simd_float2 texSize;
    float       edrHeadroom;
    float       _pad;
} PresentUniforms;

typedef struct {
    uint32_t flags;
    float    headroom;
} ConvertParams;

@interface GcMetalRenderer : NSObject {
@public
    _Atomic double _lastHardwareGpuMs;
}
@property (nonatomic) GcCallbacks callbacks;
@property (nonatomic, weak) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLComputePipelineState> nv12ToRgbaPSO;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentRgbaSdrPSO;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentNv12SdrPSO;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentRgbaHdrPSO;
@property (nonatomic, strong) id<MTLRenderPipelineState> presentNv12HdrPSO;
@property (nonatomic) CVMetalTextureCacheRef textureCache;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic) BOOL layerIsHdr;
@property (nonatomic) CGColorSpaceRef sdrColorSpace;
@property (nonatomic) CGColorSpaceRef hdrColorSpace;

// MetalFX Spatial Scaler cache
@property (nonatomic, strong, nullable) id<MTLFXSpatialScaler> spatialScaler;
@property (nonatomic, strong, nullable) id<MTLTexture> fxInputTex;
@property (nonatomic, strong, nullable) id<MTLTexture> fxOutputTex;
@property (nonatomic) NSUInteger fxInW;
@property (nonatomic) NSUInteger fxInH;
@property (nonatomic) NSUInteger fxOutW;
@property (nonatomic) NSUInteger fxOutH;
@property (nonatomic) BOOL fxIsHdr;

// Display link for ProMotion pacing
@property (nonatomic) CVDisplayLinkRef displayLink;
@property (nonatomic, strong) dispatch_semaphore_t renderBusySem;
@property (nonatomic, strong) MTLRenderPassDescriptor *reusableRPD;
@property (nonatomic) uint64_t frameCounter;
@end

static CVReturn displayLinkCallback(
    CVDisplayLinkRef displayLink,
    const CVTimeStamp *inNow,
    const CVTimeStamp *inOutputTime,
    CVOptionFlags flagsIn,
    CVOptionFlags *flagsOut,
    void *displayLinkContext
) {
    (void)displayLink; (void)inNow; (void)inOutputTime; (void)flagsIn; (void)flagsOut;
    GcMetalRenderer *r = (__bridge GcMetalRenderer *)displayLinkContext;
    if (r && r.callbacks.on_display_tick) {
        r.callbacks.on_display_tick(r.callbacks.ctx, gc_monotonic_ms());
    }
    return kCVReturnSuccess;
}

@implementation GcMetalRenderer

- (instancetype)initWithLayer:(CAMetalLayer *)layer callbacks:(GcCallbacks)cbs {
    self = [super init];
    if (self) {
        _callbacks = cbs;
        _metalLayer = layer;
        _device = MTLCreateSystemDefaultDevice();
        _commandQueue = [_device newCommandQueue];
        _renderBusySem = dispatch_semaphore_create(1);
        _reusableRPD = [MTLRenderPassDescriptor renderPassDescriptor];
        _reusableRPD.colorAttachments[0].loadAction = MTLLoadActionClear;
        _reusableRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
        _reusableRPD.colorAttachments[0].clearColor = MTLClearColorMake(0.02, 0.02, 0.03, 1.0);
        atomic_store(&_lastHardwareGpuMs, 0.0);

        _sdrColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        _hdrColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);

        layer.device = _device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.colorspace = _sdrColorSpace;
        layer.wantsExtendedDynamicRangeContent = NO;
        layer.framebufferOnly = YES;
        layer.maximumDrawableCount = 3;
        layer.displaySyncEnabled = YES;
        _layerIsHdr = NO;

        CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache);
        _ciContext = [CIContext contextWithMTLDevice:_device];

        NSError *err = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        id<MTLLibrary> lib = [_device newLibraryWithSource:kGlassCaptureMetalSource options:opts error:&err];
        if (!lib) {
            NSLog(@"[GlassCapture] Metal shader compile failed: %@", err);
        } else {
            id<MTLFunction> csFn = [lib newFunctionWithName:@"gc_nv12_to_rgba_cs"];
            _nv12ToRgbaPSO = [_device newComputePipelineStateWithFunction:csFn error:&err];

            MTLRenderPipelineDescriptor *rp = [[MTLRenderPipelineDescriptor alloc] init];
            rp.vertexFunction = [lib newFunctionWithName:@"gc_quad_vs"];

            // SDR (BGRA8Unorm) pipelines
            rp.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            rp.fragmentFunction = [lib newFunctionWithName:@"gc_present_rgba_fs"];
            _presentRgbaSdrPSO = [_device newRenderPipelineStateWithDescriptor:rp error:&err];
            rp.fragmentFunction = [lib newFunctionWithName:@"gc_present_nv12_fs"];
            _presentNv12SdrPSO = [_device newRenderPipelineStateWithDescriptor:rp error:&err];

            // HDR / EDR (RGBA16Float) pipelines
            rp.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
            rp.fragmentFunction = [lib newFunctionWithName:@"gc_present_rgba_fs"];
            _presentRgbaHdrPSO = [_device newRenderPipelineStateWithDescriptor:rp error:&err];
            rp.fragmentFunction = [lib newFunctionWithName:@"gc_present_nv12_fs"];
            _presentNv12HdrPSO = [_device newRenderPipelineStateWithDescriptor:rp error:&err];
        }

        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink);
        if (_displayLink) {
            CVDisplayLinkSetOutputCallback(_displayLink, displayLinkCallback, (__bridge void *)self);
            CVDisplayLinkStart(_displayLink);
        }
        #pragma clang diagnostic pop
    }
    return self;
}

- (void)stopDisplayLink {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (_displayLink) {
        CVDisplayLinkStop(_displayLink);
        CVDisplayLinkRelease(_displayLink);
        _displayLink = NULL;
    }
    #pragma clang diagnostic pop
}

- (void)dealloc {
    [self stopDisplayLink];
    if (_textureCache) { CFRelease(_textureCache); _textureCache = NULL; }
    if (_sdrColorSpace) { CGColorSpaceRelease(_sdrColorSpace); _sdrColorSpace = NULL; }
    if (_hdrColorSpace) { CGColorSpaceRelease(_hdrColorSpace); _hdrColorSpace = NULL; }
}

- (void)ensureLayerHdr:(BOOL)wantHdr {
    if (_layerIsHdr == wantHdr) return;
    CAMetalLayer *layer = _metalLayer;
    if (!layer) return;
    _layerIsHdr = wantHdr;
    if (wantHdr) {
        layer.pixelFormat = MTLPixelFormatRGBA16Float;
        layer.colorspace = _hdrColorSpace;
        layer.wantsExtendedDynamicRangeContent = YES;
    } else {
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.colorspace = _sdrColorSpace;
        layer.wantsExtendedDynamicRangeContent = NO;
    }
}

- (BOOL)ensureMetalFXInW:(NSUInteger)inW inH:(NSUInteger)inH outW:(NSUInteger)outW outH:(NSUInteger)outH hdr:(BOOL)isHdr {
    if (![MTLFXSpatialScalerDescriptor supportsDevice:_device]) return NO;
    if (outW < inW) outW = inW;
    if (outH < inH) outH = inH;
    if (outW > 3840) {
        double ratio = 3840.0 / (double)outW;
        outW = 3840;
        outH = (NSUInteger)fmax((double)inH, round((double)outH * ratio));
    }
    if (outH > 2160) {
        double ratio = 2160.0 / (double)outH;
        outH = 2160;
        outW = (NSUInteger)fmax((double)inW, round((double)outW * ratio));
    }

    if (_spatialScaler && _fxInW == inW && _fxInH == inH && _fxOutW == outW && _fxOutH == outH && _fxIsHdr == isHdr) {
        return YES;
    }

    MTLPixelFormat pixFmt = isHdr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    MTLFXSpatialScalerDescriptor *desc = [[MTLFXSpatialScalerDescriptor alloc] init];
    desc.inputWidth = inW;
    desc.inputHeight = inH;
    desc.outputWidth = outW;
    desc.outputHeight = outH;
    desc.colorTextureFormat = pixFmt;
    desc.outputTextureFormat = pixFmt;
    desc.colorProcessingMode = isHdr
        ? MTLFXSpatialScalerColorProcessingModeHDR
        : MTLFXSpatialScalerColorProcessingModePerceptual;

    id<MTLFXSpatialScaler> scaler = [desc newSpatialScalerWithDevice:_device];
    if (!scaler) return NO;

    MTLTextureDescriptor *inDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixFmt
                                                                                      width:inW
                                                                                     height:inH
                                                                                  mipmapped:NO];
    inDesc.storageMode = MTLStorageModePrivate;
    inDesc.usage = scaler.colorTextureUsage | MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;

    MTLTextureDescriptor *outDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixFmt
                                                                                       width:outW
                                                                                      height:outH
                                                                                   mipmapped:NO];
    outDesc.storageMode = MTLStorageModePrivate;
    outDesc.usage = scaler.outputTextureUsage | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

    id<MTLTexture> inTex = [_device newTextureWithDescriptor:inDesc];
    id<MTLTexture> outTex = [_device newTextureWithDescriptor:outDesc];
    if (!inTex || !outTex) return NO;

    _spatialScaler = scaler;
    _fxInputTex = inTex;
    _fxOutputTex = outTex;
    _fxInW = inW;
    _fxInH = inH;
    _fxOutW = outW;
    _fxOutH = outH;
    _fxIsHdr = isHdr;
    return YES;
}

@end

static simd_float2 computeAspectScale(
    uint32_t srcW, uint32_t srcH,
    uint32_t dstW, uint32_t dstH,
    int32_t aspectMode,
    bool integerLock
) {
    if (srcW == 0 || srcH == 0 || dstW == 0 || dstH == 0) {
        return simd_make_float2(1.0f, 1.0f);
    }

    if (integerLock) {
        uint32_t multX = dstW / srcW;
        uint32_t multY = dstH / srcH;
        uint32_t mult = multX < multY ? multX : multY;
        if (mult >= 1) {
            float sx = (float)(srcW * mult) / (float)dstW;
            float sy = (float)(srcH * mult) / (float)dstH;
            return simd_make_float2(sx, sy);
        }
    }

    float targetAspect = (float)srcW / (float)srcH;
    if (aspectMode == GC_ASPECT_16_9) targetAspect = 16.0f / 9.0f;
    else if (aspectMode == GC_ASPECT_4_3) targetAspect = 4.0f / 3.0f;
    else if (aspectMode == GC_ASPECT_STRETCH) return simd_make_float2(1.0f, 1.0f);

    float viewAspect = (float)dstW / (float)dstH;
    if (aspectMode == GC_ASPECT_FILL) {
        if (viewAspect > targetAspect) {
            return simd_make_float2(1.0f, viewAspect / targetAspect);
        } else {
            return simd_make_float2(targetAspect / viewAspect, 1.0f);
        }
    } else {
        if (viewAspect > targetAspect) {
            return simd_make_float2(targetAspect / viewAspect, 1.0f);
        } else {
            return simd_make_float2(1.0f, viewAspect / targetAspect);
        }
    }
}

void *gc_renderer_create(void *ca_metal_layer, const GcCallbacks *callbacks) {
    @autoreleasepool {
        CAMetalLayer *layer = (__bridge CAMetalLayer *)ca_metal_layer;
        GcMetalRenderer *r = [[GcMetalRenderer alloc] initWithLayer:layer callbacks:*callbacks];
        return (__bridge_retained void *)r;
    }
}

void gc_renderer_destroy(void *renderer_ptr) {
    if (!renderer_ptr) return;
    @autoreleasepool {
        GcMetalRenderer *r = (__bridge_transfer GcMetalRenderer *)renderer_ptr;
        [r stopDisplayLink];
    }
}

void gc_renderer_present(
    void *renderer_ptr,
    void *cv_pixel_buffer,
    const GcRenderParams *params,
    uint32_t *out_drawable_w,
    uint32_t *out_drawable_h,
    double *out_gpu_ms,
    char *out_up_engine,
    size_t out_up_engine_cap,
    bool *out_hdr_active,
    bool *out_hdr_source_10bit,
    float *out_edr_headroom,
    char *out_hdr_tag,
    size_t out_hdr_tag_cap
) {
    if (!renderer_ptr || !cv_pixel_buffer || !params) return;
    GcMetalRenderer *r = (__bridge GcMetalRenderer *)renderer_ptr;

    if (dispatch_semaphore_wait(r.renderBusySem, DISPATCH_TIME_NOW) != 0) {
        return;
    }

    CVPixelBufferRef pb = (CVPixelBufferRef)cv_pixel_buffer;
    CVPixelBufferRetain(pb);
    GcRenderParams p = *params;

    uint32_t dwOut = 0;
    uint32_t dhOut = 0;
    double gpuMs = atomic_load_explicit(&r->_lastHardwareGpuMs, memory_order_relaxed);
    char engineStorage[64] = {0};
    char hdrTagStorage[32] = {0};
    bool hdrActive = false;
    bool hdrSource10 = false;
    float headroom = 1.0f;

    @autoreleasepool {
        double t0 = gc_monotonic_ms();
        CAMetalLayer *layer = r.metalLayer;
        if (!layer || !r.commandQueue || !r.presentNv12SdrPSO || !r.presentRgbaSdrPSO) goto cleanup;

        // Query live macOS display EDR headroom (e.g. 2.0-8.0 on Liquid Retina XDR, 1.0 on SDR monitor)
        NSScreen *scr = NSScreen.mainScreen;
        if (scr) {
            headroom = (float)scr.maximumExtendedDynamicRangeColorComponentValue;
            if (headroom < 1.0f) headroom = 1.0f;
        }

        BOOL wantHdr = p.hdr_enabled ? YES : NO;
        [r ensureLayerHdr:wantHdr];
        hdrActive = wantHdr;

        CGSize drawSize = layer.drawableSize;
        uint32_t dstW = (uint32_t)drawSize.width;
        uint32_t dstH = (uint32_t)drawSize.height;
        if (dstW < 2 || dstH < 2) goto cleanup;
        dwOut = dstW;
        dhOut = dstH;

        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) goto cleanup;

        uint32_t srcW = (uint32_t)CVPixelBufferGetWidth(pb);
        uint32_t srcH = (uint32_t)CVPixelBufferGetHeight(pb);
        OSType fmt = CVPixelBufferGetPixelFormatType(pb);

        BOOL isBiPlanar8 = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                            fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
        BOOL isBiPlanar10 = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                             fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);
        BOOL isBiPlanar = isBiPlanar8 || isBiPlanar10;
        BOOL fullRange = (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                          fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange);
        BOOL isRgba16F = (fmt == kCVPixelFormatType_64RGBAHalf);

        // Inspect transfer function attachment for PQ / HLG / Linear HDR metadata
        CFTypeRef tf = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, NULL);
        BOOL isPQ = (tf && CFEqual(tf, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ));
        BOOL isHLG = (tf && CFEqual(tf, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
        BOOL isLinearIn = isRgba16F || (tf && CFEqual(tf, kCVImageBufferTransferFunction_Linear));
        if (tf) CFRelease(tf);

        hdrSource10 = isBiPlanar10 || isRgba16F || isPQ || isHLG;

        if (wantHdr) {
            if (isPQ) {
                snprintf(hdrTagStorage, sizeof(hdrTagStorage), "HDR10 · PQ");
            } else if (isHLG) {
                snprintf(hdrTagStorage, sizeof(hdrTagStorage), "HDR · HLG");
            } else if (isRgba16F) {
                snprintf(hdrTagStorage, sizeof(hdrTagStorage), "HDR · XDR");
            } else if (isBiPlanar10) {
                snprintf(hdrTagStorage, sizeof(hdrTagStorage), "HDR10");
            } else if (headroom > 1.05f) {
                snprintf(hdrTagStorage, sizeof(hdrTagStorage), "HDR · EDR %.1fx", headroom);
            } else {
                snprintf(hdrTagStorage, sizeof(hdrTagStorage), "HDR");
            }
        }

        id<MTLCommandBuffer> cmd = [r.commandQueue commandBuffer];

        CVMetalTextureRef yTexRef = NULL;
        CVMetalTextureRef uvTexRef = NULL;
        CVMetalTextureRef rgbTexRef = NULL;
        id<MTLTexture> yTex = nil;
        id<MTLTexture> uvTex = nil;
        id<MTLTexture> rgbTex = nil;

        if (isBiPlanar) {
            MTLPixelFormat yFmt = isBiPlanar10 ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm;
            MTLPixelFormat uvFmt = isBiPlanar10 ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm;
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, r.textureCache, pb, NULL, yFmt, srcW, srcH, 0, &yTexRef);
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, r.textureCache, pb, NULL, uvFmt, srcW / 2, srcH / 2, 1, &uvTexRef);
            if (yTexRef) yTex = CVMetalTextureGetTexture(yTexRef);
            if (uvTexRef) uvTex = CVMetalTextureGetTexture(uvTexRef);
        } else {
            MTLPixelFormat singleFmt = isRgba16F ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, r.textureCache, pb, NULL, singleFmt, srcW, srcH, 0, &rgbTexRef);
            if (rgbTexRef) rgbTex = CVMetalTextureGetTexture(rgbTexRef);
        }

        uint32_t baseFlags = 0;
        if (p.upscale_mode == GC_UPSCALE_INTEGER) baseFlags |= 1u;
        if (fullRange) baseFlags |= 2u;
        if (wantHdr) baseFlags |= 8u;
        if (isLinearIn) baseFlags |= 16u;
        if (isPQ) baseFlags |= 32u;
        if (isHLG) baseFlags |= 64u;

        BOOL wantMetalFX = (p.upscale_mode == GC_UPSCALE_METALFX || p.upscale_mode == GC_UPSCALE_AUTO_ML);
        simd_float2 ndcScale = computeAspectScale(srcW, srcH, dstW, dstH, p.aspect_mode, p.integer_lock);
        NSUInteger targetW = (NSUInteger)fmax((double)srcW, round((double)dstW * fabs((double)ndcScale.x)));
        NSUInteger targetH = (NSUInteger)fmax((double)srcH, round((double)dstH * fabs((double)ndcScale.y)));

        BOOL usedMetalFX = NO;
        if (wantMetalFX && (yTex || rgbTex) && (targetW > srcW || targetH > srcH)) {
            if ([r ensureMetalFXInW:srcW inH:srcH outW:targetW outH:targetH hdr:wantHdr]) {
                if (isBiPlanar && yTex && uvTex && r.nv12ToRgbaPSO) {
                    id<MTLComputeCommandEncoder> ce = [cmd computeCommandEncoder];
                    [ce setComputePipelineState:r.nv12ToRgbaPSO];
                    [ce setTexture:yTex atIndex:0];
                    [ce setTexture:uvTex atIndex:1];
                    [ce setTexture:r.fxInputTex atIndex:2];
                    ConvertParams cp = { baseFlags, headroom };
                    [ce setBytes:&cp length:sizeof(cp) atIndex:0];
                    MTLSize tg = MTLSizeMake(16, 16, 1);
                    MTLSize grid = MTLSizeMake((srcW + 15) / 16, (srcH + 15) / 16, 1);
                    [ce dispatchThreadgroups:grid threadsPerThreadgroup:tg];
                    [ce endEncoding];
                    r.spatialScaler.colorTexture = r.fxInputTex;
                    usedMetalFX = YES;
                } else if (rgbTex && rgbTex.pixelFormat == r.fxInputTex.pixelFormat) {
                    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
                    [blit copyFromTexture:rgbTex
                              sourceSlice:0 sourceLevel:0
                             sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(srcW, srcH, 1)
                                toTexture:r.fxInputTex
                         destinationSlice:0 destinationLevel:0
                        destinationOrigin:MTLOriginMake(0, 0, 0)];
                    [blit endEncoding];
                    r.spatialScaler.colorTexture = r.fxInputTex;
                    usedMetalFX = YES;
                }

                if (usedMetalFX) {
                    r.spatialScaler.inputContentWidth = srcW;
                    r.spatialScaler.inputContentHeight = srcH;
                    r.spatialScaler.outputTexture = r.fxOutputTex;
                    [r.spatialScaler encodeToCommandBuffer:cmd];
                    snprintf(engineStorage, sizeof(engineStorage),
                             wantHdr ? "MetalFX HDR (%lux%lu)" : "MetalFX (%lux%lu)",
                             (unsigned long)r.fxOutW, (unsigned long)r.fxOutH);
                }
            }
        }

        if (!usedMetalFX) {
            switch (p.upscale_mode) {
                case GC_UPSCALE_OFF:       snprintf(engineStorage, sizeof(engineStorage), "Native Zero-Copy"); break;
                case GC_UPSCALE_METALFX:   snprintf(engineStorage, sizeof(engineStorage), "MetalFX (1:1)"); break;
                case GC_UPSCALE_AUTO_ML:   snprintf(engineStorage, sizeof(engineStorage), "Auto ML / MetalFX"); break;
                case GC_UPSCALE_SHARP_CAS: snprintf(engineStorage, sizeof(engineStorage), "Metal CAS Sharp"); break;
                case GC_UPSCALE_INTEGER:   snprintf(engineStorage, sizeof(engineStorage), "Pixel Integer"); break;
                default:                   snprintf(engineStorage, sizeof(engineStorage), "Native"); break;
            }
        }

        id<MTLRenderPipelineState> rgbaPSO = wantHdr ? r.presentRgbaHdrPSO : r.presentRgbaSdrPSO;
        id<MTLRenderPipelineState> nv12PSO = wantHdr ? r.presentNv12HdrPSO : r.presentNv12SdrPSO;

        MTLRenderPassDescriptor *rpd = r.reusableRPD;
        rpd.colorAttachments[0].texture = drawable.texture;

        id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
        PresentUniforms u;
        u.scale = ndcScale;
        u.sharpness = p.sharpness;
        u.edrHeadroom = headroom;
        u._pad = 0.0f;

        if (usedMetalFX) {
            // MetalFX output is already finalized into target SDR or Extended Linear HDR space!
            u.flags = (wantHdr ? (8u | 16u) : 0u);
            if (p.sharpness > 0.05f) u.flags |= 4u;
            u.texSize = simd_make_float2((float)r.fxOutW, (float)r.fxOutH);
            [enc setRenderPipelineState:rgbaPSO];
            [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
            [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [enc setFragmentTexture:r.fxOutputTex atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        } else if (isBiPlanar && yTex && uvTex) {
            u.flags = baseFlags;
            if (p.upscale_mode == GC_UPSCALE_SHARP_CAS) u.flags |= 4u;
            u.texSize = simd_make_float2((float)srcW, (float)srcH);
            [enc setRenderPipelineState:nv12PSO];
            [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
            [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [enc setFragmentTexture:yTex atIndex:0];
            [enc setFragmentTexture:uvTex atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        } else if (rgbTex) {
            u.flags = baseFlags;
            if (p.upscale_mode == GC_UPSCALE_SHARP_CAS) u.flags |= 4u;
            u.texSize = simd_make_float2((float)srcW, (float)srcH);
            [enc setRenderPipelineState:rgbaPSO];
            [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
            [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
            [enc setFragmentTexture:rgbTex atIndex:0];
            [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }

        [enc endEncoding];
        rpd.colorAttachments[0].texture = nil;

        CVPixelBufferRef retainedPb = CVPixelBufferRetain(pb);
        __weak GcMetalRenderer *weakR = r;
        [cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            if (cb.GPUEndTime > cb.GPUStartTime) {
                double hwMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
                GcMetalRenderer *strongR = weakR;
                if (strongR) {
                    atomic_store_explicit(&strongR->_lastHardwareGpuMs, hwMs, memory_order_relaxed);
                }
            }
            if (yTexRef) CFRelease(yTexRef);
            if (uvTexRef) CFRelease(uvTexRef);
            if (rgbTexRef) CFRelease(rgbTexRef);
            CVPixelBufferRelease(retainedPb);
        }];

        [cmd presentDrawable:drawable];
        [cmd commit];

        if (gpuMs <= 0.001) {
            gpuMs = gc_monotonic_ms() - t0;
        }

        r.frameCounter++;
        if ((r.frameCounter % 120) == 0 && r.textureCache) {
            CVMetalTextureCacheFlush(r.textureCache, 0);
        }
    }

cleanup:
    CVPixelBufferRelease(pb);
    dispatch_semaphore_signal(r.renderBusySem);

    if (out_drawable_w) *out_drawable_w = dwOut;
    if (out_drawable_h) *out_drawable_h = dhOut;
    if (out_gpu_ms) *out_gpu_ms = gpuMs;
    if (out_up_engine && out_up_engine_cap > 0) snprintf(out_up_engine, out_up_engine_cap, "%s", engineStorage);
    if (out_hdr_active) *out_hdr_active = hdrActive;
    if (out_hdr_source_10bit) *out_hdr_source_10bit = hdrSource10;
    if (out_edr_headroom) *out_edr_headroom = headroom;
    if (out_hdr_tag && out_hdr_tag_cap > 0) snprintf(out_hdr_tag, out_hdr_tag_cap, "%s", hdrTagStorage);
}

bool gc_renderer_save_screenshot(void *renderer_ptr, void *cv_pixel_buffer, const char *png_path) {
    if (!renderer_ptr || !cv_pixel_buffer || !png_path) return false;
    @autoreleasepool {
        GcMetalRenderer *r = (__bridge GcMetalRenderer *)renderer_ptr;
        CVPixelBufferRef pb = (CVPixelBufferRef)cv_pixel_buffer;
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        if (!ci) return false;

        CGImageRef cg = [r.ciContext createCGImage:ci fromRect:ci.extent];
        if (!cg) return false;

        NSString *pathStr = [NSString stringWithUTF8String:png_path];
        NSURL *url = [NSURL fileURLWithPath:pathStr];
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier,
            1,
            NULL
        );
        if (!dest) {
            CGImageRelease(cg);
            return false;
        }
        CGImageDestinationAddImage(dest, cg, NULL);
        BOOL ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
        CGImageRelease(cg);
        return ok;
    }
}
