//! WASI **Preview 3** / Component-Model async runner (D-335 unit D-ηB,
//! ADR-0188). Drives an async-lifted component export through the stackless
//! callback ABI: instantiate (reusing the P2 general engine — async is a
//! property of the *export*, not instantiation), invoke the async task entry
//! once, then run `async.zig:driveScheduler` over a 1-entry `TaskTable`
//! (ADR-0195) re-entering the guest `callback` per delivered event until EXIT.
//! Coexists with the P2 runner; it does NOT replace it. Zone 3 (touches `invoke`).
//!
//! The hard loop logic + the async data model live in `feature/component/
//! async.zig` (Zone 1, ADR-0187); this is the thin engine-wiring layer.

const std = @import("std");

const async_mod = @import("../feature/component/async.zig");
const net = std.Io.net;
const wasi_host = @import("../wasi/host.zig");
const wasi_p2 = @import("component_wasi_p2.zig");

const Allocator = std.mem.Allocator;
const Engine = @import("../zwasm/engine.zig").Engine;
const Module = @import("../zwasm/module.zig").Module;
const Instance = @import("../zwasm/instance.zig").Instance;
const Value = @import("../zwasm.zig").Value;

/// The concrete ctx `driveScheduler` is generic over (ADR-0188/0195): installs
/// the engine seams against a live `Instance` + the per-task async tables.
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

    /// Multi-task seam (ADR-0195 step c): re-enter a specific task's callback.
    /// The single-component runner has exactly ONE callback (`callback_name`), so
    /// `funcidx` is ignored here; the cross-component graph runner (c-2b)
    /// dispatches by funcidx across instances.
    pub fn invokeTaskCallback(self: *P3CallbackCtx, funcidx: u32, event_code: u32, p1: u32, p2: u32) !u32 {
        _ = funcidx;
        return self.invokeCallback(event_code, p1, p2);
    }

    /// Non-blocking WAIT seam for `driveScheduler` (ADR-0195 step c): deliver any
    /// parked host-source reads (the synchronous "make progress" hook, ADR-0191
    /// E2c) + fire due timers (ADR-0205 D2), then poll. Returns null when no
    /// event is deliverable — the scheduler decides deadlock across ALL tasks
    /// (vs single-task `waitOn`, which traps directly because its one task IS
    /// the whole program).
    pub fn pollSet(self: *P3CallbackCtx, set_index: u32) !?async_mod.EventTuple {
        const set = try self.wp2.sets.get(set_index);
        try self.wp2.deliverParkedReads(set);
        _ = try self.wp2.fireDueTimers();
        _ = try self.wp2.pollBlockedSockets();
        _ = try self.wp2.pollBlockedUdpReceives();
        return try set.poll(&self.wp2.streams);
    }

    /// The no-progress seam (ADR-0205 D2): a pass delivered nothing — if a
    /// timer subtask is still armed, sleep until the nearest deadline and fire
    /// it (true = the scheduler retries); no armed timer = genuine deadlock.
    pub fn waitForTimer(self: *P3CallbackCtx) !bool {
        // A ready socket is immediate progress — retry without sleeping.
        if (try self.wp2.pollBlockedSockets()) return true;
        if (try self.wp2.pollBlockedUdpReceives()) return true;
        // External-actor seam (official sockets-echo): let the harness act
        // as the remote client while the guest is parked.
        if (self.wp2.external_sock_step) |hook| {
            if (hook(self.wp2.external_sock_ctx.?)) return true;
        }
        // Otherwise, if socket reads are still pending, briefly sleep and
        // retry (poll(2) has no scheduler-integrated wakeup here).
        if (self.wp2.blocked_socket_reads.count() > 0 or self.wp2.blocked_udp_receives.count() > 0) {
            const io = self.wp2.host.io orelse return error.NoHostIo;
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(std.time.ns_per_ms), .awake) catch |err| switch (err) {
                error.Canceled => {},
            };
            return true;
        }
        const nearest = (try self.wp2.fireDueTimers()) orelse return false;
        const now = try self.wp2.monotonicNowNs();
        if (nearest > now) {
            const io = self.wp2.host.io orelse return error.NoHostIo;
            std.Io.sleep(io, std.Io.Duration.fromNanoseconds(@intCast(nearest - now)), .awake) catch |err| switch (err) {
                error.Canceled => {}, // an early wake just re-polls
            };
        }
        _ = try self.wp2.fireDueTimers();
        return true;
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
    // Drive via the round-robin scheduler over a 1-entry TaskTable (ADR-0195
    // step c): single-task = the byte-identical 1-entry case (pollSet-returns-null
    // ≡ the old waitOn-traps-AsyncDeadlock for one task). The cross-component
    // graph runner (c-2b) seeds N tasks into the same table.
    var tasks = try async_mod.TaskTable.init(built.ctx.alloc);
    defer tasks.deinit();
    var seed = try async_mod.seedTask(initial);
    seed.callback_funcidx = callback_idx;
    _ = try tasks.add(seed);
    try async_mod.driveScheduler(&ctx, &tasks);
    // Spec (CanonicalABI.md `task.return`; wasmtime task-return-traps.wast): an
    // async-lifted export that declares a result MUST deliver it via task.return
    // before exiting — otherwise it "failed to produce a result" → guest trap.
    if (built.ctx.task_return == null and asyncExportExpectsResult(built, lift.type_index))
        return error.Unreachable;
    // `run: async func() -> result` — an `err` task.return (discriminant 1) is
    // exit code 1 per the wasi:cli command contract (official run-with-err.wasm).
    if (built.ctx.task_return) |tr| {
        if (tr != 0 and built.ctx.host.exit_code == null) built.ctx.host.exit_code = 1;
    }
}

