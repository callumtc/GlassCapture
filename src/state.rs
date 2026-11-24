use crate::config::AppConfig;
use crate::ffi::*;
use crate::pacer::{FramePacer, IngestOutcome, VtJobRequest};
use crate::telemetry::Telemetry;
use crate::test_pattern::{
    TEST_PATTERN_30_720P_UID, TEST_PATTERN_30_1080P_UID, TEST_PATTERN_60_1080P_UID,
    TestPatternRunner,
};
use std::ffi::{CStr, c_char, c_void};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

pub const SCREEN_PERM_PROMPT_UID: &str = "__GLASS_ENABLE_SCREEN_CAPTURE__";

pub struct NativeHandles {
    pub app: *mut c_void,
    pub capture: *mut c_void,
    pub screen_capture: *mut c_void,
    pub vt: *mut c_void,
    pub renderer: *mut c_void,
}

unsafe impl Send for NativeHandles {}
unsafe impl Sync for NativeHandles {}

struct RecorderHandle {
    raw: *mut c_void,
    started_ms: f64,
    path: String,
}

unsafe impl Send for RecorderHandle {}

struct RuntimeState {
    config: AppConfig,
    is_paused: bool,
    is_test_pattern: bool,
    clean_view: bool,
    overlay_mode: i32,
    active_window_id: u32,
    active_window_pid: i32,
    video_devices: Vec<GcDeviceInfo>,
    mac_windows: Vec<GcWindowInfo>,
    video_formats: Vec<GcVideoFormatInfo>,
    audio_devices: Vec<GcDeviceInfo>,
    test_runner: Option<TestPatternRunner>,
}

pub struct AppController {
    handles: OnceLock<NativeHandles>,
    state: Mutex<RuntimeState>,
    pacer: Mutex<FramePacer>,
    telemetry: Mutex<Telemetry>,
    last_presented: Mutex<Option<PixelBuffer>>,
    recorder: Mutex<Option<RecorderHandle>>,
    shutting_down: AtomicBool,
    // Lock-free hot-path flags (keeps 120Hz VSync callback zero-contention)
    has_queued_frames: AtomicBool,
    is_paused_fast: AtomicBool,
    is_recording_fast: AtomicBool,
    upscale_mode_fast: AtomicI32,
    framegen_mode_fast: AtomicI32,
    scene_guard_fast: AtomicBool,
    last_hud_tick_ms_bits: AtomicU64,
    caps: GcHardwareCaps,
}

impl AppController {
    pub fn new(force_test_pattern: bool) -> Arc<Self> {
        let mut config = AppConfig::load();
        if force_test_pattern {
            config.selected_video_uid = TEST_PATTERN_30_1080P_UID.to_string();
        }
        let up_fast = config.upscale_mode as i32;
        let fg_fast = config.framegen_mode as i32;
        let sg_fast = config.scene_guard_enabled;
        let caps = query_hardware_caps();
        Arc::new(Self {
            handles: OnceLock::new(),
            state: Mutex::new(RuntimeState {
                config,
                is_paused: false,
                is_test_pattern: force_test_pattern,
                clean_view: false,
                overlay_mode: GC_OVERLAY_OFF,
                active_window_id: 0,
                active_window_pid: 0,
                video_devices: Vec::new(),
                mac_windows: Vec::new(),
                video_formats: Vec::new(),
                audio_devices: Vec::new(),
                test_runner: None,
            }),
            pacer: Mutex::new(FramePacer::new()),
            telemetry: Mutex::new(Telemetry::new()),
            last_presented: Mutex::new(None),
            recorder: Mutex::new(None),
            shutting_down: AtomicBool::new(false),
            has_queued_frames: AtomicBool::new(false),
            is_paused_fast: AtomicBool::new(false),
            is_recording_fast: AtomicBool::new(false),
            upscale_mode_fast: AtomicI32::new(up_fast),
            framegen_mode_fast: AtomicI32::new(fg_fast),
            scene_guard_fast: AtomicBool::new(sg_fast),
            last_hud_tick_ms_bits: AtomicU64::new(0),
            caps,
        })
    }

    pub fn set_handles(&self, handles: NativeHandles) {
        let _ = self.handles.set(handles);
    }

    pub fn startup(self: &Arc<Self>) {
        let Some(h) = self.handles.get() else {
            return;
        };
        unsafe { gc_capture_request_permissions(h.capture) };

        self.refresh_devices(true);

        let (ui_snap, always_on_top) = {
            let st = self.state.lock().unwrap();
            let rec = self.recorder.lock().unwrap().is_some();
            (
                st.config
                    .to_ui_snapshot(rec, st.is_paused, st.overlay_mode, st.clean_view),
                st.config.always_on_top,
            )
        };
        unsafe {
            gc_app_update_ui_state(h.app, &ui_snap);
            gc_app_set_always_on_top(h.app, always_on_top);
            gc_capture_set_audio_volume(h.capture, ui_snap.audio_volume);
            gc_capture_set_audio_muted(h.capture, ui_snap.audio_muted);
        }

        let gpu = read_cstr(&self.caps.gpu_name);
        let msg = format!(
            "{} · VT Neural FG: {} · MetalFX: {}",
            gpu,
            if self.caps.llfi_supported { "Ready" } else { "Off" },
            if self.caps.metalfx_supported { "Ready" } else { "Off" }
        );
        self.toast(&msg);
    }

    fn toast(&self, msg: &str) {
        if let Some(h) = self.handles.get() {
            let c = to_cstring(msg);
            unsafe { gc_app_show_toast(h.app, c.as_ptr()) };
        }
    }

    fn push_ui_state(&self) {
        let Some(h) = self.handles.get() else {
            return;
        };
        let rec = self.recorder.lock().unwrap().is_some();
        let snap = {
            let st = self.state.lock().unwrap();
            st.config
                .to_ui_snapshot(rec, st.is_paused, st.overlay_mode, st.clean_view)
        };
        unsafe { gc_app_update_ui_state(h.app, &snap) };
    }

