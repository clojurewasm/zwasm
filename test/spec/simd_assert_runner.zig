//! SIMD spec assertion runner — JIT-execute + compare against
//! `assert_return` expectations on the WebAssembly testsuite SIMD
//! bundle (§9.9 per ADR-0045).
//!
//! Parallel runner to `spec_assert_runner.zig`; consumes a v128-
//! aware text manifest format that extends the scalar shape with
//! `v128:<32 hex digits>` tokens for 128-bit bit-pattern args /
//! results (see ADR-0045 §"Decision" / 2). Hex digits are
//! lower-byte-first to match the in-memory little-endian Wasm
//! v128 layout (lane-0-byte-0 first), produced by
//! `scripts/regen_spec_simd_assert.sh`'s Python distillation.
//!
//! Per-lane NaN-pattern result tokens (chunk 9.9-h-25) extend the
//! v128 form with `v128_lanes:<shape>:<l0>,<l1>,...,<lN>` where
//! `<shape>` ∈ {`f32x4`, `f64x2`} and each lane is one of:
//!   `c`       — canonical NaN (±canonical accepted)
//!   `a`       — arithmetic NaN (any quiet NaN per Wasm spec)
//!   `V<hex>`  — exact bit pattern (8 hex / lane for f32x4,
//!               16 hex / lane for f64x2; upper-byte-first
//!               natural-width hex — distinct from the
//!               lane-0-byte-0 packing of `v128:`).
//! Per Wasm spec testsuite semantics, each lane is checked
//! independently; the assertion passes iff every lane matches its
//! pattern. Only emitted for FP shapes that actually contain a
//! `nan:*` token; otherwise the legacy `v128:` form is preserved.
//!
//! §9.9-c (this commit) — populates manifest + JIT execution.
//! Walks each subdirectory's `manifest.txt`, dispatches `module` /
//! `assert_return` / `assert_invalid` / `assert_malformed` / `skip`
//! directives. Supported shapes: `() → {i32,i64,f32,f64,v128,()}`
//! and `(i32) → {i32,v128}`. v128 PARAM marshal + multi-arg shapes
//! land in §9.9-e+.
//!
//! Usage:
//!   simd_assert_runner <corpus-root>
//! exits non-zero if any `failed > 0`.

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_root_arg = arg_it.next() orelse {
        try stdout.print("usage: simd_assert_runner <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var passed: u32 = 0;
    var failed: u32 = 0;
    // Per ADR-0029 Path B (chunk 9.9-h-21): twin tally of
    // `skip-impl` (counts toward gate) vs `skip-adr-<id>` (waived).
    var skipped: u32 = 0;
    var skipped_adr: u32 = 0;
    var manifest_count: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        // Foundation fall-through: missing corpus dir means no
        // manifests are wired yet (e.g. fresh checkout pre-regen).
        // Report 0/0/0 and exit clean — `zig build test-spec-simd`
        // shouldn't fail on a clean tree where the regen hasn't run.
        try stdout.print("simd_assert_runner: corpus '{s}' not found ({s}); 0 manifests\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        return;
    };
    defer root.close(io);

    var iter = root.iterate();
    while (try iter.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        manifest_count += 1;
        try runCorpus(io, gpa, &root, dir_entry.name, stdout, &passed, &failed, &skipped, &skipped_adr);
    }

    try stdout.print(
        "\nsimd_assert_runner: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} skip-adr) (over {d} manifests)\n",
        .{ passed, failed, skipped + skipped_adr, skipped, skipped_adr, manifest_count },
    );
    try stdout.flush();

    if (failed > 0) std.process.exit(1);
}

fn runCorpus(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: *std.Io.Dir,
    name: []const u8,
    stdout: *std.Io.Writer,
    passed: *u32,
    failed: *u32,
    skipped: *u32,
    skipped_adr: *u32,
) !void {
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);

    const manifest_bytes = dir.readFileAlloc(io, "manifest.txt", gpa, .limited(1 << 22)) catch |err| {
        try stdout.print("FAIL  {s}: manifest read: {s}\n", .{ name, @errorName(err) });
        failed.* += 1;
        return;
    };
    defer gpa.free(manifest_bytes);

    var current_wasm: ?[]u8 = null;
    var current_compiled: ?runner_mod.CompiledWasm = null;
    // `module_bad` distinguishes "no module yet" from "module declared
    // but compile rejected it"; subsequent asserts under a bad module
    // are silently skipped (counted) rather than each cascading as a
    // separate FAIL — the compile failure is the load-bearing signal.
    var module_bad: bool = false;
    defer {
        if (current_wasm) |b| gpa.free(b);
        if (current_compiled) |*c| c.deinit(gpa);
    }

    var line_it = std.mem.splitScalar(u8, manifest_bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;

        // Per ADR-0029 Path B (chunk 9.9-h-21): prefix-aware classification.
        //   `skip-impl <reason>`         counts toward gate (`skip-impl == 0`).
        //   `skip-adr-<ADR-id> <reason>` waived per the named skip-ADR.
        //   `skip <reason>`              legacy bare form; back-compat warning
        //                                + counts as skip-impl until chunk
        //                                9.9-h-22 regen sweep migrates the
        //                                simd_assert manifests.
        if (std.mem.startsWith(u8, line, "skip-impl ")) {
            skipped.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "skip-adr-")) {
            skipped_adr.* += 1;
            continue;
        }
        if (std.mem.startsWith(u8, line, "skip ")) {
            try stdout.print("WARN  {s}: bare `skip` line — migrate to `skip-impl` or `skip-adr-<id>` (chunk 9.9-h-22 regen sweep): {s}\n", .{ name, line });
            skipped.* += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "module ")) {
            const file = line[7..];
            if (current_compiled) |*c| c.deinit(gpa);
            current_compiled = null;
            if (current_wasm) |b| gpa.free(b);
            current_wasm = null;
            module_bad = false;
            @memset(scratch_memory[0..], 0);
            @memset(scratch_globals[0..], 0);

            const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                try stdout.print("FAIL  {s}/{s} module read: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                module_bad = true;
                continue;
            };
            current_wasm = wasm_bytes;
            const compiled = runner_mod.compileWasm(gpa, wasm_bytes) catch |err| {
                try stdout.print("FAIL  {s}/{s} compile: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                module_bad = true;
                continue;
            };
            current_compiled = compiled;
            // §9.9 / 9.9-d-7: write active data-segment bytes
            // into `scratch_memory` so subsequent v128.load
            // fixtures see the fixture-declared bytes (rather
            // than the all-zero memset baseline). Mirrors
            // `setupRuntime`'s data-init logic without paying its
            // full per-module allocation. Without this,
            // simd_address load_data_N invocations all returned
            // v128:000... vs the expected data-segment bytes.
            runner_mod.applyActiveDataSegments(gpa, wasm_bytes, scratch_memory[0..]) catch |err| {
                try stdout.print("FAIL  {s}/{s} data-init: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                module_bad = true;
                continue;
            };
            // ADR-0052 §9.9 / 9.9-h-2 — write defined-globals
            // init values into the shared scratch buffer at the
            // module-specific per-global byte offsets the JIT
            // emit baked in. Without this, v128 globals start at
            // zero and assert_return on `global.get` returns
            // garbage (the prior 4-fail cluster on Mac).
            runner_mod.applyDefinedGlobalsInit(
                gpa,
                wasm_bytes,
                compiled.globals_offsets,
                compiled.globals_valtypes,
                scratch_globals[0..],
            ) catch |err| {
                try stdout.print("FAIL  {s}/{s} globals-init: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                module_bad = true;
                continue;
            };
            // D-063 discharge (§9.9 / 9.9-h-4) — populate the
            // funcref table from active element segments. Without
            // this, `call_indirect` traps on every call because
            // `table_size = 0` makes the bounds check (`CMP idx,
            // W25=0` → HS) always branch into the trap stub.
            runner_mod.applyTableInit(
                gpa,
                wasm_bytes,
                &compiled,
                scratch_funcptrs[0..],
                scratch_typeidxs[0..],
            ) catch |err| {
                try stdout.print("FAIL  {s}/{s} table-init: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                module_bad = true;
                continue;
            };
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_return ")) {
            if (module_bad) {
                skipped.* += 1;
                continue;
            }
            const compiled = current_compiled orelse {
                try stdout.print("FAIL  {s}: assert_return without prior module\n", .{name});
                failed.* += 1;
                continue;
            };
            const wasm = current_wasm.?;
            const ok = runAssertReturn(gpa, wasm, &compiled, line[14..], stdout, name) catch |err| {
                try stdout.print("FAIL  {s}: {s} (error {s})\n", .{ name, line, @errorName(err) });
                failed.* += 1;
                continue;
            };
            if (ok) {
                passed.* += 1;
            } else {
                failed.* += 1;
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_invalid ")) {
            const file = line[15..];
            const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                try stdout.print("FAIL  {s}/{s} (assert_invalid) read: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                var c = compiled_ok;
                c.deinit(gpa);
                try stdout.print("SKIP-VALIDATOR-GAP  {s}: assert_invalid {s}\n", .{ name, file });
                skipped.* += 1;
            } else |_| {
                passed.* += 1;
            }
            gpa.free(wasm_bytes);
            continue;
        }

        if (std.mem.startsWith(u8, line, "assert_malformed ")) {
            const file = line[17..];
            const wasm_bytes = dir.readFileAlloc(io, file, gpa, .limited(4 << 20)) catch |err| {
                try stdout.print("FAIL  {s}/{s} (assert_malformed) read: {s}\n", .{ name, file, @errorName(err) });
                failed.* += 1;
                continue;
            };
            if (runner_mod.compileWasm(gpa, wasm_bytes)) |compiled_ok| {
                var c = compiled_ok;
                c.deinit(gpa);
                try stdout.print("SKIP-PARSER-GAP  {s}: assert_malformed {s}\n", .{ name, file });
                skipped.* += 1;
            } else |_| {
                passed.* += 1;
            }
            gpa.free(wasm_bytes);
            continue;
        }

        try stdout.print("FAIL  {s}: unknown directive '{s}'\n", .{ name, line });
        failed.* += 1;
    }
}

fn parseI32Token(tok: []const u8) !u32 {
    return std.fmt.parseInt(u32, tok, 10) catch
        @as(u32, @bitCast(std.fmt.parseInt(i32, tok, 10) catch return error.BadValue));
}

fn parseI64Token(tok: []const u8) !u64 {
    return std.fmt.parseInt(u64, tok, 10) catch
        @as(u64, @bitCast(std.fmt.parseInt(i64, tok, 10) catch return error.BadValue));
}

fn parseV128Token(tok: []const u8) ![16]u8 {
    if (tok.len != 32) return error.BadValue;
    var out: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const hi = try std.fmt.charToDigit(tok[i * 2], 16);
        const lo = try std.fmt.charToDigit(tok[i * 2 + 1], 16);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

// Per-lane NaN-pattern result decoder (chunk 9.9-h-25). The
// canonical / arithmetic checks match Wasm spec §A.2 "Result
// types" + the testsuite's `nan:canonical` / `nan:arithmetic`
// semantics: a canonical NaN has exponent all-1s and mantissa =
// `1 << (mantissa_width - 1)` (sign arbitrary); an arithmetic
// NaN is any quiet NaN (exponent all-1s, mantissa MSB = 1).
const LaneShape = enum { f32x4, f64x2 };
const LaneSpec = union(enum) {
    canonical,
    arithmetic,
    exact: u64,
};

const ParsedV128Lanes = struct {
    shape: LaneShape,
    lanes: [4]LaneSpec,
    n_lanes: u8,
};

fn parseV128LanesToken(s: []const u8) !ParsedV128Lanes {
    // `s` is the suffix after `v128_lanes:`; expects
    // `<shape>:<lane0>,<lane1>,...,<laneN>`.
    const colon = std.mem.findScalar(u8, s, ':') orelse return error.BadValue;
    const shape_s = s[0..colon];
    const rest = s[colon + 1 ..];

    var out: ParsedV128Lanes = undefined;
    var hex_width: usize = undefined;
    if (std.mem.eql(u8, shape_s, "f32x4")) {
        out.shape = .f32x4;
        out.n_lanes = 4;
        hex_width = 8;
    } else if (std.mem.eql(u8, shape_s, "f64x2")) {
        out.shape = .f64x2;
        out.n_lanes = 2;
        hex_width = 16;
    } else return error.BadValue;

    var idx: u8 = 0;
    var it = std.mem.splitScalar(u8, rest, ',');
    while (it.next()) |lane_tok| {
        if (idx >= out.n_lanes) return error.BadValue;
        if (lane_tok.len == 1 and lane_tok[0] == 'c') {
            out.lanes[idx] = .canonical;
        } else if (lane_tok.len == 1 and lane_tok[0] == 'a') {
            out.lanes[idx] = .arithmetic;
        } else if (lane_tok.len == hex_width + 1 and lane_tok[0] == 'V') {
            const bits = try std.fmt.parseInt(u64, lane_tok[1..], 16);
            out.lanes[idx] = .{ .exact = bits };
        } else return error.BadValue;
        idx += 1;
    }
    if (idx != out.n_lanes) return error.BadValue;
    return out;
}

fn matchLaneF32(got_bits: u32, spec: LaneSpec) bool {
    return switch (spec) {
        // Canonical NaN: sign-agnostic ±0x7fc00000.
        .canonical => got_bits == 0x7fc00000 or got_bits == 0xffc00000,
        // Arithmetic NaN: exp all-1s + mantissa MSB = 1
        // (= any quiet NaN, includes canonical).
        .arithmetic => (got_bits & 0x7fc00000) == 0x7fc00000,
        .exact => |bits| got_bits == @as(u32, @intCast(bits & 0xffffffff)),
    };
}

fn matchLaneF64(got_bits: u64, spec: LaneSpec) bool {
    return switch (spec) {
        .canonical => got_bits == 0x7ff8000000000000 or got_bits == 0xfff8000000000000,
        .arithmetic => (got_bits & 0x7ff8000000000000) == 0x7ff8000000000000,
        .exact => |bits| got_bits == bits,
    };
}

const ArgKind = enum { i32, i64, f32, f64, v128 };
const ArgValue = union(ArgKind) {
    i32: u32,
    i64: u64,
    f32: u32,
    f64: u64,
    v128: [16]u8,
};

/// 64 KB scratch heap shared by every assertion. Mirrors the
/// `spec_assert_runner` shape exactly so the SIMD runner sees the
/// same `vm_base` / `mem_limit` semantics; data segments still
/// flow through `compileWasm`'s setupRuntime path on each `module`
/// directive.
var scratch_memory: [65536]u8 = undefined;

const Value = zwasm.runtime.Value;
/// Globals byte buffer. ADR-0052 — v128 globals live in 16-byte
/// slots (with 16-byte alignment); scalar globals in 8-byte
/// slots. 256 bytes accommodates up to 16 v128 globals or 32
/// scalars. Reset to zero on each `module` directive; init values
/// written via `applyDefinedGlobalsInit`.
var scratch_globals: [256]u8 align(16) = undefined;
/// D-063 discharge (§9.9 / 9.9-h-4) — funcref table for
/// `call_indirect`. Populated via `applyTableInit`. Sized for
/// realistic spec-fixture tables; simd_const.386 uses 2 entries.
const scratch_table_capacity = 32;
var scratch_funcptrs: [scratch_table_capacity]u64 = undefined;
var scratch_typeidxs: [scratch_table_capacity]u32 = undefined;

fn parseArgToken(tok: []const u8) !ArgValue {
    if (std.mem.startsWith(u8, tok, "i32:")) return .{ .i32 = try parseI32Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "i64:")) return .{ .i64 = try parseI64Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "f32:")) return .{ .f32 = try parseI32Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "f64:")) return .{ .f64 = try parseI64Token(tok[4..]) };
    if (std.mem.startsWith(u8, tok, "v128:")) return .{ .v128 = try parseV128Token(tok[5..]) };
    return error.BadValue;
}

fn runAssertReturn(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) !bool {
    // rest = "<fn> <args> -> <results>"
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = rest[0..arrow];
    const results_s = rest[arrow + 4 ..];

    const sp1 = std.mem.findScalar(u8, lhs, ' ') orelse return error.BadDirective;
    const fn_name = lhs[0..sp1];
    const args_s = lhs[sp1 + 1 ..];

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    var rt: entry.JitRuntime = .{
        .vm_base = scratch_memory[0..],
        .mem_limit = scratch_memory.len,
        // D-063 discharge — point at the call_indirect-ready
        // scratch funcref table populated by `applyTableInit` on
        // each `module` directive.
        .funcptr_base = &scratch_funcptrs,
        .table_size = scratch_funcptrs.len,
        .typeidx_base = &scratch_typeidxs,
        .trap_flag = 0,
        // ADR-0052 — JIT emit (`global.get/set` for both scalar
        // and v128 globals) addresses storage by byte offset off
        // `globals_base`. Cast the byte buffer as `[*]Value` so
        // the existing 8-byte-stride field type keeps compiling;
        // the actual access width depends on the global's valtype
        // (8B for scalars, 16B for v128 via MOVUPS/LDR-Q).
        .globals_base = @ptrCast(@alignCast(&scratch_globals)),
        .globals_count = scratch_globals.len / @sizeOf(Value),
        .host_dispatch_base = undefined,
        .host_dispatch_count = 0,
    };

    var args: [4]ArgValue = undefined;
    var n_args: usize = 0;
    if (!std.mem.eql(u8, args_s, "()")) {
        var arg_it = std.mem.tokenizeScalar(u8, args_s, ' ');
        while (arg_it.next()) |tok| {
            if (n_args >= args.len) {
                try stdout.print("FAIL  {s}: > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
                return false;
            }
            args[n_args] = parseArgToken(tok) catch {
                try stdout.print("FAIL  {s}: unsupported arg token ({s})\n", .{ name, tok });
                return false;
            };
            n_args += 1;
        }
    }

    // void result.
    if (std.mem.eql(u8, results_s, "()")) {
        if (n_args == 0) {
            entry.callVoidNoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
            return true;
        }
        // §9.9 / 9.9-h-3 (D-079 (i)) — v128 multi-arg setter shapes.
        // Drives simd_const fixtures like `as-global.set_value_$g0`
        // (1 v128 param) and `_$g0_$g1_$g2_$g3` (4 v128 params).
        if (n_args == 1 and args[0] == .v128) {
            entry.callVoid_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 2 and args[0] == .v128 and args[1] == .v128) {
            entry.callVoid_v128v128(compiled.module, func_idx, &rt, args[0].v128, args[1].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        if (n_args == 4 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128 and args[3] == .v128) {
            entry.callVoid_v128v128v128v128(
                compiled.module,
                func_idx,
                &rt,
                args[0].v128,
                args[1].v128,
                args[2].v128,
                args[3].v128,
            ) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        // chunk 9.9-h-28 (v128-param-pending residual discharge):
        // (i32, v128) → () — `simd_align` `v128.store align=16`.
        if (n_args == 2 and args[0] == .i32 and args[1] == .v128) {
            entry.callVoid_i32v128(compiled.module, func_idx, &rt, args[0].i32, args[1].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            return true;
        }
        try stdout.print("FAIL  {s}: void-result with {d} args unsupported for {s}\n", .{ name, n_args, fn_name });
        return false;
    }

    // Single-result decode.
    if (results_s.len < 4) {
        try stdout.print("FAIL  {s}: malformed result '{s}'\n", .{ name, results_s });
        return false;
    }

    if (std.mem.startsWith(u8, results_s, "v128:")) {
        const expected = parseV128Token(results_s[5..]) catch {
            try stdout.print("FAIL  {s}: bad v128 result token '{s}'\n", .{ name, results_s });
            return false;
        };
        const got = (try invokeV128(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], stdout, name)) orelse return false;
        if (!std.mem.eql(u8, &got, &expected)) {
            try stdout.print("FAIL  {s}: {s}({s}) → got v128:{x}, expected v128:{x}\n", .{ name, fn_name, args_s, got, expected });
            return false;
        }
        return true;
    }

    if (std.mem.startsWith(u8, results_s, "v128_lanes:")) {
        const parsed = parseV128LanesToken(results_s[11..]) catch {
            try stdout.print("FAIL  {s}: bad v128_lanes result token '{s}'\n", .{ name, results_s });
            return false;
        };
        const got = (try invokeV128(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], stdout, name)) orelse return false;
        switch (parsed.shape) {
            .f32x4 => {
                var lane: usize = 0;
                while (lane < 4) : (lane += 1) {
                    const off = lane * 4;
                    const bits = std.mem.readInt(u32, got[off..][0..4], .little);
                    if (!matchLaneF32(bits, parsed.lanes[lane])) {
                        try stdout.print(
                            "FAIL  {s}: {s}({s}) → f32x4 lane {d}: got 0x{x:0>8} vs {s}\n",
                            .{ name, fn_name, args_s, lane, bits, laneSpecName(parsed.lanes[lane]) },
                        );
                        return false;
                    }
                }
            },
            .f64x2 => {
                var lane: usize = 0;
                while (lane < 2) : (lane += 1) {
                    const off = lane * 8;
                    const bits = std.mem.readInt(u64, got[off..][0..8], .little);
                    if (!matchLaneF64(bits, parsed.lanes[lane])) {
                        try stdout.print(
                            "FAIL  {s}: {s}({s}) → f64x2 lane {d}: got 0x{x:0>16} vs {s}\n",
                            .{ name, fn_name, args_s, lane, bits, laneSpecName(parsed.lanes[lane]) },
                        );
                        return false;
                    }
                }
            },
        }
        return true;
    }

    // Scalar result.
    const result_kind: ArgKind = if (std.mem.startsWith(u8, results_s, "i32:")) .i32 else if (std.mem.startsWith(u8, results_s, "i64:")) .i64 else if (std.mem.startsWith(u8, results_s, "f32:")) .f32 else if (std.mem.startsWith(u8, results_s, "f64:")) .f64 else {
        try stdout.print("FAIL  {s}: unsupported result type '{s}'\n", .{ name, results_s });
        return false;
    };
    const exp_s = results_s[4..];
    const expected: u64 = switch (result_kind) {
        .i32, .f32 => @as(u64, try parseI32Token(exp_s)),
        .i64, .f64 => try parseI64Token(exp_s),
        .v128 => unreachable,
    };

    const got: u64 = blk: {
        if (n_args == 0 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            });
        }
        if (n_args == 0 and result_kind == .i64) {
            break :blk entry.callI64NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
        }
        if (n_args == 0 and result_kind == .f32) {
            const r = entry.callF32NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        if (n_args == 0 and result_kind == .f64) {
            const r = entry.callF64NoArgs(compiled.module, func_idx, &rt) catch |err| {
                try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        if (n_args == 1 and args[0] == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_i32(compiled.module, func_idx, &rt, args[0].i32) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-26 (v128-param-pending discharge): (v128) → i32
        // for i*x*.all_true / any_true / bitmask / extract_lane.{s,u}.
        if (n_args == 1 and args[0] == .v128 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-26: (v128) → f32 for f32x4.extract_lane.
        if (n_args == 1 and args[0] == .v128 and result_kind == .f32) {
            const r = entry.callF32_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        // chunk 9.9-h-26: (v128) → f64 for f64x2.extract_lane.
        if (n_args == 1 and args[0] == .v128 and result_kind == .f64) {
            const r = entry.callF64_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        // chunk 9.9-h-27 (v128-param-pending residual discharge):
        // (v128) → i64 for i64x2.extract_lane.
        if (n_args == 1 and args[0] == .v128 and result_kind == .i64) {
            break :blk entry.callI64_v128(compiled.module, func_idx, &rt, args[0].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        // chunk 9.9-h-27: (v128, v128) → i32 for composite
        // `*_with_v128.{and,or,xor}` / `*_as_i32.*_operand`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .v128 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128v128(compiled.module, func_idx, &rt, args[0].v128, args[1].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28 (v128-param-pending residual discharge):
        // (v128, v128, v128) → i32 — `simd_boolean`
        // `*_with_v128.bitselect` (any_true/all_true of bitselect).
        if (n_args == 3 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128v128v128(compiled.module, func_idx, &rt, args[0].v128, args[1].v128, args[2].v128) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28: (v128, i32) → i32 — `simd_lane`
        // `i*x*_replace_lane-{s,u}` / `as-i*x*_any_true-operand`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .i32 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128i32(compiled.module, func_idx, &rt, args[0].v128, args[1].i32) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28: (v128, i64) → i32 — `simd_lane`
        // `as-i32x4_any_true-operand2`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .i64 and result_kind == .i32) {
            break :blk @as(u64, entry.callI32_v128i64(compiled.module, func_idx, &rt, args[0].v128, args[1].i64) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            });
        }
        // chunk 9.9-h-28: (v128, i64) → i64 — `simd_lane`
        // `i64x2_replace_lane`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .i64 and result_kind == .i64) {
            break :blk entry.callI64_v128i64(compiled.module, func_idx, &rt, args[0].v128, args[1].i64) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
        }
        // chunk 9.9-h-28: (v128, f32) → f32 — `simd_lane`
        // `f32x4_replace_lane`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .f32 and result_kind == .f32) {
            const r = entry.callF32_v128f32(compiled.module, func_idx, &rt, args[0].v128, @as(f32, @bitCast(args[1].f32))) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @as(u32, @bitCast(r)));
        }
        // chunk 9.9-h-28: (v128, f64) → f64 — `simd_lane`
        // `f64x2_replace_lane`.
        if (n_args == 2 and args[0] == .v128 and args[1] == .f64 and result_kind == .f64) {
            const r = entry.callF64_v128f64(compiled.module, func_idx, &rt, args[0].v128, @as(f64, @bitCast(args[1].f64))) catch |err| {
                try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
                return false;
            };
            break :blk @as(u64, @bitCast(r));
        }
        try stdout.print("FAIL  {s}: scalar-result unsupported (n_args={d}, shape) for {s}({s}) -> {s}\n", .{ name, n_args, fn_name, args_s, results_s });
        return false;
    };

    if (got != expected) {
        try stdout.print("FAIL  {s}: {s}({s}) → got {d}, expected {d}\n", .{ name, fn_name, args_s, got, expected });
        return false;
    }
    return true;
}

/// Dispatch the JIT-compiled function for a v128-result assertion.
/// Returns `null` on unsupported shape / call error (after the
/// caller-level FAIL line has been printed); the caller maps `null`
/// to `return false` from `runAssertReturn`.
fn invokeV128(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    fn_name: []const u8,
    args_s: []const u8,
    args: []const ArgValue,
    stdout: *std.Io.Writer,
    name: []const u8,
) !?[16]u8 {
    const n_args = args.len;
    if (n_args == 0) {
        return entry.callV128NoArgs(compiled.module, func_idx, rt) catch |err| {
            try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
            return null;
        };
    }
    if (n_args == 1 and args[0] == .i32) {
        return entry.callV128_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 1 and args[0] == .v128) {
        return entry.callV128_v128(compiled.module, func_idx, rt, args[0].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 2 and args[0] == .v128 and args[1] == .v128) {
        return entry.callV128_v128v128(compiled.module, func_idx, rt, args[0].v128, args[1].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (n_args == 3 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128) {
        return entry.callV128_v128v128v128(compiled.module, func_idx, rt, args[0].v128, args[1].v128, args[2].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-26 (v128-param-pending discharge):
    // (v128, i32) → v128 — i*x*.shl/shr_s/shr_u + i*x*.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .i32) {
        return entry.callV128_v128i32(compiled.module, func_idx, rt, args[0].v128, args[1].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-26: (v128, f32) → v128 — f32x4.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .f32) {
        const r = entry.callV128_v128f32(compiled.module, func_idx, rt, args[0].v128, @as(f32, @bitCast(args[1].f32))) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return r;
    }
    // chunk 9.9-h-26: (v128, f64) → v128 — f64x2.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .f64) {
        const r = entry.callV128_v128f64(compiled.module, func_idx, rt, args[0].v128, @as(f64, @bitCast(args[1].f64))) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return r;
    }
    // chunk 9.9-h-27 (v128-param-pending residual discharge):
    // (v128, i64) → v128 — i64x2.replace_lane.
    if (n_args == 2 and args[0] == .v128 and args[1] == .i64) {
        return entry.callV128_v128i64(compiled.module, func_idx, rt, args[0].v128, args[1].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-27: (v128, v128, i32) → v128 — select_v128_i32.
    if (n_args == 3 and args[0] == .v128 and args[1] == .v128 and args[2] == .i32) {
        return entry.callV128_v128v128i32(compiled.module, func_idx, rt, args[0].v128, args[1].v128, args[2].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28 (v128-param-pending residual discharge):
    // (v128, v128, v128, v128) → v128 — `simd_lane`
    // `swizzle-as-i8x16_add-operands` / `shuffle-as-i8x16_sub-operands`.
    if (n_args == 4 and args[0] == .v128 and args[1] == .v128 and args[2] == .v128 and args[3] == .v128) {
        return entry.callV128_v128v128v128v128(compiled.module, func_idx, rt, args[0].v128, args[1].v128, args[2].v128, args[3].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28: (v128, i32, v128) → v128 — `simd_lane`
    // `as-v8x16_swizzle-operand`.
    if (n_args == 3 and args[0] == .v128 and args[1] == .i32 and args[2] == .v128) {
        return entry.callV128_v128i32v128(compiled.module, func_idx, rt, args[0].v128, args[1].i32, args[2].v128) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28: (v128, i32, v128, i32) → v128 — `simd_lane`
    // `as-v8x16_shuffle-operands` / `as-i*x*_add-operands`.
    if (n_args == 4 and args[0] == .v128 and args[1] == .i32 and args[2] == .v128 and args[3] == .i32) {
        return entry.callV128_v128i32v128i32(compiled.module, func_idx, rt, args[0].v128, args[1].i32, args[2].v128, args[3].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    // chunk 9.9-h-28: (v128, i64, v128, i64) → v128 — `simd_lane`
    // `as-i64x2_add-operands`.
    if (n_args == 4 and args[0] == .v128 and args[1] == .i64 and args[2] == .v128 and args[3] == .i64) {
        return entry.callV128_v128i64v128i64(compiled.module, func_idx, rt, args[0].v128, args[1].i64, args[2].v128, args[3].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    try stdout.print("FAIL  {s}: v128-result unsupported (n_args={d}, arg shape) for {s}({s})\n", .{ name, n_args, fn_name, args_s });
    return null;
}

fn laneSpecName(spec: LaneSpec) []const u8 {
    return switch (spec) {
        .canonical => "nan:canonical",
        .arithmetic => "nan:arithmetic",
        .exact => "exact",
    };
}
