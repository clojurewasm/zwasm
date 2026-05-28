//! Wasm element section decoder (Wasm 2.0 §5.5.12, 8 forms 0–7).
//! Originally extracted per ADR-0095 (superseded by ADR-0101);
//! const-expression helpers now live in `init_expr.zig` per
//! ADR-0099 §D2 (P3 deep utility). This file keeps `sections.zig`
//! imported for `sections.Error` (the externally-observable
//! section-decoder error union).

const std = @import("std");
const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");
const sections = @import("sections.zig");
const init_expr = @import("init_expr.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;

pub const ElementKind = enum { active, passive, declarative };

pub const ElementSegment = struct {
    kind: ElementKind,
    tableidx: u32 = 0,
    offset_expr: []const u8 = &.{},
    elem_type: ValType = .funcref,
    funcidxs: []const u32 = &.{},
};

pub const Elements = struct {
    arena: std.heap.ArenaAllocator,
    items: []ElementSegment,

    pub fn deinit(self: *Elements) void {
        self.arena.deinit();
    }
};

/// Decode the body of an element section (Wasm 2.0 §5.5.12).
/// Supports all 8 forms (0–7) per ADR-0014 §2.1 / 6.K.4. Forms
/// 0/1/3/4 ship in chunk 5d-2; 2/5/6/7 land in 6.K.4. Funcref is
/// the only supported reftype in v0.1.0; externref defers to a
/// follow-up row when the externref test corpus arrives.
pub fn decodeElement(parent_alloc: Allocator, body: []const u8) sections.Error!Elements {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(ElementSegment, count);

    for (items) |*e| {
        const flag = try leb128.readUleb128(u32, body, &pos);
        switch (flag) {
            0 => {
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{
                    .kind = .active,
                    .tableidx = 0,
                    .offset_expr = expr,
                    .elem_type = .funcref,
                    .funcidxs = funcs,
                };
            },
            1 => {
                if (pos >= body.len) return sections.Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return sections.Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{ .kind = .passive, .elem_type = .funcref, .funcidxs = funcs };
            },
            3 => {
                if (pos >= body.len) return sections.Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return sections.Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{ .kind = .declarative, .elem_type = .funcref, .funcidxs = funcs };
            },
            4 => {
                // active, table 0, offset expr, vec(reftype-expr).
                // wast2json with --enable-function-references emits
                // funcref segments in this form. Each expr is either
                // `ref.func F; end` (0xD2 LEB128(F) 0x0B) or
                // `ref.null funcref; end` (0xD0 0x70 0x0B); the
                // latter resolves to the spec null sentinel via
                // `funcidxs` carrying `std.math.maxInt(u32)`.
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, .funcref);
                e.* = .{
                    .kind = .active,
                    .tableidx = 0,
                    .offset_expr = expr,
                    .elem_type = .funcref,
                    .funcidxs = funcs,
                };
            },
            2 => {
                // active, explicit tableidx, offset_expr, elemkind,
                // vec(funcidx).
                const tableidx = try leb128.readUleb128(u32, body, &pos);
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                if (pos >= body.len) return sections.Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return sections.Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{
                    .kind = .active,
                    .tableidx = tableidx,
                    .offset_expr = expr,
                    .elem_type = .funcref,
                    .funcidxs = funcs,
                };
            },
            5 => {
                // passive, reftype, vec(reftype-expr).
                // function-references: element reftype may be any
                // reftype incl. typed `(ref null? $t)` — shared reader.
                const reftype_vt = init_expr.readRefType(body, &pos) catch |err| switch (err) {
                    error.UnexpectedEnd => return sections.Error.UnexpectedEnd,
                    else => return sections.Error.InvalidFunctype,
                };
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, reftype_vt);
                e.* = .{ .kind = .passive, .elem_type = reftype_vt, .funcidxs = funcs };
            },
            6 => {
                // active, explicit tableidx, offset_expr, reftype,
                // vec(reftype-expr).
                const tableidx = try leb128.readUleb128(u32, body, &pos);
                const expr_start = pos;
                try init_expr.scanInitExpr(body, &pos);
                const expr = body[expr_start..pos];
                // function-references: element reftype may be any
                // reftype incl. typed `(ref null? $t)` — shared reader.
                const reftype_vt = init_expr.readRefType(body, &pos) catch |err| switch (err) {
                    error.UnexpectedEnd => return sections.Error.UnexpectedEnd,
                    else => return sections.Error.InvalidFunctype,
                };
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, reftype_vt);
                e.* = .{
                    .kind = .active,
                    .tableidx = tableidx,
                    .offset_expr = expr,
                    .elem_type = reftype_vt,
                    .funcidxs = funcs,
                };
            },
            7 => {
                // declarative, reftype, vec(reftype-expr).
                // function-references: element reftype may be any
                // reftype incl. typed `(ref null? $t)` — shared reader.
                const reftype_vt = init_expr.readRefType(body, &pos) catch |err| switch (err) {
                    error.UnexpectedEnd => return sections.Error.UnexpectedEnd,
                    else => return sections.Error.InvalidFunctype,
                };
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos, reftype_vt);
                e.* = .{ .kind = .declarative, .elem_type = reftype_vt, .funcidxs = funcs };
            },
            else => return sections.Error.InvalidFunctype,
        }
    }

    if (pos != body.len) return sections.Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

