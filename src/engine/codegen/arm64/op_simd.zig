//! ARM64 emit pass — SIMD-128 op handlers (§9.9 / 9.5-b-iii
//! per ADR-0041).
//!
//! Wires the foundational NEON encoders (`inst_neon.zig`,
//! §9.5-a) into the ZirOp dispatch path. MVP catalogue
//! covers v128.load / v128.store / i32x4.splat / i32x4.add —
//! the four ops that demonstrate end-to-end the whole
//! SIMD pipeline (validator → lower → liveness → regalloc
//! with shape_tags → emit).
//!
//! Spill-aware integration: 9.5-b-iii MVP uses the existing
//! `gpr.resolveFp` for V-register resolution (works for
//! non-spilling functions where the SIMD vregs all fit in
//! V16-V28). Spilled v128 vregs need a 16-byte-stride
//! analog of `gpr.fpLoadSpilled` / `gpr.fpStoreSpilled`
//! (defers to 9.5-c per ADR-0041 chunk plan; current
//! `fpDefSpilled` uses 8-byte D-form stride). For now,
//! spilled v128 vregs return `UnsupportedOp` matching the
//! `gpr.resolveFp` graceful-degradation pattern.
//!
//! Per ADR-0041 §"Decision" / 2 (FP-class register pool
//! reuse with shape-tag axis): handlers query
//! `ctx.alloc.shapeTag(vreg)` only when the spill path
//! lands in 9.5-c — for non-spilled cases the V-register
//! choice is identical to scalar f32/f64.
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

/// Wasm spec §4.4.5 (`<shape>.splat`) — broadcast a scalar to
/// every lane of a v128. Shared GPR-source helper (i8x16 / i16x8
/// / i32x4 / i64x2 splat); FP-source variants (f32x4 / f64x2)
/// use `emitV128SplatFromV` because their sources are V-class.
fn emitV128SplatFromGpr(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: scalar i32/i64 src; GPR spill-aware path is its own follow-on.
    const src_reg = try gpr.resolveGpr(ctx.alloc, src_vreg);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_reg));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// FP-source splat helper. Takes an f32/f64 scalar in V-class
/// register's lane 0 and broadcasts via DUP element form.
fn emitV128SplatFromV(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    // f32/f64 scalar lives in a V-class reg's lane 0; loadSpilled
    // here uses the FP D-form spill stride (8 bytes) — fpLoadSpilled
    // returns the V index that DUP element can read from.
    const src_v = try gpr.fpLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `i8x16.splat`: pop i32 scalar (low byte), broadcast to 16 bytes.
pub fn emitI8x16Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDup16B);
}

/// `i16x8.splat`: pop i32 scalar (low half), broadcast to 8 halves.
pub fn emitI16x8Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDup8H);
}

/// `i32x4.splat`: pop scalar i32 (Wn), push v128 result (Vd.4S).
/// `DUP V<vd>.4S, W<wn>` broadcasts the i32 to all four 32-bit
/// lanes.
pub fn emitI32x4Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDup4S);
}

/// `i64x2.splat`: pop i64 scalar (Xn), broadcast to both 64-bit lanes.
pub fn emitI64x2Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromGpr(ctx, inst_neon.encDupGen2D);
}

/// `f32x4.splat`: pop f32 scalar (S<vn>), broadcast to all 4 32-bit
/// lanes via DUP element form (V<vn>.S[0] → V<vd>.4S).
pub fn emitF32x4Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromV(ctx, inst_neon.encDup4SFromS0);
}

/// `f64x2.splat`: pop f64 scalar (D<vn>), broadcast to both lanes.
pub fn emitF64x2Splat(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128SplatFromV(ctx, inst_neon.encDup2DFromD0);
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

/// `i32x4.add`: pop two v128 (Vn.4S, Vm.4S), push v128 sum
/// (Vd.4S). `ADD V<vd>.4S, V<vn>.4S, V<vm>.4S` does element-wise
/// 32-bit add across the four lanes.
/// Shared v128 binop emit helper (§9.5-c-iv): pop 2 v128, emit
/// `encoder(rd, rn, rm)`, push 1 v128. Spill-aware via the q*
/// trio at stage_idx 0/1 (same convention as gpr/fp binops —
/// lhs at 0, rhs at 1; result reuses 0 since lhs is consumed).
fn emitV128Binop(
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
/// `MVN V<d>.16B, V<n>.16B`. Uses the shared `emitV128Unop` helper
/// (defined later in this file alongside the f32x4 / f64x2 unops).
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
    if (mask_v != c_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(mask_v, c_v));
    }
    // SPILL-EXEMPT: 3-source BSL — see comment above.
    const v1_v = try gpr.resolveFp(ctx.alloc, v1_vreg);
    // SPILL-EXEMPT: 3-source BSL — see comment above.
    const v2_v = try gpr.resolveFp(ctx.alloc, v2_vreg);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encBsl16B(mask_v, v1_v, v2_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd16B);
}
pub fn emitI8x16Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub16B);
}
pub fn emitI16x8Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd8H);
}
pub fn emitI16x8Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub8H);
}
pub fn emitI32x4Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd4S);
}
pub fn emitI32x4Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub4S);
}
pub fn emitI64x2Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encAdd2D);
}
pub fn emitI64x2Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encSub2D);
}

// §9.9 / 9.9-f-7 — int unops (abs / neg / popcnt). Wasm SIMD
// spec §4.4 (vector arith). NEON ABS/NEG share the
// two-register-misc encoding with size selecting lane shape;
// CNT is byte-only (16B) and exists only for `i8x16.popcnt`.
pub fn emitI8x16Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encAbs16B);
}
pub fn emitI8x16Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encNeg16B);
}
pub fn emitI8x16Popcnt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encCnt16B);
}
pub fn emitI16x8Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encAbs8H);
}
pub fn emitI16x8Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encNeg8H);
}
pub fn emitI32x4Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encAbs4S);
}
pub fn emitI32x4Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encNeg4S);
}
pub fn emitI64x2Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encAbs2D);
}
pub fn emitI64x2Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encNeg2D);
}
// Note: Wasm SIMD has no `i8x16.mul` (only i16x8/i32x4/i64x2). The
// underlying NEON `MUL Vd.16B` encoding (encMul16B) is preserved
// in inst_neon.zig for completeness but no ZirOp dispatches to it.
pub fn emitI16x8Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encMul8H);
}
pub fn emitI32x4Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encMul4S);
}

// `i64x2.mul` handler + dispatch arm live further below near
// the §9.5-c-vii-mul block; both pre-existed in the codebase
// but were unreachable from spec corpus until §9.9 / 9.9-f-8
// added the missing validator binop arm for sub-opcode 213.

