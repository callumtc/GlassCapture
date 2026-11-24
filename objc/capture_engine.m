#import "bridge.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <stdatomic.h>
#import <math.h>

// ============================================================================
// Lock-Free SPSC Stereo Float Ring Buffer (for ultra-low-latency audio)
// ============================================================================

#define GC_AUDIO_RING_FRAMES 16384 // ~341ms max capacity @ 48kHz (trimmed to ~35ms for low latency)

typedef struct {
    float data[GC_AUDIO_RING_FRAMES * 2];
    _Atomic uint64_t write_idx;
    _Atomic uint64_t read_idx;
    _Atomic float volume;
    _Atomic bool muted;
    _Atomic uint32_t sample_rate;
    // Render-thread-only state for click-free gain & underrun smoothing
    float smooth_gain;
    float last_l;
    float last_r;
} GcAudioRing;

static void gc_audio_ring_init(GcAudioRing *r) {
    memset(r->data, 0, sizeof(r->data));
    atomic_store(&r->write_idx, 0);
    atomic_store(&r->read_idx, 0);
    atomic_store(&r->volume, 0.85f);
    atomic_store(&r->muted, false);
    atomic_store(&r->sample_rate, 48000);
    r->smooth_gain = 0.0f;
    r->last_l = 0.0f;
    r->last_r = 0.0f;
}

static void gc_audio_ring_push(GcAudioRing *r, const float *interleaved, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&r->write_idx, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->read_idx, memory_order_acquire);

    // Keep latency tight: if queued audio > ~40ms (1920 frames @ 48k), advance read_idx
    uint64_t queued = w - rd;
    uint64_t maxQueued = 2400;
    if (queued > maxQueued) {
        // Producer should not mutate read_idx directly in strict SPSC; drop incoming surplus instead
        if (frames >= GC_AUDIO_RING_FRAMES - queued) return;
    }

    uint64_t freeFrames = GC_AUDIO_RING_FRAMES - (w - rd);
    if (frames > freeFrames) frames = (uint32_t)freeFrames;

    for (uint32_t i = 0; i < frames; i++) {
        uint64_t pos = ((w + i) % GC_AUDIO_RING_FRAMES) * 2;
        r->data[pos]     = interleaved[i * 2];
        r->data[pos + 1] = interleaved[i * 2 + 1];
    }
    atomic_store_explicit(&r->write_idx, w + frames, memory_order_release);
}

// ============================================================================
// Capture Engine ObjC Implementation
// ============================================================================

@interface GcCaptureEngine : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic) GcCallbacks callbacks;
@property (nonatomic, strong) dispatch_queue_t videoQueue;
@property (nonatomic, strong) dispatch_queue_t audioQueue;
@property (nonatomic, strong, nullable) AVCaptureSession *videoSession;
@property (nonatomic, strong, nullable) AVCaptureSession *audioSession;
@property (nonatomic, strong, nullable) AVAudioEngine *audioEngine;
@property (nonatomic, strong, nullable) AVAudioSourceNode *audioSourceNode;
@property (nonatomic) GcAudioRing *audioRing;
@property (nonatomic) BOOL audioEngineRunning;
@end

@implementation GcCaptureEngine

