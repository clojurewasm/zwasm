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
//! Per-arch emit (Phase 2' a-e) is COMPLETE: x86_64 SysV +
//! arm64 AAPCS64 each cover the 2-int register-class shape
//! and 3-int MEMORY-class shape — the 3 sig shapes that hit
//! the `SKIP-WIN64-MULTI-RESULT` arm in
//! `spec_assert_runner_base.zig`. Each wrapper byte sequence
//! is unit-tested against expected bytes.
//!
//! ## Phase 2'g integration plan (linker hookup)
//!
//! Subsequent cycles wire this module into the production
//! compile path:
//!
//! 1. Extend `shared/linker.zig::link()` with an optional
//!    `wrapper_specs: ?[]const WrapperSpec` parameter (where
//!    `WrapperSpec = struct { func_idx: u32, sig: FuncType }`).
//!    When non-null + non-empty:
//!    - After laying out function bodies (current pass), call
//!      `wrapper_thunk.emit(allocator, .{ .sig, .body_offset =
//!      func_offsets[idx], .thunk_offset = block_size_so_far })`
//!      per spec.
//!    - Append wrapper bytes to `block.bytes`.
//!    - Populate `thunk_offsets[idx] = thunk_offset` for each
//!      spec'd function; `NO_THUNK` for the rest.
//!    - Skip the pass entirely when wrapper_specs == null (or
//!      `wrapper_thunk.emit` returns `Error.UnsupportedOp` for
//!      every spec — e.g. arch/shape unsupported).
//!
//! 2. Extend `shared/compile.zig::compileOne` to detect when
//!    the function's sig hits a supported wrapper shape
//!    (`results.len in {2, 3}` + all GPR-class) and append to
//!    the wrapper_specs slice.
//!
//! 3. Spec runner's 3 multi-result callsites in
//!    `test/spec/spec_assert_runner_non_simd.zig` (lines
//!    767/817/892) gated on `builtin.os.tag == .windows`:
//!    - Use `module.entry_buf(func_idx, BufferWriteFn)` to
//!      get the wrapper pointer.
//!    - Invoke via `entry_buffer_write.invokeMultiResultNoArgs`.
//!    - Unpack results from `TypedResult` array.
//!
//! 4. Remove the `SKIP-WIN64-MULTI-RESULT` arm in
//!    `spec_assert_runner_base.zig` (lines 3055-3082). After
//!    Phase 2'g lands, Win64 multi-result fixtures route
//!    through the wrapper thunk (currently the same as the
//!    existing per-shape `callI32i32i32NoArgs` etc but with
//!    the buffer-write boundary intercept).
//!
//! 5. Phase boundary windowsmini reconciliation runs
//!    `bash scripts/run_remote_windows.sh test-all` to
//!    verify the Win64 path. If wrapper byte sequence has a
//!    bug specific to Win64 (e.g. shadow space alignment),
//!    surface via test FAIL at that point.
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
        // and RDX (result 1). Save results-ptr (RSI) to STACK across
        // the CALL — RBX is in `allocatable_callee_saved_gprs` per
        // abi.zig, so the body's regalloc may use RBX as scratch.
        // The body's prologue saves RBX *only if* its regalloc
        // allocated RBX; for small functions that don't pressure
        // callee-saved regs, RBX is silently clobbered without a
        // save (surfaced by 2-int e2e test ubuntu fail at fault
        // 0x77 = result 0 value, indicating RBX = old RAX after
        // body's epilogue did MOV RAX, RBX without a paired POP).
        //
        // Stack-save shape (24 bytes):
        //   SUB RSP, 8         ; 48 83 EC 08  — keep SysV alignment
        //   MOV [RSP], RSI     ; 48 89 34 24  — save results ptr
        //   CALL body          ; E8 + disp32
        //   MOV RSI, [RSP]     ; 48 8B 34 24  — restore
        //   ADD RSP, 8         ; 48 83 C4 08
        //   MOV [RSI], RAX     ; 48 89 06     — result 0 → buf[0]
        //   MOV [RSI+8], RDX   ; 48 89 56 08  — result 1 → buf[8]
        //   XOR EAX, EAX       ; 31 C0
        //   RET                ; C3
        //
        // Alignment: wrapper-entry RSP ≡ 8 (mod 16). SUB RSP, 8
        // → RSP ≡ 0 (mod 16). CALL pushes 8 → body sees ≡ 8 (mod
        // 16) ✓ per SysV.
        try bytes.appendSlice(allocator, &.{ 0x48, 0x83, 0xEC, 0x08 }); // SUB RSP, 8
        try bytes.appendSlice(allocator, &.{ 0x48, 0x89, 0x34, 0x24 }); // MOV [RSP], RSI
        try emitCallRel32(allocator, &bytes, params, 4 + 4);
        try bytes.appendSlice(allocator, &.{ 0x48, 0x8B, 0x34, 0x24 }); // MOV RSI, [RSP]
        try bytes.appendSlice(allocator, &.{ 0x48, 0x83, 0xC4, 0x08 }); // ADD RSP, 8
        try bytes.appendSlice(allocator, &.{ 0x48, 0x89, 0x06 }); // MOV [RSI], RAX
        try bytes.appendSlice(allocator, &.{ 0x48, 0x89, 0x56, 0x08 }); // MOV [RSI+8], RDX
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
        // 3-int MEMORY-class shape (24 bytes):
        //   STP X30, XZR, [SP, #-16]!  ; A9BF7FFE — save LR (BL clobbers X30)
        //   MOV X8, X1                  ; AA0103E8
        //   BL  body                    ; 94??????
        //   LDP X30, XZR, [SP], #16    ; A8C17FFE — restore LR
        //   MOV W0, WZR                 ; 2A1F03E0
        //   RET                          ; D65F03C0
        //
        // X30 (LR) must be saved across BL — BL writes its
        // return address to X30, clobbering the wrapper's own
        // return address (the caller's site). Without the
        // save/restore the wrapper's RET jumps back to the
        // wrapper's BL+4 instead of the caller, infinite loop
        // (observed 2026-05-23 cycle 3e Phase 2'd integration
        // attempt at 99% CPU for 31 min).
        try writeInsn(allocator, &bytes, 0xA9BF7FFE);
        try writeInsn(allocator, &bytes, 0xAA0103E8);
        try emitBLAarch64(allocator, &bytes, params, 8);
        try writeInsn(allocator, &bytes, 0xA8C17FFE);
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

