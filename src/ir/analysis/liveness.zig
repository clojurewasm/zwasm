//! Per-vreg liveness analysis pass (§9.5 / 5.4).
//!
//! Walks a lowered `ZirFunc`'s instr stream simulating the
//! operand stack as a stack of vreg ids. Each push assigns a
//! fresh vreg id (sequential, 0-based) and opens a live range
//! `(def_pc, def_pc)`. Each pop closes the topmost vreg's range
//! by setting `last_use_pc = pc`. The function-level `end`
//! consumes any vreg still on the stack so its range closes at
//! that instr index too.
//!
//! Phase-5 scope is the **straight-line MVP arithmetic + locals
//! + globals + select + conversions** subset (the ops covered by
//! `src/interp/mvp_int.zig`, `mvp_float.zig`, and
//! `mvp_conversions.zig` minus control flow). Encountering any
//! control-flow op (`block` / `loop` / `if` / `else` / `br` /
//! `br_if` / `br_table` / `return` / `call` / `call_indirect`)
//! returns `error.UnsupportedControlFlow` — the Phase-7 regalloc
//! consumer will refine the analysis to handle CFG splits when
//! it lands. Calls into `memory_ops.*` (loads / stores) are not
//! covered by this iteration either; their stack effects land
//! alongside the regalloc consumer.
//!
//! Lifetime: `compute` allocates the result slice via the
//! caller-supplied allocator. The caller owns it; pair with
//! `deinit` to free.
//!
//! Zone 1 (`src/ir/`).

const std = @import("std");

const zir = @import("../zir.zig");

const Allocator = std.mem.Allocator;
const ZirFunc = zir.ZirFunc;
const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const Liveness = zir.Liveness;
const LiveRange = zir.LiveRange;

pub const Error = error{
    UnsupportedControlFlow,
    UnsupportedOp,
    OperandStackUnderflow,
    OutOfMemory,
};

/// Bounded VM operand-stack simulation. 1024 mirrors the
/// validator's `max_operand_stack` so a function the validator
/// accepts cannot exceed this depth at runtime.
const max_simulated_stack: usize = 1024;

pub const StackEffect = struct { pops: u8, pushes: u8 };