    fn refresh_devices(self: &Arc<Self>, force_restart: bool) {
        let mut raw_video = vec![GcDeviceInfo::default(); 32];
        let v_count = unsafe { gc_capture_list_video_devices(raw_video.as_mut_ptr(), 32) } as usize;
        raw_video.truncate(v_count);

        // Discover on-screen Mac Games & App Windows via ScreenCaptureKit!
        let mut raw_windows = vec![GcWindowInfo::default(); 40];
        let w_count = unsafe { gc_screen_list_windows(raw_windows.as_mut_ptr(), 40) } as usize;
        raw_windows.truncate(w_count);

        if w_count > 0 {
            for win in &raw_windows {
                let uid = read_cstr(&win.uid);
                let title = format!("🪟 {}", read_cstr(&win.title));
                raw_video.push(GcDeviceInfo::from_parts(&uid, &title, false));
            }
        } else if !unsafe { gc_screen_has_permission() } {
            raw_video.push(GcDeviceInfo::from_parts(
                SCREEN_PERM_PROMPT_UID,
                "🔓 Enable Mac Game & App Window Capture…",
                false,
            ));
        }

        // Append built-in synthetic test patterns
        raw_video.push(GcDeviceInfo::from_parts(
            TEST_PATTERN_30_1080P_UID,
            "Test Signal · 1080p 30fps (Frame Gen Demo)",
            false,
        ));
        raw_video.push(GcDeviceInfo::from_parts(
            TEST_PATTERN_30_720P_UID,
            "Test Signal · 720p 30fps (ML Super-Res + FG Demo)",
            false,
        ));
        raw_video.push(GcDeviceInfo::from_parts(
            TEST_PATTERN_60_1080P_UID,
            "Test Signal · 1080p 60fps (120Hz ProMotion Demo)",
            false,
        ));

        let mut raw_audio = vec![GcDeviceInfo::default(); 32];
        let a_count = unsafe { gc_capture_list_audio_devices(raw_audio.as_mut_ptr(), 32) } as usize;
        raw_audio.truncate(a_count);

        let (prev_video_uid, chosen_video_uid, chosen_fmt_idx, prev_audio_uid, chosen_audio_uid) = {
            let mut st = self.state.lock().unwrap();
            let prev_v = st.config.selected_video_uid.clone();
            let prev_a = st.config.selected_audio_uid.clone();
            st.video_devices = raw_video.clone();
            st.mac_windows = raw_windows;
            st.audio_devices = raw_audio.clone();

            let saved_exists = !st.config.selected_video_uid.is_empty()
                && raw_video.iter().any(|d| d.uid_str() == st.config.selected_video_uid);

            if !saved_exists {
                let preferred_external = raw_video.iter().find(|d| {
                    d.is_external && !d.name_str().to_lowercase().contains("virtual")
                });
                if let Some(ext) = preferred_external {
                    st.config.selected_video_uid = ext.uid_str();
                    st.config.selected_format_index = -1;
                } else {
                    st.config.selected_video_uid = TEST_PATTERN_30_1080P_UID.to_string();
                    st.config.selected_format_index = -1;
                }
            }

            let audio_exists = !st.config.selected_audio_uid.is_empty()
                && raw_audio.iter().any(|d| d.uid_str() == st.config.selected_audio_uid);
            if !audio_exists {
                if let Some(ext_audio) = raw_audio.iter().find(|d| d.is_external) {
                    st.config.selected_audio_uid = ext_audio.uid_str();
                } else {
                    st.config.selected_audio_uid.clear();
                }
            }

            (
                prev_v,
                st.config.selected_video_uid.clone(),
                st.config.selected_format_index,
                prev_a,
                st.config.selected_audio_uid.clone(),
            )
        };

        if force_restart || prev_video_uid != chosen_video_uid {
            self.start_video_source(&chosen_video_uid, chosen_fmt_idx);
        }
        if (force_restart || prev_audio_uid != chosen_audio_uid) && !chosen_audio_uid.is_empty() {
            self.start_audio_source(&chosen_audio_uid);
        }
        self.sync_device_lists_to_ui();
    }

    fn sync_device_lists_to_ui(&self) {
        let Some(h) = self.handles.get() else {
            return;
        };
        let (v_devs, v_uid, fmts, fmt_idx, a_devs, a_uid) = {
            let st = self.state.lock().unwrap();
            (
                st.video_devices.clone(),
                st.config.selected_video_uid.clone(),
                st.video_formats.clone(),
                st.config.selected_format_index,
                st.audio_devices.clone(),
                st.config.selected_audio_uid.clone(),
            )
        };
        let cv = to_cstring(&v_uid);
        let ca = to_cstring(&a_uid);
        unsafe {
            gc_app_set_devices(
                h.app,
                v_devs.as_ptr(),
                v_devs.len() as u32,
                cv.as_ptr(),
                fmts.as_ptr(),
                fmts.len() as u32,
                fmt_idx,
                a_devs.as_ptr(),
                a_devs.len() as u32,
                ca.as_ptr(),
            );
        }
    }

