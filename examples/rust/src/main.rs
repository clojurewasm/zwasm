//! main.rs — Minimal example using the zwasm C API via FFI
//!
//! Demonstrates: load module, invoke exported function, read result.
//!
//! Build: zig build lib && cargo build
//! Run:   cargo run

#[repr(C)]
struct zwasm_module_t {
    _private: [u8; 0],
}

#[link(name = "zwasm")]
unsafe extern "C" {
    fn zwasm_module_new(wasm_ptr: *const u8, len: usize) -> *mut zwasm_module_t;
    fn zwasm_module_invoke(
        module: *mut zwasm_module_t,
        name: *const std::ffi::c_char,
        args: *mut u64,
        nargs: u32,
        results: *mut u64,
        nresults: u32,
    ) -> bool;
    fn zwasm_module_delete(module: *mut zwasm_module_t);
    fn zwasm_last_error_message() -> *const std::ffi::c_char;
}

/* Wasm module: export "f" () -> i32 { return 42 } */
const WASM: &[u8] = &[
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
    0x02, 0x01, 0x00, 0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41,
    0x2a, 0x0b,
];

fn main() {
    unsafe {
        let module = zwasm_module_new(WASM.as_ptr(), WASM.len());

        if module.is_null() {
            let err_msg = zwasm_last_error_message();
            let c_str = std::ffi::CStr::from_ptr(err_msg);
            eprintln!("Failed to create module: {}", c_str.to_str().unwrap());
            return;
        }

        let name = std::ffi::CString::new("f").unwrap();
        let mut results = [0u64; 1];
        let ok = zwasm_module_invoke(
            module,
            name.as_ptr(),
            std::ptr::null_mut(),
            0,
            results.as_mut_ptr(),
            results.len() as u32,
        );

        if !ok {
            let err_msg = zwasm_last_error_message();
            let c_str = std::ffi::CStr::from_ptr(err_msg);
            eprintln!("Invoke error: {}", c_str.to_str().unwrap());
            zwasm_module_delete(module);
            return;
        }

        println!("f() = {}", results[0]);
        zwasm_module_delete(module);
    }
}
