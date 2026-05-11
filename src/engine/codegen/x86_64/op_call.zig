//! x86_64 emit pass — call / call_indirect family (D-030 chunk-g).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape (`arm64/op_call.zig`). Behaviour
//! change zero — handler bodies are unchanged from their pre-split
//! shape; only their home file moves.
//!
//! Handlers in this module:
//!   - `emitCall`           — direct `call N` (marshal args, restore
//!     entry_arg0 = runtime_ptr from R15, CALL placeholder + linker
//!     fixup, capture return).
//!   - `emitCallIndirect`   — `call_indirect type_idx` (bounds check
//!     against table_size, sig check against typeidx[idx], load
//!     funcptr[idx], CALL through RAX).
//!   - `emitShadowAlloc` / `emitShadowFree` — Win64 32-byte shadow
//!     space wrapper (SysV no-op).
//!   - `marshalCallArgs`    — pop N arg vregs, MOV into the per-CC
//!     arg_gprs slots (RDI/RCX is reserved for runtime_ptr).
//!   - `captureCallResult`  — i32 return → next vreg via EAX.
//!
//! Module-private wrappers (emitShadowAlloc / Free + marshalCallArgs
//! / captureCallResult) are `pub fn` so the call_indirect / call
//! handlers above can share them; nothing in `compile()` calls
//! them directly.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const gpr = @import("gpr.zig");
const jit_abi = @import("../shared/jit_abi.zig");
const types = @import("types.zig");

/// §9.9 / 9.9-i-1 helper: per-call v128-scratch base for Win64.
/// Returns the [RSP + N] offset where the first 16-byte v128
/// scratch slot lives in the caller's outgoing-args region.
/// Must agree with `emit.zig:computeOutgoingMaxBytes` Win64
/// branch. Mirror of cranelift's prologue-time
/// `ABIArg::ImplicitPtrArg` offset finalisation
/// (cranelift `cranelift/codegen/src/isa/x64/abi.rs:383-395`).
fn win64V128ScratchBase(callee_sig: zir.FuncType) u32 {
    var n_int: u32 = 0;
    var n_fp: u32 = 0;
    var n_v128: u32 = 0;
    for (callee_sig.params) |p| switch (p) {
        .i32, .i64 => n_int += 1,
        .f32, .f64 => n_fp += 1,
        .v128 => n_v128 += 1,
        .funcref, .externref => {},
    };
    const n_total = n_int + n_v128 + n_fp;
    const n_overflow: u32 = if (n_total > 3) n_total - 3 else 0;
    const shadow_and_overflow = abi.current.shadow_space_bytes + n_overflow * 8;
    return (shadow_and_overflow + 15) & ~@as(u32, 15);
}

const Allocator = std.mem.Allocator;
const Error = types.Error;
const CallFixup = types.CallFixup;

