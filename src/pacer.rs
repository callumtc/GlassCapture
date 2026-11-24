use crate::ffi::{GcFrameGenMode, PixelBuffer};
use std::collections::VecDeque;

pub struct ScheduledFrame {
    pub seq: u64,
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
    pub capped_to_120hz: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IngestOutcome {
    DirectPassthrough,
    StaticSkippedAne,
    SceneCutBypassed,
    QueuedBehindInFlight,
    DispatchedVt,
}

struct PendingJob {
    job_id: u64,
    frame_seq: u64,
    real_frame: PixelBuffer,
    arrival_ms: f64,
    pts_ns: i64,
    interval_ms: f64,
    ml_prefix: Option<String>,
}

struct QueuedRealFrame {
    frame: PixelBuffer,
    pts_ns: i64,
    arrival_ms: f64,
    mode: GcFrameGenMode,
    ml_prefix: Option<String>,
}

/// Strictly monotonic, glitch-free frame pacer for 1×, 2×, and 4× neural frame generation.
///
/// Guarantees:
/// - Strict chronological ordering: no frame with `seq <= last_presented_seq` can EVER be shown.
/// - Single in-flight VT job with queued-latest handoff prevents out-of-order frame interleaving.
/// - Smart 120Hz cap: auto-caps 4× to 2× on >=45fps sources so ANE never thrashes at 240fps.
/// - Smart scene-cut & static-frame guard: prevents morph artifacts on cuts and saves ANE power on menus.
pub struct FramePacer {
    next_job_id: u64,
    next_frame_seq: u64,
    last_presented_seq: u64,
    last_real_frame: Option<PixelBuffer>,
    last_arrival_ms: Option<f64>,
    smoothed_interval_ms: f64,
    last_scheduled_ms: f64,
    in_flight: Option<PendingJob>,
    queued_latest: Option<QueuedRealFrame>,
    present_queue: VecDeque<ScheduledFrame>,
    pub dropped_frames: u64,
}

impl FramePacer {
    pub fn new() -> Self {
        Self {
            next_job_id: 1,
            next_frame_seq: 1,
            last_presented_seq: 0,
            last_real_frame: None,
            last_arrival_ms: None,
            smoothed_interval_ms: 16.67,
            last_scheduled_ms: 0.0,
            in_flight: None,
            queued_latest: None,
            present_queue: VecDeque::with_capacity(8),
            dropped_frames: 0,
        }
    }

    pub fn reset(&mut self) {
        self.last_real_frame = None;
        self.last_arrival_ms = None;
        self.last_scheduled_ms = 0.0;
        self.in_flight = None;
        self.queued_latest = None;
        self.present_queue.clear();
        // Keep next_frame_seq / last_presented_seq monotonic across resets
    }

    pub fn has_frames(&self) -> bool {
        !self.present_queue.is_empty()
    }

    /// Ingests a newly captured real frame.
    /// `luma_diff`: mean absolute 8-bit luma difference vs `last_real_frame` (or `< 0.0` if unavailable).
    pub fn ingest_real_frame(
        &mut self,
        frame: PixelBuffer,
        pts_ns: i64,
        arrival_ms: f64,
        mode: GcFrameGenMode,
        ml_prefix: Option<String>,
        scene_guard_enabled: bool,
        luma_diff: f32,
    ) -> (Option<VtJobRequest>, IngestOutcome) {
        if let Some(prev_t) = self.last_arrival_ms {
            let dt = arrival_ms - prev_t;
            if (4.0..=150.0).contains(&dt) {
                self.smoothed_interval_ms = self.smoothed_interval_ms * 0.82 + dt * 0.18;
            }
        }
        self.last_arrival_ms = Some(arrival_ms);

        // Lowest-latency 1× direct passthrough
        if mode == GcFrameGenMode::Off {
            self.in_flight = None;
            self.queued_latest = None;
            self.last_real_frame = Some(frame.clone());
            let fseq = self.alloc_frame_seq();
            self.present_queue.clear();
            self.push_monotonic(ScheduledFrame {
                seq: fseq * 8 + 7,
                buffer: frame,
                present_at_ms: arrival_ms,
                source_arrival_ms: arrival_ms,
                pts_ns,
                is_interpolated: false,
                ml_prefix,
            });
            return (None, IngestOutcome::DirectPassthrough);
        }

        // If a VT job is already in flight, DO NOT push this newer frame ahead of it (that caused backward glitches!).
        // Instead, keep the latest real frame ready for immediate dispatch the moment the current job finishes.
        if self.in_flight.is_some() {
            if self.queued_latest.is_some() {
                self.dropped_frames += 1;
            }
            self.queued_latest = Some(QueuedRealFrame {
                frame,
                pts_ns,
                arrival_ms,
                mode,
                ml_prefix,
            });
            return (None, IngestOutcome::QueuedBehindInFlight);
        }

        self.start_or_direct(frame, pts_ns, arrival_ms, mode, ml_prefix, scene_guard_enabled, luma_diff)
    }

