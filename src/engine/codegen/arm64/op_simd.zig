//! ARM64 emit pass — SIMD-128 op handlers (§9.9 / 9.5-b-iii
//! per ADR-0041), orchestrator + V128 mem / bitwise / select /
//! const family.
//!
//! As of §9.9 / 9.9-h-18 (Track B / ADR-0054 4-way split per
//! `.dev/phase10_prep/track_b_source_split.md` §4.3), this file
//! retains only:
//!
//!   - Shared scratch reservation (`simd_scratch_v` = V31).
//!   - Cross-class helpers (`emitV128Binop`, `emitV128Unop`,
//!     `emitV128BinopSwapped`, `emitV128Ne`) consumed by the
//!     int_arith / int_cmp_lane / float sibling files.
//!   - All `emitV128*` mem family (load / store + zero + splat +
//!     extend + per-lane load/store) plus bitwise (And/Or/Xor/
//!     Andnot/Not/Bitselect), V128AnyTrue, V128Select, V128Const.
//!
//! Integer arith / int cmp+lane / float-side handlers moved to
//! `op_simd_int_arith.zig` / `op_simd_int_cmp_lane.zig` /
//! `op_simd_float.zig`.
//!
//! Spill-aware integration: handlers use `gpr.resolveFp` for
//! non-spilling vregs (V16-V28); spilled v128 vregs flow via the
//! `q*Spilled` trio (16-byte stride). Per ADR-0041 §"Decision"
//! / 2 (FP-class register pool reuse with shape-tag axis):
//! handlers query `ctx.alloc.shapeTag(vreg)` only when the
//! spill path lands in 9.5-c — non-spilled cases are identical
//! to scalar f32/f64.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const inst = @import("inst.zig");
const inst_neon = @import("inst_neon.zig");
const ctx_mod = @import("ctx.zig");
const gpr = @import("gpr.zig");
const trace = @import("../../../diagnostic/trace.zig");

const ZirInstr = zir.ZirInstr;
const EmitCtx = ctx_mod.EmitCtx;
const Error = ctx_mod.Error;

/// V31 / reserved scratch per ADR-0041 + regalloc.zig (V31
/// reserved for popcnt's V-register pipeline; reused as a SIMD
/// scratch since no live SIMD vreg can land there).
///
/// Promoted to `pub` in 9.9-h-18 because `op_simd_float.zig` and
/// `op_simd_int_cmp_lane.zig` consume it (pmin/pmax + ne
/// synthesis + replace_lane aliasing-stash). Per ADR-0054 §
/// "Helper visibility — tiered pub": cross-class primitives are
/// `pub` from day 1.
pub const simd_scratch_v: u5 = 31;

/// Wasm spec §4.4.6 (vector mem) common bounds-check prologue —
/// the v128 mirror of `op_memory.emitMemOp`'s prologue (D-060
/// discharge). Caller has already popped the addr_vreg from the
/// operand stack. Emits:
///
///   ORR W16, WZR, W_addr        ; zero-extend wasm addr to ip0
///   [ADD imm12 or MOVZ/MOVK chain to fold memarg offset into ip0]
///   ADD X17, X16, #access_size  ; ea + size into ip1
///   CMP X17, X27                ; vs mem_limit
///   B.HI <fixup>                ; trap_stub patched at func end
///   trace.writeBounds(...)      ; ADR-0028 M3-a-1 ringbuffer
///
/// After return, X16 holds the effective Wasm address; the caller
/// emits `LDR/STR Q<vt>, [X28, X16]` (X28 = vm_base) to complete
/// the access. Mirrors `op_memory.emitMemOp`'s prologue exactly so
/// any future bounds-check refinement (e.g. ADR-0028 M3-a-2 trap
/// localisation) flows uniformly across scalar + v128 paths.
fn v128MemPrologue(ctx: *EmitCtx, addr_vreg: u32, offset_imm: u32, access_size: u12) Error!void {
    const ip0: inst.Xn = 16;
    const ip1: inst.Xn = 17;
    // SPILL-EXEMPT: address staging mirrors op_memory.emitMemOp stage 0.
    const w_addr = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, addr_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encOrrRegW(ip0, 31, w_addr));
    if (offset_imm != 0) {
        if (offset_imm <= 0xFFFFFF) {
            const off_high: u12 = @intCast((offset_imm >> 12) & 0xFFF);
            const off_low: u12 = @intCast(offset_imm & 0xFFF);
            if (off_high != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12Lsl12(ip0, ip0, off_high));
            if (off_low != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip0, ip0, off_low));
        } else {
            const lane0: u16 = @truncate(offset_imm & 0xFFFF);
            const lane1: u16 = @truncate((offset_imm >> 16) & 0xFFFF);
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(ip1, lane0));
            if (lane1 != 0) try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovkImm16(ip1, lane1, 1));
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddReg(ip0, ip0, ip1));
        }
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAddImm12(ip1, ip0, access_size));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpRegX(ip1, 27));
    const fixup_at: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encBCond(.hi, 0));
    try ctx.bounds_fixups.append(ctx.allocator, fixup_at);
    trace.writeBounds(ctx.func.func_idx, fixup_at);
}

