//! wasm-c-api type-representation constructors (§13.2 / Phase 13).
//!
//! The `wasm_{valtype,functype,globaltype,tabletype,memorytype}_t` opaque
//! type descriptors + their queries + `wasm_valtype_vec_t`. These are pure
//! data descriptors (no Store/runtime coupling), so they allocate directly
//! via `std.heap.c_allocator` — unlike Trap/Module/Instance which recover
//! the allocator from a Store back-pointer (`api/instance.zig`).
//!
//! Ownership (upstream wasm-c-api, ADR-0004 pin): every `_new` returns an
//! `own *T` the caller frees with `_delete`; `_new` TAKES ownership of its
//! `own` inputs (a `globaltype_new` consumes its valtype; `functype_new`
//! consumes both valtype_vecs — their data arrays + elements). Queries
//! return borrowed `const *T` (owner = the containing type). The pointer-vec
//! `_vec_delete` cascades into per-element `_delete` (mirrors
//! `instance.wasm_extern_vec_delete`); `_vec_copy` DEEP-copies (each new vec
//! owns its own elements — a shallow copy would double-free).
//!
//! Zone 3 (`src/api/`). Re-exported via `api/wasm.zig`; `export fn`s
//! auto-link into the C-API lib.

const std = @import("std");
const testing = std.testing;

const ca = std.heap.c_allocator;

// wasm.h: WASM_I32=0, I64=1, F32=2, F64=3, EXTERNREF=128, FUNCREF=129.
// wasm_mutability_t: WASM_CONST=0, WASM_VAR=1.

/// `wasm_limits_t` — { min, max } (max = 0xffffffff when unbounded).
pub const Limits = extern struct {
    min: u32,
    max: u32,
};

/// Opaque `wasm_valtype_t` — a value-type descriptor (the valkind byte;
/// refs 128/129 are distinguished by the byte itself).
pub const ValType = extern struct {
    kind: u8,
};

/// `wasm_valtype_vec_t` — `WASM_DECLARE_VEC(valtype, *)`: a pointer-vec of
/// owned `wasm_valtype_t*`. C-ABI `{ size_t size; wasm_valtype_t** data; }`.
pub const ValTypeVec = extern struct {
    size: usize,
    data: ?[*]?*ValType,
};

// wasm_externkind_t (wasm.h): FUNC=0, GLOBAL=1, TABLE=2, MEMORY=3, TAG=4.
pub const extern_func: u8 = 0;
pub const extern_global: u8 = 1;
pub const extern_table: u8 = 2;
pub const extern_memory: u8 = 3;
pub const extern_tag: u8 = 4; // wasm.h WASM_EXTERN_TAG (exception-handling tag type)

/// `wasm_externtype_t` — the shared header (a `kind` discriminant) the four
/// concrete extern types embed as their FIRST field, so `*_as_externtype` /
/// `wasm_externtype_as_*` are zero-alloc reinterpret casts (the upstream
/// inheritance layout). An externtype pointer IS a concrete-type pointer.
pub const ExternType = extern struct {
    kind: u8,
};

/// Opaque `wasm_functype_t` — owns its param + result valtype vecs.
pub const FuncType = extern struct {
    kind: u8 = extern_func,
    params: ValTypeVec,
    results: ValTypeVec,
};

/// Opaque `wasm_globaltype_t` — owns its content valtype.
pub const GlobalType = extern struct {
    kind: u8 = extern_global,
    content: ?*ValType,
    mutability: u8,
};

/// Opaque `wasm_tabletype_t` — owns its element valtype + limits.
pub const TableType = extern struct {
    kind: u8 = extern_table,
    element: ?*ValType,
    limits: Limits,
};

/// Opaque `wasm_memorytype_t` — limits only.
pub const MemoryType = extern struct {
    kind: u8 = extern_memory,
    limits: Limits,
};

/// Opaque `wasm_tagtype_t` — an exception-handling tag type; wraps (owns) the
/// functype that is the tag's parameter signature (wasm.h:252). `kind`-first
/// layout matches the other externtypes so `_as_externtype` is a zero-alloc cast.
pub const TagType = extern struct {
    kind: u8 = extern_tag,
    functype: ?*FuncType,
};

// =====================================================================
// valtype
// =====================================================================

pub export fn wasm_valtype_new(kind: u8) callconv(.c) ?*ValType {
    const vt = ca.create(ValType) catch return null;
    vt.* = .{ .kind = kind };
    return vt;
}

pub export fn wasm_valtype_delete(vt: ?*ValType) callconv(.c) void {
    if (vt) |p| ca.destroy(p);
}

pub export fn wasm_valtype_kind(vt: ?*const ValType) callconv(.c) u8 {
    return (vt orelse return 0).kind;
}

pub export fn wasm_valtype_copy(vt: ?*const ValType) callconv(.c) ?*ValType {
    const src = vt orelse return null;
    return wasm_valtype_new(src.kind);
}

// =====================================================================
// valtype vec (pointer-vec; delete cascades to element delete)
// =====================================================================