- (instancetype)initWithCallbacks:(GcCallbacks)cbs {
    self = [super init];
    if (self) {
        _callbacks = cbs;
        dispatch_queue_attr_t vAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        dispatch_queue_attr_t aAttr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _videoQueue = dispatch_queue_create("com.glasscapture.capture.video", vAttr);
        _audioQueue = dispatch_queue_create("com.glasscapture.capture.audio", aAttr);
        _audioRing = (GcAudioRing *)calloc(1, sizeof(GcAudioRing));
        gc_audio_ring_init(_audioRing);

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onDeviceNotification:)
                                                     name:AVCaptureDeviceWasConnectedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onDeviceNotification:)
                                                     name:AVCaptureDeviceWasDisconnectedNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onAudioEngineConfigChanged:)
                                                     name:AVAudioEngineConfigurationChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)onAudioEngineConfigChanged:(NSNotification *)note {
    (void)note;
    // User plugged in AirPods / headphones or switched output speaker: seamlessly rebuild AVAudioEngine!
    dispatch_async(_audioQueue, ^{
        if (self.audioSession && self.audioSession.isRunning) {
            self.audioEngineRunning = NO;
            uint32_t sr = atomic_load_explicit(&self.audioRing->sample_rate, memory_order_relaxed);
            [self ensureAudioPlaybackWithSampleRate:(double)(sr > 8000 ? sr : 48000)];
        }
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopVideo];
    [self stopAudio];
    if (_audioRing) {
        free(_audioRing);
        _audioRing = NULL;
    }
}

- (void)onDeviceNotification:(NSNotification *)note {
    (void)note;
    if (_callbacks.on_devices_changed) {
        _callbacks.on_devices_changed(_callbacks.ctx);
    }
}

- (void)stopVideo {
    if (_videoSession) {
        if (_videoSession.isRunning) {
            [_videoSession stopRunning];
        }
        _videoSession = nil;
    }
}

- (void)stopAudio {
    if (_audioSession) {
        if (_audioSession.isRunning) {
            [_audioSession stopRunning];
        }
        _audioSession = nil;
    }
    if (_audioEngine) {
        if (_audioEngine.isRunning) {
            [_audioEngine stop];
        }
        _audioEngine = nil;
        _audioSourceNode = nil;
        _audioEngineRunning = NO;
    }
}

- (void)ensureAudioPlaybackWithSampleRate:(double)sampleRate {
    if (_audioEngineRunning && _audioEngine && _audioEngine.isRunning) return;

    if (_audioEngine) {
        [_audioEngine stop];
        _audioEngine = nil;
    }

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate > 8000 ? sampleRate : 48000.0 channels:2];
    GcAudioRing *ring = _audioRing;

    AVAudioSourceNode *node = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:^OSStatus(
        BOOL *isSilence,
        const AudioTimeStamp *timestamp,
        AVAudioFrameCount frameCount,
        AudioBufferList *outputData
    ) {
        (void)timestamp;
        uint64_t w = atomic_load_explicit(&ring->write_idx, memory_order_acquire);
        uint64_t rd = atomic_load_explicit(&ring->read_idx, memory_order_relaxed);
        uint64_t avail = w - rd;

        // Low-latency drift guard: if > ~50ms queued, skip forward to ~15ms with crossfade smoothing
        bool jumped = false;
        if (avail > 2400) {
            rd = w - 720;
            avail = 720;
            jumped = true;
        }

        float targetGain = atomic_load_explicit(&ring->muted, memory_order_relaxed)
            ? 0.0f
            : atomic_load_explicit(&ring->volume, memory_order_relaxed);

        float *leftOut = (outputData->mNumberBuffers >= 1) ? (float *)outputData->mBuffers[0].mData : NULL;
        float *rightOut = (outputData->mNumberBuffers >= 2) ? (float *)outputData->mBuffers[1].mData : leftOut;

        if (avail == 0 && ring->smooth_gain < 0.0005f && fabsf(ring->last_l) < 0.0005f && fabsf(ring->last_r) < 0.0005f) {
            for (UInt32 b = 0; b < outputData->mNumberBuffers; b++) {
                memset(outputData->mBuffers[b].mData, 0, outputData->mBuffers[b].mDataByteSize);
            }
            *isSilence = YES;
            return noErr;
        }

        *isSilence = NO;
        uint32_t toRead = (avail < frameCount) ? (uint32_t)avail : frameCount;
        float g = ring->smooth_gain;
        float prevL = ring->last_l;
        float prevR = ring->last_r;

        for (uint32_t i = 0; i < toRead; i++) {
            // Smooth gain ramp (~5ms) prevents clicks on mute/volume drag
            g += (targetGain - g) * 0.012f;
            uint64_t pos = ((rd + i) % GC_AUDIO_RING_FRAMES) * 2;
            float l = ring->data[pos] * g;
            float r = ring->data[pos + 1] * g;
            // 32-sample crossfade if drift guard jumped to eliminate pops
            if (jumped && i < 32) {
                float alpha = (float)(i + 1) / 32.0f;
                l = prevL * (1.0f - alpha) + l * alpha;
                r = prevR * (1.0f - alpha) + r * alpha;
            }
            if (leftOut) leftOut[i] = l;
            if (rightOut && rightOut != leftOut) rightOut[i] = r;
            prevL = l;
            prevR = r;
        }

        // Exponential decay tail on brief underrun instead of hard step to 0 (prevents audible click!)
        for (uint32_t i = toRead; i < frameCount; i++) {
            prevL *= 0.85f;
            prevR *= 0.85f;
            if (leftOut) leftOut[i] = prevL;
            if (rightOut && rightOut != leftOut) rightOut[i] = prevR;
        }

        ring->smooth_gain = g;
        ring->last_l = prevL;
        ring->last_r = prevR;

        if (toRead > 0) {
            atomic_store_explicit(&ring->read_idx, rd + toRead, memory_order_release);
        }
        return noErr;
    }];

    [engine attachNode:node];
    [engine connect:node to:engine.mainMixerNode format:fmt];
    NSError *err = nil;
    if ([engine startAndReturnError:&err]) {
        _audioEngine = engine;
        _audioSourceNode = node;
        _audioEngineRunning = YES;
    } else {
        NSLog(@"[GlassCapture] AVAudioEngine start failed: %@", err);
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    (void)connection;
    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!img) return;
        double nowMs = gc_monotonic_ms();
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        int64_t ptsNs = CMTIME_IS_VALID(pts) ? (int64_t)(CMTimeGetSeconds(pts) * 1e9) : (int64_t)(nowMs * 1e6);
        uint32_t w = (uint32_t)CVPixelBufferGetWidth(img);
        uint32_t h = (uint32_t)CVPixelBufferGetHeight(img);
        if (_callbacks.on_video_frame) {
            _callbacks.on_video_frame(_callbacks.ctx, (void *)img, w, h, ptsNs, nowMs);
        }
    } else if ([output isKindOfClass:[AVCaptureAudioDataOutput class]]) {
        CMFormatDescriptionRef fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription *asbd = fmtDesc ? CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) : NULL;
        if (!asbd || asbd->mChannelsPerFrame == 0) return;

        CMBlockBufferRef blockBuf = NULL;
        AudioBufferList abl;
        OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, NULL, &abl, sizeof(abl), NULL, NULL,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuf
        );
        if (st != noErr || abl.mNumberBuffers == 0) {
            if (blockBuf) CFRelease(blockBuf);
            return;
        }

        uint32_t sr = (uint32_t)asbd->mSampleRate;
        if (sr == 0) sr = 48000;
        atomic_store_explicit(&_audioRing->sample_rate, sr, memory_order_relaxed);
        [self ensureAudioPlaybackWithSampleRate:(double)sr];

        // Convert to interleaved stereo float32
        const float *src = (const float *)abl.mBuffers[0].mData;
        uint32_t ch = asbd->mChannelsPerFrame;
        uint32_t totalFloats = abl.mBuffers[0].mDataByteSize / sizeof(float);
        uint32_t frames = (ch > 0) ? (totalFloats / ch) : 0;
        if (frames > 4096) frames = 4096;

        float stereo[4096 * 2];
        float peak = 0.0f;
        for (uint32_t i = 0; i < frames; i++) {
            float l = (ch >= 1) ? src[i * ch] : 0.0f;
            float r = (ch >= 2) ? src[i * ch + 1] : l;
            stereo[i * 2] = l;
            stereo[i * 2 + 1] = r;
            float al = fabsf(l);
            float ar = fabsf(r);
            if (al > peak) peak = al;
            if (ar > peak) peak = ar;
        }

        gc_audio_ring_push(_audioRing, stereo, frames);

        if (_callbacks.on_audio_samples) {
            _callbacks.on_audio_samples(_callbacks.ctx, stereo, frames, 2, sr, peak);
        }

        if (blockBuf) CFRelease(blockBuf);
    }
}

