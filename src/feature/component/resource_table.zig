//! Resource **handle table** (CM campaign chunk C1; spec `CanonicalABI.md`
//! §Resource State / `Table` / `canon resource.{new,drop,rep}`).
//!
//! A component instance's `handles` table: a dense array + free list mapping
//! handle indices → `ResourceHandle` (own/borrow + an i32 `rep`). Index 0 is a
//! reserved `None` sentinel, so a valid handle is always ≥ 1 and `0` reads as
//! invalid. `remove` tombstones a slot (sets it `None` + frees the index), so a
//! double-drop / use-after-drop traps via the hole check on the next access —
//! the live table's invariants are the hard part (the C1 focus).
//!
//! Zone-1 pure data structure: no engine/invoke. The destructor call on an
//! owning drop is the caller's job (the Zone-3 host runs `rt.dtor(rep)` via the
//! core invoke); `drop` here just returns the `rep` to destroy. The
//! `borrow_scope`/`Task` cross-call borrow machinery defers to a later chunk;
//! C1 models the `num_lends` guard that blocks dropping a still-lent resource.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Spec `Table.MAX_LENGTH` — leaves the high 4 bits of a handle free for guest
/// tagging.
pub const MAX_LENGTH: u32 = (1 << 28) - 1;

pub const Error = error{
    /// Handle index out of bounds, the reserved 0 sentinel, or a freed
    /// (tombstoned) slot — covers use-after-drop / double-drop.
    InvalidHandle,
    /// The handle's resource type does not match the expected `rt`.
    TypeMismatch,
    /// Dropping an `own` handle that is still lent out (`num_lends != 0`).
    HandleStillBorrowed,
    /// The table reached `MAX_LENGTH`.
    TableFull,
    OutOfMemory,
};

/// One entry of the `handles` table (spec `ResourceHandle`).
pub const ResourceHandle = struct {
    /// Resource type id (the component's resource type index).
    rt: u32,
    /// The private i32 representation passed to `resource.new`.
    rep: u32,
    /// `own` (true) vs `borrow` (false).
    own: bool,
    /// Count of outstanding borrows derived from this owning handle; an `own`
    /// handle cannot be dropped while > 0.
    num_lends: u32 = 0,
};

