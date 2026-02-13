// Canonical ABI — lifts and lowers values between component types and core wasm.
// Implements the Component Model Canonical ABI spec.

const std = @import("std");
const Allocator = std.mem.Allocator;
const component = @import("component.zig");
const ValType = component.ValType;

// ── Core Value ────────────────────────────────────────────────────────

/// A core wasm value (i32, i64, f32, f64).
pub const CoreValue = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
};

/// A component-level value.
pub const ComponentValue = union(enum) {
    bool_: bool,
    s8: i8,
    u8_: u8,
    s16: i16,
    u16_: u16,
    s32: i32,
    u32_: u32,
    s64: i64,
    u64_: u64,
    f32_: f32,
    f64_: f64,
    char_: u21, // Unicode scalar value
    string_: []const u8,
    list: []const ComponentValue,
    record: []const FieldValue,
    variant: VariantValue,
    enum_: u32, // case index
    flags: u32, // bit flags
    option: ?*const ComponentValue,
    result: ResultValue,
};

pub const FieldValue = struct {
    name: []const u8,
    value: ComponentValue,
};

pub const VariantValue = struct {
    case_idx: u32,
    payload: ?*const ComponentValue,
};

pub const ResultValue = struct {
    is_ok: bool,
    payload: ?*const ComponentValue,
};

// ── Scalar Lifting (core → component) ────────────────────────────────

/// Lift a core wasm i32 value to a component scalar type.
pub fn liftScalar(vt: ValType, core: CoreValue) ?ComponentValue {
    return switch (vt) {
        .bool_ => switch (core) {
            .i32 => |v| .{ .bool_ = v != 0 },
            else => null,
        },
        .s8 => switch (core) {
            .i32 => |v| .{ .s8 = @truncate(@as(u32, @bitCast(v))) },
            else => null,
        },
        .u8_ => switch (core) {
            .i32 => |v| .{ .u8_ = @truncate(@as(u32, @bitCast(v))) },
            else => null,
        },
        .s16 => switch (core) {
            .i32 => |v| .{ .s16 = @truncate(@as(u32, @bitCast(v))) },
            else => null,
        },
        .u16_ => switch (core) {
            .i32 => |v| .{ .u16_ = @truncate(@as(u32, @bitCast(v))) },
            else => null,
        },
        .s32 => switch (core) {
            .i32 => |v| .{ .s32 = v },
            else => null,
        },
        .u32_ => switch (core) {
            .i32 => |v| .{ .u32_ = @bitCast(v) },
            else => null,
        },
        .s64 => switch (core) {
            .i64 => |v| .{ .s64 = v },
            else => null,
        },
        .u64_ => switch (core) {
            .i64 => |v| .{ .u64_ = @bitCast(v) },
            else => null,
        },
        .f32_ => switch (core) {
            .f32 => |v| .{ .f32_ = v },
            else => null,
        },
        .f64_ => switch (core) {
            .f64 => |v| .{ .f64_ = v },
            else => null,
        },
        .char_ => switch (core) {
            .i32 => |v| blk: {
                const u: u32 = @bitCast(v);
                // Validate Unicode scalar value (0-0x10FFFF, excluding surrogates)
                if (u > 0x10FFFF) break :blk null;
                if (u >= 0xD800 and u <= 0xDFFF) break :blk null;
                break :blk .{ .char_ = @intCast(u) };
            },
            else => null,
        },
        else => null, // compound types handled separately
    };
}

// ── Scalar Lowering (component → core) ───────────────────────────────

