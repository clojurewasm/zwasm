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
        for (params) |*p| p.* = try init_expr.readValType(body, &pos);

        const result_count = try leb128.readUleb128(u32, body, &pos);
        const results = try alloc.alloc(ValType, result_count);
        for (results) |*r| r.* = try init_expr.readValType(body, &pos);

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
        if (pos >= body.len) return Error.UnexpectedEnd;
        const reftype_byte = body[pos];
        pos += 1;
        const elem_type: ValType = switch (reftype_byte) {
            0x70 => .funcref,
            0x6F => .externref,
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

    for (items) |*e| {
        const name_len = try leb128.readUleb128(u32, body, &pos);
        if (pos + name_len > body.len) return Error.UnexpectedEnd;
        const name_copy = try alloc.dupe(u8, body[pos .. pos + name_len]);
        pos += name_len;

        if (pos >= body.len) return Error.UnexpectedEnd;
        const kind_byte = body[pos];
        pos += 1;
        if (kind_byte > 3) return Error.BadValType;
        const kind: ExportDesc = @enumFromInt(kind_byte);

        const idx = try leb128.readUleb128(u32, body, &pos);
        e.* = .{ .name = name_copy, .kind = kind, .idx = idx };
    }
    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
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
    // 0x6E is unassigned in the Wasm 2.0 valtype space; must be
    // rejected.
    const body = [_]u8{ 0x01, 0x60, 0x01, 0x6E, 0x00 };
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
