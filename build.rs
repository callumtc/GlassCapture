use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let objc_dir = manifest_dir.join("objc");

    let sources = [
        "app_window.m",
        "capture_engine.m",
        "screen_capture.m",
        "video_processor.m",
        "metal_renderer.m",
        "recorder.m",
    ];

    println!("cargo:rerun-if-changed=objc/bridge.h");
    for src in &sources {
        println!("cargo:rerun-if-changed=objc/{src}");
    }

    let sdk_path_out = Command::new("xcrun")
        .args(["--show-sdk-path", "--sdk", "macosx"])
        .output()
        .expect("Failed to invoke xcrun to find macOS SDK");
    let sdk_path = String::from_utf8(sdk_path_out.stdout)
        .expect("Invalid UTF-8 SDK path")
        .trim()
        .to_string();

    let profile = env::var("PROFILE").unwrap_or_else(|_| "debug".to_string());
    let opt_flag = if profile == "release" { "-O3" } else { "-O1" };

    let mut obj_paths = Vec::new();
    for src in &sources {
        let src_path = objc_dir.join(src);
        let obj_path = out_dir.join(format!("{src}.o"));

        let status = Command::new("clang")
            .args([
                "-c",
                "-fobjc-arc",
                "-fobjc-weak",
                "-Wall",
                "-Wextra",
                "-Wno-unused-parameter",
                opt_flag,
                "-g",
                "-arch",
                "arm64",
                "-mmacosx-version-min=26.0",
                "-isysroot",
                &sdk_path,
                "-I",
                objc_dir.to_str().unwrap(),
                src_path.to_str().unwrap(),
                "-o",
                obj_path.to_str().unwrap(),
            ])
            .status()
            .expect("Failed to run clang");

        if !status.success() {
            panic!("clang failed compiling objc/{src}");
        }
        obj_paths.push(obj_path);
    }

    let lib_path = out_dir.join("libgc_objc.a");
    let mut ar_cmd = Command::new("ar");
    ar_cmd.arg("rcs").arg(&lib_path);
    for obj in &obj_paths {
        ar_cmd.arg(obj);
    }
    let ar_status = ar_cmd.status().expect("Failed to run ar");
    if !ar_status.success() {
        panic!("ar failed creating libgc_objc.a");
    }

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=gc_objc");

    let frameworks = [
        "AppKit",
        "Foundation",
        "AVFoundation",
        "AVFAudio",
        "CoreAudio",
        "AudioToolbox",
        "CoreMedia",
        "CoreVideo",
        "CoreGraphics",
        "QuartzCore",
        "Metal",
        "MetalFX",
        "VideoToolbox",
        "ScreenCaptureKit",
        "Carbon",
        "ImageIO",
        "UniformTypeIdentifiers",
        "IOSurface",
    ];
    for fw in frameworks {
        println!("cargo:rustc-link-lib=framework={fw}");
    }
    println!("cargo:rustc-link-lib=objc");

    // Link clang_rt.osx so @available(...) runtime checks resolve under Rust's -nodefaultlibs
    if let Ok(out) = Command::new("clang").arg("-print-resource-dir").output() {
        let res_dir = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let rt_path = PathBuf::from(&res_dir).join("lib/darwin/libclang_rt.osx.a");
        if rt_path.exists() {
            println!("cargo:rustc-link-arg={}", rt_path.display());
        }
    }
}
