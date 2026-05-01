//! Wast-directive spec runner (Phase 2 / §9.2 / 2.7).
//!
//! Walks one or more corpus subdirectories, each containing a
//! `manifest.txt` plus the `.wasm` files referenced by it. Each
//! manifest line is `<directive> <filename>`:
//!
//!   `valid <file>`     — parse + validate; expect success.
//!   `invalid <file>`   — parse + validate; expect failure
//!                        (mirrors `(assert_invalid …)` in
//!                        `.wast`).
//!   `malformed <file>` — parse alone; expect failure (mirrors
//!                        `(assert_malformed …)` with binary
//!                        module form).
//!
//! The manifest format is produced by `scripts/regen_test_data_2_0.sh`
//! from the `commands[]` array of `wast2json`'s JSON output;
//! choosing a flat text format avoids Zig-side JSON parsing in
//! the runner (the upstream JSON shape is wide and shifting).
//!
//! Runtime assertions (`assert_return`, `assert_trap`, etc.) and
//! text-form `assert_malformed` are not represented in the
//! manifest because chunk 2.7-1's gate is parse + validate only;
//! interp-driven commands land alongside §9.2 / 2.8.
//!
//! Usage:
//!   wast_runner <corpus-root>
//! where `<corpus-root>` is a directory whose immediate children
//! are subdirectories each containing a `manifest.txt`.

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
    _ = arg_it.next() orelse unreachable;
    const corpus_root_arg = arg_it.next() orelse {
        try stdout.print("usage: wast_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var passed: u32 = 0;
    var failed: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        try runCorpus(io, gpa, &root, entry.name, stdout, &passed, &failed);
    }

    try stdout.print("\nwast_runner: {d} passed, {d} failed\n", .{ passed, failed });
    try stdout.flush();
    if (failed != 0) std.process.exit(1);
}

fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
) !void {
    var dir = root.openDir(io, name, .{}) catch |err| {
        try stdout.print("FAIL  {s}/: openDir {s}\n", .{ name, @errorName(err) });
        failed.* += 1;
        return;
    };
    defer dir.close(io);

    const manifest_bytes = dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16)) catch |err| {
        try stdout.print("FAIL  {s}/manifest.txt: {s}\n", .{ name, @errorName(err) });
        failed.* += 1;
        return;
    };
    defer gpa.free(manifest_bytes);

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse {
            try stdout.print("FAIL  {s}: bad manifest line '{s}'\n", .{ name, line });
            failed.* += 1;
            continue;
        };
        const directive = line[0..sp];
        const filename = line[sp + 1 ..];

        const wasm_bytes = dir.readFileAlloc(io, filename, gpa, .limited(4 << 20)) catch |err| {
            try stdout.print("FAIL  {s}/{s}: read {s}\n", .{ name, filename, @errorName(err) });
            failed.* += 1;
            continue;
        };
        defer gpa.free(wasm_bytes);

        const got_ok = checkOne(gpa, directive, wasm_bytes) catch |err| {
            try stdout.print("FAIL  {s}/{s}: runner error {s}\n", .{ name, filename, @errorName(err) });
            failed.* += 1;
            continue;
        };

        if (got_ok) {
            passed.* += 1;
            try stdout.print("PASS  {s}/{s} ({s})\n", .{ name, filename, directive });
        } else {
            failed.* += 1;
            try stdout.print("FAIL  {s}/{s} ({s}) — directive expectation not met\n", .{ name, filename, directive });
        }
    }
}

/// Run a single `<directive> <file>` step. Returns `true` if the
/// observed parse / validate result matches the directive's
/// expectation. Parse / validate errors are folded into the
/// boolean — only allocator OOM bubbles out.
fn checkOne(gpa: std.mem.Allocator, directive: []const u8, wasm_bytes: []const u8) !bool {
    if (std.mem.eql(u8, directive, "malformed")) {
        var module = parser.parse(gpa, wasm_bytes) catch return true;
        defer module.deinit(gpa);
        return false;
    }

    var module = parser.parse(gpa, wasm_bytes) catch {
        return std.mem.eql(u8, directive, "invalid");
    };
    defer module.deinit(gpa);

    const ok = if (validateModule(gpa, &module)) |_| true else |_| false;
    if (std.mem.eql(u8, directive, "valid")) return ok;
    if (std.mem.eql(u8, directive, "invalid")) return !ok;
    return false;
}

