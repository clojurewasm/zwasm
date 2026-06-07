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

/// `record` defvaltype (`Binary.md` 0x72): named, ordered fields.
pub const RecordType = struct {
    fields: []const NamedVal,
};

/// `list<T>` defvaltype (`Binary.md` 0x70 variable / 0x67 fixed-length).
pub const ListType = struct {
    element: *const ValType,
    /// Fixed length (`0x67`), or null for a variable-length list (`0x70`).
    fixed_length: ?u32,
};

/// `tuple` defvaltype (`Binary.md` 0x6f): positional, unnamed element types.
pub const TupleType = struct {
    types: []const ValType,
};

/// One `variant` case (`Binary.md` `case`): a label + optional payload type.
pub const Case = struct {
    name: []const u8,
    payload: ?ValType,
};

/// `variant` defvaltype (`Binary.md` 0x71): a tagged union of cases.
pub const VariantType = struct {
    cases: []const Case,
};

/// `option<T>` defvaltype (`Binary.md` 0x6b) — sugar for `variant{none, some(T)}`.
pub const OptionType = struct {
    payload: *const ValType,
};

/// `result<T, E>` defvaltype (`Binary.md` 0x6a) — sugar for
/// `variant{ok(T?), err(E?)}`; both payloads optional.
pub const ResultType = struct {
    ok: ?ValType,
    err: ?ValType,
};

/// One `deftype` in the type index space. A2 modelled primitives + `functype`;
/// B2 `enum`/`flags`; B5 the remaining compound value types. own/borrow +
/// stream/future (resources / async) land in the C-chunks.
pub const DefType = union(enum) {
    value: ValType,
    func: FuncType,
    enum_: EnumType,
    flags: FlagsType,
    record: RecordType,
    list: ListType,
    tuple: TupleType,
    variant: VariantType,
    option: OptionType,
    result: ResultType,
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
/// `string-encoding` canonopt (`Binary.md` `canonopt`).
pub const StringEncoding = enum { utf8, utf16, latin1_utf16 };

/// Decoded `opts` (`Binary.md` `canonopt` vec): the canonical-ABI options for a
/// lift/lower. async/callback are deferred (async phase).
pub const CanonOpts = struct {
    string_encoding: StringEncoding = .utf8,
    memory: ?u32 = null, // core:memidx
    realloc: ?u32 = null, // core:funcidx
    post_return: ?u32 = null, // core:funcidx
};

/// One `canon` section definition (`Binary.md` `canon`). B6 models lift/lower +
/// the resource builtins; the async/stream/future/thread builtins defer.
pub const Canon = union(enum) {
    /// `canon lift` (0x00 0x00): a core func exposed as a component func of
    /// `type_index`, with `opts`.
    lift: struct { core_func: u32, opts: CanonOpts, type_index: u32 },
    /// `canon lower` (0x01 0x00): a component func lowered to a core func.
    lower: struct { func: u32, opts: CanonOpts },
    resource_new: u32, // 0x02 typeidx
    resource_drop: u32, // 0x03 typeidx
    resource_rep: u32, // 0x04 typeidx
};

pub const TypeInfo = struct {
    arena: std.heap.ArenaAllocator,
    deftypes: std.ArrayList(DefType),
    imports: std.ArrayList(Import),
    exports: std.ArrayList(Export),
    canons: std.ArrayList(Canon),

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
    /// A malformed `canon` definition / `canonopt`.
    InvalidCanon,
    /// A `canon` builtin not yet decoded (async / stream / future / thread).
    UnsupportedCanon,
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

/// Store a `ValType` on the arena and return a stable pointer (for the
/// recursive list/option element types).
fn allocValType(arena: Allocator, ty: ValType) Error!*const ValType {
    const p = try arena.create(ValType);
    p.* = ty;
    return p;
}

/// `vec(labelvaltype)` — record fields (named, typed).
fn decodeNamedValVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const NamedVal {
    const count = try leb128.readUleb128(u32, body, pos);
    var out: std.ArrayList(NamedVal) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeLabel(body, pos);
        try out.append(arena, .{ .name = name, .ty = try decodeValType(body, pos) });
    }
    return out.toOwnedSlice(arena);
}

/// `vec(valtype)` — tuple element types.
fn decodeValTypeVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const ValType {
    const count = try leb128.readUleb128(u32, body, pos);
    var out: std.ArrayList(ValType) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) try out.append(arena, try decodeValType(body, pos));
    return out.toOwnedSlice(arena);
}

