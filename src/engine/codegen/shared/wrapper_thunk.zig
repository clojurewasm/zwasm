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

/// Emit a wrapper thunk for the given function. Per-arch
/// dispatch based on `builtin.cpu.arch` + `builtin.os.tag`.
///
/// CYCLE 3e Phase 2' (incremental): the only shape covered
/// in this commit is **x86_64 SysV, 3-int-result MEMORY-
/// class** (the `() → (i32, i32, i32)` SKIP arm shape).
/// Other shapes still return UnsupportedOp; subsequent
/// cycles add them per [`SPIKE.md`](../../../../private/spikes/adr-0106-cycle3e-call-lowering/SPIKE.md).
///
/// 3-int-result MEMORY-class wrapper (SysV) shape:
///
/// ```text
///     ; Wrapper entry (Zig caller passed: RDI=rt, RSI=results, RDX=args).
///     ; Body expects MEMORY-class layout: RDI=&result_buf, RSI=rt.
///     ; Args are 0 (the 3 SKIP-arm shapes all have empty params).
///     XCHG RDI, RSI            ; 48 87 FE  (3 bytes)
///     CALL body_offset         ; E8 d0 d1 d2 d3   (5 bytes; rel32 disp)
///     XOR EAX, EAX             ; 31 C0  (2 bytes; ErrCode_OK)
///     RET                      ; C3  (1 byte)
/// ```
///
/// Total: 11 bytes. Body writes 3 i32 results to
/// `[RDI+0/4/8]` directly via the MEMORY-class epilogue
/// (cycle-2c implementation); since RDI=results-buf for
/// us, the body fills the caller's buffer naturally.
///
/// Stack alignment: wrapper entry has RSP ≡ 8 (mod 16) per
/// SysV (after caller's CALL pushed return address). XCHG
/// doesn't change RSP. Wrapper's CALL pushes its own return
/// → body entry has RSP ≡ 0 (mod 16) which is SysV-correct
/// (body's PUSH RBP brings it back to ≡ 8).
pub fn emit(
    allocator: std.mem.Allocator,
    params: EmitParams,
) Error!EmitOutput {
    if (builtin.cpu.arch == .aarch64) {
        return emitAarch64(allocator, params);
    }
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag == .windows) {
        return Error.UnsupportedOp;
    }
    if (params.sig.params.len != 0) return Error.UnsupportedOp;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    // Classify shape: MEMORY-class (≥3 GPR results) vs register-class
    // (1-2 results in RAX/RDX). Per SysV §3.2.3.
    const n_results = params.sig.results.len;
    if (n_results == 3 and all_gpr_class(params.sig.results)) {
        // 3-int MEMORY-class: body expects RDI=&buf, RSI=rt.
        // Wrapper: XCHG RDI, RSI ; CALL body ; XOR EAX, EAX ; RET.
        try bytes.appendSlice(allocator, &.{ 0x48, 0x87, 0xFE });
        try emitCallRel32(allocator, &bytes, params, 3);
        try bytes.appendSlice(allocator, &.{ 0x31, 0xC0, 0xC3 });
    } else if (n_results == 2 and all_gpr_class(params.sig.results)) {
        // 2-int register-class: body writes results to RAX (result 0)
        // and RDX (result 1). Wrapper saves results-ptr to RBX
        // (callee-saved), calls body, then writes RAX → [RBX+0] and
        // RDX → [RBX+8]. Per ADR-0106 path (a) `[*]u64 results`
        // shape, each result occupies 8 bytes regardless of i32/i64;
        // the body's i32-result-zero-extends-to-64 + MOV r/m64
        // produces the correct u64-slot semantics for the typed
        // result helper to mask later.
        try bytes.append(allocator, 0x53); // PUSH RBX
        try bytes.appendSlice(allocator, &.{ 0x48, 0x89, 0xF3 }); // MOV RBX, RSI
        try emitCallRel32(allocator, &bytes, params, 1 + 3);
        try bytes.appendSlice(allocator, &.{ 0x48, 0x89, 0x03 }); // MOV [RBX], RAX
        try bytes.appendSlice(allocator, &.{ 0x48, 0x89, 0x53, 0x08 }); // MOV [RBX+8], RDX
        try bytes.append(allocator, 0x5B); // POP RBX
        try bytes.appendSlice(allocator, &.{ 0x31, 0xC0, 0xC3 }); // XOR EAX,EAX ; RET
    } else {
        return Error.UnsupportedOp;
    }

    return .{ .bytes = try bytes.toOwnedSlice(allocator) };
}