/// `v128.load`: pop i32 address (Wn), push v128 result (Vd.16B).
/// Wasm spec §4.4.6.1 — vector load: bounds-check `ea + 16 >
/// mem_limit` traps; alignment is a hint per §2.4.10. Per
/// `single_slot_dual_meaning.md` the wasm address is purely the
/// runtime stack-popped value; the static memarg offset folds in
/// via the prologue. After the prologue X16 holds the effective
/// Wasm address; `LDR Q<vd>, [X28, X16]` reads the 16 bytes from
/// `vm_base + ea`.
///
/// §9.9 / 9.9-d-2 (D-060) replaces the §9.5-b MVP that emitted
/// `LDR Q,[X<wn>,#imm]` directly — that path SEGV'd on `simd_align`
/// modules 90/91 because the wasm-relative addr was treated as a
/// host pointer. The MVP form was correct only when vm_base
/// happened to be 0, which never holds in practice.
pub fn emitV128Load(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const addr_vreg = ctx.pushed_vregs.pop().?;

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try v128MemPrologue(ctx, addr_vreg, ins.payload, 16);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrQReg(result_v, 28, 16));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `v128.store`: pop v128 value (Vt.16B), pop i32 address (Wn).
/// Wasm spec §4.4.6.2 — bounds-check identical to `v128.load`.
/// `STR Q<vt>, [X28, X16]` writes 16 bytes to `vm_base + ea`.
pub fn emitV128Store(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const value_vreg = ctx.pushed_vregs.pop().?;
    const addr_vreg = ctx.pushed_vregs.pop().?;

    try v128MemPrologue(ctx, addr_vreg, ins.payload, 16);
    // qLoadSpilled at stage 1 keeps the V29 stage[0] free for any
    // future use; address marshalling already consumed gpr stage 0.
    const value_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, value_vreg, 1);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encStrQReg(value_v, 28, 16));
}

// ============================================================
// §9.9 / 9.9-d-3 — v128 mem op family (12 ops sharing
// `v128MemPrologue`).
//
// Wasm spec §4.4.6.1 (vector load).
//
// All handlers follow one of three tail shapes after the prologue
// puts the effective wasm address in X16:
//
//   load_zero (32 / 64):   `LDR S/D Vd, [X28, X16]`
//                          (scalar load zero-extends upper lanes).
//   load_extend (8x8 /     `LDR D Vd, [X28, X16]` then SXTL/UXTL
//      16x4 / 32x2 ×s/u):  `.<arrangement> Vd, Vd.<half>`.
//   load_splat (8/16/32/   `ADD X16, X28, X16` (LD1R has no
//      64):                reg-offset addressing) then
//                          `LD1R {Vd.<arrangement>}, [X16]`.
//
// The bounds-check prologue is uniform (X28=vm_base / X27=mem_limit
// invariants set up in emit.zig prologue per ADR-0017).
// ============================================================