/// `<T>? ::= 0x00 | 0x01 T` — an optional valtype.
fn decodeOptionalValType(body: []const u8, pos: *usize) Error!?ValType {
    if (pos.* >= body.len) return Error.Truncated;
    const tag = body[pos.*];
    pos.* += 1;
    return switch (tag) {
        0x00 => null,
        0x01 => try decodeValType(body, pos),
        else => Error.InvalidDefType,
    };
}

/// `vec(case)` — `case ::= label' valtype? 0x00` (the trailing `0x00` is the
/// retired `refines` field, required to be zero in the current spec).
fn decodeCaseVec(arena: Allocator, body: []const u8, pos: *usize) Error![]const Case {
    const count = try leb128.readUleb128(u32, body, pos);
    var out: std.ArrayList(Case) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try decodeLabel(body, pos);
        const payload = try decodeOptionalValType(body, pos);
        if (pos.* >= body.len or body[pos.*] != 0x00) return Error.InvalidDefType;
        pos.* += 1;
        try out.append(arena, .{ .name = name, .payload = payload });
    }
    return out.toOwnedSlice(arena);
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
        0x72 => blk: { // record: vec(labelvaltype), >0 fields
            const fields = try decodeNamedValVec(arena, body, pos);
            if (fields.len == 0) break :blk Error.InvalidDefType;
            break :blk .{ .record = .{ .fields = fields } };
        },
        0x71 => blk: { // variant: vec(case), >0 cases
            const cases = try decodeCaseVec(arena, body, pos);
            if (cases.len == 0) break :blk Error.InvalidDefType;
            break :blk .{ .variant = .{ .cases = cases } };
        },
        0x70 => .{ .list = .{ .element = try allocValType(arena, try decodeValType(body, pos)), .fixed_length = null } },
        0x67 => blk: { // fixed-length list: valtype len:u32
            const elem = try allocValType(arena, try decodeValType(body, pos));
            break :blk .{ .list = .{ .element = elem, .fixed_length = try leb128.readUleb128(u32, body, pos) } };
        },
        0x6f => blk: { // tuple: vec(valtype), >0
            const tys = try decodeValTypeVec(arena, body, pos);
            if (tys.len == 0) break :blk Error.InvalidDefType;
            break :blk .{ .tuple = .{ .types = tys } };
        },
        0x6b => .{ .option = .{ .payload = try allocValType(arena, try decodeValType(body, pos)) } },
        0x6a => blk: { // result: ok? err?
            const ok = try decodeOptionalValType(body, pos);
            break :blk .{ .result = .{ .ok = ok, .err = try decodeOptionalValType(body, pos) } };
        },
        // TODO(p17/CM-C*): own 0x69 / borrow 0x68 (resources) / stream 0x66 /
        // future 0x65 (async) — decoded with their runtime machinery.
        0x69, 0x68, 0x66, 0x65 => Error.UnsupportedTypeForm,
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

/// `opts ::= vec(canonopt)` (`Binary.md`). Decodes the canonical-ABI options;
/// async (0x06) / callback (0x07) defer to the async phase.
fn decodeCanonOpts(body: []const u8, pos: *usize) Error!CanonOpts {
    var opts: CanonOpts = .{};
    const count = try leb128.readUleb128(u32, body, pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos.* >= body.len) return Error.Truncated;
        const tag = body[pos.*];
        pos.* += 1;
        switch (tag) {
            0x00 => opts.string_encoding = .utf8,
            0x01 => opts.string_encoding = .utf16,
            0x02 => opts.string_encoding = .latin1_utf16,
            0x03 => opts.memory = try leb128.readUleb128(u32, body, pos),
            0x04 => opts.realloc = try leb128.readUleb128(u32, body, pos),
            0x05 => opts.post_return = try leb128.readUleb128(u32, body, pos),
            0x06, 0x07 => return Error.UnsupportedCanon, // async / callback
            else => return Error.InvalidCanon,
        }
    }
    return opts;
}

