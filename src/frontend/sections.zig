//! Wasm section-body decoders (type / function / code).
//!
//! Phase 1 / §9.1 / 1.9 lands these incrementally — this file
//! starts with the **type section** decoder. The frontend parser
//! (1.4) hands a section's raw bytes (`Section.body`); each decoder
//! here turns them into structured data the validator (1.5) +
//! lowerer (1.6) can consume per function.
//!
//! Memory: each decoder returns an owning struct with an internal
//! arena. The caller calls `deinit` on the struct; this releases all
//! per-decoder allocations in one go (per ROADMAP §P3 cold-start —
//! single arena drop instead of N free()s).
//!
//! Zone 1 (`src/frontend/`) — imports Zone 0 (`util/leb128.zig`)
//! and Zone 1 (`ir/zir.zig`).

const std = @import("std");

const leb128 = @import("../util/leb128.zig");
const zir = @import("../ir/zir.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;
const FuncType = zir.FuncType;

pub const Error = error{
    UnexpectedEnd,
    InvalidFunctype,
    BadValType,
    TrailingBytes,
    LocalsOverflow,
    OutOfMemory,
} || leb128.Error;

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

pub const Types = struct {
    arena: std.heap.ArenaAllocator,
    items: []FuncType,

    pub fn deinit(self: *Types) void {
        self.arena.deinit();
    }
};

/// Decode the body of a type section (`SectionId.@"type"`):
///   vec(functype)
/// where `functype = 0x60 vec(valtype) vec(valtype)`.
pub fn decodeTypes(parent_alloc: Allocator, body: []const u8) Error!Types {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(FuncType, count);

    for (items) |*ft| {
        if (pos >= body.len) return Error.UnexpectedEnd;
        if (body[pos] != 0x60) return Error.InvalidFunctype;
        pos += 1;

        const param_count = try leb128.readUleb128(u32, body, &pos);
        const params = try alloc.alloc(ValType, param_count);
        for (params) |*p| p.* = try readValType(body, &pos);

        const result_count = try leb128.readUleb128(u32, body, &pos);
        const results = try alloc.alloc(ValType, result_count);
        for (results) |*r| r.* = try readValType(body, &pos);

        ft.* = .{ .params = params, .results = results };
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

/// Decode the body of a function section (`SectionId.function`):
///   vec(typeidx)
/// Returns a slice of u32 type indices (one per defined function).
pub fn decodeFunctions(alloc: Allocator, body: []const u8) Error![]u32 {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const indices = try alloc.alloc(u32, count);
    errdefer alloc.free(indices);
    for (indices) |*idx| {
        idx.* = try leb128.readUleb128(u32, body, &pos);
    }
    if (pos != body.len) return Error.TrailingBytes;
    return indices;
}

pub const ImportKind = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
};

pub const Import = struct {
    /// Module name and field name borrowed from the input.
    module: []const u8,
    name: []const u8,
    /// Discriminator + payload (typeidx for func, valtype+mut for global,
    /// limits-only for memory/table — only typeidx and global payloads
    /// are decoded structurally; the runner reads them, the others are
    /// recorded as kind only).
    kind: ImportKind,
    payload: ImportPayload,
};

pub const ImportPayload = union(enum) {
    func_typeidx: u32,
    table: void,
    memory: void,
    global: struct { valtype: ValType, mutable: bool },
};

pub const Imports = struct {
    arena: std.heap.ArenaAllocator,
    items: []Import,

    pub fn deinit(self: *Imports) void {
        self.arena.deinit();
    }
};

/// Decode the body of an import section (`SectionId.import`):
///   vec(import), import = mod:name nm:name desc
///   desc = 0x00 typeidx | 0x01 tabletype | 0x02 memtype | 0x03 globaltype
/// Table and memory descriptions are recorded as kind-only — their
/// limits payload is consumed but not surfaced (Phase-1 validators
/// do not need it). Function and global imports are decoded
/// structurally so the validator can index them.
pub fn decodeImports(parent_alloc: Allocator, body: []const u8) Error!Imports {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(Import, count);

    for (items) |*imp| {
        const mod = try readName(body, &pos);
        const nm = try readName(body, &pos);
        if (pos >= body.len) return Error.UnexpectedEnd;
        const k = body[pos];
        pos += 1;
        const kind: ImportKind = switch (k) {
            0x00, 0x01, 0x02, 0x03 => @enumFromInt(k),
            else => return Error.InvalidFunctype,
        };
        const payload: ImportPayload = switch (kind) {
            .func => .{ .func_typeidx = try leb128.readUleb128(u32, body, &pos) },
            .table => blk: {
                if (pos >= body.len) return Error.UnexpectedEnd;
                _ = body[pos]; // reftype byte
                pos += 1;
                try skipLimits(body, &pos);
                break :blk .table;
            },
            .memory => blk: {
                try skipLimits(body, &pos);
                break :blk .memory;
            },
            .global => blk: {
                const t = try readValType(body, &pos);
                if (pos >= body.len) return Error.UnexpectedEnd;
                const m = body[pos];
                pos += 1;
                if (m > 1) return Error.InvalidFunctype;
                break :blk .{ .global = .{ .valtype = t, .mutable = m == 1 } };
            },
        };
        imp.* = .{ .module = mod, .name = nm, .kind = kind, .payload = payload };
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

fn readName(body: []const u8, pos: *usize) Error![]const u8 {
    const len = try leb128.readUleb128(u32, body, pos);
    const len_us: usize = @intCast(len);
    if (len_us > body.len - pos.*) return Error.UnexpectedEnd;
    const slice = body[pos.* .. pos.* + len_us];
    pos.* += len_us;
    return slice;
}

fn skipLimits(body: []const u8, pos: *usize) Error!void {
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    const flag = body[pos.*];
    pos.* += 1;
    _ = try leb128.readUleb128(u32, body, pos); // min
    if (flag & 1 != 0) {
        _ = try leb128.readUleb128(u32, body, pos); // max
    }
}

pub const GlobalDef = struct {
    valtype: ValType,
    mutable: bool,
    /// Init-expression bytes (terminated by the trailing `end`). Borrowed
    /// from the input.
    init_expr: []const u8,
};

pub const Globals = struct {
    arena: std.heap.ArenaAllocator,
    items: []GlobalDef,

    pub fn deinit(self: *Globals) void {
        self.arena.deinit();
    }
};

/// Decode the body of a global section (`SectionId.global`):
///   vec(global), global = globaltype init_expr
///   globaltype = valtype:u8 mut:u8 (0=const, 1=var)
///   init_expr = expr terminated by 0x0B
pub fn decodeGlobals(parent_alloc: Allocator, body: []const u8) Error!Globals {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(GlobalDef, count);

    for (items) |*g| {
        const t = try readValType(body, &pos);
        if (pos >= body.len) return Error.UnexpectedEnd;
        const m = body[pos];
        pos += 1;
        if (m > 1) return Error.InvalidFunctype; // reused; malformed mut byte
        const start = pos;
        while (pos < body.len and body[pos] != 0x0B) pos += 1;
        if (pos >= body.len) return Error.UnexpectedEnd;
        // Include the terminating end (0x0B) in the init_expr slice so
        // callers can drive a validator/lowerer the same way they would a
        // function body.
        pos += 1;
        g.* = .{ .valtype = t, .mutable = m == 1, .init_expr = body[start..pos] };
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

/// Decode the body of a code section (`SectionId.code`):
///   vec(code), code = size:u32 (vec(local_decl) + expr)
///   local_decl = count:u32 valtype
/// Returns one `CodeEntry` per defined function. `entry.body` is a
/// borrowed slice into `body`; the caller keeps `body` alive for as
/// long as the result is used.
pub fn decodeCodes(parent_alloc: Allocator, body: []const u8) Error!Codes {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const fn_count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(CodeEntry, fn_count);

    for (items) |*entry| {
        const size = try leb128.readUleb128(u32, body, &pos);
        const size_us: usize = @intCast(size);
        if (size_us > body.len - pos) return Error.UnexpectedEnd;
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
            if (probe >= code.len) return Error.UnexpectedEnd;
            probe += 1; // skip the valtype byte
        }
        if (total > std.math.maxInt(u32)) return Error.LocalsOverflow;

        const locals = try alloc.alloc(ValType, @intCast(total));
        var w: usize = 0;
        for (0..decl_count) |_| {
            const c = try leb128.readUleb128(u32, code, &inner);
            const t = try readValType(code, &inner);
            for (0..c) |_| {
                locals[w] = t;
                w += 1;
            }
        }

        entry.* = .{ .locals = locals, .body = code[inner..] };
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

fn readValType(body: []const u8, pos: *usize) Error!ValType {
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    const b = body[pos.*];
    pos.* += 1;
    return switch (b) {
        0x7F => .i32,
        0x7E => .i64,
        0x7D => .f32,
        0x7C => .f64,
        else => Error.BadValType,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "decodeTypes: empty section (count=0)" {
    var t = try decodeTypes(testing.allocator, &[_]u8{0x00});
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.items.len);
}

test "decodeTypes: single () -> ()" {
    // count=1; 0x60; param_count=0; result_count=0
    var t = try decodeTypes(testing.allocator, &[_]u8{ 0x01, 0x60, 0x00, 0x00 });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    try testing.expectEqual(@as(usize, 0), t.items[0].params.len);
    try testing.expectEqual(@as(usize, 0), t.items[0].results.len);
}

test "decodeTypes: (i32, i64) -> (f32, f64)" {
    const body = [_]u8{
        0x01, // count=1
        0x60, 0x02, 0x7F, 0x7E, 0x02, 0x7D, 0x7C,
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    const ft = t.items[0];
    try testing.expectEqualSlices(ValType, &[_]ValType{ .i32, .i64 }, ft.params);
    try testing.expectEqualSlices(ValType, &[_]ValType{ .f32, .f64 }, ft.results);
}

test "decodeTypes: two functypes preserved in order" {
    const body = [_]u8{
        0x02,
        0x60, 0x01, 0x7F, 0x00, // (i32) -> ()
        0x60, 0x00, 0x01, 0x7E, // () -> (i64)
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.items.len);
    try testing.expectEqualSlices(ValType, &[_]ValType{.i32}, t.items[0].params);
    try testing.expectEqualSlices(ValType, &[_]ValType{}, t.items[0].results);
    try testing.expectEqualSlices(ValType, &[_]ValType{}, t.items[1].params);
    try testing.expectEqualSlices(ValType, &[_]ValType{.i64}, t.items[1].results);
}

test "decodeTypes: rejects missing 0x60 prefix" {
    const body = [_]u8{ 0x01, 0x61, 0x00, 0x00 };
    try testing.expectError(Error.InvalidFunctype, decodeTypes(testing.allocator, &body));
}

test "decodeTypes: rejects unknown valtype byte" {
    // 0x7B is v128 (Wasm 2.0 SIMD). For Wasm 1.0 type-section decode
    // it must be rejected.
    const body = [_]u8{ 0x01, 0x60, 0x01, 0x7B, 0x00 };
    try testing.expectError(Error.BadValType, decodeTypes(testing.allocator, &body));
}

test "decodeTypes: rejects truncated input" {
    // count=1 but no functype
    const body = [_]u8{0x01};
    try testing.expectError(Error.UnexpectedEnd, decodeTypes(testing.allocator, &body));
}

test "decodeTypes: rejects trailing bytes after final functype" {
    const body = [_]u8{ 0x01, 0x60, 0x00, 0x00, 0xFF };
    try testing.expectError(Error.TrailingBytes, decodeTypes(testing.allocator, &body));
}

test "decodeTypes: rejects truncated leb128 count" {
    const body = [_]u8{0x80}; // continuation but no follow-up
    try testing.expectError(leb128.Error.Truncated, decodeTypes(testing.allocator, &body));
}

test "decodeFunctions: empty body (count=0) yields empty slice" {
    const out = try decodeFunctions(testing.allocator, &[_]u8{0x00});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "decodeFunctions: single typeidx" {
    const out = try decodeFunctions(testing.allocator, &[_]u8{ 0x01, 0x00 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u32, &[_]u32{0}, out);
}

test "decodeFunctions: three typeidxs preserved in order" {
    const out = try decodeFunctions(testing.allocator, &[_]u8{ 0x03, 0x00, 0x02, 0x05 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 2, 5 }, out);
}

test "decodeFunctions: rejects truncated input" {
    // count=2 but only one typeidx
    const r = decodeFunctions(testing.allocator, &[_]u8{ 0x02, 0x00 });
    try testing.expectError(leb128.Error.Truncated, r);
}

test "decodeFunctions: rejects trailing bytes" {
    const r = decodeFunctions(testing.allocator, &[_]u8{ 0x01, 0x00, 0xFF });
    try testing.expectError(Error.TrailingBytes, r);
}

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
    try testing.expectError(Error.UnexpectedEnd, decodeCodes(testing.allocator, &body));
}

test "decodeCodes: rejects bad valtype in locals decl" {
    const body = [_]u8{ 0x01, 0x04, 0x01, 0x01, 0x6F, 0x0B }; // 6F = funcref (post-MVP)
    try testing.expectError(Error.BadValType, decodeCodes(testing.allocator, &body));
}

test "decodeGlobals: empty section" {
    var g = try decodeGlobals(testing.allocator, &[_]u8{0x00});
    defer g.deinit();
    try testing.expectEqual(@as(usize, 0), g.items.len);
}

test "decodeGlobals: single immutable i32 with i32.const init" {
    // count=1; valtype=i32; mut=const; init: i32.const 7 ; end
    const body = [_]u8{ 0x01, 0x7F, 0x00, 0x41, 0x07, 0x0B };
    var g = try decodeGlobals(testing.allocator, &body);
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.items.len);
    try testing.expectEqual(ValType.i32, g.items[0].valtype);
    try testing.expectEqual(false, g.items[0].mutable);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x07, 0x0B }, g.items[0].init_expr);
}

test "decodeGlobals: mutable f64 global" {
    const body = [_]u8{ 0x01, 0x7C, 0x01, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0B };
    var g = try decodeGlobals(testing.allocator, &body);
    defer g.deinit();
    try testing.expectEqual(ValType.f64, g.items[0].valtype);
    try testing.expectEqual(true, g.items[0].mutable);
}

test "decodeGlobals: rejects malformed mut byte" {
    const body = [_]u8{ 0x01, 0x7F, 0x02, 0x41, 0x00, 0x0B };
    try testing.expectError(Error.InvalidFunctype, decodeGlobals(testing.allocator, &body));
}

test "decodeImports: empty section" {
    var i = try decodeImports(testing.allocator, &[_]u8{0x00});
    defer i.deinit();
    try testing.expectEqual(@as(usize, 0), i.items.len);
}

test "decodeImports: single function import" {
    // count=1; mod="env"; name="abs"; desc=0x00 typeidx=2
    const body = [_]u8{
        0x01,
        0x03, 'e', 'n', 'v',
        0x03, 'a', 'b', 's',
        0x00, 0x02,
    };
    var i = try decodeImports(testing.allocator, &body);
    defer i.deinit();
    try testing.expectEqual(@as(usize, 1), i.items.len);
    try testing.expectEqualSlices(u8, "env", i.items[0].module);
    try testing.expectEqualSlices(u8, "abs", i.items[0].name);
    try testing.expectEqual(ImportKind.func, i.items[0].kind);
    try testing.expectEqual(@as(u32, 2), i.items[0].payload.func_typeidx);
}

test "decodeImports: single global import (immutable i32)" {
    const body = [_]u8{
        0x01,
        0x02, 'm', 'm',
        0x01, 'g',
        0x03, 0x7F, 0x00,
    };
    var i = try decodeImports(testing.allocator, &body);
    defer i.deinit();
    try testing.expectEqual(ImportKind.global, i.items[0].kind);
    try testing.expectEqual(ValType.i32, i.items[0].payload.global.valtype);
    try testing.expectEqual(false, i.items[0].payload.global.mutable);
}

test "decodeImports: rejects unknown desc kind" {
    const body = [_]u8{ 0x01, 0x00, 0x00, 0x05 };
    try testing.expectError(Error.InvalidFunctype, decodeImports(testing.allocator, &body));
}

test "decodeGlobals: rejects unterminated init_expr" {
    const body = [_]u8{ 0x01, 0x7F, 0x00, 0x41, 0x00 }; // missing 0x0B
    try testing.expectError(Error.UnexpectedEnd, decodeGlobals(testing.allocator, &body));
}
