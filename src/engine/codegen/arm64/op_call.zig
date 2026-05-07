//! ARM64 emit pass — function call handlers.
//!
//! Per ADR-0021 sub-deliverable b (§9.7 / 7.5d sub-b emit.zig
//! 9-module split): direct `call N` and indirect `call_indirect
//! type_idx` ZirOps, with the AAPCS64 arg-marshalling and
//! return-capture helpers they share.
//!
//! Direct call (`call N`):
//!   - Marshal args into X1..X7 / V0..V7.
//!   - Restore X0 = runtime_ptr (ADR-0017 sub-2d-ii: X0 is
//!     caller-saved per AAPCS64; may have been clobbered by an
//!     earlier call).
//!   - Emit BL placeholder; append CallFixup for the post-emit
//!     linker to patch with the concrete imm26 disp.
//!   - Capture return value into the next vreg.
//!
//! Indirect call (`call_indirect type_idx`):
//!   - Pop the index; marshal args.
//!   - Bounds check (CMP W17, W25 = table_size; B.HS trap).
//!   - Sig check (LDR typeidx[idx]; CMP vs expected; B.NE trap).
//!   - Funcptr load (LDR X17, [X26, X17, LSL #3]); restore X0;
//!     BLR X17.
//!   - Capture return value.
//!
//! marshalCallArgs / captureCallResult: ≤ 7 GPR + ≤ 8 FP args in
//! registers (X1..X7 + V0..V7); overflow args spill to the
//! caller's pre-allocated outgoing-args region per AAPCS64 §6.4.2.
//! §9.7 / 7.9-d-11 introduced this region at the BOTTOM of the
//! caller's frame: locals + spills shift up by `local_base_off`
//! so `[SP, #(K*8)]` for K = 0..n_stack_args-1 is reserved for
//! outgoing args and the callee reads them at `[X29, #(16+8*K)]`.
//! No SP movement around BL/BLR is needed — the region stays
//! allocated for the function's lifetime. v128 / funcref /
//! externref param / result types surface as UnsupportedOp.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const abi = @import("abi.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const jit_abi = @import("../shared/jit_abi.zig");

const ZirInstr = zir.ZirInstr;
const FuncType = zir.FuncType;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;
const CallFixup = ctx_mod.CallFixup;

/// Wasm spec §3.4.7 (call N) — direct call. Looks up
/// `func_sigs[N]` for the callee signature, marshals args, emits
/// BL placeholder + CallFixup, captures the result.
///
/// Chunk 7.9-b foundation: if `N < num_imports` (the leading
/// wasm-space slots that name imports), the call routes to the
/// function-local trap stub instead of a body-relative BL —
/// **every import call traps unconditionally** until chunk 7.9-c
/// wires up the host-call dispatcher. Args are still marshalled
/// (harmless waste; the trap branch jumps over the rest of the
/// call sequence) and the result vreg is still allocated /
/// pushed so post-call ops that pop it find a slot, even though
/// they never execute (the unconditional B redirects control to
/// the trap stub which RETs out of the function).
pub fn emitCall(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ins.payload >= ctx.func_sigs.len) return Error.AllocationMissing;
    const callee_sig: FuncType = ctx.func_sigs[ins.payload];

    try marshalCallArgs(ctx, callee_sig);

    if (ins.payload < ctx.num_imports) {
        // Chunk 7.9-d: host-import dispatch. Indirect call via
        // `JitRuntime.host_dispatch_base[idx]`. Args are already in
        // X1..X7 (marshalCallArgs above); restore X0 = runtime_ptr
        // so the host stub sees the JitRuntime ptr as its hidden
        // first arg (the host fn signature is
        // `fn(rt: *JitRuntime, ...wasm_args) callconv(.c)`).
        //
        //   LDR X16, [X19, #host_dispatch_base_off]    ; ptr-of-ptrs
        //   LDR X16, [X16, #(idx*8)]                    ; actual fn ptr
        //   ORR X0, XZR, X19                            ; restore rt_ptr
        //   BLR X16
        //
        // imm12 budget for the per-idx LDR scales by 8, so idx must
        // satisfy `idx * 8 <= 32760` ⇒ `idx <= 4095`. Realistic
        // import counts stay well under this; surface as
        // UnsupportedOp otherwise.
        const idx_byte_off_u: u64 = @as(u64, ins.payload) * 8;
        if (idx_byte_off_u > 32760) return Error.UnsupportedOp;
        const idx_byte_off: u15 = @intCast(idx_byte_off_u);

        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, abi.runtime_ptr_save_gpr, jit_abi.host_dispatch_base_off));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrImm(16, 16, idx_byte_off));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(16));

        try captureCallResult(ctx, callee_sig);
        return;
    }

    // ADR-0017 sub-2d-ii: restore runtime_ptr in X0 (X0 is
    // caller-saved per AAPCS64, may have been clobbered by an
    // earlier call in this function).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));

    // BL placeholder; the post-emit linker patches via
    // EmitOutput.call_fixups once function-body offsets are known.
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBL(0));
    try ctx.call_fixups.append(ctx.allocator, CallFixup{
        .byte_offset = fixup_at,
        .target_func_idx = ins.payload,
    });

    try captureCallResult(ctx, callee_sig);
}

