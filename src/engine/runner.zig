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
const FuncType = zir.FuncType;
const compile_func = @import("codegen/shared/compile.zig");
const linker = @import("codegen/shared/linker.zig");
const exception_table_mod = @import("codegen/shared/exception_table.zig");
const entry = @import("codegen/shared/entry.zig");
const buffer_write = @import("codegen/shared/entry_buffer_write.zig");
const rv = @import("runner_validate.zig");

/// Re-exported so callers of `JitInstance.invokeMulti` can name the result
/// slot type from the runner namespace (the spec-corpus multi-value path).
pub const TypedResult = buffer_write.TypedResult;
// ADR-0079 Step 1 — setup carve-out (RuntimeOwned + setupRuntime +
// hostDispatchTrap). Re-exports below keep callers unchanged.
const setup_mod = @import("setup.zig");
// D-451 — same WASI import oracle the JIT setup uses to bind dispatch slots
// (`populateDispatch` → `jit_dispatch.lookup`); a `null` lookup means the
// import has no host handler, so it must reject at instantiation rather than
// silently install a trap-on-call stub (Wasm spec §4.5.4).
const jit_dispatch = @import("../wasi/jit_dispatch.zig");
const setupRuntime = setup_mod.setupRuntime;
/// D-225 — resolved cross-module FUNC import target (re-exported so the
/// spec runner can build the slice for `initLinked` / `exportedFuncTarget`).
pub const FuncImportTarget = setup_mod.FuncImportTarget;
/// ADR-0134 D3 — resolved cross-module TAG import identity (re-exported
/// so the spec runner can build the slice for `initLinked`).
pub const TagImportTarget = setup_mod.TagImportTarget;
/// ADR-0134 D2 — cross-instance EH registry (re-exported so the linker /
/// spec runner can `register`/`unregister` each heap-pinned instance's
/// `*JitRuntime` for per-frame-instance unwind dispatch).
pub const eh_registry = @import("codegen/shared/eh_registry.zig");

// ADR-0079 Step 2 — compile carve-out (compileWasm + per-section
// helpers). Re-exports preserve external callers' import paths
// (`runner.compileWasm` etc still resolves).
const compile_mod = @import("compile.zig");
pub const compileWasm = compile_mod.compileWasm;
pub const applyDefinedGlobalsInit = compile_mod.applyDefinedGlobalsInit;
pub const resolveFuncrefGlobals = compile_mod.resolveFuncrefGlobals;
pub const applyTableInit = compile_mod.applyTableInit;
pub const applyTableInitCtx = compile_mod.applyTableInitCtx;
pub const applyTableInitForTable = compile_mod.applyTableInitForTable;
pub const applyTableInitForTableCtx = compile_mod.applyTableInitForTableCtx;
pub const patchTableImportFuncptrs = compile_mod.patchTableImportFuncptrs;
pub const patchTableImportFuncptrsCtx = compile_mod.patchTableImportFuncptrsCtx;
pub const countDeclaredTables = compile_mod.countDeclaredTables;
pub const declaredTableMin = compile_mod.declaredTableMin;
pub const declaredTableMax = compile_mod.declaredTableMax;
pub const applyActiveDataSegments = compile_mod.applyActiveDataSegments;
pub const applyActiveDataSegmentsCtx = compile_mod.applyActiveDataSegmentsCtx;

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
    /// Sandbox bound (D-332): a module's declared initial table
    /// elements exceed the host's `RunLimits.max_table_elements`
    /// cap. The JIT-path analogue of the interp's eager-table-alloc
    /// cap (instantiate.zig) — completes the cross-engine sandbox
    /// triad (fuel / memory / table) on the JIT runner. Early-reject
    /// before `setupRuntime`'s eager `table_refs` allocation, so a
    /// pathological `(table 4e9)` cannot OOM the host.
    TableLimitExceeded,
    /// Wasm spec §4.5.4 (instantiation): a module declares an import
    /// the host cannot satisfy. The interp path rejects this at
    /// instantiation via the linker (`UnknownImport` /
    /// `UnsupportedWasiImport`); the JIT WASI run path mirrors it here
    /// instead of silently binding the import to a trap-on-call stub
    /// (`hostDispatchTrap`) that only faults if the import is ever
    /// called. An unsatisfied import MUST fail instantiation regardless
    /// of whether it is reached at runtime (D-451).
    ImportUnsatisfied,
    /// D-475 — a module declares an i64-indexed table (table64, the memory64
    /// proposal's table extension). The validator + interp runtime support
    /// these, but the JIT codegen still indexes tables at i32 width, so
    /// compiling one would silently miscompile a >2^32 index. The JIT compile
    /// path rejects it (clean failure) until the i64 table-bounds codegen lands
    /// (D-475 slice 4); the interp path runs table64 modules correctly.
    JitTable64Unsupported,
} || compile_func.Error || parser.Error || sections.Error || linker.Error || entry.Error || validator_mod.Error || rv.Error;
// `InvalidGlobalInitExpr` / `UnsupportedEntrySignature` /
// `UnsupportedConstExpr` originate in `runner_validate.zig`
// (per ADR-0064) and are merged in via `|| rv.Error` above.

