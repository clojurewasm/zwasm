//! ZIR (Zwasm Intermediate Representation) — container types only.
//!
//! Phase 1 / task 1.1 declares the **type identities** required by
//! ROADMAP §4.2's `ZirFunc` pseudocode. Per ROADMAP §P13 ("type
//! up-front, slots over flags") every `?T` analysis / regalloc /
//! optimisation slot is reserved day 1; later phases populate the
//! fields without touching the struct shape (the W54 lesson —
//! see `~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md`).
//!
//! `ZirOp` itself is an open enum here; task 1.2 declares the full
//! Wasm 3.0 + JIT pseudo-op catalogue per ROADMAP §4.2.
//!
//! Zone 1 (`src/ir/`) — may import Zone 0 only. No upward imports.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ValType = enum(u8) {
    i32,
    i64,
    f32,
    f64,
    v128,
    funcref,
    externref,
};

pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// Module table entry (Wasm 2.0 §9.2 / 2.3 chunk 5c). Carries
/// only the static metadata the validator needs; the runtime
/// counterpart `TableInstance` (in `interp/mod.zig`) holds the
/// actual reference values.
pub const TableEntry = struct {
    elem_type: ValType,
    min: u32,
    max: ?u32 = null,
};

pub const BlockKind = enum(u8) {
    block,
    loop,
    if_then,
    else_open,
};

pub const BlockInfo = struct {
    kind: BlockKind,
    start_inst: u32,
    end_inst: u32,
    /// Position of the matching `else` opcode for `if` frames that
    /// have one. The interp routes `if cond=0` to `else_inst + 1`
    /// or, when `null`, to `end_inst + 1`. Set by the lowerer on
    /// `else` emission; remains `null` for plain blocks / loops /
    /// if-without-else.
    else_inst: ?u32 = null,
};

