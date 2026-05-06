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

        if (std.mem.startsWith(u8, line, "assert_trap ")) {
            const compiled = current_compiled orelse {
                try stdout.print("FAIL  {s}: assert_trap without prior module\n", .{name});
                failed.* += 1;
                continue;
            };
            const wasm = current_wasm.?;
            const ok = runAssertTrap(gpa, wasm, &compiled, line[12..], stdout, name) catch |err| {
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

fn parseI32Token(tok: []const u8) !u32 {
    return std.fmt.parseInt(u32, tok, 10) catch
        @as(u32, @bitCast(std.fmt.parseInt(i32, tok, 10) catch return error.BadValue));
}

fn parseI64Token(tok: []const u8) !u64 {
    return std.fmt.parseInt(u64, tok, 10) catch
        @as(u64, @bitCast(std.fmt.parseInt(i64, tok, 10) catch return error.BadValue));
}

const ArgKind = enum { i32, i64 };
const ArgValue = struct { kind: ArgKind, val: u64 };

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

    // Parse arg tokens.
    var args: [2]ArgValue = undefined;
    var n_args: usize = 0;
    if (!std.mem.eql(u8, args_s, "()")) {
        var arg_it = std.mem.tokenizeScalar(u8, args_s, ' ');
        while (arg_it.next()) |tok| {
            if (n_args >= 2) {
                try stdout.print("FAIL  {s}: > 2 args unsupported ({s})\n", .{ name, args_s });
                return false;
            }
            if (std.mem.startsWith(u8, tok, "i32:")) {
                args[n_args] = .{ .kind = .i32, .val = try parseI32Token(tok[4..]) };
            } else if (std.mem.startsWith(u8, tok, "i64:")) {
                args[n_args] = .{ .kind = .i64, .val = try parseI64Token(tok[4..]) };
            } else {
                try stdout.print("FAIL  {s}: unsupported arg type ({s})\n", .{ name, tok });
                return false;
            }
            n_args += 1;
        }
    }

    // Parse expected result.
    const result_kind: ArgKind = if (std.mem.startsWith(u8, results_s, "i32:")) .i32 else if (std.mem.startsWith(u8, results_s, "i64:")) .i64 else {
        try stdout.print("FAIL  {s}: unsupported result type '{s}'\n", .{ name, results_s });
        return false;
    };
    const exp_s = results_s[4..];
    const expected: u64 = switch (result_kind) {
        .i32 => @as(u64, try parseI32Token(exp_s)),
        .i64 => try parseI64Token(exp_s),
    };

    // Dispatch on (n_args, arg-kind shape, result-kind).
    const got: u64 = blk: {
        if (n_args == 0 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            });
        }
        if (n_args == 0 and result_kind == .i64) {
            break :blk entry.callI64NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
        }
        if (n_args == 1 and args[0].kind == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_i32(compiled.module, func_idx, &rt, @intCast(args[0].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        if (n_args == 1 and args[0].kind == .i32 and result_kind == .i64) {
            break :blk entry.callI64_i32(compiled.module, func_idx, &rt, @intCast(args[0].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        if (n_args == 1 and args[0].kind == .i64 and result_kind == .i64) {
            break :blk entry.callI64_i64(compiled.module, func_idx, &rt, args[0].val) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        if (n_args == 2 and args[0].kind == .i32 and args[1].kind == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_i32i32(compiled.module, func_idx, &rt, @intCast(args[0].val), @intCast(args[1].val)) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        try stdout.print("FAIL  {s}: unsupported (n_args={d}, arg/result shape) for {s}({s}) -> {s}\n", .{ name, n_args, fn_name, args_s, results_s });
        return false;
    };

    if (got != expected) {
        try stdout.print("FAIL  {s}: {s}({s}) → got {d}, expected {d}\n", .{ name, fn_name, args_s, got, expected });
        return false;
    }
    return true;
}

/// `assert_trap <fn> <args>` (reason discrimination is D-022 work).
/// Invokes the function and checks that `Error.Trap` is observed.
fn runAssertTrap(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) !bool {
    const sp1 = std.mem.findScalar(u8, rest, ' ') orelse return error.BadDirective;
    const fn_name = rest[0..sp1];
    const args_s = rest[sp1 + 1 ..];

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

    var args: [2]ArgValue = undefined;
    var n_args: usize = 0;
    if (!std.mem.eql(u8, args_s, "()")) {
        var arg_it = std.mem.tokenizeScalar(u8, args_s, ' ');
        while (arg_it.next()) |tok| {
            if (n_args >= 2) {
                try stdout.print("FAIL  {s}: > 2 args unsupported in assert_trap ({s})\n", .{ name, args_s });
                return false;
            }
            if (std.mem.startsWith(u8, tok, "i32:")) {
                args[n_args] = .{ .kind = .i32, .val = try parseI32Token(tok[4..]) };
            } else if (std.mem.startsWith(u8, tok, "i64:")) {
                args[n_args] = .{ .kind = .i64, .val = try parseI64Token(tok[4..]) };
            } else {
                try stdout.print("FAIL  {s}: unsupported arg type ({s})\n", .{ name, tok });
                return false;
            }
            n_args += 1;
        }
    }

    // Dispatch — same shape table as runAssertReturn but we discard
    // the i32/i64 distinction on the result side (any Error.Trap is
    // a pass for assert_trap; reason discrimination = D-022 / M3).
    const got_trap: bool = blk: {
        if (n_args == 0) {
            _ = entry.callI32NoArgs(compiled.module, func_idx, &rt) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        if (n_args == 1 and args[0].kind == .i32) {
            _ = entry.callI32_i32(compiled.module, func_idx, &rt, @intCast(args[0].val)) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        if (n_args == 1 and args[0].kind == .i64) {
            _ = entry.callI64_i64(compiled.module, func_idx, &rt, args[0].val) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        if (n_args == 2 and args[0].kind == .i32 and args[1].kind == .i32) {
            _ = entry.callI32_i32i32(compiled.module, func_idx, &rt, @intCast(args[0].val), @intCast(args[1].val)) catch |err| switch (err) {
                error.Trap => break :blk true,
            };
            break :blk false;
        }
        try stdout.print("FAIL  {s}: assert_trap unsupported (n_args={d}) for {s}({s})\n", .{ name, n_args, fn_name, args_s });
        return false;
    };

    if (!got_trap) {
        try stdout.print("FAIL  {s}: assert_trap {s}({s}) → did NOT trap\n", .{ name, fn_name, args_s });
        return false;
    }
    return true;
}
