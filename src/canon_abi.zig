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

// ── String Lifting (memory → component string) ──────────────────────

pub const StringEncoding = component.StringEncoding;

/// Lift a string from linear memory (UTF-8 encoding).
/// ptr and len are core i32 values from the flat representation.
pub fn liftStringUtf8(memory: []const u8, ptr: u32, len: u32) ?[]const u8 {
    if (ptr + len > memory.len) return null;
    const bytes = memory[ptr..][0..len];
    // Validate UTF-8
    if (!std.unicode.utf8ValidateSlice(bytes)) return null;
    return bytes;
}

/// Lift a string from linear memory (UTF-16 encoding).
/// Returns UTF-8 encoded bytes (allocated).
pub fn liftStringUtf16(alloc: Allocator, memory: []const u8, ptr: u32, len: u32) ?[]u8 {
    // len is number of u16 code units; byte length = len * 2
    const byte_len = @as(u64, len) * 2;
    if (ptr + byte_len > memory.len) return null;
    if (ptr % 2 != 0) return null; // must be aligned

    const u16_slice = std.mem.bytesAsSlice(u16, memory[ptr..][0..@intCast(byte_len)]);

    // Decode UTF-16 to UTF-8
    var buf = std.ArrayList(u8).init(alloc);
    var i: usize = 0;
    while (i < u16_slice.len) {
        const code_unit = std.mem.littleToNative(u16, u16_slice[i]);
        i += 1;
        var codepoint: u21 = undefined;

        if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
            // High surrogate — need low surrogate
            if (i >= u16_slice.len) {
                buf.deinit();
                return null;
            }
            const low = std.mem.littleToNative(u16, u16_slice[i]);
            i += 1;
            if (low < 0xDC00 or low > 0xDFFF) {
                buf.deinit();
                return null;
            }
            codepoint = @intCast((@as(u32, code_unit - 0xD800) << 10) + (low - 0xDC00) + 0x10000);
        } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
            // Lone low surrogate
            buf.deinit();
            return null;
        } else {
            codepoint = code_unit;
        }

        var utf8_buf: [4]u8 = undefined;
        const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
            buf.deinit();
            return null;
        };
        buf.appendSlice(utf8_buf[0..utf8_len]) catch {
            buf.deinit();
            return null;
        };
    }

    return buf.toOwnedSlice() catch {
        buf.deinit();
        return null;
    };
}

/// Lower a UTF-8 string to linear memory. Returns (ptr, byte_len).
/// Writes the string bytes to memory at the given offset.
pub fn lowerStringUtf8(memory: []u8, offset: u32, str: []const u8) ?struct { ptr: u32, len: u32 } {
    if (offset + str.len > memory.len) return null;
    @memcpy(memory[offset..][0..str.len], str);
    return .{ .ptr = offset, .len = @intCast(str.len) };
}

/// Lower a UTF-8 string to linear memory as UTF-16. Returns (ptr, code_unit_count).
pub fn lowerStringUtf16(memory: []u8, offset: u32, str: []const u8) ?struct { ptr: u32, len: u32 } {
    if (offset % 2 != 0) return null; // must be aligned

    var utf8_view = std.unicode.Utf8View.initUnchecked(str);
    var iter = utf8_view.iterator();
    var pos: u32 = offset;
    var count: u32 = 0;

    while (iter.nextCodepoint()) |cp| {
        if (cp >= 0x10000) {
            // Surrogate pair
            if (pos + 4 > memory.len) return null;
            const hi: u16 = @intCast(((@as(u32, cp) - 0x10000) >> 10) + 0xD800);
            const lo: u16 = @intCast(((@as(u32, cp) - 0x10000) & 0x3FF) + 0xDC00);
            std.mem.writeInt(u16, memory[pos..][0..2], hi, .little);
            std.mem.writeInt(u16, memory[pos + 2 ..][0..2], lo, .little);
            pos += 4;
            count += 2;
        } else {
            if (pos + 2 > memory.len) return null;
            std.mem.writeInt(u16, memory[pos..][0..2], @intCast(cp), .little);
            pos += 2;
            count += 1;
        }
    }

    return .{ .ptr = offset, .len = count };
}

// ── Compound Type Layout ─────────────────────────────────────────────

/// Compute memory offset aligned to given alignment.
pub fn alignTo(offset: u32, alignment: u32) u32 {
    if (alignment == 0) return offset;
    return (offset + alignment - 1) & ~(alignment - 1);
}

/// Discriminant size in bytes for a variant/enum with `case_count` cases.
pub fn discriminantSize(case_count: u32) u32 {
    if (case_count <= 0xFF) return 1;
    if (case_count <= 0xFFFF) return 2;
    return 4;
}