/// Comptime-generic owned-pointer vec ops — the `WASM_DECLARE_VEC(T, *)`
/// family for the type descriptors (functype/globaltype/… + valtype/externtype/
/// importtype/exporttype). `data` is an array of owned `?*Elem`; the vec owns
/// both the array and each element. `new` adopts the caller's pointers
/// (wasm-c-api ownership transfer); `copy` deep-clones each element via `copyFn`
/// (shallow would double-free on delete); `delete` frees each element via
/// `deleteFn` then the array. One shape, all families.
fn PtrVecOps(
    comptime Elem: type,
    comptime VecT: type,
    comptime copyFn: fn (?*const Elem) callconv(.c) ?*Elem,
    comptime deleteFn: fn (?*Elem) callconv(.c) void,
) type {
    return struct {
        fn newEmpty(out: ?*VecT) void {
            (out orelse return).* = .{ .size = 0, .data = null };
        }
        fn newUninit(out: ?*VecT, size: usize) void {
            const o = out orelse return;
            if (size == 0) {
                o.* = .{ .size = 0, .data = null };
                return;
            }
            const buf = ca.alloc(?*Elem, size) catch {
                o.* = .{ .size = 0, .data = null };
                return;
            };
            @memset(buf, null);
            o.* = .{ .size = size, .data = buf.ptr };
        }
        fn new(out: ?*VecT, size: usize, src: ?[*]const ?*Elem) void {
            const o = out orelse return;
            if (size == 0 or src == null) {
                o.* = .{ .size = 0, .data = null };
                return;
            }
            const buf = ca.alloc(?*Elem, size) catch {
                o.* = .{ .size = 0, .data = null };
                return;
            };
            @memcpy(buf, src.?[0..size]);
            o.* = .{ .size = size, .data = buf.ptr };
        }
        fn copy(out: ?*VecT, src: ?*const VecT) void {
            const o = out orelse return;
            const s = src orelse {
                o.* = .{ .size = 0, .data = null };
                return;
            };
            if (s.size == 0 or s.data == null) {
                o.* = .{ .size = 0, .data = null };
                return;
            }
            const buf = ca.alloc(?*Elem, s.size) catch {
                o.* = .{ .size = 0, .data = null };
                return;
            };
            for (s.data.?[0..s.size], 0..) |opt, i| {
                buf[i] = if (opt) |el| copyFn(el) else null;
            }
            o.* = .{ .size = s.size, .data = buf.ptr };
        }
        fn delete(v: ?*VecT) void {
            const handle = v orelse return;
            if (handle.data) |dp| {
                for (dp[0..handle.size]) |opt| {
                    if (opt) |el| deleteFn(el);
                }
                ca.free(dp[0..handle.size]);
            }
            handle.* = .{ .size = 0, .data = null };
        }
    };
}

const ValTypeVecOps = PtrVecOps(ValType, ValTypeVec, wasm_valtype_copy, wasm_valtype_delete);
pub export fn wasm_valtype_vec_new_empty(out: ?*ValTypeVec) callconv(.c) void {
    ValTypeVecOps.newEmpty(out);
}
pub export fn wasm_valtype_vec_new_uninitialized(out: ?*ValTypeVec, size: usize) callconv(.c) void {
    ValTypeVecOps.newUninit(out, size);
}
pub export fn wasm_valtype_vec_new(out: ?*ValTypeVec, size: usize, src: ?[*]const ?*ValType) callconv(.c) void {
    ValTypeVecOps.new(out, size, src);
}
pub export fn wasm_valtype_vec_copy(out: ?*ValTypeVec, src: ?*const ValTypeVec) callconv(.c) void {
    ValTypeVecOps.copy(out, src);
}
pub export fn wasm_valtype_vec_delete(v: ?*ValTypeVec) callconv(.c) void {
    ValTypeVecOps.delete(v);
}

// =====================================================================
// functype — consumes both valtype vecs
// =====================================================================

pub export fn wasm_functype_new(params: ?*ValTypeVec, results: ?*ValTypeVec) callconv(.c) ?*FuncType {
    const ft = ca.create(FuncType) catch return null;
    ft.* = .{
        .params = if (params) |p| p.* else .{ .size = 0, .data = null },
        .results = if (results) |r| r.* else .{ .size = 0, .data = null },
    };
    // Ownership transferred — zero the inputs so the caller's _vec_delete is
    // a no-op (the functype now owns the data arrays + elements).
    if (params) |p| p.* = .{ .size = 0, .data = null };
    if (results) |r| r.* = .{ .size = 0, .data = null };
    return ft;
}

pub export fn wasm_functype_delete(ft: ?*FuncType) callconv(.c) void {
    const f = ft orelse return;
    wasm_valtype_vec_delete(&f.params);
    wasm_valtype_vec_delete(&f.results);
    ca.destroy(f);
}

pub export fn wasm_functype_params(ft: ?*const FuncType) callconv(.c) ?*const ValTypeVec {
    return &(ft orelse return null).params;
}

pub export fn wasm_functype_results(ft: ?*const FuncType) callconv(.c) ?*const ValTypeVec {
    return &(ft orelse return null).results;
}

pub export fn wasm_functype_copy(ft: ?*const FuncType) callconv(.c) ?*FuncType {
    const src = ft orelse return null;
    const nf = ca.create(FuncType) catch return null;
    var p: ValTypeVec = undefined;
    var r: ValTypeVec = undefined;
    wasm_valtype_vec_copy(&p, &src.params);
    wasm_valtype_vec_copy(&r, &src.results);
    nf.* = .{ .params = p, .results = r };
    return nf;
}

// =====================================================================
// globaltype — consumes its content valtype
// =====================================================================

pub export fn wasm_globaltype_new(content: ?*ValType, mutability: u8) callconv(.c) ?*GlobalType {
    const gt = ca.create(GlobalType) catch return null;
    gt.* = .{ .content = content, .mutability = mutability };
    return gt;
}

pub export fn wasm_globaltype_delete(gt: ?*GlobalType) callconv(.c) void {
    const g = gt orelse return;
    if (g.content) |c| wasm_valtype_delete(c);
    ca.destroy(g);
}

pub export fn wasm_globaltype_content(gt: ?*const GlobalType) callconv(.c) ?*const ValType {
    return (gt orelse return null).content;
}

pub export fn wasm_globaltype_mutability(gt: ?*const GlobalType) callconv(.c) u8 {
    return (gt orelse return 0).mutability;
}

pub export fn wasm_globaltype_copy(gt: ?*const GlobalType) callconv(.c) ?*GlobalType {
    const src = gt orelse return null;
    const content_copy = if (src.content) |c| wasm_valtype_copy(c) else null;
    return wasm_globaltype_new(content_copy, src.mutability);
}

// =====================================================================
// tabletype — consumes its element valtype, copies limits
// =====================================================================