/// `i32x4.extract_lane`: pop v128 (Vn.4S), push i32 result (Wd).
/// `UMOV W<wd>, V<vn>.S[lane]` extracts the 32-bit lane (zero-
/// extended into Wd). Lane immediate is in `ins.payload`
/// (per `lower.emitLaneByte`'s 1-byte encoding from §9.4).
pub fn emitI32x4ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: i32 result (GPR); spill-aware path is its own follow-on alongside other GPR sites.
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    const lane: u2 = @intCast(ins.payload & 3);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovWFromS(result_w, src_v, lane));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// `i32x4.replace_lane`: pop scalar i32 (Wn), pop v128 (Vd.4S),
/// push v128 result (Vd' = Vd with lane[ins.payload] replaced).
/// `INS V<vd>.S[lane], W<wn>`. Note: INS modifies the destination
/// in place; for our pipeline (where the result is a fresh vreg
/// distinct from the input v128 vreg), the handler first MOVs
/// the input v128 into the result V-reg, then INS the lane.
/// When the input v128 is the same V-reg as the result (slot
/// reuse), the MOV is a no-op (encMovV16B Vd, Vd is harmless).
pub fn emitI32x4ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const new_lane_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: i32 new-lane scalar (GPR); spill-aware path is its own follow-on.
    const new_lane_w = try gpr.resolveGpr(ctx.alloc, new_lane_vreg);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    // Copy source v128 to result reg (skip if same V-reg).
    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane: u2 = @intCast(ins.payload & 3);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encInsSFromW(result_v, new_lane_w, lane));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// §9.9 / 9.5-c-vi — i8x16 / i16x8 / i64x2 lane access
// ============================================================
//
// Wasm SIMD spec — extract_lane (signed/unsigned) + replace_lane
// for the remaining int element widths. i32x4 is already wired
// in 9.5-c-iii above. f32x4 / f64x2 + i64x2.mul defer to
// 9.5-c-vii.
//
// All extract handlers return an i32 GPR result (i64 for i64x2).
// replace handlers consume an i32 GPR new-lane (i64 for i64x2).
// Per ADR-0041, the GPR side stays on the SPILL-EXEMPT escape
// hatch alongside the rest of 9.5-c (D-034 BASELINE=0; spill-
// aware GPR machinery lands in a later sub-row alongside the
// remaining bare-resolveGpr sites).

/// Helper: emit an `extract_lane` shape that reads a v128 lane via
/// a UMOV/SMOV-family encoder. The encoder builds the 32-bit
/// instruction word from (rd:Xn, rn:Vn, lane). `lane_mask` clamps
/// `ins.payload`'s lane field to the element-form's valid range.
fn emitV128ExtractLane(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, rn: u5, lane: u32) u32,
    lane_mask: u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: scalar lane result (GPR); spill-aware path is its own follow-on alongside other GPR sites.
    const result_x = try gpr.resolveGpr(ctx.alloc, result_vreg);

    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_x, src_v, lane));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit a `replace_lane` shape that writes a v128 lane via
/// an INS-family encoder.
fn emitV128ReplaceLane(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, rn: u5, lane: u32) u32,
    lane_mask: u32,
) Error!void {
    const new_lane_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: scalar new-lane (GPR); spill-aware path is its own follow-on alongside other GPR sites.
    const new_lane_x = try gpr.resolveGpr(ctx.alloc, new_lane_vreg);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, new_lane_x, lane));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// Encoder thunks — adapt the per-element-form encoder signatures to
// the helper's `(u5, u5, u32) -> u32` shape. The helpers want a
// uniform lane type so both u4 (B) and u3 (H) and u1 (D) encoders
// can share one code path; the cast is safe because `lane_mask`
// constrains the value first.

fn encUmovB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encUmovWFromB(rd, rn, @intCast(lane));
}
fn encSmovB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encSmovWFromB(rd, rn, @intCast(lane));
}
fn encInsB(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encInsBFromW(rd, rn, @intCast(lane));
}
fn encUmovH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encUmovWFromH(rd, rn, @intCast(lane));
}
fn encSmovH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encSmovWFromH(rd, rn, @intCast(lane));
}
fn encInsH(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encInsHFromW(rd, rn, @intCast(lane));
}
fn encUmovD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encUmovXFromD(rd, rn, @intCast(lane));
}
fn encInsD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encInsDFromX(rd, rn, @intCast(lane));
}

/// Wasm spec (SIMD) — `i8x16.extract_lane_s`: lane ∈ 0..15;
/// sign-extend the byte into i32. Lowers to `SMOV W<rd>, V<rn>.B[lane]`.
pub fn emitI8x16ExtractLaneS(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encSmovB, 0xF);
}

/// Wasm spec (SIMD) — `i8x16.extract_lane_u`: zero-extend the byte
/// into i32. Lowers to `UMOV W<rd>, V<rn>.B[lane]`.
pub fn emitI8x16ExtractLaneU(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encUmovB, 0xF);
}

/// Wasm spec (SIMD) — `i8x16.replace_lane`: replace the lane with the
/// low 8 bits of an i32 input. Lowers to `INS V<vd>.B[lane], W<wn>`.
pub fn emitI8x16ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLane(ctx, ins, encInsB, 0xF);
}

/// Wasm spec (SIMD) — `i16x8.extract_lane_s`: sign-extend the halfword
/// into i32. Lowers to `SMOV W<rd>, V<rn>.H[lane]`.
pub fn emitI16x8ExtractLaneS(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encSmovH, 0x7);
}

/// Wasm spec (SIMD) — `i16x8.extract_lane_u`: zero-extend the halfword
/// into i32. Lowers to `UMOV W<rd>, V<rn>.H[lane]`.
pub fn emitI16x8ExtractLaneU(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encUmovH, 0x7);
}

/// Wasm spec (SIMD) — `i16x8.replace_lane`: replace the lane with the
/// low 16 bits of an i32 input. Lowers to `INS V<vd>.H[lane], W<wn>`.
pub fn emitI16x8ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLane(ctx, ins, encInsH, 0x7);
}

/// Wasm spec (SIMD) — `i64x2.extract_lane`: lane ∈ 0..1; copy the
/// 64-bit lane into an i64 GPR. Lowers to `UMOV X<rd>, V<rn>.D[lane]`.
/// (No signed/unsigned variant — i64 has no narrower width to extend
/// from.)
pub fn emitI64x2ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLane(ctx, ins, encUmovD, 0x1);
}

/// Wasm spec (SIMD) — `i64x2.replace_lane`: replace the lane with an
/// i64 input. Lowers to `INS V<vd>.D[lane], X<rn>`.
pub fn emitI64x2ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLane(ctx, ins, encInsD, 0x1);
}

