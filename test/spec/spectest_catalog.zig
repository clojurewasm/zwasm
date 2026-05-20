//! Spectest namespace export catalog.
//!
//! The WebAssembly spec testsuite imports a small standard set
//! of exports from the `spectest` module. Func exports (print,
//! print_i32, ...) are bound via the `d-35` trap stub at the
//! JIT layer. Non-func exports (globals / table / memory) have
//! historically been rejected wholesale by
//! `spec_assert_runner_base.zig::hasUnbindableImports`, which
//! emits SKIP-CROSS-MODULE-IMPORTS. This module is the seed
//! for the §9.12-E / D-153 discharge: it enumerates the 6
//! non-func exports + their canonical values per
//! `WebAssembly/spec/test/core/imports.wast`.
//!
//! Subsequent chunks (B147+) consume this catalog from
//! `hasUnbindableImports` + the `.module` setup path so the
//! 100 SKIP-CROSS-MODULE-IMPORTS sites can be re-classified.

const std = @import("std");
const zir = @import("zwasm").ir.zir;

/// A single non-func spectest export.
pub const SpectestExport = struct {
    name: []const u8,
    kind: enum { global, table, memory },
    /// `valtype` is meaningful for kind == .global only.
    /// `init_bits_lo` / `init_bits_hi` are the 64-bit little-endian
    /// representation of the initial value (i32 / i64 / f32 / f64
    /// bit patterns; upper 32 bits zero for 32-bit shapes).
    valtype: zir.ValType,
    init_bits: u64,
    /// Limits.min / limits.max are meaningful for kind ∈ {.table, .memory}.
    /// For tables, units = elements; for memories, units = wasm pages
    /// (64 KiB each). max = 0xFFFF_FFFF encodes "no maximum" per the
    /// wasm spec's optional max semantics.
    limits_min: u32,
    limits_max: u32,
};

/// Canonical spectest non-func exports per
/// `~/Documents/OSS/WebAssembly/spec/test/core/imports.wast`.
/// Values match the reference interpreter's `spectest.ml`:
///   global_i32 : (global i32 immutable) = 666
///   global_i64 : (global i64 immutable) = 666
///   global_f32 : (global f32 immutable) = 666.6
///   global_f64 : (global f64 immutable) = 666.6
///   table      : (table 10 20 funcref)
///   memory     : (memory 1 2)
pub const non_func_exports = [_]SpectestExport{
    .{
        .name = "global_i32",
        .kind = .global,
        .valtype = .i32,
        .init_bits = 666,
        .limits_min = 0,
        .limits_max = 0,
    },
    .{
        .name = "global_i64",
        .kind = .global,
        .valtype = .i64,
        .init_bits = 666,
        .limits_min = 0,
        .limits_max = 0,
    },
    .{
        .name = "global_f32",
        .kind = .global,
        .valtype = .f32,
        // 666.6 as f32 bits = 0x4426_6666
        .init_bits = 0x4426_6666,
        .limits_min = 0,
        .limits_max = 0,
    },
    .{
        .name = "global_f64",
        .kind = .global,
        .valtype = .f64,
        // 666.6 as f64 bits = 0x4084_CCCC_CCCC_CCCD
        .init_bits = 0x4084_CCCC_CCCC_CCCD,
        .limits_min = 0,
        .limits_max = 0,
    },
    .{
        .name = "table",
        .kind = .table,
        .valtype = .funcref,
        .init_bits = 0,
        .limits_min = 10,
        .limits_max = 20,
    },
    .{
        .name = "memory",
        .kind = .memory,
        .valtype = .i32, // unused for memory
        .init_bits = 0,
        .limits_min = 1,
        .limits_max = 2,
    },
};

/// Look up a spectest non-func export by name. Returns null
/// when the name isn't a known non-func spectest export
/// (caller can then attempt the func-export path).
pub fn findNonFuncExport(name: []const u8) ?SpectestExport {
    for (non_func_exports) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

test "findNonFuncExport: global_i32 returns i32 666" {
    const e = findNonFuncExport("global_i32").?;
    try std.testing.expectEqual(@as(u64, 666), e.init_bits);
    try std.testing.expectEqual(zir.ValType.i32, e.valtype);
}

test "findNonFuncExport: table returns funcref limits 10..20" {
    const e = findNonFuncExport("table").?;
    try std.testing.expectEqual(@as(u32, 10), e.limits_min);
    try std.testing.expectEqual(@as(u32, 20), e.limits_max);
    try std.testing.expectEqual(zir.ValType.funcref, e.valtype);
}

test "findNonFuncExport: unknown name returns null" {
    try std.testing.expect(findNonFuncExport("print_i32") == null);
    try std.testing.expect(findNonFuncExport("unknown") == null);
}
