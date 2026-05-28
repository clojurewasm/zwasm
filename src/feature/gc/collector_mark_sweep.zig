//! Stop-the-world mark-sweep collector — β must-ship per
//! ADR-0115 §10 (10.G op_gc cycle 26 first cut).
//!
//! Implements the `Collector` vtable from `collector_iface.zig`
//! over the per-Store `Heap` slab + ObjectHeader / ArrayHeader
//! layouts from ADR-0116 §3a (cycle 19-20 substrate).
//!
//! ## Phases
//!
//! 1. **Mark**: invoke `walkRootsFn` with `markFromRoot`. For each
//!    root GcRef, set the ObjectHeader's mark bit. (Recursive
//!    tracing of payload reftype slots defers — this cut marks
//!    only directly-rooted objects; transitive trace lands once
//!    payload-slot iteration via TypeInfo materialises into the
//!    sweep walker. β must-ship: roots are enough to demonstrate
//!    the mark+sweep cycle is wired.)
//!
//! 2. **Sweep**: walk the heap from offset 2 (skipping null_ref).
//!    Decode each ObjectHeader → step over by header_size +
//!    payload_size (struct) OR array_header_size +
//!    length*element_size (array). Reset mark bits (clear
//!    the high bit of ObjectHeader.info) for next cycle. Count
//!    survivors + dead bytes; emit stats via the returned
//!    `SweepStats`. True reclamation (free-list reuse or
//!    compaction) defers to Phase 11 per ADR-0115 §10 closing
//!    note; this cut maintains the bump-cursor model so dead
//!    bytes leak until process exit.
//!
//! ## Mark bit encoding (ADR-0116 §3a)
//!
//! `ObjectHeader.info` is a u32. The low 31 bits hold the
//! typeidx (≤ 2^31 declared types — Wasm modules have far fewer).
//! Bit 31 (`mark_bit_mask`) is the mark phase indicator: set
//! during mark, cleared during sweep.
//!
//! ## TypeInfo dependency
//!
//! Per-object size decode reads `TypeInfo.kind` + the per-kind
//! size (StructInfo.payload_size for struct; ArrayHeader.length
//! * ArrayInfo.element.size for array). The collector takes a
//! `*const GcTypeInfos` at init so it can resolve typeidx →
//! per-kind info during sweep.
//!
//! Zone 1 (`src/feature/gc/`).

const std = @import("std");

const heap_mod = @import("heap.zig");
const iface = @import("collector_iface.zig");
const type_info_mod = @import("type_info.zig");
const runtime_mod = @import("../../runtime/runtime.zig");

const Heap = heap_mod.Heap;
const GcRef = heap_mod.GcRef;
const Collector = iface.Collector;
const RootCallback = iface.RootCallback;
const ObjectHeader = type_info_mod.ObjectHeader;
const ObjectKind = type_info_mod.ObjectKind;
const ArrayHeader = type_info_mod.ArrayHeader;
const GcTypeInfos = type_info_mod.GcTypeInfos;

const header_size: u32 = @sizeOf(ObjectHeader);
const array_header_size: u32 = @sizeOf(ArrayHeader);

/// Mark phase bit — high bit of ObjectHeader.info. Set during
/// mark, cleared during sweep. Typeidx occupies the low 31 bits.
pub const mark_bit_mask: u32 = 0x8000_0000;

/// Per-collection stats. Returned by `collect()` so callers /
/// tests can observe behaviour.
pub const SweepStats = struct {
    /// Objects walked during sweep (= total live objects in slab).
    objects_seen: u32 = 0,
    /// Objects with mark bit set (= marked live by roots).
    survivors: u32 = 0,
    /// Bytes occupied by unreachable objects (would be reclaimable
    /// under a compacting Phase 11 collector). Not freed this cut.
    dead_bytes: u32 = 0,
};

