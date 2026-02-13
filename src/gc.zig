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
// Subtype checking (D114: linear scan)
// ============================================================

const ValType = @import("opcode.zig").ValType;
const Module = module_mod.Module;

/// Check if a runtime GC value matches a target heap type.
/// Used by ref.test, ref.cast, br_on_cast.
/// Returns true if the non-null value `val` is an instance of `target_ht`.
pub fn matchesHeapType(val: u64, target_ht: u32, module: *const Module) bool {
    // Abstract heap types
    if (target_ht == ValType.HEAP_ANY) return true; // any non-null matches any
    if (target_ht == ValType.HEAP_NONE) return false; // none matches nothing

    if (isI31(val)) {
        // i31 matches: i31, eq, any
        return target_ht == ValType.HEAP_I31 or target_ht == ValType.HEAP_EQ;
    }

    if (GcHeap.isGcRef(val)) {
        const addr = GcHeap.decodeRef(val) catch return false;
        // We need the object to check struct vs array, but we don't have the heap here.
        // Instead, encode the object's type_idx in the ref. For now, we use a two-arg version.
        // This function requires the GcHeap to resolve the object.
        _ = addr;
        _ = module;
        // Can't fully resolve without heap — see matchesHeapTypeWithHeap
        return false;
    }

    // funcref: check HEAP_FUNC
    if (target_ht == ValType.HEAP_FUNC) return val != 0;

    return false;
}

/// Check if a runtime GC value matches a target heap type, with heap access.
pub fn matchesHeapTypeWithHeap(val: u64, target_ht: u32, module: *const Module, heap: *GcHeap) bool {
    if (target_ht == ValType.HEAP_ANY) return true;
    if (target_ht == ValType.HEAP_NONE) return false;

    if (isI31(val)) {
        return target_ht == ValType.HEAP_I31 or target_ht == ValType.HEAP_EQ;
    }

    if (GcHeap.isGcRef(val)) {
        const addr = GcHeap.decodeRef(val) catch return false;
        const obj = heap.getObject(addr) catch return false;
        const obj_type_idx: u32 = switch (obj.*) {
            .struct_obj => |s| s.type_idx,
            .array_obj => |a| a.type_idx,
        };
        const is_struct = switch (obj.*) {
            .struct_obj => true,
            .array_obj => false,
        };

        // Abstract type checks
        if (target_ht == ValType.HEAP_EQ) return true; // all GC objects are eq
        if (target_ht == ValType.HEAP_STRUCT) return is_struct;
        if (target_ht == ValType.HEAP_ARRAY) return !is_struct;

        // Concrete type check: target_ht is a type index
        if (target_ht >= module.types.items.len) return false;
        return isConcreteSubtype(obj_type_idx, target_ht, module);
    }

    // funcref
    if (target_ht == ValType.HEAP_FUNC) return val != 0;

    return false;
}

/// Check if concrete type `sub` is a subtype of concrete type `super` (or equal).
/// Uses linear super_types chain walk (D114).
pub fn isConcreteSubtype(sub: u32, super: u32, module: *const Module) bool {
    if (sub == super) return true;
    if (sub >= module.types.items.len) return false;

    // Walk the super_types chain
    var current = sub;
    while (true) {
        if (current >= module.types.items.len) return false;
        const td = module.types.items[current];
        if (td.super_types.len == 0) return false;
        current = td.super_types[0]; // single inheritance
        if (current == super) return true;
    }
}

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

test "subtype checking — i31 matches i31/eq/any" {
    var heap = GcHeap.init(testing.allocator);
    defer heap.deinit();
    var mod: Module = Module.init(testing.allocator, &.{});
    const i31_val = encodeI31(42);
    // i31 matches i31, eq, any but not struct/array/none
    try testing.expect(matchesHeapTypeWithHeap(i31_val, ValType.HEAP_I31, &mod, &heap));
    try testing.expect(matchesHeapTypeWithHeap(i31_val, ValType.HEAP_EQ, &mod, &heap));
    try testing.expect(matchesHeapTypeWithHeap(i31_val, ValType.HEAP_ANY, &mod, &heap));
    try testing.expect(!matchesHeapTypeWithHeap(i31_val, ValType.HEAP_STRUCT, &mod, &heap));
    try testing.expect(!matchesHeapTypeWithHeap(i31_val, ValType.HEAP_ARRAY, &mod, &heap));
    try testing.expect(!matchesHeapTypeWithHeap(i31_val, ValType.HEAP_NONE, &mod, &heap));
}

