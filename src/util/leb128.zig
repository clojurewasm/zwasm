//! Unsigned / signed LEB128 readers (Zone 0 — no upward imports).
//!
//! Byte-slice cursor form: `bytes` is the input, `pos` is advanced
//! past the consumed bytes. No allocation. Single pass per
//! ROADMAP §P6 — overlong / truncation checks happen inline,
//! never via a post-decode wrapper.
//!
//! `Error.Truncated`: input ended before a terminator byte.
//! `Error.Overlong`:  encoding exceeded the maximum byte count
//!   for the destination type (continuation bit still set on the
//!   last permitted byte).
//! `Error.Overflow`:  the decoded value did not fit in the
//!   destination type — for unsigned, unused bits of the final
//!   byte were non-zero; for signed, those bits did not all match
//!   the sign bit (rejects negative-zero / non-canonical padding).

const std = @import("std");

pub const Error = error{
    Truncated,
    Overlong,
    Overflow,
};

pub fn readUleb128(comptime T: type, bytes: []const u8, pos: *usize) Error!T {
    const ti = @typeInfo(T);
    comptime std.debug.assert(ti == .int and ti.int.signedness == .unsigned);
    const width: u16 = @bitSizeOf(T);
    const max_bytes: usize = (@as(usize, width) + 6) / 7;
    const ShiftT = std.math.Log2Int(T);

    var result: T = 0;
    var shift: u16 = 0;
    var i: usize = 0;
    while (i < max_bytes) : (i += 1) {
        if (pos.* >= bytes.len) return Error.Truncated;
        const byte = bytes[pos.*];
        pos.* += 1;
        const data: u8 = byte & 0x7F;

        if (i == max_bytes - 1) {
            const valid_bits: u16 = width - shift;
            const mask: u8 = if (valid_bits >= 7)
                0x7F
            else
                @intCast((@as(u16, 1) << @intCast(valid_bits)) - 1);
            if ((data & ~mask) != 0) return Error.Overflow;
        }
        result |= @as(T, data) << @as(ShiftT, @intCast(shift));

        if ((byte & 0x80) == 0) return result;
        shift += 7;
    }
    return Error.Overlong;
}

test "readUleb128 u32: 0x00 -> 0" {
    var pos: usize = 0;
    const v = try readUleb128(u32, &[_]u8{0x00}, &pos);
    try std.testing.expectEqual(@as(u32, 0), v);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readUleb128 u32: 0x7F -> 127" {
    var pos: usize = 0;
    const v = try readUleb128(u32, &[_]u8{0x7F}, &pos);
    try std.testing.expectEqual(@as(u32, 127), v);
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readUleb128 u32: 0x80 0x01 -> 128" {
    var pos: usize = 0;
    const v = try readUleb128(u32, &[_]u8{ 0x80, 0x01 }, &pos);
    try std.testing.expectEqual(@as(u32, 128), v);
    try std.testing.expectEqual(@as(usize, 2), pos);
}

test "readUleb128 u32: max" {
    // 2^32 - 1 = 0xFFFFFFFF — encodes as 0xFF 0xFF 0xFF 0xFF 0x0F.
    var pos: usize = 0;
    const v = try readUleb128(u32, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F }, &pos);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), v);
    try std.testing.expectEqual(@as(usize, 5), pos);
}

test "readUleb128 u32: overlong (6 bytes)" {
    // 6th continuation byte is past the 5-byte budget for u32.
    var pos: usize = 0;
    const r = readUleb128(u32, &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, &pos);
    try std.testing.expectError(Error.Overlong, r);
}

test "readUleb128 u32: overflow on final-byte unused bits" {
    // 5th byte 0x10 has bit 4 set; only the bottom 4 bits are valid for u32.
    var pos: usize = 0;
    const r = readUleb128(u32, &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x10 }, &pos);
    try std.testing.expectError(Error.Overflow, r);
}

test "readUleb128 u32: truncated mid-encoding" {
    var pos: usize = 0;
    const r = readUleb128(u32, &[_]u8{ 0x80, 0x80 }, &pos);
    try std.testing.expectError(Error.Truncated, r);
}

test "readUleb128 u32: empty input" {
    var pos: usize = 0;
    const r = readUleb128(u32, &[_]u8{}, &pos);
    try std.testing.expectError(Error.Truncated, r);
}

test "readUleb128 u64: max" {
    var pos: usize = 0;
    const v = try readUleb128(
        u64,
        &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 },
        &pos,
    );
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), v);
    try std.testing.expectEqual(@as(usize, 10), pos);
}

