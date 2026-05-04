//! Concrete parser context shared by frontend lowerer + feature
//! modules.
//!
//! `dispatch_table.zig` declares `ParserCtx` as an opaque type so
//! Zone 1 callers can pass the cursor through the dispatch table
//! without exposing the layout. Feature modules at
//! `src/feature/<feature>/` cast back to `Ctx` via
//! `Ctx.fromOpaque` to read immediates from the body.
//!
//! Zone 1 — imports Zone 0 (`support/leb128.zig`) + Zone 1
//! (`ir/dispatch_table.zig`).

const std = @import("std");

const leb128 = @import("../support/leb128.zig");
const dispatch = @import("../ir/dispatch_table.zig");

pub const Error = error{UnexpectedEnd} || leb128.Error;

pub const Ctx = struct {
    body: []const u8,
    pos: usize,

    pub fn init(body: []const u8) Ctx {
        return .{ .body = body, .pos = 0 };
    }

    pub fn readUleb32(self: *Ctx) leb128.Error!u32 {
        return leb128.readUleb128(u32, self.body, &self.pos);
    }

    pub fn readSleb32(self: *Ctx) leb128.Error!i32 {
        return leb128.readSleb128(i32, self.body, &self.pos);
    }

    pub fn readSleb64(self: *Ctx) leb128.Error!i64 {
        return leb128.readSleb128(i64, self.body, &self.pos);
    }

    pub fn readF32Bits(self: *Ctx) Error!u32 {
        if (self.body.len - self.pos < 4) return Error.UnexpectedEnd;
        const bits = std.mem.readInt(u32, self.body[self.pos..][0..4], .little);
        self.pos += 4;
        return bits;
    }

    pub const F64Bits = struct { lo: u32, hi: u32 };

    pub fn readF64Bits(self: *Ctx) Error!F64Bits {
        if (self.body.len - self.pos < 8) return Error.UnexpectedEnd;
        const lo = std.mem.readInt(u32, self.body[self.pos..][0..4], .little);
        const hi = std.mem.readInt(u32, self.body[self.pos..][4..8], .little);
        self.pos += 8;
        return .{ .lo = lo, .hi = hi };
    }

    pub fn opaqueSelf(self: *Ctx) *dispatch.ParserCtx {
        return @ptrCast(self);
    }

    pub fn fromOpaque(p: *dispatch.ParserCtx) *Ctx {
        return @ptrCast(@alignCast(p));
    }
};

const testing = std.testing;

test "Ctx.readUleb32 / readSleb32 advance cursor" {
    var ctx = Ctx.init(&[_]u8{ 0x05, 0x7F });
    try testing.expectEqual(@as(u32, 5), try ctx.readUleb32());
    try testing.expectEqual(@as(i32, -1), try ctx.readSleb32());
    try testing.expectEqual(@as(usize, 2), ctx.pos);
}

test "Ctx.readF32Bits / readF64Bits read raw little-endian" {
    var ctx = Ctx.init(&[_]u8{
        0x00, 0x00, 0x80, 0x3F, // f32 1.0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F, // f64 1.0
    });
    try testing.expectEqual(@as(u32, 0x3F800000), try ctx.readF32Bits());
    const f64b = try ctx.readF64Bits();
    try testing.expectEqual(@as(u32, 0x0000_0000), f64b.lo);
    try testing.expectEqual(@as(u32, 0x3FF0_0000), f64b.hi);
    try testing.expectEqual(@as(usize, 12), ctx.pos);
}

test "Ctx.readF32Bits truncated input fails" {
    var ctx = Ctx.init(&[_]u8{ 0x00, 0x00, 0x80 });
    try testing.expectError(Error.UnexpectedEnd, ctx.readF32Bits());
}

test "Ctx.opaqueSelf / fromOpaque round-trip the same address" {
    var ctx = Ctx.init(&[_]u8{0x00});
    const op = ctx.opaqueSelf();
    const back = Ctx.fromOpaque(op);
    try testing.expectEqual(@as(*Ctx, &ctx), back);
}
