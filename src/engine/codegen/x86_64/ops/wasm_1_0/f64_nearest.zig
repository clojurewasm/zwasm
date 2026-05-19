//! x86_64 emit handler for `f64.nearest` — Zone 2 per ADR-0074.
//! Delegates to op_alu_float.emitFpUnary (7-arg).

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_1_0/f64_nearest.zig");
const op_alu_float = @import("../../op_alu_float.zig");
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
    return op_alu_float.emitFpUnary(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, op);
}
