//! Wasm 2.0 non-SIMD spec assertion runner — JIT-execute + compare
//! scalar (i32 / i64 / f32 / f64) assertions against the curated
//! `test/spec/wasm-2.0-assert/` corpus (l-1b per ADR-0057).
//!
//! Parallel to `simd_assert_runner.zig`: both consume
//! `spec_assert_runner_base` and differ only in their
//! `RunnerCallbacks` literal. SIMD result decoding (per-lane NaN,
//! v128_lanes tokens) is unreachable here; this runner rejects
//! any `v128:` result token with FAIL. The wasm-1.0 corpus
//! continues to be served by the legacy `spec_assert_runner.zig`
//! (its PASS-line and `(D-042)` SKIP suffix shape predates base
//! and is preserved verbatim for the §9.7 / 7.5 gate semantics).
//!
//! Per ADR-0029 Path B: the twin tally split (skip-impl vs
//! skip-adr-<id>) flows through `base.AssertTally`; this runner
//! prints the same summary line shape as `simd_assert_runner`.
//!
//! Usage:
//!   spec_assert_runner_non_simd <corpus-root>
//! exits non-zero if any `failed > 0`. A missing corpus directory
//! reports `0 manifests` and exits clean — matches the SIMD runner
//! shape so an empty checkout (or the staged l-1b state before
//! the curated corpus lands) doesn't fail `test-all`.

const std = @import("std");

const zwasm = @import("zwasm");
const runner_mod = zwasm.engine.runner;
const entry = zwasm.engine.codegen.shared.entry;
const base = @import("spec_assert_runner_base.zig");

const ArgKind = base.ArgKind;
const ArgValue = base.ArgValue;

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
        try stdout.print("usage: spec_assert_runner_non_simd <corpus-root>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_root = try gpa.dupe(u8, corpus_root_arg);
    defer gpa.free(corpus_root);

    var tally: base.AssertTally = .{};
    var manifest_count: u32 = 0;

    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, corpus_root, .{ .iterate = true }) catch |err| {
        try stdout.print("spec_assert_runner_non_simd: corpus '{s}' not found ({s}); 0 manifests\n", .{ corpus_root, @errorName(err) });
        try stdout.flush();
        return;
    };
    defer root.close(io);

    var iter = root.iterate();
    while (try iter.next(io)) |dir_entry| {
        if (dir_entry.kind != .directory) continue;
        manifest_count += 1;
        try base.runCorpus(io, gpa, &root, dir_entry.name, stdout, &tally, non_simd_callbacks);
    }

    try stdout.print(
        "\nspec_assert_runner_non_simd: {d} passed, {d} failed, {d} skipped (= {d} skip-impl + {d} skip-adr) (over {d} manifests)\n",
        .{ tally.passed, tally.failed, tally.skipped + tally.skipped_adr, tally.skipped, tally.skipped_adr, manifest_count },
    );
    try stdout.flush();

    if (tally.failed > 0) std.process.exit(1);
}

/// 64 KB scratch heap — mirror of simd / wasm-1.0 runners. Each
/// `module` directive resets to zero; per-fixture in-fixture state
/// (memory.store + memory.load round-trips) is preserved across
/// asserts within one fixture.
var scratch_memory: [65536]u8 = undefined;

/// 256-byte globals buffer — ADR-0052 byte-offset layout. Scalar
/// globals occupy 8 bytes each; up to 32 globals supported per
/// fixture. 16-byte alignment kept (not strictly required without
/// v128 but harmless + matches the simd runner shape for
/// future-proofing if a Wasm 2.0 fixture imports a v128 global).
var scratch_globals: [256]u8 align(16) = undefined;

/// Funcref table for `call_indirect` — Wasm 2.0 spec fixtures
/// (call_indirect, table_get / set, table_init, etc.) need this
/// populated from active element segments per D-063's pattern.
const scratch_table_capacity = 32;
var scratch_funcptrs: [scratch_table_capacity]u64 = undefined;
var scratch_typeidxs: [scratch_table_capacity]u32 = undefined;

