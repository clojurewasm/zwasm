//! `zwasm` CLI exe entry.
//!
//! Per ADR-0024 D-4: lives at `src/cli/main.zig` (not at the
//! top-level `src/main.zig`) so that the static-library root
//! `src/zwasm.zig` does not pull in `pub fn main` — that would
//! duplicate-define `_main` against C-host examples linking
//! against `libzwasm.a`.
//!
//! The `core` module (rooted at `src/zwasm.zig`) is injected via
//! build.zig as a named import (`addImport("zwasm", core)`); the
//! library symbols are reached as `zwasm.<zone>.<symbol>`.
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
const zwasm = @import("zwasm");

const cli_run = zwasm.cli.run;
const diag_print = zwasm.cli.diag_print;
const diagnostic = zwasm.diagnostic;

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

    try stdout.print("zwasm v{s}\n", .{zwasm.version});
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
    try std.testing.expect(zwasm.version.len > 0);
}

test "build options are wired" {
    _ = build_options.wasm_level;
    _ = build_options.wasi_level;
    _ = build_options.engine_mode;
}