fn validateModule(gpa: std.mem.Allocator, module: *parser.Module) !void {
    try runOne(gpa, module);
}

/// Decode the type / function / code sections of a parsed module
/// and run the validator over each defined function. Mirrors
/// `test/spec/runner.zig`'s helper of the same name (kept in sync
/// because both runners exercise the same frontend pipeline).
fn runOne(gpa: std.mem.Allocator, module: *parser.Module) !void {
    const type_section = module.find(.@"type");
    const import_section = module.find(.import);
    const func_section = module.find(.function);
    const global_section = module.find(.global);
    const code_section = module.find(.code);

    const code_body = if (code_section) |s| s.body else return;

    var types_owned = if (type_section) |s|
        try sections.decodeTypes(gpa, s.body)
    else
        sections.Types{ .arena = std.heap.ArenaAllocator.init(gpa), .items = &.{} };
    defer types_owned.deinit();

    var imports_owned: ?sections.Imports = if (import_section) |s|
        try sections.decodeImports(gpa, s.body)
    else
        null;
    defer if (imports_owned) |*im| im.deinit();

    const defined_func_indices = if (func_section) |s|
        try sections.decodeFunctions(gpa, s.body)
    else
        try gpa.alloc(u32, 0);
    defer gpa.free(defined_func_indices);

    var codes = try sections.decodeCodes(gpa, code_body);
    defer codes.deinit();

    if (codes.items.len != defined_func_indices.len) return error.FunctionCountMismatch;

    var imp_func_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .func) {
        imp_func_count += 1;
    };
    const total_funcs = imp_func_count + defined_func_indices.len;
    const func_types = try gpa.alloc(zwasm.zir.FuncType, total_funcs);
    defer gpa.free(func_types);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .func) {
            const ti = it.payload.func_typeidx;
            if (ti >= types_owned.items.len) return error.InvalidTypeIndex;
            func_types[cursor] = types_owned.items[ti];
            cursor += 1;
        };
        for (defined_func_indices) |type_idx| {
            if (type_idx >= types_owned.items.len) return error.InvalidTypeIndex;
            func_types[cursor] = types_owned.items[type_idx];
            cursor += 1;
        }
    }

    var globals_owned: ?sections.Globals = if (global_section) |s|
        try sections.decodeGlobals(gpa, s.body)
    else
        null;
    defer if (globals_owned) |*g| g.deinit();

    var imp_global_count: usize = 0;
    if (imports_owned) |im| for (im.items) |it| if (it.kind == .global) {
        imp_global_count += 1;
    };
    const def_global_count: usize = if (globals_owned) |g| g.items.len else 0;
    const total_globals = imp_global_count + def_global_count;
    const global_entries = try gpa.alloc(validator.GlobalEntry, total_globals);
    defer gpa.free(global_entries);
    {
        var cursor: usize = 0;
        if (imports_owned) |im| for (im.items) |it| if (it.kind == .global) {
            global_entries[cursor] = .{
                .valtype = it.payload.global.valtype,
                .mutable = it.payload.global.mutable,
            };
            cursor += 1;
        };
        if (globals_owned) |g| for (g.items) |gd| {
            global_entries[cursor] = .{ .valtype = gd.valtype, .mutable = gd.mutable };
            cursor += 1;
        };
    }

    for (codes.items, defined_func_indices) |code, type_idx| {
        const sig = types_owned.items[type_idx];
        try validator.validateFunction(
            sig,
            code.locals,
            code.body,
            func_types,
            global_entries,
            types_owned.items,
            0,
            &.{},
            0,
        );
    }
}