/// `RunnerCallbacks.on_module_loaded` — repopulate scratch state
/// from the freshly-compiled module's active segments. Mirrors
/// `simd_assert_runner.simdOnModuleLoaded`; the only difference
/// is the SIMD runner's scratch_globals carries v128 16-byte
/// slots while this runner's holds 8-byte scalar slots. The
/// `applyDefinedGlobalsInit` helper is shape-aware and writes
/// the correct width per global's valtype.
fn nonSimdOnModuleLoaded(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!void {
    @memset(scratch_memory[0..], 0);
    @memset(scratch_globals[0..], 0);

    runner_mod.applyActiveDataSegments(gpa, wasm_bytes, scratch_memory[0..]) catch |err| {
        try stdout.print("FAIL  {s} data-init: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    runner_mod.applyDefinedGlobalsInit(
        gpa,
        wasm_bytes,
        compiled.globals_offsets,
        compiled.globals_valtypes,
        scratch_globals[0..],
    ) catch |err| {
        try stdout.print("FAIL  {s} globals-init: {s}\n", .{ name, @errorName(err) });
        return err;
    };
    runner_mod.applyTableInit(
        gpa,
        wasm_bytes,
        compiled,
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
    ) catch |err| {
        try stdout.print("FAIL  {s} table-init: {s}\n", .{ name, @errorName(err) });
        return err;
    };
}

/// `RunnerCallbacks.handle_assert_return` — scalar (i32 / i64 /
/// f32 / f64) dispatch. The dispatch ladder mirrors the legacy
/// `spec_assert_runner.zig`'s shape (n_args × arg-kind × result-
/// kind triple) so wasm-1.0-class fixtures port cleanly when the
/// curated wasm-2.0-assert corpus lands; v128 tokens are rejected
/// outright since this runner is the non-SIMD specialisation.
fn nonSimdRunAssertReturn(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const arrow = std.mem.find(u8, rest, " -> ") orelse return error.BadDirective;
    const lhs = rest[0..arrow];
    const results_s = rest[arrow + 4 ..];

    const fa = try base.splitFnAndArgs(lhs);
    const fn_name = fa.fn_name;
    const args_s = fa.args_s;

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    var rt = base.makeJitRuntime(
        scratch_memory[0..],
        scratch_globals[0..],
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
    );

    var args: [5]ArgValue = undefined;
    const n_args = base.parseAssertReturnArgs(args_s, &args) catch |err| {
        if (err == error.TooManyArgs) {
            try stdout.print("FAIL  {s}: > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
        } else {
            try stdout.print("FAIL  {s}: unsupported arg token ({s})\n", .{ name, args_s });
        }
        return false;
    };

    // Reject v128 args at the dispatch boundary — this runner is
    // the non-SIMD specialisation; v128-aware fixtures belong to
    // simd_assert_runner.
    for (args[0..n_args]) |a| {
        if (a == .v128) {
            try stdout.print("FAIL  {s}: v128 arg in non-SIMD runner ({s})\n", .{ name, args_s });
            return false;
        }
    }

    // Void-result dispatch.
    if (std.mem.eql(u8, results_s, "()")) {
        return dispatchVoidResult(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], stdout, name);
    }

    // v128 result token unreachable here.
    if (std.mem.startsWith(u8, results_s, "v128") or std.mem.startsWith(u8, results_s, "v128_lanes:")) {
        try stdout.print("FAIL  {s}: v128 result in non-SIMD runner ({s})\n", .{ name, results_s });
        return false;
    }

    // Scalar result.
    if (results_s.len < 4) {
        try stdout.print("FAIL  {s}: malformed result '{s}'\n", .{ name, results_s });
        return false;
    }
    const result_kind: ArgKind = if (std.mem.startsWith(u8, results_s, "i32:")) .i32 else if (std.mem.startsWith(u8, results_s, "i64:")) .i64 else if (std.mem.startsWith(u8, results_s, "f32:")) .f32 else if (std.mem.startsWith(u8, results_s, "f64:")) .f64 else {
        try stdout.print("FAIL  {s}: unsupported result type '{s}'\n", .{ name, results_s });
        return false;
    };
    const exp_s = results_s[4..];

    const got: u64 = (try dispatchScalarResult(compiled, func_idx, &rt, fn_name, args_s, args[0..n_args], result_kind, stdout, name)) orelse return false;

    // FP results: parse expected via `parseScalarFpExpected` so
    // `nan:canonical` / `nan:arithmetic` tokens compare via the
    // NaN-class matcher (Wasm spec §A.2). Integer results stay on
    // the bit-pattern equality path.
    switch (result_kind) {
        .f32 => {
            const spec = base.parseScalarFpExpected(exp_s, 32) catch {
                try stdout.print("FAIL  {s}: bad f32 result '{s}'\n", .{ name, results_s });
                return false;
            };
            const got_bits: u32 = @intCast(got & 0xffffffff);
            if (!base.matchScalarF32(got_bits, spec)) {
                try stdout.print("FAIL  {s}: {s}({s}) → got f32:0x{x:0>8}, expected {s}\n", .{ name, fn_name, args_s, got_bits, exp_s });
                return false;
            }
            return true;
        },
        .f64 => {
            const spec = base.parseScalarFpExpected(exp_s, 64) catch {
                try stdout.print("FAIL  {s}: bad f64 result '{s}'\n", .{ name, results_s });
                return false;
            };
            if (!base.matchScalarF64(got, spec)) {
                try stdout.print("FAIL  {s}: {s}({s}) → got f64:0x{x:0>16}, expected {s}\n", .{ name, fn_name, args_s, got, exp_s });
                return false;
            }
            return true;
        },
        .i32, .i64 => {
            const expected: u64 = if (result_kind == .i32)
                @as(u64, try base.parseI32Token(exp_s))
            else
                try base.parseI64Token(exp_s);
            if (got != expected) {
                try stdout.print("FAIL  {s}: {s}({s}) → got {d}, expected {d}\n", .{ name, fn_name, args_s, got, expected });
                return false;
            }
            return true;
        },
        .v128 => unreachable,
    }
}

/// Void-result dispatch ladder. Returns `false` on shape-unsupported
/// OR trap; the assert_return semantics treat both as failure (no
/// expected value to compare). The shapes covered mirror the
/// legacy wasm-1.0 runner; multi-value 5-arg dispatch
/// (`(i64, f32, f64, i32, i32)`) is included for parity with
/// upstream multi-value spec fixtures.
fn dispatchVoidResult(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    fn_name: []const u8,
    args_s: []const u8,
    args: []const ArgValue,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    if (args.len == 0) {
        entry.callVoidNoArgs(compiled.module, func_idx, rt) catch |err| {
            try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .i32) {
        entry.callVoid_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .i64) {
        entry.callVoid_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        entry.callVoid_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return false;
        };
        return true;
    }
    if (args.len == 1 and args[0] == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        entry.callVoid_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return false;
        };
        return true;
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32) {
        entry.callVoid_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return false;
        };
        return true;
    }
    if (args.len == 5 and args[0] == .i64 and args[1] == .f32 and args[2] == .f64 and args[3] == .i32 and args[4] == .i32) {
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f64 = @bitCast(args[2].f64);
        entry.callVoid_i64f32f64i32i32(compiled.module, func_idx, rt, args[0].i64, a1, a2, args[3].i32, args[4].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return false;
        };
        return true;
    }
    try stdout.print("FAIL  {s}: void-result unsupported (n_args={d}) for {s}({s})\n", .{ name, args.len, fn_name, args_s });
    return false;
}

