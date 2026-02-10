// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! zwasm CLI — run, inspect, and validate WebAssembly modules.
//!
//! Usage:
//!   zwasm run <file.wasm> [args...]
//!   zwasm run --invoke <func> <file.wasm> [i32:N ...]
//!   zwasm inspect <file.wasm>
//!   zwasm validate <file.wasm>

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const module_mod = @import("module.zig");
const opcode = @import("opcode.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var buf: [8192]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;

    var err_buf: [4096]u8 = undefined;
    var err_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &err_writer.interface;

    if (args.len < 2) {
        printUsage(stdout);
        try stdout.flush();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "run")) {
        try cmdRun(allocator, args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "inspect")) {
        try cmdInspect(allocator, args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "validate")) {
        try cmdValidate(allocator, args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage(stdout);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        try stdout.print("zwasm 0.1.0\n", .{});
    } else {
        try stderr.print("error: unknown command '{s}'\n", .{command});
        try stderr.flush();
        printUsage(stdout);
    }
    try stdout.flush();
}

fn printUsage(w: *std.Io.Writer) void {
    w.print(
        \\zwasm — Zig WebAssembly Runtime
        \\
        \\Usage:
        \\  zwasm run [options] <file.wasm> [args...]
        \\  zwasm inspect <file.wasm>
        \\  zwasm validate <file.wasm>
        \\  zwasm version
        \\  zwasm help
        \\
        \\Run options:
        \\  --invoke <func>     Call <func> instead of _start
        \\  --dir <path>        Preopen a host directory (repeatable)
        \\  --env KEY=VALUE     Set a WASI environment variable (repeatable)
        \\
    , .{}) catch {};
}

// ============================================================
// zwasm run
// ============================================================