/// Decode one funcref/externref init expression appearing in
/// element-section form 4 / 5 / 6 / 7. Supports per Wasm spec
/// §3.3.2.10 const-expr: `ref.func F; end` (0xD2 LEB128(F) 0x0B),
/// `ref.null t; end` (0xD0 0x70|0x6F 0x0B), and `global.get N;
/// end` (0x23 LEB128(N) 0x0B).
///
/// Encoding in funcidx slot:
/// - `ref.func F`: funcidx = F (assumed F < 0x80000000 which holds
///   for any realistic module — F is bound by total_funcs).
/// - `ref.null t`: funcidx = `std.math.maxInt(u32)` (null sentinel).
/// - `global.get N`: funcidx = `0x80000000 | N` (top-bit marker;
///   close-plan §6 (j) Step B cohort 6). Table-init then reads
///   the imported funcref global value at `scratch_globals[
///   globals_offsets[N]]` and substitutes it as the table entry.
fn readFuncrefInitExpr(body: []const u8, pos: *usize, expected: ValType) sections.Error!u32 {
    if (pos.* >= body.len) return sections.Error.UnexpectedEnd;
    const op = body[pos.*];
    pos.* += 1;
    const idx: u32 = switch (op) {
        0xD2 => blk: {
            // ref.func produces a (typed) funcref; valid when the
            // segment's reftype is in the func family — abstract `func`
            // (any nullability) or a concrete typed func ref `(ref $sig)`
            // (pre-GC every concrete type is a func type; ref_is_null.0
            // elem 1: `(ref 0)` with `ref.func 0`). Reject externref /
            // other heads (elem.51: ref.func into an externref segment).
            const ok = expected == .ref and switch (expected.ref.heap_type) {
                .abstract => |a| a == .func,
                .concrete => true,
            };
            if (!ok) return sections.Error.InvalidFunctype;
            break :blk try leb128.readUleb128(u32, body, pos);
        },
        0xD0 => blk: {
            if (pos.* >= body.len) return sections.Error.UnexpectedEnd;
            const rt_byte = body[pos.*];
            const rt_vt: ValType = switch (rt_byte) {
                0x70 => .funcref,
                0x6F => .externref,
                else => return sections.Error.BadValType,
            };
            if (!rt_vt.eql(expected)) return sections.Error.InvalidFunctype;
            pos.* += 1;
            break :blk std.math.maxInt(u32);
        },
        0x23 => blk: {
            // global.get produces the imported global's type. Strict
            // per-global type check is deferred to compileWasm
            // (validator owns the globals index space); decoder only
            // ensures the marker is structurally valid.
            const n = try leb128.readUleb128(u32, body, pos);
            if (n >= 0x80000000) return sections.Error.InvalidFunctype;
            break :blk 0x80000000 | n;
        },
        else => return sections.Error.InvalidFunctype,
    };
    if (pos.* >= body.len) return sections.Error.UnexpectedEnd;
    if (body[pos.*] != 0x0B) return sections.Error.InvalidFunctype;
    pos.* += 1;
    return idx;
}

/// Close-plan §6 (j) Step B cohort 6 — funcref init-expression
/// marker constants. Element segments carrying `global.get N`
/// entries encode the global index with the top bit set; consumers
/// (`applyTableInitForTable`, `populateTableRefs`) detect this and
/// resolve via `GlobalsCtx`.
pub const ELEM_GLOBAL_GET_MARKER: u32 = 0x80000000;
pub fn elemEntryIsGlobalGet(funcidx: u32) bool {
    return (funcidx & ELEM_GLOBAL_GET_MARKER) != 0 and funcidx != std.math.maxInt(u32);
}
pub fn elemEntryGlobalIdx(funcidx: u32) u32 {
    return funcidx & 0x7FFFFFFF;
}

const testing = std.testing;

test "decodeElement: empty section" {
    var e = try decodeElement(testing.allocator, &[_]u8{0x00});
    defer e.deinit();
    try testing.expectEqual(@as(usize, 0), e.items.len);
}

