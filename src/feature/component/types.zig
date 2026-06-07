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
    /// `own<i>` (0x69) — an owning handle to resource type `i`.
    own: u32,
    /// `borrow<i>` (0x68) — a borrowed handle to resource type `i`.
    borrow: u32,
    /// `instancetype` (0x42) — a component instance type (a WASI interface
    /// type is one of these).
    instance_type: InstanceType,
    /// `componenttype` (0x41) — a component type.
    component_type: ComponentType,
};

/// One `instancedecl` (`Binary.md`): a declaration inside an `instancetype`.
pub const InstanceDecl = union(enum) {
    /// 0x01 — a nested component `type` definition.
    type_def: *const DefType,
    /// 0x02 — an alias.
    alias: Alias,
    /// 0x04 — `exportdecl ::= exportname' externdesc`.
    export_decl: ImportExportDecl,
};

pub const ImportExportDecl = struct {
    name: []const u8,
    desc: ExternDesc,
};

pub const InstanceType = struct {
    decls: []const InstanceDecl,
};

/// One `componentdecl` (`Binary.md`): `0x03 importdecl` or an `instancedecl`.
pub const ComponentDecl = union(enum) {
    import_decl: ImportExportDecl,
    instance_decl: InstanceDecl,
};

pub const ComponentType = struct {
    decls: []const ComponentDecl,
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

/// `typebound` (`Binary.md`) — a `(type ...)` import/export bound.
pub const TypeBound = union(enum) {
    /// `(eq i)` — equal to type `i`.
    eq: u32,
    /// `(sub resource)` — a fresh abstract resource type.
    sub_resource,
};

/// `externdesc` (`Binary.md`) — what an import/export refers to.
pub const ExternDesc = union(enum) {
    core_module: u32,
    func: u32,
    component: u32,
    instance: u32,
    /// `(type b)` — a type import/export with bound `b`.
    type_bound: TypeBound,
    /// `(value b)` — a value import/export. B carries an `eq valueidx` or an
    /// inline `valtype`; modelled minimally (the valtype/idx) for now.
    value_bound: ?ValType,
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

/// `core:instantiatearg ::= name 0x12 instanceidx` — a `with` argument
/// supplying an imported instance to a core instantiation.
pub const CoreInstantiateArg = struct {
    name: []const u8,
    instance: u32,
};

/// `core:inlineexport ::= name core:sortidx`.
pub const CoreInlineExport = struct {
    name: []const u8,
    sort: CoreSort,
    index: u32,
};

/// One `core:instance` (`Binary.md` §Instance): instantiate a core module, or
/// a synthetic instance of inline exports.
pub const CoreInstance = union(enum) {
    instantiate: struct { module: u32, args: []const CoreInstantiateArg },
    inline_exports: []const CoreInlineExport,
};

/// One entry in the component's **core-func index space** (`Binary.md`: core
/// funcs are minted, in definition order, by `canon lower` / `canon
/// resource.{new,drop,rep}` and by core-func `alias`es — NOT by `canon lift`,
/// which mints a component func). Recording them in a single ordered list is
/// what lets the host map a core-func index to its true definition (a prior
/// alias-only count mis-indexed any component mixing lowers + aliases).
pub const CoreFuncDef = union(enum) {
    /// `canon lower` of component func `func` — host-implemented (the host
    /// satisfies the lowered import, e.g. a WASI-P2 trampoline).
    lower: u32,
    resource_new: u32,
    resource_drop: u32,
    resource_rep: u32,
    /// A core-func `alias` (a core-instance export, or an `outer` alias).
    alias: AliasTarget,
};

/// `aliastarget` (`Binary.md` §Alias): the source an alias pulls a definition
/// from.
pub const AliasTarget = union(enum) {
    /// 0x00 — an export of a (component) instance.
    component_export: struct { instance: u32, name: []const u8 },
    /// 0x01 — an export of a CORE instance (what canon-lift core funcs use).
    core_export: struct { instance: u32, name: []const u8 },
    /// 0x02 — an `outer` alias `ct` levels up at index `idx`.
    outer: struct { count: u32, index: u32 },
};

/// One entry in the component **func** index space (`Binary.md`: component
/// funcs are minted, in definition order, by func `import`s, func `alias`es, and
/// `canon lift`s — NOT by `canon lower`, which mints a CORE func). Recorded in
/// section order so a `canon lower`'s `func` operand resolves to its origin (the
/// host needs the imported interface a lowered WASI import came from).
pub const ComponentFuncDef = union(enum) {
    /// A func `import` (index into `imports`).
    import: u32,
    /// A func `alias` (an instance export, or an `outer` alias).
    alias: AliasTarget,
    /// A `canon lift` (index into `canons`).
    lift: u32,
};

/// Where a component-instance index originates: an `import` (whose name is the
/// WASI interface, e.g. `"wasi:cli/stdout@0.2.0"`) or any local definition
/// (instantiate / alias). The host classifies only imported interfaces.
pub const InstanceOrigin = union(enum) {
    import: []const u8,
    local,
};

/// `alias ::= sort aliastarget` — introduces a new index in `sort`'s space.
pub const Alias = struct {
    sort: Sort,
    target: AliasTarget,
};

/// `instantiatearg ::= name sortidx` — a `with` arg satisfying a child
/// component's import with a definition from this component's index spaces.
pub const ComponentInstantiateArg = struct {
    name: []const u8,
    sort: Sort,
    index: u32,
};

/// `inlineexport ::= exportname' sortidx`.
pub const ComponentInlineExport = struct {
    name: []const u8,
    sort: Sort,
    index: u32,
};

/// One `instance` (`Binary.md` §Instance, component level): instantiate a child
/// component with `with` args, or a synthetic instance of inline exports.
pub const ComponentInstanceDef = union(enum) {
    instantiate: struct { component: u32, args: []const ComponentInstantiateArg },
    inline_exports: []const ComponentInlineExport,
};

pub const TypeInfo = struct {
    arena: std.heap.ArenaAllocator,
    deftypes: std.ArrayList(DefType),
    /// The TRUE size of the component **type index space** — minted (in
    /// definition order) by `type`-section defs PLUS type-sort `alias`es, type
    /// `import`s, and type `export`s. `deftypes.len` alone counts only the type
    /// section, so a valid index pointing at an aliased/imported type would look
    /// out-of-bounds; validation (ADR-0176) bounds-checks against THIS instead.
    type_space_len: u32,
    imports: std.ArrayList(Import),
    exports: std.ArrayList(Export),
    canons: std.ArrayList(Canon),
    core_instances: std.ArrayList(CoreInstance),
    component_instances: std.ArrayList(ComponentInstanceDef),
    aliases: std.ArrayList(Alias),
    /// The core-func index space in definition order (`CoreFuncDef`) — the
    /// authoritative map for resolving a core-func index to its definition.
    core_funcs: std.ArrayList(CoreFuncDef),
    /// The core-**table** index space in definition order. Core tables enter the
    /// component-level index space only via `alias core export` (a core table is
    /// never minted by canon), so each entry is the alias target. Needed by the
    /// general instantiation engine (E2) to resolve a synthetic instance's table
    /// re-export — e.g. wit-bindgen's `$fixup-args` re-exporting the shim's
    /// `$imports` table (ADR-0175).
    core_tables: std.ArrayList(AliasTarget),
    /// The component-func index space in definition order (`ComponentFuncDef`) —
    /// lets a `canon lower`'s `func` operand resolve to its origin interface.
    component_funcs: std.ArrayList(ComponentFuncDef),
    /// The component-instance index space, recording each index's origin so an
    /// imported-instance alias resolves to its WASI interface name.
    instance_origins: std.ArrayList(InstanceOrigin),

    pub fn deinit(self: *TypeInfo) void {
        self.arena.deinit();
    }

    /// Resolve a `typeidx` against the decoded type index space.
    pub fn deftype(self: *const TypeInfo, index: u32) ?DefType {
        if (index >= self.deftypes.items.len) return null;
        return self.deftypes.items[index];
    }

    /// A resolved core-func index-space entry pointing at a core-instance
    /// export (the form `canon lift`/`canon lower` reference).
    pub const CoreExportRef = struct {
        instance: u32,
        name: []const u8,
    };

    /// Resolve a core-func index → its definition (`CoreFuncDef`) in the
    /// component's core-func index space, or null if out of range.
    pub fn coreFunc(self: *const TypeInfo, core_func_idx: u32) ?CoreFuncDef {
        if (core_func_idx >= self.core_funcs.items.len) return null;
        return self.core_funcs.items[core_func_idx];
    }

    /// Resolve a core-func index → the core-instance export it aliases. Returns
    /// null if out of range or the entry is not a direct core-export alias
    /// (e.g. a `canon lower`/resource builtin, or an `outer` alias — those are
    /// resolved via `coreFunc`). Indexes the full core-func space (lowers +
    /// resource builtins + aliases interleaved), not aliases alone.
    pub fn resolveCoreFuncExport(self: *const TypeInfo, core_func_idx: u32) ?CoreExportRef {
        const def = self.coreFunc(core_func_idx) orelse return null;
        return switch (def) {
            .alias => |t| switch (t) {
                .core_export => |ce| .{ .instance = ce.instance, .name = ce.name },
                else => null,
            },
            else => null,
        };
    }

    /// Resolve a core-**table** index → the core-instance export it aliases
    /// (`{instance, name}`), or null if out of range / not a core-export alias.
    /// The general instantiation engine uses this to find which built instance
    /// owns a table a synthetic instance re-exports (the shim `$imports` table).
    pub fn resolveCoreTableExport(self: *const TypeInfo, core_table_idx: u32) ?CoreExportRef {
        if (core_table_idx >= self.core_tables.items.len) return null;
        return switch (self.core_tables.items[core_table_idx]) {
            .core_export => |ce| .{ .instance = ce.instance, .name = ce.name },
            else => null,
        };
    }

    /// An imported WASI interface + func name a lowered component func came from.
    pub const ImportRef = struct { interface: []const u8, func: []const u8 };

    /// Resolve a component **func** index (a `canon lower`'s `func` operand) back
    /// to the imported interface + func name it aliases — so the host classifies
    /// a lowered WASI import by its COMPONENT interface (`wasi/adapter`) instead
    /// of the core module's hand-chosen import names. The `@version` suffix is
    /// stripped to match the adapter's interface table. Returns null when the
    /// func is not a func-alias of an imported instance (a direct func import, a
    /// `canon lift`, or an alias of a locally-defined instance).
    pub fn resolveComponentImport(self: *const TypeInfo, component_func_idx: u32) ?ImportRef {
        if (component_func_idx >= self.component_funcs.items.len) return null;
        const ce = switch (self.component_funcs.items[component_func_idx]) {
            .alias => |t| switch (t) {
                .component_export => |c| c,
                else => return null,
            },
            else => return null,
        };
        if (ce.instance >= self.instance_origins.items.len) return null;
        const full = switch (self.instance_origins.items[ce.instance]) {
            .import => |name| name,
            .local => return null,
        };
        const interface = if (std.mem.findScalar(u8, full, '@')) |at| full[0..at] else full;
        return .{ .interface = interface, .func = ce.name };
    }

    /// A component `func` export resolved to the core exports the host must
    /// invoke: the lowered core func + the canon options' realloc / post-return
    /// core funcs.
    pub const ResolvedLift = struct {
        core_func: CoreExportRef,
        realloc: ?CoreExportRef,
        post_return: ?CoreExportRef,
        string_encoding: StringEncoding,
    };

    /// Resolve a component `func` export (by name) to its `canon lift` and the
    /// underlying core exports — so the host invokes the resolved core funcs
    /// instead of guessing names. Assumes the func index space is populated by
    /// `canon lift`s in order (true for a single-component leaf; func imports /
    /// aliases occupy earlier slots and are handled when a component uses them).
    pub fn resolveLiftedFunc(self: *const TypeInfo, export_name: []const u8) ?ResolvedLift {
        var func_idx: ?u32 = null;
        for (self.exports.items) |e| {
            if (e.sort == .func and std.mem.eql(u8, e.name, export_name)) {
                func_idx = e.index;
                break;
            }
        }
        const fi = func_idx orelse return null;

        var li: u32 = 0;
        for (self.canons.items) |c| {
            if (c != .lift) continue;
            if (li == fi) {
                const lift = c.lift;
                return .{
                    .core_func = self.resolveCoreFuncExport(lift.core_func) orelse return null,
                    .realloc = if (lift.opts.realloc) |r| self.resolveCoreFuncExport(r) else null,
                    .post_return = if (lift.opts.post_return) |p| self.resolveCoreFuncExport(p) else null,
                    .string_encoding = lift.opts.string_encoding,
                };
            }
            li += 1;
        }
        return null;
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
    /// A malformed `core:instance` / `alias` definition.
    InvalidInstance,
    InvalidAlias,
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
        0x69 => .{ .own = try leb128.readUleb128(u32, body, pos) },
        0x68 => .{ .borrow = try leb128.readUleb128(u32, body, pos) },
        // TODO(p17/CM): stream 0x66 / future 0x65 (async) — decoded with their
        // runtime machinery.
        0x66, 0x65 => Error.UnsupportedTypeForm,
        0x41 => .{ .component_type = try decodeComponentType(arena, body, pos) },
        0x42 => .{ .instance_type = try decodeInstanceType(arena, body, pos) },
        // TODO(p17/CM): resourcetype definitions (0x3f sync / 0x3e async) — the
        // P2-CLI fixture uses `(sub resource)` type-bounds, not these defs.
        0x3f, 0x3e => Error.UnsupportedTypeForm,
        else => Error.InvalidDefType,
    };
}

/// `alias ::= sort aliastarget` (shared by the alias section + instancedecls).
fn decodeAlias(body: []const u8, pos: *usize) Error!Alias {
    const sort = try decodeSort(body, pos);
    if (pos.* >= body.len) return Error.Truncated;
    const tt = body[pos.*];
    pos.* += 1;
    const target: AliasTarget = switch (tt) {
        0x00 => blk: {
            const inst = try leb128.readUleb128(u32, body, pos);
            break :blk .{ .component_export = .{ .instance = inst, .name = try decodeLabel(body, pos) } };
        },
        0x01 => blk: {
            const inst = try leb128.readUleb128(u32, body, pos);
            break :blk .{ .core_export = .{ .instance = inst, .name = try decodeLabel(body, pos) } };
        },
        0x02 => blk: {
            const ct = try leb128.readUleb128(u32, body, pos);
            break :blk .{ .outer = .{ .count = ct, .index = try leb128.readUleb128(u32, body, pos) } };
        },
        else => return Error.InvalidAlias,
    };
    return .{ .sort = sort, .target = target };
}

/// `instancedecl ::= 0x00 core:type | 0x01 type | 0x02 alias | 0x04 exportdecl`.
fn decodeInstanceDecl(arena: Allocator, body: []const u8, pos: *usize) Error!InstanceDecl {
    if (pos.* >= body.len) return Error.Truncated;
    const tag = body[pos.*];
    pos.* += 1;
    return switch (tag) {
        // core:type inside an instancetype — not used by the P2-CLI WASI types.
        0x00 => Error.UnsupportedTypeForm,
        0x01 => blk: {
            const dt = try arena.create(DefType);
            dt.* = try decodeDefType(arena, body, pos);
            break :blk .{ .type_def = dt };
        },
        0x02 => .{ .alias = try decodeAlias(body, pos) },
        0x04 => blk: {
            const name = try decodeImportExportName(body, pos);
            break :blk .{ .export_decl = .{ .name = name, .desc = try decodeExternDesc(body, pos) } };
        },
        else => Error.InvalidInstance,
    };
}

/// `instancetype ::= 0x42 vec(instancedecl)`.
fn decodeInstanceType(arena: Allocator, body: []const u8, pos: *usize) Error!InstanceType {
    const count = try leb128.readUleb128(u32, body, pos);
    var decls: std.ArrayList(InstanceDecl) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) try decls.append(arena, try decodeInstanceDecl(arena, body, pos));
    return .{ .decls = try decls.toOwnedSlice(arena) };
}

/// `componenttype ::= 0x41 vec(componentdecl)`;
/// `componentdecl ::= 0x03 importdecl | instancedecl`.
fn decodeComponentType(arena: Allocator, body: []const u8, pos: *usize) Error!ComponentType {
    const count = try leb128.readUleb128(u32, body, pos);
    var decls: std.ArrayList(ComponentDecl) = .empty;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos.* >= body.len) return Error.Truncated;
        if (body[pos.*] == 0x03) {
            pos.* += 1;
            const name = try decodeImportExportName(body, pos);
            try decls.append(arena, .{ .import_decl = .{ .name = name, .desc = try decodeExternDesc(body, pos) } });
        } else {
            try decls.append(arena, .{ .instance_decl = try decodeInstanceDecl(arena, body, pos) });
        }
    }
    return .{ .decls = try decls.toOwnedSlice(arena) };
}

