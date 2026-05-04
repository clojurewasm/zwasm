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

const leb128 = @import("../support/leb128.zig");
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
    table: struct { elem_type: ValType, min: u32, max: ?u32 },
    memory: struct { min: u32, max: ?u32 },
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
                const limits = try readLimits(body, &pos);
                break :blk .{ .memory = .{ .min = limits.min, .max = limits.max } };
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

pub const DataKind = enum { active, passive };

/// One Wasm memory's limits. v0.1.0 only allows one memory per
/// module (`memidx == 0`); multi-memory is post-v0.1.0.
pub const MemoryEntry = struct {
    /// Initial size in 64 KiB pages (§5.5.5 / §5.4.4).
    min: u32,
    /// Optional upper bound in pages.
    max: ?u32 = null,
};

pub const Memories = struct {
    arena: std.heap.ArenaAllocator,
    items: []MemoryEntry,

    pub fn deinit(self: *Memories) void {
        self.arena.deinit();
    }
};

/// Decode the body of a memory section (`SectionId.memory`):
///   memorysec = vec(memtype)
///   memtype   = limits
///   limits    = 0x00 n:uleb128             (min only)
///             | 0x01 n:uleb128 m:uleb128   (min + max)
pub fn decodeMemory(parent_alloc: Allocator, body: []const u8) Error!Memories {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(MemoryEntry, count);
    for (items) |*entry| {
        if (pos >= body.len) return Error.UnexpectedEnd;
        const flag = body[pos];
        pos += 1;
        const min = try leb128.readUleb128(u32, body, &pos);
        switch (flag) {
            0x00 => entry.* = .{ .min = min },
            0x01 => {
                const max = try leb128.readUleb128(u32, body, &pos);
                entry.* = .{ .min = min, .max = max };
            },
            else => return Error.BadValType,
        }
    }
    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

pub const DataSegment = struct {
    kind: DataKind,
    /// memidx for active segments (kind 0/2). Always 0 in chunk 4b
    /// since multi-memory is post-v0.1.0.
    memidx: u32 = 0,
    /// Init-expression bytes for active segments (terminated by the
    /// trailing `end`). Empty for passive. Borrowed from the input.
    offset_expr: []const u8 = &.{},
    /// The actual data bytes. Borrowed from the input.
    bytes: []const u8,
};

pub const Datas = struct {
    arena: std.heap.ArenaAllocator,
    items: []DataSegment,

    pub fn deinit(self: *Datas) void {
        self.arena.deinit();
    }
};

/// Decode the body of a data section (`SectionId.data`):
///   vec(data), data has three forms (Wasm 2.0 §5.5.13):
///     0x00 expr bytes               — active, memidx 0
///     0x01 bytes                    — passive
///     0x02 memidx expr bytes        — active, explicit memidx
/// `bytes` is `vec(byte)` = uleb size + raw bytes. `expr` is the
/// init-expression terminated by 0x0B.
///
/// Multi-memory (form 0x02 with non-zero memidx) is post-v0.1.0;
/// chunk 4b accepts memidx but does not require it to be 0.
pub fn decodeData(parent_alloc: Allocator, body: []const u8) Error!Datas {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var pos: usize = 0;
    const count = try leb128.readUleb128(u32, body, &pos);
    const items = try alloc.alloc(DataSegment, count);

    for (items) |*d| {
        const flag = try leb128.readUleb128(u32, body, &pos);
        switch (flag) {
            0 => {
                const expr_start = pos;
                while (pos < body.len and body[pos] != 0x0B) pos += 1;
                if (pos >= body.len) return Error.UnexpectedEnd;
                pos += 1; // consume the trailing end
                const expr = body[expr_start..pos];
                const size = try leb128.readUleb128(u32, body, &pos);
                const size_us: usize = @intCast(size);
                if (size_us > body.len - pos) return Error.UnexpectedEnd;
                d.* = .{
                    .kind = .active,
                    .memidx = 0,
                    .offset_expr = expr,
                    .bytes = body[pos .. pos + size_us],
                };
                pos += size_us;
            },
            1 => {
                const size = try leb128.readUleb128(u32, body, &pos);
                const size_us: usize = @intCast(size);
                if (size_us > body.len - pos) return Error.UnexpectedEnd;
                d.* = .{
                    .kind = .passive,
                    .bytes = body[pos .. pos + size_us],
                };
                pos += size_us;
            },
            2 => {
                const memidx = try leb128.readUleb128(u32, body, &pos);
                const expr_start = pos;
                while (pos < body.len and body[pos] != 0x0B) pos += 1;
                if (pos >= body.len) return Error.UnexpectedEnd;
                pos += 1;
                const expr = body[expr_start..pos];
                const size = try leb128.readUleb128(u32, body, &pos);
                const size_us: usize = @intCast(size);
                if (size_us > body.len - pos) return Error.UnexpectedEnd;
                d.* = .{
                    .kind = .active,
                    .memidx = memidx,
                    .offset_expr = expr,
                    .bytes = body[pos .. pos + size_us],
                };
                pos += size_us;
            },
            else => return Error.InvalidFunctype, // reused: bad flag byte
        }
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

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

/// Decode the body of an element section (Wasm 2.0 §5.5.12).
/// Supports all 8 forms (0–7) per ADR-0014 §2.1 / 6.K.4. Forms
/// 0/1/3/4 ship in chunk 5d-2; 2/5/6/7 land in 6.K.4. Funcref is
/// the only supported reftype in v0.1.0; externref defers to a
/// follow-up row when the externref test corpus arrives.
pub fn decodeElement(parent_alloc: Allocator, body: []const u8) Error!Elements {
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
                while (pos < body.len and body[pos] != 0x0B) pos += 1;
                if (pos >= body.len) return Error.UnexpectedEnd;
                pos += 1;
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
                if (pos >= body.len) return Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try leb128.readUleb128(u32, body, &pos);
                e.* = .{ .kind = .passive, .elem_type = .funcref, .funcidxs = funcs };
            },
            3 => {
                if (pos >= body.len) return Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return Error.InvalidFunctype;
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
                while (pos < body.len and body[pos] != 0x0B) pos += 1;
                if (pos >= body.len) return Error.UnexpectedEnd;
                pos += 1;
                const expr = body[expr_start..pos];
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos);
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
                while (pos < body.len and body[pos] != 0x0B) pos += 1;
                if (pos >= body.len) return Error.UnexpectedEnd;
                pos += 1;
                const expr = body[expr_start..pos];
                if (pos >= body.len) return Error.UnexpectedEnd;
                const elemkind = body[pos];
                pos += 1;
                if (elemkind != 0x00) return Error.InvalidFunctype;
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
                if (pos >= body.len) return Error.UnexpectedEnd;
                const reftype = body[pos];
                pos += 1;
                if (reftype != 0x70) return Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos);
                e.* = .{ .kind = .passive, .elem_type = .funcref, .funcidxs = funcs };
            },
            6 => {
                // active, explicit tableidx, offset_expr, reftype,
                // vec(reftype-expr).
                const tableidx = try leb128.readUleb128(u32, body, &pos);
                const expr_start = pos;
                while (pos < body.len and body[pos] != 0x0B) pos += 1;
                if (pos >= body.len) return Error.UnexpectedEnd;
                pos += 1;
                const expr = body[expr_start..pos];
                if (pos >= body.len) return Error.UnexpectedEnd;
                const reftype = body[pos];
                pos += 1;
                if (reftype != 0x70) return Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos);
                e.* = .{
                    .kind = .active,
                    .tableidx = tableidx,
                    .offset_expr = expr,
                    .elem_type = .funcref,
                    .funcidxs = funcs,
                };
            },
            7 => {
                // declarative, reftype, vec(reftype-expr).
                if (pos >= body.len) return Error.UnexpectedEnd;
                const reftype = body[pos];
                pos += 1;
                if (reftype != 0x70) return Error.InvalidFunctype;
                const n = try leb128.readUleb128(u32, body, &pos);
                const funcs = try alloc.alloc(u32, n);
                for (funcs) |*f| f.* = try readFuncrefInitExpr(body, &pos);
                e.* = .{ .kind = .declarative, .elem_type = .funcref, .funcidxs = funcs };
            },
            else => return Error.InvalidFunctype,
        }
    }

    if (pos != body.len) return Error.TrailingBytes;
    return .{ .arena = arena, .items = items };
}

