//! Static-library root for the C ABI binding (§9.3 / 3.9).
//!
//! `zig build` produces `libzwasm.a` from this module. The lone
//! purpose of the file is to pull in `wasm_c_api.zig` so the
//! `export fn` symbols there land in the resulting archive — C
//! hosts (e.g. `examples/c_host/hello.c`) link against this lib
//! to call into the runtime.
//!
//! Zone 3 (`src/c_api/`) — same zone as `wasm_c_api.zig`.

comptime {
    _ = @import("c_api/wasm_c_api.zig");
    _ = @import("c_api/wasi.zig");
    _ = @import("c_api/trap_surface.zig");
    _ = @import("c_api/vec.zig");
}
