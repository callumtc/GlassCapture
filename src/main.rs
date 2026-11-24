mod config;
mod ffi;
mod pacer;
mod state;
mod telemetry;
mod test_pattern;

use crate::ffi::*;
use crate::state::*;
use std::ffi::c_void;
use std::sync::Arc;

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.iter().any(|a| a == "--info") {
        let caps = query_hardware_caps();
        println!("GlassCapture Hardware Diagnostics");
        println!("  GPU: {}", read_cstr(&caps.gpu_name));
        println!("  MetalFX Spatial: {}", caps.metalfx_supported);
        println!(
            "  VT Low-Latency Frame Interpolation: {} (max {}px, {} total px)",
            caps.llfi_supported, caps.llfi_max_dim, caps.llfi_max_pixels
        );
        println!("  VT Low-Latency Super Resolution: {}", caps.llsr_supported);
        return;
    }

    let force_test = args.iter().any(|a| a == "--test-pattern");
    let controller = AppController::new(force_test);

    // Keep an owned raw pointer alive for the lifetime of the NSApplication run loop
    let ctx_ptr = Arc::into_raw(Arc::clone(&controller)) as *mut c_void;

    let callbacks = GcCallbacks {
        ctx: ctx_ptr,
        on_video_frame: Some(cb_video_frame),
        on_audio_samples: Some(cb_audio_samples),
        on_devices_changed: Some(cb_devices_changed),
        on_ui_action: Some(cb_ui_action),
        on_display_tick: Some(cb_display_tick),
        on_vt_result: Some(cb_vt_result),
    };

    let app = unsafe { gc_app_create(&callbacks) };
    let metal_layer = unsafe { gc_app_get_metal_layer(app) };
    let capture = unsafe { gc_capture_create(&callbacks) };
    let screen_capture = unsafe { gc_screen_create(&callbacks) };
    let vt = unsafe { gc_vt_create(&callbacks) };
    let renderer = unsafe { gc_renderer_create(metal_layer, &callbacks) };

    controller.set_handles(NativeHandles {
        app,
        capture,
        screen_capture,
        vt,
        renderer,
    });

    controller.startup();

    // Enters AppKit's main run loop until Quit
    unsafe { gc_app_run(app) };
}
