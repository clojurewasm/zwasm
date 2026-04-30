//! Wasm spec test runner (Phase 1 / §9.1 / 1.8 → 1.9).
//!
//! Walks a directory of `.wasm` files and for each one runs:
//!   parser.parse  →  sections.decodeTypes + decodeFunctions +
//!   decodeCodes  →  validator.validateFunction (per function).
//!
//! Reports pass / fail counts to stdout and exits 0 iff all
//! fixtures parsed and validated.
//!
//! Usage:
//!   zig build test-spec               # walks test/spec/smoke/
//!   spec_runner_exe <corpus-dir>      # walks the given dir

const std = @import("std");

const zwasm = @import("zwasm");
const parser = zwasm.parser;
const sections = zwasm.sections;
const validator = zwasm.validator;

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

        runOne(gpa, &module) catch |err| {
            try stdout.print("FAIL  {s}: {s}\n", .{ entry.name, @errorName(err) });
            failed += 1;
            continue;
        };
        try stdout.print("PASS  {s} ({d} sections)\n", .{ entry.name, module.sections.items.len });
        passed += 1;
    }

    try stdout.print("\nspec_runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();

    if (failed != 0) std.process.exit(1);
}

/// Decode the type / function / code sections of a parsed module and
/// run the validator over each defined function. Returns on the first
/// error (caller treats it as a per-fixture failure).
fn runOne(gpa: std.mem.Allocator, module: *parser.Module) !void {
    const type_section = module.find(.@"type");
    const func_section = module.find(.function);
    const code_section = module.find(.code);

    // No code section → nothing to validate.
    const code_body = if (code_section) |s| s.body else return;

    var types_owned = if (type_section) |s|
        try sections.decodeTypes(gpa, s.body)
    else
        sections.Types{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{} };
    defer types_owned.deinit();

    const func_indices = if (func_section) |s|
        try sections.decodeFunctions(gpa, s.body)
    else
        try gpa.alloc(u32, 0);
    defer gpa.free(func_indices);

    var codes = try sections.decodeCodes(gpa, code_body);
    defer codes.deinit();

    if (codes.items.len != func_indices.len) return error.FunctionCountMismatch;

    for (codes.items, func_indices) |code, type_idx| {
        if (type_idx >= types_owned.items.len) return error.InvalidTypeIndex;
        const sig = types_owned.items[type_idx];
        try validator.validateFunction(sig, code.locals, code.body);
    }
}
