#ifndef GLASS_CAPTURE_BRIDGE_H
#define GLASS_CAPTURE_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Shared Enums (must match src/ffi.rs)
// ============================================================================

typedef enum {
    GC_UPSCALE_OFF        = 0, // Native bilinear zero-copy
    GC_UPSCALE_METALFX    = 1, // Apple MetalFX Spatial GPU upscaler
    GC_UPSCALE_AUTO_ML    = 2, // VideoToolbox ML Super-Res (when eligible) + MetalFX Spatial
    GC_UPSCALE_SHARP_CAS  = 3, // Contrast-Adaptive Sharpening + Bicubic Metal shader
    GC_UPSCALE_INTEGER    = 4, // Crisp nearest-neighbor pixel/retro shader
} GcUpscaleMode;

typedef enum {
    GC_FRAMEGEN_OFF = 0, // 1x native passthrough (lowest latency)
    GC_FRAMEGEN_2X  = 1, // 2x VideoToolbox Neural Low-Latency Frame Interpolation (phase 0.5)
    GC_FRAMEGEN_4X  = 2, // 4x VideoToolbox Neural Low-Latency Frame Interpolation (0.25, 0.5, 0.75)
} GcFrameGenMode;

typedef enum {
    GC_ASPECT_FIT     = 0, // Preserve source aspect ratio (letterbox/pillarbox)
    GC_ASPECT_FILL    = 1, // Fill entire window (crop overflow)
    GC_ASPECT_16_9    = 2, // Force 16:9
    GC_ASPECT_4_3     = 3, // Force 4:3
    GC_ASPECT_STRETCH = 4, // Stretch to window bounds
} GcAspectMode;

typedef enum {
    GC_OVERLAY_OFF          = 0, // Standard interactive GlassCapture window
    GC_OVERLAY_MATCH_WINDOW = 1, // Click-through overlay aligned 1:1 on top of target game/app window
    GC_OVERLAY_FULLSCREEN   = 2, // Click-through full-screen upscaled overlay on top of target display
} GcOverlayMode;

typedef enum {
    GC_ACTION_SELECT_VIDEO_DEVICE = 1, // str_arg = device_uid (or "SCWIN:<id>" / "__GLASS_TEST_...__")
    GC_ACTION_SELECT_VIDEO_FORMAT = 2, // int_arg = format_index
    GC_ACTION_SELECT_AUDIO_DEVICE = 3, // str_arg = device_uid (or "" for off)
    GC_ACTION_SET_AUDIO_VOLUME    = 4, // float_arg = 0.0..1.0
    GC_ACTION_TOGGLE_AUDIO_MUTE   = 5,
    GC_ACTION_SET_UPSCALE_MODE    = 6, // int_arg = GcUpscaleMode
    GC_ACTION_SET_FRAMEGEN_MODE   = 7, // int_arg = GcFrameGenMode
    GC_ACTION_SET_ASPECT_MODE     = 8, // int_arg = GcAspectMode
    GC_ACTION_TOGGLE_INTEGER_LOCK = 9,
    GC_ACTION_TOGGLE_ALWAYS_ON_TOP= 10,
    GC_ACTION_TOGGLE_HUD          = 11,
    GC_ACTION_TOGGLE_PAUSE        = 12,
    GC_ACTION_TAKE_SCREENSHOT     = 13,
    GC_ACTION_TOGGLE_RECORDING    = 14,
    GC_ACTION_TOGGLE_FULLSCREEN   = 15,
    GC_ACTION_SET_SHARPNESS       = 16, // float_arg = 0.0..1.0
    GC_ACTION_REFRESH_DEVICES     = 17,
    GC_ACTION_SET_GLASS_STYLE     = 18, // int_arg = 0 (regular), 1 (clear)
    GC_ACTION_TOGGLE_OVERLAY      = 19, // Toggle click-through game/app overlay mode
    GC_ACTION_SET_OVERLAY_STYLE   = 20, // int_arg = 1 (Match Window) or 2 (Full Screen)
    GC_ACTION_TOGGLE_HDR          = 21, // Toggle HDR / EDR passthrough
    GC_ACTION_TOGGLE_CLEAN_VIEW   = 22, // Toggle Clean / Zen View (hide all UI + HUD)
    GC_ACTION_SET_COLOR_RANGE     = 23, // int_arg = 0 (Auto), 1 (Limited), 2 (Full)
    GC_ACTION_SET_CONTRAST        = 24, // float_arg = 0.8..1.4
    GC_ACTION_SET_SATURATION      = 25, // float_arg = 0.0..1.6
    GC_ACTION_SET_GAMMA           = 26, // float_arg = 0.7..1.4
    GC_ACTION_SET_OVERSCAN        = 27, // float_arg = 0.0..0.08
    GC_ACTION_TOGGLE_AB_SPLIT     = 28, // Toggle split-screen A/B compare
    GC_ACTION_SET_AB_SPLIT_POS    = 29, // float_arg = 0.05..0.95
    GC_ACTION_RESET_COLOR         = 30, // Reset color & overscan to defaults
    GC_ACTION_TOGGLE_SCENE_GUARD  = 31, // Toggle smart scene-cut & static-frame ANE guard
    GC_ACTION_USE_TEST_SIGNAL     = 32, // Quick switch to built-in 1080p demo signal
    GC_ACTION_OPEN_PRIVACY        = 33, // Open macOS Privacy & Security settings
    GC_ACTION_APP_WILL_TERMINATE  = 99,
} GcUiAction;