// ============================================================
// §9.9 / 9.5-c-vii — f32x4 / f64x2 lane access
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.extract_lane` / `f64x2.extract_lane`
// produce a scalar f32 / f64 result held in an FP register.
// `_replace_lane` consumes a scalar FP at S[0] / D[0] of an FP
// register. Encoders: DUP-scalar (extract; zeros upper V bits) +
// INS-element (replace; copies V<n>.S[0] / V<n>.D[0] into a V<rd>
// lane). FP-side scalar resolves stay on the SPILL-EXEMPT escape
// hatch alongside the int-side resolveGpr sites — fpLoadSpilled /
// fpDefSpilled migration is its own follow-on. The v128 spill
// path remains via `qLoadSpilled` / `qDefSpilled` / `qStoreSpilled`.

/// Helper: emit `extract_lane` for FP-result variants. Mirrors
/// `emitV128ExtractLane` but resolves the result vreg to a V
/// register via `gpr.resolveFp` instead of a GPR via `resolveGpr`.
fn emitV128ExtractLaneFp(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, rn: u5, lane: u32) u32,
    lane_mask: u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: FP scalar result; fpDefSpilled (D-form, 8-byte stride) is its own follow-on alongside other FP-side sites.
    const result_v = try gpr.resolveFp(ctx.alloc, result_vreg);

    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, src_v, lane));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

/// Helper: emit `replace_lane` for FP-input variants. The new-lane
/// scalar comes from a V register (S/D form low bits), not a GPR.
///
/// Aliasing safety (D-066 close): the regalloc's LIFO slot-reuse
/// can assign `result_vreg` the same physical V-reg as
/// `new_lane_vreg` (e.g. simd_lane.137's
/// `extract_lane → replace_lane` chain on `(v128, v128) → v128`
/// — at the replace_lane site, the extracted-lane vreg dies and
/// its V-reg is the LIFO-top free slot, which is then handed back
/// to the new result vreg). The naive sequence MOV result_v ←
/// src_v then INS would clobber `new_lane_v` before INS reads it.
/// Stash `new_lane_v` through V31 (popcnt scratch — outside any
/// popcnt sequence here) when the alias condition holds.
fn emitV128ReplaceLaneFp(
    ctx: *EmitCtx,
    ins: *const ZirInstr,
    encoder: *const fn (rd: u5, dst_lane: u32, rn: u5) u32,
    lane_mask: u32,
) Error!void {
    const new_lane_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: FP scalar new-lane; fpLoadSpilled is its own follow-on alongside other FP-side sites.
    const new_lane_v = try gpr.resolveFp(ctx.alloc, new_lane_vreg);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 1);

    var ins_src: u5 = new_lane_v;
    if (src_v != result_v and new_lane_v == result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(simd_scratch_v, new_lane_v));
        ins_src = simd_scratch_v;
    }
    if (src_v != result_v) {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, src_v));
    }
    const lane = ins.payload & lane_mask;
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(result_v, lane, ins_src));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 1);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// Encoder thunks for the FP forms (parallel to the int thunks above).
fn encDupScalarS(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encMovScalarSFromVlane(rd, rn, @intCast(lane));
}
fn encDupScalarD(rd: u5, rn: u5, lane: u32) u32 {
    return inst_neon.encMovScalarDFromVlane(rd, rn, @intCast(lane));
}
fn encInsElemS(rd: u5, dst_lane: u32, rn: u5) u32 {
    return inst_neon.encMovVSlaneFromVS0(rd, @intCast(dst_lane), rn);
}
fn encInsElemD(rd: u5, dst_lane: u32, rn: u5) u32 {
    return inst_neon.encMovVDlaneFromVD0(rd, @intCast(dst_lane), rn);
}

/// Wasm spec (SIMD) — `f32x4.extract_lane`: lane ∈ 0..3; produce a
/// scalar f32. Lowers to `MOV S<rd>, V<rn>.S[lane]` (DUP scalar S).
pub fn emitF32x4ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLaneFp(ctx, ins, encDupScalarS, 0x3);
}

/// Wasm spec (SIMD) — `f32x4.replace_lane`: replace a lane with an
/// f32 scalar. Lowers to `MOV V<vd>.S[lane], V<vn>.S[0]` (INS
/// element S form, src lane 0).
pub fn emitF32x4ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLaneFp(ctx, ins, encInsElemS, 0x3);
}

/// Wasm spec (SIMD) — `f64x2.extract_lane`: lane ∈ 0..1; produce a
/// scalar f64. Lowers to `MOV D<rd>, V<rn>.D[lane]` (DUP scalar D).
pub fn emitF64x2ExtractLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ExtractLaneFp(ctx, ins, encDupScalarD, 0x1);
}

/// Wasm spec (SIMD) — `f64x2.replace_lane`: replace a lane with an
/// f64 scalar. Lowers to `MOV V<vd>.D[lane], V<vn>.D[0]` (INS
/// element D form, src lane 0).
pub fn emitF64x2ReplaceLane(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    return emitV128ReplaceLaneFp(ctx, ins, encInsElemD, 0x1);
}

// ============================================================
// §9.9 / 9.9-g-10 — int min/max + avgr_u (14 ops)
// ============================================================
//
// Wasm SIMD spec — i*x*.{min_s, min_u, max_s, max_u} for B/H/S
// shapes (no .2D form on NEON). i*x*.avgr_u for B/H only (Wasm
// has no i32x4.avgr_u). Each op compiles to a single Advanced
// SIMD three-same instruction (SMIN / UMIN / SMAX / UMAX /
// URHADD); all share the existing `emitV128Binop` helper.

pub fn emitI8x16MinS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encSmin16B); }
pub fn emitI8x16MinU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUmin16B); }
pub fn emitI8x16MaxS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encSmax16B); }
pub fn emitI8x16MaxU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUmax16B); }
pub fn emitI8x16AvgrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUrhadd16B); }
pub fn emitI16x8MinS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encSmin8H); }
pub fn emitI16x8MinU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUmin8H); }
pub fn emitI16x8MaxS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encSmax8H); }
pub fn emitI16x8MaxU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUmax8H); }
pub fn emitI16x8AvgrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUrhadd8H); }
pub fn emitI32x4MinS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encSmin4S); }
pub fn emitI32x4MinU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUmin4S); }
pub fn emitI32x4MaxS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encSmax4S); }
pub fn emitI32x4MaxU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encUmax4S); }

// ============================================================
// §9.9 / 9.5-c-vii-mul — i64x2.mul multi-instr synthesis
// ============================================================
//
// Wasm spec (SIMD) — `i64x2.mul`: lane-wise 64-bit multiply.
// A64 NEON has no `MUL Vd.2D` instruction (the size encoding
// for MUL Vd.<T>, Vn.<T>, Vm.<T> stops at 4S — bits[23:22]=11
// is reserved for D form). We synthesise via per-lane GPR
// transit:
//   for k in 0..2:
//     UMOV X16, V<lhs>.D[k]   ; encUmovXFromD
//     UMOV X17, V<rhs>.D[k]   ; encUmovXFromD
//     MUL  X16, X16, X17      ; encMulReg (X-form)
//     INS  V<result>.D[k], X16 ; encInsDFromX
//
// X16 (IP0) / X17 (IP1) are AAPCS64 intra-procedure scratch —
// already used by `op_alu_int.emitI*Rotl` (rotate-left synthesis)
// and `op_alu_float.emitF*Copysign` (signed-zero bit-mask). No
// new reservation needed.
//
// Aliasing safety: result V can equal lhs V or rhs V (regalloc
// may reuse a slot whose liveness ended at this op). The
// per-lane sequence is alias-safe — INS V<result>.D[k] only
// touches lane k, leaving the other lane intact for the next
// iteration's UMOV reads.

const i64x2_mul_scratch_a: inst.Xn = 16; // X16 / IP0
const i64x2_mul_scratch_b: inst.Xn = 17; // X17 / IP1

/// Wasm spec (SIMD) — `i64x2.mul`: 8-word emission per call.
/// See block comment above for the synthesis rationale.
pub fn emitI64x2Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    inline for (.{ 0, 1 }) |k| {
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovXFromD(i64x2_mul_scratch_a, lhs_v, k));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovXFromD(i64x2_mul_scratch_b, rhs_v, k));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMulReg(i64x2_mul_scratch_a, i64x2_mul_scratch_a, i64x2_mul_scratch_b));
        try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encInsDFromX(result_v, i64x2_mul_scratch_a, k));
    }

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// §9.9 / 9.9-g-7 — int shift left (i*x*.shl)
// ============================================================
//
// Wasm SIMD spec §3.3.6 (vector shift): `i*x*.shl` pops i32
// amount + v128 value, pushes v128. Recipe: DUP V<tmp>.<T>,
// W<amt> (broadcast scalar amount to all lanes), then USHL
// V<d>.<T>, V<src>.<T>, V<tmp>.<T>. NEON USHL automatically
// masks the shift to lane-element bitwidth (per Arm IHI 0055
// §C7.2.412), matching Wasm's "amount mod lane_width" semantic.
// shr_s / shr_u use the same shape but require NEG W<amt> first
// (NEON treats negative amount as right-shift) — deferred to a
// follow-up chunk.
//
// V29 = fp_spill_stage[0] reused as DUP destination scratch.
// W<dup_tmp_w> via spill stage 0 GPR (X14 per abi.zig).

/// Wasm shift semantic: amount is taken `mod element_width` (per
/// spec §3.3.6). NEON USHL/SSHL semantic: when `|shift| >=
/// element_width`, all result bits are zeroed (per Arm IHI 0055
/// §C7.2.412). The two semantics diverge for shift amounts at
/// or beyond element_width — Wasm wraps to a small mod, NEON
/// zeroes. We bridge with an explicit `AND W<amt>, #(lane-1)`
/// before DUP / NEG. Lane mask: 7 / 15 / 31 / 63 for i8x16 /
/// i16x8 / i32x4 / i64x2.
const shift_scratch_mask_x: u5 = 16; // X16 / IP0
const shift_scratch_amt_x: u5 = 17;  // X17 / IP1 (post-mask + post-NEG)