/// Shared scaffolding: prologue + final NEON encoding + result
/// spill flush. The caller supplies the access size and a closure
/// that emits the final encoding given the destination V register.
fn emitV128LoadFamily(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    access_size: u12,
    comptime emit_tail: fn (allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void,
) Error!void {
    const addr_vreg = ctx.pushed_vregs.pop().?;
    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try v128MemPrologue(ctx, addr_vreg, ins.payload, access_size);
    try emit_tail(ctx.allocator, ctx.buf, result_v);
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ----- load_zero: LDR S/D zero-extends upper lanes. -----

pub fn emitV128Load32Zero(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrSReg(result_v, 28, 16));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 4, tail);
}

pub fn emitV128Load64Zero(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrDReg(result_v, 28, 16));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

// ----- load_splat: ADD X16, X28, X16 then LD1R from X16. -----

pub fn emitV128Load8Splat(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encAddReg(16, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encLd1r16B(result_v, 16));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 1, tail);
}

pub fn emitV128Load16Splat(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encAddReg(16, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encLd1r8H(result_v, 16));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 2, tail);
}

pub fn emitV128Load32Splat(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encAddReg(16, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encLd1r4S(result_v, 16));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 4, tail);
}

pub fn emitV128Load64Splat(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encAddReg(16, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encLd1r2D(result_v, 16));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

// ----- load_extend: LDR D + SXTL/UXTL .<arrangement>. -----

pub fn emitV128Load8x8S(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrDReg(result_v, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encSxtl8H(result_v, result_v));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

pub fn emitV128Load8x8U(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrDReg(result_v, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encUxtl8H(result_v, result_v));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

pub fn emitV128Load16x4S(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrDReg(result_v, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encSxtl4S(result_v, result_v));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

pub fn emitV128Load16x4U(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrDReg(result_v, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encUxtl4S(result_v, result_v));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

pub fn emitV128Load32x2S(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrDReg(result_v, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encSxtl2D(result_v, result_v));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

pub fn emitV128Load32x2U(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const tail = struct {
        fn run(allocator: std.mem.Allocator, buf: anytype, result_v: u5) Error!void {
            try gpr.writeU32(allocator, buf, inst.encLdrDReg(result_v, 28, 16));
            try gpr.writeU32(allocator, buf, inst_neon.encUxtl2D(result_v, result_v));
        }
    }.run;
    try emitV128LoadFamily(ctx, ins, 8, tail);
}

// ============================================================
// §9.9 / 9.9-d-5 — v128.{load,store}{8,16,32,64}_lane (8 ops).
//
// Wasm spec §4.4.7.4 (v128.loadN_lane) / §4.4.7.5 (v128.storeN_lane):
// loadN_lane reads N bytes from memory, replaces one lane of an
// existing v128 (other lanes preserved); storeN_lane extracts one
// lane of a v128 and writes N bytes to memory. Bounds check is
// identical to scalar loadN / storeN (offset + N must not exceed
// mem_limit).
//
// Encoding strategy (NEON-canonical, mirrors v1 + Cranelift):
//   load_lane:  bounds-check prologue → scalar LDR{B,H,W,X} W17 →
//               INS V<vec>.<sz>[lane], W17 / X17.
//   store_lane: bounds-check prologue → UMOV W17 / X17,
//               V<vec>.<sz>[lane] → scalar STR{B,H,W,X} W17.
//
// Per-arch divergence vs x86_64 (which PEXTRs *before* the prologue
// to avoid RCX clobber): ARM64's prologue uses X16 for the
// effective address and X17 only as a transient (`ADD X17, X16,
// #access_size` for the limit compare). After the B.HI fixup
// queues, X17 is free again — so prologue → UMOV/LDR → STR/INS
// runs cleanly without any extra register reservation. The
// lane-immediate is masked defensively to its range (the validator
// per Wasm §3.3.6.4 already rejects out-of-range lanes).
// ============================================================

fn loadLaneInsEnc(comptime access_size: u12) fn (vd: u5, wn: u5, lane: u32) u32 {
    return struct {
        fn enc(vd: u5, wn: u5, lane: u32) u32 {
            return switch (access_size) {
                1 => inst_neon.encInsBFromW(vd, wn, @intCast(lane & 0xF)),
                2 => inst_neon.encInsHFromW(vd, wn, @intCast(lane & 0x7)),
                4 => inst_neon.encInsSFromW(vd, wn, @intCast(lane & 0x3)),
                8 => inst_neon.encInsDFromX(vd, wn, @intCast(lane & 0x1)),
                else => unreachable,
            };
        }
    }.enc;
}

fn storeLaneUmovEnc(comptime access_size: u12) fn (wd: u5, vn: u5, lane: u32) u32 {
    return struct {
        fn enc(wd: u5, vn: u5, lane: u32) u32 {
            return switch (access_size) {
                1 => inst_neon.encUmovWFromB(wd, vn, @intCast(lane & 0xF)),
                2 => inst_neon.encUmovWFromH(wd, vn, @intCast(lane & 0x7)),
                4 => inst_neon.encUmovWFromS(wd, vn, @intCast(lane & 0x3)),
                8 => inst_neon.encUmovXFromD(wd, vn, @intCast(lane & 0x1)),
                else => unreachable,
            };
        }
    }.enc;
}

fn loadScalarEnc(comptime access_size: u12) fn (rt: u5, rn: u5, rm: u5) u32 {
    return switch (access_size) {
        1 => inst.encLdrbWReg,
        2 => inst.encLdrhWReg,
        4 => inst.encLdrWReg,
        8 => inst.encLdrXReg,
        else => unreachable,
    };
}

fn storeScalarEnc(comptime access_size: u12) fn (rt: u5, rn: u5, rm: u5) u32 {
    return switch (access_size) {
        1 => inst.encStrbWReg,
        2 => inst.encStrhWReg,
        4 => inst.encStrWReg,
        8 => inst.encStrXReg,
        else => unreachable,
    };
}

/// `v128.loadN_lane`: pop v128 (Vt) + i32 addr (Wn), push v128
/// result with `lane` replaced by N bytes from `vm_base + ea`.
/// Wasm spec §4.4.7.4. The handler reuses `v128MemPrologue` so
/// any future bounds-check refinement (e.g. ADR-0028 M3-a-2 trap
/// localisation) flows uniformly.
fn emitV128LoadLane(ctx: *EmitCtx, ins: *const ZirInstr, comptime access_size: u12) Error!void {
    const vec_vreg = ctx.pushed_vregs.pop().?;
    const addr_vreg = ctx.pushed_vregs.pop().?;

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try v128MemPrologue(ctx, addr_vreg, ins.payload, access_size);

    // Source vec at stage 1 (X16 already used by prologue's GPR
    // staging, but Q stages are independent of X stages).
    const vec_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vec_vreg, 1);
    if (result_v != vec_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, vec_v));
    }
    // Scalar load into W17 (X17 is a transient, free after the
    // bounds prologue's `ADD X17, X16, #size` consumed it).
    try gpr.writeU32(ctx.allocator, ctx.buf, loadScalarEnc(access_size)(17, 28, 16));
    try gpr.writeU32(ctx.allocator, ctx.buf, loadLaneInsEnc(access_size)(result_v, 17, ins.extra));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `v128.storeN_lane`: pop v128 (Vt) + i32 addr (Wn), write N
/// bytes from `Vt.<sz>[lane]` to `vm_base + ea`. Wasm spec
/// §4.4.7.5. Order: prologue → UMOV W17 ← V<vt>.<sz>[lane] →
/// scalar STR W17, [X28, X16]. X17 is free post-prologue.
fn emitV128StoreLane(ctx: *EmitCtx, ins: *const ZirInstr, comptime access_size: u12) Error!void {
    const vec_vreg = ctx.pushed_vregs.pop().?;
    const addr_vreg = ctx.pushed_vregs.pop().?;

    try v128MemPrologue(ctx, addr_vreg, ins.payload, access_size);

    const vec_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, vec_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, storeLaneUmovEnc(access_size)(17, vec_v, ins.extra));
    try gpr.writeU32(ctx.allocator, ctx.buf, storeScalarEnc(access_size)(17, 28, 16));
}

pub fn emitV128Load8Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128LoadLane(ctx, ins, 1);
}
pub fn emitV128Load16Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128LoadLane(ctx, ins, 2);
}
pub fn emitV128Load32Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128LoadLane(ctx, ins, 4);
}
pub fn emitV128Load64Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128LoadLane(ctx, ins, 8);
}
pub fn emitV128Store8Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128StoreLane(ctx, ins, 1);
}
pub fn emitV128Store16Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128StoreLane(ctx, ins, 2);
}
pub fn emitV128Store32Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128StoreLane(ctx, ins, 4);
}
pub fn emitV128Store64Lane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    try emitV128StoreLane(ctx, ins, 8);
}

