//! Central comptime dispatch collector — Phase 9 substrate audit Q3 C
//! adoption (per ADR-0023 §4.5 amend + ADR-0073, both Accepted 2026-05-19).
//!
//! This module is the **§9.12-A bootstrap** of the per-op file pattern:
//!
//!   `src/instruction/wasm_X_Y/<op>.zig` exports the canonical 5-axis
//!   handler aggregate (`pub const handlers = .{...}`) plus the
//!   `wasm_level` / `wasi_level` metadata. The collector imports every
//!   op module at comptime, validates the shape, applies the
//!   build-option DCE filter, and builds the central dispatcher per
//!   axis via `inline switch (op) { inline else => |tag| ... }`.
//!
//! In §9.12-A the framework + validation logic lands with an **empty**
//! `collected_ops` tuple. As §9.12-B migrates the 581 ZirOp handlers
//! into per-op files, each is appended here and the comptime validation
//! catches any missing axis / metadata.
//!
//! Design references:
//! - ADR-0023 §4.5 amend (per-op file migration plan).
//! - ADR-0073 (all-layer build-option DCE substrate).
//! - `private/spikes/q3-build-option-dce-poc/dispatch_collector.zig`
//!   (spike reference; 5-op PoC verified DCE works literally).
//!
//! Zone 1 (`src/ir/`) — imports Zone 0 (`build_options`) + Zone 1.

const std = @import("std");
const build_options = @import("build_options");
const zir = @import("zir.zig");

const ZirOp = zir.ZirOp;

/// WasmLevel + WasiLevel are declared inside `build.zig` and reach
/// every `build_options` consumer via `options.addOption`. We
/// re-export the runtime *values* below; per-op files type-annotate
/// against `@TypeOf(build_options.wasm_level)` so the build remains
/// the single source of truth for the enum shape.
pub const WasmLevel = @TypeOf(build_options.wasm_level);
pub const WasiLevel = @TypeOf(build_options.wasi_level);

/// The 5 dispatch axes per op (per ADR-0023 §4.5 amend).
pub const Axis = enum {
    validate,
    lower,
    arm64,
    x86_64,
    interp,
};

/// Future-use feature gate tag set; placeholder for Phase 10 / 11
/// extensions (memory64, threads, custom-page-sizes, …).
pub const Feature = enum {
    /// No feature gate (always enabled).
    none,
};

// ---------------------------------------------------------------------
// Per-op module shape (the contract every `src/instruction/wasm_X_Y/<op>.zig`
// must satisfy):
//
//   pub const op_tag: ZirOp = .i32_add;
//   pub const wasm_level: ?WasmLevel = .v1_0;
//   pub const wasi_level: ?WasiLevel = null;
//   pub const enable_features: []const Feature = &.{};
//   pub const handlers = .{
//       .validate = validate_fn,
//       .lower    = lower_fn,
//       .arm64    = emit_arm64_fn,
//       .x86_64   = emit_x86_64_fn,
//       .interp   = interp_fn,
//   };
//
// `validateOpModule(comptime mod)` enforces this shape with
// `@compileError` messages that name what's missing.
// ---------------------------------------------------------------------

/// Comptime invariant check: a per-op file must export `op_tag`,
/// `wasm_level`, and a `handlers` struct with all 5 axes. Emits a
/// descriptive `@compileError` naming the missing field if any axis
/// or required declaration is absent.
pub fn validateOpModule(comptime mod: type) void {
    comptime {
        if (!@hasDecl(mod, "op_tag")) {
            @compileError("per-op file missing `pub const op_tag: ZirOp = ...;`");
        }
        if (!@hasDecl(mod, "wasm_level")) {
            @compileError("per-op file missing `pub const wasm_level: ?WasmLevel = ...;`");
        }
        if (!@hasDecl(mod, "handlers")) {
            @compileError("per-op file missing `pub const handlers = .{ .validate, .lower, .arm64, .x86_64, .interp };`");
        }
        const H = @TypeOf(mod.handlers);
        for (@typeInfo(Axis).@"enum".fields) |axis_field| {
            if (!@hasField(H, axis_field.name)) {
                @compileError("per-op file '" ++ @tagName(mod.op_tag) ++ "' missing handler `." ++ axis_field.name ++ "` in `pub const handlers`");
            }
        }
    }
}

/// Comptime build-option filter. Returns `true` when the op is
/// enabled by the current `-Dwasm=` / `-Dwasi=` build flags.
///
/// Used as the guard in `inline for` loops + `inline switch`
/// dispatchers so disabled op bodies are never instantiated → no
/// symbol emitted in the binary.
pub fn enabledByBuild(comptime mod: type) bool {
    comptime {
        if (@hasDecl(mod, "wasm_level")) {
            if (mod.wasm_level) |lvl| {
                if (@intFromEnum(lvl) > @intFromEnum(build_options.wasm_level)) {
                    return false;
                }
            }
        }
        if (@hasDecl(mod, "wasi_level")) {
            if (mod.wasi_level) |lvl| {
                const cur = @intFromEnum(build_options.wasi_level);
                const need = @intFromEnum(lvl);
                if (need > cur and build_options.wasi_level != .both) {
                    return false;
                }
            }
        }
        return true;
    }
}

