//! zwasm v2 — minimal Zig host example (§13.5).
//!
//! Drives the **native Zig embedding API** (ADR-0109): Engine → compile →
//! instantiate → `typedFunc().call()`. This is the Zig-native counterpart
//! to `examples/c_host/hello.c` (which uses the wasm-c-api C ABI) — same
//! module, two embedding surfaces.
//!
//!   (module (func (export "main") (result i32) (i32.const 42)))
//!
//! Built + run by `zig build run-zig-host` (and exercised in test-all).
//! Exits 0 on success (main() == 42).

const std = @import("std");
const zwasm = @import("zwasm");

const hello_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x03, 0x02, 0x01, 0x00, // func[0]: type 0
    0x07, 0x08, 0x01, 0x04, 0x6d, 0x61, 0x69, 0x6e, 0x00, 0x00, // export "main"
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: i32.const 42
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var eng = try zwasm.Engine.init(alloc, .{});
    defer eng.deinit();
    var mod = try eng.compile(&hello_wasm);
    defer mod.deinit();
    var inst = try mod.instantiate(.{});
    defer inst.deinit();

    const main_fn = inst.typedFunc(fn () i32, "main");
    const result = try main_fn.call(.{});

    std.debug.print("zwasm zig_host: main() = {d}\n", .{result});
    if (result != 42) std.process.exit(2);
}
