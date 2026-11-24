# GlassCapture

A lightweight, native **Rust** macOS capture-card viewer featuring **Apple Liquid Glass** (`NSGlassEffectView` / `NSGlassEffectContainerView`) and full Apple Silicon hardware acceleration for **Neural Frame Generation** and **Upscaling**.

## Hardware Acceleration Pipeline

- **Mac Game & App Window Capture + Click-Through Overlay (`ScreenCaptureKit`)**: Captures any on-screen Mac game or app window (`SCContentFilter(desktopIndependentWindow:)`) with zero feedback loop and can project a borderless, click-through (`ignoresMouseEvents`) upscaled & frame-generated overlay directly on top of the game (**Match Window** or **Full Screen**) with global hotkeys (`⌘⇧O`, `⌘⇧G`, `⌘⇧H`) and a macOS Menu Bar quick menu.
- **Capture Input (`AVFoundation`)**: Discovers external USB/UVC/HDMI/Thunderbolt capture cards first (`AVCaptureDeviceTypeExternal`), with live hot-plug refresh, format/FPS picker, and zero-copy `'420v'` (`IOSurface`) delivery.
- **Neural Frame Generation (`VideoToolbox`)**: Uses `VTFrameProcessor` + `VTLowLatencyFrameInterpolationConfiguration` on Apple Silicon's Neural Engine & Media Engine:
  - **Off (1×)** — Direct zero-copy passthrough for absolute lowest latency.
  - **2× Neural** — Generates intermediate motion-compensated frames (`phase = 0.5`) to double 30→60 fps or 60→120 fps on ProMotion displays.
  - **4× Neural** — Generates 3 intermediate frames (`0.25, 0.5, 0.75`) for 30→120 fps smoothness.
  - Backed by a monotonic Rust frame pacer (`src/pacer.rs`) synced to the display's hardware VSync (`CVDisplayLink`) with anti-drift backpressure.
- **Hardware Upscaling (`VideoToolbox ML` + `MetalFX` + `Metal`)**:
  - **Auto ML + MetalFX** — Uses `VTLowLatencySuperResolutionScalerConfiguration` on eligible sources (e.g. 720p→1080p `1.5×`, ≤540p→1080p `2×`), seamlessly handing off to `MTLFXSpatialScaler` to reach full Retina / 4K resolution.
  - **MetalFX Spatial** — Sub-millisecond Apple GPU spatial upscaling at any resolution.
  - **CAS Sharp** — Custom Metal Contrast-Adaptive Sharpening shader.
  - **Pixel Integer** — Crisp nearest-neighbor scaling + `1:1` integer pixel lock for retro consoles.
- **HDR / EDR Passthrough (`Metal` + `MetalFX HDR` + `ScreenCaptureKit HDR`)**: Dynamic `RGBA16Float` Extended Dynamic Range (`wantsExtendedDynamicRangeContent`) output supporting 10-bit PQ/HLG capture feeds, 16-bit extended-linear HDR Mac games, and smooth XDR highlight expansion, with glowing golden `HDR` / `HDR10` tags in the top bar and HUD.
- **Full-Screen Immersion & Clean View**: Automatically hides all UI pills, the Performance HUD, and the mouse cursor after 2 seconds of inactivity in Full Screen, plus an instant **`C` (Clean View)** toggle to hide all UI/HUD anytime.
- **Low-Latency Audio Passthrough**: Independent capture-card audio session feeding a lock-free atomic SPSC ring buffer into `AVAudioEngine` with volume, mute, and live peak meter.
- **Screenshots & HEVC Recording**: Instant lossless PNG snapshots (`~/Pictures/GlassCapture/`) and hardware-accelerated HEVC `.mov` recording (`~/Movies/GlassCapture/`).

## Build & Install

Requires macOS 26+ (Apple Silicon), Apple Command Line Tools, and Rust (`~/.cargo/bin`). No Xcode required.

```bash
./scripts/bundle_app.sh
```

This compiles the zero-dependency Rust release binary (`~644 KB`), generates the Liquid Glass `.icns` icon, ad-hoc signs the bundle, and installs it to:
- `~/Developer/GlassCapture/dist/GlassCapture.app`
- `~/Applications/GlassCapture.app`

Run hardware diagnostics from CLI:
```bash
~/Applications/GlassCapture.app/Contents/MacOS/glass_capture --info
```

## Keyboard Shortcuts

| Key | Action |
|---|---|
| `⌘⇧O` (Global) / `O` | Enter / Exit Click-Through Game & App Overlay Mode |
| `⌘⇧G` (Global) / `G` | Cycle Neural Frame Generation (`Off` → `2×` → `4×`) |
| `⌘⇧H` (Global) / `H` | Toggle floating Liquid Glass Performance HUD |
| `C` | Clean View — Hide / Show all UI & HUD immediately |
| `D` | Toggle HDR / EDR Passthrough |
| `B` | Toggle Split-Screen A/B Compare (Raw vs Enhanced) |
| `U` | Cycle Upscaler (`Off` → `MetalFX` → `Auto ML` → `CAS Sharp` → `Integer`) |
| `I` | Toggle Liquid Glass Tuning Inspector |
| `T` | Toggle Always on Top / Picture-in-Picture |
| `F` or Double-Click | Toggle Full Screen |
| `M` | Mute / Unmute capture audio |
| `Space` | Freeze / Resume live video |
| `S` | Save lossless PNG screenshot |
| `R` | Start / Stop hardware HEVC recording |
| `⌘,` | Toggle Liquid Glass style (`Regular` / `Clear`) |
