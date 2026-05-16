//! End-to-end wasm → JIT runner (Step 4 / sub-7.5b-i).
//!
//! Loads raw wasm bytes, walks the standard sections, compiles
//! every defined function via `compile_func.compileOne`, links
//! into a single JitModule, and exposes `runI32Export` /
//! `runI32EntryByIdx` for the §9.7 / 7.5 spec gate.
//!
//! Restrictions for this skeleton:
//!   - imports compile but trap unconditionally on first call
//!     (chunk 7.9-b: import-as-trap foundation; host-call dispatch
//!     lands at chunk 7.9-c)
//!   - only no-arg + i32-result entry signatures supported
//!   - trap detection deferred to sub-7.5b-ii (today: a trap
//!     in the JIT body crashes the process; only value-
//!     returning fixtures pass through this driver cleanly)
//!
//! Zone 2 (`src/engine/`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const zir = @import("../ir/zir.zig");
const validator_mod = @import("../validate/validator.zig");
const jit_dispatch = @import("../wasi/jit_dispatch.zig");
const leb128 = @import("../support/leb128.zig");
const FuncType = zir.FuncType;
const compile_func = @import("codegen/shared/compile.zig");
const linker = @import("codegen/shared/linker.zig");
const entry = @import("codegen/shared/entry.zig");
const canonical_type = @import("codegen/shared/canonical_type.zig");
const rv = @import("runner_validate.zig");

pub const Error = error{
    /// Reserved for future "import shape we cannot represent at all"
    /// failure (e.g. memory64 / shared imports beyond MVP). The
    /// chunk-b "every import call traps unconditionally" foundation
    /// does NOT raise this — function imports are accepted, indexed
    /// into the wasm-space func table, and emit a trap-stub branch
    /// at every call site.
    ///
    /// Naming: singular, matching the actual raise sites at
    /// `runtime/instance/instantiate.zig:{255,264,265,267,285,…}`.
    /// (Was misnamed `UnsupportedImports` plural pre-9.9-j-2 —
    /// declared but unraised; `test/realworld/run_runner_jit.zig`
    /// caught the plural shape and silently classified zero
    /// COMPILE-IMPORTS as a result. Fixed in this row.)
    UnsupportedImport,
    MissingTypeSection,
    MissingFunctionSection,
    MissingCodeSection,
    ExportNotFound,
    ExportIsNotFunction,
    /// Wasm spec §3.4.10: an export's idx must reference a
    /// defined entity (funcidx < total_funcs, tableidx <
    /// total_tables, memidx < total_memories, globalidx <
    /// total_globals). Surfaced at compile time by the export
    /// validation pass so `assert_invalid` modules with
    /// out-of-range export targets reject at compileWasm.
    ExportIdxOutOfRange,
    /// Wasm spec §3.4.10: within a module, all exported names
    /// must be pairwise distinct. Two exports sharing the same
    /// name string is an invalid module.
    DuplicateExport,
    /// Wasm spec §3.4.4: at most one memory in Wasm 2.0
    /// (multi-memory is a Wasm 3.0 proposal). Modules with
    /// `(memory 0) (memory 0)` or `(memory (import …)) (memory 0)`
    /// are invalid.
    MultipleMemories,
    /// Wasm spec §3.4.4: memory limits must satisfy
    /// `min ≤ max` (when max specified) and `max ≤ 65536`
    /// (4 GiB cap). Modules with `(memory 1 0)`,
    /// `(memory 65537)`, `(memory 0 65537)`, etc. are invalid.
    InvalidMemoryLimit,
    /// Wasm spec §3.4.7: an active data segment references a
    /// memory that does not exist (no memory section + no
    /// memory imports, or memidx out of range).
    DataSegmentRequiresMemory,
    /// Wasm spec §3.4.5: table limits must satisfy `min ≤ max`
    /// when max is specified.
    InvalidTableLimit,
    /// Wasm spec §3.4.6: an active element segment references
    /// a tableidx outside the [0, total_tables) range.
    ElemSegmentRequiresTable,
    /// Wasm spec §3.4.6: an active element segment's
    /// `elem_type` (funcref / externref) does not match the
    /// referenced table's `elem_type`.
    ElemSegmentTypeMismatch,
    /// Wasm spec §3.2.9 / §3.4.9: a function import's
    /// `typeidx` references a type not defined in the type
    /// section.
    ImportTypeIdxOutOfRange,
    /// Wasm spec §3.4.8: the start function must have
    /// signature `[] → []` (no params, no results) AND its
    /// funcidx must be in range.
    InvalidStartFunction,
    /// Wasm spec §5.5.13: when a data count section is
    /// present, its value must equal the data section's entry
    /// count. Triggered by `binary.{62,63,64}.wasm`.
    DataCountMismatch,
} || compile_func.Error || parser.Error || sections.Error || linker.Error || entry.Error || validator_mod.Error || rv.Error;
// `InvalidGlobalInitExpr` / `UnsupportedEntrySignature` /
// `UnsupportedConstExpr` originate in `runner_validate.zig`
// (per ADR-0064) and are merged in via `|| rv.Error` above.

/// Compile every defined function in `wasm_bytes` and link into
/// a single JitModule. Caller owns the module — pair with
/// `module.deinit`. The `func_results` slice is also returned so
/// the caller can introspect / `deinitFuncResult` each one.
pub const CompiledWasm = struct {
    module: linker.JitModule,
    func_results: []compile_func.FuncResult,
    /// Wasm-space function signatures: imports first (length =
    /// `num_imports`), then defined functions. Indexed by the
    /// wasm function index (matches `Export.idx`, `call N` payload,
    /// validator's `func_types`).
    func_sigs: []FuncType,
    /// Wasm-space typeidxs (parallel to `func_sigs`). Needed by
    /// `setupRuntime` so the per-table-entry typeidx published in
    /// `JitRuntime.typeidx_base` matches what the JIT-emitted
    /// call_indirect type-check loads (which compares against the
    /// call_indirect's static typeidx immediate).
    func_typeidxs: []u32,
    /// Number of function imports. The first `num_imports` entries
    /// of `func_sigs` correspond to imports (no body compiled);
    /// `func_results` covers only the defined functions and is
    /// indexed by `defined_idx = wasm_idx - num_imports`.
    num_imports: u32,
    /// Per-defined-global metadata (ADR-0052; §9.9 / 9.9-h-2).
    /// `globals_offsets[i]` is the byte offset of defined global
    /// `i` inside the runtime's globals byte buffer;
    /// `globals_valtypes[i]` selects the JIT emit path for
    /// global.get / global.set on that index. Scalar globals
    /// (i32/i64/f32/f64/ref) occupy 8 bytes; v128 globals
    /// occupy 16 bytes with 16-byte alignment padding.
    /// `globals_byte_size` is the total bytes the runtime
    /// needs to allocate (16-byte aligned; sum of per-global
    /// sizes plus alignment padding). Empty slices / zero when
    /// the module has no defined globals.
    globals_offsets: []u32,
    globals_valtypes: []zir.ValType,
    globals_byte_size: u32,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CompiledWasm, allocator: Allocator) void {
        for (self.func_results) |*r| compile_func.deinitFuncResult(allocator, r);
        allocator.free(self.func_results);
        allocator.free(self.func_sigs);
        allocator.free(self.func_typeidxs);
        allocator.free(self.globals_offsets);
        allocator.free(self.globals_valtypes);
        self.module.deinit(allocator);
        self.arena.deinit();
    }
};

