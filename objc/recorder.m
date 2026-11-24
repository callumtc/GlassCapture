#import "bridge.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@interface GcRecorder : NSObject
@property (nonatomic, strong) dispatch_queue_t writeQueue;
@property (nonatomic, strong) AVAssetWriter *writer;
@property (nonatomic, strong) AVAssetWriterInput *videoInput;
@property (nonatomic, strong) AVAssetWriterInputPixelBufferAdaptor *adaptor;
@property (nonatomic, strong, nullable) AVAssetWriterInput *audioInput;
@property (nonatomic) VTPixelTransferSessionRef transferSession;
@property (nonatomic) uint32_t width;
@property (nonatomic) uint32_t height;
@property (nonatomic) BOOL startedSession;
@property (nonatomic) BOOL stopped;
@property (nonatomic) int64_t basePtsNs;
@property (nonatomic) int64_t lastVideoPtsNs;
@property (nonatomic) int64_t lastAudioPtsNs;
@end

@implementation GcRecorder
- (void)dealloc {
    if (_transferSession) {
        VTPixelTransferSessionInvalidate(_transferSession);
        CFRelease(_transferSession);
        _transferSession = NULL;
    }
}
@end

void *gc_recorder_start(const char *mov_path, uint32_t width, uint32_t height, double fps, bool with_audio) {
    if (!mov_path || width < 16 || height < 16) return NULL;
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:mov_path];
        NSURL *url = [NSURL fileURLWithPath:path];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

        NSError *err = nil;
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&err];
        if (!writer || err) {
            NSLog(@"[GlassCapture] AVAssetWriter init failed: %@", err);
            return NULL;
        }

        double targetFps = fps > 10.0 ? fps : 60.0;
        double pixels = (double)width * (double)height;
        int bitrate = (int)(pixels * targetFps * 0.14); // ~17-25 Mbps for 1080p60, crisp hardware HEVC
        if (bitrate < 6000000) bitrate = 6000000;
        if (bitrate > 65000000) bitrate = 65000000;

        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeHEVC,
            AVVideoWidthKey: @(width),
            AVVideoHeightKey: @(height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(bitrate),
                AVVideoExpectedSourceFrameRateKey: @(targetFps),
                (NSString *)kVTCompressionPropertyKey_RealTime: @YES,
            }
        };

        AVAssetWriterInput *vIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
        vIn.expectsMediaDataInRealTime = YES;

        NSDictionary *srcAttrs = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (NSString *)kCVPixelBufferWidthKey: @(width),
            (NSString *)kCVPixelBufferHeightKey: @(height),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:vIn sourcePixelBufferAttributes:srcAttrs];

        if (![writer canAddInput:vIn]) return NULL;
        [writer addInput:vIn];

        AVAssetWriterInput *aIn = nil;
        if (with_audio) {
            NSDictionary *audioSettings = @{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @(48000.0),
                AVNumberOfChannelsKey: @(2),
                AVEncoderBitRateKey: @(256000),
            };
            aIn = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
            aIn.expectsMediaDataInRealTime = YES;
            if ([writer canAddInput:aIn]) {
                [writer addInput:aIn];
            } else {
                aIn = nil;
            }
        }

        if (![writer startWriting]) {
            NSLog(@"[GlassCapture] AVAssetWriter startWriting failed: %@", writer.error);
            return NULL;
        }

        GcRecorder *rec = [[GcRecorder alloc] init];
        rec.writeQueue = dispatch_queue_create("com.glasscapture.recorder", DISPATCH_QUEUE_SERIAL);
        rec.writer = writer;
        rec.videoInput = vIn;
        rec.adaptor = adaptor;
        rec.audioInput = aIn;
        rec.width = width;
        rec.height = height;
        VTPixelTransferSessionRef xfer = NULL;
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &xfer);
        rec.transferSession = xfer;
        rec.startedSession = NO;
        rec.stopped = NO;
        rec.basePtsNs = 0;
        rec.lastVideoPtsNs = -1;
        rec.lastAudioPtsNs = -1;
        return (__bridge_retained void *)rec;
    }
}

