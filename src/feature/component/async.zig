//! WASI-0.3 / Component-Model async runtime (campaign D-335 Unit D; ADR-0187).
//!
//! Stackless callback-ABI model on zwasm's synchronous engine — NO fibers. This
//! module is the Zone-1 pure-data core: the per-component stream/future **handle
//! table** (the table Unit C's i32 ABI handles index into), the `CopyState`
//! machine, and the `ReturnCode` packing. The rendezvous copy logic, waitable
//! sets, subtasks, and the callback event loop land in later chunks (β–η per
//! ADR-0187); none of those import the engine — the Zone-3 host drives the loop.
//!
//! The handle-table discipline mirrors `resource_table.zig`: dense array + free
//! list, index 0 reserved as a `None` sentinel (a valid handle is ≥ 1), and
//! `remove` tombstones a slot so a double-drop / use-after-drop traps on the
//! next access.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Spec `Table.MAX_LENGTH` — leaves the high 4 bits of a handle free for guest
/// tagging (shared with the resource handle table).
pub const MAX_LENGTH: u32 = (1 << 28) - 1;

pub const Error = error{
    /// Handle index out of bounds, the reserved 0 sentinel, or a freed
    /// (tombstoned) slot — covers use-after-drop / double-drop.
    InvalidHandle,
    /// The table reached `MAX_LENGTH`.
    TableFull,
    OutOfMemory,
    /// `drop` of a readable/writable end while a copy is in progress
    /// (spec `CopyEnd.drop` traps unless the state is IDLE/DONE).
    CopyInProgress,
    /// `cancel-read`/`cancel-write` on an end with no async copy in flight.
    NotCopying,
};

/// Copy-state of a stream/future end (`CanonicalABI.md` §Stream State). The
/// transitions (idle → async_copying → done, + cancelling) are driven by the
/// rendezvous logic in a later chunk; α only needs the enum + the idle default.
pub const CopyState = enum { idle, sync_copying, async_copying, cancelling_copy, done };

/// An async builtin's return value (`CanonicalABI.md`; wasmtime
/// `futures_and_streams.rs`). `Blocked` is the all-ones sentinel; the others
/// pack a 4-bit code in the low bits and an item count in the high 28 bits
/// (count is always 0 for futures — at most one value).
pub const ReturnCode = union(enum) {
    blocked,
    completed: u28,
    dropped: u28,
    cancelled: u28,

    pub fn encode(self: ReturnCode) u32 {
        return switch (self) {
            .blocked => 0xffff_ffff,
            .completed => |n| @as(u32, n) << 4, // code 0
            .dropped => |n| (@as(u32, n) << 4) | 1,
            .cancelled => |n| (@as(u32, n) << 4) | 2,
        };
    }
};

/// The async event kinds delivered to core wasm (`CanonicalABI.md` `EventCode`).
pub const EventCode = enum(u8) {
    none = 0,
    subtask = 1,
    stream_read = 2,
    stream_write = 3,
    future_read = 4,
    future_write = 5,
    task_cancelled = 6,
};

/// One delivered event `(code, index, payload)` — `index` is the waitable
/// handle, `payload` the encoded `ReturnCode` (or subtask state).
pub const EventTuple = struct {
    code: EventCode,
    index: u32,
    payload: u32,
};

pub const EndKind = enum { stream, future };
pub const EndSide = enum { readable, writable };

