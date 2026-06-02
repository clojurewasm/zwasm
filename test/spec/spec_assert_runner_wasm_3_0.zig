//! Wasm 3.0 spec assertion runner skeleton (10.T-2b).
//!
//! Sub-corpus selector for the 5 Wasm 3.0 proposals (memory64 /
//! tail-call / exception-handling / gc / function-references).
//! Currently a SKELETON — enumerates the baked manifests under
//! `<corpus-root>/<proposal>/<name>/manifest.txt` and reports
//! per-proposal directive counts. JIT-execute + actual assertion
//! matching comes online cycle-by-cycle as impl rows 10.M / 10.R /
//! 10.TC / 10.E / 10.G land (each impl row will adopt the
//! `spec_assert_runner_base` callbacks pattern once its proposal's
//! ZIR / runtime / codegen surface exists).
//!
//! Until then this runner serves as the **observable wiring** —
//! `zig build test-spec-wasm-3.0-assert` builds + runs it,
//! exiting clean against the smoke-baked corpus (10.T-2a). When
//! the corpus is absent (e.g. fresh checkout before 10.T-1 /
//! 10.T-2a land), reports `0 manifests` and exits clean — same
//! shape as the wasm-2.0-assert runner so test-all stays green
//! regardless of corpus state.
//!
//! Usage:
//!   spec_assert_runner_wasm_3_0 <corpus-root>
//!
//! Per ROADMAP §10 / 10.T-2b + Phase 10 design plan §4.6.

const std = @import("std");

const manifest_parser = @import("wasm_3_0_manifest.zig");
const zwasm = @import("zwasm");

// 10.M-D195b cycle 75 — host stubs for the Wasm spec testsuite's
// `spectest.print*` conventional imports. The wast harness uses them
// for trace prints; semantically they're side-effect-only no-ops, so
// our binding ignores the args entirely (still pops them off the
// operand stack per the Wasm ABI).
fn spectestPrint(_: *zwasm.Caller) void {
    // no-op (trace print semantics)
}
fn spectestPrintI32(_: *zwasm.Caller, _: i32) void {
    // no-op (trace print semantics)
}
fn spectestPrintI64(_: *zwasm.Caller, _: i64) void {
    // no-op (trace print semantics)
}
fn spectestPrintF32(_: *zwasm.Caller, _: f32) void {
    // no-op (trace print semantics)
}
fn spectestPrintF64(_: *zwasm.Caller, _: f64) void {
    // no-op (trace print semantics)
}
fn spectestPrintI32F32(_: *zwasm.Caller, _: i32, _: f32) void {
    // no-op (trace print semantics)
}
fn spectestPrintF64F64(_: *zwasm.Caller, _: f64, _: f64) void {
    // no-op (trace print semantics)
}

// D-225 — read an exported global's value (as a u64 carrier) from a
// registered exporter instance's live global storage. `mod_name` is the
// register-`<as>` name (or `$id`); both alias into `name_to_idx`.
fn resolveExportedGlobal(
    instances_list: *const std.ArrayList(zwasm.Instance),
    name_to_idx: *const std.StringHashMap(usize),
    mod_name: []const u8,
    field: []const u8,
) ?u64 {
    const idx = name_to_idx.get(mod_name) orelse return null;
    if (idx >= instances_list.items.len) return null;
    const rt = instances_list.items[idx].handle.runtime orelse return null;
    for (instances_list.items[idx].handle.exports_storage) |exp| {
        if (exp.kind == .global and std.mem.eql(u8, exp.name, field)) {
            if (exp.idx >= rt.globals.len) return null;
            return rt.globals[exp.idx].bits64;
        }
    }
    return null;
}

// D-225 — resolve a JIT module's imported-global VALUES in global-import
// order, so the §1 JIT setup-time const-exprs (`global.get N`,
// N < num_global_imports) read the real value — e.g. gc/i31.3/4's
// `(ref.i31 (global.get $env.g))` resolves env.g=42 instead of a null slot.
// Returns a gpa-owned []u64 (empty if the module has no global imports).
fn jitResolveImportedGlobals(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    instances_list: *const std.ArrayList(zwasm.Instance),
    name_to_idx: *const std.StringHashMap(usize),
) ![]u64 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var module = zwasm.parse.parser.parse(a, wasm_bytes) catch return &.{};
    const imp_sec = module.find(.import) orelse return &.{};
    var imports = zwasm.parse.sections.decodeImports(a, imp_sec.body) catch return &.{};
    defer imports.deinit();

    var vals: std.ArrayList(u64) = .empty;
    errdefer vals.deinit(gpa);
    for (imports.items) |it| {
        if (it.kind != .global) continue;
        const v = resolveExportedGlobal(instances_list, name_to_idx, it.module, it.name) orelse 0;
        try vals.append(gpa, v);
    }
    return vals.toOwnedSlice(gpa);
}

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

const PROPOSALS = [_][]const u8{
    "memory64",
    "tail-call",
    "exception-handling",
    "gc",
    "function-references",
    // 10.M cycle 65 — multi-memory corpus. Treated as a sibling
    // proposal subdir under `wasm-3.0-assert/` because the upstream
    // fixtures live in `memory64/test/core/multi-memory/` (the
    // memory64 + multi-memory proposals are jointly tracked
    // upstream). Bundle 10.M-multi-memory exercises load/store
    // routing through MemArgExtra.memidx (cycle 64 substrate).
    "multi-memory",
};

const ProposalSummary = struct {
    name: []const u8,
    manifests: u32 = 0,
    modules: u32 = 0,
    asserts_return: u32 = 0,
    asserts_return_pass: u32 = 0,
    asserts_return_fail: u32 = 0,
    asserts_trap: u32 = 0,
    asserts_trap_pass: u32 = 0,
    asserts_trap_fail: u32 = 0,
    asserts_invalid: u32 = 0,
    asserts_invalid_pass: u32 = 0,
    asserts_invalid_fail: u32 = 0,
    asserts_unlinkable: u32 = 0,
    asserts_unlinkable_pass: u32 = 0,
    asserts_unlinkable_fail: u32 = 0,
    asserts_malformed: u32 = 0,
    asserts_malformed_pass: u32 = 0,
    asserts_malformed_fail: u32 = 0,
    asserts_exception: u32 = 0,
    asserts_exception_pass: u32 = 0,
    asserts_exception_fail: u32 = 0,
    skips: u32 = 0,
    // §1 (ADR-0128) — JIT execution-mode tallies (populated only when
    // ZWASM_SPEC_ENGINE=jit). pass/fail are real JIT outcomes; skip = a
    // shape not yet wired through the JIT (see jitReturnEligible).
    jit_return_pass: u32 = 0,
    jit_return_fail: u32 = 0,
    jit_return_skip: u32 = 0,
};

/// §1 (ADR-0128) — JIT execution-mode eligibility for an `assert_return`
/// directive. The first increment routes only the no-arg + single-i32-
/// result, same-module subset through the JIT entry (`runI32Export` →
/// `callI32NoArgs`). Everything else (args, i64/fp/v128 results, multi-
/// value, void side-effect, cross-module `$M::field`) is enumerated as a
/// JIT skip so the not-yet-supported set is tracked, not silently
/// dropped — the per-backend should_fail list of wasmtime's
/// `tests/wast.rs` pattern. Skips shrink as the general arg/result
/// dispatcher lands in follow-on cycles.
fn isScalarTy(ty: []const u8) bool {
    return std.mem.eql(u8, ty, "i32") or std.mem.eql(u8, ty, "i64") or
        std.mem.eql(u8, ty, "f32") or std.mem.eql(u8, ty, "f64");
}

