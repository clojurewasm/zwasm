//! Realworld JIT compile-baseline runner (§9.7 / 7.9 chunk a).
//!
//! Walks `test/realworld/wasm/` and, for each `.wasm` fixture,
//! invokes `engine.runner.compileWasm` (= the JIT pipeline:
//! parse → validate → lower → liveness → regalloc → arm64/x86_64
//! emit → linker.link). Reports per-fixture compile outcome
//! categorised:
//!
//!   COMPILE-PASS    — `compileWasm` returned a `JitModule`.
//!                     Module body fully encoded by the host's
//!                     JIT backend. Does NOT run the entry yet
//!                     (chunks 7.9-c onward wire WASI host
//!                     dispatch + JitRuntime memory init).
//!   COMPILE-IMPORTS — `error.UnsupportedImports`. The wasm
//!                     module imports at least one host
//!                     function (typically WASI). The
//!                     compileWasm import-reject lifts in
//!                     chunk 7.9-b alongside the import-aware
//!                     linker / JitRuntime host-call dispatch.
//!   COMPILE-OP      — `error.UnsupportedOp`. Module compiles
//!                     past parse + validate but the JIT emit
//!                     pass rejects an op (typically memory.copy
//!                     / memory.fill / sign-extension /
//!                     i64-FP-globals — the residual ARM64 emit
//!                     gaps post-§9.7 / 7.7).
//!   COMPILE-VAL     — `error.ModuleAllocFailed` (validator
//!                     rejection — orthogonal to the JIT gate;
//!                     queued as a separate gap).
//!   FAIL-OTHER      — any other error class (real bug).
//!
//! The §9.7 / 7.9 exit criterion is "40+ realworld samples (out
//! of 50) run via ARM64 JIT". This chunk-a baseline measures
//! the COMPILE-side coverage; the chunks 7.9-b/c/d add the
//! infrastructure to convert COMPILE-PASS into RUN-PASS.
//!
//! Mirror of `test/realworld/run_runner.zig`'s shape (interp
//! mode); shares the corpus walk + categorisation idiom.
//!
//! Usage:
//!   zig build test-realworld-run-jit       # walks test/realworld/wasm/
//!   realworld_run_jit_runner_exe <corpus-dir>

const std = @import("std");
const builtin = @import("builtin");

const zwasm = @import("zwasm");
const engine_runner = zwasm.engine.runner;

/// Per-fixture timeout for the run-stage. cljw_*/tinygo_fib
/// fixtures have compute-heavy loops; without isolation they
/// can hang the runner. Fork-and-kill is the only hard
/// guarantee against guest tight loops (cooperative cancellation
/// requires the guest to honour a flag).
const FIXTURE_TIMEOUT_SECS: u32 = 5;

/// Subprocess isolation is only available where `fork(2)` works.
/// On Windows the runner falls back to in-process serial
/// execution: that path may hang on a tight-loop fixture, but
/// the windowsmini host already runs `test-realworld-run-jit`
/// in compile-only mode by default (ZWASM_JIT_RUN gating). The
/// loss is acceptable for the §9.8 / 8.1 MVP per
/// `.claude/rules/no_workaround.md`'s "graceful degradation"
/// allowance.
const use_fork = builtin.os.tag == .linux or builtin.os.tag == .macos;

/// Result classes mirrored from the inline switch the parent
/// process used pre-fork. Encoded into the child's exit code so
/// the parent can reconstruct the category without IPC.
const RunResult = enum { pass, trap, no_entry, unsupported_sig, other, timeout };

// SIGALRM handler state — read by `sigalrmHandler` (async-signal
// context, can only touch volatile globals + call async-safe
// libc primitives).
var child_pid_for_alarm: std.c.pid_t = 0;
var alarm_fired: bool = false;

fn sigalrmHandler(_: std.posix.SIG) callconv(.c) void {
    alarm_fired = true;
    if (child_pid_for_alarm != 0) {
        // SIGKILL — guarantees termination even if the child is
        // in an uninterruptible kernel state (mmap during JIT
        // page allocation, futex during a hung loop, etc.).
        // `std.c.kill` is async-signal-safe.
        _ = std.c.kill(child_pid_for_alarm, .KILL);
    }
}

fn installSigalrmHandler() void {
    if (comptime !use_fork) return;
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = sigalrmHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.ALRM, &act, null);
}

fn classifyRunError(err: anyerror) RunResult {
    return switch (err) {
        error.Trap => .trap,
        error.ExportNotFound, error.ExportIsNotFunction => .no_entry,
        error.UnsupportedEntrySignature => .unsupported_sig,
        else => .other,
    };
}