/// One stream/future **end** in the handle table. `elem_type` is the element
/// (stream) / value (future) WIT type index, or null for a payload-less
/// `stream`/`future`. The shared rendezvous buffer joining the two ends lands
/// in chunk β.
pub const StreamFutureEnd = struct {
    kind: EndKind,
    side: EndSide,
    elem_type: ?u32,
    state: CopyState = .idle,
    /// spec `Waitable.pending_event` — at most one event awaits delivery. Stored
    /// as the value directly (the spec's optimized non-closure form).
    pending_event: ?EventTuple = null,
    /// the waitable-set handle this end belongs to, if any (`Waitable.wset`).
    wset: ?u32 = null,

    /// `Waitable.set_pending_event`.
    pub fn setPendingEvent(self: *StreamFutureEnd, ev: EventTuple) void {
        self.pending_event = ev;
    }

    /// `Waitable.has_pending_event`.
    pub fn hasPendingEvent(self: StreamFutureEnd) bool {
        return self.pending_event != null;
    }

    /// `Waitable.get_pending_event` — delivers + clears the single event.
    pub fn takePendingEvent(self: *StreamFutureEnd) ?EventTuple {
        defer self.pending_event = null;
        return self.pending_event;
    }

    /// spec `CopyEnd.copying` — true while a copy is in flight or cancelling
    /// (the states a `drop` must not interrupt).
    pub fn copying(self: StreamFutureEnd) bool {
        return switch (self.state) {
            .idle, .done => false,
            .sync_copying, .async_copying, .cancelling_copy => true,
        };
    }

    /// Initiate a read (readable end) / write (writable end) through `shared`
    /// and fold the rendezvous result into this end's `CopyState`: a blocked
    /// op parks the end in `async_copying`, a synchronous rendezvous returns to
    /// `idle`, and a dropped peer is `done`. A within-call (synchronous)
    /// completion never lingers in `sync_copying`, so there is nothing to cancel
    /// for it — cancel only targets `async_copying`. When the rendezvous resolves
    /// the previously-pending peer, its `pending_event` is delivered here (the
    /// peer's blocked copy completes and returns to `idle`). `handle` is this
    /// end's own table handle.
    pub fn copy(self: *StreamFutureEnd, shared: *SharedStream, table: *StreamFutureTable, handle: u32, n: u32) Error!Step {
        const step = switch (self.side) {
            .readable => shared.read(n, handle),
            .writable => shared.write(n, handle),
        };
        self.state = switch (step.caller) {
            .blocked => .async_copying,
            .completed => .idle,
            .dropped => .done,
        };
        if (step.notify) |nt| {
            const peer = try table.get(nt.waitable);
            peer.setPendingEvent(.{ .code = nt.code, .index = nt.waitable, .payload = nt.payload });
            peer.state = .idle; // the peer's blocked copy has resolved
        }
        return step;
    }

    /// `stream.cancel-{read,write}` — cancel this end's in-flight async copy,
    /// clearing its pending slot in `shared`. Returns items copied so far (0 in
    /// the rendezvous-count model — partial-copy progress lands with the host
    /// buffer wiring). Errors if no async copy is in flight.
    pub fn cancel(self: *StreamFutureEnd, shared: *SharedStream) Error!u32 {
        if (self.state != .async_copying) return Error.NotCopying;
        self.state = .cancelling_copy;
        if (shared.pending) |p| {
            if (p.side == self.side) shared.pending = null;
        }
        self.state = .idle;
        return 0;
    }

    /// `drop` a readable/writable end — traps (errors) if a copy is in
    /// progress; otherwise marks the shared stream dropped so the peer's next
    /// read/write observes `DROPPED`.
    pub fn drop(self: *StreamFutureEnd, shared: *SharedStream) Error!void {
        if (self.copying()) return Error.CopyInProgress;
        shared.dropped = true;
    }
};