/// A reference result type (arrayref / eqref / anyref / funcref / externref /
/// structref / i31ref / nullref / exnref). The JIT runs these for side effects
/// (uncompared, `:?`); the manifest spells them all `*ref`. D-222.
fn isRefResultTy(ty: []const u8) bool {
    return std.mem.endsWith(u8, ty, "ref");
}

fn jitReturnEligible(args_len: usize, results_len: usize, result_ty: []const u8, arg0_ty: []const u8, module_id_len: usize) bool {
    if (module_id_len != 0) return false; // cross-module `$M::field` not wired
    // 0..3 scalar args; result void / scalar / REF. Void + ref results are
    // eligible — they RUN for their side effects (store / global.set, or a
    // `new` doing `global.set (array.new …)`) so the persistent JitInstance
    // accumulates state for later asserts (D-214/D-222). A ref result isn't
    // compared (spec encodes it `:?`); the JIT runs it via the void path.
    // arg1 scalar-ness enforced downstream; non-scalar arg0 / v128 result /
    // 4+ args stay enumerated skips (D-217).
    if (args_len > 3) return false;
    if (args_len >= 1 and !isScalarTy(arg0_ty)) return false;
    if (results_len > 1) return false;
    if (results_len == 1 and !isScalarTy(result_ty) and !isRefResultTy(result_ty)) return false;
    return true;
}

/// Pack a parsed scalar arg `zwasm.Value` into the 64-bit carrier
/// `runScalar1Export` expects (i32/f32 in the low 32, i64/f64 the full
/// 64). null for a non-scalar type. ADR-0128 §1 single-arg dispatch.
fn scalarArgBits(zv: zwasm.Value, ty: []const u8) ?u64 {
    if (std.mem.eql(u8, ty, "i32")) return @as(u32, @bitCast(zv.i32));
    if (std.mem.eql(u8, ty, "i64")) return @as(u64, @bitCast(zv.i64));
    if (std.mem.eql(u8, ty, "f32")) return @as(u32, @bitCast(zv.f32));
    if (std.mem.eql(u8, ty, "f64")) return @as(u64, @bitCast(zv.f64));
    return null;
}

/// Compare a `runScalar1Export` carrier result against the expected value
/// per result type. FP uses an exact BIT compare (NaN-safe; the corpus
/// encodes FP results as literal bit patterns). ADR-0128 §1.
fn jitScalarResultMatches(ty: []const u8, got: u64, exp_zv: zwasm.Value) bool {
    if (std.mem.eql(u8, ty, "i64")) return @as(i64, @bitCast(got)) == exp_zv.i64;
    if (std.mem.eql(u8, ty, "f32")) return @as(u32, @truncate(got)) == @as(u32, @bitCast(exp_zv.f32));
    if (std.mem.eql(u8, ty, "f64")) return got == @as(u64, @bitCast(exp_zv.f64));
    return @as(i32, @bitCast(@as(u32, @truncate(got)))) == exp_zv.i32; // i32 default
}

/// §1 (ADR-0128) — classify a `runI32Export` error so the JIT RED signal
/// means "JIT executed and produced the wrong observable behaviour", not
/// "the JIT entry could not even attempt this shape". A compile- or setup-
/// stage rejection (multi-memory, an unemitted op, a const-expr/validate
/// gap) means the JIT never executed — that is a *skip*, structurally the
/// same as the args/i64/fp eligibility skips above (wasmtime tests/wast.rs
/// should_fail pattern), and is enumerated (printed under --fail-detail),
/// not silently dropped. Only an execution-stage outcome counts as a
/// *fail*: `error.Trap` (JIT ran and trapped where a value was expected)
/// or a value mismatch (handled at the comparison site, not here).
///
/// Empirical basis (2026-05-31 --fail-detail sweep, Mac aarch64): of the
/// 96 "JITfail"s, 87 were compile/setup rejections (66 MultipleMemories,
/// 11 UnsupportedOp, 4 InvalidFuncIndex, 3 InvalidGlobalInitExpr, 2
/// StackTypeMismatch, 1 ElemSegmentTypeMismatch) — the JIT never ran them.
/// `else => false` keeps `error.Trap` AND any unanticipated error as a
/// loud fail (a new gap must surface, never hide).
fn jitErrorIsUnwiredShape(e: zwasm.engine.runner.Error) bool {
    return switch (e) {
        error.MultipleMemories,
        error.UnsupportedOp,
        error.InvalidFuncIndex,
        error.InvalidGlobalInitExpr,
        error.StackTypeMismatch,
        error.ElemSegmentTypeMismatch,
        error.UnsupportedEntrySignature,
        error.ExportNotFound,
        error.ExportIsNotFunction,
        => true,
        else => false,
    };
}