test "wrapper_thunk: end-to-end execution — () → (i32, i32, i32) via wrapper" {
    if (!(builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos) and
        !(builtin.cpu.arch == .x86_64 and builtin.os.tag != .windows))
    {
        return error.SkipZigTest;
    }
    // Build ZirFunc: () → (i32, i32, i32); body = 11; 22; 33; end.
    const zir = @import("../../../ir/zir.zig");
    const ZirFunc = zir.ZirFunc;
    const regalloc = @import("regalloc.zig");
    const native_emit = if (builtin.cpu.arch == .aarch64)
        @import("../arm64/emit.zig")
    else
        @import("../x86_64/emit.zig");
    const jit_mem = @import("../../../platform/jit_mem.zig");
    const entry_buf = @import("entry_buffer_write.zig");

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 22 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 33 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 3 },
        .{ .def_pc = 1, .last_use_pc = 3 },
        .{ .def_pc = 2, .last_use_pc = 3 },
    } };
    const slots = [_]u16{ 0, 1, 2 };
    // result_abi=.register_write (default): body uses MEMORY-class
    // for > 2 results per cycle 2c emit; wrapper bridges the
    // entry-helper-vs-MEMORY-class boundary.
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 3,
        .result_abi = .register_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const body_out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{});
    defer native_emit.deinit(testing.allocator, body_out);

    // Wrapper goes IMMEDIATELY AFTER the body in JIT memory.
    const body_offset: u32 = 0;
    const thunk_offset: u32 = @intCast(body_out.bytes.len);

    const wrapper_out = try emit(testing.allocator, .{
        .sig = sig,
        .body_offset = body_offset,
        .thunk_offset = thunk_offset,
    });
    defer testing.allocator.free(wrapper_out.bytes);

    // Allocate JIT memory + copy body + wrapper.
    const total_size = body_out.bytes.len + wrapper_out.bytes.len;
    var block = try jit_mem.alloc(total_size);
    defer jit_mem.free(block);
    try jit_mem.setWritable(block);
    @memcpy(block.bytes[body_offset..][0..body_out.bytes.len], body_out.bytes);
    @memcpy(block.bytes[thunk_offset..][0..wrapper_out.bytes.len], wrapper_out.bytes);
    try jit_mem.setExecutable(block);

    // Wrapper's address = block.bytes.ptr + thunk_offset.
    const fn_ptr: entry_buf.BufferWriteFn = @ptrCast(@alignCast(block.bytes.ptr + thunk_offset));
    var rt: entry_buf.JitRuntime = .{
        .vm_base = undefined,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    var args_buf: [1]u64 = .{0};
    var results_buf: [3]u64 = .{ 0, 0, 0 };
    try entry_buf.invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u32, 11), @as(u32, @intCast(results_buf[0] & 0xFFFFFFFF)));
    try testing.expectEqual(@as(u32, 22), @as(u32, @intCast(results_buf[1] & 0xFFFFFFFF)));
    try testing.expectEqual(@as(u32, 33), @as(u32, @intCast(results_buf[2] & 0xFFFFFFFF)));
}

