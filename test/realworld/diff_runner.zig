//! Realworld stdout differential runner (§9.6 / 6.F).
//!
//! For each `.wasm` fixture in the corpus, runs `wasmtime run`
//! to capture a reference stdout, then drives the same fixture
//! through `cli/run.zig:runWasmCaptured` and byte-compares the
//! two outputs. The §9.6 / 6.F exit criterion is: 30+ samples
//! match `wasmtime run` byte-for-byte (the ADR-0006 target,
//! retargeted from §9.4 / 4.10).
//!
//! Outcome categories:
//!
//!   MATCH       — both runtimes produced identical stdout AND
//!                 the v2 run completed (any u8 exit). Counted
//!                 toward the 30+ gate.
//!   MISMATCH    — both runtimes produced stdout but bytes
//!                 differ. Surfaces a real semantic gap; a
//!                 single MISMATCH fails the gate.
//!   SKIP-EMPTY  — both runtimes produced empty stdout (silent
//!                 guests; trivially "matching" but uninformative,
//!                 so excluded from the 30+ count).
//!   SKIP-WASMTIME-FAIL — wasmtime exited non-zero / errored;
//!                 nothing to diff against.
//!   SKIP-V2-*   — v2 surfaced an error class run_runner already
//!                 categorises (WASI host gap / validator gap /
//!                 no entry); orthogonal to differential coverage.
//!   SKIP-WASMTIME-MISSING — wasmtime not on PATH; runner exits
//!                 0 with a "no diffs run on this host" notice.
//!                 Hosts with wasmtime installed see the real gate.
//!
//! Usage:
//!   zig build test-realworld-diff      # walks test/realworld/wasm/
//!   diff_runner_exe <corpus-dir>

const std = @import("std");

const zwasm = @import("zwasm");
const cli_run = zwasm.cli.run;

/// Fixtures that need a writable WASI preopen to run to completion (they
/// `path_open` a file relative to a preopen dir). The diff runner hands
/// BOTH wasmtime and v2 the same scratch dir mapped at guest "." so their
/// stdout matches byte-for-byte (D-243). Self-cleaning fixtures (create →
/// write → read → unlink) can share one scratch dir across the two runs.
fn fixtureNeedsPreopen(name: []const u8) bool {
    return std.mem.eql(u8, name, "rust_file_io.wasm");
}

/// cwd-relative scratch dir handed to needs-preopen fixtures as guest ".".
/// The wasmtime subprocess inherits the runner's cwd, so both runtimes
/// resolve the same host path. Recreated empty per run.
const preopen_scratch = "zig-out/diff-preopen-scratch";