/// True if the async-lifted export (component func type at `type_index`) declares
/// a result valtype — gating the task.return-was-called check above.
fn asyncExportExpectsResult(built: *wasi_p2.BuiltComponent, type_index: u32) bool {
    const info = &built.info;
    if (type_index >= info.type_space.items.len) return false;
    return switch (info.type_space.items[type_index]) {
        .def => |d| switch (info.deftypes.items[d]) {
            .func => |ft| ft.result != null,
            else => false,
        },
        .named => false,
    };
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

test "D-335 front②: an async export with a result that EXITs without task.return traps (task-return-traps.wast)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_no_task_return_trap.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // The export's lifted type declares `result u32` but the core entry exits
    // without task.return → the runner traps (failed to produce a result).
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try testing.expectError(error.Unreachable, driveAsyncMain(&built));
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

test "ADR-0195 char: a single task that WAITs on a peerless stream read traps AsyncDeadlock" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_deadlock_single.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // Plain (no host peer) stream read → BLOCKED → WAIT(set); nothing ever
    // writes, so `waitOn` polls an empty set → AsyncDeadlock. Pins the exact
    // behaviour the ADR-0195 multi-task scheduler generalises (all-blocked→trap).
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try testing.expectError(error.AsyncDeadlock, driveAsyncMain(&built));
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

test "D-335 front②: stream.read on a DONE end traps — copy requires IDLE (trap-if-done.wast)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stream_read_after_done_trap.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // 1st read → DROPPED (end → DONE); 2nd read on the DONE end traps (state != IDLE).
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

test "D-335 typed marshalling: a stream<u32>.write of 2 elements transfers 8 bytes (elem_size=4)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stdout_write_via_stream_u32.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // stream<u32>: the guest writes 2 u32 ELEMENTS (0x11223344, 0x55667788);
    // the host sink must receive 2*4 = 8 BYTES (little-endian), NOT 2. This
    // distinguishes the typed-element marshalling (elem_size=4) from the prior
    // u8/count==bytes assumption (which would transfer only 2 bytes).
    var built = try wasi_p2.buildWasiP2Component(&eng, testing.allocator, bytes, &host, .{});
    defer built.deinit();
    try driveAsyncMain(&built);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55 }, capture.items);
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