test "wrapper_thunk: end-to-end execution — () → (i32, i64) via wrapper" {
    if (!(builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos) and
        !(builtin.cpu.arch == .x86_64 and builtin.os.tag != .windows))
    {
        return error.SkipZigTest;
    }
    const zir = @import("../../../ir/zir.zig");
    const ZirFunc = zir.ZirFunc;
    const regalloc = @import("regalloc.zig");
    const native_emit = if (builtin.cpu.arch == .aarch64)
        @import("../arm64/emit.zig")
    else
        @import("../x86_64/emit.zig");
    const jit_mem = @import("../../../platform/jit_mem.zig");
    const entry_buf = @import("entry_buffer_write.zig");

    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{ .i32, .i64 } };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(testing.allocator);
    try f.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 0x77 });
    try f.instrs.append(testing.allocator, .{ .op = .@"i64.const", .payload = 0xABCDEF12 });
    try f.instrs.append(testing.allocator, .{ .op = .end });
    f.liveness = .{ .ranges = &[_]zir.LiveRange{
        .{ .def_pc = 0, .last_use_pc = 2 },
        .{ .def_pc = 1, .last_use_pc = 2 },
    } };
    const slots = [_]u16{ 0, 1 };
    const alloc: regalloc.Allocation = .{
        .slots = &slots,
        .n_slots = 2,
        .result_abi = .register_write,
    };
    const sigs = [_]zir.FuncType{sig};
    const body_out = try native_emit.compile(testing.allocator, &f, alloc, &sigs, &.{}, 0, &.{}, &.{});
    defer native_emit.deinit(testing.allocator, body_out);

    const body_offset: u32 = 0;
    const thunk_offset: u32 = @intCast(body_out.bytes.len);

    const wrapper_out = try emit(testing.allocator, .{
        .sig = sig,
        .body_offset = body_offset,
        .thunk_offset = thunk_offset,
    });
    defer testing.allocator.free(wrapper_out.bytes);

    const total_size = body_out.bytes.len + wrapper_out.bytes.len;
    var block = try jit_mem.alloc(total_size);
    defer jit_mem.free(block);
    try jit_mem.setWritable(block);
    @memcpy(block.bytes[body_offset..][0..body_out.bytes.len], body_out.bytes);
    @memcpy(block.bytes[thunk_offset..][0..wrapper_out.bytes.len], wrapper_out.bytes);
    try jit_mem.setExecutable(block);

    const fn_ptr: entry_buf.BufferWriteFn = @ptrCast(@alignCast(block.bytes.ptr + thunk_offset));
    var rt: entry_buf.JitRuntime = .{
        .vm_base = undefined,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };
    var args_buf: [1]u64 = .{0};
    var results_buf: [2]u64 = .{ 0, 0 };
    try entry_buf.invokeBufferWrite(&rt, fn_ptr, &args_buf, &results_buf);
    try testing.expectEqual(@as(u32, 0x77), @as(u32, @intCast(results_buf[0] & 0xFFFFFFFF)));
    try testing.expectEqual(@as(u64, 0xABCDEF12), results_buf[1]);
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