/// Load a u32 from linear memory at given offset (little-endian).
pub fn loadU32(memory: []const u8, offset: u32) ?u32 {
    if (offset + 4 > memory.len) return null;
    return std.mem.readInt(u32, memory[offset..][0..4], .little);
}

/// Store a u32 to linear memory at given offset (little-endian).
pub fn storeU32(memory: []u8, offset: u32, value: u32) bool {
    if (offset + 4 > memory.len) return false;
    std.mem.writeInt(u32, memory[offset..][0..4], value, .little);
    return true;
}

/// Load an i32 from linear memory at given offset (little-endian).
pub fn loadI32(memory: []const u8, offset: u32) ?i32 {
    if (offset + 4 > memory.len) return null;
    return std.mem.readInt(i32, memory[offset..][0..4], .little);
}

/// Store an i32 to linear memory at given offset (little-endian).
pub fn storeI32(memory: []u8, offset: u32, value: i32) bool {
    if (offset + 4 > memory.len) return false;
    std.mem.writeInt(i32, memory[offset..][0..4], value, .little);
    return true;
}

/// Load a u8 from linear memory.
pub fn loadU8(memory: []const u8, offset: u32) ?u8 {
    if (offset >= memory.len) return null;
    return memory[offset];
}

/// Store a u8 to linear memory.
pub fn storeU8(memory: []u8, offset: u32, value: u8) bool {
    if (offset >= memory.len) return false;
    memory[offset] = value;
    return true;
}

/// Load a discriminant from linear memory (size 1, 2, or 4 bytes).
pub fn loadDiscriminant(memory: []const u8, offset: u32, disc_size: u32) ?u32 {
    return switch (disc_size) {
        1 => @as(u32, loadU8(memory, offset) orelse return null),
        2 => blk: {
            if (offset + 2 > memory.len) break :blk null;
            break :blk @as(u32, std.mem.readInt(u16, memory[offset..][0..2], .little));
        },
        4 => loadU32(memory, offset),
        else => null,
    };
}

/// Store a discriminant to linear memory.
pub fn storeDiscriminant(memory: []u8, offset: u32, disc_size: u32, value: u32) bool {
    return switch (disc_size) {
        1 => storeU8(memory, offset, @intCast(value & 0xFF)),
        2 => blk: {
            if (offset + 2 > memory.len) break :blk false;
            std.mem.writeInt(u16, memory[offset..][0..2], @intCast(value & 0xFFFF), .little);
            break :blk true;
        },
        4 => storeU32(memory, offset, value),
        else => false,
    };
}

/// Option layout: [disc:1][padding][payload]
/// Returns (disc_offset, payload_offset, total_size)
pub fn optionLayout(payload_size: u32, payload_align: u32) struct { disc_offset: u32, payload_offset: u32, total_size: u32 } {
    const disc_size: u32 = 1;
    const payload_offset = alignTo(disc_size, payload_align);
    const total = payload_offset + payload_size;
    return .{ .disc_offset = 0, .payload_offset = payload_offset, .total_size = total };
}

/// Result layout: [disc:1][padding][payload (max of ok/err)]
pub fn resultLayout(ok_size: u32, ok_align: u32, err_size: u32, err_align: u32) struct { disc_offset: u32, payload_offset: u32, total_size: u32 } {
    const disc_size: u32 = 1;
    const max_align = @max(ok_align, err_align);
    const payload_offset = alignTo(disc_size, max_align);
    const max_payload = @max(ok_size, err_size);
    const total = alignTo(payload_offset + max_payload, @max(max_align, 1));
    return .{ .disc_offset = 0, .payload_offset = payload_offset, .total_size = total };
}

