//! arm64 emit handler for `throw` — Zone 2 per ADR-0074 +
//! ADR-0114 D2 + ADR-0119.
//!
//! Wasm spec 3.0 §3.3.10.7. Per ADR-0114 D6 the full throw op
//! marshals (tag_idx, payload) into argregs and CALLs the
//! `zwasm_throw` dispatcher; on .uncaught it sets trap_flag=1
//! and returns, on .handler it JMPs to the landing pad.
//!
//! ## IT-6 cycle 3b shape (current)
//!
//! Emits the address-load + BLR sequence targeting the per-arch
//! `shared/throw_trampoline.zig::zwasmThrowTrampoline` (per
//! ADR-0119; address is `@intFromPtr` of the naked-fn symbol,
//! known at Zig compile time). The trampoline (cycle 3a) currently
//! sets `trap_flag=1` and returns to the throw site; the post-CALL
//! B placeholder then routes to the function's trap stub (same
//! IT-3 path) which finishes the trap epilogue.
//!
//! Cycle 3c replaces the trampoline body with the full
//! dispatchThrow integration (handler vs uncaught branch); the
//! emit shape stays the same.
//!
//! Byte layout (24 bytes):
//!   MOVZ X16, #(addr & 0xFFFF)               ; 4 bytes
//!   MOVK X16, #((addr >> 16) & 0xFFFF), LSL #16  ; 4 bytes
//!   MOVK X16, #((addr >> 32) & 0xFFFF), LSL #32  ; 4 bytes
//!   MOVK X16, #((addr >> 48) & 0xFFFF), LSL #48  ; 4 bytes
//!   BLR X16                                    ; 4 bytes
//!   B  <trap_stub_fixup>                       ; 4 bytes (patched)
//!
//! X16 is the AAPCS64 intra-procedure scratch (IP0), free to
//! clobber across calls. Per ADR-0017 X19 (the pinned runtime
//! ptr) is inherited intact through the BLR — the trampoline
//! reads `[X19, #trap_flag_off]` from it.
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

const meta = @import("../../../../../instruction/wasm_3_0/throw.zig");
const ctx_mod = @import("../../ctx.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const trampoline_mod = @import("../../../shared/throw_trampoline.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A + ADR-0114 D6 — regalloc 3-axis classification.
// throw is a terminator (control transfers via the dispatcher
// to either a landing pad or the entry shim). Zero in-function
// CFG successor edges. Not a safepoint.
pub const is_terminator: bool = true;
pub const n_successor_edges: u8 = 0;
pub const is_safepoint: bool = false;

/// X16 = IP0 (intra-procedure scratch, AAPCS64 §6.4 caller-saved,
/// outside the regalloc-managed pool). Loaded with the trampoline
/// address then BLR'd.
const scratch: inst.Xn = 16;

pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    _ = ins;
    const addr: u64 = @intFromPtr(&trampoline_mod.zwasmThrowTrampoline);
    try emitTrampolineCallAndTrap(ctx, addr);
}

/// Shared emit for `throw` + `throw_ref` (`throw_ref` re-uses the
/// same address-load + BLR + trap-stub-fallback shape this cycle;
/// cycle 3c will diverge once exnref handling lands).
pub fn emitTrampolineCallAndTrap(ctx: *ctx_mod.EmitCtx, trampoline_addr: u64) ctx_mod.Error!void {
    // MOVZ X16, #(addr[0..16])
    const w0: u16 = @intCast(trampoline_addr & 0xFFFF);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(scratch, w0));
    // MOVK X16, #(addr[16..32]), LSL #16
    const w1: u16 = @intCast((trampoline_addr >> 16) & 0xFFFF);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, w1, 1));
    // MOVK X16, #(addr[32..48]), LSL #32
    const w2: u16 = @intCast((trampoline_addr >> 32) & 0xFFFF);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, w2, 2));
    // MOVK X16, #(addr[48..64]), LSL #48
    const w3: u16 = @intCast((trampoline_addr >> 48) & 0xFFFF);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(scratch, w3, 3));
    // BLR X16 — call the trampoline. Returns here with trap_flag=1.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBLR(scratch));
    // B <trap_stub> — patched at function-end alongside other
    // bounds_fixups. The trap stub runs the standard epilogue +
    // RET to the entry shim, completing the uncaught-throw path.
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encB(0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
}