/// Wasm spec §3.4.7 (call N) — direct call. Mirrors
/// `arm64/op_call.zig:emitCall`: marshals args into per-CC arg
/// regs, restores entry_arg0 (= runtime_ptr) from R15 (caller-
/// saved RDI/RCX may have been clobbered by a previous call),
/// emits CALL placeholder + records `CallFixup` for the post-emit
/// linker, captures return into the next vreg.
///
/// Chunk 7.9-d: if `callee_idx < num_imports`, dispatch via
/// `JitRuntime.host_dispatch_base[idx]` — the host-import path
/// is an indirect call through the dispatch table populated by
/// the runner before invoking the entry. Args are passed
/// per the platform C ABI; the JIT-side calling convention
/// reserves arg0 for the runtime_ptr (= JitRuntime ptr), so host
/// fn signatures take `(rt: *JitRuntime, ...wasm_args)
/// callconv(.c)`.
///
/// **Scope**: i32 args + i32 / void return only. f32/f64/i64
/// args + return surface as UnsupportedOp (lifted alongside
/// 7.7-fp / globals i64 chunks).
pub fn emitCall(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    call_fixups: *std.ArrayList(CallFixup),
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    func_sigs: []const zir.FuncType,
    num_imports: u32,
    callee_idx: u32,
) Error!void {
    if (callee_idx >= func_sigs.len) return Error.AllocationMissing;
    const callee_sig = func_sigs[callee_idx];

    try marshalCallArgs(allocator, buf, alloc, pushed_vregs, spill_base_off, callee_sig);

    if (callee_idx < num_imports) {
        // Chunk 7.9-d: host-import dispatch via JitRuntime.
        // host_dispatch_base[idx]. Args are already in the per-CC
        // arg regs (marshalCallArgs above). Restore entry_arg0 =
        // runtime_ptr so the host stub sees the JitRuntime ptr as
        // its hidden first arg (signature
        // `fn(rt: *JitRuntime, ...wasm_args) callconv(.c)`).
        //
        //   MOV RAX, [R15 + host_dispatch_base_off]   ; ptr-of-ptrs
        //   MOV RAX, [RAX + idx*8]                     ; actual fn ptr
        //   MOV <entry_arg0>, R15                      ; restore rt_ptr
        //   [Win64: SUB RSP, 32 — shadow space]
        //   CALL RAX
        //   [Win64: ADD RSP, 32]
        const idx_byte_off_u: u64 = @as(u64, callee_idx) * 8;
        if (idx_byte_off_u > 0x7FFF_FFFF) return Error.UnsupportedOp;
        const idx_byte_off: i32 = @intCast(idx_byte_off_u);

        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.host_dispatch_base_off).slice());
        try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, .rax, idx_byte_off).slice());
        try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());
        try emitShadowAlloc(allocator, buf, outgoing_max_bytes);
        try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());
        try emitShadowFree(allocator, buf, outgoing_max_bytes);

        try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, callee_sig);
        return;
    }

    // Restore <entry_arg0> = runtime_ptr from R15 before
    // transferring control. The callee's prologue captures arg0
    // into its own R15 (per ADR-0026). entry_arg0 is caller-
    // saved in both SysV (RDI) and Win64 (RCX) and may have been
    // clobbered by an earlier call.
    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());

    // Win64 ABI: caller reserves 32 bytes of shadow space below
    // the call site for the callee to optionally spill its 4
    // register args. §9.7 / 7.10-f folds shadow allocation into
    // the prologue's outgoing-args region (`outgoing_max_bytes`
    // already includes shadow when any call exists), so this
    // helper becomes a no-op when prologue pre-allocation took
    // ownership. Falls back to per-call SUB RSP, 32 only when
    // outgoing_max_bytes == 0 (= no calls; defensive — emitCall
    // would not be reached).
    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);

    // CALL placeholder; linker patches via call_fixups once
    // function-body offsets are known.
    const fixup_at: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encCallRel32(0).slice());
    try call_fixups.append(allocator, .{
        .byte_offset = fixup_at,
        .target_func_idx = callee_idx,
    });

    try emitShadowFree(allocator, buf, outgoing_max_bytes);

    try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, callee_sig);
}

/// Reserve Win64 shadow space below the upcoming CALL. No-op when
/// `outgoing_max_bytes > 0` (shadow already allocated by the
/// prologue per §9.7 / 7.10-f) or when SysV (`shadow_space_bytes
/// == 0`). Per ADR-0026 / Microsoft x64.
pub fn emitShadowAlloc(allocator: Allocator, buf: *std.ArrayList(u8), outgoing_max_bytes: u32) Error!void {
    if (abi.current.shadow_space_bytes == 0) return;
    if (outgoing_max_bytes > 0) return;
    try buf.appendSlice(allocator, inst.encSubRSpImm8(@intCast(abi.current.shadow_space_bytes)).slice());
}

/// Free Win64 shadow space after CALL returns. Mirror of
/// `emitShadowAlloc` (same gating).
pub fn emitShadowFree(allocator: Allocator, buf: *std.ArrayList(u8), outgoing_max_bytes: u32) Error!void {
    if (abi.current.shadow_space_bytes == 0) return;
    if (outgoing_max_bytes > 0) return;
    try buf.appendSlice(allocator, inst.encAddRSpImm8(@intCast(abi.current.shadow_space_bytes)).slice());
}