test "wrapper_thunk: emit aarch64 3-int MEMORY-class (24 bytes)" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const i32_results = [_]@TypeOf(@as(@import("../../../ir/zir.zig").ValType, .i32)){ .i32, .i32, .i32 };
    const params: EmitParams = .{
        .sig = .{ .params = &.{}, .results = &i32_results },
        .body_offset = 64,
        .thunk_offset = 0,
    };
    const out = try emit(testing.allocator, params);
    defer testing.allocator.free(out.bytes);
    try testing.expectEqual(@as(usize, 24), out.bytes.len);
    // STP X30, XZR, [SP, #-16]!
    try testing.expectEqual(@as(u32, 0xA9BF7FFE), std.mem.readInt(u32, out.bytes[0..4], .little));
    // MOV X8, X1
    try testing.expectEqual(@as(u32, 0xAA0103E8), std.mem.readInt(u32, out.bytes[4..8], .little));
    // BL body_offset(64) - bl_site(8) = +56 bytes = +14 words → imm26 = 14
    const bl = std.mem.readInt(u32, out.bytes[8..12], .little);
    try testing.expectEqual(@as(u32, 0x94000000 | 14), bl);
    // LDP X30, XZR, [SP], #16
    try testing.expectEqual(@as(u32, 0xA8C17FFE), std.mem.readInt(u32, out.bytes[12..16], .little));
    // MOV W0, WZR
    try testing.expectEqual(@as(u32, 0x2A1F03E0), std.mem.readInt(u32, out.bytes[16..20], .little));
    // RET
    try testing.expectEqual(@as(u32, 0xD65F03C0), std.mem.readInt(u32, out.bytes[20..24], .little));
}

test "wrapper_thunk: emit x86_64 SysV 2-int register-class (i32, i64) (31 bytes)" {
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
    try testing.expectEqual(@as(usize, 31), out.bytes.len);
    // SUB RSP, 8
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x08 }, out.bytes[0..4]);
    // MOV [RSP], RSI
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x34, 0x24 }, out.bytes[4..8]);
    // CALL opcode + disp32 = 200 - (100 + 8 + 5) = 87
    try testing.expectEqual(@as(u8, 0xE8), out.bytes[8]);
    const disp = std.mem.readInt(i32, out.bytes[9..13], .little);
    try testing.expectEqual(@as(i32, 87), disp);
    // MOV RSI, [RSP] ; ADD RSP, 8
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x8B, 0x34, 0x24 }, out.bytes[13..17]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x08 }, out.bytes[17..21]);
    // MOV [RSI], RAX ; MOV [RSI+8], RDX
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x06 }, out.bytes[21..24]);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0x56, 0x08 }, out.bytes[24..28]);
    // XOR EAX, EAX ; RET
    try testing.expectEqualSlices(u8, &.{ 0x31, 0xC0, 0xC3 }, out.bytes[28..31]);
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