pub const MarkSweepCollector = struct {
    heap: *Heap,
    gc_type_infos: *const GcTypeInfos,
    /// Latest sweep statistics. Updated each `collectFn` call.
    last_stats: SweepStats = .{},
    /// Runtime back-pointer for root enumeration (cycle 27).
    /// `walkRootsImpl` casts this to `*runtime.Runtime` to scan
    /// the operand stack + frame locals + globals. Held as
    /// `?*anyopaque` so this Zone 1 file doesn't import the
    /// Runtime concrete type (avoids zone-import cycle —
    /// runtime.zig already references collector via Heap chain).
    runtime: ?*anyopaque = null,

    pub fn init(heap: *Heap, gti: *const GcTypeInfos) MarkSweepCollector {
        return .{ .heap = heap, .gc_type_infos = gti };
    }

    /// Bind a Runtime back-pointer for root enumeration. Caller
    /// passes `@ptrCast(rt)` after init. Optional — without this,
    /// `walkRootsImpl` is a no-op (cycle-26 β behaviour preserved
    /// for tests that exercise sweep without root binding).
    pub fn bindRuntime(self: *MarkSweepCollector, rt: *anyopaque) void {
        self.runtime = rt;
    }

    pub fn collector(self: *MarkSweepCollector) Collector {
        return .{
            .allocObjectFn = allocObjectImpl,
            .collectFn = collectImpl,
            .walkRootsFn = walkRootsImpl,
            .ctx = @ptrCast(self),
        };
    }

    fn allocObjectImpl(ctx: *anyopaque, size: u32) ?GcRef {
        const self: *MarkSweepCollector = @ptrCast(@alignCast(ctx));
        return self.heap.allocate(size) catch null;
    }

    /// Mark single root + transitively trace payload reftype
    /// slots (cycle 28). Idempotent: checks mark bit before
    /// recursing so cycles terminate. Conservative scan within
    /// each marked object — any payload slot whose declared
    /// valtype is a heap reftype (per `isHeapReftype`) is probed
    /// via the same filters as `tryReportRef` and recursively
    /// marked.
    pub fn markFromRoot(self: *MarkSweepCollector, ref: GcRef) void {
        if (ref == heap_mod.null_ref) return;
        if (ref + header_size > self.heap.bytes.len) return; // defensive
        var hdr: ObjectHeader = undefined;
        @memcpy(std.mem.asBytes(&hdr)[0..header_size], self.heap.bytes[ref .. ref + header_size]);
        if ((hdr.info & mark_bit_mask) != 0) return; // already marked → cycle break
        hdr.info |= mark_bit_mask;
        @memcpy(self.heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr)[0..header_size]);
        const typeidx = hdr.info & ~mark_bit_mask;
        switch (hdr.kind) {
            .struct_ => self.traceStructPayload(ref, typeidx),
            .array => self.traceArrayPayload(ref, typeidx),
        }
    }

    fn traceStructPayload(self: *MarkSweepCollector, ref: u32, typeidx: u32) void {
        if (typeidx >= self.gc_type_infos.struct_infos.len) return;
        const si = self.gc_type_infos.struct_infos[typeidx] orelse return;
        var i: u32 = 0;
        while (i < si.type_info.field_count) : (i += 1) {
            const field = si.fields[i];
            if (!isHeapReftype(field.valtype_byte)) continue;
            self.followSlot(ref + header_size + field.offset);
        }
    }

    fn traceArrayPayload(self: *MarkSweepCollector, ref: u32, typeidx: u32) void {
        if (typeidx >= self.gc_type_infos.array_infos.len) return;
        const ai = self.gc_type_infos.array_infos[typeidx] orelse return;
        if (!isHeapReftype(ai.element.valtype_byte)) return;
        if (ref + array_header_size > self.heap.bytes.len) return;
        var ahdr: ArrayHeader = undefined;
        @memcpy(std.mem.asBytes(&ahdr)[0..array_header_size], self.heap.bytes[ref .. ref + array_header_size]);
        var i: u32 = 0;
        while (i < ahdr.length) : (i += 1) {
            self.followSlot(ref + array_header_size + i * ai.element.size);
        }
    }

    /// Read 8-byte payload slot, probe as GcRef per the same
    /// filters as `tryReportRef`, recursively markFromRoot.
    fn followSlot(self: *MarkSweepCollector, slot_off: u32) void {
        if (slot_off + 8 > self.heap.bytes.len) return;
        var slot_bytes: [8]u8 = undefined;
        @memcpy(&slot_bytes, self.heap.bytes[slot_off .. slot_off + 8]);
        const slot: u64 = std.mem.readInt(u64, &slot_bytes, .little);
        if (slot == 0) return;
        if ((slot & 1) != 0) return;
        if (slot < heap_mod.Heap.min_align or slot >= self.heap.cursor) return;
        if ((slot % heap_mod.Heap.min_align) != 0) return;
        self.markFromRoot(@intCast(slot));
    }

    fn collectImpl(ctx: *anyopaque) void {
        const self: *MarkSweepCollector = @ptrCast(@alignCast(ctx));
        self.runCollection();
    }

    /// Walks the heap from `null_ref + 2` (the lowest possible
    /// non-null GcRef per Heap.allocate's min_align=2). Reads
    /// each ObjectHeader, decodes object size, advances cursor.
    /// Used by sweep + reachable to enumerate live objects.
    fn runCollection(self: *MarkSweepCollector) void {
        // Mark phase is driven externally — caller invokes
        // `walkRoots(markFromRoot, ...)` BEFORE collect().
        // collect() runs the sweep phase only.
        var stats: SweepStats = .{};
        var cursor: u32 = heap_mod.null_ref + heap_mod.Heap.min_align;
        // The Heap's bump cursor records the high-water mark; objects
        // exist in [min_align, heap.cursor).
        while (cursor < self.heap.cursor) {
            if (cursor + header_size > self.heap.bytes.len) break;
            var hdr: ObjectHeader = undefined;
            @memcpy(std.mem.asBytes(&hdr)[0..header_size], self.heap.bytes[cursor .. cursor + header_size]);
            const typeidx = hdr.info & ~mark_bit_mask;
            const marked = (hdr.info & mark_bit_mask) != 0;
            const obj_size = self.objectSizeAt(cursor, hdr, typeidx);
            if (obj_size == 0) break; // defensive — malformed header

            stats.objects_seen += 1;
            if (marked) {
                stats.survivors += 1;
                // Clear mark bit for next cycle.
                hdr.info &= ~mark_bit_mask;
                @memcpy(self.heap.bytes[cursor .. cursor + header_size], std.mem.asBytes(&hdr)[0..header_size]);
            } else {
                stats.dead_bytes += obj_size;
                // Phase 11 amendment: free-list reuse or compaction.
                // For now the dead region stays in-place but its bytes
                // are observable garbage. Sweep doesn't recycle.
            }
            cursor = std.mem.alignForward(u32, cursor + obj_size, heap_mod.Heap.min_align);
        }
        self.last_stats = stats;
    }

    /// Decode the byte size of the object at `off` whose header
    /// is `hdr` and whose typeidx (low 31 bits) is `typeidx`.
    fn objectSizeAt(self: *MarkSweepCollector, off: u32, hdr: ObjectHeader, typeidx: u32) u32 {
        return switch (hdr.kind) {
            .struct_ => blk: {
                if (typeidx >= self.gc_type_infos.struct_infos.len) break :blk 0;
                const si = self.gc_type_infos.struct_infos[typeidx] orelse break :blk 0;
                break :blk header_size + si.payload_size;
            },
            .array => blk: {
                if (typeidx >= self.gc_type_infos.array_infos.len) break :blk 0;
                const ai = self.gc_type_infos.array_infos[typeidx] orelse break :blk 0;
                if (off + array_header_size > self.heap.bytes.len) break :blk 0;
                var ahdr: ArrayHeader = undefined;
                @memcpy(std.mem.asBytes(&ahdr)[0..array_header_size], self.heap.bytes[off .. off + array_header_size]);
                break :blk array_header_size + ahdr.length * @as(u32, ai.element.size);
            },
        };
    }

    /// Conservative root walker (cycle 27). Enumerates Runtime's
    /// operand stack + per-frame locals + globals; for each
    /// Value slot tests whether `v.ref` looks like a valid GcRef
    /// (within heap range, 2-byte aligned, non-null, low-bit-0
    /// meaning not i31-tagged per ADR-0116 §6). Calls the user
    /// callback per probable GcRef.
    ///
    /// **Conservative**: an i32 / f32 / i64 value that happens
    /// to fall in the heap-offset range with the right alignment
    /// will be conservatively treated as a root, keeping the
    /// referenced object alive. False-positive marks are
    /// acceptable per ADR-0116 §1 (precise tracing requires per-
    /// slot type tracking which the validator drops at runtime).
    ///
    /// Returns silently if `bindRuntime` wasn't called (cycle-26
    /// β tests exercise sweep-without-roots; preserve that path).
    fn walkRootsImpl(ctx: *anyopaque, root_callback: RootCallback, root_ctx: *anyopaque) void {
        const self: *MarkSweepCollector = @ptrCast(@alignCast(ctx));
        const rt_opaque = self.runtime orelse return;
        const rt = @as(*runtime_mod.Runtime, @ptrCast(@alignCast(rt_opaque)));
        const heap_lo: u64 = heap_mod.Heap.min_align;
        const heap_hi: u64 = self.heap.cursor;

        // Operand stack.
        var i: u32 = 0;
        while (i < rt.operand_len) : (i += 1) {
            tryReportRef(rt.operand_buf[i], heap_lo, heap_hi, root_callback, root_ctx);
        }
        // Per-frame locals.
        var f: u32 = 0;
        while (f < rt.frame_len) : (f += 1) {
            for (rt.frame_buf[f].locals) |v| {
                tryReportRef(v, heap_lo, heap_hi, root_callback, root_ctx);
            }
        }
        // Globals (pointers to slots in globals_storage OR
        // imported globals).
        for (rt.globals) |gptr| {
            tryReportRef(gptr.*, heap_lo, heap_hi, root_callback, root_ctx);
        }
    }
};

