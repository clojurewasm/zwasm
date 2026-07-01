//! Per-vreg storage class classifier — extracted from `regalloc.zig`
//! per ADR-0092 (D-097 / d-17 origin).
//!
//! `VregClass = enum { gpr, fpr, v128 }` + `vregClassByDef` (walks
//! `func.instrs` to find the def-site op of a target vreg) +
//! `vregClassOfOp` (pure per-op classifier — large `switch (ins.op)`).
//! Pure top-level fns, no methods, no state. Re-exported by
//! `regalloc.zig` so callers reach `regalloc.VregClass` /
//! `regalloc.vregClassByDef` unchanged.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const zir = @import("../../../ir/zir.zig");
const ZirFunc = zir.ZirFunc;

/// D-097 / d-17: classify a vreg's storage class (GPR / FPR / v128)
/// by walking `func.instrs.items`, counting pushed vregs in
/// liveness order, and inspecting the op (or local valtype for
/// `local.get`) that defined the target vreg.
///
/// Used by the if-frame merge MOV path in `op_control.zig` to
/// dispatch FP-class merges through FMOV / MOVAPS instead of the
/// GPR MOV that silently corrupts f32/f64 values. The merge
/// MOV's pre-d-17 shape only dispatched on `.v128` shape_tag;
/// FP scalar (f32/f64) fell through to the GPR path and never
/// transferred the value through the FP register file.
///
/// Returns `.gpr` as the conservative default for vregs whose
/// origin couldn't be determined (e.g. malformed instr stream);
/// the merge MOV is then no worse than pre-d-17 for that vreg.
pub const VregClass = enum { gpr, fpr, v128 };

pub fn vregClassByDef(func: *const ZirFunc, target_vreg: usize) VregClass {
    var next_vreg: usize = 0;
    for (func.instrs.items) |ins| {
        const class_or_null: ?VregClass = vregClassOfOp(ins, func);
        const c = class_or_null orelse continue;
        if (next_vreg == target_vreg) return c;
        next_vreg += 1;
    }
    return .gpr;
}

/// Returns the storage class of the vreg the op pushes, or `null`
/// when the op doesn't push a result. v128 ops + FP-scalar ops are
/// enumerated; everything else defaults to `.gpr` (the existing
/// pre-d-17 merge-MOV path). The full SIMD producer list lives in
/// `populateShapeTags`; this function keeps the v128 branch
/// minimal (`zir.isSimdZirOp`) because the merge MOV's v128 path
/// is already covered via `shape_tags`.
fn vregClassOfOp(ins: zir.ZirInstr, func: *const ZirFunc) ?VregClass {
    return switch (ins.op) {
        // FP-producing scalar ops.
        .@"f32.const",
        .@"f32.abs",
        .@"f32.neg",
        .@"f32.ceil",
        .@"f32.floor",
        .@"f32.trunc",
        .@"f32.nearest",
        .@"f32.sqrt",
        .@"f32.add",
        .@"f32.sub",
        .@"f32.mul",
        .@"f32.div",
        .@"f32.min",
        .@"f32.max",
        .@"f32.copysign",
        .@"f64.const",
        .@"f64.abs",
        .@"f64.neg",
        .@"f64.ceil",
        .@"f64.floor",
        .@"f64.trunc",
        .@"f64.nearest",
        .@"f64.sqrt",
        .@"f64.add",
        .@"f64.sub",
        .@"f64.mul",
        .@"f64.div",
        .@"f64.min",
        .@"f64.max",
        .@"f64.copysign",
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
        .@"f32.reinterpret_i32",
        .@"f64.reinterpret_i64",
        .@"f32.load",
        .@"f64.load",
        => .fpr,
        // local.get: from local valtype.
        .@"local.get" => switch (func.localValType(@intCast(ins.payload))) {
            .f32, .f64 => VregClass.fpr,
            .v128 => VregClass.v128,
            .i32, .i64, .ref => VregClass.gpr,
        },
        // GC-on-JIT (D-212) — struct.get / array.get of an f32/f64
        // field/element produce an FP-class result. Without this the
        // GPR-class default leaves the value in a GPR while the f32
        // consumer (function return / call) reads the FP home → stale
        // V0/XMM0. struct.get_s/get_u are i32-only (packed extend) → gpr.
        // 0x7D = f32, 0x7C = f64 (ValType.specByte / §5.3).
        .@"struct.get" => switch (func.structFieldValType(@intCast(ins.payload), ins.extra)) {
            0x7D, 0x7C => VregClass.fpr,
            0x7B => VregClass.v128, // D-460: v128 field → 16-byte Q-class result.
            else => VregClass.gpr,
        },
        .@"array.get" => switch (func.arrayElemValType(@intCast(ins.payload))) {
            0x7D, 0x7C => VregClass.fpr,
            0x7B => VregClass.v128, // D-460: v128 element → 16-byte Q-class result.
            else => VregClass.gpr,
        },
        // Ops that don't push (advance the vreg counter).
        .@"local.tee",
        .end,
        .@"else",
        .block,
        .loop,
        .@"if",
        .br,
        .br_if,
        .br_table,
        .@"return",
        .@"unreachable",
        .nop,
        .drop,
        .@"local.set",
        .@"global.set",
        .@"memory.fill",
        .@"memory.copy",
        .@"memory.init",
        .@"data.drop",
        .@"table.copy",
        .@"table.init",
        .@"elem.drop",
        .@"table.set",
        .@"v128.store",
        .@"v128.store8_lane",
        .@"v128.store16_lane",
        .@"v128.store32_lane",
        .@"v128.store64_lane",
        .@"i32.store",
        .@"i64.store",
        .@"f32.store",
        .@"f64.store",
        .@"i32.store8",
        .@"i32.store16",
        .@"i64.store8",
        .@"i64.store16",
        .@"i64.store32",
        => null,
        // Default: GPR (covers i32 / i64 const + binops + compares,
        // i32.* / i64.* ops, ref ops, table.get GPR-result).
        else => .gpr,
    };
}