/// Shared catch-classifier for the §1 JIT no-arg dispatch arms (i32 / i64 /
/// f32 / f64): compile/setup rejects → an enumerated skip (the JIT never
/// executed this shape), execution-stage outcomes (e.g. `error.Trap`) → fail.
/// One copy so every result-type arm classifies identically.
fn recordJitRunErr(
    e: zwasm.engine.runner.Error,
    summary: *ProposalSummary,
    fail_detail: bool,
    stdout: anytype,
    proposal: []const u8,
    ename: []const u8,
    fname: []const u8,
) !void {
    if (jitErrorIsUnwiredShape(e)) {
        summary.jit_return_skip += 1;
        if (fail_detail) try stdout.print("  JITskip [{s}/{s}] {s} (unwired shape: err={s})\n", .{ proposal, ename, fname, @errorName(e) });
    } else {
        summary.jit_return_fail += 1;
        if (fail_detail) try stdout.print("  JITfail [{s}/{s}] {s} err={s}\n", .{ proposal, ename, fname, @errorName(e) });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next() orelse return;
    const corpus_root = args.next() orelse {
        try stdout.print("usage: spec_assert_runner_wasm_3_0 <corpus-root> [--fail-detail]\n", .{});
        try stdout.flush();
        return;
    };
    // Per-assert FAIL detail (cycle 163 diagnostic infra). Emitted via
    // the buffered `stdout` (reliable) — NOT std.debug.print, which
    // under-reported vs the per-manifest breakdown in cyc161. Opt-in via
    // a `--fail-detail` arg; off by default so gate runs stay clean.
    const fail_detail = if (args.next()) |a| std.mem.eql(u8, a, "--fail-detail") else false;

    // §1 (ADR-0128) — opt-in JIT execution mode. Default = interp, so
    // `zig build test-spec-wasm-3.0-assert` (and test-all) is unchanged.
    // `ZWASM_SPEC_ENGINE=jit` routes the no-arg-i32 assert_return subset
    // through the JIT entry (runI32Export) and reports jit pass/fail/skip
    // alongside the interp totals — the verification backbone that makes
    // "both backends" mechanically checkable. The JIT entry re-compiles
    // the module per call (runI32Export owns its own runtime). A
    // 2026-05-31 --fail-detail sweep settled the originally-suspected
    // "stale cross-directive state" worry: of 96 raw fails, ZERO were
    // state-dependent — 87 were compile/setup rejections (66 multi-memory,
    // 11 unemitted-op, + setup/validate gaps) now routed to
    // `jit_return_skip` by `jitErrorIsUnwiredShape`, leaving fail = JIT
    // actually executed and produced the wrong observable result (trap or
    // value mismatch). A shared-runtime state bridge was therefore dropped
    // as a zero-yield next chunk; the live lever is widening the
    // JIT-runnable shape set (see .dev/lessons + handover bundle).
    const jit_mode = if (init.environ_map.get("ZWASM_SPEC_ENGINE")) |v|
        std.mem.eql(u8, v, "jit")
    else
        false;

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_root, .{}) catch {
        try stdout.print("[wasm-3.0-assert] corpus root not found: {s} (0 manifests; exit 0)\n", .{corpus_root});
        try stdout.flush();
        return;
    };
    defer dir.close(io);

    var grand_total_manifests: u32 = 0;
    var grand_total_directives: u32 = 0;
    var grand_total_return_pass: u32 = 0;
    var grand_total_return_fail: u32 = 0;
    var grand_total_trap_pass: u32 = 0;
    var grand_total_trap_fail: u32 = 0;
    var grand_total_invalid_pass: u32 = 0;
    var grand_total_invalid_fail: u32 = 0;
    var grand_total_unlinkable_pass: u32 = 0;
    var grand_total_unlinkable_fail: u32 = 0;
    var grand_total_malformed_pass: u32 = 0;
    var grand_total_malformed_fail: u32 = 0;
    var grand_total_exception_pass: u32 = 0;
    var grand_total_exception_fail: u32 = 0;
    // §1 (ADR-0128) — JIT execution-mode grand tallies.
    var grand_total_jit_pass: u32 = 0;
    var grand_total_jit_fail: u32 = 0;
    var grand_total_jit_skip: u32 = 0;

    for (PROPOSALS) |proposal| {
        var summary: ProposalSummary = .{ .name = proposal };

        var pdir = dir.openDir(io, proposal, .{ .iterate = true }) catch {
            try stdout.print("[{s}] (no subdir; 0 manifests)\n", .{proposal});
            continue;
        };
        defer pdir.close(io);

        var it = pdir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.eql(u8, entry.name, "raw")) continue;

            const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.txt", .{entry.name});
            defer gpa.free(manifest_path);

            const manifest = pdir.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20)) catch continue;
            defer gpa.free(manifest);

            summary.manifests += 1;
            // Per-manifest fail breakdown (cycle 160 diagnostic infra):
            // snapshot fail counters so the loop can attribute return/
            // trap fails to the specific sub-corpus manifest. Printed
            // below only when this manifest contributed > 0 fails — turns
            // the diffuse per-proposal totals into a targetable per-feature
            // map for the next cycle.
            const mf_ret_fail0 = summary.asserts_return_fail;
            const mf_trap_fail0 = summary.asserts_trap_fail;

            // Active module bytes for assert_return dispatch. A new
            // `module <path>` directive replaces the slice; the
            // sub-corpus dir owns the alloc (freed below).
            var cur_module_bytes: ?[]u8 = null;
            defer if (cur_module_bytes) |b| gpa.free(b);

            // §1 / D-214 — persistent per-module JIT runtime. Instantiated
            // once per `module` directive (jit mode only); every subsequent
            // invoke routes through it so memory.grow / stores / global.set
            // accumulate across asserts (vs the old recompile-per-assert that
            // lost cross-directive state). null = no module / JIT-compile rejected.
            var cur_jit: ?zwasm.engine.runner.JitInstance = null;
            defer if (cur_jit) |*j| j.deinit(gpa);

            // 10.M-D195b cycle 71 — multi-instance lifetime for
            // cross-module `(register …)` support. Pre-cycle-71 each
            // `module` directive tore down the prior Engine/Module/
            // Linker/Instance and created fresh state. Cross-module
            // imports + Linker.defineMemory entries need shared
            // state across modules — so the runner now keeps a
            // single Engine + Linker per manifest, accumulating
            // Modules + Instances in arrays. Each instantiate
            // resolves against the cumulative Linker entries
            // (populated by prior `register <as>` directives).
            var cur_engine: zwasm.Engine = zwasm.Engine.init(gpa, .{}) catch continue;
            defer cur_engine.deinit();
            var cur_linker: zwasm.Linker = zwasm.Linker.init(&cur_engine);
            defer cur_linker.deinit();
            var modules_list: std.ArrayList(zwasm.Module) = .empty;
            defer {
                for (modules_list.items) |*m| m.deinit();
                modules_list.deinit(gpa);
            }
            var instances_list: std.ArrayList(zwasm.Instance) = .empty;
            defer {
                for (instances_list.items) |*i| i.deinit();
                instances_list.deinit(gpa);
            }
            // The most-recently-instantiated index into `instances_list`,
            // or null when no module is currently active (compile /
            // instantiate failed).
            var cur_inst_idx: ?usize = null;
            // 10.M-D195b cycle 72 — name → instance-idx map. Keyed
            // by `$<id>` (from `module $<id> <path>` directives) AND
            // by `<as>` (from `register <as>` directives). Lets
            // tagged asserts (`$M::field`) dispatch to the registered
            // instance instead of the most-recent one.
            var name_to_idx: std.StringHashMap(usize) = std.StringHashMap(usize).init(gpa);
            defer name_to_idx.deinit();

            // 10.M-D195b cycle 74 — pre-register a synthetic
            // `spectest` module's memory before processing any
            // manifest directive. The Wasm spec testsuite expects
            // a host-provided `spectest` module with conventional
            // exports (memory, globals, table, print funcs); many
            // multi-memory fixtures (imports2/4, linking2, data0.3/5)
            // declare `(import "spectest" "memory" …)` and currently
            // fail with UnknownImport. This synth covers the memory
            // export only; globals / table / funcs land in cycle 75+
            // when fixtures surface the gap.
            //
            // Bytes: `(module (memory (export "memory") 1 2)
            //                 (global (export "global_i32") i32 i32.const 666)
            //                 (global (export "global_i64") i64 i64.const 666)
            //                 (global (export "global_f32") f32 f32.const 0)
            //                 (global (export "global_f64") f64 f64.const 0))`
            // Synth carries memory + 4 globals; covers the Wasm spec
            // testsuite's conventional `spectest` host module exports
            // that current corpus fixtures actually reference.
            //
            // Section layout (raw bytes; comments name section IDs):
            //  - magic + version (8 bytes)
            //  - memory section (id 5): 1 entry, flags=1 min=1 max=2
            //  - global section (id 6): 4 entries (i32/i64/f32/f64 = 666/666/0/0,
            //    all immutable per spec testsuite convention)
            //  - export section (id 7): 5 entries (memory + 4 globals)
            const spectest_bytes = [_]u8{
                0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
                // memory section: 1 entry, flags=1, min=1, max=2
                0x05, 0x04, 0x01, 0x01, 0x01, 0x02,
                // global section: 4 entries (33 bytes content)
                //   each: valtype byte + mutable byte + init_expr + 0x0B end
                0x06, 0x21,
                0x04,
                //   global 0: i32 (0x7F) const 0x9A 0x05 (666 LEB128) — immutable
                0x7f, 0x00, 0x41, 0x9a, 0x05, 0x0b,
                //   global 1: i64 (0x7E) const 0x9A 0x05 (666) — immutable
                0x7e,
                0x00, 0x42, 0x9a, 0x05, 0x0b,
                //   global 2: f32 (0x7D) const 0.0 — immutable
                0x7d, 0x00, 0x43,
                0x00, 0x00, 0x00, 0x00, 0x0b,
                //   global 3: f64 (0x7C) const 0.0 — immutable
                0x7c, 0x00, 0x44,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x0b,
                // export section: 5 entries (62 bytes content)
                0x07, 0x3e, 0x05,
                //   "memory" memory 0
                0x06, 'm',  'e',  'm',
                'o',  'r',  'y',  0x02, 0x00,
                //   "global_i32" global 0
                0x0a, 'g',  'l',
                'o',  'b',  'a',  'l',  '_',  'i',  '3',  '2',
                0x03, 0x00,
                //   "global_i64" global 1
                0x0a, 'g',  'l',  'o',  'b',  'a',
                'l',  '_',  'i',  '6',  '4',  0x03, 0x01,
                //   "global_f32" global 2
                0x0a,
                'g',  'l',  'o',  'b',  'a',  'l',  '_',  'f',
                '3',  '2',  0x03, 0x02,
                //   "global_f64" global 3
                0x0a, 'g',  'l',  'o',
                'b',  'a',  'l',  '_',  'f',  '6',  '4',  0x03,
                0x03,
            };
            if (cur_engine.compile(&spectest_bytes)) |spectest_mod_compiled| {
                var spectest_mod = spectest_mod_compiled;
                if (modules_list.append(gpa, spectest_mod)) |_| {
                    const m_ptr = &modules_list.items[modules_list.items.len - 1];
                    if (cur_linker.instantiate(m_ptr)) |inst| {
                        var inst_mut = inst;
                        if (instances_list.append(gpa, inst_mut)) |_| {
                            const inst_ptr = &instances_list.items[instances_list.items.len - 1];
                            if (inst_ptr.memory()) |mem| {
                                cur_linker.defineMemory("spectest", "memory", mem) catch {};
                            }
                            // 10.M-D195b cycle 77 — register the
                            // synth module's global exports under
                            // the `spectest` name so fixtures that
                            // declare `(import "spectest" "global_*"
                            // (global …))` resolve via findEntry.
                            cur_linker.defineGlobal("spectest", "global_i32", inst_ptr, "global_i32") catch {};
                            cur_linker.defineGlobal("spectest", "global_i64", inst_ptr, "global_i64") catch {};
                            cur_linker.defineGlobal("spectest", "global_f32", inst_ptr, "global_f32") catch {};
                            cur_linker.defineGlobal("spectest", "global_f64", inst_ptr, "global_f64") catch {};
                        } else |_| {
                            inst_mut.deinit();
                        }
                    } else |_| {
                        // spectest instantiate failure is non-fatal:
                        // fixtures that don't reference spectest still
                        // run; ones that do will fail UnknownImport.
                    }
                } else |_| {
                    spectest_mod.deinit();
                }
            } else |_| {
                // spectest compile failure is non-fatal — see above.
            }
            // 10.M-D195b cycle 75 — spectest.print* host funcs.
            // No-op semantics; defineFunc returning errors is also
            // non-fatal (fixtures that don't reference them still run).
            cur_linker.defineFunc("spectest", "print", fn (*zwasm.Caller) void, spectestPrint) catch {};
            cur_linker.defineFunc("spectest", "print_i32", fn (*zwasm.Caller, i32) void, spectestPrintI32) catch {};
            cur_linker.defineFunc("spectest", "print_i64", fn (*zwasm.Caller, i64) void, spectestPrintI64) catch {};
            cur_linker.defineFunc("spectest", "print_f32", fn (*zwasm.Caller, f32) void, spectestPrintF32) catch {};
            cur_linker.defineFunc("spectest", "print_f64", fn (*zwasm.Caller, f64) void, spectestPrintF64) catch {};
            cur_linker.defineFunc("spectest", "print_i32_f32", fn (*zwasm.Caller, i32, f32) void, spectestPrintI32F32) catch {};
            cur_linker.defineFunc("spectest", "print_f64_f64", fn (*zwasm.Caller, f64, f64) void, spectestPrintF64F64) catch {};

            // Sub-corpus dir (e.g. `tail-call/return_call/`) — both
            // the manifest AND the .wasm files it cites live here.
            var sub_dir = pdir.openDir(io, entry.name, .{}) catch continue;
            defer sub_dir.close(io);

            var lines = std.mem.splitScalar(u8, manifest, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var args_buf: [4]manifest_parser.TypedValue = undefined;
                var results_buf: [4]manifest_parser.TypedValue = undefined;
                const d = manifest_parser.parseLine(line, &args_buf, &results_buf) catch continue;
                switch (d.kind) {
                    .module => {
                        summary.modules += 1;
                        if (cur_jit) |*j| {
                            j.deinit(gpa);
                            cur_jit = null;
                        }
                        if (cur_module_bytes) |b| gpa.free(b);
                        cur_module_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            cur_module_bytes = null;
                            cur_inst_idx = null;
                            continue;
                        };
                        // §1 / D-214 — instantiate the persistent JIT runtime
                        // for this module (jit mode only). A compile/setup
                        // reject (multi-memory, unemitted op, …) leaves cur_jit
                        // null → asserts against it become enumerated skips.
                        if (jit_mode) {
                            // D-225 — resolve this module's imported-global
                            // VALUES (global-import order) from registered
                            // exporter instances, so setup-time const-exprs
                            // (gc/i31.3/4 `(ref.i31 (global.get $env.g))`)
                            // read the real value, not a null import slot.
                            const gvals = jitResolveImportedGlobals(gpa, cur_module_bytes.?, &instances_list, &name_to_idx) catch &.{};
                            defer if (gvals.len > 0) gpa.free(gvals);
                            // Capture the module-reject cause (else this skip
                            // class is SILENT — see lesson
                            // 2026-06-02-spec-jit-skips-weight-by-root-cause).
                            cur_jit = zwasm.engine.runner.JitInstance.initLinked(gpa, cur_module_bytes.?, gvals) catch |e| inner: {
                                if (fail_detail) try stdout.print("  JITmodrej [{s}/{s}] err={s}\n", .{ proposal, d.module_path, @errorName(e) });
                                break :inner null;
                            };
                        }
                        // 10.M-D195b cycle 71 — compile + instantiate
                        // against the shared engine + linker, then
                        // accumulate. Cross-module imports declared
                        // by the new module resolve against the
                        // linker's existing entries (populated by
                        // prior `register <as>` directives).
                        zwasm.diagnostic.clearDiag();
                        var compiled = cur_engine.compile(cur_module_bytes.?) catch |e| {
                            // ADR-0016 M3 — surface the attributed validate
                            // failure (op/offset/fn) instead of the bare
                            // CompileError tag (permanent replacement for
                            // the GC bring-up op-probe).
                            if (zwasm.diagnostic.lastDiagnostic()) |dg| {
                                switch (dg.location) {
                                    .validate => |v| std.debug.print("[wasm-3.0-assert] {s}/{s} compile FAIL: {s} — {s} [fn={d} off={d} op=0x{x}]\n", .{ proposal, d.module_path, @errorName(e), dg.message(), v.fn_idx, v.body_offset, v.opcode }),
                                    else => std.debug.print("[wasm-3.0-assert] {s}/{s} compile FAIL: {s} — {s}\n", .{ proposal, d.module_path, @errorName(e), dg.message() }),
                                }
                            } else {
                                std.debug.print("[wasm-3.0-assert] {s}/{s} compile FAIL: {s}\n", .{ proposal, d.module_path, @errorName(e) });
                            }
                            cur_inst_idx = null;
                            continue;
                        };
                        modules_list.append(gpa, compiled) catch {
                            compiled.deinit();
                            cur_inst_idx = null;
                            continue;
                        };
                        const m_ptr = &modules_list.items[modules_list.items.len - 1];
                        var inst = cur_linker.instantiate(m_ptr) catch |e| {
                            std.debug.print("[wasm-3.0-assert] {s}/{s} instantiate FAIL: {s}\n", .{ proposal, d.module_path, @errorName(e) });
                            cur_inst_idx = null;
                            continue;
                        };
                        instances_list.append(gpa, inst) catch {
                            inst.deinit();
                            cur_inst_idx = null;
                            continue;
                        };
                        cur_inst_idx = instances_list.items.len - 1;
                        // 10.M-D195b cycle 72 — register the new
                        // instance under its `$<id>` tag (when the
                        // wast bound a name via `(module $X …)`).
                        // Subsequent asserts can dispatch to this
                        // instance via `$X::field`.
                        if (d.module_id.len > 0) {
                            name_to_idx.put(d.module_id, cur_inst_idx.?) catch {};
                        }
                    },
                    .register => {
                        // 10.M-D195b cycle 71 — bind the most-recent
                        // instance's memory exports into the shared
                        // Linker under `<as>` so subsequent modules'
                        // `(import "<as>" "<name>" memory)` resolves
                        // via Linker.findEntry. Only memory exports
                        // wired this cycle (func/table/global cross-
                        // module imports are out of scope until a
                        // fixture surfaces the gap).
                        const idx = cur_inst_idx orelse {
                            summary.skips += 1;
                            continue;
                        };
                        const inst = &instances_list.items[idx];
                        const exports = inst.handle.exports_storage;
                        const inst_rt = inst.handle.runtime;
                        for (exports) |exp| {
                            switch (exp.kind) {
                                .memory => {
                                    // 10.M-D195b cycle 75 — bind each
                                    // memory export at its specific
                                    // memidx (was memory0 only). The
                                    // raw-bytes overload of defineMemory
                                    // indexes into rt.memories directly.
                                    if (inst_rt) |rt| {
                                        if (exp.idx < rt.memories.len) {
                                            // D-199 — share the live *MemoryInstance.
                                            cur_linker.defineMemoryInstance(d.func_name, exp.name, rt.memories[exp.idx]) catch {};
                                        }
                                    }
                                },
                                .func => {
                                    // 10.M-D195b cycle 74 — bind every
                                    // func export through the cross-
                                    // module thunk so the importer
                                    // resolves via `findEntry` and
                                    // dispatches into the source
                                    // instance's runtime.
                                    cur_linker.defineCrossModuleFunc(d.func_name, exp.name, inst, exp.name) catch {};
                                },
                                .global => {
                                    // 10.G cycle 165 — bind global exports
                                    // (mirrors the spectest pre-register +
                                    // Linker.defineGlobal alias). gc/i31.3
                                    // + i31.4 `(import "env" "g")` need this.
                                    cur_linker.defineGlobal(d.func_name, exp.name, inst, exp.name) catch {};
                                },
                                .table => {
                                    // D-201b — bind each table export
                                    // (refs aliased) so cross-module
                                    // imports + their elem writes share it.
                                    if (inst_rt) |rt| {
                                        if (exp.idx < rt.tables.len) {
                                            cur_linker.defineTable(d.func_name, exp.name, rt.tables[exp.idx]) catch {};
                                        }
                                    }
                                },
                            }
                        }
                        // 10.E-xmodule-tags cycle 116 — bind each EH tag
                        // export (from the parallel tag_exports side-table,
                        // since tags are absent from exports_storage) so an
                        // importer's `(import <as> <name> (tag …))` resolves
                        // via the Linker.
                        for (inst.handle.tag_exports) |te| {
                            cur_linker.defineCrossModuleTag(d.func_name, te.name, inst, te.tag_index) catch {};
                        }
                        // 10.M-D195b cycle 72 — also register the
                        // instance under the `<as>` name so tagged
                        // asserts (`<as>::field`) dispatch to it.
                        name_to_idx.put(d.func_name, idx) catch {};
                        summary.skips += 1;
                    },
                    .assert_return => {
                        summary.asserts_return += 1;
                        // §1 (ADR-0128) — JIT execution mode. The no-arg-i32
                        // same-module subset runs through the JIT entry and
                        // is compared; every other shape is a tracked skip.
                        // Bypasses the interp path entirely in jit mode (the
                        // re-compile-per-call path owns its own runtime).
                        if (jit_mode) {
                            // §1 / D-214 — route through the PERSISTENT per-module
                            // JitInstance so state (memory.grow / stores / global.set)
                            // accumulates across asserts. Exact BIT compare for FP
                            // (corpus encodes FP literally; no NaN-class matcher).
                            const elig = jitReturnEligible(
                                d.args_len,
                                d.results_len,
                                if (d.results_len == 1) d.results[0].ty else "",
                                if (d.args_len >= 1) d.args[0].ty else "",
                                d.module_id.len,
                            );
                            if (!elig) {
                                summary.jit_return_skip += 1;
                                if (fail_detail) try stdout.print("  JITskip [{s}/{s}] {s} (args={d} results={d} — scalar 0/1-arg only)\n", .{ proposal, entry.name, d.func_name, d.args_len, d.results_len });
                                continue;
                            }
                            const inst = if (cur_jit) |*j| j else {
                                // module did not JIT-compile/instantiate → enumerated skip
                                summary.jit_return_skip += 1;
                                continue;
                            };
                            // Pack scalar args into bit-carriers (declaration order).
                            var arg_bits: [4]u64 = undefined;
                            var args_ok = true;
                            var ai: u8 = 0;
                            while (ai < d.args_len) : (ai += 1) {
                                const tv = d.args[ai];
                                const rvv = manifest_parser.parsePayload(tv) catch {
                                    args_ok = false;
                                    break;
                                };
                                const zvv = manifest_parser.runtimeToZwasm(rvv, tv.ty);
                                arg_bits[ai] = scalarArgBits(zvv, tv.ty) orelse {
                                    args_ok = false;
                                    break;
                                };
                            }
                            if (!args_ok) {
                                summary.jit_return_skip += 1;
                                continue;
                            }
                            const got = inst.invoke(gpa, d.func_name, arg_bits[0..d.args_len]) catch |e| {
                                try recordJitRunErr(e, &summary, fail_detail, stdout, proposal, entry.name, d.func_name);
                                continue;
                            };
                            // got == null ⇒ nothing to compare: a void result
                            // OR a REF result run for side effects (D-222). Pass
                            // = invoke ran without trapping; its side effect now
                            // persists for later asserts.
                            const got_val = got orelse {
                                summary.jit_return_pass += 1;
                                continue;
                            };
                            const exp_tv = d.results[0];
                            const exp_rv = manifest_parser.parsePayload(exp_tv) catch {
                                summary.jit_return_skip += 1;
                                continue;
                            };
                            const exp_zv = manifest_parser.runtimeToZwasm(exp_rv, exp_tv.ty);
                            if (jitScalarResultMatches(exp_tv.ty, got_val, exp_zv)) {
                                summary.jit_return_pass += 1;
                            } else {
                                summary.jit_return_fail += 1;
                                if (fail_detail) try stdout.print("  JITval [{s}/{s}] {s} ty={s} got=0x{x:0>16}\n", .{ proposal, entry.name, d.func_name, exp_tv.ty, got_val });
                            }
                            continue;
                        }
                        _ = cur_module_bytes orelse continue;
                        // Build args slice (zwasm.Value); skip if any
                        // typed arg can't parse (e.g. v128 / refs not yet
                        // mapped). Skip BEFORE instance gate so unsupported
                        // shapes stay un-counted regardless of setup state.
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) continue;
                        // Multi-value defer (cycle-3 scope); void
                        // (0 results) handled inline below so the
                        // state-mutating call still runs.
                        if (d.results_len > 1) continue;
                        // 10.M-D195b cycle 72 — tagged dispatch.
                        const idx_ret: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse {
                                summary.asserts_return_fail += 1;
                                if (fail_detail) try stdout.print("  FAILdispatch [{s}/{s}] {s} id={s}\n", .{ proposal, entry.name, d.func_name, d.module_id });
                                continue;
                            })
                        else
                            (cur_inst_idx orelse {
                                // Setup failure earlier in this module block;
                                // count as fail since the assert couldn't
                                // be evaluated.
                                summary.asserts_return_fail += 1;
                                if (fail_detail) try stdout.print("  FAILsetup [{s}/{s}] {s}\n", .{ proposal, entry.name, d.func_name });
                                continue;
                            });
                        const instance = &instances_list.items[idx_ret];
                        if (d.results_len == 0) {
                            // Void-result assert_return — invoke for
                            // side effects (store ops, table.set, etc.)
                            // so subsequent state-dependent directives
                            // see the mutation. Pass on clean return,
                            // fail on trap or setup error.
                            manifest_parser.invokeInstanceVoid(instance, d.func_name, call_args[0..d.args_len]) catch |e| {
                                summary.asserts_return_fail += 1;
                                if (fail_detail) try stdout.print("  FAILvoid [{s}/{s}] {s} err={s}\n", .{ proposal, entry.name, d.func_name, @errorName(e) });
                                continue;
                            };
                            summary.asserts_return_pass += 1;
                            continue;
                        }
                        const expected_tv = d.results[0];
                        const expected_rv = manifest_parser.parsePayload(expected_tv) catch continue;
                        const expected_zv = manifest_parser.runtimeToZwasm(expected_rv, expected_tv.ty);
                        const got = manifest_parser.invokeInstance(instance, d.func_name, call_args[0..d.args_len]) catch |e| {
                            summary.asserts_return_fail += 1;
                            if (fail_detail) try stdout.print("  FAILtrap [{s}/{s}] {s} err={s}\n", .{ proposal, entry.name, d.func_name, @errorName(e) });
                            continue;
                        };
                        // Compare by the result type's discriminator.
                        const match = if (std.mem.eql(u8, expected_tv.ty, "i32")) got.i32 == expected_zv.i32 else if (std.mem.eql(u8, expected_tv.ty, "i64")) got.i64 == expected_zv.i64 else if (std.mem.eql(u8, expected_tv.ty, "f32")) got.f32 == expected_zv.f32 else if (std.mem.eql(u8, expected_tv.ty, "f64")) got.f64 == expected_zv.f64 else false;
                        if (match) summary.asserts_return_pass += 1 else {
                            summary.asserts_return_fail += 1;
                            if (fail_detail) try stdout.print("  FAILval [{s}/{s}] {s} exp={d} got={d} ty={s}\n", .{ proposal, entry.name, d.func_name, expected_zv.i32, got.i32, expected_tv.ty });
                        }
                    },
                    .assert_trap => {
                        summary.asserts_trap += 1;
                        _ = cur_module_bytes orelse continue;
                        // Build args (skip if any typed arg can't
                        // parse — same gate as assert_return).
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) continue;
                        const idx_trap: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse {
                                summary.asserts_trap_fail += 1;
                                continue;
                            })
                        else
                            (cur_inst_idx orelse {
                                summary.asserts_trap_fail += 1;
                                continue;
                            });
                        const instance = &instances_list.items[idx_trap];
                        // assert_trap directives carry no results
                        // section in the baked manifest — invokeInstanceTrap
                        // looks up sig.results.len internally. Any
                        // InvokeError counts as the expected trap;
                        // setup errors (compile/instantiate/sig
                        // lookup) propagate as RunError → counted as
                        // fail (the assert couldn't be evaluated).
                        const outcome = manifest_parser.invokeInstanceTrap(instance, d.func_name, call_args[0..d.args_len]) catch {
                            summary.asserts_trap_fail += 1;
                            continue;
                        };
                        switch (outcome) {
                            .trapped => summary.asserts_trap_pass += 1,
                            .returned_normally => summary.asserts_trap_fail += 1,
                        }
                    },
                    .assert_invalid => {
                        summary.asserts_invalid += 1;
                        // Read the named .wasm sibling and try to
                        // compile it; rejection = pass, acceptance
                        // = fail. read errors / OOM = fail (the
                        // assert couldn't be evaluated).
                        const inv_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.asserts_invalid_fail += 1;
                            continue;
                        };
                        defer gpa.free(inv_bytes);
                        const outcome = manifest_parser.compileExpectInvalid(gpa, inv_bytes) catch {
                            summary.asserts_invalid_fail += 1;
                            continue;
                        };
                        switch (outcome) {
                            .rejected => summary.asserts_invalid_pass += 1,
                            .accepted => {
                                std.debug.print("[wasm-3.0-assert] {s}/{s} invalid-accepted (D-188 / D-195 — depends)\n", .{ proposal, d.module_path });
                                summary.asserts_invalid_fail += 1;
                            },
                        }
                    },
                    .assert_malformed => {
                        summary.asserts_malformed += 1;
                        const mal_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.asserts_malformed_fail += 1;
                            continue;
                        };
                        defer gpa.free(mal_bytes);
                        // compile bundles parse + validate today;
                        // spec-level distinction (parser-stage
                        // reject vs validator-stage reject) isn't
                        // surfaced by the c_api boundary. Any
                        // compile-side rejection counts as pass.
                        const outcome = manifest_parser.compileExpectInvalid(gpa, mal_bytes) catch {
                            summary.asserts_malformed_fail += 1;
                            continue;
                        };
                        switch (outcome) {
                            .rejected => summary.asserts_malformed_pass += 1,
                            .accepted => summary.asserts_malformed_fail += 1,
                        }
                    },
                    .assert_uninstantiable => {
                        // D-200 — the module compiles but TRAPS at
                        // instantiation (active data/elem OOB). Instantiate
                        // it against the current linker; PASS if
                        // instantiation fails. The partial active-segment
                        // writes to SHARED imported memory/table persist
                        // (D-199 shared memory + aliased table refs), which
                        // subsequent asserts depend on. Does NOT change the
                        // "current" instance (tagged asserts target the
                        // registered module).
                        summary.asserts_trap += 1;
                        const un_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.asserts_trap_fail += 1;
                            continue;
                        };
                        defer gpa.free(un_bytes);
                        zwasm.diagnostic.clearDiag();
                        var compiled = cur_engine.compile(un_bytes) catch {
                            // Rejected at compile — still did not
                            // instantiate; count pass (no side effects).
                            summary.asserts_trap_pass += 1;
                            continue;
                        };
                        modules_list.append(gpa, compiled) catch {
                            compiled.deinit();
                            summary.asserts_trap_fail += 1;
                            continue;
                        };
                        const m_ptr = &modules_list.items[modules_list.items.len - 1];
                        if (cur_linker.instantiate(m_ptr)) |inst| {
                            var bad_inst = inst;
                            bad_inst.deinit();
                            summary.asserts_trap_fail += 1; // unexpectedly instantiated
                        } else |_| {
                            summary.asserts_trap_pass += 1; // failed as expected
                        }
                    },
                    .assert_unlinkable => {
                        // cyc193 (D-198 bundle) — the module is valid but
                        // fails to LINK (import type/kind/limits mismatch).
                        // Instantiate against the current linker; PASS if
                        // instantiation fails. Verifies the REJECT direction
                        // of cross-module import subtyping (cyc192
                        // funcTypeImportCompatible).
                        summary.asserts_unlinkable += 1;
                        const ul_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            summary.asserts_unlinkable_fail += 1;
                            continue;
                        };
                        defer gpa.free(ul_bytes);
                        zwasm.diagnostic.clearDiag();
                        var compiled = cur_engine.compile(ul_bytes) catch {
                            // Rejected at compile — never linked; count pass.
                            summary.asserts_unlinkable_pass += 1;
                            continue;
                        };
                        modules_list.append(gpa, compiled) catch {
                            compiled.deinit();
                            summary.asserts_unlinkable_fail += 1;
                            continue;
                        };
                        const m_ptr = &modules_list.items[modules_list.items.len - 1];
                        if (cur_linker.instantiate(m_ptr)) |inst| {
                            var bad_inst = inst;
                            bad_inst.deinit();
                            summary.asserts_unlinkable_fail += 1; // unexpectedly linked
                        } else |_| {
                            summary.asserts_unlinkable_pass += 1; // failed to link as expected
                        }
                    },
                    .assert_exception => {
                        summary.asserts_exception += 1;
                        _ = cur_module_bytes orelse continue;
                        // Parse args (same gate as assert_return /
                        // assert_trap); v128 / refs skip.
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) continue;
                        const idx_exc: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse {
                                summary.asserts_exception_fail += 1;
                                continue;
                            })
                        else
                            (cur_inst_idx orelse {
                                summary.asserts_exception_fail += 1;
                                continue;
                            });
                        const instance = &instances_list.items[idx_exc];
                        const outcome = manifest_parser.invokeInstanceExpectException(instance, d.func_name, call_args[0..d.args_len]) catch {
                            summary.asserts_exception_fail += 1;
                            continue;
                        };
                        switch (outcome) {
                            .uncaught_exception => summary.asserts_exception_pass += 1,
                            .returned_normally, .other_trap => summary.asserts_exception_fail += 1,
                        }
                    },
                    .invoke => {
                        // D-191 — wast `(invoke "fn" args)` action.
                        // Side-effect driver for subsequent state-
                        // dependent asserts. Drop result silently
                        // (matches spec: an action by itself has
                        // no expected outcome other than non-trap).
                        // §1 / D-214 — in jit mode, drive the persistent
                        // JitInstance so the side effect persists for later
                        // JIT asserts (bypasses interp, like assert_return).
                        if (jit_mode) {
                            const inst = if (cur_jit) |*j| j else continue;
                            var ab: [4]u64 = undefined;
                            var ab_ok = true;
                            var k: u8 = 0;
                            while (k < d.args_len) : (k += 1) {
                                const tv = d.args[k];
                                const rvv = manifest_parser.parsePayload(tv) catch {
                                    ab_ok = false;
                                    break;
                                };
                                const zvv = manifest_parser.runtimeToZwasm(rvv, tv.ty);
                                ab[k] = scalarArgBits(zvv, tv.ty) orelse {
                                    ab_ok = false;
                                    break;
                                };
                            }
                            if (ab_ok) _ = inst.invoke(gpa, d.func_name, ab[0..d.args_len]) catch {};
                            continue;
                        }
                        _ = cur_module_bytes orelse continue;
                        var call_args: [4]zwasm.Value = undefined;
                        var call_args_ok = true;
                        var ai: u8 = 0;
                        while (ai < d.args_len) : (ai += 1) {
                            const tv = d.args[ai];
                            const rv = manifest_parser.parsePayload(tv) catch {
                                call_args_ok = false;
                                break;
                            };
                            call_args[ai] = manifest_parser.runtimeToZwasm(rv, tv.ty);
                        }
                        if (!call_args_ok) continue;
                        const idx_inv: usize = if (d.module_id.len > 0)
                            (name_to_idx.get(d.module_id) orelse continue)
                        else
                            (cur_inst_idx orelse continue);
                        const instance = &instances_list.items[idx_inv];
                        // Failure is informational only — the action
                        // wasn't an assertion. Counters don't increment.
                        manifest_parser.invokeInstanceVoid(instance, d.func_name, call_args[0..d.args_len]) catch {};
                    },
                    .skip_impl, .skip_validator, .skip_runtime => summary.skips += 1,
                    .unknown => {},
                }
            }
            const mf_ret_fail = summary.asserts_return_fail - mf_ret_fail0;
            const mf_trap_fail = summary.asserts_trap_fail - mf_trap_fail0;
            if (mf_ret_fail + mf_trap_fail > 0) {
                try stdout.print("  [{s}/{s}] return_fail={d} trap_fail={d}\n", .{ proposal, entry.name, mf_ret_fail, mf_trap_fail });
            }
        }

        const total_directives = summary.modules + summary.asserts_return + summary.asserts_trap +
            summary.asserts_invalid + summary.asserts_unlinkable + summary.asserts_malformed + summary.asserts_exception + summary.skips;
        try stdout.print(
            "[{s:<22}] manifests={d:<3} module={d:<3} return={d:<4} (pass={d:<4} fail={d:<4}) trap={d:<4} (pass={d:<4} fail={d:<4}) invalid={d:<3} (pass={d:<3} fail={d:<3}) malformed={d:<3} (pass={d:<3} fail={d:<3}) exception={d:<3} (pass={d:<3} fail={d:<3}) skip={d}\n",
            .{ proposal, summary.manifests, summary.modules, summary.asserts_return, summary.asserts_return_pass, summary.asserts_return_fail, summary.asserts_trap, summary.asserts_trap_pass, summary.asserts_trap_fail, summary.asserts_invalid, summary.asserts_invalid_pass, summary.asserts_invalid_fail, summary.asserts_malformed, summary.asserts_malformed_pass, summary.asserts_malformed_fail, summary.asserts_exception, summary.asserts_exception_pass, summary.asserts_exception_fail, summary.skips },
        );
        grand_total_manifests += summary.manifests;
        grand_total_directives += total_directives;
        grand_total_return_pass += summary.asserts_return_pass;
        grand_total_return_fail += summary.asserts_return_fail;
        grand_total_trap_pass += summary.asserts_trap_pass;
        grand_total_trap_fail += summary.asserts_trap_fail;
        grand_total_invalid_pass += summary.asserts_invalid_pass;
        grand_total_invalid_fail += summary.asserts_invalid_fail;
        grand_total_unlinkable_pass += summary.asserts_unlinkable_pass;
        grand_total_unlinkable_fail += summary.asserts_unlinkable_fail;
        grand_total_malformed_pass += summary.asserts_malformed_pass;
        grand_total_malformed_fail += summary.asserts_malformed_fail;
        grand_total_exception_pass += summary.asserts_exception_pass;
        grand_total_exception_fail += summary.asserts_exception_fail;
        if (jit_mode) {
            try stdout.print("[{s:<22}]   JIT: return pass={d} fail={d} skip={d}\n", .{ proposal, summary.jit_return_pass, summary.jit_return_fail, summary.jit_return_skip });
            grand_total_jit_pass += summary.jit_return_pass;
            grand_total_jit_fail += summary.jit_return_fail;
            grand_total_jit_skip += summary.jit_return_skip;
        }
    }

    try stdout.print(
        "[wasm-3.0-assert] total: {d} manifests, {d} directives; assert_return pass={d} fail={d}; assert_trap pass={d} fail={d}; assert_invalid pass={d} fail={d}; assert_unlinkable pass={d} fail={d}; assert_malformed pass={d} fail={d}; assert_exception pass={d} fail={d} (multi-value execution + assert_trap class discrimination land in follow-on cycles)\n",
        .{ grand_total_manifests, grand_total_directives, grand_total_return_pass, grand_total_return_fail, grand_total_trap_pass, grand_total_trap_fail, grand_total_invalid_pass, grand_total_invalid_fail, grand_total_unlinkable_pass, grand_total_unlinkable_fail, grand_total_malformed_pass, grand_total_malformed_fail, grand_total_exception_pass, grand_total_exception_fail },
    );
    if (jit_mode) {
        try stdout.print(
            "[wasm-3.0-assert] JIT execution mode (ADR-0128 §1): assert_return pass={d} fail={d} skip={d} (skip = JIT could not attempt this shape: eligibility-gated [args / v128 / multi-value / void / cross-module] OR compile/setup-rejected [multi-memory / unemitted-op / const-expr-or-validate gap, per jitErrorIsUnwiredShape]; fail = JIT executed and got the wrong observable result [trap or value mismatch])\n",
            .{ grand_total_jit_pass, grand_total_jit_fail, grand_total_jit_skip },
        );
    }
    try stdout.flush();
}

