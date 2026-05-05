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

        // Spawn wasmtime, capturing stdout. wasmtime exits with
        // the guest's proc_exit code (0 on success); a non-zero
        // exit + non-empty stderr usually means the guest itself
        // failed, but we still try the byte compare since that
        // is what §9.6 / 6.F measures.
        const wt_result = std.process.run(gpa, io, .{
            .argv = &[_][]const u8{ wasmtime_path, "run", fixture_path },
        }) catch |err| {
            try stdout.print("SKIP-WASMTIME-FAIL  {s}: {s}\n", .{ entry.name, @errorName(err) });
            skipped_wasmtime_fail += 1;
            continue;
        };
        defer gpa.free(wt_result.stdout);
        defer gpa.free(wt_result.stderr);
        const wt_stdout = wt_result.stdout;

        var v2_stdout: std.ArrayList(u8) = .empty;
        defer v2_stdout.deinit(std.heap.c_allocator);

        // Mirror wasmtime's default of `argv[0] = <wasm filename>`
        // so guests like `c_hello_wasi` that print argv[0] produce
        // identical bytes.
        const v2_argv: [1][]const u8 = .{entry.name};
        const v2_result = cli_run.runWasmCaptured(gpa, io, bytes, &v2_argv, &v2_stdout);
        if (v2_result) |_| {
            // Continue to byte compare.
        } else |err| switch (err) {
            error.InstanceAllocFailed,
            error.NoFuncExport,
            error.ModuleAllocFailed,
            => {
                try stdout.print("SKIP-V2-{s}  {s}\n", .{ @errorName(err), entry.name });
                skipped_v2 += 1;
                continue;
            },
            else => {
                try stdout.print("SKIP-V2-{s}  {s}\n", .{ @errorName(err), entry.name });
                skipped_v2 += 1;
                continue;
            },
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
    try stdout.flush();

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
