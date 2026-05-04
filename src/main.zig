//! `zwasm` CLI entry point.
//!
//! Subcommands:
//!   (none)              Print version + build options.
//!   run <path.wasm>     Drive a WASI module's `_start` / `main`
//!                       export; exit with the guest's
//!                       `proc_exit` code.
//!
//! ROADMAP §10 envisions `compile / validate / inspect / features
//! / wat / wasm` subcommands too — those land in later phases.

const std = @import("std");
const build_options = @import("build_options");

pub const version = "0.0.0-pre";

// Public re-exports so build-time consumers (test/spec/runner.zig,
// integration tests) can import the frontend without poking at
// individual files.
pub const parser = @import("parse/parser.zig");
pub const validator = @import("validate/validator.zig");
pub const lowerer = @import("ir/lower.zig");
pub const sections = @import("parse/sections.zig");
pub const zir = @import("ir/zir.zig");
pub const runtime = @import("runtime/runtime.zig");
pub const cli_run = @import("cli/run.zig");
pub const c_api = @import("api/wasm.zig");
pub const diagnostic = @import("diagnostic/diagnostic.zig");
pub const diag_print = @import("cli/diag_print.zig");
pub const runner = @import("engine/runner.zig");
pub const entry = @import("engine/codegen/shared/entry.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?; // executable name
    const subcmd_opt = arg_it.next();

    if (subcmd_opt) |subcmd| {
        if (std.mem.eql(u8, subcmd, "run")) {
            const path_arg = arg_it.next() orelse {
                try printlnErr(io, "usage: zwasm run <path.wasm> [args...]");
                std.process.exit(2);
            };
            const path = try gpa.dupe(u8, path_arg);
            defer gpa.free(path);

            const cwd = std.Io.Dir.cwd();
            const bytes = cwd.readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024)) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "zwasm run: cannot read '{s}': {s}", .{ path, @errorName(err) }) catch "zwasm run: read failed";
                try printlnErr(io, msg);
                std.process.exit(1);
            };
            defer gpa.free(bytes);

            // Build argv for the WASI guest. Wasmtime's default is
            // argv[0] = wasm filename + any trailing args; mirror
            // that here so guests that print argv produce parity
            // bytes.
            var argv_list: std.ArrayList([]const u8) = .empty;
            defer argv_list.deinit(gpa);
            try argv_list.append(gpa, path);
            while (arg_it.next()) |a| try argv_list.append(gpa, a);

            const code = cli_run.runWasm(gpa, io, bytes, argv_list.items) catch |err| {
                // Per ADR-0016 phase 1: prefer the structured
                // diagnostic when one was set; fall back to the
                // legacy `@errorName` form for unwired sites.
                var stderr_buf: [1024]u8 = undefined;
                var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
                const stderr = &stderr_writer.interface;
                const source: diag_print.Source = .{ .filename = path, .bytes = bytes };
                if (diagnostic.lastDiagnostic()) |diag| {
                    diag_print.formatDiagnostic(diag, source, stderr) catch {};
                } else {
                    diag_print.renderFallback(err, source, stderr) catch {};
                }
                stderr.flush() catch {};
                std.process.exit(1);
            };
            std.process.exit(code);
        }
    }

    var stdout_buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("zwasm v{s}\n", .{version});
    try stdout.print(
        "  wasm-level: {s}, wasi-level: {s}, engine: {s}\n",
        .{
            @tagName(build_options.wasm_level),
            @tagName(build_options.wasi_level),
            @tagName(build_options.engine_mode),
        },
    );
    try stdout.flush();
}

fn printlnErr(io: std.Io, msg: []const u8) !void {
    var stderr_buf: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    try stderr.print("{s}\n", .{msg});
    try stderr.flush();
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "build options are wired" {
    // Smoke check that build_options reaches main.zig.
    _ = build_options.wasm_level;
    _ = build_options.wasi_level;
    _ = build_options.engine_mode;
}

test {
    _ = @import("support/leb128.zig");
    _ = @import("support/dbg.zig");
    _ = @import("diagnostic/diagnostic.zig");
    _ = @import("cli/diag_print.zig");
    _ = @import("ir/zir.zig");
    _ = @import("ir/dispatch_table.zig");
    _ = @import("engine/codegen/shared/reg_class.zig");
    _ = @import("engine/codegen/shared/regalloc.zig");
    _ = @import("engine/codegen/arm64/inst.zig");
    _ = @import("engine/codegen/arm64/abi.zig");
    _ = @import("engine/codegen/arm64/emit.zig");
    _ = @import("platform/jit_mem.zig");
    _ = @import("engine/codegen/shared/linker.zig");
    _ = @import("engine/codegen/shared/entry.zig");
    _ = @import("engine/codegen/shared/jit_abi.zig");
    _ = @import("engine/codegen/shared/compile.zig");
    _ = @import("engine/runner.zig");
    _ = @import("ir/analysis/loop_info.zig");
    _ = @import("ir/analysis/liveness.zig");
    _ = @import("ir/verifier.zig");
    _ = @import("ir/analysis/const_prop.zig");
    _ = @import("parse/parser.zig");
    _ = @import("validate/validator.zig");
    _ = @import("validate/validator_tests.zig");
    _ = @import("ir/lower.zig");
    _ = @import("ir/lower_tests.zig");
    _ = @import("parse/ctx.zig");
    _ = @import("feature/mvp/mod.zig");
    _ = @import("parse/sections.zig");
    _ = @import("runtime/runtime.zig");
    _ = @import("runtime/value.zig");
    _ = @import("runtime/trap.zig");
    _ = @import("runtime/frame.zig");
    _ = @import("interp/dispatch.zig");
    _ = @import("interp/mvp.zig");
    _ = @import("interp/memory_ops.zig");
    _ = @import("interp/trap_audit.zig");
    _ = @import("interp/ext_2_0/sign_ext.zig");
    _ = @import("interp/ext_2_0/sat_trunc.zig");
    _ = @import("interp/ext_2_0/bulk_memory.zig");
    _ = @import("interp/ext_2_0/ref_types.zig");
    _ = @import("interp/ext_2_0/table_ops.zig");
    _ = @import("api/wasm.zig");
    _ = @import("wasi/preview1.zig");
    _ = @import("wasi/host.zig");
    _ = @import("wasi/proc.zig");
    _ = @import("wasi/fd.zig");
    _ = @import("wasi/clocks.zig");
    _ = @import("cli/run.zig");
}