test "D-335 typed marshalling (READ): a stream<u32>.read of 2 elements consumes 8 host bytes (elem_size=4)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/async_stdin_read_via_stream_u32.wasm", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    // 8 host bytes = two little-endian u32 (0x11223344, 0x55667788). The guest
    // reads 2 ELEMENTS → COMPLETED(2) (not 8) + the bytes land verbatim; a clean
    // run proves the read-path host→guest elem_size=4 marshalling.
    host.stdin_bytes = &.{ 0x44, 0x33, 0x22, 0x11, 0x88, 0x77, 0x66, 0x55 };

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
    // it returns WAIT(set), the runner's pollSet delivers "ok" → STREAM_READ →
    // re-enters the guest callback (which asserts the bytes) → EXIT. A clean run
    // proves the real driveScheduler WAIT branch end-to-end.
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

// ---- WASI 0.3 (wasm32-wasip3) conformance corpus (front ①, real rust components) ----
// Plain-rust wasip3 components built Mac-host-only via the recipe in flake.nix
// `.#gen-wasip3` (regen: scripts/gen_wasip3_fixtures.sh); the committed `.wasm`
// runs on every host through the edge-runner. Each test mirrors a wasi-testsuite
// `.json` expectation (operations: run / wait exit_code).

test "WASI 0.3 conformance (wasip3): cli-exit → exit code 1 (real rust component)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3/cli-exit.wasm", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();

    // std::process::exit(1) → wasi:cli/exit → ProcExit (caught by the runner),
    // host records exit code 1 — matches test/component/wasip3/cli-exit.json.
    try wasi_p2.runWasiMain(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(?u32, 1), host.exit_code);
}

test "WASI 0.3 conformance (wasip3): cli-env reads host env (real rust component)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3/cli-env.wasm", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    try host.setEnvs(&.{"WASI_TEST"}, &.{"ok"});

    // The guest reads `WASI_TEST` via wasi:cli/environment get-environment and
    // exit(0) iff it equals "ok" — proving the host env list is delivered +
    // decoded. NB: wasi:cli/exit only carries result<ok,err> (no numeric code),
    // so the success signal MUST be exit(0)→host exit_code 0, never a non-zero
    // sentinel (any non-zero rust exit collapses to host exit_code 1).
    try wasi_p2.runWasiMain(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(?u32, 0), host.exit_code);
}

test "WASI 0.3 conformance (wasip3): cli-stdout writes to stdout (real rust component)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3/cli-stdout.wasm", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(testing.allocator);
    host.stdout_buffer = &capture;

    // `print!("zwasm-wasip3-ok")` → the host stdout capture holds it.
    try wasi_p2.runWasiMain(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("zwasm-wasip3-ok", capture.items);
}

test "WASI 0.3 conformance (wasip3): cli-stderr writes to stderr (real rust component)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3/cli-stderr.wasm", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    var cap_err: std.ArrayList(u8) = .empty;
    defer cap_err.deinit(testing.allocator);
    host.stderr_buffer = &cap_err;

    try wasi_p2.runWasiMain(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqualStrings("zwasm-wasip3-err", cap_err.items);
}

test "WASI 0.3 conformance (wasip3): cli-args reads argv (real rust component)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3/cli-args.wasm", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    try host.setArgs(&.{ "prog", "hello" });

    // Guest reads argv[1] via get-arguments; success signal is exit(0) (the
    // wasi:cli/exit result<_,_> channel — any non-zero rust exit → host code 1).
    try wasi_p2.runWasiMain(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(?u32, 0), host.exit_code);
}

test "WASI 0.3 conformance (wasip3): cli-stdin reads stdin (real rust component)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3/cli-stdin.wasm", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.stdin_bytes = "hello";

    // Guest reads stdin via wasi:cli/stdin; success (== "hello") = exit(0).
    try wasi_p2.runWasiMain(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(?u32, 0), host.exit_code);
}

test "WASI 0.3 conformance (wasip3): cli-clocks reads wall+monotonic clocks (real rust component)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3/cli-clocks.wasm", testing.allocator, .limited(4 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(testing.allocator);
    defer host.deinit();
    host.io = io; // wasi:clocks reads the real host clock through std.Io

    // Instant::now() (monotonic) + SystemTime::now().duration_since(UNIX_EPOCH)
    // (wall) must succeed → exit(0); proves wasi:clocks is served to the guest.
    try wasi_p2.runWasiMain(&eng, testing.allocator, bytes, &host, .{});
    try testing.expectEqual(@as(?u32, 0), host.exit_code);
}

