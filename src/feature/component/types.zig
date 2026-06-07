//! Component **type model + type/import/export section decode** (CM campaign
//! chunk A2; spec `component-model/design/mvp/Binary.md` §type / §import-export).
//!
//! Builds the component-level type index space from the `type` section (id 7)
//! and the `import` (id 10) / `export` (id 11) sections. The model is kept
//! DISTINCT from `runtime.Value` (`single_slot_dual_meaning`): a component
//! `ValType` describes interface-level shape, not a runtime slot.
//!
//! Encoding note (`Binary.md`): type-constructor opcodes use the same
//! negative-SLEB128 scheme as Core Wasm — `0x7f` is `SLEB(-1)` and they count
//! down, leaving the non-negative SLEB128 range for type indices. So a
//! `valtype` is decoded by reading one SLEB128: negative → a primitive opcode
//! (`v & 0x7f`), non-negative → a `typeidx` into the type index space.
//!
//! SCOPE (A2): primitive value types + `functype` (0x40 / async 0x43) + the
//! type index space + top-level imports/exports referencing func/core-module/
//! component/instance type indices. The compound `defvaltype` forms (record /
//! variant / list / tuple / flags / enum / option / result / own / borrow) are
//! decoded alongside their canonical-ABI lift/lower in the B-chunks; the
//! recursive `componenttype` / `instancetype` / `resourcetype` forms land in
//! the C-chunks (linking / resources). Until then the decoder returns a typed
//! `UnsupportedTypeForm` (a spec-faithful deferral, never a silent skip).
//!
//! No-copy: v1 `component.zig` uses an OLDER component-model draft (e.g. its
//! `0x41` is `func`, the current spec's `0x41` is `componenttype`). This is
//! re-derived from the current `Binary.md` (component `version == 0x0d`).

const std = @import("std");

const leb128 = @import("../../support/leb128.zig");
const decode = @import("decode.zig");

const Allocator = std.mem.Allocator;

/// Primitive value types (`Binary.md` `primvaltype`). Enum values ARE the
/// (positive) opcode bytes, i.e. `v & 0x7f` of the negative SLEB128.
pub const PrimValType = enum(u8) {
    bool = 0x7f,
    s8 = 0x7e,
    u8 = 0x7d,
    s16 = 0x7c,
    u16 = 0x7b,
    s32 = 0x7a,
    u32 = 0x79,
    s64 = 0x78,
    u64 = 0x77,
    f32 = 0x76,
    f64 = 0x75,
    char = 0x74,
    string = 0x73,
    error_context = 0x64,
};

/// `valtype ::= typeidx | primvaltype` (`Binary.md`). A compound type is never
/// inline here — it is a `deftype` referenced by `type_index`.
pub const ValType = union(enum) {
    primitive: PrimValType,
    type_index: u32,
};

/// `labelvaltype ::= label' valtype` — a named parameter/field. `name` borrows
/// from the decoded input.
pub const NamedVal = struct {
    name: []const u8,
    ty: ValType,
};

/// `functype ::= 0x40 paramlist resultlist` (async variant `0x43`).
/// `resultlist` is a single optional result (`0x00 valtype` | `0x01 0x00`).
pub const FuncType = struct {
    params: []const NamedVal,
    result: ?ValType,
    is_async: bool,
};

/// `enum` defvaltype (`Binary.md` 0x6d): an ordered label set, no payloads.
pub const EnumType = struct {
    labels: []const []const u8,
};

/// `flags` defvaltype (`Binary.md` 0x6e): a bit-set of labels (1..=32).
pub const FlagsType = struct {
    labels: []const []const u8,
};

/// One `deftype` in the type index space. A2 modelled the primitive-`defvaltype`
/// and `functype` forms; B2 adds `enum`/`flags`; record/variant/list etc. land
/// in their B-chunks.
pub const DefType = union(enum) {
    value: ValType,
    func: FuncType,
    enum_: EnumType,
    flags: FlagsType,
};

/// Component-level `sort` (`Binary.md`); `core` nests a `core:sort`.
pub const CoreSort = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
    tag = 0x04,
    type = 0x10,
    module = 0x11,
    instance = 0x12,
    _,
};

pub const Sort = union(enum) {
    core: CoreSort,
    func,
    value,
    type,
    component,
    instance,
};

/// `externdesc` (`Binary.md`) — what an import/export refers to. A2 models the
/// type-index-carrying forms; `value`/`type` bounds defer to later chunks.
pub const ExternDesc = union(enum) {
    core_module: u32,
    func: u32,
    component: u32,
    instance: u32,
};

