//! WASI 0.1 fixture runner (Phase 4 / §9.4 / 4.9).
//!
//! Walks a directory of `.wasm` fixtures, for each one calls
//! `cli_run.runWasm` with the host's io context, then compares
//! the resulting exit code against the matching
//! `<basename>.expected_exit` text file (a single integer 0..255).
//!
//! Usage:
//!   zig build test-wasi-p1               # walks test/wasi/
//!   wasi_runner_exe <fixture-dir>        # walks the given dir
//!
//! Exit code: 0 iff every fixture matches its expected exit
//! code; 1 otherwise. Prints pass / fail per fixture.

const std = @import("std");

const zwasm = @import("zwasm");
const cli_run = zwasm.cli_run;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next() orelse unreachable;
    const dir_arg = arg_it.next() orelse {
        try stdout.print("usage: wasi_runner <fixture-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const dir_path = try gpa.dupe(u8, dir_arg);
    defer gpa.free(dir_path);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ dir_path, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var passed: u32 = 0;
    var failed: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;

        const wasm_bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(64 * 1024 * 1024)) catch |err| {
            try stdout.print("FAIL  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer gpa.free(wasm_bytes);

        // Locate matching .expected_exit file.
        const stem_len = entry.name.len - ".wasm".len;
        const expected_name = try std.fmt.allocPrint(gpa, "{s}.expected_exit", .{entry.name[0..stem_len]});
        defer gpa.free(expected_name);

        const expected_bytes = dir.readFileAlloc(io, expected_name, gpa, .limited(16)) catch |err| {
            try stdout.print("FAIL  {s}: missing {s} ({s})\n", .{ entry.name, expected_name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer gpa.free(expected_bytes);

        const expected_trimmed = std.mem.trim(u8, expected_bytes, &std.ascii.whitespace);
        const expected = std.fmt.parseInt(u8, expected_trimmed, 10) catch |err| {
            try stdout.print("FAIL  {s}: malformed expected '{s}' ({s})\n", .{ entry.name, expected_trimmed, @errorName(err) });
            failed += 1;
            continue;
        };

        const actual = cli_run.runWasm(gpa, io, wasm_bytes) catch |err| {
            try stdout.print("FAIL  {s}: runtime error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };

        if (actual == expected) {
            try stdout.print("PASS  {s} (exit={d})\n", .{ entry.name, actual });
            passed += 1;
        } else {
            try stdout.print("FAIL  {s}: expected exit={d}, got {d}\n", .{ entry.name, expected, actual });
            failed += 1;
        }
    }

    try stdout.print("\nwasi_runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}
