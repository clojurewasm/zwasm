//! wasm-c-api module introspection — `wasm_module_imports` / `_exports`
//! (§13.2 / Phase 13). Extracted from `api/instance.zig` (a genuinely
//! separable subsystem per ADR-0099 §D2 P3 / the D-171 restructure note):
//! it decodes a `Module`'s import/export sections into the `api/types.zig`
//! externtype descriptors. One-way dependency on `instance.Module` (no
//! cycle — instance does not import this).
//!
//! Zone 3 (`src/api/`). Re-exported via `api/wasm.zig`.

const std = @import("std");
const testing = std.testing;

const parser = @import("../parse/parser.zig");
const sections = @import("../parse/sections.zig");
const zir = @import("../ir/zir.zig");
const types = @import("types.zig");
const vec = @import("vec.zig");
const instance = @import("instance.zig");

const Module = instance.Module;
const ca = std.heap.c_allocator;

/// Map an internal `zir.ValType` → a `wasm_valkind_t` byte (wasm.h:
/// I32=0..F64=3, EXTERNREF=128, FUNCREF=129). v128 has no base-enum
/// valkind → mapped to 4 (best-effort; rare in import/export functypes).
/// Non-funcref refs (Wasm 3.0 GC) collapse to EXTERNREF.
fn valKindOf(vt: zir.ValType) u8 {
    return switch (vt) {
        .i32 => 0,
        .i64 => 1,
        .f32 => 2,
        .f64 => 3,
        .v128 => 4,
        .ref => if (vt.isFuncref()) 129 else 128,
    };
}

/// Build a `wasm_valtype_vec_t` from internal valtypes (each a fresh owned
/// `wasm_valtype_t`). Empty vec for an empty slice.
fn buildValTypeVec(vts: []const zir.ValType) types.ValTypeVec {
    var out: types.ValTypeVec = .{ .size = 0, .data = null };
    if (vts.len == 0) return out;
    const tmp = ca.alloc(?*types.ValType, vts.len) catch return out;
    defer ca.free(tmp);
    for (vts, 0..) |vt, i| tmp[i] = types.wasm_valtype_new(valKindOf(vt));
    types.wasm_valtype_vec_new(&out, vts.len, tmp.ptr); // copies the owned pointers in
    return out;
}

/// Build the `wasm_externtype_t` for one decoded import. Returns null for
/// tag imports (no base-wasm-c-api `tagtype`) — the caller skips them.
fn buildImportExternType(it: sections.Import, func_types: ?sections.Types) ?*types.ExternType {
    switch (it.payload) {
        .func_typeidx => |ti| {
            const ts = func_types orelse return null;
            if (ti >= ts.items.len) return null;
            const ft = ts.items[ti];
            var pv = buildValTypeVec(ft.params);
            var rv = buildValTypeVec(ft.results);
            const ftype = types.wasm_functype_new(&pv, &rv) orelse {
                types.wasm_valtype_vec_delete(&pv);
                types.wasm_valtype_vec_delete(&rv);
                return null;
            };
            return types.wasm_functype_as_externtype(ftype);
        },
        .global => |g| {
            const vt = types.wasm_valtype_new(valKindOf(g.valtype)) orelse return null;
            const gt = types.wasm_globaltype_new(vt, if (g.mutable) 1 else 0) orelse {
                types.wasm_valtype_delete(vt);
                return null;
            };
            return types.wasm_globaltype_as_externtype(gt);
        },
        .table => |t| {
            const vt = types.wasm_valtype_new(valKindOf(t.elem_type)) orelse return null;
            var lim: types.Limits = .{ .min = t.min, .max = t.max orelse 0xffff_ffff };
            const tt = types.wasm_tabletype_new(vt, &lim) orelse {
                types.wasm_valtype_delete(vt);
                return null;
            };
            return types.wasm_tabletype_as_externtype(tt);
        },
        .memory => |mem| {
            var lim: types.Limits = .{
                .min = std.math.cast(u32, mem.min) orelse return null,
                .max = if (mem.max) |mx| (std.math.cast(u32, mx) orelse 0xffff_ffff) else 0xffff_ffff,
            };
            const mt = types.wasm_memorytype_new(&lim) orelse return null;
            return types.wasm_memorytype_as_externtype(mt);
        },
        .tag_typeidx => return null, // tagtype not in base wasm-c-api — skipped
    }
}