// ============================================================================
// Device & Format Descriptors
// ============================================================================

typedef struct {
    char uid[256];
    char name[256];
    bool is_external;
} GcDeviceInfo;

typedef struct {
    int32_t index;
    uint32_t width;
    uint32_t height;
    double max_fps;
    char label[128];
} GcVideoFormatInfo;

// ============================================================================
// Render & Telemetry Structs
// ============================================================================

typedef struct {
    int32_t upscale_mode;       // GcUpscaleMode
    int32_t aspect_mode;        // GcAspectMode
    bool    integer_lock;
    bool    hdr_enabled;        // Enable 10-bit/16-bit HDR/EDR passthrough
    float   sharpness;          // 0.0..1.0
    int32_t color_range_mode;   // 0=Auto, 1=Limited (16-235), 2=Full (0-255)
    float   contrast;           // 0.8..1.4 (default 1.0)
    float   saturation;         // 0.0..1.6 (default 1.0)
    float   gamma;              // 0.7..1.4 (default 1.0)
    float   overscan_crop;      // 0.0..0.08 (default 0.0)
    bool    ab_split_enabled;   // Split-screen A/B compare (raw left vs enhanced right)
    float   ab_split_pos;       // 0.05..0.95 (default 0.5)
    float   window_edr_headroom;// Live EDR headroom of the window's actual NSScreen
} GcRenderParams;

typedef struct {
    double   source_fps;
    double   output_fps;
    double   vt_proc_ms;
    double   gpu_render_ms;
    double   total_latency_ms;
    uint32_t source_width;
    uint32_t source_height;
    uint32_t output_width;
    uint32_t output_height;
    uint64_t dropped_frames;
    float    audio_peak;
    bool     is_recording;
    double   recording_secs;
    bool     is_paused;
    bool     is_test_pattern;
    bool     no_signal;
    bool     hdr_active;
    bool     hdr_source_10bit;
    float    edr_headroom;
    char     hdr_tag[32];
    char     fg_engine[64];
    char     up_engine[64];
    char     status_banner[128];
} GcHudMetrics;

typedef struct {
    int32_t upscale_mode;
    int32_t framegen_mode;
    int32_t aspect_mode;
    bool    integer_lock;
    bool    always_on_top;
    bool    hud_visible;
    bool    clean_view;
    bool    hdr_enabled;
    bool    audio_muted;
    float   audio_volume;
    float   sharpness;
    int32_t color_range_mode;
    float   contrast;
    float   saturation;
    float   gamma;
    float   overscan_crop;
    bool    ab_split_enabled;
    float   ab_split_pos;
    bool    scene_guard_enabled;
    bool    is_recording;
    bool    is_paused;
    int32_t glass_style;
    int32_t overlay_mode;       // GcOverlayMode (0=off, 1=match, 2=fullscreen)
    int32_t preferred_overlay;  // 1=match window, 2=fullscreen
} GcUiStateSnapshot;

// ============================================================================
// Rust Callbacks Registered with Native Layer
// ============================================================================