fn cmdRun(allocator: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var invoke_name: ?[]const u8 = null;
    var wasm_path: ?[]const u8 = null;
    var func_args_start: usize = 0;

    // Collected options
    var env_keys: std.ArrayList([]const u8) = .empty;
    defer env_keys.deinit(allocator);
    var env_vals: std.ArrayList([]const u8) = .empty;
    defer env_vals.deinit(allocator);
    var preopen_paths: std.ArrayList([]const u8) = .empty;
    defer preopen_paths.deinit(allocator);

    // Parse options
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--invoke")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --invoke requires a function name\n", .{});
                try stderr.flush();
                return;
            }
            invoke_name = args[i];
        } else if (std.mem.eql(u8, args[i], "--dir")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --dir requires a path\n", .{});
                try stderr.flush();
                return;
            }
            try preopen_paths.append(allocator, args[i]);
        } else if (std.mem.eql(u8, args[i], "--env")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --env requires KEY=VALUE\n", .{});
                try stderr.flush();
                return;
            }
            if (std.mem.indexOfScalar(u8, args[i], '=')) |eq_pos| {
                try env_keys.append(allocator, args[i][0..eq_pos]);
                try env_vals.append(allocator, args[i][eq_pos + 1 ..]);
            } else {
                try stderr.print("error: --env value must be KEY=VALUE, got '{s}'\n", .{args[i]});
                try stderr.flush();
                return;
            }
        } else if (args[i].len > 0 and args[i][0] == '-') {
            try stderr.print("error: unknown option '{s}'\n", .{args[i]});
            try stderr.flush();
            return;
        } else {
            wasm_path = args[i];
            func_args_start = i + 1;
            break;
        }
    }

    const path = wasm_path orelse {
        try stderr.print("error: no wasm file specified\n", .{});
        try stderr.flush();
        return;
    };

    const wasm_bytes = readFile(allocator, path) catch |err| {
        try stderr.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return;
    };
    defer allocator.free(wasm_bytes);

    if (invoke_name) |func_name| {
        // Invoke a specific function with u64 args
        var module = types.WasmModule.load(allocator, wasm_bytes) catch |err| {
            try stderr.print("error: failed to load module: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return;
        };
        defer module.deinit();

        // Parse function arguments as u64
        const func_args_slice = args[func_args_start..];
        const wasm_args = try allocator.alloc(u64, func_args_slice.len);
        defer allocator.free(wasm_args);

        for (func_args_slice, 0..) |arg, idx| {
            wasm_args[idx] = std.fmt.parseInt(u64, arg, 10) catch {
                try stderr.print("error: invalid argument '{s}' (expected integer)\n", .{arg});
                try stderr.flush();
                return;
            };
        }

        // Determine result count from export info
        var result_count: usize = 1;
        if (module.getExportInfo(func_name)) |info| {
            result_count = info.result_types.len;
        }

        const results = try allocator.alloc(u64, result_count);
        defer allocator.free(results);
        @memset(results, 0);

        module.invoke(func_name, wasm_args, results) catch |err| {
            try stderr.print("error: invoke '{s}' failed: {s}\n", .{ func_name, @errorName(err) });
            try stderr.flush();
            return;
        };

        // Print results
        for (results, 0..) |r, idx| {
            if (idx > 0) try stdout.print(" ", .{});
            try stdout.print("{d}", .{r});
        }
        if (results.len > 0) try stdout.print("\n", .{});
        try stdout.flush();
    } else {
        // Build WASI args: [wasm_path] ++ remaining args
        const wasi_str_args = args[func_args_start..];
        var wasi_args_list: std.ArrayList([:0]const u8) = .empty;
        defer wasi_args_list.deinit(allocator);

        // First arg is the program name (wasm path)
        try wasi_args_list.append(allocator, @ptrCast(path));
        for (wasi_str_args) |a| {
            try wasi_args_list.append(allocator, @ptrCast(a));
        }

        // Run as WASI module (_start)
        var module = types.WasmModule.loadWasiWithOptions(allocator, wasm_bytes, .{
            .args = wasi_args_list.items,
            .env_keys = env_keys.items,
            .env_vals = env_vals.items,
            .preopen_paths = preopen_paths.items,
        }) catch |err| {
            try stderr.print("error: failed to load WASI module: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return;
        };
        defer module.deinit();

        var no_args = [_]u64{};
        var no_results = [_]u64{};
        module.invoke("_start", &no_args, &no_results) catch |err| {
            try stderr.print("error: _start failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return;
        };
    }
}

// ============================================================
// zwasm inspect
// ============================================================

fn cmdInspect(allocator: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len < 1) {
        try stderr.print("error: no wasm file specified\n", .{});
        try stderr.flush();
        return;
    }

    const path = args[0];
    const wasm_bytes = readFile(allocator, path) catch |err| {
        try stderr.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return;
    };
    defer allocator.free(wasm_bytes);

    var module = module_mod.Module.init(allocator, wasm_bytes);
    defer module.deinit();
    module.decode() catch |err| {
        try stderr.print("error: decode failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return;
    };

    try stdout.print("Module: {s}\n", .{path});
    try stdout.print("Size:   {d} bytes\n\n", .{wasm_bytes.len});

    // Exports
    if (module.exports.items.len > 0) {
        try stdout.print("Exports ({d}):\n", .{module.exports.items.len});
        for (module.exports.items) |exp| {
            const kind_str = switch (exp.kind) {
                .func => "func",
                .table => "table",
                .memory => "memory",
                .global => "global",
            };
            try stdout.print("  {s} {s}", .{ kind_str, exp.name });

            // Show function signature if available
            if (exp.kind == .func) {
                if (module.getFuncType(exp.index)) |ft| {
                    try stdout.print(" (", .{});
                    for (ft.params, 0..) |p, idx| {
                        if (idx > 0) try stdout.print(", ", .{});
                        try stdout.print("{s}", .{valTypeName(p)});
                    }
                    try stdout.print(") -> (", .{});
                    for (ft.results, 0..) |r, idx| {
                        if (idx > 0) try stdout.print(", ", .{});
                        try stdout.print("{s}", .{valTypeName(r)});
                    }
                    try stdout.print(")", .{});
                }
            }
            try stdout.print("\n", .{});
        }
    }

    // Imports
    if (module.imports.items.len > 0) {
        try stdout.print("\nImports ({d}):\n", .{module.imports.items.len});
        for (module.imports.items) |imp| {
            const kind_str = switch (imp.kind) {
                .func => "func",
                .table => "table",
                .memory => "memory",
                .global => "global",
            };
            try stdout.print("  {s} {s}::{s}", .{ kind_str, imp.module, imp.name });
            if (imp.kind == .func and imp.index < module.types.items.len) {
                const ft = module.types.items[imp.index];
                try stdout.print(" (", .{});
                for (ft.params, 0..) |p, idx| {
                    if (idx > 0) try stdout.print(", ", .{});
                    try stdout.print("{s}", .{valTypeName(p)});
                }
                try stdout.print(") -> (", .{});
                for (ft.results, 0..) |r, idx| {
                    if (idx > 0) try stdout.print(", ", .{});
                    try stdout.print("{s}", .{valTypeName(r)});
                }
                try stdout.print(")", .{});
            }
            try stdout.print("\n", .{});
        }
    }

    // Memory
    const total_memories = module.memories.items.len + module.num_imported_memories;
    if (total_memories > 0) {
        try stdout.print("\nMemories ({d}):\n", .{total_memories});
        for (module.memories.items) |mem| {
            const max_str: []const u8 = if (mem.limits.max != null) "bounded" else "unbounded";
            try stdout.print("  initial={d} pages ({d} KiB), {s}\n", .{
                mem.limits.min,
                @as(u64, mem.limits.min) * 64,
                max_str,
            });
        }
    }

    // Tables
    if (module.tables.items.len > 0) {
        try stdout.print("\nTables ({d}):\n", .{module.tables.items.len});
        for (module.tables.items) |tbl| {
            const ref_str = switch (tbl.reftype) {
                .funcref => "funcref",
                .externref => "externref",
            };
            try stdout.print("  {s} min={d}\n", .{ ref_str, tbl.limits.min });
        }
    }

    // Globals
    if (module.globals.items.len > 0) {
        try stdout.print("\nGlobals ({d}):\n", .{module.globals.items.len});
        for (module.globals.items) |g| {
            const mut_str: []const u8 = if (g.mutability == 1) "mut" else "const";
            try stdout.print("  {s} {s}\n", .{ valTypeName(g.valtype), mut_str });
        }
    }

    // Functions
    const total_funcs = module.functions.items.len;
    try stdout.print("\nFunctions: {d} defined, {d} imported\n", .{
        total_funcs,
        module.num_imported_funcs,
    });

    try stdout.flush();
}

// ============================================================
// zwasm validate
// ============================================================

fn cmdValidate(allocator: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len < 1) {
        try stderr.print("error: no wasm file specified\n", .{});
        try stderr.flush();
        return;
    }

    const path = args[0];
    const wasm_bytes = readFile(allocator, path) catch |err| {
        try stderr.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return;
    };
    defer allocator.free(wasm_bytes);

    var module = module_mod.Module.init(allocator, wasm_bytes);
    defer module.deinit();
    module.decode() catch |err| {
        try stderr.print("error: validation failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return;
    };

    try stdout.print("{s}: valid ({d} bytes, {d} functions, {d} exports)\n", .{
        path,
        wasm_bytes.len,
        module.functions.items.len + module.num_imported_funcs,
        module.exports.items.len,
    });
    try stdout.flush();
}

// ============================================================
// Helpers
// ============================================================

fn valTypeName(vt: opcode.ValType) []const u8 {
    return switch (vt) {
        .i32 => "i32",
        .i64 => "i64",
        .f32 => "f32",
        .f64 => "f64",
        .v128 => "v128",
        .funcref => "funcref",
        .externref => "externref",
    };
}

fn readFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    const read = try file.readAll(data);
    return data[0..read];
}