/// True iff the declared valtype byte is a heap-allocating reftype
/// per the Wasm 3.0 GC hierarchy. Excludes i31ref (low-bit-1
/// tagged per ADR-0116 §6 — no heap allocation) and externref
/// (no heap object owned by the GC; host-side ref).
///
/// ADR-0123 Cycle 2: ValType is no longer `enum(u8)` so we can't
/// `@enumFromInt(valtype_byte)`. Switch directly on the spec-pinned
/// byte values per Wasm 3.0 §5.3.1.
fn isHeapReftype(valtype_byte: u8) bool {
    return switch (valtype_byte) {
        0x70 => true, // funcref
        0x6E => true, // anyref
        0x6D => true, // eqref
        0x6B => true, // structref
        0x6A => true, // arrayref
        else => false, // numeric / v128 / externref / i31ref / typed refs
    };
}

fn tryReportRef(v: runtime_mod.Value, heap_lo: u64, heap_hi: u64, cb: RootCallback, cb_ctx: *anyopaque) void {
    const r = v.ref;
    // Quick rejects: null, i31-tagged (low bit 1), out of range,
    // unaligned. Each preserves the §6 invariant: heap pointers
    // have low bit 0 and live in [min_align, cursor).
    if (r == 0) return;
    if ((r & 1) != 0) return; // i31-tagged
    if (r < heap_lo or r >= heap_hi) return;
    if ((r % heap_mod.Heap.min_align) != 0) return;
    cb(cb_ctx, @intCast(r));
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const sections = @import("../../parse/sections.zig");

fn buildArenaedHeap(arena: *std.heap.ArenaAllocator, body: []const u8) !struct {
    heap: *Heap,
    gti: GcTypeInfos,
} {
    const a = arena.allocator();
    var types = try sections.decodeTypes(testing.allocator, body);
    defer types.deinit();
    const gti = try type_info_mod.materialiseGcTypes(a, types);
    const heap = try a.create(Heap);
    heap.* = Heap.init(a);
    return .{ .heap = heap, .gti = gti };
}

test "MarkSweepCollector: sweep over empty heap → 0 stats (10.G op_gc cycle 26)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    c.collector().collect();
    try testing.expectEqual(@as(u32, 0), c.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 0), c.last_stats.survivors);
    try testing.expectEqual(@as(u32, 0), c.last_stats.dead_bytes);
}

