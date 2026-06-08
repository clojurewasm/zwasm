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
const testing = std.testing;
const import_mod = @import("import.zig");
const instance_mod = @import("instance.zig");
const heap_mod = @import("../../feature/gc/heap.zig");
const type_info_mod = @import("../../feature/gc/type_info.zig");
const needs_heap_detector = @import("../../feature/gc/needs_heap_detector.zig");
const diagnostic = @import("../../diagnostic/diagnostic.zig");

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
        .tag => {
            // EH tag imports (10.E-xmodule-tags) don't contribute to
            // the func/global/table index spaces this loop sizes.
        },
    };

    const func_types = alloc.alloc(zir.FuncType, imp_func_count + defined_func_indices.len) catch return false;
    defer alloc.free(func_types);
    // 10.R-funcrefs-tail — parallel func-index → type-section-index map
    // for ADR-0123 D4 typed `ref.func`. Same index space as func_types.
    const func_type_indices = alloc.alloc(u32, imp_func_count + defined_func_indices.len) catch return false;
    defer alloc.free(func_type_indices);
    {
        var cursor: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .func) continue;
            const ti = it.payload.func_typeidx;
            if (ti >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[ti];
            func_type_indices[cursor] = ti;
            cursor += 1;
        };
        for (defined_func_indices) |type_idx| {
            if (type_idx >= types_owned.items.len) return false;
            func_types[cursor] = types_owned.items[type_idx];
            func_type_indices[cursor] = type_idx;
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

    // Wasm spec §3.4.3 — each defined global's init-expr result type must
    // be a subtype of its declared type (GC iso-recursive identity per
    // ADR-0126). The native-API validate path (this fn) previously skipped
    // this, letting type-subtyping invalid fixtures with a rec-group-
    // distinct `ref.func` init (e.g. `(global (ref 4) (ref.func 0))` where
    // func 0's type ≢ type 4) slip through. Conservative: undeterminable
    // const-expr shapes pass (an incomplete evaluator must not reject valid
    // modules).
    if (globals_owned) |g| {
        if (!validator.validateGlobalInits(g.items, global_entries, func_type_indices, &types_owned)) {
            diagnostic.setDiag(.validate, .other, .unknown, "global init-expr type mismatch (§3.4.3)", .{});
            return false;
        }
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
    // Tag index space = imported tags (kind .tag) ++ defined tags
    // (section 13), per Wasm index-space ordering. Cross-module EH
    // (10.E): try_table.1 imports test::e0 ×2, so catch/throw tag
    // indices are offset by the import count — a defined-only slice
    // mis-resolves them (wrong params → StackTypeMismatch).
    var imp_tag_count: usize = 0;
    if (imports_decoded) |im| for (im.items) |it| {
        if (it.kind == .tag) imp_tag_count += 1;
    };
    const defined_tags: []const sections.TagEntry = if (module.find(.tag)) |s|
        sections.decodeTags(alloc, s.body) catch return false
    else
        &.{};
    defer if (defined_tags.len > 0) alloc.free(defined_tags);
    const tags_slice: []const sections.TagEntry = if (imp_tag_count == 0)
        defined_tags
    else blk: {
        const combined = alloc.alloc(sections.TagEntry, imp_tag_count + defined_tags.len) catch return false;
        var ci: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind != .tag) continue;
            combined[ci] = .{ .attribute = 0, .typeidx = it.payload.tag_typeidx };
            ci += 1;
        };
        for (defined_tags) |t| {
            combined[ci] = t;
            ci += 1;
        }
        break :blk combined;
    };
    defer if (imp_tag_count > 0) alloc.free(tags_slice);

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
    var elem_seg_count: u32 = 0;
    // 10.G cycle 158 — per-segment elem reftype so the validator can
    // type-check array.init_elem (segment <: array element) and
    // table.init (segment == table elem_type). Empty = legacy callers.
    var elem_types_validate: []zir.ValType = &.{};
    if (module.find(.element)) |elem_section| {
        var elems = sections.decodeElement(alloc, elem_section.body) catch return false;
        defer elems.deinit();
        elem_seg_count = @intCast(elems.items.len);
        elem_types_validate = alloc.alloc(zir.ValType, elems.items.len) catch return false;
        for (elems.items, 0..) |seg, i| {
            elem_types_validate[i] = seg.elem_type;
            for (seg.funcidxs) |fidx| {
                // ref.null entries encoded as maxInt(u32) per the
                // element decoder; skip those.
                if (fidx != std.math.maxInt(u32) and fidx < total_funcs) {
                    declared_funcs[fidx] = true;
                }
            }
        }
    }
    defer if (elem_types_validate.len != 0) alloc.free(elem_types_validate);
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

    for (codes_owned.items, defined_func_indices, 0..) |code, type_idx, def_idx| {
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
            elem_seg_count, // table.init / elem.drop elemidx bound
            total_memory_count,
            memory0_idx_type,
            tags_slice,
            declared_funcs,
            func_type_indices,
            types_owned.kinds,
            types_owned.struct_defs,
            types_owned.array_defs,
            types_owned.supertypes,
            elem_types_validate,
        ) catch {
            // ADR-0016 M3 — the validator set the op/offset diagnostic in
            // its dispatch loop; attach the defined-function index here.
            diagnostic.noteValidateFuncIdx(@intCast(imp_func_count + def_idx));
            return false;
        };
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
/// Returns true iff `vt` is well-typed against a type section of
/// `ntypes` entries: any concrete typed ref's index must be < ntypes.
/// Abstract refs / numerics are unconditionally OK.
fn validRefTypeIdx(vt: zir.ValType, ntypes: usize) bool {
    return switch (vt) {
        .i32, .i64, .f32, .f64, .v128 => true,
        .ref => |r| switch (r.heap_type) {
            .abstract => true,
            .concrete => |idx| @as(usize, idx) < ntypes,
        },
    };
}

