//! x86_64 emit handler for `throw` — Zone 2 per ADR-0074 +
//! ADR-0114 D2 + ADR-0119. Mirror of arm64 sibling.
//!
//! Wasm spec 3.0 §3.3.10.7. Per ADR-0114 D6 marshals
//! (tag_idx, payload) into argregs and CALLs the `zwasm_throw`
//! dispatcher.
//!
//! ## Current shape (IT-6 cycle 3c + tag_idx marshal)
//!
//! Marshals `tag_idx` (= `ins.payload`, u32) into the platform's
//! first-arg register before MOVABS R10, addr + CALL R10:
//! - SysV (Linux / Mac): MOV EDI, imm32 — RDI is SysV first arg.
//!   Trampoline naked stub re-routes RDI → RDX (= trampolineCore
//!   tag_idx arg2).
//! - Win64: MOV ECX, imm32 — RCX is Win64 first arg. Trampoline
//!   stashes RCX → R10 then routes → R8 (= trampolineCore arg2).
//!
//! Byte layout (SysV — 22 bytes; Win64 — 22 bytes):
//!   MOV E{DI,CX}, imm32  ; 5 bytes
//!   MOVABS R10, imm64    ; 10 bytes (49 ba + 8-byte addr)
//!   CALL R10             ; 3 bytes (41 ff d2)
//!   JMP <trap_stub>      ; 5 bytes (e9 + disp32, patched)
//!
//! R10 is SysV/Win64 caller-saved scratch; the trampoline's body
//! also clobbers R10 (matching this site's expectations). R15
//! (the pinned runtime ptr per ADR-0017 Cc-pivot) is inherited
//! across the CALL.
//!
//! Registered in `dispatch_collector.collected_x86_64_ctx_ops`.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const builtin = @import("builtin");
const std = @import("std");
const meta = @import("../../../../../instruction/wasm_3_0/throw.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
const trampoline_mod = @import("../../../shared/throw_trampoline.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A + ADR-0114 D6 — terminator axis.
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    const tag_idx: u32 = @intCast(ins.payload);

    // 10.E-payload-prop Cycle 3 (ADR-0120) — write `eh_payload_len`
    // BEFORE the trampoline call. See arm64 sibling for the
    // full rationale; until Cycle 4 wires the pop+store of N
    // payload values, Cycle 3 unconditionally writes zero
    // (matching the pre-Cycle-3 observable behaviour of the
    // IT-6 N=0 tagged-catch tests).
    if (ctx.tag_param_counts.len > tag_idx) {
        std.debug.assert(ctx.tag_param_counts[tag_idx] <= 16);
    }
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovMemDisp32Imm32(abi.runtime_ptr_save_gpr, jit_abi.eh_payload_len_off, 0).slice());

    // Marshal tag_idx into the platform's first-arg register so
    // the trampoline's naked stub can re-route it to
    // `trampolineCore`'s arg2. SysV → RDI; Win64 → RCX.
    const first_arg_reg = if (builtin.target.os.tag == .windows)
        inst.Gpr.rcx
    else
        inst.Gpr.rdi;
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm32W(first_arg_reg, tag_idx).slice());

    const addr: u64 = @intFromPtr(&trampoline_mod.zwasmThrowTrampoline);
    try emitTrampolineCallAndTrap(ctx, addr);
    ctx.dead_code.* = true;
}

/// Shared emit for `throw` + `throw_ref` (same shape this cycle;
/// cycle 3c will diverge once exnref handling lands).
pub fn emitTrampolineCallAndTrap(ctx: *ctx_mod.EmitCtx, trampoline_addr: u64) ctx_mod.Error!void {
    // MOVABS R10, <trampoline_addr> — 10 bytes.
    try ctx.buf.appendSlice(ctx.allocator, inst.encMovImm64Q(.r10, trampoline_addr).slice());
    // CALL R10 — 3 bytes (REX.B + FF /2).
    try ctx.buf.appendSlice(ctx.allocator, inst.encCallReg(.r10).slice());
    // JMP rel32 placeholder — 5 bytes; patched at function-end
    // alongside unreachable's unreach_fixups. The trap stub runs
    // the standard epilogue + RET to the entry shim.
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try ctx.buf.appendSlice(ctx.allocator, inst.encJmpRel32(0).slice());
    try ctx.unreach_fixups.append(ctx.allocator, fixup_at);
}