/// Wasm spec §3.4.7 (call_indirect type_idx) — pops the index,
/// marshals args, runs bounds + sig checks (both branch to the
/// shared trap stub via bounds_fixups), loads the funcptr from
/// `funcptr_base[idx]`, restores RDI = runtime_ptr, and CALLs
/// through RAX.
///
/// **Scratch register strategy**: RAX is used as scratch
/// throughout. RAX is NOT in the regalloc pool (`abi.zig`
/// excludes it as `return_gpr`), so it cannot collide with any
/// live vreg. This avoids needing a `spill_stage_gprs`
/// reservation (the arm64 X16/X17 mirror) for x86_64 — RAX is
/// dead from prologue through every instruction up to the CALL
/// itself, then comes alive holding the return value.
///
/// **JitRuntime invariant access** per ADR-0026: each of
/// `table_size`, `typeidx_base`, `funcptr_base` reloads from
/// `[R15 + offset]` at point of use rather than holding
/// callee-saved slots. The cost (3 extra MOVs vs ARM64's
/// 3 reserved-reg reads) is accepted per ADR-0026 §"Decision".
pub fn emitCallIndirect(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    bounds_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    outgoing_max_bytes: u32,
    module_types: []const zir.FuncType,
    type_idx: u32,
) Error!void {
    if (type_idx >= module_types.len) return Error.AllocationMissing;
    const callee_sig = module_types[type_idx];

    // Stack at entry: [args..., idx]. Pop idx first.
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_vreg = pushed_vregs.pop().?;
    const idx_r = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, idx_vreg, 0);

    try marshalCallArgs(allocator, buf, alloc, pushed_vregs, spill_base_off, callee_sig);

    // Bounds: MOV EAX, [R15 + table_size_off] ; CMP idx_r, EAX ; JAE trap.
    try buf.appendSlice(allocator, inst.encMovR32FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.table_size_off).slice());
    try buf.appendSlice(allocator, inst.encCmpRR(.d, idx_r, .rax).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
        try bounds_fixups.append(allocator, fixup_at);
    }

    // Sig: MOV RAX, [R15 + typeidx_base_off] (load u32* table)
    //      MOV EAX, [RAX + idx_r * 4]        (load expected typeidx)
    //      CMP EAX, type_idx (imm32) ; JNE trap.
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.typeidx_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovR32FromBaseIdxLsl2(.rax, .rax, idx_r).slice());
    try buf.appendSlice(allocator, inst.encCmpRImm32(.rax, type_idx).slice());
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());
        try bounds_fixups.append(allocator, fixup_at);
    }

    // Funcptr: MOV RAX, [R15 + funcptr_base_off] ; MOV RAX, [RAX + idx_r*8].
    try buf.appendSlice(allocator, inst.encMovR64FromMemDisp32(.rax, abi.runtime_ptr_save_gpr, jit_abi.funcptr_base_off).slice());
    try buf.appendSlice(allocator, inst.encMovR64FromBaseIdxLsl3(.rax, .rax, idx_r).slice());

    // Restore <entry_arg0> = runtime_ptr (callee's prologue reads
    // it as its inbound JitRuntime ptr per ADR-0026: RDI on SysV,
    // RCX on Win64).
    try buf.appendSlice(allocator, inst.encMovRR(.q, abi.current.entry_arg0_gpr, abi.runtime_ptr_save_gpr).slice());

    // Win64 shadow space (32 bytes; SysV no-op; both no-op when
    // §9.7 / 7.10-f prologue pre-allocation took ownership).
    try emitShadowAlloc(allocator, buf, outgoing_max_bytes);

    // CALL RAX (indirect).
    try buf.appendSlice(allocator, inst.encCallReg(.rax).slice());

    try emitShadowFree(allocator, buf, outgoing_max_bytes);

    try captureCallResult(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, callee_sig);
}