    fn start_video_source(self: &Arc<Self>, uid: &str, requested_format_index: i32) {
        let Some(h) = self.handles.get() else {
            return;
        };

        // Stop any existing test pattern, live capture card, or ScreenCaptureKit stream
        {
            let mut st = self.state.lock().unwrap();
            if let Some(mut runner) = st.test_runner.take() {
                drop(st);
                runner.stop();
            }
        }
        unsafe {
            gc_capture_stop_video(h.capture);
            gc_screen_stop(h.screen_capture);
        }
        self.pacer.lock().unwrap().reset();
        self.has_queued_frames.store(false, Ordering::Release);

        // User clicked "Enable Mac Game & App Window Capture..." -> request Screen Recording permission!
        if uid == SCREEN_PERM_PROMPT_UID {
            unsafe { gc_screen_request_permission() };
            self.toast("Grant Screen Recording in System Settings, then click Refresh (↻)");
            self.sync_device_lists_to_ui();
            return;
        }

        // Mac Game / App Window via ScreenCaptureKit ("SCWIN:<window_id>")
        if let Some(id_str) = uid.strip_prefix("SCWIN:") {
            if let Ok(win_id) = id_str.parse::<u32>() {
                let target_fps = match requested_format_index {
                    1 => 30.0,
                    2 => 120.0,
                    _ => 60.0,
                };
                let (owner_pid, overlay_active, win_w, win_h, hdr_on) = {
                    let st = self.state.lock().unwrap();
                    let found = st.mac_windows.iter().find(|w| w.window_id == win_id);
                    (
                        found.map(|w| w.owner_pid).unwrap_or(0),
                        st.overlay_mode != GC_OVERLAY_OFF,
                        found.map(|w| w.width).unwrap_or(1920),
                        found.map(|w| w.height).unwrap_or(1080),
                        st.config.hdr_enabled,
                    )
                };

                let ok = unsafe {
                    gc_screen_start_window(h.screen_capture, win_id, target_fps, overlay_active, hdr_on)
                };

                let mut fmts = Vec::new();
                for (idx, fps, lbl) in [
                    (0, 60.0, format!("{}×{} @ 60 fps", win_w, win_h)),
                    (1, 30.0, format!("{}×{} @ 30 fps", win_w, win_h)),
                    (2, 120.0, format!("{}×{} @ 120 fps", win_w, win_h)),
                ] {
                    let mut f = GcVideoFormatInfo {
                        index: idx,
                        width: win_w,
                        height: win_h,
                        max_fps: fps,
                        label: [0; 128],
                    };
                    write_cstr(&mut f.label, &lbl);
                    fmts.push(f);
                }

                let chosen_fmt = if requested_format_index >= 0 && requested_format_index <= 2 {
                    requested_format_index
                } else {
                    0
                };

                {
                    let mut st = self.state.lock().unwrap();
                    st.is_test_pattern = false;
                    st.active_window_id = win_id;
                    st.active_window_pid = owner_pid;
                    st.video_formats = fmts;
                    st.config.selected_video_uid = uid.to_string();
                    st.config.selected_format_index = chosen_fmt;
                    st.config.save();
                }
                self.sync_device_lists_to_ui();
                if ok {
                    self.toast("Capturing Mac Window — Press ⌘⇧O to Overlay on Game!");
                } else {
                    self.toast("Grant Screen Recording permission in System Settings → Privacy");
                }
                return;
            }
        }

        // Clear active Mac window ID when switching to capture card / test signal
        {
            let mut st = self.state.lock().unwrap();
            st.active_window_id = 0;
            st.active_window_pid = 0;
        }

        // Built-in synthetic test pattern?
        let test_spec = match uid {
            TEST_PATTERN_30_1080P_UID => Some((1920u32, 1080u32, 30.0f64, "1920×1080 @ 30 fps")),
            TEST_PATTERN_30_720P_UID => Some((1280u32, 720u32, 30.0f64, "1280×720 @ 30 fps")),
            TEST_PATTERN_60_1080P_UID => Some((1920u32, 1080u32, 60.0f64, "1920×1080 @ 60 fps")),
            _ => None,
        };

        if let Some((w, h_px, fps, label)) = test_spec {
            let mut fmt = GcVideoFormatInfo {
                index: 0,
                width: w,
                height: h_px,
                max_fps: fps,
                label: [0; 128],
            };
            write_cstr(&mut fmt.label, label);

            let me = Arc::clone(self);
            let runner = TestPatternRunner::start(w, h_px, fps, move |pb, fw, fh, pts_ns, now_ms| {
                me.handle_incoming_frame(pb, fw, fh, pts_ns, now_ms);
            });

            {
                let mut st = self.state.lock().unwrap();
                st.is_test_pattern = true;
                st.video_formats = vec![fmt];
                st.config.selected_video_uid = uid.to_string();
                st.config.selected_format_index = 0;
                st.test_runner = Some(runner);
                st.config.save();
            }
            self.sync_device_lists_to_ui();
            return;
        }

        // Real capture card / camera device
        let uid_c = to_cstring(uid);
        let mut fmts = vec![GcVideoFormatInfo::default(); 64];
        let f_count = unsafe { gc_capture_list_video_formats(uid_c.as_ptr(), fmts.as_mut_ptr(), 64) } as usize;
        fmts.truncate(f_count);

        let chosen_idx = if requested_format_index >= 0
            && fmts.iter().any(|f| f.index == requested_format_index)
        {
            requested_format_index
        } else {
            // Prefer 1080p60 if available (ideal for LLFI + MetalFX), else highest sorted format
            fmts.iter()
                .find(|f| f.width == 1920 && f.height == 1080 && f.max_fps >= 59.0)
                .or_else(|| fmts.first())
                .map(|f| f.index)
                .unwrap_or(-1)
        };

        let hdr_on = self.state.lock().unwrap().config.hdr_enabled;
        let ok = unsafe { gc_capture_start_video(h.capture, uid_c.as_ptr(), chosen_idx, hdr_on) };
        {
            let mut st = self.state.lock().unwrap();
            st.is_test_pattern = false;
            st.video_formats = fmts;
            st.config.selected_video_uid = uid.to_string();
            st.config.selected_format_index = chosen_idx;
            st.config.save();
        }
        self.sync_device_lists_to_ui();
        if !ok {
            self.toast("Could not start video device — check Camera permission in System Settings");
        }
    }

    fn start_audio_source(&self, uid: &str) {
        let Some(h) = self.handles.get() else {
            return;
        };
        if uid.is_empty() {
            unsafe { gc_capture_stop_audio(h.capture) };
        } else {
            let c = to_cstring(uid);
            unsafe { gc_capture_start_audio(h.capture, c.as_ptr()) };
        }
        {
            let mut st = self.state.lock().unwrap();
            st.config.selected_audio_uid = uid.to_string();
            st.config.save();
        }
    }

    // ========================================================================
    // Hot-Path Video Pipeline (Capture -> VT Neural Frame Gen -> Display Link -> MetalFX)
    // ========================================================================

