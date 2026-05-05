//! Edge-case fixture runner (sub-7.5b-iii).
//!
//! Walks `test/edge_cases/p<N>/<concept>/<case>.wasm` triples,
//! reads the sibling `.expect`, runs the wasm through the
//! ARM64 JIT via `jit.run_wasm.runI32Export`, and compares
//! the result. Reports pass/fail counts to stdout.
//!
//! Usage:
//!   zwasm-edge-runner <corpus-dir>
//!
//! Mac aarch64 only today (the underlying JIT runner panics on
//! other hosts). Skipped on non-darwin-aarch64; the test-edge
//! build step gates accordingly.

const std = @import("std");
const builtin = @import("builtin");

const zwasm = @import("zwasm");
const run_wasm = zwasm.engine.runner;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    if (!(builtin.os.tag == .macos and builtin.cpu.arch == .aarch64)) {
        try stdout.print("edge-case runner: skipped (Mac aarch64 only)\n", .{});
        try stdout.flush();
        return;
    }

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?; // executable name
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: zwasm-edge-runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };

    var passed: u32 = 0;
    var failed: u32 = 0;
    try walkAndRun(io, gpa, stdout, corpus_dir_arg, &passed, &failed);

    try stdout.print("\nedge-case runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

/// Recursively walks `root_path`. For each `<case>.wasm` whose
/// sibling `<case>.expect` exists, runs the fixture and
/// compares the result.
fn walkAndRun(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    root_path: []const u8,
    passed: *u32,
    failed: *u32,
) !void {
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, root_path, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ root_path, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry_| {
        if (entry_.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry_.path, ".wasm")) continue;

        const wasm_bytes = root.readFileAlloc(io, entry_.path, gpa, .limited(1 << 20)) catch |err| {
            try stdout.print("FAIL  {s}: read .wasm: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
            continue;
        };
        defer gpa.free(wasm_bytes);

        // Sibling `.expect` (replace `.wasm` extension).
        const expect_path = try std.mem.concat(gpa, u8, &.{
            entry_.path[0 .. entry_.path.len - ".wasm".len],
            ".expect",
        });
        defer gpa.free(expect_path);
        const expect_bytes = root.readFileAlloc(io, expect_path, gpa, .limited(4096)) catch |err| {
            try stdout.print("FAIL  {s}: read .expect: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
            continue;
        };
        defer gpa.free(expect_bytes);

        runOne(gpa, stdout, entry_.path, wasm_bytes, expect_bytes, passed, failed) catch |err| {
            try stdout.print("FAIL  {s}: {s}\n", .{ entry_.path, @errorName(err) });
            failed.* += 1;
        };
    }
}

/// Parse `expect_bytes` to determine the assertion (value or
/// trap), run the fixture, compare. Increments `passed` /
/// `failed` accordingly.
fn runOne(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    name: []const u8,
    wasm_bytes: []const u8,
    expect_bytes: []const u8,
    passed: *u32,
    failed: *u32,
) !void {
    const expect = parseExpect(expect_bytes);
    const result = run_wasm.runI32Export(gpa, wasm_bytes, "test");

    switch (expect) {
        .i32 => |want| {
            if (result) |got| {
                if (got == want) {
                    try stdout.print("PASS  {s} = {d}\n", .{ name, got });
                    passed.* += 1;
                } else {
                    try stdout.print("FAIL  {s}: expected i32:{d}, got i32:{d}\n", .{ name, want, got });
                    failed.* += 1;
                }
            } else |err| switch (err) {
                error.Trap => {
                    try stdout.print("FAIL  {s}: expected i32:{d}, got trap\n", .{ name, want });
                    failed.* += 1;
                },
                else => |e| return e,
            }
        },
        .trap => {
            if (result) |got| {
                try stdout.print("FAIL  {s}: expected trap, got i32:{d}\n", .{ name, got });
                failed.* += 1;
            } else |err| switch (err) {
                error.Trap => {
                    try stdout.print("PASS  {s} (trap)\n", .{name});
                    passed.* += 1;
                },
                else => |e| return e,
            }
        },
        .unsupported => {
            try stdout.print("SKIP  {s}: unsupported expectation format\n", .{name});
        },
    }
}

const Expectation = union(enum) {
    i32: u32,
    trap: void,
    unsupported: void,
};

fn parseExpect(bytes: []const u8) Expectation {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "i32:")) {
        const num_str = std.mem.trim(u8, trimmed["i32:".len..], " \t");
        const v = std.fmt.parseInt(i64, num_str, 10) catch return .unsupported;
        // Wrap negatives into u32 representation (i32.MIN → 0x80000000).
        return .{ .i32 = @bitCast(@as(i32, @intCast(v))) };
    }
    if (std.mem.startsWith(u8, trimmed, "trap:")) return .trap;
    return .unsupported;
}
