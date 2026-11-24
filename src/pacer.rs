use crate::ffi::{GcFrameGenMode, PixelBuffer};
use std::collections::{HashMap, VecDeque};

pub struct ScheduledFrame {
    pub buffer: PixelBuffer,
    pub present_at_ms: f64,
    pub source_arrival_ms: f64,
    pub pts_ns: i64,
    #[allow(dead_code)]
    pub is_interpolated: bool,
    pub ml_prefix: Option<String>,
}

pub struct VtJobRequest {
    pub job_id: u64,
    pub prev_frame: PixelBuffer,
    pub curr_frame: PixelBuffer,
    pub multiplier: i32,
}

struct PendingJob {
    real_frame: PixelBuffer,
    arrival_ms: f64,
    pts_ns: i64,
    interval_ms: f64,
    multiplier: i32,
    base_schedule_ms: Option<f64>,
    ml_prefix: Option<String>,
}

/// Precision monotonic frame pacer for 1×, 2×, and 4× neural frame generation.
///
/// Guarantees:
/// - Zero extra buffering latency in 1× (Off) mode.
/// - Streaming per-frame scheduling for 4× mode (via VT `frameOutputHandler`).
/// - Phase-locked cadence smoothing to absorb minor ANE execution jitter.
/// - Strict in-flight concurrency cap & backlog trimming so latency can never drift.
pub struct FramePacer {
    next_job_id: u64,
    last_real_frame: Option<PixelBuffer>,
    last_arrival_ms: Option<f64>,
    smoothed_interval_ms: f64,
    last_scheduled_ms: f64,
    pending_jobs: HashMap<u64, PendingJob>,
    present_queue: VecDeque<ScheduledFrame>,
    pub dropped_frames: u64,
}

impl FramePacer {
    pub fn new() -> Self {
        Self {
            next_job_id: 1,
            last_real_frame: None,
            last_arrival_ms: None,
            smoothed_interval_ms: 16.67,
            last_scheduled_ms: 0.0,
            pending_jobs: HashMap::new(),
            present_queue: VecDeque::with_capacity(8),
            dropped_frames: 0,
        }
    }

    pub fn reset(&mut self) {
        self.last_real_frame = None;
        self.last_arrival_ms = None;
        self.last_scheduled_ms = 0.0;
        self.pending_jobs.clear();
        self.present_queue.clear();
    }

    pub fn has_frames(&self) -> bool {
        !self.present_queue.is_empty()
    }

    /// Ingests a newly captured real frame. Returns `Some(VtJobRequest)` when
    /// neural frame generation should be dispatched asynchronously.
    pub fn ingest_real_frame(
        &mut self,
        frame: PixelBuffer,
        pts_ns: i64,
        arrival_ms: f64,
        mode: GcFrameGenMode,
        ml_prefix: Option<String>,
    ) -> Option<VtJobRequest> {
        if let Some(prev_t) = self.last_arrival_ms {
            let dt = arrival_ms - prev_t;
            if (4.0..=150.0).contains(&dt) {
                self.smoothed_interval_ms = self.smoothed_interval_ms * 0.82 + dt * 0.18;
            }
        }
        self.last_arrival_ms = Some(arrival_ms);

        let prev = self.last_real_frame.replace(frame.clone());

        if mode == GcFrameGenMode::Off {
            self.present_queue.clear();
            self.present_queue.push_back(ScheduledFrame {
                buffer: frame,
                present_at_ms: arrival_ms,
                source_arrival_ms: arrival_ms,
                pts_ns,
                is_interpolated: false,
                ml_prefix,
            });
            return None;
        }

        let Some(prev_frame) = prev else {
            self.present_queue.push_back(ScheduledFrame {
                buffer: frame,
                present_at_ms: arrival_ms,
                source_arrival_ms: arrival_ms,
                pts_ns,
                is_interpolated: false,
                ml_prefix,
            });
            return None;
        };

        if prev_frame.width() != frame.width() || prev_frame.height() != frame.height() {
            self.present_queue.clear();
            self.present_queue.push_back(ScheduledFrame {
                buffer: frame,
                present_at_ms: arrival_ms,
                source_arrival_ms: arrival_ms,
                pts_ns,
                is_interpolated: false,
                ml_prefix,
            });
            return None;
        }

        // Concurrency backpressure: cap in-flight ANE jobs to 2 so latency stays bounded
        if self.pending_jobs.len() >= 2 {
            self.dropped_frames += 1;
            self.present_queue.push_back(ScheduledFrame {
                buffer: frame,
                present_at_ms: arrival_ms,
                source_arrival_ms: arrival_ms,
                pts_ns,
                is_interpolated: false,
                ml_prefix,
            });
            self.trim_backlog();
            return None;
        }

        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let mult = mode.multiplier();

        self.pending_jobs.insert(
            job_id,
            PendingJob {
                real_frame: frame.clone(),
                arrival_ms,
                pts_ns,
                interval_ms: self.smoothed_interval_ms,
                multiplier: mult,
                base_schedule_ms: None,
                ml_prefix,
            },
        );

        Some(VtJobRequest {
            job_id,
            prev_frame,
            curr_frame: frame,
            multiplier: mult,
        })
    }

