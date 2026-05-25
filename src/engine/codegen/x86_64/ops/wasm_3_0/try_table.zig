//! x86_64 emit handler for `try_table` — Zone 2 per ADR-0074
//! + ADR-0114 D2. Mirror of arm64 sibling.
//!
//! Wasm spec 3.0 §3.3.10.6. Emits zero JIT bytes; registers
//! handler entries into `ExceptionTable.Builder` for the
//! FP-walk unwinder.
//!
//! Stub: emit returns `UnsupportedOp`. Real body lands at
//! 10.E-codegen-4b.
//!
//! Zone 2 (`src/engine/codegen/x86_64/ops/`).

const std = @import("std");

const meta = @import("../../../../../instruction/wasm_3_0/try_table.zig");
const ctx_mod = @import("../../ctx.zig");
const zir = @import("../../../../../ir/zir.zig");

pub const op_tag = meta.op_tag;
pub const wasm_level = meta.wasm_level;
pub const wasi_level = meta.wasi_level;

// ADR-0113 §A/B + ADR-0114 D2 — fallthrough into inner block.
pub const is_terminator: bool = false;
pub const n_successor_edges: u8 = 1;
pub const is_safepoint: bool = false;

/// Wasm spec 3.0 §3.3.10.6 (try_table) — mirror of arm64 sibling.
/// See arm64/ops/wasm_3_0/try_table.zig for the full IT-2 rationale.
pub fn emit(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) ctx_mod.Error!void {
    std.debug.assert(ctx.exception_table_builder != null);
    std.debug.assert(ctx.open_try_tables != null);
    const builder = ctx.exception_table_builder.?;

    const block_idx: u32 = @intCast(ins.payload);
    const landing_pads = ctx.func.eh_landing_pads orelse return error.UnsupportedOp;
    const catch_entries = ctx.func.eh_catch_entries orelse return error.UnsupportedOp;

    var lp_opt: ?zir.LandingPad = null;
    for (landing_pads) |lp| {
        if (lp.block_idx == block_idx) {
            lp_opt = lp;
            break;
        }
    }
    const lp = lp_opt orelse return error.UnsupportedOp;

    const pc_start: u32 = @intCast(ctx.buf.items.len);
    const entry_start: u32 = @intCast(builder.entries.items.len);
    const range_start: usize = lp.catches_start;
    const range_end: usize = lp.catches_end;

    for (catch_entries[range_start..range_end]) |ce| {
        const is_catch_all = (ce.kind == .catch_all or ce.kind == .catch_all_ref);
        try builder.add(ctx.allocator, .{
            .pc_start = pc_start,
            .pc_end = pc_start + 1, // placeholder; end-op patches
            .tag_idx = if (is_catch_all) null else ce.tag_idx,
            .landing_pad_pc = ce.label_idx, // placeholder for IT-4
            .kind = switch (ce.kind) {
                .catch_ => .catch_,
                .catch_ref => .catch_ref,
                .catch_all => .catch_all,
                .catch_all_ref => .catch_all_ref,
            },
        });
    }
    const entry_count: u32 = @intCast(range_end - range_start);

    try ctx.labels.append(ctx.allocator, .{
        .kind = .block,
        .target_byte_offset = 0,
        .pending = .empty,
        .result_arity = 0,
        .param_arity = 0,
        .entry_stack_depth = @intCast(ctx.pushed_vregs.items.len),
    });

    try ctx.open_try_tables.?.append(ctx.allocator, .{
        .labels_depth = @intCast(ctx.labels.items.len),
        .entry_start = entry_start,
        .entry_count = entry_count,
    });
}
