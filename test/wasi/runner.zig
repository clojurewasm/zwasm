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

        // Optional `.expected_stdout` companion: when present,
        // capture guest stdout and byte-compare. When absent,
        // exit-code-only assertion is fine.
        const expected_stdout_name = try std.fmt.allocPrint(gpa, "{s}.expected_stdout", .{entry.name[0..stem_len]});
        defer gpa.free(expected_stdout_name);

        const expected_stdout_opt: ?[]u8 = dir.readFileAlloc(io, expected_stdout_name, gpa, .limited(64 * 1024)) catch null;
        defer if (expected_stdout_opt) |s| gpa.free(s);

        // The capture buffer is appended to inside the binding's
        // fd_write thunk using the host's c_allocator-backed Host
        // (see zwasm_wasi_config_new). Use the same allocator for
        // deinit so the alloc/free pair matches.
        var stdout_capture: std.ArrayList(u8) = .empty;
        defer stdout_capture.deinit(std.heap.c_allocator);
        const stdout_capture_ptr: ?*std.ArrayList(u8) = if (expected_stdout_opt != null) &stdout_capture else null;

        const wasi_argv: [1][]const u8 = .{entry.name};
        const actual = cli_run.runWasmCaptured(gpa, io, wasm_bytes, &wasi_argv, stdout_capture_ptr) catch |err| {
            try stdout.print("FAIL  {s}: runtime error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };

        if (actual != expected) {
            try stdout.print("FAIL  {s}: expected exit={d}, got {d}\n", .{ entry.name, expected, actual });
            failed += 1;
            continue;
        }

        if (expected_stdout_opt) |expected_stdout| {
            // Cross-platform: git autocrlf may convert LF -> CRLF
            // in the .expected_stdout file on Windows checkout.
            // Normalise both sides to LF before byte-compare.
            const expected_norm = try normaliseLineEndings(gpa, expected_stdout);
            defer gpa.free(expected_norm);
            const actual_norm = try normaliseLineEndings(gpa, stdout_capture.items);
            defer gpa.free(actual_norm);

            if (!std.mem.eql(u8, expected_norm, actual_norm)) {
                try stdout.print(
                    "FAIL  {s}: stdout mismatch\n  expected ({d}B): {s}\n  got      ({d}B): {s}\n",
                    .{ entry.name, expected_norm.len, expected_norm, actual_norm.len, actual_norm },
                );
                failed += 1;
                continue;
            }
            try stdout.print("PASS  {s} (exit={d}, stdout={d}B)\n", .{ entry.name, actual, stdout_capture.items.len });
        } else {
            try stdout.print("PASS  {s} (exit={d})\n", .{ entry.name, actual });
        }
        passed += 1;
    }

    try stdout.print("\nwasi_runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

/// Replace every `\r\n` byte pair with a single `\n`. Returns a
/// fresh slice owned by the caller; consumes a single
/// `Allocator.alloc` regardless of whether any conversion was
/// needed (keeps the call site's defer-free pattern uniform).
fn normaliseLineEndings(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, src.len);
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\r' and i + 1 < src.len and src[i + 1] == '\n') continue;
        try out.append(alloc, src[i]);
    }
    return out.toOwnedSlice(alloc);
}
