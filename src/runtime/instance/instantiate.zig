//! Module-bytes → instantiated Runtime helpers.
//!
//! Per ADR-0023 §7 item 5: extracts the binding-agnostic
//! instantiation helpers from `api/instance.zig`. The helpers
//! here run after `api/wasm_module_new` has copied the bytes
//! into a `Module` handle and before the C-API binding hands
//! the resulting Runtime back to its caller.
//!
//! Step A1 (this file's first cut) covers the helpers that have
//! NO `Extern` / binding-handle dependency:
//!
//! - `frontendValidate` — read-only parse + per-fn validate pass.
//! - `validateNoCode` — short-circuit when the module has no code.
//! - `buildExportTypes` — populate `Instance.export_types` per
//!   ADR-0014 §3.4.10 (drives D-006's import-vs-export check).
//! - `evalConstExprValue` / `evalConstI32Expr` — Wasm const-
//!   expression evaluators for global init + active data offsets.
//!
//! Step A2 lands `instantiateRuntime` + `checkImportTypeMatches`
//! once an `ImportBinding` Zone-1-native type replaces the
//! current `?[*]const ?*const Extern` parameter; that step
//! discharges the §A2 hard-cap violation on `api/instance.zig`.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const runtime_mod = @import("../runtime.zig");
const parser = @import("../../parse/parser.zig");
const sections = @import("../../parse/sections.zig");
const validator = @import("../../validate/validator.zig");
const zir = @import("../../ir/zir.zig");
const leb128 = @import("../../support/leb128.zig");

const Module = runtime_mod.Module;
const Value = runtime_mod.Value;
const ExportType = runtime_mod.ExportType;

/// Run the frontend pipeline (parse + section decode + per-fn
/// validate) over `binary`. Returns `true` on success. Caller
/// owns nothing — this is the read-only validate path.
pub fn frontendValidate(alloc: std.mem.Allocator, binary: []const u8) bool {
    var module = parser.parse(alloc, binary) catch return false;
    defer module.deinit(alloc);

    const type_section = module.find(.@"type") orelse return validateNoCode(alloc, &module);
    const code_section = module.find(.code) orelse return true;

    var types_owned = sections.decodeTypes(alloc, type_section.body) catch return false;
    defer types_owned.deinit();

    const func_section = module.find(.function);
    const defined_func_indices = if (func_section) |s|
        sections.decodeFunctions(alloc, s.body) catch return false
    else
        alloc.alloc(u32, 0) catch return false;
    defer alloc.free(defined_func_indices);

    var codes_owned = sections.decodeCodes(alloc, code_section.body) catch return false;
    defer codes_owned.deinit();

    if (codes_owned.items.len != defined_func_indices.len) return false;

    // `func_types` must span the full funcidx space (imports
    // first, then defined) — the validator's `call N` checks
    // `func_types[N]` and N can reference an imported function.
    var imports_decoded: ?sections.Imports = if (module.find(.import)) |sec|
        sections.decodeImports(alloc, sec.body) catch return false
    else
        null;
    defer if (imports_decoded) |*im| im.deinit();

    var imp_func_count: usize = 0;
    var imp_global_count: usize = 0;
    var imp_table_count: usize = 0;
    if (imports_decoded) |im| for (im.items) |it| switch (it.kind) {
        .func => imp_func_count += 1,
        .global => imp_global_count += 1,
        .table => imp_table_count += 1,
        .memory => {
            // Imported memories aren't counted by this loop —
            // function/global/table tallies feed `func_types` sizing.
        },
    };

    const func_types = alloc.alloc(zir.FuncType, imp_func_count + defined_func_indices.len) catch return false;
    defer alloc.free(func_types);
    {
        var cursor: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .func) continue;
            const ti = it.payload.func_typeidx;
            if (ti >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[ti];
            cursor += 1;
        };
        for (defined_func_indices) |type_idx| {
            if (type_idx >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[type_idx];
            cursor += 1;
        }
    }

    // global / table entries — built over the full imports +
    // defined index space so `global.get` and `table.*` ops
    // type-check properly. Mirrors test/spec/runner.zig.
    var globals_owned: ?sections.Globals = if (module.find(.global)) |s|
        sections.decodeGlobals(alloc, s.body) catch return false
    else
        null;
    defer if (globals_owned) |*g| g.deinit();
    const def_global_count: usize = if (globals_owned) |g| g.items.len else 0;
    const global_entries = alloc.alloc(validator.GlobalEntry, imp_global_count + def_global_count) catch return false;
    defer alloc.free(global_entries);
    {
        var cursor: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .global) continue;
            global_entries[cursor] = .{
                .valtype = it.payload.global.valtype,
                .mutable = it.payload.global.mutable,
            };
            cursor += 1;
        };
        if (globals_owned) |g| for (g.items) |gd| {
            global_entries[cursor] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
            cursor += 1;
        };
    }

    var tables_owned: ?sections.Tables = if (module.find(.table)) |s|
        sections.decodeTables(alloc, s.body) catch return false
    else
        null;
    defer if (tables_owned) |*t| t.deinit();
    const def_table_count: usize = if (tables_owned) |t| t.items.len else 0;
    const table_entries = alloc.alloc(zir.TableEntry, imp_table_count + def_table_count) catch return false;
    defer alloc.free(table_entries);
    {
        var cursor: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .table) continue;
            // Imported table descriptions come kind-only via §A10;
            // synthesise a permissive funcref so `table.*` ops
            // don't trip bounds checks during validation.
            table_entries[cursor] = .{ .elem_type = .funcref, .min = 0 };
            cursor += 1;
        };
        if (tables_owned) |t| for (t.items) |entry| {
            table_entries[cursor] = entry;
            cursor += 1;
        };
    }

    for (codes_owned.items, defined_func_indices) |code, type_idx| {
        const sig = types_owned.items[type_idx];
        validator.validateFunction(
            sig,
            code.locals,
            code.body,
            func_types,
            global_entries,
            types_owned.items,
            0, // data_count
            table_entries,
            0, // elem_count
        ) catch return false;
    }
    return true;
}

