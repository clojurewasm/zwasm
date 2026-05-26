//! Per-Instance JIT code map — translates absolute return
//! addresses (saved LR on AAPCS64 / saved RIP on SysV/Win64)
//! into module-relative PCs for `ExceptionTable.lookup`
//! (ADR-0114 D5).
//!
//! Built at JIT link time once per Runtime/Instance: as the
//! linker assigns mapped code addresses to each compiled
//! function, it calls `Builder.add` with the function's
//! `{ start_addr, len, func_idx }`. After all functions land,
//! `Builder.finalize` sorts by `start_addr` so `CodeMap.lookup`
//! can binary-search.
//!
//! Lookup algorithm:
//!   1. Binary-search for the largest entry whose
//!      `start_addr <= ret_addr`.
//!   2. Verify `ret_addr < start_addr + len`. If outside the
//!      function's range, the address is non-JIT (host
//!      function, OS trampoline, etc.) — return `.outside`.
//!   3. Otherwise return `{ relative_pc = ret_addr - start_addr,
//!      func_idx }`.
//!
//! The `outside` result lets the unwinder keep walking across
//! non-JIT frames: `normalizeForUnwind` returns
//! `std.math.maxInt(u32)` for `.outside` so
//! `ExceptionTable.lookup` falls through (no handler entry's
//! `pc_range` covers `maxInt(u32)`), the unwinder advances to
//! the next frame.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const frame_chain_adapter = @import("frame_chain_adapter.zig");

/// One JIT-emitted function's address range. `frame_bytes` is
/// the prologue's `SUB SP, SP, #N` (arm64) / `SUB RSP, #N`
/// (x86_64) frame-allocation size — the EH SP-restore path
/// applies this same subtraction after `MOV SP, X29` (arm64)
/// / `MOV RSP, RBP` (x86_64) to recover the handler frame's
/// prologue-completion SP boundary.
pub const Entry = struct {
    start_addr: usize,
    len: u32,
    func_idx: u32,
    frame_bytes: u32 = 0,
};

/// Lookup outcome.
pub const Lookup = union(enum) {
    /// `ret_addr` is inside a JIT-compiled function.
    inside: struct {
        relative_pc: u32,
        func_idx: u32,
        /// Start address of the containing function — needed by the
        /// EH handler-dispatch path to convert `landing_pad_pc`
        /// (module-relative) to an absolute target for the JMP.
        start_addr: usize,
        /// Prologue frame allocation bytes (the `SUB SP, SP, #N` the
        /// catching function emitted). The EH landing path computes
        /// `new_sp = handler_fp - frame_bytes` before the JMP.
        frame_bytes: u32,
    },
    /// `ret_addr` is not in any JIT-compiled function (host
    /// frame / OS frame / corrupted). The unwinder should
    /// fall through and walk to the next frame.
    outside,
};

pub const CodeMap = struct {
    /// Entries sorted by ascending `start_addr` (enforced by
    /// `Builder.finalize`).
    entries: []const Entry,

    pub fn lookup(self: CodeMap, ret_addr: usize) Lookup {
        if (self.entries.len == 0) return .outside;
        // Binary search for the largest start_addr <= ret_addr.
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].start_addr <= ret_addr) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // After the loop, `lo` is the count of entries with
        // start_addr <= ret_addr. The candidate (if any) is
        // entries[lo - 1].
        if (lo == 0) return .outside;
        const e = self.entries[lo - 1];
        if (ret_addr >= e.start_addr + e.len) return .outside;
        const rel: u32 = @intCast(ret_addr - e.start_addr);
        return .{ .inside = .{
            .relative_pc = rel,
            .func_idx = e.func_idx,
            .start_addr = e.start_addr,
            .frame_bytes = e.frame_bytes,
        } };
    }
};

/// Sentinel returned by `normalizeForUnwind` for non-JIT
/// frames: no `ExceptionTable.HandlerEntry` covers
/// `maxInt(u32)` (validators reject `pc_end == maxInt(u32)`
/// implicitly via the bounded JIT-emit byte counts), so the
/// unwinder's lookup falls through and walks to the next
/// frame.
pub const non_jit_pc_sentinel: u32 = std.math.maxInt(u32);

/// Translate an absolute address into a module-relative PC
/// (= `addr - block_addr`) for `ExceptionTable.lookup`. Returns
/// `non_jit_pc_sentinel` when `map` is empty or `addr` falls
/// outside any function's range. D-183/D-184 ground truth:
/// `HandlerEntry.pc_start / pc_end` are stored module-relative
/// (post-`collectModuleTable` shift); the FP-walk unwinder
/// must call `ExceptionTable.lookup` with the matching
/// module-relative PC so range checks resolve correctly.
///
/// `block_addr` is derived from `entries[0].start_addr` — the
/// first defined function's start_addr equals the JitBlock's
/// base (defined functions are sequential starting at offset 0
/// within the JitBlock; see `buildCodeMapEntries`).
pub fn toModuleRelativePc(map: *const CodeMap, addr: usize) u32 {
    if (map.entries.len == 0) return non_jit_pc_sentinel;
    switch (map.lookup(addr)) {
        .outside => return non_jit_pc_sentinel,
        .inside => {},
    }
    const block_addr = map.entries[0].start_addr;
    return @intCast(addr - block_addr);
}

