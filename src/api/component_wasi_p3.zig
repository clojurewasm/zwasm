//! WASI **Preview 3** / Component-Model async runner (D-335 unit D-ηB,
//! ADR-0188). Drives an async-lifted component export through the stackless
//! callback ABI: instantiate (reusing the P2 general engine — async is a
//! property of the *export*, not instantiation), invoke the async task entry
//! once, then run `async.zig:driveCallbackLoop` re-entering the guest
//! `callback` per delivered event until EXIT. Coexists with the P2 runner; it
//! does NOT replace it. Zone 3 (touches `invoke`).
//!
//! The hard loop logic + the async data model live in `feature/component/
//! async.zig` (Zone 1, ADR-0187); this is the thin engine-wiring layer.

const std = @import("std");

const async_mod = @import("../feature/component/async.zig");
const wasi_host = @import("../wasi/host.zig");
const wasi_p2 = @import("component_wasi_p2.zig");

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Value = @import("../zwasm.zig").Value;

/// The concrete ctx `driveCallbackLoop` is generic over (ADR-0188): installs the
/// two engine seams against a live `Instance` + the per-task async tables.
const P3CallbackCtx = struct {
    inst: *Instance,
    callback_name: []const u8,
    /// The per-task host ctx (owns the stream/set tables + host source/sink
    /// state + the parked-read delivery, ADR-0191).
    wp2: *wasi_p2.WasiP2Ctx,

    /// Re-enter the guest `callback(event_code, p1, p2) -> i32` and return its
    /// packed `CallbackResult` bits.
    pub fn invokeCallback(self: *P3CallbackCtx, event_code: u32, p1: u32, p2: u32) !u32 {
        var args = [_]Value{
            .{ .i32 = @bitCast(event_code) },
            .{ .i32 = @bitCast(p1) },
            .{ .i32 = @bitCast(p2) },
        };
        var results = [_]Value{.{ .i32 = 0 }};
        try self.inst.invoke(self.callback_name, &args, &results);
        return @bitCast(results[0].i32);
    }

    /// The WAIT seam — deliver an event from the named waitable set. First the
    /// host delivers any parked host-source reads (ADR-0191 E2c: the synchronous
    /// "make progress" hook), then poll. An empty poll with no deliverable work
    /// is a single-task deadlock: trap (`error.AsyncDeadlock`), never a silent
    /// NONE (`no_workaround.md`).
    pub fn waitOn(self: *P3CallbackCtx, set_index: u32) !async_mod.EventTuple {
        const set = try self.wp2.sets.get(set_index);
        try self.wp2.deliverParkedReads(set);
        return (try set.poll(&self.wp2.streams)) orelse error.AsyncDeadlock;
    }
};

