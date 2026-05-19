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
//! The two collectors share `WasmLevel` / `WasiLevel` / `DispatchError`
//! / `enabledByBuild` (re-exported from Zone 1) so the build-option
//! filter applies uniformly across all 5 axes.
//!
//! Per-arch op file shape (the contract):
//!
//!   pub const op_tag: ZirOp = ...;        // mirrored from Zone 1
//!   pub const wasm_level: ?WasmLevel = ...;
//!   pub const wasi_level: ?WasiLevel = ...;
//!   pub fn emit(...) DispatchError!void { ... }
//!
//! Zone 2 (`src/engine/codegen/`).

const std = @import("std");
const zir = @import("../../ir/zir.zig");
const ir_collector = @import("../../ir/dispatch_collector.zig");

const ZirOp = zir.ZirOp;

pub const WasmLevel = ir_collector.WasmLevel;
pub const WasiLevel = ir_collector.WasiLevel;
pub const DispatchError = ir_collector.DispatchError;
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
            @compileError("per-arch op file missing `pub fn emit(...) DispatchError!void { ... }`");
        }
    }
}

// ---------------------------------------------------------------------
// Per-arch collected op modules.
//
// B10 bootstrap: a single arch-pair (i32.add) for each axis to prove
// the wire-in shape. B11..Bn append additional ops via cohort migration.
// ---------------------------------------------------------------------

const arm64_i32_add = @import("arm64/ops/wasm_1_0/i32_add.zig");
const x86_64_i32_add = @import("x86_64/ops/wasm_1_0/i32_add.zig");

/// Tuple of all migrated arm64 per-op modules.
pub const collected_arm64_ops = .{
    arm64_i32_add,
};

/// Tuple of all migrated x86_64 per-op modules.
pub const collected_x86_64_ops = .{
    x86_64_i32_add,
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

/// Per-arch axis dispatcher. Mirrors the Zone 1 IR-axis dispatcher
/// shape (see `src/ir/dispatch_collector.zig::dispatcher`). Returns
/// `error.NotMigrated` when the op has no per-arch handler yet (=
/// legacy switch in `<arch>/emit.zig` retains authority).
pub fn dispatcher(comptime axis: ArchAxis) fn (op: ZirOp, args: anytype) DispatchError!void {
    return struct {
        fn dispatch(op: ZirOp, args: anytype) DispatchError!void {
            const ops = comptime switch (axis) {
                .arm64 => collected_arm64_ops,
                .x86_64 => collected_x86_64_ops,
            };
            inline for (ops) |op_mod| {
                if (comptime !enabledByBuild(op_mod)) continue;
                if (op == op_mod.op_tag) {
                    return @call(.auto, op_mod.emit, args);
                }
            }
            return DispatchError.NotMigrated;
        }
    }.dispatch;
}

// ---------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------

test "ArchAxis enum has exactly 2 variants per ADR-0074 (Zone 2 arch-axes)" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(ArchAxis).@"enum".fields.len);
}

test "migratedArchOpCount tracks collected per-arch tuples (1 after B10)" {
    try std.testing.expectEqual(@as(usize, 1), migratedArchOpCount(.arm64));
    try std.testing.expectEqual(@as(usize, 1), migratedArchOpCount(.x86_64));
}

test "dispatcher(.arm64) routes i32.add to its per-arch stub (NotMigrated by design)" {
    const result = dispatcher(.arm64)(.@"i32.add", .{});
    try std.testing.expectError(error.NotMigrated, result);
}

test "dispatcher(.x86_64) routes i32.add to its per-arch stub (NotMigrated by design)" {
    const result = dispatcher(.x86_64)(.@"i32.add", .{});
    try std.testing.expectError(error.NotMigrated, result);
}

test "dispatcher returns NotMigrated for not-yet-migrated tags (both arches)" {
    try std.testing.expectError(error.NotMigrated, dispatcher(.arm64)(.@"unreachable", .{}));
    try std.testing.expectError(error.NotMigrated, dispatcher(.x86_64)(.@"unreachable", .{}));
}
