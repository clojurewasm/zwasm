//! Top-level CLI verb classification — pure + testable. `main.zig`
//! routes on the returned `Action`; `run` / `compile` keep their own
//! per-subcommand arg parsing. Splitting the top-level routing out
//! here is what makes the CLI surface (ADR-0159: run + compile +
//! --version/--help) unit-testable without spawning the exe.
//!
//! Zone 3 (`src/cli/`).

const std = @import("std");

pub const Action = enum { banner, help, version, run, compile, unknown };

/// Classify the first CLI token. `null` (no subcommand) = the
/// version + build-options banner. An unrecognised token is
/// `.unknown` (a typo) rather than an implicit file-run — the
/// surface is explicit (`zwasm run <file>`), no bare-file shortcut.
pub fn classify(subcmd: ?[]const u8) Action {
    const s = subcmd orelse return .banner;
    if (eq(s, "--help") or eq(s, "-h") or eq(s, "help")) return .help;
    if (eq(s, "--version") or eq(s, "-V")) return .version;
    if (eq(s, "run")) return .run;
    if (eq(s, "compile")) return .compile;
    return .unknown;
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const usage =
    \\zwasm — a WebAssembly runtime
    \\
    \\Usage:
    \\  zwasm run <file.wasm|file.cwasm> [args...]   Run a module (WASI _start / main)
    \\    [--invoke <name>[=a,b,...]]                Invoke a named export (optional call args)
    \\    [--engine <interp|jit>]                    Engine: interp (default) or jit (both full WASI; jit adds SIMD)
    \\    [--dir <host>[:<guest>]]                   Preopen a host directory for WASI
    \\    [--env <KEY=VAL>]                          Set an environment variable for the guest
    \\  zwasm compile <file.wasm> -o <out.cwasm>     Compile to a .cwasm AOT artifact
    \\  zwasm --version | -V                         Print the version
    \\  zwasm --help | -h | help                     Print this help
    \\  zwasm                                        Print version + build options
    \\
;

test "classify: known verbs" {
    try std.testing.expectEqual(Action.run, classify("run"));
    try std.testing.expectEqual(Action.compile, classify("compile"));
}

test "classify: help + version flags and aliases" {
    try std.testing.expectEqual(Action.help, classify("--help"));
    try std.testing.expectEqual(Action.help, classify("-h"));
    try std.testing.expectEqual(Action.help, classify("help"));
    try std.testing.expectEqual(Action.version, classify("--version"));
    try std.testing.expectEqual(Action.version, classify("-V"));
}

test "classify: null is banner, unknown token is unknown" {
    try std.testing.expectEqual(Action.banner, classify(null));
    try std.testing.expectEqual(Action.unknown, classify("bogus"));
    try std.testing.expectEqual(Action.unknown, classify("foo.wasm"));
}

test "usage text names both shipped subcommands + every run flag main.zig parses" {
    try std.testing.expect(std.mem.find(u8, usage, "zwasm run ") != null);
    try std.testing.expect(std.mem.find(u8, usage, "zwasm compile ") != null);
    // Lock doc/code coherence: every flag `run` actually accepts (main.zig)
    // must be documented, so help can't silently drop one again (--env did).
    try std.testing.expect(std.mem.find(u8, usage, "--invoke") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--engine") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--dir") != null);
    try std.testing.expect(std.mem.find(u8, usage, "--env") != null);
}
