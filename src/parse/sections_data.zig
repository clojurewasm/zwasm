//! Wasm data section decoder (Wasm 2.0 §5.5.13). Extracted from
//! `sections.zig` per ADR-0096 (D-141 sweep, follow-up to
//! ADR-0095). Supports all 3 data-segment forms (0 active/0,
//! 1 passive, 2 active/explicit-memidx).

const std = @import("std");
const leb128 = @import("../support/leb128.zig");
const sections = @import("sections.zig");

const Allocator = std.mem.Allocator;

pub const DataKind = enum { active, passive };

pub const DataSegment = struct {
    kind: DataKind,
    /// memidx for active segments (kind 0/2). Always 0 in chunk 4b
    /// since multi-memory is post-v0.1.0.
    memidx: u32 = 0,
    /// Init-expression bytes for active segments (terminated by the
    /// trailing `end`). Empty for passive. Borrowed from the input.
    offset_expr: []const u8 = &.{},
    /// The actual data bytes. Borrowed from the input.
    bytes: []const u8,
};

pub const Datas = struct {
    arena: std.heap.ArenaAllocator,
    items: []DataSegment,

    pub fn deinit(self: *Datas) void {
        self.arena.deinit();
    }
};

/// Decode the body of a data section (`SectionId.data`):
///   vec(data), data has three forms (Wasm 2.0 §5.5.13):
///     0x00 expr bytes               — active, memidx 0
///     0x01 bytes                    — passive
///     0x02 memidx expr bytes        — active, explicit memidx
/// `bytes` is `vec(byte)` = uleb size + raw bytes. `expr` is the
/// init-expression terminated by 0x0B.
///
/// Multi-memory (form 0x02 with non-zero memidx) is post-v0.1.0;
/// chunk 4b accepts memidx but does not require it to be 0.
pub fn decodeData(parent_alloc: Allocator, body: []const u8) sections.Error!Datas {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(DataSegment, count);

    for (items) |*d| {
        const flag = try leb128.readUleb128(u32, body, &pos);
        switch (flag) {
            0 => {
                const expr_start = pos;
                try sections.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                const size = try leb128.readUleb128(u32, body, &pos);
                const size_us: usize = @intCast(size);
                if (size_us > body.len - pos) return sections.Error.UnexpectedEnd;
                d.* = .{
                    .kind = .active,
                    .memidx = 0,
                    .offset_expr = expr,
                    .bytes = body[pos .. pos + size_us],
                };
                pos += size_us;
            },
            1 => {
                const size = try leb128.readUleb128(u32, body, &pos);
                const size_us: usize = @intCast(size);
                if (size_us > body.len - pos) return sections.Error.UnexpectedEnd;
                d.* = .{
                    .kind = .passive,
                    .bytes = body[pos .. pos + size_us],
                };
                pos += size_us;
            },
            2 => {
                const memidx = try leb128.readUleb128(u32, body, &pos);
                const expr_start = pos;
                try sections.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                const size = try leb128.readUleb128(u32, body, &pos);
                const size_us: usize = @intCast(size);
                if (size_us > body.len - pos) return sections.Error.UnexpectedEnd;
                d.* = .{
                    .kind = .active,
                    .memidx = memidx,
                    .offset_expr = expr,
                    .bytes = body[pos .. pos + size_us],
                };
                pos += size_us;
            },
            else => return sections.Error.InvalidFunctype, // reused: bad flag byte
        }
    }

    if (pos != body.len) return sections.Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

const testing = std.testing;

test "decodeData: empty section" {
    var d = try decodeData(testing.allocator, &[_]u8{0x00});
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), d.items.len);
}

test "decodeData: single active segment with i32.const 0 offset + 3 bytes" {
    // count=1; flag=0; offset_expr = 0x41 0x00 0x0B; size=3; bytes=AA BB CC
    const body = [_]u8{
        0x01,
        0x00,
        0x41,
        0x00,
        0x0B,
        0x03,
        0xAA,
        0xBB,
        0xCC,
    };
    var d = try decodeData(testing.allocator, &body);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 1), d.items.len);
    try testing.expectEqual(DataKind.active, d.items[0].kind);
    try testing.expectEqual(@as(u32, 0), d.items[0].memidx);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x00, 0x0B }, d.items[0].offset_expr);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, d.items[0].bytes);
}

test "decodeData: single passive segment with 4 bytes" {
    // count=1; flag=1; size=4; bytes
    const body = [_]u8{ 0x01, 0x01, 0x04, 0x11, 0x22, 0x33, 0x44 };
    var d = try decodeData(testing.allocator, &body);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 1), d.items.len);
    try testing.expectEqual(DataKind.passive, d.items[0].kind);
    try testing.expectEqualSlices(u8, &[_]u8{}, d.items[0].offset_expr);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, d.items[0].bytes);
}

test "decodeData: active form 2 with explicit memidx" {
    // count=1; flag=2; memidx=0; offset_expr = 0x41 0x10 0x0B; size=2; bytes
    const body = [_]u8{
        0x01,
        0x02,
        0x00,
        0x41,
        0x10,
        0x0B,
        0x02,
        0xDE,
        0xAD,
    };
    var d = try decodeData(testing.allocator, &body);
    defer d.deinit();
    try testing.expectEqual(DataKind.active, d.items[0].kind);
    try testing.expectEqual(@as(u32, 0), d.items[0].memidx);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, d.items[0].bytes);
}

test "decodeData: rejects unknown flag byte" {
    const body = [_]u8{ 0x01, 0x05 };
    try testing.expectError(sections.Error.InvalidFunctype, decodeData(testing.allocator, &body));
}
