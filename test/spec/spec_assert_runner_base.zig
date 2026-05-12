//! Shared base for spec-assertion runners (§9.9 / 9.9-l-1a per ADR-0057).
//!
//! Extraction substrate for code shared between `simd_assert_runner.zig`
//! (existing) and `spec_assert_runner_non_simd.zig` (l-1b). This file
//! starts with the mechanically-extractable scalar token parsers +
//! quoted-export name splitter; subsequent l-1a sub-chunks extend it
//! with the full manifest-loop + module-init + RunnerCallbacks trait
//! per ADR-0057 §"Decision".
//!
//! Each function here is **stateless** and **format-agnostic** — the
//! tokens it parses come from text manifests produced by
//! `scripts/regen_spec_*_assert.sh` (Python distillation of upstream
//! WebAssembly testsuite `.wast` files). The behaviour matches the
//! pre-extraction shape exactly; SIMD test gate verifies green-to-green.
//!
//! Zone: test/ (outside the src/ zone hierarchy per ADR-0023 §A1).

const std = @import("std");

/// Parse a decimal integer token into its u32 bit pattern. Wasm
/// asserts emit i32 results as decimal strings; signed values may
/// appear (negative literals in the source ⇒ negative decimal here).
/// Spec semantics treat the bits as u32; both u32 and i32 parsings
/// produce the same bit pattern via `@bitCast`.
pub fn parseI32Token(tok: []const u8) !u32 {
    return std.fmt.parseInt(u32, tok, 10) catch
        @as(u32, @bitCast(std.fmt.parseInt(i32, tok, 10) catch return error.BadValue));
}

/// 64-bit mirror of `parseI32Token`. Wasm `i64` result tokens map to
/// u64 bit patterns; signed literals roundtrip via `@bitCast`.
pub fn parseI64Token(tok: []const u8) !u64 {
    return std.fmt.parseInt(u64, tok, 10) catch
        @as(u64, @bitCast(std.fmt.parseInt(i64, tok, 10) catch return error.BadValue));
}

/// Split an `assert_return` / `assert_trap` directive's left-hand
/// side into `(fn_name, args_s)`. Handles single-quoted export
/// names (Wasm 2.0 chunk 9.9-h-29 Part B: names like
/// `'v128.load align=16'` contain spaces and must stay grouped).
///
/// Returns `error.BadDirective` for malformed input (missing close
/// quote, no space after quoted name, unquoted name with no args).
pub fn splitFnAndArgs(lhs: []const u8) !struct { fn_name: []const u8, args_s: []const u8 } {
    if (lhs.len > 0 and lhs[0] == '\'') {
        const close = std.mem.findScalarPos(u8, lhs, 1, '\'') orelse return error.BadDirective;
        if (close + 1 >= lhs.len) return error.BadDirective;
        if (lhs[close + 1] != ' ') return error.BadDirective;
        return .{ .fn_name = lhs[1..close], .args_s = lhs[close + 2 ..] };
    }
    const sp1 = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    return .{ .fn_name = lhs[0..sp1], .args_s = lhs[sp1 + 1 ..] };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "parseI32Token: unsigned decimal" {
    try testing.expectEqual(@as(u32, 42), try parseI32Token("42"));
    try testing.expectEqual(@as(u32, 0), try parseI32Token("0"));
}

test "parseI32Token: negative decimal roundtrips through i32" {
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), try parseI32Token("-1"));
    try testing.expectEqual(@as(u32, 0x80000000), try parseI32Token("-2147483648"));
}

test "parseI32Token: out-of-range rejects" {
    try testing.expectError(error.BadValue, parseI32Token("9999999999"));
    try testing.expectError(error.BadValue, parseI32Token("abc"));
}

test "parseI64Token: signed/unsigned both roundtrip" {
    try testing.expectEqual(@as(u64, 42), try parseI64Token("42"));
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -1))), try parseI64Token("-1"));
    try testing.expectEqual(@as(u64, 0x8000000000000000), try parseI64Token("-9223372036854775808"));
}

test "splitFnAndArgs: unquoted name + args" {
    const r = try splitFnAndArgs("foo 1 2 3");
    try testing.expectEqualStrings("foo", r.fn_name);
    try testing.expectEqualStrings("1 2 3", r.args_s);
}

test "splitFnAndArgs: single-quoted name + args" {
    const r = try splitFnAndArgs("'v128.load align=16' 0 1");
    try testing.expectEqualStrings("v128.load align=16", r.fn_name);
    try testing.expectEqualStrings("0 1", r.args_s);
}

test "splitFnAndArgs: malformed (no close quote) rejects" {
    try testing.expectError(error.BadDirective, splitFnAndArgs("'foo bar"));
}

test "splitFnAndArgs: malformed (no space after close quote) rejects" {
    try testing.expectError(error.BadDirective, splitFnAndArgs("'foo'"));
}