    fn maybe_ml_upscale(&self, pb: PixelBuffer, fg_mode: GcFrameGenMode) -> (PixelBuffer, Option<String>) {
        // When Frame Gen is active on <=720p, run Frame Gen natively at 720p (~3.6-10.8ms) and let MetalFX Spatial (0.6ms)
        // upscale to Retina instead of blocking the capture thread on 2 sequential ANE passes!
        if fg_mode != GcFrameGenMode::Off
            || self.upscale_mode_fast.load(Ordering::Relaxed) != GcUpscaleMode::AutoMl as i32
            || !self.caps.llsr_supported
            || pb.width() > 1280
            || pb.height() > 1280
        {
            return (pb, None);
        }
        let Some(h) = self.handles.get() else {
            return (pb, None);
        };
        let mut scale = 1.0f32;
        let mut sr_ms = 0.0f64;
        let sr_raw = unsafe { gc_vt_ml_upscale_sync(h.vt, pb.as_ptr(), &mut scale, &mut sr_ms) };
        if let Some(sr_pb) = PixelBuffer::take_owned(sr_raw) {
            (sr_pb, Some(format!("VT ML {:.1}×", scale)))
        } else {
            (pb, None)
        }
    }

    fn dispatch_vt_request(&self, req: VtJobRequest) {
        let Some(h) = self.handles.get() else {
            return;
        };
        let mut label_buf = [0 as c_char; 64];
        let submitted = unsafe {
            gc_vt_submit_frame_gen(
                h.vt,
                req.job_id,
                req.prev_frame.as_ptr(),
                req.curr_frame.as_ptr(),
                req.multiplier,
                false,
                label_buf.as_mut_ptr(),
                label_buf.len(),
            )
        };
        if submitted {
            let mut lbl = read_cstr(&label_buf);
            if req.capped_to_120hz {
                lbl = "VT Neural 2× (120Hz)".to_string();
            }
            if !lbl.is_empty() {
                let mut tel = self.telemetry.lock().unwrap();
                if tel.fg_engine != lbl {
                    tel.fg_engine = lbl;
                }
            }
        } else {
            let mut pacer = self.pacer.lock().unwrap();
            let _ = pacer.on_vt_complete(req.job_id, Vec::new(), -1, monotonic_ms(), false, |_, _| -1.0);
            self.has_queued_frames.store(pacer.has_frames(), Ordering::Release);
        }
    }

    pub fn handle_incoming_frame(
        &self,
        pb: PixelBuffer,
        width: u32,
        height: u32,
        pts_ns: i64,
        arrival_ms: f64,
    ) {
        if self.shutting_down.load(Ordering::Relaxed)
            || self.is_paused_fast.load(Ordering::Relaxed)
        {
            return;
        }
        let Some(h) = self.handles.get() else {
            return;
        };

        // Power-saving occlusion check: skip ANE/GPU work when minimized or hidden (unless recording!)
        if !self.is_recording_fast.load(Ordering::Relaxed) && unsafe { !gc_app_is_visible(h.app) } {
            return;
        }

        let fg_mode = GcFrameGenMode::from_i32(self.framegen_mode_fast.load(Ordering::Relaxed));
        let scene_guard = self.scene_guard_fast.load(Ordering::Relaxed);

        {
            let mut tel = self.telemetry.lock().unwrap();
            tel.record_source_frame(arrival_ms, width, height);
            if fg_mode == GcFrameGenMode::Off {
                tel.fg_engine = "Off".to_string();
                tel.vt_proc_ms = 0.0;
            }
        }

        let (work_pb, ml_prefix) = self.maybe_ml_upscale(pb, fg_mode);

        let (job, outcome, has_any) = {
            let mut pacer = self.pacer.lock().unwrap();
            let luma_diff = if scene_guard && fg_mode != GcFrameGenMode::Off {
                match pacer.last_real_frame_ref() {
                    Some(prev) => unsafe { gc_pixel_buffer_luma_diff(prev.as_ptr(), work_pb.as_ptr()) },
                    None => -1.0,
                }
            } else {
                -1.0
            };
            let (req, out) = pacer.ingest_real_frame(
                work_pb,
                pts_ns,
                arrival_ms,
                fg_mode,
                ml_prefix,
                scene_guard,
                luma_diff,
            );
            (req, out, pacer.has_frames())
        };
        if has_any {
            self.has_queued_frames.store(true, Ordering::Release);
        }

        match outcome {
            IngestOutcome::StaticSkippedAne => {
                let mut tel = self.telemetry.lock().unwrap();
                tel.fg_engine = "VT Neural (Idle)".to_string();
                tel.vt_proc_ms = 0.0;
            }
            IngestOutcome::SceneCutBypassed => {
                let mut tel = self.telemetry.lock().unwrap();
                tel.fg_engine = "VT Neural (Cut)".to_string();
            }
            _ => {}
        }

        if let Some(req) = job {
            self.dispatch_vt_request(req);
        }
    }

    pub fn handle_vt_result(
        &self,
        job_id: u64,
        out_buffers: Vec<PixelBuffer>,
        _frame_index: u32,
        _is_final: bool,
        proc_ms: f64,
        status: i32,
    ) {
        if self.shutting_down.load(Ordering::Relaxed) {
            return;
        }
        let now_ms = monotonic_ms();
        if status == 0 {
            self.telemetry.lock().unwrap().record_vt_proc(proc_ms);
        }
        let scene_guard = self.scene_guard_fast.load(Ordering::Relaxed);
        let (chained_req, has_any) = {
            let mut pacer = self.pacer.lock().unwrap();
            let next = pacer.on_vt_complete(
                job_id,
                out_buffers,
                status,
                now_ms,
                scene_guard,
                |prev, curr| unsafe { gc_pixel_buffer_luma_diff(prev.as_ptr(), curr.as_ptr()) },
            );
            (next, pacer.has_frames())
        };
        if has_any {
            self.has_queued_frames.store(true, Ordering::Release);
        }
        if let Some(req) = chained_req {
            self.dispatch_vt_request(req);
        }
    }

