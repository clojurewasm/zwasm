//! Zone 2 codegen dispatch collector — arm64 / x86_64 axes per ADR-0074
//! (per-op file zone split along axis boundary).
//!
//! ## Why this file exists
//!
//! ADR-0073 + ADR-0023 §4.5 amend established the per-op file pattern;
//! ADR-0074 (B9) refined it: the 5 dispatch axes split across two
//! zones to keep handler bodies at the same zone as their ctx types
//! (preserves comptime DCE on every axis).
//!
//!   Zone 1 collector: `src/ir/dispatch_collector.zig`
//!     IRAxis = { .validate, .lower, .interp }
//!     Imports `src/instruction/wasm_X_Y/<op>.zig` (Zone 1).
//!
//!   Zone 2 collector: THIS FILE.
//!     ArchAxis = { .arm64, .x86_64 }
//!     Imports `src/engine/codegen/<arch>/ops/wasm_X_Y/<op>.zig`
//!     (Zone 2). Each arch op file in turn imports the Zone 1
//!     identity anchor for `op_tag` / `wasm_level` / `wasi_level`.
//!
//! The two collectors share `WasmLevel` / `WasiLevel` / `enabledByBuild`
//! (re-exported from Zone 1) so the build-option filter applies
//! uniformly across all 5 axes.
//!
//! ## Dispatch contract (B11 refactor)
//!
//! `dispatch(axis, op, args)` returns `!bool`:
//!   - `true`: the per-arch handler for `op` ran (errors propagated
//!     via the `try`-propagating inferred error set).
//!   - `false`: no per-arch op file is registered for `op` (= legacy
//!     switch in `<arch>/emit.zig` retains authority).
//!   - error: whatever the per-arch handler raised; the caller's
//!     enclosing fn's `Error` set must include it (per-arch handlers
//!     return `arm64/ctx.Error!void` or `x86_64/ctx.Error!void`,
//!     matching the wire-call's enclosing fn).
//!
//! Per-arch op file shape:
//!
//!   pub const op_tag: ZirOp = ...;        // mirrored from Zone 1
//!   pub const wasm_level: ?WasmLevel = ...;
//!   pub const wasi_level: ?WasiLevel = ...;
//!   pub fn emit(...) Error!void { ... }   // real body; per-arch ctx
//!
//! Zone 2 (`src/engine/codegen/`).

const std = @import("std");
const zir = @import("../../ir/zir.zig");
const ir_collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;

pub const WasmLevel = ir_collector.WasmLevel;
pub const WasiLevel = ir_collector.WasiLevel;
pub const enabledByBuild = ir_collector.enabledByBuild;

/// Per-arch codegen axes (per ADR-0074). The IR-axis counterparts
/// live at Zone 1's `IRAxis` enum.
pub const ArchAxis = enum {
    arm64,
    x86_64,
};

/// Comptime contract check for per-arch op modules.
pub fn validateArchOpModule(comptime mod: type) void {
    comptime {
        if (!@hasDecl(mod, "op_tag")) {
            @compileError("per-arch op file missing `pub const op_tag: ZirOp = ...;`");
        }
        if (!@hasDecl(mod, "wasm_level")) {
            @compileError("per-arch op file missing `pub const wasm_level: ?WasmLevel = ...;`");
        }
        if (!@hasDecl(mod, "emit")) {
            @compileError("per-arch op file missing `pub fn emit(...) Error!void { ... }`");
        }
    }
}

/// ADR-0113 §A — regalloc 3-axis classification. A per-op file
/// may declare any subset of `{is_terminator, n_successor_edges,
/// is_safepoint}`; absent declarations fall back to safe
/// defaults that match the regular-call shape (returns to
/// caller, single successor, no GC safepoint). The defaults are
/// chosen so a per-op file that hasn't migrated to the 3-axis
/// regime still classifies sanely for the regalloc layer.
///
/// As regalloc consumers come online (tail-call terminator-class,
/// EH N-successor catch dispatch, GC stack-map safepoint
/// walking), per-op files opt in by overriding the axes they
/// diverge from. Per ADR-0113 §A's per-op file convention.
pub const Axis3 = struct {
    is_terminator: bool,
    n_successor_edges: u8,
    is_safepoint: bool,
};

