//! Steady-state per-call latency: instantiate once, call many times.
//!
//! Every other bench in `bench/` goes through `hyperfine` on a whole process
//! (spawn + instantiate + execute), which is one guest invocation per process.
//! A cost paid on *every* call is therefore paid once there and disappears into
//! process startup. This runner measures the other shape: load once, call
//! repeatedly, so per-call costs are visible at all.
//!
//! This is an instrument, not a new performance goal. ROADMAP §2 P3 keeps
//! cold-start as the primary metric and nothing here changes that. What it
//! exists for is D-584 and D-585, two per-call costs whose recorded numbers
//! measurement contradicts and which no committed harness can check.
//!
//! Compile and instantiate sit outside the timed region deliberately. Folding
//! them in would answer the cold-start question, which
//! `scripts/bench_aot_coldstart.sh` already owns.
//!
//! Output is one YAML fragment on stdout, in the shape
//! `bench/results/latency_history.yaml` appends (ADR-0209 D2). Nanoseconds, not
//! the `mean_ms` of `history.yaml`: a 10 ns call has no significant digits left
//! in milliseconds.

const std = @import("std");
const zwasm = @import("zwasm");
const build_options = @import("build_options");

const guest = @embedFile("percall_loop.wasm");

/// Wasm instructions executed per loop TRIP, counted from the `.wat`:
/// `local.get` x5, `i32.ge_s`, `br_if`, `i32.add` x2, `local.set` x2,
/// `i32.const`, `br`.
///
/// `wasm_insns` in the output is `trips * insns_per_trip`, so the zero-trip row
/// records 0 while the guest still runs the loop-header compare, its `br_if`,
/// and the trailing `local.get`. That row is there to expose a per-call
/// constant, not to be divided into.
const insns_per_trip = 13;

/// Trip counts to record. Deliberately short: this is a regression guard run by
/// hand at merge time, not the full sweep an investigation would use. (The gate
/// only COMPILES this file — ADR-0209 D3 keeps the measurement out of CI.) The
/// small sizes are where a per-call constant is visible; the large one keeps
/// an eye on the engine itself.
const trips = [_]i32{ 0, 16, 512 };

/// `zwasm.EngineKind` directly rather than a local mirror of it. `.auto` is
/// never passed: it resolves to one of the two and recording it would obscure
/// which one produced the number.
const EngineKind = @TypeOf(@as(zwasm.Module.InstantiateOpts, undefined).engine);

fn callsFor(n: i32) u32 {
    return if (n <= 16) 20_000 else 2_000;
}

/// Per-call nanoseconds over 5 timed repetitions of `calls` invocations each.
///
/// Returns the spread, not just the middle. The median is what to read, since
/// one scheduler hiccup cannot move it; `min` and `max` are what tell a reader
/// whether the median means anything — within this process. They cannot flag a
/// run that was uniformly slow, e.g. one scheduled onto an efficiency core,
/// because then all five samples agree with each other and the spread stays
/// narrow. Cross-run comparison is the only guard against that. Recording only the median would hide a
/// run whose five samples disagreed wildly, and ADR-0209 D3 deliberately has no
/// threshold gate — a human reads these, and a human needs the spread to read
/// them. `history.yaml` carries `stddev_ms` / `min_ms` / `max_ms` next to
/// `mean_ms` for the same reason.
/// The `ctx: anytype` + `once()` shape costs nothing worth accounting for: an
/// empty `once()` measures 0.000 ns (the optimizer removes the loop outright)
/// and a `doNotOptimizeAway`-only body measures 0.276 ns, against 423 ns for
/// the cheapest real lane. That is 0.065% of the smallest thing recorded here.
const Spread = struct { median: f64, min: f64, max: f64 };

fn measure(io: std.Io, calls: u32, ctx: anytype) Spread {
    // 1000 is generous rather than tuned. `Engine.compile` compiles the whole
    // module up front, so there is no lazy per-call compilation to pay off;
    // what warms is icache and page-in. Sweeping the warm-up over
    // 0 / 1 / 10 / 100 / 1000 / 10000 at 512 trips moved the result by 6.6% on
    // the JIT and 2.5% on the interpreter, non-monotonically, which is noise
    // inside the ~7% machine-state drift rather than a warm-up effect: the
    // steady value is reached after a single call.
    var warm: u32 = 0;
    while (warm < @min(1000, calls)) : (warm += 1) ctx.once();

    var samples: [5]f64 = undefined;
    for (&samples) |*s| {
        const t0 = std.Io.Clock.awake.now(io).nanoseconds;
        var k: u32 = 0;
        while (k < calls) : (k += 1) ctx.once();
        const t1 = std.Io.Clock.awake.now(io).nanoseconds;
        s.* = @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(calls));
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    return .{ .median = samples[2], .min = samples[0], .max = samples[4] };
}