// ============================================================
// Official wasi-testsuite conformance (ADR-0205 D3)
// ============================================================
// Fixtures = the upstream-BUILT `prod/testsuite-base` wasm32-wasip3 binaries
// (stripped; provenance + pin in scripts/vendor_wasip3_official.sh), driven by
// the official per-test manifests. The in-process runner flattens the
// operation stream: stdin `write` payloads are pre-supplied, stdout/stderr
// `read` payloads become capture assertions, `wait.exit_code` the exit check —
// faithful for every vendored test (none requires mid-run interactivity).

/// The flattened expectation set of one official manifest (absent manifest =
/// upstream default: run with no I/O, expect exit 0).
/// A manifest socket operation (official sockets-echo): the harness plays
/// the remote client. `connect`/`send` run at the scheduler's no-progress
/// seam (the guest is parked waiting for exactly this actor); `recv` runs
/// after the guest completed (the echoed bytes are buffered on our fd).
const SockOp = struct {
    kind: enum { connect, send, recv },
    payload: []const u8 = "",
};

const OfficialExpect = struct {
    env_keys: std.ArrayList([]const u8) = .empty,
    env_vals: std.ArrayList([]const u8) = .empty,
    args: std.ArrayList([]const u8) = .empty,
    stdin: std.ArrayList(u8) = .empty,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    assert_stdout: bool = false,
    assert_stderr: bool = false,
    exit_code: u32 = 0,
    /// Legacy flat-manifest "root": the preopen tree name (copied to a fresh
    /// tmp dir per run — the tests mutate it) mapped as guest "/".
    root: ?[]const u8 = null,
    sock_ops: std.ArrayList(SockOp) = .empty,

    fn deinit(self: *OfficialExpect, alloc: std.mem.Allocator) void {
        self.env_keys.deinit(alloc);
        self.env_vals.deinit(alloc);
        self.args.deinit(alloc);
        self.stdin.deinit(alloc);
        self.stdout.deinit(alloc);
        self.stderr.deinit(alloc);
        self.sock_ops.deinit(alloc);
    }
};

fn parseOfficialManifest(alloc: std.mem.Allocator, parsed: *const std.json.Value, out: *OfficialExpect) !void {
    // Legacy flat form ({"root": ..., "exit_code": ...}) coexists with the
    // operations form upstream (test_case.py LEGACY_CONFIG_KEYS).
    if (parsed.object.get("root")) |r| out.root = r.string;
    if (parsed.object.get("exit_code")) |ec| out.exit_code = @intCast(ec.integer);
    const ops = parsed.object.get("operations") orelse return;
    for (ops.array.items) |op| {
        const ty = op.object.get("type").?.string;
        if (std.mem.eql(u8, ty, "run")) {
            if (op.object.get("env")) |env| {
                var it = env.object.iterator();
                while (it.next()) |e| {
                    try out.env_keys.append(alloc, e.key_ptr.*);
                    try out.env_vals.append(alloc, e.value_ptr.string);
                }
            }
            if (op.object.get("args")) |args| {
                for (args.array.items) |a| try out.args.append(alloc, a.string);
            }
        } else if (std.mem.eql(u8, ty, "write")) {
            // Only stdin is writable from the runner side.
            try out.stdin.appendSlice(alloc, op.object.get("payload").?.string);
        } else if (std.mem.eql(u8, ty, "read")) {
            const id = op.object.get("id").?.string;
            const payload = op.object.get("payload").?.string;
            if (std.mem.eql(u8, id, "stdout")) {
                try out.stdout.appendSlice(alloc, payload);
                out.assert_stdout = true;
            } else if (std.mem.eql(u8, id, "stderr")) {
                try out.stderr.appendSlice(alloc, payload);
                out.assert_stderr = true;
            }
        } else if (std.mem.eql(u8, ty, "wait")) {
            if (op.object.get("exit_code")) |ec| out.exit_code = @intCast(ec.integer);
        } else if (std.mem.eql(u8, ty, "connect")) {
            try out.sock_ops.append(alloc, .{ .kind = .connect });
        } else if (std.mem.eql(u8, ty, "send")) {
            try out.sock_ops.append(alloc, .{ .kind = .send, .payload = op.object.get("payload").?.string });
        } else if (std.mem.eql(u8, ty, "recv")) {
            try out.sock_ops.append(alloc, .{ .kind = .recv, .payload = op.object.get("payload").?.string });
        }
    }
}

