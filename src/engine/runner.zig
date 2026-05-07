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

pub const Error = error{
    /// Reserved for future "import shape we cannot represent at all"
    /// failure (e.g. memory64 / shared imports beyond MVP). The
    /// chunk-b "every import call traps unconditionally" foundation
    /// does NOT raise this — function imports are accepted, indexed
    /// into the wasm-space func table, and emit a trap-stub branch
    /// at every call site.
    UnsupportedImports,
    MissingTypeSection,
    MissingFunctionSection,
    MissingCodeSection,
    ExportNotFound,
    ExportIsNotFunction,
    UnsupportedEntrySignature,
} || compile_func.Error || parser.Error || sections.Error || linker.Error || entry.Error || validator_mod.Error;

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
    /// Number of function imports. The first `num_imports` entries
    /// of `func_sigs` correspond to imports (no body compiled);
    /// `func_results` covers only the defined functions and is
    /// indexed by `defined_idx = wasm_idx - num_imports`.
    num_imports: u32,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CompiledWasm, allocator: Allocator) void {
        for (self.func_results) |*r| compile_func.deinitFuncResult(allocator, r);
        allocator.free(self.func_results);
        allocator.free(self.func_sigs);
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

    // Per Wasm spec: type / function / code sections are all
    // OPTIONAL — a module with no defined functions is valid
    // (just header + optional non-function sections). Bail out
    // early with an empty CompiledWasm in that case rather than
    // demanding a type section. (A module may have imports but no
    // defined functions; that case also returns an empty
    // JitModule — call-by-export to an import-only function is
    // unreachable from JIT-compiled code today.)
    const func_section_opt = module.find(.function);
    if (func_section_opt == null) {
        const empty_results = try allocator.alloc(compile_func.FuncResult, 0);
        // Build func_sigs from import-only function entries (if any)
        // so `findExportFunc` → wasm-space idx → func_sigs[idx]
        // resolution remains valid for export-import re-exports.
        var sig_count: u32 = 0;
        if (imports_buf) |ib| {
            for (ib.items) |imp| {
                if (imp.kind == .func) sig_count += 1;
            }
        }
        const empty_module = try linker.link(allocator, &.{}, sig_count);
        const sigs = try allocator.alloc(FuncType, sig_count);
        if (imports_buf) |ib| {
            // Need a type section to resolve func imports' typeidx.
            if (sig_count > 0) {
                const type_section = module.find(.@"type") orelse return Error.MissingTypeSection;
                var types = try sections.decodeTypes(a, type_section.body);
                defer types.deinit();
                var w: u32 = 0;
                for (ib.items) |imp| {
                    if (imp.kind != .func) continue;
                    const tidx = imp.payload.func_typeidx;
                    if (tidx >= types.items.len) {
                        allocator.free(sigs);
                        return Error.MissingTypeSection;
                    }
                    sigs[w] = types.items[tidx];
                    w += 1;
                }
            }
        }
        return .{
            .module = empty_module,
            .func_results = empty_results,
            .func_sigs = sigs,
            .num_imports = sig_count,
            .arena = arena,
        };
    }

    const type_section = module.find(.@"type") orelse return Error.MissingTypeSection;
    var types = try sections.decodeTypes(a, type_section.body);
    defer types.deinit();

    const defined_func_typeidx = try sections.decodeFunctions(a, func_section_opt.?.body);

    const code_section = module.find(.code) orelse return Error.MissingCodeSection;
    var codes = try sections.decodeCodes(a, code_section.body);
    defer codes.deinit();

    if (codes.items.len != defined_func_typeidx.len) return Error.MissingCodeSection;

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
    if (imports_buf) |ib| {
        var w: u32 = 0;
        for (ib.items) |imp| {
            if (imp.kind != .func) continue;
            const tidx = imp.payload.func_typeidx;
            if (tidx >= types.items.len) return Error.MissingTypeSection;
            func_sigs[w] = types.items[tidx];
            w += 1;
        }
    }
    for (defined_func_typeidx, 0..) |type_idx, i| {
        if (type_idx >= types.items.len) return Error.MissingTypeSection;
        func_sigs[num_imports + i] = types.items[type_idx];
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

    const validator_globals = try a.alloc(validator_mod.GlobalEntry, if (globals_buf) |g| g.items.len else 0);
    if (globals_buf) |g| {
        for (g.items, 0..) |gd, gi| {
            validator_globals[gi] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
        }
    }
    const validator_tables: []const zir.TableEntry = if (tables_buf) |t| t.items else &.{};
    const validator_data_count: u32 = if (datas_buf) |d| @intCast(d.items.len) else 0;
    const validator_elem_count: u32 = if (elems_buf) |e| @intCast(e.items.len) else 0;

    // Compile each defined function. On failure, log the
    // offending func_idx to stderr — the spec-jit-compile runner
    // captures this via `2>&1 > /tmp/<host>.log` so root-cause
    // bisection (which fixture, which function) is visible
    // without re-running the gate.
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
        validator_mod.validateFunction(
            sig,
            code.locals,
            code.body,
            func_sigs,
            validator_globals,
            types.items,
            validator_data_count,
            validator_tables,
            validator_elem_count,
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
        .num_imports = num_imports,
        .arena = arena,
    };
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
/// result value. Today's runner builds a no-memory, no-table
/// JitRuntime — fixtures that touch memory/tables need a richer
/// runtime construction (sub-7.5b-iii).
pub fn runI32Export(
    allocator: Allocator,
    wasm_bytes: []const u8,
    export_name: []const u8,
) Error!u32 {
    const func_idx = try findExportFunc(allocator, wasm_bytes, export_name);

    var compiled = try compileWasm(allocator, wasm_bytes);
    defer compiled.deinit(allocator);

    if (func_idx >= compiled.func_sigs.len) return Error.ExportNotFound;
    // Re-exporting an imported function is rejected from this
    // shim — the JitModule only has bodies for defined functions;
    // the entry pointer for an import sentinel slot is a 0xFFFF
    // sentinel, not callable. Fixtures wanting to call an imported
    // export need the chunk 7.9-c host-call dispatcher.
    if (func_idx < compiled.num_imports) return Error.UnsupportedEntrySignature;
    const sig = compiled.func_sigs[func_idx];
    if (sig.params.len != 0 or sig.results.len != 1 or sig.results[0] != .i32) {
        return Error.UnsupportedEntrySignature;
    }

    // Allocate + populate host_dispatch table. Each import-call
    // site emits an indirect call through
    // `host_dispatch_base[idx]`. Default-fill with the trap
    // trampoline, then overlay real WASI handlers for any
    // imports whose `(module, name)` matches the snapshot-
    // preview1 manifest in `wasi/jit_dispatch.zig`. Imports
    // outside the manifest stay pointed at the trap (the host
    // hasn't supplied that capability).
    const dispatch = try allocator.alloc(usize, compiled.num_imports);
    defer allocator.free(dispatch);
    for (dispatch) |*slot| slot.* = @intFromPtr(&hostDispatchTrap);

    // Memory + data init (chunk 7.9-d-3, closes D-031). When the
    // module declares a memory section, allocate
    // `memories[0].min * 65536` bytes and copy each active data
    // segment to its computed offset. Combined with d-2's WASI
    // dispatch this lets fixtures that touch linear memory run
    // end-to-end — fd_write iov walks, args/environ writes, etc.
    var memory_slice: []u8 = &.{};
    defer if (memory_slice.len > 0) allocator.free(memory_slice);

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
            // Cap at 256 MiB to avoid runaway tests; realworld
            // fixtures with larger declared memory surface as
            // UnsupportedEntrySignature for the d-3 runner.
            if (total_bytes > 256 * 1024 * 1024) {
                return Error.UnsupportedEntrySignature;
            }
            memory_slice = try allocator.alloc(u8, @intCast(total_bytes));
            @memset(memory_slice, 0);
        }
    }

    if (module.find(.data)) |s| {
        var datas = try sections.decodeData(ta, s.body);
        defer datas.deinit();
        for (datas.items) |seg| {
            if (seg.kind != .active) continue;
            const off = evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const off_u: u64 = @intCast(off);
            if (off_u + seg.bytes.len > memory_slice.len) {
                return Error.UnsupportedEntrySignature;
            }
            @memcpy(memory_slice[@intCast(off_u)..][0..seg.bytes.len], seg.bytes);
        }
    }

    var rt: entry.JitRuntime = .{
        .vm_base = if (memory_slice.len > 0) memory_slice.ptr else @ptrFromInt(@as(usize, 0x1000)),
        .mem_limit = memory_slice.len,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
        .host_dispatch_base = dispatch.ptr,
        .host_dispatch_count = compiled.num_imports,
    };
    return entry.callI32NoArgs(compiled.module, func_idx, &rt);
}