fn engineNs(io: std.Io, gpa: std.mem.Allocator, engine: EngineKind, n: i32) !Spread {
    var eng = try zwasm.Engine.init(gpa, .{});
    defer eng.deinit();
    var mod = try eng.compile(guest);
    defer mod.deinit();
    var inst = try mod.instantiate(.{
        // Unmetered: fuel accounting is per-instruction work that would land on
        // the interpreter's side of the comparison and not the JIT's.
        .fuel = .unmetered,
        .engine = engine,
    });
    defer inst.deinit();
    const work = inst.typedFunc(fn (i32) i32, "work");

    const Ctx = struct {
        work: @TypeOf(work),
        n: i32,
        fn once(c: @This()) void {
            // `@panic` rather than `unreachable`: the current guest has no
            // memory, table, division or call_indirect, so it cannot trap, but
            // `unreachable` is UB in ReleaseFast the moment that stops being
            // true. A bench that hits UB reports numbers instead of failing.
            std.mem.doNotOptimizeAway(c.work.call(.{c.n}) catch @panic("guest trapped; the bench guest must not trap"));
        }
    };
    return measure(io, callsFor(n), Ctx{ .work = work, .n = n });
}

/// The stack-limit query the JIT entry helpers run on every invocation
/// (`engine/codegen/shared/entry.zig`). Recorded on its own because it is a
/// per-platform constant that dominates the JIT column on Linux/glibc main
/// threads and is nearly free elsewhere (D-584). Recording it separately means
/// a regression in it can be told apart from a regression in the engine.
fn stackLimitNs(io: std.Io) Spread {
    const Ctx = struct {
        fn once(_: @This()) void {
            const sl = zwasm.platform.stack_limit;
            std.mem.doNotOptimizeAway(sl.computeStackLimit(sl.STACK_GUARD_HEADROOM));
        }
    };
    return measure(io, 20_000, Ctx{});
}

/// Guard against timing the wrong thing. Both engines must return the same
/// value for the same input; a lane that silently ran a different function
/// would still produce plausible nanoseconds.
fn verify(gpa: std.mem.Allocator) !void {
    const probe: i32 = 1000;
    const expected: i32 = probe * (probe - 1) / 2;
    inline for (.{ .interp, .jit }) |kind| {
        var eng = try zwasm.Engine.init(gpa, .{});
        defer eng.deinit();
        var mod = try eng.compile(guest);
        defer mod.deinit();
        var inst = try mod.instantiate(.{ .fuel = .unmetered, .engine = kind });
        defer inst.deinit();
        const got = try inst.typedFunc(fn (i32) i32, "work").call(.{probe});
        if (got != expected) return error.EngineDisagrees;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const builtin = @import("builtin");

    var buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &w.interface;

    try verify(gpa);

    // `darwin` rather than Zig's `macos` tag: `history.yaml` has recorded
    // `aarch64-darwin` since the bench harness existed, and two series that
    // cannot be joined on arch are two series nobody will compare.
    const os_name = if (builtin.os.tag == .macos) "darwin" else @tagName(builtin.os.tag);
    try out.print("  arch: {s}-{s}\n", .{ @tagName(builtin.cpu.arch), os_name });
    // The ENGINE's mode, not this program's. `build.zig` floors the engine
    // module at ReleaseSafe when the caller asks for Debug (`runner_optimize`),
    // so `builtin.mode` here would record `Debug` for numbers that ReleaseSafe
    // engine code produced — a row stating conditions that never held.
    try out.print("  engine_build_mode: {s}\n", .{@tagName(build_options.runner_engine_optimize)});
    try out.print("  runner_build_mode: {s}\n", .{@tagName(builtin.mode)});
    try out.print("  samples: 5\n", .{});
    const sl = stackLimitNs(io);
    try out.print("  stack_limit_query_ns: {d:.1}\n", .{sl.median});
    try out.print("  stack_limit_query_ns_min: {d:.1}\n", .{sl.min});
    try out.print("  stack_limit_query_ns_max: {d:.1}\n", .{sl.max});
    try out.print("  calls:\n", .{});
    for (trips) |n| {
        const i = try engineNs(io, gpa, .interp, n);
        const j = try engineNs(io, gpa, .jit, n);
        try out.print("    - trips: {d}\n", .{n});
        try out.print("      wasm_insns: {d}\n", .{@as(i64, n) * insns_per_trip});
        try out.print("      interp_ns: {d:.1}\n", .{i.median});
        try out.print("      interp_ns_min: {d:.1}\n", .{i.min});
        try out.print("      interp_ns_max: {d:.1}\n", .{i.max});
        try out.print("      jit_ns: {d:.1}\n", .{j.median});
        try out.print("      jit_ns_min: {d:.1}\n", .{j.min});
        try out.print("      jit_ns_max: {d:.1}\n", .{j.max});
        try out.print("      jit_over_interp: {d:.3}\n", .{j.median / i.median});
    }
    try out.flush();
}
