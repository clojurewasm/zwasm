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
const rv = @import("runner_validate.zig");
// ADR-0079 Step 1 — setup carve-out (RuntimeOwned + setupRuntime +
// hostDispatchTrap). Re-exports below keep callers unchanged.
const setup_mod = @import("setup.zig");
const setupRuntime = setup_mod.setupRuntime;

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
        return initLinked(allocator, wasm_bytes, &.{});
    }

    /// D-225 — `init` + cross-module imported-global resolution. The caller
    /// (spec runner / linker) passes the resolved imported-global values in
    /// import order so the module's setup-time const-expr evals (defined-
    /// global init, table explicit-init-expr) can `global.get` an imported
    /// global. Plain `init` passes `&.{}` (no imports).
    pub fn initLinked(allocator: Allocator, wasm_bytes: []const u8, imported_global_vals: []const u64) Error!JitInstance {
        var compiled = try compileWasm(allocator, wasm_bytes);
        errdefer compiled.deinit(allocator);
        const owned = try setup_mod.setupRuntimeLinked(allocator, &compiled, wasm_bytes, imported_global_vals);
        return .{ .compiled = compiled, .owned = owned, .wasm_bytes = wasm_bytes };
    }

    pub fn deinit(self: *JitInstance, allocator: Allocator) void {
        self.owned.deinit(allocator);
        self.compiled.deinit(allocator);
    }

    /// Invoke an export by name against the persisted runtime. `args` are
    /// scalar bit-carriers in declaration order. Returns the scalar result
    /// as a u64 carrier, or null when there is nothing to compare — a void
    /// (0-result) export OR a REF-result export (the latter is RUN for its
    /// side effects, e.g. `new` doing `global.set (array.new …)`, via the
    /// void dispatch path: the callee sets the result register, a void caller
    /// ignores it — ABI-safe; the spec runner uses `:?` for ref results, D-222).
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
            const pk = scalarKey(sig.params[0]) orelse return Error.UnsupportedEntrySignature;
            if (run_as_void) {
                try dispatchVoid1(m, func_idx, r, pk, args[0]);
                return null;
            }
            return try dispatchScalar1(m, func_idx, r, @as(u4, pk) * 4 + scalarKey(sig.results[0]).?, args[0]);
        }
        if (sig.params.len == 2) {
            const pk0 = scalarKey(sig.params[0]) orelse return Error.UnsupportedEntrySignature;
            const pk1 = scalarKey(sig.params[1]) orelse return Error.UnsupportedEntrySignature;
            if (run_as_void) {
                try dispatchVoid2(m, func_idx, r, (@as(u8, pk0) << 4) | pk1, args[0], args[1]);
                return null;
            }
            return try dispatchScalar2(m, func_idx, r, (@as(u8, pk0) << 4) | (@as(u8, pk1) << 2) | scalarKey(sig.results[0]).?, args[0], args[1]);
        }
        if (sig.params.len == 3) {
            // The corpus exercises only (i32,i32,i32) -> {void, i32, ref} at
            // arity 3; other 3-arg shapes stay enumerated skips (D-217).
            if (!(sig.params[0] == .i32 and sig.params[1] == .i32 and sig.params[2] == .i32))
                return Error.UnsupportedEntrySignature;
            const a0: u32 = @truncate(args[0]);
            const a1: u32 = @truncate(args[1]);
            const a2: u32 = @truncate(args[2]);
            if (run_as_void) {
                try entry.callVoid_i32i32i32(m, func_idx, r, a0, a1, a2);
                return null;
            }
            if (sig.results[0] != .i32) return Error.UnsupportedEntrySignature;
            return @as(u64, try entry.callI32_i32i32i32(m, func_idx, r, a0, a1, a2));
        }
        return Error.UnsupportedEntrySignature; // 4+ args: future cycle
    }
};
