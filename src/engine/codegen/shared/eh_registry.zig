//! Process-global registry: live JIT instances' code-block address
//! ranges → their EH views, for cross-instance unwinding (ADR-0134 D2).
//!
//! The FP-walk unwinder (`unwind.walk`) resolves each frame's absolute
//! PC to its OWNING instance via this registry, so it consults THAT
//! instance's exception table + tag-identity map (`tag_ids`) — letting
//! a module-1 throw reach a module-2 catch. The owning instance is the
//! one whose per-Instance `CodeMap` (built from `rt.eh_code_map_entries`)
//! contains the PC; the registry just holds the live `*JitRuntime`s and
//! reuses each one's existing CodeMap for the containment test + the
//! abs→module-relative PC normalization.
//!
//! Scope: single-threaded (the spec runner / linker drives JIT
//! instantiation serially). A fixed-capacity table avoids any
//! allocation on the safepoint-free unwind path (ADR-0114 D5: no
//! allocator calls between teardown and landing). The caller
//! (`engine/setup` / the linker) `register`s an instance once its
//! `*JitRuntime` address is stable (heap-pinned) and `unregister`s it
//! at teardown. Overflow past the cap drops silently — the spec corpus
//! links at most a handful of instances per test.
//!
//! Zone 2 (`src/engine/codegen/shared/`).

const std = @import("std");

const jit_abi = @import("jit_abi.zig");
const code_map_mod = @import("code_map.zig");
const exception_table = @import("exception_table.zig");
const unwind = @import("unwind.zig");

const CAP = 64;
var rts: [CAP]?*jit_abi.JitRuntime = .{null} ** CAP;

/// Registered bridge-thunk arena address ranges (D-238 / ADR-0185 (b)).
/// A cross-module bridge thunk lives in the IMPORTER instance's
/// `thunk_arena`, outside every instance's per-function CodeMap. The
/// x86_64 frame-chain sniff must still recognize a thunk-return address
/// as valid code to disambiguate the callee's prologue layout, so the
/// arenas are registered globally here (the importer's arena is not the
/// throwing instance's view).
const ThunkRange = struct { start: usize, len: usize };
var thunk_ranges: [CAP]?ThunkRange = .{null} ** CAP;

/// Register a live instance (idempotent). Address must be stable for
/// the registered lifetime (heap-pinned per D-225's exporter contract).
pub fn register(rt: *jit_abi.JitRuntime) void {
    for (rts) |slot| if (slot == rt) return;
    for (&rts) |*slot| if (slot.* == null) {
        slot.* = rt;
        return;
    };
    // Full → drop. Bounded by the spec-runner's per-test instance count.
}

/// Remove an instance at teardown (no-op if absent).
pub fn unregister(rt: *jit_abi.JitRuntime) void {
    for (&rts) |*slot| if (slot.* == rt) {
        slot.* = null;
        return;
    };
}

/// Register a bridge-thunk arena's address range (idempotent on `start`).
/// Called at JIT finalize once the arena page is mapped (`setup.zig`).
pub fn registerThunkArena(start: usize, len: usize) void {
    for (thunk_ranges) |slot| if (slot) |r| {
        if (r.start == start) return;
    };
    for (&thunk_ranges) |*slot| if (slot.* == null) {
        slot.* = .{ .start = start, .len = len };
        return;
    };
    // Full → drop (bounded by per-test instance count, like `rts`).
}

/// Remove a thunk arena at teardown (no-op if absent).
pub fn unregisterThunkArena(start: usize) void {
    for (&thunk_ranges) |*slot| if (slot.*) |r| {
        if (r.start == start) {
            slot.* = null;
            return;
        }
    };
}

/// True if `addr` falls inside any registered bridge-thunk arena.
pub fn isThunkAddr(addr: usize) bool {
    for (thunk_ranges) |slot| if (slot) |r| {
        if (addr >= r.start and addr < r.start + r.len) return true;
    };
    return false;
}

