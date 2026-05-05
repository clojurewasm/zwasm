//! Module-bytes → instantiated Runtime helpers.
//!
//! Per ADR-0023 §7 item 5: extracts the binding-agnostic
//! instantiation helpers from `api/instance.zig`. The helpers
//! here run after `api/wasm_module_new` has copied the bytes
//! into a `Module` handle and before the C-API binding hands
//! the resulting Runtime back to its caller.
//!
//! Helpers with NO binding dependency (Step A1):
//!
//! - `frontendValidate` — read-only parse + per-fn validate pass.
//! - `validateNoCode` — short-circuit when the module has no code.
//! - `buildExportTypes` — populate `Instance.export_types` per
//!   ADR-0014 §3.4.10 (drives D-006's import-vs-export check).
//! - `evalConstExprValue` / `evalConstI32Expr` — Wasm const-
//!   expression evaluators for global init + active data offsets.
//!
//! Step A2 (this commit) adds `instantiateRuntime` and
//! `checkImportTypeMatches`. The former takes `?[]const
//! ImportBinding` (Zone-1 native, per `import.zig`) instead of
//! the previous `?[*]const ?*const Extern`; the C-API binding
//! pre-resolves every import (Extern lookup, WASI thunk lookup,
//! CallCtx allocation) into the binding before calling here.
//! The latter does a pure data compare — both expected and
//! source descriptors travel inside each `ImportBinding`
//! variant, so no source-binary re-decode is needed.
//!
//! Zone 1 (`src/runtime/`).

const std = @import("std");

const runtime_mod = @import("../runtime.zig");
const lower = @import("../../ir/lower.zig");
const loop_info_mod = @import("../../ir/analysis/loop_info.zig");
const verifier_mod = @import("../../ir/verifier.zig");
const parser = @import("../../parse/parser.zig");
const sections = @import("../../parse/sections.zig");
const validator = @import("../../validate/validator.zig");
const zir = @import("../../ir/zir.zig");
const leb128 = @import("../../support/leb128.zig");
const dbg = @import("../../support/dbg.zig");
const import_mod = @import("import.zig");
const instance_mod = @import("instance.zig");

const Module = runtime_mod.Module;
const Value = runtime_mod.Value;
const ExportType = runtime_mod.ExportType;
const Runtime = runtime_mod.Runtime;
const HostCall = runtime_mod.HostCall;
const FuncEntity = runtime_mod.FuncEntity;
const TableInstance = runtime_mod.TableInstance;
const Instance = instance_mod.Instance;
const ImportBinding = import_mod.ImportBinding;

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