pub const ZirOp = enum(u16) {
    // ============================================================
    // Wasm 1.0 / MVP (the baseline)
    // ============================================================
    // control flow
    @"unreachable",
    @"nop",
    @"block",
    @"loop",
    @"if",
    @"else",
    @"end",
    @"br",
    @"br_if",
    @"br_table",
    @"return",
    @"call",
    @"call_indirect",

    // parametric
    @"drop",
    @"select",
    @"select_typed",

    // variable
    @"local.get",
    @"local.set",
    @"local.tee",
    @"global.get",
    @"global.set",

    // i32 const + arith + bit + cmp
    @"i32.const",
    @"i32.eqz", @"i32.eq", @"i32.ne",
    @"i32.lt_s", @"i32.lt_u", @"i32.gt_s", @"i32.gt_u",
    @"i32.le_s", @"i32.le_u", @"i32.ge_s", @"i32.ge_u",
    @"i32.clz", @"i32.ctz", @"i32.popcnt",
    @"i32.add", @"i32.sub", @"i32.mul",
    @"i32.div_s", @"i32.div_u", @"i32.rem_s", @"i32.rem_u",
    @"i32.and", @"i32.or", @"i32.xor",
    @"i32.shl", @"i32.shr_s", @"i32.shr_u", @"i32.rotl", @"i32.rotr",

    // i64 const + arith + bit + cmp
    @"i64.const",
    @"i64.eqz", @"i64.eq", @"i64.ne",
    @"i64.lt_s", @"i64.lt_u", @"i64.gt_s", @"i64.gt_u",
    @"i64.le_s", @"i64.le_u", @"i64.ge_s", @"i64.ge_u",
    @"i64.clz", @"i64.ctz", @"i64.popcnt",
    @"i64.add", @"i64.sub", @"i64.mul",
    @"i64.div_s", @"i64.div_u", @"i64.rem_s", @"i64.rem_u",
    @"i64.and", @"i64.or", @"i64.xor",
    @"i64.shl", @"i64.shr_s", @"i64.shr_u", @"i64.rotl", @"i64.rotr",

    // f32 const + arith + cmp
    @"f32.const",
    @"f32.eq", @"f32.ne", @"f32.lt", @"f32.gt", @"f32.le", @"f32.ge",
    @"f32.abs", @"f32.neg", @"f32.ceil", @"f32.floor", @"f32.trunc", @"f32.nearest", @"f32.sqrt",
    @"f32.add", @"f32.sub", @"f32.mul", @"f32.div", @"f32.min", @"f32.max", @"f32.copysign",

    // f64 const + arith + cmp
    @"f64.const",
    @"f64.eq", @"f64.ne", @"f64.lt", @"f64.gt", @"f64.le", @"f64.ge",
    @"f64.abs", @"f64.neg", @"f64.ceil", @"f64.floor", @"f64.trunc", @"f64.nearest", @"f64.sqrt",
    @"f64.add", @"f64.sub", @"f64.mul", @"f64.div", @"f64.min", @"f64.max", @"f64.copysign",

    // numeric conversion
    @"i32.wrap_i64",
    @"i32.trunc_f32_s", @"i32.trunc_f32_u",
    @"i32.trunc_f64_s", @"i32.trunc_f64_u",
    @"i64.extend_i32_s", @"i64.extend_i32_u",
    @"i64.trunc_f32_s", @"i64.trunc_f32_u",
    @"i64.trunc_f64_s", @"i64.trunc_f64_u",
    @"f32.convert_i32_s", @"f32.convert_i32_u",
    @"f32.convert_i64_s", @"f32.convert_i64_u",
    @"f32.demote_f64",
    @"f64.convert_i32_s", @"f64.convert_i32_u",
    @"f64.convert_i64_s", @"f64.convert_i64_u",
    @"f64.promote_f32",
    @"i32.reinterpret_f32",
    @"i64.reinterpret_f64",
    @"f32.reinterpret_i32",
    @"f64.reinterpret_i64",

    // memory load / store (i32 / i64 / f32 / f64)
    @"i32.load", @"i64.load", @"f32.load", @"f64.load",
    @"i32.load8_s", @"i32.load8_u", @"i32.load16_s", @"i32.load16_u",
    @"i64.load8_s", @"i64.load8_u", @"i64.load16_s", @"i64.load16_u",
    @"i64.load32_s", @"i64.load32_u",
    @"i32.store", @"i64.store", @"f32.store", @"f64.store",
    @"i32.store8", @"i32.store16",
    @"i64.store8", @"i64.store16", @"i64.store32",
    @"memory.size", @"memory.grow",

    // ============================================================
    // Wasm 2.0 additions
    // ============================================================
    // sign extension
    @"i32.extend8_s", @"i32.extend16_s",
    @"i64.extend8_s", @"i64.extend16_s", @"i64.extend32_s",

    // saturating truncation
    @"i32.trunc_sat_f32_s", @"i32.trunc_sat_f32_u",
    @"i32.trunc_sat_f64_s", @"i32.trunc_sat_f64_u",
    @"i64.trunc_sat_f32_s", @"i64.trunc_sat_f32_u",
    @"i64.trunc_sat_f64_s", @"i64.trunc_sat_f64_u",

    // bulk memory
    @"memory.copy", @"memory.fill", @"memory.init",
    @"data.drop",
    @"table.copy", @"table.init",
    @"elem.drop",

    // reference types
    @"ref.null", @"ref.is_null", @"ref.func",
    @"table.get", @"table.set", @"table.size", @"table.grow", @"table.fill",

    // ============================================================
    // Wasm 2.0: SIMD-128
    // ============================================================
    // load / store
    @"v128.load", @"v128.store",
    @"v128.load8x8_s", @"v128.load8x8_u",
    @"v128.load16x4_s", @"v128.load16x4_u",
    @"v128.load32x2_s", @"v128.load32x2_u",
    @"v128.load8_splat", @"v128.load16_splat", @"v128.load32_splat", @"v128.load64_splat",
    @"v128.load32_zero", @"v128.load64_zero",
    @"v128.load8_lane", @"v128.load16_lane", @"v128.load32_lane", @"v128.load64_lane",
    @"v128.store8_lane", @"v128.store16_lane", @"v128.store32_lane", @"v128.store64_lane",

    // const / shuffle / lane
    @"v128.const",
    @"i8x16.shuffle", @"i8x16.swizzle",
    @"i8x16.splat", @"i16x8.splat", @"i32x4.splat", @"i64x2.splat",
    @"f32x4.splat", @"f64x2.splat",
    @"i8x16.extract_lane_s", @"i8x16.extract_lane_u", @"i8x16.replace_lane",
    @"i16x8.extract_lane_s", @"i16x8.extract_lane_u", @"i16x8.replace_lane",
    @"i32x4.extract_lane", @"i32x4.replace_lane",
    @"i64x2.extract_lane", @"i64x2.replace_lane",
    @"f32x4.extract_lane", @"f32x4.replace_lane",
    @"f64x2.extract_lane", @"f64x2.replace_lane",

    // i8x16 cmp + arith + bit
    @"i8x16.eq", @"i8x16.ne",
    @"i8x16.lt_s", @"i8x16.lt_u", @"i8x16.gt_s", @"i8x16.gt_u",
    @"i8x16.le_s", @"i8x16.le_u", @"i8x16.ge_s", @"i8x16.ge_u",
    @"i8x16.abs", @"i8x16.neg", @"i8x16.popcnt",
    @"i8x16.all_true", @"i8x16.bitmask",
    @"i8x16.narrow_i16x8_s", @"i8x16.narrow_i16x8_u",
    @"i8x16.shl", @"i8x16.shr_s", @"i8x16.shr_u",
    @"i8x16.add", @"i8x16.add_sat_s", @"i8x16.add_sat_u",
    @"i8x16.sub", @"i8x16.sub_sat_s", @"i8x16.sub_sat_u",
    @"i8x16.min_s", @"i8x16.min_u", @"i8x16.max_s", @"i8x16.max_u",
    @"i8x16.avgr_u",

    // i16x8 cmp + arith + bit
    @"i16x8.eq", @"i16x8.ne",
    @"i16x8.lt_s", @"i16x8.lt_u", @"i16x8.gt_s", @"i16x8.gt_u",
    @"i16x8.le_s", @"i16x8.le_u", @"i16x8.ge_s", @"i16x8.ge_u",
    @"i16x8.abs", @"i16x8.neg",
    @"i16x8.q15mulr_sat_s",
    @"i16x8.all_true", @"i16x8.bitmask",
    @"i16x8.narrow_i32x4_s", @"i16x8.narrow_i32x4_u",
    @"i16x8.extend_low_i8x16_s", @"i16x8.extend_high_i8x16_s",
    @"i16x8.extend_low_i8x16_u", @"i16x8.extend_high_i8x16_u",
    @"i16x8.shl", @"i16x8.shr_s", @"i16x8.shr_u",
    @"i16x8.add", @"i16x8.add_sat_s", @"i16x8.add_sat_u",
    @"i16x8.sub", @"i16x8.sub_sat_s", @"i16x8.sub_sat_u",
    @"i16x8.mul",
    @"i16x8.min_s", @"i16x8.min_u", @"i16x8.max_s", @"i16x8.max_u",
    @"i16x8.avgr_u",
    @"i16x8.extmul_low_i8x16_s", @"i16x8.extmul_high_i8x16_s",
    @"i16x8.extmul_low_i8x16_u", @"i16x8.extmul_high_i8x16_u",

    // i32x4 cmp + arith + bit
    @"i32x4.eq", @"i32x4.ne",
    @"i32x4.lt_s", @"i32x4.lt_u", @"i32x4.gt_s", @"i32x4.gt_u",
    @"i32x4.le_s", @"i32x4.le_u", @"i32x4.ge_s", @"i32x4.ge_u",
    @"i32x4.abs", @"i32x4.neg",
    @"i32x4.all_true", @"i32x4.bitmask",
    @"i32x4.extend_low_i16x8_s", @"i32x4.extend_high_i16x8_s",
    @"i32x4.extend_low_i16x8_u", @"i32x4.extend_high_i16x8_u",
    @"i32x4.shl", @"i32x4.shr_s", @"i32x4.shr_u",
    @"i32x4.add", @"i32x4.sub", @"i32x4.mul",
    @"i32x4.min_s", @"i32x4.min_u", @"i32x4.max_s", @"i32x4.max_u",
    @"i32x4.dot_i16x8_s",
    @"i32x4.extmul_low_i16x8_s", @"i32x4.extmul_high_i16x8_s",
    @"i32x4.extmul_low_i16x8_u", @"i32x4.extmul_high_i16x8_u",
    @"i32x4.trunc_sat_f32x4_s", @"i32x4.trunc_sat_f32x4_u",
    @"i32x4.trunc_sat_f64x2_s_zero", @"i32x4.trunc_sat_f64x2_u_zero",

    // i64x2 cmp + arith + bit
    @"i64x2.eq", @"i64x2.ne",
    @"i64x2.lt_s", @"i64x2.gt_s", @"i64x2.le_s", @"i64x2.ge_s",
    @"i64x2.abs", @"i64x2.neg",
    @"i64x2.all_true", @"i64x2.bitmask",
    @"i64x2.extend_low_i32x4_s", @"i64x2.extend_high_i32x4_s",
    @"i64x2.extend_low_i32x4_u", @"i64x2.extend_high_i32x4_u",
    @"i64x2.shl", @"i64x2.shr_s", @"i64x2.shr_u",
    @"i64x2.add", @"i64x2.sub", @"i64x2.mul",
    @"i64x2.extmul_low_i32x4_s", @"i64x2.extmul_high_i32x4_s",
    @"i64x2.extmul_low_i32x4_u", @"i64x2.extmul_high_i32x4_u",

    // f32x4 / f64x2 cmp + arith
    @"f32x4.eq", @"f32x4.ne", @"f32x4.lt", @"f32x4.gt", @"f32x4.le", @"f32x4.ge",
    @"f32x4.abs", @"f32x4.neg", @"f32x4.sqrt",
    @"f32x4.add", @"f32x4.sub", @"f32x4.mul", @"f32x4.div",
    @"f32x4.min", @"f32x4.max", @"f32x4.pmin", @"f32x4.pmax",
    @"f32x4.ceil", @"f32x4.floor", @"f32x4.trunc", @"f32x4.nearest",
    @"f32x4.convert_i32x4_s", @"f32x4.convert_i32x4_u",
    @"f32x4.demote_f64x2_zero",

    @"f64x2.eq", @"f64x2.ne", @"f64x2.lt", @"f64x2.gt", @"f64x2.le", @"f64x2.ge",
    @"f64x2.abs", @"f64x2.neg", @"f64x2.sqrt",
    @"f64x2.add", @"f64x2.sub", @"f64x2.mul", @"f64x2.div",
    @"f64x2.min", @"f64x2.max", @"f64x2.pmin", @"f64x2.pmax",
    @"f64x2.ceil", @"f64x2.floor", @"f64x2.trunc", @"f64x2.nearest",
    @"f64x2.convert_low_i32x4_s", @"f64x2.convert_low_i32x4_u",
    @"f64x2.promote_low_f32x4",

    // v128 bit / boolean
    @"v128.not", @"v128.and", @"v128.andnot", @"v128.or", @"v128.xor",
    @"v128.bitselect", @"v128.any_true",

    // ============================================================
    // Wasm 3.0 additions
    // ============================================================
    @"memory.size_64",
    @"memory.grow_64",

    // exception handling
    @"try_table",
    @"throw",
    @"throw_ref",

    // tail call
    @"return_call",
    @"return_call_indirect",
    @"return_call_ref",

    // function references
    @"call_ref",
    @"ref.as_non_null",
    @"br_on_null",
    @"br_on_non_null",

    // GC: struct
    @"struct.new",
    @"struct.new_default",
    @"struct.get",
    @"struct.get_s",
    @"struct.get_u",
    @"struct.set",

    // GC: array
    @"array.new",
    @"array.new_default",
    @"array.new_fixed",
    @"array.new_data",
    @"array.new_elem",
    @"array.get",
    @"array.get_s",
    @"array.get_u",
    @"array.set",
    @"array.len",
    @"array.fill",
    @"array.copy",
    @"array.init_data",
    @"array.init_elem",

    // GC: ref / cast / extern conversion
    @"ref.test",
    @"ref.test_null",
    @"ref.cast",
    @"ref.cast_null",
    @"br_on_cast",
    @"br_on_cast_fail",
    @"any.convert_extern",
    @"extern.convert_any",

    // GC: i31
    @"ref.i31",
    @"i31.get_s",
    @"i31.get_u",

    // relaxed-simd
    @"i8x16.relaxed_swizzle",
    @"i32x4.relaxed_trunc_f32x4_s", @"i32x4.relaxed_trunc_f32x4_u",
    @"i32x4.relaxed_trunc_f64x2_s_zero", @"i32x4.relaxed_trunc_f64x2_u_zero",
    @"f32x4.relaxed_madd", @"f32x4.relaxed_nmadd",
    @"f64x2.relaxed_madd", @"f64x2.relaxed_nmadd",
    @"i8x16.relaxed_laneselect", @"i16x8.relaxed_laneselect",
    @"i32x4.relaxed_laneselect", @"i64x2.relaxed_laneselect",
    @"f32x4.relaxed_min", @"f32x4.relaxed_max",
    @"f64x2.relaxed_min", @"f64x2.relaxed_max",
    @"i16x8.relaxed_q15mulr_s",
    @"i16x8.relaxed_dot_i8x16_i7x16_s",
    @"i32x4.relaxed_dot_i8x16_i7x16_add_s",

    // wide arithmetic
    @"i64.add128", @"i64.sub128",
    @"i64.mul_wide_s", @"i64.mul_wide_u",

    // custom page sizes
    @"memory.discard",

    // ============================================================
    // Phase 3-4 proposals — slots reserved, implementation deferred
    // ============================================================
    // threads / atomics
    @"memory.atomic.notify",
    @"memory.atomic.wait32", @"memory.atomic.wait64",
    @"atomic.fence",
    @"i32.atomic.load", @"i32.atomic.load8_u", @"i32.atomic.load16_u",
    @"i64.atomic.load", @"i64.atomic.load8_u", @"i64.atomic.load16_u", @"i64.atomic.load32_u",
    @"i32.atomic.store", @"i32.atomic.store8", @"i32.atomic.store16",
    @"i64.atomic.store", @"i64.atomic.store8", @"i64.atomic.store16", @"i64.atomic.store32",
    @"i32.atomic.rmw.add", @"i32.atomic.rmw.sub", @"i32.atomic.rmw.and", @"i32.atomic.rmw.or", @"i32.atomic.rmw.xor", @"i32.atomic.rmw.xchg", @"i32.atomic.rmw.cmpxchg",
    @"i64.atomic.rmw.add", @"i64.atomic.rmw.sub", @"i64.atomic.rmw.and", @"i64.atomic.rmw.or", @"i64.atomic.rmw.xor", @"i64.atomic.rmw.xchg", @"i64.atomic.rmw.cmpxchg",
    @"i32.atomic.rmw8.add_u", @"i32.atomic.rmw8.sub_u", @"i32.atomic.rmw8.and_u", @"i32.atomic.rmw8.or_u", @"i32.atomic.rmw8.xor_u", @"i32.atomic.rmw8.xchg_u", @"i32.atomic.rmw8.cmpxchg_u",
    @"i32.atomic.rmw16.add_u", @"i32.atomic.rmw16.sub_u", @"i32.atomic.rmw16.and_u", @"i32.atomic.rmw16.or_u", @"i32.atomic.rmw16.xor_u", @"i32.atomic.rmw16.xchg_u", @"i32.atomic.rmw16.cmpxchg_u",
    @"i64.atomic.rmw8.add_u", @"i64.atomic.rmw8.sub_u", @"i64.atomic.rmw8.and_u", @"i64.atomic.rmw8.or_u", @"i64.atomic.rmw8.xor_u", @"i64.atomic.rmw8.xchg_u", @"i64.atomic.rmw8.cmpxchg_u",
    @"i64.atomic.rmw16.add_u", @"i64.atomic.rmw16.sub_u", @"i64.atomic.rmw16.and_u", @"i64.atomic.rmw16.or_u", @"i64.atomic.rmw16.xor_u", @"i64.atomic.rmw16.xchg_u", @"i64.atomic.rmw16.cmpxchg_u",
    @"i64.atomic.rmw32.add_u", @"i64.atomic.rmw32.sub_u", @"i64.atomic.rmw32.and_u", @"i64.atomic.rmw32.or_u", @"i64.atomic.rmw32.xor_u", @"i64.atomic.rmw32.xchg_u", @"i64.atomic.rmw32.cmpxchg_u",

    // stack switching (continuations)
    @"cont.new",
    @"cont.bind",
    @"resume",
    @"resume_throw",
    @"suspend",
    @"switch",

    // memory-control
    @"memory.protect",

    // ============================================================
    // Pseudo opcodes — JIT-internal, populated Phase 7+
    // ============================================================
    @"__pseudo.const_in_reg",
    @"__pseudo.loop_header",
    @"__pseudo.loop_back_edge",
    @"__pseudo.loop_end",
    @"__pseudo.bounds_check_elided",
    @"__pseudo.phi_block_param",
    @"__pseudo.spill_to_slot",
    @"__pseudo.reload_from_slot",
    @"__pseudo.inst_ptr_cache_set",
    @"__pseudo.vm_ptr_cache_set",
    @"__pseudo.simd_base_cache_set",
    @"__pseudo.frame_setup",
    @"__pseudo.frame_teardown",

    _,
};