/// The harness-side remote client for `SockOp` manifests. `step` is the
/// `external_sock_step` hook: performs the next in-seam op (connect / send)
/// against the address the guest printed to stdout; `recv` ops stop the
/// in-seam phase (verified post-run by the harness).
const ExternalClient = struct {
    io: std.Io,
    stdout: *std.ArrayList(u8),
    ops: []const SockOp,
    next: usize = 0,
    stream: ?net.Stream = null,

    fn step(ctx_ptr: *anyopaque) bool {
        const self: *ExternalClient = @ptrCast(@alignCast(ctx_ptr));
        if (self.next >= self.ops.len) return false;
        switch (self.ops[self.next].kind) {
            .connect => {
                const addr = self.parseAddrLine() orelse return false; // not printed yet
                self.stream = addr.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch return false;
                self.next += 1;
                return true;
            },
            .send => {
                const s = self.stream orelse return false;
                const data = [_][]const u8{self.ops[self.next].payload};
                _ = self.io.vtable.netWrite(self.io.userdata, s.socket.handle, "", &data, 1) catch return false;
                self.next += 1;
                return true;
            },
            .recv => return false, // post-run phase (runOfficialWasip3Test)
        }
    }

    /// Parse the LAST complete stdout line as "a.b.c.d:port" (the echo
    /// guest's Display for its bound v4 address).
    fn parseAddrLine(self: *ExternalClient) ?net.IpAddress {
        const text = self.stdout.items;
        const nl = std.mem.findScalarLast(u8, text, '\n') orelse return null;
        const line_start = if (std.mem.findScalarLast(u8, text[0..nl], '\n')) |p| p + 1 else 0;
        const line = text[line_start..nl];
        const colon = std.mem.findScalarLast(u8, line, ':') orelse return null;
        const port = std.fmt.parseInt(u16, line[colon + 1 ..], 10) catch return null;
        const ip4 = net.Ip4Address.parse(line[0..colon], port) catch return null;
        return .{ .ip4 = ip4 };
    }
};

