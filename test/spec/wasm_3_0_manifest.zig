//! Wasm 3.0 spec assertion manifest parser (10.E spec corpus
//! runner foundation; first cycle of the planned bundle).
//!
//! The wasm-3.0-assert corpus (10.T-2a) bakes per-proposal
//! sub-directories with a `manifest.txt` per `.wast` source. Each
//! line is one directive:
//!
//!   module <path>
//!   assert_return <funcname> [<typed-arg>...] -> [<typed-result>...]
//!   assert_trap <funcname> [<typed-arg>...]
//!   assert_exception <funcname> [<typed-arg>...]
//!   assert_invalid <wasm-path>
//!   assert_malformed <wasm-path>
//!   skip-impl <reason>
//!   skip-validator <reason>
//!   skip-runtime <reason>
//!
//! Typed args + results use the shape `<wasm-type>:<decimal>`:
//!   i32:42, i64:18446744073709551612, f32:1165172736 (bit
//!   pattern), f64:4634211053438658150 (bit pattern). Empty
//!   result `()` means void; multi-value return is the rare
//!   `( v1 v2 ... )` shape (post-1.0 multi-value proposal — out
//!   of scope this cycle; will land alongside the test runner
//!   when needed).
//!
//! This file lands the parser only (no execution dispatch yet).
//! The future spec_assert_runner_wasm_3_0.zig consumer will:
//!   (1) iterate manifests under corpus_root,
//!   (2) call `parseLine` on each line to get a Directive,
//!   (3) dispatch each Directive against cli_run.runWasmCaptured
//!       (assert_return / assert_trap) or the relevant validator
//!       hook (assert_invalid / assert_malformed) etc.
//!
//! Zone 3 test-tree helper (`test/spec/`) — may import any Zone.

const std = @import("std");

const runtime = @import("zwasm").runtime;

pub const TypedValue = struct {
    /// "i32" / "i64" / "f32" / "f64". v128 / refs land when a
    /// fixture in the corpus requires them.
    ty: []const u8,
    /// Raw decimal payload after the colon. Caller parses to the
    /// target type — `parseLine` keeps the slice borrowed from
    /// the input line so the parser stays alloc-free.
    payload: []const u8,
};

pub const Kind = enum {
    module,
    assert_return,
    assert_trap,
    assert_exception,
    assert_invalid,
    assert_malformed,
    skip_impl,
    skip_validator,
    skip_runtime,
    unknown,
};

pub const Directive = struct {
    kind: Kind,
    /// `module <path>` → the wasm path (basename relative to
    /// the manifest dir). `assert_invalid` / `assert_malformed`
    /// → the wasm path. Else empty.
    module_path: []const u8 = "",
    /// Function name for assert_return / assert_trap /
    /// assert_exception. Empty otherwise.
    func_name: []const u8 = "",
    /// `skip-*` reason (the substring after the first space).
    reason: []const u8 = "",
    /// Caller stages args + results into these arrays. Parser
    /// writes by index up to the slice length; returns
    /// `OutOfRange` if more typed tokens appear than fit. The
    /// `*_len` fields name the populated count.
    args: []TypedValue,
    results: []TypedValue,
    args_len: u8 = 0,
    results_len: u8 = 0,
};

pub const Error = error{
    OutOfRange,
    MalformedTypedValue,
};

pub const PayloadError = error{
    UnknownType,
    InvalidDecimal,
    Overflow,
};

/// Parse a `TypedValue` token's payload into the runtime `Value`
/// union arm. f32 / f64 payloads in the corpus are decimal-encoded
/// **bit patterns** (per `wast-importer.sh`'s f32/f64 emission); the
/// payload `1165172736` for `f32:` means `@bitCast(@as(u32,
/// 1165172736)) → f32`. i32 / i64 use the same parseInt path but
/// the parsed value lands directly in the signed-arm via @bitCast
/// (Wasm const literals are nominally unsigned wraparound).
pub fn parsePayload(tv: TypedValue) PayloadError!runtime.Value {
    if (std.mem.eql(u8, tv.ty, "i32")) {
        const u = std.fmt.parseInt(u32, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .i32 = @bitCast(u) };
    }
    if (std.mem.eql(u8, tv.ty, "i64")) {
        const u = std.fmt.parseInt(u64, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .i64 = @bitCast(u) };
    }
    if (std.mem.eql(u8, tv.ty, "f32")) {
        const u = std.fmt.parseInt(u32, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .f32 = @bitCast(u) };
    }
    if (std.mem.eql(u8, tv.ty, "f64")) {
        const u = std.fmt.parseInt(u64, tv.payload, 10) catch |err| return mapParseErr(err);
        return runtime.Value{ .f64 = @bitCast(u) };
    }
    // v128 / funcref / externref payloads land when a manifest in
    // the corpus emits them; the wasm-3.0-assert sub-corpora baked
    // so far use only i32/i64/f32/f64.
    return PayloadError.UnknownType;
}

