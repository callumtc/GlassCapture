#import "bridge.h"

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@interface GcScreenCapture : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic) GcCallbacks callbacks;
@property (nonatomic, strong) dispatch_queue_t sampleQueue;
@property (nonatomic, strong, nullable) SCStream *stream;
@property (nonatomic, strong, nullable) SCStreamConfiguration *streamConfig;
@property (nonatomic) uint32_t activeWindowID;
@end

@implementation GcScreenCapture

- (instancetype)initWithCallbacks:(GcCallbacks)cbs {
    self = [super init];
    if (self) {
        _callbacks = cbs;
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        _sampleQueue = dispatch_queue_create("com.glasscapture.screencapture", attr);
    }
    return self;
}

- (void)stopStream {
    SCStream *s = _stream;
    _stream = nil;
    _streamConfig = nil;
    _activeWindowID = 0;
    if (s) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [s stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            (void)error;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
    }
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen) return;

    // Only accept complete newly-rendered frames (skip idle/blank WindowServer packets)
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        if (dict) {
            NSNumber *statusNum = (__bridge NSNumber *)CFDictionaryGetValue(dict, (__bridge const void *)SCStreamFrameInfoStatus);
            if (statusNum && statusNum.integerValue != SCFrameStatusComplete) {
                return;
            }
        }
    }

    CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!img) return;

    double nowMs = gc_monotonic_ms();
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    int64_t ptsNs = CMTIME_IS_VALID(pts) ? (int64_t)(CMTimeGetSeconds(pts) * 1e9) : (int64_t)(nowMs * 1e6);
    uint32_t w = (uint32_t)CVPixelBufferGetWidth(img);
    uint32_t h = (uint32_t)CVPixelBufferGetHeight(img);
    if (w < 16 || h < 16) return;

    if (_callbacks.on_video_frame) {
        _callbacks.on_video_frame(_callbacks.ctx, (void *)img, w, h, ptsNs, nowMs);
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    (void)stream;
    if (error) {
        NSLog(@"[GlassCapture] ScreenCaptureKit stream stopped: %@", error.localizedDescription);
    }
}

@end

// ============================================================================
// C Bridge Functions
// ============================================================================

void *gc_screen_create(const GcCallbacks *callbacks) {
    @autoreleasepool {
        GcScreenCapture *sc = [[GcScreenCapture alloc] initWithCallbacks:*callbacks];
        return (__bridge_retained void *)sc;
    }
}

void gc_screen_destroy(void *sc_ptr) {
    if (!sc_ptr) return;
    @autoreleasepool {
        GcScreenCapture *sc = (__bridge_transfer GcScreenCapture *)sc_ptr;
        [sc stopStream];
    }
}

bool gc_screen_has_permission(void) {
    return CGPreflightScreenCaptureAccess();
}

void gc_screen_request_permission(void) {
    CGRequestScreenCaptureAccess();
}