// ============================================================
// §9.9 / 9.9-d-5 — v128 select / select_typed.
//
// Wasm spec §4.4.4.1 (select / select_typed): pop c (i32),
// val2 (T), val1 (T); push val1 if c != 0, else val2. T = v128
// path needs a SIMD-aware mask synthesis since ARM has no
// SIMD CSEL.
//
// Recipe (CSETM + DUP V.2D + BSL):
//   CMP cond_w, #0
//   CSETM X17, NE              ; X17 = -1 if cond≠0, else 0
//   DUP   V<mask>.2D, X17      ; V<mask> = all-1s or all-0s
//   BSL   V<mask>.16B, V<v1>.16B, V<v2>.16B
//                              ; V<mask> = (V<mask> & V<v1>)
//                              ;        | (~V<mask> & V<v2>)
//
// BSL writes Vd in place; we reuse the result V slot for the
// mask so no extra V scratch is needed. The 3-source spill
// staging (mask=dst at stage 0, val1 at stage 1, val2 at
// stage 2) needs stage_idx=2 — but qLoadSpilled exposes only
// stages 0/1 today; for the non-spilled MVP path the SPILL-
// EXEMPT marker keeps direct gpr.resolveFp semantics.
// ============================================================

/// `select` / `select_typed` with v128 operand type (Wasm spec
/// §4.4.4.1). Caller has already popped cond_v / val2_v / val1_v
/// and verified val1_v's shape_tag is .v128.
pub fn emitV128Select(ctx: *EmitCtx, cond_v: u32, val1_v: u32, val2_v: u32, result_vreg: u32) Error!void {
    // SPILL-EXEMPT: cond is i32 (GPR); single-stage load.
    const cond_w = try gpr.gprLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, cond_v, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(cond_w, 0));
    // Mask materialisation into X17 (transient). After CSETM the
    // GPR cond_w is dead.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetmX(17, .ne));

    const mask_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encDupGen2D(mask_v, 17));
    // SPILL-EXEMPT: v128 select needs 3 V regs simultaneously
    // (mask=dst, val1, val2). qLoadSpilled exposes only stages
    // 0/1; val2 at stage 2 lifts alongside D-037 spill-stage
    // extension. For non-spilled SIMD vregs (which fit in
    // V16-V28) gpr.resolveFp returns the physical V reg directly.
    const val1_v_phys = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, val1_v, 1);
    const val2_v_phys = try gpr.resolveFp(ctx.alloc, val2_v);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encBsl16B(mask_v, val1_v_phys, val2_v_phys));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
}

