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

const zwasm_root = @import("zwasm");

pub const RunError = error{
    LoadFailed,
    InvokeFailed,
} || std.mem.Allocator.Error;

/// Cycle 3: compile + invoke a wasm module's named export with
/// typed args, return the first result Value. Per ADR-0109 the
/// native Zig API (`zwasm.Engine` + `zwasm.Linker` +
/// `zwasm.Instance.invoke`) is the canonical path — no c_api
/// veneer.
///
/// Args + results use `zwasm.Value` (the Native API tagged union;
/// f32/f64 stored as bit patterns). runtime.Value (from cycle 2's
/// parsePayload) is the *internal* extern union; the caller
/// converts via the small `runtimeToZwasm` adapter below.
///
/// **Bytes-in, not path-in**: the caller supplies the wasm byte
/// slice (typically via `@embedFile` at the test call site). This
/// keeps runOne FS-free + io-free → callable from any unit test
/// without `std.process.Init` ceremony.
///
/// Scope (deliberate; multi-result + void lands when a manifest
/// entry needs it):
///   - exactly 1 result expected; void-returning funcs unsupported.
///   - invocation errors flatten to `RunError.InvokeFailed`;
///     trap-class discrimination is a follow-on cycle.
pub fn runOne(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!zwasm_root.Value {
    var engine = zwasm_root.Engine.init(alloc, .{}) catch return RunError.OutOfMemory;
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return RunError.InvokeFailed;
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = linker.instantiate(&module) catch return RunError.InvokeFailed;
    defer instance.deinit();

    var results: [1]zwasm_root.Value = undefined;
    instance.invoke(func_name, args, results[0..1]) catch return RunError.InvokeFailed;
    return results[0];
}

pub const TrapOutcome = enum {
    /// invoke errored — assert_trap passes (something trapped).
    trapped,
    /// invoke returned normally — assert_trap fails (no trap).
    returned_normally,
};

/// `assert_trap` execution path: compile + instantiate + look up
/// the export's sig (so results are sized correctly + the arity
/// check doesn't trip pre-execution), then invoke. Any
/// `Instance.InvokeError` from invoke is treated as a trap
/// (matches the v1 spec runner's lenient policy — the bake step
/// drops the original trap-reason string, so trap-class
/// discrimination is a follow-on enhancement). Returns
/// `.returned_normally` if invoke succeeds (assert_trap fail).
///
/// Setup errors (compile failure, instantiate failure, export
/// not found, not-a-func) propagate as `RunError` — the caller
/// can decide whether to count them as fail or skip.
pub fn runOneTrap(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!TrapOutcome {
    var engine = zwasm_root.Engine.init(alloc, .{}) catch return RunError.OutOfMemory;
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return RunError.LoadFailed;
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = linker.instantiate(&module) catch return RunError.LoadFailed;
    defer instance.deinit();

    const sig = instance.exportFuncSig(func_name) orelse return RunError.LoadFailed;
    const n_results = sig.results.len;
    // Stack-bounded; the wasm-3.0-assert corpus's assert_trap funcs
    // top out at single-scalar results today. Multi-result trap
    // funcs land alongside multi-value execution in a follow-on
    // cycle (matches the assert_return single-scalar gate).
    var results_buf: [4]zwasm_root.Value = undefined;
    if (n_results > results_buf.len) return RunError.InvokeFailed;
    const results = results_buf[0..n_results];

    instance.invoke(func_name, args, results) catch return .trapped;
    return .returned_normally;
}

pub const ExceptionOutcome = enum {
    /// invoke errored with `Trap.UncaughtException` —
    /// assert_exception passes.
    uncaught_exception,
    /// invoke returned normally — assert_exception fails (function
    /// completed without throwing).
    returned_normally,
    /// invoke errored with a non-exception trap (DivByZero, OOB,
    /// etc.) — assert_exception fails (function trapped but not
    /// via the EH path).
    other_trap,
};

/// `assert_exception` execution path: same compile + sig + invoke
/// shape as runOneTrap, but discriminates the trap class. Only
/// `Trap.UncaughtException` counts as the expected outcome; any
/// other trap (DivByZero, OOB, etc.) is `.other_trap` (failed
/// because the function trapped for an unrelated reason).
/// Requires the c_api `mapDispatchErr` to route UncaughtException
/// through (added alongside this helper).
pub fn runOneExpectException(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
    func_name: []const u8,
    args: []const zwasm_root.Value,
) RunError!ExceptionOutcome {
    var engine = zwasm_root.Engine.init(alloc, .{}) catch return RunError.OutOfMemory;
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return RunError.LoadFailed;
    defer module.deinit();
    var linker = zwasm_root.Linker.init(&engine);
    defer linker.deinit();
    var instance = linker.instantiate(&module) catch return RunError.LoadFailed;
    defer instance.deinit();

    const sig = instance.exportFuncSig(func_name) orelse return RunError.LoadFailed;
    const n_results = sig.results.len;
    var results_buf: [4]zwasm_root.Value = undefined;
    if (n_results > results_buf.len) return RunError.InvokeFailed;
    const results = results_buf[0..n_results];

    instance.invoke(func_name, args, results) catch |err| {
        return if (err == error.UncaughtException) .uncaught_exception else .other_trap;
    };
    return .returned_normally;
}

pub const CompileOutcome = enum {
    /// Engine.compile errored — assert_invalid / assert_malformed
    /// passes (the validator/parser rejected as expected).
    rejected,
    /// Engine.compile succeeded — assert_invalid / assert_malformed
    /// fails (the bytes parsed AND validated clean).
    accepted,
};

/// `assert_invalid` / `assert_malformed` execution path: try
/// `Engine.compile` and report whether the module was rejected.
/// Currently both directives map to the same dispatch (compile
/// bundles parse + validate; the spec-level distinction —
/// assert_malformed targets the parser stage, assert_invalid the
/// validator — isn't surfaced by the c_api boundary today).
/// OutOfMemory propagates; everything else from compile is treated
/// as a rejection.
pub fn compileExpectInvalid(
    alloc: std.mem.Allocator,
    wasm_bytes: []const u8,
) std.mem.Allocator.Error!CompileOutcome {
    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = engine.compile(wasm_bytes) catch return .rejected;
    module.deinit();
    return .accepted;
}

/// Adapter for the cycle-2 parsePayload output (runtime.Value
/// extern union) → cycle-3 runOne input (zwasm.Value tagged union).
/// The two types differ structurally: runtime.Value stores floats
/// natively; zwasm.Value stores floats as bit patterns (u32/u64).
/// This adapter handles the i32/i64/f32/f64 arms; v128 / ref arms
/// land when a manifest needs them.
pub fn runtimeToZwasm(rv: runtime.Value, ty: []const u8) zwasm_root.Value {
    if (std.mem.eql(u8, ty, "i32")) return .{ .i32 = rv.i32 };
    if (std.mem.eql(u8, ty, "i64")) return .{ .i64 = rv.i64 };
    if (std.mem.eql(u8, ty, "f32")) return .{ .f32 = @bitCast(rv.f32) };
    if (std.mem.eql(u8, ty, "f64")) return .{ .f64 = @bitCast(rv.f64) };
    unreachable; // caller already validated via parsePayload
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

test "runOne e2e: return_call.0.wasm type-i32 () -> i32:306 (10.TC verify)" {
    // First end-to-end manifest entry execution via the Native Zig
    // API. Exercises the same-module direct tail-call codegen from
    // the just-closed 10.TC-emit-body bundle: fn `type-i32` ends in
    // `return_call type-first` (per the wast source); type-first
    // returns 306 (= 0x132).
    //
    // @embedFile pins the fixture at compile time — keeps runOne
    // FS-free + io-free, and the test fails fast if the corpus is
    // missing (rather than skipping silently).
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.0.wasm");
    const result = try runOne(testing.allocator, wasm_bytes, "type-i32", &.{});
    try testing.expectEqual(@as(i32, 306), result.i32);
}

test "runOneTrap: handcrafted_trap always_traps reports .trapped" {
    // wasm-1.0 handcrafted_trap/m.wasm exports two fns: `always_traps`
    // (unconditional `unreachable`) and `trap_on_neg` (traps when arg
    // < 0). Cross-corpus fixture — Wasm 3.0 corpus's assert_trap
    // funcs require parser/codegen support that isn't all green yet
    // (memory64 / EH); the 1.0 fixture exercises ONLY the
    // runOneTrap dispatch surface, which is corpus-agnostic.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const outcome = try runOneTrap(testing.allocator, wasm_bytes, "always_traps", &.{});
    try testing.expectEqual(TrapOutcome.trapped, outcome);
}

test "runOneTrap: trap_on_neg i32:5 returns normally (no false trap)" {
    // Sanity guard: `trap_on_neg` with arg 5 (≥ 0) does NOT trap;
    // ensures the helper doesn't classify normal returns as trapped
    // (e.g. by swallowing a setup-side error).
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = 5 }};
    const outcome = try runOneTrap(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(TrapOutcome.returned_normally, outcome);
}

test "runOneTrap: trap_on_neg i32:-1 traps" {
    // Pairs with the assert_return above; verifies the trap path
    // fires when arg < 0.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = -1 }};
    const outcome = try runOneTrap(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(TrapOutcome.trapped, outcome);
}

test "compileExpectInvalid: return_call.1.wasm rejected (assert_invalid path)" {
    // tail-call return_call.1.wasm is listed as assert_invalid in
    // the corpus manifest (one of 10 invalid fixtures). The
    // validator must reject it; this pins the assert_invalid
    // dispatch surface before the runner wires it in.
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.1.wasm");
    const outcome = try compileExpectInvalid(testing.allocator, wasm_bytes);
    try testing.expectEqual(CompileOutcome.rejected, outcome);
}

test "runOneExpectException: trap_on_neg i32:-1 reports .other_trap (not exception)" {
    // Sanity guard: a non-EH trap (here `unreachable` via
    // handcrafted_trap) must be classified `.other_trap`, NOT
    // `.uncaught_exception`. Verifies the trap-class discrimination
    // doesn't conflate generic traps with EH exceptions.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = -1 }};
    const outcome = try runOneExpectException(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(ExceptionOutcome.other_trap, outcome);
}

test "runOneExpectException: normal return reports .returned_normally" {
    // Sanity: a function that returns cleanly is `.returned_normally`,
    // not exception/trap. Mirrors the runOneTrap returned_normally
    // guard.
    const wasm_bytes = @embedFile("wasm-1.0-assert/handcrafted_trap/m.wasm");
    const args = [_]zwasm_root.Value{.{ .i32 = 5 }};
    const outcome = try runOneExpectException(testing.allocator, wasm_bytes, "trap_on_neg", &args);
    try testing.expectEqual(ExceptionOutcome.returned_normally, outcome);
}

test "D-188 bisect: EH + func-refs invalid-accepted fixtures (regression marker)" {
    // Identifies the 6 fixtures listed as assert_invalid that
    // current `Engine.compile` accepts. Pinned per D-188 — when
    // the validator's reject-set closes a case, the count goes
    // down; this test goes red as a prompt to update the marker.
    // Cross-corpus @embedFile pins the fixtures at compile time.
    const Case = struct { name: []const u8, bytes: []const u8 };
    const cases = [_]Case{
        // exception-handling try_table (7 fixtures: 6..12; 6 pass / 1 fail per runner)
        .{ .name = "try_table.6",  .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.6.wasm") },
        .{ .name = "try_table.7",  .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.7.wasm") },
        .{ .name = "try_table.8",  .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.8.wasm") },
        .{ .name = "try_table.9",  .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.9.wasm") },
        .{ .name = "try_table.10", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.10.wasm") },
        .{ .name = "try_table.11", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.11.wasm") },
        .{ .name = "try_table.12", .bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.12.wasm") },
        // function-references ref (12 fixtures: 1..12; 7 pass / 5 fail per runner)
        .{ .name = "ref.1",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.1.wasm") },
        .{ .name = "ref.2",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.2.wasm") },
        .{ .name = "ref.3",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.3.wasm") },
        .{ .name = "ref.4",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.4.wasm") },
        .{ .name = "ref.5",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.5.wasm") },
        .{ .name = "ref.6",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.6.wasm") },
        .{ .name = "ref.7",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.7.wasm") },
        .{ .name = "ref.8",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.8.wasm") },
        .{ .name = "ref.9",  .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.9.wasm") },
        .{ .name = "ref.10", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.10.wasm") },
        .{ .name = "ref.11", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.11.wasm") },
        .{ .name = "ref.12", .bytes = @embedFile("wasm-3.0-assert/function-references/ref/ref.12.wasm") },
    };

    var accepted_count: u32 = 0;
    for (cases) |c| {
        const outcome = try compileExpectInvalid(testing.allocator, c.bytes);
        if (outcome == .accepted) {
            std.debug.print("[D-188 invalid-accepted] {s}\n", .{c.name});
            accepted_count += 1;
        }
    }
    // Current state: 1 fixture incorrectly accepted (try_table.10
    // — deep EH validator gap around `catch_all_ref` typing in a
    // try_table block declared without `(result exnref)`). The
    // 5 function-references "unknown type" cases (ref.1..5) closed
    // at the D-188 first-cycle fix in `instantiate.zig::frontendValidate`
    // (pre-decode pass forced section-body validation regardless
    // of code-section presence). Tighten further when the EH
    // try_table type-check rule lands.
    try testing.expectEqual(@as(u32, 1), accepted_count);
}

test "EH gap regression: try_table.0.wasm currently rejects at compile (10.E pending)" {
    // Documents the current EH module-compile gap (drives the
    // 33/34 assert_return + 2/2 assert_trap + 4/4 assert_exception
    // fails for exception-handling in the spec runner). When 10.E
    // EH validator + execution rounds close enough that try_table.0
    // compiles, this test flips red as a prompt to retighten to
    // the post-fix state (compile OK + invoke produces values).
    const wasm_bytes = @embedFile("wasm-3.0-assert/exception-handling/try_table/try_table.0.wasm");
    const alloc = testing.allocator;
    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    try testing.expectError(error.ParseFailed, engine.compile(wasm_bytes));
}

test "memory64: address64.0.wasm compiles (frontendValidate memory0_idx_type plumbing)" {
    // Regression marker for the memory64 frontendValidate fix.
    // Before the fix, `validator.validateFunction` defaulted
    // memory0_idx_type to .i32, so memory64 fixtures (which load/
    // store at i64 addresses) failed with StackTypeMismatch.
    // After the fix, frontendValidate extracts the memory section's
    // idx_type and threads it into validator. Compile-side only;
    // runtime memory ops + invoke remain a separate gap.
    const wasm_bytes = @embedFile("wasm-3.0-assert/memory64/address64/address64.0.wasm");
    const alloc = testing.allocator;

    var engine = try zwasm_root.Engine.init(alloc, .{});
    defer engine.deinit();
    var module = try engine.compile(wasm_bytes);
    defer module.deinit();
}

test "compileExpectInvalid: return_call.0.wasm accepted (no false rejection)" {
    // Sanity: the valid return_call.0.wasm (which the bisect test
    // executes 31/31 directives against) must NOT be reported as
    // rejected. Guards against the helper classifying valid
    // modules as invalid.
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.0.wasm");
    const outcome = try compileExpectInvalid(testing.allocator, wasm_bytes);
    try testing.expectEqual(CompileOutcome.accepted, outcome);
}

// ============================================================
// Tail-call FAIL bisect (D-187 — interp tail-call grows Zig stack)
// ============================================================
//
// wasm-3.0-assert/tail-call shows pass=25 / fail=6 out of 31
// assert_returns against `return_call.0.wasm`. Root cause (per
// `src/interp/mvp.zig:440-443` self-documented limitation): the
// interp's `returnCallOp` invokes the callee via Zig recursion
// (`invoke(callee)` then `tailReturn` — see mvp.zig:467-482),
// mirroring Wasm tail-calls onto the host call stack. Each
// `return_call` adds an interp Frame (max_frame_stack = 256 per
// `src/runtime/frame.zig:24`); recursion exceeding 256 deep hits
// `Trap.CallStackExhausted` at `runtime.zig:341`. The 6 failing
// cases (count/even/odd at 999+ iterations) need millions of
// tail-iterations and trip the ceiling well before completion.
// The JIT codegen (10.TC-emit-body bundle) implements
// frame_teardown + BR X16 / JMP R11 for actual frame-reuse;
// Native API `Instance.invoke` (src/zwasm/instance.zig:113) goes
// through `dispatch.run` → interp dispatch table, so the JIT
// path is not yet exercised by this runner.
//
// This test is a **regression marker** — `pass == 25` pins the
// current state. When D-187 discharges (either by routing the
// spec runner through the JIT or implementing a non-recursive
// interp dispatch for tail-call), this assertion fails red and
// must be retightened to `pass == 31, fail == 0`.
//
// All 31 asserts target `return_call.0.wasm`; later `module`
// directives in the manifest switch to other fixtures unrelated
// to these asserts.
test "tail-call bisect: enumerate 31 assert_returns + print failures (D-187 regression marker)" {
    const wasm_bytes = @embedFile("wasm-3.0-assert/tail-call/return_call/return_call.0.wasm");
    const Case = struct {
        name: []const u8,
        args: []const zwasm_root.Value,
        want_kind: enum { i32, i64, f32, f64 },
        want_i32: i32 = 0,
        want_i64: i64 = 0,
        want_f32: u32 = 0,
        want_f64: u64 = 0,
    };
    const cases = [_]Case{
        .{ .name = "type-i32",       .args = &.{}, .want_kind = .i32, .want_i32 = 306 },
        .{ .name = "type-i64",       .args = &.{}, .want_kind = .i64, .want_i64 = 356 },
        .{ .name = "type-f32",       .args = &.{}, .want_kind = .f32, .want_f32 = 1165172736 },
        .{ .name = "type-f64",       .args = &.{}, .want_kind = .f64, .want_f64 = 4660882566700597248 },
        .{ .name = "type-first-i32", .args = &.{}, .want_kind = .i32, .want_i32 = 32 },
        .{ .name = "type-first-i64", .args = &.{}, .want_kind = .i64, .want_i64 = 64 },
        .{ .name = "type-first-f32", .args = &.{}, .want_kind = .f32, .want_f32 = 1068037571 },
        .{ .name = "type-first-f64", .args = &.{}, .want_kind = .f64, .want_f64 = 4610064722561534525 },
        .{ .name = "type-second-i32",.args = &.{}, .want_kind = .i32, .want_i32 = 32 },
        .{ .name = "type-second-i64",.args = &.{}, .want_kind = .i64, .want_i64 = 64 },
        .{ .name = "type-second-f32",.args = &.{}, .want_kind = .f32, .want_f32 = 1107296256 },
        .{ .name = "type-second-f64",.args = &.{}, .want_kind = .f64, .want_f64 = 4634211053438658150 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 0 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 1 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 1 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 1 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 5 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 120 },
        .{ .name = "fac-acc", .args = &[_]zwasm_root.Value{ .{ .i64 = 25 }, .{ .i64 = 1 } }, .want_kind = .i64, .want_i64 = 7034535277573963776 },
        .{ .name = "count", .args = &[_]zwasm_root.Value{ .{ .i64 = 0 } }, .want_kind = .i64, .want_i64 = 0 },
        .{ .name = "count", .args = &[_]zwasm_root.Value{ .{ .i64 = 1000 } }, .want_kind = .i64, .want_i64 = 0 },
        .{ .name = "count", .args = &[_]zwasm_root.Value{ .{ .i64 = 1000000 } }, .want_kind = .i64, .want_i64 = 0 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{ .{ .i64 = 0 } }, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{ .{ .i64 = 1 } }, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{ .{ .i64 = 100 } }, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{ .{ .i64 = 77 } }, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{ .{ .i64 = 1000000 } }, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "even", .args = &[_]zwasm_root.Value{ .{ .i64 = 1000001 } }, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{ .{ .i64 = 0 } }, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{ .{ .i64 = 1 } }, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{ .{ .i64 = 200 } }, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{ .{ .i64 = 77 } }, .want_kind = .i32, .want_i32 = 44 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{ .{ .i64 = 1000000 } }, .want_kind = .i32, .want_i32 = 99 },
        .{ .name = "odd", .args = &[_]zwasm_root.Value{ .{ .i64 = 999999 } }, .want_kind = .i32, .want_i32 = 44 },
    };

    var pass: u32 = 0;
    var fail: u32 = 0;
    for (cases, 0..) |c, idx| {
        const got = runOne(testing.allocator, wasm_bytes, c.name, c.args) catch |err| {
            std.debug.print("[bisect fail #{d:>2}] {s} args={any} -> err={s}\n", .{ idx, c.name, c.args, @errorName(err) });
            fail += 1;
            continue;
        };
        const ok = switch (c.want_kind) {
            .i32 => got.i32 == c.want_i32,
            .i64 => got.i64 == c.want_i64,
            .f32 => got.f32 == c.want_f32,
            .f64 => got.f64 == c.want_f64,
        };
        if (ok) {
            pass += 1;
        } else {
            switch (c.want_kind) {
                .i32 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=i32:{d} got=i32:{d}\n", .{ idx, c.name, c.args, c.want_i32, got.i32 }),
                .i64 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=i64:{d} got=i64:{d}\n", .{ idx, c.name, c.args, c.want_i64, got.i64 }),
                .f32 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=f32:{x} got=f32:{x}\n", .{ idx, c.name, c.args, c.want_f32, got.f32 }),
                .f64 => std.debug.print("[bisect fail #{d:>2}] {s} args={any} want=f64:{x} got=f64:{x}\n", .{ idx, c.name, c.args, c.want_f64, got.f64 }),
            }
            fail += 1;
        }
    }
    if (pass != cases.len or fail != 0) {
        std.debug.print("[tail-call bisect] pass={d} fail={d} (expected all-pass)\n", .{ pass, fail });
    }
    // D-187 discharged via the 10.TC interp trampoline (planned
    // row 10.TC scope) — `dispatch.run` now switches frames
    // in-place on `return_call`, so the host Zig call stack no
    // longer grows per Wasm tail-call. All 31 directives must pass.
    try testing.expectEqual(@as(u32, 0), fail);
    try testing.expectEqual(@as(u32, @intCast(cases.len)), pass);
}
