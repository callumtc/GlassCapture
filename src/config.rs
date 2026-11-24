use crate::ffi::{GC_OVERLAY_MATCH_WINDOW, GcAspectMode, GcFrameGenMode, GcUiStateSnapshot, GcUpscaleMode};
use std::fs;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub selected_video_uid: String,
    pub selected_format_index: i32,
    pub selected_audio_uid: String,
    pub upscale_mode: GcUpscaleMode,
    pub framegen_mode: GcFrameGenMode,
    pub aspect_mode: GcAspectMode,
    pub integer_lock: bool,
    pub always_on_top: bool,
    pub hud_visible: bool,
    pub hdr_enabled: bool,
    pub audio_muted: bool,
    pub audio_volume: f32,
    pub sharpness: f32,
    pub color_range_mode: i32,   // 0 = Auto, 1 = Limited, 2 = Full
    pub contrast: f32,
    pub saturation: f32,
    pub gamma: f32,
    pub overscan_crop: f32,
    pub ab_split_enabled: bool,
    pub ab_split_pos: f32,
    pub scene_guard_enabled: bool,
    pub glass_style: i32,        // 0 = Regular, 1 = Clear
    pub preferred_overlay: i32,  // 1 = Match Window, 2 = Full Screen
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            selected_video_uid: String::new(),
            selected_format_index: -1,
            selected_audio_uid: String::new(),
            upscale_mode: GcUpscaleMode::AutoMl,
            framegen_mode: GcFrameGenMode::TwoX,
            aspect_mode: GcAspectMode::Fit,
            integer_lock: false,
            always_on_top: false,
            hud_visible: true,
            hdr_enabled: false,
            audio_muted: false,
            audio_volume: 0.85,
            sharpness: 0.35,
            color_range_mode: 0,
            contrast: 1.0,
            saturation: 1.0,
            gamma: 1.0,
            overscan_crop: 0.0,
            ab_split_enabled: false,
            ab_split_pos: 0.5,
            scene_guard_enabled: true,
            glass_style: 0,
            preferred_overlay: GC_OVERLAY_MATCH_WINDOW,
        }
    }
}

impl AppConfig {
    pub fn config_path() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("GlassCapture")
            .join("config.toml")
    }

    pub fn load() -> Self {
        let mut cfg = Self::default();
        let Ok(content) = fs::read_to_string(Self::config_path()) else {
            return cfg;
        };
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }
            let Some((k, v)) = trimmed.split_once('=') else {
                continue;
            };
            let key = k.trim();
            let val = v.trim().trim_matches('"');
            match key {
                "selected_video_uid" => cfg.selected_video_uid = val.to_string(),
                "selected_format_index" => {
                    if let Ok(n) = val.parse() {
                        cfg.selected_format_index = n;
                    }
                }
                "selected_audio_uid" => cfg.selected_audio_uid = val.to_string(),
                "upscale_mode" => {
                    if let Ok(n) = val.parse() {
                        cfg.upscale_mode = GcUpscaleMode::from_i32(n);
                    }
                }
                "framegen_mode" => {
                    if let Ok(n) = val.parse() {
                        cfg.framegen_mode = GcFrameGenMode::from_i32(n);
                    }
                }
                "aspect_mode" => {
                    if let Ok(n) = val.parse() {
                        cfg.aspect_mode = GcAspectMode::from_i32(n);
                    }
                }
                "integer_lock" => cfg.integer_lock = val == "true",
                "always_on_top" => cfg.always_on_top = val == "true",
                "hud_visible" => cfg.hud_visible = val == "true",
                "hdr_enabled" => cfg.hdr_enabled = val == "true",
                "audio_muted" => cfg.audio_muted = val == "true",
                "audio_volume" => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.audio_volume = f.clamp(0.0, 1.0);
                    }
                }
                "sharpness" => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.sharpness = f.clamp(0.0, 1.0);
                    }
                }
                "color_range_mode" => {
                    if let Ok(n) = val.parse() {
                        cfg.color_range_mode = n;
                    }
                }
                "contrast" => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.contrast = f.clamp(0.7, 1.5);
                    }
                }
                "saturation" => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.saturation = f.clamp(0.0, 1.8);
                    }
                }
                "gamma" => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.gamma = f.clamp(0.6, 1.6);
                    }
                }
                "overscan_crop" => {
                    if let Ok(f) = val.parse::<f32>() {
                        cfg.overscan_crop = f.clamp(0.0, 0.08);
                    }
                }
                "scene_guard_enabled" => cfg.scene_guard_enabled = val == "true",
                "glass_style" => {
                    if let Ok(n) = val.parse() {
                        cfg.glass_style = n;
                    }
                }
                "preferred_overlay" => {
                    if let Ok(n) = val.parse() {
                        cfg.preferred_overlay = n;
                    }
                }
                _ => {}
            }
        }
        cfg
    }

    pub fn save(&self) {
        let path = Self::config_path();
        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let body = format!(
            "# GlassCapture configuration\n\
             selected_video_uid = \"{}\"\n\
             selected_format_index = {}\n\
             selected_audio_uid = \"{}\"\n\
             upscale_mode = {}\n\
             framegen_mode = {}\n\
             aspect_mode = {}\n\
             integer_lock = {}\n\
             always_on_top = {}\n\
             hud_visible = {}\n\
             hdr_enabled = {}\n\
             audio_muted = {}\n\
             audio_volume = {:.3}\n\
             sharpness = {:.3}\n\
             color_range_mode = {}\n\
             contrast = {:.3}\n\
             saturation = {:.3}\n\
             gamma = {:.3}\n\
             overscan_crop = {:.4}\n\
             scene_guard_enabled = {}\n\
             glass_style = {}\n\
             preferred_overlay = {}\n",
            self.selected_video_uid,
            self.selected_format_index,
            self.selected_audio_uid,
            self.upscale_mode as i32,
            self.framegen_mode as i32,
            self.aspect_mode as i32,
            self.integer_lock,
            self.always_on_top,
            self.hud_visible,
            self.hdr_enabled,
            self.audio_muted,
            self.audio_volume,
            self.sharpness,
            self.color_range_mode,
            self.contrast,
            self.saturation,
            self.gamma,
            self.overscan_crop,
            self.scene_guard_enabled,
            self.glass_style,
            self.preferred_overlay
        );
        let _ = fs::write(path, body);
    }

    pub fn to_ui_snapshot(
        &self,
        is_recording: bool,
        is_paused: bool,
        overlay_mode: i32,
        clean_view: bool,
    ) -> GcUiStateSnapshot {
        GcUiStateSnapshot {
            upscale_mode: self.upscale_mode as i32,
            framegen_mode: self.framegen_mode as i32,
            aspect_mode: self.aspect_mode as i32,
            integer_lock: self.integer_lock,
            always_on_top: self.always_on_top,
            hud_visible: self.hud_visible,
            clean_view,
            hdr_enabled: self.hdr_enabled,
            audio_muted: self.audio_muted,
            audio_volume: self.audio_volume,
            sharpness: self.sharpness,
            color_range_mode: self.color_range_mode,
            contrast: self.contrast,
            saturation: self.saturation,
            gamma: self.gamma,
            overscan_crop: self.overscan_crop,
            ab_split_enabled: self.ab_split_enabled,
            ab_split_pos: self.ab_split_pos,
            scene_guard_enabled: self.scene_guard_enabled,
            is_recording,
            is_paused,
            glass_style: self.glass_style,
            overlay_mode,
            preferred_overlay: self.preferred_overlay,
        }
    }
}