    pub fn handle_display_tick(&self, now_ms: f64) {
        if self.shutting_down.load(Ordering::Relaxed) {
            return;
        }
        let Some(h) = self.handles.get() else {
            return;
        };

        let is_rec = self.is_recording_fast.load(Ordering::Relaxed);
        if !is_rec && unsafe { !gc_app_is_visible(h.app) } {
            return;
        }

        // Ultra-fast lock-free check: skip mutexes completely on idle VSync ticks!
        let has_queued = self.has_queued_frames.load(Ordering::Acquire);
        let last_hud = f64::from_bits(self.last_hud_tick_ms_bits.load(Ordering::Relaxed));
        let hud_due = (now_ms - last_hud) >= 100.0;
        if !has_queued && !hud_due {
            return;
        }

        let is_paused = self.is_paused_fast.load(Ordering::Relaxed);
        let due = if is_paused || !has_queued {
            None
        } else {
            let mut pacer = self.pacer.lock().unwrap();
            let f = pacer.pop_due_frame(now_ms);
            self.has_queued_frames.store(pacer.has_frames(), Ordering::Release);
            f
        };

        if let Some(frame) = due {
            let win_edr = unsafe { gc_app_get_screen_edr_headroom(h.app) };
            let render_params = {
                let st = self.state.lock().unwrap();
                GcRenderParams {
                    upscale_mode: st.config.upscale_mode as i32,
                    aspect_mode: st.config.aspect_mode as i32,
                    integer_lock: st.config.integer_lock,
                    hdr_enabled: st.config.hdr_enabled,
                    sharpness: st.config.sharpness,
                    color_range_mode: st.config.color_range_mode,
                    contrast: st.config.contrast,
                    saturation: st.config.saturation,
                    gamma: st.config.gamma,
                    overscan_crop: st.config.overscan_crop,
                    ab_split_enabled: st.config.ab_split_enabled,
                    ab_split_pos: st.config.ab_split_pos,
                    window_edr_headroom: win_edr,
                }
            };

            let present_pb = frame.buffer;

            // Forward upscaled/frame-gen frame to Hardware HEVC recorder if active
            if is_rec {
                if let Ok(rec_guard) = self.recorder.lock() {
                    if let Some(rec) = rec_guard.as_ref() {
                        unsafe { gc_recorder_append_video(rec.raw, present_pb.as_ptr(), frame.pts_ns) };
                    }
                }
            }

            let mut out_w = 0u32;
            let mut out_h = 0u32;
            let mut gpu_ms = 0.0f64;
            let mut up_buf = [0 as c_char; 64];
            let mut hdr_active = false;
            let mut hdr_source_10bit = false;
            let mut edr_headroom = 1.0f32;
            let mut hdr_tag_buf = [0 as c_char; 32];

            unsafe {
                gc_renderer_present(
                    h.renderer,
                    present_pb.as_ptr(),
                    &render_params,
                    &mut out_w,
                    &mut out_h,
                    &mut gpu_ms,
                    up_buf.as_mut_ptr(),
                    up_buf.len(),
                    &mut hdr_active,
                    &mut hdr_source_10bit,
                    &mut edr_headroom,
                    hdr_tag_buf.as_mut_ptr(),
                    hdr_tag_buf.len(),
                );
            }

            *self.last_presented.lock().unwrap() = Some(present_pb);

            if out_w > 0 && out_h > 0 {
                let metal_label = read_cstr(&up_buf);
                let combined_up = match frame.ml_prefix {
                    Some(prefix) => format!("{} + {}", prefix, metal_label),
                    None => metal_label,
                };
                let hdr_tag = read_cstr(&hdr_tag_buf);

                let end_to_end_ms = monotonic_ms() - frame.source_arrival_ms;
                let dropped = self.pacer.lock().unwrap().dropped_frames;

                let mut tel = self.telemetry.lock().unwrap();
                tel.dropped_frames = dropped;
                tel.hdr_active = hdr_active;
                tel.hdr_source_10bit = hdr_source_10bit;
                tel.edr_headroom = edr_headroom;
                if tel.hdr_tag != hdr_tag {
                    tel.hdr_tag = hdr_tag;
                }
                tel.record_output_frame(now_ms, out_w, out_h, gpu_ms, end_to_end_ms, &combined_up);
            }
        }

        // Push telemetry HUD at 10 Hz
        if hud_due {
            self.last_hud_tick_ms_bits.store(now_ms.to_bits(), Ordering::Relaxed);
            let is_test = self.state.lock().unwrap().is_test_pattern;
            let (rec_active, rec_secs) = if is_rec {
                match self.recorder.lock().unwrap().as_ref() {
                    Some(r) => (true, ((now_ms - r.started_ms) / 1000.0).max(0.0)),
                    None => (false, 0.0),
                }
            } else {
                (false, 0.0)
            };
            let m = self
                .telemetry
                .lock()
                .unwrap()
                .build_metrics(now_ms, rec_active, rec_secs, is_paused, is_test);
            unsafe { gc_app_update_hud_metrics(h.app, &m) };
        }
    }

    pub fn handle_audio_samples(
        &self,
        samples: *const f32,
        frame_count: u32,
        sample_rate: u32,
        peak: f32,
    ) {
        if self.shutting_down.load(Ordering::Relaxed) {
            return;
        }
        self.telemetry.lock().unwrap().record_audio_peak(peak);
        if let Ok(rec_guard) = self.recorder.lock() {
            if let Some(rec) = rec_guard.as_ref() {
                let pts_ns = (monotonic_ms() * 1_000_000.0) as i64;
                unsafe {
                    gc_recorder_append_audio(rec.raw, samples, frame_count, sample_rate, pts_ns);
                }
            }
        }
    }

    // ========================================================================
    // UI Actions & Capture Utilities
    // ========================================================================