typedef void (*GcVideoFrameCb)(
    void *ctx,
    void *cv_pixel_buffer, // Retained by ObjC for duration of call; Rust must retain if keeping
    uint32_t width,
    uint32_t height,
    int64_t pts_ns,
    double arrival_ms
);

typedef void (*GcAudioSamplesCb)(
    void *ctx,
    const float *samples,
    uint32_t frame_count,
    uint32_t channels,
    uint32_t sample_rate,
    float peak_level
);

typedef void (*GcDevicesChangedCb)(void *ctx);
typedef void (*GcUiActionCb)(void *ctx, int32_t action, int32_t int_arg, float float_arg, const char *str_arg);
typedef void (*GcDisplayTickCb)(void *ctx, double now_ms);

typedef void (*GcVtResultCb)(
    void *ctx,
    uint64_t job_id,
    void *const *out_pixel_buffers, // Array of `count` CVPixelBufferRef (retained for call)
    uint32_t count,
    uint32_t frame_index,           // 0..total_expected-1 for streaming output
    bool is_final,                  // true on final frame of job
    double proc_ms,
    int32_t status // 0 = ok
);

typedef struct {
    void *ctx;
    GcVideoFrameCb     on_video_frame;
    GcAudioSamplesCb   on_audio_samples;
    GcDevicesChangedCb on_devices_changed;
    GcUiActionCb       on_ui_action;
    GcDisplayTickCb    on_display_tick;
    GcVtResultCb       on_vt_result;
} GcCallbacks;

// ============================================================================
// PixelBuffer Lifecycle & Utility Helpers
// ============================================================================

void *gc_pixel_buffer_retain(void *pb);
void  gc_pixel_buffer_release(void *pb);
uint32_t gc_pixel_buffer_width(void *pb);
uint32_t gc_pixel_buffer_height(void *pb);
double gc_monotonic_ms(void);
// Computes fast 64-point mean absolute luma difference (0..255) in ~1.3us for scene-cut & static-frame detection.
// Returns -1.0f if formats/dimensions differ or non-biplanar.
float  gc_pixel_buffer_luma_diff(void *pb_a, void *pb_b);
void   gc_format_local_timestamp(char *out_buf, size_t cap);

// Creates an IOSurface-backed '420v' CVPixelBuffer filled with NV12 Y/CbCr data
// Used by the Rust synthetic test-pattern generator.
void *gc_create_nv12_pixel_buffer(
    uint32_t width,
    uint32_t height,
    const uint8_t *y_plane,
    size_t y_stride,
    const uint8_t *uv_plane,
    size_t uv_stride
);

// ============================================================================
// App & Liquid Glass Window (objc/app_window.m)
// ============================================================================

void *gc_app_create(const GcCallbacks *callbacks);
void  gc_app_run(void *app); // Enters [NSApp run] on main thread
void *gc_app_get_metal_layer(void *app);
void  gc_app_set_devices(
    void *app,
    const GcDeviceInfo *video_devices, uint32_t video_count, const char *selected_video_uid,
    const GcVideoFormatInfo *formats, uint32_t format_count, int32_t selected_format_idx,
    const GcDeviceInfo *audio_devices, uint32_t audio_count, const char *selected_audio_uid
);
void  gc_app_update_ui_state(void *app, const GcUiStateSnapshot *state);
void  gc_app_update_hud_metrics(void *app, const GcHudMetrics *metrics);
void  gc_app_show_toast(void *app, const char *message);
void  gc_app_set_always_on_top(void *app, bool enabled);
void  gc_app_toggle_fullscreen(void *app);
void  gc_app_set_window_title(void *app, const char *title);
bool  gc_app_is_visible(void *app);
float gc_app_get_screen_edr_headroom(void *app);
void  gc_app_set_overlay_mode(void *app, int32_t overlay_mode, uint32_t target_window_id, int32_t target_pid);
void  gc_app_open_privacy_settings(void);

// ============================================================================
// ScreenCaptureKit Mac Game & App Window Capture (objc/screen_capture.m)
// ============================================================================

typedef struct {
    uint32_t window_id;
    int32_t  owner_pid;
    uint32_t width;
    uint32_t height;
    char     uid[64];     // "SCWIN:<window_id>"
    char     title[256];  // "AppName — WindowTitle"
} GcWindowInfo;