fn emitV128IntShift(
    ctx: *EmitCtx,
    lane_mask: u16, // 7 / 15 / 31 / 63
    is_64bit: bool, // true for i64x2 (use X-form NEG)
    is_shr: bool,   // true for shr_s/shr_u (NEG amount before DUP)
    dup_encoder: *const fn (rd: u5, rn: u5) u32,
    shift_encoder: *const fn (rd: u5, rn: u5, rm: u5) u32,
) Error!void {
    const amt_vreg = ctx.pushed_vregs.pop().?;
    // SPILL-EXEMPT: i32 amount; consumed via AND/NEG/DUP below.
    const amt_w = try gpr.resolveGpr(ctx.alloc, amt_vreg);

    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    const dup_v: u5 = 29; // fp_spill_stage[0]

    // MOVZ X16, #lane_mask ; AND W17, W<amt>, W16  (masks the amount mod lane_width).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encMovzImm16(shift_scratch_mask_x, lane_mask));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAndRegW(shift_scratch_amt_x, amt_w, shift_scratch_mask_x));
    if (is_shr) {
        if (is_64bit) {
            // SUB X17, XZR, X17 — full 64-bit NEG (mask cleared upper bits, so X17's high half is 0 pre-NEG).
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubReg(shift_scratch_amt_x, 31, shift_scratch_amt_x));
        } else {
            try gpr.writeU32(ctx.allocator, ctx.buf, inst.encSubRegW(shift_scratch_amt_x, 31, shift_scratch_amt_x));
        }
    }
    try gpr.writeU32(ctx.allocator, ctx.buf, dup_encoder(dup_v, shift_scratch_amt_x));
    try gpr.writeU32(ctx.allocator, ctx.buf, shift_encoder(result_v, src_v, dup_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}


pub fn emitI8x16Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 7,  false, false, inst_neon.encDup16B,    inst_neon.encUshl16B);
}
pub fn emitI16x8Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 15, false, false, inst_neon.encDup8H,     inst_neon.encUshl8H);
}
pub fn emitI32x4Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 31, false, false, inst_neon.encDup4S,     inst_neon.encUshl4S);
}
pub fn emitI64x2Shl(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 63, true,  false, inst_neon.encDupGen2D,  inst_neon.encUshl2D);
}

// ============================================================
// §9.9 / 9.9-g-8 — int shift right (i*x*.shr_s, i*x*.shr_u)
// ============================================================
//
// NEON's USHL/SSHL with **negative** shift amount in V<m>'s
// per-lane element performs a right shift (logical for U,
// arithmetic for S). The recipe extends `emitV128IntShl` with a
// preceding NEG of the W<amt> (or X<amt> for i64x2) before DUP:
//
//   SUB W<tmp>, WZR, W<amt>        ; 32-bit NEG (i8x16/i16x8/i32x4)
//   DUP V<dup>.<T>, W<tmp>
//   (U|S)SHL Vd.<T>, Vsrc.<T>, V<dup>.<T>
//
// For i64x2: SUB X<tmp>, XZR, X<amt> — full 64-bit NEG, since the
// W amount has been zero-extended into X<amt>'s low 32 bits and
// the high 32 bits are 0 (Wasm shift amount mod 64 is always
// non-negative, so the zero-extended X<amt> already represents
// the correct positive value pre-NEG).

// shr_u — USHL with negative (masked) amount.
pub fn emitI8x16ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 7,  false, true, inst_neon.encDup16B,   inst_neon.encUshl16B);
}
pub fn emitI16x8ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 15, false, true, inst_neon.encDup8H,    inst_neon.encUshl8H);
}
pub fn emitI32x4ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 31, false, true, inst_neon.encDup4S,    inst_neon.encUshl4S);
}
pub fn emitI64x2ShrU(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 63, true,  true, inst_neon.encDupGen2D, inst_neon.encUshl2D);
}