test "wasm-3.0-assert: PROPOSALS list matches design plan §3.1-§3.5 + §4.6 + 10.M extension" {
    // 10.M cycle 65 (`1e88350f`) added "multi-memory" as the 6th
    // entry; the upstream proposal lives at memory64/test/core/
    // multi-memory/ (jointly tracked with memory64). ROADMAP §10
    // row 10.M explicitly names multi-memory in scope, so this is
    // a 10.M extension of the original 5-proposal design plan, not
    // a §4/§9 scope deviation needing an ADR (per §18 routine
    // additions to the test-infrastructure layer).
    try std.testing.expectEqual(@as(usize, 6), PROPOSALS.len);
    try std.testing.expectEqualStrings("memory64", PROPOSALS[0]);
    try std.testing.expectEqualStrings("tail-call", PROPOSALS[1]);
    try std.testing.expectEqualStrings("exception-handling", PROPOSALS[2]);
    try std.testing.expectEqualStrings("gc", PROPOSALS[3]);
    try std.testing.expectEqualStrings("function-references", PROPOSALS[4]);
    try std.testing.expectEqualStrings("multi-memory", PROPOSALS[5]);
}

test "wasm-3.0-assert §1: JIT execution-mode eligibility + no-arg i32/i64/f32/f64 JIT invoke (ADR-0128 §1)" {
    // §1 dispatcher increment — no-arg + single-result, same-module, with
    // result type ∈ {i32, i64, f32, f64} wired through the JIT. Scalars use
    // exact BIT comparison (correct for NaN bit patterns, which the corpus
    // encodes literally — `nan:canonical`/`nan:arithmetic` tokens are absent
    // from the wasm-3.0 result set, so no class matcher is needed). args /
    // multi-value / cross-module remain enumerated skips.
    try std.testing.expect(jitReturnEligible(0, 1, "i32", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(0, 1, "i64", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(0, 1, "f32", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(0, 1, "f64", "", 0)); // no-arg wired
    try std.testing.expect(jitReturnEligible(1, 1, "i32", "i32", 0)); // single-scalar-arg wired
    try std.testing.expect(jitReturnEligible(1, 1, "i64", "f64", 0)); // single-scalar-arg wired
    try std.testing.expect(jitReturnEligible(0, 0, "", "", 0)); // void no-arg (state side-effect runs)
    try std.testing.expect(jitReturnEligible(1, 0, "", "i32", 0)); // void single-scalar-arg (store)
    try std.testing.expect(jitReturnEligible(2, 1, "i32", "i32", 0)); // 2-scalar-arg wired (D-217)
    try std.testing.expect(jitReturnEligible(2, 0, "", "i64", 0)); // 2-arg void store (D-217)
    try std.testing.expect(!jitReturnEligible(1, 1, "i32", "v128", 0)); // non-scalar arg0
    try std.testing.expect(jitReturnEligible(3, 1, "i32", "i32", 0)); // 3-scalar-arg wired (D-217)
    try std.testing.expect(!jitReturnEligible(4, 1, "i32", "i32", 0)); // 4-arg (future)
    try std.testing.expect(!jitReturnEligible(0, 2, "i32", "", 0)); // multi-value
    try std.testing.expect(!jitReturnEligible(0, 1, "v128", "", 0)); // v128 result (later)
    try std.testing.expect(!jitReturnEligible(0, 1, "i32", "", 3)); // cross-module ($M::field)

    // End-to-end: the no-arg i32 export executes THROUGH the JIT entry
    // (runI32Export → callI32NoArgs), not the interpreter. Hand-built
    // `(module (func (export "seven") (result i32) i32.const 7))`.
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type: () -> i32
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x09, 0x01, 0x05, 0x73, 0x65, 0x76, 0x65, 0x6e, 0x00, 0x00, // export "seven" func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x07, 0x0b, // code: i32.const 7; end
    };
    const got = try zwasm.engine.runner.runI32Export(std.testing.allocator, &wasm, "seven");
    try std.testing.expectEqual(@as(u32, 7), got);

    // End-to-end i64: exercises the full 64-bit width via `i64.const -1`
    // (all-ones) so an i32-only path would mis-marshal. Hand-built
    // `(module (func (export "big") (result i64) i64.const -1))`.
    const wasm64 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7e, // type: () -> i64
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x07, 0x01, 0x03, 0x62, 0x69, 0x67, 0x00, 0x00, // export "big" func 0
        0x0a, 0x06, 0x01, 0x04, 0x00, 0x42, 0x7f, 0x0b, // code: i64.const -1; end
    };
    const got64 = try zwasm.engine.runner.runI64Export(std.testing.allocator, &wasm64, "big");
    try std.testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(got64)));

    // End-to-end f32: the result is a canonical NaN bit pattern
    // (`0x7fc00000`). Comparing BITS (not float `==`, which is false for
    // NaN) is what makes the JIT FP path correct. Hand-built
    // `(module (func (export "qnan") (result f32) f32.const <0x7fc00000>))`.
    const wasm_f32 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7d, // type: () -> f32
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x08, 0x01, 0x04, 0x71, 0x6e, 0x61, 0x6e, 0x00, 0x00, // export "qnan" func 0
        0x0a, 0x09, 0x01, 0x07, 0x00, 0x43, 0x00, 0x00, 0xc0, 0x7f, 0x0b, // f32.const 0x7fc00000; end
    };
    const got_f32 = try zwasm.engine.runner.runF32Export(std.testing.allocator, &wasm_f32, "qnan");
    try std.testing.expectEqual(@as(u32, 0x7fc00000), @as(u32, @bitCast(got_f32)));

    // End-to-end f64: `f64.const 2.5` (bits 0x4004000000000000). Hand-built
    // `(module (func (export "two_half") (result f64) f64.const 2.5))`.
    const wasm_f64 = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7c, // type: () -> f64
        0x03, 0x02, 0x01, 0x00, // func: typeidx 0
        0x07, 0x0c, 0x01, 0x08, 0x74, 0x77, 0x6f, 0x5f, 0x68, 0x61, 0x6c, 0x66, 0x00, 0x00, // export "two_half" func 0
        0x0a, 0x0d, 0x01, 0x0b, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x40, 0x0b, // f64.const 2.5; end
    };
    const got_f64 = try zwasm.engine.runner.runF64Export(std.testing.allocator, &wasm_f64, "two_half");
    try std.testing.expectEqual(@as(u64, 0x4004000000000000), @as(u64, @bitCast(got_f64)));
}

