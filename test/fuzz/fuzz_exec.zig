//! Interp-vs-JIT EXECUTION differential fuzzer (D-469).
//!
//! Walks a corpus of `wasm-tools smith` modules and, for each one that BOTH
//! engines instantiate, invokes every 0-param / single-{i32,i64}-result export
//! under the interp (`Instance.invoke`) AND the JIT (`JitInstance.invoke`) with
//! a deterministic fuel budget, then compares the outcomes. A divergence —
//! interp returns a value the JIT doesn't (or vice versa), or the two return
//! DIFFERENT values — is a finding (the D-330/D-331A/D-468 class of JIT-execute
//! miscompiles, which the spec/realworld corpora may not reach). A process-level
//! CRASH (panic / unreachable / SEGV) is likewise a finding (external detection:
//! the process dies, the runner sees the signal exit).
//!
//! Why FOCUSED (0-param, 1 scalar result): it sidesteps argument generation and
//! the multi-result / v128 / ref-result marshalling mismatch between the two
//! invoke ABIs (interp `[]Value`; JIT `[]u64 → ?u64`), while still exercising the
//! full function body under both engines.
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

const FUEL: u64 = 200_000;
const OUT_OF_FUEL_KIND: u32 = 17; // jit raw trap_kind for out_of_fuel

const Outcome = union(enum) {
    value: u64, // normalised result bits (i32 zero-extended into the low 32)
    trap, // a non-fuel trap
    fuel, // out_of_fuel — not comparable across engines
};

fn interpInvoke(inst: *zwasm.Instance, name: []const u8, is_i64: bool) Outcome {
    var results: [1]zwasm.Value = undefined;
    inst.invoke(name, &.{}, results[0..1]) catch |err| {
        if (err == error.OutOfFuel) return .fuel;
        return .trap;
    };
    return .{ .value = if (is_i64)
        @bitCast(results[0].i64)
    else
        @as(u64, @as(u32, @bitCast(results[0].i32))) };
}

fn jitInvoke(jit: *engine_runner.JitInstance, gpa: std.mem.Allocator, name: []const u8, is_i64: bool) Outcome {
    const r = jit.invoke(gpa, name, &.{}) catch {
        if (jit.owned.rt.trap_kind == OUT_OF_FUEL_KIND) return .fuel;
        return .trap;
    };
    const raw = r orelse 0;
    return .{ .value = if (is_i64) raw else @as(u64, @as(u32, @truncate(raw))) };
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
            const tag = std.meta.activeTag(sig.results[0]);
            const is_i64 = tag == .i64;
            if (tag != .i32 and !is_i64) continue;

            interp_inst.setFuel(FUEL);
            jit.owned.rt.fuel_cell = std.math.cast(i64, FUEL) orelse std.math.maxInt(i64);
            jit.owned.rt.fuel_metered = 1;

            const io_out = interpInvoke(&interp_inst, name, is_i64);
            const jo_out = jitInvoke(&jit, gpa, name, is_i64);
            if (io_out == .fuel or jo_out == .fuel) continue; // not comparable
            funcs_compared += 1;

            const ok = switch (io_out) {
                .trap => jo_out == .trap,
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