/// `frame_chain_adapter.NormalizePcFn` adapter. `ctx` MUST be a
/// `*const CodeMap`. Thin wrapper around `toModuleRelativePc`.
pub fn normalizeForUnwind(ret_addr: usize, ctx: ?*anyopaque) u32 {
    const map: *const CodeMap = @ptrCast(@alignCast(ctx.?));
    return toModuleRelativePc(map, ret_addr);
}

/// Convenience: build a `frame_chain_adapter.Context` whose
/// `normalize` is `normalizeForUnwind` and whose `normalize_ctx`
/// points at the given `CodeMap`. The trampoline calls this
/// once per unwind.
pub fn adapterContextFor(map: *const CodeMap) frame_chain_adapter.Context {
    return .{
        .normalize = normalizeForUnwind,
        .normalize_ctx = @ptrCast(@constCast(map)),
    };
}

/// Build-time accumulator. The JIT linker instantiates one
/// per Runtime/Instance and calls `add` once per compiled
/// function; `finalize` sorts by `start_addr` for the
/// binary search.
pub const Builder = struct {
    entries: std.ArrayList(Entry),

    pub const empty: Builder = .{ .entries = .empty };

    pub fn deinit(self: *Builder, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn add(
        self: *Builder,
        allocator: std.mem.Allocator,
        entry: Entry,
    ) !void {
        std.debug.assert(entry.len > 0);
        try self.entries.append(allocator, entry);
    }

    /// Sort entries by ascending `start_addr` and freeze into a
    /// `CodeMap`. The returned map aliases the builder's
    /// allocation; caller owns lifetime via `deinit`.
    pub fn finalize(self: *Builder) CodeMap {
        std.mem.sort(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.start_addr < b.start_addr;
            }
        }.lessThan);
        return .{ .entries = self.entries.items };
    }
};

// ---------------------------------------------------------------------
// Unit tests — pure-data lookup; no per-arch dependency.
// ---------------------------------------------------------------------

const testing = std.testing;

test "code_map: empty map — lookup always returns .outside" {
    const m: CodeMap = .{ .entries = &.{} };
    try testing.expectEqual(Lookup.outside, m.lookup(0));
    try testing.expectEqual(Lookup.outside, m.lookup(0x1000));
}

test "code_map: single function — lookup returns relative_pc inside range" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x1000, .len = 256, .func_idx = 0 });
    const m = b.finalize();

    const hit = m.lookup(0x1050);
    try testing.expect(hit == .inside);
    try testing.expectEqual(@as(u32, 0x50), hit.inside.relative_pc);
    try testing.expectEqual(@as(u32, 0), hit.inside.func_idx);
}

test "code_map: ret_addr at start_addr → relative_pc=0" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x2000, .len = 100, .func_idx = 5 });
    const m = b.finalize();

    const hit = m.lookup(0x2000);
    try testing.expect(hit == .inside);
    try testing.expectEqual(@as(u32, 0), hit.inside.relative_pc);
    try testing.expectEqual(@as(u32, 5), hit.inside.func_idx);
}

test "code_map: ret_addr at start_addr + len (boundary) → .outside (half-open range)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x3000, .len = 100, .func_idx = 0 });
    const m = b.finalize();

    // Just past the function's last byte → outside.
    try testing.expectEqual(Lookup.outside, m.lookup(0x3000 + 100));
    // Just inside the last byte → still inside.
    const last = m.lookup(0x3000 + 99);
    try testing.expect(last == .inside);
    try testing.expectEqual(@as(u32, 99), last.inside.relative_pc);
}

test "code_map: ret_addr below any function start → .outside" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x5000, .len = 100, .func_idx = 0 });
    const m = b.finalize();

    try testing.expectEqual(Lookup.outside, m.lookup(0x4000));
    try testing.expectEqual(Lookup.outside, m.lookup(0x4FFF));
}

test "code_map: ret_addr in gap between functions → .outside" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x1000, .len = 50, .func_idx = 0 });
    try b.add(testing.allocator, .{ .start_addr = 0x2000, .len = 50, .func_idx = 1 });
    const m = b.finalize();

    // Between f0 [0x1000, 0x1032) and f1 [0x2000, 0x2032).
    try testing.expectEqual(Lookup.outside, m.lookup(0x1500));
    // Inside f1.
    const hit = m.lookup(0x2010);
    try testing.expect(hit == .inside);
    try testing.expectEqual(@as(u32, 0x10), hit.inside.relative_pc);
    try testing.expectEqual(@as(u32, 1), hit.inside.func_idx);
}