    /// Handles either a streaming intermediate frame (4× mode) or the final completion of a VT job.
    pub fn on_vt_frame(
        &mut self,
        job_id: u64,
        interpolated: Vec<PixelBuffer>,
        frame_index: u32,
        is_final: bool,
        status: i32,
        now_ms: f64,
        interp_ml_prefix: Option<String>,
    ) {
        if status != 0 {
            if let Some(job) = self.pending_jobs.remove(&job_id) {
                self.present_queue.push_back(ScheduledFrame {
                    buffer: job.real_frame,
                    present_at_ms: now_ms,
                    source_arrival_ms: job.arrival_ms,
                    pts_ns: job.pts_ns,
                    is_interpolated: false,
                    ml_prefix: job.ml_prefix,
                });
                self.trim_backlog();
            }
            return;
        }

        let Some(job) = self.pending_jobs.get_mut(&job_id) else {
            return;
        };

        let total = job.multiplier.max(2) as usize;
        let step_ms = (job.interval_ms / (total as f64)).clamp(4.0, 40.0);
        let step_ns = (step_ms * 1_000_000.0) as i64;
        let interp_count = (total - 1) as i64;
        let start_pts_ns = job.pts_ns - interp_count * step_ns;

        // Soft phase-locked anchor: smoothly continue from previous scheduled frame when within 1.2x interval
        let base_t = *job.base_schedule_ms.get_or_insert_with(|| {
            let candidate = self.last_scheduled_ms + step_ms;
            if self.last_scheduled_ms > 0.0
                && candidate >= now_ms - step_ms * 0.6
                && candidate <= now_ms + job.interval_ms * 1.2
            {
                // Blend 70% phase-locked cadence + 30% actual completion time to prevent drift
                candidate * 0.7 + now_ms * 0.3
            } else {
                now_ms
            }
        });

        for (offset, buf) in interpolated.into_iter().enumerate() {
            let slot = (frame_index as usize) + offset;
            let sched_t = (base_t + (slot as f64) * step_ms).max(now_ms);
            self.present_queue.push_back(ScheduledFrame {
                buffer: buf,
                present_at_ms: sched_t,
                source_arrival_ms: job.arrival_ms,
                pts_ns: start_pts_ns + (slot as i64) * step_ns,
                is_interpolated: true,
                ml_prefix: interp_ml_prefix.clone().or_else(|| job.ml_prefix.clone()),
            });
            self.last_scheduled_ms = sched_t;
        }

        if is_final {
            let Some(done_job) = self.pending_jobs.remove(&job_id) else {
                return;
            };
            let real_slot = total - 1;
            let real_t = (base_t + (real_slot as f64) * step_ms).max(now_ms);
            self.present_queue.push_back(ScheduledFrame {
                buffer: done_job.real_frame,
                present_at_ms: real_t,
                source_arrival_ms: done_job.arrival_ms,
                pts_ns: done_job.pts_ns,
                is_interpolated: false,
                ml_prefix: done_job.ml_prefix,
            });
            self.last_scheduled_ms = real_t;
        }

        self.trim_backlog();
    }