/// Evaluate a Wasm const-expression that resolves to an i32.
/// Active data-segment offsets reach this path; v0.1.0's only
/// supported shape is `i32.const N; end` (3+ bytes: opcode 0x41,
/// sleb128 N, opcode 0x0B). Mirrors the shape in
/// `runtime/instance/instantiate.zig:evalConstI32Expr` but stays
/// JIT-runner-local to avoid pulling instance/ into engine/.
fn evalConstI32Expr(expr: []const u8) !i32 {
    if (expr.len < 2 or expr[0] != 0x41) return error.UnsupportedConstExpr;
    var pos: usize = 1;
    const v = try leb128.readSleb128(i32, expr, &pos);
    if (pos >= expr.len or expr[pos] != 0x0B) return error.UnsupportedConstExpr;
    return v;
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
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
        0x0a, 0x0b, 0x01, 0x09, 0x00,
        0x43, 0x00, 0x00, 0x80, 0x7f, 0xfc, 0x00, 0x0b,
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
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
        0x0a, 0x0b, 0x01, 0x09, 0x00,
        0x43, 0x00, 0x00, 0xc0, 0x7f, 0xfc, 0x00, 0x0b,
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
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
        0x0a, 0x0b, 0x01, 0x09, 0x00,
        0x43, 0x00, 0x00, 0x80, 0xff, 0xfc, 0x00, 0x0b,
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
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
        0x03, 0x02, 0x01, 0x00,
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
        0x0a, 0x0a, 0x01, 0x08, 0x00,
        0x43, 0x00, 0x00, 0xc0, 0x7f, 0xa8, 0x0b,
    };
    try testing.expectError(entry.Error.Trap, runI32Export(testing.allocator, &bytes, "test"));
}

test "compileWasm: empty module (header only) compiles to empty CompiledWasm" {
    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        return error.SkipZigTest;
    }
    // Bare module header — magic + version, no sections at all.
    // Per Wasm spec this is a valid empty module.
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    var compiled = try compileWasm(testing.allocator, &bytes);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), compiled.func_sigs.len);
    try testing.expectEqual(@as(usize, 0), compiled.func_results.len);
}
