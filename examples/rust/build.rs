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

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=zwasm");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib_dir.display());
}