void gc_recorder_append_video(void *rec_ptr, void *cv_pixel_buffer, int64_t pts_ns) {
    if (!rec_ptr || !cv_pixel_buffer) return;
    GcRecorder *rec = (__bridge GcRecorder *)rec_ptr;
    CVPixelBufferRef pb = CVPixelBufferRetain((CVPixelBufferRef)cv_pixel_buffer);

    dispatch_async(rec.writeQueue, ^{
        @autoreleasepool {
            if (rec.stopped || rec.writer.status != AVAssetWriterStatusWriting) {
                CVPixelBufferRelease(pb);
                return;
            }
            if (!rec.startedSession) {
                rec.basePtsNs = pts_ns;
                [rec.writer startSessionAtSourceTime:kCMTimeZero];
                rec.startedSession = YES;
            }
            int64_t relNs = pts_ns - rec.basePtsNs;
            if (relNs <= rec.lastVideoPtsNs) {
                relNs = rec.lastVideoPtsNs + 1000000; // ensure strictly monotonic (+1ms)
            }
            if (rec.videoInput.isReadyForMoreMediaData) {
                CMTime t = CMTimeMake(relNs, 1000000000);
                CVPixelBufferRef toAppend = pb;
                CVPixelBufferRef converted = NULL;

                // Convert HDR (RGBA16Float/10-bit) or mismatched dimensions via hardware Media Engine into adaptor pool!
                OSType fmt = CVPixelBufferGetPixelFormatType(pb);
                size_t pw = CVPixelBufferGetWidth(pb);
                size_t ph = CVPixelBufferGetHeight(pb);
                if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || pw != rec.width || ph != rec.height) {
                    CVPixelBufferPoolRef pool = rec.adaptor.pixelBufferPool;
                    if (pool && rec.transferSession &&
                        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &converted) == kCVReturnSuccess && converted) {
                        if (VTPixelTransferSessionTransferImage(rec.transferSession, pb, converted) == noErr) {
                            toAppend = converted;
                        }
                    }
                }

                if ([rec.adaptor appendPixelBuffer:toAppend withPresentationTime:t]) {
                    rec.lastVideoPtsNs = relNs;
                }
                if (converted) CVPixelBufferRelease(converted);
            }
            CVPixelBufferRelease(pb);
        }
    });
}

void gc_recorder_append_audio(void *rec_ptr, const float *interleaved_stereo, uint32_t frame_count, uint32_t sample_rate, int64_t pts_ns) {
    if (!rec_ptr || !interleaved_stereo || frame_count == 0) return;
    GcRecorder *rec = (__bridge GcRecorder *)rec_ptr;
    if (!rec.audioInput) return;

    size_t byteLen = (size_t)frame_count * 2 * sizeof(float);
    NSData *pcmCopy = [NSData dataWithBytes:interleaved_stereo length:byteLen];

    dispatch_async(rec.writeQueue, ^{
        @autoreleasepool {
            if (rec.stopped || !rec.startedSession || rec.writer.status != AVAssetWriterStatusWriting) return;
            if (!rec.audioInput.isReadyForMoreMediaData) return;

            int64_t relNs = pts_ns - rec.basePtsNs;
            if (relNs < 0) return;
            if (relNs <= rec.lastAudioPtsNs) {
                relNs = rec.lastAudioPtsNs + 1000;
            }

            AudioStreamBasicDescription asbd = {0};
            asbd.mSampleRate = sample_rate > 0 ? (double)sample_rate : 48000.0;
            asbd.mFormatID = kAudioFormatLinearPCM;
            asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            asbd.mBytesPerPacket = 8;
            asbd.mFramesPerPacket = 1;
            asbd.mBytesPerFrame = 8;
            asbd.mChannelsPerFrame = 2;
            asbd.mBitsPerChannel = 32;

            CMAudioFormatDescriptionRef fmt = NULL;
            if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fmt) != noErr || !fmt) {
                return;
            }

            CMBlockBufferRef block = NULL;
            if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, pcmCopy.length, kCFAllocatorDefault, NULL, 0, pcmCopy.length, 0, &block) != noErr || !block) {
                CFRelease(fmt);
                return;
            }
            CMBlockBufferReplaceDataBytes(pcmCopy.bytes, block, 0, pcmCopy.length);

            CMSampleTimingInfo timing = {
                .duration = CMTimeMake(1, (int32_t)asbd.mSampleRate),
                .presentationTimeStamp = CMTimeMake(relNs, 1000000000),
                .decodeTimeStamp = kCMTimeInvalid
            };
            CMSampleBufferRef sbuf = NULL;
            if (CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL, fmt, (CMItemCount)frame_count, 1, &timing, 0, NULL, &sbuf) == noErr && sbuf) {
                if ([rec.audioInput appendSampleBuffer:sbuf]) {
                    rec.lastAudioPtsNs = relNs;
                }
                CFRelease(sbuf);
            }
            CFRelease(block);
            CFRelease(fmt);
        }
    });
}

void gc_recorder_stop(void *rec_ptr) {
    if (!rec_ptr) return;
    @autoreleasepool {
        GcRecorder *rec = (__bridge_transfer GcRecorder *)rec_ptr;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(rec.writeQueue, ^{
            rec.stopped = YES;
            if (rec.writer.status == AVAssetWriterStatusWriting) {
                [rec.videoInput markAsFinished];
                if (rec.audioInput) [rec.audioInput markAsFinished];
                [rec.writer finishWritingWithCompletionHandler:^{
                    dispatch_semaphore_signal(sem);
                }];
            } else {
                dispatch_semaphore_signal(sem);
            }
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));
    }
}