pub fn compileWasm(allocator: Allocator, wasm_bytes: []const u8) Error!CompiledWasm {
    var module = try parser.parse(allocator, wasm_bytes);
    defer module.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Decode the import section (chunk 7.9-b). Imports are accepted
    // in MVP shape; only function imports contribute to the wasm
    // function index space. Memory / table / global imports are
    // recorded as kind-only — table-size / globals_base / mem
    // wiring lands at chunk 7.9-c when host-call dispatch arrives.
    var imports_buf: ?sections.Imports = null;
    defer if (imports_buf) |*ib| ib.deinit();
    if (module.find(.import)) |s| imports_buf = try sections.decodeImports(allocator, s.body);

    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage):
    // Wasm spec §5.5.3 type section canonical encoding. Eager
    // decode catches malformed LEB128 (over-long / overflow) in
    // count / param_count / result_count, non-0x60 functype
    // tags, malformed valtype bytes, and trailing bytes. Without
    // this proactive decode, modules with type section but no
    // imports / function section silently passed (the type
    // section's content was never read). Drains
    // binary-leb128.{31,32,56,57,90} + binary.74.
    if (module.find(.type)) |ts| {
        var t = try sections.decodeTypes(a, ts.body);
        t.deinit();
    }

    // §9.9 / 9.9-l-1b-d093-d75 (skip-impl drainage):
    // Wasm spec §3.4.4 memory section validation. Three rules:
    //   (a) Total memories (import + defined) ≤ 1 in Wasm 2.0
    //       (multi-memory is a Wasm 3.0 proposal; rejected).
    //   (b) For each memory's limits: min ≤ 65536 (4 GiB cap),
    //       max ≤ 65536 if specified, AND max ≥ min if both
    //       specified.
    //   (c) Data segments require a memory to exist (active
    //       segments with memidx≥mem_count, or any data segment
    //       in a module with zero memories, are invalid).
    // Drains the `memory` + portions of `data` SKIP-VALIDATOR-GAP
    // families — previously compileWasm accepted these shapes
    // and the runner surfaced SKIP-VALIDATOR-GAP at the
    // `.assert_invalid` arm.
    {
        const max_mem_pages: u32 = 65536;
        var num_memory_imports: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .memory) {
                num_memory_imports += 1;
            };
        }
        var defined_memories: u32 = 0;
        if (module.find(.memory)) |ms| {
            var ms_buf = try sections.decodeMemory(a, ms.body);
            defer ms_buf.deinit();
            defined_memories = @intCast(ms_buf.items.len);
            for (ms_buf.items) |mem_entry| {
                if (mem_entry.min > max_mem_pages) return Error.InvalidMemoryLimit;
                if (mem_entry.max) |max| {
                    if (max > max_mem_pages) return Error.InvalidMemoryLimit;
                    if (max < mem_entry.min) return Error.InvalidMemoryLimit;
                }
            }
        }
        if (num_memory_imports + defined_memories > 1) return Error.MultipleMemories;
        // Data section requires a memory to exist (Wasm 2.0
        // §3.4.7 — `C.mems[memidx]` must be defined). With our
        // memidx fixed at 0 (single-memory MVP), the requirement
        // collapses to "≥ 1 memory exists".
        if (module.find(.data)) |ds| {
            var ds_buf = try sections.decodeData(a, ds.body);
            defer ds_buf.deinit();
            for (ds_buf.items) |seg| {
                if (seg.kind != .passive) {
                    // Active or active-with-memidx (kind 0 / 2):
                    // segment requires a memory.
                    if (num_memory_imports + defined_memories == 0) {
                        return Error.DataSegmentRequiresMemory;
                    }
                    if (seg.memidx >= num_memory_imports + defined_memories) {
                        return Error.DataSegmentRequiresMemory;
                    }
                }
            }
        }
    }

    // §9.9 / 9.9-l-1b-d093-d76 (skip-impl drainage):
    // Wasm spec §3.4.5 table + §3.4.6 element validation.
    //   (a) §3.4.5 Table limits: `min ≤ max` if max specified.
    //       (Unlike memory, table doesn't have a hard cap on
    //       count in spec text — Wasm 2.0 §A.3 limits to one
    //       table at-instance-time only; we keep that as a
    //       Phase-10+ refinement.)
    //   (b) §3.4.6 Element segment table reference: an active
    //       elem segment's tableidx must reference an existing
    //       table (import + defined).
    // Also §3.4.9 import typeidx validation: each function
    // import's `typeidx` must reference a defined type.
    // Drains `table` (size mins/max + unknown table) and
    // portions of `elem` (unknown table) SKIP-VALIDATOR-GAP.
    {
        // Build a combined table reftype map (imports + defined)
        // so the elem-segment validation can check reftype
        // compatibility (§3.4.6 — active elem.elem_type must
        // match its target table's elem_type).
        var num_table_imports: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .table) {
                num_table_imports += 1;
            };
        }
        var defined_tables: u32 = 0;
        var defined_tables_reftypes: []const zir.ValType = &.{};
        if (module.find(.table)) |ts| {
            var ts_buf = try sections.decodeTables(a, ts.body);
            defer ts_buf.deinit();
            defined_tables = @intCast(ts_buf.items.len);
            for (ts_buf.items) |tbl_entry| {
                if (tbl_entry.max) |max| {
                    if (max < tbl_entry.min) return Error.InvalidTableLimit;
                }
            }
            // Copy reftypes into arena-allocated slice that
            // outlives the local `ts_buf`.
            const reftypes_mut = try a.alloc(zir.ValType, ts_buf.items.len);
            for (ts_buf.items, 0..) |t, i| reftypes_mut[i] = t.elem_type;
            defined_tables_reftypes = reftypes_mut;
        }
        const total_tables = num_table_imports + defined_tables;
        // Compute total funcs (imports + defined) so elem
        // segments can be range-checked. Used by the
        // §9.9 / 9.9-l-1b-d093-d83 funcidx-range check below.
        var num_func_imports_early: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .func) {
                num_func_imports_early += 1;
            };
        }
        var defined_funcs_count_early: u32 = 0;
        if (module.find(.function)) |fs| {
            const fs_buf = try sections.decodeFunctions(a, fs.body);
            defined_funcs_count_early = @intCast(fs_buf.len);
        }
        const total_funcs_early = num_func_imports_early + defined_funcs_count_early;
        // Active elem segments require a referenced table AND
        // their elem_type must match the table's elem_type
        // (§9.9 / 9.9-l-1b-d093-d80 elem reftype check).
        // §9.9 / 9.9-l-1b-d093-d83: all elem segments (active /
        // passive / declarative) must have every non-null
        // funcidx in [0, total_funcs). `funcidxs[i] ==
        // maxInt(u32)` encodes `ref.null` (init-expr form);
        // skip those.
        if (module.find(.element)) |es| {
            var es_buf = try sections.decodeElement(a, es.body);
            defer es_buf.deinit();
            for (es_buf.items) |seg| {
                for (seg.funcidxs) |fidx| {
                    if (fidx == std.math.maxInt(u32)) continue;
                    if (fidx >= total_funcs_early) return Error.InvalidFuncIndex;
                }
                if (seg.kind == .active) {
                    if (seg.tableidx >= total_tables) {
                        return Error.ElemSegmentRequiresTable;
                    }
                    // Look up the referenced table's reftype.
                    const tbl_reftype: zir.ValType = blk: {
                        if (seg.tableidx < num_table_imports) {
                            // Walk imports to find the N-th table import.
                            var seen: u32 = 0;
                            const ib = imports_buf orelse return Error.ElemSegmentRequiresTable;
                            for (ib.items) |imp| {
                                if (imp.kind != .table) continue;
                                if (seen == seg.tableidx) break :blk imp.payload.table.elem_type;
                                seen += 1;
                            }
                            return Error.ElemSegmentRequiresTable;
                        } else {
                            const di = seg.tableidx - num_table_imports;
                            break :blk defined_tables_reftypes[di];
                        }
                    };
                    if (seg.elem_type != tbl_reftype) {
                        return Error.ElemSegmentTypeMismatch;
                    }
                }
            }
        }
        // §3.4.9 / §3.2.9 import typeidx range: `(import "x" "y"
        // (func (type N)))` requires `N < types.len`. The main
        // path already enforces this at line ~250 via the
        // tidx-vs-types-len check, but only when sig_count > 0
        // hits that branch. Mirror the check here so it fires
        // unconditionally regardless of the empty-fn vs main
        // path.
        if (imports_buf) |ib| {
            // Skip when no type section AND no function imports
            // (nothing to validate).
            const has_func_imports = blk: {
                for (ib.items) |imp| if (imp.kind == .func) break :blk true;
                break :blk false;
            };
            if (has_func_imports) {
                const type_section = module.find(.type) orelse return Error.MissingTypeSection;
                var types_buf = try sections.decodeTypes(a, type_section.body);
                defer types_buf.deinit();
                for (ib.items) |imp| {
                    if (imp.kind != .func) continue;
                    if (imp.payload.func_typeidx >= types_buf.items.len) {
                        return Error.ImportTypeIdxOutOfRange;
                    }
                }
            }
        }
    }

    // Per Wasm spec: type / function / code sections are all
    // OPTIONAL — a module with no defined functions is valid
    // (just header + optional non-function sections). Bail out
    // early with an empty CompiledWasm in that case rather than
    // demanding a type section. (A module may have imports but no
    // defined functions; that case also returns an empty
    // JitModule — call-by-export to an import-only function is
    // unreachable from JIT-compiled code today.)
    // D-127 (d-52): Wasm spec allows an EMPTY Function section
    // (count=0) without a corresponding Type section
    // (binary.60.wasm). Treat empty function section like absent
    // function section — both bypass the type-section requirement
    // since neither contributes defined funcs.
    const func_section_opt = blk: {
        const opt = module.find(.function);
        if (opt) |s| {
            // Empty function section body = single LEB128 0x00 byte.
            if (s.body.len == 1 and s.body[0] == 0x00) break :blk null;
        }
        break :blk opt;
    };
    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage):
    // Wasm spec §5.5.6: function and code sections must be
    // present together and have equal entry counts. The
    // function-section + code-section count match is enforced
    // in the main path below; this mirror catches "code
    // section without function section" (binary.57.wasm).
    if (func_section_opt == null) {
        if (module.find(.code)) |cs| {
            // Decode the code section and reject when non-empty.
            var c_buf = try sections.decodeCodes(a, cs.body);
            defer c_buf.deinit();
            if (c_buf.items.len != 0) return Error.MissingFunctionSection;
        }
    }
    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage):
    // Wasm spec §5.5.13 data count section: when present, its
    // value must equal the number of data segments in the data
    // section. Absence of data section with non-zero
    // data_count, or count mismatch, is malformed.
    // Drains binary.{62,63,64}.
    if (module.find(.data_count)) |dcs| {
        var pos: usize = 0;
        const dc_value = try leb128.readUleb128(u32, dcs.body, &pos);
        if (pos != dcs.body.len) return Error.TrailingBytes;
        const data_seg_count: u32 = if (module.find(.data)) |ds| blk: {
            var ds_buf = try sections.decodeData(a, ds.body);
            defer ds_buf.deinit();
            break :blk @intCast(ds_buf.items.len);
        } else 0;
        if (dc_value != data_seg_count) return Error.DataCountMismatch;
    }
    if (func_section_opt == null) {
        // §9.9 / 9.9-l-1b-d093-d69 (D-135 discharge): each
        // allocation below was previously uncovered by errdefer.
        // The downstream `Error.MissingTypeSection` paths (at the
        // `module.find(.type) orelse return` site below and at
        // the `tidx >= types.items.len` check) leaked the
        // already-made allocations under the runCorpus
        // `.assert_invalid` arm on OrbStack Linux x86_64 (4 leak
        // sites per process exit per d-65 valgrind / d-69 stack
        // traces). The fix is structural: pair each `alloc` with
        // an `errdefer free` so an error return after the alloc
        // unwinds cleanly. The success-path `return` does not
        // fire errdefers, so the returned `CompiledWasm` still
        // owns the allocations and the caller's `c.deinit(gpa)`
        // path remains correct.
        const empty_results = try allocator.alloc(compile_func.FuncResult, 0);
        errdefer allocator.free(empty_results);
        // Build func_sigs from import-only function entries (if any)
        // so `findExportFunc` → wasm-space idx → func_sigs[idx]
        // resolution remains valid for export-import re-exports.
        var sig_count: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| {
                if (imp.kind == .func) sig_count += 1;
            }
        }
        var empty_module = try linker.link(allocator, &.{}, sig_count);
        errdefer empty_module.deinit(allocator);
        const sigs = try allocator.alloc(FuncType, sig_count);
        errdefer allocator.free(sigs);
        const typeidxs = try allocator.alloc(u32, sig_count);
        errdefer allocator.free(typeidxs);
        const empty_global_offsets = try allocator.alloc(u32, 0);
        errdefer allocator.free(empty_global_offsets);
        const empty_global_valtypes = try allocator.alloc(zir.ValType, 0);
        errdefer allocator.free(empty_global_valtypes);
        if (imports_buf) |ib| {
            // Need a type section to resolve func imports' typeidx.
            if (sig_count > 0) {
                const type_section = module.find(.type) orelse return Error.MissingTypeSection;
                var types = try sections.decodeTypes(a, type_section.body);
                defer types.deinit();
                var w: u32 = 0;
                for (ib.items) |imp| {
                    if (imp.kind != .func) continue;
                    const tidx = imp.payload.func_typeidx;
                    if (tidx >= types.items.len) return Error.MissingTypeSection;
                    sigs[w] = types.items[tidx];
                    typeidxs[w] = tidx;
                    w += 1;
                }
            }
        }
        // §9.9 / 9.9-l-1b-d093-d74 export validation (empty-fn path
        // mirror of the main-path check below). Wasm spec §3.4.10:
        // each export's idx must reference a defined entity AND
        // names must be pairwise distinct. Many `assert_invalid`
        // modules in `exports.wast` lack a function section (e.g.
        // `(module (export "a" (func 0)))` with zero funcs) so
        // they take this empty-fn early-return path; without this
        // check they'd compileWasm-accept and surface as
        // SKIP-VALIDATOR-GAP.

        // §9.9 / 9.9-l-1b-d093-d77 mirror — empty-fn path
        // global init-expr validation. Most `global.wast`
        // assert_invalid modules consist of a global section
        // only (no function/code), so they take this branch.
        // Without this check the global init-expr validator
        // would never fire on them.
        var num_global_imports_empty: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| if (imp.kind == .global) {
                num_global_imports_empty += 1;
            };
        }
        // §9.9 / 9.9-l-1b-d093-d82 — total_funcs for empty-fn
        // path = number of function imports only (no defined
        // functions). Used by validateGlobalInitExpr's ref.func
        // arm for range-checking funcidxs in global / offset
        // const-exprs.
        const total_funcs_empty_for_init: u32 = sig_count;
        if (module.find(.global)) |gs| {
            var gs_buf = try sections.decodeGlobals(a, gs.body);
            defer gs_buf.deinit();
            for (gs_buf.items) |gd| {
                try rv.validateGlobalInitExpr(gd.init_expr, gd.valtype, num_global_imports_empty, imports_buf, total_funcs_empty_for_init);
            }
        }
        // §9.9 / 9.9-l-1b-d093-d78 mirror — empty-fn path
        // elem + data active-offset_expr validation.
        if (module.find(.data)) |ds| {
            var ds_buf = try sections.decodeData(a, ds.body);
            defer ds_buf.deinit();
            for (ds_buf.items) |seg| {
                if (seg.kind == .active) {
                    try rv.validateGlobalInitExpr(seg.offset_expr, .i32, num_global_imports_empty, imports_buf, total_funcs_empty_for_init);
                }
            }
        }
        if (module.find(.element)) |es| {
            var es_buf = try sections.decodeElement(a, es.body);
            defer es_buf.deinit();
            for (es_buf.items) |seg| {
                if (seg.kind == .active) {
                    try rv.validateGlobalInitExpr(seg.offset_expr, .i32, num_global_imports_empty, imports_buf, total_funcs_empty_for_init);
                }
            }
        }

        if (module.find(.@"export")) |es| {
            var exports = try sections.decodeExports(a, es.body);
            defer exports.deinit();
            var num_table_imports: u32 = 0;
            var num_memory_imports: u32 = 0;
            var num_global_imports: u32 = 0;
            if (imports_buf) |ib| {
                for (ib.items) |imp| switch (imp.kind) {
                    .func => {},
                    .table => num_table_imports += 1,
                    .memory => num_memory_imports += 1,
                    .global => num_global_imports += 1,
                };
            }
            const defined_tables: u32 = if (module.find(.table)) |ts| blk: {
                var ts_buf = try sections.decodeTables(a, ts.body);
                defer ts_buf.deinit();
                break :blk @intCast(ts_buf.items.len);
            } else 0;
            const defined_memories: u32 = if (module.find(.memory)) |ms| blk: {
                var ms_buf = try sections.decodeMemory(a, ms.body);
                defer ms_buf.deinit();
                break :blk @intCast(ms_buf.items.len);
            } else 0;
            const defined_globals_section: u32 = if (module.find(.global)) |gs| blk: {
                var gs_buf = try sections.decodeGlobals(a, gs.body);
                defer gs_buf.deinit();
                break :blk @intCast(gs_buf.items.len);
            } else 0;
            const total_tables_empty: u32 = num_table_imports + defined_tables;
            const total_memories_empty: u32 = num_memory_imports + defined_memories;
            const total_globals_empty: u32 = num_global_imports + defined_globals_section;
            const total_funcs_empty: u32 = sig_count;
            var seen_names: std.StringHashMap(void) = .init(a);
            defer seen_names.deinit();
            try seen_names.ensureTotalCapacity(@intCast(exports.items.len));
            for (exports.items) |e| {
                const gop = try seen_names.getOrPut(e.name);
                if (gop.found_existing) return Error.DuplicateExport;
                const ok = switch (e.kind) {
                    .func => e.idx < total_funcs_empty,
                    .table => e.idx < total_tables_empty,
                    .memory => e.idx < total_memories_empty,
                    .global => e.idx < total_globals_empty,
                };
                if (!ok) return Error.ExportIdxOutOfRange;
            }
        }
        return .{
            .module = empty_module,
            .func_results = empty_results,
            .func_sigs = sigs,
            .func_typeidxs = typeidxs,
            .num_imports = sig_count,
            .globals_offsets = empty_global_offsets,
            .globals_valtypes = empty_global_valtypes,
            .globals_byte_size = 0,
            .arena = arena,
        };
    }

    const type_section = module.find(.type) orelse return Error.MissingTypeSection;
    var types = try sections.decodeTypes(a, type_section.body);
    defer types.deinit();

    const defined_func_typeidx = try sections.decodeFunctions(a, func_section_opt.?.body);

    const code_section = module.find(.code) orelse return Error.MissingCodeSection;
    var codes = try sections.decodeCodes(a, code_section.body);
    defer codes.deinit();

    if (codes.items.len != defined_func_typeidx.len) return Error.MissingCodeSection;

    // §9.9 / 9.9-l-1b-d093-d84 (skip-impl drainage): track
    // whether the optional data_count section is present. Wasm
    // spec §5.5.10 requires the section whenever any function
    // body uses `memory.init` (0xFC 0x08) or `data.drop` (0xFC
    // 0x09). The validator enforces this via its
    // `data_count_section_present` field during opcode walk
    // (drains binary.{66,67}).
    const data_count_section_present: bool = module.find(.data_count) != null;

    // Count function imports (memory / table / global imports do
    // not extend the function index space).
    var num_imports: u32 = 0;
    if (imports_buf) |ib| {
        for (ib.items) |imp| {
            if (imp.kind == .func) num_imports += 1;
        }
    }

    // Build the unified wasm-space func_sigs vector:
    // `[import_func_sigs..., defined_func_sigs...]`. Indexed by
    // wasm function index throughout (validator, lower, emit).
    const total_funcs = num_imports + @as(u32, @intCast(defined_func_typeidx.len));
    const func_sigs = try allocator.alloc(FuncType, total_funcs);
    errdefer allocator.free(func_sigs);
    const func_typeidxs = try allocator.alloc(u32, total_funcs);
    errdefer allocator.free(func_typeidxs);
    if (imports_buf) |ib| {
        var w: u32 = 0;
        for (ib.items) |imp| {
            if (imp.kind != .func) continue;
            const tidx = imp.payload.func_typeidx;
            if (tidx >= types.items.len) return Error.MissingTypeSection;
            func_sigs[w] = types.items[tidx];
            func_typeidxs[w] = tidx;
            w += 1;
        }
    }
    for (defined_func_typeidx, 0..) |type_idx, i| {
        if (type_idx >= types.items.len) return Error.MissingTypeSection;
        func_sigs[num_imports + i] = types.items[type_idx];
        func_typeidxs[num_imports + i] = type_idx;
    }

    // §9.9 / 9.9-l-1b-d093-d76 (skip-impl drainage):
    // Wasm spec §3.4.8 start function validation. A start
    // section (id=8) carries a single funcidx; the referenced
    // function must (a) exist in the function index space and
    // (b) have signature `[] → []` (no params, no results).
    // Drains `start.wast` SKIP-VALIDATOR-GAP for "unknown
    // function" / "start function must be [] → []".
    if (module.find(.start)) |ss| {
        var pos: usize = 0;
        const start_funcidx = try leb128.readUleb128(u32, ss.body, &pos);
        if (pos != ss.body.len) return Error.UnsupportedEntrySignature; // trailing bytes in start section
        if (start_funcidx >= total_funcs) return Error.InvalidStartFunction;
        const start_sig = func_sigs[start_funcidx];
        if (start_sig.params.len != 0 or start_sig.results.len != 0) {
            return Error.InvalidStartFunction;
        }
    }

    // 7.5-close-d042-prep: decode globals / tables / data /
    // elements so we can build the validator's per-function
    // type-checking context. Sections are OPTIONAL; absent
    // sections yield empty slices / 0 counts.
    var globals_buf: ?sections.Globals = null;
    defer if (globals_buf) |*g| g.deinit();
    var tables_buf: ?sections.Tables = null;
    defer if (tables_buf) |*t| t.deinit();
    var datas_buf: ?sections.Datas = null;
    defer if (datas_buf) |*d| d.deinit();
    var elems_buf: ?sections.Elements = null;
    defer if (elems_buf) |*e| e.deinit();

    if (module.find(.global)) |s| globals_buf = try sections.decodeGlobals(allocator, s.body);
    if (module.find(.table)) |s| tables_buf = try sections.decodeTables(allocator, s.body);
    if (module.find(.data)) |s| datas_buf = try sections.decodeData(allocator, s.body);
    if (module.find(.element)) |s| elems_buf = try sections.decodeElement(allocator, s.body);

    // §9.9 / 9.9-l-1b-d093-d77 (skip-impl drainage):
    // Wasm spec §3.4.3 / §3.3.2 global init-expression
    // validation. Per spec, a defined global's init_expr
    // must be a "constant expression": single const opcode
    // (i32/i64/f32/f64.const, ref.null, ref.func, or
    // global.get of an *imported* *immutable* global)
    // followed by `end (0x0B)`, AND the result type must
    // match the declared valtype.
    // Count global imports once for d-77 + d-78 const-expr
    // checks (init-expr `global.get` must reference an
    // imported immutable global).
    var num_global_imports_main: u32 = 0;
    if (imports_buf) |ib| {
        for (ib.items) |imp| if (imp.kind == .global) {
            num_global_imports_main += 1;
        };
    }
    if (globals_buf) |g| {
        for (g.items) |gd| {
            try rv.validateGlobalInitExpr(gd.init_expr, gd.valtype, num_global_imports_main, imports_buf, total_funcs);
        }
    }

    // §9.9 / 9.9-l-1b-d093-d78 (skip-impl drainage):
    // Wasm spec §3.4.6 / §3.4.7 — active elem/data segment
    // **offset expressions** must be `i32`-typed constant
    // expressions per §3.3.2. Drains `elem` + `data`
    // SKIP-VALIDATOR-GAP entries with "type mismatch",
    // "constant expression required", "unknown global" in
    // offset positions.
    if (datas_buf) |d| {
        for (d.items) |seg| {
            if (seg.kind == .active) {
                try rv.validateGlobalInitExpr(seg.offset_expr, .i32, num_global_imports_main, imports_buf, total_funcs);
            }
        }
    }
    if (elems_buf) |e| {
        for (e.items) |seg| {
            if (seg.kind == .active) {
                try rv.validateGlobalInitExpr(seg.offset_expr, .i32, num_global_imports_main, imports_buf, total_funcs);
            }
        }
    }

    const validator_globals = try a.alloc(validator_mod.GlobalEntry, if (globals_buf) |g| g.items.len else 0);
    if (globals_buf) |g| {
        for (g.items, 0..) |gd, gi| {
            validator_globals[gi] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
        }
    }

    // ADR-0052 §9.9 / 9.9-h-2 — per-defined-global byte offsets.
    // Scalar globals (i32/i64/f32/f64/ref) occupy 8 bytes; v128
    // globals occupy 16 bytes with 16-byte alignment padding.
    // Indexed by defined-global idx (i.e. import-globals are NOT
    // counted; the JIT emit path keys off this same indexing via
    // its `payload < imp_globals` branch — out of scope this chunk,
    // tracked under D-079).
    const defined_globals_count: u32 = if (globals_buf) |g| @intCast(g.items.len) else 0;
    const globals_offsets = try allocator.alloc(u32, defined_globals_count);
    errdefer allocator.free(globals_offsets);
    const globals_valtypes = try allocator.alloc(zir.ValType, defined_globals_count);
    errdefer allocator.free(globals_valtypes);
    var globals_byte_size: u32 = 0;
    if (globals_buf) |g| {
        var off: u32 = 0;
        for (g.items, 0..) |gd, gi| {
            globals_valtypes[gi] = gd.valtype;
            const size_align: struct { size: u32, alignv: u32 } = switch (gd.valtype) {
                .v128 => .{ .size = 16, .alignv = 16 },
                .i32, .i64, .f32, .f64, .funcref, .externref => .{ .size = 8, .alignv = 8 },
            };
            off = std.mem.alignForward(u32, off, size_align.alignv);
            globals_offsets[gi] = off;
            off += size_align.size;
        }
        // Round total up to 16 bytes so the byte buffer is safe to
        // address as v128 from any starting position.
        globals_byte_size = std.mem.alignForward(u32, off, 16);
    }
    const validator_tables: []const zir.TableEntry = if (tables_buf) |t| t.items else &.{};
    const validator_data_count: u32 = if (datas_buf) |d| @intCast(d.items.len) else 0;
    const validator_elem_count: u32 = if (elems_buf) |e| @intCast(e.items.len) else 0;

    // §9.9 / 9.9-l-1b-d093-d74 (skip-impl drainage):
    // Wasm spec §3.4.10 export validation. Decode the export
    // section (when present) and verify:
    //   (a) Each export's idx references a defined entity in
    //       its kind's index space (func / table / memory /
    //       global).
    //   (b) All exported names within a module are pairwise
    //       distinct (no duplicates).
    // Drains `assert_invalid` modules whose validity hinges on
    // these spec rules — previously SKIP-VALIDATOR-GAP at the
    // `.assert_invalid` runner arm because compileWasm
    // accepted them.
    if (module.find(.@"export")) |s| {
        var exports = try sections.decodeExports(a, s.body);
        defer exports.deinit();

        // Count imports per kind (memory / table / global
        // imports occupy slots 0..N before any defined entity).
        var num_table_imports: u32 = 0;
        var num_memory_imports: u32 = 0;
        var num_global_imports: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| switch (imp.kind) {
                .func => {},
                .table => num_table_imports += 1,
                .memory => num_memory_imports += 1,
                .global => num_global_imports += 1,
            };
        }
        const total_tables: u32 = num_table_imports + @as(u32, @intCast(if (tables_buf) |t| t.items.len else 0));
        const total_globals: u32 = num_global_imports + defined_globals_count;
        // Memory section: at most one memory in Wasm 2.0
        // (multi-memory is a Wasm 3.0 proposal; out of scope).
        const defined_memories: u32 = if (module.find(.memory)) |ms| blk: {
            var ms_buf = try sections.decodeMemory(a, ms.body);
            defer ms_buf.deinit();
            break :blk @intCast(ms_buf.items.len);
        } else 0;
        const total_memories: u32 = num_memory_imports + defined_memories;

        // Track names for duplicate detection. Backed by the
        // arena `a` (function-local), released on compileWasm
        // return.
        var seen_names: std.StringHashMap(void) = .init(a);
        defer seen_names.deinit();
        try seen_names.ensureTotalCapacity(@intCast(exports.items.len));
        for (exports.items) |e| {
            const gop = try seen_names.getOrPut(e.name);
            if (gop.found_existing) return Error.DuplicateExport;
            const ok = switch (e.kind) {
                .func => e.idx < total_funcs,
                .table => e.idx < total_tables,
                .memory => e.idx < total_memories,
                .global => e.idx < total_globals,
            };
            if (!ok) return Error.ExportIdxOutOfRange;
        }
    }

    // Compile each defined function. On failure, log the
    // offending func_idx to stderr — the spec-jit-compile runner
    // captures this via `2>&1 > /tmp/<host>.log` so root-cause
    // bisection (which fixture, which function) is visible
    // without re-running the gate.
    // §9.9 / 9.9-l-1b-d093-d79: count memories (imports +
    // defined) so the validator can reject memory ops
    // (load/store/size/grow/fill/copy/init) in function bodies
    // when the module has no memory.
    var validator_memory_count: u32 = 0;
    if (imports_buf) |ib| {
        for (ib.items) |imp| if (imp.kind == .memory) {
            validator_memory_count += 1;
        };
    }
    if (module.find(.memory)) |ms| {
        var ms_buf = try sections.decodeMemory(a, ms.body);
        defer ms_buf.deinit();
        validator_memory_count += @intCast(ms_buf.items.len);
    }

    // §9.9 / 9.9-l-1b-d093-d83 (skip-impl drainage):
    // Wasm spec §3.3.5.20 table.init elem-vs-table reftype
    // matching. Build the per-elem-segment reftype slice; the
    // validator's opTableInit compares against the destination
    // table's reftype.
    const elem_types_slice: []const zir.ValType = if (elems_buf) |e| blk: {
        const out = try a.alloc(zir.ValType, e.items.len);
        for (e.items, 0..) |seg, i| out[i] = seg.elem_type;
        break :blk out;
    } else &.{};

    // §9.9 / 9.9-l-1b-d093-d82 (skip-impl drainage):
    // Wasm spec §3.4.7.3 / §3.4.10 declared-funcrefs set. A
    // funcidx is "declared" iff it appears in some global
    // initializer, element segment (funcidx or init-expr), or
    // export (kind=func). Function code bodies and the start
    // function do NOT contribute. Used by the validator's
    // `opRefFunc` to reject `ref.func N` when N is not in the
    // declared set ("undeclared function reference").
    const declared_funcs = try a.alloc(bool, total_funcs);
    @memset(declared_funcs, false);
    if (globals_buf) |g| {
        for (g.items) |gd| {
            if (rv.initExprRefFunc(gd.init_expr)) |fidx| {
                if (fidx < total_funcs) declared_funcs[fidx] = true;
            }
        }
    }
    if (elems_buf) |e| {
        for (e.items) |seg| {
            for (seg.funcidxs) |fidx| {
                // ref.null entries are encoded as maxInt(u32);
                // skip those.
                if (fidx != std.math.maxInt(u32) and fidx < total_funcs) {
                    declared_funcs[fidx] = true;
                }
            }
        }
    }
    if (module.find(.@"export")) |s| {
        var exports = try sections.decodeExports(a, s.body);
        defer exports.deinit();
        for (exports.items) |e| {
            if (e.kind == .func and e.idx < total_funcs) {
                declared_funcs[e.idx] = true;
            }
        }
    }

    const results = try allocator.alloc(compile_func.FuncResult, defined_func_typeidx.len);
    errdefer allocator.free(results);
    var compiled: usize = 0;
    errdefer for (results[0..compiled]) |*r| compile_func.deinitFuncResult(allocator, r);
    for (codes.items, 0..) |code, i| {
        // Defined function K's wasm-space index = num_imports + K.
        const wasm_idx: u32 = num_imports + @as(u32, @intCast(i));
        const sig = func_sigs[wasm_idx];
        // 7.5-close-d042-impl: validate before compile. Surfaces
        // type-mismatch / unknown-local / unknown-global etc. as
        // ValidationFailed instead of silent miscompile or arbitrary
        // lower-side errors. The full validator-context split is
        // documented in `.dev/lessons/2026-05-07-validator-dead-
        // code-in-runtime.md`.
        // D-115 d-39: collect per-untyped-`select` resolved valtype
        // bytes so lower can populate `ZirInstr.extra` for the emit
        // dispatch (FCSEL / FpSelect vs gpr32 CSEL).
        var select_types: std.ArrayList(u8) = .empty;
        defer select_types.deinit(allocator);
        validator_mod.validateFunctionAndCollectSelectTypesWithMemory(
            allocator,
            sig,
            code.locals,
            code.body,
            func_sigs,
            validator_globals,
            types.items,
            validator_data_count,
            validator_tables,
            validator_elem_count,
            validator_memory_count,
            declared_funcs,
            elem_types_slice,
            data_count_section_present,
            &select_types,
        ) catch |err| {
            std.debug.print("compileWasm: func[{d}] params={d} results={d} → validate {s}\n", .{
                wasm_idx,
                sig.params.len,
                sig.results.len,
                @errorName(err),
            });
            return err;
        };
        results[i] = compile_func.compileOne(
            allocator,
            wasm_idx,
            sig,
            code.body,
            code.locals,
            types.items,
            func_sigs,
            num_imports,
            globals_offsets,
            globals_valtypes,
            select_types.items,
        ) catch |err| {
            std.debug.print("compileWasm: func[{d}] params={d} results={d} → {s}\n", .{
                wasm_idx,
                sig.params.len,
                sig.results.len,
                @errorName(err),
            });
            return err;
        };
        compiled += 1;
    }

    // Link into one JitModule. The linker reserves the first
    // `num_imports` slots in `func_offsets` for import sentinels;
    // import calls never produce a CallFixup (the emit pass routes
    // them to the function-local trap stub directly), so the
    // sentinel slots are never read.
    const bodies = try allocator.alloc(linker.FuncBody, results.len);
    defer allocator.free(bodies);
    for (results, 0..) |r, i| {
        bodies[i] = .{ .bytes = r.out.bytes, .call_fixups = r.out.call_fixups };
    }
    const linked = try linker.link(allocator, bodies, num_imports);

    return .{
        .module = linked,
        .func_results = results,
        .func_sigs = func_sigs,
        .func_typeidxs = func_typeidxs,
        .num_imports = num_imports,
        .globals_offsets = globals_offsets,
        .globals_valtypes = globals_valtypes,
        .globals_byte_size = globals_byte_size,
        .arena = arena,
    };
}