    fn start_or_direct(
        &mut self,
        frame: PixelBuffer,
        pts_ns: i64,
        arrival_ms: f64,
        mode: GcFrameGenMode,
        ml_prefix: Option<String>,
        scene_guard_enabled: bool,
        luma_diff: f32,
    ) -> (Option<VtJobRequest>, IngestOutcome) {
        let prev = self.last_real_frame.replace(frame.clone());
        let Some(prev_frame) = prev else {
            let fseq = self.alloc_frame_seq();
            self.push_monotonic(ScheduledFrame {
                seq: fseq * 8 + 7,
                buffer: frame,
                present_at_ms: arrival_ms,
                source_arrival_ms: arrival_ms,
                pts_ns,
                is_interpolated: false,
                ml_prefix,
            });
            return (None, IngestOutcome::DirectPassthrough);
        };

        if prev_frame.width() != frame.width() || prev_frame.height() != frame.height() {
            let fseq = self.alloc_frame_seq();
            self.present_queue.clear();
            self.push_monotonic(ScheduledFrame {
                seq: fseq * 8 + 7,
                buffer: frame,
                present_at_ms: arrival_ms,
                source_arrival_ms: arrival_ms,
                pts_ns,
                is_interpolated: false,
                ml_prefix,
            });
            return (None, IngestOutcome::DirectPassthrough);
        }

        // Smart Scene-Cut & Static-Frame Guard (1.3us cost!)
        if scene_guard_enabled && luma_diff >= 0.0 {
            if luma_diff < 0.35 {
                // Static screen / menu -> skip Neural Engine completely to save power & heat!
                let fseq = self.alloc_frame_seq();
                self.push_monotonic(ScheduledFrame {
                    seq: fseq * 8 + 7,
                    buffer: frame,
                    present_at_ms: arrival_ms,
                    source_arrival_ms: arrival_ms,
                    pts_ns,
                    is_interpolated: false,
                    ml_prefix,
                });
                self.trim_backlog();
                return (None, IngestOutcome::StaticSkippedAne);
            }
            if luma_diff > 36.0 {
                // Hard camera cut / loading screen flash -> bypass interpolation to prevent morphing smear!
                let fseq = self.alloc_frame_seq();
                self.push_monotonic(ScheduledFrame {
                    seq: fseq * 8 + 7,
                    buffer: frame,
                    present_at_ms: arrival_ms,
                    source_arrival_ms: arrival_ms,
                    pts_ns,
                    is_interpolated: false,
                    ml_prefix,
                });
                self.trim_backlog();
                return (None, IngestOutcome::SceneCutBypassed);
            }
        }

        // Smart 120Hz cap: if source is already >= 45fps (interval < 22ms), cap 4x -> 2x (60->120fps)
        // so we don't waste ANE generating 240fps on a 120Hz display!
        let mut mult = mode.multiplier();
        let mut capped = false;
        if mult >= 4 && self.smoothed_interval_ms < 22.0 {
            mult = 2;
            capped = true;
        }

        let job_id = self.next_job_id;
        self.next_job_id += 1;
        let frame_seq = self.alloc_frame_seq();

        self.in_flight = Some(PendingJob {
            job_id,
            frame_seq,
            real_frame: frame.clone(),
            arrival_ms,
            pts_ns,
            interval_ms: self.smoothed_interval_ms,
            ml_prefix,
        });

        (
            Some(VtJobRequest {
                job_id,
                prev_frame,
                curr_frame: frame,
                multiplier: mult,
                capped_to_120hz: capped,
            }),
            IngestOutcome::DispatchedVt,
        )
    }