/// arm64 AAPCS64 wrapper emit (Mac aarch64).
///
/// AAPCS64 register usage: X0=rt, X1=results, X2=args (per ADR-0106
/// path (a)'s `fn(rt, results, args) callconv(.c) ErrCode`).
/// Body's MEMORY-class path (cycle 2c arm64 implementation) expects
/// X8=indirect-result-pointer + X0=rt; register-class path expects
/// X0=rt + result regs are X0/X1.
///
/// 3-int MEMORY-class shape (the `() → (i32, i32, i32)` SKIP shape):
///   MOV  X8, X1           ; results ptr into X8 hidden arg
///   ADRP X16, body        ; address-of-body high
///   ADD  X16, X16, body_lo
///   BLR  X16
///   MOV  W0, WZR          ; ErrCode_OK = 0
///   RET
///
/// For BLR-via-X16 setup the relative addressing math is more
/// complex than x86_64's CALL rel32. Use a simpler scheme: emit an
/// LDR-from-literal-pool that contains body_addr, then BLR. ~20 bytes.
/// Even simpler for relative-BL: arm64's B/BL is ±128MB range; for
/// in-module dispatch this is always reachable.
///
/// Simplest shape:
///   MOV  X8, X1                ; 0xAA0103E8  — 4 bytes (ORR X8, XZR, X1)
///   BL   body_offset            ; 0x94000000 | (imm26)  — 4 bytes
///   MOV  W0, WZR                ; 0x2A1F03E0  — 4 bytes (ORR W0, WZR, WZR)
///   RET                          ; 0xD65F03C0  — 4 bytes
///
/// Total: 16 bytes. `imm26` is the body-relative-to-call-site
/// displacement in 4-byte words, sign-extended.
fn emitAarch64(allocator: std.mem.Allocator, params: EmitParams) Error!EmitOutput {
    if (params.sig.params.len != 0) return Error.UnsupportedOp;
    if (!all_gpr_class(params.sig.results)) return Error.UnsupportedOp;

    const n_results = params.sig.results.len;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    if (n_results == 3) {
        // 3-int MEMORY-class shape: MOV X8, X1 + BL + MOV W0, WZR + RET.
        try writeInsn(allocator, &bytes, 0xAA0103E8);
        try emitBLAarch64(allocator, &bytes, params, 4);
        try writeInsn(allocator, &bytes, 0x2A1F03E0);
        try writeInsn(allocator, &bytes, 0xD65F03C0);
    } else if (n_results == 2) {
        // 2-int register-class shape: body returns result 0 in X0,
        // result 1 in X1 per AAPCS64. Save results ptr (X1) + LR to
        // stack across the BL, then write X0/X1 to caller's buffer.
        //
        // ```text
        //   STP X1, X30, [SP, #-16]!  ; A9BF7BE1
        //   BL  body                   ; 94?????
        //   LDP X9, X30, [SP], #16     ; A8C17BE9  — X9 = results, X30 = LR
        //   STR X0, [X9, #0]           ; F9000120
        //   STR X1, [X9, #8]           ; F9000521
        //   MOV W0, WZR                ; 2A1F03E0
        //   RET                        ; D65F03C0
        // ```
        // 7 insns × 4 = 28 bytes.
        try writeInsn(allocator, &bytes, 0xA9BF7BE1); // STP X1, X30, [SP, #-16]!
        try emitBLAarch64(allocator, &bytes, params, 4);
        try writeInsn(allocator, &bytes, 0xA8C17BE9); // LDP X9, X30, [SP], #16
        try writeInsn(allocator, &bytes, 0xF9000120); // STR X0, [X9, #0]
        try writeInsn(allocator, &bytes, 0xF9000521); // STR X1, [X9, #8]
        try writeInsn(allocator, &bytes, 0x2A1F03E0); // MOV W0, WZR
        try writeInsn(allocator, &bytes, 0xD65F03C0); // RET
    } else {
        return Error.UnsupportedOp;
    }

    return .{ .bytes = try bytes.toOwnedSlice(allocator) };
}