/// Indirect call: `call_indirect type_idx`. Pops the index,
/// marshals args, runs bounds + sig checks (both branch to the
/// shared trap stub via ctx.bounds_fixups), loads the funcptr,
/// restores X0, BLR.
pub fn emitCallIndirect(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    if (ins.payload >= ctx.module_types.len) return Error.AllocationMissing;
    const callee_sig: FuncType = ctx.module_types[ins.payload];

    // Stack at entry: [args..., idx]. Pop idx first.
    if (ctx.pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const idx_vreg = ctx.pushed_vregs.pop().?;

    try marshalCallArgs(ctx, callee_sig);

    // Bounds + sig check using the trap-stub at function tail
    // (shared with memory bounds — single trap reason today;
    // Diagnostic M3 / D-022 splits them later).
    const w_idx = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, idx_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(17, 31, w_idx));

    // Bounds: CMP W17, W25 ; B.HS trap.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegW(17, 25));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hs, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }

    // Sig: LDR W16, [X24, X17, LSL #2] ; CMP W16, #expected ; B.NE trap.
    // Skeleton restricts expected typeidx to imm12 range
    // (4096 distinct types is well above any realistic module's
    // needs); larger typeidx → UnsupportedOp.
    if (ins.payload >= 4096) return Error.UnsupportedOp;
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrWRegLsl2(16, 24, 17));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(16, @intCast(ins.payload)));
    {
        const fixup_at: u32 = @intCast(ctx.buf.items.len);
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.ne, 0));
        try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    }

    // Funcptr load + BLR. Restore X0 = runtime_ptr (ADR-0017
    // sub-2d-ii) before transferring control.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encLdrXRegLsl3(17, 26, 17));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(0, 31, abi.runtime_ptr_save_gpr));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(17));

    try captureCallResult(ctx, callee_sig);
}

