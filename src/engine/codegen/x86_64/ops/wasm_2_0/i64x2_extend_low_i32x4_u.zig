//! x86_64 emit handler for `i64x2.extend_low_i32x4_u` — Zone 2 per ADR-0074.

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_2_0/i64x2_extend_low_i32x4_u.zig");
const op_simd_int_cmp_lane = @import("../../op_simd_int_cmp_lane.zig");
const regalloc = @import("../../../shared/regalloc.zig");
const types = @import("../../types.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

pub fn emit(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) types.Error!void {
    _ = op;
    _ = spill_base_off;
    return op_simd_int_cmp_lane.emitI64x2ExtendLowI32x4U(allocator, buf, alloc, pushed_vregs, next_vreg);
}