fn runFixtureNoFork(gpa: std.mem.Allocator, bytes: []const u8) RunResult {
    const r = engine_runner.runVoidExport(gpa, bytes, "_start");
    if (r) |_| return .pass else |e| return classifyRunError(e);
}

fn runFixtureWithTimeout(gpa: std.mem.Allocator, bytes: []const u8) RunResult {
    if (comptime !use_fork) return runFixtureNoFork(gpa, bytes);

    // Zig 0.16's `std.posix.fork` / `waitpid` are not yet
    // re-exposed (only `kill` / `sigaction` / `sigemptyset` /
    // `W` macros sit in posix); use the libc shims directly.
    const pid = std.c.fork();
    if (pid == -1) return .other;
    if (pid == 0) {
        // Child: run the entry, encode the category as the exit
        // code, and `std.process.exit` (skips parent-side defers).
        const r = engine_runner.runVoidExport(gpa, bytes, "_start");
        const code: u8 = if (r) |_| 0 else |err| switch (err) {
            error.Trap => 1,
            error.ExportNotFound, error.ExportIsNotFunction => 2,
            error.UnsupportedEntrySignature => 3,
            else => 4,
        };
        std.process.exit(code);
    }

    // Parent: arm the alarm, block in waitpid; the SIGALRM
    // handler kills the child with SIGKILL on timeout.
    child_pid_for_alarm = pid;
    alarm_fired = false;
    _ = std.c.alarm(FIXTURE_TIMEOUT_SECS);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    _ = std.c.alarm(0);
    child_pid_for_alarm = 0;

    const u_status: u32 = @bitCast(status);
    if (std.posix.W.IFEXITED(u_status)) {
        return switch (std.posix.W.EXITSTATUS(u_status)) {
            0 => .pass,
            1 => .trap,
            2 => .no_entry,
            3 => .unsupported_sig,
            else => .other,
        };
    }
    // Killed by signal — if the alarm fired, attribute to timeout;
    // otherwise the child crashed (SIGSEGV / SIGBUS / similar) →
    // .other so the runner can still report the gap.
    if (alarm_fired) return .timeout;
    return .other;
}

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
        try stdout.print("usage: run_runner_jit <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(2);
    };
    defer dir.close(io);

    // Run-stage gating (chunk 7.9-d-4): invoking the JIT-compiled
    // `_start` entry can hang on fixtures with long-running loops
    // (no per-fixture timeout in this MVP). Default OFF to keep
    // test-all responsive; opt-in via env var
    // `ZWASM_JIT_RUN=1` for run-pass measurement. Per-fixture
    // timeout via subprocess fork is post-d-4 (see handover plan
    // for d-5 — child-process isolation + SIGALRM deadline).
    const run_stage_enabled: bool = blk: {
        const env_val = init.environ_map.get("ZWASM_JIT_RUN") orelse break :blk false;
        break :blk std.mem.eql(u8, env_val, "1");
    };
    if (run_stage_enabled and comptime !use_fork) {
        try stdout.print(
            "(run-stage requested via ZWASM_JIT_RUN=1 but per-fixture isolation requires fork(2) — falling back to compile-only on this host)\n",
            .{},
        );
        try stdout.flush();
    }
    const run_stage_active = run_stage_enabled and use_fork;
    if (run_stage_active) {
        try stdout.print("(run-stage enabled via ZWASM_JIT_RUN=1; per-fixture timeout {d}s)\n", .{FIXTURE_TIMEOUT_SECS});
        installSigalrmHandler();
    }

    var total: u32 = 0;
    var compile_pass: u32 = 0;
    var run_pass: u32 = 0;
    var run_trap: u32 = 0;
    var run_no_entry: u32 = 0;
    var run_unsupported_sig: u32 = 0;
    var run_timeout: u32 = 0;
    var compile_imports: u32 = 0;
    var compile_op: u32 = 0;
    var compile_val: u32 = 0;
    var fail_other: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;
        total += 1;

        // Per-fixture stderr trace gated on the same env var as
        // the run-stage. Crash-time stdout is buffered and the
        // recursive-panic path skips the flush, so stderr is the
        // only way to know which fixture is in flight when a SEGV
        // hits. Compile-only mode stays quiet to keep the output
        // table-friendly.
        if (run_stage_active) std.debug.print("[try] {s}\n", .{entry.name});
        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(64 << 20)) catch |err| {
            try stdout.print("FAIL-OTHER  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            fail_other += 1;
            continue;
        };
        defer gpa.free(bytes);

        const result = engine_runner.compileWasm(gpa, bytes);
        if (result) |compiled_const| {
            var compiled = compiled_const;
            compiled.deinit(gpa);
            compile_pass += 1;
            if (run_stage_active) {
                // Try to invoke `_start` (the canonical WASI entry)
                // inside a fork-isolated child with a SIGALRM
                // deadline. See helper `runFixtureWithTimeout`
                // above for the exit-code → RunResult decoding.
                switch (runFixtureWithTimeout(gpa, bytes)) {
                    .pass => {
                        try stdout.print("RUN-PASS  {s}\n", .{entry.name});
                        try stdout.flush();
                        run_pass += 1;
                    },
                    .trap => {
                        try stdout.print("RUN-TRAP  {s}\n", .{entry.name});
                        try stdout.flush();
                        run_trap += 1;
                    },
                    .no_entry => {
                        try stdout.print("RUN-NO-ENTRY  {s}\n", .{entry.name});
                        try stdout.flush();
                        run_no_entry += 1;
                    },
                    .unsupported_sig => {
                        try stdout.print("RUN-UNSUPPORTED-SIG  {s}\n", .{entry.name});
                        try stdout.flush();
                        run_unsupported_sig += 1;
                    },
                    .timeout => {
                        try stdout.print("RUN-TIMEOUT  {s} (>{d}s)\n", .{ entry.name, FIXTURE_TIMEOUT_SECS });
                        try stdout.flush();
                        run_timeout += 1;
                    },
                    .other => {
                        try stdout.print("RUN-OTHER  {s}\n", .{entry.name});
                        try stdout.flush();
                        fail_other += 1;
                    },
                }
            } else {
                try stdout.print("COMPILE-PASS  {s}\n", .{entry.name});
            }
        } else |err| switch (err) {
            error.UnsupportedImports => {
                try stdout.print("COMPILE-IMPORTS  {s} (host imports — chunk 7.9-b will lift)\n", .{entry.name});
                compile_imports += 1;
            },
            error.UnsupportedOp,
            error.UnsupportedControlFlow,
            // Chunk 7.9-b unhid these by lifting UnsupportedImports:
            // SlotOverflow = regalloc pool exhaustion (post-MVP
            // spill ratchet, ROADMAP §A12), surfaces same shape as
            // UnsupportedOp in the COMPILE / RUN classification.
            error.SlotOverflow,
            => {
                try stdout.print("COMPILE-OP  {s}: {s}\n", .{ entry.name, @errorName(err) });
                compile_op += 1;
            },
            error.StackTypeMismatch,
            error.ArityMismatch,
            error.InvalidLocalIndex,
            error.StackUnderflow,
            error.InvalidFuncIndex,
            error.InvalidGlobalIndex,
            error.BadValType,
            error.UnsupportedEntrySignature,
            // Chunk 7.9-b unhid: realworld fixtures with malformed
            // (per our validator) func-types. Investigation belongs
            // alongside chunk 7.9-c (some go binaries use multi-
            // value sigs that the v2 validator pre-decodes
            // strictly; the spec requires it but our InvalidFunctype
            // shape may be tightening a check beyond strict need).
            error.InvalidFunctype,
            => {
                try stdout.print("COMPILE-VAL  {s}: {s}\n", .{ entry.name, @errorName(err) });
                compile_val += 1;
            },
            else => {
                try stdout.print("FAIL-OTHER  {s}: {s}\n", .{ entry.name, @errorName(err) });
                fail_other += 1;
            },
        }
    }

    if (run_stage_active) {
        try stdout.print(
            "\nrealworld_run_jit_runner: {d}/{d} compile-pass | run: {d} pass, {d} trap, {d} no-entry, {d} unsupported-sig, {d} timeout (>{d}s) | compile gaps: {d} imports, {d} op, {d} val | {d} fail-other\n",
            .{ compile_pass, total, run_pass, run_trap, run_no_entry, run_unsupported_sig, run_timeout, FIXTURE_TIMEOUT_SECS, compile_imports, compile_op, compile_val, fail_other },
        );
    } else {
        try stdout.print(
            "\nrealworld_run_jit_runner: {d}/{d} compile-pass, {d} compile-imports, {d} compile-op, {d} compile-val, {d} fail-other (run-stage disabled; set ZWASM_JIT_RUN=1 to invoke entries)\n",
            .{ compile_pass, total, compile_imports, compile_op, compile_val, fail_other },
        );
    }
    try stdout.flush();

    // Chunk 7.9-a baseline gate: this runner exits 0 regardless
    // (compile categorisation is informational at baseline). The
    // §9.7 / 7.9 exit criterion (40+ run-pass) gates on the
    // chunks-b/c/d successor that turns COMPILE-PASS into RUN-
    // PASS. fail-other is a real bug; it does fail the gate.
    if (fail_other != 0) std.process.exit(1);
}