/// Instantiate `bytes` into `rt`, wiring every import via
/// `bindings` (one per `(import ...)` row in declaration order).
/// Pass `null` when the module has no imports.
///
/// Caller responsibilities (per ADR-0014 §2.2 / 6.K.2):
/// - `inst.arena` is already allocated and assigned (the binding
///   side wants to allocate `bindings[]` + cross-module CallCtx
///   on the same arena BEFORE this fn runs).
/// - `rt.alloc` is already rebound to `inst.arena.?.allocator()`.
/// - `rt.instance` is already set to `inst`.
///
/// Per ADR-0023 §7 item 5 (Step A2): the C-API binding
/// pre-resolves all imports — including WASI thunk lookup and
/// cross-module CallCtx allocation — into `ImportBinding`
/// values before calling here. This file is therefore unaware
/// of `Extern`, `wasi.lookupWasiThunk`, or `cross_module.CallCtx`,
/// and the runtime-side type-match check is a pure data compare.
pub fn instantiateRuntime(
    bytes: []const u8,
    inst: *Instance,
    rt: *Runtime,
    bindings: ?[]const ImportBinding,
) !void {
    const a = (inst.arena orelse return error.InvalidModule).allocator();

    var module = try parser.parse(a, bytes);
    defer module.deinit(a);

    // §9.4 / 4.7 + §9.6 / 6.E iter 7: import section. Every import
    // resolution comes from `bindings[i]` (the binding-side has
    // already done WASI thunk lookup or cross-module Extern
    // resolution).
    var imports_decoded: ?sections.Imports = null;
    defer if (imports_decoded) |*im| im.deinit();
    if (module.find(.import)) |import_section| {
        imports_decoded = try sections.decodeImports(a, import_section.body);
        for (imports_decoded.?.items, 0..) |it, idx| {
            const arr = bindings orelse return error.UnknownImportModule;
            if (idx >= arr.len) return error.UnknownImportModule;
            const binding = arr[idx];
            // Kind compatibility: each `ImportBinding` variant must
            // match the importer-declared kind.
            const binding_kind: sections.ImportKind = switch (binding) {
                .func => .func,
                .table => .table,
                .memory => .memory,
                .global => .global,
            };
            if (binding_kind != it.kind) return error.ImportKindMismatch;
            // Per Wasm 2.0 §3.4.10: import-vs-export type matching.
            // Pure data compare — both expected and source
            // descriptors live inside the binding.
            try checkImportTypeMatches(a, module, it, binding);
        }
    }

    var imp_func_count: u32 = 0;
    var imp_table_count: u32 = 0;
    var imp_memory_count: u32 = 0;
    var imp_global_count: u32 = 0;
    if (imports_decoded) |im| for (im.items) |it| switch (it.kind) {
        .func => imp_func_count += 1,
        .table => imp_table_count += 1,
        .memory => imp_memory_count += 1,
        .global => imp_global_count += 1,
    };

    // Type / function / code sections may be absent for modules
    // that only re-export imports.
    const code_section_opt = module.find(.code);
    const func_section = module.find(.function);
    const type_section_opt = module.find(.@"type");

    const types = if (type_section_opt) |s|
        try sections.decodeTypes(a, s.body)
    else
        sections.Types{ .arena = std.heap.ArenaAllocator.init(a), .items = &.{} };

    var funcs: []zir.ZirFunc = &.{};
    if (code_section_opt) |code_section| {
        const def_idx = if (func_section) |s|
            try sections.decodeFunctions(a, s.body)
        else
            try a.alloc(u32, 0);

        const codes = try sections.decodeCodes(a, code_section.body);
        if (codes.items.len != def_idx.len) return error.InvalidModule;

        funcs = try a.alloc(zir.ZirFunc, codes.items.len);
        for (codes.items, def_idx, 0..) |code, type_idx, i| {
            if (type_idx >= types.items.len) return error.InvalidTypeIndex;
            funcs[i] = zir.ZirFunc.init(@intCast(imp_func_count + i), types.items[type_idx], code.locals);
            try lower.lowerFunctionBody(a, code.body, &funcs[i], types.items);
            funcs[i].loop_info = try loop_info_mod.compute(a, &funcs[i]);
            verifier_mod.verify(&funcs[i]) catch return error.InvalidModule;
        }
    }
    inst.funcs_storage = funcs;

    const total_funcs = imp_func_count + funcs.len;
    const func_ptrs = try a.alloc(*const zir.ZirFunc, total_funcs);
    if (imp_func_count > 0) {
        const placeholder = try a.create(zir.ZirFunc);
        placeholder.* = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
        try placeholder.instrs.append(a, .{ .op = .@"unreachable", .payload = 0, .extra = 0 });
        for (0..imp_func_count) |i| func_ptrs[i] = placeholder;
    }
    for (funcs, 0..) |*f, i| func_ptrs[imp_func_count + i] = f;
    inst.func_ptrs_storage = func_ptrs;

    // host_calls — copy the pre-built HostCall from each func
    // binding into the corresponding slot. Defined funcs sit at
    // the higher indices and stay null.
    if (imp_func_count > 0) {
        const host_calls = try a.alloc(?HostCall, total_funcs);
        @memset(host_calls, null);
        var imp_idx: u32 = 0;
        for (imports_decoded.?.items, 0..) |it, idx| {
            if (it.kind != .func) continue;
            host_calls[imp_idx] = bindings.?[idx].func.host_call;
            imp_idx += 1;
        }
        rt.host_calls = host_calls;
    }

    rt.funcs = func_ptrs;
    rt.module_types = types.items;

    // §9.6 / 6.K.1 (ADR-0014 §2.1): per-instance FuncEntity array.
    // Imported funcs (per 6.K.3) point at the source runtime so
    // call_indirect through a foreign-funcref cell routes via
    // FuncEntity.runtime. WASI imports keep the local placeholder
    // (WASI is always called by funcidx, never by ref).
    if (total_funcs > 0) {
        const entities = try a.alloc(FuncEntity, total_funcs);
        for (0..total_funcs) |i| entities[i] = .{
            .runtime = rt,
            .func_idx = @intCast(i),
        };
        if (imp_func_count > 0) {
            var imp_idx: u32 = 0;
            for (imports_decoded.?.items, 0..) |it, idx| {
                if (it.kind != .func) continue;
                const fb = bindings.?[idx].func;
                switch (fb.source) {
                    .cross_module => |cm| {
                        entities[imp_idx] = .{
                            .runtime = cm.source_runtime,
                            .func_idx = cm.source_funcidx,
                        };
                    },
                    .wasi => {
                        // Local placeholder remains in place.
                    },
                }
                imp_idx += 1;
            }
        }
        rt.func_entities = entities;
    }

    // Memory wiring. Imported memory aliases the source's slice
    // (no copy); defined memory is allocated locally.
    if (imp_memory_count > 1) return error.MultiMemoryUnsupported;
    if (imp_memory_count == 1) {
        for (imports_decoded.?.items, 0..) |it, idx| {
            if (it.kind != .memory) continue;
            rt.memory = bindings.?[idx].memory.memory;
            break;
        }
    } else if (module.find(.memory)) |memory_section| {
        var memories = try sections.decodeMemory(a, memory_section.body);
        defer memories.deinit();
        if (memories.items.len > 1) return error.MultiMemoryUnsupported;
        if (memories.items.len == 1) {
            const pages = memories.items[0].min;
            const bytes_total: usize = @as(usize, pages) * 65536;
            const mem = try a.alloc(u8, bytes_total);
            @memset(mem, 0);
            rt.memory = mem;
            dbg.print("instantiate.alloc", "memory rt={x} ptr={x} len={d}", .{
                @intFromPtr(rt), @intFromPtr(mem.ptr), mem.len,
            });
        }
    }

    if (module.find(.data)) |data_section| {
        var datas = try sections.decodeData(a, data_section.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            if (seg.memidx != 0) return error.MultiMemoryUnsupported;
            const offset = try evalConstI32Expr(seg.offset_expr);
            const dst_end = @as(usize, @intCast(offset)) + seg.bytes.len;
            if (dst_end > rt.memory.len) return error.DataSegmentOutOfRange;
            @memcpy(rt.memory[@intCast(offset)..dst_end], seg.bytes);
        }
    }

    // Tables. Imported tables value-copy the source TableInstance
    // (the refs slice is shared). Defined tables get freshly
    // allocated refs from the per-instance arena.
    {
        var tables_owned: ?sections.Tables = if (module.find(.table)) |s|
            try sections.decodeTables(a, s.body)
        else
            null;
        defer if (tables_owned) |*t| t.deinit();
        const def_table_count: u32 = if (tables_owned) |t| @intCast(t.items.len) else 0;
        const total_table_count: u32 = imp_table_count + def_table_count;
        if (total_table_count > 0) {
            const tbl_storage = try a.alloc(TableInstance, total_table_count);
            if (imp_table_count > 0) {
                var imp_idx: u32 = 0;
                for (imports_decoded.?.items, 0..) |it, idx| {
                    if (it.kind != .table) continue;
                    tbl_storage[imp_idx] = bindings.?[idx].table.instance;
                    imp_idx += 1;
                }
            }
            if (tables_owned) |t| for (t.items, 0..) |entry, i| {
                const refs = try a.alloc(Value, entry.min);
                for (refs) |*r| r.* = .{ .ref = Value.null_ref };
                tbl_storage[imp_table_count + i] = .{
                    .refs = refs,
                    .elem_type = entry.elem_type,
                    .max = entry.max,
                };
            };
            rt.tables = tbl_storage;
        }
    }

    // Element segments.
    if (module.find(.element)) |elem_section| {
        var elems = try sections.decodeElement(a, elem_section.body);
        defer elems.deinit();
        if (elems.items.len > 0) {
            const seg_storage = try a.alloc([]const Value, elems.items.len);
            const dropped = try a.alloc(bool, elems.items.len);
            @memset(dropped, false);
            for (elems.items, 0..) |seg, idx| {
                const refs = try a.alloc(Value, seg.funcidxs.len);
                for (seg.funcidxs, 0..) |fidx, j| {
                    refs[j] = if (fidx == std.math.maxInt(u32))
                        .{ .ref = Value.null_ref }
                    else if (fidx < rt.func_entities.len)
                        Value.fromFuncRef(&rt.func_entities[fidx])
                    else
                        return error.InvalidElementFuncIndex;
                }
                seg_storage[idx] = refs;
                if (seg.kind == .active) {
                    if (seg.tableidx >= rt.tables.len) return error.InvalidTableIndex;
                    const offset = try evalConstI32Expr(seg.offset_expr);
                    const off_usize: usize = @intCast(offset);
                    const dst_end = off_usize + refs.len;
                    if (dst_end > rt.tables[seg.tableidx].refs.len) return error.ElementSegmentOutOfRange;
                    @memcpy(rt.tables[seg.tableidx].refs[off_usize..dst_end], refs);
                    dropped[idx] = true;
                } else if (seg.kind == .declarative) {
                    dropped[idx] = true;
                }
            }
            rt.elems = seg_storage;
            rt.elem_dropped = dropped;
        }
    }

    // Globals. Imported globals alias source-instance slots via
    // per-slot pointer; defined globals point at arena-owned
    // slots in `globals_storage`.
    {
        var defined_count: usize = 0;
        if (module.find(.global)) |global_section| {
            var globals = try sections.decodeGlobals(a, global_section.body);
            defer globals.deinit();
            defined_count = globals.items.len;

            const total = imp_global_count + defined_count;
            if (total > 0) {
                const slots = try a.alloc(*Value, total);
                const storage = try a.alloc(Value, defined_count);
                if (imp_global_count > 0) {
                    var imp_idx: u32 = 0;
                    for (imports_decoded.?.items, 0..) |it, idx| {
                        if (it.kind != .global) continue;
                        slots[imp_idx] = bindings.?[idx].global.slot;
                        imp_idx += 1;
                    }
                }
                for (globals.items, 0..) |g, i| {
                    storage[i] = try evalConstExprValue(g.init_expr);
                    slots[imp_global_count + i] = &storage[i];
                }
                rt.globals = slots;
                rt.globals_storage = storage;
            }
        } else if (imp_global_count > 0) {
            const slots = try a.alloc(*Value, imp_global_count);
            var imp_idx: u32 = 0;
            for (imports_decoded.?.items, 0..) |it, idx| {
                if (it.kind != .global) continue;
                slots[imp_idx] = bindings.?[idx].global.slot;
                imp_idx += 1;
            }
            rt.globals = slots;
        }
    }

    if (module.find(.@"export")) |export_section| {
        const exports = try sections.decodeExports(a, export_section.body);
        inst.exports_storage = exports.items;
        inst.export_types = try buildExportTypes(a, module, exports.items, imports_decoded);
    }
}

