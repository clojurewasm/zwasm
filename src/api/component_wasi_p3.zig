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
    streams: *async_mod.StreamFutureTable,
    sets: *async_mod.WaitableSetTable,

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

    /// The WAIT seam — deliver an event from the named waitable set. With no
    /// cross-task scheduler yet, an empty poll is a single-task deadlock: trap
    /// (`error.AsyncDeadlock`), never a silent NONE (`no_workaround.md`). Real
    /// blocking arrives with the ζ2 / Unit-E host concurrency.
    pub fn waitOn(self: *P3CallbackCtx, set_index: u32) !async_mod.EventTuple {
        const set = try self.sets.get(set_index);
        return (try set.poll(self.streams)) orelse error.AsyncDeadlock;
    }
};

/// Run the first async-lifted export of `bytes` to completion through the
/// stackless callback loop. Mirrors `runWasiP2Main` for the sync case.
pub fn runWasiP3Main(engine: *Engine, alloc: Allocator, bytes: []const u8, host: *wasi_host.Host, opts: Module.InstantiateOpts) anyerror!void {
    var built = try wasi_p2.buildWasiP2Component(engine, alloc, bytes, host, opts);
    defer built.deinit();
    try driveAsyncMain(&built);
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

    // The async tables live in the component ctx (ADR-0189 ζ2) so the canon
    // builtin trampolines (bound at instantiation) and the loop share them.
    var ctx = P3CallbackCtx{ .inst = inst, .callback_name = cb_ref.name, .streams = &built.ctx.streams, .sets = &built.ctx.sets };

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