/// `sort ::= 0x00 core:sort | 0x01 func | 0x02 value | 0x03 type | 0x04
/// component | 0x05 instance`.
fn decodeSort(body: []const u8, pos: *usize) Error!Sort {
    if (pos.* >= body.len) return Error.Truncated;
    const sort_byte = body[pos.*];
    pos.* += 1;
    return switch (sort_byte) {
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
        else => Error.InvalidSort,
    };
}

fn decodeSortIdx(body: []const u8, pos: *usize) Error!struct { sort: Sort, index: u32 } {
    const sort = try decodeSort(body, pos);
    return .{ .sort = sort, .index = try leb128.readUleb128(u32, body, pos) };
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
        0x02 => { // value bound: 0x00 eq valueidx | 0x01 valtype
            if (pos.* >= body.len) return Error.Truncated;
            const vtag = body[pos.*];
            pos.* += 1;
            return switch (vtag) {
                0x00 => blk: { // eq valueidx
                    _ = try leb128.readUleb128(u32, body, pos);
                    break :blk .{ .value_bound = null };
                },
                0x01 => .{ .value_bound = try decodeValType(body, pos) },
                else => Error.InvalidExternDesc,
            };
        },
        0x03 => { // type bound: 0x00 eq typeidx | 0x01 sub resource
            if (pos.* >= body.len) return Error.Truncated;
            const tb = body[pos.*];
            pos.* += 1;
            return switch (tb) {
                0x00 => .{ .type_bound = .{ .eq = try leb128.readUleb128(u32, body, pos) } },
                0x01 => .{ .type_bound = .sub_resource },
                else => Error.InvalidExternDesc,
            };
        },
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

fn decodeCoreSortIdx(body: []const u8, pos: *usize) Error!struct { sort: CoreSort, index: u32 } {
    if (pos.* >= body.len) return Error.Truncated;
    const cs: CoreSort = @enumFromInt(body[pos.*]);
    pos.* += 1;
    return .{ .sort = cs, .index = try leb128.readUleb128(u32, body, pos) };
}

/// `core:instance` section (id 2) = `vec(core:instance)`.
fn decodeCoreInstanceSection(arena: Allocator, out: *std.ArrayList(CoreInstance), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos >= body.len) return Error.Truncated;
        const tag = body[pos];
        pos += 1;
        switch (tag) {
            0x00 => { // instantiate moduleidx vec(instantiatearg)
                const module = try leb128.readUleb128(u32, body, &pos);
                const argc = try leb128.readUleb128(u32, body, &pos);
                var args: std.ArrayList(CoreInstantiateArg) = .empty;
                var j: u32 = 0;
                while (j < argc) : (j += 1) {
                    const name = try decodeLabel(body, &pos);
                    if (pos >= body.len or body[pos] != 0x12) return Error.InvalidInstance;
                    pos += 1; // 0x12 = instance sort tag
                    try args.append(arena, .{ .name = name, .instance = try leb128.readUleb128(u32, body, &pos) });
                }
                try out.append(arena, .{ .instantiate = .{ .module = module, .args = try args.toOwnedSlice(arena) } });
            },
            0x01 => { // vec(core:inlineexport)
                const ec = try leb128.readUleb128(u32, body, &pos);
                var exps: std.ArrayList(CoreInlineExport) = .empty;
                var j: u32 = 0;
                while (j < ec) : (j += 1) {
                    const name = try decodeLabel(body, &pos);
                    const si = try decodeCoreSortIdx(body, &pos);
                    try exps.append(arena, .{ .name = name, .sort = si.sort, .index = si.index });
                }
                try out.append(arena, .{ .inline_exports = try exps.toOwnedSlice(arena) });
            },
            else => return Error.InvalidInstance,
        }
    }
    if (pos != body.len) return Error.TrailingBytes;
}