/// ADR-0052 — write each defined global's init-expression value
/// into `globals_buf` at the per-global byte offset (i.e. the
/// same offset the JIT-emitted `global.get/set` ops bake in).
/// Scalar globals (i32/i64/f32/f64/refs) write 8 bytes;
/// v128 globals write 16 bytes. Mirrors `applyActiveDataSegments`
/// for spec-test runners that build their JitRuntime around a
/// caller-owned globals byte buffer instead of going through the
/// full `setupRuntime` allocation path.
///
/// The caller's buffer MUST be at least `compiled.globals_byte_size`
/// bytes; v128 access requires 16-byte alignment per the
/// MOVUPS/LDR-Q layout. Buffers smaller than required are rejected
/// with `Error.UnsupportedEntrySignature`.
pub fn applyDefinedGlobalsInit(
    allocator: Allocator,
    wasm_bytes: []const u8,
    globals_offsets: []const u32,
    globals_valtypes: []const zir.ValType,
    globals_buf: []u8,
) Error!void {
    if (globals_offsets.len == 0) return;
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);
    const section = module.find(.global) orelse return;
    var globals_decoded = try sections.decodeGlobals(ta, section.body);
    defer globals_decoded.deinit();
    if (globals_decoded.items.len != globals_offsets.len) return Error.UnsupportedEntrySignature;

    for (globals_decoded.items, 0..) |gd, gi| {
        const off = globals_offsets[gi];
        const vt = globals_valtypes[gi];
        switch (vt) {
            .v128 => {
                if (off + 16 > globals_buf.len) return Error.UnsupportedEntrySignature;
                const bytes = try rv.evalConstV128Expr(gd.init_expr);
                @memcpy(globals_buf[off..][0..16], &bytes);
            },
            .i32, .i64, .f32, .f64, .funcref, .externref => {
                if (off + 8 > globals_buf.len) return Error.UnsupportedEntrySignature;
                const raw = try rv.evalConstScalarRaw(gd.init_expr);
                std.mem.writeInt(u64, globals_buf[off..][0..8], raw, .little);
            },
        }
    }
}