/// Emit a 4-byte BL instruction. `pre_offset` is the number of
/// bytes emitted BEFORE this BL in the wrapper (used to compute
/// the wrapper-relative offset where the BL itself lives).
fn emitBLAarch64(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    params: EmitParams,
    pre_offset: u32,
) Error!void {
    const bl_site: i64 = @as(i64, @intCast(params.thunk_offset)) +
        @as(i64, @intCast(pre_offset));
    const disp_bytes: i64 = @as(i64, @intCast(params.body_offset)) - bl_site;
    if (@mod(disp_bytes, 4) != 0) return Error.UnsupportedOp;
    const disp_words: i32 = @intCast(@divExact(disp_bytes, 4));
    const imm26: u32 = @bitCast(disp_words);
    try writeInsn(allocator, bytes, 0x94000000 | (imm26 & 0x03FFFFFF));
}

fn writeInsn(allocator: std.mem.Allocator, bytes: *std.ArrayList(u8), word: u32) Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, word, .little);
    try bytes.appendSlice(allocator, &b);
}

fn all_gpr_class(results: []const @import("../../../ir/zir.zig").ValType) bool {
    for (results) |r| switch (r) {
        .i32, .i64, .funcref, .externref => {},
        .f32, .f64, .v128 => return false,
    };
    return true;
}

/// Emit `CALL rel32`. `instr_pre_len` is the number of bytes
/// emitted BEFORE this CALL in the wrapper (used to compute
/// the wrapper-relative offset where the disp32 is measured
/// from — which is the byte after the CALL = thunk_offset +
/// instr_pre_len + 5).
fn emitCallRel32(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    params: EmitParams,
    instr_pre_len: u32,
) Error!void {
    const call_site_after: i64 = @as(i64, @intCast(params.thunk_offset)) +
        @as(i64, @intCast(instr_pre_len)) + 5;
    const disp: i32 = @intCast(@as(i64, @intCast(params.body_offset)) - call_site_after);
    try bytes.append(allocator, 0xE8);
    var disp_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &disp_bytes, disp, .little);
    try bytes.appendSlice(allocator, &disp_bytes);
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

test "wrapper_thunk: emit returns UnsupportedOp for 0-result sig" {
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &.{} },
        .body_offset = 0,
        .thunk_offset = 0,
    };
    const r = emit(testing.allocator, params);
    try testing.expectError(Error.UnsupportedOp, r);
}

test "wrapper_thunk: emit aarch64 2-int register-class (i32, i64) (28 bytes)" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const results = [_]@TypeOf(@as(@import("../../../ir/zir.zig").ValType, .i32)){ .i32, .i64 };
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &results },
        .body_offset = 256,
        .thunk_offset = 0,
    };
    const out = try emit(testing.allocator, params);
    defer testing.allocator.free(out.bytes);
    try testing.expectEqual(@as(usize, 28), out.bytes.len);
    // STP X1, X30, [SP, #-16]!
    try testing.expectEqual(@as(u32, 0xA9BF7BE1), std.mem.readInt(u32, out.bytes[0..4], .little));
    // BL body_offset(256) - bl_site(4) = 252 bytes = 63 words → imm26 = 63
    const bl = std.mem.readInt(u32, out.bytes[4..8], .little);
    try testing.expectEqual(@as(u32, 0x94000000 | 63), bl);
    // LDP X9, X30, [SP], #16
    try testing.expectEqual(@as(u32, 0xA8C17BE9), std.mem.readInt(u32, out.bytes[8..12], .little));
    // STR X0, [X9, #0]
    try testing.expectEqual(@as(u32, 0xF9000120), std.mem.readInt(u32, out.bytes[12..16], .little));
    // STR X1, [X9, #8]
    try testing.expectEqual(@as(u32, 0xF9000521), std.mem.readInt(u32, out.bytes[16..20], .little));
    // MOV W0, WZR
    try testing.expectEqual(@as(u32, 0x2A1F03E0), std.mem.readInt(u32, out.bytes[20..24], .little));
    // RET
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[24..28], .little));
}

