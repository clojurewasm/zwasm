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
        const typeidxs = try allocator.alloc(u32, sig_count);
        const empty_global_offsets = try allocator.alloc(u32, 0);
        const empty_global_valtypes = try allocator.alloc(zir.ValType, 0);
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
                    if (tidx >= types.items.len) {
                        allocator.free(sigs);
                        allocator.free(typeidxs);
                        return Error.MissingTypeSection;
                    }
                    sigs[w] = types.items[tidx];
                    typeidxs[w] = tidx;
                    w += 1;
                }
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
            globals_offsets,
            globals_valtypes,
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
                const bytes = try evalConstV128Expr(gd.init_expr);
                @memcpy(globals_buf[off..][0..16], &bytes);
            },
            .i32, .i64, .f32, .f64, .funcref, .externref => {
                if (off + 8 > globals_buf.len) return Error.UnsupportedEntrySignature;
                const raw = try evalConstScalarRaw(gd.init_expr);
                std.mem.writeInt(u64, globals_buf[off..][0..8], raw, .little);
            },
        }
    }
}

/// Decode a single scalar `*.const` (i32/i64/f32/f64) or
/// `ref.null` init-expression and return its 8-byte raw bit
/// pattern (little-endian). Mirrors
/// `runtime/instance/instantiate.zig:evalConstExprValue` but
/// stays in this module so the engine layer can run const-expr
/// evaluation without crossing into the runtime-instance Zone.
fn evalConstScalarRaw(expr: []const u8) Error!u64 {
    if (expr.len < 2) return Error.UnsupportedEntrySignature;
    var pos: usize = 1;
    const v: u64 = switch (expr[0]) {
        0x41 => blk: { // i32.const
            const n = leb128.readSleb128(i32, expr, &pos) catch return Error.UnsupportedEntrySignature;
            const u: u32 = @bitCast(n);
            break :blk @as(u64, u);
        },
        0x42 => blk: { // i64.const
            const n = leb128.readSleb128(i64, expr, &pos) catch return Error.UnsupportedEntrySignature;
            break :blk @bitCast(n);
        },
        0x43 => blk: { // f32.const
            if (pos + 4 > expr.len) return Error.UnsupportedEntrySignature;
            const bits = std.mem.readInt(u32, expr[pos..][0..4], .little);
            pos += 4;
            break :blk @as(u64, bits);
        },
        0x44 => blk: { // f64.const
            if (pos + 8 > expr.len) return Error.UnsupportedEntrySignature;
            const bits = std.mem.readInt(u64, expr[pos..][0..8], .little);
            pos += 8;
            break :blk bits;
        },
        0xD0 => blk: { // ref.null reftype
            if (pos >= expr.len) return Error.UnsupportedEntrySignature;
            pos += 1;
            break :blk 0;
        },
        else => return Error.UnsupportedEntrySignature,
    };
    if (pos >= expr.len or expr[pos] != 0x0B) return Error.UnsupportedEntrySignature;
    return v;
}