    /// Handles VT completion and optionally returns the next queued `VtJobRequest` to chain immediately!
    pub fn on_vt_complete(
        &mut self,
        job_id: u64,
        interpolated: Vec<PixelBuffer>,
        status: i32,
        now_ms: f64,
        scene_guard_enabled: bool,
        next_luma_diff_fn: impl FnOnce(&PixelBuffer, &PixelBuffer) -> f32,
    ) -> Option<VtJobRequest> {
        let Some(job) = self.in_flight.take() else {
            return None;
        };
        if job.job_id != job_id {
            // Stale callback from a previous reset — ignore cleanly
            return None;
        }

        if status != 0 || interpolated.is_empty() {
            self.push_monotonic(ScheduledFrame {
                seq: job.frame_seq * 8 + 7,
                buffer: job.real_frame,
                present_at_ms: now_ms,
                source_arrival_ms: job.arrival_ms,
                pts_ns: job.pts_ns,
                is_interpolated: false,
                ml_prefix: job.ml_prefix,
            });
            self.trim_backlog();
        } else {
            let total = interpolated.len() + 1;
            let step_ms = (job.interval_ms / (total as f64)).clamp(4.0, 40.0);
            let step_ns = (step_ms * 1_000_000.0) as i64;
            let start_pts_ns = job.pts_ns - (interpolated.len() as i64) * step_ns;

            // Smooth phase-locked anchor
            let candidate = self.last_scheduled_ms + step_ms;
            let base_t = if self.last_scheduled_ms > 0.0
                && candidate >= now_ms - step_ms * 0.5
                && candidate <= now_ms + job.interval_ms * 1.1
            {
                candidate * 0.7 + now_ms * 0.3
            } else {
                now_ms
            };

            for (slot, buf) in interpolated.into_iter().enumerate() {
                let sched_t = (base_t + (slot as f64) * step_ms).max(now_ms);
                self.push_monotonic(ScheduledFrame {
                    seq: job.frame_seq * 8 + (slot as u64),
                    buffer: buf,
                    present_at_ms: sched_t,
                    source_arrival_ms: job.arrival_ms,
                    pts_ns: start_pts_ns + (slot as i64) * step_ns,
                    is_interpolated: true,
                    ml_prefix: job.ml_prefix.clone(),
                });
                self.last_scheduled_ms = sched_t;
            }

            let real_t = (base_t + ((total - 1) as f64) * step_ms).max(now_ms);
            self.push_monotonic(ScheduledFrame {
                seq: job.frame_seq * 8 + 7,
                buffer: job.real_frame,
                present_at_ms: real_t,
                source_arrival_ms: job.arrival_ms,
                pts_ns: job.pts_ns,
                is_interpolated: false,
                ml_prefix: job.ml_prefix,
            });
            self.last_scheduled_ms = real_t;
            self.trim_backlog();
        }

        // If a newer capture frame arrived while VT was busy, immediately chain it in strict order!
        if let Some(q) = self.queued_latest.take() {
            let diff = match self.last_real_frame.as_ref() {
                Some(prev) if scene_guard_enabled => next_luma_diff_fn(prev, &q.frame),
                _ => -1.0,
            };
            let (next_req, _) = self.start_or_direct(
                q.frame,
                q.pts_ns,
                q.arrival_ms,
                q.mode,
                q.ml_prefix,
                scene_guard_enabled,
                diff,
            );
            return next_req;
        }
        None
    }

    pub fn pop_due_frame(&mut self, now_ms: f64) -> Option<ScheduledFrame> {
        let front = self.present_queue.front()?;
        if front.present_at_ms <= now_ms + 2.5 {
            let mut chosen = self.present_queue.pop_front().unwrap();
            while let Some(next) = self.present_queue.front() {
                if next.present_at_ms <= now_ms - 6.0 {
                    chosen = self.present_queue.pop_front().unwrap();
                    self.dropped_frames += 1;
                } else {
                    break;
                }
            }
            if chosen.seq > self.last_presented_seq {
                self.last_presented_seq = chosen.seq;
                Some(chosen)
            } else {
                None
            }
        } else {
            None
        }
    }

    pub fn last_real_frame_ref(&self) -> Option<&PixelBuffer> {
        self.last_real_frame.as_ref()
    }

    fn alloc_frame_seq(&mut self) -> u64 {
        let s = self.next_frame_seq;
        self.next_frame_seq += 1;
        s
    }

    fn push_monotonic(&mut self, f: ScheduledFrame) {
        if f.seq <= self.last_presented_seq {
            return;
        }
        if let Some(back) = self.present_queue.back() {
            if f.seq <= back.seq {
                return;
            }
        }
        self.present_queue.push_back(f);
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
        let (req, _) = pacer.ingest_real_frame(f1, 0, 100.0, GcFrameGenMode::Off, None, true, 10.0);
        assert!(req.is_none());
        let popped = pacer.pop_due_frame(100.0).expect("frame should be immediately due");
        assert!(!popped.is_interpolated);
        assert!(pacer.pop_due_frame(100.0).is_none());
    }

