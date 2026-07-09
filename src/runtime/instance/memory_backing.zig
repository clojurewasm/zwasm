//! Linear-memory backing selection (ADR-0202 D1).
//!
//! Chooses between the reservation-backed guard-page store (qualifying
//! i32 / 64 KiB-page memories on supported hosts — base pointer never
//! moves, grow = commit-in-place) and the plain allocator heap
//! (everything else — realloc on grow, base may move). The live
//! memory-creation surfaces (instantiate / engine setup / c-api
//! `wasm_memory_new`) route here so the ADR-0202 binding-time
//! soundness invariant has a single enforcement point. (The former
//! exception — the compute-only AOT mini-runtime's plain-heap scratch —
//! was retired at ADR-0203 stage 3: a loaded `.cwasm` binds memory
//! through the same setup path as fresh JIT, i.e. through here.)
//!
//! Zone 1 (`src/runtime/instance/`) — imports Zone 0
//! (`platform/guarded_mem`) + Zone 1 (`parse/sections`).

const std = @import("std");
const guarded_mem = @import("../../platform/guarded_mem.zig");
const sections = @import("../../parse/sections.zig");

/// A linear-memory backing store. `reservation == null` = plain
/// allocator heap (grow reallocs; base may move). Non-null =
/// guard-page reservation (grow commits in place; base never moves;
/// accesses past `bytes.len` up to the reservation end hardware-fault).
pub const Backing = struct {
    bytes: []u8,
    reservation: ?guarded_mem.Reservation = null,
};

/// ADR-0202 D1 qualification: i32 index space, standard 64 KiB pages
/// (a non-host-page-aligned `mem_limit` would leave a committed tail
/// the elided JIT could silently access), supported 64-bit host.
pub fn qualifies(idx_type: sections.MemoryEntry.IdxType, page_size_log2: u8) bool {
    return guarded_mem.supported and idx_type == .i32 and page_size_log2 == 16;
}

/// Allocate the initial backing for a linear memory of `bytes_total`
/// bytes. Zero-filled either way (heap: memset; guarded: OS anonymous
/// pages). Reservation failure maps to OutOfMemory — with the guard
/// region a qualifying memory has no heap fallback (ADR-0202 D1: code
/// compiled against a guarded memory0 must not silently get a plain
/// buffer).
pub fn allocBacking(
    alloc: std.mem.Allocator,
    bytes_total: usize,
    idx_type: sections.MemoryEntry.IdxType,
    page_size_log2: u8,
) error{OutOfMemory}!Backing {
    if (qualifies(idx_type, page_size_log2)) {
        // Same hard refusal as `growGuarded`: an initial size past the
        // 4 GiB i32 idx span (reachable via `wasm_memory_new` with
        // min > 65536 pages) must not commit into the guard region.
        if (bytes_total > (1 << 32)) return error.OutOfMemory;
        var res = guarded_mem.reserve(guarded_mem.i32_full_reservation) catch
            return error.OutOfMemory;
        guarded_mem.commit(&res, bytes_total) catch {
            guarded_mem.release(res);
            return error.OutOfMemory;
        };
        return .{ .bytes = res.base[0..bytes_total], .reservation = res };
    }
    const bytes = try alloc.alloc(u8, bytes_total);
    @memset(bytes, 0);
    return .{ .bytes = bytes };
}

/// Grow a guarded backing in place to `new_bytes` total. Returns the
/// new slice (SAME base pointer) or null when the request exceeds the
/// 4 GiB i32 idx span or the commit fails. Newly committed pages read
/// as zero (guarded_mem contract) — no memset. The span check is a
/// hard refusal, not an assert: `wasm_memory_grow`/`wasm_memory_new`
/// feed embedder-controlled u32s here with no earlier page cap, and
/// committing into the guard region would void the elision soundness.
/// Always call through a pointer INTO the owning struct — a local
/// `Reservation` copy loses the `.committed` advance (harmless-but-
/// wasteful re-commit on the next grow).
pub fn growGuarded(res: *guarded_mem.Reservation, new_bytes: usize) ?[]u8 {
    if (new_bytes > (1 << 32)) return null;
    guarded_mem.commit(res, new_bytes) catch return null;
    return res.base[0..new_bytes];
}

/// Release a backing produced by `allocBacking`.
pub fn freeBacking(alloc: std.mem.Allocator, b: Backing) void {
    if (b.reservation) |res| {
        guarded_mem.release(res);
        return;
    }
    if (b.bytes.len > 0) alloc.free(b.bytes);
}

// -----------------------------------------------------------
// Tests.
// -----------------------------------------------------------

const testing = std.testing;

test "memory_backing: qualifying i32/64KiB memory gets a guarded reservation; grow keeps the base" {
    if (comptime !guarded_mem.supported) return; // comptime platform prune (ADR-0122 D3) — ADR-0202 D1 host list
    const b = try allocBacking(testing.allocator, 2 * 65536, .i32, 16);
    defer freeBacking(testing.allocator, b);
    try testing.expect(b.reservation != null);
    try testing.expectEqual(@as(usize, 2 * 65536), b.bytes.len);
    try testing.expectEqual(@as(u8, 0), b.bytes[0]);
    try testing.expectEqual(@as(u8, 0), b.bytes[2 * 65536 - 1]);

    var res = b.reservation.?;
    const base_before = b.bytes.ptr;
    const grown = growGuarded(&res, 5 * 65536).?;
    try testing.expectEqual(base_before, grown.ptr); // in-place — never moves
    try testing.expectEqual(@as(usize, 5 * 65536), grown.len);
    try testing.expectEqual(@as(u8, 0), grown[5 * 65536 - 1]); // fresh pages zero
}

test "memory_backing: memory64 + custom-page-size memories stay heap-backed" {
    const b64 = try allocBacking(testing.allocator, 65536, .i64, 16);
    defer freeBacking(testing.allocator, b64);
    try testing.expect(b64.reservation == null);

    const b1 = try allocBacking(testing.allocator, 256, .i32, 0); // 1-byte pages
    defer freeBacking(testing.allocator, b1);
    try testing.expect(b1.reservation == null);
}

test "memory_backing: requests past the 4 GiB i32 idx span are refused, not asserted" {
    if (comptime !guarded_mem.supported) return; // comptime platform prune (ADR-0122 D3) — ADR-0202 D1 host list
    // C-ABI-reachable inputs (wasm_memory_new min / wasm_memory_grow
    // delta) can exceed the idx span with no earlier page cap — the
    // chokepoint must refuse, or elided code could touch committed
    // guard pages.
    try testing.expectError(
        error.OutOfMemory,
        allocBacking(testing.allocator, (1 << 32) + 65536, .i32, 16),
    );
    const b = try allocBacking(testing.allocator, 65536, .i32, 16);
    defer freeBacking(testing.allocator, b);
    var res = b.reservation.?;
    try testing.expectEqual(@as(?[]u8, null), growGuarded(&res, (1 << 32) + 65536));
}

test "memory_backing: zero-length qualifying memory is valid and growable" {
    if (comptime !guarded_mem.supported) return; // comptime platform prune (ADR-0122 D3) — ADR-0202 D1 host list
    const b = try allocBacking(testing.allocator, 0, .i32, 16);
    defer freeBacking(testing.allocator, b);
    try testing.expect(b.reservation != null);
    try testing.expectEqual(@as(usize, 0), b.bytes.len);
    var res = b.reservation.?;
    const grown = growGuarded(&res, 65536).?;
    try testing.expectEqual(@as(u8, 0), grown[65535]);
}