@end

// ============================================================================
// C Bridge Functions
// ============================================================================

void *gc_capture_create(const GcCallbacks *callbacks) {
    @autoreleasepool {
        GcCaptureEngine *eng = [[GcCaptureEngine alloc] initWithCallbacks:*callbacks];
        return (__bridge_retained void *)eng;
    }
}

void gc_capture_destroy(void *cap_ptr) {
    if (!cap_ptr) return;
    @autoreleasepool {
        GcCaptureEngine *eng = (__bridge_transfer GcCaptureEngine *)cap_ptr;
        [eng stopVideo];
        [eng stopAudio];
    }
}

void gc_capture_request_permissions(void *cap_ptr) {
    (void)cap_ptr;
    @autoreleasepool {
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                (void)granted;
            }];
        }
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                (void)granted;
            }];
        }
    }
}

uint32_t gc_capture_list_video_devices(GcDeviceInfo *out_list, uint32_t max_count) {
    if (!out_list || max_count == 0) return 0;
    @autoreleasepool {
        AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[
                AVCaptureDeviceTypeExternal,
                AVCaptureDeviceTypeBuiltInWideAngleCamera,
                AVCaptureDeviceTypeContinuityCamera
            ]
            mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionUnspecified];

        // Put external capture cards first!
        NSArray<AVCaptureDevice *> *sorted = [ds.devices sortedArrayUsingComparator:^NSComparisonResult(AVCaptureDevice *a, AVCaptureDevice *b) {
            BOOL extA = [a.deviceType isEqualToString:AVCaptureDeviceTypeExternal];
            BOOL extB = [b.deviceType isEqualToString:AVCaptureDeviceTypeExternal];
            if (extA != extB) return extA ? NSOrderedAscending : NSOrderedDescending;
            return [a.localizedName localizedCaseInsensitiveCompare:b.localizedName];
        }];

        uint32_t count = 0;
        for (AVCaptureDevice *d in sorted) {
            if (count >= max_count) break;
            memset(&out_list[count], 0, sizeof(GcDeviceInfo));
            snprintf(out_list[count].uid, sizeof(out_list[count].uid), "%s", d.uniqueID.UTF8String ?: "");
            snprintf(out_list[count].name, sizeof(out_list[count].name), "%s", d.localizedName.UTF8String ?: "Video Device");
            out_list[count].is_external = [d.deviceType isEqualToString:AVCaptureDeviceTypeExternal];
            count++;
        }
        return count;
    }
}