/// Stack effect of an MVP op for liveness purposes. Returns
/// `null` for ops the analysis does not yet model (control flow,
/// memory ops, pseudo opcodes); callers translate that into the
/// appropriate error.
///
/// Exposed (pub since §9.9 / 9.9-d-6 / D-061) so
/// `regalloc.populateShapeTags` can mirror this same vreg
/// numbering — keeping the two in sync without duplicating
/// the catalogue.
pub fn stackEffect(op: ZirOp) ?StackEffect {
    return switch (op) {
        // 0 → 0
        .nop => .{ .pops = 0, .pushes = 0 },
        // 0 → 1
        .@"i32.const",
        .@"i64.const",
        .@"f32.const",
        .@"f64.const",
        .@"local.get",
        .@"global.get",
        => .{ .pops = 0, .pushes = 1 },
        // 1 → 0
        .drop,
        .@"local.set",
        .@"global.set",
        => .{ .pops = 1, .pushes = 0 },
        // local.tee — operand-stack-transparent per emit's
        // semantics (STR top → local slot, no pop/push). The
        // pop=1/push=1 form would close the input vreg's range
        // and fabricate a fresh vreg, opening a regalloc reuse
        // window the subsequent push could clobber. See the
        // dedicated dispatch arm in `compute()` for the
        // last-use extension. populateShapeTags also matches
        // (no shape_tag increment at local.tee).
        .@"local.tee" => .{ .pops = 0, .pushes = 0 },
        // 1 → 1 testop / unop (i32 / i64 / f32 / f64)
        .@"i32.eqz",
        .@"i32.clz",
        .@"i32.ctz",
        .@"i32.popcnt",
        .@"i64.eqz",
        .@"i64.clz",
        .@"i64.ctz",
        .@"i64.popcnt",
        .@"f32.abs",
        .@"f32.neg",
        .@"f32.ceil",
        .@"f32.floor",
        .@"f32.trunc",
        .@"f32.nearest",
        .@"f32.sqrt",
        .@"f64.abs",
        .@"f64.neg",
        .@"f64.ceil",
        .@"f64.floor",
        .@"f64.trunc",
        .@"f64.nearest",
        .@"f64.sqrt",
        // conversions 1 → 1
        .@"i32.wrap_i64",
        .@"i32.trunc_f32_s",
        .@"i32.trunc_f32_u",
        .@"i32.trunc_f64_s",
        .@"i32.trunc_f64_u",
        .@"i64.extend_i32_s",
        .@"i64.extend_i32_u",
        .@"i64.trunc_f32_s",
        .@"i64.trunc_f32_u",
        .@"i64.trunc_f64_s",
        .@"i64.trunc_f64_u",
        .@"f32.convert_i32_s",
        .@"f32.convert_i32_u",
        .@"f32.convert_i64_s",
        .@"f32.convert_i64_u",
        .@"f32.demote_f64",
        .@"f64.convert_i32_s",
        .@"f64.convert_i32_u",
        .@"f64.convert_i64_s",
        .@"f64.convert_i64_u",
        .@"f64.promote_f32",
        .@"i32.reinterpret_f32",
        .@"i64.reinterpret_f64",
        .@"f32.reinterpret_i32",
        .@"f64.reinterpret_i64",
        // Wasm 2.0 sat_trunc (sub-h5).
        .@"i32.trunc_sat_f32_s",
        .@"i32.trunc_sat_f32_u",
        .@"i32.trunc_sat_f64_s",
        .@"i32.trunc_sat_f64_u",
        .@"i64.trunc_sat_f32_s",
        .@"i64.trunc_sat_f32_u",
        .@"i64.trunc_sat_f64_s",
        .@"i64.trunc_sat_f64_u",
        // Wasm 2.0 sign-extension ops (§9.7 / 7.9 chunk c).
        // Wasm spec §4.4.1.4 (extendN_s) — pop one int, push the
        // sign-extended same-width int. Same 1→1 stack shape as
        // any unary integer op.
        .@"i32.extend8_s",
        .@"i32.extend16_s",
        .@"i64.extend8_s",
        .@"i64.extend16_s",
        .@"i64.extend32_s",
        => .{ .pops = 1, .pushes = 1 },
        // 2 → 1 binop
        .@"i32.add",
        .@"i32.sub",
        .@"i32.mul",
        .@"i32.div_s",
        .@"i32.div_u",
        .@"i32.rem_s",
        .@"i32.rem_u",
        .@"i32.and",
        .@"i32.or",
        .@"i32.xor",
        .@"i32.shl",
        .@"i32.shr_s",
        .@"i32.shr_u",
        .@"i32.rotl",
        .@"i32.rotr",
        .@"i64.add",
        .@"i64.sub",
        .@"i64.mul",
        .@"i64.div_s",
        .@"i64.div_u",
        .@"i64.rem_s",
        .@"i64.rem_u",
        .@"i64.and",
        .@"i64.or",
        .@"i64.xor",
        .@"i64.shl",
        .@"i64.shr_s",
        .@"i64.shr_u",
        .@"i64.rotl",
        .@"i64.rotr",
        .@"f32.add",
        .@"f32.sub",
        .@"f32.mul",
        .@"f32.div",
        .@"f32.min",
        .@"f32.max",
        .@"f32.copysign",
        .@"f64.add",
        .@"f64.sub",
        .@"f64.mul",
        .@"f64.div",
        .@"f64.min",
        .@"f64.max",
        .@"f64.copysign",
        // 2 → 1 relop
        .@"i32.eq",
        .@"i32.ne",
        .@"i32.lt_s",
        .@"i32.lt_u",
        .@"i32.gt_s",
        .@"i32.gt_u",
        .@"i32.le_s",
        .@"i32.le_u",
        .@"i32.ge_s",
        .@"i32.ge_u",
        .@"i64.eq",
        .@"i64.ne",
        .@"i64.lt_s",
        .@"i64.lt_u",
        .@"i64.gt_s",
        .@"i64.gt_u",
        .@"i64.le_s",
        .@"i64.le_u",
        .@"i64.ge_s",
        .@"i64.ge_u",
        .@"f32.eq",
        .@"f32.ne",
        .@"f32.lt",
        .@"f32.gt",
        .@"f32.le",
        .@"f32.ge",
        .@"f64.eq",
        .@"f64.ne",
        .@"f64.lt",
        .@"f64.gt",
        .@"f64.le",
        .@"f64.ge",
        => .{ .pops = 2, .pushes = 1 },
        // 3 → 1 select
        .select, .select_typed => .{ .pops = 3, .pushes = 1 },
        // memory loads (1 → 1; pop addr, push value)
        .@"i32.load",
        .@"i32.load8_s",
        .@"i32.load8_u",
        .@"i32.load16_s",
        .@"i32.load16_u",
        .@"i64.load",
        .@"i64.load8_s",
        .@"i64.load8_u",
        .@"i64.load16_s",
        .@"i64.load16_u",
        .@"i64.load32_s",
        .@"i64.load32_u",
        .@"f32.load",
        .@"f64.load",
        => .{ .pops = 1, .pushes = 1 },
        // memory stores (2 → 0; pop addr + value)
        .@"i32.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        .@"f32.store",
        .@"f64.store",
        => .{ .pops = 2, .pushes = 0 },
        // memory.size (0 → 1) / memory.grow (1 → 1)
        .@"memory.size" => .{ .pops = 0, .pushes = 1 },
        .@"memory.grow" => .{ .pops = 1, .pushes = 1 },
        // Wasm spec §4.4.7 (bulk memory) — pop dst, src/val, n.
        // No result is pushed.
        .@"memory.copy", .@"memory.fill" => .{ .pops = 3, .pushes = 0 },
        // §9.9 / 9.9-m-3b: memory.init pops dst, src, n (3) and
        // pushes nothing; dataidx is in `payload`. data.drop /
        // elem.drop are 0 → 0 (no operand stack effect; dropped
        // flag is JIT-handled via `payload`).
        .@"memory.init" => .{ .pops = 3, .pushes = 0 },
        .@"data.drop", .@"elem.drop" => .{ .pops = 0, .pushes = 0 },
        // §9.9 / 9.9-m-2a (per ADR-0058): table.* family stack
        // effects. Wasm spec §4.4.10–§4.4.16 (table instructions).
        //   table.get x: 1 → 1 (pop i32 idx; push reftype value)
        //   table.set x: 2 → 0 (pop reftype val; pop i32 idx)
        //   table.size x: 0 → 1 (push i32 current length)
        //   table.grow x: 2 → 1 (pop init reftype + n i32; push i32 prev_size or -1)
        //   table.fill x: 3 → 0 (pop dst i32, val reftype, n i32)
        //   table.copy x y / table.init x y: 3 → 0 (pop dst, src, n)
        .@"table.get" => .{ .pops = 1, .pushes = 1 },
        .@"table.set" => .{ .pops = 2, .pushes = 0 },
        .@"table.size" => .{ .pops = 0, .pushes = 1 },
        .@"table.grow" => .{ .pops = 2, .pushes = 1 },
        .@"table.fill", .@"table.copy", .@"table.init" => .{ .pops = 3, .pushes = 0 },
        // §9.9 / 9.9-m-1a/b (per ADR-0056): reference-typed ops.
        //   ref.null t: 0 → 1 (pushes a null reftype)
        //   ref.is_null: 1 → 1 (pop reftype, push i32 test result)
        //   ref.func x: 0 → 1 (pushes funcref for func x)
        .@"ref.null", .@"ref.func" => .{ .pops = 0, .pushes = 1 },
        .@"ref.is_null" => .{ .pops = 1, .pushes = 1 },
        // ============================================================
        // Wasm 2.0 SIMD (v128) — §9.9 / 9.9-d.
        // Wasm spec §4.4.6 (vector instructions).
        // ============================================================
        // 0 → 1: const.
        .@"v128.const" => .{ .pops = 0, .pushes = 1 },
        // 1 → 1: memory loads (pop addr, push v128).
        .@"v128.load",
        .@"v128.load8x8_s",
        .@"v128.load8x8_u",
        .@"v128.load16x4_s",
        .@"v128.load16x4_u",
        .@"v128.load32x2_s",
        .@"v128.load32x2_u",
        .@"v128.load8_splat",
        .@"v128.load16_splat",
        .@"v128.load32_splat",
        .@"v128.load64_splat",
        .@"v128.load32_zero",
        .@"v128.load64_zero",
        => .{ .pops = 1, .pushes = 1 },
        // 2 → 0: stores (pop addr + value).
        .@"v128.store" => .{ .pops = 2, .pushes = 0 },
        // 2 → 1: load_lane (pop addr + v128 src, merge byte from
        // mem into one lane).
        .@"v128.load8_lane",
        .@"v128.load16_lane",
        .@"v128.load32_lane",
        .@"v128.load64_lane",
        => .{ .pops = 2, .pushes = 1 },
        // 2 → 0: store_lane (pop addr + v128 src).
        .@"v128.store8_lane",
        .@"v128.store16_lane",
        .@"v128.store32_lane",
        .@"v128.store64_lane",
        => .{ .pops = 2, .pushes = 0 },
        // 1 → 1: splat from scalar (pop scalar, push v128).
        .@"i8x16.splat",
        .@"i16x8.splat",
        .@"i32x4.splat",
        .@"i64x2.splat",
        .@"f32x4.splat",
        .@"f64x2.splat",
        // 1 → 1: extract_lane (pop v128, push scalar; imm in
        // payload).
        .@"i8x16.extract_lane_s",
        .@"i8x16.extract_lane_u",
        .@"i16x8.extract_lane_s",
        .@"i16x8.extract_lane_u",
        .@"i32x4.extract_lane",
        .@"i64x2.extract_lane",
        .@"f32x4.extract_lane",
        .@"f64x2.extract_lane",
        // 1 → 1: bitwise unop / popcnt / abs / neg.
        .@"v128.not",
        .@"i8x16.abs",
        .@"i16x8.abs",
        .@"i32x4.abs",
        .@"i64x2.abs",
        .@"i8x16.neg",
        .@"i16x8.neg",
        .@"i32x4.neg",
        .@"i64x2.neg",
        .@"i8x16.popcnt",
        // 1 → 1: FP unop.
        .@"f32x4.abs",
        .@"f32x4.neg",
        .@"f32x4.sqrt",
        .@"f32x4.ceil",
        .@"f32x4.floor",
        .@"f32x4.trunc",
        .@"f32x4.nearest",
        .@"f64x2.abs",
        .@"f64x2.neg",
        .@"f64x2.sqrt",
        .@"f64x2.ceil",
        .@"f64x2.floor",
        .@"f64x2.trunc",
        .@"f64x2.nearest",
        // 1 → 1: extend low/high.
        .@"i16x8.extend_low_i8x16_s",
        .@"i16x8.extend_high_i8x16_s",
        .@"i16x8.extend_low_i8x16_u",
        .@"i16x8.extend_high_i8x16_u",
        .@"i32x4.extend_low_i16x8_s",
        .@"i32x4.extend_high_i16x8_s",
        .@"i32x4.extend_low_i16x8_u",
        .@"i32x4.extend_high_i16x8_u",
        .@"i64x2.extend_low_i32x4_s",
        .@"i64x2.extend_high_i32x4_s",
        .@"i64x2.extend_low_i32x4_u",
        .@"i64x2.extend_high_i32x4_u",
        // 1 → 1: extadd_pairwise.
        .@"i16x8.extadd_pairwise_i8x16_s",
        .@"i16x8.extadd_pairwise_i8x16_u",
        .@"i32x4.extadd_pairwise_i16x8_s",
        .@"i32x4.extadd_pairwise_i16x8_u",
        // 1 → 1: FP convert / promote / demote / trunc_sat.
        .@"f32x4.convert_i32x4_s",
        .@"f32x4.convert_i32x4_u",
        .@"f64x2.convert_low_i32x4_s",
        .@"f64x2.convert_low_i32x4_u",
        .@"f64x2.promote_low_f32x4",
        .@"f32x4.demote_f64x2_zero",
        .@"i32x4.trunc_sat_f32x4_s",
        .@"i32x4.trunc_sat_f32x4_u",
        .@"i32x4.trunc_sat_f64x2_s_zero",
        .@"i32x4.trunc_sat_f64x2_u_zero",
        // 1 → 1: bitmask / all_true / any_true (pop v128, push i32).
        .@"v128.any_true",
        .@"i8x16.all_true",
        .@"i16x8.all_true",
        .@"i32x4.all_true",
        .@"i64x2.all_true",
        .@"i8x16.bitmask",
        .@"i16x8.bitmask",
        .@"i32x4.bitmask",
        .@"i64x2.bitmask",
        => .{ .pops = 1, .pushes = 1 },
        // 2 → 1: bitwise binop.
        .@"v128.and",
        .@"v128.or",
        .@"v128.xor",
        .@"v128.andnot",
        // 2 → 1: integer add/sub/mul.
        .@"i8x16.add",
        .@"i8x16.sub",
        .@"i16x8.add",
        .@"i16x8.sub",
        .@"i16x8.mul",
        .@"i32x4.add",
        .@"i32x4.sub",
        .@"i32x4.mul",
        .@"i64x2.add",
        .@"i64x2.sub",
        .@"i64x2.mul",
        // 2 → 1: saturating arith + avgr.
        .@"i8x16.add_sat_s",
        .@"i8x16.add_sat_u",
        .@"i8x16.sub_sat_s",
        .@"i8x16.sub_sat_u",
        .@"i16x8.add_sat_s",
        .@"i16x8.add_sat_u",
        .@"i16x8.sub_sat_s",
        .@"i16x8.sub_sat_u",
        .@"i8x16.avgr_u",
        .@"i16x8.avgr_u",
        // 2 → 1: min/max.
        .@"i8x16.min_s",
        .@"i8x16.min_u",
        .@"i8x16.max_s",
        .@"i8x16.max_u",
        .@"i16x8.min_s",
        .@"i16x8.min_u",
        .@"i16x8.max_s",
        .@"i16x8.max_u",
        .@"i32x4.min_s",
        .@"i32x4.min_u",
        .@"i32x4.max_s",
        .@"i32x4.max_u",
        // 2 → 1: int compare.
        .@"i8x16.eq",
        .@"i8x16.ne",
        .@"i8x16.lt_s",
        .@"i8x16.lt_u",
        .@"i8x16.gt_s",
        .@"i8x16.gt_u",
        .@"i8x16.le_s",
        .@"i8x16.le_u",
        .@"i8x16.ge_s",
        .@"i8x16.ge_u",
        .@"i16x8.eq",
        .@"i16x8.ne",
        .@"i16x8.lt_s",
        .@"i16x8.lt_u",
        .@"i16x8.gt_s",
        .@"i16x8.gt_u",
        .@"i16x8.le_s",
        .@"i16x8.le_u",
        .@"i16x8.ge_s",
        .@"i16x8.ge_u",
        .@"i32x4.eq",
        .@"i32x4.ne",
        .@"i32x4.lt_s",
        .@"i32x4.lt_u",
        .@"i32x4.gt_s",
        .@"i32x4.gt_u",
        .@"i32x4.le_s",
        .@"i32x4.le_u",
        .@"i32x4.ge_s",
        .@"i32x4.ge_u",
        .@"i64x2.eq",
        .@"i64x2.ne",
        .@"i64x2.lt_s",
        .@"i64x2.gt_s",
        .@"i64x2.le_s",
        .@"i64x2.ge_s",
        // 2 → 1: FP compare.
        .@"f32x4.eq",
        .@"f32x4.ne",
        .@"f32x4.lt",
        .@"f32x4.gt",
        .@"f32x4.le",
        .@"f32x4.ge",
        .@"f64x2.eq",
        .@"f64x2.ne",
        .@"f64x2.lt",
        .@"f64x2.gt",
        .@"f64x2.le",
        .@"f64x2.ge",
        // 2 → 1: FP arith.
        .@"f32x4.add",
        .@"f32x4.sub",
        .@"f32x4.mul",
        .@"f32x4.div",
        .@"f32x4.min",
        .@"f32x4.max",
        .@"f32x4.pmin",
        .@"f32x4.pmax",
        .@"f64x2.add",
        .@"f64x2.sub",
        .@"f64x2.mul",
        .@"f64x2.div",
        .@"f64x2.min",
        .@"f64x2.max",
        .@"f64x2.pmin",
        .@"f64x2.pmax",
        // 2 → 1: shifts (pop v128 + i32 count).
        .@"i8x16.shl",
        .@"i8x16.shr_s",
        .@"i8x16.shr_u",
        .@"i16x8.shl",
        .@"i16x8.shr_s",
        .@"i16x8.shr_u",
        .@"i32x4.shl",
        .@"i32x4.shr_s",
        .@"i32x4.shr_u",
        .@"i64x2.shl",
        .@"i64x2.shr_s",
        .@"i64x2.shr_u",
        // 2 → 1: shuffle (2 v128 + 16-byte imm) / swizzle.
        .@"i8x16.shuffle",
        .@"i8x16.swizzle",
        // 2 → 1: replace_lane (pop v128 + scalar; imm in payload).
        .@"i8x16.replace_lane",
        .@"i16x8.replace_lane",
        .@"i32x4.replace_lane",
        .@"i64x2.replace_lane",
        .@"f32x4.replace_lane",
        .@"f64x2.replace_lane",
        // 2 → 1: narrow saturating (2 v128 → 1 v128).
        .@"i8x16.narrow_i16x8_s",
        .@"i8x16.narrow_i16x8_u",
        .@"i16x8.narrow_i32x4_s",
        .@"i16x8.narrow_i32x4_u",
        // 2 → 1: ext multiply / dot / q15mulr.
        .@"i16x8.q15mulr_sat_s",
        .@"i32x4.dot_i16x8_s",
        .@"i16x8.extmul_low_i8x16_s",
        .@"i16x8.extmul_high_i8x16_s",
        .@"i16x8.extmul_low_i8x16_u",
        .@"i16x8.extmul_high_i8x16_u",
        .@"i32x4.extmul_low_i16x8_s",
        .@"i32x4.extmul_high_i16x8_s",
        .@"i32x4.extmul_low_i16x8_u",
        .@"i32x4.extmul_high_i16x8_u",
        .@"i64x2.extmul_low_i32x4_s",
        .@"i64x2.extmul_high_i32x4_s",
        .@"i64x2.extmul_low_i32x4_u",
        .@"i64x2.extmul_high_i32x4_u",
        => .{ .pops = 2, .pushes = 1 },
        // 3 → 1: bitselect (a, b, mask).
        .@"v128.bitselect" => .{ .pops = 3, .pushes = 1 },
        else => null,
    };
}