uint32_t gc_screen_list_windows(GcWindowInfo *out_list, uint32_t max_count) {
    if (!out_list || max_count == 0) return 0;
    if (!CGPreflightScreenCaptureAccess()) {
        // Don't block startup with permission dialog; use CGWindowList basic enumeration if possible
        return 0;
    }
    @autoreleasepool {
        __block NSArray<SCWindow *> *windows = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                   onScreenWindowsOnly:YES
                                                     completionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
            if (!error && content) {
                windows = content.windows;
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
        if (!windows) return 0;

        pid_t myPid = NSRunningApplication.currentApplication.processIdentifier;
        NSMutableArray<SCWindow *> *filtered = [NSMutableArray array];

        for (SCWindow *w in windows) {
            if (w.windowLayer != 0) continue;
            if (!w.owningApplication) continue;
            if (w.owningApplication.processID == myPid) continue;
            if (w.frame.size.width < 240 || w.frame.size.height < 160) continue;

            NSString *appName = w.owningApplication.applicationName ?: @"";
            if (appName.length == 0) continue;
            if ([appName isEqualToString:@"Window Server"] ||
                [appName isEqualToString:@"Dock"] ||
                [appName isEqualToString:@"Control Center"] ||
                [appName isEqualToString:@"Notification Center"]) {
                continue;
            }
            [filtered addObject:w];
        }

        // Largest windows (games, full apps) first
        [filtered sortUsingComparator:^NSComparisonResult(SCWindow *a, SCWindow *b) {
            double areaA = a.frame.size.width * a.frame.size.height;
            double areaB = b.frame.size.width * b.frame.size.height;
            if (fabs(areaA - areaB) > 100.0) return areaA > areaB ? NSOrderedAscending : NSOrderedDescending;
            return [a.owningApplication.applicationName localizedCaseInsensitiveCompare:b.owningApplication.applicationName];
        }];

        uint32_t count = 0;
        for (SCWindow *w in filtered) {
            if (count >= max_count) break;
            memset(&out_list[count], 0, sizeof(GcWindowInfo));
            out_list[count].window_id = (uint32_t)w.windowID;
            out_list[count].owner_pid = (int32_t)w.owningApplication.processID;
            out_list[count].width = (uint32_t)w.frame.size.width;
            out_list[count].height = (uint32_t)w.frame.size.height;
            snprintf(out_list[count].uid, sizeof(out_list[count].uid), "SCWIN:%u", (unsigned)w.windowID);

            NSString *appName = w.owningApplication.applicationName ?: @"App";
            NSString *winTitle = w.title;
            NSString *label = (winTitle && winTitle.length > 0 && ![winTitle isEqualToString:appName])
                ? [NSString stringWithFormat:@"%@ — %@", appName, winTitle]
                : appName;
            snprintf(out_list[count].title, sizeof(out_list[count].title), "%s", label.UTF8String ?: "Window");
            count++;
        }
        return count;
    }
}

bool gc_screen_start_window(void *sc_ptr, uint32_t window_id, double target_fps, bool hide_cursor, bool hdr_enabled) {
    if (!sc_ptr || window_id == 0) return false;
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        return false;
    }
    @autoreleasepool {
        GcScreenCapture *sc = (__bridge GcScreenCapture *)sc_ptr;
        [sc stopStream];

        __block SCWindow *targetWin = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES
                                                   onScreenWindowsOnly:NO
                                                     completionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
            if (!error && content) {
                for (SCWindow *w in content.windows) {
                    if ((uint32_t)w.windowID == window_id) {
                        targetWin = w;
                        break;
                    }
                }
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)));
        if (!targetWin) return false;

        SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWin];
        SCStreamConfiguration *cfg = nil;
        if (hdr_enabled) {
            cfg = [SCStreamConfiguration streamConfigurationWithPreset:SCStreamConfigurationPresetCaptureHDRStreamLocalDisplay];
        } else {
            cfg = [[SCStreamConfiguration alloc] init];
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            cfg.colorSpaceName = kCGColorSpaceITUR_709;
        }

        // Compute optimal capture dimensions (cap at 1920x1080 so VT Neural Frame Gen runs natively without downscaling!)
        double scale = NSScreen.mainScreen.backingScaleFactor ?: 2.0;
        double capW = targetWin.frame.size.width * scale;
        double capH = targetWin.frame.size.height * scale;
        if (capW > 1920.0 || capH > 1080.0) {
            double r = fmin(1920.0 / capW, 1080.0 / capH);
            capW *= r;
            capH *= r;
        }
        size_t wPx = ((size_t)fmax(64.0, round(capW))) & ~((size_t)1);
        size_t hPx = ((size_t)fmax(64.0, round(capH))) & ~((size_t)1);

        cfg.width = wPx;
        cfg.height = hPx;
        cfg.showsCursor = !hide_cursor;
        cfg.queueDepth = 3;
        cfg.scalesToFit = YES;
        int32_t fpsInt = (target_fps >= 10.0 && target_fps <= 120.0) ? (int32_t)llround(target_fps) : 60;
        cfg.minimumFrameInterval = CMTimeMake(1, fpsInt);

        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:sc];
        NSError *addErr = nil;
        if (![stream addStreamOutput:sc type:SCStreamOutputTypeScreen sampleHandlerQueue:sc.sampleQueue error:&addErr]) {
            NSLog(@"[GlassCapture] SCStream addStreamOutput failed: %@", addErr);
            return false;
        }

        __block BOOL startedOk = NO;
        dispatch_semaphore_t startSem = dispatch_semaphore_create(0);
        [stream startCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"[GlassCapture] SCStream startCapture failed: %@", error);
            } else {
                startedOk = YES;
            }
            dispatch_semaphore_signal(startSem);
        }];
        dispatch_semaphore_wait(startSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)));

        if (startedOk) {
            sc.stream = stream;
            sc.streamConfig = cfg;
            sc.activeWindowID = window_id;
        }
        return startedOk;
    }
}

void gc_screen_set_hide_cursor(void *sc_ptr, bool hide_cursor) {
    if (!sc_ptr) return;
    @autoreleasepool {
        GcScreenCapture *sc = (__bridge GcScreenCapture *)sc_ptr;
        if (!sc.stream || !sc.streamConfig) return;
        sc.streamConfig.showsCursor = !hide_cursor;
        [sc.stream updateConfiguration:sc.streamConfig completionHandler:^(NSError * _Nullable error) {
            (void)error;
        }];
    }
}

void gc_screen_stop(void *sc_ptr) {
    if (!sc_ptr) return;
    @autoreleasepool {
        GcScreenCapture *sc = (__bridge GcScreenCapture *)sc_ptr;
        [sc stopStream];
    }
}

bool gc_screen_get_window_frame(uint32_t window_id, double *out_x, double *out_y, double *out_w, double *out_h) {
    if (window_id == 0) return false;
    @autoreleasepool {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, (CGWindowID)window_id);
        if (!list) return false;
        BOOL found = NO;
        if (CFArrayGetCount(list) > 0) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, 0);
            NSDictionary *boundsDict = info[(NSString *)kCGWindowBounds];
            CGRect cgRect = CGRectZero;
            if (boundsDict && CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &cgRect)) {
                // Convert CG top-left coordinates to AppKit bottom-left screen coordinates using primary screen height
                CGFloat primaryH = 0;
                NSArray<NSScreen *> *screens = NSScreen.screens;
                if (screens.count > 0) {
                    primaryH = screens[0].frame.size.height;
                }
                double appKitY = (double)primaryH - (double)(cgRect.origin.y + cgRect.size.height);
                if (out_x) *out_x = (double)cgRect.origin.x;
                if (out_y) *out_y = appKitY;
                if (out_w) *out_w = (double)cgRect.size.width;
                if (out_h) *out_h = (double)cgRect.size.height;
                found = (cgRect.size.width >= 32 && cgRect.size.height >= 32);
            }
        }
        CFRelease(list);
        return found;
    }
}