/// Compile every defined function in `wasm_bytes` and link into
/// a single JitModule. Caller owns the module — pair with
/// `module.deinit`. The `func_results` slice is also returned so
/// the caller can introspect / `deinitFuncResult` each one.
/// A func-kind export of a compiled module: name → wasm-space func
/// index. The AOT producer serialises these so a loaded `.cwasm`
/// resolves `_start`/`main`/`--invoke <name>` (ADR-0138).
pub const FuncExport = struct {
    name: []const u8,
    func_idx: u32,
};

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
    /// Per-defined-global metadata (ADR-0052 + ADR-0110 §9.13-V).
    /// `globals_offsets[i]` is the byte offset of global `i`
    /// inside the runtime's globals byte buffer;
    /// `globals_valtypes[i]` selects the JIT emit path for
    /// global.get / global.set on that index. Post-widen: every
    /// global occupies uniform 16 bytes regardless of valtype,
    /// so the total byte size is derivable as
    /// `globals_valtypes.len * 16` (consumers that need a
    /// pre-aligned allocation size compute it inline).
    /// Empty slices when the module has no globals.
    globals_offsets: []u32,
    globals_valtypes: []zir.ValType,
    num_global_imports: u32, // B150 (D-153): wasm-idx[0..N) imports prefix.
    /// Wasm 3.0 EH (10.E-N-3) — per-tag param count, pre-resolved
    /// at compile time from
    /// `tag_section[i].typeidx → module_types[typeidx].params.len`.
    /// Consumed by the interp's `throwOp` via
    /// `Runtime.tag_param_counts` after `setup` writes it.
    /// Empty slice when the module has no tag section.
    tag_param_counts: []u32,
    /// ADR-0120 D5 (10.E-payload-prop cycle 1) — slot-count
    /// variant of tag_param_counts. v128 = 2 slots; all other
    /// v0.1 types = 1 slot. Consumed by JIT throw / catch emit
    /// to compute `[runtime_ptr + payload_ptr_off + i*8]`
    /// offsets when v128 tag params are present. Empty slice
    /// when no tag section.
    tag_param_slot_counts: []u32,
    /// Phase 10.E IT-5 (ADR-0114 D3) — per-Instance JIT exception
    /// table flattened from per-function `EmitOutput.exception_handlers`
    /// at compile end. pc_start / pc_end are module-relative
    /// (= function-local pcs shifted by the linker's func_offsets).
    /// Consumed by the FP-walk unwinder via
    /// `ExceptionTable.lookup(absolute_pc - block_addr, throw_tag_idx)`.
    /// Empty slice when no function contains a try_table.
    exception_table: exception_table_mod.ExceptionTable,
    /// Func-kind exports (name → wasm func idx), for the AOT producer
    /// (ADR-0138). Names + the slice are arena-owned (freed by
    /// `arena.deinit()`), so `deinit` needs no extra free. Empty slice
    /// when the module exports no functions.
    exports: []const FuncExport,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CompiledWasm, allocator: Allocator) void {
        for (self.func_results) |*r| compile_func.deinitFuncResult(allocator, r);
        allocator.free(self.func_results);
        allocator.free(self.func_sigs);
        allocator.free(self.func_typeidxs);
        allocator.free(self.globals_offsets);
        allocator.free(self.globals_valtypes);
        if (self.tag_param_counts.len > 0) allocator.free(self.tag_param_counts);
        if (self.tag_param_slot_counts.len > 0) allocator.free(self.tag_param_slot_counts);
        if (self.exception_table.entries.len > 0) allocator.free(self.exception_table.entries);
        self.module.deinit(allocator);
        self.arena.deinit();
    }
};

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

/// Run a no-arg, i64-result exported function and return the raw 64-bit
/// result. Mirrors `runI32Export`; differs only in the result-type gate
/// (`.i64`) and the entry helper (`callI64NoArgs`). The spec-corpus §1
/// JIT execution mode dispatches here for `() -> i64` asserts.
pub fn runI64Export(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
) Error!u64 {
    return runI64ExportWasi(allocator, wasm_bytes, export_name, null);
}