fn mapParseErr(err: std.fmt.ParseIntError) PayloadError {
    return switch (err) {
        error.Overflow => PayloadError.Overflow,
        error.InvalidCharacter => PayloadError.InvalidDecimal,
    };
}

/// Parse one manifest line into a `Directive`. The caller owns
/// `args_buf` and `results_buf` (typically per-line stack
/// buffers of length 4 each — manifest cap inferred from the
/// 10.T-2a corpus: max-args-per-line ≈ 3 in practice, max-
/// results-per-line ≤ 2 for the wasm-3.0-assert subset before
/// multi-value).
pub fn parseLine(
    line: []const u8,
    args_buf: []TypedValue,
    results_buf: []TypedValue,
) Error!Directive {
    var directive: Directive = .{
        .kind = .unknown,
        .args = args_buf,
        .results = results_buf,
    };

    // Identify the directive head + capture the rest.
    const head = std.mem.findScalar(u8, line, ' ') orelse line.len;
    const kind_str = line[0..head];
    const rest = if (head == line.len) "" else line[head + 1 ..];

    if (std.mem.eql(u8, kind_str, "module")) {
        directive.kind = .module;
        directive.module_path = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "skip-impl")) {
        directive.kind = .skip_impl;
        directive.reason = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "skip-validator")) {
        directive.kind = .skip_validator;
        directive.reason = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "skip-runtime")) {
        directive.kind = .skip_runtime;
        directive.reason = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "assert_invalid")) {
        directive.kind = .assert_invalid;
        directive.module_path = rest;
        return directive;
    }
    if (std.mem.eql(u8, kind_str, "assert_malformed")) {
        directive.kind = .assert_malformed;
        directive.module_path = rest;
        return directive;
    }

    const is_assert_return = std.mem.eql(u8, kind_str, "assert_return");
    const is_assert_trap = std.mem.eql(u8, kind_str, "assert_trap");
    const is_assert_exception = std.mem.eql(u8, kind_str, "assert_exception");
    if (!is_assert_return and !is_assert_trap and !is_assert_exception) {
        return directive; // .unknown
    }

    directive.kind = if (is_assert_return) .assert_return else if (is_assert_trap) .assert_trap else .assert_exception;

    // Split rest into tokens; first non-typed token is funcname,
    // typed tokens (`<ty>:<val>`) until `->` are args, after
    // `->` are results.
    var tokens = std.mem.splitScalar(u8, rest, ' ');
    var seen_arrow: bool = false;
    var seen_name: bool = false;
    while (tokens.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "->")) {
            seen_arrow = true;
            continue;
        }
        if (!seen_name and std.mem.findScalar(u8, tok, ':') == null and !std.mem.eql(u8, tok, "()")) {
            directive.func_name = tok;
            seen_name = true;
            continue;
        }
        // Typed value or empty-result marker `()`.
        if (std.mem.eql(u8, tok, "()")) {
            // Void result — no typed value added.
            continue;
        }
        const colon = std.mem.findScalar(u8, tok, ':') orelse return Error.MalformedTypedValue;
        const tv: TypedValue = .{ .ty = tok[0..colon], .payload = tok[colon + 1 ..] };
        if (seen_arrow) {
            if (directive.results_len >= results_buf.len) return Error.OutOfRange;
            results_buf[directive.results_len] = tv;
            directive.results_len += 1;
        } else {
            if (directive.args_len >= args_buf.len) return Error.OutOfRange;
            args_buf[directive.args_len] = tv;
            directive.args_len += 1;
        }
    }

    return directive;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "parseLine: module directive captures path" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("module return_call.0.wasm", &args, &results);
    try testing.expectEqual(Kind.module, d.kind);
    try testing.expectEqualStrings("return_call.0.wasm", d.module_path);
}

test "parseLine: assert_return with no args + i32 result" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return type-i32 () -> i32:306", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqualStrings("type-i32", d.func_name);
    try testing.expectEqual(@as(u8, 0), d.args_len);
    try testing.expectEqual(@as(u8, 1), d.results_len);
    try testing.expectEqualStrings("i32", d.results[0].ty);
    try testing.expectEqualStrings("306", d.results[0].payload);
}

test "parseLine: assert_return with typed args + i64 result" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return fac-acc i64:5 i64:1 -> i64:120", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqualStrings("fac-acc", d.func_name);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    try testing.expectEqualStrings("i64", d.args[0].ty);
    try testing.expectEqualStrings("5", d.args[0].payload);
    try testing.expectEqualStrings("1", d.args[1].payload);
    try testing.expectEqual(@as(u8, 1), d.results_len);
    try testing.expectEqualStrings("120", d.results[0].payload);
}