/// True if `abs_pc` is a valid JIT code address ANYWHERE in the live EH
/// world — any registered instance's CodeMap OR any registered bridge-thunk
/// arena (ADR-0185 (c)). The x86_64 frame-chain sniff uses this (not a
/// single instance's CodeMap) to disambiguate a frame's prologue layout,
/// because a cross-instance unwind walks frames belonging to other
/// instances + the importer's bridge thunk.
pub fn isCodeAddr(abs_pc: usize) bool {
    if (isThunkAddr(abs_pc)) return true;
    for (rts) |slot| {
        const rt = slot orelse continue;
        const cmap = cmapFor(rt);
        if (cmap.entries.len == 0) continue;
        switch (cmap.lookup(abs_pc)) {
            .inside => return true,
            .outside => {},
        }
    }
    return false;
}

/// Drop all registrations (test isolation).
pub fn reset() void {
    rts = .{null} ** CAP;
    thunk_ranges = .{null} ** CAP;
}

fn cmapFor(rt: *const jit_abi.JitRuntime) code_map_mod.CodeMap {
    return .{ .entries = if (rt.eh_code_map_entries) |p| p[0..rt.eh_code_map_count] else &.{} };
}

fn tableFor(rt: *const jit_abi.JitRuntime) exception_table.ExceptionTable {
    return .{
        .entries = if (rt.eh_table_entries) |p| p[0..rt.eh_table_count] else &.{},
        .tag_ids = if (rt.tag_ids_ptr) |p| p[0..rt.tag_ids_count] else null,
    };
}

/// `unwind.InstanceResolver.resolve` impl: find the registered instance
/// whose CodeMap contains `abs_pc` and return its table + the PC
/// normalized to that instance's module space. `null` when no instance
/// owns the PC (e.g. a cross-module bridge-thunk frame → pass-through).
pub fn resolve(abs_pc: usize, ctx: ?*anyopaque) ?unwind.ResolvedFrame {
    _ = ctx;
    for (rts) |slot| {
        const rt = slot orelse continue;
        const cmap = cmapFor(rt);
        if (cmap.entries.len == 0) continue;
        switch (cmap.lookup(abs_pc)) {
            .inside => return .{
                .table = tableFor(rt),
                .module_pc = code_map_mod.toModuleRelativePc(&cmap, abs_pc),
            },
            .outside => {},
        }
    }
    return null;
}

/// Build the `InstanceResolver` the trampoline passes to `unwind.walk`.
pub fn resolver() unwind.InstanceResolver {
    return .{ .resolve = resolve, .ctx = null };
}

