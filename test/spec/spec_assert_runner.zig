//! Spec assertion runner — JIT-execute + compare against
//! `assert_return` expectations (§9.7 / 7.5-spec-assertion-driver-a).
//!
//! Walks subdirectories of a corpus root produced by
//! `scripts/regen_spec_1_0_assert.sh`. Each subdirectory has a
//! `manifest.txt` with directives:
//!
//!   `module <file>`                                — load .wasm into JIT
//!   `assert_return <fn> () -> <type>:<value>`      — invoke 0-arg
//!   `assert_return <fn> i32:<v> -> i32:<v>`        — invoke 1-i32-arg
//!   `skip <reason>`                                — record as skipped
//!
//! Chunk-a covers ONLY i32→i32 (0/1 args). Subsequent chunks
//! widen the surface (i64, f32/f64, multi-arg, traps).
//!
//! Usage:
//!   spec_assert_runner <corpus-root>
//! exits non-zero if any `failed > 0`.

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_root_arg = arg_it.next() orelse {
        try stdout.print("usage: spec_assert_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer root.close(io);

    var it = root.iterate();
    while (try it.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        try runCorpus(io, gpa, &root, dir_entry.name, stdout, &passed, &failed, &skipped);
    }

    try stdout.print("\nspec_assert_runner: {d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });
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
    skipped: *u32,
) !void {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);

    const manifest_bytes = try dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 16));
    defer gpa.free(manifest_bytes);

    var current_wasm: ?[]u8 = null;
    var current_compiled: ?runner_mod.CompiledWasm = null;
    defer {
        if (current_wasm) |b| gpa.free(b);
        if (current_compiled) |*c| c.deinit(gpa);
    }

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "skip ")) {
            skipped.* += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "module ")) {
            const file = line[7..];
            // Drop any prior compiled module.
            if (current_compiled) |*c| c.deinit(gpa);
            current_compiled = null;
            if (current_wasm) |b| gpa.free(b);
            current_wasm = null;

            const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                try stdout.print("FAIL  {s}/{s} module read: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current_wasm = wasm_bytes;

            const compiled = runner_mod.compileWasm(gpa, wasm_bytes) catch |err| {
                try stdout.print("FAIL  {s}/{s} compile: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            current_compiled = compiled;
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_return ")) {
            const compiled = current_compiled orelse {
                try stdout.print("FAIL  {s}: assert_return without prior module\n", .{name});
                failed.* += 1;
                continue;
            };
            const wasm = current_wasm.?;
            const ok = runAssertReturn(gpa, wasm, &compiled, line[14..], stdout, name) catch |err| {
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                failed.* += 1;
                continue;
            };
            if (ok) {
                passed.* += 1;
                try stdout.print("PASS  {s}: {s}\n", .{ name, line });
            } else {
                failed.* += 1;
            }
            continue;
        }

        try stdout.print("FAIL  {s}: unknown directive '{s}'\n", .{ name, line });
        failed.* += 1;
    }
}

fn runAssertReturn(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) !bool {
    // rest = "<fn> <args> -> <results>"
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = rest[0..arrow];
    const results_s = rest[arrow + 4 ..];

    const sp1 = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    const fn_name = lhs[0..sp1];
    const args_s = lhs[sp1 + 1 ..];

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    var memory: [0]u8 = .{};
    var rt: entry.JitRuntime = .{
        .vm_base = &memory,
        .mem_limit = 0,
        .funcptr_base = undefined,
        .table_size = 0,
        .typeidx_base = undefined,
        .trap_flag = 0,
        .globals_base = undefined,
        .globals_count = 0,
    };

    // Parse args.
    const got: u32 = blk: {
        if (std.mem.eql(u8, args_s, "()")) {
            break :blk entry.callI32NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
        }
        // Single i32 arg: "i32:<value>"
        if (std.mem.startsWith(u8, args_s, "i32:")) {
            const v_s = args_s[4..];
            const a0 = std.fmt.parseInt(u32, v_s, 10) catch
                @as(u32, @bitCast(std.fmt.parseInt(i32, v_s, 10) catch return error.BadValue));
            break :blk entry.callI32_i32(compiled.module, func_idx, &rt, a0) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        try stdout.print("FAIL  {s}: unsupported args shape '{s}'\n", .{ name, args_s });
        return false;
    };

    // Parse expected result: "i32:<value>"
    if (!std.mem.startsWith(u8, results_s, "i32:")) {
        try stdout.print("FAIL  {s}: unsupported result shape '{s}'\n", .{ name, results_s });
        return false;
    }
    const exp_s = results_s[4..];
    const expected = std.fmt.parseInt(u32, exp_s, 10) catch
        @as(u32, @bitCast(std.fmt.parseInt(i32, exp_s, 10) catch return error.BadValue));

    if (got != expected) {
        try stdout.print("FAIL  {s}: {s}({s}) → got {d}, expected {d}\n", .{ name, fn_name, args_s, got, expected });
        return false;
    }
    return true;
}