/// Wasm 2.0 §3.4.10 import-matching check. The importer's
/// `it.payload` carries its expected type; the binding carries
/// the source's actual type. Compare the two.
fn checkImportTypeMatches(
    a: std.mem.Allocator,
    module: Module,
    it: sections.Import,
    binding: ImportBinding,
) !void {
    switch (it.kind) {
        .func => {
            const want_tidx = it.payload.func_typeidx;
            const type_sec = module.find(.@"type") orelse return error.ImportTypeMismatch;
            var types = try sections.decodeTypes(a, type_sec.body);
            defer types.deinit();
            if (want_tidx >= types.items.len) return error.ImportTypeMismatch;
            const want_ft = types.items[want_tidx];
            switch (binding.func.source) {
                .cross_module => |cm| {
                    const sft = cm.source_signature;
                    if (sft.params.len != want_ft.params.len) return error.ImportTypeMismatch;
                    if (sft.results.len != want_ft.results.len) return error.ImportTypeMismatch;
                    for (sft.params, want_ft.params) |sp, wp| {
                        if (sp != wp) return error.ImportTypeMismatch;
                    }
                    for (sft.results, want_ft.results) |sr, wr| {
                        if (sr != wr) return error.ImportTypeMismatch;
                    }
                },
                .wasi => {
                    // WASI binding-side guarantees the lookup
                    // matched the (module, name); no further
                    // signature compare required here.
                },
            }
        },
        .global => {
            const want = it.payload.global;
            const g = binding.global;
            if (g.source_valtype != want.valtype) return error.ImportTypeMismatch;
            if (g.source_mutable != want.mutable) return error.ImportTypeMismatch;
        },
        .table => {
            const want = it.payload.table;
            const t = binding.table;
            if (t.source_elem_type != want.elem_type) return error.ImportTypeMismatch;
            if (t.source_min < want.min) return error.ImportTypeMismatch;
            if (want.max) |wm| {
                const sm = t.source_max orelse return error.ImportTypeMismatch;
                if (sm > wm) return error.ImportTypeMismatch;
            }
        },
        .memory => {
            const want = it.payload.memory;
            const m = binding.memory;
            if (m.source_min < want.min) return error.ImportTypeMismatch;
            if (want.max) |wm| {
                const max_s = m.source_max orelse return error.ImportTypeMismatch;
                if (max_s > wm) return error.ImportTypeMismatch;
            }
        },
    }
}
