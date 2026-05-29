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
const skip = @import("../test_support/skip.zig");

// File-loading harness lands at sub-7.5b-iii (needs std.Io
// plumbing). Today's tests use hand-inlined wasm bytes —
// generated by `xxd test/edge_cases/p7/.../<case>.wasm` on
// the fixtures committed in sub-3c.

test "runI32Export: memory64 store+load round-trip via i64 idx_type (ADR-0111 D4 e2e)" {
    // D-181 discharge: x86_64 SysV `emitMemOpI64` X-form + wrap-check
    // body is implemented (src/engine/codegen/x86_64/op_memory.zig:306);
    // `usesRuntimePtr` already whitelists all memory load/store ops
    // (src/engine/codegen/x86_64/usage.zig:60). Ungated for Mac aarch64
    // + Linux x86_64 SysV per ADR-0111 D4. Windows skip retained
    // (phase-boundary host).
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (memory i64 1)
    //   (func (export "test") (result i32)
    //     i64.const 0    ;; address (i64-indexed memory takes i64 addr)
    //     i32.const 42   ;; value to store
    //     i32.store offset=0 align=2
    //     i64.const 0    ;; address (load)
    //     i32.load offset=0 align=2))
    //
    // End-to-end verification of the 10.M-1..10.M-4c chain:
    //   parser (memory section i64 flag) → validator (i64 addr type) →
    //   lower (MemArgExtra packed) → codegen (emitMemOpI64 X-form +
    //   wrap-check) → runtime (Runtime.memories[0] populated with
    //   idx_type=.i64). Returns 42 (stored, then loaded).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // \0asm + version
        // type sec: 1 type, () -> i32
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        // func sec: 1 func, type 0
        0x03,
        0x02, 0x01, 0x00,
        // memory sec: 1 mem, flag=0x04 (i64, min only), min=1
        0x05, 0x03, 0x01, 0x04, 0x01,
        // export sec: 1 export, name="test" (len 4), kind=func, idx=0
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74,
        0x00, 0x00,
        // code sec: 1 body, size 14
        //   0x00              locals_count = 0
        //   0x42 0x00         i64.const 0  (addr)
        //   0x41 0x2A         i32.const 42 (value)
        //   0x36 0x02 0x00    i32.store align=2 offset=0
        //   0x42 0x00         i64.const 0  (addr)
        //   0x28 0x02 0x00    i32.load align=2 offset=0
        //   0x0B              end
        0x0a, 0x10, 0x01, 0x0e, 0x00, 0x42,
        0x00, 0x41, 0x2a, 0x36, 0x02, 0x00, 0x42, 0x00,
        0x28, 0x02, 0x00, 0x0b,
    };
    const result = try runI32Export(testing.allocator, &bytes, "test");
    try testing.expectEqual(@as(u32, 42), result);
}

test "runI32Export: trunc_sat_f32_s/pos_inf returns INT32_MAX" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
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
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
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
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
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
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
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