/// Run the first async-lifted export of `bytes` to completion through the
/// stackless callback loop. Mirrors `runWasiP2Main` for the sync case.
pub fn runWasiP3Main(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!void {
    var built = try wasi_p2.buildWasiP2Component(engine, alloc, bytes, host, opts);
    defer built.deinit();
    try driveAsyncMain(&built);
}

/// The unified WASI-component entry (D-335 Unit F): build once, then dispatch —
/// an **async-lifted** export (a `canon lift` with `opts.is_async`) goes through
/// the P3 stackless callback loop, else the sync `wasi:cli/run` path. This is
/// the surface the CLI / embedders call so an async P3 component "just runs".
pub fn runWasiMain(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!void {
    var built = try wasi_p2.buildWasiP2Component(engine, alloc, bytes, host, opts);
    defer built.deinit();
    for (built.info.canons.items) |c| {
        if (c == .lift and c.lift.opts.is_async) return driveAsyncMain(&built);
    }
    return wasi_p2.runWasiP2MainBuilt(&built);
}

/// Drive the first async-lifted export of an already-built component through the
/// stackless callback loop. Split from `runWasiP3Main` so tests (and embedders)
/// can inspect the result the guest delivered via `task.return`
/// (`built.ctx.task_return`, ADR-0189 ζ2) after the loop exits.
pub fn driveAsyncMain(built: *wasi_p2.BuiltComponent) anyerror!void {
    // async is an export property (ADR-0188): the first `canon lift` with
    // `opts.is_async` is the task to drive; its `callback` is the loop re-entry.
    const lift = blk: {
        for (built.info.canons.items) |c| {
            if (c == .lift and c.lift.opts.is_async) break :blk c.lift;
        }
        return error.NoAsyncExport;
    };
    const callback_idx = lift.opts.callback orelse return error.NoAsyncCallback;

    const entry_ref = built.info.resolveCoreFuncExport(lift.core_func) orelse return error.NoRunExport;
    const cb_ref = built.info.resolveCoreFuncExport(callback_idx) orelse return error.NoAsyncCallback;
    const inst = built.guestInstance(entry_ref.instance) orelse return error.NoRunExport;

    // The async tables + host source/sink state live in the component ctx
    // (ADR-0189 ζ2 / ADR-0191 E2c) so the canon builtin trampolines (bound at
    // instantiation), the parked-read delivery, and the loop share them.
    var ctx = P3CallbackCtx{ .inst = inst, .callback_name = cb_ref.name, .wp2 = built.ctx };

    // Invoke the async task entry once; its packed i32 return seeds the loop.
    var results = [_]Value{.{ .i32 = 0 }};
    inst.invoke(entry_ref.name, &.{}, &results) catch |err| {
        if (err == error.ProcExit) return; // wasi:cli/exit clean unwind
        return err;
    };
    const initial: u32 = @bitCast(results[0].i32);
    try async_mod.driveCallbackLoop(&ctx, initial);
}

const testing = std.testing;

test "D-335 unit D-ηB: an async-lifted export that returns EXIT runs end-to-end through the P3 runner" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_exit_immediate.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The core task entry returns 0 (EXIT) immediately → the loop terminates
    // without re-entering the callback. No trap, no deadlock.
    try runWasiP3Main(&eng, testing.allocator, bytes, &host, .{});
}

test "D-335 unit D-ηB: a YIELD task entry re-enters the guest callback end-to-end (EXIT after one)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_yield_then_exit.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // run returns YIELD(1) → the loop MUST invoke the guest callback (proving
    // the invokeCallback seam reaches a real Instance); callback returns EXIT(0)
    // → clean termination after exactly one re-entry. A miswired callback would
    // spin forever on YIELD.
    try runWasiP3Main(&eng, testing.allocator, bytes, &host, .{});
}

test "D-335 unit D-ζ2: canon task.return delivers the async task result to the host" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_task_return.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The core entry calls task.return(42) then returns EXIT. Build + drive
    // directly (not runWasiP3Main) so we can inspect the delivered result.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    try testing.expectEqual(@as(?u32, 42), built.ctx.task_return);
}

test "D-335 unit D-ζ2: canon stream.new mints a stream end pair via the host builtin" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stream_new.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The core entry calls stream.new (was UnsupportedWasiImport pre-ζ2) then
    // EXITs. After the run, the ctx stream table holds the minted readable +
    // writable ends (handles 1 and 2).
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    _ = try built.ctx.streams.get(1); // readable end minted
    _ = try built.ctx.streams.get(2); // writable end minted
}

test "D-335 unit D-ζ2: canon stream.drop-{readable,writable} tear down both ends + free the shared" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stream_drop.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The core entry mints a stream then drops both ends. After the run, both
    // end handles are tombstoned (a re-get traps) — the shared was freed at the
    // 2nd drop (no leak; the table's deinit would catch a stuck slot).
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    try testing.expectError(async_mod.Error.InvalidHandle, built.ctx.streams.get(1));
    try testing.expectError(async_mod.Error.InvalidHandle, built.ctx.streams.get(2));
}

test "D-335 unit D-ζ2: stream.read with no writer returns BLOCKED (single-task)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stream_read_blocked.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The guest reads a fresh stream with no writer and traps (unreachable) if
    // the read did not return BLOCKED — so a clean run proves the BLOCKED path.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
}

test "D-335 unit D-ζ2: stream.read after the writer drops returns DROPPED (single-task)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stream_read_dropped.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The guest drops the writable end then reads the readable end; it traps
    // unless the read reports DROPPED — a clean run proves the dropped-peer path.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
}

test "D-335 unit D-ζ2: future.read with no writer returns BLOCKED (single-task)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_future_read_blocked.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // Future analogue of the stream BLOCKED test: exercises the SharedFuture
    // rendezvous (the `.future` arm of end.copy), not the SharedStream path.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
}

