//! Per-function entry counter — a D-489 differential primitive.
//!
//! A process-global `[max_funcs]u64` indexed by wasm func_idx. Both the
//! interp (frame-push site) and the JIT (function prologue, via an emitted
//! `INC [&counts + idx*8]`) bump the same array, so a `ZWASM_DEBUG=jit.callcount`
//! run of the SAME module under each engine yields two call profiles. Diffing
//! them surfaces the first function whose execution count diverges — e.g. a
//! function called N times under interp but 0 under x86_64-jit is downstream of
//! a miscompiled loop/branch count (the D-489 "count→0 under spill" shape).
//!
//! Gated entirely by `ZWASM_DEBUG=jit.callcount` (compile-time check in the JIT
//! emitter; runtime check at the interp bump + dump). Zero cost when off: the
//! JIT simply does not emit the INC, and the interp's `dbg.on` guard short-
//! circuits. Zone 0 (`support/`) so every zone may import it.

const std = @import("std");

/// Fixed upper bound on func count for the profiler array. Realworld TinyGo/Go
/// modules sit well under this (tinygo_json ≈ 266 funcs). A func_idx ≥ this is
/// silently not counted (the diff still works for the lower indices).
pub const max_funcs: usize = 16384;

/// Process-global counter array. The JIT prologue emits an absolute-address
/// `INC qword [&counts + idx*8]`; `@intFromPtr(&counts)` gives that base.
pub var counts: [max_funcs]u64 = [_]u64{0} ** max_funcs;

/// Interp-side bump (the JIT bumps via emitted code). Caller guards with
/// `dbg.on("jit.callcount")` so the common path stays branch-free here.
pub inline fn bump(func_idx: u32) void {
    if (func_idx < max_funcs) counts[func_idx] +%= 1;
}

/// Print every non-zero counter as `[callcount] idx=<N> count=<C>` to stderr.
/// Called at program end (CLI run path) when the gate is on. func_idx → name
/// mapping is done offline via `wasm-tools print` (the wasm name section).
pub fn dump() void {
    for (counts, 0..) |c, idx| {
        if (c != 0) std.debug.print("[callcount] idx={d} count={d}\n", .{ idx, c });
    }
}

/// Zero the array (between runs in the same process, e.g. tests). Not needed
/// for the one-shot CLI path.
pub fn reset() void {
    @memset(&counts, 0);
}

test "bump increments per-index; reset clears; out-of-range is a no-op" {
    const testing = @import("std").testing;
    reset();
    bump(5);
    bump(5);
    bump(7);
    bump(max_funcs); // out of range → ignored, no panic
    try testing.expectEqual(@as(u64, 2), counts[5]);
    try testing.expectEqual(@as(u64, 1), counts[7]);
    try testing.expectEqual(@as(u64, 0), counts[6]);
    reset();
    try testing.expectEqual(@as(u64, 0), counts[5]);
}
