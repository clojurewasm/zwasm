// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! GC heap — no-collect allocator for struct/array objects (GC proposal).
//!
//! D111: append-only allocation. Collector deferred to W20.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const module_mod = @import("module.zig");

/// Tag bit for i31ref values on the operand stack (bit 63).
pub const I31_TAG: u64 = @as(u64, 1) << 63;

/// Tag bits for GC object references on the operand stack (bits 32-39).
pub const GC_TAG: u64 = @as(u64, 0x01) << 32;

/// A GC heap object (struct or array instance).
/// Operand stack value type (matches Vm stack: u64).
const StackVal = u64;

pub const GcObject = union(enum) {
    struct_obj: StructObj,
    array_obj: ArrayObj,
};

/// A struct instance on the GC heap.
pub const StructObj = struct {
    type_idx: u32,
    fields: []StackVal, // each field stored as u64 (same as operand stack)
};

/// An array instance on the GC heap.
pub const ArrayObj = struct {
    type_idx: u32,
    elements: []StackVal,
};

/// No-collect GC heap. Append-only allocation.
pub const GcHeap = struct {
    objects: ArrayList(GcObject),
    alloc: Allocator,

    pub fn init(alloc: Allocator) GcHeap {
        return .{ .objects = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *GcHeap) void {
        for (self.objects.items) |obj| {
            switch (obj) {
                .struct_obj => |s| self.alloc.free(s.fields),
                .array_obj => |a| self.alloc.free(a.elements),
            }
        }
        self.objects.deinit(self.alloc);
    }

    /// Allocate a struct object, returns gc_addr (index into objects).
    pub fn allocStruct(self: *GcHeap, type_idx: u32, fields: []const StackVal) !u32 {
        const stored = try self.alloc.alloc(StackVal, fields.len);
        @memcpy(stored, fields);
        const addr: u32 = @intCast(self.objects.items.len);
        try self.objects.append(self.alloc, .{ .struct_obj = .{
            .type_idx = type_idx,
            .fields = stored,
        } });
        return addr;
    }

    /// Allocate an array object, returns gc_addr.
    pub fn allocArray(self: *GcHeap, type_idx: u32, len: u32, init_val: StackVal) !u32 {
        const elements = try self.alloc.alloc(StackVal, len);
        @memset(elements, init_val);
        const addr: u32 = @intCast(self.objects.items.len);
        try self.objects.append(self.alloc, .{ .array_obj = .{
            .type_idx = type_idx,
            .elements = elements,
        } });
        return addr;
    }

    /// Allocate an array with pre-filled values, returns gc_addr.
    pub fn allocArrayWithValues(self: *GcHeap, type_idx: u32, values: []const StackVal) !u32 {
        const elements = try self.alloc.alloc(StackVal, values.len);
        @memcpy(elements, values);
        const addr: u32 = @intCast(self.objects.items.len);
        try self.objects.append(self.alloc, .{ .array_obj = .{
            .type_idx = type_idx,
            .elements = elements,
        } });
        return addr;
    }

    /// Get a mutable reference to a GC object by address.
    pub fn getObject(self: *GcHeap, addr: u32) !*GcObject {
        if (addr >= self.objects.items.len) return error.Trap;
        return &self.objects.items[addr];
    }

    /// Encode a GC heap address as an operand stack value (non-null).
    pub fn encodeRef(addr: u32) u64 {
        return (@as(u64, addr) + 1) | GC_TAG;
    }

    /// Decode an operand stack value to a GC heap address.
    /// Returns null if the value is null ref (0).
    pub fn decodeRef(val: u64) !u32 {
        if (val == 0) return error.Trap; // null ref
        // Check for i31 tag
        if (val & I31_TAG != 0) return error.Trap; // i31, not a heap ref
        const raw = val & 0xFFFF_FFFF; // low 32 bits = addr + 1
        if (raw == 0) return error.Trap;
        return @intCast(raw - 1);
    }

    /// Check if an operand stack value is a GC heap reference (not null, not i31).
    pub fn isGcRef(val: u64) bool {
        if (val == 0) return false;
        if (val & I31_TAG != 0) return false;
        return (val & GC_TAG) != 0;
    }
};

// ============================================================
// i31 helpers
// ============================================================

/// Encode an i32 value as an i31ref on the operand stack.
/// Truncates to 31 bits.
pub fn encodeI31(val: i32) u64 {
    const bits: u32 = @bitCast(val);
    return (@as(u64, bits & 0x7FFF_FFFF)) | I31_TAG;
}

/// Decode an i31ref value with sign extension (i31.get_s).
pub fn decodeI31Signed(val: u64) !i32 {
    if (val == 0) return error.Trap; // null i31ref
    if (val & I31_TAG == 0) return error.Trap; // not i31
    const bits: u32 = @intCast(val & 0x7FFF_FFFF);
    // Sign extend from bit 30
    if (bits & 0x4000_0000 != 0) {
        return @bitCast(bits | 0x8000_0000);
    }
    return @bitCast(bits);
}

/// Decode an i31ref value with zero extension (i31.get_u).
pub fn decodeI31Unsigned(val: u64) !i32 {
    if (val == 0) return error.Trap; // null i31ref
    if (val & I31_TAG == 0) return error.Trap; // not i31
    return @intCast(val & 0x7FFF_FFFF);
}

/// Check if an operand stack value is an i31ref.
pub fn isI31(val: u64) bool {
    return val != 0 and (val & I31_TAG != 0);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "i31 encode/decode round-trip" {
    // Positive value
    const pos = encodeI31(42);
    try testing.expect(isI31(pos));
    try testing.expectEqual(@as(i32, 42), try decodeI31Signed(pos));
    try testing.expectEqual(@as(i32, 42), try decodeI31Unsigned(pos));

    // Negative value (-1)
    const neg = encodeI31(-1);
    try testing.expect(isI31(neg));
    try testing.expectEqual(@as(i32, -1), try decodeI31Signed(neg));
    try testing.expectEqual(@as(i32, 0x7FFF_FFFF), try decodeI31Unsigned(neg));

    // Zero
    const zero = encodeI31(0);
    try testing.expect(isI31(zero));
    try testing.expectEqual(@as(i32, 0), try decodeI31Signed(zero));
    try testing.expectEqual(@as(i32, 0), try decodeI31Unsigned(zero));
}

test "i31 null trap" {
    try testing.expectError(error.Trap, decodeI31Signed(0));
    try testing.expectError(error.Trap, decodeI31Unsigned(0));
}

test "GcHeap allocStruct" {
    var heap = GcHeap.init(testing.allocator);
    defer heap.deinit();

    const fields = [_]u64{ 42, 100 };
    const addr = try heap.allocStruct(0, &fields);
    try testing.expectEqual(@as(u32, 0), addr);

    const obj = try heap.getObject(addr);
    switch (obj.*) {
        .struct_obj => |s| {
            try testing.expectEqual(@as(u32, 0), s.type_idx);
            try testing.expectEqual(@as(usize, 2), s.fields.len);
            try testing.expectEqual(@as(u64, 42), s.fields[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GcHeap allocArray" {
    var heap = GcHeap.init(testing.allocator);
    defer heap.deinit();

    const addr = try heap.allocArray(1, 3, 99);
    const obj = try heap.getObject(addr);
    switch (obj.*) {
        .array_obj => |a| {
            try testing.expectEqual(@as(u32, 1), a.type_idx);
            try testing.expectEqual(@as(usize, 3), a.elements.len);
            try testing.expectEqual(@as(u64, 99), a.elements[0]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GcHeap encodeRef/decodeRef" {
    const ref = GcHeap.encodeRef(5);
    try testing.expect(GcHeap.isGcRef(ref));
    try testing.expectEqual(@as(u32, 5), try GcHeap.decodeRef(ref));

    // null ref
    try testing.expect(!GcHeap.isGcRef(0));
    try testing.expectError(error.Trap, GcHeap.decodeRef(0));
}

test "i31 VM integration — ref.i31 + i31.get_s round-trip" {
    const Module = module_mod.Module;
    const Store = @import("store.zig").Store;
    const Instance = @import("instance.zig").Instance;
    const Vm = @import("vm.zig").Vm;

    // Wasm binary: (func (export "i31rt") (param i32) (result i32) local.get 0 ref.i31 i31.get_s end)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x01, 0x00, 0x00, 0x00, // version
        // Type section: 1 type — (i32) -> (i32)
        0x01, 0x06, // section id=1, size=6
        0x01, // 1 type
        0x60, 0x01, 0x7F, 0x01, 0x7F, // func (i32) -> (i32)
        // Function section: 1 function, type 0
        0x03, 0x02, // section id=3, size=2
        0x01, 0x00, // 1 func, type idx 0
        // Export section: "i31rt" -> func 0
        0x07, 0x09, // section id=7, size=9
        0x01, // 1 export
        0x05, 'i', '3', '1', 'r', 't', // name
        0x00, 0x00, // func, idx 0
        // Code section: 1 body
        0x0A, 0x0A, // section id=10, size=10
        0x01, // 1 body
        0x08, // body size = 8
        0x00, // 0 locals
        0x20, 0x00, // local.get 0
        0xFB, 0x1C, // ref.i31
        0xFB, 0x1D, // i31.get_s
        0x0B, // end
    };

    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    // Test positive value: 42
    var args = [_]u64{42};
    var results = [_]u64{0};
    try vm.invoke(&inst, "i31rt", &args, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);

    // Test negative value: -1 (0xFFFFFFFF as i32)
    args = [_]u64{@as(u64, @as(u32, @bitCast(@as(i32, -1))))};
    results = [_]u64{0};
    try vm.invoke(&inst, "i31rt", &args, &results);
    // i31 truncates to 31 bits, so -1 stays -1 (0x7FFFFFFF -> sign extend -> 0xFFFFFFFF)
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -1)))), results[0]);
}