/// D-063 discharge (§9.9 / 9.9-h-4) — walk the module's active
/// element segments and populate caller-owned `funcptrs_buf` +
/// `typeidxs_buf` with table entries that match the c_api
/// `setupRuntime` shape. Without this, the JIT-emitted
/// `call_indirect` bounds-check (`CMP W17, W25 (=table_size)`)
/// and sig-check (`LDR W16, [X24 (=typeidx_base), X17, LSL #2]`)
/// see uninitialised state and trap on every call.
///
/// Caller passes `funcptrs_buf.len == typeidxs_buf.len ==
/// max_table_entries` (i.e. the runner's fixed-size scratch);
/// segments writing past that bound surface
/// `UnsupportedEntrySignature`. `typeidxs_buf` is pre-seeded to
/// `maxInt(u32)` (the "no func here" sentinel — the JIT
/// sig-check's CMP-against-typeidx never matches, traps cleanly
/// rather than dereferencing NULL).
pub fn applyTableInit(
    allocator: Allocator,
    wasm_bytes: []const u8,
    compiled: *const CompiledWasm,
    funcptrs_buf: []u64,
    typeidxs_buf: []u32,
) Error!void {
    return applyTableInitForTable(allocator, wasm_bytes, compiled, 0, funcptrs_buf, typeidxs_buf);
}

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): per-table variant of
/// `applyTableInit`. `tableidx` selects which declared table's
/// active element segments are applied; segments targeting any
/// other table are skipped. Used by spec_assert harness's
/// `setupMultiTableScratch` to populate per-table
/// funcptr/typeidx scratch arrays for non-zero tables.
pub fn applyTableInitForTable(
    allocator: Allocator,
    wasm_bytes: []const u8,
    compiled: *const CompiledWasm,
    tableidx: u32,
    funcptrs_buf: []u64,
    typeidxs_buf: []u32,
) Error!void {
    if (funcptrs_buf.len != typeidxs_buf.len) return Error.UnsupportedEntrySignature;
    @memset(funcptrs_buf, 0);
    @memset(typeidxs_buf, std.math.maxInt(u32));

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);
    const section = module.find(.element) orelse return;
    var elems = try sections.decodeElement(ta, section.body);
    defer elems.deinit();

    // D-111: canonicalize the funcref's stored typeidx so the
    // call_indirect runtime sig check (`CMP EAX, #canonical`)
    // matches structurally-equivalent types declared at different
    // typeidx (Wasm spec §3.4.6 + §4.4.10.1). The codegen side
    // canonicalizes the call_indirect's annotated typeidx
    // identically; both sides see the lowest-index typeidx for a
    // given shape, so the bytewise compare implements structural
    // matching. Module types are decoded once (re-parsed from the
    // wasm bytes — the temp arena scope keeps the slice alive
    // through the loop).
    const types_section = module.find(.type) orelse {
        // No types section ⇒ no funcs ⇒ no element-segment funcidxs
        // to write. Spec-malformed modules with elems but no types
        // would fail earlier in compileWasm.
        return;
    };
    var types = try sections.decodeTypes(ta, types_section.body);
    defer types.deinit();

    for (elems.items) |seg| {
        if (seg.kind != .active) continue;
        if (seg.tableidx != tableidx) continue;
        const off = rv.evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
        if (off < 0) return Error.UnsupportedEntrySignature;
        const base: usize = @intCast(off);
        if (base + seg.funcidxs.len > funcptrs_buf.len) return Error.UnsupportedEntrySignature;
        for (seg.funcidxs, 0..) |fidx, i| {
            if (fidx == std.math.maxInt(u32)) continue; // ref.null funcref
            if (fidx >= compiled.func_sigs.len) return Error.UnsupportedEntrySignature;
            const f_off = compiled.module.func_offsets[fidx];
            const raw_typeidx = compiled.func_typeidxs[fidx];
            typeidxs_buf[base + i] = canonical_type.canonicalTypeidx(types.items, raw_typeidx);
            if (f_off == linker.IMPORT_SENTINEL_OFFSET) continue;
            funcptrs_buf[base + i] = @intFromPtr(compiled.module.block.bytes.ptr + f_off);
        }
    }
}

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): count the number of
/// declared tables in `wasm_bytes`. Used by spec_assert harness
/// to decide whether multi-table scratch needs to be wired.
/// Returns 0 when the module has no table section.
pub fn countDeclaredTables(allocator: Allocator, wasm_bytes: []const u8) u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = parser.parse(ta, wasm_bytes) catch return 0;
    const section = module.find(.table) orelse return 0;
    var tables = sections.decodeTables(ta, section.body) catch return 0;
    defer tables.deinit();
    return @intCast(tables.items.len);
}

