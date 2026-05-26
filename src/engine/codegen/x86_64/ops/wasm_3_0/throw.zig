//! x86_64 emit handler for `throw` — Zone 2 per ADR-0074 +
//! ADR-0114 D2 + ADR-0119. Mirror of arm64 sibling.
//!
//! Wasm spec 3.0 §3.3.10.7. Per ADR-0114 D6 marshals
//! (tag_idx, payload) into argregs and CALLs the `zwasm_throw`
//! dispatcher.
//!
//! ## IT-6 cycle 3b shape (current)
//!
//! Emits MOVABS imm64 → R10 + CALL R10 + JMP-rel32 fallback
//! targeting the function trap stub. The trampoline (cycle 3a)
//! currently sets `trap_flag=1` then RETs; control resumes at
//! the JMP and lands at the trap stub for the standard epilogue.
//! Cycle 3c replaces the trampoline body with the full
//! dispatchThrow integration; the emit shape stays the same.
//!
//! Byte layout (17 bytes):
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

const meta = @import("../../../../../instruction/wasm_3_0/throw.zig");
const ctx_mod = @import("../../ctx.zig");
const inst = @import("../../inst.zig");
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
    _ = ins;
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