pub const Import = struct {
    name: []const u8,
    desc: ExternDesc,
};

/// Top-level `export ::= exportname' sortidx externdesc?` — the export aliases
/// a definition by `sortidx`; the optional `externdesc` ascribes a type.
pub const Export = struct {
    name: []const u8,
    sort: Sort,
    index: u32,
    desc: ?ExternDesc,
};

/// The decoded type index space + import/export lists. All owned allocations
/// live in `arena`; `name` slices borrow from the component input.
pub const TypeInfo = struct {
    arena: std.heap.ArenaAllocator,
    deftypes: std.ArrayList(DefType),
    imports: std.ArrayList(Import),
    exports: std.ArrayList(Export),

    pub fn deinit(self: *TypeInfo) void {
        self.arena.deinit();
    }

    /// Resolve a `typeidx` against the decoded type index space.
    pub fn deftype(self: *const TypeInfo, index: u32) ?DefType {
        if (index >= self.deftypes.items.len) return null;
        return self.deftypes.items[index];
    }
};

pub const Error = error{
    Truncated,
    InvalidValType,
    InvalidDefType,
    InvalidFuncType,
    InvalidTypeIndex,
    InvalidName,
    InvalidExternDesc,
    InvalidSort,
    /// `enum` with zero labels (spec requires `> 0`).
    EmptyEnum,
    /// `flags` label count outside `0 < n <= 32` (spec cap).
    InvalidFlagsCount,
    /// A spec-defined form not yet decoded (compound defvaltype → B-chunks;
    /// component/instance/resource type → C-chunks). Typed deferral, not a
    /// silent skip (`no_workaround`).
    UnsupportedTypeForm,
    TrailingBytes,
    OutOfMemory,
} || leb128.Error;

// ============================================================
// Primitive decode helpers (operate on a section body + cursor)
// ============================================================

fn primFromOpcode(op: u8) Error!PrimValType {
    return switch (op) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x7a, 0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x64 => @enumFromInt(op),
        // Compound defvaltype opcodes are valid deftypes but never inline
        // valtypes; in a valtype position they are malformed.
        else => Error.InvalidValType,
    };
}

/// `valtype ::= typeidx | primvaltype` via the negative-SLEB128 scheme.
fn decodeValType(body: []const u8, pos: *usize) Error!ValType {
    const v = try leb128.readSleb128(i64, body, pos);
    if (v < 0) return .{ .primitive = try primFromOpcode(@intCast(v & 0x7f)) };
    if (v > std.math.maxInt(u32)) return Error.InvalidTypeIndex;
    return .{ .type_index = @intCast(v) };
}

/// `label' ::= len:u32 label` / `name ::= len:u32 bytes` — a length-prefixed
/// borrowed slice (no prefix byte).
fn decodeLabel(body: []const u8, pos: *usize) Error![]const u8 {
    const len = try leb128.readUleb128(u32, body, pos);
    const len_usize: usize = @intCast(len);
    if (len_usize > body.len - pos.*) return Error.InvalidName;
    const s = body[pos.* .. pos.* + len_usize];
    pos.* += len_usize;
    return s;
}

/// `vec(label')` — a length-prefixed sequence of length-prefixed labels
/// (enum/flags label lists). Labels borrow from the input.
fn decodeLabelVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const []const u8 {
    const count = try leb128.readUleb128(u32, body, pos);
    var labels: std.ArrayList([]const u8) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try labels.append(arena, try decodeLabel(body, pos));
    }
    return labels.toOwnedSlice(arena);
}

/// `importname' ::= (0x00|0x01) len name | 0x02 len name versionsuffix`.
/// The 0x00/0x01 prefixes are the pre-1.0 plain/interface distinction (both
/// yield the base name); 0x02 carries a trailing semver suffix, read and
/// dropped (spec: "ignored for validation except diagnostics"). Returns the
/// base name (borrowed).
fn decodeImportExportName(body: []const u8, pos: *usize) Error![]const u8 {
    if (pos.* >= body.len) return Error.Truncated;
    const prefix = body[pos.*];
    pos.* += 1;
    switch (prefix) {
        0x00, 0x01 => return try decodeLabel(body, pos),
        0x02 => {
            const name = try decodeLabel(body, pos);
            _ = try decodeLabel(body, pos); // versionsuffix — dropped
            return name;
        },
        else => return Error.InvalidName,
    }
}