pub fn validateNoCode(_: std.mem.Allocator, _: *Module) bool {
    // No code section: nothing per-function to validate. The
    // module's section-id ordering was already checked by
    // parser.parse, which is sufficient.
    return true;
}

/// Build the `[]ExportType` parallel slice that populates
/// `Instance.export_types`. For each export the import-section
/// decode resolves the funcidx / tableidx / memidx / globalidx
/// to a concrete structural type, so cross-module import-vs-
/// export checking at the c_api boundary is a direct compare.
/// For each export:
/// - Func: walk imports + defined-funcs to find which one is at
///   `idx`; resolve typeidx via the source's type section.
/// - Global: walk imports + decoded globals for type info.
/// - Table: walk imports + decoded tables for elem_type + limits.
/// - Memory: walk imports + decoded memories for limits.
pub fn buildExportTypes(
    a: std.mem.Allocator,
    module: Module,
    exports_items: []sections.Export,
    imports_decoded: ?sections.Imports,
) ![]ExportType {
    if (exports_items.len == 0) return &.{};
    const out = try a.alloc(ExportType, exports_items.len);
    errdefer a.free(out);

    // Decode the type section once (used for func sig resolution).
    var types_owned: ?sections.Types = null;
    defer if (types_owned) |*t| t.deinit();
    if (module.find(.@"type")) |s| {
        types_owned = try sections.decodeTypes(a, s.body);
    }
    var func_section_funcs: ?[]u32 = null;
    if (module.find(.function)) |s| {
        func_section_funcs = try sections.decodeFunctions(a, s.body);
    }
    defer if (func_section_funcs) |slice| a.free(slice);

    var defined_globals: ?sections.Globals = null;
    defer if (defined_globals) |*g| g.deinit();
    if (module.find(.global)) |s| {
        defined_globals = try sections.decodeGlobals(a, s.body);
    }
    var defined_tables: ?sections.Tables = null;
    defer if (defined_tables) |*t| t.deinit();
    if (module.find(.table)) |s| {
        defined_tables = try sections.decodeTables(a, s.body);
    }
    var defined_memories: ?sections.Memories = null;
    defer if (defined_memories) |*m| m.deinit();
    if (module.find(.memory)) |s| {
        defined_memories = try sections.decodeMemory(a, s.body);
    }

    for (exports_items, 0..) |exp, i| {
        out[i] = switch (exp.kind) {
            .func => blk: {
                // Find this funcidx among (imports' funcs ++ defined funcs).
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .func) continue;
                        if (idx == exp.idx) {
                            const tidx = it.payload.func_typeidx;
                            const ft = if (types_owned) |t| t.items[tidx] else
                                return error.UnsupportedImport;
                            break :blk .{ .func = ft };
                        }
                        idx += 1;
                    }
                    imp_count = idx; // total func imports walked
                }
                // Defined func: index = exp.idx - imp_count
                const def_idx = exp.idx - imp_count;
                const fs = func_section_funcs orelse return error.UnsupportedImport;
                if (def_idx >= fs.len) return error.UnsupportedImport;
                const tidx = fs[def_idx];
                const ft = if (types_owned) |t| t.items[tidx] else
                    return error.UnsupportedImport;
                break :blk .{ .func = ft };
            },
            .table => blk: {
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .table) continue;
                        if (idx == exp.idx) {
                            const t = it.payload.table;
                            break :blk .{ .table = .{ .elem_type = t.elem_type, .min = t.min, .max = t.max } };
                        }
                        idx += 1;
                    }
                    imp_count = idx;
                }
                const def_idx = exp.idx - imp_count;
                const dt = (defined_tables orelse return error.UnsupportedImport).items;
                if (def_idx >= dt.len) return error.UnsupportedImport;
                const t = dt[def_idx];
                break :blk .{ .table = .{ .elem_type = t.elem_type, .min = t.min, .max = t.max } };
            },
            .memory => blk: {
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .memory) continue;
                        if (idx == exp.idx) {
                            const m = it.payload.memory;
                            break :blk .{ .memory = .{ .min = m.min, .max = m.max } };
                        }
                        idx += 1;
                    }
                    imp_count = idx;
                }
                const def_idx = exp.idx - imp_count;
                const dm = (defined_memories orelse return error.UnsupportedImport).items;
                if (def_idx >= dm.len) return error.UnsupportedImport;
                const m = dm[def_idx];
                break :blk .{ .memory = .{ .min = m.min, .max = m.max } };
            },
            .global => blk: {
                var imp_count: u32 = 0;
                if (imports_decoded) |im| {
                    var idx: u32 = 0;
                    for (im.items) |it| {
                        if (it.kind != .global) continue;
                        if (idx == exp.idx) {
                            const g = it.payload.global;
                            break :blk .{ .global = .{ .valtype = g.valtype, .mutable = g.mutable } };
                        }
                        idx += 1;
                    }
                    imp_count = idx;
                }
                const def_idx = exp.idx - imp_count;
                const dg = (defined_globals orelse return error.UnsupportedImport).items;
                if (def_idx >= dg.len) return error.UnsupportedImport;
                const g = dg[def_idx];
                break :blk .{ .global = .{ .valtype = g.valtype, .mutable = g.mutable } };
            },
        };
    }
    return out;
}