    #[test]
    fn two_x_mode_schedules_interpolated_then_real_strictly_in_order() {
        let mut pacer = FramePacer::new();
        let f0 = dummy_pb(64, 64);
        let f1 = dummy_pb(64, 64);
        let interp = dummy_pb(64, 64);

        let (r0, _) = pacer.ingest_real_frame(f0, 0, 1000.0, GcFrameGenMode::TwoX, None, false, -1.0);
        assert!(r0.is_none());
        let s0 = pacer.pop_due_frame(1000.0).unwrap().seq;

        let (req, _) = pacer.ingest_real_frame(f1, 33_333_333, 1033.33, GcFrameGenMode::TwoX, None, false, -1.0);
        let req = req.expect("should dispatch 2x VT job");
        assert_eq!(req.multiplier, 2);

        pacer.on_vt_complete(req.job_id, vec![interp], 0, 1043.33, false, |_, _| -1.0);

        let out1 = pacer.pop_due_frame(1043.33).expect("interpolated frame due");
        assert!(out1.is_interpolated);
        assert!(out1.seq > s0);

        assert!(pacer.pop_due_frame(1045.0).is_none());
        let out2 = pacer.pop_due_frame(1062.0).expect("real frame due at half interval");
        assert!(!out2.is_interpolated);
        assert!(out2.seq > out1.seq);
    }

    #[test]
    fn four_x_mode_on_30fps_delivers_all_four_in_strict_order_and_chains_queued() {
        let mut pacer = FramePacer::new();
        // Prime 30fps interval (~33.33ms)
        for i in 0..8 {
            let f = dummy_pb(64, 64);
            let t = 1000.0 + (i as f64) * 33.33;
            let (req, _) = pacer.ingest_real_frame(f, (t * 1e6) as i64, t, GcFrameGenMode::Off, None, false, -1.0);
            assert!(req.is_none());
            pacer.pop_due_frame(t);
        }

        let f_next = dummy_pb(64, 64);
        let (req, _) = pacer.ingest_real_frame(f_next, 1_300_000_000, 1300.0, GcFrameGenMode::FourX, None, false, -1.0);
        let req = req.expect("should dispatch 4x job on 30fps stream");
        assert_eq!(req.multiplier, 4);
        assert!(!req.capped_to_120hz);

        // Newer frame arrives while 4x job is still running -> must queue, NOT jump ahead!
        let f_later = dummy_pb(64, 64);
        let (req2, out2) = pacer.ingest_real_frame(f_later, 1_333_333_000, 1333.33, GcFrameGenMode::FourX, None, false, -1.0);
        assert!(req2.is_none());
        assert_eq!(out2, IngestOutcome::QueuedBehindInFlight);
        assert!(pacer.pop_due_frame(1333.33).is_none());

        // Complete 4x job -> delivers 3 interp + 1 real AND automatically chains f_later!
        let chained = pacer.on_vt_complete(
            req.job_id,
            vec![dummy_pb(64, 64), dummy_pb(64, 64), dummy_pb(64, 64)],
            0,
            1311.0,
            false,
            |_, _| -1.0,
        );
        assert!(chained.is_some(), "queued frame should chain immediately");

        let mut seqs = Vec::new();
        let mut t = 1311.0;
        for _ in 0..20 {
            if let Some(f) = pacer.pop_due_frame(t) {
                seqs.push((f.seq, f.is_interpolated));
            }
            t += 4.0;
        }
        assert_eq!(seqs.len(), 4);
        assert!(seqs.windows(2).all(|w| w[1].0 > w[0].0), "sequences must be strictly increasing");
        assert_eq!(seqs.iter().map(|x| x.1).collect::<Vec<_>>(), vec![true, true, true, false]);
    }

    #[test]
    fn four_x_auto_caps_to_two_x_on_60fps_stream() {
        let mut pacer = FramePacer::new();
        let f0 = dummy_pb(64, 64);
        let f1 = dummy_pb(64, 64);
        pacer.ingest_real_frame(f0, 0, 1000.0, GcFrameGenMode::FourX, None, false, -1.0);
        pacer.pop_due_frame(1000.0);
        let (req, _) = pacer.ingest_real_frame(f1, 16_670_000, 1016.67, GcFrameGenMode::FourX, None, false, -1.0);
        let req = req.unwrap();
        assert_eq!(req.multiplier, 2);
        assert!(req.capped_to_120hz);
    }

    #[test]
    fn scene_guard_skips_static_and_cuts() {
        let mut pacer = FramePacer::new();
        pacer.ingest_real_frame(dummy_pb(64, 64), 0, 1000.0, GcFrameGenMode::TwoX, None, true, 10.0);
        let (r_static, o_static) = pacer.ingest_real_frame(dummy_pb(64, 64), 16_000_000, 1016.0, GcFrameGenMode::TwoX, None, true, 0.1);
        assert!(r_static.is_none());
        assert_eq!(o_static, IngestOutcome::StaticSkippedAne);

        let (r_cut, o_cut) = pacer.ingest_real_frame(dummy_pb(64, 64), 33_000_000, 1033.0, GcFrameGenMode::TwoX, None, true, 52.0);
        assert!(r_cut.is_none());
        assert_eq!(o_cut, IngestOutcome::SceneCutBypassed);
    }
}