test "MarkSweepCollector: 2 struct allocs + 1 root → survivors=1, dead=struct_payload+header (10.G op_gc cycle 26)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // struct { i32 var } → payload_size = 8; alloc size = header(8) + 8 = 16.
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    // Manually allocate two objects with the right header shape so
    // sweep can decode them. Use Heap.allocate + write header by hand.
    const sz: u32 = header_size + 8;
    const ref1 = try env.heap.allocate(sz);
    const hdr1: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref1 .. ref1 + header_size], std.mem.asBytes(&hdr1)[0..header_size]);
    const ref2 = try env.heap.allocate(sz);
    const hdr2: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref2 .. ref2 + header_size], std.mem.asBytes(&hdr2)[0..header_size]);

    // Mark only the first object as root.
    c.markFromRoot(ref1);
    c.collector().collect();

    try testing.expectEqual(@as(u32, 2), c.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 1), c.last_stats.survivors);
    try testing.expectEqual(sz, c.last_stats.dead_bytes);
}

test "MarkSweepCollector: array object size decoded from ArrayHeader.length (10.G op_gc cycle 26)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // array<i32 var>; element size = 8 per slot.
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    const length: u32 = 4;
    const total: u32 = array_header_size + length * 8;
    const ref = try env.heap.allocate(total);
    const ahdr: ArrayHeader = .{
        .header = .{ .kind = .array, .info = 0 },
        .length = length,
    };
    @memcpy(env.heap.bytes[ref .. ref + array_header_size], std.mem.asBytes(&ahdr)[0..array_header_size]);

    // Don't mark → dead.
    c.collector().collect();
    try testing.expectEqual(@as(u32, 1), c.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 0), c.last_stats.survivors);
    try testing.expectEqual(total, c.last_stats.dead_bytes);
}

