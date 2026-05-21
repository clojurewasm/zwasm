//! Wasm code section decoder (Wasm §5.5.11). Extracted from
//! `sections.zig` per ADR-0096 (D-141 sweep, follow-up to
//! ADR-0095). Function bodies + locals expansion.

const std = @import("std");
const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");
const sections = @import("sections.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;

pub const CodeEntry = struct {
    /// Flattened locals: each `(count valtype)` decl is expanded so
    /// the validator/lowerer can index `locals[i]` directly.
    locals: []const ValType,
    /// Expression bytes (terminated by the implicit function-frame
    /// `end`). Borrowed from the input; the caller keeps the input
    /// alive for as long as `body` is referenced.
    body: []const u8,
};

pub const Codes = struct {
    arena: std.heap.ArenaAllocator,
    items: []CodeEntry,

    pub fn deinit(self: *Codes) void {
        self.arena.deinit();
    }
};

/// Decode the body of a code section:
///   codesec = vec(code)
///   code    = size:u32 locals:vec(local_decl) expr
///   local_decl = count:u32 valtype
/// Returns one `CodeEntry` per defined function. `entry.body` is a
/// borrowed slice into `body`; the caller keeps `body` alive for as
/// long as the result is used.
pub fn decodeCodes(parent_alloc: Allocator, body: []const u8) sections.Error!Codes {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const fn_count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(CodeEntry, fn_count);

    for (items) |*entry| {
        const size = try leb128.readUleb128(u32, body, &pos);
        const size_us: usize = @intCast(size);
        if (size_us > body.len - pos) return sections.Error.UnexpectedEnd;
        const code = body[pos .. pos + size_us];
        pos += size_us;

        var inner: usize = 0;
        const decl_count = try leb128.readUleb128(u32, code, &inner);

        // First pass: total locals so we can allocate exactly once.
        var probe = inner;
        var total: u64 = 0;
        for (0..decl_count) |_| {
            const c = try leb128.readUleb128(u32, code, &probe);
            total += c;
            if (probe >= code.len) return sections.Error.UnexpectedEnd;
            probe += 1; // skip the valtype byte
        }
        if (total > std.math.maxInt(u32)) return sections.Error.LocalsOverflow;

        const locals = try alloc.alloc(ValType, @intCast(total));
        var w: usize = 0;
        for (0..decl_count) |_| {
            const c = try leb128.readUleb128(u32, code, &inner);
            const t = try sections.readValType(code, &inner);
            for (0..c) |_| {
                locals[w] = t;
                w += 1;
            }
        }

        entry.* = .{ .locals = locals, .body = code[inner..] };
    }

    if (pos != body.len) return sections.Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

const testing = std.testing;

test "decodeCodes: empty section" {
    var c = try decodeCodes(testing.allocator, &[_]u8{0x00});
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.items.len);
}

test "decodeCodes: single function with no locals + bare end" {
    // count=1; size=2; locals_count=0; expr=0x0B
    const body = [_]u8{ 0x01, 0x02, 0x00, 0x0B };
    var c = try decodeCodes(testing.allocator, &body);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.items.len);
    try testing.expectEqual(@as(usize, 0), c.items[0].locals.len);
    try testing.expectEqualSlices(u8, &[_]u8{0x0B}, c.items[0].body);
}

test "decodeCodes: locals expansion (3 i32 + 2 i64)" {
    // count=1; size=N; locals_count=2; (3 i32) (2 i64); expr=0x0B
    const body = [_]u8{
        0x01, // fn count
        0x06, // body size = 6 bytes
        0x02, // 2 local decls
        0x03, 0x7F, // 3x i32
        0x02, 0x7E, // 2x i64
        0x0B, // end
    };
    var c = try decodeCodes(testing.allocator, &body);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.items.len);
    try testing.expectEqualSlices(
        ValType,
        &[_]ValType{ .i32, .i32, .i32, .i64, .i64 },
        c.items[0].locals,
    );
    try testing.expectEqualSlices(u8, &[_]u8{0x0B}, c.items[0].body);
}

test "decodeCodes: two functions, body slices borrow correctly" {
    const body = [_]u8{
        0x02,
        0x02, 0x00, 0x0B, // fn 0: no locals, end
        0x04, 0x00, 0x41, 0x07, 0x0B, // fn 1: no locals, i32.const 7, end
    };
    var c = try decodeCodes(testing.allocator, &body);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.items.len);
    try testing.expectEqualSlices(u8, &[_]u8{0x0B}, c.items[0].body);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x07, 0x0B }, c.items[1].body);
}

test "decodeCodes: rejects size overrun" {
    const body = [_]u8{ 0x01, 0xFF, 0x00 }; // size=255 but only 1 byte follows
    try testing.expectError(sections.Error.UnexpectedEnd, decodeCodes(testing.allocator, &body));
}

test "decodeCodes: rejects bad valtype in locals decl" {
    // 0x5F is unassigned in the Wasm 2.0 valtype space; reftype
    // bytes 0x70 / 0x6F are now accepted (see `decodeCodes: accepts
    // funcref local decl` below).
    const body = [_]u8{ 0x01, 0x04, 0x01, 0x01, 0x5F, 0x0B };
    try testing.expectError(sections.Error.BadValType, decodeCodes(testing.allocator, &body));
}

test "decodeCodes: accepts funcref local decl (Wasm 2.0 §5.3.1)" {
    // Function with `(local funcref)`. Per §4.5.3.1 locals are
    // initialised to null reftype; the parser only verifies the
    // declaration decodes.
    const body = [_]u8{ 0x01, 0x04, 0x01, 0x01, 0x70, 0x0B };
    var c = try decodeCodes(testing.allocator, &body);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.items.len);
    try testing.expectEqualSlices(ValType, &[_]ValType{.funcref}, c.items[0].locals);
}

test "decodeCodes: accepts externref local decl (Wasm 2.0 §5.3.1)" {
    const body = [_]u8{ 0x01, 0x04, 0x01, 0x01, 0x6F, 0x0B };
    var c = try decodeCodes(testing.allocator, &body);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.items.len);
    try testing.expectEqualSlices(ValType, &[_]ValType{.externref}, c.items[0].locals);
}