fn decodeFuncType(arena: Allocator, body: []const u8, pos: *usize, is_async: bool) Error!FuncType {
    const param_count = try leb128.readUleb128(u32, body, pos);
    var params: std.ArrayList(NamedVal) = .empty;
    var i: u32 = 0;
    while (i < param_count) : (i += 1) {
        const name = try decodeLabel(body, pos);
        const ty = try decodeValType(body, pos);
        try params.append(arena, .{ .name = name, .ty = ty });
    }

    if (pos.* >= body.len) return Error.InvalidFuncType;
    const result_tag = body[pos.*];
    pos.* += 1;
    const result: ?ValType = switch (result_tag) {
        0x00 => try decodeValType(body, pos),
        0x01 => blk: {
            if (pos.* >= body.len or body[pos.*] != 0x00) return Error.InvalidFuncType;
            pos.* += 1;
            break :blk null;
        },
        else => return Error.InvalidFuncType,
    };

    return .{ .params = try params.toOwnedSlice(arena), .result = result, .is_async = is_async };
}

fn decodeDefType(arena: Allocator, body: []const u8, pos: *usize) Error!DefType {
    const v = try leb128.readSleb128(i64, body, pos);
    if (v >= 0) return Error.InvalidDefType; // a deftype is never a bare typeidx
    const op: u8 = @intCast(v & 0x7f);
    return switch (op) {
        0x7f, 0x7e, 0x7d, 0x7c, 0x7b, 0x7a, 0x79, 0x78, 0x77, 0x76, 0x75, 0x74, 0x73, 0x64 => .{ .value = .{ .primitive = @enumFromInt(op) } },
        0x40 => .{ .func = try decodeFuncType(arena, body, pos, false) },
        0x43 => .{ .func = try decodeFuncType(arena, body, pos, true) },
        0x6d => blk: { // enum: vec(label')
            const labels = try decodeLabelVec(arena, body, pos);
            if (labels.len == 0) break :blk Error.EmptyEnum;
            break :blk .{ .enum_ = .{ .labels = labels } };
        },
        0x6e => blk: { // flags: vec(label'), 0 < n <= 32
            const labels = try decodeLabelVec(arena, body, pos);
            if (labels.len == 0 or labels.len > 32) break :blk Error.InvalidFlagsCount;
            break :blk .{ .flags = .{ .labels = labels } };
        },
        // TODO(p17/CM-B*): remaining compound defvaltype (record 0x72 /
        // variant 0x71 / list 0x70,0x67 / tuple 0x6f / option 0x6b /
        // result 0x6a / own 0x69 / borrow 0x68 / stream 0x66 / future 0x65).
        0x72, 0x71, 0x70, 0x67, 0x6f, 0x6b, 0x6a, 0x69, 0x68, 0x66, 0x65 => Error.UnsupportedTypeForm,
        // TODO(p17/CM-C*): componenttype 0x41 / instancetype 0x42 /
        // resourcetype 0x3f,0x3e (recurse into the declarator tree).
        0x41, 0x42, 0x3f, 0x3e => Error.UnsupportedTypeForm,
        else => Error.InvalidDefType,
    };
}

fn decodeSortIdx(body: []const u8, pos: *usize) Error!struct { sort: Sort, index: u32 } {
    if (pos.* >= body.len) return Error.Truncated;
    const sort_byte = body[pos.*];
    pos.* += 1;
    const sort: Sort = switch (sort_byte) {
        0x00 => blk: {
            if (pos.* >= body.len) return Error.Truncated;
            const cs = body[pos.*];
            pos.* += 1;
            break :blk .{ .core = @enumFromInt(cs) };
        },
        0x01 => .func,
        0x02 => .value,
        0x03 => .type,
        0x04 => .component,
        0x05 => .instance,
        else => return Error.InvalidSort,
    };
    const index = try leb128.readUleb128(u32, body, pos);
    return .{ .sort = sort, .index = index };
}

fn decodeExternDesc(body: []const u8, pos: *usize) Error!ExternDesc {
    if (pos.* >= body.len) return Error.Truncated;
    const tag = body[pos.*];
    pos.* += 1;
    switch (tag) {
        0x00 => {
            if (pos.* >= body.len or body[pos.*] != 0x11) return Error.InvalidExternDesc;
            pos.* += 1; // 0x11 = core:sort module
            return .{ .core_module = try leb128.readUleb128(u32, body, pos) };
        },
        0x01 => return .{ .func = try leb128.readUleb128(u32, body, pos) },
        0x04 => return .{ .component = try leb128.readUleb128(u32, body, pos) },
        0x05 => return .{ .instance = try leb128.readUleb128(u32, body, pos) },
        // TODO(p17/CM): value-bound (0x02) + type-bound (0x03) externdescs.
        0x02, 0x03 => return Error.UnsupportedTypeForm,
        else => return Error.InvalidExternDesc,
    }
}