test "MarkSweepCollector: mark bit cleared after sweep (10.G op_gc cycle 26)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    const ref = try env.heap.allocate(header_size + 8);
    const hdr: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref .. ref + header_size], std.mem.asBytes(&hdr)[0..header_size]);

    c.markFromRoot(ref);
    // Verify mark bit set before sweep.
    var pre: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&pre)[0..header_size], env.heap.bytes[ref .. ref + header_size]);
    try testing.expect((pre.info & mark_bit_mask) != 0);

    c.collector().collect();
    var post: ObjectHeader = undefined;
    @memcpy(std.mem.asBytes(&post)[0..header_size], env.heap.bytes[ref .. ref + header_size]);
    try testing.expectEqual(@as(u32, 0), post.info & mark_bit_mask);
    // Typeidx (low 31 bits) preserved.
    try testing.expectEqual(@as(u32, 0), post.info);
}

test "MarkSweepCollector: allocObject delegates to Heap.allocate (10.G op_gc cycle 26)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    const col = c.collector();
    const ref = col.allocObject(16) orelse return error.UnexpectedAllocFail;
    try testing.expect(ref >= 2);
    try testing.expect(ref % 2 == 0);
}

test "MarkSweepCollector.walkRoots: enumerates operand-stack GcRefs (10.G op_gc cycle 27)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);
    const a = arena.allocator();
    const rt = try a.create(runtime_mod.Runtime);
    rt.* = runtime_mod.Runtime.init(a);

    // Allocate 2 objects so the heap cursor advances.
    const sz: u32 = header_size + 8;
    const ref1 = try env.heap.allocate(sz);
    const hdr1: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref1 .. ref1 + header_size], std.mem.asBytes(&hdr1)[0..header_size]);
    const ref2 = try env.heap.allocate(sz);
    const hdr2: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref2 .. ref2 + header_size], std.mem.asBytes(&hdr2)[0..header_size]);

    // Push ref1 (not ref2) onto operand stack as a Value.ref.
    try rt.pushOperand(.{ .ref = @as(u64, ref1) });

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    c.bindRuntime(@ptrCast(rt));

    // Collected via the vtable: walkRoots → markFromRoot → collect.
    const Collected = struct {
        var seen: [16]GcRef = undefined;
        var seen_len: usize = 0;
        fn cb(_: *anyopaque, ref: GcRef) void {
            if (seen_len < seen.len) {
                seen[seen_len] = ref;
                seen_len += 1;
            }
        }
    };
    Collected.seen_len = 0;
    const col = c.collector();
    col.walkRoots(Collected.cb, @ptrCast(rt));
    try testing.expectEqual(@as(usize, 1), Collected.seen_len);
    try testing.expectEqual(ref1, Collected.seen[0]);
}

