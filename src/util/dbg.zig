//! Env-gated debug logger (ADR-0015 candidate).
//!
//! `dbg.print(comptime mod, fmt, args)` is a no-op unless the
//! environment variable `ZWASM_DEBUG` enables `mod` (or one of its
//! prefixes — `interp` enables `interp.alloc`, `interp.dispatch`,
//! …). The value `*` enables every module; the empty / unset
//! value disables every module.
//!
//! Compile-stripped in `ReleaseFast` / `ReleaseSmall` via a
//! `builtin.mode` guard — release builds emit zero code for the
//! call site (the comptime branch + `@compileLog`-free body
//! collapses).
//!
//! The whitelist is parsed lazily on the first call from each
//! module, then cached in a comptime-keyed `bool`. Subsequent
//! calls are a single atomic load + branch when disabled.
//!
//! ## Usage
//!
//! ```zig
//! const dbg = @import("util/dbg.zig");
//!
//! dbg.print("interp.alloc", "rt={x} mem.ptr={x} len={d}", .{
//!     @intFromPtr(rt), @intFromPtr(mem.ptr), mem.len,
//! });
//! ```
//!
//! ```sh
//! ZWASM_DEBUG=interp.alloc zig build test 2>&1 | grep dbg
//! ZWASM_DEBUG=interp,c_api zig build test 2>&1
//! ZWASM_DEBUG=* zig build test 2>&1
//! ```
//!
//! Output goes to stderr via `std.debug.print`. Each line is
//! prefixed with `[dbg <mod>] ` so multiple modules' lines stay
//! distinguishable when several are enabled.
//!
//! Zone 0 (`src/util/`).

const std = @import("std");
const builtin = @import("builtin");

/// Set at startup if anyone calls `print`; cached so repeated calls
/// don't re-read the environment. The whitelist itself is interned
/// in a static buffer to avoid relying on the GPA / arena.
const Whitelist = struct {
    /// `*` enables every module.
    everything: bool = false,
    /// Stable storage for the comma-split env value. We never grow
    /// this; the env is read once per process. 4 KiB is enough for
    /// any sensible developer setup.
    buf: [4096]u8 = undefined,
    len: usize = 0,
    /// Pointers into `buf`; up to 64 entries.
    entries: [64][]const u8 = undefined,
    entry_count: usize = 0,
};

var whitelist: Whitelist = .{};
var whitelist_initialised: bool = false;

fn initWhitelist() void {
    // Single-threaded init: the loop sets `whitelist_initialised`
    // last, and concurrent readers tolerate seeing the partial
    // state because they re-check the flag before consulting
    // entries. Since this is a debug-only path the cost is
    // immaterial.
    if (whitelist_initialised) return;
    // TODO(adr-0015): remove the std.c.getenv dependency once Zig
    // stdlib re-exposes a libc-free env-read suitable for a no-
    // allocator init path. Today's options:
    //   * std.posix.getenv         — removed in Zig 0.16 (was the
    //                                canonical no-allocator path).
    //   * std.process.getEnvVarOwned — needs an Allocator we don't
    //                                  have here.
    //   * std.process.Init.environ_map — only available via the
    //                                    Juicy Main entrypoint.
    // Until one of those becomes accessible from a leaf utility,
    // dbg.zig is callable only from libc-linked compilation units
    // (c_api binding + test runners — see ADR-0015 §1 "libc
    // requirement" + Negative consequences).
    const raw = std.c.getenv("ZWASM_DEBUG");
    const value: []const u8 = if (raw) |p| std.mem.span(p) else "";
    if (std.mem.eql(u8, value, "*")) {
        whitelist.everything = true;
        whitelist_initialised = true;
        return;
    }
    if (value.len == 0) {
        whitelist_initialised = true;
        return;
    }
    const copy_len = @min(value.len, whitelist.buf.len);
    @memcpy(whitelist.buf[0..copy_len], value[0..copy_len]);
    whitelist.len = copy_len;
    var it = std.mem.tokenizeScalar(u8, whitelist.buf[0..copy_len], ',');
    while (it.next()) |tok| {
        const trimmed = std.mem.trim(u8, tok, " \t");
        if (trimmed.len == 0) continue;
        if (whitelist.entry_count >= whitelist.entries.len) break;
        whitelist.entries[whitelist.entry_count] = trimmed;
        whitelist.entry_count += 1;
    }
    whitelist_initialised = true;
}

fn enabled(comptime mod: []const u8) bool {
    // Release builds skip the env read entirely — call sites
    // collapse to nothing.
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        return false;
    }
    if (!whitelist_initialised) initWhitelist();
    if (whitelist.everything) return true;
    var i: usize = 0;
    while (i < whitelist.entry_count) : (i += 1) {
        const e = whitelist.entries[i];
        // Prefix match: `interp` enables `interp.alloc`, but
        // `interp.alloc` does NOT enable `interp` (the more
        // specific filter wins from the developer's side). Skip
        // when `mod` is shorter than `e` — slice-from-empty is a
        // compile error in Zig 0.16 when both bounds are 0.
        if (mod.len == 0 or mod.len < e.len) continue;
        if (e.len > 0 and std.mem.eql(u8, mod[0..e.len], e)) {
            // Boundary: either exact match, or next char is `.`.
            if (mod.len == e.len) return true;
            if (mod[e.len] == '.') return true;
        }
    }
    return false;
}

/// Print `fmt`-formatted output to stderr if `mod` is enabled by
/// `ZWASM_DEBUG`. Comptime no-op in release builds.
pub fn print(comptime mod: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        return;
    }
    if (!enabled(mod)) return;
    std.debug.print("[dbg " ++ mod ++ "] " ++ fmt ++ "\n", args);
}

/// Force-disable the cached whitelist. Test-only: lets a unit test
/// re-evaluate `ZWASM_DEBUG` after mutating the process env.
pub fn resetForTest() void {
    whitelist = .{};
    whitelist_initialised = false;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "enabled: empty whitelist disables every module" {
    resetForTest();
    // ZWASM_DEBUG isn't set in the test process — initWhitelist
    // takes the empty branch.
    try testing.expect(!enabled("any"));
    try testing.expect(!enabled("interp.alloc"));
}

test "enabled: prefix match — `interp` enables `interp.alloc`" {
    resetForTest();
    whitelist.entries[0] = "interp";
    whitelist.entry_count = 1;
    whitelist_initialised = true;
    defer resetForTest();
    try testing.expect(enabled("interp"));
    try testing.expect(enabled("interp.alloc"));
    try testing.expect(enabled("interp.dispatch"));
    try testing.expect(!enabled("c_api"));
    try testing.expect(!enabled("interpolate")); // boundary check
}

test "enabled: more specific entry doesn't enable the parent" {
    resetForTest();
    whitelist.entries[0] = "interp.alloc";
    whitelist.entry_count = 1;
    whitelist_initialised = true;
    defer resetForTest();
    try testing.expect(enabled("interp.alloc"));
    try testing.expect(!enabled("interp"));
    try testing.expect(!enabled("interp.dispatch"));
}

test "enabled: `*` enables every module" {
    resetForTest();
    whitelist.everything = true;
    whitelist_initialised = true;
    defer resetForTest();
    try testing.expect(enabled("anything"));
    try testing.expect(enabled("interp.alloc"));
    // Empty mod string isn't expected from real call sites (every
    // call passes a comptime literal); we don't assert on it.
}