/// Shared v128 binop emit helper (§9.5-c-iv): pop 2 v128, emit
/// `encoder(rd, rn, rm)`, push 1 v128. Spill-aware via the q*
/// trio at stage_idx 0/1 (same convention as gpr/fp binops —
/// lhs at 0, rhs at 1; result reuses 0 since lhs is consumed).
///
/// Promoted to `pub` in 9.9-h-18 because the sibling files
/// (`op_simd_int_arith.zig` / `op_simd_int_cmp_lane.zig` /
/// `op_simd_float.zig`) drive their per-op handlers through it.
/// Per ADR-0054 §"Helper visibility — tiered pub".
pub fn emitV128Binop(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5, rm: u5) u32,
) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, lhs_v, rhs_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit a v128 unary op via the given encoder (rd, rn) → u32.
/// Pop 1 v128 vreg, push 1 v128 result. Mirrors `emitV128Binop` but
/// with one source operand.
///
/// Promoted to `pub` in 9.9-h-18 (used by abs/neg/popcnt in
/// op_simd_int_arith.zig + extend in op_simd_int_cmp_lane.zig +
/// FP unaries in op_simd_float.zig). Per ADR-0054 §"Helper
/// visibility — tiered pub".
pub fn emitV128Unop(ctx: *EmitCtx, encoder: *const fn (rd: u5, rn: u5) u32) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit a binop with operands swapped (calls encoder(rd, rhs, lhs)
/// instead of the default encoder(rd, lhs, rhs)). Used for lt/le → gt/ge
/// rewrites in `op_simd_int_cmp_lane.zig` + `op_simd_float.zig`.
///
/// Promoted to `pub` in 9.9-h-18 per ADR-0054 §"Helper
/// visibility — tiered pub".
pub fn emitV128BinopSwapped(ctx: *EmitCtx, encoder: *const fn (rd: u5, rn: u5, rm: u5) u32) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Operand swap — for lt(a,b) we emit gt(b,a).
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, rhs_v, lhs_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit `ne` synthesis. CMEQ → NOT V16B → MOV result, V31.
/// Used by int and FP `ne` handlers in the sibling files.
///
/// Promoted to `pub` in 9.9-h-18 per ADR-0054 §"Helper
/// visibility — tiered pub".
pub fn emitV128Ne(ctx: *EmitCtx, eq_encoder: *const fn (rd: u5, rn: u5, rm: u5) u32) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Step 1: CMEQ V31, V<lhs>, V<rhs>
    try gpr.writeU32(ctx.allocator, ctx.buf, eq_encoder(simd_scratch_v, lhs_v, rhs_v));
    // Step 2: NOT V31.16B, V31.16B
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encNotV16B(simd_scratch_v, simd_scratch_v));
    // Step 3: MOV V<result>.16B, V31.16B
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, simd_scratch_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// §9.9 / 9.9-f-1 — v128 bitwise ops. AND / OR / XOR / ANDNOT /
// BITSELECT all share the existing `emitV128Binop` /
// `emitV128Binop3` shape; v128.not consumes a single v128 input
// (unop). Per Wasm spec §4.4 (bitwise SIMD).