test "D-335 / D-337: future.drop-writable before any write traps (CanonicalABI §Future State)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_future_drop_before_write.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // Unlike a stream, a future's readable end never observes DROPPED and its
    // writable end cannot be dropped pre-write — the drop itself traps.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    // The drop traps (canonical guest trap); a clean run would mean the guard
    // is missing and the guest reached its EXIT.
    try testing.expectError(error.Unreachable, driveAsyncMain(&built));
}

test "D-335 / D-445: stream.read with a never-minted handle traps (not host panic)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_bad_handle_read.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // A guest-supplied bad handle is a guest fault: it must surface as a guest
    // trap, not abort the host via mapDispatchErr's else=>@panic (D-445).
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try testing.expectError(error.Unreachable, driveAsyncMain(&built));
}

test "D-335 / D-445: stream.cancel-read with no copy in flight traps (not host panic)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_cancel_no_copy.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // Cancelling an idle end (NotCopying) is illegal op sequencing → guest trap.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try testing.expectError(error.Unreachable, driveAsyncMain(&built));
}

test "D-335 / D-445: waitable.join on a never-minted set handle traps (not host panic)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_bad_set_join.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // A guest-supplied bad set handle is a guest fault → guest trap, not a host panic.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try testing.expectError(error.Unreachable, driveAsyncMain(&built));
}

test "D-335 unit D-ζ2: stream.cancel-read cancels a parked read (single-task)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stream_cancel.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The guest reads (BLOCKED → parks async-copying) then cancel-reads; it
    // traps unless cancel reports CANCELLED count 0 — a clean run proves it.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
}

test "D-335 unit E1: wasi:cli/stdout write-via-stream — a guest stream.write COMPLETES to the host sink" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stdout_write_via_stream.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // The guest hands a stream's readable end to stdout.write-via-stream (host
    // becomes the always-ready reader = fd 1 sink), writes "hi\n" → the write
    // COMPLETES and the bytes are marshalled to the host sink. First guest
    // stream.write COMPLETION + element marshalling e2e.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    try testing.expectEqualStrings("hi\n", capture.items);
}

test "D-335 unit E1: wasi:cli/stderr write-via-stream routes a guest stream.write to fd 2" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stderr_write_via_stream.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var cap_err: std.ArrayList(u8) = .empty;
    defer cap_err.deinit(testing.allocator);
    var cap_out: std.ArrayList(u8) = .empty;
    defer cap_out.deinit(testing.allocator);
    host.stderr_buffer = &cap_err;
    host.stdout_buffer = &cap_out;

    // The stderr host sink (fd 2) captures the bytes; stdout stays empty —
    // proving the write-via-stream fd routing is per-interface.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    try testing.expectEqualStrings("er\n", cap_err.items);
    try testing.expectEqualStrings("", cap_out.items);
}

test "D-335 unit E3: wasi:cli/stdin read-via-stream — a guest stream.read COMPLETES from the host source" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stdin_read_via_stream.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.stdin_bytes = "ok"; // the host stream source

    // The guest read-via-streams, reads the host source, and traps unless it
    // sees COMPLETED(2) + bytes "ok" — a clean run proves the read-direction
    // COMPLETION + host→guest element marshalling.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
}

test "D-335 unit E2b: waitable-set.new + waitable.join build a set holding the joined waitable" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_waitable_set.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The guest mints a stream (readable end handle 1) + a set (handle 1) and
    // joins the readable end. After the run, the set holds that member.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    const set = try built.ctx.sets.get(1);
    try testing.expectEqualSlices(u32, &.{1}, set.elems.items);
}

test "D-335 unit E2c: the WAIT path — a parked read → WAIT(set) → host delivers → callback re-entry" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_wait_path.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.stdin_bytes = "ok"; // the host source delivers these at waitOn

    // Force the host-source read to PARK (ADR-0191 E2c): the guest's read blocks,
    // it returns WAIT(set), the runner's waitOn delivers "ok" → STREAM_READ →
    // re-enters the guest callback (which asserts the bytes) → EXIT. A clean run
    // proves the real driveCallbackLoop WAIT branch end-to-end.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    built.ctx.defer_host_source_reads = true;
    try driveAsyncMain(&built);
}

test "D-335 unit E: write-via-stream's result future resolves to ok (future.read)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_future_result.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // Guest writes "hi" then future.reads the returned result future; it traps
    // unless the read reports COMPLETED(1) + ok (0) — a clean run proves the
    // host result future resolves.
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    try testing.expectEqualStrings("hi", capture.items);
}