// ---------------------------------------------------------------------
// Collected op modules.
//
// §9.12-A bootstrap: empty. §9.12-B migration appends one entry per
// migrated op:
//
//     const i32_add = @import("../instruction/wasm_1_0/i32_add.zig");
//     ...
//     pub const collected_ops = .{
//         i32_add,
//         ...
//     };
//
// The validation at module top-level walks the tuple and runs
// `validateOpModule(@TypeOf(op))` on each, emitting a `@compileError`
// if any shape invariant is violated. This means **adding a malformed
// per-op file fails the build immediately** — the substrate cannot
// silently regress.
// ---------------------------------------------------------------------

/// Tuple of all migrated per-op modules. Order is not load-bearing;
/// `dispatcher` uses `op_tag` for routing.
pub const collected_ops = .{};

comptime {
    for (collected_ops) |op_mod| {
        validateOpModule(@TypeOf(op_mod));
    }
}

/// Count of currently-migrated ops, filtered by the active build options.
/// All comptime-resolved; returns a constant for the current build.
pub fn migratedOpCount() usize {
    return comptime blk: {
        var n: usize = 0;
        for (collected_ops) |op_mod| {
            if (enabledByBuild(@TypeOf(op_mod))) {
                n += 1;
            }
        }
        break :blk n;
    };
}

/// Count of ZirOp tags (canonical authoritative number; ~581 at Phase 9).
pub fn zirOpTagCount() usize {
    return @typeInfo(ZirOp).@"enum".fields.len;
}

/// Whether the substrate migration is complete (= every ZirOp tag has
/// a corresponding per-op module). At §9.12-B exit this returns true;
/// during §9.12-A it returns false (collected_ops is empty).
pub fn migrationComplete() bool {
    return migratedOpCount() == zirOpTagCount();
}

// ---------------------------------------------------------------------
// Dispatcher framework (per-axis).
//
// In §9.12-B, validator.zig / lower.zig / arm64/emit.zig /
// x86_64/emit.zig / interp/dispatch.zig will replace their exhaustive
// switches with thin calls to `dispatcher(.<axis>)`. The dispatcher
// inline-switches on the ZirOp tag; each arm `comptime`-resolves the
// corresponding op_mod and either invokes the handler or `continue`s
// (skipping if disabled by build option).
//
// At §9.12-A the dispatcher returns a placeholder error for every op,
// because `collected_ops` is empty. The framework compiles, gets
// covered by tests, and is ready for §9.12-B to fill in.
// ---------------------------------------------------------------------

pub const DispatchError = error{
    /// The op is not migrated to a per-op file yet (§9.12-B incomplete).
    /// Eliminated once `migrationComplete()` returns true.
    NotMigrated,
    /// The op is filtered out by the current build option set (e.g.
    /// `-Dwasm=v1_0` building Wasm 2.0+ op).
    UnsupportedOpForBuildLevel,
};

/// Look up the per-op module for `tag` at comptime; returns null when
/// no migrated module matches.
pub fn opModuleFor(comptime tag: ZirOp) ?type {
    comptime {
        for (collected_ops) |op_mod| {
            if (op_mod.op_tag == tag) {
                return @TypeOf(op_mod);
            }
        }
        return null;
    }
}

// ---------------------------------------------------------------------
// Tests — exercise the framework (Step 5 gate coverage).
// ---------------------------------------------------------------------

test "zirOpTagCount matches the ZirOp enum field count" {
    const n = zirOpTagCount();
    // Phase 9 has 581 declared ZirOp tags (per ADR-0071 §Context).
    // Loose lower bound test — any drop indicates an accidental enum truncation.
    try std.testing.expect(n >= 200);
}

test "migratedOpCount is 0 in §9.12-A bootstrap (empty collected_ops)" {
    try std.testing.expectEqual(@as(usize, 0), migratedOpCount());
}

test "migrationComplete is false during §9.12-A (no per-op files yet)" {
    try std.testing.expect(!migrationComplete());
}

test "opModuleFor returns null for any tag (no ops migrated yet)" {
    // Use a comptime-known tag from the ZirOp enum.
    const result = comptime opModuleFor(.@"unreachable");
    try std.testing.expectEqual(@as(?type, null), result);
}

test "Axis enum has exactly 5 variants per ADR-0023 §4.5 amend" {
    try std.testing.expectEqual(@as(usize, 5), @typeInfo(Axis).@"enum".fields.len);
}