pub fn emitV128And(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAnd16B);
}
pub fn emitV128Or(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encOrrV16B);
}
pub fn emitV128Xor(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encEor16B);
}
/// Wasm `v128.andnot a b` = `a AND NOT b`. NEON `BIC Vd, Vn, Vm`
/// computes `Vn AND NOT Vm` — exact match.
pub fn emitV128Andnot(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encBic16B);
}

/// `v128.not`: pop 1 v128, push 1 v128 with all bits inverted.
/// `MVN V<d>.16B, V<n>.16B`. Uses the shared `emitV128Unop` helper.
pub fn emitV128Not(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encMvn16B);
}

/// `v128.bitselect c v1 v2`: result lanes = `(v1 AND c) | (v2 AND NOT c)`.
/// Per Wasm spec §4.4.7 — pop 3× v128 (top-of-stack is c), push v128.
/// `BSL Vd.16B, Vn.16B, Vm.16B` computes `Vd ← (Vd AND Vn) | (Vm AND NOT Vd)`,
/// so we MOV Vd ← c first then `BSL Vd, v1, v2`. Mask reuses result V slot
/// (BSL writes Vd in place — same shape as 9.9-d-5's emitV128Select).
pub fn emitV128Bitselect(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const c_vreg = ctx.pushed_vregs.pop().?;
    const v2_vreg = ctx.pushed_vregs.pop().?;
    const v1_vreg = ctx.pushed_vregs.pop().?;
    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;

    // SPILL-EXEMPT: bitselect needs 3 V regs simultaneously
    // (mask=dst, v1, v2). Mirrors emitV128Select's 3-source
    // shape; D-037 stage_idx=2 follow-on lifts this once the
    // FP-spill scaffold extends.
    const mask_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);
    const c_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, c_vreg, 1);
    const v1_x = try gpr.resolveFp(ctx.alloc, v1_vreg);
    const v2_x = try gpr.resolveFp(ctx.alloc, v2_vreg);

    // §9.9 / 9.9-h-14 (D-070 discharge): regalloc's LIFO slot-
    // reuse can assign `result_vreg` (=mask_v) the same physical
    // V reg as v1 or v2. The naive `MOV mask_v, c_v` then
    // clobbers v1 or v2 before `BSL` reads it; symptom is
    // `bitselect(aa, bb, c)` returning wrong values for the
    // c==0 / c==all-ones boundary cases. Stash the destroyed
    // operand through V31 (popcnt scratch — outside any
    // popcnt sequence in this handler).
    const v1_for_op: inst_neon.Vn = if (mask_v != c_v and mask_v == v1_x) blk: {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(31, v1_x));
        break :blk 31;
    } else v1_x;
    const v2_for_op: inst_neon.Vn = if (mask_v != c_v and mask_v == v2_x) blk: {
        // mask_v can equal at most one of {v1_x, v2_x} unless
        // v1_v == v2_v (same vreg passed twice). The latter is
        // not a slot-reuse alias — it's identical-input, and
        // BSL reads it once before BSL semantics consume.
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(31, v2_x));
        break :blk 31;
    } else v2_x;

    if (mask_v != c_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(mask_v, c_v));
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encBsl16B(mask_v, v1_for_op, v2_for_op));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// §9.9 / 9.9-g-3 — v128.any_true reduction
// ============================================================
//
// Wasm SIMD spec — `v128.any_true` returns 1 iff any byte of the
// input v128 is non-zero. Pops v128, pushes i32. (The matching
// `i*x*.all_true` reductions live in `op_simd_int_cmp_lane.zig`
// alongside the other int reductions.)
//
// ARM64 strategy:
//
//   any_true: UMAXV B<v>, V<src>.16B (max byte across 16 lanes
//             — non-zero iff any byte was). Then UMOV W,V.B[0];
//             CMP W,#0; CSET W,NE.