test "wrapper_thunk: emit aarch64 3-int MEMORY-class (16 bytes)" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const i32_results = [_]@TypeOf(@as(@import("../../../ir/zir.zig").ValType, .i32)){ .i32, .i32, .i32 };
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &i32_results },
        .body_offset = 64,
        .thunk_offset = 0,
    };
    const out = try emit(testing.allocator, params);
    defer testing.allocator.free(out.bytes);
    try testing.expectEqual(@as(usize, 16), out.bytes.len);
    // MOV X8, X1
    try testing.expectEqual(@as(u32, 0xAA0103E8), std.mem.readInt(u32, out.bytes[0..4], .little));
    // BL body_offset(64) - bl_site(4) = +60 bytes = +15 words → imm26 = 15
    const bl = std.mem.readInt(u32, out.bytes[4..8], .little);
    try testing.expectEqual(@as(u32, 0x94000000 | 15), bl);
    // MOV W0, WZR
    try testing.expectEqual(@as(u32, 0x2A1F03E0), std.mem.readInt(u32, out.bytes[8..12], .little));
    // RET
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[12..16], .little));
}

test "wrapper_thunk: emit x86_64 SysV 2-int register-class (i32, i64) (20 bytes)" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    const results = [_]@TypeOf(@as(@import("../../../ir/zir.zig").ValType, .i32)){ .i32, .i64 };
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &results },
        .body_offset = 200,
        .thunk_offset = 100,
    };
    const out = try emit(testing.allocator, params);
    defer testing.allocator.free(out.bytes);
    try testing.expectEqual(@as(usize, 20), out.bytes.len);
    // PUSH RBX
    try testing.expectEqual(@as(u8, 0x53), out.bytes[0]);
    // MOV RBX, RSI
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xF3 }, out.bytes[1..4]);
    // CALL opcode + disp32 = 200 - (100 + 4 + 5) = 91
    try testing.expectEqual(@as(u8, 0xE8), out.bytes[4]);
    const disp = std.mem.readInt(i32, out.bytes[5..9], .little);
    try testing.expectEqual(@as(i32, 91), disp);
    // MOV [RBX], RAX ; MOV [RBX+8], RDX
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x03 }, out.bytes[9..12]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x53, 0x08 }, out.bytes[12..16]);
    // POP RBX ; XOR EAX, EAX ; RET
    try testing.expectEqualSlices(u8, &.{ 0x5B, 0x31, 0xC0, 0xC3 }, out.bytes[16..20]);
}

test "wrapper_thunk: emit x86_64 SysV 3-int-result MEMORY-class (11 bytes)" {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    const i32_results = [_]@TypeOf(@as(@import("../../../ir/zir.zig").ValType, .i32)){ .i32, .i32, .i32 };
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &i32_results },
        .body_offset = 100,
        .thunk_offset = 50,
    };
    const out = try emit(testing.allocator, params);
    defer testing.allocator.free(out.bytes);
    try testing.expectEqual(@as(usize, 11), out.bytes.len);
    // XCHG RDI, RSI
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x87, 0xFE }, out.bytes[0..3]);
    // CALL opcode
    try testing.expectEqual(@as(u8, 0xE8), out.bytes[3]);
    // disp32 = body_offset(100) - (thunk_offset(50) + 3 + 5) = 42
    const disp = std.mem.readInt(i32, out.bytes[4..8], .little);
    try testing.expectEqual(@as(i32, 42), disp);
    // XOR EAX, EAX + RET
    try testing.expectEqualSlices(u8, &.{ 0x31, 0xC0, 0xC3 }, out.bytes[8..11]);
}

// Reference jit_abi so the import survives `zig build test`
// even though Phase 2' is the consumer.
comptime {
    _ = jit_abi;
    _ = builtin;
}