fn decodeCanonSection(arena: Allocator, out: *std.ArrayList(Canon), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos >= body.len) return Error.Truncated;
        const op = body[pos];
        pos += 1;
        const canon: Canon = switch (op) {
            0x00 => blk: { // canon lift: 0x00 funcidx opts typeidx
                if (pos >= body.len or body[pos] != 0x00) return Error.InvalidCanon;
                pos += 1;
                const core_func = try leb128.readUleb128(u32, body, &pos);
                const opts = try decodeCanonOpts(body, &pos);
                break :blk .{ .lift = .{ .core_func = core_func, .opts = opts, .type_index = try leb128.readUleb128(u32, body, &pos) } };
            },
            0x01 => blk: { // canon lower: 0x01 funcidx opts
                if (pos >= body.len or body[pos] != 0x00) return Error.InvalidCanon;
                pos += 1;
                const func = try leb128.readUleb128(u32, body, &pos);
                break :blk .{ .lower = .{ .func = func, .opts = try decodeCanonOpts(body, &pos) } };
            },
            0x02 => .{ .resource_new = try leb128.readUleb128(u32, body, &pos) },
            0x03 => .{ .resource_drop = try leb128.readUleb128(u32, body, &pos) },
            0x04 => .{ .resource_rep = try leb128.readUleb128(u32, body, &pos) },
            // async / stream / future / thread builtins (0x05..0x26) defer.
            else => return Error.UnsupportedCanon,
        };
        try out.append(arena, canon);
    }
    if (pos != body.len) return Error.TrailingBytes;
}

/// Decode the type index space + imports/exports + canon defs of an
/// already-walked component (`decode.decode`). The returned `TypeInfo` owns its
/// allocations (`deinit`) but borrows `name` slices from the component input.
pub fn decodeTypeInfo(parent: Allocator, component: *const decode.Component) Error!TypeInfo {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const a = arena.allocator();

    var deftypes: std.ArrayList(DefType) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var exports: std.ArrayList(Export) = .empty;
    var canons: std.ArrayList(Canon) = .empty;

    for (component.sections.items) |sec| {
        switch (sec.id) {
            .type => try decodeTypeSection(a, &deftypes, sec.body),
            .import => try decodeImportSection(a, &imports, sec.body),
            .@"export" => try decodeExportSection(a, &exports, sec.body),
            .canon => try decodeCanonSection(a, &canons, sec.body),
            else => {}, // other sections decoded in later chunks
        }
    }

    return .{ .arena = arena, .deftypes = deftypes, .imports = imports, .exports = exports, .canons = canons };
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

test "record decode: 0x72 named fields" {
    // record { x: u32, y: string }: 0x72 count=2, "x" u32(0x79), "y" string(0x73)
    const body = [_]u8{ 0x01, 0x72, 0x02, 0x01, 'x', 0x79, 0x01, 'y', 0x73 };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const r = info.deftypes.items[0].record;
    try testing.expectEqual(@as(usize, 2), r.fields.len);
    try testing.expectEqualStrings("x", r.fields[0].name);
    try testing.expectEqual(PrimValType.u32, r.fields[0].ty.primitive);
    try testing.expectEqual(PrimValType.string, r.fields[1].ty.primitive);
}

test "list decode: variable (0x70) and fixed (0x67)" {
    // type[0] = list<u8>, type[1] = list<u8, 4>
    const body = [_]u8{ 0x02, 0x70, 0x7d, 0x67, 0x7d, 0x04 };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(?u32, null), info.deftypes.items[0].list.fixed_length);
    try testing.expectEqual(PrimValType.u8, info.deftypes.items[0].list.element.primitive);
    try testing.expectEqual(@as(?u32, 4), info.deftypes.items[1].list.fixed_length);
}

