//! ADR-0202 D3 — trap registry: the fault-classification data the
//! production signal/VEH handler reads to decide "wasm oob trap" vs
//! "internal zwasm bug".
//!
//! Two tables:
//! - **Guarded reservations** `[base, end)` — auto-registered by
//!   `guarded_mem.reserve` / auto-unregistered by `release` (single
//!   chokepoint; no caller can forget an unregister on any of the
//!   several release paths).
//! - **JIT code regions** `[start, end)` + a per-function table of
//!   `{code_off, oob_stub_off}` (sorted by `code_off`, built by the
//!   linker at publish) — registered where the code block is
//!   published, unregistered where it is freed.
//!
//! `classify(fault_addr, pc)` — BOTH conditions must hold (a stray
//! host-bug store into the reservation must NOT be converted to a
//! wasm trap unless the faulting PC is JIT code): fault_addr inside a
//! guarded reservation AND pc inside a registered code region. Returns
//! the absolute address of the containing function's oob (kind=6)
//! trap stub for the PC-redirect, else null.
//!
//! Async-signal-safety: fixed-capacity global arrays, no allocation,
//! no locks. Mutation (register/unregister) happens at publish /
//! instantiate / teardown time — never while JIT code is executing on
//! the same thread, and the runtime is single-threaded today; D-509
//! (threads) inherits this constraint explicitly (ADR-0202 D3).
//!
//! Zone 0 (`src/platform/`) — depends only on Zig stdlib.

const std = @import("std");

pub const Error = error{
    /// Fixed-capacity table is full.
    RegistryFull,
};

/// Per-function entry: byte offset of the function's code start and
/// of its kind=6 (oob_memory) trap stub, both relative to the code
/// region's `start`. `no_stub` marks a function that has no oob stub
/// (a fault there stays unclassified → diagnostic path; fail-safe).
pub const FuncEntry = struct {
    code_off: u32,
    oob_stub_off: u32,

    pub const no_stub: u32 = std.math.maxInt(u32);
};

const CodeRegion = struct {
    start: usize,
    end: usize,
    /// Sorted ascending by `code_off`; owned by the registrant and
    /// must outlive the registration (the linker's module owns it).
    funcs: []const FuncEntry,
};

const GuardedRegion = struct {
    base: usize,
    end: usize,
};

const max_code_regions = 1024;
const max_guarded_regions = 4096;

var code_regions: [max_code_regions]CodeRegion = undefined;
var code_regions_len: usize = 0;
var guarded_regions: [max_guarded_regions]GuardedRegion = undefined;
var guarded_regions_len: usize = 0;

/// Register a published JIT code region. `funcs` must be sorted
/// ascending by `code_off` and outlive the registration.
pub fn registerCodeRegion(start: usize, end: usize, funcs: []const FuncEntry) Error!void {
    std.debug.assert(start < end);
    if (code_regions_len == max_code_regions) return Error.RegistryFull;
    code_regions[code_regions_len] = .{ .start = start, .end = end, .funcs = funcs };
    code_regions_len += 1;
}

/// Unregister by region start (swap-remove). No-op when absent —
/// teardown paths may run after a failed/partial publish.
pub fn unregisterCodeRegion(start: usize) void {
    var i: usize = 0;
    while (i < code_regions_len) : (i += 1) {
        if (code_regions[i].start == start) {
            code_regions_len -= 1;
            code_regions[i] = code_regions[code_regions_len];
            return;
        }
    }
}

/// Register a guarded reservation `[base, end)`. Called by
/// `guarded_mem.reserve` — not by feature code.
pub fn registerGuarded(base: usize, end: usize) Error!void {
    std.debug.assert(base < end);
    if (guarded_regions_len == max_guarded_regions) return Error.RegistryFull;
    guarded_regions[guarded_regions_len] = .{ .base = base, .end = end };
    guarded_regions_len += 1;
}

/// Unregister by reservation base (swap-remove). No-op when absent.
pub fn unregisterGuarded(base: usize) void {
    var i: usize = 0;
    while (i < guarded_regions_len) : (i += 1) {
        if (guarded_regions[i].base == base) {
            guarded_regions_len -= 1;
            guarded_regions[i] = guarded_regions[guarded_regions_len];
            return;
        }
    }
}

/// Handler-side classification (async-signal-safe: pure reads, no
/// allocation). Returns the ABSOLUTE address of the oob trap stub of
/// the function containing `pc` when `fault_addr` lies in a guarded
/// reservation AND `pc` lies in a registered code region; else null.
pub fn classify(fault_addr: usize, pc: usize) ?usize {
    if (!isGuardedAddr(fault_addr)) return null;
    const region = findCodeRegion(pc) orelse return null;
    const rel: u32 = @intCast(pc - region.start);
    const entry = findFunc(region.funcs, rel) orelse return null;
    if (entry.oob_stub_off == FuncEntry.no_stub) return null;
    return region.start + entry.oob_stub_off;
}

