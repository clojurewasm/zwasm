//! GC TypeInfo / StructInfo / ArrayInfo runtime layout per
//! ADR-0116 §3a (Revision 2026-05-27; cycle 19) and the parser
//! side-tables landed at ADR-0121 D2 (cycle 14).
//!
//! Materialisation happens at Instance construction time
//! (`runtime/instance/instantiate.zig`; wiring lands cycle 21+):
//! walk `sections.Types.kinds` / `Types.struct_defs` /
//! `Types.array_defs` → allocate parallel TypeInfo array per
//! Instance arena. The pointer-stable info ptr lives in each
//! heap ObjectHeader's `info` slot so the GC walker can decode
//! object kind + field layout.
//!
//! This cut: 8-byte-uniform field-slot layout (every field gets
//! an 8-byte slot regardless of declared size). Per-field
//! alignment optimisation defers to Phase 11. v128 fields
//! reject with Error.UnsupportedFieldSize.
//!
//! Zone 1 (`src/feature/gc/`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const sections = @import("../../parse/sections.zig");
const zir = @import("../../ir/zir.zig");
const ValType = zir.ValType;

pub const Error = error{
    /// v128 field declared in a struct/array typedef. Deferred per
    /// ADR-0116 §3a — Phase 11 revisits per-field alignment math.
    UnsupportedFieldSize,
    OutOfMemory,
};

/// Uniform field-slot size for this cut (ADR-0116 §3a). All
/// payload slots are 8 bytes regardless of declared field type.
/// Preserves the 2-byte alignment invariant (§5) trivially and
/// keeps offset compute O(1) without per-field alignment math.
pub const slot_size: u8 = 8;

pub const TypeKind = enum(u8) {
    func,
    struct_,
    array,
};

/// One field of a struct or one element-type triple of an array.
/// Extern-stable so the layout survives Zig version bumps.
pub const FieldInfo = extern struct {
    /// Byte offset of this field within the struct payload (or
    /// 0 for the sole array element-type slot). Multiples of
    /// `slot_size` in this cut.
    offset: u32,
    /// Byte size of the slot (always `slot_size` this cut).
    size: u8,
    /// ValType byte (Wasm 3.0 §5.3.5 encoding). Stored as u8 so
    /// the layout stays extern-stable.
    valtype_byte: u8,
    /// Mutable bit from the spec field-type triple. Read by
    /// struct.set / array.set / array.fill paths.
    mutable: bool,
    /// Reserved for future per-field alignment / kind flags.
    _reserved: u8 = 0,
};

/// Per-type RTT entry (ADR-0116 §3). Cycle-20 cut: depth-0
/// chains only; supertype_chain stays all-zero (sub-typing
/// support lands when recursive-types section parsing
/// materialises).
pub const TypeInfo = extern struct {
    /// Display: typeidx of each ancestor up to depth 7.
    /// `[0]..[depth-1]` are valid; `[depth..7]` are zero.
    supertype_chain: [8]u32,
    /// 0 = top (any / extern / func); chain[depth-1] = self.
    depth: u8,
    kind: TypeKind,
    /// Pad to align field_count to 4 bytes.
    _pad: [2]u8 = .{ 0, 0 },
    /// Number of entries in `fields` (for struct) or 1 (for array).
    field_count: u32,
};

pub const StructInfo = extern struct {
    type_info: *const TypeInfo,
    fields: [*]const FieldInfo,
    /// Total payload size after the GC ObjectHeader. Equal to
    /// `field_count * slot_size` this cut.
    payload_size: u32,
};

pub const ArrayInfo = extern struct {
    type_info: *const TypeInfo,
    /// Single element-type triple. The per-element byte size is
    /// `element.size` (always `slot_size` this cut).
    element: FieldInfo,
};

pub const ObjectKind = enum(u8) {
    struct_,
    array,
};

/// Heap object header. 8 bytes total; preserves the §5 low-bit-0
/// invariant for GcRef storage (header alignment is 8; payload
/// starts at offset 8 which is aligned).
pub const ObjectHeader = extern struct {
    kind: ObjectKind,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// 32-bit offset into the per-Instance TypeInfo array (NOT a
    /// raw pointer — the resolver in collector_mark_sweep maps
    /// this to `*const TypeInfo`). High bit reserved for mark
    /// phase per ADR-0115 §10.
    info: u32,
};

