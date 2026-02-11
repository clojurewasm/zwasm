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
const vm_mod = @import("vm.zig");
const trace_mod = vm_mod.trace_mod;

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
        const ok = try cmdRun(allocator, args[2..], stdout, stderr);
        try stdout.flush();
        if (!ok) std.process.exit(1);
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
        \\  zwasm inspect [--json] <file.wasm>
        \\  zwasm validate <file.wasm>
        \\  zwasm version
        \\  zwasm help
        \\
        \\Run options:
        \\  --invoke <func>     Call <func> instead of _start
        \\  --batch             Batch mode: read invocations from stdin
        \\  --link name=file    Link a module as import source (repeatable)
        \\  --dir <path>        Preopen a host directory (repeatable)
        \\  --env KEY=VALUE     Set a WASI environment variable (repeatable)
        \\  --profile           Print execution profile (opcode frequency, call counts)
        \\  --trace=CATS        Trace categories: jit,regir,exec,mem,call (comma-separated)
        \\  --dump-regir=N      Dump RegIR for function index N
        \\  --dump-jit=N        Dump JIT disassembly for function index N
        \\
    , .{}) catch {};
}

// ============================================================
// zwasm run
// ============================================================

fn cmdRun(allocator: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var invoke_name: ?[]const u8 = null;
    var wasm_path: ?[]const u8 = null;
    var func_args_start: usize = 0;
    var batch_mode = false;
    var profile_mode = false;
    var trace_categories: u8 = 0;
    var dump_regir_func: ?u32 = null;
    var dump_jit_func: ?u32 = null;

    // Collected options
    var env_keys: std.ArrayList([]const u8) = .empty;
    defer env_keys.deinit(allocator);
    var env_vals: std.ArrayList([]const u8) = .empty;
    defer env_vals.deinit(allocator);
    var preopen_paths: std.ArrayList([]const u8) = .empty;
    defer preopen_paths.deinit(allocator);
    var link_names: std.ArrayList([]const u8) = .empty;
    defer link_names.deinit(allocator);
    var link_paths: std.ArrayList([]const u8) = .empty;
    defer link_paths.deinit(allocator);

    // Parse options
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--batch")) {
            batch_mode = true;
        } else if (std.mem.eql(u8, args[i], "--profile")) {
            profile_mode = true;
        } else if (std.mem.eql(u8, args[i], "--invoke")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --invoke requires a function name\n", .{});
                try stderr.flush();
                return false;
            }
            invoke_name = args[i];
        } else if (std.mem.eql(u8, args[i], "--dir")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --dir requires a path\n", .{});
                try stderr.flush();
                return false;
            }
            try preopen_paths.append(allocator, args[i]);
        } else if (std.mem.eql(u8, args[i], "--env")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --env requires KEY=VALUE\n", .{});
                try stderr.flush();
                return false;
            }
            if (std.mem.indexOfScalar(u8, args[i], '=')) |eq_pos| {
                try env_keys.append(allocator, args[i][0..eq_pos]);
                try env_vals.append(allocator, args[i][eq_pos + 1 ..]);
            } else {
                try stderr.print("error: --env value must be KEY=VALUE, got '{s}'\n", .{args[i]});
                try stderr.flush();
                return false;
            }
        } else if (std.mem.eql(u8, args[i], "--link")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --link requires name=path.wasm\n", .{});
                try stderr.flush();
                return false;
            }
            if (std.mem.indexOfScalar(u8, args[i], '=')) |eq_pos| {
                try link_names.append(allocator, args[i][0..eq_pos]);
                try link_paths.append(allocator, args[i][eq_pos + 1 ..]);
            } else {
                try stderr.print("error: --link value must be name=path.wasm\n", .{});
                try stderr.flush();
                return false;
            }
        } else if (std.mem.startsWith(u8, args[i], "--trace=")) {
            trace_categories = trace_mod.parseCategories(args[i]["--trace=".len..]);
        } else if (std.mem.startsWith(u8, args[i], "--dump-regir=")) {
            dump_regir_func = std.fmt.parseInt(u32, args[i]["--dump-regir=".len..], 10) catch {
                try stderr.print("error: --dump-regir requires a function index (u32)\n", .{});
                try stderr.flush();
                return false;
            };
        } else if (std.mem.startsWith(u8, args[i], "--dump-jit=")) {
            dump_jit_func = std.fmt.parseInt(u32, args[i]["--dump-jit=".len..], 10) catch {
                try stderr.print("error: --dump-jit requires a function index (u32)\n", .{});
                try stderr.flush();
                return false;
            };
        } else if (args[i].len > 0 and args[i][0] == '-') {
            try stderr.print("error: unknown option '{s}'\n", .{args[i]});
            try stderr.flush();
            return false;
        } else {
            wasm_path = args[i];
            func_args_start = i + 1;
            break;
        }
    }

    const path = wasm_path orelse {
        try stderr.print("error: no wasm file specified\n", .{});
        try stderr.flush();
        return false;
    };

    const wasm_bytes = readFile(allocator, path) catch |err| {
        try stderr.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return false;
    };
    defer allocator.free(wasm_bytes);

    // Load linked modules
    var linked_modules: std.ArrayList(*types.WasmModule) = .empty;
    defer {
        for (linked_modules.items) |lm| lm.deinit();
        linked_modules.deinit(allocator);
    }
    // Keep wasm bytes alive as long as the modules reference them
    var linked_bytes: std.ArrayList([]const u8) = .empty;
    defer {
        for (linked_bytes.items) |bytes| allocator.free(bytes);
        linked_bytes.deinit(allocator);
    }
    var import_entries: std.ArrayList(types.ImportEntry) = .empty;
    defer import_entries.deinit(allocator);

    for (link_names.items, link_paths.items) |name, lpath| {
        const link_bytes = readFile(allocator, lpath) catch |err| {
            try stderr.print("error: cannot read linked module '{s}': {s}\n", .{ lpath, @errorName(err) });
            try stderr.flush();
            return false;
        };
        // Load with already-loaded linked modules as imports (transitive chains)
        const lm = if (import_entries.items.len > 0)
            types.WasmModule.loadWithImports(allocator, link_bytes, import_entries.items) catch
                // Retry without imports if the linked module doesn't need them
                types.WasmModule.load(allocator, link_bytes) catch |err| {
                    allocator.free(link_bytes);
                    try stderr.print("error: failed to load linked module '{s}': {s}\n", .{ lpath, @errorName(err) });
                    try stderr.flush();
                    return false;
                }
        else
            types.WasmModule.load(allocator, link_bytes) catch |err| {
                allocator.free(link_bytes);
                try stderr.print("error: failed to load linked module '{s}': {s}\n", .{ lpath, @errorName(err) });
                try stderr.flush();
                return false;
            };
        try linked_bytes.append(allocator, link_bytes);
        try linked_modules.append(allocator, lm);
        try import_entries.append(allocator, .{
            .module = name,
            .source = .{ .wasm_module = lm },
        });
    }

    if (batch_mode) {
        return cmdBatch(allocator, wasm_bytes, import_entries.items, stdout, stderr);
    }

    const imports_slice: ?[]const types.ImportEntry = if (import_entries.items.len > 0)
        import_entries.items
    else
        null;

    if (invoke_name) |func_name| {
        // Invoke a specific function with u64 args.
        // Try plain load first; if it fails with ImportNotFound, retry with WASI.
        // When --link is used, also pass imports. Combine with WASI on fallback.
        const wasi_opts: types.WasiOptions = .{
            .args = &.{},
            .env_keys = env_keys.items,
            .env_vals = env_vals.items,
            .preopen_paths = preopen_paths.items,
        };

        const module = load_blk: {
            if (imports_slice != null) {
                // With --link: try imports only, then imports + WASI
                break :load_blk types.WasmModule.loadWithImports(allocator, wasm_bytes, imports_slice.?) catch |err| {
                    if (err == error.ImportNotFound) {
                        break :load_blk types.WasmModule.loadWasiWithImports(allocator, wasm_bytes, imports_slice, wasi_opts) catch |err2| {
                            try stderr.print("error: failed to load module: {s}\n", .{@errorName(err2)});
                            try stderr.flush();
                            return false;
                        };
                    }
                    try stderr.print("error: failed to load module: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    return false;
                };
            }
            // No --link: try plain, then WASI
            break :load_blk types.WasmModule.load(allocator, wasm_bytes) catch |err| {
                if (err == error.ImportNotFound) {
                    break :load_blk types.WasmModule.loadWasiWithOptions(allocator, wasm_bytes, wasi_opts) catch |err2| {
                        try stderr.print("error: failed to load module: {s}\n", .{@errorName(err2)});
                        try stderr.flush();
                        return false;
                    };
                }
                try stderr.print("error: failed to load module: {s}\n", .{@errorName(err)});
                try stderr.flush();
                return false;
            };
        };
        defer module.deinit();

        // Enable profiling if requested (note: disables JIT for accurate opcode counting)
        var profile = vm_mod.Profile.init();
        if (profile_mode) {
            module.vm.profile = &profile;
            try stderr.print("[note] --profile disables JIT for accurate opcode counting\n", .{});
            try stderr.flush();
        }

        // Enable tracing if requested
        var trace_config = trace_mod.TraceConfig{
            .categories = trace_categories,
            .dump_regir_func = dump_regir_func,
            .dump_jit_func = dump_jit_func,
        };
        if (trace_categories != 0 or dump_regir_func != null or dump_jit_func != null) {
            module.vm.trace = &trace_config;
        }

        // Parse function arguments as u64
        const func_args_slice = args[func_args_start..];
        const wasm_args = try allocator.alloc(u64, func_args_slice.len);
        defer allocator.free(wasm_args);

        for (func_args_slice, 0..) |arg, idx| {
            wasm_args[idx] = std.fmt.parseInt(u64, arg, 10) catch {
                try stderr.print("error: invalid argument '{s}' (expected integer)\n", .{arg});
                try stderr.flush();
                return false;
            };
        }

        // Determine result count and types from export info
        var result_count: usize = 1;
        const export_info = module.getExportInfo(func_name);
        if (export_info) |info| {
            result_count = info.result_types.len;
        }

        const results = try allocator.alloc(u64, result_count);
        defer allocator.free(results);
        @memset(results, 0);

        module.invoke(func_name, wasm_args, results) catch |err| {
            try stderr.print("error: invoke '{s}' failed: {s}\n", .{ func_name, @errorName(err) });
            try stderr.flush();
            if (profile_mode) printProfile(&profile, stderr);
            return false;
        };

        // Print results (truncate 32-bit types to u32)
        for (results, 0..) |r, idx| {
            if (idx > 0) try stdout.print(" ", .{});
            const val = if (export_info) |info| blk: {
                if (idx < info.result_types.len) {
                    break :blk switch (info.result_types[idx]) {
                        .i32, .f32 => r & 0xFFFFFFFF,
                        else => r,
                    };
                }
                break :blk r;
            } else r;
            try stdout.print("{d}", .{val});
        }
        if (results.len > 0) try stdout.print("\n", .{});
        try stdout.flush();

        if (profile_mode) printProfile(&profile, stderr);
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

        // Run as WASI module (_start), with --link imports if provided
        const wasi_opts2: types.WasiOptions = .{
            .args = wasi_args_list.items,
            .env_keys = env_keys.items,
            .env_vals = env_vals.items,
            .preopen_paths = preopen_paths.items,
        };
        var module = types.WasmModule.loadWasiWithImports(allocator, wasm_bytes, imports_slice, wasi_opts2) catch |err| {
            try stderr.print("error: failed to load WASI module: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return false;
        };
        defer module.deinit();

        // Enable profiling if requested
        var wasi_profile = vm_mod.Profile.init();
        if (profile_mode) module.vm.profile = &wasi_profile;

        // Enable tracing if requested
        var wasi_trace_config = trace_mod.TraceConfig{
            .categories = trace_categories,
            .dump_regir_func = dump_regir_func,
            .dump_jit_func = dump_jit_func,
        };
        if (trace_categories != 0 or dump_regir_func != null or dump_jit_func != null) {
            module.vm.trace = &wasi_trace_config;
        }

        var no_args = [_]u64{};
        var no_results = [_]u64{};
        module.invoke("_start", &no_args, &no_results) catch |err| {
            // proc_exit triggers a Trap — check if exit_code was set
            if (module.getWasiExitCode()) |code| {
                if (profile_mode) printProfile(&wasi_profile, stderr);
                if (code != 0) std.process.exit(@truncate(code));
                return true;
            }
            try stderr.print("error: _start failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            if (profile_mode) printProfile(&wasi_profile, stderr);
            return false;
        };

        if (profile_mode) printProfile(&wasi_profile, stderr);

        // Normal completion — check for explicit exit code
        if (module.getWasiExitCode()) |code| {
            if (code != 0) std.process.exit(@truncate(code));
        }
    }
    return true;
}

// ============================================================
// Profile printing
// ============================================================

fn printProfile(profile: *const vm_mod.Profile, w: *std.Io.Writer) void {
    w.print("\n=== Execution Profile ===\n", .{}) catch {};
    w.print("Total instructions: {d}\n", .{profile.total_instrs}) catch {};
    w.print("Function calls:     {d}\n\n", .{profile.call_count}) catch {};

    // Collect and sort opcode counts
    const Entry = struct { op: u8, count: u64 };
    var entries: [256]Entry = undefined;
    var n: usize = 0;
    for (0..256) |i| {
        if (profile.opcode_counts[i] > 0) {
            entries[n] = .{ .op = @intCast(i), .count = profile.opcode_counts[i] };
            n += 1;
        }
    }

    // Sort by count descending (simple insertion sort, max 256 entries)
    if (n == 0) return;
    for (1..n) |i| {
        var j = i;
        while (j > 0 and entries[j].count > entries[j - 1].count) {
            const tmp = entries[j];
            entries[j] = entries[j - 1];
            entries[j - 1] = tmp;
            j -= 1;
        }
    }

    // Print top 20 opcodes
    const top = @min(n, 20);
    if (top > 0) {
        w.print("Top opcodes:\n", .{}) catch {};
        for (0..top) |i| {
            const e = entries[i];
            const name = opcodeName(e.op);
            const pct = if (profile.total_instrs > 0)
                @as(f64, @floatFromInt(e.count)) / @as(f64, @floatFromInt(profile.total_instrs)) * 100.0
            else
                0.0;
            if (std.mem.eql(u8, name, "unknown")) {
                w.print("  0x{X:0>2}{s:22} {d:>12} ({d:.1}%)\n", .{ e.op, "", e.count, pct }) catch {};
            } else {
                w.print("  {s:24} {d:>12} ({d:.1}%)\n", .{ name, e.count, pct }) catch {};
            }
        }
    }

    // Print misc opcode counts if any
    var has_misc = false;
    for (0..32) |i| {
        if (profile.misc_counts[i] > 0) { has_misc = true; break; }
    }
    if (has_misc) {
        w.print("\nMisc opcodes (0xFC prefix):\n", .{}) catch {};
        for (0..32) |i| {
            if (profile.misc_counts[i] > 0) {
                const name = miscOpcodeName(@intCast(i));
                w.print("  {s:24} {d:>12}\n", .{ name, profile.misc_counts[i] }) catch {};
            }
        }
    }

    w.print("=========================\n", .{}) catch {};
    w.flush() catch {};
}

fn opcodeName(op: u8) []const u8 {
    return switch (op) {
        0x00 => "unreachable",
        0x01 => "nop",
        0x02 => "block",
        0x03 => "loop",
        0x04 => "if",
        0x05 => "else",
        0x0B => "end",
        0x0C => "br",
        0x0D => "br_if",
        0x0E => "br_table",
        0x0F => "return",
        0x10 => "call",
        0x11 => "call_indirect",
        0x1A => "drop",
        0x1B => "select",
        0x20 => "local.get",
        0x21 => "local.set",
        0x22 => "local.tee",
        0x23 => "global.get",
        0x24 => "global.set",
        0x28 => "i32.load",
        0x29 => "i64.load",
        0x2A => "f32.load",
        0x2B => "f64.load",
        0x2C => "i32.load8_s",
        0x2D => "i32.load8_u",
        0x2E => "i32.load16_s",
        0x2F => "i32.load16_u",
        0x36 => "i32.store",
        0x37 => "i64.store",
        0x38 => "f32.store",
        0x39 => "f64.store",
        0x3A => "i32.store8",
        0x3B => "i32.store16",
        0x41 => "i32.const",
        0x42 => "i64.const",
        0x43 => "f32.const",
        0x44 => "f64.const",
        0x45 => "i32.eqz",
        0x46 => "i32.eq",
        0x47 => "i32.ne",
        0x48 => "i32.lt_s",
        0x49 => "i32.lt_u",
        0x4A => "i32.gt_s",
        0x4B => "i32.gt_u",
        0x4C => "i32.le_s",
        0x4D => "i32.le_u",
        0x4E => "i32.ge_s",
        0x4F => "i32.ge_u",
        0x50 => "i64.eqz",
        0x51 => "i64.eq",
        0x53 => "i64.lt_s",
        0x6A => "i32.add",
        0x6B => "i32.sub",
        0x6C => "i32.mul",
        0x6D => "i32.div_s",
        0x6E => "i32.div_u",
        0x71 => "i32.and",
        0x72 => "i32.or",
        0x73 => "i32.xor",
        0x74 => "i32.shl",
        0x75 => "i32.shr_s",
        0x76 => "i32.shr_u",
        0x7C => "i64.add",
        0x7D => "i64.sub",
        0x7E => "i64.mul",
        0x92 => "f32.add",
        0x93 => "f32.sub",
        0x94 => "f32.mul",
        0x95 => "f32.div",
        0x99 => "f64.abs",
        0x9A => "f64.neg",
        0x9F => "f64.sqrt",
        0xA0 => "f64.add",
        0xA1 => "f64.sub",
        0xA2 => "f64.mul",
        0xA3 => "f64.div",
        0xA7 => "i32.wrap_i64",
        0xAC => "i64.extend_i32_s",
        0xAD => "i64.extend_i32_u",
        0xFC => "misc_prefix",
        0xFD => "simd_prefix",
        // Superinstructions (predecoded fused ops, 0xE0-0xEF)
        0xE0 => "local.get+get",
        0xE1 => "local.get+const",
        0xE2 => "locals+add",
        0xE3 => "locals+sub",
        0xE4 => "local+const+add",
        0xE5 => "local+const+sub",
        0xE6 => "local+const+lt_s",
        0xE7 => "local+const+ge_s",
        0xE8 => "local+const+lt_u",
        0xE9 => "locals+gt_s",
        0xEA => "locals+le_s",
        else => "unknown",
    };
}

fn miscOpcodeName(sub: u8) []const u8 {
    return switch (sub) {
        0x00 => "i32.trunc_sat_f32_s",
        0x01 => "i32.trunc_sat_f32_u",
        0x02 => "i32.trunc_sat_f64_s",
        0x03 => "i32.trunc_sat_f64_u",
        0x08 => "memory.init",
        0x09 => "data.drop",
        0x0A => "memory.copy",
        0x0B => "memory.fill",
        0x0C => "table.init",
        0x0D => "elem.drop",
        0x0E => "table.copy",
        0x0F => "table.grow",
        0x10 => "table.size",
        0x11 => "table.fill",
        else => "misc.unknown",
    };
}

// ============================================================
// zwasm inspect
// ============================================================

fn cmdInspect(allocator: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var json_mode = false;
    var path: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            path = arg;
        }
    }

    const file_path = path orelse {
        try stderr.print("error: no wasm file specified\n", .{});
        try stderr.flush();
        return;
    };
    const wasm_bytes = readFile(allocator, file_path) catch |err| {
        try stderr.print("error: cannot read '{s}': {s}\n", .{ file_path, @errorName(err) });
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

    if (json_mode) {
        try printInspectJson(&module, file_path, wasm_bytes.len, stdout);
        try stdout.flush();
        return;
    }

    try stdout.print("Module: {s}\n", .{file_path});
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
                .tag => "tag",
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
                .tag => "tag",
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

fn printInspectJson(module: *const module_mod.Module, file_path: []const u8, size: usize, w: *std.Io.Writer) !void {
    try w.print("{{\"module\":\"{s}\",\"size\":{d}", .{ file_path, size });

    // Exports
    try w.print(",\"exports\":[", .{});
    for (module.exports.items, 0..) |exp, i| {
        if (i > 0) try w.print(",", .{});
        const kind_str = switch (exp.kind) {
            .func => "func",
            .table => "table",
            .memory => "memory",
            .global => "global",
            .tag => "tag",
        };
        try w.print("{{\"name\":\"{s}\",\"kind\":\"{s}\"", .{ exp.name, kind_str });
        if (exp.kind == .func) {
            if (module.getFuncType(exp.index)) |ft| {
                try w.print(",\"params\":[", .{});
                for (ft.params, 0..) |p, pi| {
                    if (pi > 0) try w.print(",", .{});
                    try w.print("\"{s}\"", .{valTypeName(p)});
                }
                try w.print("],\"results\":[", .{});
                for (ft.results, 0..) |r, ri| {
                    if (ri > 0) try w.print(",", .{});
                    try w.print("\"{s}\"", .{valTypeName(r)});
                }
                try w.print("]", .{});
            }
        }
        try w.print("}}", .{});
    }
    try w.print("]", .{});

    // Imports
    try w.print(",\"imports\":[", .{});
    for (module.imports.items, 0..) |imp, i| {
        if (i > 0) try w.print(",", .{});
        const kind_str = switch (imp.kind) {
            .func => "func",
            .table => "table",
            .memory => "memory",
            .global => "global",
            .tag => "tag",
        };
        try w.print("{{\"module\":\"{s}\",\"name\":\"{s}\",\"kind\":\"{s}\"", .{ imp.module, imp.name, kind_str });
        if (imp.kind == .func and imp.index < module.types.items.len) {
            const ft = module.types.items[imp.index];
            try w.print(",\"params\":[", .{});
            for (ft.params, 0..) |p, pi| {
                if (pi > 0) try w.print(",", .{});
                try w.print("\"{s}\"", .{valTypeName(p)});
            }
            try w.print("],\"results\":[", .{});
            for (ft.results, 0..) |r, ri| {
                if (ri > 0) try w.print(",", .{});
                try w.print("\"{s}\"", .{valTypeName(r)});
            }
            try w.print("]", .{});
        }
        try w.print("}}", .{});
    }
    try w.print("]", .{});

    // Summary
    try w.print(",\"functions_defined\":{d},\"functions_imported\":{d}", .{
        module.functions.items.len,
        module.num_imported_funcs,
    });
    try w.print(",\"memories\":{d},\"tables\":{d},\"globals\":{d}", .{
        module.memories.items.len + module.num_imported_memories,
        module.tables.items.len,
        module.globals.items.len,
    });

    try w.print("}}\n", .{});
}

// ============================================================
// zwasm run --batch
// ============================================================

/// Batch mode: read invocations from stdin, one per line.
/// Protocol: "invoke <func> [arg1 arg2 ...]"
/// Output: "ok [val1 val2 ...]" or "error <message>"
fn cmdBatch(allocator: Allocator, wasm_bytes: []const u8, imports: []const types.ImportEntry, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    _ = stderr;
    var module = if (imports.len > 0)
        types.WasmModule.loadWithImports(allocator, wasm_bytes, imports) catch |err| {
            try stdout.print("error load {s}\n", .{@errorName(err)});
            try stdout.flush();
            return false;
        }
    else
        types.WasmModule.load(allocator, wasm_bytes) catch |err| {
            try stdout.print("error load {s}\n", .{@errorName(err)});
            try stdout.flush();
            return false;
        };
    defer module.deinit();

    const stdin = std.fs.File.stdin();
    var read_buf: [8192]u8 = undefined;
    var reader = stdin.reader(&read_buf);
    const r = &reader.interface;

    // Reusable buffers for args/results (400+ params needed for func-400-params test)
    var arg_buf: [512]u64 = undefined;
    var result_buf: [512]u64 = undefined;

    while (true) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => continue,
            else => break,
        } orelse break;

        // Skip empty lines
        if (line.len == 0) continue;

        // Parse: "invoke <len>:<func> [arg1 arg2 ...]"
        // Function name is length-prefixed to handle special characters.
        if (!std.mem.startsWith(u8, line, "invoke ")) {
            try stdout.print("error unknown command\n", .{});
            try stdout.flush();
            continue;
        }

        const rest = line["invoke ".len..];

        // Two protocols:
        // 1. Length-prefixed: "invoke <len>:<func_name> [args...]"
        // 2. Hex-encoded:    "invoke hex:<hex_name> [args...]" (for names with \0, \n, \r)
        var hex_decode_buf: [512]u8 = undefined;
        var func_name: []const u8 = undefined;
        var args_start: usize = undefined;

        if (std.mem.startsWith(u8, rest, "hex:")) {
            // Hex-encoded: find end of hex name (space or end of line)
            const hex_start = 4; // after "hex:"
            const hex_end = std.mem.indexOfScalar(u8, rest[hex_start..], ' ') orelse (rest.len - hex_start);
            const hex_str = rest[hex_start .. hex_start + hex_end];
            if (hex_str.len % 2 != 0 or hex_str.len / 2 > hex_decode_buf.len) {
                try stdout.print("error invalid hex name\n", .{});
                try stdout.flush();
                continue;
            }
            const decoded = std.fmt.hexToBytes(&hex_decode_buf, hex_str) catch {
                try stdout.print("error invalid hex name\n", .{});
                try stdout.flush();
                continue;
            };
            func_name = decoded;
            args_start = hex_start + hex_end;
        } else {
            // Length-prefixed: "<len>:<func_name> [args...]"
            const colon_pos = std.mem.indexOfScalar(u8, rest, ':') orelse {
                try stdout.print("error missing length prefix\n", .{});
                try stdout.flush();
                continue;
            };
            const name_len = std.fmt.parseInt(usize, rest[0..colon_pos], 10) catch {
                try stdout.print("error invalid length\n", .{});
                try stdout.flush();
                continue;
            };
            const name_start = colon_pos + 1;
            if (name_start + name_len > rest.len) {
                try stdout.print("error name too long\n", .{});
                try stdout.flush();
                continue;
            }
            func_name = rest[name_start .. name_start + name_len];
            args_start = name_start + name_len;
        }

        // Parse arguments (space-separated after name)
        var arg_count: usize = 0;
        var arg_err = false;
        if (args_start < rest.len) {
            var parts = std.mem.splitScalar(u8, rest[args_start..], ' ');
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                if (arg_count >= arg_buf.len) {
                    arg_err = true;
                    break;
                }
                arg_buf[arg_count] = std.fmt.parseInt(u64, part, 10) catch {
                    arg_err = true;
                    break;
                };
                arg_count += 1;
            }
        }
        if (arg_err) {
            try stdout.print("error invalid arguments\n", .{});
            try stdout.flush();
            continue;
        }

        // Determine result count and types from export
        var result_count: usize = 1;
        const batch_export_info = module.getExportInfo(func_name);
        if (batch_export_info) |info| {
            result_count = info.result_types.len;
        }
        if (result_count > result_buf.len) result_count = result_buf.len;

        @memset(result_buf[0..result_count], 0);

        module.invoke(func_name, arg_buf[0..arg_count], result_buf[0..result_count]) catch |err| {
            try stdout.print("error {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };

        // Output: "ok [val1 val2 ...]" (truncate 32-bit types to u32)
        try stdout.print("ok", .{});
        for (result_buf[0..result_count], 0..) |val, ridx| {
            const out_val = if (batch_export_info) |info| blk: {
                if (ridx < info.result_types.len) {
                    break :blk switch (info.result_types[ridx]) {
                        .i32, .f32 => val & 0xFFFFFFFF,
                        else => val,
                    };
                }
                break :blk val;
            } else val;
            try stdout.print(" {d}", .{out_val});
        }
        try stdout.print("\n", .{});
        try stdout.flush();
    }
    return true;
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
