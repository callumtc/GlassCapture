#![allow(dead_code)]

use std::ffi::{CStr, CString, c_char, c_void};
use std::ptr;

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GcUpscaleMode {
    Off = 0,
    MetalFx = 1,
    AutoMl = 2,
    SharpCas = 3,
    Integer = 4,
}

impl GcUpscaleMode {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::Off,
            1 => Self::MetalFx,
            2 => Self::AutoMl,
            3 => Self::SharpCas,
            4 => Self::Integer,
            _ => Self::AutoMl,
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Off => "Off (Native)",
            Self::MetalFx => "MetalFX Spatial",
            Self::AutoMl => "Auto ML + MetalFX",
            Self::SharpCas => "CAS Sharp",
            Self::Integer => "Pixel Integer",
        }
    }
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GcFrameGenMode {
    Off = 0,
    TwoX = 1,
    FourX = 2,
}

impl GcFrameGenMode {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::Off,
            1 => Self::TwoX,
            2 => Self::FourX,
            _ => Self::TwoX,
        }
    }

    pub fn multiplier(self) -> i32 {
        match self {
            Self::Off => 1,
            Self::TwoX => 2,
            Self::FourX => 4,
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Off => "Off (1×)",
            Self::TwoX => "2× Neural",
            Self::FourX => "4× Neural",
        }
    }
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GcAspectMode {
    Fit = 0,
    Fill = 1,
    Ratio16x9 = 2,
    Ratio4x3 = 3,
    Stretch = 4,
}

impl GcAspectMode {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::Fit,
            1 => Self::Fill,
            2 => Self::Ratio16x9,
            3 => Self::Ratio4x3,
            4 => Self::Stretch,
            _ => Self::Fit,
        }
    }
}

pub const GC_OVERLAY_OFF: i32 = 0;
pub const GC_OVERLAY_MATCH_WINDOW: i32 = 1;
pub const GC_OVERLAY_FULLSCREEN: i32 = 2;

pub const GC_ACTION_SELECT_VIDEO_DEVICE: i32 = 1;
pub const GC_ACTION_SELECT_VIDEO_FORMAT: i32 = 2;
pub const GC_ACTION_SELECT_AUDIO_DEVICE: i32 = 3;
pub const GC_ACTION_SET_AUDIO_VOLUME: i32 = 4;
pub const GC_ACTION_TOGGLE_AUDIO_MUTE: i32 = 5;
pub const GC_ACTION_SET_UPSCALE_MODE: i32 = 6;
pub const GC_ACTION_SET_FRAMEGEN_MODE: i32 = 7;
pub const GC_ACTION_SET_ASPECT_MODE: i32 = 8;
pub const GC_ACTION_TOGGLE_INTEGER_LOCK: i32 = 9;
pub const GC_ACTION_TOGGLE_ALWAYS_ON_TOP: i32 = 10;
pub const GC_ACTION_TOGGLE_HUD: i32 = 11;
pub const GC_ACTION_TOGGLE_PAUSE: i32 = 12;
pub const GC_ACTION_TAKE_SCREENSHOT: i32 = 13;
pub const GC_ACTION_TOGGLE_RECORDING: i32 = 14;
pub const GC_ACTION_TOGGLE_FULLSCREEN: i32 = 15;
pub const GC_ACTION_SET_SHARPNESS: i32 = 16;
pub const GC_ACTION_REFRESH_DEVICES: i32 = 17;
pub const GC_ACTION_SET_GLASS_STYLE: i32 = 18;
pub const GC_ACTION_TOGGLE_OVERLAY: i32 = 19;
pub const GC_ACTION_SET_OVERLAY_STYLE: i32 = 20;
pub const GC_ACTION_TOGGLE_HDR: i32 = 21;
pub const GC_ACTION_TOGGLE_CLEAN_VIEW: i32 = 22;
pub const GC_ACTION_APP_WILL_TERMINATE: i32 = 99;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GcDeviceInfo {
    pub uid: [c_char; 256],
    pub name: [c_char; 256],
    pub is_external: bool,
}

impl Default for GcDeviceInfo {
    fn default() -> Self {
        Self {
            uid: [0; 256],
            name: [0; 256],
            is_external: false,
        }
    }
}

impl GcDeviceInfo {
    pub fn from_parts(uid: &str, name: &str, is_external: bool) -> Self {
        let mut s = Self::default();
        write_cstr(&mut s.uid, uid);
        write_cstr(&mut s.name, name);
        s.is_external = is_external;
        s
    }

    pub fn uid_str(&self) -> String {
        read_cstr(&self.uid)
    }