/// Variant layout: [disc:N][padding][payload (max of case payloads)]
pub fn variantLayout(case_count: u32, max_payload_size: u32, max_payload_align: u32) struct { disc_offset: u32, payload_offset: u32, total_size: u32 } {
    const disc_size = discriminantSize(case_count);
    const payload_align = @max(max_payload_align, 1);
    const payload_offset = alignTo(disc_size, payload_align);
    const total = alignTo(payload_offset + max_payload_size, @max(payload_align, disc_size));
    return .{ .disc_offset = 0, .payload_offset = payload_offset, .total_size = total };
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

// ── String Tests ─────────────────────────────────────────────────────

test "liftStringUtf8 — basic" {
    var mem: [64]u8 = undefined;
    @memcpy(mem[0..5], "hello");
    const s = liftStringUtf8(&mem, 0, 5).?;
    try std.testing.expectEqualStrings("hello", s);
}

test "liftStringUtf8 — unicode" {
    const utf8 = "日本語"; // 9 bytes
    var mem: [64]u8 = undefined;
    @memcpy(mem[0..utf8.len], utf8);
    const s = liftStringUtf8(&mem, 0, @intCast(utf8.len)).?;
    try std.testing.expectEqualStrings("日本語", s);
}

test "liftStringUtf8 — invalid utf8" {
    var mem = [_]u8{ 0xFF, 0xFE, 0x00, 0x00 };
    try std.testing.expect(liftStringUtf8(&mem, 0, 2) == null);
}

test "liftStringUtf8 — out of bounds" {
    var mem: [4]u8 = undefined;
    try std.testing.expect(liftStringUtf8(&mem, 0, 5) == null);
}

test "liftStringUtf16 — basic ASCII" {
    // "Hi" in UTF-16LE: 0x48 0x00, 0x69 0x00
    var mem = [_]u8{ 0x48, 0x00, 0x69, 0x00 };
    const s = liftStringUtf16(std.testing.allocator, &mem, 0, 2).?;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("Hi", s);
}

test "liftStringUtf16 — surrogate pair" {
    // U+1F600 (grinning face) = D83D DE00 in UTF-16
    var mem = [_]u8{ 0x3D, 0xD8, 0x00, 0xDE };
    const s = liftStringUtf16(std.testing.allocator, &mem, 0, 2).?;
    defer std.testing.allocator.free(s);
    // U+1F600 in UTF-8: F0 9F 98 80
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", s);
}

test "lowerStringUtf8 — basic" {
    var mem: [64]u8 = undefined;
    const result = lowerStringUtf8(&mem, 0, "hello").?;
    try std.testing.expectEqual(@as(u32, 0), result.ptr);
    try std.testing.expectEqual(@as(u32, 5), result.len);
    try std.testing.expectEqualStrings("hello", mem[0..5]);
}

test "lowerStringUtf16 — basic ASCII" {
    var mem: [64]u8 = undefined;
    const result = lowerStringUtf16(&mem, 0, "Hi").?;
    try std.testing.expectEqual(@as(u32, 0), result.ptr);
    try std.testing.expectEqual(@as(u32, 2), result.len); // 2 code units
    // Verify UTF-16LE bytes
    try std.testing.expectEqual(@as(u16, 'H'), std.mem.readInt(u16, mem[0..2], .little));
    try std.testing.expectEqual(@as(u16, 'i'), std.mem.readInt(u16, mem[2..4], .little));
}

test "lowerStringUtf16 — surrogate pair" {
    var mem: [64]u8 = undefined;
    const result = lowerStringUtf16(&mem, 0, "\xF0\x9F\x98\x80").?; // U+1F600
    try std.testing.expectEqual(@as(u32, 2), result.len); // 2 code units (surrogate pair)
    try std.testing.expectEqual(@as(u16, 0xD83D), std.mem.readInt(u16, mem[0..2], .little));
    try std.testing.expectEqual(@as(u16, 0xDE00), std.mem.readInt(u16, mem[2..4], .little));
}

// ── Compound Type Tests ──────────────────────────────────────────────

test "alignTo — alignment padding" {
    try std.testing.expectEqual(@as(u32, 0), alignTo(0, 4));
    try std.testing.expectEqual(@as(u32, 4), alignTo(1, 4));
    try std.testing.expectEqual(@as(u32, 4), alignTo(3, 4));
    try std.testing.expectEqual(@as(u32, 4), alignTo(4, 4));
    try std.testing.expectEqual(@as(u32, 8), alignTo(5, 4));
    try std.testing.expectEqual(@as(u32, 2), alignTo(1, 2));
    try std.testing.expectEqual(@as(u32, 1), alignTo(1, 1));
}

test "discriminantSize" {
    try std.testing.expectEqual(@as(u32, 1), discriminantSize(2)); // bool-like
    try std.testing.expectEqual(@as(u32, 1), discriminantSize(255));
    try std.testing.expectEqual(@as(u32, 2), discriminantSize(256));
    try std.testing.expectEqual(@as(u32, 2), discriminantSize(65535));
    try std.testing.expectEqual(@as(u32, 4), discriminantSize(65536));
}

test "loadU32/storeU32 — roundtrip" {
    var mem: [16]u8 = undefined;
    try std.testing.expect(storeU32(&mem, 0, 0xDEADBEEF));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), loadU32(&mem, 0).?);
    try std.testing.expect(storeU32(&mem, 4, 42));
    try std.testing.expectEqual(@as(u32, 42), loadU32(&mem, 4).?);
}

