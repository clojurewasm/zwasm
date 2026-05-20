//! Module export lookup helpers.
//!
//! Companion to `engine/runner.zig`'s `findExportFunc` (which
//! stays in runner.zig for now — at the 2000-LOC hard cap, every
//! new addition lands here instead per D-141 / file_size_check
//! ratchet). This module focuses on "given wasm bytes + an export
//! name, find the indexed entity"; callers compose this with the
//! engine runtime to read or invoke the resolved entity.
//!
//! Zone 2 (`src/engine/`).

const std = @import("std");

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const runner_mod = @import("runner.zig");

const Allocator = std.mem.Allocator;
const Error = runner_mod.Error;

/// Find an exported global by name. Returns its global_idx in the
/// module's global index space (imports + defined). Used by the
/// §9.12-E spec runner `get-action` directive (Wasm spec `(get
/// "name")` action — reads a global's current value for an
/// `assert_return` comparison). Pairs with `runner.findExportFunc`
/// for the action-dispatcher discharge of `non-invoke-action`
/// skip-impl sites (master plan §5.3).
///
/// Returns `Error.ExportNotFound` when no export with that name
/// exists; `Error.ExportIsNotFunction` (reused with global
/// semantics — the error set has no dedicated `ExportIsNotGlobal`
/// variant yet) when the named export is not a global.
pub fn findExportGlobal(allocator: Allocator, wasm_bytes: []const u8, name: []const u8) Error!u32 {
    var module = try parser.parse(allocator, wasm_bytes);
    defer module.deinit(allocator);

    const export_section = module.find(.@"export") orelse return Error.ExportNotFound;
    var exports = try sections.decodeExports(allocator, export_section.body);
    defer exports.deinit();

    for (exports.items) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (e.kind != .global) return Error.ExportIsNotFunction;
        return e.idx;
    }
    return Error.ExportNotFound;
}

test "findExportGlobal: returns idx for named global export" {
    // Minimal module bytes containing:
    //   - magic + version
    //   - global section: 1 global, type=i32 const 42 mut=immut
    //   - export section: 1 export "g" → global 0
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, // \0asm
        0x01, 0x00, 0x00, 0x00, // version 1
        // type section (id=1) — required for some parsers; empty here
        // global section (id=6)
        0x06, 0x06, 0x01, 0x7f,
        0x00, 0x41, 0x2a, 0x0b,
        // export section (id=7) — 1 export "g" kind=global idx=0
        0x07, 0x05, 0x01, 0x01,
        0x67, 0x03, 0x00,
    };
    const idx = try findExportGlobal(std.testing.allocator, &bytes, "g");
    try std.testing.expectEqual(@as(u32, 0), idx);
}

test "findExportGlobal: ExportNotFound for missing name" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x06, 0x06, 0x01, 0x7f,
        0x00, 0x41, 0x2a, 0x0b,
        0x07, 0x05, 0x01, 0x01,
        0x67, 0x03, 0x00,
    };
    try std.testing.expectError(Error.ExportNotFound, findExportGlobal(std.testing.allocator, &bytes, "missing"));
}