// ============================================================
// Section-level decode
// ============================================================

fn decodeTypeSection(arena: Allocator, out: *std.ArrayList(DefType), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try out.append(arena, try decodeDefType(arena, body, &pos));
    }
    if (pos != body.len) return Error.TrailingBytes;
}

fn decodeImportSection(arena: Allocator, out: *std.ArrayList(Import), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeImportExportName(body, &pos);
        const desc = try decodeExternDesc(body, &pos);
        try out.append(arena, .{ .name = name, .desc = desc });
    }
    if (pos != body.len) return Error.TrailingBytes;
}

fn decodeExportSection(arena: Allocator, out: *std.ArrayList(Export), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeImportExportName(body, &pos);
        const si = try decodeSortIdx(body, &pos);
        // externdesc? ::= 0x00 (none) | 0x01 externdesc
        if (pos >= body.len) return Error.Truncated;
        const has_desc = body[pos];
        pos += 1;
        const desc: ?ExternDesc = switch (has_desc) {
            0x00 => null,
            0x01 => try decodeExternDesc(body, &pos),
            else => return Error.InvalidExternDesc,
        };
        try out.append(arena, .{ .name = name, .sort = si.sort, .index = si.index, .desc = desc });
    }
    if (pos != body.len) return Error.TrailingBytes;
}

/// Decode the type index space + imports/exports of an already-walked
/// component (`decode.decode`). The returned `TypeInfo` owns its allocations
/// (`deinit`) but borrows `name` slices from the component input.
pub fn decodeTypeInfo(parent: Allocator, component: *const decode.Component) Error!TypeInfo {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const a = arena.allocator();

    var deftypes: std.ArrayList(DefType) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var exports: std.ArrayList(Export) = .empty;

    for (component.sections.items) |sec| {
        switch (sec.id) {
            .type => try decodeTypeSection(a, &deftypes, sec.body),
            .import => try decodeImportSection(a, &imports, sec.body),
            .@"export" => try decodeExportSection(a, &exports, sec.body),
            else => {}, // other sections decoded in later chunks
        }
    }

    return .{ .arena = arena, .deftypes = deftypes, .imports = imports, .exports = exports };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

/// Build a component binary from a slice of (section-id, body) pairs.
fn buildComponent(comptime sections: []const struct { u8, []const u8 }) []const u8 {
    comptime {
        var out: []const u8 = &[_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00 };
        for (sections) |s| {
            out = out ++ [_]u8{ s[0], @intCast(s[1].len) } ++ s[1];
        }
        return out;
    }
}

fn decodeBoth(bytes: []const u8) !TypeInfo {
    var comp = try decode.decode(testing.allocator, bytes);
    defer comp.deinit(testing.allocator);
    return decodeTypeInfo(testing.allocator, &comp);
}

test "type section: a single primitive deftype" {
    // type section: count=1, deftype = primvaltype string (0x73)
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x73 } }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 1), info.deftypes.items.len);
    try testing.expectEqual(PrimValType.string, info.deftypes.items[0].value.primitive);
}