    pub fn handle_ui_action(self: &Arc<Self>, action: i32, int_arg: i32, float_arg: f32, str_arg: &str) {
        let Some(h) = self.handles.get() else {
            return;
        };

        match action {
            GC_ACTION_SELECT_VIDEO_DEVICE => {
                self.start_video_source(str_arg, -1);
            }
            GC_ACTION_SELECT_VIDEO_FORMAT => {
                let uid = self.state.lock().unwrap().config.selected_video_uid.clone();
                self.start_video_source(&uid, int_arg);
            }
            GC_ACTION_SELECT_AUDIO_DEVICE => {
                self.start_audio_source(str_arg);
                self.toast(if str_arg.is_empty() {
                    "Audio passthrough off"
                } else {
                    "Switched audio capture device"
                });
            }
            GC_ACTION_SET_AUDIO_VOLUME => {
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.audio_volume = float_arg.clamp(0.0, 1.0);
                    st.config.save();
                }
                unsafe { gc_capture_set_audio_volume(h.capture, float_arg.clamp(0.0, 1.0)) };
            }
            GC_ACTION_TOGGLE_AUDIO_MUTE => {
                let muted = {
                    let mut st = self.state.lock().unwrap();
                    st.config.audio_muted = !st.config.audio_muted;
                    st.config.save();
                    st.config.audio_muted
                };
                unsafe { gc_capture_set_audio_muted(h.capture, muted) };
                self.push_ui_state();
                self.toast(if muted { "Audio Muted" } else { "Audio Unmuted" });
            }
            GC_ACTION_SET_UPSCALE_MODE => {
                let mode = GcUpscaleMode::from_i32(int_arg);
                self.upscale_mode_fast.store(mode as i32, Ordering::Relaxed);
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.upscale_mode = mode;
                    st.config.save();
                }
                self.push_ui_state();
                self.toast(&format!("Upscaler: {}", mode.display_name()));
            }
            GC_ACTION_SET_FRAMEGEN_MODE => {
                let mode = GcFrameGenMode::from_i32(int_arg);
                self.framegen_mode_fast.store(mode as i32, Ordering::Relaxed);
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.framegen_mode = mode;
                    st.config.save();
                }
                self.pacer.lock().unwrap().reset();
                self.has_queued_frames.store(false, Ordering::Release);
                self.push_ui_state();
                self.toast(&format!("Frame Generation: {}", mode.display_name()));
            }
            GC_ACTION_SET_ASPECT_MODE => {
                let mode = GcAspectMode::from_i32(int_arg);
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.aspect_mode = mode;
                    st.config.save();
                }
                self.push_ui_state();
            }
            GC_ACTION_TOGGLE_INTEGER_LOCK => {
                let locked = {
                    let mut st = self.state.lock().unwrap();
                    st.config.integer_lock = !st.config.integer_lock;
                    st.config.save();
                    st.config.integer_lock
                };
                self.push_ui_state();
                self.toast(if locked {
                    "Integer 1:1 Pixel Scale Locked"
                } else {
                    "Integer Scale Unlocked"
                });
            }
            GC_ACTION_TOGGLE_ALWAYS_ON_TOP => {
                let pinned = {
                    let mut st = self.state.lock().unwrap();
                    st.config.always_on_top = !st.config.always_on_top;
                    st.config.save();
                    st.config.always_on_top
                };
                unsafe { gc_app_set_always_on_top(h.app, pinned) };
                self.push_ui_state();
                self.toast(if pinned {
                    "Always on Top (PiP) Enabled"
                } else {
                    "Always on Top Disabled"
                });
            }
            GC_ACTION_TOGGLE_HUD => {
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.hud_visible = !st.config.hud_visible;
                    st.config.save();
                }
                self.push_ui_state();
            }
            GC_ACTION_TOGGLE_PAUSE => {
                let paused = {
                    let mut st = self.state.lock().unwrap();
                    st.is_paused = !st.is_paused;
                    st.is_paused
                };
                self.is_paused_fast.store(paused, Ordering::Relaxed);
                self.push_ui_state();
                self.toast(if paused { "Video Frozen" } else { "Resumed Live Feed" });
            }
            GC_ACTION_SET_SHARPNESS => {
                let mut st = self.state.lock().unwrap();
                st.config.sharpness = float_arg.clamp(0.0, 1.0);
                st.config.save();
            }
            GC_ACTION_TOGGLE_FULLSCREEN => {
                unsafe { gc_app_toggle_fullscreen(h.app) };
            }
            GC_ACTION_REFRESH_DEVICES => {
                self.refresh_devices(false);
                if int_arg == 0 {
                    self.toast("Refreshed capture devices & Mac windows");
                }
            }
            GC_ACTION_SET_GLASS_STYLE => {
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.glass_style = int_arg;
                    st.config.save();
                }
                self.push_ui_state();
                self.toast(if int_arg == 1 {
                    "Liquid Glass: Clear"
                } else {
                    "Liquid Glass: Regular"
                });
            }
            GC_ACTION_TOGGLE_OVERLAY => {
                let (new_mode, target_win, target_pid) = {
                    let mut st = self.state.lock().unwrap();
                    if st.overlay_mode != GC_OVERLAY_OFF {
                        st.overlay_mode = GC_OVERLAY_OFF;
                    } else if st.active_window_id != 0 {
                        st.overlay_mode = if st.config.preferred_overlay == GC_OVERLAY_FULLSCREEN {
                            GC_OVERLAY_FULLSCREEN
                        } else {
                            GC_OVERLAY_MATCH_WINDOW
                        };
                    } else {
                        // Also allow Full-Screen click-through overlay on capture cards!
                        st.overlay_mode = GC_OVERLAY_FULLSCREEN;
                    }
                    (st.overlay_mode, st.active_window_id, st.active_window_pid)
                };
                unsafe {
                    gc_screen_set_hide_cursor(h.screen_capture, new_mode != GC_OVERLAY_OFF);
                    gc_app_set_overlay_mode(h.app, new_mode, target_win, target_pid);
                }
                self.push_ui_state();
                let msg = match new_mode {
                    GC_OVERLAY_MATCH_WINDOW => "Game Overlay Active (Click-Through) · Press ⌘⇧O to Exit",
                    GC_OVERLAY_FULLSCREEN => "Full-Screen Overlay Active (Click-Through) · Press ⌘⇧O to Exit",
                    _ => "Exited Overlay Mode",
                };
                self.toast(msg);
            }
            GC_ACTION_SET_OVERLAY_STYLE => {
                let style = if int_arg == GC_OVERLAY_FULLSCREEN {
                    GC_OVERLAY_FULLSCREEN
                } else {
                    GC_OVERLAY_MATCH_WINDOW
                };
                let (is_active, target_win, target_pid) = {
                    let mut st = self.state.lock().unwrap();
                    st.config.preferred_overlay = style;
                    st.config.save();
                    if st.overlay_mode != GC_OVERLAY_OFF {
                        st.overlay_mode = style;
                    }
                    (st.overlay_mode != GC_OVERLAY_OFF, st.active_window_id, st.active_window_pid)
                };
                if is_active {
                    unsafe { gc_app_set_overlay_mode(h.app, style, target_win, target_pid) };
                }
                self.push_ui_state();
                self.toast(if style == GC_OVERLAY_FULLSCREEN {
                    "Overlay Style: Full Screen"
                } else {
                    "Overlay Style: Match Game Window"
                });
            }
            GC_ACTION_TOGGLE_HDR => {
                let (hdr_on, uid, fmt_idx) = {
                    let mut st = self.state.lock().unwrap();
                    st.config.hdr_enabled = !st.config.hdr_enabled;
                    st.config.save();
                    (
                        st.config.hdr_enabled,
                        st.config.selected_video_uid.clone(),
                        st.config.selected_format_index,
                    )
                };
                // Restart active capture card or ScreenCaptureKit stream so 10-bit / 16-bit HDR stream engages immediately
                if !uid.starts_with("__GLASS_TEST_") && uid != SCREEN_PERM_PROMPT_UID && !uid.is_empty() {
                    self.start_video_source(&uid, fmt_idx);
                }
                self.push_ui_state();
                self.toast(if hdr_on {
                    "HDR / EDR Passthrough Enabled"
                } else {
                    "HDR Passthrough Off (SDR)"
                });
            }
            GC_ACTION_TOGGLE_CLEAN_VIEW => {
                let clean = {
                    let mut st = self.state.lock().unwrap();
                    st.clean_view = !st.clean_view;
                    st.clean_view
                };
                self.push_ui_state();
                if clean {
                    self.toast("Clean View — Press C or Esc to show UI");
                }
            }
            GC_ACTION_SET_COLOR_RANGE => {
                let mode = int_arg.clamp(0, 2);
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.color_range_mode = mode;
                    st.config.save();
                }
                self.push_ui_state();
                self.toast(match mode {
                    1 => "Color Range: Limited (16–235)",
                    2 => "Color Range: Full (0–255)",
                    _ => "Color Range: Auto",
                });
            }
            GC_ACTION_SET_CONTRAST => {
                let mut st = self.state.lock().unwrap();
                st.config.contrast = float_arg.clamp(0.7, 1.5);
                st.config.save();
            }
            GC_ACTION_SET_SATURATION => {
                let mut st = self.state.lock().unwrap();
                st.config.saturation = float_arg.clamp(0.0, 1.8);
                st.config.save();
            }
            GC_ACTION_SET_GAMMA => {
                let mut st = self.state.lock().unwrap();
                st.config.gamma = float_arg.clamp(0.6, 1.6);
                st.config.save();
            }
            GC_ACTION_SET_OVERSCAN => {
                let mut st = self.state.lock().unwrap();
                st.config.overscan_crop = float_arg.clamp(0.0, 0.08);
                st.config.save();
            }
            GC_ACTION_TOGGLE_AB_SPLIT => {
                let enabled = {
                    let mut st = self.state.lock().unwrap();
                    st.config.ab_split_enabled = !st.config.ab_split_enabled;
                    st.config.ab_split_enabled
                };
                self.push_ui_state();
                self.toast(if enabled {
                    "Split Compare ON: Raw (Left) vs Enhanced (Right)"
                } else {
                    "Split Compare Off"
                });
            }
            GC_ACTION_SET_AB_SPLIT_POS => {
                let mut st = self.state.lock().unwrap();
                st.config.ab_split_pos = float_arg.clamp(0.05, 0.95);
            }
            GC_ACTION_RESET_COLOR => {
                {
                    let mut st = self.state.lock().unwrap();
                    st.config.color_range_mode = 0;
                    st.config.contrast = 1.0;
                    st.config.saturation = 1.0;
                    st.config.gamma = 1.0;
                    st.config.overscan_crop = 0.0;
                    st.config.sharpness = 0.35;
                    st.config.save();
                }
                self.push_ui_state();
                self.toast("Color & Overscan Reset to Defaults");
            }
            GC_ACTION_TOGGLE_SCENE_GUARD => {
                let enabled = {
                    let mut st = self.state.lock().unwrap();
                    st.config.scene_guard_enabled = !st.config.scene_guard_enabled;
                    st.config.save();
                    st.config.scene_guard_enabled
                };
                self.scene_guard_fast.store(enabled, Ordering::Relaxed);
                self.push_ui_state();
                self.toast(if enabled {
                    "Smart Scene-Cut & Idle ANE Guard Enabled"
                } else {
                    "Scene-Cut Guard Disabled"
                });
            }
            GC_ACTION_USE_TEST_SIGNAL => {
                self.start_video_source(TEST_PATTERN_30_1080P_UID, 0);
                self.toast("Switched to 1080p 30fps Demo Signal");
            }
            GC_ACTION_OPEN_PRIVACY => {
                unsafe { gc_app_open_privacy_settings() };
            }
            GC_ACTION_TAKE_SCREENSHOT => {
                self.save_screenshot();
            }
            GC_ACTION_TOGGLE_RECORDING => {
                self.toggle_recording();
            }
            GC_ACTION_APP_WILL_TERMINATE => {
                self.shutdown();
            }
            _ => {}
        }
    }

    pub fn handle_devices_changed(self: &Arc<Self>) {
        if self.shutting_down.load(Ordering::Relaxed) {
            return;
        }
        self.refresh_devices(false);
    }

    fn save_screenshot(&self) {
        let Some(h) = self.handles.get() else {
            return;
        };
        let Some(pb) = self.last_presented.lock().unwrap().clone() else {
            self.toast("No video frame yet");
            return;
        };
        let dir = user_media_dir("Pictures");
        let _ = fs::create_dir_all(&dir);
        let filename = format!("GlassCapture_{}.png", unix_timestamp_label());
        let full_path = dir.join(&filename);
        let c_path = to_cstring(full_path.to_string_lossy().as_ref());

        let ok = unsafe { gc_renderer_save_screenshot(h.renderer, pb.as_ptr(), c_path.as_ptr()) };
        if ok {
            self.toast(&format!("Saved ~/Pictures/GlassCapture/{}", filename));
        } else {
            self.toast("Screenshot failed");
        }
    }

    fn toggle_recording(&self) {
        let mut rec_guard = self.recorder.lock().unwrap();
        if let Some(existing) = rec_guard.take() {
            self.is_recording_fast.store(false, Ordering::Relaxed);
            drop(rec_guard);
            unsafe { gc_recorder_stop(existing.raw) };
            self.push_ui_state();
            self.toast(&format!("Saved HEVC recording: {}", existing.path));
            return;
        }

        let pb_opt = self.last_presented.lock().unwrap().clone();
        let Some(pb) = pb_opt else {
            drop(rec_guard);
            self.toast("Wait for a video frame before recording");
            return;
        };

        let w = pb.width();
        let h_px = pb.height();
        let fps = {
            let tel = self.telemetry.lock().unwrap();
            let f = tel.output_fps(monotonic_ms());
            if f > 15.0 { f } else { 60.0 }
        };
        let with_audio = !self.state.lock().unwrap().config.selected_audio_uid.is_empty();

        let dir = user_media_dir("Movies");
        let _ = fs::create_dir_all(&dir);
        let filename = format!("GlassCapture_{}.mov", unix_timestamp_label());
        let full_path = dir.join(&filename);
        let c_path = to_cstring(full_path.to_string_lossy().as_ref());

        let raw = unsafe { gc_recorder_start(c_path.as_ptr(), w, h_px, fps, with_audio) };
        if raw.is_null() {
            drop(rec_guard);
            self.toast("Failed to start HEVC recording");
            return;
        }

        *rec_guard = Some(RecorderHandle {
            raw,
            started_ms: monotonic_ms(),
            path: format!("~/Movies/GlassCapture/{}", filename),
        });
        self.is_recording_fast.store(true, Ordering::Relaxed);
        drop(rec_guard);
        self.push_ui_state();
        self.toast(&format!("Recording HEVC ({}×{} @ {:.0}fps)…", w, h_px, fps));
    }

    pub fn shutdown(&self) {
        if self.shutting_down.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Some(mut runner) = self.state.lock().unwrap().test_runner.take() {
            runner.stop();
        }
        if let Some(rec) = self.recorder.lock().unwrap().take() {
            unsafe { gc_recorder_stop(rec.raw) };
        }
        if let Some(h) = self.handles.get() {
            unsafe {
                gc_capture_stop_video(h.capture);
                gc_capture_stop_audio(h.capture);
                gc_screen_stop(h.screen_capture);
                gc_renderer_destroy(h.renderer);
                gc_vt_destroy(h.vt);
                gc_screen_destroy(h.screen_capture);
                gc_capture_destroy(h.capture);
            }
        }
    }
}