pub fn axisOf(comptime mod: type) Axis3 {
    return comptime .{
        .is_terminator = if (@hasDecl(mod, "is_terminator")) mod.is_terminator else false,
        .n_successor_edges = if (@hasDecl(mod, "n_successor_edges")) mod.n_successor_edges else 1,
        .is_safepoint = if (@hasDecl(mod, "is_safepoint")) mod.is_safepoint else false,
    };
}

// ---------------------------------------------------------------------
// Per-arch collected op modules.
//
// B11: arm64 i32.add real body.
// B12: x86_64 i32.add real body.
// B13: i32 binary ALU cohort (sub/mul/and/or/xor × 2 arches).
// ---------------------------------------------------------------------

// Op registry extracted to `dispatch_collector_ops.zig` per ADR-0086
// (mirror of ADR-0082's ir/dispatch_collector_ops.zig). The dispatcher
// framework + comptime validation stays in this file.
const ops_registry = @import("dispatch_collector_ops.zig");
pub const collected_arm64_ops = ops_registry.collected_arm64_ops;
pub const collected_x86_64_ops = ops_registry.collected_x86_64_ops;
pub const collected_x86_64_ctx_ops = ops_registry.collected_x86_64_ctx_ops;

comptime {
    @setEvalBranchQuota(10_000);
    for (collected_arm64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ctx_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
}

/// Count of currently-migrated arch ops, filtered by the active build
/// options. All comptime-resolved.
pub fn migratedArchOpCount(comptime axis: ArchAxis) usize {
    return comptime blk: {
        @setEvalBranchQuota(10_000);
        const ops = switch (axis) {
            .arm64 => collected_arm64_ops,
            .x86_64 => collected_x86_64_ops,
        };
        var n: usize = 0;
        for (ops) |op_mod| {
            if (enabledByBuild(op_mod)) {
                n += 1;
            }
        }
        break :blk n;
    };
}

/// Per-arch dispatch. Returns `true` if the per-arch handler ran;
/// `false` if no per-arch op file is registered (legacy switch should
/// take over). Handler errors propagate via the inferred error set.
///
/// `args` is a tuple matching the per-arch `emit` function's signature
/// (per-arch ctx types are Zone 2 concerns).
pub fn dispatch(comptime axis: ArchAxis, op: ZirOp, args: anytype) !bool {
    const ops = comptime switch (axis) {
        .arm64 => collected_arm64_ops,
        .x86_64 => collected_x86_64_ops,
    };
    inline for (ops) |op_mod| {
        if (comptime !enabledByBuild(op_mod)) continue;
        if (op == op_mod.op_tag) {
            try @call(.auto, op_mod.emit, args);
            return true;
        }
    }
    return false;
}

/// §9.12-B / B108 (ADR-0073 + ADR-0075) — inline-switch dispatcher
/// cutover for the x86_64 `(ctx, ins)` migrated cohort. Walks
/// `collected_x86_64_ctx_ops` and dispatches to the matching per-op
/// file's `emit(ctx, ins)`. Returns `true` if handled; `false` lets
/// the giant switch in `x86_64/emit.zig` take over for ops outside
/// the ctx tuple (extract_lane / replace_lane / shuffle / i64x2.mul
/// / v128.const / load_lane / store_lane / popcnt / trunc_sat_f64x2
/// / convert_low_i32x4_u — payload-laden or no-Zone-1-meta).
pub fn dispatchX86_64Ctx(op: ZirOp, ctx_ptr: anytype, ins_ptr: anytype) !bool {
    @setEvalBranchQuota(20_000);
    inline for (collected_x86_64_ctx_ops) |op_mod| {
        if (comptime !enabledByBuild(op_mod)) continue;
        if (op == op_mod.op_tag) {
            try op_mod.emit(ctx_ptr, ins_ptr);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------

test "ArchAxis enum has exactly 2 variants per ADR-0074 (Zone 2 arch-axes)" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(ArchAxis).@"enum".fields.len);
}

test "migratedArchOpCount tracks collected per-arch tuples (B59: arm64=348, x86_64=292)" {
    // arm64 = 162 + 10 i16x8 cmp; x86_64 = 154 + 10 - 8 trunc_sat
    // (B57) - 8 int→float convert (B58) - 6 reinterpret/promote/demote
    // (B59 moved B28 stubs to ctx tuple). B60 added 23 NEW scalar
    // load/store per-op files directly to ctx tuple (not in legacy
    // tuple before, so x86_64 count unchanged).
    // Phase 10 EH (ADR-0114) — IT-1 added arm64_try_table (+1 = 349).
    try std.testing.expectEqual(@as(usize, 349), migratedArchOpCount(.arm64));
    // B79..B106 walked cohorts; B107 SIMD residual (21 ops) — legacy tuple empty.
    try std.testing.expectEqual(@as(usize, 0), migratedArchOpCount(.x86_64));
}

test "collected_x86_64_ctx_ops tracks B54+ migrations to `(ctx, ins)` shape" {
    // B54: i32.div_s PoC (1). B55: full i32+i64 div/rem cohort (+7 = 8).
    // B56: Wasm 1.0 trapping trunc cohort (+8 = 16). B57: Wasm 2.0
    // trunc_sat cohort moved from legacy tuple (+8 = 24). B58: Wasm
    // 1.0 int→float convert cohort moved from legacy tuple (+8 = 32).
    // B59: reinterpret + promote/demote moved from legacy tuple
    // (+6 = 38). B60: scalar load/store cohort (23 new per-op files,
    // +23 = 61). B61: bulk-memory cohort (3 new per-op files for
    // memory.fill/copy/init, +3 = 64; data.drop / elem.drop deferred
    // — Zone 1 meta files don't exist yet). B62: globals cohort
    // (global.get/set, 2 new per-op files, +2 = 66). B63: table
    // ops cohort (7 new per-op files: table.get/set/size/grow/
    // fill/copy/init, +7 = 73). B64: call cohort (call +
    // call_indirect, 2 new per-op files, +2 = 75). B65: control
    // structure cohort (block + loop, 2 new per-op files, +2 = 77).
    // B66: Zone 1 meta backfill (no Zone 2 change). B67: const
    // cohort (i32/i64/f32/f64.const, 4 new per-op files, +4 = 81).
    // B68: ref cohort (ref.null + ref.func, 2 new per-op files,
    // +2 = 83). B69: drop (1 new per-op file, +1 = 84). B70:
    // select (1 new per-op file, +1 = 85; select_typed shares
    // runtime via emit.zig grouped arm but lacks Zone 1 meta —
    // its per-op file is deferred). The B6x+1 cutover folds this
    // tuple back into `collected_x86_64_ops`. B71: memory.size +
    // memory.grow (2 new per-op files + 2 Zone 1 meta backfills,
    // +2 = 87). B72: nop (1 new per-op file + 1 meta backfill,
    // +1 = 88). B73: unreachable (1 new per-op file; ctx extended
    // with `dead_code: *bool`, +1 = 89). B74: return (1 new
    // per-op file; ctx extended with `frame_bytes: u32` +
    // `uses_runtime_ptr: bool`, +1 = 90). B75: br family
    // (br + br_if + br_table, all ctx fields exist; 3 new per-op
    // files, +3 = 93). B76: if + else (2 new per-op files,
    // +2 = 95). B77: end (1 new per-op file, +1 = 96 —
    // function-level form + label-end form both route through
    // op_control.emitEndCtx; emit.zig dispatch snapshots
    // labels.len pre-call to decide body-loop break). B78:
    // local.{get,set,tee} (3 new per-op files, +3 = 99;
    // new op_locals.zig host module, ctx ext for total_locals
    // + local_disps). B79: i32 binary ALU cohort (i32.add/sub/
    // mul/and/or/xor, 6 ops) moved from legacy tuple (+6 = 105;
    // emitI32BinaryCtx adapter wraps existing emitI32Binary).
    // B80: i64 binary ALU cohort (6 ops; emitI64BinaryCtx) moved
    // from legacy (+6 = 111). B81: i32 compare cohort (10 ops;
    // emitI32CompareCtx) moved from legacy (+10 = 121).
    // B82: i64 compare cohort (10 ops; emitI64CompareCtx) moved
    // from legacy (+10 = 131). B83: i32+i64 shift cohorts (10 ops;
    // emitI{32,64}ShiftCtx) moved from legacy (+10 = 141).
    // B84: bitcount(6) + eqz(2) = 8 ops moved from legacy (+8 = 149).
    // B85: sign-extension(5) + width-conversion(3) = 8 ops moved
    // (+8 = 157). B86: FP arith (8 ops; emitFpBinaryCtx) moved
    // (+8 = 165). B87: FP compare (12 ops; emitFpCompareCtx)
    // moved (+12 = 177). B88: FP unary (14 ops; emitFpUnaryCtx)
    // moved (+14 = 191). B89: FP min/max+copysign (6 ops;
    // emitFp{MinMax,Copysign}Ctx) moved (+6 = 197). B90: v128
    // logical (6 ops; emitV128*Ctx adapters; first SIMD migration)
    // moved (+6 = 203). B91: SIMD int binary arith (10 ops; add/sub
    // × 4 widths + i16x8/i32x4.mul; i64x2.mul deferred — no Zone 1
    // meta) moved (+10 = 213). B92: SIMD int neg/abs (8 ops;
    // 5-arg helpers, ins ignored) moved (+8 = 221). B93: SIMD
    // i8x16 compare cohort (10 ops; eq is 6-arg, others 5-arg)
    // moved (+10 = 231). B94: SIMD i16x8 compare cohort (10 ops)
    // moved (+10 = 241). B95: SIMD i32x4 compare cohort (10 ops)
    // moved (+10 = 251). B96: SIMD i64x2 compare cohort (6 ops;
    // no _u variants) moved (+6 = 257). B97: SIMD int shifts
    // cohort (12 ops; all 6-arg) moved (+12 = 269). B98: SIMD
    // int min/max cohort (12 ops; all 6-arg) moved (+12 = 281).
    // B99: SIMD int sat arith (10 ops; all 6-arg) moved (+10 = 291).
    // B100: SIMD f32x4 arith (8 ops; add/sub/mul/div 6-arg, min/max/
    // pmin/pmax 5-arg) moved (+8 = 299). B101: SIMD f64x2 arith
    // (8 ops; mirror) moved (+8 = 307). B102: SIMD float unary
    // (14 ops; all 5-arg) moved (+14 = 321). B103: SIMD float
    // compare (12 ops; all 5-arg) moved (+12 = 333). B104: SIMD
    // bool reductions (9 ops; all 6-arg) moved (+9 = 342). B105:
    // SIMD narrow+extend (16 ops; 4 narrow 6-arg + 12 extend
    // 5-arg) moved (+16 = 358). B106: SIMD extmul (12 ops; all
    // 5-arg) moved (+12 = 370). B107: SIMD residual (ref.is_null
    // + 6 splats + swizzle + 4 extadd_pairwise + dot + q15mulr +
    // 7 fp-conv = 21 ops) moved (+21 = 391); legacy tuple empty.
    // Phase 10 EH (ADR-0114) — IT-1 added x86_64_try_table (+1 = 392);
    // IT-3 added x86_64_throw + x86_64_throw_ref (+2 = 394).
    // 10.TC emit-body cycle 5 (ADR-0112) — x86_64_return_call (+1 = 395).
    try std.testing.expectEqual(@as(usize, 395), collected_x86_64_ctx_ops.len);
}

// Note: a `dispatch(.arm64, tag, args)` test at this layer would
// fail to compile because `inline for` expands the `@call(.auto,
// op_mod.emit, args)` at comptime against every registered per-arch
// handler — handlers require their real ctx tuples, not a smoke
// `.{}`. The dispatcher's wire contract is covered by integration
// tests at `arm64/emit.zig` (and `x86_64/emit.zig` once B12 lands)
// going through real spec-driven fixtures.

// ADR-0113 §A: 3-axis classification — comptime tests.

test "axisOf: per-op file without explicit axes falls back to call defaults" {
    // A struct with no axis declarations should resolve to the
    // "regular call" defaults: returns to caller, 1 successor,
    // not a safepoint.
    const FakeOp = struct {};
    const axis = axisOf(FakeOp);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_1_0/call.zig declares regular-call axes (ADR-0113 §A)" {
    const call_mod = @import("arm64/ops/wasm_1_0/call.zig");
    const axis = axisOf(call_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(true, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_1_0/call.zig declares regular-call axes (ADR-0113 §A)" {
    const call_mod = @import("x86_64/ops/wasm_1_0/call.zig");
    const axis = axisOf(call_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(true, axis.is_safepoint);
}

test "axisOf: partial override — only is_terminator declared, others default" {
    const FakeTerminatorOp = struct {
        pub const is_terminator: bool = true;
    };
    const axis = axisOf(FakeTerminatorOp);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

// ADR-0112 D2 + ADR-0113 §A — return_call / return_call_indirect /
// return_call_ref are terminators (frame teardown + tail-jump
// leaves the function): is_terminator=true, n_successor_edges=0,
// is_safepoint=false (safepoint-free invariant between teardown
// and BR/JMP per ADR-0112 D7).

test "axisOf: arm64 ops/wasm_3_0/return_call.zig declares terminator axes (ADR-0112 + ADR-0113 §A)" {
    const rc_mod = @import("arm64/ops/wasm_3_0/return_call.zig");
    const axis = axisOf(rc_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/return_call_indirect.zig declares terminator axes" {
    const rci_mod = @import("arm64/ops/wasm_3_0/return_call_indirect.zig");
    const axis = axisOf(rci_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/return_call_ref.zig declares terminator axes" {
    const rcr_mod = @import("arm64/ops/wasm_3_0/return_call_ref.zig");
    const axis = axisOf(rcr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/return_call.zig declares terminator axes" {
    const rc_mod = @import("x86_64/ops/wasm_3_0/return_call.zig");
    const axis = axisOf(rc_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/return_call_indirect.zig declares terminator axes" {
    const rci_mod = @import("x86_64/ops/wasm_3_0/return_call_indirect.zig");
    const axis = axisOf(rci_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/return_call_ref.zig declares terminator axes" {
    const rcr_mod = @import("x86_64/ops/wasm_3_0/return_call_ref.zig");
    const axis = axisOf(rcr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

// ADR-0114 D2/D6 + ADR-0113 §A/B — EH op axes:
//   try_table = fallthrough (NOT terminator), 1 successor edge
//     per the catch-all per-op constant (per-callsite N
//     populated at lower time per ADR-0113 D3), not a safepoint.
//   throw / throw_ref = terminator (CALL into dispatcher;
//     never returns to caller), 0 in-function CFG edges, not
//     a safepoint (mirrors tail-call shape).

test "axisOf: arm64 ops/wasm_3_0/try_table.zig declares fallthrough axes (ADR-0114 D2)" {
    const tt_mod = @import("arm64/ops/wasm_3_0/try_table.zig");
    const axis = axisOf(tt_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/throw.zig declares terminator axes (ADR-0114 D6)" {
    const th_mod = @import("arm64/ops/wasm_3_0/throw.zig");
    const axis = axisOf(th_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: arm64 ops/wasm_3_0/throw_ref.zig declares terminator axes" {
    const tr_mod = @import("arm64/ops/wasm_3_0/throw_ref.zig");
    const axis = axisOf(tr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/try_table.zig declares fallthrough axes" {
    const tt_mod = @import("x86_64/ops/wasm_3_0/try_table.zig");
    const axis = axisOf(tt_mod);
    try std.testing.expectEqual(false, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 1), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/throw.zig declares terminator axes" {
    const th_mod = @import("x86_64/ops/wasm_3_0/throw.zig");
    const axis = axisOf(th_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}

test "axisOf: x86_64 ops/wasm_3_0/throw_ref.zig declares terminator axes" {
    const tr_mod = @import("x86_64/ops/wasm_3_0/throw_ref.zig");
    const axis = axisOf(tr_mod);
    try std.testing.expectEqual(true, axis.is_terminator);
    try std.testing.expectEqual(@as(u8, 0), axis.n_successor_edges);
    try std.testing.expectEqual(false, axis.is_safepoint);
}
