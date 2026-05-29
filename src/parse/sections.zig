// FILE-SIZE-EXEMPT: Wasm spec §5.5 section-body decoder catalog (P1 spec-defined closed sub-language; uniform decoder pattern per section id) (per ADR-0099 D1)
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
//! Zone 1 (`src/frontend/`) — imports Zone 0 (`support/leb128.zig`)
//! and Zone 1 (`ir/zir.zig`).

const std = @import("std");
const build_options = @import("build_options");

const leb128 = @import("../support/leb128.zig");
const zir = @import("../ir/zir.zig");
const init_expr = @import("init_expr.zig");

const Allocator = std.mem.Allocator;
const ValType = zir.ValType;
const FuncType = zir.FuncType;

pub const Error = error{
    UnexpectedEnd,
    InvalidFunctype,
    BadValType,
    TrailingBytes,
    LocalsOverflow,
    /// Memory64 (i64 idx_type) flag bit set in limits prefix but
    /// build's `wasm_level < .v3_0` — comptime gate per ADR-0111
    /// Decision 1.
    Memory64Unsupported,
    /// Wasm 3.0 EH proposal §4.5: a tag entry's attribute byte must
    /// be `0x00` (exception tag); other values are reserved for
    /// future extensions and rejected at parse time.
    InvalidTagAttribute,
    OutOfMemory,
} || leb128.Error;

// Code section (Wasm §5.5.11) extracted to `sections_codes.zig`
// per ADR-0096; re-exports below preserve `sections.X` namespace.
const codes_mod = @import("sections_codes.zig");
pub const CodeEntry = codes_mod.CodeEntry;
pub const Codes = codes_mod.Codes;
pub const decodeCodes = codes_mod.decodeCodes;

/// Per ADR-0121 D2: kind tag for each type-section entry. Existing
/// `Types.items[idx]: FuncType` slot is consulted only when
/// `kinds[idx] == .func`; struct / array defs live in the sparse
/// side tables below.
pub const TypeKind = enum(u8) { func, structdef, arraydef };

/// Wasm 3.0 GC §5.3 storage type: `storagetype = valtype | packedtype`.
/// Per ADR-0125 (refines ADR-0121 D3) this is a union, not a `ValType`
/// extension — `i8`/`i16` never appear on the operand stack, so keeping
/// them out of `ValType` avoids the single_slot_dual_meaning hazard.
pub const PackedType = enum(u8) { i8 = 0x78, i16 = 0x77 };

pub const StorageType = union(enum) {
    val: ValType,
    packed_: PackedType,

    /// The operand-stack type seen by struct.new / set / get_s / get_u
    /// (packed fields unpack to i32). Plain struct.get / array.get on a
    /// packed field is invalid — callers check `isPacked` first.
    pub fn operandType(self: StorageType) ValType {
        return switch (self) {
            .val => |v| v,
            .packed_ => .i32,
        };
    }

    pub fn isPacked(self: StorageType) bool {
        return self == .packed_;
    }

    /// Wasm 3.0 §5.3 wire byte — for `FieldInfo.valtype_byte`.
    pub fn specByte(self: StorageType) u8 {
        return switch (self) {
            .val => |v| v.specByte(),
            .packed_ => |p| @intFromEnum(p),
        };
    }

    /// Stored width in bytes for the get_s/get_u sign-extension boundary
    /// (i8→1, i16→2). The heap slot stays 8 bytes uniform (ADR-0116 §3a);
    /// this is the narrow read/write width, not the slot size.
    pub fn storageWidth(self: StorageType) u8 {
        return switch (self) {
            .val => 8,
            .packed_ => |p| switch (p) {
                .i8 => 1,
                .i16 => 2,
            },
        };
    }
};

/// Per ADR-0121 D2 / ADR-0125: shared field-type carrier for struct
/// fields + array elements. `storage` is the Wasm 3.0 storagetype
/// (valtype or packed i8/i16).
pub const StructFieldType = struct {
    storage: StorageType,
    mutable: bool,
};

/// Per ADR-0121 D2: struct typedef. Field list owned by the parent
/// `Types` arena.
pub const StructDef = struct {
    fields: []const StructFieldType,
};

/// Per ADR-0121 D2: array typedef. Single element-type carrier
/// (arrays share the field-type encoding per Wasm 3.0 GC §5).
pub const ArrayDef = struct {
    element: StructFieldType,
};

pub const Types = struct {
    arena: std.heap.ArenaAllocator,
    items: []FuncType,
    /// Parallel to `items`; tags each entry's typedef kind.
    kinds: []TypeKind,
    /// Sparse; non-null iff `kinds[i] == .structdef`.
    struct_defs: []?StructDef,
    /// Sparse; non-null iff `kinds[i] == .arraydef`.
    array_defs: []?ArrayDef,
    /// Parallel to `items`; declared supertype indices from a `sub` /
    /// `sub final` typedef (Wasm 3.0 GC §5). Empty slice for a bare
    /// comptype. Consumed by `validator.validateTypeSection` /
    /// `typeDefIsSubtype` (ADR-0124).
    supertypes: [][]const u32,
    /// Parallel to `items`; true iff the typedef is final and cannot be
    /// extended — `sub final` (0x50) and a bare comptype (0x60/0x5F/0x5E)
    /// are final; `sub` (0x4F) is open. Extending a final type is invalid
    /// (Wasm 3.0 GC §3 sub-validation; ADR-0124).
    finals: []bool,

    pub fn deinit(self: *Types) void {
        self.arena.deinit();
    }
};

/// Decode a single field-type triple per Wasm 3.0 GC §5: storage type
/// (`valtype | packedtype`, ADR-0125) + mutability byte (0x00 const,
/// 0x01 var).
fn readFieldType(body: []const u8, pos: *usize) Error!StructFieldType {
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    // ADR-0125 Part B — packed storage types: i8 (0x78) / i16 (0x77)
    // are NOT valtypes (never on the operand stack), so peek before
    // delegating to readValType.
    const storage: StorageType = switch (body[pos.*]) {
        0x78 => blk: {
            pos.* += 1;
            break :blk .{ .packed_ = .i8 };
        },
        0x77 => blk: {
            pos.* += 1;
            break :blk .{ .packed_ = .i16 };
        },
        else => .{ .val = try init_expr.readValType(body, pos) },
    };
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    const mut_byte = body[pos.*];
    pos.* += 1;
    const mutable = switch (mut_byte) {
        0x00 => false,
        0x01 => true,
        else => return Error.InvalidFunctype,
    };
    return .{ .storage = storage, .mutable = mutable };
}