pub const ZirInstr = struct {
    op: ZirOp,
    payload: u32 = 0,
    extra: u32 = 0,
};

// Forward-declared "slot" types — identities reserved day 1 per
// P13 / W54 lesson. Fields land in the populating phase
// (commented at each declaration). Adding fields later is OK;
// renaming or removing the type would be a §4.2 deviation
// requiring an ADR (§18).

/// Phase 5+: per-function liveness analysis result.
pub const Liveness = struct {};

/// Phase 5+: loop nesting + branch target resolution. Populated
/// by `src/ir/loop_info.zig` from `ZirFunc.blocks` after the
/// lowerer fills the block table. Slices borrowed; lifetime is
/// the caller's (typically the per-instance arena, or
/// `loop_info.deinit` on free).
pub const LoopInfo = struct {
    /// Instruction indices of `loop` opcodes in this function.
    /// Parallel to `loop_end`. Empty for non-looping functions.
    loop_headers: []const u32 = &.{},
    /// Instruction indices of the matching `end` for each loop in
    /// `loop_headers`. Same length as `loop_headers`.
    loop_end: []const u32 = &.{},
};

/// Phase 5+: hoisted-constant pool seed.
pub const ConstantPool = struct {};

/// Phase 7+: per-vreg register-class hint.
pub const RegClass = enum(u8) { gpr, fpr, simd, _ };

