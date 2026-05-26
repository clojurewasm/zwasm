//! arm64 emit handler for `throw` — Zone 2 per ADR-0074 +
//! ADR-0114 D2 + ADR-0119.
//!
//! Wasm spec 3.0 §3.3.10.7. Per ADR-0114 D6 the full throw op
//! marshals (tag_idx, payload) into argregs and CALLs the
//! `zwasm_throw` dispatcher; on .uncaught it sets trap_flag=1
//! and returns, on .handler it JMPs to the landing pad.
//!
//! ## Current shape (IT-6 cycle 3c + tag_idx marshal)
//!
//! Marshals `tag_idx` (= `ins.payload`, u32 — Phase 10.Z widened
//! to u64 but tag indices fit in u32) into W0 before the BLR. The
//! trampoline's naked stub (`shared/throw_trampoline.zig`) reads
//! W0/X0 as the throw-site tag indicator and re-routes it to X2
//! (= trampolineCore's `tag_idx` arg) before calling
//! `dispatchThrow`. The dispatcher matches it against installed
//! `HandlerEntry.tag_idx` for tagged catches (`.catch_` /
//! `.catch_ref`); catch_all / catch_all_ref clauses ignore it.
//!
//! Byte layout (32 bytes — was 24 pre-marshal):
//!   MOVZ W0, #(tag_idx & 0xFFFF)             ; 4 bytes
//!   MOVK W0, #((tag_idx >> 16) & 0xFFFF), LSL #16  ; 4 bytes
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
//! reads `[X19, #trap_flag_off]` from it. W0 is caller-saved and
//! used as the AAPCS64 first int arg; the trampoline shuffles
//! it to its actual arg position (X2) before calling core.
//!
//! Zone 2 (`src/engine/codegen/arm64/ops/`).

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_3_0/throw.zig");
const ctx_mod = @import("../../ctx.zig");
const abi = @import("../../abi.zig");
const gpr = @import("../../gpr.zig");
const inst = @import("../../inst.zig");
const jit_abi = @import("../../../shared/jit_abi.zig");
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
    const tag_idx: u32 = @intCast(ins.payload);

    // 10.E-payload-prop Cycle 3 (ADR-0120) — write `eh_payload_len`
    // BEFORE the trampoline call. Cycle 3 ships N=0 always (the
    // pop+store of N payload values lands at Cycle 4); the
    // landing-pad reads `eh_payload_len` to know how many slots
    // to push, so writing the correct value here is the
    // load-bearing contract. For tag_idx valid against the
    // threaded `tag_param_counts`, the value would be
    // `tag_param_counts[tag_idx]`; until Cycle 4 wires the
    // pop+store, we conservatively emit STR Wzr (zero) so the
    // landing pad pushes nothing — matching the pre-Cycle-3
    // observable behaviour of the IT-6 N=0 tagged-catch tests.
    if (ctx.tag_param_counts.len > tag_idx) {
        // Debug-only check that threading is consistent with the
        // validator's range check at compile time.
        std.debug.assert(ctx.tag_param_counts[tag_idx] <= 16);
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encStrImmW(31, abi.runtime_ptr_save_gpr, jit_abi.eh_payload_len_off));

    // Marshal tag_idx into W0 — the trampoline's naked stub reads
    // X0 as the throw-site tag indicator and re-routes it to X2
    // (= trampolineCore's `tag_idx` arg). MOVZ + MOVK covers the
    // full u32 range; for typical small tag indices the high MOVK
    // could be elided but emitting both keeps the byte layout
    // uniform (8 bytes always) and avoids a per-call branch.
    const tag_lo: u16 = @intCast(tag_idx & 0xFFFF);
    const tag_hi: u16 = @intCast((tag_idx >> 16) & 0xFFFF);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(0, tag_lo));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(0, tag_hi, 1));

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