/// Decode a `v128.const` (0xFD 0x0C) terminated init-expression
/// and return the 16-byte little-endian-encoded constant.
fn evalConstV128Expr(expr: []const u8) Error!([16]u8) {
    // (v128.const v128) (end) — 0xFD 0x0C <16 bytes> 0x0B
    if (expr.len < 2 + 16 + 1) return Error.UnsupportedEntrySignature;
    if (expr[0] != 0xFD or expr[1] != 0x0C) return Error.UnsupportedEntrySignature;
    if (expr[18] != 0x0B) return Error.UnsupportedEntrySignature;
    var out: [16]u8 = undefined;
    @memcpy(&out, expr[2..][0..16]);
    return out;
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

    for (elems.items) |seg| {
        if (seg.kind != .active) continue;
        if (seg.tableidx != 0) continue;
        const off = evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
        if (off < 0) return Error.UnsupportedEntrySignature;
        const base: usize = @intCast(off);
        if (base + seg.funcidxs.len > funcptrs_buf.len) return Error.UnsupportedEntrySignature;
        for (seg.funcidxs, 0..) |fidx, i| {
            if (fidx == std.math.maxInt(u32)) continue; // ref.null funcref
            if (fidx >= compiled.func_sigs.len) return Error.UnsupportedEntrySignature;
            const f_off = compiled.module.func_offsets[fidx];
            typeidxs_buf[base + i] = compiled.func_typeidxs[fidx];
            if (f_off == linker.IMPORT_SENTINEL_OFFSET) continue;
            funcptrs_buf[base + i] = @intFromPtr(compiled.module.block.bytes.ptr + f_off);
        }
    }
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
            const off = evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
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

    fn deinit(self: *RuntimeOwned, allocator: Allocator) void {
        if (self.memory.len > 0) allocator.free(self.memory);
        allocator.free(self.dispatch);
        allocator.free(self.globals);
        allocator.free(self.funcptrs);
        allocator.free(self.typeidxs);
        if (self.func_entities.len > 0) allocator.free(self.func_entities);
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
            const off = evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
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
    var table_size: u32 = 0;
    if (module.find(.table)) |s| {
        var tables_buf = try sections.decodeTables(ta, s.body);
        defer tables_buf.deinit();
        if (tables_buf.items.len > 0) {
            table_size = tables_buf.items[0].min;
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

    // Wasm spec §4.5.7 (table.init / element-segment instantiation)
    // — populate the table with funcref entries from the element
    // section. Without this, `call_indirect` loads a NULL funcptr
    // and SEGVs at PC=0 (D-049 root cause). Active segments only;
    // passive / declarative segments live in the runtime element
    // index space, not the table itself, and reach the runtime via
    // `table.init` ops which v0.1.0's JIT path doesn't emit yet.
    if (module.find(.element)) |s| {
        var elems = try sections.decodeElement(ta, s.body);
        defer elems.deinit();
        for (elems.items) |seg| {
            if (seg.kind != .active) continue;
            if (seg.tableidx != 0) continue;
            const off = evalConstI32Expr(seg.offset_expr) catch return Error.UnsupportedEntrySignature;
            if (off < 0) return Error.UnsupportedEntrySignature;
            const base: usize = @intCast(off);
            if (base + seg.funcidxs.len > funcptrs_buf.len) return Error.UnsupportedEntrySignature;
            for (seg.funcidxs, 0..) |fidx, i| {
                if (fidx == std.math.maxInt(u32)) {
                    // ref.null funcref — leave the slot null + sentinel typeidx.
                    continue;
                }
                if (fidx >= compiled.func_sigs.len) return Error.UnsupportedEntrySignature;
                const f_off = compiled.module.func_offsets[fidx];
                typeidxs_buf[base + i] = compiled.func_typeidxs[fidx];
                if (f_off == linker.IMPORT_SENTINEL_OFFSET) {
                    // Imported function in a table — host-call dispatch
                    // through `host_dispatch_base` is required to invoke
                    // it. v0.1.0's JIT call_indirect path doesn't emit
                    // that trampoline; leave funcptr null so an attempt
                    // to call it traps via NULL deref instead of running
                    // arbitrary host code.
                    continue;
                }
                funcptrs_buf[base + i] = @intFromPtr(compiled.module.block.bytes.ptr + f_off);
            }
        }
    }

    // §9.9 / 9.9-m-1b: per-module FuncEntity array for JIT
    // ref.func. Size = total functions (imports + defined).
    // Allocated unconditionally so JIT-emitted ref.func reads
    // a stable, distinct address per funcidx.
    const FuncEntity = @import("../runtime/instance/func.zig").FuncEntity;
    const total_funcs = compiled.func_sigs.len;
    const func_entities = try allocator.alloc(FuncEntity, total_funcs);
    errdefer allocator.free(func_entities);
    // Contents left default — neither field is read by the JIT
    // path; interp uses its own FuncEntity allocation through a
    // full Runtime. (Zig's `alloc` returns uninitialised memory;
    // any reader of `.runtime` / `.func_idx` would be a bug.)
    for (func_entities, 0..) |*fe, i| {
        fe.* = .{ .runtime = undefined, .func_idx = @intCast(i) };
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
        },
        .memory = memory,
        .dispatch = dispatch,
        .globals = globals_buf,
        .funcptrs = funcptrs_buf,
        .typeidxs = typeidxs_buf,
        .func_entities = func_entities,
    };
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
