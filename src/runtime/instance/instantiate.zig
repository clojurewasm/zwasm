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
const import_mod = @import("import.zig");
const instance_mod = @import("instance.zig");
const heap_mod = @import("../../feature/gc/heap.zig");

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

    // D-188 — structural body validation runs unconditionally for
    // every present section that contains valtype-bearing entries.
    // The downstream path's type/global/table/elem decodes were
    // gated behind the "has-type-section AND has-code-section"
    // shortcut, which let modules containing only a type / global
    // / table / elem section bypass valtype checks (e.g., the
    // Wasm 3.0 typed-funcref `(ref N)` byte 0x64/0x63 with an
    // out-of-bounds typeidx in the wasm-3.0-assert/function-
    // references/ref.{1..5} fixtures). Decoding here is a pure
    // structural integrity gate; the heavier per-function
    // validation below remains gated on a code section being
    // present.
    if (!preDecodeSectionBodies(alloc, &module)) return false;

    const type_section = module.find(.type) orelse return validateNoCode(alloc, &module);
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

    // Memory0's idx_type drives the validator's memory-op address
    // valtype (i32 vs i64). Wasm 3.0 memory64 modules declare a
    // memory section with flag bit 0x04 set; without threading
    // this through, the validator defaults to i32 addresses and
    // rejects memory64 function bodies with StackTypeMismatch.
    // ADR-0111 D1.
    var memories_owned: ?sections.Memories = if (module.find(.memory)) |s|
        sections.decodeMemory(alloc, s.body) catch return false
    else
        null;
    defer if (memories_owned) |*m| m.deinit();
    const memory0_idx_type: sections.MemoryEntry.IdxType =
        if (memories_owned) |m|
            (if (m.items.len > 0) m.items[0].idx_type else .i32)
        else
            .i32;

    // 10.E EH module-compile path: decode the tag section so
    // `throw` / `try_table` catch clauses range-check tag_idx
    // against module.tags[] instead of failing on the empty
    // default. Modules without a tag section pass an empty slice
    // (preserves prior behavior for non-EH modules).
    const tags_slice: []const sections.TagEntry = if (module.find(.tag)) |s|
        sections.decodeTags(alloc, s.body) catch return false
    else
        &.{};
    defer if (tags_slice.len > 0) alloc.free(tags_slice);

    // 10.R cycle 60 (D-195 sub-gap c) — Wasm spec §3.4.10 declared-
    // funcrefs bitset. `ref.func N` must reference a function that
    // appears in some global init expr (as `ref.func`), element
    // segment (funcidx entry), or export (kind=func). Function bodies
    // and the start function do NOT contribute. Mirror of
    // `src/engine/compile.zig`'s declared_funcs construction; the
    // bypassed-validation path (this fn) previously left
    // `declared_funcs = &.{}`, letting fixtures like ref_func.4/5
    // sneak past the validator's check. Builds before the per-fn
    // validate loop so every function body sees the same bitset.
    const total_funcs: usize = imp_func_count + defined_func_indices.len;
    const declared_funcs = alloc.alloc(bool, total_funcs) catch return false;
    defer alloc.free(declared_funcs);
    @memset(declared_funcs, false);
    if (globals_owned) |g| for (g.items) |gd| {
        if (initExprRefFuncLocal(gd.init_expr)) |fidx| {
            if (fidx < total_funcs) declared_funcs[fidx] = true;
        }
    };
    if (module.find(.element)) |elem_section| {
        var elems = sections.decodeElement(alloc, elem_section.body) catch return false;
        defer elems.deinit();
        for (elems.items) |seg| {
            for (seg.funcidxs) |fidx| {
                // ref.null entries encoded as maxInt(u32) per the
                // element decoder; skip those.
                if (fidx != std.math.maxInt(u32) and fidx < total_funcs) {
                    declared_funcs[fidx] = true;
                }
            }
        }
    }
    if (module.find(.@"export")) |exp_section| {
        // Manual export scan tolerant of Wasm 3.0 export-kind
        // extensions (e.g., `tag = 4` from the EH proposal which
        // `sections.decodeExports` currently rejects with
        // `BadValType` — see try_table.0.wasm). Only `kind == 0`
        // (func) contributes to the declared-funcrefs set; other
        // kinds (table / memory / global / tag / future) are
        // ignored. Malformed body still rejects via `return false`.
        const body = exp_section.body;
        var pos: usize = 0;
        const count = leb128.readUleb128(u32, body, &pos) catch return false;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            const name_len = leb128.readUleb128(u32, body, &pos) catch return false;
            if (pos + name_len > body.len) return false;
            pos += name_len;
            if (pos >= body.len) return false;
            const kind_byte = body[pos];
            pos += 1;
            const exp_idx = leb128.readUleb128(u32, body, &pos) catch return false;
            if (kind_byte == 0 and exp_idx < total_funcs) {
                declared_funcs[exp_idx] = true;
            }
        }
        if (pos != body.len) return false;
    }

    // 10.M cycle 66 — total memory count (imports + defined) so the
    // validator can range-check memidx in memory.size / memory.grow /
    // load / store ops against the actual memory space.
    const imp_memory_count_validate: u32 = blk: {
        var n: u32 = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind == .memory) n += 1;
        };
        break :blk n;
    };
    const def_memory_count_validate: u32 = if (memories_owned) |m| @intCast(m.items.len) else 0;
    const total_memory_count: u32 = imp_memory_count_validate + def_memory_count_validate;

    // 10.M cycle 68 — decode data section + DataCount section so the
    // validator can range-check memory.init dataidx against the
    // actual segment count (was hard-pinned to 0, rejecting every
    // memory.init / data.drop with InvalidFuncIndex). compile.zig's
    // similar path was already threaded; frontendValidate had a
    // pre-existing gap surfaced by 10.M corpus expansion at cycle 68.
    var datas_owned: ?sections.Datas = if (module.find(.data)) |s|
        sections.decodeData(alloc, s.body) catch return false
    else
        null;
    defer if (datas_owned) |*d| d.deinit();
    const data_count_validate: u32 = if (datas_owned) |d| @intCast(d.items.len) else 0;
    // `data_count_section_present` defaults to `true` on the
    // Validator struct; `validateFunctionWithMemIdxAndTags` doesn't
    // override it. Modules using memory.init MUST declare a
    // DataCount section per Wasm 2.0 §5.5.16 — the parser already
    // rejects malformed orderings, and validator's MEMINIT-without-
    // DataCount check is best-effort. Future: thread the actual
    // `data_count_section_present` boolean if a fixture surfaces a
    // miscompile around its absence.

    for (codes_owned.items, defined_func_indices) |code, type_idx| {
        const sig = types_owned.items[type_idx];
        validator.validateFunctionWithMemIdxAndTags(
            sig,
            code.locals,
            code.body,
            func_types,
            global_entries,
            types_owned.items,
            data_count_validate,
            table_entries,
            0, // elem_count
            total_memory_count,
            memory0_idx_type,
            tags_slice,
            declared_funcs,
        ) catch return false;
    }
    return true;
}