/// Run one vendored official test end-to-end and assert its manifest.
fn runOfficialWasip3Test(comptime name: []const u8) !void {
    const alloc = testing.allocator;
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3_official/" ++ name ++ ".wasm", alloc, .limited(8 << 20));
    defer alloc.free(bytes);

    var expect: OfficialExpect = .{};
    defer expect.deinit(alloc);
    var manifest_parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (manifest_parsed) |*p| p.deinit();
    if (std.Io.Dir.cwd().readFileAlloc(io, "test/component/wasip3_official/" ++ name ++ ".json", alloc, .limited(1 << 20))) |mb| {
        defer alloc.free(mb);
        manifest_parsed = try std.json.parseFromSlice(std.json.Value, alloc, mb, .{});
        try parseOfficialManifest(alloc, &manifest_parsed.?.value, &expect);
    } else |_| {
        // No manifest = upstream default (run, expect exit 0, no I/O asserts).
    }

    var eng = try Engine.init(alloc, .{});
    defer eng.deinit();
    var host = try wasi_host.Host.init(alloc);
    defer host.deinit();
    host.io = io;

    // "root" preopen: copy the vendored tree into a fresh tmp dir (the guest
    // mutates it) and map it as guest "/" (the upstream wasmtime adapter's
    // `--dir root::/`).
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    if (expect.root) |root_name| {
        const src_path = try std.fmt.allocPrint(alloc, "test/component/wasip3_official/{s}", .{root_name});
        defer alloc.free(src_path);
        var src_dir = try std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true });
        defer src_dir.close(io);
        var it = src_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const data = try src_dir.readFileAlloc(io, entry.name, alloc, .limited(1 << 20));
            defer alloc.free(data);
            try tmp.dir.writeFile(io, .{ .sub_path = entry.name, .data = data });
        }
        _ = try host.addPreopen(tmp.dir.handle, "/");
    }

    // argv[0] = the test's own basename (the upstream runner launches by name).
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, name ++ ".wasm");
    try argv.appendSlice(alloc, expect.args.items);
    try host.setArgs(argv.items);
    if (expect.env_keys.items.len > 0) try host.setEnvs(expect.env_keys.items, expect.env_vals.items);
    host.stdin_bytes = expect.stdin.items;

    var stdout_cap: std.ArrayList(u8) = .empty;
    defer stdout_cap.deinit(alloc);
    var stderr_cap: std.ArrayList(u8) = .empty;
    defer stderr_cap.deinit(alloc);
    host.stdout_buffer = &stdout_cap;
    host.stderr_buffer = &stderr_cap;

    if (expect.sock_ops.items.len > 0) {
        // Socket-operations manifest (sockets-echo): the harness is the
        // remote client. Build first so the external-actor seam can be
        // installed on the component ctx, then drive.
        var built = try wasi_p2.buildWasiP2Component(&eng, alloc, bytes, &host, .{});
        defer built.deinit();
        var client = ExternalClient{ .io = io, .stdout = &stdout_cap, .ops = expect.sock_ops.items };
        defer if (client.stream) |s| s.close(io);
        built.ctx.external_sock_step = ExternalClient.step;
        built.ctx.external_sock_ctx = &client;
        driveAsyncMain(&built) catch |err| {
            std.debug.print("[official {s}] runner error {t}; guest stderr:\n{s}\n", .{ name, err, stderr_cap.items });
            return err;
        };
        // Post-run ops: the echoed bytes (and FIN) are buffered on our fd.
        for (expect.sock_ops.items[client.next..]) |op| {
            try testing.expectEqual(@as(@TypeOf(op.kind), .recv), op.kind);
            const s = client.stream orelse return error.TestUnexpectedResult;
            const buf = try alloc.alloc(u8, op.payload.len);
            defer alloc.free(buf);
            var got: usize = 0;
            while (got < buf.len) {
                var bufs = [_][]u8{buf[got..]};
                const n = try io.vtable.netRead(io.userdata, s.socket.handle, &bufs);
                if (n == 0) break;
                got += n;
            }
            try testing.expectEqualStrings(op.payload, buf[0..got]);
        }
    } else wasi_p2.runWasiMain(&eng, alloc, bytes, &host, .{}) catch |err| {
        // Surface the guest's own report (a rust assert panic lands on
        // stderr) — the raw trap code alone is undebuggable.
        std.debug.print("[official {s}] runner error {t}; guest stderr:\n{s}\n", .{ name, err, stderr_cap.items });
        return err;
    };
    try testing.expectEqual(@as(?u32, expect.exit_code), host.exit_code orelse 0);
    if (expect.assert_stdout) try testing.expectEqualStrings(expect.stdout.items, stdout_cap.items);
    if (expect.assert_stderr) try testing.expectEqualStrings(expect.stderr.items, stderr_cap.items);
}

test "wasip3-official: cli-env" {
    try runOfficialWasip3Test("cli-env");
}
test "wasip3-official: cli-exit" {
    try runOfficialWasip3Test("cli-exit");
}
test "wasip3-official: cli-stdio" {
    try runOfficialWasip3Test("cli-stdio");
}
test "wasip3-official: cli-stdio-roundtrip" {
    try runOfficialWasip3Test("cli-stdio-roundtrip");
}
test "wasip3-official: cli-stdout-flush" {
    try runOfficialWasip3Test("cli-stdout-flush");
}
test "wasip3-official: cli-terminal" {
    try runOfficialWasip3Test("cli-terminal");
}
test "wasip3-official: monotonic-clock (async wait-until/wait-for timers)" {
    try runOfficialWasip3Test("monotonic-clock");
}
test "wasip3-official: multi-clock-wait (20 interleaved wait-until subtasks)" {
    try runOfficialWasip3Test("multi-clock-wait");
}
test "wasip3-official: random (incl. cached insecure-seed)" {
    try runOfficialWasip3Test("random");
}
test "wasip3-official: wall-clock" {
    try runOfficialWasip3Test("wall-clock");
}
test "wasip3-official: run-with-err (exit code 1)" {
    try runOfficialWasip3Test("run-with-err");
}

