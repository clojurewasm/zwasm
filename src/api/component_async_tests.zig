//! Cross-component async tests — ADR-0195 (multi-task scheduler) + ADR-0197
//! (handle-isolation ownership ledger). Extracted from `component_tests.zig` per
//! the file-size smell rule (P3: the cross-component graph async subsystem changes
//! on its own cadence; this is the home for future D-464 adversarial cases). Tests
//! `component.instantiateGraph` + the `GraphAsync` scheduler/ledger end-to-end.

const std = @import("std");
const testing = std.testing;

const component = @import("component.zig");
const Engine = @import("../zwasm/engine.zig").Engine;

// component.zig public decls the tests reference by bare name.
const instantiateGraph = component.instantiateGraph;

const two_async_components_path = "test/component/two_async_components.wasm";

test "ADR-0195 c-2b: a 2-component async graph runs e2e (A async-calls B; both tasks complete)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A's async `run` async-calls B's async `tick`. The boundary trampoline mints
    // B's subtask into the SHARED scheduler table; driveScheduler drives BOTH to
    // completion. A clean return (no AsyncDeadlock) + both tasks `.done` proves
    // the cross-component async routing — not just A running in isolation.
    try graph.driveAsyncMain("run");
    const counts = graph.asyncTaskCounts();
    try testing.expectEqual(@as(usize, 2), counts.total); // A's run + B's tick
    try testing.expectEqual(@as(usize, 2), counts.done); // both reached EXIT
}

const two_async_components_task_return_path = "test/component/two_async_components_task_return.wasm";

test "ADR-0195 d-a: a cross-component async callee's task.return value is captured graph-side" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_task_return_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A's async `run` async-calls B's async `tick: async func() -> u32`. B's core
    // `tick` calls task.return(42) then EXITs. The graph-level task.return host
    // func captures 42 into B's subtask's per-task result slot — proving the
    // smallest guest↔guest async DATA transfer (not just both tasks completing).
    try graph.driveAsyncMain("run");
    const counts = graph.asyncTaskCounts();
    try testing.expectEqual(@as(usize, 2), counts.total); // A's run + B's tick
    try testing.expectEqual(@as(usize, 2), counts.done); // both reached EXIT

    // B's subtask is the SECOND task added (task id 2: A's run = 1, B's tick = 2).
    try testing.expectEqual(@as(?u32, 42), graph.taskResult(2));
}

const two_async_components_consume_result_path = "test/component/two_async_components_consume_result.wasm";

test "ADR-0195 d-b: the caller consumes the callee's async result (B's value lowered into A's retptr)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_consume_result_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A's `run` async-calls B's `tick: -> u32` with a retptr; the graph lowers B's
    // synchronously-resolved result (42) into A's memory at the retptr; A reads it
    // and task.returns it. So A's OWN task result (task 1) is 42 — proving A
    // received B's value (vs d-a, where only B's task 2 held 42).
    try graph.driveAsyncMain("run");
    const counts = graph.asyncTaskCounts();
    try testing.expectEqual(@as(usize, 2), counts.total);
    try testing.expectEqual(@as(usize, 2), counts.done);
    try testing.expectEqual(@as(?u32, 42), graph.taskResult(1)); // A consumed B's result
}

const two_async_components_future_path = "test/component/two_async_components_future.wasm";

test "ADR-0195 d-b-2: a single-shot guest↔guest async future rendezvous (B writes 42, A reads it)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_future_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A's `run` mints a `future<u32>` (over the GRAPH-shared rendezvous), async-calls
    // B's `tick(future<u32>)` passing the writable handle. B runs synchronously during
    // the async call and `future.write`s 42 into the shared rendezvous; A then
    // `future.read`s 42 and task.returns it. A's OWN task result (task 1) == 42 proves
    // the value crossed B→A through the cross-component future (not just both completing).
    try graph.driveAsyncMain("run");
    const counts = graph.asyncTaskCounts();
    try testing.expectEqual(@as(usize, 2), counts.total); // A's run + B's tick
    try testing.expectEqual(@as(usize, 2), counts.done); // both reached EXIT
    try testing.expectEqual(@as(?u32, 42), graph.taskResult(1)); // A read B's future value
}

const two_async_components_stream_path = "test/component/two_async_components_stream.wasm";

test "ADR-0195 d-c-1: a synchronous multi-element guest↔guest async stream rendezvous (B writes 3 bytes, A reads + sums them)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_stream_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A's `run` mints a `stream<u8>` (over the GRAPH-shared rendezvous), async-calls
    // B's `tick(stream<u8>)` passing the writable handle. B runs synchronously during
    // the async call and `stream.write`s 3 bytes {10,20,12} into the shared rendezvous;
    // A then `stream.read`s the 3 bytes and task.returns their sum. A's OWN task result
    // (task 1) == 42 proves the multi-byte payload crossed B→A through the cross-component
    // stream (not just both completing), and that A's read COMPLETED(3) without BLOCKing.
    try graph.driveAsyncMain("run");
    const counts = graph.asyncTaskCounts();
    try testing.expectEqual(@as(usize, 2), counts.total); // A's run + B's tick
    try testing.expectEqual(@as(usize, 2), counts.done); // both reached EXIT
    try testing.expectEqual(@as(?u32, 42), graph.taskResult(1)); // A summed B's stream bytes
}

const two_async_components_stream_blocking_path = "test/component/two_async_components_stream_blocking.wasm";
const two_async_components_stream_deadlock_path = "test/component/two_async_components_stream_deadlock.wasm";