fn isControlFlow(op: ZirOp) bool {
    // After sub-7.5c-iv, every Wasm 1.0 control-flow op is
    // handled explicitly in `compute`. The function exists
    // only as documentation of the categories; nothing in the
    // analysis branches on it now.
    return switch (op) {
        .@"unreachable",
        .br,
        .br_if,
        .br_table,
        .@"return",
        .block,
        .loop,
        .@"if",
        .@"else",
        .end,
        .call,
        .call_indirect,
        => true,
        else => false,
    };
}

/// Compute per-vreg live ranges. Returns a `Liveness` whose
/// `ranges` slice the caller owns.
///
/// `func_sigs` indexes function signatures by func_idx; consulted
/// by `call N` to determine the pop/push count. `module_types`
/// indexes type signatures by typeidx; consulted by
/// `call_indirect type_idx`. Pass empty slices when the function
/// has no calls (the existing straight-line tests).
///
/// **Phase 7.5 scope**: extends Phase-5's straight-line MVP +
/// conversions + sat_trunc (sub-h5) with `call` + `call_indirect`.
/// Block-level control flow (block / loop / if / else / br / etc.)
/// still rejects; sub-7.5c-future widens this to structured-CFG-
/// aware analysis.
pub fn compute(
    allocator: Allocator,
    func: *const ZirFunc,
    func_sigs: []const zir.FuncType,
    module_types: []const zir.FuncType,
) Error!Liveness {
    var ranges: std.ArrayList(LiveRange) = .empty;
    errdefer ranges.deinit(allocator);

    var sim_stack: [max_simulated_stack]u32 = undefined;
    var sim_len: usize = 0;

    // Sub-7.5c-iv: after an unconditional branch (br / return /
    // unreachable) the rest of the block body is dead code per
    // Wasm's polymorphic-stack rule. Dead-code liveness does
    // nothing structurally — vregs that the dead region produces
    // would never reach a real consumer; their ranges stay
    // collapsed to a single pc by virtue of no later instr
    // popping them. So we don't track a separate dead flag
    // explicitly; the conservative pop-on-branch handling below
    // is enough.

    for (func.instrs.items, 0..) |instr, idx| {
        const pc: u32 = @intCast(idx);

        // The function-level `end` closes every still-live vreg.
        if (instr.op == .end) {
            const is_function_end = (idx + 1 == func.instrs.items.len);
            if (is_function_end) {
                while (sim_len > 0) {
                    sim_len -= 1;
                    const vreg = sim_stack[sim_len];
                    ranges.items[vreg].last_use_pc = pc;
                }
            }
            // Mid-function `end` (block/loop/if frame closer) is
            // transparent at the liveness level — values produced
            // inside the block stay on the operand stack and flow
            // naturally to the next consumer. The Wasm validator
            // already enforces stack-shape consistency at block
            // boundaries.
            continue;
        }

        // block / loop / else: structural markers, transparent.
        if (instr.op == .block or instr.op == .loop or instr.op == .@"else") {
            continue;
        }

        // if: pops the condition (1 operand), no push.
        // Tolerant pop: in dead code (after br / return /
        // unreachable drained sim_stack to 0), the cond pop is a
        // no-op. Validator already proved the stack shape; we
        // need not re-validate here.
        if (instr.op == .@"if") {
            if (sim_len > 0) {
                sim_len -= 1;
                const cond_vreg = sim_stack[sim_len];
                ranges.items[cond_vreg].last_use_pc = pc;
            }
            continue;
        }

        // Branches: conservative single-pass liveness.
        //   br N           — unconditional. Result values for
        //                     label N stay on the operand stack
        //                     at the target. For us: close every
        //                     vreg currently live (pessimistic;
        //                     forces spill if reused after target).
        //   br_if N        — pop 1 (condition); operand stack
        //                     otherwise unchanged (the K result
        //                     values for label N stay on stack
        //                     for both branch paths).
        //   br_table       — pop 1 (table index); same as br_if.
        //   return         — close all live vregs (function exits).
        //   unreachable    — trap; subsequent code dead.
        //
        // After unconditional branches the rest of the body is
        // dead per Wasm's polymorphic-stack rule. The Wasm
        // validator already accepts dead-code stack
        // arbitrariness; for liveness we just don't touch ranges
        // in that region. Implementation: continue iterating
        // until the matching `end` (the lowerer guarantees one
        // exists per Wasm validator rules); subsequent ops may
        // re-push fresh vregs they themselves define, which we
        // treat conservatively.
        if (instr.op == .br or instr.op == .@"return" or instr.op == .@"unreachable") {
            while (sim_len > 0) {
                sim_len -= 1;
                const vreg = sim_stack[sim_len];
                ranges.items[vreg].last_use_pc = pc;
            }
            continue;
        }
        if (instr.op == .br_if or instr.op == .br_table) {
            // Tolerant pop (see if-handler above for rationale).
            if (sim_len > 0) {
                sim_len -= 1;
                const cond_vreg = sim_stack[sim_len];
                ranges.items[cond_vreg].last_use_pc = pc;
            }
            continue;
        }

        // D-093 (d-3): `local.tee` is operand-stack-transparent.
        // The per-arch emit doesn't pop or push — it STRs the
        // top vreg's register into the local slot and leaves the
        // vreg on the operand stack. The generic stackEffect
        // (.pops=1, .pushes=1) path would close the original
        // vreg's range AND fabricate a fresh vreg, opening a
        // window where the original vreg's slot can be reused
        // by a subsequent push (e.g. the right-hand operand of
        // an i32.add). Wasm spec §4.4.5.3 — local.tee is "set
        // and propagate"; the propagation IS the same value.
        //
        // Pre-d-3 surfaced as the `local_tee` cluster (8 spec
        // failures: `as-binary-left` got 20 expected 13 = `op1 +
        // op1` because the right-hand vreg was given the
        // closed-vreg's slot, clobbering op1 before the add
        // read it).
        if (instr.op == .@"local.tee") {
            if (sim_len > 0) {
                const top_vreg = sim_stack[sim_len - 1];
                ranges.items[top_vreg].last_use_pc = pc;
            }
            continue;
        }

        // call / call_indirect: pop callee-sig.params, push callee-sig.results.
        if (instr.op == .call or instr.op == .call_indirect) {
            const callee_sig: zir.FuncType = blk: {
                if (instr.op == .call) {
                    if (instr.payload >= func_sigs.len) {
                        std.debug.print("liveness: UnsupportedOp[call-payload-OOB] payload={d} func_sigs.len={d} func_idx={d}\n", .{ instr.payload, func_sigs.len, func.func_idx });
                        return Error.UnsupportedOp;
                    }
                    break :blk func_sigs[instr.payload];
                } else {
                    if (instr.payload >= module_types.len) {
                        std.debug.print("liveness: UnsupportedOp[call_indirect-payload-OOB] payload={d} types.len={d} func_idx={d}\n", .{ instr.payload, module_types.len, func.func_idx });
                        return Error.UnsupportedOp;
                    }
                    break :blk module_types[instr.payload];
                }
            };
            // call_indirect's stack at entry is [args..., idx]; pop idx first.
            // Tolerant: dead-code pops are no-ops (validator proved
            // shape).
            if (instr.op == .call_indirect) {
                if (sim_len > 0) {
                    sim_len -= 1;
                    const idx_vreg = sim_stack[sim_len];
                    ranges.items[idx_vreg].last_use_pc = pc;
                }
            }
            // Pop N args (in reverse stack order). Best-effort:
            // pop only as many as actually present.
            const n_args: usize = callee_sig.params.len;
            var ai: usize = 0;
            while (ai < n_args and sim_len > 0) : (ai += 1) {
                sim_len -= 1;
                const arg_vreg = sim_stack[sim_len];
                ranges.items[arg_vreg].last_use_pc = pc;
            }
            // Push results.
            for (callee_sig.results) |_| {
                const vreg: u32 = @intCast(ranges.items.len);
                try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
                if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
                sim_stack[sim_len] = vreg;
                sim_len += 1;
            }
            continue;
        }

        if (isControlFlow(instr.op)) return Error.UnsupportedControlFlow;

        const eff = stackEffect(instr.op) orelse {
            std.debug.print("liveness: UnsupportedOp[stackEffect-missing] op={s} func_idx={d}\n", .{ @tagName(instr.op), func.func_idx });
            return Error.UnsupportedOp;
        };

        // Pop side first — record last_use for each vreg
        // consumed. Best-effort: in dead code (validator-cleared,
        // post-br/unreachable region), pops silently no-op.
        var i: u8 = 0;
        while (i < eff.pops and sim_len > 0) : (i += 1) {
            sim_len -= 1;
            const vreg = sim_stack[sim_len];
            ranges.items[vreg].last_use_pc = pc;
        }

        // Push side — open a fresh vreg per produced value.
        i = 0;
        while (i < eff.pushes) : (i += 1) {
            const vreg: u32 = @intCast(ranges.items.len);
            try ranges.append(allocator, .{ .def_pc = pc, .last_use_pc = pc });
            if (sim_len == max_simulated_stack) return Error.OperandStackUnderflow;
            sim_stack[sim_len] = vreg;
            sim_len += 1;
        }
    }

    return .{ .ranges = try ranges.toOwnedSlice(allocator) };
}

