//! `ComponentValue` — the PUBLIC component-level value tree (ADR-0183).
//!
//! Mirrors the WIT value model so an embedder exchanges rich values with a
//! component (records ↔ host maps, lists ↔ vectors, results → host error
//! handling — the CWFS component-as-namespace consumer). DISTINCT from
//! `runtime.Value` by design (`single_slot_dual_meaning`): core flat values
//! never leak through this surface; the canonical ABI (canon.zig) is the
//! only translator.
//!
//! Ownership: compound payloads (string/list/record/tuple/pointers) are
//! owned by the allocator passed to the builder (`deinit` frees the whole
//! tree). `record` field NAMES borrow from the component's decoded
//! `TypeInfo` (alive for the instance's lifetime) — values own only values.
//!
//! Zone 1 (`feature/component/`): pure data, no host orchestration.

const std = @import("std");

/// One WIT value (`Explainer.md` value types). `own`/`borrow` resource
/// handles are reserved arms (resource passing is ADR-0183 later scope).
pub const ComponentValue = union(enum) {
    bool: bool,
    s8: i8,
    u8: u8,
    s16: i16,
    u16: u16,
    s32: i32,
    u32: u32,
    s64: i64,
    u64: u64,
    f32: f32,
    f64: f64,
    /// Unicode scalar value (the WIT `char`).
    char: u21,
    string: []const u8,
    list: []ComponentValue,
    record: []Field,
    tuple: []ComponentValue,
    /// `case` = the variant's case ordinal (type-model order).
    variant: Variant,
    /// The enum case ordinal + its label (REQ-2, cw CM-API).
    @"enum": Enum,
    option: ?*ComponentValue,
    result: Result,
    /// Bit-packed per the type's label order (≤ 32 labels per spec) + the
    /// type's labels (REQ-2, cw CM-API; bit i ↔ labels[i]).
    flags: Flags,
    /// An OWNING resource handle (component-table index; D-322). The
    /// handle's lifecycle belongs to the component instance's table —
    /// `deinit` does not drop it.
    own: u32,
    /// A BORROWED resource handle (lowered to the rep at the call).
    borrow: u32,

    pub const Field = struct {
        /// Borrows from the decoded `TypeInfo` (NOT owned by the tree).
        name: []const u8,
        value: ComponentValue,
    };

    pub const Variant = struct {
        case: u32,
        /// The case's label (REQ-2). Borrows from the decoded `TypeInfo` on
        /// a lifted result; `""` on a host-constructed input value (invoke
        /// dispatches by `case` ordinal — use `resolveFuncSig` to map a
        /// label to its ordinal).
        case_name: []const u8 = "",
        payload: ?*ComponentValue,
    };

    pub const Result = struct {
        is_ok: bool,
        payload: ?*ComponentValue,
    };

    /// An enum value: the case ordinal + (on a lifted result) its label.
    pub const Enum = struct {
        index: u32,
        /// Borrows from `TypeInfo` (output); `""` on host input.
        label: []const u8 = "",
    };

    /// A flags value: the bit set + (on a lifted result) the type's labels in
    /// bit order. `bits` is authoritative; `labels` is the introspection aid
    /// (set label `i` ⇔ `bits & (1 << i) != 0`).
    pub const Flags = struct {
        bits: u32,
        /// Borrows from `TypeInfo` (output); `&.{}` on host input.
        labels: []const []const u8 = &.{},
    };

    /// Recursively free every allocation the tree owns.
    pub fn deinit(self: ComponentValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .string => |s| alloc.free(s),
            .list, .tuple => |items| {
                for (items) |item| item.deinit(alloc);
                alloc.free(items);
            },
            .record => |fields| {
                for (fields) |f| f.value.deinit(alloc);
                alloc.free(fields);
            },
            .variant => |v| if (v.payload) |p| {
                p.deinit(alloc);
                alloc.destroy(p);
            },
            .option => |opt| if (opt) |p| {
                p.deinit(alloc);
                alloc.destroy(p);
            },
            .result => |r| if (r.payload) |p| {
                p.deinit(alloc);
                alloc.destroy(p);
            },
            .bool, .s8, .u8, .s16, .u16, .s32, .u32, .s64, .u64, .f32, .f64, .char, .@"enum", .flags, .own, .borrow => {},
        }
    }
};

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "deinit frees a nested tree (record{list, string} in a result)" {
    const a = testing.allocator;
    const items = try a.alloc(ComponentValue, 2);
    items[0] = .{ .u32 = 1 };
    items[1] = .{ .u32 = 2 };
    const fields = try a.alloc(ComponentValue.Field, 2);
    fields[0] = .{ .name = "xs", .value = .{ .list = items } };
    fields[1] = .{ .name = "label", .value = .{ .string = try a.dupe(u8, "hi") } };
    const payload = try a.create(ComponentValue);
    payload.* = .{ .record = fields };
    const v: ComponentValue = .{ .result = .{ .is_ok = true, .payload = payload } };
    v.deinit(a); // testing.allocator reports leaks if anything is missed
}