/// Six parallel arena-backed accumulators for `decodeTypes` — one entry
/// appended per subtype, kept index-parallel.
const TypeAcc = struct {
    items: *std.ArrayList(FuncType),
    kinds: *std.ArrayList(TypeKind),
    struct_defs: *std.ArrayList(?StructDef),
    array_defs: *std.ArrayList(?ArrayDef),
    supertypes: *std.ArrayList([]const u32),
    finals: *std.ArrayList(bool),
};

/// Read one `subtype` (Wasm 3.0 GC §5) and append it as a single type
/// index to `acc`:
///   subtype ::= 0x50 vec(typeidx) comptype  -- sub (NoFinal, extendable)
///             | 0x4F vec(typeidx) comptype  -- sub final
///             | comptype                     -- = sub final ϵ comptype
///   comptype ::= 0x60 functype | 0x5F structtype | 0x5E arraytype
/// Byte assignment per the GC reference interpreter `binary/decode.ml`
/// (0x50 = NoFinal, 0x4F = Final, 0x4E = rec). A bare comptype is final
/// with no declared supertypes.
fn readSubtypeInto(alloc: Allocator, body: []const u8, pos: *usize, acc: TypeAcc) Error!void {
    var fin = true;
    var supers: []const u32 = &.{};
    if (body[pos.*] == 0x50 or body[pos.*] == 0x4F) {
        if (body[pos.*] == 0x50) fin = false; // 0x50 = sub (open); 0x4F = sub final
        pos.* += 1;
        const super_count = try leb128.readUleb128(u32, body, pos);
        const s = try alloc.alloc(u32, super_count);
        for (s) |*x| x.* = try leb128.readUleb128(u32, body, pos);
        supers = s;
        if (pos.* >= body.len) return Error.UnexpectedEnd;
    }
    switch (body[pos.*]) {
        0x60 => {
            pos.* += 1;
            const param_count = try leb128.readUleb128(u32, body, pos);
            const params = try alloc.alloc(ValType, param_count);
            for (params) |*p| p.* = try init_expr.readValType(body, pos);
            const result_count = try leb128.readUleb128(u32, body, pos);
            const results = try alloc.alloc(ValType, result_count);
            for (results) |*r| r.* = try init_expr.readValType(body, pos);
            try acc.items.append(alloc, .{ .params = params, .results = results });
            try acc.kinds.append(alloc, .func);
            try acc.struct_defs.append(alloc, null);
            try acc.array_defs.append(alloc, null);
        },
        0x5F => {
            pos.* += 1;
            const field_count = try leb128.readUleb128(u32, body, pos);
            const fields = try alloc.alloc(StructFieldType, field_count);
            for (fields) |*f| f.* = try readFieldType(body, pos);
            try acc.items.append(alloc, .{ .params = &.{}, .results = &.{} });
            try acc.kinds.append(alloc, .structdef);
            try acc.struct_defs.append(alloc, .{ .fields = fields });
            try acc.array_defs.append(alloc, null);
        },
        0x5E => {
            pos.* += 1;
            const element = try readFieldType(body, pos);
            try acc.items.append(alloc, .{ .params = &.{}, .results = &.{} });
            try acc.kinds.append(alloc, .arraydef);
            try acc.struct_defs.append(alloc, null);
            try acc.array_defs.append(alloc, .{ .element = element });
        },
        else => return Error.InvalidFunctype,
    }
    try acc.supertypes.append(alloc, supers);
    try acc.finals.append(alloc, fin);
}

