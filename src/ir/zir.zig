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
};

pub const ZirOp = enum(u16) {
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

/// Phase 5+: loop nesting + branch target resolution.
pub const LoopInfo = struct {};

/// Phase 5+: hoisted-constant pool seed.
pub const ConstantPool = struct {};

/// Phase 6+: per-vreg register-class hint.
pub const RegClass = enum(u8) { gpr, fpr, simd, _ };

/// Phase 6+: spilled-vreg stack slot record.
pub const SpillSlot = struct {};

/// Phase 6+: special-purpose register cache layout (inst_ptr /
/// vm_ptr / simd_base, per ROADMAP §4.2 RegClass.*_special).
pub const CacheLayout = struct {};

/// Phase 8+: SIMD lane-routing metadata.
pub const LaneRouting = struct {};

/// Phase 9+: GC-managed reference root map.
pub const GcRootMap = struct {};

/// Phase 9+: exception-handling landing pad record.
pub const LandingPad = struct {};

/// Phase 9+: tail-call site record.
pub const TailCallSite = struct {};

/// Phase 14+: hoisted constant placement record.
pub const HoistedConst = struct {};

/// Phase 14+: bounds-check elision proof.
pub const ElisionRecord = struct {};

/// Phase 14+: mov-coalescer audit record.
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

    // Phase 6+ — JIT register allocator.
    reg_class_hints: ?[]RegClass = null,
    spill_slots: ?[]SpillSlot = null,
    inst_ptr_cache_layout: ?CacheLayout = null,
    vm_ptr_cache_layout: ?CacheLayout = null,
    simd_base_cache_layout: ?CacheLayout = null,

    // Phase 8+ — SIMD additional state.
    simd_lane_routing: ?LaneRouting = null,

    // Phase 9+ — GC / EH / tail-call additional state.
    gc_root_map: ?GcRootMap = null,
    eh_landing_pads: ?[]LandingPad = null,
    tail_call_sites: ?[]TailCallSite = null,

    // Phase 14+ — optimisation passes.
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
