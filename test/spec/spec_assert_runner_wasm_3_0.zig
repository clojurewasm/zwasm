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
    asserts_malformed: u32 = 0,
    asserts_malformed_pass: u32 = 0,
    asserts_malformed_fail: u32 = 0,
    asserts_exception: u32 = 0,
    asserts_exception_pass: u32 = 0,
    asserts_exception_fail: u32 = 0,
    skips: u32 = 0,
};

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
    var grand_total_malformed_pass: u32 = 0;
    var grand_total_malformed_fail: u32 = 0;
    var grand_total_exception_pass: u32 = 0;
    var grand_total_exception_fail: u32 = 0;

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
                0x06, 0x21, 0x04,
                //   global 0: i32 (0x7F) const 0x9A 0x05 (666 LEB128) — immutable
                0x7f, 0x00, 0x41, 0x9a, 0x05, 0x0b,
                //   global 1: i64 (0x7E) const 0x9A 0x05 (666) — immutable
                0x7e, 0x00, 0x42, 0x9a, 0x05, 0x0b,
                //   global 2: f32 (0x7D) const 0.0 — immutable
                0x7d, 0x00, 0x43, 0x00, 0x00, 0x00, 0x00, 0x0b,
                //   global 3: f64 (0x7C) const 0.0 — immutable
                0x7c, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0b,
                // export section: 5 entries (62 bytes content)
                0x07, 0x3e, 0x05,
                //   "memory" memory 0
                0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
                //   "global_i32" global 0
                0x0a, 'g', 'l', 'o', 'b', 'a', 'l', '_', 'i', '3', '2', 0x03, 0x00,
                //   "global_i64" global 1
                0x0a, 'g', 'l', 'o', 'b', 'a', 'l', '_', 'i', '6', '4', 0x03, 0x01,
                //   "global_f32" global 2
                0x0a, 'g', 'l', 'o', 'b', 'a', 'l', '_', 'f', '3', '2', 0x03, 0x02,
                //   "global_f64" global 3
                0x0a, 'g', 'l', 'o', 'b', 'a', 'l', '_', 'f', '6', '4', 0x03, 0x03,
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
                        if (cur_module_bytes) |b| gpa.free(b);
                        cur_module_bytes = sub_dir.readFileAlloc(io, d.module_path, gpa, .limited(4 << 20)) catch {
                            cur_module_bytes = null;
                            cur_inst_idx = null;
                            continue;
                        };
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
                                            cur_linker.defineMemoryBytes(d.func_name, exp.name, rt.memories[exp.idx].bytes) catch {};
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
                                .table, .global => {
                                    // Out of scope; table / global
                                    // cross-module exports remain
                                    // unbound (importing modules will
                                    // fail with UnknownImport for those).
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
                        const match = if (std.mem.eql(u8, expected_tv.ty, "i32")) got.i32 == expected_zv.i32
                            else if (std.mem.eql(u8, expected_tv.ty, "i64")) got.i64 == expected_zv.i64
                            else if (std.mem.eql(u8, expected_tv.ty, "f32")) got.f32 == expected_zv.f32
                            else if (std.mem.eql(u8, expected_tv.ty, "f64")) got.f64 == expected_zv.f64
                            else false;
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
            summary.asserts_invalid + summary.asserts_malformed + summary.asserts_exception + summary.skips;
        try stdout.print(
            "[{s:<22}] manifests={d:<3} module={d:<3} return={d:<4} (pass={d:<4} fail={d:<4}) trap={d:<4} (pass={d:<4} fail={d:<4}) invalid={d:<3} (pass={d:<3} fail={d:<3}) malformed={d:<3} (pass={d:<3} fail={d:<3}) exception={d:<3} (pass={d:<3} fail={d:<3}) skip={d}\n",
            .{ proposal, summary.manifests, summary.modules, summary.asserts_return,
               summary.asserts_return_pass, summary.asserts_return_fail,
               summary.asserts_trap, summary.asserts_trap_pass, summary.asserts_trap_fail,
               summary.asserts_invalid, summary.asserts_invalid_pass, summary.asserts_invalid_fail,
               summary.asserts_malformed, summary.asserts_malformed_pass, summary.asserts_malformed_fail,
               summary.asserts_exception, summary.asserts_exception_pass, summary.asserts_exception_fail,
               summary.skips },
        );
        grand_total_manifests += summary.manifests;
        grand_total_directives += total_directives;
        grand_total_return_pass += summary.asserts_return_pass;
        grand_total_return_fail += summary.asserts_return_fail;
        grand_total_trap_pass += summary.asserts_trap_pass;
        grand_total_trap_fail += summary.asserts_trap_fail;
        grand_total_invalid_pass += summary.asserts_invalid_pass;
        grand_total_invalid_fail += summary.asserts_invalid_fail;
        grand_total_malformed_pass += summary.asserts_malformed_pass;
        grand_total_malformed_fail += summary.asserts_malformed_fail;
        grand_total_exception_pass += summary.asserts_exception_pass;
        grand_total_exception_fail += summary.asserts_exception_fail;
    }

    try stdout.print(
        "[wasm-3.0-assert] total: {d} manifests, {d} directives; assert_return pass={d} fail={d}; assert_trap pass={d} fail={d}; assert_invalid pass={d} fail={d}; assert_malformed pass={d} fail={d}; assert_exception pass={d} fail={d} (multi-value execution + assert_trap class discrimination land in follow-on cycles)\n",
        .{ grand_total_manifests, grand_total_directives,
           grand_total_return_pass, grand_total_return_fail,
           grand_total_trap_pass, grand_total_trap_fail,
           grand_total_invalid_pass, grand_total_invalid_fail,
           grand_total_malformed_pass, grand_total_malformed_fail,
           grand_total_exception_pass, grand_total_exception_fail },
    );
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