/// Decode the body of a type section (`SectionId.@"type"`):
///   vec(rectype)
///   rectype ::= 0x4E vec(subtype)   -- recursive group (N type indices)
///             | subtype              -- single (one type index)
/// A `rec` group of N expands to N CONSECUTIVE type indices; mutual
/// references resolve against the post-expansion index space (so the
/// returned `items.len` is the total expanded type count, not the
/// vec(rectype) length). per ADR-0121 D1 the `items` slot stays
/// `FuncType`-typed; non-func entries land as zero placeholders
/// consulted via `kinds`.
pub fn decodeTypes(parent_alloc: Allocator, body: []const u8) Error!Types {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const rec_count = try leb128.readUleb128(u32, body, &pos);

    var items: std.ArrayList(FuncType) = .empty;
    var kinds: std.ArrayList(TypeKind) = .empty;
    var struct_defs: std.ArrayList(?StructDef) = .empty;
    var array_defs: std.ArrayList(?ArrayDef) = .empty;
    var supertypes: std.ArrayList([]const u32) = .empty;
    var finals: std.ArrayList(bool) = .empty;
    const acc: TypeAcc = .{
        .items = &items,
        .kinds = &kinds,
        .struct_defs = &struct_defs,
        .array_defs = &array_defs,
        .supertypes = &supertypes,
        .finals = &finals,
    };

    var rec: u32 = 0;
    while (rec < rec_count) : (rec += 1) {
        if (pos >= body.len) return Error.UnexpectedEnd;
        if (body[pos] == 0x4E) {
            // rec group: vec(subtype) → N consecutive type indices.
            pos += 1;
            const n = try leb128.readUleb128(u32, body, &pos);
            var k: u32 = 0;
            while (k < n) : (k += 1) try readSubtypeInto(alloc, body, &pos, acc);
        } else {
            try readSubtypeInto(alloc, body, &pos, acc);
        }
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{
        .arena = arena,
        .items = items.items,
        .kinds = kinds.items,
        .struct_defs = struct_defs.items,
        .array_defs = array_defs.items,
        .supertypes = supertypes.items,
        .finals = finals.items,
    };
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

/// Wasm 3.0 exception-handling proposal §4.5: one tag-section
/// entry. The attribute byte is currently `0x00` (exception tag)
/// only; `typeidx` references a function-type whose params
/// describe the exception's payload (results MUST be empty per
/// the EH proposal validation rules — enforced when the
/// tag-resolution wiring lands at 10.E-N).
pub const TagEntry = struct {
    attribute: u8,
    typeidx: u32,
};

/// Decode the body of a tag section (`SectionId.tag`):
///   vec(tag)
///   tag := attr:byte typeidx:u32
/// Returns a slice of TagEntry. Caller owns the allocation
/// (single arena drop per the file-level memory contract).
///
/// Wasm 3.0 EH proposal §4.5 binary format.
pub fn decodeTags(alloc: Allocator, body: []const u8) Error![]TagEntry {
    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const entries = try alloc.alloc(TagEntry, count);
    errdefer alloc.free(entries);
    for (entries) |*entry| {
        if (pos >= body.len) return Error.UnexpectedEnd;
        const attr = body[pos];
        pos += 1;
        if (attr != 0x00) return Error.InvalidTagAttribute;
        const typeidx = try leb128.readUleb128(u32, body, &pos);
        entry.* = .{ .attribute = attr, .typeidx = typeidx };
    }
    if (pos != body.len) return Error.TrailingBytes;
    return entries;
}

pub const ImportKind = enum(u8) {
    func = 0x00,
    table = 0x01,
    memory = 0x02,
    global = 0x03,
    // Wasm 3.0 EH (10.E-xmodule-tags / ADR-0114): tag import
    // `(import "M" "e0" (tag (type N)))`. try_table.1 imports a tag
    // from the registered try_table.0.
    tag = 0x04,
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
    table: struct { elem_type: ValType, min: u32, max: ?u32 },
    memory: MemoryEntry,
    global: struct { valtype: ValType, mutable: bool },
    // Wasm 3.0 EH tag import — the tag's type-section index (10.E).
    tag_typeidx: u32,
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
            0x00, 0x01, 0x02, 0x03, 0x04 => @enumFromInt(k),
            else => return Error.InvalidFunctype,
        };
        const payload: ImportPayload = switch (kind) {
            .func => .{ .func_typeidx = try leb128.readUleb128(u32, body, &pos) },
            .tag => blk: {
                // tagtype = attribute(0x00) + typeidx (Wasm 3.0 EH).
                if (pos >= body.len) return Error.UnexpectedEnd;
                const attr = body[pos];
                pos += 1;
                if (attr != 0x00) return Error.InvalidFunctype;
                break :blk .{ .tag_typeidx = try leb128.readUleb128(u32, body, &pos) };
            },
            .table => blk: {
                if (pos >= body.len) return Error.UnexpectedEnd;
                const reftype_byte = body[pos];
                pos += 1;
                const elem_type: ValType = switch (reftype_byte) {
                    0x70 => .funcref,
                    0x6f => .externref,
                    else => return Error.InvalidFunctype,
                };
                const limits = try readLimits(body, &pos);
                break :blk .{ .table = .{ .elem_type = elem_type, .min = limits.min, .max = limits.max } };
            },
            .memory => blk: {
                const ml = try readMemLimits(body, &pos);
                break :blk .{ .memory = .{ .idx_type = ml.idx_type, .min = ml.min, .max = ml.max } };
            },
            .global => blk: {
                const t = try init_expr.readValType(body, &pos);
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

fn readLimits(body: []const u8, pos: *usize) Error!struct { min: u32, max: ?u32 } {
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    const flag = body[pos.*];
    pos.* += 1;
    if (flag > 1) return Error.InvalidFunctype;
    const min = try leb128.readUleb128(u32, body, pos);
    const max: ?u32 = if (flag & 1 != 0) try leb128.readUleb128(u32, body, pos) else null;
    return .{ .min = min, .max = max };
}

pub const Tables = struct {
    arena: std.heap.ArenaAllocator,
    items: []zir.TableEntry,

    pub fn deinit(self: *Tables) void {
        self.arena.deinit();
    }
};

/// Decode the body of a table section (`SectionId.table`):
///   vec(table), table = tabletype = reftype limits
/// reftype: 0x70 (funcref) | 0x6F (externref).
/// limits: 0x00 min | 0x01 min max.
pub fn decodeTables(parent_alloc: Allocator, body: []const u8) Error!Tables {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(zir.TableEntry, count);

    for (items) |*t| {
        // function-references: table elem_type may be any reftype,
        // incl. the typed `(ref null? $t)` forms — decode via the shared
        // reftype reader instead of a hardcoded funcref/externref switch.
        const elem_type = init_expr.readRefType(body, &pos) catch |e| switch (e) {
            error.UnexpectedEnd => return Error.UnexpectedEnd,
            else => return Error.BadValType,
        };
        if (pos >= body.len) return Error.UnexpectedEnd;
        const flag = body[pos];
        pos += 1;
        // Wasm spec §5.3.1: table-type limits encoding flag
        // must be 0 (min only) or 1 (min + max). Any other
        // value is malformed (binary.87.wasm asserts this for
        // flag=0x08).
        if (flag != 0 and flag != 1) return Error.InvalidFunctype;
        const min = try leb128.readUleb128(u32, body, &pos);
        const max: ?u32 = if (flag & 1 != 0)
            try leb128.readUleb128(u32, body, &pos)
        else
            null;
        t.* = .{ .elem_type = elem_type, .min = min, .max = max };
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
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
        const t = try init_expr.readValType(body, &pos);
        if (pos >= body.len) return Error.UnexpectedEnd;
        const m = body[pos];
        pos += 1;
        if (m > 1) return Error.InvalidFunctype; // reused; malformed mut byte
        const start = pos;
        // Include the terminating end (0x0B) in the init_expr slice so
        // callers can drive a validator/lowerer the same way they would a
        // function body.
        try init_expr.scanInitExpr(body, &pos);
        g.* = .{ .valtype = t, .mutable = m == 1, .init_expr = body[start..pos] };
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

// decodeCodes moved to `sections_codes.zig` per ADR-0096.

// DataKind moved to `sections_data.zig` (re-exported below after
// the memory section).

/// One Wasm memory's limits. Wasm 3.0 §5.4.4 widens the limits
/// prefix to encode the i64-flag bit (memory64 proposal). Per
/// ADR-0111 Decision 1, `idx_type` is always present (not
/// build-option-gated) for ABI stability across `-Dwasm` levels.
/// Multi-memory enable lives at parser+validator (this layer);
/// runtime cascade to `[]MemoryInstance` is 10.M-2.
pub const MemoryEntry = struct {
    /// Address-space width discriminator (Wasm 3.0 §5.4.4 limits
    /// prefix bit 0x04). `.i32` for legacy (≤ 4 GiB); `.i64` for
    /// memory64 (spec-full 2^64 addressable).
    idx_type: IdxType = .i32,
    /// Initial size in 64 KiB pages (§5.5.5 / §5.4.4). u64 storage
    /// regardless of `idx_type`; for `.i32`, decoder rejects values
    /// > `u32` max.
    min: u64,
    /// Optional upper bound in pages.
    max: ?u64 = null,

    pub const IdxType = enum(u1) { i32 = 0, i64 = 1 };
};

pub const Memories = struct {
    arena: std.heap.ArenaAllocator,
    items: []MemoryEntry,

    pub fn deinit(self: *Memories) void {
        self.arena.deinit();
    }
};

/// Read one memory's limits per Wasm 3.0 §5.4.4. Flag byte bits:
/// - bit 0 (0x01): has_max
/// - bit 1 (0x02): shared (NOT supported in v0.1.0; rejected)
/// - bit 2 (0x04): memory64 (i64 idx_type)
/// - bit 3 (0x08): has_page_size (custom-page-size proposal;
///   not supported)
/// Accepted flag values: `0x00` / `0x01` (i32) always; `0x04` /
/// `0x05` (i64) only when `comptime build_options.wasm_level >=
/// .v3_0` — else `Error.Memory64Unsupported` per ADR-0111 D1.
fn readMemLimits(body: []const u8, pos: *usize) Error!MemoryEntry {
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    const flag = body[pos.*];
    pos.* += 1;
    const has_max = (flag & 0x01) != 0;
    const is_shared = (flag & 0x02) != 0;
    const is_i64 = (flag & 0x04) != 0;
    if (is_shared) return Error.BadValType;
    if ((flag & ~@as(u8, 0x05)) != 0) return Error.BadValType;
    if (is_i64) {
        if (comptime @intFromEnum(build_options.wasm_level) < @intFromEnum(@TypeOf(build_options.wasm_level).v3_0)) {
            return Error.Memory64Unsupported;
        }
    }
    const min = try leb128.readUleb128(u64, body, pos);
    const max: ?u64 = if (has_max) try leb128.readUleb128(u64, body, pos) else null;
    const idx_type: MemoryEntry.IdxType = if (is_i64) .i64 else .i32;
    return .{ .idx_type = idx_type, .min = min, .max = max };
}

/// Decode the body of a memory section (`SectionId.memory`):
///   memorysec = vec(memtype)
///   memtype   = limits
/// See `readMemLimits` for the flag-byte semantics. Multi-memory
/// is enabled at this layer (Wasm 3.0 §5.4.6); the count > 1
/// constraint is enforced at the runtime instantiation layer
/// (10.M-2).
pub fn decodeMemory(parent_alloc: Allocator, body: []const u8) Error!Memories {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(MemoryEntry, count);
    for (items) |*entry| {
        entry.* = try readMemLimits(body, &pos);
    }
    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

// Data section (Wasm 2.0 §5.5.13) extracted to `sections_data.zig`
// per ADR-0096; re-exports below preserve `sections.X` namespace.
const data_mod = @import("sections_data.zig");
pub const DataKind = data_mod.DataKind;
pub const DataSegment = data_mod.DataSegment;
pub const Datas = data_mod.Datas;
pub const decodeData = data_mod.decodeData;

// Element section (Wasm 2.0 §5.5.12) extracted to
// `sections_element.zig` per ADR-0095. Types + decoder +
// per-funcref-init-expr helpers + global.get marker live there;
// re-exports below preserve the `sections.X` namespace for callers.
const elem = @import("sections_element.zig");
pub const ElementKind = elem.ElementKind;
pub const ElementSegment = elem.ElementSegment;
pub const Elements = elem.Elements;
pub const decodeElement = elem.decodeElement;
pub const ELEM_GLOBAL_GET_MARKER = elem.ELEM_GLOBAL_GET_MARKER;
pub const elemEntryIsGlobalGet = elem.elemEntryIsGlobalGet;
pub const elemEntryGlobalIdx = elem.elemEntryGlobalIdx;

pub const ExportDesc = enum(u8) {
    func = 0,
    table = 1,
    memory = 2,
    global = 3,
};

pub const Export = struct {
    /// Owned by `Exports.arena`; survives the source body's lifetime.
    name: []const u8,
    kind: ExportDesc,
    idx: u32,
};

pub const Exports = struct {
    arena: std.heap.ArenaAllocator,
    items: []Export,

    pub fn deinit(self: *Exports) void {
        self.arena.deinit();
    }
};

/// Decode the body of an export section (Wasm 1.0 §5.5.10):
///   exportsec = vec(export)
///   export    = name:vec(byte), desc:exportdesc
///   exportdesc = (func | table | memory | global) idx:u32
pub fn decodeExports(parent_alloc: Allocator, body: []const u8) Error!Exports {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(Export, count);

    // 10.E cycle 79 — Wasm 3.0 EH adds export-kind 0x04 (tag); the
    // upstream `wasm-c-api` doesn't include it in `wasm_externkind_t`
    // so the v2 c_api surface (`ExternKind`) doesn't either. To let
    // EH-using modules (try_table.0.wasm exports `e0` as kind=4)
    // instantiate, we recognise kind=4 at decode but FILTER the
    // export from `items` — the body's tag references go through
    // the tag section directly, not through exports_storage.
    // ExportDesc stays at 4 variants; downstream switches don't
    // need a `.tag` arm. Future-cycle: cross-instance tag imports
    // (D-192 sibling) will need a richer kind type.
    var write_i: usize = 0;
    for (0..count) |_| {
        const name_len = try leb128.readUleb128(u32, body, &pos);
        if (pos + name_len > body.len) return Error.UnexpectedEnd;
        const name_copy = try alloc.dupe(u8, body[pos .. pos + name_len]);
        pos += name_len;

        if (pos >= body.len) return Error.UnexpectedEnd;
        const kind_byte = body[pos];
        pos += 1;
        if (kind_byte > 4) return Error.BadValType;
        const idx = try leb128.readUleb128(u32, body, &pos);
        if (kind_byte == 4) continue; // drop tag exports (see comment above)
        const kind: ExportDesc = @enumFromInt(kind_byte);
        items[write_i] = .{ .name = name_copy, .kind = kind, .idx = idx };
        write_i += 1;
    }
    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items[0..write_i] };
}

// scanInitExpr / readValType / skipLeb128 extracted to
// `init_expr.zig` per ADR-0101 (post-ADR-0099 redesign). Re-exports
// preserve the `sections.scanInitExpr` / `sections.readValType`
// public surface for any external caller that still reaches them
// by namespace; internal callers use `init_expr.X` directly.
pub const scanInitExpr = init_expr.scanInitExpr;
pub const readValType = init_expr.readValType;

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
        0x60,
        0x02,
        0x7F,
        0x7E,
        0x02,
        0x7D,
        0x7C,
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    const ft = t.items[0];
    try testing.expectEqualSlices(ValType, &[_]ValType{ .i32, .i64 }, ft.params);
    try testing.expectEqualSlices(ValType, &[_]ValType{ .f32, .f64 }, ft.results);
}

test "decodeTypes: functype with exnref result (Wasm 3.0 EH; 10.E-xmodule-tags cycle 112)" {
    // try_table.1's catch_ref result tuples encode as `(i32, exnref)`
    // = 0x60 0x00 0x02 0x7F 0x69 — the bare-0x69 exnref in the Type
    // section was the FIRST parse blocker for the EH cross-module
    // corpus (decodeTypes → readValType BadValType pre-cycle-112).
    const body = [_]u8{
        0x01, // count=1
        0x60, // func
        0x00, // 0 params
        0x02, 0x7F, 0x69, // 2 results: i32, exnref
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    const ft = t.items[0];
    try testing.expectEqual(@as(usize, 0), ft.params.len);
    try testing.expectEqual(@as(usize, 2), ft.results.len);
    try testing.expectEqual(ValType.i32, ft.results[0]);
    try testing.expect(ft.results[1].eql(ValType.exnref));
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

test "decodeTypes: rejects unknown typedef prefix" {
    // 0x61 is unassigned in the Wasm 3.0 typedef space (0x60 func,
    // 0x5F struct, 0x5E array). Other prefixes must reject.
    const body = [_]u8{ 0x01, 0x61, 0x00, 0x00 };
    try testing.expectError(Error.InvalidFunctype, decodeTypes(testing.allocator, &body));
}

test "decodeTypes: sub / sub final prefix populates supertypes + finals (10.G ADR-0124 cycle 126)" {
    // Wasm 3.0 GC §5 subtype binary form (byte assignment per the GC
    // reference interpreter binary/decode.ml: 0x4F = sub final, 0x50 = sub):
    //   type 0 = 0x4F 0x00 (struct i32)          -- `sub final` (no supers)
    //   type 1 = 0x50 0x01 0x00 (struct i32 i64)  -- `sub $0` (open)
    const body = [_]u8{
        0x02,
        0x4F, 0x00, 0x5F, 0x01, 0x7F, 0x00, // sub final, 0 supers, struct{i32 const}
        0x50, 0x01, 0x00, 0x5F, 0x02, 0x7F, 0x00, 0x7E, 0x00, // sub $0, struct{i32,i64 const}
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.items.len);
    try testing.expectEqual(TypeKind.structdef, t.kinds[0]);
    try testing.expectEqual(TypeKind.structdef, t.kinds[1]);
    // type 0: `sub final` → final, no declared supertypes.
    try testing.expectEqual(true, t.finals[0]);
    try testing.expectEqual(@as(usize, 0), t.supertypes[0].len);
    // type 1: `sub $0` → NOT final (open), one declared supertype (index 0).
    try testing.expectEqual(false, t.finals[1]);
    try testing.expectEqualSlices(u32, &[_]u32{0}, t.supertypes[1]);
}

test "decodeTypes: 0x4E rec group expands to N consecutive type indices (10.G cycle 126)" {
    // vec(rectype) of 2: a bare struct, then a `rec` group of 2 mutually-
    // referencing structs. Total = 3 type indices.
    //   rectype 0 = 0x5F (struct{i32 const})                  -- bare → final, no supers
    //   rectype 1 = 0x4E 0x02 (rec group of 2):
    //     idx 1 = 0x50 0x00 0x5F (struct{ (ref null 2) const })  -- sub, refs idx 2
    //     idx 2 = 0x50 0x00 0x5F (struct{ (ref null 1) const })  -- sub, refs idx 1
    const body = [_]u8{
        0x02, // 2 rectypes
        0x5F, 0x01, 0x7F, 0x00, // rectype 0: bare struct{i32 const}
        0x4E, 0x02, // rec group of 2
        0x50, 0x00, 0x5F, 0x01, 0x63, 0x02, 0x00, // idx1: sub, struct{(ref null $2) const}
        0x50, 0x00, 0x5F, 0x01, 0x63, 0x01, 0x00, // idx2: sub, struct{(ref null $1) const}
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 3), t.items.len); // rec-of-2 expanded
    try testing.expectEqual(TypeKind.structdef, t.kinds[0]);
    try testing.expectEqual(TypeKind.structdef, t.kinds[1]);
    try testing.expectEqual(TypeKind.structdef, t.kinds[2]);
    try testing.expectEqual(true, t.finals[0]); // bare → final
    try testing.expectEqual(false, t.finals[1]); // 0x50 sub → open
    try testing.expectEqual(false, t.finals[2]);
}

test "decodeTypes: single struct with one i32 const field (ADR-0121 D4; 10.G op_gc cycle 14)" {
    // structtype = 0x5F vec(fieldtype); fieldtype = valtype mut_byte.
    // Encoding: count=1, 0x5F, field_count=1, valtype=i32(0x7F), mut=0x00.
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x00 };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    try testing.expectEqual(TypeKind.structdef, t.kinds[0]);
    try testing.expect(t.struct_defs[0] != null);
    const sd = t.struct_defs[0].?;
    try testing.expectEqual(@as(usize, 1), sd.fields.len);
    try testing.expectEqual(ValType.i32, sd.fields[0].storage.operandType());
    try testing.expectEqual(false, sd.fields[0].mutable);
}

test "decodeTypes: multi-field struct preserves field order + mutability (ADR-0121 D4)" {
    // struct { i32 const, i64 var, f32 const }.
    const body = [_]u8{
        0x01, 0x5F,
        0x03,
        0x7F, 0x00, // i32 const
        0x7E, 0x01, // i64 var
        0x7D, 0x00, // f32 const
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    const sd = t.struct_defs[0].?;
    try testing.expectEqual(@as(usize, 3), sd.fields.len);
    try testing.expectEqual(ValType.i32, sd.fields[0].storage.operandType());
    try testing.expectEqual(false, sd.fields[0].mutable);
    try testing.expectEqual(ValType.i64, sd.fields[1].storage.operandType());
    try testing.expectEqual(true, sd.fields[1].mutable);
    try testing.expectEqual(ValType.f32, sd.fields[2].storage.operandType());
    try testing.expectEqual(false, sd.fields[2].mutable);
}

test "decodeTypes: array of i32 var (ADR-0121 D4; 10.G op_gc cycle 14)" {
    // arraytype = 0x5E fieldtype; one element-type triple.
    const body = [_]u8{ 0x01, 0x5E, 0x7F, 0x01 };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(TypeKind.arraydef, t.kinds[0]);
    try testing.expect(t.array_defs[0] != null);
    const ad = t.array_defs[0].?;
    try testing.expectEqual(ValType.i32, ad.element.storage.operandType());
    try testing.expectEqual(true, ad.element.mutable);
}

test "decodeTypes: mixed func + struct + array preserves kinds in order (ADR-0121 D4)" {
    // Three entries: () -> (), struct { i32 var }, array of i64 const.
    const body = [_]u8{
        0x03,
        0x60, 0x00, 0x00, // () -> ()
        0x5F, 0x01, 0x7F, 0x01, // struct { i32 var }
        0x5E, 0x7E, 0x00, // array of i64 const
    };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 3), t.items.len);
    try testing.expectEqual(TypeKind.func, t.kinds[0]);
    try testing.expectEqual(TypeKind.structdef, t.kinds[1]);
    try testing.expectEqual(TypeKind.arraydef, t.kinds[2]);
    try testing.expect(t.struct_defs[0] == null);
    try testing.expect(t.struct_defs[1] != null);
    try testing.expect(t.struct_defs[2] == null);
    try testing.expect(t.array_defs[2] != null);
}

test "decodeTypes: rejects invalid mutability byte (ADR-0121 D4)" {
    // mut byte must be 0x00 or 0x01; 0x02 rejects.
    const body = [_]u8{ 0x01, 0x5F, 0x01, 0x7F, 0x02 };
    try testing.expectError(Error.InvalidFunctype, decodeTypes(testing.allocator, &body));
}

test "decodeTypes: accepts v128 valtype (Wasm 2.0 SIMD)" {
    // 0x7B is v128 per Wasm 2.0 SIMD §5.3.5. Type sections that
    // declare v128 in params or results must decode without error.
    const body = [_]u8{ 0x01, 0x60, 0x01, 0x7B, 0x01, 0x7B };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    try testing.expectEqualSlices(ValType, &[_]ValType{.v128}, t.items[0].params);
    try testing.expectEqualSlices(ValType, &[_]ValType{.v128}, t.items[0].results);
}

test "decodeTypes: rejects unknown valtype byte" {
    // 0x55 is unassigned in the Wasm 3.0 valtype space; must be
    // rejected. (0x6E was previously used here but became anyref
    // in Wasm 3.0 GC — see ADR-0115 §6 Revision 2026-05-29 +
    // 10.G op_gc cycle 6.)
    const body = [_]u8{ 0x01, 0x60, 0x01, 0x55, 0x00 };
    try testing.expectError(Error.BadValType, decodeTypes(testing.allocator, &body));
}

test "decodeTypes: accepts funcref param/result (Wasm 2.0 §5.3.1)" {
    // 0x70 is funcref. (funcref) -> (funcref) must decode without
    // error so that function types can express reftype param/result
    // signatures (e.g. for `(param funcref)` helpers).
    const body = [_]u8{ 0x01, 0x60, 0x01, 0x70, 0x01, 0x70 };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    try testing.expectEqualSlices(ValType, &[_]ValType{.funcref}, t.items[0].params);
    try testing.expectEqualSlices(ValType, &[_]ValType{.funcref}, t.items[0].results);
}

test "decodeTypes: accepts externref param/result (Wasm 2.0 §5.3.1)" {
    // 0x6F is externref. (externref) -> (externref) must decode.
    const body = [_]u8{ 0x01, 0x60, 0x01, 0x6F, 0x01, 0x6F };
    var t = try decodeTypes(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.items.len);
    try testing.expectEqualSlices(ValType, &[_]ValType{.externref}, t.items[0].params);
    try testing.expectEqualSlices(ValType, &[_]ValType{.externref}, t.items[0].results);
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

test "decodeTags: empty body (count=0) yields empty slice" {
    const out = try decodeTags(testing.allocator, &[_]u8{0x00});
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "decodeTags: single entry (attr=0x00 typeidx=0)" {
    // body: count=1, attr=0x00, typeidx=0.
    const out = try decodeTags(testing.allocator, &[_]u8{ 0x01, 0x00, 0x00 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u8, 0x00), out[0].attribute);
    try testing.expectEqual(@as(u32, 0), out[0].typeidx);
}

test "decodeTags: three entries preserved in order" {
    // body: count=3, (attr=0 typeidx=0), (attr=0 typeidx=2), (attr=0 typeidx=5)
    const out = try decodeTags(testing.allocator, &[_]u8{ 0x03, 0x00, 0x00, 0x00, 0x02, 0x00, 0x05 });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(u32, 0), out[0].typeidx);
    try testing.expectEqual(@as(u32, 2), out[1].typeidx);
    try testing.expectEqual(@as(u32, 5), out[2].typeidx);
}

test "decodeTags: rejects non-zero attribute byte (reserved for future use)" {
    // attr=0x01 is reserved; only 0x00 (exception tag) is currently valid.
    const r = decodeTags(testing.allocator, &[_]u8{ 0x01, 0x01, 0x00 });
    try testing.expectError(Error.InvalidTagAttribute, r);
}

test "decodeTags: rejects truncated input (missing typeidx)" {
    // count=1, attr=0x00, but no typeidx follows.
    const r = decodeTags(testing.allocator, &[_]u8{ 0x01, 0x00 });
    try testing.expectError(leb128.Error.Truncated, r);
}

test "decodeTags: rejects trailing bytes" {
    const r = decodeTags(testing.allocator, &[_]u8{ 0x01, 0x00, 0x00, 0xFF });
    try testing.expectError(Error.TrailingBytes, r);
}

// decodeCodes tests moved to `sections_codes.zig` per ADR-0096.

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

test "decodeGlobals: accepts externref valtype (Wasm 2.0 §5.3.1)" {
    // count=1; valtype=externref (0x6F); mut=const; init: ref.null
    // extern ; end (0xD0 0x6F 0x0B).
    const body = [_]u8{ 0x01, 0x6F, 0x00, 0xD0, 0x6F, 0x0B };
    var g = try decodeGlobals(testing.allocator, &body);
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.items.len);
    try testing.expectEqual(ValType.externref, g.items[0].valtype);
    try testing.expectEqual(false, g.items[0].mutable);
}

test "decodeGlobals: accepts funcref valtype (Wasm 2.0 §5.3.1)" {
    const body = [_]u8{ 0x01, 0x70, 0x01, 0xD0, 0x70, 0x0B };
    var g = try decodeGlobals(testing.allocator, &body);
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.items.len);
    try testing.expectEqual(ValType.funcref, g.items[0].valtype);
    try testing.expectEqual(true, g.items[0].mutable);
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
        0x03,
        'e',
        'n',
        'v',
        0x03,
        'a',
        'b',
        's',
        0x00,
        0x02,
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
        0x02,
        'm',
        'm',
        0x01,
        'g',
        0x03,
        0x7F,
        0x00,
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

test "decodeImports: tag import (Wasm 3.0 EH, 10.E-xmodule-tags)" {
    // count=1; mod="test"; name="e0"; desc=0x04 (tag) attr=0x00 typeidx=0.
    // try_table.1 imports `test::e0` (a tag) — previously rejected at
    // parse (kind 0x04 → InvalidFunctype); now decodes to ImportKind.tag.
    const body = [_]u8{ 0x01, 0x04, 't', 'e', 's', 't', 0x02, 'e', '0', 0x04, 0x00, 0x00 };
    var i = try decodeImports(testing.allocator, &body);
    defer i.deinit();
    try testing.expectEqual(ImportKind.tag, i.items[0].kind);
    try testing.expectEqual(@as(u32, 0), i.items[0].payload.tag_typeidx);
}

test "decodeImports: tag import with non-zero attribute byte rejected" {
    // tagtype attribute must be 0x00 (reserved); 0x01 is malformed.
    const body = [_]u8{ 0x01, 0x04, 't', 'e', 's', 't', 0x02, 'e', '0', 0x04, 0x01, 0x00 };
    try testing.expectError(Error.InvalidFunctype, decodeImports(testing.allocator, &body));
}

test "decodeGlobals: rejects unterminated init_expr" {
    const body = [_]u8{ 0x01, 0x7F, 0x00, 0x41, 0x00 }; // missing 0x0B
    try testing.expectError(Error.UnexpectedEnd, decodeGlobals(testing.allocator, &body));
}

test "decodeGlobals: v128 init_expr whose lane byte equals 0x0B (simd_const.388)" {
    // Two v128-mut globals back-to-back. Global 0's v128.const immediate
    // contains the byte 0x0B (lane 11 = 0x0B). A naive scan-for-0x0B
    // would truncate global 0's init_expr mid-immediate and misparse
    // the rest as global 1's globaltype → BadValType. This regression-
    // detects the simd_const.388.wasm failure surfaced after §9.9-g-19.
    //
    // Body (count=2):
    //   global 0: 7B 01  fd 0c <16 bytes with 0x0B at offset 11>  0b
    //   global 1: 7B 01  fd 0c <16 zero bytes>                    0b
    const body = [_]u8{
        0x02, // count
        // global 0
        0x7B, 0x01, // v128 mut
        0xFD, 0x0C,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x0B, // lane 11 = 0x0B (the trap byte)
        0x00, 0x00, 0x00, 0x00,
        0x0B, // end
        // global 1
        0x7B, 0x01, // v128 mut
        0xFD, 0x0C,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x0B, // end
    };
    var g = try decodeGlobals(testing.allocator, &body);
    defer g.deinit();
    try testing.expectEqual(@as(usize, 2), g.items.len);
    try testing.expectEqual(ValType.v128, g.items[0].valtype);
    try testing.expectEqual(ValType.v128, g.items[1].valtype);
    try testing.expectEqual(true, g.items[0].mutable);
    try testing.expectEqual(true, g.items[1].mutable);
    // Global 0's init_expr must span the full FD 0C + 16 bytes + 0x0B
    // (21 bytes total) — proves the scanner walked the v128.const
    // immediate instead of bailing at the embedded 0x0B byte.
    // FD 0C + 16 immediate + 0x0B = 19 bytes.
    try testing.expectEqual(@as(usize, 19), g.items[0].init_expr.len);
    try testing.expectEqual(@as(usize, 19), g.items[1].init_expr.len);
}

// decodeData tests moved to `sections_data.zig` per ADR-0096.
// decodeElement tests moved to `sections_element.zig` per ADR-0095.

test "decodeTables: empty section" {
    var t = try decodeTables(testing.allocator, &[_]u8{0x00});
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.items.len);
}

test "decodeTables: funcref with min only" {
    // count=1; reftype=0x70; flag=0; min=10
    const body = [_]u8{ 0x01, 0x70, 0x00, 0x0A };
    var t = try decodeTables(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(ValType.funcref, t.items[0].elem_type);
    try testing.expectEqual(@as(u32, 10), t.items[0].min);
    try testing.expectEqual(@as(?u32, null), t.items[0].max);
}

test "decodeTables: externref with min and max" {
    const body = [_]u8{ 0x01, 0x6F, 0x01, 0x05, 0x10 };
    var t = try decodeTables(testing.allocator, &body);
    defer t.deinit();
    try testing.expectEqual(ValType.externref, t.items[0].elem_type);
    try testing.expectEqual(@as(u32, 5), t.items[0].min);
    try testing.expectEqual(@as(?u32, 16), t.items[0].max);
}

test "decodeTables: rejects unknown reftype byte" {
    try testing.expectError(Error.BadValType, decodeTables(testing.allocator, &[_]u8{ 0x01, 0x55, 0x00, 0x00 }));
}

test "decodeTables: typed-ref (ref null 0) table (function-references)" {
    // count=1; reftype (ref null 0) = 0x63 0x00; flag=0; min=2.
    // ref_is_null.0 declares `(table 2 (ref null 0))`.
    const body = [_]u8{ 0x01, 0x63, 0x00, 0x00, 0x02 };
    var t = try decodeTables(testing.allocator, &body);
    defer t.deinit();
    const et = t.items[0].elem_type;
    try testing.expect(et == .ref);
    try testing.expectEqual(true, et.ref.nullable);
    try testing.expect(et.ref.heap_type == .concrete);
    try testing.expectEqual(@as(u32, 0), et.ref.heap_type.concrete);
    try testing.expectEqual(@as(u32, 2), t.items[0].min);
}

test "decodeMemory: min only + min/max forms (i32 default)" {
    // count=2; entry 0 = (min 1); entry 1 = (min 2 max 3)
    const body = [_]u8{ 0x02, 0x00, 0x01, 0x01, 0x02, 0x03 };
    var m = try decodeMemory(testing.allocator, &body);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.items.len);
    try testing.expectEqual(MemoryEntry.IdxType.i32, m.items[0].idx_type);
    try testing.expectEqual(@as(u64, 1), m.items[0].min);
    try testing.expect(m.items[0].max == null);
    try testing.expectEqual(MemoryEntry.IdxType.i32, m.items[1].idx_type);
    try testing.expectEqual(@as(u64, 2), m.items[1].min);
    try testing.expectEqual(@as(u64, 3), m.items[1].max.?);
}

test "decodeMemory: rejects shared flag (threads not supported)" {
    const body = [_]u8{ 0x01, 0x03, 0x01, 0x02 };
    try testing.expectError(Error.BadValType, decodeMemory(testing.allocator, &body));
}

test "decodeMemory: rejects reserved flag bits" {
    const body = [_]u8{ 0x01, 0x08, 0x01 };
    try testing.expectError(Error.BadValType, decodeMemory(testing.allocator, &body));
}

// Memory64 (Wasm 3.0 §5.4.4): flag bit 0x04 selects i64 idx_type.
// Tests fire only under -Dwasm=v3_0 (the default); under v2_0 the
// parser rejects with Error.Memory64Unsupported (comptime gate per
// ADR-0111 D1; verified via the -Dwasm=v2_0 build path itself, not
// a runtime test).
test "decodeMemory: i64 memory min only (Wasm 3.0 §5.4.4)" {
    if (comptime @intFromEnum(build_options.wasm_level) < @intFromEnum(@TypeOf(build_options.wasm_level).v3_0)) return;
    // count=1; flag=0x04 (i64, min only); min=7
    const body = [_]u8{ 0x01, 0x04, 0x07 };
    var m = try decodeMemory(testing.allocator, &body);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.items.len);
    try testing.expectEqual(MemoryEntry.IdxType.i64, m.items[0].idx_type);
    try testing.expectEqual(@as(u64, 7), m.items[0].min);
    try testing.expect(m.items[0].max == null);
}

test "decodeMemory: i64 memory min+max (Wasm 3.0 §5.4.4)" {
    if (comptime @intFromEnum(build_options.wasm_level) < @intFromEnum(@TypeOf(build_options.wasm_level).v3_0)) return;
    // count=1; flag=0x05 (i64, min+max); min=2, max=8
    const body = [_]u8{ 0x01, 0x05, 0x02, 0x08 };
    var m = try decodeMemory(testing.allocator, &body);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.items.len);
    try testing.expectEqual(MemoryEntry.IdxType.i64, m.items[0].idx_type);
    try testing.expectEqual(@as(u64, 2), m.items[0].min);
    try testing.expectEqual(@as(u64, 8), m.items[0].max.?);
}

test "decodeMemory: multi-memory parser enable (Wasm 3.0 §5.4.6)" {
    // count=3 mixed: (i32 min 1), (i64 min 2 max 3), (i32 min 4)
    // Runtime instantiation still rejects count > 1 until 10.M-2;
    // this test asserts the parser layer alone accepts the shape.
    const body = [_]u8{
        0x03, // count=3
        0x00, 0x01, // entry 0: i32, min 1
        0x05, 0x02, 0x03, // entry 1: i64, min 2, max 3
        0x00, 0x04, // entry 2: i32, min 4
    };
    if (comptime @intFromEnum(build_options.wasm_level) < @intFromEnum(@TypeOf(build_options.wasm_level).v3_0)) {
        // v2.0 build rejects entry 1's i64 flag at the parser.
        try testing.expectError(Error.Memory64Unsupported, decodeMemory(testing.allocator, &body));
        return;
    }
    var m = try decodeMemory(testing.allocator, &body);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 3), m.items.len);
    try testing.expectEqual(MemoryEntry.IdxType.i32, m.items[0].idx_type);
    try testing.expectEqual(@as(u64, 1), m.items[0].min);
    try testing.expectEqual(MemoryEntry.IdxType.i64, m.items[1].idx_type);
    try testing.expectEqual(@as(u64, 2), m.items[1].min);
    try testing.expectEqual(@as(u64, 3), m.items[1].max.?);
    try testing.expectEqual(MemoryEntry.IdxType.i32, m.items[2].idx_type);
    try testing.expectEqual(@as(u64, 4), m.items[2].min);
}

test "decodeExports: single func export" {
    // count=1, name "main" (len=4), desc=func(0), idx=0
    const body = [_]u8{ 0x01, 0x04, 0x6D, 0x61, 0x69, 0x6E, 0x00, 0x00 };
    var ex = try decodeExports(testing.allocator, &body);
    defer ex.deinit();
    try testing.expectEqual(@as(usize, 1), ex.items.len);
    try testing.expectEqualStrings("main", ex.items[0].name);
    try testing.expectEqual(ExportDesc.func, ex.items[0].kind);
    try testing.expectEqual(@as(u32, 0), ex.items[0].idx);
}

test "decodeExports: empty section" {
    var ex = try decodeExports(testing.allocator, &[_]u8{0x00});
    defer ex.deinit();
    try testing.expectEqual(@as(usize, 0), ex.items.len);
}

test "decodeExports: rejects unknown desc kind" {
    const body = [_]u8{ 0x01, 0x01, 0x61, 0x05, 0x00 };
    try testing.expectError(Error.BadValType, decodeExports(testing.allocator, &body));
}