test "decodeElement: single active form 0 with two funcidxs" {
    // count=1; flag=0; offset_expr = i32.const 5 ; end; n=2; funcs=[0,1]
    const body = [_]u8{
        0x01,
        0x00,
        0x41,
        0x05,
        0x0B,
        0x02,
        0x00,
        0x01,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expectEqual(@as(u32, 0), e.items[0].tableidx);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, e.items[0].funcidxs);
}

test "decodeElement: form 6 typed-ref (ref 0) elem with ref.func init expr" {
    // ref_is_null.0 elem 1: active, tableidx, offset, reftype (ref 0),
    // vec [ref.func 0]. `ref.func` produces a typed funcref that must
    // satisfy the concrete (ref 0) segment type (not just abstract
    // funcref). count=1; flag=6; tableidx=0; offset=i32.const 0;end;
    // reftype=(ref 0)=0x64 0x00; n=1; expr=ref.func 0;end.
    const body = [_]u8{ 0x01, 0x06, 0x00, 0x41, 0x00, 0x0B, 0x64, 0x00, 0x01, 0xD2, 0x00, 0x0B };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expect(e.items[0].elem_type == .ref);
    try testing.expect(e.items[0].elem_type.ref.heap_type == .concrete);
    try testing.expectEqualSlices(u32, &[_]u32{0}, e.items[0].funcidxs);
}

test "decodeElement: passive form 1 with elemkind=funcref" {
    // count=1; flag=1; elemkind=0x00; n=1; funcs=[3]
    const body = [_]u8{ 0x01, 0x01, 0x00, 0x01, 0x03 };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.passive, e.items[0].kind);
    try testing.expectEqualSlices(u32, &[_]u32{3}, e.items[0].funcidxs);
}

test "decodeElement: declarative form 3" {
    const body = [_]u8{ 0x01, 0x03, 0x00, 0x00 };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.declarative, e.items[0].kind);
    try testing.expectEqual(@as(usize, 0), e.items[0].funcidxs.len);
}

test "decodeElement: active form 2 with explicit tableidx" {
    // Per Wasm 2.0 §5.5.12: flag=2, tableidx (uleb), offset_expr,
    // elemkind, vec(funcidx).
    // count=1; flag=2; tableidx=1; offset = i32.const 0; end;
    // elemkind=0x00; n=2; funcs=[0,1]
    const body = [_]u8{
        0x01,
        0x02,
        0x01,
        0x41,
        0x00,
        0x0B,
        0x00,
        0x02,
        0x00,
        0x01,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expectEqual(@as(u32, 1), e.items[0].tableidx);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, e.items[0].funcidxs);
}

test "decodeElement: passive form 5 (reftype + expr-vec)" {
    // Per Wasm 2.0 §5.5.12: flag=5, reftype, vec(reftype-expr).
    // count=1; flag=5; reftype=0x70 (funcref); n=2;
    // expr0 = ref.func 7; end; expr1 = ref.null funcref; end
    const body = [_]u8{
        0x01,
        0x05,
        0x70,
        0x02,
        0xD2,
        0x07,
        0x0B,
        0xD0,
        0x70,
        0x0B,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.passive, e.items[0].kind);
    try testing.expectEqual(ValType.funcref, e.items[0].elem_type);
    try testing.expectEqualSlices(u32, &[_]u32{ 7, std.math.maxInt(u32) }, e.items[0].funcidxs);
}

test "decodeElement: active form 6 (tableidx + offset + reftype + expr-vec)" {
    // Per Wasm 2.0 §5.5.12: flag=6, tableidx, offset_expr,
    // reftype, vec(reftype-expr).
    // count=1; flag=6; tableidx=2; offset = i32.const 4; end;
    // reftype=0x70; n=1; expr = ref.func 3; end
    const body = [_]u8{
        0x01,
        0x06,
        0x02,
        0x41,
        0x04,
        0x0B,
        0x70,
        0x01,
        0xD2,
        0x03,
        0x0B,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expectEqual(@as(u32, 2), e.items[0].tableidx);
    try testing.expectEqual(ValType.funcref, e.items[0].elem_type);
    try testing.expectEqualSlices(u32, &[_]u32{3}, e.items[0].funcidxs);
}

test "decodeElement: declarative form 7 (reftype + expr-vec)" {
    // Per Wasm 2.0 §5.5.12: flag=7, reftype, vec(reftype-expr).
    // count=1; flag=7; reftype=0x70; n=1; expr = ref.func 0; end
    const body = [_]u8{
        0x01,
        0x07,
        0x70,
        0x01,
        0xD2,
        0x00,
        0x0B,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.declarative, e.items[0].kind);
    try testing.expectEqual(ValType.funcref, e.items[0].elem_type);
    try testing.expectEqualSlices(u32, &[_]u32{0}, e.items[0].funcidxs);
}