void *gc_screen_create(const GcCallbacks *callbacks);
void  gc_screen_destroy(void *sc);
bool  gc_screen_has_permission(void);
void  gc_screen_request_permission(void);
uint32_t gc_screen_list_windows(GcWindowInfo *out_list, uint32_t max_count);
bool  gc_screen_start_window(void *sc, uint32_t window_id, double target_fps, bool hide_cursor, bool hdr_enabled);
void  gc_screen_set_hide_cursor(void *sc, bool hide_cursor);
void  gc_screen_stop(void *sc);
bool  gc_screen_get_window_frame(uint32_t window_id, double *out_x, double *out_y, double *out_w, double *out_h);

// ============================================================================
// Capture Engine (objc/capture_engine.m)
// ============================================================================

void *gc_capture_create(const GcCallbacks *callbacks);
void  gc_capture_destroy(void *cap);
void  gc_capture_request_permissions(void *cap);
uint32_t gc_capture_list_video_devices(GcDeviceInfo *out_list, uint32_t max_count);
uint32_t gc_capture_list_audio_devices(GcDeviceInfo *out_list, uint32_t max_count);
uint32_t gc_capture_list_video_formats(const char *device_uid, GcVideoFormatInfo *out_list, uint32_t max_count);
bool  gc_capture_start_video(void *cap, const char *device_uid, int32_t format_index, bool hdr_enabled);
void  gc_capture_stop_video(void *cap);
bool  gc_capture_start_audio(void *cap, const char *device_uid);
void  gc_capture_stop_audio(void *cap);
void  gc_capture_set_audio_volume(void *cap, float volume);
void  gc_capture_set_audio_muted(void *cap, bool muted);

// ============================================================================
// VideoToolbox Hardware Processor (objc/video_processor.m)
// ============================================================================

typedef struct {
    bool     llfi_supported;
    bool     llsr_supported;
    bool     metalfx_supported;
    uint32_t llfi_max_dim;
    uint64_t llfi_max_pixels;
    char     gpu_name[128];
} GcHardwareCaps;

void  gc_hw_query_caps(GcHardwareCaps *out_caps);

void *gc_vt_create(const GcCallbacks *callbacks);
void  gc_vt_destroy(void *vt);

// Asynchronously interpolates between prev_pb and curr_pb.
// multiplier = 2 (1 interpolated frame at 0.5) or 4 (3 interpolated frames at 0.25, 0.5, 0.75).
// Automatically handles >1080p via hardware VTPixelTransferSession downscale into 1080p LLFI.
bool  gc_vt_submit_frame_gen(
    void *vt,
    uint64_t job_id,
    void *prev_pb,
    void *curr_pb,
    int32_t multiplier,
    bool also_ml_upscale,
    char *out_engine_label,
    size_t label_cap
);

// Synchronously or fast-path ML super-resolution on a single frame (returns new retained CVPixelBufferRef or NULL if resolution ineligible for LLSR).
void *gc_vt_ml_upscale_sync(
    void *vt,
    void *src_pb,
    float *out_scale_factor,
    double *out_proc_ms
);

// ============================================================================
// Metal + MetalFX Renderer (objc/metal_renderer.m)
// ============================================================================

void *gc_renderer_create(void *ca_metal_layer, const GcCallbacks *callbacks);
void  gc_renderer_destroy(void *renderer);
void  gc_renderer_present(
    void *renderer,
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
);
bool  gc_renderer_save_screenshot(void *renderer, void *cv_pixel_buffer, const char *png_path);

// ============================================================================
// Hardware HEVC Recorder (objc/recorder.m)
// ============================================================================

void *gc_recorder_start(const char *mov_path, uint32_t width, uint32_t height, double fps, bool with_audio);
void  gc_recorder_append_video(void *rec, void *cv_pixel_buffer, int64_t pts_ns);
void  gc_recorder_append_audio(void *rec, const float *interleaved_stereo, uint32_t frame_count, uint32_t sample_rate, int64_t pts_ns);
void  gc_recorder_stop(void *rec);

#ifdef __cplusplus
}
#endif

#endif // GLASS_CAPTURE_BRIDGE_H