pub fn deinit(allocator: Allocator, info: Liveness) void {
    if (info.ranges.len != 0) allocator.free(info.ranges);
}

const testing = std.testing;

fn buildFunc(allocator: Allocator, ops: []const ZirInstr) !ZirFunc {
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    errdefer f.deinit(allocator);
    for (ops) |o| try f.instrs.append(allocator, o);
    return f;
}

test "compute: straight-line i32.const + i32.const + i32.add + drop + end" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.add" },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 3), live.ranges.len);
    // vreg 0: pushed at pc 0, consumed by add at pc 2.
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[0].last_use_pc);
    // vreg 1: pushed at pc 1, consumed by add at pc 2.
    try testing.expectEqual(@as(u32, 1), live.ranges[1].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[1].last_use_pc);
    // vreg 2: produced by add at pc 2, consumed by drop at pc 3.
    try testing.expectEqual(@as(u32, 2), live.ranges[2].def_pc);
    try testing.expectEqual(@as(u32, 3), live.ranges[2].last_use_pc);
}

test "compute: function-level end closes the still-live vreg" {
    // i32.const 7 ; end -> vreg 0 def=0 last_use=1 (closed by end)
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 7 },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 1), live.ranges[0].last_use_pc);
}

test "compute: D-093 (d-3) local.tee keeps the input vreg alive across the tee" {
    // local.get 0 ; local.tee 1 ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"local.get", .payload = 0 },
        .{ .op = .@"local.tee", .payload = 1 },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    // local.tee is operand-stack-transparent (matches emit's
    // "STR top → local slot, no pop/push" semantics). Only one
    // vreg exists across local.get → local.tee → drop; its
    // last_use_pc extends from the tee through to the drop.
    // Pre-d-3 there were 2 vregs (local.tee fabricated a fresh
    // push); the original vreg's slot got reused by subsequent
    // pushes (the local_tee cluster bug).
    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 0), live.ranges[0].def_pc);
    try testing.expectEqual(@as(u32, 2), live.ranges[0].last_use_pc);
}