pub export fn wasm_tabletype_new(element: ?*ValType, limits: ?*const Limits) callconv(.c) ?*TableType {
    const tt = ca.create(TableType) catch return null;
    tt.* = .{
        .element = element,
        .limits = if (limits) |l| l.* else .{ .min = 0, .max = 0xffff_ffff },
    };
    return tt;
}

pub export fn wasm_tabletype_delete(tt: ?*TableType) callconv(.c) void {
    const t = tt orelse return;
    if (t.element) |e| wasm_valtype_delete(e);
    ca.destroy(t);
}

pub export fn wasm_tabletype_element(tt: ?*const TableType) callconv(.c) ?*const ValType {
    return (tt orelse return null).element;
}

pub export fn wasm_tabletype_limits(tt: ?*const TableType) callconv(.c) ?*const Limits {
    return &(tt orelse return null).limits;
}

pub export fn wasm_tabletype_copy(tt: ?*const TableType) callconv(.c) ?*TableType {
    const src = tt orelse return null;
    const elem_copy = if (src.element) |e| wasm_valtype_copy(e) else null;
    var lim = src.limits;
    return wasm_tabletype_new(elem_copy, &lim);
}

// =====================================================================
// memorytype — limits only
// =====================================================================

pub export fn wasm_memorytype_new(limits: ?*const Limits) callconv(.c) ?*MemoryType {
    const mt = ca.create(MemoryType) catch return null;
    mt.* = .{ .limits = if (limits) |l| l.* else .{ .min = 0, .max = 0xffff_ffff } };
    return mt;
}

pub export fn wasm_memorytype_delete(mt: ?*MemoryType) callconv(.c) void {
    if (mt) |m| ca.destroy(m);
}

pub export fn wasm_memorytype_limits(mt: ?*const MemoryType) callconv(.c) ?*const Limits {
    return &(mt orelse return null).limits;
}

pub export fn wasm_memorytype_copy(mt: ?*const MemoryType) callconv(.c) ?*MemoryType {
    const src = mt orelse return null;
    var lim = src.limits;
    return wasm_memorytype_new(&lim);
}

// =====================================================================
// tagtype (exception-handling tag type; wraps an owned functype)
// =====================================================================

/// `wasm_tagtype_new(own functype)` — takes ownership of `ft`.
pub export fn wasm_tagtype_new(ft: ?*FuncType) callconv(.c) ?*TagType {
    const f = ft orelse return null;
    const tt = ca.create(TagType) catch return null;
    tt.* = .{ .functype = f };
    return tt;
}
pub export fn wasm_tagtype_delete(tt: ?*TagType) callconv(.c) void {
    const t = tt orelse return;
    if (t.functype) |f| wasm_functype_delete(f);
    ca.destroy(t);
}
pub export fn wasm_tagtype_functype(tt: ?*const TagType) callconv(.c) ?*const FuncType {
    return (tt orelse return null).functype;
}
pub export fn wasm_tagtype_copy(tt: ?*const TagType) callconv(.c) ?*TagType {
    const src = tt orelse return null;
    const fcopy = if (src.functype) |f| wasm_functype_copy(f) else null;
    const c = ca.create(TagType) catch {
        if (fcopy) |f| wasm_functype_delete(f);
        return null;
    };
    c.* = .{ .functype = fcopy };
    return c;
}

