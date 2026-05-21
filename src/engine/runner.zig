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
    num_global_imports: u32, // B150 (D-153): wasm-idx[0..N) imports prefix.
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

/// Allocations bundled with the JitRuntime they back. Returned
/// from `setupRuntime`; caller defers `.deinit(allocator)`.
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
