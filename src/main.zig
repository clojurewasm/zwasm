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
pub const parser = @import("frontend/parser.zig");
pub const validator = @import("frontend/validator.zig");
pub const lowerer = @import("frontend/lowerer.zig");
pub const sections = @import("frontend/sections.zig");
pub const zir = @import("ir/zir.zig");
pub const interp = @import("interp/mod.zig");
pub const cli_run = @import("cli/run.zig");
pub const c_api = @import("c_api/wasm_c_api.zig");
pub const diagnostic = @import("runtime/diagnostic.zig");
pub const diag_print = @import("cli/diag_print.zig");

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

            const code = cli_run.runWasm(gpa, io, bytes) catch |err| {
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
    _ = @import("util/leb128.zig");
    _ = @import("util/dbg.zig");
    _ = @import("runtime/diagnostic.zig");
    _ = @import("cli/diag_print.zig");
    _ = @import("ir/zir.zig");
    _ = @import("ir/dispatch_table.zig");
    _ = @import("ir/loop_info.zig");
    _ = @import("ir/liveness.zig");
    _ = @import("ir/verifier.zig");
    _ = @import("ir/const_prop.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/validator.zig");
    _ = @import("frontend/validator_tests.zig");
    _ = @import("frontend/lowerer.zig");
    _ = @import("frontend/lowerer_tests.zig");
    _ = @import("frontend/parse_ctx.zig");
    _ = @import("feature/mvp/mod.zig");
    _ = @import("frontend/sections.zig");
    _ = @import("interp/mod.zig");
    _ = @import("interp/dispatch.zig");
    _ = @import("interp/mvp.zig");
    _ = @import("interp/memory_ops.zig");
    _ = @import("interp/trap_audit.zig");
    _ = @import("interp/ext_2_0/sign_ext.zig");
    _ = @import("interp/ext_2_0/sat_trunc.zig");
    _ = @import("interp/ext_2_0/bulk_memory.zig");
    _ = @import("interp/ext_2_0/ref_types.zig");
    _ = @import("interp/ext_2_0/table_ops.zig");
    _ = @import("c_api/wasm_c_api.zig");
    _ = @import("wasi/p1.zig");
    _ = @import("wasi/host.zig");
    _ = @import("wasi/proc.zig");
    _ = @import("wasi/fd.zig");
    _ = @import("wasi/clocks.zig");
    _ = @import("cli/run.zig");
}