/// §9.9 / 9.9-l-1b-d093-d42b (D-112): per-table size lookup
/// (table `tableidx`'s declared `min`). Returns 0 when the
/// module has no table section OR `tableidx` is out of range.
pub fn declaredTableMin(allocator: Allocator, wasm_bytes: []const u8, tableidx: u32) u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = parser.parse(ta, wasm_bytes) catch return 0;
    const section = module.find(.table) orelse return 0;
    var tables = sections.decodeTables(ta, section.body) catch return 0;
    defer tables.deinit();
    if (tableidx >= tables.items.len) return 0;
    return tables.items[tableidx].min;
}

/// §9.9 / 9.9-l-1b-d093-d48 (D-122/D-125): per-table declared
/// `max` lookup. Returns `null` when the table has no max OR the
/// module has no table section OR `tableidx` is out of range.
/// Consumed by spec_assert harness to populate `TableSlice.max`
/// so JIT `table.grow`'s callout can enforce the cap (Wasm 2.0
/// §4.4.10.1 host-refuses-growth semantics).
pub fn declaredTableMax(allocator: Allocator, wasm_bytes: []const u8, tableidx: u32) ?u32 {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = parser.parse(ta, wasm_bytes) catch return null;
    const section = module.find(.table) orelse return null;
    var tables = sections.decodeTables(ta, section.body) catch return null;
    defer tables.deinit();
    if (tableidx >= tables.items.len) return null;
    return tables.items[tableidx].max;
}

/// Apply active data segments from `wasm_bytes` into `memory`
/// (a caller-owned buffer, e.g. a fixed-size scratch arena).
/// Mirrors the data-init half of `setupRuntime` so spec-test
/// runners can reuse a stable scratch_memory across modules
/// without paying the full setupRuntime allocation cost. §9.9 /
/// 9.9-d-7: simd_assert_runner relies on this so its
/// `scratch_memory` reflects each fixture's data-segment bytes
/// before assert_return calls fire.
///
/// Returns `Error.UnsupportedEntrySignature` if a segment's
/// offset is negative, the offset+bytes exceeds `memory.len`,
/// or the offset_expr is not a `i32.const` literal. Passive /
/// declarative segments are skipped (only `active` is honoured).
pub fn applyActiveDataSegments(
    allocator: Allocator,
    wasm_bytes: []const u8,
    memory: []u8,
) Error!void {
    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);
    if (module.find(.data)) |s| {
        var datas = try sections.decodeData(ta, s.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            const off = rv.evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const off_u: u64 = @intCast(off);
            if (off_u + seg.bytes.len > memory.len) return Error.UnsupportedEntrySignature;
            @memcpy(memory[@intCast(off_u)..][0..seg.bytes.len], seg.bytes);
        }
    }
}

/// Find an exported function by name. Returns its func_idx in
/// the module's function index space (imports + defined).
pub fn findExportFunc(allocator: Allocator, wasm_bytes: []const u8, name: []const u8) Error!u32 {
    var module = try parser.parse(allocator, wasm_bytes);
    defer module.deinit(allocator);

    const export_section = module.find(.@"export") orelse return Error.ExportNotFound;
    var exports = try sections.decodeExports(allocator, export_section.body);
    defer exports.deinit();

    for (exports.items) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (e.kind != .func) return Error.ExportIsNotFunction;
        return e.idx;
    }
    return Error.ExportNotFound;
}