/// `instance` section (id 5) = `vec(instance)` (component level).
fn decodeInstanceSection(arena: Allocator, out: *std.ArrayList(ComponentInstanceDef), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos >= body.len) return Error.Truncated;
        const tag = body[pos];
        pos += 1;
        switch (tag) {
            0x00 => { // instantiate componentidx vec(instantiatearg)
                const component = try leb128.readUleb128(u32, body, &pos);
                const argc = try leb128.readUleb128(u32, body, &pos);
                var args: std.ArrayList(ComponentInstantiateArg) = .empty;
                var j: u32 = 0;
                while (j < argc) : (j += 1) {
                    const name = try decodeLabel(body, &pos);
                    const si = try decodeSortIdx(body, &pos);
                    try args.append(arena, .{ .name = name, .sort = si.sort, .index = si.index });
                }
                try out.append(arena, .{ .instantiate = .{ .component = component, .args = try args.toOwnedSlice(arena) } });
            },
            0x01 => { // vec(inlineexport)
                const ec = try leb128.readUleb128(u32, body, &pos);
                var exps: std.ArrayList(ComponentInlineExport) = .empty;
                var j: u32 = 0;
                while (j < ec) : (j += 1) {
                    const name = try decodeImportExportName(body, &pos);
                    const si = try decodeSortIdx(body, &pos);
                    try exps.append(arena, .{ .name = name, .sort = si.sort, .index = si.index });
                }
                try out.append(arena, .{ .inline_exports = try exps.toOwnedSlice(arena) });
            },
            else => return Error.InvalidInstance,
        }
    }
    if (pos != body.len) return Error.TrailingBytes;
}