/// Return the CodeMap of the registered instance that owns `abs_pc`, or
/// null if none. The trampoline uses this for the `.handler` SP-restore
/// + landing-pad computation when the catching frame is in a DIFFERENT
/// instance than the throwing one (cross-instance catch): the handler's
/// `start_addr` + `frame_bytes` must come from the CATCHING instance's
/// CodeMap, not the throwing one's (ADR-0134 D2).
pub fn codeMapForPc(abs_pc: usize) ?code_map_mod.CodeMap {
    for (rts) |slot| {
        const rt = slot orelse continue;
        const cmap = cmapFor(rt);
        if (cmap.entries.len == 0) continue;
        switch (cmap.lookup(abs_pc)) {
            .inside => return cmap,
            .outside => {},
        }
    }
    return null;
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "eh_registry: resolve picks the instance whose CodeMap contains the PC" {
    reset();
    defer reset();

    // Two synthetic instances. A's code block at 0x10000; B's at 0x20000.
    var a_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0 }};
    var b_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x20000, .len = 0x100, .func_idx = 0 }};
    const a_ids = [_]u64{0xAA};
    const b_ids = [_]u64{0xAA};

    // Only the EH-view fields `resolve` reads need values; the rest of
    // the extern struct is irrelevant to the registry (left undefined).
    var a_rt: jit_abi.JitRuntime = undefined;
    a_rt.eh_code_map_entries = &a_cm;
    a_rt.eh_code_map_count = 1;
    a_rt.eh_table_entries = null;
    a_rt.eh_table_count = 0;
    a_rt.tag_ids_ptr = &a_ids;
    a_rt.tag_ids_count = 1;
    var b_rt: jit_abi.JitRuntime = undefined;
    b_rt.eh_code_map_entries = &b_cm;
    b_rt.eh_code_map_count = 1;
    b_rt.eh_table_entries = null;
    b_rt.eh_table_count = 0;
    b_rt.tag_ids_ptr = &b_ids;
    b_rt.tag_ids_count = 1;

    register(&a_rt);
    register(&b_rt);
    register(&a_rt); // idempotent

    // PC in A → A's table + module_pc relative to A's block base.
    const ra = resolve(0x10042, null).?;
    try testing.expectEqual(@as(u32, 0x42), ra.module_pc);
    try testing.expectEqual(@as(?[]const u64, &a_ids), ra.table.tag_ids);

    // PC in B → B's instance.
    const rb = resolve(0x20010, null).?;
    try testing.expectEqual(@as(u32, 0x10), rb.module_pc);
    try testing.expectEqual(@as(?[]const u64, &b_ids), rb.table.tag_ids);

    // PC in neither (a thunk-arena address) → pass-through null.
    try testing.expectEqual(@as(?unwind.ResolvedFrame, null), resolve(0x90000, null));

    // After unregister, A's PC no longer resolves.
    unregister(&a_rt);
    try testing.expectEqual(@as(?unwind.ResolvedFrame, null), resolve(0x10042, null));
}

test "eh_registry: thunk-arena range registration + isThunkAddr (ADR-0185 b)" {
    reset();
    defer reset();

    registerThunkArena(0x50000, 0x80);
    registerThunkArena(0x50000, 0x80); // idempotent on start
    registerThunkArena(0x60000, 0x40);

    try testing.expect(isThunkAddr(0x50000)); // first byte
    try testing.expect(isThunkAddr(0x5007F)); // last byte in range
    try testing.expect(!isThunkAddr(0x50080)); // one past end → outside
    try testing.expect(!isThunkAddr(0x4FFFF)); // one before start → outside
    try testing.expect(isThunkAddr(0x60020)); // second arena

    unregisterThunkArena(0x50000);
    try testing.expect(!isThunkAddr(0x50000)); // gone
    try testing.expect(isThunkAddr(0x60020)); // other arena intact
}

test "eh_registry: isCodeAddr spans all instances' CodeMaps + thunk ranges (ADR-0185 c)" {
    reset();
    defer reset();

    var a_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x10000, .len = 0x100, .func_idx = 0 }};
    var b_cm = [_]code_map_mod.Entry{.{ .start_addr = 0x20000, .len = 0x100, .func_idx = 0 }};
    var a_rt: jit_abi.JitRuntime = undefined;
    a_rt.eh_code_map_entries = &a_cm;
    a_rt.eh_code_map_count = 1;
    var b_rt: jit_abi.JitRuntime = undefined;
    b_rt.eh_code_map_entries = &b_cm;
    b_rt.eh_code_map_count = 1;
    register(&a_rt);
    register(&b_rt);
    registerThunkArena(0x50000, 0x80);

    // The load-bearing D-238 property: a PC in ANY instance's CodeMap OR
    // any thunk arena is "code", even though no single instance's CodeMap
    // contains all three — the single-CodeMap sniff could not see this.
    try testing.expect(isCodeAddr(0x10042)); // instance A's body
    try testing.expect(isCodeAddr(0x20010)); // instance B's body
    try testing.expect(isCodeAddr(0x50040)); // a bridge-thunk return addr
    try testing.expect(!isCodeAddr(0x90000)); // host stack / not code → false
}