/// Run a no-arg, i32-result exported function and return the
/// result value. Wraps `setupRuntime` + `entry.callI32NoArgs`.
pub fn runI32Export(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
) Error!u32 {
    const func_idx = try findExportFunc(allocator, wasm_bytes, export_name);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    if (func_idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    if (func_idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[func_idx];
    if (sig.params.len != 0 or sig.results.len != 1 or sig.results[0] != .i32) {
        return Error.UnsupportedEntrySignature;
    }

    var owned = try setupRuntime(allocator, &compiled, wasm_bytes);
    defer owned.deinit(allocator);
    return entry.callI32NoArgs(compiled.module, func_idx, &owned.rt);
}

/// Run a no-arg, void-result exported function (e.g. `_start`)
/// and surface trap as Error.Trap. Mirrors `runI32Export`'s
/// setup; differs only in the entry-call helper + signature
/// gate.
/// Compile + invoke a void-returning export. Returns the
/// post-call value of `JitRuntime.jit_executed_flag` (per
/// §9.8a / 8a.2 ADR-0034 sentinel) so callers can distinguish
/// "JIT body actually executed" (`flag != 0`) from "compile-
/// passed but never invoked" (`flag == 0`). On Mac aarch64
/// hosts the ARM64 prologue inject sets the flag; x86_64
/// hosts always return 0 until D-055 lands the x86_64 wire-up.
pub fn runVoidExport(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
) Error!u32 {
    const func_idx = try findExportFunc(allocator, wasm_bytes, export_name);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    if (func_idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    if (func_idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[func_idx];
    if (sig.params.len != 0 or sig.results.len != 0) {
        return Error.UnsupportedEntrySignature;
    }

    var owned = try setupRuntime(allocator, &compiled, wasm_bytes);
    defer owned.deinit(allocator);
    try entry.callVoidNoArgs(compiled.module, func_idx, &owned.rt);
    return owned.rt.jit_executed_flag;
}

/// Allocations bundled with the JitRuntime they back. Returned
/// from `setupRuntime`; caller defers `.deinit(allocator)`.
const RuntimeOwned = struct {
    rt: entry.JitRuntime,
    memory: []u8,
    dispatch: []usize,
    globals: []@import("../runtime/value.zig").Value,
    funcptrs: []u64,
    typeidxs: []u32,
    // §9.9 / 9.9-m-1b: per-module FuncEntity array backing JIT
    // `ref.func`. JIT computes `&func_entities[idx]` for each
    // ref.func op; only the address matters for ref.is_null /
    // ref.eq / select_typed [funcref] semantics. Struct contents
    // (FuncEntity.runtime, .func_idx) are not exercised on this
    // code path (no full Runtime; interp uses its own allocation).
    func_entities: []@import("../runtime/instance/func.zig").FuncEntity,
    // §9.9 / 9.9-m-3a: parallel data/elem segment "dropped"
    // flag arrays. bool stored as u8 (matches extern struct
    // layout the JIT expects).
    data_dropped: []u8,
    elem_dropped: []u8,
    // §9.9 / 9.9-m-3b: per-data-segment SegmentSlice descriptors
    // backing JIT `memory.init`. Each entry's `ptr` aliases the
    // module's parsed `.data` section bytes (held by the caller
    // via `wasm_bytes`); the lifetime contract is that
    // `wasm_bytes` outlives `RuntimeOwned` (callers pass module
    // bytes that persist across the call).
    data_segments: []entry.SegmentSlice,
    // §9.9 / 9.9-m-2a: per-table descriptors + contiguous refs
    // arena backing JIT `table.get` / `table.set` / `table.size`.
    // `tables_descriptors[k].refs` points into `table_refs`; the
    // two slices have matching lifetimes (both freed at deinit).
    tables_descriptors: []entry.TableSlice,
    table_refs: []u64,
    // §9.9 / 9.9-m-2c-init: per-element-segment ElemSlice descriptors
    // + contiguous u64 arena holding the pre-computed funcref values.
    elem_segments: []entry.ElemSlice,
    elem_refs: []u64,
    // §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
    // dispatch descriptors + extra (non-table-0) funcptr/typeidx
    // arena. Table 0's TableJitCallInfo entry reuses `funcptrs` /
    // `typeidxs` above; tables 1..N point into the contiguous
    // `extra_funcptrs` / `extra_typeidxs` arenas via per-table
    // offsets computed at setup time.
    tables_jit_ci: []entry.TableJitCallInfo,
    extra_funcptrs: []u64,
    extra_typeidxs: []u32,

    fn deinit(self: *RuntimeOwned, allocator: Allocator) void {
        if (self.memory.len > 0) allocator.free(self.memory);
        allocator.free(self.dispatch);
        allocator.free(self.globals);
        allocator.free(self.funcptrs);
        allocator.free(self.typeidxs);
        if (self.func_entities.len > 0) allocator.free(self.func_entities);
        if (self.data_dropped.len > 0) allocator.free(self.data_dropped);
        if (self.elem_dropped.len > 0) allocator.free(self.elem_dropped);
        if (self.data_segments.len > 0) allocator.free(self.data_segments);
        allocator.free(self.tables_descriptors);
        allocator.free(self.table_refs);
        if (self.elem_segments.len > 0) allocator.free(self.elem_segments);
        if (self.elem_refs.len > 0) allocator.free(self.elem_refs);
        allocator.free(self.tables_jit_ci);
        if (self.extra_funcptrs.len > 0) allocator.free(self.extra_funcptrs);
        if (self.extra_typeidxs.len > 0) allocator.free(self.extra_typeidxs);
    }
};

/// Build a JitRuntime + populate its host_dispatch table + init
/// linear memory from data segments. Shared between `runI32Export`
/// and `runVoidExport`. The caller owns the returned `memory` and
/// `dispatch` slices via `RuntimeOwned.deinit`.
fn setupRuntime(
    allocator: Allocator,
    compiled: *const CompiledWasm,
    wasm_bytes: []const u8,
) Error!RuntimeOwned {
    const dispatch = try allocator.alloc(usize, compiled.num_imports);
    errdefer allocator.free(dispatch);
    for (dispatch) |*slot| slot.* = @intFromPtr(&hostDispatchTrap);

    var memory: []u8 = &.{};
    errdefer if (memory.len > 0) allocator.free(memory);

    var temp_arena = std.heap.ArenaAllocator.init(allocator);
    defer temp_arena.deinit();
    const ta = temp_arena.allocator();
    var module = try parser.parse(ta, wasm_bytes);

    if (module.find(.import)) |s| {
        if (compiled.num_imports > 0) {
            var imports_buf = try sections.decodeImports(ta, s.body);
            defer imports_buf.deinit();
            jit_dispatch.populateDispatch(dispatch, imports_buf.items);
        }
    }

    if (module.find(.memory)) |s| {
        var memories = try sections.decodeMemory(ta, s.body);
        defer memories.deinit();
        if (memories.items.len > 0) {
            const page_size: u64 = 65536;
            const min_pages: u64 = memories.items[0].min;
            const total_bytes: u64 = min_pages * page_size;
            if (total_bytes > 256 * 1024 * 1024) {
                return Error.UnsupportedEntrySignature;
            }
            memory = try allocator.alloc(u8, @intCast(total_bytes));
            @memset(memory, 0);
        }
    }

    if (module.find(.data)) |s| {
        var datas = try sections.decodeData(ta, s.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            const off = rv.evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const off_u: u64 = @intCast(off);
            if (off_u + seg.bytes.len > memory.len) {
                return Error.UnsupportedEntrySignature;
            }
            @memcpy(memory[@intCast(off_u)..][0..seg.bytes.len], seg.bytes);
        }
    }

    // Decode globals + tables for placeholder arrays. Realistic
    // values are needed because fixtures' JIT bodies reach for
    // global.get / call_indirect bodies that reference these
    // offsets even when the bounds check would short-circuit
    // — `globals_base = undefined` previously caused 0xaaaa...
    // segfaults in the realworld corpus invocation path.
    var globals_count: u32 = 0;
    if (module.find(.global)) |s| {
        var globals_buf = try sections.decodeGlobals(ta, s.body);
        defer globals_buf.deinit();
        globals_count = @intCast(globals_buf.items.len);
    }
    // §9.9 / 9.9-m-2a: parse the table section into per-table
    // descriptors. `table_size` is retained as the table-0 entry
    // count (call_indirect's `funcptrs_buf` + `typeidxs_buf` are
    // table-0-only specialisations); the new `tables_descs` array
    // generalises this to all declared tables for `table.get` /
    // `table.set` / `table.size` (m-2a) and later m-2b/c ops.
    var table_size: u32 = 0;
    const TableMeta = struct { min: u32, max: ?u32 };
    var table_metas: []TableMeta = &.{};
    if (module.find(.table)) |s| {
        var tables_buf = try sections.decodeTables(ta, s.body);
        defer tables_buf.deinit();
        if (tables_buf.items.len > 0) {
            table_size = tables_buf.items[0].min;
            table_metas = try ta.alloc(TableMeta, tables_buf.items.len);
            for (tables_buf.items, 0..) |t, i| {
                table_metas[i] = .{ .min = t.min, .max = t.max };
            }
        }
    }
    // Cap to keep allocator pressure bounded; fixtures with large
    // declared globals / tables surface as UnsupportedEntrySignature.
    if (globals_count > 4096) return Error.UnsupportedEntrySignature;
    if (table_size > 4096) return Error.UnsupportedEntrySignature;

    const Value = @import("../runtime/value.zig").Value;
    const globals_buf = try allocator.alloc(Value, if (globals_count == 0) 1 else globals_count);
    errdefer allocator.free(globals_buf);
    @memset(globals_buf, .{ .bits64 = 0 });

    const funcptrs_buf = try allocator.alloc(u64, if (table_size == 0) 1 else table_size);
    errdefer allocator.free(funcptrs_buf);
    @memset(funcptrs_buf, 0);
    const typeidxs_buf = try allocator.alloc(u32, if (table_size == 0) 1 else table_size);
    errdefer allocator.free(typeidxs_buf);
    // Sentinel `maxInt(u32)` for "no function in this slot" — the
    // JIT-emitted call_indirect type-check `cmp w16, #expected`
    // never matches this, so an unset slot traps cleanly via the
    // bounds_fixups path instead of through a NULL `blr`.
    @memset(typeidxs_buf, std.math.maxInt(u32));

    // §9.9 / 9.9-m-2a (per ADR-0058): generalised per-table storage.
    // Each declared table gets a `TableSlice` descriptor with `refs`
    // pointing into a single contiguous `table_refs` arena. Each
    // entry is `Value.ref`-encoded u64 (FuncEntity pointer for
    // funcref, host handle for externref, or `null_ref` sentinel).
    // Initialised to `null_ref`; the element-section loop below
    // mirrors writes from `funcptrs_buf` into the corresponding
    // `table_refs` slot (using the FuncEntity-ptr encoding, NOT
    // the native-code-ptr encoding used by `funcptrs_buf`).
    var total_table_refs: usize = 0;
    for (table_metas) |tm| total_table_refs += tm.min;
    const tables_descs = try allocator.alloc(entry.TableSlice, if (table_metas.len == 0) 1 else table_metas.len);
    errdefer allocator.free(tables_descs);
    const table_refs = try allocator.alloc(u64, if (total_table_refs == 0) 1 else total_table_refs);
    errdefer allocator.free(table_refs);
    @memset(table_refs, Value.null_ref);
    {
        var ref_offset: usize = 0;
        for (table_metas, 0..) |tm, i| {
            tables_descs[i] = .{
                .refs = table_refs.ptr + ref_offset,
                .len = tm.min,
                .max = tm.max orelse entry.table_no_max,
            };
            ref_offset += tm.min;
        }
        // For modules without a declared table section, leave the
        // single placeholder descriptor pointing at the sentinel
        // refs slot. table.get with tableidx=0 against such a
        // module would already have been rejected by the validator
        // (no table declared → InvalidFuncIndex).
        if (table_metas.len == 0) {
            tables_descs[0] = .{ .refs = table_refs.ptr, .len = 0, .max = entry.table_no_max };
        }
    }

    // §9.9 / 9.9-l-1b-d093-d42 (D-112): per-table call_indirect
    // dispatch descriptors. Table 0 reuses `funcptrs_buf` /
    // `typeidxs_buf` so the legacy JitRuntime scalar fields stay
    // backed by identical memory. Tables 1..N get their funcptr /
    // typeidx storage from a contiguous `extra_funcptrs` /
    // `extra_typeidxs` arena, sized by the sum of those tables'
    // declared `min` entry counts. The descriptor array indexes
    // by table_idx (Wasm spec §3.4.6 call_indirect tableidx byte).
    var extra_total_slots: usize = 0;
    if (table_metas.len > 1) {
        for (table_metas[1..]) |tm| extra_total_slots += tm.min;
    }
    const tables_jit_ci_buf = try allocator.alloc(entry.TableJitCallInfo, if (table_metas.len == 0) 1 else table_metas.len);
    errdefer allocator.free(tables_jit_ci_buf);
    const extra_funcptrs_buf = try allocator.alloc(u64, if (extra_total_slots == 0) 1 else extra_total_slots);
    errdefer allocator.free(extra_funcptrs_buf);
    @memset(extra_funcptrs_buf, 0);
    const extra_typeidxs_buf = try allocator.alloc(u32, if (extra_total_slots == 0) 1 else extra_total_slots);
    errdefer allocator.free(extra_typeidxs_buf);
    @memset(extra_typeidxs_buf, std.math.maxInt(u32));
    {
        tables_jit_ci_buf[0] = .{ .funcptr_base = funcptrs_buf.ptr, .typeidx_base = typeidxs_buf.ptr };
        if (table_metas.len > 1) {
            var off: usize = 0;
            for (table_metas[1..], 1..) |tm, k| {
                tables_jit_ci_buf[k] = .{
                    .funcptr_base = extra_funcptrs_buf.ptr + off,
                    .typeidx_base = extra_typeidxs_buf.ptr + off,
                };
                off += tm.min;
            }
        }
    }
    // Per-table starting offsets into the extra arenas. Indexed
    // by table_idx (entry 0 unused; entries 1+ are the slot at
    // which that table's funcptr/typeidx slice starts within
    // extra_funcptrs/extra_typeidxs). The 16-table cap above
    // makes this a fixed-size stack array; modules exceeding the
    // cap surface as UnsupportedEntrySignature.
    if (table_metas.len > 16) return Error.UnsupportedEntrySignature;
    var extra_offs: [16]usize = [_]usize{0} ** 16;
    if (table_metas.len > 1) {
        var off: usize = 0;
        for (table_metas[1..], 1..) |tm, k| {
            extra_offs[k] = off;
            off += tm.min;
        }
    }

    // §9.9 / 9.9-m-1b: per-module FuncEntity array for JIT
    // ref.func. Size = total functions (imports + defined).
    // Allocated unconditionally so JIT-emitted ref.func reads
    // a stable, distinct address per funcidx. Moved above the
    // element-section loop (§9.9 / 9.9-m-2a) so the loop can
    // populate `table_refs` with FuncEntity-ptr encoding in
    // the same pass that populates `funcptrs_buf` with the
    // native-code-ptr encoding.
    const FuncEntity = @import("../runtime/instance/func.zig").FuncEntity;
    const total_funcs = compiled.func_sigs.len;
    const func_entities = try allocator.alloc(FuncEntity, total_funcs);
    errdefer allocator.free(func_entities);
    for (func_entities, 0..) |*fe, i| {
        fe.* = .{ .runtime = undefined, .func_idx = @intCast(i) };
    }

    // Wasm spec §4.5.7 (table.init / element-segment instantiation)
    // — populate the table with funcref entries from the element
    // section. Without this, `call_indirect` loads a NULL funcptr
    // and SEGVs at PC=0 (D-049 root cause). Active segments only;
    // passive / declarative segments live in the runtime element
    // index space, not the table itself, and reach the runtime via
    // `table.init` ops which v0.1.0's JIT path doesn't emit yet.
    //
    // §9.9 / 9.9-m-2a: the same loop populates `tables_descs[k].refs`
    // (`table_refs` arena slice) with `Value.fromFuncRef` encoding
    // (`@intFromPtr(&func_entities[fidx])`) for JIT `table.get`.
    // `funcptrs_buf` keeps the native-code-ptr encoding for
    // `call_indirect`'s fast path; the two views are coherent at
    // setup time but diverge if `table.set` runs post-instantiation
    // (a known follow-up tracked as part of the m-2 cluster).
    if (module.find(.element)) |s| {
        var elems = try sections.decodeElement(ta, s.body);
        defer elems.deinit();
        // D-111: canonicalize typeidx so call_indirect's structural
        // FuncType match (Wasm spec §3.4.6 + §4.4.10.1) works on
        // the bytewise typeidx compare. Decode the type section
        // once for the loop.
        const canon_types_section = module.find(.type);
        var canon_types: ?sections.Types = null;
        defer if (canon_types) |*t| t.deinit();
        if (canon_types_section) |ts| {
            canon_types = try sections.decodeTypes(ta, ts.body);
        }
        for (elems.items) |seg| {
            if (seg.kind != .active) continue;
            if (seg.tableidx >= tables_descs.len) continue;
            const off = rv.evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const base: usize = @intCast(off);
            const tbl = tables_descs[seg.tableidx];
            if (base + seg.funcidxs.len > tbl.len) return Error.UnsupportedEntrySignature;
            // §9.9 / 9.9-l-1b-d093-d42: per-table funcptr/typeidx
            // slice. Table 0 writes into the legacy flat
            // `funcptrs_buf` / `typeidxs_buf` (which back the
            // JitRuntime scalar `funcptr_base` / `typeidx_base`
            // fields); tables 1+ write into their slice within the
            // `extra_funcptrs` / `extra_typeidxs` arenas. The JIT
            // emit (arm64/x86_64 op_call.emitCallIndirect) selects
            // the right slice via `tables_jit_ci_ptr[table_idx]`.
            const is_table0 = (seg.tableidx == 0);
            const tbl_funcptrs: []u64 = if (is_table0)
                funcptrs_buf
            else
                extra_funcptrs_buf[extra_offs[seg.tableidx] .. extra_offs[seg.tableidx] + table_metas[seg.tableidx].min];
            const tbl_typeidxs: []u32 = if (is_table0)
                typeidxs_buf
            else
                extra_typeidxs_buf[extra_offs[seg.tableidx] .. extra_offs[seg.tableidx] + table_metas[seg.tableidx].min];
            if (base + seg.funcidxs.len > tbl_funcptrs.len) return Error.UnsupportedEntrySignature;
            for (seg.funcidxs, 0..) |fidx, i| {
                if (fidx == std.math.maxInt(u32)) {
                    // ref.null funcref — leave the slot null + sentinel typeidx.
                    tbl.refs[base + i] = Value.null_ref;
                    continue;
                }
                if (fidx >= compiled.func_sigs.len) return Error.UnsupportedEntrySignature;
                tbl.refs[base + i] = @intFromPtr(&func_entities[fidx]);
                const f_off = compiled.module.func_offsets[fidx];
                const raw_typeidx = compiled.func_typeidxs[fidx];
                tbl_typeidxs[base + i] = if (canon_types) |t|
                    canonical_type.canonicalTypeidx(t.items, raw_typeidx)
                else
                    raw_typeidx;
                if (f_off == linker.IMPORT_SENTINEL_OFFSET) {
                    // Imported function in a table — host-call dispatch
                    // through `host_dispatch_base` is required to invoke
                    // it. v0.1.0's JIT call_indirect path doesn't emit
                    // that trampoline; leave funcptr null so an attempt
                    // to call it traps via NULL deref instead of running
                    // arbitrary host code.
                    continue;
                }
                tbl_funcptrs[base + i] = @intFromPtr(compiled.module.block.bytes.ptr + f_off);
            }
        }
    }

    // §9.9 / 9.9-m-3a: data / elem segment dropped-flag arrays.
    // Each is a bool[] sized to the module's segment count;
    // initialised to false (segment not yet dropped). JIT data.drop
    // / elem.drop write byte stores; JIT memory.init (m-3b) reads
    // before computing seg_len. For modules without segments, the
    // arrays are zero-length (no allocation, ptr = undefined).
    // §9.9 / 9.9-m-3b: parallel data_segments descriptor array.
    // Each entry's `ptr` aliases the parsed module's `.data`
    // section bytes via the resident `wasm_bytes` slice — the
    // segment's `bytes` field already points into that buffer
    // (no copy). `len` is the segment's byte count; the JIT
    // overrides to 0 via the `data_dropped_ptr` flag.
    var data_dropped_count: u32 = 0;
    var data_segments_buf: []entry.SegmentSlice = &.{};
    errdefer if (data_segments_buf.len > 0) allocator.free(data_segments_buf);
    if (module.find(.data)) |s| {
        var datas_buf = try sections.decodeData(ta, s.body);
        defer datas_buf.deinit();
        data_dropped_count = @intCast(datas_buf.items.len);
        if (data_dropped_count > 0) {
            data_segments_buf = try allocator.alloc(entry.SegmentSlice, data_dropped_count);
            for (datas_buf.items, 0..) |seg, i| {
                data_segments_buf[i] = .{
                    .ptr = if (seg.bytes.len == 0) @as([*]const u8, undefined) else seg.bytes.ptr,
                    .len = seg.bytes.len,
                };
            }
        }
    }
    const data_dropped = try allocator.alloc(u8, data_dropped_count);
    errdefer allocator.free(data_dropped);
    @memset(data_dropped, 0);
    // Wasm 2.0 §4.5.5: active data segments are consumed at
    // instantiation — applyActiveDataSegments has already copied
    // their bytes into linear memory; subsequent `memory.init`
    // against them must trap on n>0 because the segment's
    // effective size is 0. Mirror of d-49's elem-segment fix.
    if (module.find(.data)) |s_drop| {
        var datas_drop = try sections.decodeData(ta, s_drop.body);
        defer datas_drop.deinit();
        for (datas_drop.items, 0..) |seg, i| {
            if (seg.kind == .active) data_dropped[i] = 1;
        }
    }

    // §9.9 / 9.9-m-2c-init: per-element-segment ElemSlice arena.
    // Each segment gets its own pre-computed `[]u64` of Value.ref
    // values (FuncEntity ptr encoding for funcref; Value.null_ref
    // for null entries). The ElemSlice descriptors point into a
    // single contiguous arena sized to the sum of all
    // seg.funcidxs.len. JIT `table.init` indexes the descriptors
    // with stride 16, reads `refs[src..src+n]`, and writes into
    // the target table's u64[] storage.
    var elem_dropped_count: u32 = 0;
    var elem_segments_buf: []entry.ElemSlice = &.{};
    errdefer if (elem_segments_buf.len > 0) allocator.free(elem_segments_buf);
    var elem_refs_arena: []u64 = &.{};
    errdefer if (elem_refs_arena.len > 0) allocator.free(elem_refs_arena);
    if (module.find(.element)) |s| {
        var elems_buf = try sections.decodeElement(ta, s.body);
        defer elems_buf.deinit();
        elem_dropped_count = @intCast(elems_buf.items.len);
        if (elem_dropped_count > 0) {
            var total_refs: usize = 0;
            for (elems_buf.items) |seg| total_refs += seg.funcidxs.len;
            elem_segments_buf = try allocator.alloc(entry.ElemSlice, elem_dropped_count);
            elem_refs_arena = try allocator.alloc(u64, if (total_refs == 0) 1 else total_refs);
            var off: usize = 0;
            for (elems_buf.items, 0..) |seg, i| {
                const seg_len: u32 = @intCast(seg.funcidxs.len);
                elem_segments_buf[i] = .{
                    .refs = elem_refs_arena.ptr + off,
                    .len = seg_len,
                };
                for (seg.funcidxs, 0..) |fidx, k| {
                    if (fidx == std.math.maxInt(u32)) {
                        elem_refs_arena[off + k] = Value.null_ref;
                    } else if (fidx >= compiled.func_sigs.len) {
                        return Error.UnsupportedEntrySignature;
                    } else {
                        elem_refs_arena[off + k] = @intFromPtr(&func_entities[fidx]);
                    }
                }
                off += seg_len;
            }
        }
    }
    const elem_dropped = try allocator.alloc(u8, elem_dropped_count);
    errdefer allocator.free(elem_dropped);
    @memset(elem_dropped, 0);
    // Wasm 2.0 §4.5.4: active + declarative elem segments are
    // consumed at instantiation — their effective size becomes 0
    // for any subsequent `table.init`. Re-walk the section to
    // mark them dropped. Passive segments stay live until an
    // explicit `elem.drop`.
    if (module.find(.element)) |s_drop| {
        var elems_drop = try sections.decodeElement(ta, s_drop.body);
        defer elems_drop.deinit();
        for (elems_drop.items, 0..) |seg, i| {
            if (seg.kind != .passive) elem_dropped[i] = 1;
        }
    }

    return .{
        .rt = .{
            .vm_base = if (memory.len > 0) memory.ptr else @ptrFromInt(@as(usize, 0x1000)),
            .mem_limit = memory.len,
            .funcptr_base = funcptrs_buf.ptr,
            .table_size = table_size,
            .typeidx_base = typeidxs_buf.ptr,
            .trap_flag = 0,
            .globals_base = globals_buf.ptr,
            .globals_count = globals_count,
            .host_dispatch_base = dispatch.ptr,
            .host_dispatch_count = compiled.num_imports,
            .func_entities_ptr = @ptrCast(func_entities.ptr),
            .func_entities_count = @intCast(total_funcs),
            .data_dropped_ptr = data_dropped.ptr,
            .data_dropped_count = data_dropped_count,
            .elem_dropped_ptr = elem_dropped.ptr,
            .elem_dropped_count = elem_dropped_count,
            .data_segments_ptr = if (data_segments_buf.len == 0) @as([*]const entry.SegmentSlice, undefined) else data_segments_buf.ptr,
            .data_segments_count = @intCast(data_segments_buf.len),
            .tables_ptr = tables_descs.ptr,
            .tables_count = @intCast(table_metas.len),
            .elem_segments_ptr = if (elem_segments_buf.len == 0) @as([*]const entry.ElemSlice, undefined) else elem_segments_buf.ptr,
            .elem_segments_count = @intCast(elem_segments_buf.len),
            .tables_jit_ci_ptr = tables_jit_ci_buf.ptr,
            .tables_jit_ci_count = @intCast(tables_jit_ci_buf.len),
        },
        .memory = memory,
        .dispatch = dispatch,
        .globals = globals_buf,
        .funcptrs = funcptrs_buf,
        .typeidxs = typeidxs_buf,
        .func_entities = func_entities,
        .data_dropped = data_dropped,
        .elem_dropped = elem_dropped,
        .data_segments = data_segments_buf,
        .tables_descriptors = tables_descs,
        .table_refs = table_refs,
        .elem_segments = elem_segments_buf,
        .elem_refs = elem_refs_arena,
        .tables_jit_ci = tables_jit_ci_buf,
        .extra_funcptrs = extra_funcptrs_buf,
        .extra_typeidxs = extra_typeidxs_buf,
    };
}

/// Default host-import trap trampoline (chunk 7.9-d). C-ABI
/// function pointer planted into every `host_dispatch_base[i]`
/// slot when no real WASI handler has been installed. Sets
/// `rt.trap_flag = 1` and returns 0 (sentinel). The entry shim's
/// post-return inspection of `rt.trap_flag` distinguishes this
/// trap from a real i32 return value of 0.
///
/// The trampoline takes the JitRuntime ptr as its first arg
/// (matching the JIT-side calling convention's
/// `entry_arg0 = runtime_ptr` reservation). Subsequent Wasm args
/// are passed in arg-regs 1..N but are ignored — the trampoline
/// has no per-import signature, only a fail-safe sink. This
/// works because the C ABI on both AAPCS64 and SysV / Win64
/// permits a callee to read fewer args than the caller passed
/// without faulting.
fn hostDispatchTrap(rt: *entry.JitRuntime) callconv(.c) u64 {
    rt.trap_flag = 1;
    return 0;
}

// ============================================================
// Tests
// ============================================================

const builtin = @import("builtin");
const testing = std.testing;

// File-loading harness lands at sub-7.5b-iii (needs std.Io
// plumbing). Today's tests use hand-inlined wasm bytes —
// generated by `xxd test/edge_cases/p7/.../<case>.wasm` on
// the fixtures committed in sub-3c.

test "runI32Export: trunc_sat_f32_s/pos_inf returns INT32_MAX" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // (module (func (export "test") (result i32) f32.const +inf
    //   i32.trunc_sat_f32_s)) — compiled via wat2wasm 1.0.39.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74,
        0x65, 0x73, 0x74, 0x00, 0x00, 0x0a, 0x0b, 0x01,
        0x09, 0x00, 0x43, 0x00, 0x00, 0x80, 0x7f, 0xfc,
        0x00, 0x0b,
    };
    const result = try runI32Export(testing.allocator, &bytes, "test");
    try testing.expectEqual(@as(u32, 2147483647), result);
}

test "runI32Export: trunc_sat_f32_s/nan returns 0" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // (module (func (export "test") (result i32) f32.const nan
    //   i32.trunc_sat_f32_s))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74,
        0x65, 0x73, 0x74, 0x00, 0x00, 0x0a, 0x0b, 0x01,
        0x09, 0x00, 0x43, 0x00, 0x00, 0xc0, 0x7f, 0xfc,
        0x00, 0x0b,
    };
    const result = try runI32Export(testing.allocator, &bytes, "test");
    try testing.expectEqual(@as(u32, 0), result);
}

