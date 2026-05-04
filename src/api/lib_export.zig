//! Static-library root for the C ABI binding (§9.3 / 3.9).
//!
//! `zig build` produces `libzwasm.a` from this module. The lone
//! purpose of the file is to pull in `wasm.zig` so the
//! `export fn` symbols there land in the resulting archive — C
//! hosts (e.g. `examples/c_host/hello.c`) link against this lib
//! to call into the runtime.
//!
//! Zone 3 (`src/api/`) — same zone as `wasm.zig`.

comptime {
    _ = @import("wasm.zig");
    _ = @import("wasi.zig");
    _ = @import("trap_surface.zig");
    _ = @import("vec.zig");
    _ = @import("instance.zig");
}
