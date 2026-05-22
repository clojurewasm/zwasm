//! Buffer-write entry wrapper thunk (ADR-0106 cycle 3e
//! foundation).
//!
//! Per the cycle 3e design spike at
//! `private/spikes/adr-0106-cycle3e-call-lowering/SPIKE.md`
//! §"REVISED APPROACH", the cycle 3e implementation pivots
//! from "in-body buffer_write epilogue" to "per-function
//! wrapper thunk":
//!
//! - **Function body**: unchanged, compiled with default
//!   `.register_write` epilogue. Intra-module dispatch
//!   (Wasm `call N` / `call_indirect`) routes through
//!   `funcptr_base[i]` = body address, preserving register
//!   convention internally.
//! - **Wrapper thunk** (this file): a JIT-emitted machine-
//!   code thunk per multi-result function. Zig-side
//!   signature `fn(rt, results, args) callconv(.c) ErrCode`
//!   — single u32 return, no hidden RCX pointer issue on
//!   Win64. Internally calls the function body via raw
//!   assembly (no `callconv(.c)` at the internal call →
//!   no Win64 ABI rules → no struct-return ABI mismatch).
//!
//! Per-arch emit primitives are stubs in this commit; cycle
//! 3e Phase 2' implements them. This file provides the
//! type foundation + the `EmitParams` shape so subsequent
//! cycles have a stable callsite contract.
//!
//! Zone 2 (`src/engine/codegen/shared/`) — same as
//! `entry_buffer_write.zig` + `result_abi.zig`.

const std = @import("std");
const builtin = @import("builtin");

const jit_abi = @import("jit_abi.zig");
const FuncType = @import("../../../ir/zir.zig").FuncType;

/// Wrapper thunk emit parameters. The caller (cycle 3e
/// `compileWasm` + linker) builds this per multi-result
/// function it wants to wrap.
pub const EmitParams = struct {
    /// Wasm function signature — params + results define
    /// how the wrapper loads args from `[R8/RDX/X2 + 8*i]`
    /// and stores results to `[RDX/RSI/X1 + 8*i]`.
    sig: FuncType,
    /// Byte offset of the function body within the linker's
    /// linked code blob. The wrapper's internal CALL/BL
    /// reaches this address (PC-relative on arm64, RIP-
    /// relative + indirect on x86_64).
    body_offset: u32,
    /// Self-offset where the wrapper itself lives within
    /// the linked code blob. Needed to compute the
    /// body_offset - thunk_offset displacement for the
    /// internal CALL/BL.
    thunk_offset: u32,
};

/// Per-arch emit result.
pub const EmitOutput = struct {
    /// Wrapper thunk machine-code bytes.
    bytes: []const u8,
};

/// Emit a wrapper thunk for the given function. Per-arch
/// dispatch happens here; the implementation is platform-
/// specific bytes-emit per the calling convention.
///
/// CYCLE 3e STATUS: stub returning Error.UnsupportedOp. The
/// actual emit logic for x86_64 + arm64 lands in Phase 2'
/// per the spike doc. This file provides the type + public
/// API foundation so callers + tests have a stable shape.
pub const Error = error{
    /// The function shape isn't supported by this arch's
    /// wrapper emit. Cycle 3e Phase 2' replaces this with
    /// the actual per-shape emit.
    UnsupportedOp,
    /// Allocator out of memory during byte buffer growth.
    OutOfMemory,
};

pub fn emit(
    _: std.mem.Allocator,
    _: EmitParams,
) Error!EmitOutput {
    // CYCLE 3e PHASE 2' will replace this stub with per-arch
    // emit. The stub returns UnsupportedOp so callers can
    // detect "wrapper not yet implemented" cleanly.
    return Error.UnsupportedOp;
}

const testing = std.testing;

test "wrapper_thunk: EmitParams + EmitOutput types present" {
    // Compile-time sanity: the types exist and have the
    // expected fields. Once Phase 2' lands, additional
    // tests verify byte-sequence correctness per arch.
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &.{} },
        .body_offset = 0,
        .thunk_offset = 0,
    };
    _ = params;
}

test "wrapper_thunk: emit stub returns UnsupportedOp" {
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &.{} },
        .body_offset = 0,
        .thunk_offset = 0,
    };
    const r = emit(testing.allocator, params);
    try testing.expectError(Error.UnsupportedOp, r);
}

// Reference jit_abi so the import survives `zig build test`
// even though Phase 2' is the consumer.
comptime {
    _ = jit_abi;
    _ = builtin;
}