test "loadDiscriminant — different sizes" {
    var mem = [_]u8{ 0x03, 0x00, 0x01, 0x00, 0x05, 0x00, 0x00, 0x00 };
    // 1-byte discriminant
    try std.testing.expectEqual(@as(u32, 3), loadDiscriminant(&mem, 0, 1).?);
    // 2-byte discriminant
    try std.testing.expectEqual(@as(u32, 3), loadDiscriminant(&mem, 0, 2).?);
    try std.testing.expectEqual(@as(u32, 1), loadDiscriminant(&mem, 2, 2).?);
    // 4-byte discriminant
    try std.testing.expectEqual(@as(u32, 0x00010003), loadDiscriminant(&mem, 0, 4).?);
}

test "storeDiscriminant — different sizes" {
    var mem: [8]u8 = undefined;
    @memset(&mem, 0);
    try std.testing.expect(storeDiscriminant(&mem, 0, 1, 5));
    try std.testing.expectEqual(@as(u8, 5), mem[0]);
    try std.testing.expect(storeDiscriminant(&mem, 2, 2, 0x1234));
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, mem[2..4], .little));
}

test "optionLayout — u32 payload" {
    // option<u32>: disc(1) + pad(3) + payload(4) = 8
    const layout = optionLayout(4, 4);
    try std.testing.expectEqual(@as(u32, 0), layout.disc_offset);
    try std.testing.expectEqual(@as(u32, 4), layout.payload_offset);
    try std.testing.expectEqual(@as(u32, 8), layout.total_size);
}

test "optionLayout — u8 payload" {
    // option<u8>: disc(1) + payload(1) = 2
    const layout = optionLayout(1, 1);
    try std.testing.expectEqual(@as(u32, 0), layout.disc_offset);
    try std.testing.expectEqual(@as(u32, 1), layout.payload_offset);
    try std.testing.expectEqual(@as(u32, 2), layout.total_size);
}

test "resultLayout — ok=u32, err=string" {
    // result<u32, string>: disc(1) + pad(3) + max_payload(8) = 12
    const layout = resultLayout(4, 4, 8, 4);
    try std.testing.expectEqual(@as(u32, 0), layout.disc_offset);
    try std.testing.expectEqual(@as(u32, 4), layout.payload_offset);
    try std.testing.expectEqual(@as(u32, 12), layout.total_size);
}

test "variantLayout — 3 cases" {
    // variant with 3 cases, max payload 4 bytes, align 4
    const layout = variantLayout(3, 4, 4);
    try std.testing.expectEqual(@as(u32, 0), layout.disc_offset);
    try std.testing.expectEqual(@as(u32, 4), layout.payload_offset); // disc(1) aligned to 4
    try std.testing.expectEqual(@as(u32, 8), layout.total_size);
}

test "memory ops — option<u32> write and read" {
    var mem: [16]u8 = undefined;
    @memset(&mem, 0);

    const layout = optionLayout(4, 4);

    // Write some(42)
    try std.testing.expect(storeDiscriminant(&mem, layout.disc_offset, 1, 1)); // some=1
    try std.testing.expect(storeU32(&mem, layout.payload_offset, 42));

    // Read back
    const disc = loadDiscriminant(&mem, layout.disc_offset, 1).?;
    try std.testing.expectEqual(@as(u32, 1), disc);
    const val = loadU32(&mem, layout.payload_offset).?;
    try std.testing.expectEqual(@as(u32, 42), val);
}

test "memory ops — result<u32, u32> ok case" {
    var mem: [16]u8 = undefined;
    @memset(&mem, 0);

    const layout = resultLayout(4, 4, 4, 4);

    // Write ok(100)
    try std.testing.expect(storeDiscriminant(&mem, layout.disc_offset, 1, 0)); // ok=0
    try std.testing.expect(storeU32(&mem, layout.payload_offset, 100));

    // Read back
    try std.testing.expectEqual(@as(u32, 0), loadDiscriminant(&mem, layout.disc_offset, 1).?);
    try std.testing.expectEqual(@as(u32, 100), loadU32(&mem, layout.payload_offset).?);
}

test "memory ops — enum discriminant" {
    var mem: [4]u8 = undefined;
    @memset(&mem, 0);

    // enum with 3 cases, write case 2
    try std.testing.expect(storeDiscriminant(&mem, 0, discriminantSize(3), 2));
    try std.testing.expectEqual(@as(u32, 2), loadDiscriminant(&mem, 0, discriminantSize(3)).?);
}