fn preDecodeSectionBodies(alloc: std.mem.Allocator, module: *Module) bool {
    // ADR-0123 Cycle 3 — type-section typed-funcref bounds check.
    // Modules whose FuncType.params / results contain a concrete
    // typed ref `(ref null? $idx)` are now parseable (parser was
    // extended at cycle 92 / 10.R-valtype-widen Cycle 3); the
    // bounds check on $idx ∈ [0, types.len) must run at module-
    // load time, NOT lazily at validate. Without it the function-
    // references/ref.1/2/3/6/8 invalid fixtures (each containing
    // `(ref $1)` while only 1 type is defined) pass the no-code
    // shortcut and reach instantiate as "valid" when spec demands
    // invalid.
    if (module.find(.type)) |s| {
        var t = sections.decodeTypes(alloc, s.body) catch |e| {
            // ADR-0016 M3 — type-section decode failure (e.g. a packed
            // storage type i8/i16 the field decoder doesn't accept yet,
            // or an out-of-range typeidx). Pre-func-loop, so no opcode.
            diagnostic.setDiag(.validate, .other, .unknown, "type-section decode: {s}", .{@errorName(e)});
            return false;
        };
        defer t.deinit();
        const ntypes = t.items.len;
        for (t.items) |ft| {
            for (ft.params) |p| if (!validRefTypeIdx(p, ntypes)) return false;
            for (ft.results) |r| if (!validRefTypeIdx(r, ntypes)) return false;
        }
        // GC struct/array field reftypes carry concrete typeidxs too —
        // now that rec/sub typedefs parse (cyc126), bound-check them or a
        // fixture with an out-of-range field `(ref $N)` would slip through.
        for (t.struct_defs) |sd| if (sd) |sdef| {
            for (sdef.fields) |f| if (!validRefTypeIdx(f.storage.operandType(), ntypes)) return false;
        };
        for (t.array_defs) |ad| if (ad) |adef| {
            if (!validRefTypeIdx(adef.element.storage.operandType(), ntypes)) return false;
        };
        // ADR-0124 — reject non-conformant `sub`/`sub final` subtype
        // declarations (structural mismatch, extending a final type,
        // out-of-bounds / forward supertype). Runs in the no-code path
        // too, so type-only gc modules (type-subtyping-invalid corpus)
        // can't bypass it.
        if (!validator.validateTypeSection(&t)) {
            diagnostic.setDiag(.validate, .other, .unknown, "type-section subtype validation rejected (ADR-0124)", .{});
            return false;
        }
    }
    if (module.find(.import)) |s| {
        var im = sections.decodeImports(alloc, s.body) catch return false;
        im.deinit();
    }
    if (module.find(.table)) |s| {
        var t = sections.decodeTables(alloc, s.body) catch return false;
        defer t.deinit();
        // ADR-0123 — table elem_type typed-funcref bounds. ref.4
        // fixture: `(table (ref null 1))` with no type 1 defined.
        // decodeTables now accepts typed reftypes (10.R-funcrefs-tail-2)
        // so the concrete-index bound must be enforced at load time.
        const ntypes: usize = if (module.find(.type)) |ts| blk: {
            var ty = sections.decodeTypes(alloc, ts.body) catch break :blk 0;
            defer ty.deinit();
            break :blk ty.items.len;
        } else 0;
        for (t.items) |tbl| {
            if (!validRefTypeIdx(tbl.elem_type, ntypes)) return false;
            // Wasm §3.2.4 table limits: `min ≤ max` if a max is present. The
            // spec ceiling on the size itself is 2^32-1 (the full u32 range),
            // so `min` needs no upper bound here — a large declared `min` is a
            // valid module (table.6: `(table funcref 0xffffffff)`); refusing to
            // RESERVE that many entries is an instantiation-time resource
            // concern (D-316), not a validation error.
            if (tbl.max) |mx| {
                if (mx < tbl.min) return false;
            }
        }
    }
    if (module.find(.memory)) |s| {
        var m = sections.decodeMemory(alloc, s.body) catch return false;
        defer m.deinit();
        // Wasm §3.2.5 / §A.1 — a memory min/max above the per-idx-type page
        // ceiling is rejected at validate time (interp path; mirrors the JIT
        // `engine/compile.zig`), so a crafted oversized declared memory is
        // refused, never allocated. Runs unconditionally (no-code path too).
        for (m.items) |me| {
            const cap: u64 = switch (me.idx_type) {
                .i32 => sections.MAX_MEMORY_PAGES_I32,
                .i64 => sections.MAX_MEMORY_PAGES_I64,
            };
            if (me.min > cap) return false;
            if (me.max) |mx| {
                if (mx > cap or mx < me.min) return false;
            }
        }
    }
    if (module.find(.global)) |s| {
        var g = sections.decodeGlobals(alloc, s.body) catch return false;
        defer g.deinit();
        // ADR-0123 Cycle 3 — global-section typed-funcref bounds.
        // ref.3 fixture: `(global (ref null $1))` with no type
        // section. Reject.
        const ntypes: usize = if (module.find(.type)) |ts| blk: {
            var t = sections.decodeTypes(alloc, ts.body) catch break :blk 0;
            defer t.deinit();
            break :blk t.items.len;
        } else 0;
        for (g.items) |gd| {
            if (!validRefTypeIdx(gd.valtype, ntypes)) return false;
        }
    }
    // ADR-0123 Cycle 3 — code-section local-decl typed-funcref
    // bounds. ref.8 fixture: function with `(local (ref null $1))`
    // declared in the function body but no type 1 defined.
    if (module.find(.code)) |s| {
        var c = sections.decodeCodes(alloc, s.body) catch return false;
        defer c.deinit();
        const ntypes: usize = if (module.find(.type)) |ts| blk: {
            var t = sections.decodeTypes(alloc, ts.body) catch break :blk 0;
            defer t.deinit();
            break :blk t.items.len;
        } else 0;
        for (c.items) |fbody| {
            for (fbody.locals) |loc_vt| {
                if (!validRefTypeIdx(loc_vt, ntypes)) return false;
            }
        }
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
        // ADR-0123 — element reftype typed-funcref bounds. ref.5
        // fixture: `(elem (ref 1))` with no type 1 defined.
        // decodeElement now accepts typed reftypes (10.R-funcrefs-tail-2)
        // so the concrete-index bound must be enforced at load time.
        const ntypes: usize = if (module.find(.type)) |ts| blk: {
            var ty = sections.decodeTypes(alloc, ts.body) catch break :blk 0;
            defer ty.deinit();
            break :blk ty.items.len;
        } else 0;
        for (e.items) |seg| {
            if (!validRefTypeIdx(seg.elem_type, ntypes)) return false;
            // The funcidxs slot is funcidx-typed only for func-family
            // segments. For i31ref/anyref/etc. it holds an encoded ref
            // value (e.g. ref.i31), NOT a funcidx — skip the range check.
            const is_funcref_family = seg.elem_type == .ref and switch (seg.elem_type.ref.heap_type) {
                .abstract => |a| a == .func,
                .concrete => true,
            };
            if (is_funcref_family) {
                for (seg.funcidxs) |fidx| {
                    if (fidx == std.math.maxInt(u32)) continue; // ref.null sentinel
                    if (fidx >= total_funcs) return false;
                }
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
                            const t = types_owned orelse return error.UnsupportedImport;
                            break :blk .{ .func = .{ .sig = t.items[tidx], .final = t.finals[tidx], .typeidx = tidx } };
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
                const t = types_owned orelse return error.UnsupportedImport;
                break :blk .{ .func = .{ .sig = t.items[tidx], .final = t.finals[tidx], .typeidx = tidx } };
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
    // Wasm 3.0 GC: `ref.i31` (0xFB 0x1C) is a constant-expression op —
    // it wraps a preceding `i32.const N` into a non-null `(ref i31)`.
    // (struct.new / array.new const exprs need heap alloc → later chunk.)
    var result = v;
    if (pos < expr.len and expr[pos] == 0xFB) {
        pos += 1;
        const sub = try leb128.readUleb128(u32, expr, &pos);
        if (sub != 28) return error.UnsupportedConstExpr; // 0x1C = ref.i31
        result = Value.fromI31Truncate(result.i32);
    }
    if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
    return result;
}

/// Evaluate a Wasm 3.0 GC `struct.new` / `array.new` constant expression
/// at instantiation (§3.5.10 const-expr extension). The global-init loop
/// falls here when `evalConstExprValue` rejects with
/// `UnsupportedConstExpr`. A small const-stack handles numeric consts +
/// ref.i31 + struct.new[_default] + array.new[_default]/array.new_fixed:
/// allocate on `rt.gc_heap` using the materialised Struct/ArrayInfo and
/// write the leading const operands into the object slots (mirrors
/// struct_ops.zig / array_ops.zig / ADR-0116 §3a).
/// Primitive-param form so both the interp instantiate path and the JIT
/// setup path (`engine/setup.zig`) can evaluate GC const-expr globals
/// without coupling engine → Instance. `gc_heap` / `gc_type_infos` are
/// nullable; a GC const-expr op on a module without them rejects with
/// `UnsupportedConstExpr` (D-223).
pub fn evalGlobalInitGc(
    expr: []const u8,
    gc_heap: ?*heap_mod.Heap,
    gc_type_infos: ?type_info_mod.GcTypeInfos,
    func_entities: []FuncEntity,
    imported_globals: []const *Value,
) anyerror!Value {
    const type_info = @import("../../feature/gc/type_info.zig");
    const header_size: u32 = @sizeOf(type_info.ObjectHeader);
    var stack: [16]Value = undefined;
    var sp: usize = 0;
    var pos: usize = 0;
    while (pos < expr.len) {
        const op = expr[pos];
        pos += 1;
        if (op == 0x0B) break;
        if (sp >= stack.len) return error.UnsupportedConstExpr;
        switch (op) {
            0x41 => {
                stack[sp] = .{ .i32 = try leb128.readSleb128(i32, expr, &pos) };
                sp += 1;
            },
            0x42 => {
                stack[sp] = .{ .i64 = try leb128.readSleb128(i64, expr, &pos) };
                sp += 1;
            },
            0x43 => {
                if (pos + 4 > expr.len) return error.UnsupportedConstExpr;
                stack[sp] = .{ .bits64 = std.mem.readInt(u32, expr[pos..][0..4], .little) };
                pos += 4;
                sp += 1;
            },
            0x44 => {
                if (pos + 8 > expr.len) return error.UnsupportedConstExpr;
                stack[sp] = .{ .bits64 = std.mem.readInt(u64, expr[pos..][0..8], .little) };
                pos += 8;
                sp += 1;
            },
            0x23 => { // global.get N — Wasm §3.5.10 const-expr; read an
                // already-evaluated prior global (imported or earlier-
                // defined). i31.wast $i31ref_of_global_global_initializer:
                // `(global i31ref (ref.i31 (global.get $g)))`.
                const gidx = try leb128.readUleb128(u32, expr, &pos);
                if (gidx >= imported_globals.len) return error.UnsupportedConstExpr;
                stack[sp] = imported_globals[gidx].*;
                sp += 1;
            },
            0xD2 => { // ref.func N — Wasm §3.5.10 const-expr; push funcref
                // Value resolved against rt.func_entities (mirrors the
                // simple-global ref.func path + element-init above). Needed
                // when ref.func feeds a GC const-expr, e.g. array.init_elem.3
                // `(array.new $arrref (ref.func $dummy) (i32.const 12))`.
                const fidx = try leb128.readUleb128(u32, expr, &pos);
                if (fidx >= func_entities.len) return error.UnsupportedConstExpr;
                stack[sp] = Value.fromFuncRef(&func_entities[fidx]);
                sp += 1;
            },
            0xFB => {
                const sub = try leb128.readUleb128(u32, expr, &pos);
                switch (sub) {
                    28 => { // ref.i31: wrap the preceding i32 const
                        if (sp == 0) return error.UnsupportedConstExpr;
                        stack[sp - 1] = Value.fromI31Truncate(stack[sp - 1].i32);
                    },
                    0, 1 => { // struct.new / struct.new_default
                        const typeidx = try leb128.readUleb128(u32, expr, &pos);
                        const gti = gc_type_infos orelse return error.UnsupportedConstExpr;
                        if (typeidx >= gti.struct_infos.len) return error.UnsupportedConstExpr;
                        const si = gti.struct_infos[typeidx] orelse return error.UnsupportedConstExpr;
                        const heap = gc_heap orelse return error.UnsupportedConstExpr;
                        const ref = try heap.allocate(header_size + si.payload_size);
                        const hdr: type_info.ObjectHeader = .{ .kind = .struct_, .info = typeidx };
                        @memcpy(heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr));
                        if (sub == 0) {
                            // Fields are on the const-stack in declared order;
                            // write top-down so field[i] gets its operand.
                            var i: usize = si.type_info.field_count;
                            while (i > 0) {
                                i -= 1;
                                if (sp == 0) return error.UnsupportedConstExpr;
                                sp -= 1;
                                const off = ref + header_size + si.fields[i].offset;
                                @memcpy(heap.bytes[off .. off + 8], std.mem.asBytes(&stack[sp])[0..8]);
                            }
                        }
                        stack[sp] = .{ .ref = @as(u64, ref) };
                        sp += 1;
                    },
                    6, 7 => { // array.new / array.new_default
                        const typeidx = try leb128.readUleb128(u32, expr, &pos);
                        const gti = gc_type_infos orelse return error.UnsupportedConstExpr;
                        if (typeidx >= gti.array_infos.len) return error.UnsupportedConstExpr;
                        const ai = gti.array_infos[typeidx] orelse return error.UnsupportedConstExpr;
                        const heap = gc_heap orelse return error.UnsupportedConstExpr;
                        const ahs: u32 = @sizeOf(type_info.ArrayHeader);
                        // Stack (top first): size:i32, then init value (sub 6 only).
                        if (sp == 0) return error.UnsupportedConstExpr;
                        sp -= 1;
                        if (stack[sp].i32 < 0) return error.UnsupportedConstExpr;
                        const length: u32 = @intCast(stack[sp].i32);
                        var init_v: Value = .{ .i64 = 0 };
                        if (sub == 6) {
                            if (sp == 0) return error.UnsupportedConstExpr;
                            sp -= 1;
                            init_v = stack[sp];
                        }
                        const ref = try heap.allocate(ahs + length * @as(u32, ai.element.size));
                        const ah: type_info.ArrayHeader = .{ .header = .{ .kind = .array, .info = typeidx }, .length = length };
                        @memcpy(heap.bytes[ref .. ref + ahs], std.mem.asBytes(&ah)[0..ahs]);
                        var k: u32 = 0;
                        while (k < length) : (k += 1) {
                            const off = ref + ahs + k * @as(u32, ai.element.size);
                            if (sub == 6) {
                                @memcpy(heap.bytes[off .. off + ai.element.size], std.mem.asBytes(&init_v)[0..ai.element.size]);
                            } else {
                                @memset(heap.bytes[off .. off + ai.element.size], 0);
                            }
                        }
                        stack[sp] = .{ .ref = @as(u64, ref) };
                        sp += 1;
                    },
                    8 => { // array.new_fixed $t N
                        const typeidx = try leb128.readUleb128(u32, expr, &pos);
                        const nlen = try leb128.readUleb128(u32, expr, &pos);
                        const gti = gc_type_infos orelse return error.UnsupportedConstExpr;
                        if (typeidx >= gti.array_infos.len) return error.UnsupportedConstExpr;
                        const ai = gti.array_infos[typeidx] orelse return error.UnsupportedConstExpr;
                        const heap = gc_heap orelse return error.UnsupportedConstExpr;
                        const ahs: u32 = @sizeOf(type_info.ArrayHeader);
                        const ref = try heap.allocate(ahs + nlen * @as(u32, ai.element.size));
                        const ah: type_info.ArrayHeader = .{ .header = .{ .kind = .array, .info = typeidx }, .length = nlen };
                        @memcpy(heap.bytes[ref .. ref + ahs], std.mem.asBytes(&ah)[0..ahs]);
                        var k: u32 = nlen;
                        while (k > 0) {
                            k -= 1;
                            if (sp == 0) return error.UnsupportedConstExpr;
                            sp -= 1;
                            const off = ref + ahs + k * @as(u32, ai.element.size);
                            @memcpy(heap.bytes[off .. off + ai.element.size], std.mem.asBytes(&stack[sp])[0..ai.element.size]);
                        }
                        stack[sp] = .{ .ref = @as(u64, ref) };
                        sp += 1;
                    },
                    else => return error.UnsupportedConstExpr,
                }
            },
            else => return error.UnsupportedConstExpr,
        }
    }
    if (sp == 0) return error.UnsupportedConstExpr;
    return stack[sp - 1];
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
    }

    // 10.G op_gc cycle 21 (ADR-0116 §3a impl) + D-232. Materialise the
    // per-Instance GC type-identity table (supertype chains + canonical ids +
    // finality) from the parser side-tables. Needed by GC-heap modules AND by
    // FUNC-only-subtyping modules: a module declaring `sub` / `sub final` func
    // types has no heap objects but still needs this table for correct
    // call_indirect / ref.* subtype checks (without it, `sigEq`'s structural
    // compare wrongly accepts structurally-equal-but-distinct types). Decoupled
    // from `needs_gc_heap` per D-232. ADR-0115 zero-overhead preserved: the
    // cheap `mayUseTypeSubtyping` byte pre-filter skips the decode entirely for
    // non-subtyping modules; the precise `usesTypeSubtyping` then rejects byte
    // false-positives. (Decode is fresh here; consolidation with the
    // instantiateInternal decode is a future cycle.)
    if (module.find(.type)) |type_section| {
        if (module.needs_gc_heap or needs_heap_detector.mayUseTypeSubtyping(&module)) {
            var types = try sections.decodeTypes(a, type_section.body);
            defer types.deinit();
            if (module.needs_gc_heap or needs_heap_detector.usesTypeSubtyping(types)) {
                const type_info = @import("../../feature/gc/type_info.zig");
                inst.gc_type_infos = try type_info.materialiseGcTypes(a, types);
            }
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
                .tag => .tag,
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
        .tag => {}, // EH tag imports don't tally into these index spaces (10.E)
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
            .supertypes = &.{},
            .finals = &.{},
        };

    var funcs: []zir.ZirFunc = &.{};
    // Raw declared typeidx per DEFINED func (parallel to `funcs`); kept
    // in scope for the FuncEntity build below (ADR-0126 — ref.test/cast
    // on a funcref needs the raw index).
    var defined_typeidxs: []const u32 = &.{};
    if (code_section_opt) |code_section| {
        const def_idx = if (func_section) |s|
            try sections.decodeFunctions(a, s.body)
        else
            try a.alloc(u32, 0);

        const codes = try sections.decodeCodes(a, code_section.body);
        if (codes.items.len != def_idx.len) return error.InvalidModule;
        defined_typeidxs = def_idx;

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
        // Each imported func gets a placeholder body carrying its DECLARED sig
        // (not a shared empty one), so a `call_indirect` whose table slot holds
        // an imported func type-checks against the right signature (D-310). The
        // body is never executed — both host and cross-module imports dispatch
        // via host_calls (callOp / callIndirectOp); the unreachable is a backstop.
        var imp_idx: u32 = 0;
        for (imports_decoded.?.items) |it| {
            if (it.kind != .func) continue;
            const ph = try a.create(zir.ZirFunc);
            ph.* = zir.ZirFunc.init(imp_idx, types.items[it.payload.func_typeidx], &.{});
            try ph.instrs.append(a, .{ .op = .@"unreachable", .payload = 0, .extra = 0 });
            func_ptrs[imp_idx] = ph;
            imp_idx += 1;
        }
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
    // Tag index space = imported tags (kind .tag) ++ defined tags
    // (section 13), per Wasm ordering. 10.E-xmodule-tags cycle 116:
    // throwOp/catchOp index `tag_param_counts[tag_idx]` with tag_idx in
    // the FULL space — a defined-only table mis-counts imported-tag
    // throws → operand-stack underflow (same import-offset class as the
    // cyc114 validator fix). Imported tag counts come from the import's
    // declared typeidx.
    {
        var imp_tag_count: usize = 0;
        if (imports_decoded) |im| for (im.items) |it| {
            if (it.kind == .tag) imp_tag_count += 1;
        };
        const defined_tag_entries: []const sections.TagEntry = if (module.find(.tag)) |tag_section|
            try sections.decodeTags(a, tag_section.body)
        else
            &.{};
        const total_tags = imp_tag_count + defined_tag_entries.len;
        if (total_tags > 0) {
            const counts = try a.alloc(u32, total_tags);
            const slot_counts = try a.alloc(u32, total_tags);
            // ADR-0114 D1 tag identity table, parallel to counts.
            const tags_arr = try a.alloc(*runtime_mod.TagInstance, total_tags);
            var total_slots: u32 = 0;
            var ti: usize = 0;
            const fillTag = struct {
                fn f(typeidx: u32, all_types: []const zir.FuncType, c: []u32, sc: []u32, idx: usize, max_slots: *u32) !void {
                    if (typeidx >= all_types.len) return error.InvalidTypeIndex;
                    const params = all_types[typeidx].params;
                    c[idx] = @intCast(params.len);
                    var slots: u32 = 0;
                    for (params) |p| slots += runtime_mod.slotCountForValType(p);
                    sc[idx] = slots;
                    if (slots > max_slots.*) max_slots.* = slots;
                }
            }.f;
            if (imports_decoded) |im| for (im.items, 0..) |it, idx| {
                if (it.kind != .tag) continue;
                try fillTag(it.payload.tag_typeidx, types.items, counts, slot_counts, ti, &total_slots);
                // Imported tag identity = the source instance's
                // *TagInstance (cross-module pointer sharing, ADR-0114
                // D1). `bindings[idx]` is a `.tag` binding (binding-kind
                // checked earlier).
                const src = bindings.?[idx].tag;
                if (src.source_tag_index >= src.source_runtime.tags.len) return error.ImportTypeMismatch;
                tags_arr[ti] = src.source_runtime.tags[src.source_tag_index];
                ti += 1;
            };
            for (defined_tag_entries) |entry| {
                try fillTag(entry.typeidx, types.items, counts, slot_counts, ti, &total_slots);
                // Defined tag: fresh identity (its heap address IS the
                // identity per ADR-0114 D1).
                const inst_tag = try a.create(runtime_mod.TagInstance);
                inst_tag.* = .{ .typeidx = entry.typeidx };
                tags_arr[ti] = inst_tag;
                ti += 1;
            }
            rt.tag_param_counts = counts;
            rt.tag_param_slot_counts = slot_counts;
            rt.tags = tags_arr;
            // ADR-0120 D1: pre-size eh_payload to the maximum per-tag
            // slot count (single-use buffer; capacity = max not sum).
            if (total_slots > 0) {
                rt.eh_payload = try a.alloc(u64, total_slots);
                @memset(rt.eh_payload, 0);
            }
        }
    }

    // §9.6 / 6.K.1 (ADR-0014 §2.1): per-instance FuncEntity array.
    // Imported funcs (per 6.K.3) point at the source runtime so
    // call_indirect through a foreign-funcref cell routes via
    // FuncEntity.runtime. WASI imports keep the local placeholder
    // (WASI is always called by funcidx, never by ref).
    if (total_funcs > 0) {
        const entities = try a.alloc(FuncEntity, total_funcs);
        for (0..total_funcs) |i| {
            // Defined funcs sit at `imp_func_count..total_funcs`; carry
            // their raw declared typeidx for ref.test/cast RTT.
            const raw_ti: u32 = if (i >= imp_func_count and (i - imp_func_count) < defined_typeidxs.len)
                defined_typeidxs[i - imp_func_count]
            else
                0;
            entities[i] = .{
                .runtime = rt,
                .func_idx = @intCast(i),
                // TODO(9.12-audit): table storage shape — see D-126 / ADR-0068.
                // Interp instantiate path; JIT mirror-write reads these.
                // 0 = "not JIT-resolved" sentinel.
                .typeidx = 0,
                .funcptr = 0,
                .raw_typeidx = raw_ti,
            };
        }
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
        // D-199 — pointer-per-entry. Imported memories ADOPT the
        // exporter's live `*MemoryInstance` (shared growth); defined
        // memories live in this instance's owned `memory_storage`.
        const mi = try a.alloc(*runtime_mod.MemoryInstance, total_memory_count_alloc);
        const def_storage = try a.alloc(runtime_mod.MemoryInstance, def_memory_count);
        var slot: usize = 0;
        // Imports first.
        if (imp_memory_count > 0) {
            for (imports_decoded.?.items, 0..) |it, idx| {
                if (it.kind != .memory) continue;
                mi[slot] = bindings.?[idx].memory.inst; // shared exporter instance
                slot += 1;
            }
        }
        // Then defined (own storage; `mi` points into `def_storage`).
        if (defined_memories) |memories| {
            for (memories.items, 0..) |entry, di| {
                const pages = entry.min;
                // ADR-0179 #3c: a host page cap bounds the INITIAL allocation,
                // not only `memory.grow` — a declared `min` above the cap is
                // refused here before the bytes are reserved (page units match
                // `growMemory`'s direct comparison).
                if (rt.store_memory_pages_max) |cap| {
                    if (pages > cap) return error.MemoryLimitExceeded;
                }
                // Custom-page-sizes (ADR-0168 v0.2): initial bytes = min ×
                // (1 << page_size_log2). Default 64 KiB.
                const page_size: usize = @as(usize, 1) << @intCast(entry.page_size_log2);
                const bytes_total: usize = @as(usize, pages) * page_size;
                const mem = try a.alloc(u8, bytes_total);
                @memset(mem, 0);
                def_storage[di] = .{
                    .bytes = mem,
                    .idx_type = entry.idx_type,
                    .pages_min = entry.min,
                    .pages_max = entry.max,
                    .shared = entry.shared,
                    .page_size_log2 = entry.page_size_log2,
                };
                mi[slot] = &def_storage[di];
                slot += 1;
            }
        }
        rt.memories = mi;
        rt.memory_storage = def_storage;
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
            if (tables_owned) |t| {
                // 10.G cycle 166 — imported global slots for table
                // init-expr global.get. Tables are created before the
                // globals loop builds rt.globals, so extract the imported
                // slots from bindings here (i31.3 table init-expr reads
                // `global.get $g` of an imported global).
                var imp_glob_slots: []*Value = &.{};
                if (imp_global_count > 0) {
                    const gs = try a.alloc(*Value, imp_global_count);
                    var gi: usize = 0;
                    for (imports_decoded.?.items, 0..) |it, idx| {
                        if (it.kind != .global) continue;
                        gs[gi] = bindings.?[idx].global.slot;
                        gi += 1;
                    }
                    imp_glob_slots = gs;
                }
                for (t.items, 0..) |entry, i| {
                    const refs = try a.alloc(Value, entry.min);
                    if (entry.init_expr.len > 0) {
                        // Wasm 3.0 table-with-init-expr: eval the const-expr
                        // once + fill every slot with the result.
                        const v = evalConstExprValue(entry.init_expr) catch |e|
                            if (e == error.UnsupportedConstExpr)
                                try evalGlobalInitGc(entry.init_expr, rt.gc_heap, inst.gc_type_infos, rt.func_entities, imp_glob_slots)
                            else
                                return e;
                        for (refs) |*r| r.* = v;
                    } else {
                        for (refs) |*r| r.* = .{ .ref = Value.null_ref };
                    }
                    tbl_storage[imp_table_count + i] = .{
                        .refs = refs,
                        .elem_type = entry.elem_type,
                        .max = entry.max,
                    };
                }
            }
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
                const refs = if (seg.item_exprs.len > 0) blk: {
                    // 10.G cycle 164 — WasmGC general const-expr items
                    // (array.new / array.new_fixed / struct.new …): evaluate
                    // each item expr to a Value via the GC const-expr
                    // evaluator (allocates on the already-materialised
                    // gc_heap). gc/array.8 `array.new_elem` reads these.
                    const rs = try a.alloc(Value, seg.item_exprs.len);
                    // Element segments materialise before globals → no
                    // imported-global slice available; elem const-expr
                    // items (array.new/struct.new) don't use global.get.
                    for (seg.item_exprs, 0..) |ex, j| rs[j] = try evalGlobalInitGc(ex, rt.gc_heap, inst.gc_type_infos, rt.func_entities, &.{});
                    break :blk rs;
                } else blk: {
                    // For func-family segments the slot is a funcidx → resolve
                    // to a funcref. For non-func segments (i31ref/anyref/…) the
                    // slot already holds the ENCODED ref value (e.g. i31-packed,
                    // per the element decoder) → store it directly as a GcRef.
                    const is_funcref_family = seg.elem_type == .ref and switch (seg.elem_type.ref.heap_type) {
                        .abstract => |ab| ab == .func,
                        .concrete => true,
                    };
                    const rs = try a.alloc(Value, seg.funcidxs.len);
                    for (seg.funcidxs, 0..) |fidx, j| {
                        if (fidx == std.math.maxInt(u32)) {
                            rs[j] = .{ .ref = Value.null_ref };
                        } else if (is_funcref_family) {
                            if (fidx >= rt.func_entities.len) return error.InvalidElementFuncIndex;
                            rs[j] = Value.fromFuncRef(&rt.func_entities[fidx]);
                        } else {
                            rs[j] = .{ .ref = @as(u64, fidx) };
                        }
                    }
                    break :blk rs;
                };
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
                    // Wasm spec §3.5.10 — `ref.func N` is a valid global
                    // init expr. evalConstExprValue is instance-context-
                    // free, so resolve the funcref here against
                    // rt.func_entities (mirrors element-init above).
                    // ref_func.3: `(global funcref (ref.func 0))`.
                    storage[i] = if (initExprRefFuncLocal(g.init_expr)) |fidx|
                        (if (fidx < rt.func_entities.len)
                            Value.fromFuncRef(&rt.func_entities[fidx])
                        else
                            return error.InvalidGlobalRefFunc)
                    else
                        evalConstExprValue(g.init_expr) catch |e|
                            if (e == error.UnsupportedConstExpr)
                                // prior_globals = imports + already-evaluated
                                // defined globals (slots[imp+i] set just
                                // below) → global.get sees only legal
                                // lower-index const-expr references.
                                try evalGlobalInitGc(g.init_expr, rt.gc_heap, inst.gc_type_infos, rt.func_entities, slots[0 .. imp_global_count + i])
                            else
                                return e;
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
        // Populate rt.datas with the (instance-arena-owned) segment bytes
        // so memory.init / data.drop / array.new_data can read them at
        // runtime — datas.deinit() frees the decode arena, so dupe into
        // `a`. (Production previously never set rt.datas; only a test
        // helper did, so passive segments + array.new_data found it empty.)
        const seg_bytes = try a.alloc([]const u8, datas.items.len);
        for (datas.items, 0..) |seg, di| {
            seg_bytes[di] = try a.dupe(u8, seg.bytes);
            if (seg.kind != .active) continue;
            if (seg.memidx >= rt.memories.len) return error.DataSegmentOutOfRange;
            const target = rt.memories[seg.memidx]; // already a *MemoryInstance (D-199)
            const mem_idx_type: sections.MemoryEntry.IdxType = target.idx_type;
            const offset = try evalConstMemAddrExprWithGlobals(seg.offset_expr, mem_idx_type, rt.globals);
            const dst_end_u128: u128 = @as(u128, offset) + @as(u128, seg.bytes.len);
            if (dst_end_u128 > target.bytes.len) return error.DataSegmentOutOfRange;
            const dst_end: usize = @intCast(dst_end_u128);
            @memcpy(target.bytes[@intCast(offset)..dst_end], seg.bytes);
        }
        rt.datas = seg_bytes;
        rt.data_dropped = try a.alloc(bool, datas.items.len);
        @memset(rt.data_dropped, false);
    }

    if (module.find(.@"export")) |export_section| {
        const exports = try sections.decodeExports(a, export_section.body);
        inst.exports_storage = exports.items;
        inst.export_types = try buildExportTypes(a, module, exports.items, imports_decoded);
        // ADR-0127 PHASE C — retain the exporter's full type section (arena-
        // backed, freed by arena.deinit) so a cross-module func import can run
        // the cross-`Types` type-def identity check at link resolve.
        inst.export_src_types = if (module.find(.type)) |ts_sec| try sections.decodeTypes(a, ts_sec.body) else null;
        // EH cross-module tag exports (10.E-xmodule-tags): tag exports
        // (kind 0x04) are dropped from exports_storage (c_api ExternKind
        // lacks a tag variant), so scan the export section directly for
        // them into the parallel `tag_exports` side-table.
        const body = export_section.body;
        var tag_list: std.ArrayList(instance_mod.TagExport) = .empty;
        var pos: usize = 0;
        const count = try leb128.readUleb128(u32, body, &pos);
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            const name_len = try leb128.readUleb128(u32, body, &pos);
            if (pos + name_len > body.len) return error.InvalidModule;
            const name = try a.dupe(u8, body[pos .. pos + name_len]);
            pos += name_len;
            if (pos >= body.len) return error.InvalidModule;
            const kind_byte = body[pos];
            pos += 1;
            const exp_idx = try leb128.readUleb128(u32, body, &pos);
            if (kind_byte == 4) {
                try tag_list.append(a, .{ .name = name, .tag_index = exp_idx });
            }
        }
        inst.tag_exports = tag_list.items;
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
                    // Wasm 3.0 §4.5.10 — the PROVIDED func type must be a
                    // SUBTYPE of the declared import type (func subtyping,
                    // §3.3.5.1), not exact-equal. cyc192 (D-198 .30/.48/.50):
                    // a cross-module module imports the same name under
                    // multiple subtype-related sigs. Monotonic-safe vs the
                    // prior exact `eql` — only widens acceptance, so the
                    // green multi-mem + EH cross-module imports (all eql) are
                    // unaffected.
                    if (!validator.funcTypeImportCompatible(want_ft, cm.source_signature, &types)) {
                        return error.ImportTypeMismatch;
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
            if (!g.source_valtype.eql(want.valtype)) return error.ImportTypeMismatch;
            if (g.source_mutable != want.mutable) return error.ImportTypeMismatch;
        },
        .table => {
            const want = it.payload.table;
            const t = binding.table;
            if (!t.source_elem_type.eql(want.elem_type)) return error.ImportTypeMismatch;
            if (t.source_min < want.min) return error.ImportTypeMismatch;
            if (want.max) |wm| {
                const sm = t.source_max orelse return error.ImportTypeMismatch;
                if (sm > wm) return error.ImportTypeMismatch;
            }
        },
        .memory => {
            const want = it.payload.memory;
            // D-199 — source descriptor comes from the shared instance.
            // Wasm §4.5.4 matches the source's CURRENT size (a grown
            // memory's effective min = its current pages), not its
            // declared min — imports4 imports a memory grown to 2 while
            // declaring min 2.
            const m = binding.memory.inst;
            // Custom-page-sizes (ADR-0168 v0.2): page count in the source's
            // own page-size units (1 << page_size_log2; default 64 KiB).
            const src_pages: u64 = m.bytes.len / (@as(u64, 1) << @intCast(m.page_size_log2));
            if (src_pages < want.min) return error.ImportTypeMismatch;
            if (want.max) |wm| {
                const max_s = m.pages_max orelse return error.ImportTypeMismatch;
                if (max_s > wm) return error.ImportTypeMismatch;
            }
        },
        // EH tag import (10.E-xmodule-tags). v0.1 param-COUNT match:
        // importer's declared tag type (typeidx → params) vs the source
        // tag's param count. Full param-TYPE identity rides the
        // `*TagInstance` execution step (ADR-0114). NOTE:
        // `tag_param_counts` is defined-tag-indexed; `source_tag_index`
        // matches it as long as the source module imports no tags
        // (true for the spec EH source try_table.0).
        .tag => {
            const t = binding.tag;
            const want_tidx = it.payload.tag_typeidx;
            const type_sec = module.find(.type) orelse return error.ImportTypeMismatch;
            var types = try sections.decodeTypes(a, type_sec.body);
            defer types.deinit();
            if (want_tidx >= types.items.len) return error.ImportTypeMismatch;
            const want_params = types.items[want_tidx].params.len;
            const src_counts = t.source_runtime.tag_param_counts;
            if (t.source_tag_index >= src_counts.len) return error.ImportTypeMismatch;
            if (src_counts[t.source_tag_index] != want_params) return error.ImportTypeMismatch;
        },
    }
}

test "frontendValidate: imported tag occupies the tag index space (10.E-xmodule-tags cycle 114)" {
    // Module imports 1 tag (typeidx 0 = () -> ()) and a func body
    // `throw 0` references it by index 0. The validator's tag index
    // space must be [imported tags] ++ [defined tags]; pre-cycle-114
    // `frontendValidate` passed a DEFINED-only slice (here empty) →
    // `throw 0` → InvalidTagIndex → validate fail. This mirrors the
    // wasm-3.0 corpus red: try_table.1 imports test::e0 ×2, so every
    // catch/throw index was offset by 2 (func[5] StackTypeMismatch).
    const m = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // header
        0x01, 0x04, 0x01, 0x60, 0x00, 0x00, // type: () -> ()
        0x02, 0x08, 0x01, 0x01, 0x6d, 0x01, 0x74, 0x04, 0x00, 0x00, // import "m"."t" tag (typeidx 0)
        0x03, 0x02, 0x01, 0x00, // function: 1 func, type 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x08, 0x00, 0x0b, // code: (throw 0) end
    };
    try testing.expect(frontendValidate(testing.allocator, &m));
}

test "evalConstExprValue: i32.const N; ref.i31; end produces an i31 ref (10.G cycle 130)" {
    // `i32.const 42; ref.i31; end` (0x41 0x2A 0xFB 0x1C 0x0B) → (ref i31) holding 42.
    const v = try evalConstExprValue(&[_]u8{ 0x41, 0x2A, 0xFB, 0x1C, 0x0B });
    try testing.expect(Value.isI31Ref(v));
    try testing.expectEqual(@as(i32, 42), Value.refAsI31Signed(v));
    // A non-i31 GC const op in this position is unsupported (struct.new = 0x00).
    try testing.expectError(error.UnsupportedConstExpr, evalConstExprValue(&[_]u8{ 0x41, 0x00, 0xFB, 0x00, 0x00, 0x0B }));
}
