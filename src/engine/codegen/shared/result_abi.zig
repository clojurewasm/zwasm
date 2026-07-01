//! Result-marshal ABI selector for JIT-compiled functions
//! (ADR-0106 path (a) foundation).
//!
//! Threaded into `arm64/emit.zig::compile()` + `x86_64/emit.zig::compile()`
//! to select between the legacy register-write epilogue
//! (per-class C-ABI: RAX/RDX/XMM0/XMM1 on x86_64, X0..X7/V0..V7
//! on arm64) and the new buffer-write epilogue per
//! `entry_buffer_write.zig::BufferWriteFn`.
//!
//! Per the ADR-0106 design spike at
//! `private/spikes/adr-0106-cycle2/SPIKE.md` (Alt 2 chosen), the
//! buffer-write epilogue writes `results[i]` instead of the
//! per-class C-ABI registers (RAX/RDX / X0/X1).
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

pub const ResultAbi = enum {
    /// Legacy per-class register-write epilogue. Multi-result on
    /// Win64 mis-marshals via hidden RCX struct-return — the
    /// D-164 root cause documented in ADR-0106 §"Context".
    register_write,
    /// Buffer-write epilogue per ADR-0106 path (a). The JIT body
    /// writes each result to `[results_ptr + 8*i]`; the entry
    /// helper's signature is `fn(*JitRuntime, [*]u64 results,
    /// [*]const u64 args) callconv(.c) ErrCode`. Win64-safe
    /// (single u64 ErrCode return); SysV / AAPCS64 use the same
    /// uniform shape.
    buffer_write,
};

const testing = std.testing;

test "ResultAbi: enum values present" {
    const r: ResultAbi = .register_write;
    const b: ResultAbi = .buffer_write;
    try testing.expect(r != b);
}