/// The per-component stream/future handle table (ADR-0187). Index 0 is the
/// reserved `None` sentinel; holes are `null` and reused via the free list.
pub const StreamFutureTable = struct {
    slots: std.ArrayList(?StreamFutureEnd),
    free: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Error!StreamFutureTable {
        var slots: std.ArrayList(?StreamFutureEnd) = .empty;
        errdefer slots.deinit(alloc);
        try slots.append(alloc, null); // reserve index 0
        return .{ .slots = slots, .free = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *StreamFutureTable) void {
        self.slots.deinit(self.alloc);
        self.free.deinit(self.alloc);
    }

    /// `Table.add` — reuse a free hole or grow; returns the handle index (≥ 1).
    pub fn add(self: *StreamFutureTable, end: StreamFutureEnd) Error!u32 {
        if (self.free.pop()) |i| {
            self.slots.items[i] = end;
            return i;
        }
        const i: u32 = @intCast(self.slots.items.len);
        if (i > MAX_LENGTH) return Error.TableFull;
        try self.slots.append(self.alloc, end);
        return i;
    }

    /// `Table.get` — bounds + hole check (the trap source for stale handles).
    pub fn get(self: *StreamFutureTable, i: u32) Error!*StreamFutureEnd {
        if (i == 0 or i >= self.slots.items.len) return Error.InvalidHandle;
        if (self.slots.items[i] == null) return Error.InvalidHandle;
        return &self.slots.items[i].?;
    }

    /// `Table.remove` — tombstone the slot + push the hole to the free list.
    pub fn remove(self: *StreamFutureTable, i: u32) Error!StreamFutureEnd {
        const end = (try self.get(i)).*;
        self.slots.items[i] = null;
        try self.free.append(self.alloc, i);
        return end;
    }
};

/// A "waitable set" (`CanonicalABI.md` `WaitableSet`): a collection of waitable
/// handles that core wasm waits on / polls for *any* member to make progress.
/// `elems` holds the member handle indices into the `StreamFutureTable`; a real
/// implementation would embed a ready-list to avoid the O(n) scan, but a member
/// can carry at most one pending event so correctness is unaffected.
pub const WaitableSet = struct {
    elems: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) WaitableSet {
        return .{ .elems = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *WaitableSet) void {
        self.elems.deinit(self.alloc);
    }

    /// `Waitable.join` (the set side) — add a member handle.
    pub fn join(self: *WaitableSet, handle: u32) Error!void {
        try self.elems.append(self.alloc, handle);
    }

    /// True if any member has a pending event (`WaitableSet.has_pending_event`).
    pub fn hasPendingEvent(self: WaitableSet, table: *StreamFutureTable) bool {
        for (self.elems.items) |h| {
            const e = table.get(h) catch continue;
            if (e.hasPendingEvent()) return true;
        }
        return false;
    }

    /// `WaitableSet.poll` — deliver (and clear) the first member's pending
    /// event, or null for `EventCode.NONE` (nothing ready). The blocking
    /// `wait` variant adds the event-loop suspension on top (Unit η).
    pub fn poll(self: *WaitableSet, table: *StreamFutureTable) Error!?EventTuple {
        for (self.elems.items) |h| {
            const e = table.get(h) catch continue;
            if (e.hasPendingEvent()) return e.takePendingEvent();
        }
        return null;
    }
};

/// Outcome of one read/write rendezvous step (`CanonicalABI.md` stream
/// `read`/`write`). `caller` is what happens to the calling end. When a
/// rendezvous resolves the previously-pending opposite end, `notify` identifies
/// it (its waitable handle + the copy event code + encoded `ReturnCode`) so the
/// caller delivers a `pending_event` to it (the Unit-δ event seam).
pub const Step = struct {
    caller: union(enum) { blocked, completed: u32, dropped },
    notify: ?Notify = null,

    pub const Notify = struct { waitable: u32, code: EventCode, payload: u32 };
};

/// The copy-event code delivered to a resolved end of the given `side`
/// (a readable end's read completed → STREAM_READ; writable → STREAM_WRITE).
fn streamEventFor(side: EndSide) EventCode {
    return switch (side) {
        .readable => .stream_read,
        .writable => .stream_write,
    };
}

/// The state shared by a stream's two ends (`CanonicalABI.md` §Stream State,
/// the `SharedStreamImpl` rendezvous). Zone-1 control logic only: it computes
/// the transfer COUNT (`min` of the two buffers) and the state transitions; the
/// actual element bytes are moved by the host via the Unit-C canon store/load
/// (this module never touches guest memory). At most one end is `pending` at a
/// time (one-reader / one-writer invariant). `pending.waitable` records the
/// blocked end's handle so a later rendezvous can deliver its event.
pub const SharedStream = struct {
    elem_type: ?u32,
    dropped: bool = false,
    pending: ?Pending = null,

    pub const Pending = struct { side: EndSide, remain: u32, waitable: u32 };

    fn notifyOf(p: Pending, n: u32) Step.Notify {
        return .{ .waitable = p.waitable, .code = streamEventFor(p.side), .payload = (ReturnCode{ .completed = @intCast(n) }).encode() };
    }

    /// `ReadableStream.read` — `cap` is the destination buffer capacity;
    /// `handle` is this readable end's table handle (recorded if it blocks).
    pub fn read(self: *SharedStream, cap: u32, handle: u32) Step {
        if (self.dropped) return .{ .caller = .dropped };
        const w = self.pending orelse {
            self.pending = .{ .side = .readable, .remain = cap, .waitable = handle };
            return .{ .caller = .blocked };
        };
        std.debug.assert(w.side == .writable);
        if (w.remain > 0) {
            if (cap == 0) return .{ .caller = .{ .completed = 0 } }; // writer stays pending
            const n = @min(cap, w.remain);
            self.pending = null;
            return .{ .caller = .{ .completed = n }, .notify = notifyOf(w, n) };
        }
        // Zero-length pending write: notify the writer COMPLETED(0); this read
        // becomes pending. (read has NO zero-zero shortcut — see write.)
        self.pending = .{ .side = .readable, .remain = cap, .waitable = handle };
        return .{ .caller = .blocked, .notify = notifyOf(w, 0) };
    }

    /// `WritableStream.write` — `count` is the source item count; `handle` is
    /// this writable end's table handle. The zero-zero rendezvous resolves in
    /// the writer's favour (livelock avoidance).
    pub fn write(self: *SharedStream, count: u32, handle: u32) Step {
        if (self.dropped) return .{ .caller = .dropped };
        const r = self.pending orelse {
            self.pending = .{ .side = .writable, .remain = count, .waitable = handle };
            return .{ .caller = .blocked };
        };
        std.debug.assert(r.side == .readable);
        if (r.remain > 0) {
            if (count == 0) return .{ .caller = .{ .completed = 0 } }; // reader stays pending
            const n = @min(count, r.remain);
            self.pending = null;
            return .{ .caller = .{ .completed = n }, .notify = notifyOf(r, n) };
        }
        // Pending reader is zero-length.
        if (count == 0) return .{ .caller = .{ .completed = 0 } }; // both zero → write wins, read pends
        self.pending = .{ .side = .writable, .remain = count, .waitable = handle };
        return .{ .caller = .blocked, .notify = notifyOf(r, 0) };
    }
};

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "ReturnCode packs per the canonical-ABI encoding" {
    try testing.expectEqual(@as(u32, 0xffff_ffff), (@as(ReturnCode, .blocked)).encode());
    try testing.expectEqual(@as(u32, 3 << 4), (ReturnCode{ .completed = 3 }).encode());
    try testing.expectEqual(@as(u32, (5 << 4) | 1), (ReturnCode{ .dropped = 5 }).encode());
    try testing.expectEqual(@as(u32, (2 << 4) | 2), (ReturnCode{ .cancelled = 2 }).encode());
    // futures carry a zero count → just the code in the low bits.
    try testing.expectEqual(@as(u32, 0), (ReturnCode{ .completed = 0 }).encode());
}

test "stream rendezvous: write-then-read copies min(counts); notifies the pending writer" {
    var s = SharedStream{ .elem_type = 5 };
    try testing.expect(s.write(2, 11).caller == .blocked); // writer (handle 11) pends
    const step = s.read(4, 22); // reader rendezvous with the pending writer
    try testing.expectEqual(@as(u32, 2), step.caller.completed);
    const nt = step.notify.?;
    try testing.expectEqual(@as(u32, 11), nt.waitable); // the previously-pending writer
    try testing.expectEqual(EventCode.stream_write, nt.code);
    try testing.expectEqual((ReturnCode{ .completed = 2 }).encode(), nt.payload);
    try testing.expect(s.pending == null); // both ends resolved
}

test "stream rendezvous: read-then-write is symmetric (notifies the pending reader)" {
    var s = SharedStream{ .elem_type = null };
    try testing.expect(s.read(4, 22).caller == .blocked);
    const step = s.write(2, 11);
    try testing.expectEqual(@as(u32, 2), step.caller.completed);
    const nt = step.notify.?;
    try testing.expectEqual(@as(u32, 22), nt.waitable); // the pending reader
    try testing.expectEqual(EventCode.stream_read, nt.code);
    try testing.expect(s.pending == null);
}

test "stream rendezvous: dropped end + zero-length livelock tiebreak (write wins)" {
    var dropped = SharedStream{ .elem_type = null, .dropped = true };
    try testing.expect(dropped.read(4, 1).caller == .dropped);
    try testing.expect(dropped.write(4, 1).caller == .dropped);

    // zero-length read pends; a following zero-length write COMPLETES while the
    // read stays pending (the spec's livelock-avoidance asymmetry).
    var s = SharedStream{ .elem_type = null };
    try testing.expect(s.read(0, 22).caller == .blocked);
    const w = s.write(0, 11);
    try testing.expectEqual(@as(u32, 0), w.caller.completed);
    try testing.expect(s.pending != null); // read still pending
}

test "waitable-set: poll delivers a member's pending event once, then clears it" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    const h = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });

    var ws = WaitableSet.init(testing.allocator);
    defer ws.deinit();
    try ws.join(h);
    try testing.expect(!ws.hasPendingEvent(&t));
    try testing.expect((try ws.poll(&t)) == null); // EventCode.NONE → null

    // a STREAM_READ event lands on the member end.
    (try t.get(h)).setPendingEvent(.{ .code = .stream_read, .index = h, .payload = 7 });
    try testing.expect(ws.hasPendingEvent(&t));
    const ev = (try ws.poll(&t)).?;
    try testing.expectEqual(EventCode.stream_read, ev.code);
    try testing.expectEqual(h, ev.index);
    try testing.expectEqual(@as(u32, 7), ev.payload);

    // get_pending_event clears it (at-most-one event per waitable).
    try testing.expect(!ws.hasPendingEvent(&t));
    try testing.expect((try ws.poll(&t)) == null);
}