// tagtype ↔ externtype (zero-alloc cast / checked downcast; kind = extern_tag).
pub export fn wasm_tagtype_as_externtype(tt: ?*TagType) callconv(.c) ?*ExternType {
    return @ptrCast(tt);
}
pub export fn wasm_tagtype_as_externtype_const(tt: ?*const TagType) callconv(.c) ?*const ExternType {
    return @ptrCast(tt);
}
pub export fn wasm_externtype_as_tagtype(et: ?*ExternType) callconv(.c) ?*TagType {
    const e = et orelse return null;
    return if (e.kind == extern_tag) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_tagtype_const(et: ?*const ExternType) callconv(.c) ?*const TagType {
    const e = et orelse return null;
    return if (e.kind == extern_tag) @ptrCast(@alignCast(e)) else null;
}

pub const TagTypeVec = extern struct { size: usize, data: ?[*]?*TagType };
const TagTypeVecOps = PtrVecOps(TagType, TagTypeVec, wasm_tagtype_copy, wasm_tagtype_delete);
pub export fn wasm_tagtype_vec_new_empty(out: ?*TagTypeVec) callconv(.c) void {
    TagTypeVecOps.newEmpty(out);
}
pub export fn wasm_tagtype_vec_new_uninitialized(out: ?*TagTypeVec, size: usize) callconv(.c) void {
    TagTypeVecOps.newUninit(out, size);
}
pub export fn wasm_tagtype_vec_new(out: ?*TagTypeVec, size: usize, src: ?[*]const ?*TagType) callconv(.c) void {
    TagTypeVecOps.new(out, size, src);
}
pub export fn wasm_tagtype_vec_copy(out: ?*TagTypeVec, src: ?*const TagTypeVec) callconv(.c) void {
    TagTypeVecOps.copy(out, src);
}
pub export fn wasm_tagtype_vec_delete(v: ?*TagTypeVec) callconv(.c) void {
    TagTypeVecOps.delete(v);
}

test "tagtype: new (consumes functype) / functype / copy / as_externtype round-trip / vec" {
    var pv: ValTypeVec = undefined;
    var rv: ValTypeVec = undefined;
    var params = [_]?*ValType{wasm_valtype_new(0)}; // (i32) -> ()
    wasm_valtype_vec_new(&pv, params.len, &params);
    wasm_valtype_vec_new(&rv, 0, null);
    const ft = wasm_functype_new(&pv, &rv).?;
    const tag = wasm_tagtype_new(ft).?; // takes ownership of ft
    defer wasm_tagtype_delete(tag);
    try testing.expectEqual(@as(usize, 1), wasm_tagtype_functype(tag).?.params.size);

    // as_externtype round-trip (kind = extern_tag = 4).
    const et = wasm_tagtype_as_externtype(tag).?;
    try testing.expectEqual(extern_tag, wasm_externtype_kind(et));
    try testing.expectEqual(tag, wasm_externtype_as_tagtype(et).?);
    try testing.expect(wasm_externtype_as_functype(et) == null); // wrong-kind → null

    // copy (deep — independent functype).
    const c = wasm_tagtype_copy(tag).?;
    defer wasm_tagtype_delete(c);
    try testing.expect(c != tag);
    try testing.expectEqual(@as(usize, 1), wasm_tagtype_functype(c).?.params.size);

    // vec.
    var elems = [_]?*TagType{wasm_tagtype_copy(tag)};
    var vecz: TagTypeVec = undefined;
    wasm_tagtype_vec_new(&vecz, elems.len, &elems);
    try testing.expectEqual(@as(usize, 1), vecz.size);
    wasm_tagtype_vec_delete(&vecz); // frees the copied tag
}

// =====================================================================
// externtype — reinterpret-cast views over the 4 concrete types
// =====================================================================

pub export fn wasm_externtype_kind(et: ?*const ExternType) callconv(.c) u8 {
    return (et orelse return 0).kind;
}

// concrete → externtype: zero-alloc cast (kind is the shared first field).
pub export fn wasm_functype_as_externtype(ft: ?*FuncType) callconv(.c) ?*ExternType {
    return @ptrCast(ft);
}
pub export fn wasm_globaltype_as_externtype(gt: ?*GlobalType) callconv(.c) ?*ExternType {
    return @ptrCast(gt);
}
pub export fn wasm_tabletype_as_externtype(tt: ?*TableType) callconv(.c) ?*ExternType {
    return @ptrCast(tt);
}
pub export fn wasm_memorytype_as_externtype(mt: ?*MemoryType) callconv(.c) ?*ExternType {
    return @ptrCast(mt);
}
pub export fn wasm_functype_as_externtype_const(ft: ?*const FuncType) callconv(.c) ?*const ExternType {
    return @ptrCast(ft);
}
pub export fn wasm_globaltype_as_externtype_const(gt: ?*const GlobalType) callconv(.c) ?*const ExternType {
    return @ptrCast(gt);
}
pub export fn wasm_tabletype_as_externtype_const(tt: ?*const TableType) callconv(.c) ?*const ExternType {
    return @ptrCast(tt);
}
pub export fn wasm_memorytype_as_externtype_const(mt: ?*const MemoryType) callconv(.c) ?*const ExternType {
    return @ptrCast(mt);
}

// externtype → concrete: checked cast (null on kind mismatch).
pub export fn wasm_externtype_as_functype(et: ?*ExternType) callconv(.c) ?*FuncType {
    const e = et orelse return null;
    return if (e.kind == extern_func) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_globaltype(et: ?*ExternType) callconv(.c) ?*GlobalType {
    const e = et orelse return null;
    return if (e.kind == extern_global) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_tabletype(et: ?*ExternType) callconv(.c) ?*TableType {
    const e = et orelse return null;
    return if (e.kind == extern_table) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_memorytype(et: ?*ExternType) callconv(.c) ?*MemoryType {
    const e = et orelse return null;
    return if (e.kind == extern_memory) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_functype_const(et: ?*const ExternType) callconv(.c) ?*const FuncType {
    const e = et orelse return null;
    return if (e.kind == extern_func) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_globaltype_const(et: ?*const ExternType) callconv(.c) ?*const GlobalType {
    const e = et orelse return null;
    return if (e.kind == extern_global) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_tabletype_const(et: ?*const ExternType) callconv(.c) ?*const TableType {
    const e = et orelse return null;
    return if (e.kind == extern_table) @ptrCast(@alignCast(e)) else null;
}
pub export fn wasm_externtype_as_memorytype_const(et: ?*const ExternType) callconv(.c) ?*const MemoryType {
    const e = et orelse return null;
    return if (e.kind == extern_memory) @ptrCast(@alignCast(e)) else null;
}

// externtype delete/copy dispatch to the concrete type by kind.
pub export fn wasm_externtype_delete(et: ?*ExternType) callconv(.c) void {
    const e = et orelse return;
    switch (e.kind) {
        extern_func => wasm_functype_delete(@ptrCast(@alignCast(e))),
        extern_global => wasm_globaltype_delete(@ptrCast(@alignCast(e))),
        extern_table => wasm_tabletype_delete(@ptrCast(@alignCast(e))),
        extern_memory => wasm_memorytype_delete(@ptrCast(@alignCast(e))),
        extern_tag => wasm_tagtype_delete(@ptrCast(@alignCast(e))),
        else => {},
    }
}
pub export fn wasm_externtype_copy(et: ?*const ExternType) callconv(.c) ?*ExternType {
    const e = et orelse return null;
    return switch (e.kind) {
        extern_func => wasm_functype_as_externtype(wasm_functype_copy(@ptrCast(@alignCast(e)))),
        extern_global => wasm_globaltype_as_externtype(wasm_globaltype_copy(@ptrCast(@alignCast(e)))),
        extern_table => wasm_tabletype_as_externtype(wasm_tabletype_copy(@ptrCast(@alignCast(e)))),
        extern_memory => wasm_memorytype_as_externtype(wasm_memorytype_copy(@ptrCast(@alignCast(e)))),
        extern_tag => wasm_tagtype_as_externtype(wasm_tagtype_copy(@ptrCast(@alignCast(e)))),
        else => null,
    };
}

/// `wasm_externtype_vec_t` — pointer-vec; delete cascades to element delete.
pub const ExternTypeVec = extern struct {
    size: usize,
    data: ?[*]?*ExternType,
};

const ExternTypeVecOps = PtrVecOps(ExternType, ExternTypeVec, wasm_externtype_copy, wasm_externtype_delete);
pub export fn wasm_externtype_vec_new_empty(out: ?*ExternTypeVec) callconv(.c) void {
    ExternTypeVecOps.newEmpty(out);
}
pub export fn wasm_externtype_vec_new_uninitialized(out: ?*ExternTypeVec, size: usize) callconv(.c) void {
    ExternTypeVecOps.newUninit(out, size);
}
pub export fn wasm_externtype_vec_new(out: ?*ExternTypeVec, size: usize, src: ?[*]const ?*ExternType) callconv(.c) void {
    ExternTypeVecOps.new(out, size, src);
}
pub export fn wasm_externtype_vec_copy(out: ?*ExternTypeVec, src: ?*const ExternTypeVec) callconv(.c) void {
    ExternTypeVecOps.copy(out, src);
}
pub export fn wasm_externtype_vec_delete(v: ?*ExternTypeVec) callconv(.c) void {
    ExternTypeVecOps.delete(v);
}

// =====================================================================
// importtype / exporttype  (name = wasm_byte_vec_t)
// =====================================================================

const ByteVec = @import("vec.zig").ByteVec;

/// Opaque `wasm_importtype_t` — owns its module/name byte vecs + externtype.
pub const ImportType = extern struct {
    module: ByteVec,
    name: ByteVec,
    et: ?*ExternType,
};

/// Opaque `wasm_exporttype_t` — owns its name byte vec + externtype.
pub const ExportType = extern struct {
    name: ByteVec,
    et: ?*ExternType,
};

fn freeByteVec(bv: *ByteVec) void {
    if (bv.data) |p| ca.free(p[0..bv.size]);
    bv.* = .{ .size = 0, .data = null };
}

fn copyByteVec(src: ByteVec) ByteVec {
    if (src.size == 0 or src.data == null) return .{ .size = 0, .data = null };
    const buf = ca.alloc(u8, src.size) catch return .{ .size = 0, .data = null };
    @memcpy(buf, src.data.?[0..src.size]);
    return .{ .size = src.size, .data = buf.ptr };
}

pub export fn wasm_importtype_new(module: ?*ByteVec, name: ?*ByteVec, et: ?*ExternType) callconv(.c) ?*ImportType {
    const it = ca.create(ImportType) catch return null;
    it.* = .{
        .module = if (module) |m| m.* else .{ .size = 0, .data = null },
        .name = if (name) |n| n.* else .{ .size = 0, .data = null },
        .et = et,
    };
    if (module) |m| m.* = .{ .size = 0, .data = null }; // ownership transferred
    if (name) |n| n.* = .{ .size = 0, .data = null };
    return it;
}

pub export fn wasm_importtype_delete(it: ?*ImportType) callconv(.c) void {
    const i = it orelse return;
    freeByteVec(&i.module);
    freeByteVec(&i.name);
    if (i.et) |e| wasm_externtype_delete(e);
    ca.destroy(i);
}

pub export fn wasm_importtype_module(it: ?*const ImportType) callconv(.c) ?*const ByteVec {
    return &(it orelse return null).module;
}
pub export fn wasm_importtype_name(it: ?*const ImportType) callconv(.c) ?*const ByteVec {
    return &(it orelse return null).name;
}
pub export fn wasm_importtype_type(it: ?*const ImportType) callconv(.c) ?*const ExternType {
    return (it orelse return null).et;
}
pub export fn wasm_importtype_copy(it: ?*const ImportType) callconv(.c) ?*ImportType {
    const src = it orelse return null;
    const ni = ca.create(ImportType) catch return null;
    ni.* = .{
        .module = copyByteVec(src.module),
        .name = copyByteVec(src.name),
        .et = if (src.et) |e| wasm_externtype_copy(e) else null,
    };
    return ni;
}

pub export fn wasm_exporttype_new(name: ?*ByteVec, et: ?*ExternType) callconv(.c) ?*ExportType {
    const xt = ca.create(ExportType) catch return null;
    xt.* = .{
        .name = if (name) |n| n.* else .{ .size = 0, .data = null },
        .et = et,
    };
    if (name) |n| n.* = .{ .size = 0, .data = null };
    return xt;
}

pub export fn wasm_exporttype_delete(xt: ?*ExportType) callconv(.c) void {
    const x = xt orelse return;
    freeByteVec(&x.name);
    if (x.et) |e| wasm_externtype_delete(e);
    ca.destroy(x);
}

pub export fn wasm_exporttype_name(xt: ?*const ExportType) callconv(.c) ?*const ByteVec {
    return &(xt orelse return null).name;
}
pub export fn wasm_exporttype_type(xt: ?*const ExportType) callconv(.c) ?*const ExternType {
    return (xt orelse return null).et;
}
pub export fn wasm_exporttype_copy(xt: ?*const ExportType) callconv(.c) ?*ExportType {
    const src = xt orelse return null;
    const nx = ca.create(ExportType) catch return null;
    nx.* = .{
        .name = copyByteVec(src.name),
        .et = if (src.et) |e| wasm_externtype_copy(e) else null,
    };
    return nx;
}

// importtype / exporttype vecs (pointer-vecs; delete cascades).
pub const ImportTypeVec = extern struct { size: usize, data: ?[*]?*ImportType };
pub const ExportTypeVec = extern struct { size: usize, data: ?[*]?*ExportType };

const ImportTypeVecOps = PtrVecOps(ImportType, ImportTypeVec, wasm_importtype_copy, wasm_importtype_delete);
pub export fn wasm_importtype_vec_new_empty(out: ?*ImportTypeVec) callconv(.c) void {
    ImportTypeVecOps.newEmpty(out);
}
pub export fn wasm_importtype_vec_new_uninitialized(out: ?*ImportTypeVec, size: usize) callconv(.c) void {
    ImportTypeVecOps.newUninit(out, size);
}
pub export fn wasm_importtype_vec_new(out: ?*ImportTypeVec, size: usize, src: ?[*]const ?*ImportType) callconv(.c) void {
    ImportTypeVecOps.new(out, size, src);
}
pub export fn wasm_importtype_vec_copy(out: ?*ImportTypeVec, src: ?*const ImportTypeVec) callconv(.c) void {
    ImportTypeVecOps.copy(out, src);
}
pub export fn wasm_importtype_vec_delete(v: ?*ImportTypeVec) callconv(.c) void {
    ImportTypeVecOps.delete(v);
}

const ExportTypeVecOps = PtrVecOps(ExportType, ExportTypeVec, wasm_exporttype_copy, wasm_exporttype_delete);
pub export fn wasm_exporttype_vec_new_empty(out: ?*ExportTypeVec) callconv(.c) void {
    ExportTypeVecOps.newEmpty(out);
}
pub export fn wasm_exporttype_vec_new_uninitialized(out: ?*ExportTypeVec, size: usize) callconv(.c) void {
    ExportTypeVecOps.newUninit(out, size);
}
pub export fn wasm_exporttype_vec_new(out: ?*ExportTypeVec, size: usize, src: ?[*]const ?*ExportType) callconv(.c) void {
    ExportTypeVecOps.new(out, size, src);
}
pub export fn wasm_exporttype_vec_copy(out: ?*ExportTypeVec, src: ?*const ExportTypeVec) callconv(.c) void {
    ExportTypeVecOps.copy(out, src);
}
pub export fn wasm_exporttype_vec_delete(v: ?*ExportTypeVec) callconv(.c) void {
    ExportTypeVecOps.delete(v);
}

// =====================================================================
// functype / globaltype / tabletype / memorytype vecs (wasm.h
// WASM_DECLARE_TYPE → WASM_DECLARE_VEC). Owned-pointer vecs; same shape
// as the valtype/externtype/import/export families above (PtrVecOps).
// =====================================================================

pub const FuncTypeVec = extern struct { size: usize, data: ?[*]?*FuncType };
pub const GlobalTypeVec = extern struct { size: usize, data: ?[*]?*GlobalType };
pub const TableTypeVec = extern struct { size: usize, data: ?[*]?*TableType };
pub const MemoryTypeVec = extern struct { size: usize, data: ?[*]?*MemoryType };

const FuncTypeVecOps = PtrVecOps(FuncType, FuncTypeVec, wasm_functype_copy, wasm_functype_delete);
pub export fn wasm_functype_vec_new_empty(out: ?*FuncTypeVec) callconv(.c) void {
    FuncTypeVecOps.newEmpty(out);
}
pub export fn wasm_functype_vec_new_uninitialized(out: ?*FuncTypeVec, size: usize) callconv(.c) void {
    FuncTypeVecOps.newUninit(out, size);
}
pub export fn wasm_functype_vec_new(out: ?*FuncTypeVec, size: usize, src: ?[*]const ?*FuncType) callconv(.c) void {
    FuncTypeVecOps.new(out, size, src);
}
pub export fn wasm_functype_vec_copy(out: ?*FuncTypeVec, src: ?*const FuncTypeVec) callconv(.c) void {
    FuncTypeVecOps.copy(out, src);
}
pub export fn wasm_functype_vec_delete(v: ?*FuncTypeVec) callconv(.c) void {
    FuncTypeVecOps.delete(v);
}

const GlobalTypeVecOps = PtrVecOps(GlobalType, GlobalTypeVec, wasm_globaltype_copy, wasm_globaltype_delete);
pub export fn wasm_globaltype_vec_new_empty(out: ?*GlobalTypeVec) callconv(.c) void {
    GlobalTypeVecOps.newEmpty(out);
}
pub export fn wasm_globaltype_vec_new_uninitialized(out: ?*GlobalTypeVec, size: usize) callconv(.c) void {
    GlobalTypeVecOps.newUninit(out, size);
}
pub export fn wasm_globaltype_vec_new(out: ?*GlobalTypeVec, size: usize, src: ?[*]const ?*GlobalType) callconv(.c) void {
    GlobalTypeVecOps.new(out, size, src);
}
pub export fn wasm_globaltype_vec_copy(out: ?*GlobalTypeVec, src: ?*const GlobalTypeVec) callconv(.c) void {
    GlobalTypeVecOps.copy(out, src);
}
pub export fn wasm_globaltype_vec_delete(v: ?*GlobalTypeVec) callconv(.c) void {
    GlobalTypeVecOps.delete(v);
}

const TableTypeVecOps = PtrVecOps(TableType, TableTypeVec, wasm_tabletype_copy, wasm_tabletype_delete);
pub export fn wasm_tabletype_vec_new_empty(out: ?*TableTypeVec) callconv(.c) void {
    TableTypeVecOps.newEmpty(out);
}
pub export fn wasm_tabletype_vec_new_uninitialized(out: ?*TableTypeVec, size: usize) callconv(.c) void {
    TableTypeVecOps.newUninit(out, size);
}
pub export fn wasm_tabletype_vec_new(out: ?*TableTypeVec, size: usize, src: ?[*]const ?*TableType) callconv(.c) void {
    TableTypeVecOps.new(out, size, src);
}
pub export fn wasm_tabletype_vec_copy(out: ?*TableTypeVec, src: ?*const TableTypeVec) callconv(.c) void {
    TableTypeVecOps.copy(out, src);
}
pub export fn wasm_tabletype_vec_delete(v: ?*TableTypeVec) callconv(.c) void {
    TableTypeVecOps.delete(v);
}

const MemoryTypeVecOps = PtrVecOps(MemoryType, MemoryTypeVec, wasm_memorytype_copy, wasm_memorytype_delete);
pub export fn wasm_memorytype_vec_new_empty(out: ?*MemoryTypeVec) callconv(.c) void {
    MemoryTypeVecOps.newEmpty(out);
}
pub export fn wasm_memorytype_vec_new_uninitialized(out: ?*MemoryTypeVec, size: usize) callconv(.c) void {
    MemoryTypeVecOps.newUninit(out, size);
}
pub export fn wasm_memorytype_vec_new(out: ?*MemoryTypeVec, size: usize, src: ?[*]const ?*MemoryType) callconv(.c) void {
    MemoryTypeVecOps.new(out, size, src);
}
pub export fn wasm_memorytype_vec_copy(out: ?*MemoryTypeVec, src: ?*const MemoryTypeVec) callconv(.c) void {
    MemoryTypeVecOps.copy(out, src);
}
pub export fn wasm_memorytype_vec_delete(v: ?*MemoryTypeVec) callconv(.c) void {
    MemoryTypeVecOps.delete(v);
}

// =====================================================================
// Tests
// =====================================================================

test "valtype: new/kind/copy/delete round-trip" {
    const vt = wasm_valtype_new(0).?; // WASM_I32
    defer wasm_valtype_delete(vt);
    try testing.expectEqual(@as(u8, 0), wasm_valtype_kind(vt));
    const c = wasm_valtype_copy(vt).?;
    defer wasm_valtype_delete(c);
    try testing.expectEqual(@as(u8, 0), wasm_valtype_kind(c));
    wasm_valtype_delete(null); // null-tolerant
}

test "valtype_vec: new from elements, delete cascades to elements" {
    var elems = [_]?*ValType{ wasm_valtype_new(0), wasm_valtype_new(1) };
    var vec: ValTypeVec = undefined;
    wasm_valtype_vec_new(&vec, elems.len, &elems);
    try testing.expectEqual(@as(usize, 2), vec.size);
    try testing.expectEqual(@as(u8, 1), wasm_valtype_kind(vec.data.?[1].?));
    wasm_valtype_vec_delete(&vec); // frees the two valtypes + the array
    try testing.expectEqual(@as(usize, 0), vec.size);
}

test "functype: new consumes vecs, params/results query, delete" {
    var params = [_]?*ValType{ wasm_valtype_new(0), wasm_valtype_new(1) }; // (i32,i64)
    var results = [_]?*ValType{wasm_valtype_new(2)}; // -> f32
    var pv: ValTypeVec = undefined;
    var rv: ValTypeVec = undefined;
    wasm_valtype_vec_new(&pv, params.len, &params);
    wasm_valtype_vec_new(&rv, results.len, &results);
    const ft = wasm_functype_new(&pv, &rv).?;
    defer wasm_functype_delete(ft);
    // Inputs were consumed (zeroed).
    try testing.expectEqual(@as(usize, 0), pv.size);
    try testing.expectEqual(@as(usize, 2), wasm_functype_params(ft).?.size);
    try testing.expectEqual(@as(usize, 1), wasm_functype_results(ft).?.size);
    try testing.expectEqual(@as(u8, 2), wasm_valtype_kind(wasm_functype_results(ft).?.data.?[0].?));
}

test "functype: copy is deep (independent delete)" {
    var pv: ValTypeVec = undefined;
    var rv: ValTypeVec = undefined;
    var params = [_]?*ValType{wasm_valtype_new(0)};
    wasm_valtype_vec_new(&pv, params.len, &params);
    wasm_valtype_vec_new_empty(&rv);
    const ft = wasm_functype_new(&pv, &rv).?;
    defer wasm_functype_delete(ft);
    const ft2 = wasm_functype_copy(ft).?;
    defer wasm_functype_delete(ft2); // independent — no double-free
    try testing.expectEqual(@as(usize, 1), wasm_functype_params(ft2).?.size);
}

test "globaltype: content/mutability + owns valtype" {
    const gt = wasm_globaltype_new(wasm_valtype_new(3), 1).?; // f64, VAR
    defer wasm_globaltype_delete(gt);
    try testing.expectEqual(@as(u8, 3), wasm_valtype_kind(wasm_globaltype_content(gt).?));
    try testing.expectEqual(@as(u8, 1), wasm_globaltype_mutability(gt));
}

test "tabletype + memorytype: limits round-trip" {
    var lim: Limits = .{ .min = 1, .max = 10 };
    const tt = wasm_tabletype_new(wasm_valtype_new(129), &lim).?; // funcref
    defer wasm_tabletype_delete(tt);
    try testing.expectEqual(@as(u32, 1), wasm_tabletype_limits(tt).?.min);
    try testing.expectEqual(@as(u8, 129), wasm_valtype_kind(wasm_tabletype_element(tt).?));

    const mt = wasm_memorytype_new(&lim).?;
    defer wasm_memorytype_delete(mt);
    try testing.expectEqual(@as(u32, 10), wasm_memorytype_limits(mt).?.max);
}

test "externtype: functype round-trips through as_externtype + kind + checked downcast" {
    var pv: ValTypeVec = undefined;
    var rv: ValTypeVec = undefined;
    wasm_valtype_vec_new_empty(&pv);
    wasm_valtype_vec_new_empty(&rv);
    const ft = wasm_functype_new(&pv, &rv).?;
    const et = wasm_functype_as_externtype(ft).?; // zero-alloc view
    try testing.expectEqual(extern_func, wasm_externtype_kind(et));
    try testing.expect(wasm_externtype_as_functype(et) == ft); // same object
    try testing.expect(wasm_externtype_as_globaltype(et) == null); // kind mismatch
    wasm_externtype_delete(et); // dispatches to functype_delete (frees the object once)
}

test "externtype: copy dispatches by kind (independent delete)" {
    var lim: Limits = .{ .min = 2, .max = 4 };
    const mt = wasm_memorytype_new(&lim).?;
    const et = wasm_memorytype_as_externtype(mt).?;
    const et2 = wasm_externtype_copy(et).?;
    defer wasm_externtype_delete(et2);
    defer wasm_externtype_delete(et);
    try testing.expectEqual(extern_memory, wasm_externtype_kind(et2));
    try testing.expectEqual(@as(u32, 4), wasm_externtype_as_memorytype(et2).?.limits.max);
}

test "importtype: module/name/type + owns externtype, delete frees all" {
    var lim: Limits = .{ .min = 1, .max = 1 };
    const et = wasm_tabletype_as_externtype(wasm_tabletype_new(wasm_valtype_new(129), &lim).?).?;
    var mod: ByteVec = undefined;
    var nm: ByteVec = undefined;
    @import("vec.zig").wasm_byte_vec_new(&mod, 3, "env");
    @import("vec.zig").wasm_byte_vec_new(&nm, 1, "t");
    const it = wasm_importtype_new(&mod, &nm, et).?;
    defer wasm_importtype_delete(it);
    try testing.expectEqual(@as(usize, 0), mod.size); // consumed
    try testing.expectEqual(@as(usize, 3), wasm_importtype_module(it).?.size);
    try testing.expectEqual(extern_table, wasm_externtype_kind(wasm_importtype_type(it).?));
}

test "exporttype: name/type + copy is independent" {
    var lim: Limits = .{ .min = 0, .max = 0xffff_ffff };
    const et = wasm_memorytype_as_externtype(wasm_memorytype_new(&lim).?).?;
    var nm: ByteVec = undefined;
    @import("vec.zig").wasm_byte_vec_new(&nm, 3, "mem");
    const xt = wasm_exporttype_new(&nm, et).?;
    defer wasm_exporttype_delete(xt);
    const xt2 = wasm_exporttype_copy(xt).?;
    defer wasm_exporttype_delete(xt2); // independent
    try testing.expectEqual(@as(usize, 3), wasm_exporttype_name(xt2).?.size);
    try testing.expectEqual(extern_memory, wasm_externtype_kind(wasm_exporttype_type(xt2).?));
}

test "importtype_vec: delete cascades to element delete" {
    var lim: Limits = .{ .min = 1, .max = 1 };
    var mod: ByteVec = undefined;
    var nm: ByteVec = undefined;
    @import("vec.zig").wasm_byte_vec_new(&mod, 1, "a");
    @import("vec.zig").wasm_byte_vec_new(&nm, 1, "b");
    const it = wasm_importtype_new(&mod, &nm, wasm_memorytype_as_externtype(wasm_memorytype_new(&lim).?).?).?;
    var elems = [_]?*ImportType{it};
    var vec: ImportTypeVec = undefined;
    wasm_importtype_vec_new(&vec, 1, &elems);
    try testing.expectEqual(@as(usize, 1), vec.size);
    wasm_importtype_vec_delete(&vec); // frees the importtype (+ its name vecs + externtype)
    try testing.expectEqual(@as(usize, 0), vec.size);
}

test "globaltype_vec (PtrVecOps): new adopts, copy is deep-independent, delete cascades + null discipline" {
    var elems = [_]?*GlobalType{
        wasm_globaltype_new(wasm_valtype_new(0), 0), // const i32
        wasm_globaltype_new(wasm_valtype_new(1), 1), // var i64
    };
    var v: GlobalTypeVec = undefined;
    wasm_globaltype_vec_new(&v, elems.len, &elems);
    try testing.expectEqual(@as(usize, 2), v.size);
    try testing.expectEqual(@as(u8, 1), wasm_valtype_kind(wasm_globaltype_content(v.data.?[1].?).?)); // i64
    try testing.expectEqual(@as(u8, 1), wasm_globaltype_mutability(v.data.?[1].?)); // WASM_VAR

    var c: GlobalTypeVec = undefined;
    wasm_globaltype_vec_copy(&c, &v);
    try testing.expectEqual(@as(usize, 2), c.size);
    try testing.expect(v.data.? != c.data.?); // independent array
    try testing.expect(v.data.?[0].? != c.data.?[0].?); // independent elements (deep copy)
    try testing.expectEqual(@as(u8, 0), wasm_valtype_kind(wasm_globaltype_content(c.data.?[0].?).?)); // i32

    wasm_globaltype_vec_delete(&v);
    wasm_globaltype_vec_delete(&c);
    try testing.expectEqual(@as(usize, 0), v.size);

    var empty: GlobalTypeVec = .{ .size = 99, .data = null };
    wasm_globaltype_vec_new_empty(&empty);
    try testing.expectEqual(@as(usize, 0), empty.size);
    var u: GlobalTypeVec = undefined;
    wasm_globaltype_vec_new_uninitialized(&u, 3);
    try testing.expectEqual(@as(usize, 3), u.size);
    try testing.expect(u.data.?[0] == null); // pointer-vec memset to null
    wasm_globaltype_vec_delete(&u);
    wasm_globaltype_vec_new_empty(null);
    wasm_globaltype_vec_copy(null, null);
    wasm_globaltype_vec_delete(null);
}

test "functype/tabletype/memorytype vec: new/copy/delete smoke (PtrVecOps instantiations)" {
    var fts = [_]?*FuncType{wasm_functype_new(null, null)}; // () -> ()
    var fv: FuncTypeVec = undefined;
    wasm_functype_vec_new(&fv, fts.len, &fts);
    var fv2: FuncTypeVec = undefined;
    wasm_functype_vec_copy(&fv2, &fv);
    try testing.expectEqual(@as(usize, 1), fv2.size);
    try testing.expect(fv.data.?[0].? != fv2.data.?[0].?); // deep copy
    wasm_functype_vec_delete(&fv);
    wasm_functype_vec_delete(&fv2);

    var tlim: Limits = .{ .min = 1, .max = 0xffff_ffff };
    var tts = [_]?*TableType{wasm_tabletype_new(wasm_valtype_new(129), &tlim)}; // funcref [1..]
    var tv: TableTypeVec = undefined;
    wasm_tabletype_vec_new(&tv, tts.len, &tts);
    var tv2: TableTypeVec = undefined;
    wasm_tabletype_vec_copy(&tv2, &tv);
    try testing.expectEqual(@as(usize, 1), tv2.size);
    wasm_tabletype_vec_delete(&tv);
    wasm_tabletype_vec_delete(&tv2);

    var mlim: Limits = .{ .min = 2, .max = 0xffff_ffff };
    var mts = [_]?*MemoryType{wasm_memorytype_new(&mlim)}; // [2..]
    var mv: MemoryTypeVec = undefined;
    wasm_memorytype_vec_new(&mv, mts.len, &mts);
    var mv2: MemoryTypeVec = undefined;
    wasm_memorytype_vec_copy(&mv2, &mv);
    try testing.expectEqual(@as(usize, 1), mv2.size);
    wasm_memorytype_vec_delete(&mv);
    wasm_memorytype_vec_delete(&mv2);
}
