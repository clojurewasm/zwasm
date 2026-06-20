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

    // Opt-in lanes, parsed from any remaining args in any order (both OFF by
    // default — each is a dedicated diagnostic target, not the always-run gate):
    //   --aot     in-process AOT-WASI vs wasmtime (D-283 widen / D-251 validate).
    //   --wasmer  wasmer as a 2nd reference oracle vs wasmtime (§9.6 A3). The
    //             value: a wasmtime/wasmer disagreement is the divergence a
    //             single-reference gate can't see.
    //   --jit     run via the WASI-aware `--engine jit` path (`runWasmJitCaptured`)
    //             + byte-diff vs wasmtime (D-283). The real JIT-correctness net —
    //             the bare `run_runner_jit` run-stage executes with NO WASI host so
    //             every fd_write/proc_exit "traps"; this lane measures actual output.
    var aot_lane = false;
    var wasmer_lane = false;
    var jit_lane = false;
    while (arg_it.next()) |a| {
        if (std.mem.eql(u8, a, "--aot")) {
            aot_lane = true;
        } else if (std.mem.eql(u8, a, "--wasmer")) {
            wasmer_lane = true;
        } else if (std.mem.eql(u8, a, "--jit")) {
            jit_lane = true;
        }
    }

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

    // Second-oracle resolution (only when --wasmer): wasmer is Mac-only in the
    // flake, so it is absent on the x86_64 hosts — the lane then skips with a
    // notice and the wasmtime gate still runs (parallels SKIP-WASMTIME-MISSING).
    const wasmer_path_opt: ?[]u8 = if (wasmer_lane) try resolveWasmer(gpa, io) else null;
    defer if (wasmer_path_opt) |p| gpa.free(p);
    if (wasmer_lane and wasmer_path_opt == null) {
        try stdout.print(
            "SKIP-WASMER-MISSING — wasmer not on PATH; the A3 second-oracle lane needs " ++
                "`nix develop .#bench` (wasmer is Mac-only per flake.nix). wasmtime gate still runs.\n",
            .{},
        );
        try stdout.flush();
    }

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

    // wasmer second-oracle lane (§9.6 A3, opt-in). Agreement is measured
    // against the wasmtime reference (not v2) — the point is to corroborate or
    // contradict the gate's single oracle. REPORT-ONLY.
    var wasmer_agree: u32 = 0;
    var wasmer_disagree: u32 = 0;
    var wasmer_skipped: u32 = 0;

    // JIT lane (D-283, opt-in). Runs each fixture via the WASI-aware JIT path and
    // byte-diffs stdout vs wasmtime — the real `--engine jit` correctness signal.
    var jit_matched: u32 = 0;
    var jit_mismatched: u32 = 0;
    var jit_skipped: u32 = 0;

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
            }, &.{}, &.{}, null, .{})
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

        // wasmer second-oracle lane (opt-in) — placed before the v2-trap/empty
        // continues so the references are compared even where v2 can't complete.
        if (wasmer_lane and wasmer_path_opt != null) {
            switch (try wasmerCompare(gpa, io, wasmer_path_opt.?, corpus_dir, entry.name, needs_preopen, wt_stdout, wt_exit, v2_stdout.items, stdout)) {
                .agree => wasmer_agree += 1,
                .disagree => wasmer_disagree += 1,
                .skip => wasmer_skipped += 1,
            }
            try stdout.flush();
        }

        // JIT lane (opt-in) — same placement rationale as the AOT/wasmer lanes:
        // run BEFORE the v2-trap/empty continues so the JIT path is compared even
        // where the interp v2 can't complete.
        if (jit_lane) {
            switch (try jitCompare(gpa, io, bytes, entry.name, &v2_argv, needs_preopen, wt_stdout, wt_exit, stdout)) {
                .match => jit_matched += 1,
                .mismatch => jit_mismatched += 1,
                .skip => jit_skipped += 1,
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
    }
    if (wasmer_lane and wasmer_path_opt != null) {
        try stdout.print(
            "diff_runner [wasmer]: {d}/{d} agree-with-wasmtime, {d} REF-DISAGREE, {d} skipped — REPORT-ONLY\n",
            .{ wasmer_agree, total, wasmer_disagree, wasmer_skipped },
        );
    }
    if (jit_lane) {
        try stdout.print(
            "diff_runner [jit]: {d}/{d} matched vs wasmtime, {d} mismatched, {d} skipped (JIT-unsupported / trap) — GATING (fatal on mismatch)\n",
            .{ jit_matched, total, jit_mismatched, jit_skipped },
        );
    }
    // Flush the summary unconditionally: the green path (no mismatch, matched
    // >= 30) returns at the bottom WITHOUT hitting any of the branch-local
    // flushes below, so the summary line would otherwise be lost in the
    // buffered writer (observed: "diff_runner: 53/" truncation).
    try stdout.flush();

    if (mismatched != 0) std.process.exit(1);
    // D-283 discharge (2026-06-20): the JIT-vs-wasmtime lane is now a REAL gate
    // (was REPORT-ONLY). The realworld corpus reached 56/56 matched under
    // `--engine jit` once the (A) 2 miscompiles (c_sha256/emcc_fasta, D-330) and
    // (B) 9 go_* hangs (proc_exit JIT termination, D-468/ADR-0199) cleared. A
    // single JIT-vs-wasmtime byte mismatch now fails the gate. Safe on
    // wasmtime-less hosts: jit_mismatched stays 0 (all SKIP) so it can't fire
    // falsely — the interp gate's `matched >= 30` confirms wasmtime actually ran.
    if (jit_lane and jit_mismatched != 0) std.process.exit(1);
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

/// Outcome of the wasmer second-oracle lane for one fixture. `agree` =
/// wasmer's stdout equals wasmtime's (the gate's oracle is corroborated);
/// `disagree` = the two reference runtimes differ (REF-DISAGREE — the signal a
/// single-reference gate misses); `skip` = wasmer could not complete the run.
const WasmerOutcome = enum { agree, disagree, skip };

/// Run `fixture_path` through `wasmer run` and compare its stdout to the
/// wasmtime reference. On disagreement, also report which reference v2 (the
/// interp) matched, so the divergence is immediately triageable. Mirrors the
/// AOT/interp lanes' skip semantics: a wasmer non-zero exit where wasmtime
/// exited 0 = wasmer could not complete (skip, not a reference disagreement).
fn wasmerCompare(
    gpa: std.mem.Allocator,
    io: std.Io,
    wasmer_path: []const u8,
    corpus_dir: []const u8,
    name: []const u8,
    needs_preopen: bool,
    wt_stdout: []const u8,
    wt_exit: u8,
    v2_stdout: []const u8,
    out: anytype,
) !WasmerOutcome {
    // argv[0] convention differs at the CLI frontend: wasmtime (and v2) use the
    // fixture BASENAME, wasmer uses the path arg verbatim. To measure runtime
    // SEMANTICS — not the launcher's argv[0] policy — run wasmer FROM the corpus
    // dir with the bare basename, so its argv[0] matches wasmtime's. Without this
    // every argv[0]-printing guest is a spurious REF-DISAGREE.
    // The preopen fixture keeps the inherited cwd + relative `--mapdir` scratch
    // (its guest does not print a divergent argv[0]); only there is the full path
    // passed so the relative host scratch still resolves.
    // wasmer preopen syntax is `--mapdir <GUEST_DIR:HOST_DIR>` (single colon),
    // vs wasmtime's `--dir <HOST::GUEST>`.
    const fixture_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ corpus_dir, name });
    defer gpa.free(fixture_path);
    const wm_argv: []const []const u8 = if (needs_preopen)
        &.{ wasmer_path, "run", "--mapdir", "." ++ ":" ++ preopen_scratch, fixture_path }
    else
        &.{ wasmer_path, "run", name };
    const cwd_opt: std.process.Child.Cwd = if (needs_preopen) .inherit else .{ .path = corpus_dir };
    const wm_result = std.process.run(gpa, io, .{ .argv = wm_argv, .cwd = cwd_opt }) catch |err| {
        try out.print("  SKIP-WASMER-RUN  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    defer gpa.free(wm_result.stdout);
    defer gpa.free(wm_result.stderr);
    const wm_exit: u8 = switch (wm_result.term) {
        .exited => |c| c,
        else => 1,
    };
    if (wm_exit != 0 and wt_exit == 0) {
        try out.print("  SKIP-WASMER-TRAP  {s} (wasmer exit={d}, wasmtime exit=0)\n", .{ name, wm_exit });
        return .skip;
    }
    if (std.mem.eql(u8, wt_stdout, wm_result.stdout)) return .agree;

    const v2_side = if (std.mem.eql(u8, v2_stdout, wm_result.stdout))
        "v2==wasmer"
    else if (std.mem.eql(u8, v2_stdout, wt_stdout))
        "v2==wasmtime"
    else
        "v2!=both";
    try out.print(
        "  REF-DISAGREE  {s} (wasmtime={d} bytes, wasmer={d} bytes; {s})\n",
        .{ name, wt_stdout.len, wm_result.stdout.len, v2_side },
    );
    return .disagree;
}

/// Outcome of the JIT lane for one fixture — mirrors `AotOutcome`.
const JitOutcome = enum { match, mismatch, skip };

/// Run `bytes` through the WASI-aware JIT path (`cli_run.runWasmJitCaptured` =
/// the real `--engine jit`, with a stdout-capture buffer) and byte-compare vs
/// `wt_stdout`. This is the realworld JIT-correctness net (D-283): the bare
/// `run_runner_jit` run-stage executes with NO WASI host, so every fixture
/// hitting `fd_write`/`proc_exit` mid-run "traps" — a false signal. Skip
/// semantics mirror the interp/AOT lanes: a JIT non-zero exit where wasmtime
/// exited 0 = the JIT could not complete (skip, not an output regression).
fn jitCompare(
    gpa: std.mem.Allocator,
    io: std.Io,
    bytes: []const u8,
    name: []const u8,
    argv: []const []const u8,
    needs_preopen: bool,
    wt_stdout: []const u8,
    wt_exit: u8,
    out: anytype,
) !JitOutcome {
    var jit_stdout: std.ArrayList(u8) = .empty;
    defer jit_stdout.deinit(gpa);
    const preopens: []const cli_run.PreopenDir = if (needs_preopen)
        &.{.{ .host_path = preopen_scratch, .guest_path = "." }}
    else
        &.{};
    const jit_exit: u8 = cli_run.runWasmJitCaptured(gpa, io, bytes, null, argv, preopens, &.{}, &.{}, .{}, &jit_stdout, null) catch |err| {
        try out.print("  SKIP-JIT-RUN  {s}: {s}\n", .{ name, @errorName(err) });
        return .skip;
    };
    if (jit_exit != 0 and wt_exit == 0) {
        try out.print("  SKIP-JIT-TRAP  {s} (jit exit={d}, wasmtime exit=0 — JIT could not complete)\n", .{ name, jit_exit });
        return .skip;
    }
    if (std.mem.eql(u8, wt_stdout, jit_stdout.items)) return .match;
    try out.print("  MISMATCH-JIT  {s} (wasmtime={d} bytes, jit={d} bytes)\n", .{ name, wt_stdout.len, jit_stdout.items.len });
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

/// Test whether `wasmer` is reachable on PATH (the §9.6 A3 second-oracle lane).
/// wasmer is Mac-only in the flake (no x86_64-linux binary-cache hit), so this
/// returns null off the Mac dev shell and the lane skips. Bare command name is
/// returned (PATH lookup) for the same cross-host reason as resolveWasmtime.
fn resolveWasmer(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "wasmer", "--version" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    return try allocator.dupe(u8, "wasmer");
}
