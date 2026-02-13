// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! zwasm CLI — run, inspect, and validate WebAssembly modules.
//!
//! Usage:
//!   zwasm run <file.wasm|.wat> [args...]
//!   zwasm run --invoke <func> <file.wasm|.wat> [i32:N ...]
//!   zwasm inspect <file.wasm|.wat>
//!   zwasm validate <file.wasm|.wat>

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const module_mod = @import("module.zig");
const opcode = @import("opcode.zig");
const vm_mod = @import("vm.zig");
const trace_mod = vm_mod.trace_mod;
const wat = @import("wat.zig");
const validate = @import("validate.zig");
const build_options = @import("build_options");
const component_mod = @import("component.zig");
const guard_mod = @import("guard.zig");
const jit_mod = vm_mod.jit_mod;

pub fn main() !void {
    // Install signal handler for JIT guard page OOB traps
    if (comptime jit_mod.jitSupported()) {
        guard_mod.installSignalHandler();
    }

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
        const ok = try cmdValidate(allocator, args[2..], stdout, stderr);
        try stdout.flush();
        if (!ok) std.process.exit(1);
    } else if (std.mem.eql(u8, command, "features")) {
        cmdFeatures(args[2..], stdout, stderr);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage(stdout);
    } else if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "version")) {
        try stdout.print("zwasm {s}\n", .{build_options.version});
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
        \\  zwasm run [options] <file.wasm|.wat> [args...]
        \\  zwasm inspect [--json] <file.wasm|.wat>
        \\  zwasm validate <file.wasm|.wat>
        \\  zwasm features
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
        \\  --allow-read        Grant filesystem read capability
        \\  --allow-write       Grant filesystem write capability
        \\  --allow-env         Grant environment variable access
        \\  --allow-path        Grant path operations (open, mkdir, unlink, etc.)
        \\  --allow-all         Grant all WASI capabilities
        \\  --max-memory <N>    Memory ceiling in bytes (limits memory.grow)
        \\  --fuel <N>          Instruction fuel limit (traps when exhausted)
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
    var caps = types.Capabilities.cli_default;
    var max_memory_bytes: ?u64 = null;
    var fuel: ?u64 = null;

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
        } else if (std.mem.eql(u8, args[i], "--allow-read")) {
            caps.allow_read = true;
        } else if (std.mem.eql(u8, args[i], "--allow-write")) {
            caps.allow_write = true;
        } else if (std.mem.eql(u8, args[i], "--allow-env")) {
            caps.allow_env = true;
        } else if (std.mem.eql(u8, args[i], "--allow-path")) {
            caps.allow_path = true;
        } else if (std.mem.eql(u8, args[i], "--allow-all")) {
            caps = types.Capabilities.all;
        } else if (std.mem.eql(u8, args[i], "--max-memory")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --max-memory requires a byte count\n", .{});
                try stderr.flush();
                return false;
            }
            max_memory_bytes = std.fmt.parseInt(u64, args[i], 10) catch {
                try stderr.print("error: --max-memory requires a valid number\n", .{});
                try stderr.flush();
                return false;
            };
        } else if (std.mem.eql(u8, args[i], "--fuel")) {
            i += 1;
            if (i >= args.len) {
                try stderr.print("error: --fuel requires an instruction count\n", .{});
                try stderr.flush();
                return false;
            }
            fuel = std.fmt.parseInt(u64, args[i], 10) catch {
                try stderr.print("error: --fuel requires a valid number\n", .{});
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

    const wasm_bytes = readWasmFile(allocator, path) catch |err| {
        try stderr.print("error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return false;
    };
    defer allocator.free(wasm_bytes);

    // Auto-detect component vs core module
    if (component_mod.isComponent(wasm_bytes)) {
        return runComponent(allocator, wasm_bytes, stdout, stderr);
    }

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
        return cmdBatch(allocator, wasm_bytes, import_entries.items, link_names.items, linked_modules.items, stdout, stderr);
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
            .caps = caps,
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

        // Apply resource limits
        module.vm.max_memory_bytes = max_memory_bytes;
        module.vm.fuel = fuel;

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
        // v128 results use 2 u64 slots each
        var result_count: usize = 1;
        const export_info = module.getExportInfo(func_name);
        if (export_info) |info| {
            result_count = 0;
            for (info.result_types) |rt| {
                result_count += if (rt == .v128) 2 else 1;
            }
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

        // Print results (truncate 32-bit types to u32, v128 as two u64)
        if (export_info) |info| {
            var ridx: usize = 0;
            for (info.result_types, 0..) |rt, tidx| {
                if (tidx > 0 or ridx > 0) try stdout.print(" ", .{});
                if (rt == .v128) {
                    try stdout.print("{d} {d}", .{ results[ridx], results[ridx + 1] });
                    ridx += 2;
                } else {
                    const val = switch (rt) {
                        .i32, .f32 => results[ridx] & 0xFFFFFFFF,
                        else => results[ridx],
                    };
                    try stdout.print("{d}", .{val});
                    ridx += 1;
                }
            }
        } else {
            for (results, 0..) |r, idx| {
                if (idx > 0) try stdout.print(" ", .{});
                try stdout.print("{d}", .{r});
            }
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
            .caps = caps,
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

        // Apply resource limits
        module.vm.max_memory_bytes = max_memory_bytes;
        module.vm.fuel = fuel;

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
// Component Model execution
// ============================================================

fn runComponent(allocator: Allocator, wasm_bytes: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    _ = stdout;

    // Decode the component
    var comp = component_mod.Component.init(allocator, wasm_bytes);
    defer comp.deinit();

    comp.decode() catch |err| {
        try stderr.print("error: failed to decode component: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return false;
    };

    // Create and instantiate
    var instance = component_mod.ComponentInstance.init(allocator, &comp);
    defer instance.deinit();

    instance.instantiate() catch |err| {
        try stderr.print("error: failed to instantiate component: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return false;
    };

    // Report component info
    try stderr.print("component: {d} core module(s), {d} export(s)\n", .{
        instance.coreModuleCount(),
        comp.exports.items.len,
    });

    // Look for a _start-like entry point in core modules
    for (instance.core_modules.items) |m| {
        var no_args = [_]u64{};
        var no_results = [_]u64{};
        m.invoke("_start", &no_args, &no_results) catch |err| {
            if (m.getWasiExitCode()) |code| {
                if (code != 0) std.process.exit(@truncate(code));
                return true;
            }
            try stderr.print("error: _start failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return false;
        };

        if (m.getWasiExitCode()) |code| {
            if (code != 0) std.process.exit(@truncate(code));
        }
        return true;
    }

    try stderr.print("error: no executable entry point found in component\n", .{});
    try stderr.flush();
    return false;
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
    const wasm_bytes = readWasmFile(allocator, file_path) catch |err| {
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
            if (imp.kind == .func) {
                if (module.getTypeFunc(imp.index)) |ft| {
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
        if (imp.kind == .func) {
            if (module.getTypeFunc(imp.index)) |ft| {
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
fn cmdBatch(allocator: Allocator, wasm_bytes: []const u8, imports: []const types.ImportEntry, link_names: []const []const u8, linked_modules: []const *types.WasmModule, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
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

        // Parse command: invoke, get, invoke_on, get_on
        const is_invoke_on = std.mem.startsWith(u8, line, "invoke_on ");
        const is_get_on = std.mem.startsWith(u8, line, "get_on ");
        const is_get = !is_get_on and std.mem.startsWith(u8, line, "get ");
        const is_invoke = !is_invoke_on and std.mem.startsWith(u8, line, "invoke ");
        if (!is_invoke and !is_get and !is_invoke_on and !is_get_on) {
            try stdout.print("error unknown command\n", .{});
            try stdout.flush();
            continue;
        }

        // For invoke_on/get_on, find the target linked module
        var target_module: *types.WasmModule = module;
        var rest: []const u8 = undefined;
        if (is_invoke_on or is_get_on) {
            const prefix_len2: usize = if (is_invoke_on) "invoke_on ".len else "get_on ".len;
            const after_cmd = line[prefix_len2..];
            // Module name is space-delimited (simple names, no special chars)
            const space_pos = std.mem.indexOfScalar(u8, after_cmd, ' ') orelse {
                try stdout.print("error missing function name\n", .{});
                try stdout.flush();
                continue;
            };
            const mod_name = after_cmd[0..space_pos];
            rest = after_cmd[space_pos + 1 ..];
            // Find linked module
            var found = false;
            for (link_names, linked_modules) |ln, lm| {
                if (std.mem.eql(u8, ln, mod_name)) {
                    target_module = lm;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try stdout.print("error module not found\n", .{});
                try stdout.flush();
                continue;
            }
        } else {
            const prefix_len2: usize = if (is_get) "get ".len else "invoke ".len;
            rest = line[prefix_len2..];
        }

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
        // v128 args use "v128:lo:hi" format (2 u64 slots)
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
                if (std.mem.startsWith(u8, part, "v128:")) {
                    // v128:lo:hi — split into two u64 slots
                    const v128_data = part["v128:".len..];
                    const colon = std.mem.indexOfScalar(u8, v128_data, ':') orelse {
                        arg_err = true;
                        break;
                    };
                    arg_buf[arg_count] = std.fmt.parseInt(u64, v128_data[0..colon], 10) catch {
                        arg_err = true;
                        break;
                    };
                    arg_count += 1;
                    if (arg_count >= arg_buf.len) { arg_err = true; break; }
                    arg_buf[arg_count] = std.fmt.parseInt(u64, v128_data[colon + 1 ..], 10) catch {
                        arg_err = true;
                        break;
                    };
                    arg_count += 1;
                } else {
                    arg_buf[arg_count] = std.fmt.parseInt(u64, part, 10) catch {
                        arg_err = true;
                        break;
                    };
                    arg_count += 1;
                }
            }
        }
        if (arg_err) {
            try stdout.print("error invalid arguments\n", .{});
            try stdout.flush();
            continue;
        }

        // Handle "get"/"get_on" command: read exported global value
        if (is_get or is_get_on) {
            const global_addr = target_module.instance.getExportGlobalAddr(func_name) orelse {
                try stdout.print("error global not found\n", .{});
                try stdout.flush();
                continue;
            };
            const g = target_module.store.getGlobal(global_addr) catch {
                try stdout.print("error bad global\n", .{});
                try stdout.flush();
                continue;
            };
            const val: u64 = switch (g.valtype) {
                .i32, .f32 => @as(u64, @truncate(g.value)) & 0xFFFFFFFF,
                else => @truncate(g.value),
            };
            try stdout.print("ok {d}\n", .{val});
            try stdout.flush();
            continue;
        }

        // Determine result count — v128 results use 2 u64 slots
        var result_count: usize = 1;
        const batch_export_info = target_module.getExportInfo(func_name);
        if (batch_export_info) |info| {
            result_count = 0;
            for (info.result_types) |rt| {
                result_count += if (rt == .v128) 2 else 1;
            }
        }
        if (result_count > result_buf.len) result_count = result_buf.len;

        @memset(result_buf[0..result_count], 0);

        target_module.invoke(func_name, arg_buf[0..arg_count], result_buf[0..result_count]) catch |err| {
            try stdout.print("error {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };

        // Output: "ok [val1 val2 ...]" (truncate 32-bit types to u32)
        try stdout.print("ok", .{});
        if (batch_export_info) |info| {
            var ridx: usize = 0;
            for (info.result_types) |rt| {
                if (rt == .v128) {
                    // v128: output as two u64 values
                    try stdout.print(" {d} {d}", .{ result_buf[ridx], result_buf[ridx + 1] });
                    ridx += 2;
                } else {
                    const out_val = switch (rt) {
                        .i32, .f32 => result_buf[ridx] & 0xFFFFFFFF,
                        else => result_buf[ridx],
                    };
                    try stdout.print(" {d}", .{out_val});
                    ridx += 1;
                }
            }
        } else {
            for (result_buf[0..result_count]) |val| {
                try stdout.print(" {d}", .{val});
            }
        }
        try stdout.print("\n", .{});
        try stdout.flush();
    }
    return true;
}

// ============================================================
// zwasm validate
// ============================================================

fn cmdValidate(allocator: Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    if (args.len < 1) {
        try stderr.print("error: no wasm file specified\n", .{});
        try stderr.flush();
        return false;
    }

    const path = args[0];
    const wasm_bytes = readWasmFile(allocator, path) catch |err| {
        try stderr.print("error: validation failed: {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return false;
    };
    defer allocator.free(wasm_bytes);

    var module = module_mod.Module.init(allocator, wasm_bytes);
    defer module.deinit();
    module.decode() catch |err| {
        try stderr.print("error: validation failed: {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return false;
    };

    validate.validateModule(allocator, &module) catch |err| {
        try stderr.print("error: validation failed: {s}: {s}\n", .{ path, @errorName(err) });
        try stderr.flush();
        return false;
    };

    try stdout.print("{s}: valid ({d} bytes, {d} functions, {d} exports)\n", .{
        path,
        wasm_bytes.len,
        module.functions.items.len + module.num_imported_funcs,
        module.exports.items.len,
    });
    try stdout.flush();
    return true;
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
        .exnref => "exnref",
        .ref_type => "ref",
        .ref_null_type => "ref_null",
    };
}

// ── features subcommand ────────────────────────────────────────────

const Feature = struct {
    name: []const u8,
    spec_level: SpecLevel,
    status: Status,
    opcodes: u16,

    const Status = enum { complete, partial, planned };
    const SpecLevel = enum {
        wasm_2_0, // W3C Recommendation (Dec 2019)
        wasm_3_0, // W3C Recommendation (Jul 2024, batch 2 Jul 2025)
        phase_4, // Browser-shipped, not yet ratified
        phase_3, // Implementation phase
    };

    fn specLevelStr(self: Feature) []const u8 {
        return switch (self.spec_level) {
            .wasm_2_0 => "Wasm 2.0",
            .wasm_3_0 => "Wasm 3.0",
            .phase_4 => "Phase 4",
            .phase_3 => "Phase 3",
        };
    }
};

const features_list = [_]Feature{
    // Wasm 2.0 — W3C Recommendation (Dec 2019)
    .{ .name = "Sign extension", .spec_level = .wasm_2_0, .status = .complete, .opcodes = 7 },
    .{ .name = "Non-trapping float-to-int", .spec_level = .wasm_2_0, .status = .complete, .opcodes = 8 },
    .{ .name = "Bulk memory", .spec_level = .wasm_2_0, .status = .complete, .opcodes = 9 },
    .{ .name = "Reference types", .spec_level = .wasm_2_0, .status = .complete, .opcodes = 5 },
    .{ .name = "Multi-value", .spec_level = .wasm_2_0, .status = .complete, .opcodes = 0 },
    .{ .name = "Fixed-width SIMD", .spec_level = .wasm_2_0, .status = .complete, .opcodes = 236 },
    // Wasm 3.0 — W3C Recommendation (Jul 2024 + batch 2 Jul 2025)
    .{ .name = "Tail call", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 2 },
    .{ .name = "Extended const", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 0 },
    .{ .name = "Function references", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 5 },
    .{ .name = "GC", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 31 },
    .{ .name = "Multi-memory", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 0 },
    .{ .name = "Relaxed SIMD", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 20 },
    .{ .name = "Branch hinting", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 0 },
    .{ .name = "Exception handling", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 3 },
    .{ .name = "Memory64", .spec_level = .wasm_3_0, .status = .complete, .opcodes = 0 },
    // Other proposals
    .{ .name = "Wide arithmetic", .spec_level = .phase_3, .status = .complete, .opcodes = 4 },
    .{ .name = "Custom page sizes", .spec_level = .phase_3, .status = .complete, .opcodes = 0 },
    .{ .name = "Threads", .spec_level = .phase_4, .status = .complete, .opcodes = 79 },
};

fn cmdFeatures(args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) void {
    _ = stderr;
    var json_mode = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json_mode = true;
    }

    if (json_mode) {
        printFeaturesJson(stdout);
    } else {
        printFeaturesTable(stdout);
    }
}

fn printFeaturesTable(stdout: *std.Io.Writer) void {
    stdout.print("Spec       Proposal                    Status     Opcodes\n", .{}) catch {};
    stdout.print("────       ───────────────────────     ────────   ───────\n", .{}) catch {};
    for (features_list) |f| {
        const status_str = statusStr(f.status);
        if (f.opcodes > 0) {
            stdout.print("{s: <11}{s: <28}{s: <11}{d}\n", .{ f.specLevelStr(), f.name, status_str, f.opcodes }) catch {};
        } else {
            stdout.print("{s: <11}{s: <28}{s: <11}-\n", .{ f.specLevelStr(), f.name, status_str }) catch {};
        }
    }
    const summary = featureSummary();
    stdout.print("\n{d}/{d} proposals complete, {d} opcodes total\n", .{
        summary.complete, features_list.len, summary.total_opcodes,
    }) catch {};
}

fn printFeaturesJson(stdout: *std.Io.Writer) void {
    stdout.print("{{\"features\":[", .{}) catch {};
    for (features_list, 0..) |f, i| {
        if (i > 0) stdout.print(",", .{}) catch {};
        stdout.print("{{\"name\":\"{s}\",\"spec_level\":\"{s}\",\"status\":\"{s}\",\"opcodes\":{d}}}", .{
            f.name, f.specLevelStr(), statusStr(f.status), f.opcodes,
        }) catch {};
    }
    const summary = featureSummary();
    stdout.print("],\"summary\":{{\"complete\":{d},\"total\":{d},\"opcodes\":{d}}}}}\n", .{
        summary.complete, features_list.len, summary.total_opcodes,
    }) catch {};
}

fn statusStr(status: Feature.Status) []const u8 {
    return switch (status) {
        .complete => "complete",
        .partial => "partial",
        .planned => "planned",
    };
}

fn featureSummary() struct { complete: u16, total_opcodes: u16 } {
    var complete: u16 = 0;
    var total_opcodes: u16 = 0;
    for (features_list) |f| {
        if (f.status == .complete) complete += 1;
        total_opcodes += f.opcodes;
    }
    return .{ .complete = complete, .total_opcodes = total_opcodes };
}

test "features list has expected entries" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 18), features_list.len);

    // All status values are valid (compile-time guarantee, but test the first/last)
    try testing.expectEqual(Feature.Status.complete, features_list[0].status);
    try testing.expectEqual(Feature.Status.planned, features_list[features_list.len - 1].status);

    // Spec levels: first 6 are Wasm 2.0, next 9 are Wasm 3.0
    try testing.expectEqual(Feature.SpecLevel.wasm_2_0, features_list[0].spec_level);
    try testing.expectEqual(Feature.SpecLevel.wasm_3_0, features_list[6].spec_level);
    try testing.expectEqual(Feature.SpecLevel.phase_4, features_list[17].spec_level);

    // Spec level string
    try testing.expectEqualStrings("Wasm 2.0", features_list[0].specLevelStr());
    try testing.expectEqualStrings("Phase 4", features_list[17].specLevelStr());

    // Total opcodes
    var total: u16 = 0;
    for (features_list) |f| total += f.opcodes;
    try testing.expect(total >= 398);
}

fn readFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    const read = try file.readAll(data);
    return data[0..read];
}

fn isWatFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".wat");
}

/// Read a file and convert WAT to wasm binary if needed.
/// Returns wasm bytes owned by caller.
fn readWasmFile(allocator: Allocator, path: []const u8) ![]const u8 {
    const file_bytes = try readFile(allocator, path);
    if (isWatFile(path)) {
        defer allocator.free(file_bytes);
        if (!build_options.enable_wat) return error.WatNotEnabled;
        return wat.watToWasm(allocator, file_bytes);
    }
    return file_bytes;
}

test "component detection in CLI" {
    // Verify component_mod.isComponent distinguishes correctly
    const comp_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00 };
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expect(component_mod.isComponent(&comp_bytes));
    try std.testing.expect(!component_mod.isComponent(&mod_bytes));
    try std.testing.expect(component_mod.isCoreModule(&mod_bytes));
    try std.testing.expect(!component_mod.isCoreModule(&comp_bytes));
}