/// Wasm spec §3.4.7 (call N) — marshal call arguments per AAPCS64
/// §6.4.2. Pop N arg vregs in REVERSE stack order (top = arg N-1)
/// then emit MOV/FMOV from each arg's home register into X1..X7
/// (per ADR-0017 X0 reserved for runtime_ptr) or V0..V7. Args that
/// overflow the int (X1..X7, 7 slots) or fp (V0..V7, 8 slots) pools
/// land in the caller's pre-allocated outgoing-args region at
/// `[SP, #(K*8)]` for K = NSAA index — see §9.7 / 7.9-d-11. The
/// callee reads them at `[X29, #(16 + 8*K)]`.
///
/// **No source-clobber risk by construction**: vregs are allocated
/// out of `[X9..X15, X19..X28]` (GPR pool) and `[V16..V30]` (FP
/// pool), neither of which overlaps the arg-passing registers. So
/// a naive sequential MOV per arg is correct without parallel-move
/// analysis. For overflow args, `gprLoadSpilled(stage 0)` /
/// `fpLoadSpilled(stage 0)` lands the value in a staging register
/// that the immediately-following STR consumes before the next
/// arg's stage-0 load reuses it.
fn marshalCallArgs(ctx: *EmitCtx, callee_sig: FuncType) Error!void {
    const n_args: u32 = @intCast(callee_sig.params.len);
    if (n_args == 0) return;
    if (ctx.pushed_vregs.items.len < n_args) return Error.AllocationMissing;

    // Pop in reverse stack order: top = arg N-1, deepest = arg 0.
    // Cap chosen as a generous comptime constant; realistic Wasm
    // signatures stay well under 64.
    const max_args: u32 = 64;
    var arg_vregs: [max_args]u32 = undefined;
    if (n_args > max_args) {
        std.debug.print("arm64/op_call: marshal n_args={d} > {d}\n", .{ n_args, max_args });
        return Error.UnsupportedOp;
    }
    var i: u32 = n_args;
    while (i > 0) {
        i -= 1;
        arg_vregs[i] = ctx.pushed_vregs.pop().?;
    }

    var gpr_arg_slot: inst.Xn = 1;
    var fp_arg_slot: inst.Vn = 0;
    // §9.7 / 7.9-d-11: NSAA index for caller-side stack-arg
    // lowering. Each overflow consumes one 8-byte slot at
    // `[SP, #(stack_arg_idx*8)]` in the outgoing-args region.
    var stack_arg_idx: u32 = 0;
    var k: u32 = 0;
    while (k < n_args) : (k += 1) {
        const src_vreg = arg_vregs[k];
        switch (callee_sig.params[k]) {
            .i32 => {
                const ws = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (gpr_arg_slot >= 8) {
                    const off_u: u32 = stack_arg_idx * 8;
                    if (off_u > 16380) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImmW(ws, 31, @intCast(off_u)));
                    stack_arg_idx += 1;
                } else {
                    if (ws != gpr_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(gpr_arg_slot, 31, ws));
                    }
                    gpr_arg_slot += 1;
                }
            },
            .i64 => {
                const xs = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (gpr_arg_slot >= 8) {
                    const off_u: u32 = stack_arg_idx * 8;
                    if (off_u > 32760) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImm(xs, 31, @intCast(off_u)));
                    stack_arg_idx += 1;
                } else {
                    if (xs != gpr_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(gpr_arg_slot, 31, xs));
                    }
                    gpr_arg_slot += 1;
                }
            },
            .f32 => {
                const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (fp_arg_slot >= 8) {
                    const off_u: u32 = stack_arg_idx * 8;
                    if (off_u > 16380) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrSImm(vs, 31, @intCast(off_u)));
                    stack_arg_idx += 1;
                } else {
                    if (vs != fp_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovSReg(fp_arg_slot, vs));
                    }
                    fp_arg_slot += 1;
                }
            },
            .f64 => {
                const vs = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);
                if (fp_arg_slot >= 8) {
                    const off_u: u32 = stack_arg_idx * 8;
                    if (off_u > 32760) return Error.UnsupportedOp;
                    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrDImm(vs, 31, @intCast(off_u)));
                    stack_arg_idx += 1;
                } else {
                    if (vs != fp_arg_slot) {
                        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDReg(fp_arg_slot, vs));
                    }
                    fp_arg_slot += 1;
                }
            },
            .v128, .funcref, .externref => |t| {
                std.debug.print("arm64/op_call: marshal {s} param unsupported\n", .{@tagName(t)});
                return Error.UnsupportedOp;
            },
        }
    }
}

/// Capture a call's return value into the next vreg, dispatching
/// on the callee's result type. Per AAPCS64: i32→W0, i64→X0,
/// f32→S0, f64→D0. Single-result MVP only — multi-value returns
/// (Wasm 2.0) land at sub-g3 follow-up. Void callees push
/// nothing.
fn captureCallResult(ctx: *EmitCtx, callee_sig: FuncType) Error!void {
    if (callee_sig.results.len == 0) return;
    if (callee_sig.results.len > 1) return Error.UnsupportedOp;

    const result = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result >= ctx.alloc.slots.len) return Error.AllocationMissing;
    const slot_id = ctx.alloc.slots[result];

    switch (callee_sig.results[0]) {
        .i32 => {
            const wd = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
            if (wd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(wd, 31, 0));
        },
        .i64 => {
            const xd = abi.slotToReg(slot_id) orelse return Error.SlotOverflow;
            if (xd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrReg(xd, 31, 0));
        },
        .f32 => {
            const vd = abi.fpSlotToReg(slot_id) orelse return Error.SlotOverflow;
            if (vd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovSReg(vd, 0));
        },
        .f64 => {
            const vd = abi.fpSlotToReg(slot_id) orelse return Error.SlotOverflow;
            if (vd != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encFmovDReg(vd, 0));
        },
        .v128, .funcref, .externref => return Error.UnsupportedOp,
    }
    try ctx.pushed_vregs.append(ctx.allocator, result);
}
