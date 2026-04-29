use std::{env, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let lib_dir = manifest
        .join("..")
        .join("..")
        .join("zig-out")
        .join("lib")
        .canonicalize()
        .expect("zig-out/lib not found — run `zig build lib` first");

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let is_windows = target_os == "windows";

    if env::var("ZWASM_STATIC").is_ok() {
        // Static linking: requires libzwasm.a (POSIX) / zwasm.lib (Windows MSVC)
        // built with `-Dpic=true -Dcompiler-rt=true`. Copy only the archive
        // to a temp dir so the linker can't pick the .dylib/.so/.dll.
        let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
        let static_dir = out_dir.join("zwasm_static");
        std::fs::create_dir_all(&static_dir).unwrap();
        let archive_name = if is_windows { "zwasm.lib" } else { "libzwasm.a" };
        std::fs::copy(lib_dir.join(archive_name), static_dir.join(archive_name)).unwrap();
        println!("cargo:rustc-link-search=native={}", static_dir.display());
        println!("cargo:rustc-link-lib=static=zwasm");
        if !is_windows {
            // POSIX libc / libm. On Windows MSVC the CRT is auto-linked
            // by rustc; explicit `-lc` / `-lm` would fail because they
            // are not separate libraries on that ABI.
            println!("cargo:rustc-link-lib=c");
            println!("cargo:rustc-link-lib=m");
        }
    } else {
        // Dynamic linking (default).
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
        println!("cargo:rustc-link-lib=zwasm");
        if is_windows {
            // Windows DLL search order looks at the executable directory
            // first. Zig installs `zwasm.dll` to `zig-out/bin/`; copy it
            // alongside the cargo target binary so `cargo run` finds it
            // at runtime. There is no analogue of `-Wl,-rpath` on PE.
            let bin_dir = manifest
                .join("..")
                .join("..")
                .join("zig-out")
                .join("bin")
                .canonicalize()
                .expect("zig-out/bin not found — run `zig build shared-lib` first");
            let dll_src = bin_dir.join("zwasm.dll");
            // OUT_DIR is `<target>/<profile>/build/<crate>-<hash>/out`,
            // so `<target>/<profile>` is three ancestors up.
            let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
            let target_profile_dir = out_dir
                .ancestors()
                .nth(3)
                .expect("OUT_DIR ancestor lookup")
                .to_path_buf();
            let dll_dst = target_profile_dir.join("zwasm.dll");
            std::fs::copy(&dll_src, &dll_dst)
                .expect("copying zwasm.dll next to cargo target binary");
            println!("cargo:rerun-if-changed={}", dll_src.display());
        } else {
            // POSIX: rpath the zig-out/lib directory directly.
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
        }
    }
}