/// `alias` section (id 6) = `vec(alias)`; `alias ::= sort aliastarget`.
fn decodeAliasSection(arena: Allocator, out: *std.ArrayList(Alias), body: []const u8) Error!void {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    var i: u32 = 0;
    while (i < count) : (i += 1) try out.append(arena, try decodeAlias(body, &pos));
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
    var core_instances: std.ArrayList(CoreInstance) = .empty;
    var component_instances: std.ArrayList(ComponentInstanceDef) = .empty;
    var aliases: std.ArrayList(Alias) = .empty;
    var core_funcs: std.ArrayList(CoreFuncDef) = .empty;
    var core_tables: std.ArrayList(AliasTarget) = .empty;
    var component_funcs: std.ArrayList(ComponentFuncDef) = .empty;
    var instance_origins: std.ArrayList(InstanceOrigin) = .empty;

    for (component.sections.items) |sec| {
        // Track per-kind counts before this section so the newly-decoded entries
        // append to the core-/component-func and instance index spaces in binary
        // (section) order — entries from different sections must interleave by
        // their true definition order (a lower's func operand and an instance
        // alias both index spaces populated across several sections).
        const imports_before = imports.items.len;
        const canons_before = canons.items.len;
        const aliases_before = aliases.items.len;
        const cinst_before = component_instances.items.len;
        switch (sec.id) {
            .type => try decodeTypeSection(a, &deftypes, sec.body),
            .import => try decodeImportSection(a, &imports, sec.body),
            .@"export" => try decodeExportSection(a, &exports, sec.body),
            .canon => try decodeCanonSection(a, &canons, sec.body),
            .core_instance => try decodeCoreInstanceSection(a, &core_instances, sec.body),
            .instance => try decodeInstanceSection(a, &component_instances, sec.body),
            .alias => try decodeAliasSection(a, &aliases, sec.body),
            else => {}, // other sections decoded in later chunks
        }
        switch (sec.id) {
            .import => for (imports.items[imports_before..], imports_before..) |imp, abs| switch (imp.desc) {
                .func => try component_funcs.append(a, .{ .import = @intCast(abs) }),
                .instance => try instance_origins.append(a, .{ .import = imp.name }),
                else => {},
            },
            .canon => for (canons.items[canons_before..], canons_before..) |c, abs| switch (c) {
                .lower => |l| try core_funcs.append(a, .{ .lower = l.func }),
                .resource_new => |t| try core_funcs.append(a, .{ .resource_new = t }),
                .resource_drop => |t| try core_funcs.append(a, .{ .resource_drop = t }),
                .resource_rep => |t| try core_funcs.append(a, .{ .resource_rep = t }),
                .lift => try component_funcs.append(a, .{ .lift = @intCast(abs) }),
            },
            .alias => for (aliases.items[aliases_before..]) |al| switch (al.sort) {
                .core => |cs| switch (cs) {
                    .func => try core_funcs.append(a, .{ .alias = al.target }),
                    .table => try core_tables.append(a, al.target),
                    else => {},
                },
                .func => try component_funcs.append(a, .{ .alias = al.target }),
                .instance => try instance_origins.append(a, .local),
                else => {},
            },
            .instance => for (component_instances.items[cinst_before..]) |_| try instance_origins.append(a, .local),
            else => {},
        }
    }

    // The type-index space = type-section defs + type-sort aliases + type
    // imports + type exports (the four forms that mint a type index).
    var type_space_len: u32 = @intCast(deftypes.items.len);
    for (aliases.items) |al| {
        if (std.meta.activeTag(al.sort) == .type) type_space_len += 1;
    }
    for (imports.items) |imp| {
        if (std.meta.activeTag(imp.desc) == .type_bound) type_space_len += 1;
    }
    for (exports.items) |ex| {
        if (std.meta.activeTag(ex.sort) == .type) type_space_len += 1;
    }

    return .{
        .arena = arena,
        .deftypes = deftypes,
        .type_space_len = type_space_len,
        .imports = imports,
        .exports = exports,
        .canons = canons,
        .core_instances = core_instances,
        .component_instances = component_instances,
        .aliases = aliases,
        .core_funcs = core_funcs,
        .core_tables = core_tables,
        .component_funcs = component_funcs,
        .instance_origins = instance_origins,
    };
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

test "own/borrow decode (0x69 / 0x68)" {
    // type[0] = own<3>, type[1] = borrow<3>
    const body = [_]u8{ 0x02, 0x69, 0x03, 0x68, 0x03 };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(u32, 3), info.deftypes.items[0].own);
    try testing.expectEqual(@as(u32, 3), info.deftypes.items[1].borrow);
}