/// Marshal call arguments per SysV x86_64 §3.2.3 / Microsoft x64
/// §"Argument Passing": pop N arg vregs in REVERSE (top-of-stack =
/// rightmost arg), then emit MOV from each arg's home register
/// into the per-Cc arg slot. Args overflowing the register pool
/// land at `[RSP + outgoing_offset + 8 * K]` in the caller's
/// pre-allocated outgoing-args region (§9.7 / 7.10-f mirror of
/// arm64 d-11). The callee's prologue reads them at `[RBP + 16
/// + r15_save_off + 8 * K]`.
///
/// **Per-Cc overflow position**:
///   - SysV: outgoing_offset = 0; per-overflow slot K = NSAA index
///     (incremented per overflowed arg of EITHER class — both
///     classes share the NSAA stream in declaration order).
///   - Win64: outgoing_offset = 32 (shadow space); per-overflow
///     slot K = `shared_slot - 4` where shared_slot tracks the
///     int/fp shared counter and 4 is the per-Cc reg pool size.
///
/// **No source-clobber risk by construction**: the regalloc pool
/// (RBX, R12-R14 ± RDI/RSI on Win64) is disjoint from the per-Cc
/// arg regs, so naive sequential MOV per arg is correct without
/// parallel-move analysis. Spilled args stage through R10/R11
/// (GPR) or XMM14/15 (FP) via the spill-aware helpers — disjoint
/// from arg regs and from each other across stages.
///
/// **Scope**: ≤ 64 args (effectively unlimited). v128 / funcref /
/// externref still surface UnsupportedOp.
pub fn marshalCallArgs(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    spill_base_off: u32,
    callee_sig: zir.FuncType,
) Error!void {
    const n_args: u32 = @intCast(callee_sig.params.len);
    if (n_args == 0) return;
    if (pushed_vregs.items.len < n_args) return Error.AllocationMissing;

    var arg_vregs: [64]u32 = undefined;
    if (n_args > arg_vregs.len) return types.rejectUnsupported("src/engine/codegen/x86_64/op_call.zig:217", 0);
    var i: u32 = n_args;
    while (i > 0) {
        i -= 1;
        arg_vregs[i] = pushed_vregs.pop().?;
    }

    // arg_gprs slot 0 carries `*const JitRuntime` (RDI on SysV,
    // RCX on Win64) — skip; user int args start at slot 1.
    // FP args use a separate slot counter on SysV (§3.2.3 — int and
    // FP register pools are independent), but a SHARED counter on
    // Win64 (Microsoft x64 §"Argument Passing" — arg N occupies
    // either arg_gprs[N] or arg_xmms[N], advancing both indices).
    //   SysV: arg_gprs[1..6] = RSI, RDX, RCX, R8, R9 (5 user GPRs)
    //         arg_xmms[0..7] = XMM0..XMM7 (8 user FP slots)
    //   Win64: arg_gprs[1..4] = RDX, R8, R9 (3 user GPRs);
    //          arg_xmms[1..4] = XMM1..XMM3 (3 user FP slots,
    //          shared count with int).
    var gpr_arg_slot: usize = 1;
    var fp_arg_slot: usize = if (abi.current_cc == .win64) 1 else 0;
    // SysV NSAA index (per-overflow counter; increments only on
    // overflow). Win64 reuses gpr_arg_slot/fp_arg_slot's shared
    // value to derive its overflow slot.
    var nsaa_idx: u32 = 0;
    // §9.9 / 9.9-i-1 Win64 v128 hidden-pointer scratch index.
    // Counts v128 args processed so far; the per-arg scratch
    // lives at `[RSP + win64V128ScratchBase(sig) + v128_idx*16]`.
    var v128_idx: u32 = 0;
    const win64_v128_scratch_base: u32 = if (abi.current_cc == .win64)
        win64V128ScratchBase(callee_sig)
    else
        0;
    var k: u32 = 0;
    while (k < n_args) : (k += 1) {
        const src_vreg = arg_vregs[k];
        switch (callee_sig.params[k]) {
            .i32 => {
                if (gpr_arg_slot >= abi.current.arg_gprs.len) {
                    // Overflow: stage src into R10 (or R11 if R10
                    // already holds a prior overflowed arg in
                    // flight — but the marshal sequence emits each
                    // store before staging the next, so stage 0 is
                    // safe here). Then STR W to outgoing region.
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, gpr_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreR32MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_gprs[gpr_arg_slot];
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovRR(.d, dst, src).slice());
                    }
                }
                gpr_arg_slot += 1;
                if (abi.current_cc == .win64) fp_arg_slot += 1;
            },
            .i64 => {
                if (gpr_arg_slot >= abi.current.arg_gprs.len) {
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, gpr_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreR64MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_gprs[gpr_arg_slot];
                    const src = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovRR(.q, dst, src).slice());
                    }
                }
                gpr_arg_slot += 1;
                if (abi.current_cc == .win64) fp_arg_slot += 1;
            },
            .f32 => {
                if (fp_arg_slot >= abi.current.arg_xmms.len) {
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, fp_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreXmmF32MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_xmms[fp_arg_slot];
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                    }
                }
                fp_arg_slot += 1;
                if (abi.current_cc == .win64) gpr_arg_slot += 1;
            },
            .f64 => {
                if (fp_arg_slot >= abi.current.arg_xmms.len) {
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    const disp = computeOverflowDisp(nsaa_idx, fp_arg_slot);
                    try buf.appendSlice(allocator, inst.encStoreXmmF64MemRSPDisp32(src, disp).slice());
                    nsaa_idx += 1;
                } else {
                    const dst = abi.current.arg_xmms[fp_arg_slot];
                    const src = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_vreg, 0);
                    if (src != dst) {
                        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                    }
                }
                fp_arg_slot += 1;
                if (abi.current_cc == .win64) gpr_arg_slot += 1;
            },
            // §9.9 / 9.9-h-7 SysV + §9.9 / 9.9-i-1 Win64 caller-side
            // v128 marshal. SysV (§3.2.3 SIMD): XMM0..XMM7 direct,
            // overflow on stack as 2-eightbyte SSE class (16-byte
            // aligned). Win64 (Microsoft x64 §"Param passing"):
            // hidden-pointer — write v128 to 16-byte aligned scratch
            // in caller's outgoing-args region, pass scratch address
            // in the next int-arg-reg slot (RDX/R8/R9) or overflow
            // 8-byte stack slot. Spilled v128 vregs trip D-078 (c)
            // via `resolveXmm`'s explicit UnsupportedOp.
            .v128 => {
                if (abi.current_cc == .win64) {
                    // Write v128 source into the per-call scratch
                    // slot at `[RSP + scratch_base + v128_idx*16]`.
                    const src = try gpr.resolveXmm(alloc, src_vreg);
                    const scratch_disp: i32 = @intCast(win64_v128_scratch_base + v128_idx * 16);
                    try buf.appendSlice(allocator, inst.encStoreXmmV128MemRSPDisp32(src, scratch_disp).slice());
                    // Pass the scratch address in the int-arg-reg slot,
                    // or store the pointer onto the stack overflow.
                    if (gpr_arg_slot < abi.current.arg_gprs.len) {
                        const ptr_reg = abi.current.arg_gprs[gpr_arg_slot];
                        try buf.appendSlice(allocator, inst.encLeaR64BaseRspDisp32(ptr_reg, scratch_disp).slice());
                    } else {
                        // Stack overflow: caller writes the 8-byte
                        // pointer into the int-arg shared slot.
                        try buf.appendSlice(allocator, inst.encLeaR64BaseRspDisp32(.rax, scratch_disp).slice());
                        const disp = computeOverflowDisp(nsaa_idx, gpr_arg_slot);
                        try buf.appendSlice(allocator, inst.encStoreR64MemRSPDisp32(.rax, disp).slice());
                        nsaa_idx += 1;
                    }
                    gpr_arg_slot += 1;
                    fp_arg_slot += 1;
                    v128_idx += 1;
                } else {
                    // SysV path.
                    if (fp_arg_slot >= abi.current.arg_xmms.len) {
                        // §9.9 / 9.9-i-1 SysV v128 stack-overflow co-discharge:
                        // write the 16-byte v128 to `[RSP + nsaa_disp]`,
                        // 16-byte aligned (NSAA SSE class takes 2 eightbytes).
                        if ((nsaa_idx & 1) != 0) nsaa_idx += 1;
                        const src = try gpr.resolveXmm(alloc, src_vreg);
                        const disp: i32 = @intCast(nsaa_idx * 8);
                        try buf.appendSlice(allocator, inst.encStoreXmmV128MemRSPDisp32(src, disp).slice());
                        nsaa_idx += 2;
                        fp_arg_slot += 1;
                    } else {
                        const dst = abi.current.arg_xmms[fp_arg_slot];
                        const src = try gpr.resolveXmm(alloc, src_vreg);
                        if (src != dst) {
                            try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, src).slice());
                        }
                        fp_arg_slot += 1;
                    }
                }
            },
            .funcref, .externref => return types.rejectUnsupported("src/engine/codegen/x86_64/op_call.zig:funcref-externref", 0),
        }
    }
}