fn user_media_dir(sub: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(sub).join("GlassCapture")
}

fn unix_timestamp_label() -> String {
    let mut buf = [0 as c_char; 64];
    unsafe { gc_format_local_timestamp(buf.as_mut_ptr(), buf.len()) };
    let s = read_cstr(&buf);
    if s.is_empty() {
        "capture".to_string()
    } else {
        s
    }
}

// ============================================================================
// Extern "C" Trampolines from ObjC -> Rust AppController
// ============================================================================

pub extern "C" fn cb_video_frame(
    ctx: *mut c_void,
    pb: *mut c_void,
    w: u32,
    h: u32,
    pts_ns: i64,
    arrival_ms: f64,
) {
    if ctx.is_null() || pb.is_null() {
        return;
    }
    let ctrl = unsafe { &*(ctx as *const AppController) };
    if let Some(buf) = PixelBuffer::retain_from_raw(pb) {
        ctrl.handle_incoming_frame(buf, w, h, pts_ns, arrival_ms);
    }
}

pub extern "C" fn cb_audio_samples(
    ctx: *mut c_void,
    samples: *const f32,
    frame_count: u32,
    _channels: u32,
    sample_rate: u32,
    peak_level: f32,
) {
    if ctx.is_null() {
        return;
    }
    let ctrl = unsafe { &*(ctx as *const AppController) };
    ctrl.handle_audio_samples(samples, frame_count, sample_rate, peak_level);
}