/// Wasm spec §3.4.10 declared-funcrefs helper: extract the single
/// `ref.func N` payload from a global init expr, returning `null`
/// when the expr is not a `ref.func N; end` sequence (e.g.
/// `i32.const N; end`, `global.get N; end`, malformed). Inlined here
/// instead of importing `engine/runner_validate.zig::initExprRefFunc`
/// because that module is Zone 2 and this is Zone 1 (per
/// `.claude/rules/zone_deps.md`).
fn initExprRefFuncLocal(expr: []const u8) ?u32 {
    if (expr.len < 3) return null;
    if (expr[0] != 0xD2) return null; // ref.func opcode
    var pos: usize = 1;
    const idx = leb128.readUleb128(u32, expr, &pos) catch return null;
    if (pos >= expr.len or expr[pos] != 0x0B) return null;
    return idx;
}

pub fn validateNoCode(_: std.mem.Allocator, _: *Module) bool {
    // No code section: nothing per-function to validate. The
    // module's section-id ordering was already checked by
    // parser.parse; section-body structural integrity is checked
    // separately by `preDecodeSectionBodies` (called from
    // `frontendValidate`'s top), so this helper is genuinely a
    // no-op for modules with no code.
    return true;
}

/// D-188 — pre-validation pass that decodes the body of each
/// present section whose entries embed valtypes (or other
/// structural data with their own integrity invariants). Returns
/// false on any decode error. Runs ahead of the conditional
/// per-function validate path so a module without a code section
/// can't silently bypass type/global/table/elem body checks.
fn preDecodeSectionBodies(alloc: std.mem.Allocator, module: *Module) bool {
    if (module.find(.type)) |s| {
        var t = sections.decodeTypes(alloc, s.body) catch return false;
        t.deinit();
    }
    if (module.find(.import)) |s| {
        var im = sections.decodeImports(alloc, s.body) catch return false;
        im.deinit();
    }
    if (module.find(.table)) |s| {
        var t = sections.decodeTables(alloc, s.body) catch return false;
        t.deinit();
    }
    if (module.find(.memory)) |s| {
        var m = sections.decodeMemory(alloc, s.body) catch return false;
        m.deinit();
    }
    if (module.find(.global)) |s| {
        var g = sections.decodeGlobals(alloc, s.body) catch return false;
        g.deinit();
    }
    if (module.find(.element)) |s| {
        var e = sections.decodeElement(alloc, s.body) catch return false;
        defer e.deinit();
        // 10.TC cycle 81 — element-section funcidx range check.
        // Sibling to D-188's no-code-section pre-decode (cycle 60).
        // Without this, modules with only `(table)` + `(elem
        // (ref.func N))` referencing a non-existent funcidx N pass
        // the no-code shortcut and reach instantiate as "valid"
        // when spec demands invalid. Compute total_funcs from
        // imports + function section; reject elem entries whose
        // funcidx is out of range. Tail-call corpus surfaced this
        // via `tail-call/return_call_indirect.27.wasm` (cycle 80).
        var imp_func_count: u32 = 0;
        if (module.find(.import)) |is| {
            var im = sections.decodeImports(alloc, is.body) catch return false;
            defer im.deinit();
            for (im.items) |it| {
                if (it.kind == .func) imp_func_count += 1;
            }
        }
        var def_func_count: u32 = 0;
        if (module.find(.function)) |fs| {
            const fns = sections.decodeFunctions(alloc, fs.body) catch return false;
            defer alloc.free(fns);
            def_func_count = @intCast(fns.len);
        }
        const total_funcs = imp_func_count + def_func_count;
        for (e.items) |seg| {
            for (seg.funcidxs) |fidx| {
                if (fidx == std.math.maxInt(u32)) continue; // ref.null sentinel
                if (fidx >= total_funcs) return false;
            }
        }
    }
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
    if (module.find(.type)) |s| {
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
                            const ft = if (types_owned) |t| t.items[tidx] else return error.UnsupportedImport;
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
                const ft = if (types_owned) |t| t.items[tidx] else return error.UnsupportedImport;
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
                            break :blk .{ .memory = .{ .idx_type = m.idx_type, .min = m.min, .max = m.max } };
                        }
                        idx += 1;
                    }
                    imp_count = idx;
                }
                const def_idx = exp.idx - imp_count;
                const dm = (defined_memories orelse return error.UnsupportedImport).items;
                if (def_idx >= dm.len) return error.UnsupportedImport;
                const m = dm[def_idx];
                break :blk .{ .memory = .{ .idx_type = m.idx_type, .min = m.min, .max = m.max } };
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
/// Supported shapes for v0.1.0: `<i32|i64|f32|f64>.const N; end`,
/// `ref.null funcref|externref; end`, and Wasm 2.0 `v128.const
/// b0..b15; end` (post-ADR-0110 §9.13-V Phase A.4f; closes D-169).
/// `global.get N` (importing from another module's globals) defers
/// with the rest of cross-module global imports.
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
        // Wasm 2.0 SIMD prefix — currently only `v128.const`
        // (sub-opcode 0x0C) is a valid const-expression op (per
        // Wasm 2.0 §3.5.4 + ADR-0110 D-169 discharge).
        0xFD => blk: {
            if (pos >= expr.len) return error.UnsupportedConstExpr;
            const sub = expr[pos];
            pos += 1;
            if (sub != 0x0C) return error.UnsupportedConstExpr;
            if (pos + 16 > expr.len) return error.UnsupportedConstExpr;
            var bytes: [16]u8 = undefined;
            @memcpy(&bytes, expr[pos..][0..16]);
            pos += 16;
            break :blk .{ .v128 = bytes };
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

/// Wasm spec §3.4.7 — active data segment offset's result type
/// matches the target memory's idx_type. memory64 modules emit
/// `i64.const N; end` (opcode 0x42) for offsets; legacy i32
/// memories emit `i32.const N; end` (opcode 0x41). Returns the
/// offset as `u64` so the caller can range-check against the
/// memory's byte length uniformly.
pub fn evalConstMemAddrExpr(
    expr: []const u8,
    idx_type: sections.MemoryEntry.IdxType,
) !u64 {
    return evalConstMemAddrExprWithGlobals(expr, idx_type, &.{});
}

/// 10.M-D195b cycle 78 — accepts `global.get N` (opcode 0x23) in
/// addition to the const-int shapes. The N index is into the
/// importer's `rt.globals` slice (post-import-binding). Spec testsuite
/// fixtures like `multi-memory/data0.{3,5}.wasm` declare
/// `(data (global.get 0) "a")` against an imported `spectest.global_i32`
/// global, hitting this path after the cycle-77 Linker.defineGlobal
/// wiring resolves the import.
pub fn evalConstMemAddrExprWithGlobals(
    expr: []const u8,
    idx_type: sections.MemoryEntry.IdxType,
    globals: []const *Value,
) !u64 {
    if (expr.len < 2) return error.UnsupportedConstExpr;
    switch (expr[0]) {
        0x23 => { // global.get N
            var pos: usize = 1;
            const idx = leb128.readUleb128(u32, expr, &pos) catch return error.UnsupportedConstExpr;
            if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
            if (idx >= globals.len) return error.UnsupportedConstExpr;
            const cell = globals[idx].*;
            return switch (idx_type) {
                .i32 => @as(u64, @intCast(@as(u32, @bitCast(cell.i32)))),
                .i64 => @bitCast(cell.i64),
            };
        },
        else => switch (idx_type) {
            .i32 => return @as(u64, @intCast(@as(u32, @bitCast(try evalConstI32Expr(expr))))),
            .i64 => {
                if (expr[0] != 0x42) return error.UnsupportedConstExpr;
                var pos: usize = 1;
                const v = try leb128.readSleb128(i64, expr, &pos);
                if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
                return @bitCast(v);
            },
        },
    }
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

    // 10.G-foundation cycle 5 (ADR-0115 §1 zero-overhead gate).
    // Materialise the per-Store GC heap slab when the module
    // declares GC types / heap reftype slots (`needs_gc_heap`
    // set at parse-time by `feature/gc/needs_heap_detector`).
    // Non-GC modules see no allocation here — invariant per
    // ADR-0115 §1: zero overhead when false.
    if (module.needs_gc_heap) {
        const h = try a.create(heap_mod.Heap);
        h.* = heap_mod.Heap.init(a);
        rt.gc_heap = h;

        // 10.G op_gc cycle 21 (ADR-0116 §3a impl). Materialise
        // per-Instance GC type metadata from the parser side-
        // tables. Decode types fresh (the main type-section
        // decode happens later in `instantiateInternal` but
        // doesn't expose its `Types` upward; for now we decode
        // here too — a follow-up consolidation cycle can share
        // the decode if hot-path measurement justifies it).
        if (module.find(.type)) |type_section| {
            var types = try sections.decodeTypes(a, type_section.body);
            defer types.deinit();
            const type_info = @import("../../feature/gc/type_info.zig");
            inst.gc_type_infos = try type_info.materialiseGcTypes(a, types);
        }
    }

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
    const type_section_opt = module.find(.type);

    const types = if (type_section_opt) |s|
        try sections.decodeTypes(a, s.body)
    else
        sections.Types{
            .arena = std.heap.ArenaAllocator.init(a),
            .items = &.{},
            .kinds = &.{},
            .struct_defs = &.{},
            .array_defs = &.{},
        };

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
            try lower.lowerFunctionBody(a, code.body, &funcs[i], types.items, &.{});
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

    // 10.E-N-4: production tag_param_counts wiring. Mirror of
    // engine/runner.zig::compileWasm's tag-section handling for
    // the interp-side Runtime: decode tags + resolve per-tag
    // param count via the type section. The interp throw / catch
    // path (feature/exception_handling/exception.zig + mvp.zig
    // throwOp) consumes Runtime.tag_param_counts[tag_idx] to know
    // how many operand-stack values to pop into the Exception
    // payload. Wasm 3.0 §3.3.10.7 (throw).
    if (module.find(.tag)) |tag_section| {
        const tag_entries = try sections.decodeTags(a, tag_section.body);
        const counts = try a.alloc(u32, tag_entries.len);
        // ADR-0120 D5: parallel slot-count table (v128 = 2 slots,
        // all v0.1 numeric/ref types = 1 slot). Computed alongside
        // tag_param_counts because both walk the same tag section
        // + same types lookup.
        const slot_counts = try a.alloc(u32, tag_entries.len);
        var total_slots: u32 = 0;
        for (tag_entries, 0..) |entry, i| {
            if (entry.typeidx >= types.items.len) return error.InvalidTypeIndex;
            const params = types.items[entry.typeidx].params;
            counts[i] = @intCast(params.len);
            var slots: u32 = 0;
            for (params) |p| {
                slots += runtime_mod.slotCountForValType(p);
            }
            slot_counts[i] = slots;
            if (slots > total_slots) total_slots = slots;
        }
        rt.tag_param_counts = counts;
        rt.tag_param_slot_counts = slot_counts;
        // ADR-0120 D1: pre-size eh_payload to the maximum per-tag
        // slot count. The buffer is single-use (one throw in flight
        // at a time per Runtime per ADR-0120 D5+Consequence §5),
        // so capacity = max(per-tag) not sum.
        if (total_slots > 0) {
            rt.eh_payload = try a.alloc(u64, total_slots);
            @memset(rt.eh_payload, 0);
        }
    }

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
            // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
            // Interp instantiate path; JIT mirror-write reads these.
            // 0 = "not JIT-resolved" sentinel.
            .typeidx = 0,
            .funcptr = 0,
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
                            .typeidx = 0,
                            .funcptr = 0,
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
    // (no copy); defined memory is allocated locally. Each wiring
    // path also populates `rt.memories[0]` (ADR-0111 D2) so the
    // per-memory descriptor (idx_type + page bounds) is reachable
    // from the runtime side; `rt.memory` keeps its pointer-alias
    // semantics via setMemory0Bytes.
    // 10.M cycle 71 — additive memory wiring: imports + defined.
    // Pre-cycle-71 the if/else-if dropped defined memories whenever
    // ≥1 memory was imported. Wasm 3.0 multi-memory allows both;
    // load1.wast (D-195(b) bundle) exercises the combination.
    // Total = imp_memory_count + defined section count. Fill imports
    // first (memidx 0..imp-1), then defined (memidx imp..total-1).
    // `rt.memory` keeps aliasing memories[0] for the legacy emit
    // path's `[base, offset]` shape.
    var defined_memories: ?sections.Memories = if (module.find(.memory)) |s|
        sections.decodeMemory(a, s.body) catch null
    else
        null;
    defer if (defined_memories) |*m| m.deinit();
    const def_memory_count: usize = if (defined_memories) |m| m.items.len else 0;
    const total_memory_count_alloc: usize = imp_memory_count + def_memory_count;
    if (total_memory_count_alloc > 0) {
        const mi = try a.alloc(runtime_mod.MemoryInstance, total_memory_count_alloc);
        var slot: usize = 0;
        // Imports first.
        if (imp_memory_count > 0) {
            for (imports_decoded.?.items, 0..) |it, idx| {
                if (it.kind != .memory) continue;
                const m = bindings.?[idx].memory;
                mi[slot] = .{
                    .bytes = m.memory,
                    .idx_type = m.source_idx_type,
                    .pages_min = m.source_min,
                    .pages_max = m.source_max,
                };
                slot += 1;
            }
        }
        // Then defined.
        if (defined_memories) |memories| {
            for (memories.items) |entry| {
                const pages = entry.min;
                const bytes_total: usize = @as(usize, pages) * 65536;
                const mem = try a.alloc(u8, bytes_total);
                @memset(mem, 0);
                mi[slot] = .{
                    .bytes = mem,
                    .idx_type = entry.idx_type,
                    .pages_min = entry.min,
                    .pages_max = entry.max,
                };
                slot += 1;
            }
        }
        rt.memories = mi;
        rt.memory = mi[0].bytes;
    }

    // 10.M-D195b cycle 78 — data segments deferred to AFTER globals
    // init so `(data (global.get N) ...)` offsets can resolve via
    // rt.globals. Previously processed inline here; the move below
    // happens after the globals section at line ~1020.

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

    // 10.M-D195b cycle 78 — data segment initialization deferred
    // from the early memory-wiring block to AFTER global init. Active
    // data segments may carry `(data (global.get N) ...)` offsets
    // that read from an imported global (e.g., spec testsuite's
    // `(global.get 0)` against spectest.global_i32). rt.globals must
    // be populated before this loop fires.
    if (module.find(.data)) |data_section| {
        var datas = try sections.decodeData(a, data_section.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            if (seg.memidx >= rt.memories.len) return error.DataSegmentOutOfRange;
            const target = &rt.memories[seg.memidx];
            const mem_idx_type: sections.MemoryEntry.IdxType = target.idx_type;
            const offset = try evalConstMemAddrExprWithGlobals(seg.offset_expr, mem_idx_type, rt.globals);
            const dst_end_u128: u128 = @as(u128, offset) + @as(u128, seg.bytes.len);
            if (dst_end_u128 > target.bytes.len) return error.DataSegmentOutOfRange;
            const dst_end: usize = @intCast(dst_end_u128);
            @memcpy(target.bytes[@intCast(offset)..dst_end], seg.bytes);
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
            const type_sec = module.find(.type) orelse return error.ImportTypeMismatch;
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
