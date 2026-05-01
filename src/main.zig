//! `zwasm` CLI entry point.
//!
//! Phase 0 surface: prints `zwasm v<version>` and exits. Phase 1+
//! wires CLI argparse and the subcommand dispatch (`run | compile |
//! validate | inspect | features | wat | wasm`) per ROADMAP §10.

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;

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
    _ = @import("ir/zir.zig");
    _ = @import("ir/dispatch_table.zig");
    _ = @import("frontend/parser.zig");
    _ = @import("frontend/validator.zig");
    _ = @import("frontend/lowerer.zig");
    _ = @import("frontend/parse_ctx.zig");
    _ = @import("feature/mvp/mod.zig");
    _ = @import("frontend/sections.zig");
    _ = @import("interp/mod.zig");
    _ = @import("interp/dispatch.zig");
    _ = @import("interp/mvp.zig");
    _ = @import("interp/memory_ops.zig");
    _ = @import("interp/ext_2_0/sign_ext.zig");
    _ = @import("interp/ext_2_0/sat_trunc.zig");
}