test "runI32Export: simple i32.const probe on all hosts (sanity)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module (func (export "test") (result i32) (i32.const 42)))
    // Simplest possible runI32Export fixture — verifies the basic
    // entry-shim + JIT pipeline works on the current host
    // independent of any EH machinery.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
        0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74,
        0x65, 0x73, 0x74, 0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 42), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: direct return_call tail-call returns 42 end-to-end (10.TC-JIT / D-205)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (func $test (export "test") (result i32) (return_call $answer))
    //   (func $answer (result i32) (i32.const 42)))
    //
    // Exercises the full parse→validate→JIT-compile→execute pipeline
    // for `return_call` (Wasm 3.0 §3.3.8.18). The arm64 emit
    // (emit.zig .return_call → op_tail_call.emitDirectReturnCall) and
    // the B/JMP fixup are linker-tested in isolation
    // (shared/linker.zig); this is the first runI32Export-level
    // assertion that the same-module direct tail-call reaches the
    // callee body and returns its result. D-205 discharge anchor.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x09, 0x02, 0x60, 0x00, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f, // type: 2× () -> i32
        0x03, 0x03, 0x02, 0x00, 0x01, // func: func0→type0, func1→type1
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, // export "test" → func0
        0x0a, 0x0b, 0x02, 0x04, 0x00, 0x12, 0x01, 0x0b, 0x04, 0x00, 0x41, 0x2a, 0x0b, // code: fn0 return_call 1; fn1 i32.const 42
    };
    try testing.expectEqual(@as(u32, 42), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: return_call_indirect through table[0] returns 99 end-to-end (10.TC-JIT / D-205)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (type $sig (func (result i32)))
    //   (table 1 funcref)
    //   (elem (i32.const 0) $worker)
    //   (func $worker (type $sig) (i32.const 99))
    //   (func $test (export "test") (result i32)
    //     (i32.const 0) (return_call_indirect (type $sig))))
    //
    // Exercises the indirect tail-call JIT path end-to-end
    // (emit.zig .return_call_indirect → op_tail_call.emitIndirectReturnCall:
    // bounds-check + sig-check + funcptr→X16 + frame_teardown + BR X16,
    // table-0/≤2-results fast path). Companion to the direct
    // return_call e2e test; both now reach the callee body after the
    // liveness terminator-class fix. Wasm spec 3.0 §3.3.8.19.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> i32
        0x03, 0x03, 0x02, 0x00, 0x00, // func: worker→type0, test→type0
        0x04, 0x04, 0x01, 0x70, 0x00, 0x01, // table: 1 funcref
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, // export "test" → func1
        0x09, 0x07, 0x01, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00, // elem: table[0] = func0 (payload 7 bytes)
        0x0a, 0x0f, 0x02, 0x05, 0x00, 0x41, 0xe3, 0x00, 0x0b, 0x07, 0x00, 0x41, 0x00, 0x13, 0x00, 0x00, 0x0b, // code: fn0 i32.const 99 (LEB 0xe3 0x00); fn1 i32.const 0; return_call_indirect type0 table0
    };
    try testing.expectEqual(@as(u32, 99), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: tail-recursive return_call with args sums to 15 (10.TC-JIT / D-205 clang_musttail shape)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (func $sum (param $n i32) (param $acc i32) (result i32)
    //     (if (i32.eqz (local.get $n)) (then (return (local.get $acc))))
    //     (return_call $sum
    //       (i32.sub (local.get $n) (i32.const 1))
    //       (i32.add (local.get $acc) (local.get $n))))
    //   (func $test (export "test") (result i32)
    //     (return_call $sum (i32.const 5) (i32.const 0))))
    //
    // The actual D-205 trigger SHAPE: direct return_call WITH non-empty
    // args + self-recursion (clang __attribute__((musttail))). IT-2/3
    // used zero args (marshalCallArgs no-op); this exercises arg
    // marshalling (X1/X2 per AAPCS64) AND frame REUSE across 6 tail-recursive
    // levels — proper tail-call must not grow the native stack.
    // sum(5,0) → 5+4+3+2+1 = 15. Wasm spec 3.0 §3.3.8.18.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x0b, 0x02, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f, // type0 (i32,i32)->i32, type1 ()->i32
        0x03, 0x03, 0x02, 0x00, 0x01, // func: sum→type0, test→type1
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, // export "test" → func1
        0x0a, 0x22, 0x02, // code: 2 bodies, payload 0x22
        // body0 $sum (size 0x17): if(eqz n) return acc; return_call sum(n-1, acc+n)
        0x17, 0x00, 0x20,
        0x00, 0x45, 0x04,
        0x40, 0x20, 0x01,
        0x0f, 0x0b, 0x20,
        0x00, 0x41, 0x01,
        0x6b, 0x20, 0x01,
        0x20, 0x00, 0x6a,
        0x12, 0x00, 0x0b,
        // body1 $test (size 0x08): return_call sum(5, 0)
        0x08, 0x00, 0x41,
        0x05, 0x41, 0x00,
        0x12, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 15), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: call_ref through a funcref returns 42 end-to-end (10.R-call_ref-JIT / D-186)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // arm64 (manual switch in emit.zig) + x86_64 (collected per-op
    // dispatch_collector_ops.zig) both emit call_ref as of 10.R-call_ref-JIT IT-2.
    // (module
    //   (type $sig (func (param i32) (result i32)))
    //   (func $double (export "double") (type $sig) local.get 0 i32.const 2 i32.mul)
    //   (func $test (export "test") (result i32)
    //     i32.const 21 (ref.func $double) (call_ref $sig)))
    //
    // First JIT call_ref: ref.func pushes @intFromPtr(&func_entities[0])
    // (a *FuncEntity, already JIT-emitted); call_ref pops it, null-checks,
    // loads the funcptr from the FuncEntity (funcentity_funcptr_offset),
    // and BLRs. $double(21) = 42. ($double exported so ref.func 0 is in
    // the ref-able set per spec.) Wasm spec 3.0 §3.3.8.13 (call_ref).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x0a, 0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x00, 0x01, 0x7f, // type0 (i32)->i32, type1 ()->i32
        0x03, 0x03, 0x02, 0x00, 0x01, // func: double→type0, test→type1
        0x07, 0x11, 0x02, 0x06, 0x64, 0x6f, 0x75, 0x62, 0x6c, 0x65, 0x00, 0x00, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, // export "double"→f0, "test"→f1
        0x0a, 0x12, 0x02, 0x07, 0x00, 0x20, 0x00, 0x41, 0x02, 0x6c, 0x0b, 0x08, 0x00, 0x41, 0x15, 0xd2, 0x00, 0x14, 0x00, 0x0b, // code: double=local.get0*2; test=21 ref.func0 call_ref0
    };
    try testing.expectEqual(@as(u32, 42), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: return_call_ref tail-call through a funcref returns 42 (10.R / D-206)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // arm64 (manual switch in emit.zig) + x86_64 (collected per-op in
    // dispatch_collector_ops.zig) both emit return_call_ref as of cyc207.
    // (module
    //   (type $sig (func (result i32)))
    //   (func $worker (export "worker") (type $sig) (i32.const 42))
    //   (func $test (export "test") (result i32)
    //     ref.func $worker return_call_ref $sig))
    //
    // Tail-call variant of call_ref: ref.func pushes *FuncEntity;
    // return_call_ref pops it, null-checks, derefs funcentity_funcptr_offset,
    // tears down the caller frame, BRs to $worker (no return here). $worker → 42.
    // Wasm spec 3.0 §3.3.8.20.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type0 () -> i32
        0x03, 0x03, 0x02, 0x00, 0x00, // func: worker→type0, test→type0
        0x07, 0x11, 0x02, 0x06, 0x77, 0x6f, 0x72, 0x6b, 0x65, 0x72, 0x00, 0x00, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x01, // export "worker"→f0, "test"→f1
        0x0a, 0x0d, 0x02, 0x04, 0x00, 0x41, 0x2a, 0x0b, 0x06, 0x00, 0xd2, 0x00, 0x15, 0x00, 0x0b, // code: worker=i32.const42; test=ref.func0 return_call_ref0
    };
    try testing.expectEqual(@as(u32, 42), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: call_ref of a null funcref traps (10.R / D-207 null-trap)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // arm64 traps correctly; x86_64 returns 0 instead of trapping (D-208 —
    // funcref null-check miscompile). Gate to aarch64 until D-208 resolved.
    if (builtin.cpu.arch != .aarch64) return skip.blocker(.@"D-208");
    // (module (type $sig (func (result i32)))
    //   (func $test (export "test") (result i32) ref.null $sig call_ref $sig))
    //
    // Exercises the call_ref null-check (arm64 CMP X17,#0;B.EQ — x86_64 OR r,r;JZ —
    // → shared bounds trap stub). ref.null $sig = 0xd0 + sleb heaptype 0. Wasm
    // spec §4.4.8.13: call_ref of a null reference traps.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type0 () -> i32
        0x03, 0x02, 0x01, 0x00, // func: test→type0
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, // export "test" → func0
        0x0a, 0x08, 0x01, 0x06, 0x00, 0xd0, 0x00, 0x14, 0x00, 0x0b, // code: ref.null 0; call_ref 0
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: return_call_ref of a null funcref traps (10.R/10.TC / D-207 null-trap)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // arm64 traps correctly; x86_64 returns 0 (D-208 funcref null-check
    // miscompile). Gate to aarch64 until D-208 resolved.
    if (builtin.cpu.arch != .aarch64) return skip.blocker(.@"D-208");
    // Same as the call_ref null-trap but the tail-call variant
    // (return_call_ref = 0x15). The null-check fires before frame teardown.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type0 () -> i32
        0x03, 0x02, 0x01, 0x00, // func: test→type0
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00, // export "test" → func0
        0x0a, 0x08, 0x01, 0x06, 0x00, 0xd0, 0x00, 0x15, 0x00, 0x0b, // code: ref.null 0; return_call_ref 0
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: throw + catch_all returns 42 (IT-6 cycle 3c-iii-d end-to-end)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (tag $e0)
    //   (func (export "test") (result i32)
    //     (block $catch
    //       (try_table (catch_all $catch)
    //         (throw $e0))
    //       (return (i32.const 99)))
    //     (i32.const 42)))
    //
    // Acceptance per Phase 10 EH integration plan §IT-6:
    //   end-to-end `throw 0` catches via `try_table catch_all 0`,
    //   lands at the catch_all block, returns normally with the
    //   "caught" sentinel 42 (not the "fallthrough" 99 and not a
    //   trap).
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
        0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x0d, 0x03,
        0x01, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00,
        0x00, 0x0a, 0x15, 0x01, 0x13, 0x00, 0x02, 0x40, 0x1f, 0x40, 0x01, 0x02,
        0x00, 0x08, 0x00, 0x0b, 0x41, 0xe3, 0x00, 0x0f, 0x0b, 0x41, 0x2a, 0x0b,
    };
    try testing.expectEqual(@as(u32, 42), try runI32Export(testing.allocator, &bytes, "test"));

    // Companion check: same shape WITHOUT the catch_all clause →
    // throw propagates uncaught → trap (verifies the dispatch
    // pipeline distinguishes the two cases, not just that
    // landing_pad happens to land at i32.const 42 unconditionally).
    const uncaught_bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
        0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x0d, 0x03,
        0x01, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00,
        0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x08, 0x00, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &uncaught_bytes, "test"));
}