/// Compute the [RSP + disp] offset for an overflowed arg per
/// the active Cc. SysV uses the NSAA counter; Win64 uses the
/// shared int/fp slot index post-shadow-space (slot 4 = first
/// overflow at [RSP + 32]). See §9.7 / 7.10-f rationale on
/// `marshalCallArgs`.
fn computeOverflowDisp(nsaa_idx: u32, shared_slot: usize) i32 {
    return switch (abi.current_cc) {
        .sysv => @intCast(nsaa_idx * 8),
        .win64 => @intCast(shared_slot * 8),
    };
}

/// Capture a call's return value into the next vreg per SysV
/// §3.2.1: i32 → EAX. Single-result MVP only — multi-value
/// returns (Wasm 2.0) land at sub-g3 follow-up. Void callees
/// push nothing.
pub fn captureCallResult(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    callee_sig: zir.FuncType,
) Error!void {
    if (callee_sig.results.len == 0) return;
    if (callee_sig.results.len > 1) return types.rejectUnsupported("src/engine/codegen/x86_64/op_call.zig:261", 0);

    const result = next_vreg.*;
    next_vreg.* += 1;
    if (result >= alloc.slots.len) return Error.AllocationMissing;

    switch (callee_sig.results[0]) {
        .i32 => {
            const dst = try gpr.gprDefSpilled(alloc, result, 0);
            if (dst != abi.return_gpr) {
                try buf.appendSlice(allocator, inst.encMovRR(.d, dst, abi.return_gpr).slice());
            }
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
        },
        .i64 => {
            // §9.7 / 7.10-c: i64 result via .q-form MOV from RAX.
            const dst = try gpr.gprDefSpilled(alloc, result, 0);
            if (dst != abi.return_gpr) {
                try buf.appendSlice(allocator, inst.encMovRR(.q, dst, abi.return_gpr).slice());
            }
            try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
        },
        .f32, .f64 => {
            // §9.7 / 7.10-e: f32/f64 result via MOVAPS from XMM0
            // (= return_xmm). Same MOVAPS-preserves-128-bit shape
            // as marshalCallArgs's f32/f64 widening. Spilled result
            // vregs flush via xmmStoreSpilled.
            const dst = try gpr.xmmDefSpilled(alloc, result, 0);
            if (dst != abi.return_xmm) {
                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, abi.return_xmm).slice());
            }
            try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result, 0);
        },
        // §9.9 / 9.9-h-7 (D-080 discharge): v128 result via MOVAPS
        // from XMM0 (= return_xmm). Mirrors the ARM64
        // `captureCallResult.v128` path. Register-only — spilled
        // v128 result vregs trip D-078 (c) via `resolveXmm`.
        .v128 => {
            const dst = try gpr.resolveXmm(alloc, result);
            if (dst != abi.return_xmm) {
                try buf.appendSlice(allocator, inst.encMovapsXmmXmm(dst, abi.return_xmm).slice());
            }
        },
        .funcref, .externref => return types.rejectUnsupported("src/engine/codegen/x86_64/op_call.zig:capture-funcref-externref", 0),
    }
    try pushed_vregs.append(allocator, result);
}