test "MarkSweepCollector.walkRoots: filters i31-tagged + null + out-of-range (10.G op_gc cycle 27)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);
    const a = arena.allocator();
    const rt = try a.create(runtime_mod.Runtime);
    rt.* = runtime_mod.Runtime.init(a);

    // Push a real ref + 3 non-ref junk values that should be filtered.
    const sz: u32 = header_size + 8;
    const ref1 = try env.heap.allocate(sz);
    const hdr1: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref1 .. ref1 + header_size], std.mem.asBytes(&hdr1)[0..header_size]);

    try rt.pushOperand(.{ .ref = @as(u64, ref1) });
    try rt.pushOperand(.{ .ref = 0 }); // null
    try rt.pushOperand(.{ .ref = 0x4242_4243 }); // odd → i31-tagged
    try rt.pushOperand(.{ .ref = 0xDEAD_BEEF_DEAD_BEEF }); // way out of range

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    c.bindRuntime(@ptrCast(rt));

    const Collected = struct {
        var seen: [16]GcRef = undefined;
        var seen_len: usize = 0;
        fn cb(_: *anyopaque, ref: GcRef) void {
            if (seen_len < seen.len) {
                seen[seen_len] = ref;
                seen_len += 1;
            }
        }
    };
    Collected.seen_len = 0;
    c.collector().walkRoots(Collected.cb, @ptrCast(rt));
    try testing.expectEqual(@as(usize, 1), Collected.seen_len);
    try testing.expectEqual(ref1, Collected.seen[0]);
}

test "MarkSweepCollector: rt.globals reftype value reported as root (10.G op_gc cycle 27)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);
    const a = arena.allocator();
    const rt = try a.create(runtime_mod.Runtime);
    rt.* = runtime_mod.Runtime.init(a);

    const sz: u32 = header_size + 8;
    const ref1 = try env.heap.allocate(sz);
    const hdr1: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[ref1 .. ref1 + header_size], std.mem.asBytes(&hdr1)[0..header_size]);

    // Synthesise a 1-global runtime: globals_storage[0] holds the
    // ref Value; globals[0] points at it.
    const storage = try a.alloc(runtime_mod.Value, 1);
    storage[0] = .{ .ref = @as(u64, ref1) };
    const ptrs = try a.alloc(*runtime_mod.Value, 1);
    ptrs[0] = &storage[0];
    rt.globals = ptrs;
    rt.globals_storage = storage;

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    c.bindRuntime(@ptrCast(rt));

    const Collected = struct {
        var seen: [16]GcRef = undefined;
        var seen_len: usize = 0;
        fn cb(_: *anyopaque, ref: GcRef) void {
            if (seen_len < seen.len) {
                seen[seen_len] = ref;
                seen_len += 1;
            }
        }
    };
    Collected.seen_len = 0;
    c.collector().walkRoots(Collected.cb, @ptrCast(rt));
    try testing.expectEqual(@as(usize, 1), Collected.seen_len);
    try testing.expectEqual(ref1, Collected.seen[0]);
}

test "MarkSweepCollector: transitive trace via struct field (10.G op_gc cycle 28)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // struct { anyref var } — single reftype field (heap reftype per isHeapReftype).
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x6E, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    // Allocate "child" struct first, then "parent" struct holding child's ref.
    const sz: u32 = header_size + 8;
    const child_ref = try env.heap.allocate(sz);
    const child_hdr: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[child_ref .. child_ref + header_size], std.mem.asBytes(&child_hdr)[0..header_size]);

    const parent_ref = try env.heap.allocate(sz);
    const parent_hdr: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[parent_ref .. parent_ref + header_size], std.mem.asBytes(&parent_hdr)[0..header_size]);
    // Parent's field 0 holds child_ref.
    var slot: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot, @as(u64, child_ref), .little);
    @memcpy(env.heap.bytes[parent_ref + header_size .. parent_ref + header_size + 8], &slot);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    // Mark only the parent; child should be marked transitively.
    c.markFromRoot(parent_ref);
    c.collector().collect();

    // Both survived → survivors=2, dead_bytes=0.
    try testing.expectEqual(@as(u32, 2), c.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 2), c.last_stats.survivors);
    try testing.expectEqual(@as(u32, 0), c.last_stats.dead_bytes);
}

