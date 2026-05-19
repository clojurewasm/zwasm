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

// ---------------------------------------------------------------------
// Per-arch collected op modules.
//
// B11: arm64 i32.add real body.
// B12: x86_64 i32.add real body.
// B13: i32 binary ALU cohort (sub/mul/and/or/xor × 2 arches).
// ---------------------------------------------------------------------

const arm64_i32_add = @import("arm64/ops/wasm_1_0/i32_add.zig");
const arm64_i32_sub = @import("arm64/ops/wasm_1_0/i32_sub.zig");
const arm64_i32_mul = @import("arm64/ops/wasm_1_0/i32_mul.zig");
const arm64_i32_and = @import("arm64/ops/wasm_1_0/i32_and.zig");
const arm64_i32_or = @import("arm64/ops/wasm_1_0/i32_or.zig");
const arm64_i32_xor = @import("arm64/ops/wasm_1_0/i32_xor.zig");
const arm64_i64_add = @import("arm64/ops/wasm_1_0/i64_add.zig");
const arm64_i64_sub = @import("arm64/ops/wasm_1_0/i64_sub.zig");
const arm64_i64_mul = @import("arm64/ops/wasm_1_0/i64_mul.zig");
const arm64_i64_and = @import("arm64/ops/wasm_1_0/i64_and.zig");
const arm64_i64_or = @import("arm64/ops/wasm_1_0/i64_or.zig");
const arm64_i64_xor = @import("arm64/ops/wasm_1_0/i64_xor.zig");

const x86_64_i32_add = @import("x86_64/ops/wasm_1_0/i32_add.zig");
const x86_64_i32_sub = @import("x86_64/ops/wasm_1_0/i32_sub.zig");
const x86_64_i32_mul = @import("x86_64/ops/wasm_1_0/i32_mul.zig");
const x86_64_i32_and = @import("x86_64/ops/wasm_1_0/i32_and.zig");
const x86_64_i32_or = @import("x86_64/ops/wasm_1_0/i32_or.zig");
const x86_64_i32_xor = @import("x86_64/ops/wasm_1_0/i32_xor.zig");
const x86_64_i64_add = @import("x86_64/ops/wasm_1_0/i64_add.zig");
const x86_64_i64_sub = @import("x86_64/ops/wasm_1_0/i64_sub.zig");
const x86_64_i64_mul = @import("x86_64/ops/wasm_1_0/i64_mul.zig");
const x86_64_i64_and = @import("x86_64/ops/wasm_1_0/i64_and.zig");
const x86_64_i64_or = @import("x86_64/ops/wasm_1_0/i64_or.zig");
const x86_64_i64_xor = @import("x86_64/ops/wasm_1_0/i64_xor.zig");

/// Tuple of all migrated arm64 per-op modules.
pub const collected_arm64_ops = .{
    arm64_i32_add,
    arm64_i32_sub,
    arm64_i32_mul,
    arm64_i32_and,
    arm64_i32_or,
    arm64_i32_xor,
    arm64_i64_add,
    arm64_i64_sub,
    arm64_i64_mul,
    arm64_i64_and,
    arm64_i64_or,
    arm64_i64_xor,
};

/// Tuple of all migrated x86_64 per-op modules.
pub const collected_x86_64_ops = .{
    x86_64_i32_add,
    x86_64_i32_sub,
    x86_64_i32_mul,
    x86_64_i32_and,
    x86_64_i32_or,
    x86_64_i32_xor,
    x86_64_i64_add,
    x86_64_i64_sub,
    x86_64_i64_mul,
    x86_64_i64_and,
    x86_64_i64_or,
    x86_64_i64_xor,
};

comptime {
    for (collected_arm64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
    for (collected_x86_64_ops) |op_mod| {
        validateArchOpModule(op_mod);
    }
}

/// Count of currently-migrated arch ops, filtered by the active build
/// options. All comptime-resolved.
pub fn migratedArchOpCount(comptime axis: ArchAxis) usize {
    return comptime blk: {
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

// ---------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------

test "ArchAxis enum has exactly 2 variants per ADR-0074 (Zone 2 arch-axes)" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(ArchAxis).@"enum".fields.len);
}

test "migratedArchOpCount tracks collected per-arch tuples (B14: arm64=12, x86_64=12)" {
    try std.testing.expectEqual(@as(usize, 12), migratedArchOpCount(.arm64));
    try std.testing.expectEqual(@as(usize, 12), migratedArchOpCount(.x86_64));
}

// Note: a `dispatch(.arm64, tag, args)` test at this layer would
// fail to compile because `inline for` expands the `@call(.auto,
// op_mod.emit, args)` at comptime against every registered per-arch
// handler — handlers require their real ctx tuples, not a smoke
// `.{}`. The dispatcher's wire contract is covered by integration
// tests at `arm64/emit.zig` (and `x86_64/emit.zig` once B12 lands)
// going through real spec-driven fixtures.