/// Array variant: 12 bytes (8 header + 4 length).
pub const ArrayHeader = extern struct {
    header: ObjectHeader,
    /// Element count; set at array.new* allocation; read by
    /// array.len + array.get/set/fill for bounds check.
    length: u32,
};

/// Materialised per-Instance GC type metadata. `entries` is
/// indexed by typeidx (mirrors `sections.Types.items.len`).
/// Non-struct/non-array entries have `kind = .func` placeholder
/// + null struct_info / array_info pointers.
///
/// Lifetime is caller-owned — `materialiseGcTypes` takes an
/// `Allocator` and allocates the three slices from it. The
/// Instance's arena allocator is the typical caller; on
/// `Instance.arena.deinit()` everything is released uniformly.
/// No internal arena (the test-only `decodeAndMaterialise`
/// helper provides one for unit-test cleanup convenience).
pub const GcTypeInfos = struct {
    entries: []TypeInfo,
    struct_infos: []?StructInfo,
    array_infos: []?ArrayInfo,
    /// 10.G cycle 168 (ADR-0126 Phase-10a) — structural canonical id per
    /// type. Two types with the same id are canonically equal (Wasm 3.0
    /// GC §4.2.8): same kind + finality + canonical supertype + field/
    /// elem/param-result structure. Concrete-ref fields fold the RAW
    /// target index (conservative — recursive canonical-equal-but-
    /// distinct-index refs do NOT merge yet; that's Phase-10b). Consulted
    /// by `concreteReaches` (RTT) so ref.test on a structurally-equal
    /// type matches (ref_test test-canon).
    canonical_ids: []const u64,
};

// FNV-1a-style structural fold helpers for canonical type ids (ADR-0126).
fn foldU64(h: u64, x: u64) u64 {
    return (h ^ x) *% 0x100000001b3;
}
fn foldValType(h: u64, vt: ValType) u64 {
    var x = foldU64(h, @as(u64, @intFromEnum(std.meta.activeTag(vt))) + 1);
    switch (vt) {
        .ref => |r| {
            x = foldU64(x, if (r.nullable) 2 else 1);
            switch (r.heap_type) {
                .abstract => |a| x = foldU64(x, 0x100 + @as(u64, @intFromEnum(a))),
                .concrete => |idx| x = foldU64(x, 0x10000 + @as(u64, idx)),
            }
        },
        else => {},
    }
    return x;
}
fn foldStorage(h: u64, st: sections.StorageType) u64 {
    return switch (st) {
        .val => |vt| foldValType(h, vt),
        .packed_ => |p| foldU64(h, 0x300 + @as(u64, @intFromEnum(p))),
    };
}

/// Extend a packed (i8/i16) field's stored low bytes to i32 — sign-
/// extend when `signed` (get_s) else zero-extend (get_u). `valtype_byte`
/// is the FieldInfo wire byte (0x78 i8 / 0x77 i16). Returns null for a
/// non-packed byte (the validator rejects get_s/get_u there; callers
/// trap defensively). ADR-0125 B-exec; shared by struct_ops + array_ops.
pub fn extendPackedToI32(stored: i32, valtype_byte: u8, signed: bool) ?i32 {
    const u: u32 = @bitCast(stored);
    return switch (valtype_byte) {
        0x78 => if (signed) @as(i32, @as(i8, @bitCast(@as(u8, @truncate(u))))) else @as(i32, @as(u8, @truncate(u))),
        0x77 => if (signed) @as(i32, @as(i16, @bitCast(@as(u16, @truncate(u))))) else @as(i32, @as(u16, @truncate(u))),
        else => null,
    };
}

/// Compute the heap slot size of a field given its storage type.
/// Slots are 8 bytes uniform (ADR-0116 §3a) — packed i8/i16 occupy a
/// full slot too; their narrow width is the get_s/get_u extension
/// boundary (`StorageType.storageWidth`), not the slot size.
fn fieldSlotSize(storage: sections.StorageType) Error!u8 {
    return switch (storage) {
        .packed_ => slot_size,
        .val => |v| switch (v) {
            .v128 => Error.UnsupportedFieldSize,
            .i32, .i64, .f32, .f64, .ref => slot_size,
        },
    };
}