test "ADR-0195 d-c-2: a BLOCKING guest↔guest async stream rendezvous (B reads→BLOCKS→WAITs, A writes, B re-enters via pollSet, sums to 42)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_stream_blocking_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A's `run` mints a `stream<u8>`, async-calls B's `tick(stream<u8>)` passing the
    // READABLE end. B `stream.read`s it → BLOCKED (A has not written) → joins it to a
    // fresh waitable-set + returns WAIT(set), so B's task is `.waiting` (the genuine
    // block — NOT the synchronous d-c-1 path). A then `stream.write`s {20,22} into the
    // writable end: the rendezvous resolves B's parked read, copies the bytes into B's
    // memory + sets B's read-end STREAM_READ pending_event. `driveScheduler` polls B's
    // `.waiting` task → `GraphAsyncCtx.pollSet` fetches the set, finds the pending event,
    // re-enters B's callback, which reads 20+22 == 42 and task.returns it. B's OWN task
    // result (task 2) == 42 proves the value crossed A→B through the BLOCKING park-then-
    // deliver path + the pollSet/waitable-set delivery.
    try graph.driveAsyncMain("run");
    const counts = graph.asyncTaskCounts();
    try testing.expectEqual(@as(usize, 2), counts.total); // A's run + B's tick
    try testing.expectEqual(@as(usize, 2), counts.done); // both reached EXIT
    try testing.expectEqual(@as(?u32, 42), graph.taskResult(2)); // B summed A's delivered bytes
}

test "ADR-0195 d-c-2 (adversarial): a cross-component async read that BLOCKS with no peer write TRAPS AsyncDeadlock, never hangs or completes silently" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_stream_deadlock_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // B blocks on the read; A never writes → B's `.waiting` task is never woken
    // (pollSet returns null forever) and a whole scheduler pass makes no progress.
    // The driver MUST trap `AsyncDeadlock` (loud), not hang or silently return.
    try testing.expectError(error.AsyncDeadlock, graph.driveAsyncMain("run"));
}

const two_async_components_stream_isolation_path = "test/component/two_async_components_stream_isolation.wasm";

test "ADR-0197 (security/D-463): child B writing to child A's UN-GRANTED stream handle must TRAP, not inject into A's private stream" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_stream_isolation_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A mints TWO streams; grants B only w1 but B writes to bare handle 4 == A's
    // PRIVATE writable end w2 (a handle B was never given). Under per-component
    // handle isolation (ADR-0197) B's own table has no index 4 → `stream.write`
    // traps (InvalidHandle → canonical guest `error.Unreachable`). The pre-fix
    // shared-table behaviour SILENTLY succeeded — B injected bytes into A's private
    // stream and A read 42 back (the cross-component handle-isolation leak).
    try testing.expectError(error.Unreachable, graph.driveAsyncMain("run"));
}

const two_async_components_stream_dropped_path = "test/component/two_async_components_stream_dropped.wasm";

test "ADR-0195 (e)/D-464: a cross-component stream whose WRITABLE peer is DROPPED mid-rendezvous lets the reader observe DROPPED, not hang" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_stream_dropped_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A passes the writable end to B; B drops it without writing. A's `stream.read`
    // folds the dropped peer into the spec DROPPED return code (`(0 << 4) | 1` == 1).
    // A `task.return`s that raw code, so A's task result == 1 proves the reader saw a
    // clean DROPPED — not BLOCKED (0xffffffff), COMPLETED (0), an AsyncDeadlock hang,
    // or a trap. Exercises the graph drop path (B owns w post-transfer, ADR-0197).
    try graph.driveAsyncMain("run");
    const counts = graph.asyncTaskCounts();
    try testing.expectEqual(@as(usize, 2), counts.total); // A's run + B's tick
    try testing.expectEqual(@as(usize, 2), counts.done); // both reached EXIT
    try testing.expectEqual(@as(?u32, 1), graph.taskResult(1)); // A saw DROPPED (code 1)
}

const two_async_components_future_drop_trap_path = "test/component/two_async_components_future_drop_trap.wasm";

test "D-465: dropping a cross-component FUTURE writable end before writing TRAPS (FutureDropBeforeWrite), not BLOCK/silent" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_future_drop_trap_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // B drops the writable future end before writing; the reader (A) has not dropped,
    // so the spec guard (`guardWritableDrop` → FutureDropBeforeWrite) must fire and the
    // drive must trap. Pre-fix the graph drop builtin skipped the guard (BLOCKED).
    try testing.expectError(error.Unreachable, graph.driveAsyncMain("run"));
}

const two_async_components_future_drop_reader_path = "test/component/two_async_components_future_drop_reader.wasm";

test "D-465: when the FUTURE reader drops its readable end, the writer's future.write observes DROPPED" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_future_drop_reader_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // A drops its readable end, then B writes → B's future.write sees the dropped
    // rendezvous and returns the spec DROPPED code (1). B's task (task 2) result == 1.
    try graph.driveAsyncMain("run");
    try testing.expectEqual(@as(?u32, 1), graph.taskResult(2)); // B saw DROPPED (code 1)
}

const two_async_components_stream_blocking_drop_path = "test/component/two_async_components_stream_blocking_drop.wasm";

test "D-464(1): a PARKED cross-component stream reader is woken with DROPPED when its writable peer drops (no deadlock)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, two_async_components_stream_blocking_drop_path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(bytes);

    var eng = try Engine.init(testing.allocator, .{});
    defer eng.deinit();
    var graph = try instantiateGraph(&eng, testing.allocator, bytes, .{});
    defer graph.deinit();

    // B parks reading; A drops the writable peer. The drop must wake B's parked read
    // with DROPPED (B re-reads → low bit set → task.return 99), not leave it waiting
    // forever (AsyncDeadlock).
    try graph.driveAsyncMain("run");
    try testing.expectEqual(@as(?u32, 99), graph.taskResult(2)); // B woken with DROPPED
}