test "subtype checking — GC struct ref matches struct/eq/any" {
    var heap = GcHeap.init(testing.allocator);
    defer heap.deinit();
    const fields = [_]u64{42};
    const addr = try heap.allocStruct(0, &fields);
    const ref_val = GcHeap.encodeRef(addr);

    // Create a minimal module with one struct type (no supertypes)
    var types_list: std.ArrayList(module_mod.TypeDef) = .empty;
    defer types_list.deinit(testing.allocator);
    try types_list.append(testing.allocator, .{
        .composite = .{ .struct_type = .{ .fields = &.{} } },
    });
    var mod: Module = Module.init(testing.allocator, &.{});
    mod.types = types_list;

    try testing.expect(matchesHeapTypeWithHeap(ref_val, ValType.HEAP_STRUCT, &mod, &heap));
    try testing.expect(matchesHeapTypeWithHeap(ref_val, ValType.HEAP_EQ, &mod, &heap));
    try testing.expect(matchesHeapTypeWithHeap(ref_val, ValType.HEAP_ANY, &mod, &heap));
    try testing.expect(!matchesHeapTypeWithHeap(ref_val, ValType.HEAP_ARRAY, &mod, &heap));
    try testing.expect(!matchesHeapTypeWithHeap(ref_val, ValType.HEAP_I31, &mod, &heap));
    // Concrete type 0 matches itself
    try testing.expect(matchesHeapTypeWithHeap(ref_val, 0, &mod, &heap));
}

test "subtype checking — concrete subtype chain" {
    // type 0 = struct {} (base)
    // type 1 = struct {} with super = [0]
    var types_list: std.ArrayList(module_mod.TypeDef) = .empty;
    defer types_list.deinit(testing.allocator);
    const supers = [_]u32{0};
    try types_list.append(testing.allocator, .{
        .composite = .{ .struct_type = .{ .fields = &.{} } },
    });
    try types_list.append(testing.allocator, .{
        .composite = .{ .struct_type = .{ .fields = &.{} } },
        .super_types = &supers,
        .is_final = false,
    });
    var mod: Module = Module.init(testing.allocator, &.{});
    mod.types = types_list;

    // type 1 is subtype of type 0
    try testing.expect(isConcreteSubtype(1, 0, &mod));
    // type 0 is NOT subtype of type 1
    try testing.expect(!isConcreteSubtype(0, 1, &mod));
    // type 0 is subtype of itself
    try testing.expect(isConcreteSubtype(0, 0, &mod));
}

test "struct VM integration — struct.new + struct.get" {
    const Store = @import("store.zig").Store;
    const Instance = @import("instance.zig").Instance;
    const Vm = @import("vm.zig").Vm;

    // Module with: type 0 = struct { (mut i32), (mut i32) }, type 1 = func (i32 i32) -> (i32)
    // func (export "stest") (param i32 i32) (result i32): local.get 0, local.get 1, struct.new 0, struct.get 0 1, end
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // magic + version
        // Type section: 2 types (size = 1 + 6 + 6 = 13)
        0x01, 0x0D, // section id=1, size=13
        0x02, // 2 types
        // type 0: struct { (mut i32), (mut i32) }
        0x5F, 0x02, // struct, 2 fields
        0x7F, 0x01, // field 0: i32, mutable
        0x7F, 0x01, // field 1: i32, mutable
        // type 1: func (i32, i32) -> (i32)
        0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F, // func (i32 i32) -> (i32)
        // Function section
        0x03, 0x02, 0x01, 0x01, // 1 func, type idx 1
        // Export section
        0x07, 0x09, 0x01, 0x05, 's', 't', 'e', 's', 't', 0x00, 0x00,
        // Code section (body: 1+2+2+3+4+1 = 13 bytes, section: 1+1+13 = 15)
        0x0A, 0x0F, // section id=10, size=15
        0x01, 0x0D, // 1 body, size=13
        0x00, // 0 locals
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0xFB, 0x00, // struct.new (gc_prefix + sub=0)
        0x00, // typeidx 0
        0xFB, 0x02, // struct.get (gc_prefix + sub=2)
        0x00, // typeidx 0
        0x01, // fieldidx 1
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
    // struct.new with fields (10, 20), then struct.get field 1 -> 20
    var args = [_]u64{ 10, 20 };
    var results = [_]u64{0};
    try vm.invoke(&inst, "stest", &args, &results);
    try testing.expectEqual(@as(u64, 20), results[0]);
}

test "struct VM integration — struct.new_default + struct.set + struct.get" {
    const Store = @import("store.zig").Store;
    const Instance = @import("instance.zig").Instance;
    const Vm = @import("vm.zig").Vm;

    // func (export "stest2") (param i32) (result i32) (local i64)
    //   struct.new_default 0, local.tee 1, local.get 0, struct.set 0 0, local.get 1, struct.get 0 0, end
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // Type section (size=12)
        0x01, 0x0C,
        0x02, // 2 types
        0x5F, 0x02, 0x7F, 0x01, 0x7F, 0x01, // struct { mut i32, mut i32 }
        0x60, 0x01, 0x7F, 0x01, 0x7F, // func (i32) -> (i32)
        // Function section
        0x03, 0x02, 0x01, 0x01, // 1 func, type 1
        // Export section
        0x07, 0x0A, 0x01, 0x06, 's', 't', 'e', 's', 't', '2', 0x00, 0x00,
        // Code section (body=21, section=1+1+21=23)
        0x0A, 0x17, // section 10, size=23
        0x01, 0x15, // 1 body, size=21
        0x01, 0x01, 0x7E, // 1 local: i64
        0xFB, 0x01, 0x00, // struct.new_default 0
        0x22, 0x01, // local.tee 1
        0x20, 0x00, // local.get 0
        0xFB, 0x05, 0x00, 0x00, // struct.set 0 0
        0x20, 0x01, // local.get 1
        0xFB, 0x02, 0x00, 0x00, // struct.get 0 0
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
    // Set field 0 to 99, then read it back
    var args = [_]u64{99};
    var results = [_]u64{0};
    try vm.invoke(&inst, "stest2", &args, &results);
    try testing.expectEqual(@as(u64, 99), results[0]);
}