/// Lower a component scalar value to a core wasm value.
pub fn lowerScalar(val: ComponentValue) ?CoreValue {
    return switch (val) {
        .bool_ => |v| .{ .i32 = if (v) 1 else 0 },
        .s8 => |v| .{ .i32 = @as(i32, v) },
        .u8_ => |v| .{ .i32 = @as(i32, v) },
        .s16 => |v| .{ .i32 = @as(i32, v) },
        .u16_ => |v| .{ .i32 = @as(i32, v) },
        .s32 => |v| .{ .i32 = v },
        .u32_ => |v| .{ .i32 = @bitCast(v) },
        .s64 => |v| .{ .i64 = v },
        .u64_ => |v| .{ .i64 = @bitCast(v) },
        .f32_ => |v| .{ .f32 = v },
        .f64_ => |v| .{ .f64 = v },
        .char_ => |v| .{ .i32 = @intCast(v) },
        else => null, // compound types handled separately
    };
}

// ── Flat Type Layout ─────────────────────────────────────────────────

/// Core wasm type for canonical ABI flat layout.
pub const CoreType = enum {
    i32,
    i64,
    f32,
    f64,
};

/// Returns the flat core type(s) for a component value type.
pub fn flatType(vt: ValType) ?CoreType {
    return switch (vt) {
        .bool_, .s8, .u8_, .s16, .u16_, .s32, .u32_, .char_ => .i32,
        .s64, .u64_ => .i64,
        .f32_ => .f32,
        .f64_ => .f64,
        else => null, // compound types need special handling
    };
}

/// Returns the byte size of a component value type in linear memory.
pub fn sizeOf(vt: ValType) ?u32 {
    return switch (vt) {
        .bool_, .s8, .u8_ => 1,
        .s16, .u16_ => 2,
        .s32, .u32_, .f32_, .char_ => 4,
        .s64, .u64_, .f64_ => 8,
        .string_ => 8, // ptr + len (i32 + i32)
        .list => 8, // ptr + len
        else => null,
    };
}

/// Returns the alignment of a component value type in linear memory.
pub fn alignOf(vt: ValType) ?u32 {
    return switch (vt) {
        .bool_, .s8, .u8_ => 1,
        .s16, .u16_ => 2,
        .s32, .u32_, .f32_, .char_ => 4,
        .s64, .u64_, .f64_, .string_, .list => 4,
        else => null,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "liftScalar — bool" {
    const t = liftScalar(.bool_, .{ .i32 = 0 }).?;
    try std.testing.expectEqual(false, t.bool_);
    const f = liftScalar(.bool_, .{ .i32 = 1 }).?;
    try std.testing.expectEqual(true, f.bool_);
    // Non-zero is true
    const nz = liftScalar(.bool_, .{ .i32 = 42 }).?;
    try std.testing.expectEqual(true, nz.bool_);
}

test "liftScalar — integers" {
    // u8
    try std.testing.expectEqual(@as(u8, 255), liftScalar(.u8_, .{ .i32 = 255 }).?.u8_);
    try std.testing.expectEqual(@as(u8, 0), liftScalar(.u8_, .{ .i32 = 256 }).?.u8_); // truncation

    // s8
    try std.testing.expectEqual(@as(i8, -1), liftScalar(.s8, .{ .i32 = -1 }).?.s8);

    // u16
    try std.testing.expectEqual(@as(u16, 1000), liftScalar(.u16_, .{ .i32 = 1000 }).?.u16_);

    // s32
    try std.testing.expectEqual(@as(i32, -42), liftScalar(.s32, .{ .i32 = -42 }).?.s32);

    // u32
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), liftScalar(.u32_, .{ .i32 = -1 }).?.u32_);

    // s64
    try std.testing.expectEqual(@as(i64, -1), liftScalar(.s64, .{ .i64 = -1 }).?.s64);

    // u64
    try std.testing.expectEqual(@as(u64, 42), liftScalar(.u64_, .{ .i64 = 42 }).?.u64_);
}

test "liftScalar — floats" {
    try std.testing.expectEqual(@as(f32, 3.14), liftScalar(.f32_, .{ .f32 = 3.14 }).?.f32_);
    try std.testing.expectEqual(@as(f64, 2.718), liftScalar(.f64_, .{ .f64 = 2.718 }).?.f64_);
}