pub extern "C" fn cb_devices_changed(ctx: *mut c_void) {
    if ctx.is_null() {
        return;
    }
    let ctrl = unsafe {
        Arc::increment_strong_count(ctx as *const AppController);
        Arc::from_raw(ctx as *const AppController)
    };
    ctrl.handle_devices_changed();
}

pub extern "C" fn cb_ui_action(
    ctx: *mut c_void,
    action: i32,
    int_arg: i32,
    float_arg: f32,
    str_arg: *const c_char,
) {
    if ctx.is_null() {
        return;
    }
    let s = if str_arg.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(str_arg).to_string_lossy().into_owned() }
    };
    let ctrl = unsafe {
        Arc::increment_strong_count(ctx as *const AppController);
        Arc::from_raw(ctx as *const AppController)
    };
    ctrl.handle_ui_action(action, int_arg, float_arg, &s);
}

pub extern "C" fn cb_display_tick(ctx: *mut c_void, now_ms: f64) {
    if ctx.is_null() {
        return;
    }
    let ctrl = unsafe { &*(ctx as *const AppController) };
    ctrl.handle_display_tick(now_ms);
}

pub extern "C" fn cb_vt_result(
    ctx: *mut c_void,
    job_id: u64,
    out_buffers: *const *mut c_void,
    count: u32,
    frame_index: u32,
    is_final: bool,
    proc_ms: f64,
    status: i32,
) {
    if ctx.is_null() {
        return;
    }
    let ctrl = unsafe { &*(ctx as *const AppController) };
    let mut bufs = Vec::with_capacity(count as usize);
    if !out_buffers.is_null() && count > 0 {
        for i in 0..(count as usize) {
            let raw = unsafe { *out_buffers.add(i) };
            if let Some(pb) = PixelBuffer::retain_from_raw(raw) {
                bufs.push(pb);
            }
        }
    }
    ctrl.handle_vt_result(job_id, bufs, frame_index, is_final, proc_ms, status);
}