test "array VM integration — array.new + array.get + array.len" {
    const Store = @import("store.zig").Store;
    const Instance = @import("instance.zig").Instance;
    const Vm = @import("vm.zig").Vm;

    // type 0 = array (mut i32), type 1 = func (i32 init, i32 len) -> (i32)
    // func: local.get 0, local.get 1, array.new 0, i32.const 0, array.get 0, end
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // Type section (size=10): 2 types
        0x01, 0x0A,
        0x02,
        0x5E, 0x7F, 0x01, // array (mut i32)
        0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F, // func (i32 i32) -> (i32)
        // Function section
        0x03, 0x02, 0x01, 0x01,
        // Export section: "atest"
        0x07, 0x09, 0x01, 0x05, 'a', 't', 'e', 's', 't', 0x00, 0x00,
        // Code section (body = 1+2+2+3+2+3+1 = 14, section = 1+1+14 = 16)
        0x0A, 0x10,
        0x01, 0x0E,
        0x00, // 0 locals
        0x20, 0x00, // local.get 0 (init_val)
        0x20, 0x01, // local.get 1 (len)
        0xFB, 0x06, 0x00, // array.new 0
        0x41, 0x00, // i32.const 0 (index)
        0xFB, 0x0B, 0x00, // array.get 0
        0x0B,
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
    // array.new with init=42, len=3, then array.get at index 0 -> 42
    var args = [_]u64{ 42, 3 };
    var results = [_]u64{0};
    try vm.invoke(&inst, "atest", &args, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);
}

test "i31 VM integration — ref.i31 + i31.get_s round-trip" {
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

test "cast VM integration — ref.test i31ref against i31" {
    const Store = @import("store.zig").Store;
    const Instance = @import("instance.zig").Instance;
    const Vm = @import("vm.zig").Vm;

    // Wasm binary:
    // (func (export "rt") (param i32) (result i32)
    //   local.get 0       ;; i32 param
    //   ref.i31            ;; -> i31ref
    //   ref.test i31       ;; -> i32 (1 if matches)
    // )
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // magic + version
        // Type section: (i32) -> (i32)
        0x01, 0x06, 0x01, 0x60, 0x01, 0x7F, 0x01, 0x7F,
        // Function section
        0x03, 0x02, 0x01, 0x00,
        // Export section: "rt" -> func 0
        0x07, 0x06, 0x01, 0x02, 'r', 't', 0x00, 0x00,
        // Code section
        0x0A, 0x0B, // section id=10, size=11
        0x01, // 1 body
        0x09, // body size = 9
        0x00, // 0 locals
        0x20, 0x00, // local.get 0
        0xFB, 0x1C, // ref.i31
        0xFB, 0x14, // ref.test
        0x6C, // heap type = i31 (-20 as signed LEB128)
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
    var args = [_]u64{42};
    var results = [_]u64{0};
    try vm.invoke(&inst, "rt", &args, &results);
    try testing.expectEqual(@as(u64, 1), results[0]); // i31ref matches i31 → 1

    // Test ref.test against eq (i31 is subtype of eq) → should also return 1
    // Reuse same module/instance but with a different test encoding:
    // We test against HEAP_ANY which all non-null refs match
}

test "cast VM integration — ref.cast null traps" {
    const Store = @import("store.zig").Store;
    const Instance = @import("instance.zig").Instance;
    const Vm = @import("vm.zig").Vm;

    // (func (export "rc") (result i32)
    //   ref.null i31      ;; push null i31ref
    //   ref.cast i31      ;; cast null → trap
    //   i31.get_s          ;; unreachable
    // )
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // Type section: () -> (i32)
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,
        // Function section
        0x03, 0x02, 0x01, 0x00,
        // Export section: "rc" -> func 0
        0x07, 0x06, 0x01, 0x02, 'r', 'c', 0x00, 0x00,
        // Code section
        0x0A, 0x0B, // section id=10, size=11
        0x01, // 1 body
        0x09, // body size = 9
        0x00, // 0 locals
        0xD0, 0x6C, // ref.null i31 (0xD0 + heaptype i31 = 0x6C)
        0xFB, 0x16, // ref.cast
        0x6C, // heap type = i31
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
    var args = [_]u64{};
    var results = [_]u64{0};
    // ref.cast on null should trap
    try testing.expectError(error.Trap, vm.invoke(&inst, "rc", &args, &results));
}