uint32_t gc_capture_list_audio_devices(GcDeviceInfo *out_list, uint32_t max_count) {
    if (!out_list || max_count == 0) return 0;
    @autoreleasepool {
        AVCaptureDeviceDiscoverySession *ds = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[
                AVCaptureDeviceTypeExternal,
                AVCaptureDeviceTypeMicrophone
            ]
            mediaType:AVMediaTypeAudio
            position:AVCaptureDevicePositionUnspecified];

        NSArray<AVCaptureDevice *> *sorted = [ds.devices sortedArrayUsingComparator:^NSComparisonResult(AVCaptureDevice *a, AVCaptureDevice *b) {
            BOOL extA = [a.deviceType isEqualToString:AVCaptureDeviceTypeExternal];
            BOOL extB = [b.deviceType isEqualToString:AVCaptureDeviceTypeExternal];
            if (extA != extB) return extA ? NSOrderedAscending : NSOrderedDescending;
            return [a.localizedName localizedCaseInsensitiveCompare:b.localizedName];
        }];

        uint32_t count = 0;
        for (AVCaptureDevice *d in sorted) {
            if (count >= max_count) break;
            memset(&out_list[count], 0, sizeof(GcDeviceInfo));
            snprintf(out_list[count].uid, sizeof(out_list[count].uid), "%s", d.uniqueID.UTF8String ?: "");
            snprintf(out_list[count].name, sizeof(out_list[count].name), "%s", d.localizedName.UTF8String ?: "Audio Device");
            out_list[count].is_external = [d.deviceType isEqualToString:AVCaptureDeviceTypeExternal];
            count++;
        }
        return count;
    }
}