test "variant/option/result decode" {
    // variant { "a", "b"(u32) } : 0x71 count=2; "a" none 0x00; "b" some(u32) 0x00
    const variant_body = [_]u8{ 0x01, 0x71, 0x02, 0x01, 'a', 0x00, 0x00, 0x01, 'b', 0x01, 0x79, 0x00 };
    var v = try decodeBoth(comptime buildComponent(&.{.{ 7, &variant_body }}));
    defer v.deinit();
    const variant = v.deftypes.items[0].variant;
    try testing.expectEqual(@as(usize, 2), variant.cases.len);
    try testing.expectEqual(@as(?ValType, null), variant.cases[0].payload);
    try testing.expectEqual(PrimValType.u32, variant.cases[1].payload.?.primitive);

    // option<string>: 0x6b string
    var o = try decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6b, 0x73 } }}));
    defer o.deinit();
    try testing.expectEqual(PrimValType.string, o.deftypes.items[0].option.payload.primitive);

    // result<u32, string>: 0x6a 0x01 u32 0x01 string
    var r = try decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6a, 0x01, 0x79, 0x01, 0x73 } }}));
    defer r.deinit();
    try testing.expectEqual(PrimValType.u32, r.deftypes.items[0].result.ok.?.primitive);
    try testing.expectEqual(PrimValType.string, r.deftypes.items[0].result.err.?.primitive);
}

test "tuple decode + empty record rejected" {
    // tuple<u32, f64>: 0x6f count=2
    var t = try decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x6f, 0x02, 0x79, 0x75 } }}));
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.deftypes.items[0].tuple.types.len);

    // empty record (count 0) is malformed.
    try testing.expectError(Error.InvalidDefType, decodeBoth(comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x72, 0x00 } }})));
}

test "own/borrow still defer with UnsupportedTypeForm (0x69)" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x69, 0x00 } }});
    try testing.expectError(Error.UnsupportedTypeForm, decodeBoth(bytes));
}

test "canon section: canon lift with opts (utf8 + memory 0 + realloc 1)" {
    // count=1; lift 0x00 0x00 funcidx=0 opts{utf8, memory 0, realloc 1} typeidx=0
    const body = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x03, 0x00, 0x03, 0x00, 0x04, 0x01, 0x00 };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 1), info.canons.items.len);
    const lift = info.canons.items[0].lift;
    try testing.expectEqual(@as(u32, 0), lift.core_func);
    try testing.expectEqual(@as(u32, 0), lift.type_index);
    try testing.expectEqual(StringEncoding.utf8, lift.opts.string_encoding);
    try testing.expectEqual(@as(?u32, 0), lift.opts.memory);
    try testing.expectEqual(@as(?u32, 1), lift.opts.realloc);
    try testing.expectEqual(@as(?u32, null), lift.opts.post_return);
}

test "canon section: canon lower + empty opts + utf16/post-return" {
    // lower 0x01 0x00 func=2 opts{} ; then a second lower with utf16 + post-return 3
    const body = [_]u8{
        0x02,
        0x01, 0x00, 0x02, 0x00, // lower func 2, no opts
        0x01, 0x00, 0x07, 0x02, 0x01, 0x05, 0x03, // lower func 7, opts{utf16, post-return 3}
    };
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 2), info.canons.items[0].lower.func);
    try testing.expectEqual(StringEncoding.utf8, info.canons.items[0].lower.opts.string_encoding);
    try testing.expectEqual(StringEncoding.utf16, info.canons.items[1].lower.opts.string_encoding);
    try testing.expectEqual(@as(?u32, 3), info.canons.items[1].lower.opts.post_return);
}

test "canon section: resource builtins decode" {
    const body = [_]u8{ 0x01, 0x02, 0x05 }; // resource.new typeidx 5
    const bytes = comptime buildComponent(&.{.{ 8, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 5), info.canons.items[0].resource_new);
}

test "canon: async opt + async builtin defer UnsupportedCanon" {
    // lift with opts{async 0x06}
    const async_opt = [_]u8{ 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x00 };
    try testing.expectError(Error.UnsupportedCanon, decodeBoth(comptime buildComponent(&.{.{ 8, &async_opt }})));
    // a stream/future builtin opcode (0x0e)
    const builtin = [_]u8{ 0x01, 0x0e, 0x00 };
    try testing.expectError(Error.UnsupportedCanon, decodeBoth(comptime buildComponent(&.{.{ 8, &builtin }})));
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