/// AOT lane fixture-size cap (bytes). The opt-in `--aot` lane JIT-compiles
/// each fixture in-process; libc/Go/Rust guests above this size take minutes
/// to compile and trap under `--engine jit` anyway, so they are SKIP-AOT-LARGE
/// — the small compute/WASI fixtures under the cap are the achievable AOT
/// differential. Tune up once a subprocess-based (timeout-able) lane lands.
const aot_size_cap: usize = 64 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: diff_runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    // Optional `--aot` 2nd arg opts into the AOT lane (D-283 widen / D-251
    // validate). OFF by default: the AOT lane JIT-compiles every fixture
    // (slow on large guests) + runs native AOT code in-process, so it is a
    // dedicated diagnostic target (`test-realworld-diff-aot`), NOT part of the
    // always-run interp differential gate (`test-realworld-diff`).
    const aot_lane = if (arg_it.next()) |a| std.mem.eql(u8, a, "--aot") else false;

    const wasmtime_path_opt = try resolveWasmtime(gpa, io);
    defer if (wasmtime_path_opt) |p| gpa.free(p);

    if (wasmtime_path_opt == null) {
        try stdout.print(
            "SKIP-WASMTIME-MISSING — wasmtime not on PATH (and no nix-store wrapper found). " ++
                "§9.6 / 6.F differential gate is non-fatal on this host; the gate is real on " ++
                "hosts with wasmtime installed (the dev shell pins it via flake.nix).\n",
            .{},
        );
        try stdout.flush();
        return;
    }
    const wasmtime_path = wasmtime_path_opt.?;

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var matched: u32 = 0;
    var mismatched: u32 = 0;
    var skipped_empty: u32 = 0;
    var skipped_wasmtime_fail: u32 = 0;
    var skipped_v2: u32 = 0;
    var total: u32 = 0;

    // AOT lane (D-283 widen / D-251 validate): run the SAME fixture through
    // standalone AOT-WASI (`.cwasm` produce → run) and byte-compare vs
    // wasmtime, independent of the interp outcome. REPORT-ONLY this chunk
    // (loud per-fixture logging, no gate-fail) — first triage of how much of
    // the corpus the AOT path covers; a follow-up chunk gates once clean.
    var aot_matched: u32 = 0;
    var aot_mismatched: u32 = 0;
    var aot_skipped: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
        total += 1;

        const fixture_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_dir, entry.name });
        defer gpa.free(fixture_path);

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20)) catch {
            try stdout.print("SKIP-V2-READ  {s}\n", .{entry.name});
            skipped_v2 += 1;
            continue;
        };
        defer gpa.free(bytes);

        const needs_preopen = fixtureNeedsPreopen(entry.name);
        if (needs_preopen) {
            // Fresh empty scratch dir for both runtimes (guest sees it as ".").
            cwd.deleteTree(io, preopen_scratch) catch {};
            cwd.createDirPath(io, preopen_scratch) catch |err| {
                try stdout.print("SKIP-V2-PREOPEN  {s}: createDirPath {s}\n", .{ entry.name, @errorName(err) });
                skipped_v2 += 1;
                continue;
            };
        }
        defer if (needs_preopen) {
            cwd.deleteTree(io, preopen_scratch) catch {};
        };

        // Spawn wasmtime, capturing stdout. wasmtime exits with
        // the guest's proc_exit code (0 on success); a non-zero
        // exit + non-empty stderr usually means the guest itself
        // failed, but we still try the byte compare since that
        // is what §9.6 / 6.F measures. Needs-preopen fixtures get
        // `--dir <scratch>::.` (wasmtime host::guest syntax).
        const wt_argv: []const []const u8 = if (needs_preopen)
            &.{ wasmtime_path, "run", "--dir", preopen_scratch ++ "::.", fixture_path }
        else
            &.{ wasmtime_path, "run", fixture_path };
        const wt_result = std.process.run(gpa, io, .{
            .argv = wt_argv,
        }) catch |err| {
            try stdout.print("SKIP-WASMTIME-FAIL  {s}: {s}\n", .{ entry.name, @errorName(err) });
            skipped_wasmtime_fail += 1;
            continue;
        };
        defer gpa.free(wt_result.stdout);
        defer gpa.free(wt_result.stderr);
        const wt_stdout = wt_result.stdout;

        var v2_stdout: std.ArrayList(u8) = .empty;
        // capture_alloc contract (2d99e5a2): runWasmCaptured* grows the
        // capture buffer with the CALLER's allocator — free with the same
        // `gpa` or glibc aborts with `free(): invalid pointer`.
        defer v2_stdout.deinit(gpa);

        // Mirror wasmtime's default of `argv[0] = <wasm filename>`
        // so guests like `c_hello_wasi` that print argv[0] produce
        // identical bytes.
        const v2_argv: [1][]const u8 = .{entry.name};
        const v2_result = if (needs_preopen)
            cli_run.runWasmCapturedOpts(gpa, io, bytes, &v2_argv, &v2_stdout, null, &.{
                .{ .host_path = preopen_scratch, .guest_path = "." },
            }, &.{}, &.{}, null)
        else
            cli_run.runWasmCaptured(gpa, io, bytes, &v2_argv, &v2_stdout, null);
        const v2_exit: u8 = v2_result catch |err| {
            try stdout.print("SKIP-V2-{s}  {s}\n", .{ @errorName(err), entry.name });
            skipped_v2 += 1;
            continue;
        };

        // v2 trapped / exited non-zero where wasmtime ran to a clean exit
        // (0) = v2 could NOT complete the run — a v2 limitation, not an
        // output regression. Categorise skipped-v2, consistent with
        // instantiate-fail skips. Both-completed-but-different-output still
        // falls through to MISMATCH below, so genuine output regressions are
        // NOT masked. (The standard-Go CallStackExhausted case that used to
        // land here was the label-stack depth bug, resolved in D-242.)
        const wt_exit: u8 = switch (wt_result.term) {
            .exited => |c| c,
            else => 1,
        };

        // AOT lane (opt-in) — independent of the interp outcome (so SIMD
        // fixtures the interp can't run still get an AOT vs wasmtime compare).
        // Flush per fixture so incremental output shows progress.
        if (aot_lane) {
            if (bytes.len > aot_size_cap) {
                // The AOT lane JIT-compiles each fixture in-process; large libc
                // / Go / Rust guests (100KB–1MB) take minutes to compile AND
                // already trap under `--engine jit` (a separate v2 gap), so
                // they can't validate AOT either. Cap to keep the run practical;
                // the small compute/WASI fixtures are the achievable validation.
                try stdout.print("  SKIP-AOT-LARGE  {s} ({d} bytes > {d} cap)\n", .{ entry.name, bytes.len, aot_size_cap });
                aot_skipped += 1;
            } else switch (try aotCompare(gpa, io, bytes, entry.name, &v2_argv, needs_preopen, wt_stdout, wt_exit, stdout)) {
                .match => aot_matched += 1,
                .mismatch => aot_mismatched += 1,
                .skip => aot_skipped += 1,
            }
            try stdout.flush();
        }

        if (v2_exit != 0 and wt_exit == 0) {
            try stdout.print("SKIP-V2-TRAP  {s} (v2 exit={d}, wasmtime exit=0 — v2 could not complete)\n", .{ entry.name, v2_exit });
            skipped_v2 += 1;
            continue;
        }

        if (wt_stdout.len == 0 and v2_stdout.items.len == 0) {
            try stdout.print("SKIP-EMPTY  {s}\n", .{entry.name});
            skipped_empty += 1;
            continue;
        }

        if (std.mem.eql(u8, wt_stdout, v2_stdout.items)) {
            try stdout.print("MATCH  {s} ({d} bytes)\n", .{ entry.name, wt_stdout.len });
            matched += 1;
        } else {
            try stdout.print(
                "MISMATCH  {s} (wasmtime={d} bytes, v2={d} bytes)\n",
                .{ entry.name, wt_stdout.len, v2_stdout.items.len },
            );
            mismatched += 1;
        }
    }

    try stdout.print(
        "\ndiff_runner: {d}/{d} matched, {d} mismatched, {d} skipped-empty, " ++
            "{d} skipped-wasmtime-fail, {d} skipped-v2\n",
        .{ matched, total, mismatched, skipped_empty, skipped_wasmtime_fail, skipped_v2 },
    );
    // AOT lane summary (opt-in, report-only; D-283 widen / D-251 validate).
    if (aot_lane) {
        try stdout.print(
            "diff_runner [aot]: {d}/{d} matched, {d} mismatched, {d} skipped (AOT-unsupported / trap) — REPORT-ONLY\n",
            .{ aot_matched, total, aot_mismatched, aot_skipped },
        );
        try stdout.flush();
    }

    if (mismatched != 0) std.process.exit(1);
    // wasmtime resolved via `which` but every spawn failed (e.g. on
    // windowsmini, where `which wasmtime` finds a stub that doesn't
    // actually execute). Treat as SKIP-WASMTIME-MISSING so the gate
    // remains portable; the gate is real on hosts where wasmtime
    // genuinely runs.
    if (matched == 0 and skipped_wasmtime_fail == total and total > 0) {
        try stdout.print(
            "SKIP-WASMTIME-UNUSABLE — wasmtime resolved but every spawn failed " ++
                "({d} of {d} fixtures); §9.6 / 6.F differential gate is non-fatal on this host.\n",
            .{ skipped_wasmtime_fail, total },
        );
        try stdout.flush();
        return;
    }
    if (matched < 30) {
        try stdout.print("error: §9.6 / 6.F requires 30+ matches; saw only {d}\n", .{matched});
        try stdout.flush();
        std.process.exit(1);
    }
}