test "compute: br closes all live vregs at branch site (sub-7.5c-iv)" {
    // (i32.const 1) (br) (end) — `br` is now handled, not rejected.
    // The const's vreg should have last_use_pc == br's pc.
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .br },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer testing.allocator.free(live.ranges);
    try testing.expectEqual(@as(usize, 1), live.ranges.len);
    try testing.expectEqual(@as(u32, 1), live.ranges[0].last_use_pc); // br at pc=1
}

test "compute: pop on empty stack is tolerant (validator-cleared dead-code path)" {
    // Liveness trusts the validator's prior pass for stack-shape
    // validity. A pop on an empty stack — only reachable via the
    // dead-code zone after an unconditional branch — is a no-op
    // here, not an error. See §9.7 / 7.5-block-result-deadcode.
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer testing.allocator.free(live.ranges);
    try testing.expectEqual(@as(usize, 0), live.ranges.len);
}

test "compute: dead code after `br 0` does not underflow" {
    // Real-world repro from spec/wasm-1.0/labels.0.wasm:
    //   block (result i32) i32.const 1 ; br 0 ; i32.const 0 end
    // After `br 0` the stack drains; `i32.const 0` (dead code)
    // pushes a fresh vreg. The matching `end` is the
    // function-level end (block / function share `end` op since
    // the block-result path collapses).
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .block },
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .br, .payload = 0 },
        .{ .op = .@"i32.const", .payload = 0 },
        .{ .op = .end },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    // Should compute successfully — no underflow on the dead
    // i32.const after the br.
    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer testing.allocator.free(live.ranges);
    // Two i32.const pushes → 2 vreg ranges.
    try testing.expectEqual(@as(usize, 2), live.ranges.len);
}