test "readUleb128 sequential reads advance pos" {
    var pos: usize = 0;
    const buf = [_]u8{ 0x05, 0x80, 0x01 };
    try std.testing.expectEqual(@as(u32, 5), try readUleb128(u32, &buf, &pos));
    try std.testing.expectEqual(@as(usize, 1), pos);
    try std.testing.expectEqual(@as(u32, 128), try readUleb128(u32, &buf, &pos));
    try std.testing.expectEqual(@as(usize, 3), pos);
}

pub fn readSleb128(comptime T: type, bytes: []const u8, pos: *usize) Error!T {
    const ti = @typeInfo(T);
    comptime std.debug.assert(ti == .int and ti.int.signedness == .signed);
    const width: u16 = @bitSizeOf(T);
    const max_bytes: usize = (@as(usize, width) + 6) / 7;
    const U = @Int(.unsigned, width);
    const ShiftU = std.math.Log2Int(U);

    var result: U = 0;
    var shift: u16 = 0;
    var i: usize = 0;
    while (i < max_bytes) : (i += 1) {
        if (pos.* >= bytes.len) return Error.Truncated;
        const byte = bytes[pos.*];
        pos.* += 1;
        const data: u8 = byte & 0x7F;
        const cont = (byte & 0x80) != 0;
        const valid_bits: u16 = @min(@as(u16, 7), width - shift);

        if (!cont) {
            if (valid_bits < 7) {
                const sign_bit_pos: u3 = @intCast(valid_bits - 1);
                const sign: u8 = (data >> sign_bit_pos) & 1;
                const lsb_mask: u8 = (@as(u8, 1) << @as(u3, @intCast(valid_bits))) -% 1;
                const upper_mask: u8 = 0x7F & ~lsb_mask;
                const expected: u8 = if (sign == 1) upper_mask else 0;
                if ((data & upper_mask) != expected) return Error.Overflow;
            }
            result |= @as(U, data) << @as(ShiftU, @intCast(shift));

            const sign_bit_pos: u3 = @intCast(valid_bits - 1);
            const sign: u1 = @intCast((data >> sign_bit_pos) & 1);
            if (sign == 1) {
                const total_bits: u16 = shift + valid_bits;
                if (total_bits < width) {
                    const lower_mask: U = (@as(U, 1) << @as(ShiftU, @intCast(total_bits))) - 1;
                    result |= ~lower_mask;
                }
            }
            return @bitCast(result);
        }
        if (i == max_bytes - 1) return Error.Overlong;
        result |= @as(U, data) << @as(ShiftU, @intCast(shift));
        shift += 7;
    }
    unreachable;
}

test "readSleb128 i32: 0 -> 0" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(i32, 0), try readSleb128(i32, &[_]u8{0x00}, &pos));
    try std.testing.expectEqual(@as(usize, 1), pos);
}

test "readSleb128 i32: -1 -> 0x7F" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(i32, -1), try readSleb128(i32, &[_]u8{0x7F}, &pos));
}

test "readSleb128 i32: 64 (two bytes)" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(i32, 64), try readSleb128(i32, &[_]u8{ 0xC0, 0x00 }, &pos));
}

test "readSleb128 i32: -64 (single byte sign-extended)" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(i32, -64), try readSleb128(i32, &[_]u8{0x40}, &pos));
}

test "readSleb128 i32: -65 (two bytes)" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(i32, -65), try readSleb128(i32, &[_]u8{ 0xBF, 0x7F }, &pos));
}

test "readSleb128 i32: max positive (2^31 - 1)" {
    var pos: usize = 0;
    const v = try readSleb128(i32, &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x07 }, &pos);
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), v);
}

test "readSleb128 i32: min (-2^31)" {
    var pos: usize = 0;
    const v = try readSleb128(i32, &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x78 }, &pos);
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), v);
}

test "readSleb128 i32: overflow on inconsistent sign padding" {
    // Final byte 0x10: sign bit (bit 3) = 0, but bit 4 = 1. Padding mismatch.
    var pos: usize = 0;
    const r = readSleb128(i32, &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x10 }, &pos);
    try std.testing.expectError(Error.Overflow, r);
}

test "readSleb128 i32: overlong (6th continuation byte)" {
    var pos: usize = 0;
    const r = readSleb128(i32, &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, &pos);
    try std.testing.expectError(Error.Overlong, r);
}

test "readSleb128 i32: truncated mid-encoding" {
    var pos: usize = 0;
    const r = readSleb128(i32, &[_]u8{ 0xC0, 0x80 }, &pos);
    try std.testing.expectError(Error.Truncated, r);
}

test "readSleb128 i64: max positive" {
    var pos: usize = 0;
    const v = try readSleb128(
        i64,
        &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 },
        &pos,
    );
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), v);
}

test "readSleb128 i64: min" {
    var pos: usize = 0;
    const v = try readSleb128(
        i64,
        &[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F },
        &pos,
    );
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), v);
}