    pub fn name_str(&self) -> String {
        read_cstr(&self.name)
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GcVideoFormatInfo {
    pub index: i32,
    pub width: u32,
    pub height: u32,
    pub max_fps: f64,
    pub label: [c_char; 128],
}

impl Default for GcVideoFormatInfo {
    fn default() -> Self {
        Self {
            index: -1,
            width: 0,
            height: 0,
            max_fps: 0.0,
            label: [0; 128],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct GcRenderParams {
    pub upscale_mode: i32,
    pub aspect_mode: i32,
    pub integer_lock: bool,
    pub hdr_enabled: bool,
    pub sharpness: f32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GcHudMetrics {
    pub source_fps: f64,
    pub output_fps: f64,
    pub vt_proc_ms: f64,
    pub gpu_render_ms: f64,
    pub total_latency_ms: f64,
    pub source_width: u32,
    pub source_height: u32,
    pub output_width: u32,
    pub output_height: u32,
    pub dropped_frames: u64,
    pub audio_peak: f32,
    pub is_recording: bool,
    pub recording_secs: f64,
    pub is_paused: bool,
    pub is_test_pattern: bool,
    pub hdr_active: bool,
    pub hdr_source_10bit: bool,
    pub edr_headroom: f32,
    pub hdr_tag: [c_char; 32],
    pub fg_engine: [c_char; 64],
    pub up_engine: [c_char; 64],
    pub status_banner: [c_char; 128],
}

impl Default for GcHudMetrics {
    fn default() -> Self {
        Self {
            source_fps: 0.0,
            output_fps: 0.0,
            vt_proc_ms: 0.0,
            gpu_render_ms: 0.0,
            total_latency_ms: 0.0,
            source_width: 0,
            source_height: 0,
            output_width: 0,
            output_height: 0,
            dropped_frames: 0,
            audio_peak: 0.0,
            is_recording: false,
            recording_secs: 0.0,
            is_paused: false,
            is_test_pattern: false,
            hdr_active: false,
            hdr_source_10bit: false,
            edr_headroom: 1.0,
            hdr_tag: [0; 32],
            fg_engine: [0; 64],
            up_engine: [0; 64],
            status_banner: [0; 128],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct GcUiStateSnapshot {
    pub upscale_mode: i32,
    pub framegen_mode: i32,
    pub aspect_mode: i32,
    pub integer_lock: bool,
    pub always_on_top: bool,
    pub hud_visible: bool,
    pub clean_view: bool,
    pub hdr_enabled: bool,
    pub audio_muted: bool,
    pub audio_volume: f32,
    pub sharpness: f32,
    pub is_recording: bool,
    pub is_paused: bool,
    pub glass_style: i32,
    pub overlay_mode: i32,
    pub preferred_overlay: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GcWindowInfo {
    pub window_id: u32,
    pub owner_pid: i32,
    pub width: u32,
    pub height: u32,
    pub uid: [c_char; 64],
    pub title: [c_char; 256],
}

impl Default for GcWindowInfo {
    fn default() -> Self {
        Self {
            window_id: 0,
            owner_pid: 0,
            width: 0,
            height: 0,
            uid: [0; 64],
            title: [0; 256],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GcHardwareCaps {
    pub llfi_supported: bool,
    pub llsr_supported: bool,
    pub metalfx_supported: bool,
    pub llfi_max_dim: u32,
    pub llfi_max_pixels: u64,
    pub gpu_name: [c_char; 128],
}

impl Default for GcHardwareCaps {
    fn default() -> Self {
        Self {
            llfi_supported: false,
            llsr_supported: false,
            metalfx_supported: false,
            llfi_max_dim: 0,
            llfi_max_pixels: 0,
            gpu_name: [0; 128],
        }
    }
}

pub type GcVideoFrameCb =
    extern "C" fn(ctx: *mut c_void, pb: *mut c_void, w: u32, h: u32, pts_ns: i64, arrival_ms: f64);
pub type GcAudioSamplesCb = extern "C" fn(
    ctx: *mut c_void,
    samples: *const f32,
    frame_count: u32,
    channels: u32,
    sample_rate: u32,
    peak_level: f32,
);
pub type GcDevicesChangedCb = extern "C" fn(ctx: *mut c_void);
pub type GcUiActionCb =
    extern "C" fn(ctx: *mut c_void, action: i32, int_arg: i32, float_arg: f32, str_arg: *const c_char);
pub type GcDisplayTickCb = extern "C" fn(ctx: *mut c_void, now_ms: f64);
pub type GcVtResultCb = extern "C" fn(
    ctx: *mut c_void,
    job_id: u64,
    out_buffers: *const *mut c_void,
    count: u32,
    frame_index: u32,
    is_final: bool,
    proc_ms: f64,
    status: i32,
);

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GcCallbacks {
    pub ctx: *mut c_void,
    pub on_video_frame: Option<GcVideoFrameCb>,
    pub on_audio_samples: Option<GcAudioSamplesCb>,
    pub on_devices_changed: Option<GcDevicesChangedCb>,
    pub on_ui_action: Option<GcUiActionCb>,
    pub on_display_tick: Option<GcDisplayTickCb>,
    pub on_vt_result: Option<GcVtResultCb>,
}

unsafe extern "C" {
    pub fn gc_pixel_buffer_retain(pb: *mut c_void) -> *mut c_void;
    pub fn gc_pixel_buffer_release(pb: *mut c_void);
    pub fn gc_pixel_buffer_width(pb: *mut c_void) -> u32;
    pub fn gc_pixel_buffer_height(pb: *mut c_void) -> u32;
    pub fn gc_monotonic_ms() -> f64;
    pub fn gc_create_nv12_pixel_buffer(
        width: u32,
        height: u32,
        y_plane: *const u8,
        y_stride: usize,
        uv_plane: *const u8,
        uv_stride: usize,
    ) -> *mut c_void;

    pub fn gc_hw_query_caps(out_caps: *mut GcHardwareCaps);

    pub fn gc_app_create(callbacks: *const GcCallbacks) -> *mut c_void;
    pub fn gc_app_run(app: *mut c_void);
    pub fn gc_app_get_metal_layer(app: *mut c_void) -> *mut c_void;
    pub fn gc_app_set_devices(
        app: *mut c_void,
        video_devices: *const GcDeviceInfo,
        video_count: u32,
        selected_video_uid: *const c_char,
        formats: *const GcVideoFormatInfo,
        format_count: u32,
        selected_format_idx: i32,
        audio_devices: *const GcDeviceInfo,
        audio_count: u32,
        selected_audio_uid: *const c_char,
    );
    pub fn gc_app_update_ui_state(app: *mut c_void, state: *const GcUiStateSnapshot);
    pub fn gc_app_update_hud_metrics(app: *mut c_void, metrics: *const GcHudMetrics);
    pub fn gc_app_show_toast(app: *mut c_void, message: *const c_char);
    pub fn gc_app_set_always_on_top(app: *mut c_void, enabled: bool);
    pub fn gc_app_toggle_fullscreen(app: *mut c_void);
    pub fn gc_app_set_window_title(app: *mut c_void, title: *const c_char);
    pub fn gc_app_is_visible(app: *mut c_void) -> bool;
    pub fn gc_app_set_overlay_mode(app: *mut c_void, overlay_mode: i32, target_window_id: u32, target_pid: i32);

    pub fn gc_screen_create(callbacks: *const GcCallbacks) -> *mut c_void;
    pub fn gc_screen_destroy(sc: *mut c_void);
    pub fn gc_screen_has_permission() -> bool;
    pub fn gc_screen_request_permission();
    pub fn gc_screen_list_windows(out_list: *mut GcWindowInfo, max_count: u32) -> u32;
    pub fn gc_screen_start_window(
        sc: *mut c_void,
        window_id: u32,
        target_fps: f64,
        hide_cursor: bool,
        hdr_enabled: bool,
    ) -> bool;
    pub fn gc_screen_set_hide_cursor(sc: *mut c_void, hide_cursor: bool);
    pub fn gc_screen_stop(sc: *mut c_void);

    pub fn gc_capture_create(callbacks: *const GcCallbacks) -> *mut c_void;
    pub fn gc_capture_destroy(cap: *mut c_void);
    pub fn gc_capture_request_permissions(cap: *mut c_void);
    pub fn gc_capture_list_video_devices(out_list: *mut GcDeviceInfo, max_count: u32) -> u32;
    pub fn gc_capture_list_audio_devices(out_list: *mut GcDeviceInfo, max_count: u32) -> u32;
    pub fn gc_capture_list_video_formats(
        device_uid: *const c_char,
        out_list: *mut GcVideoFormatInfo,
        max_count: u32,
    ) -> u32;
    pub fn gc_capture_start_video(
        cap: *mut c_void,
        device_uid: *const c_char,
        format_index: i32,
        hdr_enabled: bool,
    ) -> bool;
    pub fn gc_capture_stop_video(cap: *mut c_void);
    pub fn gc_capture_start_audio(cap: *mut c_void, device_uid: *const c_char) -> bool;
    pub fn gc_capture_stop_audio(cap: *mut c_void);
    pub fn gc_capture_set_audio_volume(cap: *mut c_void, volume: f32);
    pub fn gc_capture_set_audio_muted(cap: *mut c_void, muted: bool);

    pub fn gc_vt_create(callbacks: *const GcCallbacks) -> *mut c_void;
    pub fn gc_vt_destroy(vt: *mut c_void);
    pub fn gc_vt_submit_frame_gen(
        vt: *mut c_void,
        job_id: u64,
        prev_pb: *mut c_void,
        curr_pb: *mut c_void,
        multiplier: i32,
        also_ml_upscale: bool,
        out_engine_label: *mut c_char,
        label_cap: usize,
    ) -> bool;
    pub fn gc_vt_ml_upscale_sync(
        vt: *mut c_void,
        src_pb: *mut c_void,
        out_scale_factor: *mut f32,
        out_proc_ms: *mut f64,
    ) -> *mut c_void;

    pub fn gc_renderer_create(ca_metal_layer: *mut c_void, callbacks: *const GcCallbacks) -> *mut c_void;
    pub fn gc_renderer_destroy(renderer: *mut c_void);
    pub fn gc_renderer_present(
        renderer: *mut c_void,
        cv_pixel_buffer: *mut c_void,
        params: *const GcRenderParams,
        out_drawable_w: *mut u32,
        out_drawable_h: *mut u32,
        out_gpu_ms: *mut f64,
        out_up_engine: *mut c_char,
        out_up_engine_cap: usize,
        out_hdr_active: *mut bool,
        out_hdr_source_10bit: *mut bool,
        out_edr_headroom: *mut f32,
        out_hdr_tag: *mut c_char,
        out_hdr_tag_cap: usize,
    );
    pub fn gc_renderer_save_screenshot(
        renderer: *mut c_void,
        cv_pixel_buffer: *mut c_void,
        png_path: *const c_char,
    ) -> bool;

    pub fn gc_recorder_start(
        mov_path: *const c_char,
        width: u32,
        height: u32,
        fps: f64,
        with_audio: bool,
    ) -> *mut c_void;
    pub fn gc_recorder_append_video(rec: *mut c_void, cv_pixel_buffer: *mut c_void, pts_ns: i64);
    pub fn gc_recorder_append_audio(
        rec: *mut c_void,
        interleaved_stereo: *const f32,
        frame_count: u32,
        sample_rate: u32,
        pts_ns: i64,
    );
    pub fn gc_recorder_stop(rec: *mut c_void);
}

// ============================================================================
// Safe RAII Wrapper Around CVPixelBufferRef
// ============================================================================

pub struct PixelBuffer {
    ptr: *mut c_void,
}

unsafe impl Send for PixelBuffer {}
unsafe impl Sync for PixelBuffer {}

impl PixelBuffer {
    /// Retains a borrowed CVPixelBufferRef safely.
    pub fn retain_from_raw(raw: *mut c_void) -> Option<Self> {
        if raw.is_null() {
            return None;
        }
        let retained = unsafe { gc_pixel_buffer_retain(raw) };
        if retained.is_null() {
            None
        } else {
            Some(Self { ptr: retained })
        }
    }

    /// Takes ownership of an already-retained CVPixelBufferRef (no extra retain).
    pub fn take_owned(raw: *mut c_void) -> Option<Self> {
        if raw.is_null() {
            None
        } else {
            Some(Self { ptr: raw })
        }
    }

    pub fn as_ptr(&self) -> *mut c_void {
        self.ptr
    }

    pub fn width(&self) -> u32 {
        unsafe { gc_pixel_buffer_width(self.ptr) }
    }

    pub fn height(&self) -> u32 {
        unsafe { gc_pixel_buffer_height(self.ptr) }
    }
}

impl Clone for PixelBuffer {
    fn clone(&self) -> Self {
        let retained = unsafe { gc_pixel_buffer_retain(self.ptr) };
        Self { ptr: retained }
    }
}

impl Drop for PixelBuffer {
    fn drop(&mut self) {
        if !self.ptr.is_null() {
            unsafe { gc_pixel_buffer_release(self.ptr) };
            self.ptr = ptr::null_mut();
        }
    }
}

// ============================================================================
// C String Helpers
// ============================================================================

pub fn write_cstr<const N: usize>(buf: &mut [c_char; N], s: &str) {
    buf.fill(0);
    let bytes = s.as_bytes();
    let max_len = N.saturating_sub(1);
    let copy_len = bytes.len().min(max_len);
    for i in 0..copy_len {
        buf[i] = bytes[i] as c_char;
    }
}

pub fn read_cstr(buf: &[c_char]) -> String {
    unsafe {
        CStr::from_ptr(buf.as_ptr())
            .to_string_lossy()
            .into_owned()
    }
}

pub fn to_cstring(s: &str) -> CString {
    CString::new(s).unwrap_or_else(|_| CString::new("").unwrap())
}

pub fn monotonic_ms() -> f64 {
    unsafe { gc_monotonic_ms() }
}

pub fn query_hardware_caps() -> GcHardwareCaps {
    let mut caps = GcHardwareCaps::default();
    unsafe { gc_hw_query_caps(&mut caps) };
    caps
}