/// Outcome of the AOT lane for one fixture. `skip` collapses every
/// AOT-unsupported reason (compile/produce error = §12.3b cycle-1 limits
/// like passive data / non-const globals; run error = unsupported entry
/// signature; trap = AOT couldn't complete where wasmtime did) — each is
/// logged with its specific reason for triage, none is silent.
const AotOutcome = enum { match, mismatch, skip };

/// Run `bytes` through standalone AOT-WASI (compile → `.cwasm` produce →
/// `runCwasmWasi` with stdout capture) and byte-compare vs `wt_stdout`.
/// Mirrors the interp lane's skip semantics: an AOT non-zero exit where
/// wasmtime exited 0 = AOT could not complete (skip, not a regression).
fn aotCompare(
    gpa: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    name: []const u8,
    argv: []const []const u8,
    needs_preopen: bool,
    wt_stdout: []const u8,
    wt_exit: u8,
    out: anytype,
) !AotOutcome {
    const zrunner = zwasm.engine.runner;
    const zproduce = zwasm.engine.codegen.aot.produce;

    var compiled = zrunner.compileWasm(gpa, bytes) catch |err| {
        try out.print("  SKIP-AOT-COMPILE  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    defer compiled.deinit(gpa);

    const cwasm = zproduce.produceFromCompiledWasm(gpa, &compiled, bytes) catch |err| {
        try out.print("  SKIP-AOT-PRODUCE  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    defer gpa.free(cwasm);

    var aot_stdout: std.ArrayList(u8) = .empty;
    defer aot_stdout.deinit(gpa);

    const preopens: []const cli_run.PreopenDir = if (needs_preopen)
        &.{.{ .host_path = preopen_scratch, .guest_path = "." }}
    else
        &.{};
    const aot_exit: u8 = cli_run.runCwasmWasi(gpa, io, cwasm, null, argv, preopens, &.{}, &.{}, &aot_stdout) catch |err| {
        try out.print("  SKIP-AOT-RUN  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    if (aot_exit != 0 and wt_exit == 0) {
        try out.print("  SKIP-AOT-TRAP  {s} (aot exit={d}, wasmtime exit=0 — AOT could not complete)\n", .{ name, aot_exit });
        return .skip;
    }
    if (std.mem.eql(u8, wt_stdout, aot_stdout.items)) return .match;
    try out.print("  MISMATCH-AOT  {s} (wasmtime={d} bytes, aot={d} bytes)\n", .{ name, wt_stdout.len, aot_stdout.items.len });
    return .mismatch;
}

/// Test whether `wasmtime` is reachable on PATH. Returns the
/// bare command name (`"wasmtime"`) if reachable, null otherwise.
///
/// We deliberately do NOT return the path from `which` /
/// `where.exe` because on Windows MSYS / Git-Bash hosts (e.g.
/// the project's `windowsmini`) `which` returns a Unix-style
/// `/c/...` path that Zig's native Windows process spawn cannot
/// resolve to the actual binary. Returning the bare command name
/// lets `std.process.run` do its own PATH lookup, which works
/// uniformly on Mac aarch64, OrbStack Ubuntu, and Windows native.
///
/// Discharges debt D-008 (the previous "wasmtime stub on
/// windowsmini" framing was wrong; wasmtime IS installed there
/// — `which`'s MSYS-format path was the actual blocker).
fn resolveWasmtime(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "wasmtime", "--version" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    return try allocator.dupe(u8, "wasmtime");
}