/// Phase 7+: spilled-vreg stack slot record.
pub const SpillSlot = struct {};

/// Phase 7+: special-purpose register cache layout (inst_ptr /
/// vm_ptr / simd_base, per ROADMAP §4.2 RegClass.*_special).
pub const CacheLayout = struct {};

/// Phase 9+: SIMD lane-routing metadata.
pub const LaneRouting = struct {};

/// Phase 10+: GC-managed reference root map.
pub const GcRootMap = struct {};

/// Phase 10+: exception-handling landing pad record.
pub const LandingPad = struct {};

/// Phase 10+: tail-call site record.
pub const TailCallSite = struct {};

/// Phase 15+: hoisted constant placement record.
pub const HoistedConst = struct {};

/// Phase 15+: bounds-check elision proof.
pub const ElisionRecord = struct {};

/// Phase 15+: mov-coalescer audit record.
pub const CoalesceRecord = struct {};

pub const ZirFunc = struct {
    func_idx: u32,
    sig: FuncType,
    locals: []const ValType,
    instrs: std.ArrayList(ZirInstr),
    blocks: std.ArrayList(BlockInfo),
    branch_targets: std.ArrayList(u32),

    // Phase 5+ — analysis layer.
    loop_info: ?LoopInfo = null,
    liveness: ?Liveness = null,
    constant_pool: ?ConstantPool = null,

    // Phase 7+ — JIT register allocator.
    reg_class_hints: ?[]RegClass = null,
    spill_slots: ?[]SpillSlot = null,
    inst_ptr_cache_layout: ?CacheLayout = null,
    vm_ptr_cache_layout: ?CacheLayout = null,
    simd_base_cache_layout: ?CacheLayout = null,

    // Phase 9+ — SIMD additional state.
    simd_lane_routing: ?LaneRouting = null,

    // Phase 10+ — GC / EH / tail-call additional state.
    gc_root_map: ?GcRootMap = null,
    eh_landing_pads: ?[]LandingPad = null,
    tail_call_sites: ?[]TailCallSite = null,

    // Phase 15+ — optimisation passes.
    hoisted_constants: ?[]HoistedConst = null,
    bounds_check_elision_map: ?[]ElisionRecord = null,
    coalesced_movs: ?[]CoalesceRecord = null,

    pub fn init(func_idx: u32, sig: FuncType, locals: []const ValType) ZirFunc {
        return .{
            .func_idx = func_idx,
            .sig = sig,
            .locals = locals,
            .instrs = .empty,
            .blocks = .empty,
            .branch_targets = .empty,
        };
    }

    pub fn deinit(self: *ZirFunc, alloc: Allocator) void {
        self.instrs.deinit(alloc);
        self.blocks.deinit(alloc);
        self.branch_targets.deinit(alloc);
    }
};