test "compute: select consumes 3 vregs and produces 1" {
    // i32.const 1 ; i32.const 2 ; i32.const 0 ; select ; drop ; end
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 1 },
        .{ .op = .@"i32.const", .payload = 2 },
        .{ .op = .@"i32.const", .payload = 0 },
        .{ .op = .select },
        .{ .op = .drop },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    const live = try compute(testing.allocator, &f, &.{}, &.{});
    defer deinit(testing.allocator, live);

    try testing.expectEqual(@as(usize, 4), live.ranges.len);
    // The three operands all close at pc 3 (select), and select's
    // result vreg lives until drop at pc 4.
    for (live.ranges[0..3]) |r| {
        try testing.expectEqual(@as(u32, 3), r.last_use_pc);
    }
    try testing.expectEqual(@as(u32, 3), live.ranges[3].def_pc);
    try testing.expectEqual(@as(u32, 4), live.ranges[3].last_use_pc);
}

test "compute: install onto ZirFunc.liveness slot round-trips" {
    var f = try buildFunc(testing.allocator, &.{
        .{ .op = .@"i32.const", .payload = 5 },
        .{ .op = .end },
    });
    defer f.deinit(testing.allocator);

    f.liveness = try compute(testing.allocator, &f, &.{}, &.{});
    defer if (f.liveness) |li| deinit(testing.allocator, li);

    try testing.expect(f.liveness != null);
    try testing.expectEqual(@as(usize, 1), f.liveness.?.ranges.len);
}