    /// Pops the next due frame on the display's hardware VSync tick.
    pub fn pop_due_frame(&mut self, now_ms: f64) -> Option<ScheduledFrame> {
        let front = self.present_queue.front()?;
        // 2.5ms lead tolerance aligns smoothly with ProMotion 8.33ms / 16.67ms VSync edges
        if front.present_at_ms <= now_ms + 2.5 {
            let mut chosen = self.present_queue.pop_front().unwrap();
            // Skip stale overdue frames so glass-to-glass latency stays tight
            while let Some(next) = self.present_queue.front() {
                if next.present_at_ms <= now_ms - 6.0 {
                    chosen = self.present_queue.pop_front().unwrap();
                    self.dropped_frames += 1;
                } else {
                    break;
                }
            }
            Some(chosen)
        } else {
            None
        }
    }

    fn trim_backlog(&mut self) {
        while self.present_queue.len() > 6 {
            self.present_queue.pop_front();
            self.dropped_frames += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::gc_create_nv12_pixel_buffer;

    fn dummy_pb(w: u32, h: u32) -> PixelBuffer {
        let y = vec![128u8; (w * h) as usize];
        let uv = vec![128u8; (w * (h / 2)) as usize];
        let raw = unsafe {
            gc_create_nv12_pixel_buffer(w, h, y.as_ptr(), w as usize, uv.as_ptr(), w as usize)
        };
        PixelBuffer::take_owned(raw).expect("failed to create test CVPixelBuffer")
    }

    #[test]
    fn off_mode_presents_immediately_without_buffering() {
        let mut pacer = FramePacer::new();
        let f1 = dummy_pb(64, 64);
        assert!(pacer.ingest_real_frame(f1, 0, 100.0, GcFrameGenMode::Off, None).is_none());
        let popped = pacer.pop_due_frame(100.0).expect("frame should be immediately due");
        assert!(!popped.is_interpolated);
        assert!(pacer.pop_due_frame(100.0).is_none());
    }

    #[test]
    fn two_x_mode_schedules_interpolated_then_real_evenly() {
        let mut pacer = FramePacer::new();
        let f0 = dummy_pb(64, 64);
        let f1 = dummy_pb(64, 64);
        let interp = dummy_pb(64, 64);

        assert!(pacer.ingest_real_frame(f0, 0, 1000.0, GcFrameGenMode::TwoX, None).is_none());
        assert!(pacer.pop_due_frame(1000.0).is_some());

        let req = pacer
            .ingest_real_frame(f1, 33_333_333, 1033.33, GcFrameGenMode::TwoX, None)
            .expect("should dispatch 2x VT job");
        assert_eq!(req.multiplier, 2);

        pacer.on_vt_frame(req.job_id, vec![interp], 0, true, 0, 1043.33, None);

        let out1 = pacer.pop_due_frame(1043.33).expect("interpolated frame due");
        assert!(out1.is_interpolated);

        assert!(pacer.pop_due_frame(1045.0).is_none());
        let out2 = pacer.pop_due_frame(1062.0).expect("real frame due at half interval");
        assert!(!out2.is_interpolated);
    }

    #[test]
    fn four_x_streaming_schedules_each_frame_as_it_arrives() {
        let mut pacer = FramePacer::new();
        let f0 = dummy_pb(64, 64);
        let f1 = dummy_pb(64, 64);
        let i1 = dummy_pb(64, 64);
        let i2 = dummy_pb(64, 64);
        let i3 = dummy_pb(64, 64);

        pacer.ingest_real_frame(f0, 0, 1000.0, GcFrameGenMode::FourX, None);
        pacer.pop_due_frame(1000.0);

        let req = pacer
            .ingest_real_frame(f1, 33_333_333, 1033.33, GcFrameGenMode::FourX, None)
            .expect("should dispatch 4x VT job");
        assert_eq!(req.multiplier, 4);

        // Stream 0.25 frame early!
        pacer.on_vt_frame(req.job_id, vec![i1], 0, false, 0, 1040.0, None);
        let first = pacer.pop_due_frame(1040.0).expect("0.25 frame immediately available");
        assert!(first.is_interpolated);

        // Stream 0.50 and 0.75 (final)
        pacer.on_vt_frame(req.job_id, vec![i2], 1, false, 0, 1044.0, None);
        pacer.on_vt_frame(req.job_id, vec![i3], 2, true, 0, 1048.0, None);

        let mut popped_flags = Vec::new();
        let mut t = 1048.0;
        for _ in 0..20 {
            if let Some(f) = pacer.pop_due_frame(t) {
                popped_flags.push(f.is_interpolated);
            }
            t += 4.0;
        }
        assert_eq!(popped_flags, vec![true, true, false]);
    }
}
