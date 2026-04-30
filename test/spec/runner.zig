//! Wasm spec test runner (Phase 1 / §9.1 / 1.8 — bring-up scaffold).
//!
//! Walks a directory of `.wasm` files and drives each through the
//! frontend parser (`src/frontend/parser.zig`). Reports pass / fail
//! counts to stdout and exits 0 iff all fixtures parsed cleanly.
//!
//! 1.8 wires only the parser; the validator + lowerer integration
//! (which needs the type / function / code section-body decoders)
//! lands in §9.1 / 1.9, alongside vendoring the upstream MVP corpus
//! at `test/spec/json/` (gitignored, regenerated from
//! `test/spec/wat/` per ROADMAP §5).
//!
//! Usage:
//!   zig build test-spec               # walks test/spec/smoke/
//!   spec_runner_exe <corpus-dir>      # walks the given dir

const std = @import("std");

const parser = @import("zwasm").parser;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next() orelse unreachable; // executable name
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: spec_runner <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);
    var passed: u32 = 0;
    var failed: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wasm")) continue;

        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch |err| {
            try stdout.print("FAIL  {s}: read error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer gpa.free(bytes);

        var module = parser.parse(gpa, bytes) catch |err| {
            try stdout.print("FAIL  {s}: parse error {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        defer module.deinit(gpa);

        try stdout.print("PASS  {s} ({d} sections)\n", .{ entry.name, module.sections.items.len });
        passed += 1;
    }

    try stdout.print("\nspec_runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();

    if (failed != 0) std.process.exit(1);
}