/// Evaluate a global init-expression and return the initial Value.
/// Supported shapes for v0.1.0: `<i32|i64|f32|f64>.const N; end`
/// and `ref.null funcref|externref; end`. `global.get N` (importing
/// from another module's globals) defers with the rest of cross-
/// module global imports.
pub fn evalConstExprValue(expr: []const u8) !Value {
    if (expr.len < 2) return error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v: Value = switch (expr[0]) {
        0x41 => blk: {
            const n = try leb128.readSleb128(i32, expr, &pos);
            break :blk .{ .i32 = n };
        },
        0x42 => blk: {
            const n = try leb128.readSleb128(i64, expr, &pos);
            break :blk .{ .i64 = n };
        },
        0x43 => blk: {
            if (pos + 4 > expr.len) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u32, expr[pos..][0..4], .little);
            pos += 4;
            break :blk .{ .bits64 = bits };
        },
        0x44 => blk: {
            if (pos + 8 > expr.len) return error.UnsupportedConstExpr;
            const bits = std.mem.readInt(u64, expr[pos..][0..8], .little);
            pos += 8;
            break :blk .{ .bits64 = bits };
        },
        0xD0 => blk: {
            if (pos >= expr.len) return error.UnsupportedConstExpr;
            pos += 1;
            break :blk .{ .ref = Value.null_ref };
        },
        else => return error.UnsupportedConstExpr,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
    return v;
}

/// Evaluate a Wasm const-expression that resolves to an i32.
/// Active data-segment offsets currently reach this path; the
/// only shape v0.1.0 needs is `i32.const N; end` (3+ bytes:
/// opcode 0x41, sleb128 N, opcode 0x0B).
pub fn evalConstI32Expr(expr: []const u8) !i32 {
    if (expr.len < 2 or expr[0] != 0x41) return error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v = try leb128.readSleb128(i32, expr, &pos);
    if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
    return v;
}