test "runI32Export: tagged catch routes by tag_idx — throw $e1 → catch $e1 returns 77" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (tag $e0) (tag $e1)
    //   (func (export "test") (result i32)
    //     (block $catch_e1
    //       (block $catch_e0
    //         (try_table (catch $e0 $catch_e0) (catch $e1 $catch_e1)
    //           (throw $e1))
    //         unreachable)
    //       unreachable)
    //     (i32.const 77)))
    //
    // Exercises op_throw's tag_idx marshal: throws tag 1; the
    // unwinder must match the SECOND HandlerEntry (catch $e1 → 1),
    // NOT the first (catch $e0 → 0). Without the marshal, the
    // throw site delivers garbage `tag_idx`, and the dispatcher's
    // match would be undefined — likely hitting catch_e0 (= trap
    // via unreachable between $catch_e0 and $catch_e1) or
    // mis-matching entirely. With the marshal, tag 1 hits the
    // SECOND entry → branch to $catch_e1 → fall through to
    // `(i32.const 77)` → return 77.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
        0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x0d, 0x05,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73,
        0x74, 0x00, 0x00, 0x0a, 0x1b, 0x01, 0x19, 0x00, 0x02, 0x40, 0x02, 0x40,
        0x1f, 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x08, 0x01, 0x0b,
        0x00, 0x0b, 0x00, 0x0b, 0x41, 0xcd, 0x00, 0x0b,
    };
    try testing.expectEqual(@as(u32, 77), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: cross-frame throw — callee throws, caller's try_table catches (D-183)" {
    // D-184 closed — x86_64 prologue-aware sniffed loadFrame in
    // frame_chain.loadFrameSniffed disambiguates the saved-RBP
    // vs saved-R15 slot via CodeMap lookup. Test ungated for
    // Mac aarch64 + Linux x86_64 SysV; windows = phase-boundary
    // gate per ADR-0067.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (tag $e0)
    //   (func $callee (throw $e0))
    //   (func (export "test") (result i32)
    //     (block $catch
    //       (try_table (catch_all $catch)
    //         call $callee)
    //       (return (i32.const 99)))
    //     (i32.const 42)))
    //
    // D-183 discharge: the dispatcher's initial_pc + the
    // unwinder's caller_pc are now both module-relative (=
    // `absolute_pc - block_addr`), matching the module-relative
    // pc_start/pc_end stored by `collectModuleTable`. Prior to
    // the fix, dispatch returned function-relative PCs which
    // happened to equal module-relative only for the first
    // defined function — multi-function modules fell through to
    // `.uncaught` because the caller's pc range was offset by
    // the preceding function(s)'s byte length.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
        0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x03, 0x02, 0x00, 0x01, 0x0d,
        0x03, 0x01, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74,
        0x00, 0x01, 0x0a, 0x1a, 0x02, 0x04, 0x00, 0x08, 0x00, 0x0b, 0x13, 0x00,
        0x02, 0x40, 0x1f, 0x40, 0x01, 0x02, 0x00, 0x10, 0x00, 0x0b, 0x41, 0xe3,
        0x00, 0x0f, 0x0b, 0x41, 0x2a, 0x0b,
    };
    try testing.expectEqual(@as(u32, 42), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: multi-catch try_table — tag-correct clause's prelude pushes payload (D-182 per-clause)" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (type $t (func (param i32)))
    //   (tag $e0 (type $t))
    //   (tag $e1 (type $t))
    //   (func (export "test") (result i32)
    //     (block $catch (result i32)
    //       (try_table (catch $e0 $catch) (catch $e1 $catch)
    //         i32.const 88
    //         throw $e1)
    //       i32.const 99)))
    //
    // Exercises the per-clause prelude path in D-182's
    // landing_pad_fixups patch site: BOTH catches target the
    // same outer label ($catch) and BOTH have N=1 payload
    // counts, so each clause needs its own prelude emitting
    // a load-from-eh_payload_buf into the block-result vreg.
    // The dispatcher's `entry.tag_idx` lookup picks catch $e1
    // → its prelude fires → pushes 88 → block returns 88.
    //
    // If the per-clause-prelude path were broken (e.g.,
    // matching both fixups to the same landing_pad_pc),
    // the dispatcher could land at the wrong clause and
    // the regression would surface as 0 or 99.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
        0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x0d,
        0x05, 0x02, 0x00, 0x00, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65,
        0x73, 0x74, 0x00, 0x00, 0x0a, 0x19, 0x01, 0x17, 0x00, 0x02, 0x7f, 0x1f,
        0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x41, 0xd8, 0x00, 0x08,
        0x01, 0x0b, 0x41, 0xe3, 0x00, 0x0b, 0x0b,
    };
    try testing.expectEqual(@as(u32, 88), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: cross-frame throw with i32 payload — propagates via eh_payload_buf across frames" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (type $t0 (func (param i32)))
    //   (tag $e0 (type $t0))
    //   (func $callee
    //     i32.const 55
    //     throw $e0)
    //   (func (export "test") (result i32)
    //     (block $catch (result i32)
    //       (try_table (catch $e0 $catch)
    //         call $callee)
    //       i32.const 99)))
    //
    // Validates that `eh_payload_buf` (per-Runtime, NOT
    // stack-allocated) survives the cross-frame FP-walk. callee
    // throws with payload 55; the buffer is written at the
    // throw site (in callee). The walker traverses to test's
    // frame, matches catch_$e0, loads the payload from the same
    // buffer (still 55 — no other writes intervened), pushes
    // 55 into the block-result vreg. Returns 55.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0c, 0x03, 0x60,
        0x01, 0x7f, 0x00, 0x60, 0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x03,
        0x02, 0x01, 0x02, 0x0d, 0x03, 0x01, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04,
        0x74, 0x65, 0x73, 0x74, 0x00, 0x01, 0x0a, 0x1a, 0x02, 0x06, 0x00, 0x41,
        0x37, 0x08, 0x00, 0x0b, 0x11, 0x00, 0x02, 0x7f, 0x1f, 0x40, 0x01, 0x00,
        0x00, 0x00, 0x10, 0x00, 0x0b, 0x41, 0xe3, 0x00, 0x0b, 0x0b,
    };
    try testing.expectEqual(@as(u32, 55), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: 2-level cross-frame throw — inner→mid→test catches via outermost try_table" {
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (tag $e0)
    //   (func $inner (throw $e0))
    //   (func $mid (call $inner))
    //   (func (export "test") (result i32)
    //     (block $catch
    //       (try_table (catch_all $catch)
    //         call $mid)
    //       (return (i32.const 99)))
    //     (i32.const 77)))
    //
    // Exercises the FP-walk unwinder traversing 2 frames
    // (inner → mid → test). Verifies the sniffed loadFrame
    // (D-184) handles repeated walk-step disambiguation —
    // each frame has uses_runtime_ptr=true (every function
    // either throws, calls, or has try_table), so each frame's
    // [RBP, 0] holds saved R15 (rt ptr value), not saved RBP.
    // The CodeMap-aware sniff per frame finds the correct
    // saved-RBP slot each iteration.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x60,
        0x00, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x04, 0x03, 0x00, 0x00, 0x01,
        0x0d, 0x03, 0x01, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73,
        0x74, 0x00, 0x02, 0x0a, 0x20, 0x03, 0x04, 0x00, 0x08, 0x00, 0x0b, 0x04,
        0x00, 0x10, 0x00, 0x0b, 0x14, 0x00, 0x02, 0x40, 0x1f, 0x40, 0x01, 0x02,
        0x00, 0x10, 0x01, 0x0b, 0x41, 0xe3, 0x00, 0x0f, 0x0b, 0x41, 0xcd, 0x00,
        0x0b,
    };
    try testing.expectEqual(@as(u32, 77), try runI32Export(testing.allocator, &bytes, "test"));
}