test "liftScalar — char" {
    // Valid Unicode scalar
    try std.testing.expectEqual(@as(u21, 'A'), liftScalar(.char_, .{ .i32 = 0x41 }).?.char_);
    try std.testing.expectEqual(@as(u21, 0x1F600), liftScalar(.char_, .{ .i32 = 0x1F600 }).?.char_);

    // Invalid: surrogate
    try std.testing.expect(liftScalar(.char_, .{ .i32 = 0xD800 }) == null);
    // Invalid: too large
    try std.testing.expect(liftScalar(.char_, .{ .i32 = 0x110000 }) == null);
}

test "liftScalar — type mismatch" {
    // i64 value for bool type
    try std.testing.expect(liftScalar(.bool_, .{ .i64 = 0 }) == null);
    // i32 value for f64 type
    try std.testing.expect(liftScalar(.f64_, .{ .i32 = 0 }) == null);
}

test "lowerScalar — roundtrip" {
    // bool
    try std.testing.expectEqual(@as(i32, 1), lowerScalar(.{ .bool_ = true }).?.i32);
    try std.testing.expectEqual(@as(i32, 0), lowerScalar(.{ .bool_ = false }).?.i32);

    // integers
    try std.testing.expectEqual(@as(i32, 42), lowerScalar(.{ .u8_ = 42 }).?.i32);
    try std.testing.expectEqual(@as(i32, -1), lowerScalar(.{ .s8 = -1 }).?.i32);
    try std.testing.expectEqual(@as(i64, 100), lowerScalar(.{ .u64_ = 100 }).?.i64);

    // floats
    try std.testing.expectEqual(@as(f32, 1.5), lowerScalar(.{ .f32_ = 1.5 }).?.f32);
    try std.testing.expectEqual(@as(f64, 2.5), lowerScalar(.{ .f64_ = 2.5 }).?.f64);

    // char
    try std.testing.expectEqual(@as(i32, 0x41), lowerScalar(.{ .char_ = 'A' }).?.i32);
}

test "flatType — scalar mappings" {
    try std.testing.expectEqual(CoreType.i32, flatType(.bool_).?);
    try std.testing.expectEqual(CoreType.i32, flatType(.u8_).?);
    try std.testing.expectEqual(CoreType.i32, flatType(.s32).?);
    try std.testing.expectEqual(CoreType.i32, flatType(.char_).?);
    try std.testing.expectEqual(CoreType.i64, flatType(.s64).?);
    try std.testing.expectEqual(CoreType.i64, flatType(.u64_).?);
    try std.testing.expectEqual(CoreType.f32, flatType(.f32_).?);
    try std.testing.expectEqual(CoreType.f64, flatType(.f64_).?);
}

test "sizeOf — scalar sizes" {
    try std.testing.expectEqual(@as(u32, 1), sizeOf(.bool_).?);
    try std.testing.expectEqual(@as(u32, 1), sizeOf(.u8_).?);
    try std.testing.expectEqual(@as(u32, 2), sizeOf(.s16).?);
    try std.testing.expectEqual(@as(u32, 4), sizeOf(.u32_).?);
    try std.testing.expectEqual(@as(u32, 4), sizeOf(.char_).?);
    try std.testing.expectEqual(@as(u32, 8), sizeOf(.s64).?);
    try std.testing.expectEqual(@as(u32, 8), sizeOf(.f64_).?);
    try std.testing.expectEqual(@as(u32, 8), sizeOf(.string_).?);
}

test "alignOf — scalar alignments" {
    try std.testing.expectEqual(@as(u32, 1), alignOf(.bool_).?);
    try std.testing.expectEqual(@as(u32, 2), alignOf(.u16_).?);
    try std.testing.expectEqual(@as(u32, 4), alignOf(.u32_).?);
    try std.testing.expectEqual(@as(u32, 4), alignOf(.string_).?);
}
