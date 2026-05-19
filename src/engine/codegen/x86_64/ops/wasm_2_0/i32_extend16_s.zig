//! x86_64 emit handler for `i32.extend16_s` — Zone 2 per ADR-0074.
//! Bundled via op_alu_int.emitSignExtend (7-arg with op-keyed switch).

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_2_0/i32_extend16_s.zig");
const op_alu_int = @import("../../op_alu_int.zig");
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
    return op_alu_int.emitSignExtend(allocator, buf, alloc, pushed_vregs, next_vreg, spill_base_off, op);
}