/// Walk parser-side Types and build the per-Instance GC type
/// metadata. Caller-owned allocator; on partial failure mid-walk
/// the per-typeidx allocations are NOT individually freed
/// (caller arena-drops on its own deinit path — Instance arena
/// is the canonical case).
pub fn materialiseGcTypes(alloc: Allocator, types: sections.Types) Error!GcTypeInfos {
    const n = types.items.len;
    const entries = try alloc.alloc(TypeInfo, n);
    const struct_infos = try alloc.alloc(?StructInfo, n);
    const array_infos = try alloc.alloc(?ArrayInfo, n);
    for (struct_infos) |*s| s.* = null;
    for (array_infos) |*a| a.* = null;

    for (entries, 0..) |*entry, i| {
        const kind = types.kinds[i];
        entry.* = .{
            .supertype_chain = [_]u32{0} ** 8,
            .depth = 0,
            .kind = switch (kind) {
                .func => .func,
                .structdef => .struct_,
                .arraydef => .array,
            },
            .field_count = 0,
        };
        // RTT (ADR-0116 §3) — build the ancestor-inclusive supertype chain
        // [self, parent, …] from the parsed declared supertypes so
        // ref.test/cast concrete-$idx matching can membership-test it.
        // Single-supertype chains dominate; bound to the 8-entry array.
        {
            var d: u8 = 0;
            var cur: u32 = @intCast(i);
            while (d < entry.supertype_chain.len) {
                entry.supertype_chain[d] = cur;
                d += 1;
                const supers = if (cur < types.supertypes.len) types.supertypes[cur] else &.{};
                if (supers.len == 0) break;
                const parent = supers[0];
                if (parent == cur or parent >= n) break; // cycle / OOB guard
                cur = parent;
            }
            entry.depth = d;
        }
        switch (kind) {
            .func => {},
            .structdef => {
                const sd = types.struct_defs[i].?;
                const fields = try alloc.alloc(FieldInfo, sd.fields.len);
                var offset: u32 = 0;
                for (sd.fields, 0..) |spec_field, fi| {
                    const sz = try fieldSlotSize(spec_field.storage);
                    fields[fi] = .{
                        .offset = offset,
                        .size = sz,
                        .valtype_byte = spec_field.storage.specByte(),
                        .mutable = spec_field.mutable,
                    };
                    offset += sz;
                }
                entry.field_count = @intCast(sd.fields.len);
                struct_infos[i] = .{
                    .type_info = entry,
                    .fields = fields.ptr,
                    .payload_size = offset,
                };
            },
            .arraydef => {
                const ad = types.array_defs[i].?;
                const sz = try fieldSlotSize(ad.element.storage);
                entry.field_count = 1;
                array_infos[i] = .{
                    .type_info = entry,
                    .element = .{
                        .offset = 0,
                        .size = sz,
                        .valtype_byte = ad.element.storage.specByte(),
                        .mutable = ad.element.mutable,
                    },
                };
            },
        }
    }

    // ADR-0126 Phase-10a — structural canonical ids. Index order: a
    // declared supertype is a lower index (parent declared first), so
    // `canonical_ids[parent]` is ready; forward/rec-group supertype refs
    // (parent >= i) fold 0 (conservative, no canonicalization → 10b).
    const canonical_ids = try alloc.alloc(u64, n);
    for (canonical_ids, 0..) |*cid, i| {
        var h: u64 = 0xcbf29ce484222325;
        h = foldU64(h, @as(u64, @intFromEnum(types.kinds[i])) + 1);
        h = foldU64(h, if (i < types.finals.len and types.finals[i]) 2 else 1);
        const sup_id: u64 = blk: {
            if (i < types.supertypes.len and types.supertypes[i].len > 0) {
                const p = types.supertypes[i][0];
                if (p < i) break :blk canonical_ids[p];
            }
            break :blk 0;
        };
        h = foldU64(h, sup_id);
        switch (types.kinds[i]) {
            .structdef => if (types.struct_defs[i]) |sd| {
                for (sd.fields) |f| {
                    h = foldStorage(h, f.storage);
                    h = foldU64(h, if (f.mutable) 2 else 1);
                }
            },
            .arraydef => if (types.array_defs[i]) |ad| {
                h = foldStorage(h, ad.element.storage);
                h = foldU64(h, if (ad.element.mutable) 2 else 1);
            },
            .func => {
                const ft = types.items[i];
                for (ft.params) |p| h = foldValType(h, p);
                h = foldU64(h, 0xF0F0);
                for (ft.results) |r| h = foldValType(h, r);
            },
        }
        cid.* = h;
    }

    return .{
        .entries = entries,
        .struct_infos = struct_infos,
        .array_infos = array_infos,
        .canonical_ids = canonical_ids,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Test helper: decode types + materialise into a local arena;
/// arena returned for caller-side deinit. The pre-cycle-21
/// `GcTypeInfos.deinit` was inlined into the struct; this
/// helper restores the test-time convenience.
fn decodeAndMaterialise(body: []const u8) !struct {
    arena: std.heap.ArenaAllocator,
    gti: GcTypeInfos,
} {
    var t = try sections.decodeTypes(testing.allocator, body);
    defer t.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const gti = try materialiseGcTypes(arena.allocator(), t);
    return .{ .arena = arena, .gti = gti };
}

test "extendPackedToI32: i8/i16 sign- vs zero-extend; truncation; non-packed → null (ADR-0125 B-exec)" {
    // i8 (0x78): low byte of 0x1FF is 0xFF → -1 signed, 255 unsigned.
    try testing.expectEqual(@as(?i32, -1), extendPackedToI32(0x1FF, 0x78, true));
    try testing.expectEqual(@as(?i32, 255), extendPackedToI32(0x1FF, 0x78, false));
    // i8 positive: 0x7F stays 127 either way.
    try testing.expectEqual(@as(?i32, 127), extendPackedToI32(0x7F, 0x78, true));
    // i16 (0x77): low 16 of 0x1FFFF is 0xFFFF → -1 signed, 65535 unsigned.
    try testing.expectEqual(@as(?i32, -1), extendPackedToI32(0x1FFFF, 0x77, true));
    try testing.expectEqual(@as(?i32, 65535), extendPackedToI32(0x1FFFF, 0x77, false));
    // Non-packed wire byte (i32 = 0x7F) → null (validator rejects get_s/_u there).
    try testing.expectEqual(@as(?i32, null), extendPackedToI32(42, 0x7F, true));
}

test "materialiseGcTypes: supertype_chain built self-inclusive from declared supers (10.G cycle 151, RTT)" {
    // type0 = struct{} (bare); type1 = sub $0 struct{i32}.
    //   0x02            — 2 types
    //   0x5F 0x00       — type0: structtype, 0 fields (bare → final, no super)
    //   0x50 0x01 0x00  — type1: sub (NoFinal), 1 supertype = $0
    //   0x5F 0x01 0x7F 0x00 — structtype, 1 field i32 const
    const body = [_]u8{ 0x02, 0x5F, 0x00, 0x50, 0x01, 0x00, 0x5F, 0x01, 0x7F, 0x00 };
    var r = try decodeAndMaterialise(&body);
    defer r.arena.deinit();
    // chain(0) = [0] (self only); chain(1) = [1, 0] (self, parent).
    try testing.expectEqual(@as(u8, 1), r.gti.entries[0].depth);
    try testing.expectEqual(@as(u32, 0), r.gti.entries[0].supertype_chain[0]);
    try testing.expectEqual(@as(u8, 2), r.gti.entries[1].depth);
    try testing.expectEqual(@as(u32, 1), r.gti.entries[1].supertype_chain[0]);
    try testing.expectEqual(@as(u32, 0), r.gti.entries[1].supertype_chain[1]);
}

test "materialiseGcTypes: single i32 struct → 1 field offset=0 size=8" {
    // structtype: count=1, 0x5F, field_count=1, valtype=i32(0x7F), mut=0x00.
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x00 };
    var result = try decodeAndMaterialise(&body);
    defer result.arena.deinit();
    const gti = result.gti;

    try testing.expectEqual(@as(usize, 1), gti.entries.len);
    try testing.expectEqual(TypeKind.struct_, gti.entries[0].kind);
    try testing.expectEqual(@as(u32, 1), gti.entries[0].field_count);
    try testing.expect(gti.struct_infos[0] != null);
    const si = gti.struct_infos[0].?;
    try testing.expectEqual(@as(u32, 8), si.payload_size);
    try testing.expectEqual(@as(u32, 0), si.fields[0].offset);
    try testing.expectEqual(slot_size, si.fields[0].size);
    try testing.expectEqual(@as(u8, 0x7F), si.fields[0].valtype_byte);
    try testing.expectEqual(false, si.fields[0].mutable);
}

test "materialiseGcTypes: multi-field struct → offsets 0, 8, 16; payload_size 24" {
    // struct { i32 const, i64 var, f32 const }
    const body = [_]u8{
        0x01, 0x5F,
        0x03, 0x7F,
        0x00, 0x7E,
        0x01, 0x7D,
        0x00,
    };
    var result = try decodeAndMaterialise(&body);
    defer result.arena.deinit();
    const gti = result.gti;

    const si = gti.struct_infos[0].?;
    try testing.expectEqual(@as(u32, 24), si.payload_size);
    try testing.expectEqual(@as(u32, 0), si.fields[0].offset);
    try testing.expectEqual(@as(u32, 8), si.fields[1].offset);
    try testing.expectEqual(@as(u32, 16), si.fields[2].offset);
    try testing.expectEqual(true, si.fields[1].mutable);
    try testing.expectEqual(false, si.fields[2].mutable);
}

test "materialiseGcTypes: array of i32 → element.size=8 offset=0" {
    // arraytype: count=1, 0x5E, valtype=i32, mut=0x01.
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    var result = try decodeAndMaterialise(&body);
    defer result.arena.deinit();
    const gti = result.gti;

    try testing.expectEqual(TypeKind.array, gti.entries[0].kind);
    try testing.expect(gti.array_infos[0] != null);
    const ai = gti.array_infos[0].?;
    try testing.expectEqual(@as(u32, 0), ai.element.offset);
    try testing.expectEqual(slot_size, ai.element.size);
    try testing.expectEqual(@as(u8, 0x7F), ai.element.valtype_byte);
    try testing.expectEqual(true, ai.element.mutable);
}

test "materialiseGcTypes: mixed func+struct+array preserves kinds" {
    const body = [_]u8{
        0x03,
        0x60, 0x00, 0x00, // () -> ()
        0x5F, 0x01, 0x7F, 0x01, // struct { i32 var }
        0x5E, 0x7E, 0x00, // array of i64 const
    };
    var result = try decodeAndMaterialise(&body);
    defer result.arena.deinit();
    const gti = result.gti;

    try testing.expectEqual(TypeKind.func, gti.entries[0].kind);
    try testing.expectEqual(TypeKind.struct_, gti.entries[1].kind);
    try testing.expectEqual(TypeKind.array, gti.entries[2].kind);
    try testing.expect(gti.struct_infos[1] != null);
    try testing.expect(gti.array_infos[2] != null);
    try testing.expect(gti.struct_infos[0] == null);
    try testing.expect(gti.array_infos[1] == null);
}

test "materialiseGcTypes: v128 field rejects UnsupportedFieldSize" {
    // struct { v128 const }
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7B, 0x00 };
    var t = try sections.decodeTypes(testing.allocator, &body);
    defer t.deinit();
    // Arena handles partial-failure cleanup (caller responsibility per
    // the function's contract — Instance arena is the canonical site).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(Error.UnsupportedFieldSize, materialiseGcTypes(arena.allocator(), t));
}

test "ObjectHeader layout: 8 bytes; ArrayHeader: 12 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(ObjectHeader));
    try testing.expectEqual(@as(usize, 12), @sizeOf(ArrayHeader));
}

test "FieldInfo + TypeInfo extern alignment stays stable" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(FieldInfo));
    // TypeInfo: 8*4 supertype + 1 depth + 1 kind + 2 pad + 4 field_count = 40
    try testing.expectEqual(@as(usize, 40), @sizeOf(TypeInfo));
}
