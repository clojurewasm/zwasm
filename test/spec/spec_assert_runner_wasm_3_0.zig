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

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

const PROPOSALS = [_][]const u8{
    "memory64",
    "tail-call",
    "exception-handling",
    "gc",
    "function-references",
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
        try stdout.print("usage: spec_assert_runner_wasm_3_0 <corpus-root>\n", .{});
        try stdout.flush();
        return;
    };

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

            // Active module bytes for assert_return dispatch. A new
            // `module <path>` directive replaces the slice; the
            // sub-corpus dir owns the alloc (freed below).
            var cur_module_bytes: ?[]u8 = null;
            defer if (cur_module_bytes) |b| gpa.free(b);

            // D-190 — Engine/Module/Linker/Instance share-state across
            // all directives following each `module <path>` block.
            // Each `module` directive tears down the prior context
            // and creates a fresh one; subsequent assert_returns /
            // assert_traps / assert_exceptions invoke against the
            // shared Instance so state-dependent sequences (e.g.,
            // memory_grow64's grow → size → load) accumulate per
            // spec semantics. Setup failure leaves cur_instance =
            // null so dependent directives skip cleanly.
            var cur_engine: ?zwasm.Engine = null;
            var cur_module: ?zwasm.Module = null;
            var cur_linker: ?zwasm.Linker = null;
            var cur_instance: ?zwasm.Instance = null;
            defer {
                if (cur_instance) |*i| i.deinit();
                if (cur_linker) |*l| l.deinit();
                if (cur_module) |*m| m.deinit();
                if (cur_engine) |*e| e.deinit();
            }

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
                            continue;
                        };
                        // D-190 — tear down prior context (defers
                        // are scope-bound; explicit teardown happens
                        // here per `module` directive).
                        if (cur_instance) |*i| { i.deinit(); cur_instance = null; }
                        if (cur_linker) |*l| { l.deinit(); cur_linker = null; }
                        if (cur_module) |*m| { m.deinit(); cur_module = null; }
                        if (cur_engine) |*e| { e.deinit(); cur_engine = null; }
                        cur_engine = zwasm.Engine.init(gpa, .{}) catch continue;
                        cur_module = (cur_engine.?).compile(cur_module_bytes.?) catch |e| {
                            // Compile failed — leave cur_engine alive
                            // but cur_module/instance null; dependent
                            // asserts will skip via the orelse path.
                            // 10.R cycle 59 — surface per-module compile
                            // failures to stderr so the runner emits
                            // an observable signal (silent skip masked
                            // function-references corpus expansion).
                            std.debug.print("[wasm-3.0-assert] {s}/{s} compile FAIL: {s}\n", .{ proposal, d.module_path, @errorName(e) });
                            continue;
                        };
                        cur_linker = zwasm.Linker.init(&cur_engine.?);
                        cur_instance = (cur_linker.?).instantiate(&cur_module.?) catch |e| {
                            std.debug.print("[wasm-3.0-assert] {s}/{s} instantiate FAIL: {s}\n", .{ proposal, d.module_path, @errorName(e) });
                            continue;
                        };
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
                        const instance = if (cur_instance) |*i| i else {
                            // Setup failure earlier in this module block;
                            // count as fail since the assert couldn't
                            // be evaluated.
                            summary.asserts_return_fail += 1;
                            continue;
                        };
                        if (d.results_len == 0) {
                            // Void-result assert_return — invoke for
                            // side effects (store ops, table.set, etc.)
                            // so subsequent state-dependent directives
                            // see the mutation. Pass on clean return,
                            // fail on trap or setup error.
                            manifest_parser.invokeInstanceVoid(instance, d.func_name, call_args[0..d.args_len]) catch {
                                summary.asserts_return_fail += 1;
                                continue;
                            };
                            summary.asserts_return_pass += 1;
                            continue;
                        }
                        const expected_tv = d.results[0];
                        const expected_rv = manifest_parser.parsePayload(expected_tv) catch continue;
                        const expected_zv = manifest_parser.runtimeToZwasm(expected_rv, expected_tv.ty);
                        const got = manifest_parser.invokeInstance(instance, d.func_name, call_args[0..d.args_len]) catch {
                            summary.asserts_return_fail += 1;
                            continue;
                        };
                        // Compare by the result type's discriminator.
                        const match = if (std.mem.eql(u8, expected_tv.ty, "i32")) got.i32 == expected_zv.i32
                            else if (std.mem.eql(u8, expected_tv.ty, "i64")) got.i64 == expected_zv.i64
                            else if (std.mem.eql(u8, expected_tv.ty, "f32")) got.f32 == expected_zv.f32
                            else if (std.mem.eql(u8, expected_tv.ty, "f64")) got.f64 == expected_zv.f64
                            else false;
                        if (match) summary.asserts_return_pass += 1 else summary.asserts_return_fail += 1;
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
                        const instance = if (cur_instance) |*i| i else {
                            summary.asserts_trap_fail += 1;
                            continue;
                        };
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
                        const instance = if (cur_instance) |*i| i else {
                            summary.asserts_exception_fail += 1;
                            continue;
                        };
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
                        const instance = if (cur_instance) |*i| i else continue;
                        // Failure is informational only — the action
                        // wasn't an assertion. Counters don't increment.
                        manifest_parser.invokeInstanceVoid(instance, d.func_name, call_args[0..d.args_len]) catch {};
                    },
                    .skip_impl, .skip_validator, .skip_runtime => summary.skips += 1,
                    .unknown => {},
                }
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

test "wasm-3.0-assert: PROPOSALS list matches design plan §3.1-§3.5 + §4.6" {
    try std.testing.expectEqual(@as(usize, 5), PROPOSALS.len);
    try std.testing.expectEqualStrings("memory64", PROPOSALS[0]);
    try std.testing.expectEqualStrings("tail-call", PROPOSALS[1]);
    try std.testing.expectEqualStrings("exception-handling", PROPOSALS[2]);
    try std.testing.expectEqualStrings("gc", PROPOSALS[3]);
    try std.testing.expectEqualStrings("function-references", PROPOSALS[4]);
}