// shr_s — SSHL with negative (masked) amount (arithmetic sign extension).
pub fn emitI8x16ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 7,  false, true, inst_neon.encDup16B,   inst_neon.encSshl16B);
}
pub fn emitI16x8ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 15, false, true, inst_neon.encDup8H,    inst_neon.encSshl8H);
}
pub fn emitI32x4ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 31, false, true, inst_neon.encDup4S,    inst_neon.encSshl4S);
}
pub fn emitI64x2ShrS(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128IntShift(ctx, 63, true,  true, inst_neon.encDupGen2D, inst_neon.encSshl2D);
}

// ============================================================
// §9.9 / 9.9-g-3 — v128 reductions (any_true / all_true)
// ============================================================
//
// Wasm SIMD spec — `v128.any_true` returns 1 iff any byte of the
// input v128 is non-zero; `i*x*.all_true` returns 1 iff every
// lane of the input v128 is non-zero. Both pop v128, push i32.
//
// ARM64 strategy:
//
//   any_true: UMAXV B<v>, V<src>.16B (max byte across 16 lanes
//             — non-zero iff any byte was). Then UMOV W,V.B[0];
//             CMP W,#0; CSET W,NE.
//
//   i8x16/i16x8/i32x4.all_true: UMINV {B,H,S}<v>, V<src>.{16B,8H,
//             4S} (min lane is non-zero iff every lane was).
//             Then UMOV → CMP → CSET NE. Same shape; the encoder
//             differs by lane-width.
//
//   i64x2.all_true: NEON has no UMINV.2D form — synthesise via
//             two D-lane extracts + CMP + CSET + AND. Per Arm
//             IHI 0055 §C7.2.394 (UMINV is byte/halfword/word
//             only; doubleword reduction requires GPR detour).
//
// Result vreg is GPR-class (i32). The shared helper
// `emitV128ReduceWithEncoder` handles the common path; i64x2 has
// its own dedicated handler.

const reduce_scratch_v: u5 = 29; // V29: fp_spill_stage[0]; safe inside this op.
const reduce_scratch_x_a: u5 = 16; // X16 / IP0
const reduce_scratch_x_b: u5 = 17; // X17 / IP1

fn emitV128ReduceWithEncoder(
    ctx: *EmitCtx,
    encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: i32 result; mirrors emitI32x4ExtractLane's pre-spill-aware GPR-result shape.
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    // Reduce into V29 (lane 0 holds the max/min byte/half/word).
    try gpr.writeU32(ctx.allocator, ctx.buf, encoder(reduce_scratch_v, src_v));
    // Extract lane 0 (B form) into W16 — width 8 / 16 / 32 of the
    // reduced scalar all zero-extend cleanly into W via UMOV B
    // since "value != 0" is what we actually compare; the upper
    // bits are immaterial.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovWFromB(reduce_scratch_x_a, reduce_scratch_v, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmW(reduce_scratch_x_a, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(result_w, .ne));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitV128AnyTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ReduceWithEncoder(ctx, inst_neon.encUmaxv16B);
}

pub fn emitI8x16AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ReduceWithEncoder(ctx, inst_neon.encUminv16B);
}

pub fn emitI16x8AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ReduceWithEncoder(ctx, inst_neon.encUminv8H);
}

pub fn emitI32x4AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ReduceWithEncoder(ctx, inst_neon.encUminv4S);
}

/// `i64x2.all_true`: NEON UMINV has no 2D form. Synthesise via
/// extracting both 64-bit lanes to GPRs, comparing each to 0,
/// and ANDing the cset results. 6 instructions.
pub fn emitI64x2AllTrue(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    // SPILL-EXEMPT: i32 result mirrors emitV128ReduceWithEncoder.
    const result_w = try gpr.resolveGpr(ctx.alloc, result_vreg);

    // X16 ← src.D[0]; X17 ← src.D[1].
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovXFromD(reduce_scratch_x_a, src_v, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encUmovXFromD(reduce_scratch_x_b, src_v, 1));
    // CMP X16, #0 ; CSET W16, NE
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(reduce_scratch_x_a, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(reduce_scratch_x_a, .ne));
    // CMP X17, #0 ; CSET W17, NE
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCmpImmX(reduce_scratch_x_b, 0));
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encCsetW(reduce_scratch_x_b, .ne));
    // AND W<result>, W16, W17
    try gpr.writeU32(ctx.allocator, ctx.buf, inst.encAndRegW(result_w, reduce_scratch_x_a, reduce_scratch_x_b));
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