test "type section: functype (string) -> (string)" {
    // functype 0x40, 1 param "x":string(0x73), resultlist 0x00 string(0x73)
    const body = [_]u8{
        0x01, // count = 1 deftype
        0x40, // functype
        0x01, // 1 param
        0x01, 0x78, // label' "x"
        0x73, // valtype string
        0x00, 0x73, // resultlist: one result, string
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();

    const ft = info.deftypes.items[0].func;
    try testing.expectEqual(@as(usize, 1), ft.params.len);
    try testing.expectEqualStrings("x", ft.params[0].name);
    try testing.expectEqual(PrimValType.string, ft.params[0].ty.primitive);
    try testing.expectEqual(PrimValType.string, ft.result.?.primitive);
    try testing.expect(!ft.is_async);
}

test "functype with no results (0x01 0x00) + a typeidx param" {
    const body = [_]u8{
        0x01, 0x40, // count, functype
        0x01, 0x01, 0x61, 0x00, // 1 param "a" : valtype typeidx 0
        0x01, 0x00, // resultlist: no results
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const ft = info.deftypes.items[0].func;
    try testing.expectEqual(@as(u32, 0), ft.params[0].ty.type_index);
    try testing.expectEqual(@as(?ValType, null), ft.result);
}

test "round-trip: an imported AND exported func type resolves via the index space" {
    // type[0] = (func (param "s" string) (result string))
    const type_body = [_]u8{ 0x01, 0x40, 0x01, 0x01, 0x73, 0x73, 0x00, 0x73 };
    // import "host:greet" (func (type 0))   — externdesc 0x01 typeidx 0
    const import_body = [_]u8{ 0x01, 0x00, 0x0a, 'h', 'o', 's', 't', ':', 'g', 'r', 'e', 'e', 't', 0x01, 0x00 };
    // export "greet" sortidx(func=0x01, idx 0) externdesc? = 0x01 (func type 0)
    const export_body = [_]u8{ 0x01, 0x00, 0x05, 'g', 'r', 'e', 'e', 't', 0x01, 0x00, 0x01, 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{
        .{ 7, &type_body },
        .{ 10, &import_body },
        .{ 11, &export_body },
    });
    var info = try decodeBoth(bytes);
    defer info.deinit();

    try testing.expectEqual(@as(usize, 1), info.imports.items.len);
    try testing.expectEqualStrings("host:greet", info.imports.items[0].name);
    try testing.expectEqual(@as(u32, 0), info.imports.items[0].desc.func);

    try testing.expectEqual(@as(usize, 1), info.exports.items.len);
    try testing.expectEqualStrings("greet", info.exports.items[0].name);
    try testing.expectEqual(Sort.func, info.exports.items[0].sort);
    try testing.expectEqual(@as(u32, 0), info.exports.items[0].desc.?.func);

    // both the import and export resolve to the same func deftype.
    const dt = info.deftype(info.imports.items[0].desc.func).?;
    try testing.expectEqual(PrimValType.string, dt.func.params[0].ty.primitive);
}

test "export with no externdesc (optional absent)" {
    // export "x" sortidx(func 0x01, idx 2), externdesc? = 0x00
    const export_body = [_]u8{ 0x01, 0x00, 0x01, 'x', 0x01, 0x02, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 11, &export_body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 2), info.exports.items[0].index);
    try testing.expectEqual(@as(?ExternDesc, null), info.exports.items[0].desc);
}

test "import name 0x02 prefix carries a dropped version suffix" {
    // import 0x02 "p:i" version "1.0" (func type 0)
    const import_body = [_]u8{ 0x01, 0x02, 0x03, 'p', ':', 'i', 0x03, '1', '.', '0', 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 10, &import_body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqualStrings("p:i", info.imports.items[0].name);
}

test "core-module externdesc (0x00 0x11)" {
    // import "m" (core module (type 3)) : 0x00 0x11 idx 3
    const import_body = [_]u8{ 0x01, 0x00, 0x01, 'm', 0x00, 0x11, 0x03 };
    const bytes = comptime buildComponent(&.{.{ 10, &import_body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 3), info.imports.items[0].desc.core_module);
}

test "compound defvaltype defers with UnsupportedTypeForm (record 0x72)" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x72 } }});
    try testing.expectError(Error.UnsupportedTypeForm, decodeBoth(bytes));
}

test "enum decode: 0x6d label vec" {
    // enum { "red", "green" }: 0x6d count=2, "red" "green"
    const body = [_]u8{ 0x01, 0x6d, 0x02, 0x03, 'r', 'e', 'd', 0x05, 'g', 'r', 'e', 'e', 'n' };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const e = info.deftypes.items[0].enum_;
    try testing.expectEqual(@as(usize, 2), e.labels.len);
    try testing.expectEqualStrings("red", e.labels[0]);
    try testing.expectEqualStrings("green", e.labels[1]);
}

test "flags decode: 0x6e label vec" {
    // flags { "a", "b", "c" }: 0x6e count=3
    const body = [_]u8{ 0x01, 0x6e, 0x03, 0x01, 'a', 0x01, 'b', 0x01, 'c' };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 3), info.deftypes.items[0].flags.labels.len);
}

test "enum with zero labels is rejected" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6d, 0x00 } }});
    try testing.expectError(Error.EmptyEnum, decodeBoth(bytes));
}

test "componenttype defers with UnsupportedTypeForm (0x41)" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x41 } }});
    try testing.expectError(Error.UnsupportedTypeForm, decodeBoth(bytes));
}

test "deftype cannot be a bare typeidx" {
    // count=1, then SLEB 0x00 = 0 (non-negative) → InvalidDefType
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x00 } }});
    try testing.expectError(Error.InvalidDefType, decodeBoth(bytes));
}

test "type section with trailing bytes is rejected" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x73, 0xff } }});
    try testing.expectError(Error.TrailingBytes, decodeBoth(bytes));
}
