use crate::ffi::{GcHudMetrics, write_cstr};
use std::collections::VecDeque;

pub struct Telemetry {
    source_times: VecDeque<f64>,
    output_times: VecDeque<f64>,
    pub source_width: u32,
    pub source_height: u32,
    pub output_width: u32,
    pub output_height: u32,
    pub vt_proc_ms: f64,
    pub gpu_render_ms: f64,
    pub total_latency_ms: f64,
    pub dropped_frames: u64,
    pub audio_peak: f32,
    pub hdr_active: bool,
    pub hdr_source_10bit: bool,
    pub edr_headroom: f32,
    pub hdr_tag: String,
    pub fg_engine: String,
    pub up_engine: String,
    pub last_hud_push_ms: f64,
}

impl Telemetry {
    pub fn new() -> Self {
        Self {
            source_times: VecDeque::with_capacity(256),
            output_times: VecDeque::with_capacity(256),
            source_width: 0,
            source_height: 0,
            output_width: 0,
            output_height: 0,
            vt_proc_ms: 0.0,
            gpu_render_ms: 0.0,
            total_latency_ms: 0.0,
            dropped_frames: 0,
            audio_peak: 0.0,
            hdr_active: false,
            hdr_source_10bit: false,
            edr_headroom: 1.0,
            hdr_tag: String::new(),
            fg_engine: "Off".to_string(),
            up_engine: "Auto".to_string(),
            last_hud_push_ms: 0.0,
        }
    }

    pub fn record_source_frame(&mut self, now_ms: f64, width: u32, height: u32) {
        self.source_width = width;
        self.source_height = height;
        self.source_times.push_back(now_ms);
        trim_window(&mut self.source_times, now_ms);
    }

    pub fn record_output_frame(
        &mut self,
        now_ms: f64,
        out_w: u32,
        out_h: u32,
        gpu_ms: f64,
        end_to_end_ms: f64,
        up_engine: &str,
    ) {
        self.output_width = out_w;
        self.output_height = out_h;
        self.gpu_render_ms = ewma(self.gpu_render_ms, gpu_ms, 0.2);
        if end_to_end_ms >= 0.0 && end_to_end_ms < 500.0 {
            self.total_latency_ms = ewma(self.total_latency_ms, end_to_end_ms, 0.15);
        }
        if !up_engine.is_empty() {
            self.up_engine.clear();
            self.up_engine.push_str(up_engine);
        }
        self.output_times.push_back(now_ms);
        trim_window(&mut self.output_times, now_ms);
    }

    pub fn record_vt_proc(&mut self, proc_ms: f64) {
        self.vt_proc_ms = ewma(self.vt_proc_ms, proc_ms, 0.2);
    }

    pub fn record_audio_peak(&mut self, peak: f32) {
        self.audio_peak = if peak > self.audio_peak {
            peak
        } else {
            self.audio_peak * 0.88 + peak * 0.12
        };
    }

    pub fn source_fps(&self, now_ms: f64) -> f64 {
        window_fps(&self.source_times, now_ms)
    }

    pub fn output_fps(&self, now_ms: f64) -> f64 {
        window_fps(&self.output_times, now_ms)
    }

    #[allow(dead_code)]
    pub fn should_push_hud(&mut self, now_ms: f64) -> bool {
        if now_ms - self.last_hud_push_ms >= 100.0 {
            self.last_hud_push_ms = now_ms;
            true
        } else {
            false
        }
    }

    pub fn build_metrics(
        &self,
        now_ms: f64,
        is_recording: bool,
        recording_secs: f64,
        is_paused: bool,
        is_test_pattern: bool,
    ) -> GcHudMetrics {
        let mut m = GcHudMetrics {
            source_fps: self.source_fps(now_ms),
            output_fps: self.output_fps(now_ms),
            vt_proc_ms: self.vt_proc_ms,
            gpu_render_ms: self.gpu_render_ms,
            total_latency_ms: self.total_latency_ms,
            source_width: self.source_width,
            source_height: self.source_height,
            output_width: self.output_width,
            output_height: self.output_height,
            dropped_frames: self.dropped_frames,
            audio_peak: self.audio_peak,
            is_recording,
            recording_secs,
            is_paused,
            is_test_pattern,
            hdr_active: self.hdr_active,
            hdr_source_10bit: self.hdr_source_10bit,
            edr_headroom: self.edr_headroom,
            ..Default::default()
        };
        write_cstr(&mut m.hdr_tag, &self.hdr_tag);
        write_cstr(&mut m.fg_engine, &self.fg_engine);
        write_cstr(&mut m.up_engine, &self.up_engine);
        m
    }
}

fn trim_window(q: &mut VecDeque<f64>, now_ms: f64) {
    while let Some(&front) = q.front() {
        if now_ms - front > 1000.0 {
            q.pop_front();
        } else {
            break;
        }
    }
}

fn window_fps(q: &VecDeque<f64>, now_ms: f64) -> f64 {
    if q.len() < 2 {
        return 0.0;
    }
    let first = *q.front().unwrap();
    let last = *q.back().unwrap();
    if now_ms - last > 1200.0 {
        return 0.0;
    }
    let span_ms = (last - first).max(1.0);
    ((q.len() - 1) as f64) * 1000.0 / span_ms
}

fn ewma(prev: f64, sample: f64, alpha: f64) -> f64 {
    if prev <= 0.0001 {
        sample
    } else {
        prev * (1.0 - alpha) + sample * alpha
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sliding_window_computes_accurate_fps() {
        let mut tel = Telemetry::new();
        for i in 0..61 {
            tel.record_source_frame((i as f64) * (1000.0 / 60.0), 1920, 1080);
        }
        let fps = tel.source_fps(1000.0);
        assert!((fps - 60.0).abs() < 0.5, "expected ~60 fps, got {fps}");
    }
}