test "code_map: Builder.finalize sorts entries (out-of-order add works)" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    // Add in reverse order — finalize must sort.
    try b.add(testing.allocator, .{ .start_addr = 0x3000, .len = 50, .func_idx = 2 });
    try b.add(testing.allocator, .{ .start_addr = 0x1000, .len = 50, .func_idx = 0 });
    try b.add(testing.allocator, .{ .start_addr = 0x2000, .len = 50, .func_idx = 1 });
    const m = b.finalize();

    try testing.expectEqual(@as(usize, 0x1000), m.entries[0].start_addr);
    try testing.expectEqual(@as(usize, 0x2000), m.entries[1].start_addr);
    try testing.expectEqual(@as(usize, 0x3000), m.entries[2].start_addr);

    // Lookup still works after sorting.
    const hit = m.lookup(0x2025);
    try testing.expect(hit == .inside);
    try testing.expectEqual(@as(u32, 1), hit.inside.func_idx);
}

test "code_map: binary search correctness on 8-entry map" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try b.add(testing.allocator, .{
            .start_addr = 0x10000 + i * 0x1000,
            .len = 0x200,
            .func_idx = i,
        });
    }
    const m = b.finalize();

    // Probe each function.
    var probe: u32 = 0;
    while (probe < 8) : (probe += 1) {
        const addr: usize = 0x10000 + probe * 0x1000 + 0x80;
        const hit = m.lookup(addr);
        try testing.expect(hit == .inside);
        try testing.expectEqual(@as(u32, 0x80), hit.inside.relative_pc);
        try testing.expectEqual(probe, hit.inside.func_idx);
    }

    // Probe gaps (each function is 0x200 long; gap until next at +0x1000).
    var gap: u32 = 0;
    while (gap < 7) : (gap += 1) {
        const addr: usize = 0x10000 + gap * 0x1000 + 0x500; // mid-gap
        try testing.expectEqual(Lookup.outside, m.lookup(addr));
    }
}

test "code_map: toModuleRelativePc — multi-function, second func's addrs → module-relative (D-183)" {
    // D-183 load-bearing contract: for multi-function modules,
    // `toModuleRelativePc` returns `addr - first_func.start_addr`
    // (= module-relative), NOT `addr - containing_func.start_addr`
    // (= function-relative). HandlerEntries are stored
    // module-relative post-collectModuleTable shift; the
    // unwinder's `ExceptionTable.lookup` consumes module-relative
    // PC. This test pins the contract.
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x10000, .len = 0x80, .func_idx = 0 });
    try b.add(testing.allocator, .{ .start_addr = 0x10080, .len = 0x80, .func_idx = 1 });
    const m = b.finalize();

    // Addr inside func 0 (the first; block_addr = func0.start_addr).
    // module-relative = 0x10042 - 0x10000 = 0x42.
    try testing.expectEqual(@as(u32, 0x42), toModuleRelativePc(&m, 0x10042));
    // Addr inside func 1: module-relative = 0x100C0 - 0x10000 = 0xC0
    // (NOT function-relative 0x40). This is the value the
    // unwinder feeds `ExceptionTable.lookup` for func1's PC.
    try testing.expectEqual(@as(u32, 0xC0), toModuleRelativePc(&m, 0x100C0));
    // Outside both → sentinel.
    try testing.expectEqual(non_jit_pc_sentinel, toModuleRelativePc(&m, 0x20000));
    // Empty map → sentinel (defensive).
    var b2: Builder = .empty;
    defer b2.deinit(testing.allocator);
    const empty_m = b2.finalize();
    try testing.expectEqual(non_jit_pc_sentinel, toModuleRelativePc(&empty_m, 0x10042));
}

test "code_map: normalizeForUnwind — inside → relative_pc" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x4000, .len = 200, .func_idx = 0 });
    const m = b.finalize();

    const rel = normalizeForUnwind(0x4042, @ptrCast(@constCast(&m)));
    try testing.expectEqual(@as(u32, 0x42), rel);
}

test "code_map: normalizeForUnwind — outside → non_jit_pc_sentinel" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x4000, .len = 200, .func_idx = 0 });
    const m = b.finalize();

    const rel = normalizeForUnwind(0x8000, @ptrCast(@constCast(&m)));
    try testing.expectEqual(non_jit_pc_sentinel, rel);
}

test "code_map: Entry.frame_bytes defaults to 0 for back-compat" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x9000, .len = 50, .func_idx = 0 });
    const m = b.finalize();
    try testing.expectEqual(@as(u32, 0), m.entries[0].frame_bytes);
}

test "code_map: Entry.frame_bytes round-trips when explicitly set" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{
        .start_addr = 0xA000,
        .len = 100,
        .func_idx = 0,
        .frame_bytes = 64,
    });
    const m = b.finalize();
    try testing.expectEqual(@as(u32, 64), m.entries[0].frame_bytes);

    const hit = m.lookup(0xA042);
    try testing.expect(hit == .inside);
    try testing.expectEqual(@as(u32, 0x42), hit.inside.relative_pc);
}

test "code_map: adapterContextFor produces a Context the adapter can consume" {
    var b: Builder = .empty;
    defer b.deinit(testing.allocator);
    try b.add(testing.allocator, .{ .start_addr = 0x6000, .len = 100, .func_idx = 3 });
    const m = b.finalize();

    const ctx = adapterContextFor(&m);
    const rel = ctx.normalize(0x6025, ctx.normalize_ctx);
    try testing.expectEqual(@as(u32, 0x25), rel);
}