test "MarkSweepCollector: transitive trace via array element (10.G op_gc cycle 28)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // array<anyref var>
    const body = [_]u8{ 0x01, 0x5E, 0x6E, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    // Allocate child struct (no struct typedef in module — fake it with typeidx=0 but ai resolves array_infos[0]).
    // Use array typedef for both: parent is array of 1 element holding child's GcRef.
    const child_sz: u32 = array_header_size + 8;
    const child_ref = try env.heap.allocate(child_sz);
    const child_ahdr: ArrayHeader = .{
        .header = .{ .kind = .array, .info = 0 },
        .length = 1,
    };
    @memcpy(env.heap.bytes[child_ref .. child_ref + array_header_size], std.mem.asBytes(&child_ahdr)[0..array_header_size]);

    const parent_ref = try env.heap.allocate(child_sz);
    const parent_ahdr: ArrayHeader = .{
        .header = .{ .kind = .array, .info = 0 },
        .length = 1,
    };
    @memcpy(env.heap.bytes[parent_ref .. parent_ref + array_header_size], std.mem.asBytes(&parent_ahdr)[0..array_header_size]);
    // Parent's element 0 holds child_ref.
    var slot: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot, @as(u64, child_ref), .little);
    @memcpy(env.heap.bytes[parent_ref + array_header_size .. parent_ref + array_header_size + 8], &slot);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    c.markFromRoot(parent_ref);
    c.collector().collect();

    try testing.expectEqual(@as(u32, 2), c.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 2), c.last_stats.survivors);
}

test "MarkSweepCollector: cycle in struct refs terminates (10.G op_gc cycle 28)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x6E, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    const sz: u32 = header_size + 8;
    const a_ref = try env.heap.allocate(sz);
    const a_hdr: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[a_ref .. a_ref + header_size], std.mem.asBytes(&a_hdr)[0..header_size]);
    const b_ref = try env.heap.allocate(sz);
    const b_hdr: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[b_ref .. b_ref + header_size], std.mem.asBytes(&b_hdr)[0..header_size]);
    // a.field0 = b; b.field0 = a → cycle.
    var slot_a: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot_a, @as(u64, b_ref), .little);
    @memcpy(env.heap.bytes[a_ref + header_size .. a_ref + header_size + 8], &slot_a);
    var slot_b: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot_b, @as(u64, a_ref), .little);
    @memcpy(env.heap.bytes[b_ref + header_size .. b_ref + header_size + 8], &slot_b);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    c.markFromRoot(a_ref); // would recurse forever without cycle break
    c.collector().collect();

    try testing.expectEqual(@as(u32, 2), c.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 2), c.last_stats.survivors);
}

test "MarkSweepCollector: i32 field NOT traced as reftype (10.G op_gc cycle 28)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // struct { i32 var } — non-reftype field; the slot's u64 value
    // happens to fall in heap range but should NOT be followed.
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x01 };
    const env = try buildArenaedHeap(&arena, &body);

    const sz: u32 = header_size + 8;
    const survivor_ref = try env.heap.allocate(sz);
    const survivor_hdr: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[survivor_ref .. survivor_ref + header_size], std.mem.asBytes(&survivor_hdr)[0..header_size]);

    const decoy_ref = try env.heap.allocate(sz);
    const decoy_hdr: ObjectHeader = .{ .kind = .struct_, .info = 0 };
    @memcpy(env.heap.bytes[decoy_ref .. decoy_ref + header_size], std.mem.asBytes(&decoy_hdr)[0..header_size]);

    // survivor.field0 = decoy_ref as if it were a heap address;
    // because the field's valtype is i32 (non-reftype), trace
    // should NOT follow.
    var slot: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot, @as(u64, decoy_ref), .little);
    @memcpy(env.heap.bytes[survivor_ref + header_size .. survivor_ref + header_size + 8], &slot);

    var c = MarkSweepCollector.init(env.heap, &env.gti);
    c.markFromRoot(survivor_ref);
    c.collector().collect();

    // Only survivor marked; decoy is dead.
    try testing.expectEqual(@as(u32, 2), c.last_stats.objects_seen);
    try testing.expectEqual(@as(u32, 1), c.last_stats.survivors);
    try testing.expectEqual(sz, c.last_stats.dead_bytes);
}