uint32_t gc_capture_list_video_formats(const char *device_uid, GcVideoFormatInfo *out_list, uint32_t max_count) {
    if (!device_uid || !out_list || max_count == 0) return 0;
    @autoreleasepool {
        NSString *uid = [NSString stringWithUTF8String:device_uid];
        AVCaptureDevice *dev = [AVCaptureDevice deviceWithUniqueID:uid];
        if (!dev) return 0;

        NSMutableDictionary<NSString *, NSDictionary *> *bestByKey = [NSMutableDictionary dictionary];

        NSArray<AVCaptureDeviceFormat *> *formats = dev.formats;
        for (NSUInteger i = 0; i < formats.count; i++) {
            AVCaptureDeviceFormat *f = formats[i];
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
            if (dims.width <= 0 || dims.height <= 0) continue;

            double maxFps = 0.0;
            for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
                if (r.maxFrameRate > maxFps) maxFps = r.maxFrameRate;
            }
            if (maxFps <= 0.0) maxFps = 30.0;

            OSType sub = CMFormatDescriptionGetMediaSubType(f.formatDescription);
            BOOL is420v = (sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                           sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);

            NSString *key = [NSString stringWithFormat:@"%dx%d@%d", dims.width, dims.height, (int)llround(maxFps)];
            NSDictionary *existing = bestByKey[key];
            // Prefer native zero-copy '420v' over 'yuvs'/'2vuy' when resolution & fps match
            if (existing && ([existing[@"is420v"] boolValue] || !is420v)) continue;
            bestByKey[key] = @{
                @"idx": @(i),
                @"w": @(dims.width),
                @"h": @(dims.height),
                @"fps": @(maxFps),
                @"is420v": @(is420v)
            };
        }
        NSMutableArray<NSDictionary *> *dedup = [NSMutableArray arrayWithArray:bestByKey.allValues];

        [dedup sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            long long pxA = [a[@"w"] longLongValue] * [a[@"h"] longLongValue];
            long long pxB = [b[@"w"] longLongValue] * [b[@"h"] longLongValue];
            if (pxA != pxB) return pxA > pxB ? NSOrderedAscending : NSOrderedDescending;
            double fpsA = [a[@"fps"] doubleValue];
            double fpsB = [b[@"fps"] doubleValue];
            if (fabs(fpsA - fpsB) > 0.5) return fpsA > fpsB ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];

        uint32_t count = 0;
        for (NSDictionary *entry in dedup) {
            if (count >= max_count) break;
            int32_t idx = [entry[@"idx"] intValue];
            uint32_t w = [entry[@"w"] unsignedIntValue];
            uint32_t h = [entry[@"h"] unsignedIntValue];
            double fps = [entry[@"fps"] doubleValue];
            out_list[count].index = idx;
            out_list[count].width = w;
            out_list[count].height = h;
            out_list[count].max_fps = fps;
            snprintf(out_list[count].label, sizeof(out_list[count].label), "%u×%u @ %.0f fps", w, h, fps);
            count++;
        }
        return count;
    }
}

bool gc_capture_start_video(void *cap_ptr, const char *device_uid, int32_t format_index, bool hdr_enabled) {
    if (!cap_ptr || !device_uid) return false;
    @autoreleasepool {
        GcCaptureEngine *eng = (__bridge GcCaptureEngine *)cap_ptr;
        [eng stopVideo];

        NSString *uid = [NSString stringWithUTF8String:device_uid];
        AVCaptureDevice *dev = [AVCaptureDevice deviceWithUniqueID:uid];
        if (!dev) return false;

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        if (!input || err) {
            NSLog(@"[GlassCapture] Failed creating video input: %@", err);
            return false;
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        [session beginConfiguration];
        if ([session canAddInput:input]) {
            [session addInput:input];
        } else {
            [session commitConfiguration];
            return false;
        }

        AVCaptureDeviceFormat *chosenFormat = nil;
        AVFrameRateRange *bestRange = nil;
        if (format_index >= 0 && (NSUInteger)format_index < dev.formats.count) {
            chosenFormat = dev.formats[(NSUInteger)format_index];
            for (AVFrameRateRange *r in chosenFormat.videoSupportedFrameRateRanges) {
                if (!bestRange || r.maxFrameRate > bestRange.maxFrameRate) {
                    bestRange = r;
                }
            }
        }

        // Preserve 10-bit HDR pixel format when HDR passthrough is enabled and the capture card supports 10-bit!
        OSType reqPixFmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        if (hdr_enabled && chosenFormat) {
            OSType sub = CMFormatDescriptionGetMediaSubType(chosenFormat.formatDescription);
            if (sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
                reqPixFmt = sub;
            }
        }

        AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
        output.alwaysDiscardsLateVideoFrames = YES;
        output.videoSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(reqPixFmt),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        };
        [output setSampleBufferDelegate:eng queue:eng.videoQueue];

        if ([session canAddOutput:output]) {
            [session addOutput:output];
        } else {
            [session commitConfiguration];
            return false;
        }

        [session commitConfiguration];
        eng.videoSession = session;

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [session startRunning];

            // On macOS, AVCaptureSession startRunning resets UVC capture cards' activeVideoMinFrameDuration
            // (e.g. dropping 1080p60 down to 20fps). Lock and enforce the selected format & max FPS AFTER startRunning!
            if (chosenFormat && bestRange) {
                NSError *lockErr = nil;
                if ([dev lockForConfiguration:&lockErr]) {
                    dev.activeFormat = chosenFormat;
                    dev.activeVideoMinFrameDuration = bestRange.minFrameDuration;
                    dev.activeVideoMaxFrameDuration = bestRange.minFrameDuration;
                    [dev unlockForConfiguration];
                }
                // Verify once more after CMIO settles (~150ms) in case the UVC driver renegotiated
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    if (eng.videoSession != session || !session.isRunning) return;
                    double curFps = CMTimeGetSeconds(dev.activeVideoMinFrameDuration) > 0
                        ? (1.0 / CMTimeGetSeconds(dev.activeVideoMinFrameDuration)) : 0.0;
                    if (curFps < bestRange.maxFrameRate - 1.0) {
                        NSError *retryErr = nil;
                        if ([dev lockForConfiguration:&retryErr]) {
                            dev.activeFormat = chosenFormat;
                            dev.activeVideoMinFrameDuration = bestRange.minFrameDuration;
                            dev.activeVideoMaxFrameDuration = bestRange.minFrameDuration;
                            [dev unlockForConfiguration];
                        }
                    }
                });
            }
        });
        return true;
    }
}