/// Decode one funcref init expression appearing in element-section
/// form 4 / 6: either `ref.func F; end` (0xD2 LEB128(F) 0x0B) or
/// `ref.null funcref; end` (0xD0 0x70 0x0B). Returns the funcidx
/// or `std.math.maxInt(u32)` for null.
fn readFuncrefInitExpr(body: []const u8, pos: *usize) Error!u32 {
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    const op = body[pos.*];
    pos.* += 1;
    const idx: u32 = switch (op) {
        0xD2 => try leb128.readUleb128(u32, body, pos),
        0xD0 => blk: {
            if (pos.* >= body.len) return Error.UnexpectedEnd;
            if (body[pos.*] != 0x70) return Error.BadValType;
            pos.* += 1;
            break :blk std.math.maxInt(u32);
        },
        else => return Error.InvalidFunctype,
    };
    if (pos.* >= body.len) return Error.UnexpectedEnd;
    if (body[pos.*] != 0x0B) return Error.InvalidFunctype;
    pos.* += 1;
    return idx;
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

test "decodeData: empty section" {
    var d = try decodeData(testing.allocator, &[_]u8{0x00});
    defer d.deinit();
    try testing.expectEqual(@as(usize, 0), d.items.len);
}

test "decodeData: single active segment with i32.const 0 offset + 3 bytes" {
    // count=1; flag=0; offset_expr = 0x41 0x00 0x0B; size=3; bytes=AA BB CC
    const body = [_]u8{
        0x01,
        0x00,
        0x41, 0x00, 0x0B,
        0x03,
        0xAA, 0xBB, 0xCC,
    };
    var d = try decodeData(testing.allocator, &body);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 1), d.items.len);
    try testing.expectEqual(DataKind.active, d.items[0].kind);
    try testing.expectEqual(@as(u32, 0), d.items[0].memidx);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x00, 0x0B }, d.items[0].offset_expr);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, d.items[0].bytes);
}