pub const ResourceTable = struct {
    /// `slots[0]` is the reserved `None` sentinel; holes are `null`.
    slots: std.ArrayList(?ResourceHandle),
    /// Free list of hole indices, reused in preference to growing.
    free: std.ArrayList(u32),
    alloc: Allocator,

    pub fn init(alloc: Allocator) Error!ResourceTable {
        var slots: std.ArrayList(?ResourceHandle) = .empty;
        errdefer slots.deinit(alloc);
        try slots.append(alloc, null); // reserve index 0
        return .{ .slots = slots, .free = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *ResourceTable) void {
        self.slots.deinit(self.alloc);
        self.free.deinit(self.alloc);
    }

    /// `Table.add` — reuse a free hole or grow.
    fn add(self: *ResourceTable, h: ResourceHandle) Error!u32 {
        if (self.free.pop()) |i| {
            self.slots.items[i] = h;
            return i;
        }
        const i: u32 = @intCast(self.slots.items.len);
        if (i > MAX_LENGTH) return Error.TableFull;
        try self.slots.append(self.alloc, h);
        return i;
    }

    /// `Table.get` — bounds + hole check (the trap source for stale handles).
    fn handlePtr(self: *ResourceTable, i: u32) Error!*ResourceHandle {
        if (i == 0 or i >= self.slots.items.len) return Error.InvalidHandle;
        if (self.slots.items[i] == null) return Error.InvalidHandle;
        return &self.slots.items[i].?;
    }

    /// `Table.remove` — tombstone the slot + push the hole to the free list.
    fn removeAt(self: *ResourceTable, i: u32) Error!ResourceHandle {
        const h = (try self.handlePtr(i)).*;
        self.slots.items[i] = null;
        try self.free.append(self.alloc, i);
        return h;
    }

    /// `canon resource.new` — create an owning handle for the representation.
    pub fn new(self: *ResourceTable, rt: u32, representation: u32) Error!u32 {
        return self.add(.{ .rt = rt, .rep = representation, .own = true });
    }

    /// Create a `borrow` handle of an existing owning handle, incrementing the
    /// lender's `num_lends` (so the owner can't be dropped while lent). The
    /// `borrow_scope`/`Task` lifetime machinery lands in a later chunk.
    pub fn newBorrow(self: *ResourceTable, rt: u32, lender: u32) Error!u32 {
        const owner = try self.handlePtr(lender);
        if (owner.rt != rt) return Error.TypeMismatch;
        const representation = owner.rep;
        owner.num_lends += 1;
        return self.add(.{ .rt = rt, .rep = representation, .own = false });
    }

    /// `canon resource.rep` — read the private representation of a handle.
    pub fn rep(self: *ResourceTable, rt: u32, i: u32) Error!u32 {
        const h = try self.handlePtr(i);
        if (h.rt != rt) return Error.TypeMismatch;
        return h.rep;
    }

    /// `canon resource.drop` — remove the handle. Returns the `rep` to destroy
    /// when the handle was owning (the caller runs the destructor), or `null`
    /// for a `borrow` (which instead decrements its lender's `num_lends`).
    /// Traps on a stale handle (double-drop), type mismatch, or a still-lent
    /// owning handle.
    pub fn drop(self: *ResourceTable, rt: u32, i: u32) Error!?u32 {
        const h = try self.handlePtr(i);
        if (h.rt != rt) return Error.TypeMismatch;
        if (h.own and h.num_lends != 0) return Error.HandleStillBorrowed;
        const removed = try self.removeAt(i);
        return if (removed.own) removed.rep else null;
    }

    /// Drop a handle WITHOUT a resource-type check — for a host that models
    /// several P2 resource kinds in ONE table and routes `canon resource.drop`
    /// generically (the handle's stored `rt` is authoritative; the language-level
    /// drop already named the type). Same own/borrow + still-lent semantics as
    /// `drop`. Returns the removed owning handle (`.rt` + `.rep`) so the host can
    /// run the right destructor per resource type, or null for a `borrow`.
    pub fn dropAny(self: *ResourceTable, i: u32) Error!?ResourceHandle {
        const h = try self.handlePtr(i);
        if (h.own and h.num_lends != 0) return Error.HandleStillBorrowed;
        const removed = try self.removeAt(i);
        return if (removed.own) removed else null;
    }

    /// Return a lent owning handle (`num_lends -= 1`). Called when a `borrow`
    /// derived from `lender` is dropped (the lender must still be live).
    pub fn endLend(self: *ResourceTable, lender: u32) Error!void {
        const owner = try self.handlePtr(lender);
        if (owner.num_lends == 0) return Error.InvalidHandle;
        owner.num_lends -= 1;
    }
};

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "new + rep round-trips; handle is >= 1" {
    var t = try ResourceTable.init(testing.allocator);
    defer t.deinit();
    const h = try t.new(7, 0xCAFE);
    try testing.expect(h >= 1);
    try testing.expectEqual(@as(u32, 0xCAFE), try t.rep(7, h));
}

test "dropAny removes a handle of any type without an rt check (returns its rep)" {
    var t = try ResourceTable.init(testing.allocator);
    defer t.deinit();
    const a = try t.new(1, 100); // output-stream-typed
    const b = try t.new(2, 200); // descriptor-typed
    const da = try t.dropAny(a);
    try testing.expectEqual(@as(u32, 1), da.?.rt);
    try testing.expectEqual(@as(u32, 100), da.?.rep);
    const db = try t.dropAny(b);
    try testing.expectEqual(@as(u32, 2), db.?.rt);
    try testing.expectEqual(@as(u32, 200), db.?.rep);
    // Both are now stale (double-drop traps).
    try testing.expectError(Error.InvalidHandle, t.dropAny(a));
}

test "handle 0 (sentinel) is always invalid" {
    var t = try ResourceTable.init(testing.allocator);
    defer t.deinit();
    try testing.expectError(Error.InvalidHandle, t.rep(7, 0));
    try testing.expectError(Error.InvalidHandle, t.drop(7, 0));
}

test "drop then access traps; double-drop traps" {
    var t = try ResourceTable.init(testing.allocator);
    defer t.deinit();
    const h = try t.new(1, 42);
    try testing.expectEqual(@as(?u32, 42), try t.drop(1, h)); // owning → returns rep
    try testing.expectError(Error.InvalidHandle, t.rep(1, h)); // use-after-drop
    try testing.expectError(Error.InvalidHandle, t.drop(1, h)); // double-drop
}

test "type mismatch on rep/drop traps" {
    var t = try ResourceTable.init(testing.allocator);
    defer t.deinit();
    const h = try t.new(3, 99);
    try testing.expectError(Error.TypeMismatch, t.rep(4, h));
    try testing.expectError(Error.TypeMismatch, t.drop(4, h));
}

test "borrow lifecycle: own can't drop while lent; endLend unblocks" {
    var t = try ResourceTable.init(testing.allocator);
    defer t.deinit();
    const owner = try t.new(2, 0x100);
    const borrow = try t.newBorrow(2, owner);
    try testing.expectEqual(@as(u32, 0x100), try t.rep(2, borrow)); // shares the rep

    // The owner is lent → dropping it traps.
    try testing.expectError(Error.HandleStillBorrowed, t.drop(2, owner));
    // Drop the borrow (own=false → null) and return the lend.
    try testing.expectEqual(@as(?u32, null), try t.drop(2, borrow));
    try t.endLend(owner);
    // Now the owner drops cleanly.
    try testing.expectEqual(@as(?u32, 0x100), try t.drop(2, owner));
}

test "free list reuses tombstoned slots" {
    var t = try ResourceTable.init(testing.allocator);
    defer t.deinit();
    const a = try t.new(1, 10);
    _ = try t.drop(1, a);
    const b = try t.new(1, 20); // should reuse a's slot index
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(u32, 20), try t.rep(1, b));
}