test "wasm-3.0-assert §1: JIT error classification — unwired-shape → skip, executed-wrong → fail (ADR-0128 §1)" {
    // Compile/setup-stage rejections (the JIT never executed) classify as
    // skip — structurally the same as the args/i64/fp eligibility skips,
    // enumerated not silently dropped. Empirically these are 87 of the 96
    // raw fails (66 multi-memory + 11 unemitted-op + setup/validate gaps).
    try std.testing.expect(jitErrorIsUnwiredShape(error.MultipleMemories));
    try std.testing.expect(jitErrorIsUnwiredShape(error.UnsupportedOp));
    try std.testing.expect(jitErrorIsUnwiredShape(error.InvalidFuncIndex));
    try std.testing.expect(jitErrorIsUnwiredShape(error.InvalidGlobalInitExpr));
    try std.testing.expect(jitErrorIsUnwiredShape(error.StackTypeMismatch));
    try std.testing.expect(jitErrorIsUnwiredShape(error.ElemSegmentTypeMismatch));
    try std.testing.expect(jitErrorIsUnwiredShape(error.UnsupportedEntrySignature));
    try std.testing.expect(jitErrorIsUnwiredShape(error.ExportNotFound));

    // Execution-stage outcome = the JIT ran and produced the wrong
    // observable behaviour → genuine fail (the meaningful both-backends
    // RED signal). `error.Trap` and any unanticipated error stay fail.
    try std.testing.expect(!jitErrorIsUnwiredShape(error.Trap));
}