test "runI32Export: trunc_sat_f32_s/neg_inf returns INT32_MIN (as u32 = 0x80000000)" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // (module (func (export "test") (result i32) f32.const -inf
    //   i32.trunc_sat_f32_s))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74,
        0x65, 0x73, 0x74, 0x00, 0x00, 0x0a, 0x0b, 0x01,
        0x09, 0x00, 0x43, 0x00, 0x00, 0x80, 0xff, 0xfc,
        0x00, 0x0b,
    };
    const result = try runI32Export(testing.allocator, &bytes, "test");
    try testing.expectEqual(@as(u32, 0x80000000), result);
}

test "runI32Export: trunc_f32_s/nan traps (sub-7.5b-ii trap_flag detection)" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // (module (func (export "test") (result i32) f32.const nan
    //   i32.trunc_f32_s)) — Wasm 1.0 trapping trunc; NaN → trap.
    // Same module shape as the sat variant, only the opcode
    // differs: 0xa8 (i32.trunc_f32_s) instead of 0xfc 0x00.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
        0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74,
        0x65, 0x73, 0x74, 0x00, 0x00, 0x0a, 0x0a, 0x01,
        0x08, 0x00, 0x43, 0x00, 0x00, 0xc0, 0x7f, 0xa8,
        0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "test"));
}