fn isGuardedAddr(addr: usize) bool {
    for (guarded_regions[0..guarded_regions_len]) |g| {
        if (addr >= g.base and addr < g.end) return true;
    }
    return false;
}

fn findCodeRegion(pc: usize) ?*const CodeRegion {
    for (code_regions[0..code_regions_len]) |*r| {
        if (pc >= r.start and pc < r.end) return r;
    }
    return null;
}

/// Greatest entry with `code_off <= rel` (binary search; `funcs` is
/// sorted ascending by `code_off`).
fn findFunc(funcs: []const FuncEntry, rel: u32) ?*const FuncEntry {
    if (funcs.len == 0 or rel < funcs[0].code_off) return null;
    var lo: usize = 0;
    var hi: usize = funcs.len; // invariant: funcs[lo].code_off <= rel < funcs[hi].code_off (hi virtual)
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (funcs[mid].code_off <= rel) lo = mid else hi = mid;
    }
    return &funcs[lo];
}

// -----------------------------------------------------------
// Tests. The registry is global state — each test unregisters
// what it registers (mirrors real publish/teardown pairing).
// -----------------------------------------------------------

const testing = std.testing;

test "trap_registry: classify requires BOTH a guarded fault addr AND a JIT pc" {
    const funcs = [_]FuncEntry{
        .{ .code_off = 0x000, .oob_stub_off = 0x0f0 },
        .{ .code_off = 0x100, .oob_stub_off = 0x1f0 },
    };
    try registerGuarded(0x10_0000, 0x20_0000);
    defer unregisterGuarded(0x10_0000);
    try registerCodeRegion(0x50_0000, 0x50_1000, &funcs);
    defer unregisterCodeRegion(0x50_0000);

    // in-guard fault + pc in func 0 → func 0's stub.
    try testing.expectEqual(@as(?usize, 0x50_00f0), classify(0x10_8000, 0x50_0040));
    // pc in func 1 (incl. exactly at its first byte) → func 1's stub.
    try testing.expectEqual(@as(?usize, 0x50_01f0), classify(0x10_8000, 0x50_0100));
    try testing.expectEqual(@as(?usize, 0x50_01f0), classify(0x1f_ffff, 0x50_0fff));
    // fault addr NOT guarded → null even with a JIT pc.
    try testing.expectEqual(@as(?usize, null), classify(0x30_0000, 0x50_0040));
    // pc NOT in a code region → null even with a guarded fault addr.
    try testing.expectEqual(@as(?usize, null), classify(0x10_8000, 0x60_0000));
}

test "trap_registry: pc below the first function's code_off is unclassified (defensive)" {
    const funcs = [_]FuncEntry{.{ .code_off = 0x80, .oob_stub_off = 0xf0 }};
    try registerGuarded(0x10_0000, 0x20_0000);
    defer unregisterGuarded(0x10_0000);
    try registerCodeRegion(0x50_0000, 0x50_1000, &funcs);
    defer unregisterCodeRegion(0x50_0000);
    // pc inside the region but before funcs[0] (e.g. linker padding).
    try testing.expectEqual(@as(?usize, null), classify(0x10_8000, 0x50_0010));
    try testing.expectEqual(@as(?usize, 0x50_00f0), classify(0x10_8000, 0x50_0080));
}

test "trap_registry: a function without an oob stub stays unclassified (fail-safe)" {
    const funcs = [_]FuncEntry{
        .{ .code_off = 0x000, .oob_stub_off = FuncEntry.no_stub },
    };
    try registerGuarded(0x10_0000, 0x20_0000);
    defer unregisterGuarded(0x10_0000);
    try registerCodeRegion(0x50_0000, 0x50_1000, &funcs);
    defer unregisterCodeRegion(0x50_0000);

    try testing.expectEqual(@as(?usize, null), classify(0x10_8000, 0x50_0040));
}

test "trap_registry: unregister removes classification; unregistering absent keys is a no-op" {
    const funcs = [_]FuncEntry{.{ .code_off = 0, .oob_stub_off = 0x40 }};
    try registerGuarded(0x10_0000, 0x20_0000);
    try registerCodeRegion(0x50_0000, 0x50_1000, &funcs);
    try testing.expect(classify(0x10_0000, 0x50_0000) != null);

    unregisterCodeRegion(0x50_0000);
    try testing.expectEqual(@as(?usize, null), classify(0x10_0000, 0x50_0000));
    unregisterGuarded(0x10_0000);
    unregisterGuarded(0x10_0000); // absent — no-op
    unregisterCodeRegion(0xdead); // absent — no-op
}
