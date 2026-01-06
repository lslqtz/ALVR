use std::{env, path::PathBuf};

fn main() {
    // 只在 Windows ARM64 上构建
    let target = env::var("TARGET").unwrap_or_default();
    
    if !target.contains("aarch64") || !target.contains("windows") {
        println!("cargo:warning=This crate is designed for aarch64-pc-windows-msvc target");
    }

    // 查找 ARM64 FFmpeg
    let ffmpeg_dir = find_ffmpeg_dir();
    
    if let Some(dir) = ffmpeg_dir {
        println!("cargo:rustc-link-search=native={}/lib", dir.display());
        println!("cargo:rustc-link-lib=avcodec");
        println!("cargo:rustc-link-lib=avutil");
        println!("cargo:rustc-link-lib=swscale");
        
        // 生成 FFmpeg bindings
        let bindings = bindgen::Builder::default()
            .header("wrapper.h")
            .clang_arg(format!("-I{}/include", dir.display()))
            .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
            .generate()
            .expect("Unable to generate FFmpeg bindings");
        
        let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
        bindings
            .write_to_file(out_path.join("ffmpeg_bindings.rs"))
            .expect("Couldn't write bindings!");
    } else {
        println!("cargo:warning=FFmpeg ARM64 not found, encoder will not work");
    }
}

fn find_ffmpeg_dir() -> Option<PathBuf> {
    // 优先查找 deps/windows/ffmpeg-arm64
    let workspace_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap())
        .parent()? // alvr
        .parent()? // ALVR root
        .to_path_buf();
    
    let deps_arm64 = workspace_dir.join("deps/windows/ffmpeg-arm64");
    if deps_arm64.exists() {
        return Some(deps_arm64);
    }
    
    // 备选：尝试 pkg-config
    if let Ok(lib) = pkg_config::Config::new().probe("libavcodec") {
        if let Some(path) = lib.link_paths.first() {
            return Some(path.parent()?.to_path_buf());
        }
    }
    
    None
}