const any_true_scratch_v: u5 = 29; // V29: fp_spill_stage[0]; safe inside this op.
const any_true_scratch_x_a: u5 = 16; // X16 / IP0

pub fn emitV128AnyTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: i32 result; mirrors emitI32x4ExtractLane's pre-spill-aware GPR-result shape.
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    // Reduce into V29 (lane 0 holds the max byte).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmaxv16B(any_true_scratch_v, src_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovWFromB(any_true_scratch_x_a, any_true_scratch_v, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(any_true_scratch_x_a, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(result_w, .ne));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// §9.9 / 9.6-f-ii — v128.const (per ADR-0042)
// ============================================================
//
// Materialises a 16-byte literal from the per-function const-pool
// via PC-relative LDR-Q-literal. The lower pass populates
// `func.simd_consts` (lower.zig) and stores the array index in
// `ZirInstr.payload`. The handler emits an LDR-Q-literal placeholder
// (imm19=0) and records a SimdConstFixup; the per-function emit
// close (emit.zig) appends the const-pool 16-byte aligned past the
// trap stub and patches each fixup's imm19.
//
// `i8x16.shuffle` (which also uses the const-pool) lives in
// `op_simd_int_cmp_lane.zig` alongside swizzle and the other
// per-lane recipes.

/// Wasm spec (SIMD) — `v128.const`: push a 16-byte literal as a
/// v128 value. Lowers to `LDR Q<rt>, <const-pool entry>` (1 insn,
/// fixup-resolved at function close).
pub fn emitV128Const(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Emit LDR-Q-literal placeholder (imm19=0) and record fixup.
    const fixup_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrLiteralQ(result_v, 0));
    try ctx.simd_const_fixups.append(ctx.allocator, .{
        .byte_offset = fixup_byte,
        .const_idx = ins.payload,
    });

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}