/// `wasm_module_imports(module, own importtype_vec* out)` — decode the
/// module's import section into one `wasm_importtype_t` per import (module
/// name + field name + the import's externtype). Tag imports are skipped
/// (no base `tagtype`). `out` is owned by the caller (`importtype_vec_delete`).
pub export fn wasm_module_imports(m: ?*const Module, out: ?*types.ImportTypeVec) callconv(.c) void {
    const o = out orelse return;
    o.* = .{ .size = 0, .data = null };
    const mod = m orelse return;
    const bp = mod.bytes_ptr orelse return;
    const bytes = bp[0..mod.bytes_len];

    var arena = std.heap.ArenaAllocator.init(ca);
    defer arena.deinit();
    const a = arena.allocator();

    var parsed = parser.parse(a, bytes) catch return;
    defer parsed.deinit(a);
    const imp_sec = parsed.find(.import) orelse return; // no imports → empty vec
    var imps = sections.decodeImports(a, imp_sec.body) catch return;
    defer imps.deinit();
    if (imps.items.len == 0) return;

    var func_types: ?sections.Types = null;
    defer if (func_types) |*t| t.deinit();
    if (parsed.find(.type)) |ts| func_types = sections.decodeTypes(a, ts.body) catch null;

    // Collect built importtypes (skipping unsupported), then publish the vec.
    var built: std.ArrayList(?*types.ImportType) = .empty;
    defer built.deinit(ca);
    for (imps.items) |it| {
        const et = buildImportExternType(it, func_types) orelse continue;
        var modv: vec.ByteVec = undefined;
        var nmv: vec.ByteVec = undefined;
        vec.wasm_byte_vec_new(&modv, it.module.len, it.module.ptr);
        vec.wasm_byte_vec_new(&nmv, it.name.len, it.name.ptr);
        const imp = types.wasm_importtype_new(&modv, &nmv, et) orelse {
            types.wasm_externtype_delete(et);
            if (modv.data) |p| ca.free(p[0..modv.size]);
            if (nmv.data) |p| ca.free(p[0..nmv.size]);
            continue;
        };
        built.append(ca, imp) catch {
            types.wasm_importtype_delete(imp);
            continue;
        };
    }
    types.wasm_importtype_vec_new(o, built.items.len, if (built.items.len > 0) built.items.ptr else null);
}

// =====================================================================
// Tests
// =====================================================================

// (module (type (func (param i32))) (import "env" "f" (func (type 0))))
const func_import_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, // type (i32) -> ()
    0x02, 0x09, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x01, 0x66, 0x00, 0x00, // import env.f func type 0
};

test "wasm_module_imports: func import → importtype (env.f : (i32) -> ())" {
    const e = instance.wasm_engine_new() orelse return error.EngineAllocFailed;
    defer instance.wasm_engine_delete(e);
    const s = instance.wasm_store_new(e) orelse return error.StoreAllocFailed;
    defer instance.wasm_store_delete(s);
    var bytes = func_import_wasm;
    const bv: vec.ByteVec = .{ .size = bytes.len, .data = &bytes };
    const m = instance.wasm_module_new(s, &bv) orelse return error.ModuleAllocFailed;
    defer instance.wasm_module_delete(m);

    var imports: types.ImportTypeVec = undefined;
    wasm_module_imports(m, &imports);
    defer types.wasm_importtype_vec_delete(&imports);

    try testing.expectEqual(@as(usize, 1), imports.size);
    const it = imports.data.?[0].?;
    try testing.expectEqualStrings("env", types.wasm_importtype_module(it).?.data.?[0..3]);
    try testing.expectEqualStrings("f", types.wasm_importtype_name(it).?.data.?[0..1]);
    const et = types.wasm_importtype_type(it).?;
    try testing.expectEqual(types.extern_func, types.wasm_externtype_kind(et));
    const ft = types.wasm_externtype_as_functype_const(et).?;
    try testing.expectEqual(@as(usize, 1), ft.params.size);
    try testing.expectEqual(@as(u8, 0), types.wasm_valtype_kind(ft.params.data.?[0].?)); // i32
    try testing.expectEqual(@as(usize, 0), ft.results.size);
}

test "wasm_module_imports: null-arg → empty vec, no crash" {
    var imports: types.ImportTypeVec = undefined;
    wasm_module_imports(null, &imports);
    try testing.expectEqual(@as(usize, 0), imports.size);
    wasm_module_imports(null, null);
}