test "runI32Export: throw + catch_ with i32 payload returns 88 (10.E-payload-prop bundle close)" {
    // D-182 discharge — bundle 10.E-payload-prop closed on both
    // arches. Throw side: throw.emit pops N values + stores at
    // eh_payload_buf. Catch side: emit.zig (arm64 + x86_64) at
    // the catch-label end-op-patch site emits per-clause prelude
    // loading eh_payload_buf[i] into the block-result vreg slot
    // (via gprDefSpilled + gprStoreSpilled) + JMP-to-common
    // continuation. windowsmini = phase-boundary per ADR-0067.
    if (builtin.os.tag == .windows) return skip.phaseEnd(.win64);
    // (module
    //   (type $t0 (func (param i32)))
    //   (tag $e0 (type $t0))
    //   (func (export "test") (result i32)
    //     (block $catch (result i32)
    //       (try_table (catch $e0 $catch)
    //         i32.const 88
    //         throw $e0
    //       )
    //       i32.const 99
    //     )))
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x09, 0x02, 0x60,
        0x01, 0x7f, 0x00, 0x60, 0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x01, 0x0d,
        0x03, 0x01, 0x00, 0x00, 0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74,
        0x00, 0x00, 0x0a, 0x16, 0x01, 0x14, 0x00, 0x02, 0x7f, 0x1f, 0x40, 0x01,
        0x00, 0x00, 0x00, 0x41, 0xd8, 0x00, 0x08, 0x00, 0x0b, 0x41, 0xe3, 0x00,
        0x0b, 0x0b,
    };
    try testing.expectEqual(@as(u32, 88), try runI32Export(testing.allocator, &bytes, "test"));
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