test "ZirFunc.init: required fields populated, slots null" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(7, sig, &.{});
    defer f.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 7), f.func_idx);
    try std.testing.expectEqual(@as(usize, 0), f.sig.params.len);
    try std.testing.expectEqual(@as(usize, 0), f.sig.results.len);
    try std.testing.expectEqual(@as(usize, 0), f.locals.len);
    try std.testing.expectEqual(@as(usize, 0), f.instrs.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), f.branch_targets.items.len);

    try std.testing.expect(f.loop_info == null);
    try std.testing.expect(f.liveness == null);
    try std.testing.expect(f.constant_pool == null);
    try std.testing.expect(f.reg_class_hints == null);
    try std.testing.expect(f.spill_slots == null);
    try std.testing.expect(f.inst_ptr_cache_layout == null);
    try std.testing.expect(f.vm_ptr_cache_layout == null);
    try std.testing.expect(f.simd_base_cache_layout == null);
    try std.testing.expect(f.simd_lane_routing == null);
    try std.testing.expect(f.gc_root_map == null);
    try std.testing.expect(f.eh_landing_pads == null);
    try std.testing.expect(f.tail_call_sites == null);
    try std.testing.expect(f.hoisted_constants == null);
    try std.testing.expect(f.bounds_check_elision_map == null);
    try std.testing.expect(f.coalesced_movs == null);
}