/// Like `runI64Export` but attaches a WASI host (a `*wasi.host.Host`, passed
/// opaquely) to the JIT runtime so imported WASI calls do REAL I/O instead of
/// the compute-only stubs (D-244). `wasi_host == null` → the stub path.
pub fn runI64ExportWasi(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
    wasi_host: ?*anyopaque,
) Error!u64 {
    const func_idx = try findExportFunc(allocator, wasm_bytes, export_name);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    if (func_idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    if (func_idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[func_idx];
    if (sig.params.len != 0 or sig.results.len != 1 or sig.results[0] != .i64) {
        return Error.UnsupportedEntrySignature;
    }

    var owned = try setupRuntime(allocator, &compiled, wasm_bytes);
    defer owned.deinit(allocator);
    owned.rt.wasi_host = wasi_host;
    return entry.callI64NoArgs(compiled.module, func_idx, &owned.rt);
}

/// Run a no-arg, f32-result exported function. Mirrors `runI64Export`;
/// differs only in the result-type gate (`.f32`) and entry helper
/// (`callF32NoArgs`). Callers compare the raw bit pattern (NaN-safe).
pub fn runF32Export(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
) Error!f32 {
    const func_idx = try findExportFunc(allocator, wasm_bytes, export_name);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    if (func_idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    if (func_idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[func_idx];
    if (sig.params.len != 0 or sig.results.len != 1 or sig.results[0] != .f32) {
        return Error.UnsupportedEntrySignature;
    }

    var owned = try setupRuntime(allocator, &compiled, wasm_bytes);
    defer owned.deinit(allocator);
    return entry.callF32NoArgs(compiled.module, func_idx, &owned.rt);
}

/// Run a no-arg, f64-result exported function. f64 mirror of
/// `runF32Export` (gate `.f64`, entry `callF64NoArgs`).
pub fn runF64Export(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
) Error!f64 {
    const func_idx = try findExportFunc(allocator, wasm_bytes, export_name);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    if (func_idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    if (func_idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[func_idx];
    if (sig.params.len != 0 or sig.results.len != 1 or sig.results[0] != .f64) {
        return Error.UnsupportedEntrySignature;
    }

    var owned = try setupRuntime(allocator, &compiled, wasm_bytes);
    defer owned.deinit(allocator);
    return entry.callF64NoArgs(compiled.module, func_idx, &owned.rt);
}

/// Run a no-arg, void-result exported function (e.g. `_start`)
/// and surface trap as Error.Trap. Mirrors `runI32Export`'s
/// setup; differs only in the entry-call helper + signature
/// gate.
/// Compile + invoke a void-returning export. Returns the
/// post-call value of `JitRuntime.jit_executed_flag` (per
/// §9.8a / 8a.2 ADR-0034 sentinel) so callers can distinguish
/// "JIT body actually executed" (`flag != 0`) from "compile-
/// passed but never invoked" (`flag == 0`). Both ARM64 (since
/// `d6e29ac`) and x86_64 (since D-055 close at `871c78e1`)
/// prologue injects set the flag — `uses_runtime_ptr=true`
/// only; functions with no memory / call ops keep flag at 0
/// since the sentinel is gated on R15 / X19 availability.
pub fn runVoidExport(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
) Error!u32 {
    return runVoidExportWasi(allocator, wasm_bytes, export_name, null, null);
}

/// Like `runVoidExport` but attaches a WASI host (a `*wasi.host.Host`, passed
/// opaquely) to the JIT runtime so imported WASI calls do REAL I/O instead of
/// the compute-only stubs (D-244). The CLI `--engine jit` run path (chunk 2c)
/// will own a Host and call through here. `wasi_host == null` → the stub path.
/// `trap_code_out` (ADR-0164 workstream A): when non-null and the run traps,
/// receives `JitRuntime.trap_kind` — the trap-kind code the shared trap stub
/// recorded — so the CLI can surface a per-kind message instead of a bare
/// `Trap`. Unchanged on a clean return; left untouched on a non-trap error.
pub fn runVoidExportWasi(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
    wasi_host: ?*anyopaque,
    trap_code_out: ?*u32,
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
    owned.rt.wasi_host = wasi_host;
    entry.callVoidNoArgs(compiled.module, func_idx, &owned.rt) catch |err| {
        if (err == Error.Trap) {
            if (trap_code_out) |p| p.* = owned.rt.trap_kind;
        }
        return err;
    };
    return owned.rt.jit_executed_flag;
}

/// D-284 — lenient default-entry resolution for the JIT CLI, mirroring the
/// interp/AOT chain: `_start` → `main` → first func export → null (no func
/// export → instantiate-only). Returns the entry func index, or null.
fn resolveLenientEntryIdx(allocator: Allocator, wasm_bytes: []const u8) Error!?u32 {
    var module = try parser.parse(allocator, wasm_bytes);
    defer module.deinit(allocator);
    const export_section = module.find(.@"export") orelse return null;
    var exports = try sections.decodeExports(allocator, export_section.body);
    defer exports.deinit();
    var first_func: ?u32 = null;
    var start_idx: ?u32 = null;
    var main_idx: ?u32 = null;
    for (exports.items) |e| {
        if (e.kind != .func) continue;
        if (first_func == null) first_func = e.idx;
        if (std.mem.eql(u8, e.name, "_start")) start_idx = e.idx;
        if (std.mem.eql(u8, e.name, "main")) main_idx = e.idx;
    }
    return start_idx orelse main_idx orelse first_func;
}

/// D-284 — run a WASI module via the LENIENT entry chain so the JIT CLI matches
/// the interp (`runWasmCaptured`) + AOT (`runCwasm`): `--invoke NAME` → `_start`
/// → `main` → first func export, else INSTANTIATE-ONLY (exit 0, wasmtime-aligned)
/// — instead of strict `_start`-only → ExportNotFound on no-`_start` modules
/// (D-284 nbody). A void entry runs via `callVoidNoArgs` (proc_exit code flows
/// through the host); a no-arg `() -> i32` entry runs via `callI32NoArgs` (i32 →
/// exit, AOT-aligned). Other default-entry shapes (params / non-i32 result) have
/// no args to supply → instantiate-only. `--invoke` of an unsupported sig keeps
/// the existing UnsupportedEntrySignature contract.
/// ADR-0179 #3a-4 / D-314 — sandboxing limits the CLI threads into the JIT
/// run path (the facade stays interp-only by design, so the JIT runner arms
/// its JitRuntime directly). All optional; defaults = unmetered/uncapped.
pub const RunLimits = struct {
    /// JIT fuel budget; units = poll-site crossings (prologue + loop
    /// back-edges), NOT interp instructions (ADR-0179 rev 2026-06-12).
    fuel: ?u64 = null,
    /// Host cap on linear memory, in BYTES (converted to memory0's page
    /// units here, where mem0_page_size_log2 is known).
    max_memory_bytes: ?u64 = null,
    /// Host cap on a module's declared INITIAL table elements, summed across
    /// all defined tables (D-332). `null` = unlimited (no regression). The
    /// JIT-path analogue of the interp eager-table-alloc cap; enforced as an
    /// early-reject before setup's `table_refs` allocation.
    max_table_elements: ?u64 = null,
    /// Cooperative-interruption flag (e.g. the CLI's --timeout timer raises
    /// it). Must outlive the run.
    interrupt_flag: ?*const std.atomic.Value(u32) = null,
};

/// Sum a module's declared INITIAL table elements across all defined tables,
/// for the `RunLimits.max_table_elements` sandbox check (D-332). Mirrors
/// setup.zig's table decode; an arena keeps it allocation-clean.
/// Wasm spec §4.5.4 — reject instantiation when the module declares an import
/// the WASI host cannot satisfy (D-451). The JIT WASI run path's only import
/// provider is `jit_dispatch` (the same oracle `setupRuntime` uses to populate
/// the dispatch table); an import whose `(module, name)` does not resolve there
/// would otherwise be left as a trap-on-call `hostDispatchTrap` stub and the
/// module would instantiate + run if the import is never called — diverging
/// from the interp path (linker `UnknownImport`) and the spec. Non-func imports
/// (memory/table/global/tag) are never satisfiable through the WASI host, so
/// any such import is unsatisfied here too (the interp WASI path rejects them
/// identically). Modules with no import section pass trivially.
fn assertWasiImportsSatisfied(allocator: Allocator, wasm_bytes: []const u8) Error!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const module = try parser.parse(ta, wasm_bytes);
    const s = module.find(.import) orelse return;
    var imports_buf = try sections.decodeImports(ta, s.body);
    defer imports_buf.deinit();
    for (imports_buf.items) |imp| {
        if (imp.kind != .func) return Error.ImportUnsatisfied;
        if (jit_dispatch.lookup(imp.module, imp.name) == null) return Error.ImportUnsatisfied;
    }
}

fn declaredTableElements(allocator: Allocator, wasm_bytes: []const u8) Error!u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const module = try parser.parse(ta, wasm_bytes);
    var total: u64 = 0;
    if (module.find(.table)) |s| {
        var tables = try sections.decodeTables(ta, s.body);
        defer tables.deinit();
        for (tables.items) |t| total += t.min;
    }
    return total;
}

/// A scalar `--invoke` result surfaced by `runWasiLenient` through its
/// `result_out` channel. Kept Zone-2-local (no `api.wasm.Val`): the Zone-3 CLI
/// maps it to the C-API val for `invoke_args.formatScalar`. Splitting this off
/// the `u32` return (which stays the exit/instantiate flag) removes the latent
/// dual-meaning where an i32-returning invoke overloaded the exit-code slot.
pub const ScalarResult = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    /// A v128 result — outside the C-ABI `Val` kind set, so the CLI formats
    /// the raw 16 bytes directly. The JIT returns it via `entry.callV128NoArgs`
    /// (the interp is non-SIMD, so v128-result invoke is JIT-only).
    v128: [16]u8,
};

fn decodeScalarResult(t: zir.ValType, carrier: u64) ScalarResult {
    return switch (scalarKey(t).?) {
        0 => .{ .i32 = @bitCast(@as(u32, @truncate(carrier))) },
        1 => .{ .i64 = @bitCast(carrier) },
        2 => .{ .f32 = @bitCast(@as(u32, @truncate(carrier))) },
        3 => .{ .f64 = @bitCast(carrier) },
    };
}

/// Back-compat delegate: lenient WASI run with NO typed invoke args (the
/// common case — `_start` / a zero-arg `--invoke`). Threads an empty arg slice
/// to `runWasiLenientArgs`.
pub fn runWasiLenient(
    allocator: Allocator,
    wasm_bytes: []const u8,
    invoke_name: ?[]const u8,
    wasi_host: ?*anyopaque,
    trap_code_out: ?*u32,
    limits: RunLimits,
    result_out: ?*?ScalarResult,
) Error!u32 {
    return runWasiLenientArgs(allocator, wasm_bytes, invoke_name, wasi_host, trap_code_out, limits, result_out, &.{}, null);
}

/// D-477: lenient WASI run that also accepts typed `--invoke` ARGS (pre-packed
/// u64 carriers per the buffer-write ABI: i32/f32 in the low 32 bits, i64/f64/
/// ref full-64). A params-bearing GPR export with a single scalar (or void)
/// result routes through the generalized buffer-write thunk; `args.len` must
/// equal the entry's param arity. v1/zero-arg shapes behave exactly as before
/// (`args` empty).
pub fn runWasiLenientArgs(
    allocator: Allocator,
    wasm_bytes: []const u8,
    invoke_name: ?[]const u8,
    wasi_host: ?*anyopaque,
    trap_code_out: ?*u32,
    limits: RunLimits,
    result_out: ?*?ScalarResult,
    args: []const u64,
    multi_out: ?[]buffer_write.TypedResult,
) Error!u32 {
    const entry_idx: ?u32 = if (invoke_name) |name|
        try findExportFunc(allocator, wasm_bytes, name)
    else
        try resolveLenientEntryIdx(allocator, wasm_bytes);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    // D-451 — Wasm spec §4.5.4: an unsatisfied import MUST fail instantiation,
    // regardless of whether it is ever called. Reject here (interp-parity)
    // rather than leaving the import as a trap-on-call stub.
    try assertWasiImportsSatisfied(allocator, wasm_bytes);

    // D-332 sandbox triad (table leg): reject a module whose declared initial
    // table elements exceed the host cap BEFORE setup's eager `table_refs`
    // alloc, so a pathological `(table 4e9)` can't OOM the host. Mirrors the
    // interp eager-alloc cap (instantiate.zig); `null` = unlimited.
    if (limits.max_table_elements) |cap| {
        if (try declaredTableElements(allocator, wasm_bytes) > cap) return Error.TableLimitExceeded;
    }

    var owned = try setupRuntime(allocator, &compiled, wasm_bytes);
    defer owned.deinit(allocator);
    owned.rt.wasi_host = wasi_host;
    if (limits.fuel) |n| {
        owned.rt.fuel_cell = std.math.cast(i64, n) orelse std.math.maxInt(i64);
        owned.rt.fuel_metered = 1;
    }
    if (limits.max_memory_bytes) |bytes_cap| {
        if (owned.mem_ctx) |ctx| ctx.host_max_pages = bytes_cap >> @intCast(owned.rt.mem0_page_size_log2);
    }
    // D-314(b): the table-elements cap also bounds runtime `table.grow`
    // (jitTableGrow reads `rt.store_table_elements_max`), not just the initial
    // eager alloc rejected above. Sets the same cap the early-reject used.
    if (limits.max_table_elements) |cap| owned.rt.store_table_elements_max = cap; // maxInt sentinel default = unlimited
    if (limits.interrupt_flag) |flag| owned.rt.interrupt_ptr = flag;

    const idx = entry_idx orelse return owned.rt.jit_executed_flag; // no entry → instantiate-only
    if (idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    if (idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[idx];

    if (sig.params.len == 0 and sig.results.len == 0) {
        entry.callVoidNoArgs(compiled.module, idx, &owned.rt) catch |err| {
            if (err == Error.Trap) {
                if (trap_code_out) |p| p.* = owned.rt.trap_kind;
            }
            return err;
        };
        return owned.rt.jit_executed_flag;
    }
    if (sig.params.len == 0 and sig.results.len == 1) {
        if (scalarKey(sig.results[0])) |rk| {
            const carrier = dispatchNoArg(compiled.module, idx, &owned.rt, rk) catch |err| {
                if (err == Error.Trap) {
                    if (trap_code_out) |p| p.* = owned.rt.trap_kind;
                }
                return err;
            };
            if (result_out) |ro| ro.* = decodeScalarResult(sig.results[0], carrier);
            return owned.rt.jit_executed_flag;
        }
        // v128 single result: outside the scalar (u64-carrier) set — the JIT
        // returns the full 16 bytes via the SIMD return register. wasmtime
        // supports this host-invoke; without this branch a `(result v128)`
        // export rejected with UnsupportedEntrySignature (the interp is
        // non-SIMD, so this path is JIT-only).
        if (sig.results[0] == .v128) {
            const v = entry.callV128NoArgs(compiled.module, idx, &owned.rt) catch |err| {
                if (err == Error.Trap) {
                    if (trap_code_out) |p| p.* = owned.rt.trap_kind;
                }
                return err;
            };
            if (result_out) |ro| ro.* = .{ .v128 = v };
            return owned.rt.jit_executed_flag;
        }
        // remaining non-scalar single result (ref) — the named-invoke path
        // rejects it; a default entry just instantiate-runs.
        if (invoke_name != null) return Error.UnsupportedEntrySignature;
        return owned.rt.jit_executed_flag;
    }
    // D-477: multi-arg (params > 0) host invoke via the generalized buffer-write
    // thunk. Single scalar/void result fills `result_out`; a MULTI result (≥2,
    // when `multi_out` is provided + sized to the result arity) fills `multi_out`
    // (TypedResult[], same decode as `invokeMulti`). Only shapes for which
    // `wrapper_thunk.emit` produced a thunk (hasThunk) qualify; FP/v128/>N-param
    // shapes have no thunk → fall through to the reject below. `args` are the
    // pre-packed u64 carriers.
    const can_multi = sig.results.len >= 2 and multi_out != null and multi_out.?.len == sig.results.len;
    if (sig.params.len == args.len and
        (sig.results.len == 0 or (sig.results.len == 1 and scalarKey(sig.results[0]) != null) or can_multi) and
        compiled.module.hasThunk(idx))
    {
        var abuf: [16]u64 = undefined;
        for (args, 0..) |a, j| abuf[j] = a;
        var rbuf: [16]u64 = [_]u64{0} ** 16;
        const fnp = compiled.module.entry_buf(idx, buffer_write.BufferWriteFn);
        buffer_write.invokeBufferWrite(&owned.rt, fnp, &abuf, &rbuf) catch |err| {
            if (err == Error.Trap) {
                if (trap_code_out) |p| p.* = owned.rt.trap_kind;
            }
            return err;
        };
        if (sig.results.len == 1) {
            if (result_out) |ro| ro.* = decodeScalarResult(sig.results[0], rbuf[0]);
        } else if (can_multi) {
            for (multi_out.?, 0..) |*res, i| {
                res.* = switch (resultKind(sig.results[i]) orelse return Error.UnsupportedEntrySignature) {
                    .i32 => .{ .i32 = @truncate(rbuf[i]) },
                    .i64 => .{ .i64 = rbuf[i] },
                    .f32 => .{ .f32 = @truncate(rbuf[i]) },
                    .f64 => .{ .f64 = rbuf[i] },
                    .funcref => .{ .funcref = rbuf[i] },
                    .externref => .{ .externref = rbuf[i] },
                };
            }
        }
        return owned.rt.jit_executed_flag;
    }
    if (invoke_name != null) return Error.UnsupportedEntrySignature;
    return owned.rt.jit_executed_flag; // unsupported default-entry shape → instantiate-only
}

/// Map a scalar `ValType` to a 0..3 dispatch key (i32/i64/f32/f64);
/// null for non-scalar (v128 / ref) types so the caller can reject the
/// shape as an enumerated spec-corpus skip. `==` against the void-tag
/// union fields mirrors the no-arg gates (`sig.results[0] != .i32`),
/// avoiding a switch + the exhaustive-enum lint on `ValType`'s `ref`
/// payload arm.
fn scalarKey(t: zir.ValType) ?u2 {
    if (t == .i32) return 0;
    if (t == .i64) return 1;
    if (t == .f32) return 2;
    if (t == .f64) return 3;
    return null;
}

/// Map a result valtype to the buffer-write `TypedResult` tag (multi-value
/// invoke). Refs ride the u64 carrier (ADR-0116); v128 is unsupported.
fn resultKind(t: zir.ValType) ?buffer_write.ResultKind {
    return switch (t) {
        .i32 => .i32,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        .ref => |r| if (r.heap_type == .abstract and r.heap_type.abstract == .extern_) .externref else .funcref,
        else => null,
    };
}

/// Param key for the JIT entry (D-226): like `scalarKey`, but a reftype param
/// rides the i64 carrier — a ref is a u64 in a GPR (ADR-0116), so the i64 entry
/// ABI passes it UNTRUNCATED via `callVoid_i64` / `callX_i64`. This lets
/// reftype-param setup fns run through the JIT entry — e.g. the spec corpus
/// `(invoke "init" (ref.extern 0))` that populates ref.test/ref.cast tables.
/// Results keep `scalarKey` (a ref RESULT routes the void path via `ref_result`).
fn paramScalarKey(t: zir.ValType) ?u2 {
    if (std.meta.activeTag(t) == .ref) return 1; // i64-class u64 carrier
    return scalarKey(t);
}

/// Dispatch a no-arg scalar-result call to the matching `entry.callXNoArgs`
/// helper, returning the result as a u64 carrier. `rk` = result scalar key.
fn dispatchNoArg(m: linker.JitModule, func_idx: u32, r: *entry.JitRuntime, rk: u2) Error!u64 {
    return switch (rk) {
        0 => @as(u64, try entry.callI32NoArgs(m, func_idx, r)),
        1 => try entry.callI64NoArgs(m, func_idx, r),
        2 => @as(u64, @as(u32, @bitCast(try entry.callF32NoArgs(m, func_idx, r)))),
        3 => @bitCast(try entry.callF64NoArgs(m, func_idx, r)),
    };
}

/// Dispatch a single-scalar-arg, void-result call to the matching
/// `entry.callVoid_X` helper. `pk` = param scalar key.
fn dispatchVoid1(m: linker.JitModule, func_idx: u32, r: *entry.JitRuntime, pk: u2, arg_bits: u64) Error!void {
    const a_u32: u32 = @truncate(arg_bits);
    return switch (pk) {
        0 => entry.callVoid_i32(m, func_idx, r, a_u32),
        1 => entry.callVoid_i64(m, func_idx, r, arg_bits),
        2 => entry.callVoid_f32(m, func_idx, r, @bitCast(a_u32)),
        3 => entry.callVoid_f64(m, func_idx, r, @bitCast(arg_bits)),
    };
}

/// Dispatch a single-scalar-arg, single-scalar-result call to the matching
/// `entry.callX_Y` cross-type helper (§9.9 widen set), covering the full 4×4
/// matrix. `arg_bits` carries the arg (i32/f32 low 32, i64/f64 full 64);
/// result returns the same way. `key` = param-key*4 + result-key.
fn dispatchScalar1(m: linker.JitModule, func_idx: u32, r: *entry.JitRuntime, key: u4, arg_bits: u64) Error!u64 {
    const a_u32: u32 = @truncate(arg_bits);
    const a_u64: u64 = arg_bits;
    const a_f32: f32 = @bitCast(a_u32);
    const a_f64: f64 = @bitCast(a_u64);
    return switch (key) {
        0 => @as(u64, try entry.callI32_i32(m, func_idx, r, a_u32)),
        1 => try entry.callI64_i32(m, func_idx, r, a_u32),
        2 => @as(u64, @as(u32, @bitCast(try entry.callF32_i32(m, func_idx, r, a_u32)))),
        3 => @bitCast(try entry.callF64_i32(m, func_idx, r, a_u32)),
        4 => @as(u64, try entry.callI32_i64(m, func_idx, r, a_u64)),
        5 => try entry.callI64_i64(m, func_idx, r, a_u64),
        6 => @as(u64, @as(u32, @bitCast(try entry.callF32_i64(m, func_idx, r, a_u64)))),
        7 => @bitCast(try entry.callF64_i64(m, func_idx, r, a_u64)),
        8 => @as(u64, try entry.callI32_f32(m, func_idx, r, a_f32)),
        9 => try entry.callI64_f32(m, func_idx, r, a_f32),
        10 => @as(u64, @as(u32, @bitCast(try entry.callF32_f32(m, func_idx, r, a_f32)))),
        11 => @bitCast(try entry.callF64_f32(m, func_idx, r, a_f32)),
        12 => @as(u64, try entry.callI32_f64(m, func_idx, r, a_f64)),
        13 => try entry.callI64_f64(m, func_idx, r, a_f64),
        14 => @as(u64, @as(u32, @bitCast(try entry.callF32_f64(m, func_idx, r, a_f64)))),
        15 => @bitCast(try entry.callF64_f64(m, func_idx, r, a_f64)),
    };
}

/// Dispatch a two-scalar-arg, void-result call (D-217). `key` =
/// param0-key<<4 | param1-key. Only the (param0, param1) combos the
/// spec corpus exercises have `entry.callVoid_XY` helpers; others →
/// `UnsupportedEntrySignature` (enumerated skip).
fn dispatchVoid2(m: linker.JitModule, func_idx: u32, r: *entry.JitRuntime, key: u8, a0: u64, a1: u64) Error!void {
    const x0_u32: u32 = @truncate(a0);
    const x1_u32: u32 = @truncate(a1);
    return switch (key) {
        0x00 => entry.callVoid_i32i32(m, func_idx, r, x0_u32, x1_u32), // (i32,i32)
        0x01 => entry.callVoid_i32i64(m, func_idx, r, x0_u32, a1), // (i32,i64)
        0x10 => entry.callVoid_i64i32(m, func_idx, r, a0, x1_u32), // (i64,i32)
        else => Error.UnsupportedEntrySignature,
    };
}

/// Dispatch a two-scalar-arg, single-scalar-result call (D-217). `key` =
/// param0-key<<4 | param1-key<<2 | result-key. Covers the scalar 2-arg
/// combos the spec corpus exercises; others → `UnsupportedEntrySignature`.
fn dispatchScalar2(m: linker.JitModule, func_idx: u32, r: *entry.JitRuntime, key: u8, a0: u64, a1: u64) Error!u64 {
    const x0_u32: u32 = @truncate(a0);
    const x1_u32: u32 = @truncate(a1);
    const x1_f32: f32 = @bitCast(x1_u32);
    return switch (key) {
        0x00 => @as(u64, try entry.callI32_i32i32(m, func_idx, r, x0_u32, x1_u32)), // (i32,i32)->i32
        0x01 => try entry.callI64_i32i32(m, func_idx, r, x0_u32, x1_u32), // (i32,i32)->i64
        0x02 => @as(u64, @as(u32, @bitCast(try entry.callF32_i32i32(m, func_idx, r, x0_u32, x1_u32)))), // (i32,i32)->f32
        0x05 => try entry.callI64_i32i64(m, func_idx, r, x0_u32, a1), // (i32,i64)->i64
        0x0a => @as(u64, @as(u32, @bitCast(try entry.callF32_i32f32(m, func_idx, r, x0_u32, x1_f32)))), // (i32,f32)->f32
        0x14 => @as(u64, try entry.callI32_i64i64(m, func_idx, r, a0, a1)), // (i64,i64)->i32
        0x15 => try entry.callI64_i64i64(m, func_idx, r, a0, a1), // (i64,i64)->i64
        else => Error.UnsupportedEntrySignature,
    };
}

/// Run a single-scalar-arg, single-scalar-result export through the JIT
/// entry (fresh compile + setup per call — no state persistence). Non-scalar
/// param/result, wrong arity, or an imported target → `UnsupportedEntrySignature`
/// (an enumerated spec-corpus skip, not a fail). ADR-0128 §1.
pub fn runScalar1Export(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
    arg_bits: u64,
) Error!u64 {
    const func_idx = try findExportFunc(allocator, wasm_bytes, export_name);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    if (func_idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    if (func_idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[func_idx];
    if (sig.params.len != 1 or sig.results.len != 1) return Error.UnsupportedEntrySignature;
    const pk = scalarKey(sig.params[0]) orelse return Error.UnsupportedEntrySignature;
    const rk = scalarKey(sig.results[0]) orelse return Error.UnsupportedEntrySignature;

    var owned = try setupRuntime(allocator, &compiled, wasm_bytes);
    defer owned.deinit(allocator);
    return dispatchScalar1(compiled.module, func_idx, &owned.rt, @as(u4, pk) * 4 + rk, arg_bits);
}

/// A compiled + instantiated module whose JIT runtime PERSISTS across
/// invocations, so memory/global/table mutations (`memory.grow`, stores,
/// `global.set`, `table.set`) accumulate — mirroring how an embedder (and
/// the interp path) uses the JIT. The spec-corpus mode instantiates one per
/// `module` directive and routes every subsequent invoke through it so
/// cross-directive state is preserved (D-214; ADR-0128 §1). `wasm_bytes` is
/// borrowed — the caller must keep it alive for the instance's lifetime.
pub const JitInstance = struct {
    compiled: CompiledWasm,
    owned: setup_mod.RuntimeOwned,
    wasm_bytes: []const u8,

    pub fn init(allocator: Allocator, wasm_bytes: []const u8) Error!JitInstance {
        return initLinked(allocator, wasm_bytes, &.{}, &.{}, &.{});
    }

    /// D-225 — `init` + cross-module import resolution. The caller (spec
    /// runner / linker) passes, in import order: resolved imported-GLOBAL
    /// values (`imported_global_vals`) for setup-time const-expr evals +
    /// emitted global.get-of-import; and resolved FUNC-import targets
    /// (`func_import_targets`, func-import order) so the importer emits a
    /// cohort-safe bridge thunk into `dispatch[N]` and a cross-module call
    /// dispatches to the exporter instead of trapping. Plain `init` passes
    /// `&.{}` for both (no imports).
    pub fn initLinked(
        allocator: Allocator,
        wasm_bytes: []const u8,
        imported_global_vals: []const u64,
        func_import_targets: []const setup_mod.FuncImportTarget,
        tag_import_targets: []const setup_mod.TagImportTarget,
    ) Error!JitInstance {
        var compiled = try compileWasm(allocator, wasm_bytes);
        errdefer compiled.deinit(allocator);
        const owned = try setup_mod.setupRuntimeLinked(allocator, &compiled, wasm_bytes, imported_global_vals, func_import_targets, tag_import_targets);
        return .{ .compiled = compiled, .owned = owned, .wasm_bytes = wasm_bytes };
    }

    pub fn deinit(self: *JitInstance, allocator: Allocator) void {
        self.owned.deinit(allocator);
        self.compiled.deinit(allocator);
    }

    /// D-225 — resolve THIS instance as a cross-module export target: the
    /// (callee_rt, callee_entry) an importer plants into a bridge thunk for
    /// `(import "<this>" "<name>" (func …))`. Null if `name` isn't an
    /// exported func. `callee_rt` is the address of this instance's pinned
    /// JitRuntime (stable — JitInstance must not move while referenced).
    pub fn exportedFuncTarget(self: *JitInstance, allocator: Allocator, name: []const u8) ?setup_mod.FuncImportTarget {
        const idx = findExportFunc(allocator, self.wasm_bytes, name) catch return null;
        if (idx < self.compiled.num_imports) return null;
        return .{
            .callee_rt = @intFromPtr(&self.owned.rt),
            .callee_entry = self.compiled.module.entryAddr(idx),
        };
    }

    /// ADR-0134 D3 — resolve THIS instance as a cross-module TAG export
    /// target: the globally-comparable identity id for `(export "<name>"
    /// (tag …))`, = this instance's `tag_ids[exported_tag_idx]` (an
    /// address-derived token per ADR-0114 D7). An importer writes the
    /// returned `source_id` into its own `tag_ids[import_idx]` so a
    /// cross-module throw and catch compare equal. Null if `name` is not
    /// an exported tag (tag exports are dropped by `decodeExports`, so
    /// this uses the dedicated `sections.findExportedTagIndex` scan).
    pub fn exportedTagTarget(self: *JitInstance, allocator: Allocator, name: []const u8) ?setup_mod.TagImportTarget {
        var module = parser.parse(allocator, self.wasm_bytes) catch return null;
        defer module.deinit(allocator);
        const exp_sec = module.find(.@"export") orelse return null;
        const tag_idx = (sections.findExportedTagIndex(exp_sec.body, name) catch return null) orelse return null;
        if (self.owned.rt.tag_ids_ptr) |p| {
            if (tag_idx < self.owned.rt.tag_ids_count) return .{ .source_id = p[tag_idx] };
        }
        return null;
    }

    /// Invoke an export by name against the persisted runtime. `args` are
    /// scalar bit-carriers in declaration order. Returns the scalar result
    /// as a u64 carrier, or null when there is nothing to compare — a void
    /// (0-result) export OR a REF-result export (the latter is RUN for its
    /// side effects, e.g. `new` doing `global.set (array.new …)`, via the
    /// void dispatch path: the callee sets the result register, a void caller
    /// ignores it — ABI-safe; the spec runner uses `:?` for ref results, D-222).
    /// ADR-0179 #3a / D-314 — host→JIT cooperative-interruption driving path.
    /// Point the JIT runtime's `interrupt_ptr` at a host `std.atomic.Value(u32)`
    /// (or null to disable). The JIT prologue/back-edge poll traps `Error.Trap`
    /// (trap_kind 16 = interrupted) on the next entry/back-edge once the host
    /// stores a nonzero value. The flag must outlive every `invoke`.
    pub fn setInterruptFlag(self: *JitInstance, flag: ?*const std.atomic.Value(u32)) void {
        self.owned.rt.interrupt_ptr = flag;
    }

    /// ADR-0179 #3b / D-314 — arm (or disarm with null) the JIT fuel budget.
    /// Units are POLL-SITE CROSSINGS (function prologue + each loop back-edge),
    /// NOT interp instructions — engines meter differently by design (ADR-0179
    /// rev 2026-06-12). Exhaustion traps with kind 17 (out_of_fuel).
    pub fn setFuel(self: *JitInstance, fuel: ?u64) void {
        if (fuel) |n| {
            self.owned.rt.fuel_cell = std.math.cast(i64, n) orelse std.math.maxInt(i64);
            self.owned.rt.fuel_metered = 1;
        } else {
            self.owned.rt.fuel_metered = 0;
        }
    }

    /// Remaining JIT fuel; null when unmetered. After an out-of-fuel trap the
    /// cell is one past zero — clamp so the host never sees a negative budget.
    pub fn fuelRemaining(self: *const JitInstance) ?u64 {
        if (self.owned.rt.fuel_metered == 0) return null;
        const cell = self.owned.rt.fuel_cell;
        return if (cell < 0) 0 else @intCast(cell);
    }

    /// ADR-0179 #3c-2 / D-314 — impose a host max on linear memory, in PAGES
    /// (an extra ceiling below the declared/spec max; JIT mirror of the
    /// facade `setMemoryPagesLimit`). `memory.grow` past it returns the spec
    /// grow-failure (-1), not a trap. `null` clears the host cap. No-op for
    /// a module with no memory.
    pub fn setMemoryPagesLimit(self: *JitInstance, max_pages: ?u64) void {
        if (self.owned.mem_ctx) |ctx| ctx.host_max_pages = max_pages;
    }

    /// ADR-0200 — surface a named export's function signature (params/results)
    /// without invoking, so the embedding API can validate arity + type results.
    /// Null when `name` is not an exported function. The JIT path populates no
    /// `exports_storage`, so this resolves via `findExportFunc` over the bytes.
    pub fn exportFuncSig(self: *JitInstance, allocator: Allocator, name: []const u8) ?FuncType {
        const idx = findExportFunc(allocator, self.wasm_bytes, name) catch return null;
        if (idx >= self.compiled.func_sigs.len) return null;
        return self.compiled.func_sigs[idx];
    }

    /// Wider arities / v128 result / non-scalar args → `UnsupportedEntrySignature`.
    pub fn invoke(self: *JitInstance, allocator: Allocator, export_name: []const u8, args: []const u64) Error!?u64 {
        const func_idx = try findExportFunc(allocator, self.wasm_bytes, export_name);
        if (func_idx >= self.compiled.func_sigs.len) return Error.ExportNotFound;
        if (func_idx < self.compiled.num_imports) return Error.UnsupportedEntrySignature;
        const sig = self.compiled.func_sigs[func_idx];
        if (sig.results.len > 1 or sig.params.len != args.len) return Error.UnsupportedEntrySignature;
        const m = self.compiled.module;
        const r = &self.owned.rt;

        // 0 results OR a ref result → run via the void path (uncompared);
        // v128 result → unsupported.
        const ref_result = sig.results.len == 1 and std.meta.activeTag(sig.results[0]) == .ref;
        if (sig.results.len == 1 and !ref_result and scalarKey(sig.results[0]) == null)
            return Error.UnsupportedEntrySignature;
        const run_as_void = sig.results.len == 0 or ref_result;

        if (sig.params.len == 0) {
            if (run_as_void) {
                try entry.callVoidNoArgs(m, func_idx, r);
                return null;
            }
            return try dispatchNoArg(m, func_idx, r, scalarKey(sig.results[0]).?);
        }
        if (sig.params.len == 1) {
            const pk = paramScalarKey(sig.params[0]) orelse return Error.UnsupportedEntrySignature;
            if (run_as_void) {
                try dispatchVoid1(m, func_idx, r, pk, args[0]);
                return null;
            }
            return try dispatchScalar1(m, func_idx, r, @as(u4, pk) * 4 + scalarKey(sig.results[0]).?, args[0]);
        }
        if (sig.params.len == 2) {
            const pk0 = paramScalarKey(sig.params[0]) orelse return Error.UnsupportedEntrySignature;
            const pk1 = paramScalarKey(sig.params[1]) orelse return Error.UnsupportedEntrySignature;
            if (run_as_void) {
                try dispatchVoid2(m, func_idx, r, (@as(u8, pk0) << 4) | pk1, args[0], args[1]);
                return null;
            }
            return try dispatchScalar2(m, func_idx, r, (@as(u8, pk0) << 4) | (@as(u8, pk1) << 2) | scalarKey(sig.results[0]).?, args[0], args[1]);
        }
        if (sig.params.len == 3 and sig.params[0] == .i32 and sig.params[1] == .i32 and sig.params[2] == .i32 and sig.results.len == 1 and sig.results[0] == .i32) {
            // Fast path the corpus's common (i32,i32,i32)->i32 via the
            // shape-specific helper; everything else at arity 3+ routes
            // through the D-477 buffer-write thunk below.
            const a0: u32 = @truncate(args[0]);
            const a1: u32 = @truncate(args[1]);
            const a2: u32 = @truncate(args[2]);
            return @as(u64, try entry.callI32_i32i32i32(m, func_idx, r, a0, a1, a2));
        }
        if (sig.params.len == 3 and sig.params[0] == .i32 and sig.params[1] == .i32 and sig.params[2] == .i32 and run_as_void) {
            const a0: u32 = @truncate(args[0]);
            const a1: u32 = @truncate(args[1]);
            const a2: u32 = @truncate(args[2]);
            try entry.callVoid_i32i32i32(m, func_idx, r, a0, a1, a2);
            return null;
        }
        // D-477: any remaining multi-arg shape (3-arg non-(i32³), 4+ args)
        // routes through the generalized buffer-write thunk when one exists
        // (exported GPR-class, ≤7 params). FP/v128/>7-param shapes have no
        // thunk and stay UnsupportedEntrySignature until their later slice.
        return self.invokeViaBufferSingle(func_idx, sig, args, run_as_void);
    }

    /// D-477 — single-result (or void/ref) host invoke via the buffer-write
    /// thunk. Packs `args` as u64 slots, calls the generalized wrapper, and
    /// decodes the single result slot (i32/f32 masked to 32 bits, i64/f64/ref
    /// full 64). `UnsupportedEntrySignature` when no thunk was emitted for the
    /// shape (the gate that keeps FP/v128/>7-param off the still-partial emit).
    fn invokeViaBufferSingle(self: *JitInstance, func_idx: u32, sig: zir.FuncType, args: []const u64, run_as_void: bool) Error!?u64 {
        if (!self.compiled.module.hasThunk(func_idx)) return Error.UnsupportedEntrySignature;
        var abuf: [8]u64 = undefined;
        for (args, 0..) |a, j| abuf[j] = a;
        var rbuf: [1]u64 = .{0};
        const fnp = self.compiled.module.entry_buf(func_idx, buffer_write.BufferWriteFn);
        try buffer_write.invokeBufferWrite(&self.owned.rt, fnp, &abuf, &rbuf);
        if (run_as_void) return null;
        const rk = scalarKey(sig.results[0]) orelse return Error.UnsupportedEntrySignature;
        return if (rk == 0 or rk == 2) (rbuf[0] & 0xFFFFFFFF) else rbuf[0];
    }

    /// Multi-value invoke (results.len > 1), which `invoke` rejects. Routes
    /// through the ADR-0106 wrapper-thunk buffer-write entry (`entry_buf`):
    /// the wrapper writes each result to `[results+8*i]`, sidestepping the
    /// register-pair cap of the single-result C-ABI epilogue. `results_out`
    /// length must equal the function's result arity; each slot is tagged
    /// from `sig.results[i]` and filled with the unpacked value. Args are
    /// packed u64 (i32 zero-extended, ref as its u64 carrier).
    pub fn invokeMulti(
        self: *JitInstance,
        allocator: Allocator,
        export_name: []const u8,
        args: []const u64,
        results_out: []buffer_write.TypedResult,
    ) Error!void {
        const func_idx = try findExportFunc(allocator, self.wasm_bytes, export_name);
        if (func_idx >= self.compiled.func_sigs.len) return Error.ExportNotFound;
        if (func_idx < self.compiled.num_imports) return Error.UnsupportedEntrySignature;
        const sig = self.compiled.func_sigs[func_idx];
        if (sig.results.len != results_out.len or sig.params.len != args.len)
            return Error.UnsupportedEntrySignature;
        if (results_out.len > 16) return Error.UnsupportedEntrySignature;
        // Not every multi-result shape gets a wrapper thunk (wrapper_thunk.emit
        // rejects some); without one there is no buffer-write entry → skip.
        if (!self.compiled.module.hasThunk(func_idx)) return Error.UnsupportedEntrySignature;

        const fn_ptr = self.compiled.module.entry_buf(func_idx, buffer_write.BufferWriteFn);
        var u64_buf: [16]u64 = undefined;
        try buffer_write.invokeBufferWrite(&self.owned.rt, fn_ptr, args.ptr, &u64_buf);
        for (results_out, 0..) |*res, i| {
            const slot = u64_buf[i];
            res.* = switch (resultKind(sig.results[i]) orelse return Error.UnsupportedEntrySignature) {
                .i32 => .{ .i32 = @truncate(slot) },
                .i64 => .{ .i64 = slot },
                .f32 => .{ .f32 = @truncate(slot) },
                .f64 => .{ .f64 = slot },
                .funcref => .{ .funcref = slot },
                .externref => .{ .externref = slot },
            };
        }
    }
};