test "compileWasm: tag_param_counts populated from tag section + types (10.E-N-3)" {
    // type(1): [(i32) -> ()]  — typeidx=0 has 1 param.
    // tag(13): [tag attr=0 typeidx=0]  — tag 0 references typeidx 0.
    // Expected: compiled.tag_param_counts = [1].
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: count=1; functype: 0x60, params=[i32], results=[]
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7F, 0x00,
        // tag section (id 13): count=1; tag: attr=0x00, typeidx=0
        0x0D,
        0x03, 0x01, 0x00, 0x00,
    };
    var compiled = try compileWasm(testing.allocator, &bytes);
    defer compiled.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), compiled.tag_param_counts.len);
    try testing.expectEqual(@as(u32, 1), compiled.tag_param_counts[0]);
}

test "compileWasm: tag_param_counts empty when no tag section (10.E-N-3)" {
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var compiled = try compileWasm(testing.allocator, &bytes);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), compiled.tag_param_counts.len);
}

test "compileWasm: multiple tags with mixed-arity types (10.E-N-3)" {
    // type 0: () -> ()         (0 params)
    // type 1: (i32 i64) -> ()  (2 params)
    // tag 0 → type 0; tag 1 → type 1; tag 2 → type 0.
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        // type section: count=2
        0x01, 0x09, 0x02,
        0x60, 0x00, 0x00, // type 0: 0 params, 0 results
        0x60, 0x02, 0x7F, 0x7E, 0x00, // type 1: i32+i64 params, 0 results
        // tag section: count=3; (0,0), (0,1), (0,0)
        0x0D, 0x07, 0x03, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00,
    };
    var compiled = try compileWasm(testing.allocator, &bytes);
    defer compiled.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), compiled.tag_param_counts.len);
    try testing.expectEqual(@as(u32, 0), compiled.tag_param_counts[0]);
    try testing.expectEqual(@as(u32, 2), compiled.tag_param_counts[1]);
    try testing.expectEqual(@as(u32, 0), compiled.tag_param_counts[2]);
}