test "ZirFunc: instrs grow via per-call allocator" {
    const sig: FuncType = .{ .params = &.{}, .results = &.{} };
    var f = ZirFunc.init(0, sig, &.{});
    defer f.deinit(std.testing.allocator);

    const op0: ZirOp = @enumFromInt(0);
    try f.instrs.append(std.testing.allocator, .{ .op = op0, .payload = 42, .extra = 0 });
    try f.instrs.append(std.testing.allocator, .{ .op = op0, .payload = 0, .extra = 7 });

    try std.testing.expectEqual(@as(usize, 2), f.instrs.items.len);
    try std.testing.expectEqual(@as(u32, 42), f.instrs.items[0].payload);
    try std.testing.expectEqual(@as(u32, 7), f.instrs.items[1].extra);
}

test "ValType / BlockKind: enum tags are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ValType.i32));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ValType.i64));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(BlockKind.block));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(BlockKind.loop));
}

test "FuncType holds slices without copying" {
    const params = [_]ValType{ .i32, .i64 };
    const results = [_]ValType{.f64};
    const sig: FuncType = .{ .params = &params, .results = &results };
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    try std.testing.expectEqual(ValType.f64, sig.results[0]);
}

test "ZirOp: MVP opcodes are declared" {
    // Spot-check a representative slice of MVP entries.
    const mvp = [_]ZirOp{
        .@"unreachable", .@"nop", .@"block",  .@"loop",     .@"if",
        .@"else",        .@"end", .@"br",     .@"br_if",    .@"br_table",
        .@"return",      .@"call", .@"call_indirect",
        .@"drop",        .@"select", .@"select_typed",
        .@"local.get",   .@"local.set", .@"local.tee",
        .@"global.get",  .@"global.set",
        .@"i32.const", .@"i32.add", .@"i32.sub", .@"i32.mul",
        .@"i64.const", .@"f32.const", .@"f64.const",
        .@"memory.size", .@"memory.grow",
    };
    inline for (mvp) |op| {
        _ = @intFromEnum(op);
    }
}