/// Scalar-result dispatch ladder. Returns the bit-pattern as `u64`
/// (caller compares against the parsed expected value). `null` on
/// shape-unsupported or trap (caller treats as FAIL; the dispatch
/// already printed the FAIL line).
fn dispatchScalarResult(
    compiled: *const runner_mod.CompiledWasm,
    func_idx: u32,
    rt: *entry.JitRuntime,
    fn_name: []const u8,
    args_s: []const u8,
    args: []const ArgValue,
    result_kind: ArgKind,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!?u64 {
    if (args.len == 0 and result_kind == .i32) {
        return @as(u64, entry.callI32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
            return null;
        });
    }
    if (args.len == 0 and result_kind == .i64) {
        return entry.callI64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
            return null;
        };
    }
    if (args.len == 0 and result_kind == .f32) {
        const r = entry.callF32NoArgs(compiled.module, func_idx, rt) catch |err| {
            try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 0 and result_kind == .f64) {
        const r = entry.callF64NoArgs(compiled.module, func_idx, rt) catch |err| {
            try stdout.print("FAIL  {s}: call {s}(): {s}\n", .{ name, fn_name, @errorName(err) });
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .i64) {
        return entry.callI64_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (args.len == 1 and args[0] == .i64 and result_kind == .i64) {
        return entry.callI64_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const r = entry.callF32_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const r = entry.callF64_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    // §9.9 / 9.9-l-1b-widen: cross-type scalar shapes from
    // conversions.wast — trunc / trunc_sat (FP→int), convert
    // (int→FP), promote / demote / reinterpret across FP widths.
    if (args.len == 1 and args[0] == .i64 and result_kind == .i32) {
        return @as(u64, entry.callI32_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .i32) {
        const a0: f32 = @bitCast(args[0].f32);
        return @as(u64, entry.callI32_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .i32) {
        const a0: f64 = @bitCast(args[0].f64);
        return @as(u64, entry.callI32_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .i64) {
        const a0: f32 = @bitCast(args[0].f32);
        return entry.callI64_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .i64) {
        const a0: f64 = @bitCast(args[0].f64);
        return entry.callI64_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .f32) {
        const r = entry.callF32_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .i64 and result_kind == .f32) {
        const r = entry.callF32_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .i32 and result_kind == .f64) {
        const r = entry.callF64_i32(compiled.module, func_idx, rt, args[0].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 1 and args[0] == .i64 and result_kind == .f64) {
        const r = entry.callF64_i64(compiled.module, func_idx, rt, args[0].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 1 and args[0] == .f64 and result_kind == .f32) {
        const a0: f64 = @bitCast(args[0].f64);
        const r = entry.callF32_f64(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 1 and args[0] == .f32 and result_kind == .f64) {
        const a0: f32 = @bitCast(args[0].f32);
        const r = entry.callF64_f32(compiled.module, func_idx, rt, a0) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 2 and args[0] == .i32 and args[1] == .i32 and result_kind == .i32) {
        return @as(u64, entry.callI32_i32i32(compiled.module, func_idx, rt, args[0].i32, args[1].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    // §9.9 / 9.9-l-1b-binop: i64 / f32 / f64 2-arg shapes
    // (binop + cmp families exercised by i64 / f32 / f64 / *_cmp wasts).
    if (args.len == 2 and args[0] == .i64 and args[1] == .i64 and result_kind == .i64) {
        return entry.callI64_i64i64(compiled.module, func_idx, rt, args[0].i64, args[1].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (args.len == 2 and args[0] == .i64 and args[1] == .i64 and result_kind == .i32) {
        return @as(u64, entry.callI32_i64i64(compiled.module, func_idx, rt, args[0].i64, args[1].i64) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    if (args.len == 2 and args[0] == .f32 and args[1] == .f32 and result_kind == .f32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        const r = entry.callF32_f32f32(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @as(u32, @bitCast(r)));
    }
    if (args.len == 2 and args[0] == .f32 and args[1] == .f32 and result_kind == .i32) {
        const a0: f32 = @bitCast(args[0].f32);
        const a1: f32 = @bitCast(args[1].f32);
        return @as(u64, entry.callI32_f32f32(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    if (args.len == 2 and args[0] == .f64 and args[1] == .f64 and result_kind == .f64) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        const r = entry.callF64_f64f64(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    if (args.len == 2 and args[0] == .f64 and args[1] == .f64 and result_kind == .i32) {
        const a0: f64 = @bitCast(args[0].f64);
        const a1: f64 = @bitCast(args[1].f64);
        return @as(u64, entry.callI32_f64f64(compiled.module, func_idx, rt, a0, a1) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        });
    }
    if (args.len == 5 and args[0] == .i64 and args[1] == .f32 and args[2] == .f64 and args[3] == .i32 and args[4] == .i32 and result_kind == .i64) {
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f64 = @bitCast(args[2].f64);
        return entry.callI64_i64f32f64i32i32(compiled.module, func_idx, rt, args[0].i64, a1, a2, args[3].i32, args[4].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
    }
    if (args.len == 5 and args[0] == .i64 and args[1] == .f32 and args[2] == .f64 and args[3] == .i32 and args[4] == .i32 and result_kind == .f64) {
        const a1: f32 = @bitCast(args[1].f32);
        const a2: f64 = @bitCast(args[2].f64);
        const r = entry.callF64_i64f32f64i32i32(compiled.module, func_idx, rt, args[0].i64, a1, a2, args[3].i32, args[4].i32) catch |err| {
            try stdout.print("FAIL  {s}: call {s}({s}): {s}\n", .{ name, fn_name, args_s, @errorName(err) });
            return null;
        };
        return @as(u64, @bitCast(r));
    }
    try stdout.print("FAIL  {s}: unsupported shape n_args={d} result_kind={s} for {s}({s})\n", .{ name, args.len, @tagName(result_kind), fn_name, args_s });
    return null;
}

/// `RunnerCallbacks.handle_assert_trap` — invokes the function +
/// classifies the outcome. Any successful call (including matching
/// the expected value happenstance) is a FAIL; `Error.Trap` is a
/// PASS; any other error is a distinct FAIL line. Trap-reason
/// discrimination is D-022's scope (interp trap-location wiring);
/// today the runner only checks "did trap occur".
fn nonSimdRunAssertTrap(
    gpa: std.mem.Allocator,
    wasm_bytes: []const u8,
    compiled: *const runner_mod.CompiledWasm,
    rest: []const u8,
    stdout: *std.Io.Writer,
    name: []const u8,
) anyerror!bool {
    const fa = try base.splitFnAndArgs(rest);
    const fn_name = fa.fn_name;
    const args_s = fa.args_s;

    const func_idx = runner_mod.findExportFunc(gpa, wasm_bytes, fn_name) catch |err| {
        try stdout.print("FAIL  {s}: assert_trap findExport({s}): {s}\n", .{ name, fn_name, @errorName(err) });
        return false;
    };

    var rt = base.makeJitRuntime(
        scratch_memory[0..],
        scratch_globals[0..],
        scratch_funcptrs[0..],
        scratch_typeidxs[0..],
    );

    var args: [5]ArgValue = undefined;
    const n_args = base.parseAssertReturnArgs(args_s, &args) catch |err| {
        if (err == error.TooManyArgs) {
            try stdout.print("FAIL  {s}: assert_trap > {d} args unsupported ({s})\n", .{ name, args.len, args_s });
        } else {
            try stdout.print("FAIL  {s}: assert_trap unsupported arg token ({s})\n", .{ name, args_s });
        }
        return false;
    };

    for (args[0..n_args]) |a| {
        if (a == .v128) {
            try stdout.print("FAIL  {s}: assert_trap v128 arg in non-SIMD runner ({s})\n", .{ name, args_s });
            return false;
        }
    }

    // Invoke via the simplest matching shape. Result type is
    // immaterial — `Error.Trap` is the only PASS outcome.
    const trapped: bool = blk: {
        if (n_args == 0) {
            _ = entry.callI32NoArgs(compiled.module, func_idx, &rt) catch |err| {
                break :blk err == entry.Error.Trap;
            };
            break :blk false;
        }
        if (n_args == 1 and args[0] == .i32) {
            _ = entry.callI32_i32(compiled.module, func_idx, &rt, args[0].i32) catch |err| {
                break :blk err == entry.Error.Trap;
            };
            break :blk false;
        }
        if (n_args == 1 and args[0] == .i64) {
            _ = entry.callI64_i64(compiled.module, func_idx, &rt, args[0].i64) catch |err| {
                break :blk err == entry.Error.Trap;
            };
            break :blk false;
        }
        if (n_args == 2 and args[0] == .i32 and args[1] == .i32) {
            _ = entry.callI32_i32i32(compiled.module, func_idx, &rt, args[0].i32, args[1].i32) catch |err| {
                break :blk err == entry.Error.Trap;
            };
            break :blk false;
        }
        if (n_args == 2 and args[0] == .i64 and args[1] == .i64) {
            _ = entry.callI64_i64i64(compiled.module, func_idx, &rt, args[0].i64, args[1].i64) catch |err| {
                break :blk err == entry.Error.Trap;
            };
            break :blk false;
        }
        // §9.9 / 9.9-l-1b-trap-widen — f32 / f64 arg shapes.
        // Trap-result type is immaterial; reuse the cross-type
        // entry helpers added at widen (callI32_f32 / callI64_f64
        // etc.) since they share the same FP-arg ABI lane.
        if (n_args == 1 and args[0] == .f32) {
            const a0: f32 = @bitCast(args[0].f32);
            _ = entry.callI32_f32(compiled.module, func_idx, &rt, a0) catch |err| {
                break :blk err == entry.Error.Trap;
            };
            break :blk false;
        }
        if (n_args == 1 and args[0] == .f64) {
            const a0: f64 = @bitCast(args[0].f64);
            _ = entry.callI32_f64(compiled.module, func_idx, &rt, a0) catch |err| {
                break :blk err == entry.Error.Trap;
            };
            break :blk false;
        }
        try stdout.print("FAIL  {s}: assert_trap unsupported shape n_args={d} for {s}({s})\n", .{ name, n_args, fn_name, args_s });
        return false;
    };

    if (!trapped) {
        try stdout.print("FAIL  {s}: assert_trap {s}({s}) did not trap\n", .{ name, fn_name, args_s });
        return false;
    }
    return true;
}

const non_simd_callbacks: base.RunnerCallbacks = .{
    .on_module_loaded = nonSimdOnModuleLoaded,
    .handle_assert_return = nonSimdRunAssertReturn,
    .handle_assert_trap = nonSimdRunAssertTrap,
};
