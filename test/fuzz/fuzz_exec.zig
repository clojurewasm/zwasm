//! Interp-vs-JIT EXECUTION differential fuzzer (D-469).
//!
//! Walks a corpus of `wasm-tools smith` modules and, for each one that BOTH
//! engines instantiate, invokes every 0-param / single-scalar-result (i32/i64/
//! f32/f64) export under the interp (`Instance.invoke`) AND the JIT (`JitInstance.invoke`) with
//! a deterministic fuel budget, then compares the outcomes. A divergence —
//! interp returns a value the JIT doesn't (or vice versa), the two return
//! DIFFERENT values, or both trap with DIFFERENT precise kinds — is a finding
//! (the D-330/D-331A/D-468 JIT-execute-miscompile class + the D-470/GC-trap-kind
//! precision class, neither of which the spec/realworld corpora reliably reach).
//! A process-level CRASH (panic / unreachable / SEGV) is likewise a finding
//! (external detection: the process dies, the runner sees the signal exit).
//!
//! Trap-kind compare: both engines map a trap to the shared `trap_surface.TrapKind`
//! (interp error → `mapInterpTrap`; JIT raw code → `jitTrapCode`). Kinds are only
//! compared when BOTH sides name one precisely; an interp `binding_error` (host
//! catch-all) or a JIT generic-bucket code (raw 0/1, codegen-unsplit) is treated
//! as incomparable and falls back to the lenient both-trap-OK rule — no false
//! mismatch, but a genuine kind divergence (e.g. interp `null_reference` vs JIT
//! `oob_memory`) is caught.
//!
//! Why FOCUSED (0-param, 1 scalar result): it sidesteps argument generation and
//! the multi-result / v128 / ref-result marshalling mismatch between the two
//! invoke ABIs (interp `[]Value`; JIT `[]u64 → ?u64`), while still exercising the
//! full function body under both engines. Widening to (zero-filled) i32/i64 PARAMS
//! was measured to add 0 funcs (the single-scalar-RESULT filter is binding, not
//! params), so params stay at 0; the RESULT filter does include f32/f64 — FP
//! execution is a prime divergence source and the bit-compare is sound under the
//! corpus's `canonicalize-nans`.
//!
//! Fuel: both engines are bounded so an infinite-loop smith body can't hang the
//! fuzzer. The fuel UNITS differ (interp = per-instruction; JIT = poll-site
//! crossings), so `out_of_fuel` on EITHER side is NOT comparable — that function
//! is skipped. Modules with imports are skipped (interp instantiate fails without
//! a host → the whole module is skipped, avoiding an import asymmetry).
//!
//! GATING: prints each MISMATCH (module / func / values) and exits non-zero if
//! any divergence is seen (the campaign baseline confirmed 122 funcs / 0 mismatch).
//!
//! Usage: `zig build test-fuzz-exec` (seed corpus) / `zwasm-fuzz-exec <dir>`.

const std = @import("std");

const zwasm = @import("zwasm");
const engine_runner = zwasm.engine.runner;
const trap_surface = zwasm.api.trap_surface;
const TrapKind = trap_surface.TrapKind;

const FUEL: u64 = 200_000;
const OUT_OF_FUEL_KIND: u32 = 17; // jit raw trap_kind for out_of_fuel

const Outcome = union(enum) {
    value: u64, // normalised result bits (i32 zero-extended into the low 32)
    // A non-fuel trap. The payload is the PRECISE trap kind when both ABIs can
    // name it (interp error → `mapInterpTrap`; JIT raw code → `jitTrapCode`), or
    // `null` when incomparable — interp `binding_error` (host catch-all) or JIT
    // generic bucket (raw 0/1, codegen-unsplit). Comparing kinds catches the
    // D-470 / GC-trap-kind-precision class (both engines trap, but with DIFFERENT
    // kinds) that a plain both-trap-OK check silently passes; `null` on either
    // side falls back to that lenient both-trap-OK to avoid a false mismatch.
    trap: ?TrapKind,
    fuel, // out_of_fuel — not comparable across engines
};

fn kindName(k: ?TrapKind) []const u8 {
    return if (k) |kk| @tagName(kk) else "(incomparable)";
}

// f32/f64 results: the smith corpus is generated with `canonicalize-nans` so a
// NaN result is the single canonical bit pattern in BOTH engines — a direct bit
// compare is sound (a differing NaN payload would be a real spec divergence). The
// curated f32/f64 exec_seed cases return non-NaN finite values, so the committed
// gate doesn't depend on the canonicalisation either way.

/// Normalise an interp result Value to its raw bits (32-bit scalars zero-extended
/// into the low 32, matching the JIT's `dispatchNoArg` carrier encoding).
fn valueBits(v: zwasm.Value) u64 {
    return switch (v) {
        .i32 => |x| @as(u64, @as(u32, @bitCast(x))),
        .f32 => |x| @as(u64, @as(u32, @bitCast(x))),
        .i64 => |x| @bitCast(x),
        .f64 => |x| @bitCast(x),
        else => 0, // filtered out before invoke
    };
}

fn interpInvoke(inst: *zwasm.Instance, name: []const u8) Outcome {
    var results: [1]zwasm.Value = undefined;
    inst.invoke(name, &.{}, results[0..1]) catch |err| {
        if (err == error.OutOfFuel) return .fuel;
        const k = trap_surface.mapInterpTrap(err);
        // `binding_error` is the host catch-all bucket, not a spec trap kind the
        // JIT path emits — treat as incomparable rather than risk a false mismatch.
        return .{ .trap = if (k == .binding_error) null else k };
    };
    return .{ .value = valueBits(results[0]) };
}