test "stream end CopyState: blocked copy → async_copying; cancel → idle; drop traps while copying" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    var shared = SharedStream{ .elem_type = null };
    const rh = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });
    const re = try t.get(rh);
    try testing.expect(!re.copying());

    // a read with no pending writer blocks → the end enters async_copying.
    try testing.expect((try re.copy(&shared, &t, rh, 4)).caller == .blocked);
    try testing.expectEqual(CopyState.async_copying, re.state);
    try testing.expect(re.copying());

    // dropping an end with a copy in progress traps (spec CopyEnd.drop).
    try testing.expectError(Error.CopyInProgress, re.drop(&shared));

    // cancel clears the in-flight copy and the shared pending slot → idle.
    _ = try re.cancel(&shared);
    try testing.expectEqual(CopyState.idle, re.state);
    try testing.expect(shared.pending == null);

    // now drop is allowed and sets the shared dropped flag.
    try re.drop(&shared);
    try testing.expect(shared.dropped);
}

test "stream end copy: synchronous rendezvous resolves both ends to idle; dropped peer → done" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    var shared = SharedStream{ .elem_type = null };
    const wh = try t.add(.{ .kind = .stream, .side = .writable, .elem_type = null });
    const rh = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });

    try testing.expect((try (try t.get(wh)).copy(&shared, &t, wh, 2)).caller == .blocked); // writer pends
    const step = try (try t.get(rh)).copy(&shared, &t, rh, 4); // reader rendezvous (synchronous)
    try testing.expectEqual(@as(u32, 2), step.caller.completed);
    try testing.expectEqual(CopyState.idle, (try t.get(rh)).state);
    // the previously-pending writer got its event delivered + resolved to idle.
    try testing.expect((try t.get(wh)).hasPendingEvent());
    try testing.expectEqual(CopyState.idle, (try t.get(wh)).state);

    // a peer drop makes the next copy see DROPPED → the end is done.
    shared.dropped = true;
    try testing.expect((try (try t.get(rh)).copy(&shared, &t, rh, 1)).caller == .dropped);
    try testing.expectEqual(CopyState.done, (try t.get(rh)).state);
}