void gc_capture_stop_video(void *cap_ptr) {
    if (!cap_ptr) return;
    @autoreleasepool {
        GcCaptureEngine *eng = (__bridge GcCaptureEngine *)cap_ptr;
        [eng stopVideo];
    }
}

bool gc_capture_start_audio(void *cap_ptr, const char *device_uid) {
    if (!cap_ptr || !device_uid || device_uid[0] == '\0') return false;
    @autoreleasepool {
        GcCaptureEngine *eng = (__bridge GcCaptureEngine *)cap_ptr;
        [eng stopAudio];

        NSString *uid = [NSString stringWithUTF8String:device_uid];
        AVCaptureDevice *dev = [AVCaptureDevice deviceWithUniqueID:uid];
        if (!dev) return false;

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        if (!input || err) return false;

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        [session beginConfiguration];
        if ([session canAddInput:input]) {
            [session addInput:input];
        } else {
            [session commitConfiguration];
            return false;
        }

        AVCaptureAudioDataOutput *output = [[AVCaptureAudioDataOutput alloc] init];
        output.audioSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @(48000.0),
            AVNumberOfChannelsKey: @(2),
            AVLinearPCMBitDepthKey: @(32),
            AVLinearPCMIsFloatKey: @YES,
            AVLinearPCMIsNonInterleaved: @NO,
        };
        [output setSampleBufferDelegate:eng queue:eng.audioQueue];

        if ([session canAddOutput:output]) {
            [session addOutput:output];
        } else {
            [session commitConfiguration];
            return false;
        }
        [session commitConfiguration];

        eng.audioSession = session;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [session startRunning];
        });
        return true;
    }
}

void gc_capture_stop_audio(void *cap_ptr) {
    if (!cap_ptr) return;
    @autoreleasepool {
        GcCaptureEngine *eng = (__bridge GcCaptureEngine *)cap_ptr;
        [eng stopAudio];
    }
}

void gc_capture_set_audio_volume(void *cap_ptr, float volume) {
    if (!cap_ptr) return;
    GcCaptureEngine *eng = (__bridge GcCaptureEngine *)cap_ptr;
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    atomic_store_explicit(&eng.audioRing->volume, volume, memory_order_relaxed);
}

void gc_capture_set_audio_muted(void *cap_ptr, bool muted) {
    if (!cap_ptr) return;
    GcCaptureEngine *eng = (__bridge GcCaptureEngine *)cap_ptr;
    atomic_store_explicit(&eng.audioRing->muted, muted, memory_order_relaxed);
}