fn jitInvoke(jit: *engine_runner.JitInstance, gpa: std.mem.Allocator, name: []const u8) Outcome {
    // `JitInstance.invoke` returns the scalar result as a u64 carrier already
    // zero-extended for 32-bit types (dispatchNoArg) — matches `valueBits`.
    const r = jit.invoke(gpa, name, &.{}) catch {
        const raw = jit.owned.rt.trap_kind;
        if (raw == OUT_OF_FUEL_KIND) return .fuel;
        // `jitTrapCode` → null for the generic bucket (raw 0/1) the codegen does
        // not split per-kind; null = incomparable (preserve the both-trap-OK path).
        return .{ .trap = trap_surface.jitTrapCode(raw) };
    };
    return .{ .value = r orelse 0 };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    _ = arg_it.next().?;
    const corpus_dir_arg = arg_it.next() orelse {
        try stdout.print("usage: zwasm-fuzz-exec <corpus-dir>\n", .{});
        try stdout.flush();
        std.process.exit(2);
    };
    const corpus_dir = try gpa.dupe(u8, corpus_dir_arg);
    defer gpa.free(corpus_dir);

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, corpus_dir, .{ .iterate = true }) catch |err| {
        try stdout.print("error: cannot open '{s}': {s}\n", .{ corpus_dir, @errorName(err) });
        try stdout.flush();
        std.process.exit(1);
    };
    defer dir.close(io);

    var processed: u32 = 0;
    var modules_compared: u32 = 0;
    var funcs_compared: u32 = 0;
    var mismatched: u32 = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const bytes = dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(bytes);
        processed += 1;

        // Interp: compile + instantiate. Any error (invalid / imports / start
        // trap) → skip the whole module (keeps the engines symmetric).
        var eng = zwasm.Engine.init(gpa, .{}) catch continue;
        defer eng.deinit();
        var mod = eng.compile(bytes) catch continue;
        defer mod.deinit();
        var interp_inst = mod.instantiate(.{}) catch continue;
        defer interp_inst.deinit();

        // JIT: instantiate. UnsupportedOp / import / resource errors → skip.
        var jit = engine_runner.JitInstance.init(gpa, bytes) catch continue;
        defer jit.deinit(gpa);

        modules_compared += 1;

        for (jit.compiled.exports) |fe| {
            const name = fe.name;
            const sig = interp_inst.exportFuncSig(name) orelse continue;
            if (sig.params.len != 0 or sig.results.len != 1) continue;
            // Single scalar result of any number type. f32/f64 EXECUTION is a prime
            // interp-vs-JIT divergence source (rounding, NaN); the carrier-bit
            // compare is sound under canonicalize-nans. v128/ref results excluded
            // (the JIT invoke runs them via the uncompared void path).
            switch (std.meta.activeTag(sig.results[0])) {
                .i32, .i64, .f32, .f64 => {},
                else => continue,
            }

            interp_inst.setFuel(FUEL);
            jit.owned.rt.fuel_cell = std.math.cast(i64, FUEL) orelse std.math.maxInt(i64);
            jit.owned.rt.fuel_metered = 1;
            // Reset the shared trap-kind slot so a trap on THIS invoke can't read
            // a stale code from a prior export; raw 0 → `jitTrapCode` null (lenient).
            jit.owned.rt.trap_kind = 0;

            const io_out = interpInvoke(&interp_inst, name);
            const jo_out = jitInvoke(&jit, gpa, name);
            if (io_out == .fuel or jo_out == .fuel) continue; // not comparable
            funcs_compared += 1;

            const ok = switch (io_out) {
                // Both trap: OK iff the kinds match, OR either side is incomparable
                // (interp host bucket / JIT generic bucket) → lenient both-trap-OK.
                .trap => |ik| switch (jo_out) {
                    .trap => |jk| ik == null or jk == null or ik.? == jk.?,
                    else => false,
                },
                .value => |iv| jo_out == .value and jo_out.value == iv,
                .fuel => unreachable,
            };
            if (!ok) {
                mismatched += 1;
                try stdout.print("MISMATCH  {s} / {s}: interp={s} jit={s}\n", .{
                    entry.name, name, @tagName(io_out), @tagName(jo_out),
                });
                if (io_out == .value and jo_out == .value) {
                    try stdout.print("          interp=0x{x} jit=0x{x}\n", .{ io_out.value, jo_out.value });
                } else if (io_out == .trap and jo_out == .trap) {
                    try stdout.print("          interp-kind={s} jit-kind={s}\n", .{
                        kindName(io_out.trap), kindName(jo_out.trap),
                    });
                }
            }
        }
    }

    try stdout.print(
        "\nfuzz_exec: {d} processed, {d} modules compared, {d} funcs compared, {d} mismatched (interp-vs-JIT) — GATING\n",
        .{ processed, modules_compared, funcs_compared, mismatched },
    );
    try stdout.flush();

    if (processed == 0) {
        try stdout.print("error: empty corpus '{s}'\n", .{corpus_dir});
        try stdout.flush();
        std.process.exit(1);
    }
    // GATING: a value/trap divergence between the interp and the JIT on the same
    // function is a real bug (a JIT-execute miscompile). The campaign run validated
    // the comparison (122 funcs, 0 mismatch), so any future mismatch is a finding.
    if (mismatched != 0) std.process.exit(1);
}