// ============================================================
// §9.6 / 9.6-a — f32x4 / f64x2 binary FP arithmetic
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.add/sub/mul/div`, `f64x2.add/sub/mul/div`.
// Lowers to NEON FADD/FSUB/FMUL/FDIV with 4S (S = single) or 2D
// (D = double) arrangement. NEON FP arith follows IEEE-754
// round-to-nearest-even with NaN-propagation matching Wasm
// semantics (per ADR-0041 §"4. NEON IEEE-754 spec-fidelity").
//
// All 8 handlers share the existing `emitV128Binop` shape — pop
// 2 v128, push 1 v128 — so they're thin adapters around the
// per-shape encoder.

pub fn emitF32x4Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFAdd4S);
}
pub fn emitF32x4Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFSub4S);
}
pub fn emitF32x4Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMul4S);
}
pub fn emitF32x4Div(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFDiv4S);
}
pub fn emitF64x2Add(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFAdd2D);
}
pub fn emitF64x2Sub(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFSub2D);
}
pub fn emitF64x2Mul(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMul2D);
}
pub fn emitF64x2Div(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFDiv2D);
}

// ============================================================
// §9.6 / 9.6-b — f32x4 / f64x2 unary FP arithmetic
// ============================================================
//
// Wasm spec (SIMD) — `f32x4.{abs,neg,sqrt,ceil,floor,trunc,nearest}`
// and the f64x2 counterparts. Lowers to NEON FABS / FNEG / FSQRT /
// FRINTN / FRINTM / FRINTP / FRINTZ with 4S or 2D shape.

/// Helper: emit a v128 unary op via the given encoder (rd, rn) → u32.
/// Pop 1 v128 vreg, push 1 v128 result. Mirrors `emitV128Binop` but
/// with one source operand.
fn emitV128Unop(ctx: *EmitCtx, encoder: *const fn (rd: u5, rn: u5) u32) Error!void {
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

pub fn emitF32x4Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFAbs4S);
}
pub fn emitF32x4Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFNeg4S);
}
pub fn emitF32x4Sqrt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFSqrt4S);
}
pub fn emitF32x4Ceil(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintP4S);
}
pub fn emitF32x4Floor(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintM4S);
}
pub fn emitF32x4Trunc(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintZ4S);
}
pub fn emitF32x4Nearest(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintN4S);
}
pub fn emitF64x2Abs(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFAbs2D);
}
pub fn emitF64x2Neg(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFNeg2D);
}
pub fn emitF64x2Sqrt(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFSqrt2D);
}
pub fn emitF64x2Ceil(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintP2D);
}
pub fn emitF64x2Floor(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintM2D);
}
pub fn emitF64x2Trunc(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintZ2D);
}
pub fn emitF64x2Nearest(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFRintN2D);
}

// ============================================================
// §9.6 / 9.6-c-i — f32x4 / f64x2 min / max (NaN-propagating)
// ============================================================
//
// Wasm spec (SIMD) — IEEE-754-2008 min/max with NaN propagation.
// NEON FMAX/FMIN match exactly. `pmin`/`pmax` (pseudo-min/max
// with zero-on-equal-magnitude semantics) defer to 9.6-c-ii.

pub fn emitF32x4Min(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMin4S);
}
pub fn emitF32x4Max(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMax4S);
}
pub fn emitF64x2Min(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMin2D);
}
pub fn emitF64x2Max(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Binop(ctx, inst_neon.encFMax2D);
}

// ============================================================
// §9.6 / 9.6-c-ii — f32x4/f64x2 pmin/pmax synthesis
// ============================================================
//
// Wasm spec (SIMD) — pseudo-min/max with zero-on-equal-magnitude:
//   pmin(x, y) ≡ if y < x then y else x   (returns y on ties / NaN)
//   pmax(x, y) ≡ if x < y then y else x   (returns y on ties / NaN)
//
// A64 NEON has no direct instruction; synthesis via FCMGT + BSL
// per Arm IHI 0055. Sequence (3 instructions):
//   1. FCMGT V31, V<a>, V<b>            ; mask = (a > b)
//   2. BSL   V31.16B, V<true>.16B, V<false>.16B ; V31 = mask ? true : false
//   3. MOV   V<result>.16B, V31.16B     ; copy to result V
//
// V31 reservation: per `regalloc.zig:126` ("V31 reserved for popcnt's
// V-register pipeline"); reused here as a SIMD scratch since no live
// SIMD vreg can land there.
//
// pmin operand choice: a=lhs, b=rhs, true=rhs, false=lhs.
//   mask = (lhs > rhs); true case = rhs, false case = lhs.
// pmax operand choice: a=rhs, b=lhs, true=rhs, false=lhs.
//   mask = (rhs > lhs); true case = rhs, false case = lhs.

const simd_scratch_v: u5 = 31; // V31 / reserved scratch per ADR-0041 + regalloc.zig

fn emitPminPmaxSynthesis(
    ctx: *EmitCtx,
    cmp_encoder: *const fn (rd: u5, rn: u5, rm: u5) u32,
    is_pmax: bool,
) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Step 1: FCMGT V31, V<a>, V<b>. For pmin, a=lhs, b=rhs (mask = lhs > rhs).
    // For pmax, a=rhs, b=lhs (mask = rhs > lhs).
    const cmp_a = if (is_pmax) rhs_v else lhs_v;
    const cmp_b = if (is_pmax) lhs_v else rhs_v;
    try gpr.writeU32(ctx.allocator, ctx.buf, cmp_encoder(simd_scratch_v, cmp_a, cmp_b));

    // Step 2: BSL V31, V<rhs>.16B, V<lhs>.16B — mask ? rhs : lhs (same
    // for both pmin and pmax since the mask sense already encodes which).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encBsl16B(simd_scratch_v, rhs_v, lhs_v));

    // Step 3: MOV V<result>.16B, V31.16B (alias of ORR Vd, Vn, Vn).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(result_v, simd_scratch_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitF32x4Pmin(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt4S, false);
}
pub fn emitF32x4Pmax(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt4S, true);
}
pub fn emitF64x2Pmin(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt2D, false);
}
pub fn emitF64x2Pmax(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitPminPmaxSynthesis(ctx, inst_neon.encFCmGt2D, true);
}

// ============================================================
// §9.6 / 9.6-d — Int per-lane compares
// ============================================================
//
// Wasm spec (SIMD) — `i*x*.{eq,ne,lt_s,lt_u,gt_s,gt_u,le_s,le_u,ge_s,ge_u}`.
// i64x2 omits the unsigned variants per Wasm 2.0 SIMD.
//
// Strategy:
// - eq: emitV128Binop with CMEQ encoder
// - ne: CMEQ + NOT V16B (3-instr synthesis using V31 scratch)
// - gt_s: emitV128Binop with CMGT encoder
// - gt_u: emitV128Binop with CMHI encoder
// - ge_s: emitV128Binop with CMGE encoder
// - ge_u: emitV128Binop with CMHS encoder
// - lt_*: same encoder as gt_*, but operands swapped at handler level
// - le_*: same encoder as ge_*, but operands swapped

/// Helper: emit a binop with operands swapped (calls encoder(rd, rhs, lhs)
/// instead of the default encoder(rd, lhs, rhs)). Used for lt/le → gt/ge
/// rewrites.
fn emitV128BinopSwapped(ctx: *EmitCtx, encoder: *const fn (rd: u5, rn: u5, rm: u5) u32) Error!void {
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
fn emitV128Ne(ctx: *EmitCtx, eq_encoder: *const fn (rd: u5, rn: u5, rm: u5) u32) Error!void {
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

// i8x16 compares
pub fn emitI8x16Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq16B); }
pub fn emitI8x16Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq16B); }
pub fn emitI8x16GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt16B); }
pub fn emitI8x16GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHi16B); }
pub fn emitI8x16GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe16B); }
pub fn emitI8x16GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHs16B); }
pub fn emitI8x16LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt16B); }
pub fn emitI8x16LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHi16B); }
pub fn emitI8x16LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe16B); }
pub fn emitI8x16LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHs16B); }

// i16x8 compares
pub fn emitI16x8Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq8H); }
pub fn emitI16x8Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq8H); }
pub fn emitI16x8GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt8H); }
pub fn emitI16x8GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHi8H); }
pub fn emitI16x8GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe8H); }
pub fn emitI16x8GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHs8H); }
pub fn emitI16x8LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt8H); }
pub fn emitI16x8LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHi8H); }
pub fn emitI16x8LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe8H); }
pub fn emitI16x8LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHs8H); }

// i32x4 compares
pub fn emitI32x4Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq4S); }
pub fn emitI32x4Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq4S); }
pub fn emitI32x4GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt4S); }
pub fn emitI32x4GtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHi4S); }
pub fn emitI32x4GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe4S); }
pub fn emitI32x4GeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmHs4S); }
pub fn emitI32x4LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt4S); }
pub fn emitI32x4LtU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHi4S); }
pub fn emitI32x4LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe4S); }
pub fn emitI32x4LeU(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmHs4S); }

// i64x2 compares — signed only per Wasm 2.0 SIMD.
pub fn emitI64x2Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmEq2D); }
pub fn emitI64x2Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encCmEq2D); }
pub fn emitI64x2GtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGt2D); }
pub fn emitI64x2GeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encCmGe2D); }
pub fn emitI64x2LtS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGt2D); }
pub fn emitI64x2LeS(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encCmGe2D); }

// ============================================================
// §9.6 / 9.6-e — FP per-lane compares
// ============================================================
//
// Wasm spec (SIMD) — `f*x*.{eq,ne,lt,gt,le,ge}` (12 ops total).
// Reuse 9.6-d's helpers: `emitV128Binop` for direct, `emitV128Ne`
// for ne synthesis, `emitV128BinopSwapped` for lt/le rewrites.
// FCMGT was added in 9.6-c-ii; FCMEQ + FCMGE land here.

pub fn emitF32x4Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmEq4S); }
pub fn emitF32x4Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encFCmEq4S); }
pub fn emitF32x4Gt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGt4S); }
pub fn emitF32x4Ge(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGe4S); }
pub fn emitF32x4Lt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGt4S); }
pub fn emitF32x4Le(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGe4S); }

pub fn emitF64x2Eq(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmEq2D); }
pub fn emitF64x2Ne(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Ne(ctx, inst_neon.encFCmEq2D); }
pub fn emitF64x2Gt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGt2D); }
pub fn emitF64x2Ge(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Binop(ctx, inst_neon.encFCmGe2D); }
pub fn emitF64x2Lt(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGt2D); }
pub fn emitF64x2Le(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128BinopSwapped(ctx, inst_neon.encFCmGe2D); }

// ============================================================
// §9.6 / 9.6-f-i — i8x16.swizzle
// ============================================================
//
// Wasm spec (SIMD) — `i8x16.swizzle(operand, indices)`:
//   for each lane k: output[k] = (indices[k] < 16) ? operand[indices[k]] : 0
//
// Lowers to NEON TBL (1-register table form):
//   TBL V<result>.16B, { V<operand>.16B }, V<indices>.16B
// Stack order: operand pushed first, indices pushed second; popped
// in reverse → indices first, operand second.
// ============================================================
// §9.6 / 9.6-g-i — i*x*.extend_{low,high}_i*x*_{s,u} (12 ops)
// ============================================================
//
// Wasm spec — bitwise sign/zero extension to double-width lanes.
// Single-instruction NEON lowering (SXTL/SXTL2/UXTL/UXTL2 — aliases
// of SSHLL/USHLL with shift=0). Each handler is a thin
// `emitV128Unop` adapter with the appropriate per-shape encoder.

pub fn emitI16x8ExtendLowI8x16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encSxtl8H); }
pub fn emitI16x8ExtendHighI8x16S(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encSxtl2_8H); }
pub fn emitI16x8ExtendLowI8x16U(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encUxtl8H); }
pub fn emitI16x8ExtendHighI8x16U(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encUxtl2_8H); }

pub fn emitI32x4ExtendLowI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encSxtl4S); }
pub fn emitI32x4ExtendHighI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encSxtl2_4S); }
pub fn emitI32x4ExtendLowI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encUxtl4S); }
pub fn emitI32x4ExtendHighI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encUxtl2_4S); }

pub fn emitI64x2ExtendLowI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encSxtl2D); }
pub fn emitI64x2ExtendHighI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encSxtl2_2D); }
pub fn emitI64x2ExtendLowI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encUxtl2D); }
pub fn emitI64x2ExtendHighI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void { try emitV128Unop(ctx, inst_neon.encUxtl2_2D); }

// ============================================================
// §9.6 / 9.6-g-ii — saturating narrow (4 ops)
// ============================================================
//
// Wasm spec — `*.narrow_*_{s,u}`. Two-instruction synthesis:
//   1. <low_enc>  result.<half>, lhs.<full>   ; writes lower, zeros upper
//   2. <high_enc> result.<full>, rhs.<full>   ; writes upper, preserves lower
// SQXTN's Q=0 form clears upper half + Q=1 form preserves lower half
// → no scratch register needed (cranelift uses same pattern).

fn emitV128NarrowSaturating(
    ctx: *EmitCtx,
    low_encoder: *const fn (rd: u5, rn: u5) u32,
    high_encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Step 1: low-half narrow into result_v (zeros upper half).
    try gpr.writeU32(ctx.allocator, ctx.buf, low_encoder(result_v, lhs_v));
    // Step 2: high-half narrow merges into upper of result_v.
    try gpr.writeU32(ctx.allocator, ctx.buf, high_encoder(result_v, rhs_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16NarrowI16x8S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon.encSqxtn8B, inst_neon.encSqxtn2_16B);
}
pub fn emitI8x16NarrowI16x8U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon.encSqxtun8B, inst_neon.encSqxtun2_16B);
}
pub fn emitI16x8NarrowI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon.encSqxtn4H, inst_neon.encSqxtn2_8H);
}
pub fn emitI16x8NarrowI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128NarrowSaturating(ctx, inst_neon.encSqxtun4H, inst_neon.encSqxtun2_8H);
}

// ============================================================
// §9.6 / 9.6-g-iii — i→f FP convert (4 ops)
// ============================================================
//
// Wasm spec — `f32x4.convert_i32x4_{s,u}` (single SCVTF/UCVTF .4S
// instruction) + `f64x2.convert_low_i32x4_{s,u}` (2-instruction
// synthesis: SXTL/UXTL .2D extends lower 2 i32 lanes to 2 i64,
// then SCVTF/UCVTF .2D converts in place). FPCR RMode=00 default
// gives IEEE-754 round-to-nearest-even, matching Wasm spec
// §4.3.2.11-13.

pub fn emitF32x4ConvertI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encScvtf4S);
}
pub fn emitF32x4ConvertI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encUcvtf4S);
}

/// Helper: emit `f64x2.convert_low_i32x4_{s,u}` synthesis. Sequence:
///   1. SXTL/UXTL result.2D, src.2S — extend lower 2 i32 lanes to 2 i64.
///   2. SCVTF/UCVTF result.2D, result.2D — convert in place.
fn emitV128ConvertLowI32ToF64(
    ctx: *EmitCtx,
    extend_encoder: *const fn (rd: u5, rn: u5) u32,
    convert_encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, extend_encoder(result_v, src_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, convert_encoder(result_v, result_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitF64x2ConvertLowI32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ConvertLowI32ToF64(ctx, inst_neon.encSxtl2D, inst_neon.encScvtf2D);
}
pub fn emitF64x2ConvertLowI32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128ConvertLowI32ToF64(ctx, inst_neon.encUxtl2D, inst_neon.encUcvtf2D);
}

// ============================================================
// §9.6 / 9.6-g-iv — FCVTL / FCVTN (FP narrow / widen)
// ============================================================
//
// Wasm spec — `f64x2.promote_low_f32x4` (widens lower 2 f32 →
// 2 f64) + `f32x4.demote_f64x2_zero` (narrows 2 f64 → lower 2
// f32 lanes; upper 2 zeroed by Q=0 form).

pub fn emitF64x2PromoteLowF32x4(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFCvtl_2D_2S);
}
pub fn emitF32x4DemoteF64x2Zero(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFCvtn_2S_2D);
}

// ============================================================
// §9.6 / 9.6-g-v — trunc_sat (4 ops)
// ============================================================
//
// Wasm spec — `i32x4.trunc_sat_f32x4_{s,u}` (single-instruction
// FCVTZS/U .4S; NaN→0 + saturation match NEON default per Arm
// IHI 0055 §C7.2.131-133) + `i32x4.trunc_sat_f64x2_{s,u}_zero`
// (2-instruction synthesis: FCVTZS/U .2D narrows f64→i64 with
// sat, then SQXTN/UQXTN .2S narrows i64→i32 with sat; Q=0 form
// of the narrow instruction zeros upper 64 bits of the result,
// matching Wasm `_zero` semantic).

pub fn emitI32x4TruncSatF32x4S(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFcvtzs4S);
}
pub fn emitI32x4TruncSatF32x4U(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128Unop(ctx, inst_neon.encFcvtzu4S);
}

/// Helper: emit `i32x4.trunc_sat_f64x2_*_zero` synthesis. Sequence:
///   1. FCVTZS/U result.2D, src.2D — f64x2 → i64x2 with sat.
///   2. SQXTN/UQXTN result.2S, result.2D — i64x2 → i32x2 with sat;
///      Q=0 form clears upper 64 bits of result.
/// For signed: convert_encoder=encFcvtzs2D, narrow_encoder=encSqxtn2S
/// For unsigned: convert_encoder=encFcvtzu2D, narrow_encoder=encUqxtn2S
fn emitV128TruncSatF64Zero(
    ctx: *EmitCtx,
    convert_encoder: *const fn (rd: u5, rn: u5) u32,
    narrow_encoder: *const fn (rd: u5, rn: u5) u32,
) Error!void {
    const src_vreg = ctx.pushed_vregs.pop().?;
    const src_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, src_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, convert_encoder(result_v, src_v));
    try gpr.writeU32(ctx.allocator, ctx.buf, narrow_encoder(result_v, result_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI32x4TruncSatF64x2SZero(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128TruncSatF64Zero(ctx, inst_neon.encFcvtzs2D, inst_neon.encSqxtn2S);
}
pub fn emitI32x4TruncSatF64x2UZero(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    try emitV128TruncSatF64Zero(ctx, inst_neon.encFcvtzu2D, inst_neon.encUqxtn2S);
}

// ============================================================
// §9.6 / 9.6-f-ii — v128.const + i8x16.shuffle (per ADR-0042)
// ============================================================
//
// Both ops materialise a 16-byte literal from the per-function
// const-pool via PC-relative LDR-Q-literal. The lower pass populates
// `func.simd_consts` (lower.zig) and stores the array index in
// `ZirInstr.payload`. The handler emits an LDR-Q-literal placeholder
// (imm19=0) and records a SimdConstFixup; the per-function emit
// close (emit.zig) appends the const-pool 16-byte aligned past the
// trap stub and patches each fixup's imm19.

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

/// Wasm spec (SIMD) — `i8x16.shuffle`: pop 2 v128 (lhs, rhs), push
/// v128 result. The 16-byte shuffle mask is materialised from the
/// const-pool. NEON TBL 2-register form requires a consecutive
/// V-register pair; we copy lhs → V30 and rhs → V31, then run TBL
/// with the mask read from the result V register (which receives
/// the const-pool load + the TBL output in sequence — TBL's
/// register-level atomic semantics permit Vd == Vm).
///
/// Sequence:
///   MOV V31.16B, V<rhs>.16B
///   MOV V30.16B, V<lhs>.16B    (after lhs load, before mask load)
///   LDR Q<result>, <const-pool>  (placeholder; fixup-resolved)
///   TBL V<result>.16B, { V30.16B, V31.16B }, V<result>.16B
pub fn emitI8x16Shuffle(ctx: *EmitCtx, ins: *const ZirInstr) Error!void {
    const rhs_vreg = ctx.pushed_vregs.pop().?;
    const rhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, rhs_vreg, 1);
    // Save rhs to V31 IMMEDIATELY after qLoadSpilled — if rhs was
    // spilled, rhs_v == V30 (spill stage 1) and we must copy to V31
    // before V30 is overwritten by the lhs load stage.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(31, rhs_v));

    const lhs_vreg = ctx.pushed_vregs.pop().?;
    const lhs_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, lhs_vreg, 0);
    // Save lhs to V30. If lhs was spilled, lhs_v == V29, distinct
    // from V30 (rhs spill stage which is now overwritten with lhs;
    // this is fine since rhs is already in V31).
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encMovV16B(30, lhs_v));

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    // Materialise mask into result_v via LDR-Q-literal placeholder.
    const fixup_byte: u32 = @intCast(ctx.buf.items.len);
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encLdrLiteralQ(result_v, 0));
    try ctx.simd_const_fixups.append(ctx.allocator, .{
        .byte_offset = fixup_byte,
        .const_idx = ins.payload,
    });

    // TBL V<result>.16B, { V30.16B, V31.16B }, V<result>.16B.
    // result_v serves both as Vd (output) and Vm (mask) — atomic
    // register read-then-write is well-defined per Arm IHI 0055.
    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encTbl2Reg(result_v, 30, result_v));

    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}

pub fn emitI8x16Swizzle(ctx: *EmitCtx, _: *const ZirInstr) Error!void {
    const indices_vreg = ctx.pushed_vregs.pop().?;
    const indices_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, indices_vreg, 1);

    const operand_vreg = ctx.pushed_vregs.pop().?;
    const operand_v = try gpr.qLoadSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, operand_vreg, 0);

    const result_vreg = ctx.next_vreg.*;
    ctx.next_vreg.* += 1;
    if (result_vreg >= ctx.alloc.slots.len) return Error.SlotOverflow;
    const result_v = try gpr.qDefSpilled(ctx.alloc, result_vreg, 0);

    try gpr.writeU32(ctx.allocator, ctx.buf, inst_neon.encTbl1Reg(result_v, operand_v, indices_v));
    try gpr.qStoreSpilled(ctx.allocator, ctx.buf, ctx.alloc, ctx.spill_base_off, result_vreg, 0);
    try ctx.pushed_vregs.append(ctx.allocator, result_vreg);
}