test "D-335 unit D-δ: a rendezvous delivers a STREAM_READ event to the blocked reader's waitable-set" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();
    var shared = SharedStream{ .elem_type = null };
    const rh = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = null });
    const wh = try t.add(.{ .kind = .stream, .side = .writable, .elem_type = null });

    var ws = WaitableSet.init(testing.allocator);
    defer ws.deinit();
    try ws.join(rh);

    // reader blocks (no writer yet) — nothing ready on its set.
    try testing.expect((try (try t.get(rh)).copy(&shared, &t, rh, 4)).caller == .blocked);
    try testing.expect((try ws.poll(&t)) == null);

    // writer writes 2 → the reader's set now has a STREAM_READ event.
    try testing.expectEqual(@as(u32, 2), (try (try t.get(wh)).copy(&shared, &t, wh, 2)).caller.completed);
    const ev = (try ws.poll(&t)).?;
    try testing.expectEqual(EventCode.stream_read, ev.code);
    try testing.expectEqual(rh, ev.index);
    try testing.expectEqual((ReturnCode{ .completed = 2 }).encode(), ev.payload);
}

test "stream/future end table: add/get/remove lifecycle + index-0 reserved" {
    var t = try StreamFutureTable.init(testing.allocator);
    defer t.deinit();

    const h = try t.add(.{ .kind = .stream, .side = .readable, .elem_type = 5 });
    try testing.expect(h >= 1); // a valid handle is never the 0 sentinel
    const end = try t.get(h);
    try testing.expectEqual(EndKind.stream, end.kind);
    try testing.expectEqual(EndSide.readable, end.side);
    try testing.expectEqual(@as(?u32, 5), end.elem_type);
    try testing.expectEqual(CopyState.idle, end.state);

    // index 0 is the reserved None sentinel.
    try testing.expectError(Error.InvalidHandle, t.get(0));

    // remove tombstones → use-after-drop / double-drop trap.
    _ = try t.remove(h);
    try testing.expectError(Error.InvalidHandle, t.get(h));
    try testing.expectError(Error.InvalidHandle, t.remove(h));

    // a freed slot is reused (free list) for the next add.
    const h2 = try t.add(.{ .kind = .future, .side = .writable, .elem_type = null });
    try testing.expectEqual(h, h2);
    try testing.expectEqual(EndKind.future, (try t.get(h2)).kind);
}
