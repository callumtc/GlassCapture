use crate::ffi::{PixelBuffer, gc_create_nv12_pixel_buffer, monotonic_ms};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub const TEST_PATTERN_30_1080P_UID: &str = "__GLASS_TEST_1080P30__";
pub const TEST_PATTERN_30_720P_UID: &str = "__GLASS_TEST_720P30__";
pub const TEST_PATTERN_60_1080P_UID: &str = "__GLASS_TEST_1080P60__";

pub struct TestPatternRunner {
    stop_flag: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl TestPatternRunner {
    pub fn start<F>(width: u32, height: u32, fps: f64, on_frame: F) -> Self
    where
        F: Fn(PixelBuffer, u32, u32, i64, f64) + Send + 'static,
    {
        let stop_flag = Arc::new(AtomicBool::new(false));
        let stop = stop_flag.clone();

        let handle = thread::Builder::new()
            .name("gc-test-pattern".to_string())
            .spawn(move || {
                let w = width as usize;
                let h = height as usize;
                let uv_h = h / 2;
                let mut y_plane = vec![16u8; w * h];
                let mut uv_plane = vec![128u8; w * uv_h];

                let start_instant = Instant::now();
                let frame_dur = Duration::from_secs_f64(1.0 / fps.max(1.0));
                let mut frame_idx: u64 = 0;

                // Precompute static subtle slate grid + color bar strip template
                let mut base_y = vec![24u8; w * h];
                let mut base_uv = vec![128u8; w * uv_h];

                // Rich studio-grade aurora backdrop with subtle geometric calibration grid
                // (designed to showcase Liquid Glass refraction AND MetalFX/Neural FG clarity)
                for row in 0..h {
                    let row_off = row * w;
                    let is_h_line = (row % 80) == 0;
                    let fy = (row as f32) / (h as f32);
                    for col in 0..w {
                        let is_v_line = (col % 80) == 0;
                        let fx = (col as f32) / (w as f32);
                        // Smooth radial vignette + subtle horizon glow
                        let dx = fx - 0.5;
                        let dy = fy - 0.48;
                        let dist = (dx * dx + dy * dy).sqrt();
                        let base_lum = (62.0 - dist * 58.0).clamp(18.0, 68.0);
                        let lum = if is_h_line || is_v_line {
                            (base_lum + 16.0) as u8
                        } else {
                            base_lum as u8
                        };
                        base_y[row_off + col] = lum;
                    }
                    if (row & 1) == 0 {
                        let uv_off = (row / 2) * w;
                        for col in (0..w).step_by(2) {
                            let fx = (col as f32) / (w as f32);
                            // Deep teal-indigo -> violet-rose studio gradient
                            let cb = (158.0 - 34.0 * fx + 18.0 * fy).clamp(90.0, 195.0) as u8;
                            let cr = (112.0 + 46.0 * fx - 14.0 * fy).clamp(90.0, 185.0) as u8;
                            base_uv[uv_off + col] = cb;
                            base_uv[uv_off + col + 1] = cr;
                        }
                    }
                }

                // Sleek floating color calibration ribbon (centered, padded from top bar)
                let band_top = (h * 20) / 100;
                let band_bot = band_top + (h * 6) / 100;
                let band_x0 = (w * 20) / 100;
                let band_x1 = (w * 80) / 100;
                let band_w = (band_x1 - band_x0).max(1);
                let bars: [(u8, u8, u8); 7] = [
                    (220, 128, 128), // Pure White
                    (204, 48, 144),  // Amber
                    (178, 168, 46),  // Aqua
                    (152, 74, 56),   // Emerald
                    (116, 204, 210), // Orchid
                    (92, 102, 236),  // Crimson
                    (58, 232, 114),  // Cobalt
                ];
                for row in band_top..band_bot {
                    let y_off = row * w;
                    let uv_off = (row / 2) * w;
                    for col in band_x0..band_x1 {
                        let b = ((col - band_x0) * 7) / band_w;
                        let (yv, cb, cr) = bars[b.min(6)];
                        base_y[y_off + col] = yv;
                        if (row & 1) == 0 && (col & 1) == 0 {
                            base_uv[uv_off + col] = cb;
                            base_uv[uv_off + col + 1] = cr;
                        }
                    }
                }

                // Fine resolution wedge (diagonal high-frequency lines) to show off MetalFX / ML SR!
                let box_x0 = w / 10;
                let box_x1 = box_x0 + w / 5;
                let box_y0 = (h * 58) / 100;
                let box_y1 = (h * 74) / 100;
                for row in box_y0..box_y1 {
                    let y_off = row * w;
                    for col in box_x0..box_x1 {
                        let stripe = ((col + row) % 6) < 2;
                        base_y[y_off + col] = if stripe { 225 } else { 28 };
                    }
                }

                while !stop.load(Ordering::Relaxed) {
                    let t = (frame_idx as f64) / fps;
                    y_plane.copy_from_slice(&base_y);
                    uv_plane.copy_from_slice(&base_uv);

                    // 1. Fast smooth sweeping motion bar (unmistakably reveals 30->60/120fps Frame Gen!)
                    let sweep = ((t * 0.55) % 1.0) as f32;
                    let bar_w = (w / 28).max(16);
                    let bar_x = (sweep * (w - bar_w) as f32) as usize;
                    let bar_y0 = (h * 32) / 100;
                    let bar_y1 = (h * 52) / 100;
                    for row in bar_y0..bar_y1 {
                        let y_off = row * w;
                        let uv_off = (row / 2) * w;
                        for col in bar_x..(bar_x + bar_w).min(w) {
                            let edge = col == bar_x || col + 1 == bar_x + bar_w;
                            y_plane[y_off + col] = if edge { 240 } else { 215 };
                            if (row & 1) == 0 && (col & 1) == 0 {
                                uv_plane[uv_off + col] = 175;
                                uv_plane[uv_off + col + 1] = 68;
                            }
                        }
                    }

                    // 2. Smooth oscillating luminous orb (tests curved neural optical-flow motion!)
                    let cx = (w as f64 * 0.62) + (w as f64 * 0.24) * (t * 2.4).sin();
                    let cy = (h as f64 * 0.67) + (h as f64 * 0.11) * (t * 4.8).cos();
                    let radius = (h as f64 * 0.065) as i32;
                    let r2 = radius * radius;
                    let x0 = ((cx as i32) - radius).max(0) as usize;
                    let x1 = ((cx as i32) + radius).min(w as i32 - 1) as usize;
                    let y0 = ((cy as i32) - radius).max(0) as usize;
                    let y1 = ((cy as i32) + radius).min(h as i32 - 1) as usize;

                    for row in y0..=y1 {
                        let dy = row as i32 - cy as i32;
                        let y_off = row * w;
                        let uv_off = (row / 2) * w;
                        for col in x0..=x1 {
                            let dx = col as i32 - cx as i32;
                            let d2 = dx * dx + dy * dy;
                            if d2 <= r2 {
                                let shade = 1.0 - (d2 as f32) / (r2 as f32);
                                y_plane[y_off + col] = (140.0 + 100.0 * shade) as u8;
                                if (row & 1) == 0 && (col & 1) == 0 {
                                    uv_plane[uv_off + col] = 85;
                                    uv_plane[uv_off + col + 1] = 220;
                                }
                            }
                        }
                    }

                    let raw_pb = unsafe {
                        gc_create_nv12_pixel_buffer(
                            width,
                            height,
                            y_plane.as_ptr(),
                            w,
                            uv_plane.as_ptr(),
                            w,
                        )
                    };

                    if let Some(pb) = PixelBuffer::take_owned(raw_pb) {
                        let now_ms = monotonic_ms();
                        let pts_ns = (t * 1_000_000_000.0) as i64;
                        on_frame(pb, width, height, pts_ns, now_ms);
                    }

                    frame_idx += 1;
                    let next_target = start_instant + frame_dur.mul_f64(frame_idx as f64);
                    let now = Instant::now();
                    if next_target > now {
                        thread::sleep(next_target - now);
                    }
                }
            })
            .ok();

        Self { stop_flag, handle }
    }

    pub fn stop(&mut self) {
        self.stop_flag.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

impl Drop for TestPatternRunner {
    fn drop(&mut self) {
        self.stop();
    }
}