test "wasip3-official: filesystem-stat" {
    try runOfficialWasip3Test("filesystem-stat");
}
test "wasip3-official: filesystem-io (file via-stream data plane)" {
    try runOfficialWasip3Test("filesystem-io");
}
test "wasip3-official: filesystem-advise" {
    try runOfficialWasip3Test("filesystem-advise");
}
test "wasip3-official: filesystem-dotdot" {
    try runOfficialWasip3Test("filesystem-dotdot");
}
test "wasip3-official: filesystem-flags-and-type" {
    try runOfficialWasip3Test("filesystem-flags-and-type");
}
test "wasip3-official: filesystem-hard-links" {
    try runOfficialWasip3Test("filesystem-hard-links");
}
test "wasip3-official: filesystem-is-same-object" {
    try runOfficialWasip3Test("filesystem-is-same-object");
}
test "wasip3-official: filesystem-metadata-hash" {
    try runOfficialWasip3Test("filesystem-metadata-hash");
}
test "wasip3-official: filesystem-mkdir-rmdir" {
    try runOfficialWasip3Test("filesystem-mkdir-rmdir");
}
test "wasip3-official: filesystem-open-errors" {
    try runOfficialWasip3Test("filesystem-open-errors");
}
test "wasip3-official: filesystem-read-directory" {
    try runOfficialWasip3Test("filesystem-read-directory");
}
test "wasip3-official: filesystem-rename" {
    try runOfficialWasip3Test("filesystem-rename");
}
test "wasip3-official: filesystem-set-size" {
    try runOfficialWasip3Test("filesystem-set-size");
}
test "wasip3-official: filesystem-unlink-errors" {
    try runOfficialWasip3Test("filesystem-unlink-errors");
}

test "wasip3-official: sockets-tcp-properties (TCP option store)" {
    try runOfficialWasip3Test("sockets-tcp-properties");
}
test "wasip3-official: sockets-udp-properties (UDP option store)" {
    try runOfficialWasip3Test("sockets-udp-properties");
}
test "wasip3-official: sockets-udp-bind (bind + address validation)" {
    try runOfficialWasip3Test("sockets-udp-bind");
}
test "wasip3-official: sockets-tcp-bind (REUSEADDR + addrinuse contracts)" {
    try runOfficialWasip3Test("sockets-tcp-bind");
}
test "wasip3-official: sockets-tcp-connect (incl. explicit-bind connect)" {
    // Windows: connect-from-an-explicitly-bound socket is not-supported —
    // the raw posix bound-connect composition (ADR-0070 amendment) has no
    // NT/AFD counterpart yet.
    if (@import("builtin").os.tag == .windows)
        return @import("../test_support/skip.zig").blocker(.@"D-569");
    try runOfficialWasip3Test("sockets-tcp-connect");
}
test "wasip3-official: http-fields (fields resource, RFC 9110 validation)" {
    try runOfficialWasip3Test("http-fields");
}
test "wasip3-official: http-request (method/scheme/path/authority validation)" {
    try runOfficialWasip3Test("http-request");
}
test "wasip3-official: http-response (status code + immutable headers)" {
    try runOfficialWasip3Test("http-response");
}
test "wasip3-official: http-request-options (timeouts + immutable child)" {
    try runOfficialWasip3Test("http-request-options");
}
test "wasip3-official: sockets-udp-connect" {
    try runOfficialWasip3Test("sockets-udp-connect");
}
test "wasip3-official: sockets-udp-send" {
    try runOfficialWasip3Test("sockets-udp-send");
}
test "wasip3-official: sockets-udp-receive" {
    try runOfficialWasip3Test("sockets-udp-receive");
}
test "wasip3-official: sockets-tcp-listen" {
    try runOfficialWasip3Test("sockets-tcp-listen");
}
test "wasip3-official: sockets-tcp-send" {
    try runOfficialWasip3Test("sockets-tcp-send");
}
test "wasip3-official: sockets-tcp-receive" {
    try runOfficialWasip3Test("sockets-tcp-receive");
}
test "wasip3-official: sockets-echo (join! interleaved data plane)" {
    try runOfficialWasip3Test("sockets-echo");
}