test "decodeData: single passive segment with 4 bytes" {
    // count=1; flag=1; size=4; bytes
    const body = [_]u8{ 0x01, 0x01, 0x04, 0x11, 0x22, 0x33, 0x44 };
    var d = try decodeData(testing.allocator, &body);
    defer d.deinit();
    try testing.expectEqual(@as(usize, 1), d.items.len);
    try testing.expectEqual(DataKind.passive, d.items[0].kind);
    try testing.expectEqualSlices(u8, &[_]u8{}, d.items[0].offset_expr);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44 }, d.items[0].bytes);
}

test "decodeData: active form 2 with explicit memidx" {
    // count=1; flag=2; memidx=0; offset_expr = 0x41 0x10 0x0B; size=2; bytes
    const body = [_]u8{
        0x01,
        0x02,
        0x00,
        0x41, 0x10, 0x0B,
        0x02,
        0xDE, 0xAD,
    };
    var d = try decodeData(testing.allocator, &body);
    defer d.deinit();
    try testing.expectEqual(DataKind.active, d.items[0].kind);
    try testing.expectEqual(@as(u32, 0), d.items[0].memidx);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xDE, 0xAD }, d.items[0].bytes);
}

test "decodeData: rejects unknown flag byte" {
    const body = [_]u8{ 0x01, 0x05 };
    try testing.expectError(Error.InvalidFunctype, decodeData(testing.allocator, &body));
}

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
        0x41, 0x05, 0x0B,
        0x02,
        0x00, 0x01,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.active, e.items[0].kind);
    try testing.expectEqual(@as(u32, 0), e.items[0].tableidx);
    try testing.expectEqualSlices(u32, &[_]u32{ 0, 1 }, e.items[0].funcidxs);
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
        0x41, 0x00, 0x0B,
        0x00,
        0x02, 0x00, 0x01,
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
        0xD2, 0x07, 0x0B,
        0xD0, 0x70, 0x0B,
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
        0x41, 0x04, 0x0B,
        0x70,
        0x01,
        0xD2, 0x03, 0x0B,
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
        0xD2, 0x00, 0x0B,
    };
    var e = try decodeElement(testing.allocator, &body);
    defer e.deinit();
    try testing.expectEqual(ElementKind.declarative, e.items[0].kind);
    try testing.expectEqual(ValType.funcref, e.items[0].elem_type);
    try testing.expectEqualSlices(u32, &[_]u32{0}, e.items[0].funcidxs);
}

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

test "decodeMemory: min only + min/max forms" {
    // count=2; entry 0 = (min 1); entry 1 = (min 2 max 3)
    const body = [_]u8{ 0x02, 0x00, 0x01, 0x01, 0x02, 0x03 };
    var m = try decodeMemory(testing.allocator, &body);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.items.len);
    try testing.expectEqual(@as(u32, 1), m.items[0].min);
    try testing.expect(m.items[0].max == null);
    try testing.expectEqual(@as(u32, 2), m.items[1].min);
    try testing.expectEqual(@as(u32, 3), m.items[1].max.?);
}

test "decodeMemory: rejects unknown limits flag" {
    const body = [_]u8{ 0x01, 0x05, 0x01 };
    try testing.expectError(Error.BadValType, decodeMemory(testing.allocator, &body));
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