test "compileWasm: empty module (header only) compiles to empty CompiledWasm" {
    // §9.9 / 9.9-l-1b-d093-d69: ungated (was Mac-only) so the
    // testing.allocator (DebugAllocator) leak gate runs on all
    // hosts. D-135 documents 4 leak sites traced to compileWasm's
    // empty-fn-section path on OrbStack Linux x86_64 under the
    // runCorpus `.assert_invalid` arm; this Mac-host test passes,
    // so the leak class (if real) is either Linux x86_64-specific
    // or runCorpus-lifecycle-specific (not reproducible via a
    // single compileWasm + deinit cycle).
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var compiled = try compileWasm(testing.allocator, &bytes);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), compiled.func_sigs.len);
    try testing.expectEqual(@as(usize, 0), compiled.func_results.len);
}

test "compileWasm: empty function section (count=0) — binary.60.wasm shape (D-135 path)" {
    // §9.9 / 9.9-l-1b-d093-d69 (D-135 path discriminator): a
    // function section that is present-but-empty (body = single
    // LEB128 0x00 byte → count=0). This is the wasm shape D-127
    // (d-52) added explicit handling for. Per the empty-fn
    // early-return at runner.zig:138-194, this path converges
    // with the bare-header path into the `func_section_opt ==
    // null` branch — same allocations, same deinit. If this test
    // is leak-clean under testing.allocator on Mac aarch64, the
    // D-135 leak is NOT a structural deinit bug but something
    // specific to the runCorpus lifecycle (e.g. the
    // assert_invalid arm's `var c = compiled_ok; c.deinit(gpa)`
    // pattern) OR Linux x86_64-specific.
    //
    // Module bytes (binary.60.wasm exact): magic + version +
    // section 03 (function) of size 1 with body=[0x00] (count=0).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x03, 0x01, 0x00,
    };
    var compiled = try compileWasm(testing.allocator, &bytes);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), compiled.func_sigs.len);
    try testing.expectEqual(@as(usize, 0), compiled.func_results.len);
}

test "compileWasm: empty code section (count=0) — binary.61.wasm shape (D-135 path)" {
    // §9.9 / 9.9-l-1b-d093-d69 (D-135 path discriminator):
    // mirror of the binary.60 test but with the empty body in
    // the CODE section instead of the function section. binary.61
    // declares code section size=1 body=[0x00] but no function
    // section. compileWasm's `module.find(.function) == null`
    // branch fires directly (no need for the d-52 empty-body
    // check). Same downstream allocations + deinit.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x0a, 0x01, 0x00,
    };
    var compiled = try compileWasm(testing.allocator, &bytes);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), compiled.func_sigs.len);
    try testing.expectEqual(@as(usize, 0), compiled.func_results.len);
}