test "externdesc type-bound (sub resource / eq) on an import" {
    // import "r" (type (sub resource)) : externdesc 0x03 0x01
    const sub = [_]u8{ 0x01, 0x00, 0x01, 'r', 0x03, 0x01 };
    var s = try decodeBoth(comptime buildComponent(&.{.{ 10, &sub }}));
    defer s.deinit();
    try testing.expectEqual(TypeBound.sub_resource, s.imports.items[0].desc.type_bound);

    // import "t" (type (eq 5)) : externdesc 0x03 0x00 5
    const eq = [_]u8{ 0x01, 0x00, 0x01, 't', 0x03, 0x00, 0x05 };
    var e = try decodeBoth(comptime buildComponent(&.{.{ 10, &eq }}));
    defer e.deinit();
    try testing.expectEqual(@as(u32, 5), e.imports.items[0].desc.type_bound.eq);
}

test "stream/future still defer with UnsupportedTypeForm (0x66)" {
    const bytes = comptime buildComponent(&.{.{ 7, &[_]u8{ 0x01, 0x66, 0x00 } }});
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

test "core-instance decode: instantiate + inline exports" {
    const body = [_]u8{
        0x02,
        0x00, 0x00, 0x00, // [0] instantiate module 0, 0 args
        0x01, 0x01, 0x01, 'm', 0x02, 0x00, // [1] inline: export "m" → core mem 0
    };
    const bytes = comptime buildComponent(&.{.{ 2, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 2), info.core_instances.items.len);
    try testing.expectEqual(@as(u32, 0), info.core_instances.items[0].instantiate.module);
    try testing.expectEqualStrings("m", info.core_instances.items[1].inline_exports[0].name);
    try testing.expectEqual(CoreSort.memory, info.core_instances.items[1].inline_exports[0].sort);
}

test "alias decode: core export + outer" {
    const body = [_]u8{
        0x02,
        0x00, 0x00, 0x01, 0x00, 0x05, 'g', 'r', 'e', 'e', 't', // (core func) core export inst 0 "greet"
        0x03, 0x02, 0x02, 0x03, // (type) outer ct 2 idx 3
    };
    const bytes = comptime buildComponent(&.{.{ 6, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 2), info.aliases.items.len);
    try testing.expectEqualStrings("greet", info.aliases.items[0].target.core_export.name);
    try testing.expectEqual(@as(u32, 0), info.aliases.items[0].target.core_export.instance);
    try testing.expectEqual(@as(u32, 2), info.aliases.items[1].target.outer.count);
    try testing.expectEqual(@as(u32, 3), info.aliases.items[1].target.outer.index);
}

test "component-instance decode: instantiate with arg + inline exports" {
    const body = [_]u8{
        0x02,
        0x00, 0x00, 0x01, 0x01, 'a', 0x05, 0x00, // instantiate comp 0, arg "a" → instance 0
        0x01, 0x01, 0x00, 0x01, 'f', 0x01, 0x00, // inline: export "f" → func 0
    };
    const bytes = comptime buildComponent(&.{.{ 5, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    try testing.expectEqual(@as(usize, 2), info.component_instances.items.len);
    const inst0 = info.component_instances.items[0].instantiate;
    try testing.expectEqual(@as(u32, 0), inst0.component);
    try testing.expectEqualStrings("a", inst0.args[0].name);
    try testing.expectEqual(Sort.instance, inst0.args[0].sort);
    const inl = info.component_instances.items[1].inline_exports;
    try testing.expectEqualStrings("f", inl[0].name);
    try testing.expectEqual(Sort.func, inl[0].sort);
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

test "instancetype decode: an interface type with an exported func + own type" {
    // type[0] = instance { (export "f" (func (type 0))); (type own<0>) }
    //   0x42 count=2 | 0x04 exportname'("f") externdesc(0x01 func 0) | 0x01 own<0>(0x69 0x00)
    const body = [_]u8{
        0x01, 0x42, 0x02,
        0x04, 0x00, 0x01, 'f', 0x01, 0x00, // exportdecl "f" → func type 0
        0x01, 0x69, 0x00, // type def: own<0>
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const it = info.deftypes.items[0].instance_type;
    try testing.expectEqual(@as(usize, 2), it.decls.len);
    try testing.expectEqualStrings("f", it.decls[0].export_decl.name);
    try testing.expectEqual(@as(u32, 0), it.decls[0].export_decl.desc.func);
    try testing.expectEqual(@as(u32, 0), it.decls[1].type_def.own);
}

test "componenttype decode: an import + a nested instance type" {
    // type[0] = component { (import "i" (instance (type 0))); 0x42 instance{} }
    //   0x41 count=2 | 0x03 importname'("i") externdesc(0x05 instance 0) | <instancedecl 0x42? no>
    // componentdecl: 0x03 importdecl | instancedecl. Use 0x03 import + a 0x04 export instancedecl.
    const body = [_]u8{
        0x01, 0x41, 0x02,
        0x03, 0x00, 0x01, 'i', 0x05, 0x00, // importdecl "i" → instance type 0
        0x04, 0x00, 0x01, 'e', 0x03, 0x01, // instancedecl exportdecl "e" → (type (sub resource))
    };
    const bytes = comptime buildComponent(&.{.{ 7, &body }});
    var info = try decodeBoth(bytes);
    defer info.deinit();
    const ct = info.deftypes.items[0].component_type;
    try testing.expectEqual(@as(usize, 2), ct.decls.len);
    try testing.expectEqualStrings("i", ct.decls[0].import_decl.name);
    try testing.expectEqual(@as(u32, 0), ct.decls[0].import_decl.desc.instance);
    try testing.expectEqualStrings("e", ct.decls[1].instance_decl.export_decl.name);
    try testing.expectEqual(TypeBound.sub_resource, ct.decls[1].instance_decl.export_decl.desc.type_bound);
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
