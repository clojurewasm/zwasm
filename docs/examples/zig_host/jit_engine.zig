//! zwasm v2 — Zig mini-consumer for the JIT-backed embedding API (ADR-0200).
//!
//! Native Zig embedder selecting the JIT engine per-instance
//! (`Module.instantiate(.{ .engine = .jit })`) and driving it through the
//! ADR-0109 facade (`typedFunc().call()`). Counterpart to
//! `docs/examples/c_host/jit_engine.c` — same module, two embedding surfaces.
//!
//! One module exports a multi-arg `add` (→5) and a SIMD-body `lane0`
//! (i32x4.extract_lane on a v128.const → 42; SIMD executes on the JIT, the
//! user's "SIMD must be JIT" constraint met at a scalar boundary).
//!
//! `zig build run-zig-host-jit` (and exercised in test-all). Exits 0 on success.

const std = @import("std");
const zwasm = @import("zwasm");

// (module
//   (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
//   (func (export "lane0") (result i32)
//     (i32x4.extract_lane 0 (v128.const i32x4 42 0 0 0))))
const jit_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x0b, 0x02, 0x60, 0x02, 0x7f, 0x7f, 0x01,
    0x7f, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x03, 0x02,
    0x00, 0x01, 0x07, 0x0f, 0x02, 0x03, 0x61, 0x64,
    0x64, 0x00, 0x00, 0x05, 0x6c, 0x61, 0x6e, 0x65,
    0x30, 0x00, 0x01, 0x0a, 0x21, 0x02, 0x07, 0x00,
    0x20, 0x00, 0x20, 0x01, 0x6a, 0x0b, 0x17, 0x00,
    0xfd, 0x0c, 0x2a, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0xfd, 0x1b, 0x00, 0x0b,
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var eng = try zwasm.Engine.init(alloc, .{});
    defer eng.deinit();
    var mod = try eng.compile(&jit_wasm);
    defer mod.deinit();

    // The engine knob — per-instance JIT selection (interp coexists). One field.
    var inst = try mod.instantiate(.{ .engine = .jit });
    defer inst.deinit();

    const add = inst.typedFunc(fn (i32, i32) i32, "add");
    const sum = try add.call(.{ 2, 3 });
    if (sum != 5) {
        std.debug.print("zig_host (JIT): add(2,3) = {d} != 5\n", .{sum});
        std.process.exit(2);
    }

    const lane0 = inst.typedFunc(fn () i32, "lane0");
    const lane = try lane0.call(.{});
    if (lane != 42) {
        std.debug.print("zig_host (JIT): lane0() = {d} != 42\n", .{lane});
        std.process.exit(3);
    }

    std.debug.print("zwasm zig_host (JIT): add(2,3)={d} lane0()={d}\n", .{ sum, lane });
}