test "ZirOp: Wasm 2.0 / SIMD / 3.0 entries declared" {
    const v2 = [_]ZirOp{ .@"i32.extend8_s", .@"memory.copy", .@"ref.null", .@"table.get" };
    const simd = [_]ZirOp{ .@"v128.load", .@"v128.const", .@"i8x16.add", .@"f64x2.add" };
    const v3 = [_]ZirOp{
        .@"try_table",   .@"throw",       .@"return_call", .@"call_ref",
        .@"struct.new",  .@"array.new",   .@"ref.test",    .@"ref.i31",
        .@"memory.discard",
    };
    const phase34 = [_]ZirOp{ .@"atomic.fence", .@"i32.atomic.load", .@"cont.new", .@"resume" };
    const pseudo = [_]ZirOp{
        .@"__pseudo.const_in_reg",       .@"__pseudo.loop_header",
        .@"__pseudo.bounds_check_elided", .@"__pseudo.spill_to_slot",
        .@"__pseudo.frame_setup",
    };
    inline for (v2 ++ simd ++ v3 ++ phase34 ++ pseudo) |op| {
        _ = @intFromEnum(op);
    }
}

test "ZirOp: tag count meets §4.2 baseline" {
    // §4.2 declares ~280 named tags (Wasm 1.0 + 2.0 + SIMD + 3.0
    // + Phase 3-4 reserved + JIT pseudo-ops). Treat 250 as a
    // conservative floor — the assertion guards against a future
    // accidental deletion of a swath of tags.
    const fields = @typeInfo(ZirOp).@"enum".fields;
    try std.testing.expect(fields.len >= 250);
}
