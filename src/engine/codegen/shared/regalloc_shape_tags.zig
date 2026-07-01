//! populateShapeTags — extracted from `regalloc.zig` per ADR-0090.
//!
//! Pure top-level helper (no methods, no state): given a
//! `ZirFunc`, walks its op stream + signature to produce a
//! per-vreg `[]ShapeTag` array consumed by the v128-aware emit
//! dispatch. Re-exported by `regalloc.zig` so the single external
//! caller (`engine/codegen/x86_64/op_simd.zig`) continues to
//! reach `regalloc.populateShapeTags` unchanged.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const zir = @import("../../../ir/zir.zig");
const liveness = @import("../../../ir/analysis/liveness.zig");
const regalloc = @import("regalloc.zig");

const ZirFunc = zir.ZirFunc;
const ShapeTag = regalloc.ShapeTag;
const Error = regalloc.Error;

/// Populate `Allocation.shape_tags` for a function whose
/// `func.instrs` contains SIMD-128 ZirOps OR whose signature /
/// locals declare v128 (per ADR-0041 §"Decision" /
/// 2). Walks the instr stream once mirroring liveness's
/// def-order vreg numbering (each push increments `next_vreg`);
/// the produced vreg's tag is determined by the op:
///
/// - `local.get` / `local.tee`: tag = `func.localValType(payload)`
///   (v128 if the local was declared with valtype 0x7B).
/// - SIMD-producing ops (per the explicit list below): `.v128`.
/// - All other producers: `.scalar` (the @memset default), with
///   the push count taken from `liveness.stackEffect` for
///   accurate vreg-id counting.
///
/// The any_simd trigger expands to v128 in
/// `func.sig.params`/`results` and `func.locals` so a function
/// whose body is `local.get v128; local.get v128; local.get i32;
/// select` (the `simd_select.0` fixture's shape — D-061
/// discharge) still produces shape_tags, allowing the v128-aware
/// emit dispatch to fire on the local.get-pushed vregs.
///
/// Returns a freshly-allocated slice; caller stores in
/// `alloc.shape_tags` and pairs free with `regalloc.deinit`.
/// Returns `null` when no v128 indicators are present — the
/// caller treats that as all-scalar.
pub fn populateShapeTags(allocator: Allocator, func: *const ZirFunc, n_vregs: usize) Error!?[]ShapeTag {
    // Quick bail: trigger when any v128 indicator is present —
    // a SIMD ZirOp in the body OR a v128-typed param / local /
    // result. The `local.get v128 / select` shape (no inline
    // SIMD op) needs the latter trigger or it would silently
    // fall back to all-scalar shape_tags.
    var any_simd: bool = false;
    for (func.instrs.items) |ins| {
        if (zir.isSimdZirOp(ins.op)) {
            any_simd = true;
            break;
        }
    }
    if (!any_simd) {
        for (func.sig.params) |p| if (p == .v128) {
            any_simd = true;
            break;
        };
    }
    if (!any_simd) {
        for (func.sig.results) |r| if (r == .v128) {
            any_simd = true;
            break;
        };
    }
    if (!any_simd) {
        for (func.locals) |l| if (l == .v128) {
            any_simd = true;
            break;
        };
    }
    if (!any_simd) return null;

    const tags = try allocator.alloc(ShapeTag, n_vregs);
    errdefer allocator.free(tags);
    @memset(tags, .scalar);

    // Walk instrs mirroring liveness.compute's def-order vreg
    // numbering (each push increments next_vreg, and the produced
    // vreg gets a per-op shape tag).
    var next_vreg: usize = 0;
    for (func.instrs.items) |ins| {
        // local.get pushes one vreg whose type comes from the
        // indexed local. v128 locals (params / declared locals)
        // flow through here; D-061 discharge.
        if (ins.op == .@"local.get") {
            if (next_vreg < tags.len) {
                if (func.localValType(@intCast(ins.payload)) == .v128) tags[next_vreg] = .v128;
            }
            next_vreg += 1;
            continue;
        }
        // local.tee — operand-stack-transparent (see
        // liveness.zig `local.tee` arm in compute()). No new
        // vreg; the existing top vreg keeps its shape tag.
        if (ins.op == .@"local.tee") continue;
        // Per ADR-0041 §"Decision" / 1: extract_lane ops produce
        // scalar (i32 / i64 / f32 / f64) from v128. v128.const +
        // v128.load* / splat / binop / unop / shuffle / swizzle
        // produce v128.
        const is_simd_producer: bool = switch (ins.op) {
            .@"v128.const",
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
            // load_lane: pop idx + v128, push merged v128.
            .@"v128.load8_lane",
            .@"v128.load16_lane",
            .@"v128.load32_lane",
            .@"v128.load64_lane",
            .@"v128.not",
            .@"v128.and",
            .@"v128.or",
            .@"v128.xor",
            .@"v128.andnot",
            .@"v128.bitselect",
            .@"i16x8.shl",
            .@"i16x8.shr_s",
            .@"i16x8.shr_u",
            .@"i32x4.shl",
            .@"i32x4.shr_s",
            .@"i32x4.shr_u",
            .@"i64x2.shl",
            .@"i64x2.shr_u",
            .@"i64x2.shr_s",
            .@"i8x16.shl",
            .@"i8x16.shr_u",
            .@"i8x16.shr_s",
            .@"i8x16.abs",
            .@"i16x8.abs",
            .@"i32x4.abs",
            .@"i64x2.abs",
            .@"i8x16.neg",
            .@"i16x8.neg",
            .@"i32x4.neg",
            .@"i64x2.neg",
            .@"i8x16.splat",
            .@"i16x8.splat",
            .@"i32x4.splat",
            .@"i64x2.splat",
            .@"f32x4.splat",
            .@"f64x2.splat",
            .@"i8x16.shuffle",
            .@"i8x16.swizzle",
            .@"i8x16.add",
            .@"i8x16.sub",
            .@"i16x8.add",
            .@"i16x8.sub",
            .@"i16x8.mul",
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
            .@"i16x8.extadd_pairwise_i8x16_s",
            .@"i16x8.extadd_pairwise_i8x16_u",
            .@"i32x4.extadd_pairwise_i16x8_s",
            .@"i32x4.extadd_pairwise_i16x8_u",
            .@"i8x16.popcnt",
            .@"i32x4.add",
            .@"i32x4.sub",
            .@"i32x4.mul",
            .@"i64x2.add",
            .@"i64x2.sub",
            .@"i64x2.mul",
            .@"f32x4.add",
            .@"f32x4.sub",
            .@"f32x4.mul",
            .@"f32x4.div",
            .@"f64x2.add",
            .@"f64x2.sub",
            .@"f64x2.mul",
            .@"f64x2.div",
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
            .@"f32x4.min",
            .@"f32x4.max",
            .@"f64x2.min",
            .@"f64x2.max",
            .@"f32x4.pmin",
            .@"f32x4.pmax",
            .@"f64x2.pmin",
            .@"f64x2.pmax",
            // Int min/max + sat arith + avgr_u (22 ops, all 2-in 1-out v128).
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
            .@"i8x16.narrow_i16x8_s",
            .@"i8x16.narrow_i16x8_u",
            .@"i16x8.narrow_i32x4_s",
            .@"i16x8.narrow_i32x4_u",
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
            .@"i8x16.replace_lane",
            .@"i16x8.replace_lane",
            .@"i32x4.replace_lane",
            .@"i64x2.replace_lane",
            .@"f32x4.replace_lane",
            .@"f64x2.replace_lane",
            => true,
            else => false,
        };
        if (is_simd_producer) {
            if (next_vreg < tags.len) tags[next_vreg] = .v128;
            next_vreg += 1;
            continue;
        }
        // All other producers: tag stays `.scalar` (memset
        // default); push count comes from `liveness.stackEffect`.
        // stackEffect returns null for control-flow ops
        // (block / loop / if / else / end / br / br_if /
        // br_table / return / unreachable) and for call /
        // call_indirect — both of which need different handling
        // in liveness.compute. Control-flow ops do not push;
        // call / call_indirect's variadic-results push count
        // would require func_sigs / module_types threading and
        // is deferred (call-with-v128-result fixtures aren't in
        // scope).
        if (liveness.stackEffect(ins.op)) |eff| {
            next_vreg += eff.pushes;
        }
    }

    return tags;
}