test "parseLine: assert_return with void result `()`" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return store i64:18446744073709551612 i32:42 -> ()", &args, &results);
    try testing.expectEqual(Kind.assert_return, d.kind);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    try testing.expectEqual(@as(u8, 0), d.results_len); // void
}

test "parseLine: assert_trap no result" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_trap store i64:18446744073709551613 i32:13", &args, &results);
    try testing.expectEqual(Kind.assert_trap, d.kind);
    try testing.expectEqualStrings("store", d.func_name);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    try testing.expectEqual(@as(u8, 0), d.results_len);
}

test "parseLine: skip-impl directive captures reason" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("skip-impl directive-action", &args, &results);
    try testing.expectEqual(Kind.skip_impl, d.kind);
    try testing.expectEqualStrings("directive-action", d.reason);
}

test "parseLine: assert_invalid captures wasm path" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_invalid bad.wasm", &args, &results);
    try testing.expectEqual(Kind.assert_invalid, d.kind);
    try testing.expectEqualStrings("bad.wasm", d.module_path);
}

test "parseLine: args overflow → OutOfRange" {
    var args: [1]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    try testing.expectError(Error.OutOfRange, parseLine("assert_return foo i32:1 i32:2 -> ()", &args, &results));
}

test "parsePayload: i32 positive decimal lands in Value.i32" {
    const v = try parsePayload(.{ .ty = "i32", .payload = "306" });
    try testing.expectEqual(@as(i32, 306), v.i32);
}

test "parsePayload: i32 large-unsigned wraps via @bitCast (Wasm const semantics)" {
    // 0xFFFFFFFF = u32 max; @bitCast → i32 -1.
    const v = try parsePayload(.{ .ty = "i32", .payload = "4294967295" });
    try testing.expectEqual(@as(i32, -1), v.i32);
}

test "parsePayload: i64 large-unsigned wraps to -1" {
    // 18446744073709551615 = u64 max.
    const v = try parsePayload(.{ .ty = "i64", .payload = "18446744073709551615" });
    try testing.expectEqual(@as(i64, -1), v.i64);
}

test "parsePayload: f32 bit pattern → @bitCast f32 (corpus shape)" {
    // 0x40000000 = 1073741824 = bit pattern for f32 2.0.
    const v = try parsePayload(.{ .ty = "f32", .payload = "1073741824" });
    try testing.expectEqual(@as(f32, 2.0), v.f32);
}

test "parsePayload: f64 bit pattern → @bitCast f64" {
    // 0x4000000000000000 = 4611686018427387904 = bit pattern for f64 2.0.
    const v = try parsePayload(.{ .ty = "f64", .payload = "4611686018427387904" });
    try testing.expectEqual(@as(f64, 2.0), v.f64);
}

test "parsePayload: f32 round-trip via @bitCast (corpus-style payload)" {
    // Confirm the bit-cast direction matches the manifest's
    // assumed encoding: a known f32 (3.14) → its u32 bit pattern
    // (decimal-stringified) → parsePayload → same f32.
    const bits: u32 = @bitCast(@as(f32, 3.14));
    var buf: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{bits});
    const v = try parsePayload(.{ .ty = "f32", .payload = s });
    try testing.expectEqual(@as(f32, 3.14), v.f32);
}

test "parsePayload: unknown type returns PayloadError.UnknownType" {
    try testing.expectError(PayloadError.UnknownType, parsePayload(.{ .ty = "v128", .payload = "0" }));
}

test "parsePayload: invalid decimal returns PayloadError.InvalidDecimal" {
    try testing.expectError(PayloadError.InvalidDecimal, parsePayload(.{ .ty = "i32", .payload = "abc" }));
}

test "parsePayload: overflow returns PayloadError.Overflow" {
    try testing.expectError(PayloadError.Overflow, parsePayload(.{ .ty = "i32", .payload = "4294967296" }));
}

test "parsePayload + parseLine round-trip: assert_return fac-acc i64:5 i64:1 → Value{i64:5} Value{i64:1}" {
    var args: [4]TypedValue = undefined;
    var results: [4]TypedValue = undefined;
    const d = try parseLine("assert_return fac-acc i64:5 i64:1 -> i64:120", &args, &results);
    try testing.expectEqual(@as(u8, 2), d.args_len);
    const a0 = try parsePayload(d.args[0]);
    const a1 = try parsePayload(d.args[1]);
    const r0 = try parsePayload(d.results[0]);
    try testing.expectEqual(@as(i64, 5), a0.i64);
    try testing.expectEqual(@as(i64, 1), a1.i64);
    try testing.expectEqual(@as(i64, 120), r0.i64);
}
