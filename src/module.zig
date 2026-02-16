// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Wasm binary module decoder — parses sections 0-12.
//!
//! Design: no intermediate representation (no Rr). Code bodies and init
//! expressions are stored as raw bytecode slices that the VM interprets
//! directly. This saves ~500 LOC vs zware's Rr approach.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;

// ============================================================
// Module types
// ============================================================

/// Function signature.
pub const FuncType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// Storage type for struct/array fields (GC proposal).
pub const StorageType = union(enum) {
    val: ValType,
    i8, // packed 0x78
    i16, // packed 0x77
};

/// Field type for struct/array (GC proposal).
pub const FieldType = struct {
    storage: StorageType,
    mutable: bool, // false = const, true = var
};

/// Struct composite type (GC proposal).
pub const StructType = struct {
    fields: []const FieldType,
};

/// Array composite type (GC proposal).
pub const ArrayType = struct {
    field: FieldType,
};

/// Composite type: func, struct, or array (GC proposal).
pub const CompositeType = union(enum) {
    func: FuncType,
    struct_type: StructType,
    array_type: ArrayType,
};

/// Type definition with subtyping info (GC proposal).
pub const TypeDef = struct {
    composite: CompositeType,
    super_types: []const u32 = &.{}, // subtyping parents
    is_final: bool = true, // sub final by default

    /// Convenience: get FuncType if this is a func composite type.
    pub fn getFunc(self: TypeDef) ?FuncType {
        return switch (self.composite) {
            .func => |f| f,
            else => null,
        };
    }
};

/// Import descriptor.
pub const Import = struct {
    module: []const u8,
    name: []const u8,
    kind: opcode.ExternalKind,
    /// For func: type index. For table/memory/global: encoded inline.
    index: u32,
    // Table/memory/global inline data (only used when kind != func)
    table_type: ?TableDef = null,
    memory_type: ?MemoryDef = null,
    global_type: ?GlobalDef = null,
};

/// Export descriptor.
pub const Export = struct {
    name: []const u8,
    kind: opcode.ExternalKind,
    index: u32,
};

/// Function section entry — maps to a type index.
pub const FunctionDef = struct {
    type_idx: u32,
};

/// Table definition.
pub const TableDef = struct {
    reftype: opcode.RefType,
    limits: opcode.Limits,
    init_expr: ?[]const u8 = null, // table init expression (function-references proposal)
};

/// Memory definition.
pub const MemoryDef = struct {
    limits: opcode.Limits,
};

/// Global definition.
pub const GlobalDef = struct {
    valtype: ValType,
    mutability: u8, // 0 = immutable, 1 = mutable
    init_expr: []const u8, // raw bytecode of init expression
};

/// Tag definition (exception handling proposal).
pub const TagDef = struct {
    type_idx: u32,
};

/// Branch hint from metadata.code.branch_hint custom section (Wasm 3.0).
pub const BranchHint = struct {
    func_idx: u32,
    byte_offset: u32,
    hint: u8, // 0 = likely NOT taken, 1 = likely taken
};

/// Local variable definition within a code body.
pub const LocalEntry = struct {
    count: u32,
    valtype: ValType,
};

/// Code section entry — a function body.
pub const Code = struct {
    locals: []const LocalEntry,
    body: []const u8, // raw Wasm bytecode (up to but not including final `end`)
    locals_count: u32, // total number of locals (sum of all LocalEntry.count)
};

/// Element segment.
pub const ElementSegment = struct {
    mode: ElementMode,
    reftype: opcode.RefType,
    init: ElementInit,
};

pub const ElementMode = union(enum) {
    passive,
    active: struct { table_idx: u32, offset_expr: []const u8 },
    declarative,
};

pub const ElementInit = union(enum) {
    func_indices: []const u32,
    expressions: []const []const u8,
};

/// Data segment.
pub const DataSegment = struct {
    mode: DataMode,
    data: []const u8,
};

pub const DataMode = union(enum) {
    passive,
    active: struct { mem_idx: u32, offset_expr: []const u8 },
};

// ============================================================
// Module
// ============================================================

/// Rec group range: [start, start+count) in the types array.
pub const RecGroup = struct {
    start: u32,
    count: u32,
};

pub const Module = struct {
    alloc: Allocator,
    wasm_bin: []const u8,
    decoded: bool,

    // Decoded sections
    types: ArrayList(TypeDef),
    rec_groups: ArrayList(RecGroup),
    canonical_ids: []u32,
    imports: ArrayList(Import),
    functions: ArrayList(FunctionDef),
    tables: ArrayList(TableDef),
    memories: ArrayList(MemoryDef),
    globals: ArrayList(GlobalDef),
    tags: ArrayList(TagDef),
    exports: ArrayList(Export),
    start: ?u32,
    elements: ArrayList(ElementSegment),
    codes: ArrayList(Code),
    datas: ArrayList(DataSegment),
    data_count: ?u32,
    branch_hints: ArrayList(BranchHint),

    // Derived counts
    num_imported_funcs: u32,
    num_imported_tables: u32,
    num_imported_memories: u32,
    num_imported_globals: u32,
    num_imported_tags: u32,

    pub fn init(alloc: Allocator, wasm_bin: []const u8) Module {
        return .{
            .alloc = alloc,
            .wasm_bin = wasm_bin,
            .decoded = false,
            .types = .empty,
            .rec_groups = .empty,
            .canonical_ids = &.{},
            .imports = .empty,
            .functions = .empty,
            .tables = .empty,
            .memories = .empty,
            .globals = .empty,
            .tags = .empty,
            .exports = .empty,
            .start = null,
            .elements = .empty,
            .codes = .empty,
            .datas = .empty,
            .data_count = null,
            .branch_hints = .empty,
            .num_imported_funcs = 0,
            .num_imported_tables = 0,
            .num_imported_memories = 0,
            .num_imported_globals = 0,
            .num_imported_tags = 0,
        };
    }

    pub fn deinit(self: *Module) void {
        for (self.types.items) |td| {
            switch (td.composite) {
                .func => |ft| {
                    self.alloc.free(ft.params);
                    self.alloc.free(ft.results);
                },
                .struct_type => |st| self.alloc.free(st.fields),
                .array_type => {},
            }
            if (td.super_types.len > 0) self.alloc.free(td.super_types);
        }
        self.types.deinit(self.alloc);
        self.rec_groups.deinit(self.alloc);
        if (self.canonical_ids.len > 0) self.alloc.free(self.canonical_ids);

        self.imports.deinit(self.alloc);
        self.functions.deinit(self.alloc);
        self.tables.deinit(self.alloc);
        self.memories.deinit(self.alloc);

        for (self.globals.items) |g| _ = g; // init_expr is a slice into wasm_bin
        self.globals.deinit(self.alloc);

        self.tags.deinit(self.alloc);

        self.exports.deinit(self.alloc);

        for (self.elements.items) |es| {
            switch (es.init) {
                .func_indices => |fi| self.alloc.free(fi),
                .expressions => |exprs| self.alloc.free(exprs),
            }
        }
        self.elements.deinit(self.alloc);

        for (self.codes.items) |c| self.alloc.free(c.locals);
        self.codes.deinit(self.alloc);

        self.datas.deinit(self.alloc);
        self.branch_hints.deinit(self.alloc);
    }

    pub fn decode(self: *Module) !void {
        if (self.wasm_bin.len < 8) return error.InvalidWasm;

        // Verify magic and version
        if (!mem.eql(u8, self.wasm_bin[0..4], &opcode.MAGIC))
            return error.InvalidWasm;
        if (!mem.eql(u8, self.wasm_bin[4..8], &opcode.VERSION))
            return error.InvalidWasm;

        var reader = Reader.init(self.wasm_bin[8..]);
        var last_section_id: u8 = 0;

        while (reader.hasMore()) {
            try self.decodeSection(&reader, &last_section_id);
        }

        // Verify function/code count consistency
        if (self.functions.items.len != self.codes.items.len)
            return error.FunctionCodeMismatch;

        // Verify data count matches actual data section count
        if (self.data_count) |dc| {
            if (dc != self.datas.items.len) return error.MalformedModule;
        }

        // Validate start function index
        if (self.start) |start_idx| {
            const total_funcs = self.num_imported_funcs + self.functions.items.len;
            if (start_idx >= total_funcs) return error.InvalidWasm;
        }

        self.decoded = true;
    }

    fn decodeSection(self: *Module, reader: *Reader, last_section_id: *u8) !void {
        const section_id = try reader.readByte();
        const section_size = try reader.readU32();
        var sub = try reader.subReader(section_size);

        // Non-custom sections must appear in order, at most once
        // Binary order: 1,2,3,4,5,6,7,8,9,12,10,11 (data_count before code)
        // Tag section (13, exception handling) has flexible placement — only check no duplicates
        if (section_id != 0 and section_id != 13) {
            const order = sectionOrder(section_id);
            if (order <= last_section_id.*) {
                return error.MalformedModule;
            }
            last_section_id.* = order;
        }

        const section: opcode.Section = @enumFromInt(section_id);
        switch (section) {
            .custom => try self.decodeCustomSection(&sub),
            .type => try self.decodeTypeSection(&sub),
            .import => try self.decodeImportSection(&sub),
            .function => try self.decodeFunctionSection(&sub),
            .table => try self.decodeTableSection(&sub),
            .memory => try self.decodeMemorySection(&sub),
            .global => try self.decodeGlobalSection(&sub),
            .@"export" => try self.decodeExportSection(&sub),
            .start => try self.decodeStartSection(&sub),
            .element => try self.decodeElementSection(&sub),
            .code => try self.decodeCodeSection(&sub),
            .data => try self.decodeDataSection(&sub),
            .data_count => try self.decodeDataCountSection(&sub),
            .tag => try self.decodeTagSection(&sub),
            _ => {
                return error.MalformedModule;
            },
        }

        // Verify section consumed exactly the declared size (custom sections may have trailing data)
        if (section != .custom and sub.hasMore()) {
            return error.MalformedModule;
        }
    }

    // ---- Section 1: Type ----
    fn decodeTypeSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.types.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const form = try reader.readByte();
            if (form == 0x4E) {
                // rec group: 0x4E count subtype*
                const rec_count = try reader.readU32();
                const group_start: u32 = @intCast(self.types.items.len);
                try self.types.ensureTotalCapacity(self.alloc, self.types.items.len + rec_count);
                for (0..rec_count) |_| {
                    try self.decodeSubType(reader);
                }
                try self.rec_groups.append(self.alloc, .{ .start = group_start, .count = rec_count });
            } else {
                // Single type definition (may be sub/sub-final or bare composite)
                const group_start: u32 = @intCast(self.types.items.len);
                try self.decodeSubTypeWithForm(reader, form);
                try self.rec_groups.append(self.alloc, .{ .start = group_start, .count = 1 });
            }
        }

        // Canonicalize types: assign canonical IDs so structurally identical
        // rec groups get the same IDs (needed for call_indirect type matching).
        try self.canonicalizeTypes();
    }

    /// Assign canonical type IDs. Structurally identical rec groups get the
    /// same canonical IDs, enabling O(1) type matching in call_indirect.
    fn canonicalizeTypes(self: *Module) !void {
        const n = self.types.items.len;
        if (n == 0) return;
        self.canonical_ids = try self.alloc.alloc(u32, n);

        // For each rec group, check if a previous group has the same structure.
        // If so, reuse its canonical IDs. Otherwise, assign self as canonical.
        for (self.rec_groups.items) |group| {
            var matched = false;
            for (self.rec_groups.items) |prev| {
                if (prev.start >= group.start) break; // only look at earlier groups
                if (prev.count != group.count) continue;
                if (self.recGroupsEqual(group, prev)) {
                    // Map this group's types to prev group's canonical IDs
                    for (0..group.count) |i| {
                        self.canonical_ids[group.start + i] = self.canonical_ids[prev.start + i];
                    }
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                // Self-canonical: each type maps to its own index
                for (0..group.count) |i| {
                    self.canonical_ids[group.start + i] = group.start + @as(u32, @intCast(i));
                }
            }
        }
    }

    /// Check if two rec groups are structurally equivalent.
    fn recGroupsEqual(self: *const Module, a: RecGroup, b: RecGroup) bool {
        if (a.count != b.count) return false;
        for (0..a.count) |i| {
            if (!self.typeDefsCanonEqual(
                a.start + @as(u32, @intCast(i)),
                b.start + @as(u32, @intCast(i)),
                a,
                b,
            )) return false;
        }
        return true;
    }

    /// Check if two TypeDefs are structurally equivalent with canonical resolution.
    fn typeDefsCanonEqual(self: *const Module, idx_a: u32, idx_b: u32, grp_a: RecGroup, grp_b: RecGroup) bool {
        const ta = self.types.items[idx_a];
        const tb = self.types.items[idx_b];
        if (ta.is_final != tb.is_final) return false;
        if (ta.super_types.len != tb.super_types.len) return false;
        for (ta.super_types, tb.super_types) |sa, sb| {
            if (self.canonRef(sa, grp_a) != self.canonRef(sb, grp_b)) return false;
        }
        return self.compositeCanonEqual(ta.composite, tb.composite, grp_a, grp_b);
    }

    /// Check if two composite types are structurally equivalent.
    fn compositeCanonEqual(self: *const Module, a: CompositeType, b: CompositeType, grp_a: RecGroup, grp_b: RecGroup) bool {
        switch (a) {
            .func => |fa| {
                const fb = switch (b) {
                    .func => |f| f,
                    else => return false,
                };
                return self.valTypeSliceCanonEqual(fa.params, fb.params, grp_a, grp_b) and
                    self.valTypeSliceCanonEqual(fa.results, fb.results, grp_a, grp_b);
            },
            .struct_type => |sa| {
                const sb = switch (b) {
                    .struct_type => |s| s,
                    else => return false,
                };
                if (sa.fields.len != sb.fields.len) return false;
                for (sa.fields, sb.fields) |fa, fb| {
                    if (fa.mutable != fb.mutable) return false;
                    if (!self.storageCanonEqual(fa.storage, fb.storage, grp_a, grp_b)) return false;
                }
                return true;
            },
            .array_type => |aa| {
                const ab = switch (b) {
                    .array_type => |arr| arr,
                    else => return false,
                };
                if (aa.field.mutable != ab.field.mutable) return false;
                return self.storageCanonEqual(aa.field.storage, ab.field.storage, grp_a, grp_b);
            },
        }
    }

    fn storageCanonEqual(self: *const Module, a: StorageType, b: StorageType, grp_a: RecGroup, grp_b: RecGroup) bool {
        switch (a) {
            .i8 => return b == .i8,
            .i16 => return b == .i16,
            .val => |va| {
                const vb = switch (b) {
                    .val => |v| v,
                    else => return false,
                };
                return self.valTypeCanonEqual(va, vb, grp_a, grp_b);
            },
        }
    }

    fn valTypeSliceCanonEqual(self: *const Module, a: []const ValType, b: []const ValType, grp_a: RecGroup, grp_b: RecGroup) bool {
        if (a.len != b.len) return false;
        for (a, b) |va, vb| {
            if (!self.valTypeCanonEqual(va, vb, grp_a, grp_b)) return false;
        }
        return true;
    }

    fn valTypeCanonEqual(self: *const Module, a: ValType, b: ValType, grp_a: RecGroup, grp_b: RecGroup) bool {
        const tag_a: @typeInfo(ValType).@"union".tag_type.? = a;
        const tag_b: @typeInfo(ValType).@"union".tag_type.? = b;
        if (tag_a != tag_b) return false;
        return switch (a) {
            .i32, .i64, .f32, .f64, .v128, .funcref, .externref, .exnref => true,
            .ref_type => |idx_a| self.canonRef(idx_a, grp_a) == self.canonRef(b.ref_type, grp_b),
            .ref_null_type => |idx_a| self.canonRef(idx_a, grp_a) == self.canonRef(b.ref_null_type, grp_b),
        };
    }

    /// Canonicalize a type reference: intra-group refs become relative offsets
    /// (with high bit set to distinguish from canonical IDs), cross-group refs
    /// become their previously-assigned canonical ID.
    fn canonRef(self: *const Module, idx: u32, grp: RecGroup) u32 {
        // Abstract heap type codes (≥ 0x69) are not type indices
        if (idx >= 0x69) return idx;
        // Intra-group reference: use relative offset with marker bit
        if (idx >= grp.start and idx < grp.start + grp.count) {
            return 0x80000000 | (idx - grp.start);
        }
        // Cross-group reference: use already-computed canonical ID
        return self.canonical_ids[idx];
    }

    fn decodeSubType(self: *Module, reader: *Reader) !void {
        const form = try reader.readByte();
        try self.decodeSubTypeWithForm(reader, form);
    }

    fn decodeSubTypeWithForm(self: *Module, reader: *Reader, form: u8) !void {
        var is_final: bool = true;
        var super_types: []const u32 = &.{};

        if (form == 0x50 or form == 0x4F) {
            // 0x50 = sub (non-final), 0x4F = sub final
            is_final = (form == 0x4F);
            const super_count = try reader.readU32();
            if (super_count > 0) {
                const supers = try self.alloc.alloc(u32, super_count);
                for (supers) |*s| s.* = try reader.readU32();
                super_types = supers;
            }
            // Read the composite type tag
            const comp_form = try reader.readByte();
            const composite = try self.decodeCompositeType(reader, comp_form);
            try self.types.append(self.alloc, .{
                .composite = composite,
                .super_types = super_types,
                .is_final = is_final,
            });
        } else {
            // Bare composite type (implicitly final, no supertypes)
            const composite = try self.decodeCompositeType(reader, form);
            try self.types.append(self.alloc, .{
                .composite = composite,
            });
        }
    }

    fn decodeCompositeType(self: *Module, reader: *Reader, form: u8) !CompositeType {
        return switch (form) {
            0x60 => .{ .func = try self.decodeFuncType(reader) },
            0x5F => .{ .struct_type = try self.decodeStructType(reader) },
            0x5E => .{ .array_type = try self.decodeArrayType(reader) },
            else => error.InvalidWasm,
        };
    }

    fn decodeFuncType(self: *Module, reader: *Reader) !FuncType {
        const param_count = try reader.readU32();
        const params = try self.alloc.alloc(ValType, param_count);
        errdefer self.alloc.free(params);
        for (params) |*p| p.* = try ValType.readValType(reader);

        const result_count = try reader.readU32();
        const results = try self.alloc.alloc(ValType, result_count);
        errdefer self.alloc.free(results);
        for (results) |*r| r.* = try ValType.readValType(reader);

        return .{ .params = params, .results = results };
    }

    fn decodeStructType(self: *Module, reader: *Reader) !StructType {
        const field_count = try reader.readU32();
        const fields = try self.alloc.alloc(FieldType, field_count);
        errdefer self.alloc.free(fields);
        for (fields) |*f| f.* = try decodeFieldType(reader);
        return .{ .fields = fields };
    }

    fn decodeArrayType(_: *Module, reader: *Reader) !ArrayType {
        const field = try decodeFieldType(reader);
        return .{ .field = field };
    }

    /// Get FuncType by type index (returns null if not a func type or out of bounds).
    pub fn getTypeFunc(self: *const Module, type_idx: u32) ?FuncType {
        if (type_idx >= self.types.items.len) return null;
        return self.types.items[type_idx].getFunc();
    }

    /// Get canonical type ID for a type index (for call_indirect matching).
    pub fn getCanonicalTypeId(self: *const Module, type_idx: u32) u32 {
        if (type_idx < self.canonical_ids.len) return self.canonical_ids[type_idx];
        return type_idx;
    }

    /// Check if concrete type `sub` is a subtype of (or equal to) concrete type `super`.
    /// Uses canonical IDs for equivalence, then walks the super_types chain.
    pub fn isTypeSubtype(self: *const Module, sub: u32, super: u32) bool {
        if (sub == super) return true;
        const canon_sub = self.getCanonicalTypeId(sub);
        const canon_super = self.getCanonicalTypeId(super);
        if (canon_sub == canon_super) return true;
        if (sub >= self.types.items.len) return false;
        var current = sub;
        while (true) {
            if (current >= self.types.items.len) return false;
            const td = self.types.items[current];
            if (td.super_types.len == 0) return false;
            current = td.super_types[0];
            if (current == super) return true;
            if (self.getCanonicalTypeId(current) == canon_super) return true;
        }
    }

    /// Check if a function matches the expected call_indirect type.
    /// Uses subtype checking: func's type must be a subtype of the expected type.
    /// Falls back to structural comparison for host/imported functions.
    pub fn matchesCallIndirectType(
        self: *const Module,
        type_idx: u32,
        func_canonical_id: u32,
        func_params: []const ValType,
        func_results: []const ValType,
    ) bool {
        const UNSET = std.math.maxInt(u32);
        if (func_canonical_id != UNSET) {
            // Canonical subtype check — definitive when IDs are available.
            // With GC proposal, structurally identical types can be distinct
            // (e.g., (sub (func)) vs (sub final (func))). Do NOT fall through
            // to structural comparison when canonical check fails.
            return self.isTypeSubtype(func_canonical_id, self.getCanonicalTypeId(type_idx));
        }
        // Structural comparison only for host functions without canonical IDs
        if (self.getTypeFunc(type_idx)) |expected| {
            return ValType.sliceEql(expected.params, func_params) and
                ValType.sliceEql(expected.results, func_results);
        }
        return true;
    }

    // ---- Section 2: Import ----
    fn decodeImportSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.imports.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const mod_len = try reader.readU32();
            const mod_name = try reader.readBytes(mod_len);
            if (!std.unicode.utf8ValidateSlice(mod_name)) return error.MalformedUtf8;
            const name_len = try reader.readU32();
            const name = try reader.readBytes(name_len);
            if (!std.unicode.utf8ValidateSlice(name)) return error.MalformedUtf8;
            const kind_byte = try reader.readByte();
            const kind: opcode.ExternalKind = @enumFromInt(kind_byte);

            var imp = Import{
                .module = mod_name,
                .name = name,
                .kind = kind,
                .index = 0,
            };

            switch (kind) {
                .func => {
                    imp.index = try reader.readU32();
                    self.num_imported_funcs += 1;
                },
                .table => {
                    imp.table_type = try readTableDef(reader);
                    self.num_imported_tables += 1;
                },
                .memory => {
                    imp.memory_type = try readMemoryDef(reader);
                    self.num_imported_memories += 1;
                },
                .global => {
                    imp.global_type = try readGlobalImportDef(reader);
                    self.num_imported_globals += 1;
                },
                .tag => {
                    const attr = try reader.readByte();
                    if (attr != 0) return error.InvalidWasm; // only exception attribute
                    imp.index = try reader.readU32();
                    self.num_imported_tags += 1;
                },
            }

            try self.imports.append(self.alloc, imp);
        }
    }

    // ---- Section 3: Function ----
    fn decodeFunctionSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.functions.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            try self.functions.append(self.alloc, .{ .type_idx = try reader.readU32() });
        }
    }

    // ---- Section 4: Table ----
    fn decodeTableSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.tables.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            try self.tables.append(self.alloc, try readTableDef(reader));
        }
    }

    // ---- Section 5: Memory ----
    fn decodeMemorySection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.memories.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            try self.memories.append(self.alloc, try readMemoryDef(reader));
        }
    }

    // ---- Section 6: Global ----
    fn decodeGlobalSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.globals.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            const valtype: ValType = try ValType.readValType(reader);
            const mutability = try reader.readByte();
            if (mutability > 1) return error.MalformedModule;
            const init_start = reader.pos;
            try skipInitExpr(reader);
            const init_end = reader.pos;

            try self.globals.append(self.alloc, .{
                .valtype = valtype,
                .mutability = mutability,
                .init_expr = reader.bytes[init_start..init_end],
            });
        }
    }

    // ---- Section 13: Tag (exception handling) ----
    fn decodeTagSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.tags.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            const attr = try reader.readByte();
            if (attr != 0) return error.InvalidWasm; // only exception attribute
            const type_idx = try reader.readU32();
            try self.tags.append(self.alloc, .{ .type_idx = type_idx });
        }
    }

    // ---- Section 7: Export ----
    fn decodeExportSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.exports.ensureTotalCapacity(self.alloc, count);
        for (0..count) |_| {
            const name_len = try reader.readU32();
            const name = try reader.readBytes(name_len);
            if (!std.unicode.utf8ValidateSlice(name)) return error.MalformedUtf8;
            const kind: opcode.ExternalKind = @enumFromInt(try reader.readByte());
            const index = try reader.readU32();
            // Check for duplicate export names
            for (self.exports.items) |existing| {
                if (mem.eql(u8, existing.name, name)) return error.DuplicateExport;
            }
            try self.exports.append(self.alloc, .{ .name = name, .kind = kind, .index = index });
        }
    }

    // ---- Section 8: Start ----
    fn decodeStartSection(self: *Module, reader: *Reader) !void {
        self.start = try reader.readU32();
    }

    // ---- Section 9: Element ----
    fn decodeElementSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.elements.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const elem_type = try reader.readU32();
            try self.elements.append(self.alloc, try self.decodeElementSegment(reader, elem_type));
        }
    }

    fn decodeElementSegment(self: *Module, reader: *Reader, elem_type: u32) !ElementSegment {
        switch (elem_type) {
            0 => {
                // Active, table 0, func indices
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .{ .active = .{
                        .table_idx = 0,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            1 => {
                // Passive, elemkind, func indices
                const elemkind = try reader.readByte();
                _ = elemkind; // 0x00 = funcref
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .passive,
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            2 => {
                // Active, explicit table, elemkind, func indices
                const table_idx = try reader.readU32();
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const elemkind = try reader.readByte();
                _ = elemkind;
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .{ .active = .{
                        .table_idx = table_idx,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            3 => {
                // Declarative, elemkind, func indices
                const elemkind = try reader.readByte();
                _ = elemkind;
                const num = try reader.readU32();
                const indices = try self.alloc.alloc(u32, num);
                for (indices) |*idx| idx.* = try reader.readU32();

                return .{
                    .mode = .declarative,
                    .reftype = .funcref,
                    .init = .{ .func_indices = indices },
                };
            },
            4 => {
                // Active, table 0, expressions
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .{ .active = .{
                        .table_idx = 0,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = .funcref,
                    .init = .{ .expressions = exprs },
                };
            },
            5 => {
                // Passive, explicit reftype, expressions
                const reftype = try readRefTypeGC(reader);
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .passive,
                    .reftype = reftype,
                    .init = .{ .expressions = exprs },
                };
            },
            6 => {
                // Active, explicit table + reftype, expressions
                const table_idx = try reader.readU32();
                const offset_start = reader.pos;
                try skipInitExpr(reader);
                const offset_end = reader.pos;
                const reftype = try readRefTypeGC(reader);
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .{ .active = .{
                        .table_idx = table_idx,
                        .offset_expr = reader.bytes[offset_start..offset_end],
                    } },
                    .reftype = reftype,
                    .init = .{ .expressions = exprs },
                };
            },
            7 => {
                // Declarative, explicit reftype, expressions
                const reftype = try readRefTypeGC(reader);
                const num = try reader.readU32();
                const exprs = try self.alloc.alloc([]const u8, num);
                for (exprs) |*expr| {
                    const expr_start = reader.pos;
                    try skipInitExpr(reader);
                    expr.* = reader.bytes[expr_start..reader.pos];
                }

                return .{
                    .mode = .declarative,
                    .reftype = reftype,
                    .init = .{ .expressions = exprs },
                };
            },
            else => return error.InvalidWasm,
        }
    }

    // ---- Section 10: Code ----
    fn decodeCodeSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.codes.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const body_size = try reader.readU32();
            var body_reader = try reader.subReader(body_size);

            // Parse locals
            const num_local_entries = try body_reader.readU32();
            const locals = try self.alloc.alloc(LocalEntry, num_local_entries);
            errdefer self.alloc.free(locals);
            var locals_count: u32 = 0;
            for (locals) |*le| {
                le.count = try body_reader.readU32();
                le.valtype = try ValType.readValType(&body_reader);
                locals_count += le.count;
            }

            // Remaining bytes are the function body (includes trailing `end`)
            const body = body_reader.bytes[body_reader.pos..];

            // Validate: top-level `end` must be the last byte (no trailing bytes)
            try validateBodyEnd(body);

            try self.codes.append(self.alloc, .{
                .locals = locals,
                .body = body,
                .locals_count = locals_count,
            });
        }
    }

    fn skipBlockType(r: *Reader) !void {
        if (!r.hasMore()) return error.MalformedModule;
        const byte = r.bytes[r.pos];
        if (byte == 0x40 or (byte >= 0x69 and byte <= 0x7F)) {
            r.pos += 1;
        } else if (byte == 0x63 or byte == 0x64) {
            // (ref null ht) or (ref ht): skip prefix byte + S33 heap type
            r.pos += 1;
            _ = try r.readI33();
        } else {
            _ = try r.readI33();
        }
    }

    /// Validate that the function body ends with its top-level `end` opcode
    /// and has no trailing bytes. Scans opcodes tracking block depth.
    fn validateBodyEnd(body: []const u8) !void {
        var r = Reader.init(body);
        var depth: u32 = 1; // function body is an implicit block

        while (r.hasMore()) {
            const byte = try r.readByte();
            switch (byte) {
                0x02, 0x03, 0x04 => { // block, loop, if
                    try skipBlockType(&r);
                    depth += 1;
                },
                0x1F => { // try_table
                    try skipBlockType(&r);
                    const n = try r.readU32();
                    for (0..n) |_| {
                        const kind = try r.readByte();
                        if (kind == 0x00 or kind == 0x01) _ = try r.readU32();
                        _ = try r.readU32();
                    }
                    depth += 1;
                },
                0x0B => { // end
                    depth -= 1;
                    if (depth == 0) {
                        if (r.hasMore()) return error.MalformedModule;
                        return;
                    }
                },
                // Skip immediates for all other opcodes
                0x0C, 0x0D => _ = try r.readU32(), // br, br_if
                0x0E => { // br_table
                    const count = try r.readU32();
                    for (0..count + 1) |_| _ = try r.readU32();
                },
                0x10, 0x12, 0x14, 0x15 => _ = try r.readU32(), // call, return_call, call_ref, return_call_ref
                0x11, 0x13 => { _ = try r.readU32(); _ = try r.readU32(); }, // call_indirect, return_call_indirect
                0x08 => _ = try r.readU32(), // throw
                0x1C => { const n = try r.readU32(); for (0..n) |_| _ = try r.readByte(); }, // select_t
                0x20, 0x21, 0x22 => _ = try r.readU32(), // local.get/set/tee
                0x23, 0x24 => _ = try r.readU32(), // global.get/set
                0x25, 0x26 => _ = try r.readU32(), // table.get/set
                0xD2 => _ = try r.readU32(), // ref.func
                0xD5, 0xD6 => _ = try r.readU32(), // br_on_null, br_on_non_null
                0x41 => _ = try r.readI32(), // i32.const
                0x42 => _ = try r.readI64(), // i64.const
                0x43 => r.pos += 4, // f32.const
                0x44 => r.pos += 8, // f64.const
                0x28...0x3E => { // memory load/store
                    const align_flags = try r.readU32();
                    if (align_flags & 0x40 != 0) _ = try r.readU32(); // memidx (multi-memory)
                    _ = try r.readU32(); // offset
                },
                0x3F, 0x40 => _ = try r.readU32(), // memory.size/grow (memidx)
                0xD0 => _ = try r.readI33(), // ref.null (heap type, S33 LEB128)
                0xFC => { // misc prefix
                    const sub = try r.readU32();
                    switch (sub) {
                        0...7 => {}, // trunc_sat
                        8 => { _ = try r.readU32(); _ = try r.readU32(); }, // memory.init (dataidx, memidx)
                        9 => _ = try r.readU32(), // data.drop
                        10 => { _ = try r.readU32(); _ = try r.readU32(); }, // memory.copy (dest_memidx, src_memidx)
                        11 => _ = try r.readU32(), // memory.fill (memidx)
                        12 => { _ = try r.readU32(); _ = try r.readU32(); }, // table.init
                        13 => _ = try r.readU32(), // elem.drop
                        14 => { _ = try r.readU32(); _ = try r.readU32(); }, // table.copy
                        15 => _ = try r.readU32(), // table.grow
                        16 => _ = try r.readU32(), // table.size
                        17 => _ = try r.readU32(), // table.fill
                        else => {},
                    }
                },
                0xFD => { // simd prefix
                    const sub = try r.readU32();
                    if (sub <= 11 or sub == 92 or sub == 93) {
                        // v128.load/store variants (0-11), load32/64_zero (92-93) — memarg
                        const simd_align = try r.readU32();
                        _ = try r.readU32(); // offset
                        if (simd_align & 0x40 != 0) _ = try r.readU32(); // memidx
                    } else if (sub >= 84 and sub <= 91) {
                        // v128.load*_lane (84-87), v128.store*_lane (88-91) — memarg + lane_index
                        const lane_align = try r.readU32();
                        _ = try r.readU32(); // offset
                        if (lane_align & 0x40 != 0) _ = try r.readU32(); // memidx
                        _ = try r.readByte();
                    } else if (sub == 12) {
                        r.pos += 16; // v128.const
                    } else if (sub == 13) {
                        r.pos += 16; // i8x16.shuffle
                    } else if (sub >= 21 and sub <= 34) {
                        _ = try r.readByte(); // extract/replace lane index
                    }
                    // All other SIMD ops have no immediates
                },
                0xFB => { // GC prefix
                    const gc_sub = try r.readU32();
                    switch (gc_sub) {
                        0x00, 0x01 => _ = try r.readU32(), // struct.new/new_default (typeidx)
                        0x02, 0x03, 0x04, 0x05 => { // struct.get/get_s/get_u/set
                            _ = try r.readU32(); // typeidx
                            _ = try r.readU32(); // fieldidx
                        },
                        0x06, 0x07 => _ = try r.readU32(), // array.new/new_default (typeidx)
                        0x08 => { _ = try r.readU32(); _ = try r.readU32(); }, // array.new_fixed (typeidx, N)
                        0x09, 0x0A => { _ = try r.readU32(); _ = try r.readU32(); }, // array.new_data/elem
                        0x0B, 0x0C, 0x0D, 0x0E => _ = try r.readU32(), // array.get/get_s/get_u/set
                        0x0F => {}, // array.len (no immediates)
                        0x10 => _ = try r.readU32(), // array.fill (typeidx)
                        0x11 => { _ = try r.readU32(); _ = try r.readU32(); }, // array.copy
                        0x12, 0x13 => { _ = try r.readU32(); _ = try r.readU32(); }, // array.init_data/elem
                        0x14, 0x15 => _ = try r.readI33(), // ref.test/ref.test_null (heaptype)
                        0x16, 0x17 => _ = try r.readI33(), // ref.cast/ref.cast_null (heaptype)
                        0x18, 0x19 => { // br_on_cast/br_on_cast_fail
                            _ = try r.readByte(); // flags
                            _ = try r.readU32(); // labelidx
                            _ = try r.readI33(); // heaptype1
                            _ = try r.readI33(); // heaptype2
                        },
                        0x1A, 0x1B => {}, // any.convert_extern, extern.convert_any
                        0x1C, 0x1D, 0x1E => {}, // ref.i31, i31.get_s, i31.get_u
                        else => {},
                    }
                },
                0xFE => { // atomic prefix (threads proposal)
                    const atomic_sub = try r.readU32();
                    if (atomic_sub == 0x03) {
                        // atomic.fence: reserved byte 0x00
                        const reserved = try r.readByte();
                        if (reserved != 0x00) return error.MalformedModule;
                    } else {
                        // All other atomic ops have memarg (align + offset)
                        _ = try r.readU32(); // align
                        _ = try r.readU32(); // offset
                    }
                },
                else => {}, // opcodes with no immediates
            }
        }
        // Reached end of body without function-level end
        return error.MalformedModule;
    }

    // ---- Section 11: Data ----
    fn decodeDataSection(self: *Module, reader: *Reader) !void {
        const count = try reader.readU32();
        try self.datas.ensureTotalCapacity(self.alloc, count);

        for (0..count) |_| {
            const data_type = try reader.readU32();
            switch (data_type) {
                0 => {
                    // Active, memory 0
                    const offset_start = reader.pos;
                    try skipInitExpr(reader);
                    const offset_end = reader.pos;
                    const data_len = try reader.readU32();
                    const data = try reader.readBytes(data_len);

                    try self.datas.append(self.alloc, .{
                        .mode = .{ .active = .{
                            .mem_idx = 0,
                            .offset_expr = reader.bytes[offset_start..offset_end],
                        } },
                        .data = data,
                    });
                },
                1 => {
                    // Passive
                    const data_len = try reader.readU32();
                    const data = try reader.readBytes(data_len);

                    try self.datas.append(self.alloc, .{
                        .mode = .passive,
                        .data = data,
                    });
                },
                2 => {
                    // Active, explicit memory
                    const mem_idx = try reader.readU32();
                    const offset_start = reader.pos;
                    try skipInitExpr(reader);
                    const offset_end = reader.pos;
                    const data_len = try reader.readU32();
                    const data = try reader.readBytes(data_len);

                    try self.datas.append(self.alloc, .{
                        .mode = .{ .active = .{
                            .mem_idx = mem_idx,
                            .offset_expr = reader.bytes[offset_start..offset_end],
                        } },
                        .data = data,
                    });
                },
                else => return error.InvalidWasm,
            }
        }
    }

    // ---- Section 12: Data Count ----
    fn decodeDataCountSection(self: *Module, reader: *Reader) !void {
        self.data_count = try reader.readU32();
    }

    // ---- Export lookup helpers ----

    pub fn getExport(self: *const Module, name: []const u8, kind: opcode.ExternalKind) ?u32 {
        for (self.exports.items) |exp| {
            if (exp.kind == kind and mem.eql(u8, exp.name, name))
                return exp.index;
        }
        return null;
    }

    /// Get the FuncType for a function by its function index (imports first, then local).
    pub fn getFuncType(self: *const Module, func_idx: u32) ?FuncType {
        if (func_idx < self.num_imported_funcs) {
            // Imported function
            var import_func_idx: u32 = 0;
            for (self.imports.items) |imp| {
                if (imp.kind == .func) {
                    if (import_func_idx == func_idx) {
                        return self.getTypeFunc(imp.index);
                    }
                    import_func_idx += 1;
                }
            }
            return null;
        } else {
            // Local function
            const local_idx = func_idx - self.num_imported_funcs;
            if (local_idx >= self.functions.items.len) return null;
            const type_idx = self.functions.items[local_idx].type_idx;
            return self.getTypeFunc(type_idx);
        }
    }

    // ---- Custom sections ----

    fn decodeCustomSection(self: *Module, reader: *Reader) !void {
        const name_len = try reader.readU32();
        const name = try reader.readBytes(name_len);
        if (!std.unicode.utf8ValidateSlice(name)) return error.MalformedUtf8;
        if (mem.eql(u8, name, "metadata.code.branch_hint")) {
            try self.decodeBranchHints(reader);
        }
        // All other custom sections are silently ignored.
    }

    /// Parse metadata.code.branch_hint custom section (Wasm 3.0).
    fn decodeBranchHints(self: *Module, reader: *Reader) !void {
        const num_funcs = try reader.readU32();
        for (0..num_funcs) |_| {
            const func_idx = try reader.readU32();
            const num_hints = try reader.readU32();
            for (0..num_hints) |_| {
                const byte_offset = try reader.readU32();
                const size = try reader.readU32();
                if (size != 1) {
                    _ = try reader.readBytes(size);
                    continue;
                }
                const hint = try reader.readByte();
                try self.branch_hints.append(self.alloc, .{
                    .func_idx = func_idx,
                    .byte_offset = byte_offset,
                    .hint = hint,
                });
            }
        }
    }
};

// ============================================================
// Helpers
// ============================================================

fn decodeFieldType(reader: *Reader) !FieldType {
    // Storage type: peek at byte to determine if packed or valtype
    const byte = reader.bytes[reader.pos];
    const storage: StorageType = if (byte == 0x78) blk: {
        reader.pos += 1;
        break :blk .i8;
    } else if (byte == 0x77) blk: {
        reader.pos += 1;
        break :blk .i16;
    } else .{ .val = try ValType.readValType(reader) };
    const mut_byte = try reader.readByte();
    if (mut_byte > 1) return error.InvalidWasm;
    return .{ .storage = storage, .mutable = mut_byte == 1 };
}

/// Read a reftype from binary, supporting GC typed refs (0x63/0x64 prefix)
/// and shorthand abstract heap types (0x6E=anyref, 0x6D=eqref, etc.).
/// Maps non-MVP types to externref as carrier.
fn readRefTypeGC(reader: *Reader) !opcode.RefType {
    const first_byte = try reader.readByte();
    if (first_byte == 0x63 or first_byte == 0x64) {
        // GC typed ref: (ref null ht) or (ref ht) — read heap type
        const ht = try reader.readI33();
        if (ht == -16) return .funcref; // func
        if (ht == -17) return .externref; // extern
        return .externref; // GC heap types — use externref as carrier
    }
    if (first_byte == 0x70) return .funcref;
    if (first_byte == 0x6F) return .externref;
    // GC shorthand reftypes: anyref(0x6E), eqref(0x6D), i31ref(0x6C),
    // structref(0x6B), arrayref(0x6A), exnref(0x69), nullref(0x71), etc.
    return .externref;
}

fn readTableDef(reader: *Reader) !TableDef {
    // Check for function-references encoding: 0x40 0x00 reftype limits init_expr
    if (reader.pos < reader.bytes.len and reader.bytes[reader.pos] == 0x40) {
        _ = try reader.readByte(); // consume 0x40
        _ = try reader.readByte(); // consume flags (0x00)
        const reftype = try readRefTypeGC(reader);
        const limits = try readLimits(reader);
        const init_start = reader.pos;
        try skipInitExpr(reader);
        const init_end = reader.pos;
        return .{ .reftype = reftype, .limits = limits, .init_expr = reader.bytes[init_start..init_end] };
    }
    const reftype = try readRefTypeGC(reader);
    const limits = try readLimits(reader);
    return .{ .reftype = reftype, .limits = limits };
}

fn readMemoryDef(reader: *Reader) !MemoryDef {
    const limits = try readLimits(reader);
    // 32-bit memories: max 65536 pages (4 GiB)
    if (!limits.is_64) {
        if (limits.min > 65536) return error.InvalidWasm;
        if (limits.max) |m| {
            if (m > 65536) return error.InvalidWasm;
        }
    }
    return .{ .limits = limits };
}

/// Map section ID to binary position order.
/// Binary order: 1,2,13,3,4,5,6,7,8,9,12,10,11 (tag after import, data_count before code).
fn sectionOrder(section_id: u8) u8 {
    return switch (section_id) {
        1 => 1, // type
        2 => 2, // import
        13 => 3, // tag (exception handling: between import and function)
        3 => 4, // function
        4 => 5, // table
        5 => 6, // memory
        6 => 7, // global
        7 => 8, // export
        8 => 9, // start
        9 => 10, // element
        12 => 11, // data_count (before code)
        10 => 12, // code
        11 => 13, // data
        else => section_id + 100, // unknown sections get high order
    };
}

fn readGlobalImportDef(reader: *Reader) !GlobalDef {
    const valtype: ValType = try ValType.readValType(reader);
    const mutability = try reader.readByte();
    if (mutability > 1) return error.MalformedModule;
    return .{ .valtype = valtype, .mutability = mutability, .init_expr = &.{} };
}

fn readLimits(reader: *Reader) !opcode.Limits {
    const flags = try reader.readByte();
    // Valid flags: has_max(0x01), shared(0x02), is_64(0x04), page_size(0x08)
    if (flags & 0xF0 != 0) return error.InvalidWasm;
    const is_64 = (flags & 0x04) != 0;
    const has_max = (flags & 0x01) != 0;
    const is_shared = (flags & 0x02) != 0;
    const has_page_size = (flags & 0x08) != 0;
    // Shared memory requires max to be specified
    if (is_shared and !has_max) return error.InvalidWasm;

    // Read min/max first, then page_size exponent (per binary encoding order)
    var min: u64 = undefined;
    var max: ?u64 = null;
    if (is_64) {
        min = try reader.readU64();
        max = if (has_max) try reader.readU64() else null;
    } else {
        min = try reader.readU32();
        const max32: ?u32 = if (has_max) try reader.readU32() else null;
        max = if (max32) |m| m else null;
    }

    var page_size: u32 = 65536;
    if (has_page_size) {
        const p = try reader.readU32();
        // page_size = 2^p; spec only allows p=0 (size=1) or p=16 (size=65536)
        if (p > 16) return error.InvalidWasm;
        page_size = @as(u32, 1) << @intCast(p);
        if (page_size != 1 and page_size != 65536) return error.InvalidWasm;
    }

    // Validate min <= max
    if (max) |m| {
        if (min > m) return error.InvalidWasm;
    }

    return .{ .min = min, .max = max, .is_64 = is_64, .is_shared = is_shared, .page_size = page_size };
}

/// Skip over an init expression (reads until `end` opcode 0x0B).
fn skipInitExpr(reader: *Reader) !void {
    while (true) {
        const byte = try reader.readByte();
        const op: opcode.Opcode = @enumFromInt(byte);
        switch (op) {
            .end => return,
            .i32_const => _ = try reader.readI32(),
            .i64_const => _ = try reader.readI64(),
            .f32_const => _ = try reader.readBytes(4),
            .f64_const => _ = try reader.readBytes(8),
            .global_get => _ = try reader.readU32(),
            .ref_null => _ = try reader.readI33(), // heap type (S33 LEB128)
            .ref_func => _ = try reader.readU32(),
            // Extended constant expressions (Wasm 3.0)
            .i32_add, .i32_sub, .i32_mul,
            .i64_add, .i64_sub, .i64_mul,
            => {},
            // GC prefix — struct/array constructors and conversions in init expressions
            .gc_prefix => {
                const gc_op = try reader.readU32();
                switch (gc_op) {
                    0x00, 0x01, 0x06, 0x07 => _ = try reader.readU32(), // struct.new/default, array.new/default (type_idx)
                    0x08 => { _ = try reader.readU32(); _ = try reader.readU32(); }, // array.new_fixed (type_idx, count)
                    0x1A, 0x1B, 0x1C => {}, // any.convert_extern, extern.convert_any, ref.i31
                    else => return error.InvalidWasm,
                }
            },
            // SIMD prefix — v128.const (0xFD 0x0C) in init expressions
            .simd_prefix => {
                const simd_op = try reader.readU32();
                if (simd_op == 0x0C) { // v128.const
                    _ = try reader.readBytes(16);
                } else {
                    return error.InvalidWasm;
                }
            },
            else => return error.InvalidWasm,
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Read a wasm test file at runtime (avoids @embedFile package path issues).
fn readTestFile(alloc: Allocator, name: []const u8) ![]const u8 {
    // Try relative path from project root (for `zig test` and `zig build test`)
    const prefixes = [_][]const u8{
        "src/testdata/",
        "testdata/",
        "src/wasm/testdata/",
    };
    for (prefixes) |prefix| {
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name });
        defer alloc.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();
        const stat = try file.stat();
        const data = try alloc.alloc(u8, stat.size);
        const read = try file.readAll(data);
        return data[0..read];
    }
    return error.FileNotFound;
}

test "Module — decode 01_add.wasm" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    // Type section: one func type (i32, i32) -> i32
    try testing.expectEqual(@as(usize, 1), mod.types.items.len);
    const ft0 = mod.types.items[0].getFunc().?;
    try testing.expectEqual(@as(usize, 2), ft0.params.len);
    try testing.expectEqual(ValType.i32, ft0.params[0]);
    try testing.expectEqual(ValType.i32, ft0.params[1]);
    try testing.expectEqual(@as(usize, 1), ft0.results.len);
    try testing.expectEqual(ValType.i32, ft0.results[0]);

    // Function section: one function
    try testing.expectEqual(@as(usize, 1), mod.functions.items.len);
    try testing.expectEqual(@as(u32, 0), mod.functions.items[0].type_idx);

    // Export section: "add"
    try testing.expectEqual(@as(usize, 1), mod.exports.items.len);
    try testing.expectEqualStrings("add", mod.exports.items[0].name);
    try testing.expectEqual(opcode.ExternalKind.func, mod.exports.items[0].kind);

    // Code section: one code body
    try testing.expectEqual(@as(usize, 1), mod.codes.items.len);
    try testing.expect(mod.codes.items[0].body.len > 0);

    // No imports, no start
    try testing.expectEqual(@as(usize, 0), mod.imports.items.len);
    try testing.expect(mod.start == null);
}

test "Module — decode 02_fibonacci.wasm" {
    const wasm = try readTestFile(testing.allocator, "02_fibonacci.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.getExport("fib", .func) != null);
}

test "Module — decode 03_memory.wasm" {
    const wasm = try readTestFile(testing.allocator, "03_memory.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.memories.items.len > 0);
    try testing.expect(mod.getExport("store", .func) != null);
    try testing.expect(mod.getExport("load", .func) != null);
}

test "Module — decode 04_imports.wasm" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.imports.items.len >= 2);
    try testing.expectEqualStrings("env", mod.imports.items[0].module);
    try testing.expectEqual(@as(u32, 2), mod.num_imported_funcs);
    try testing.expect(mod.getExport("greet", .func) != null);
}

test "Module — decode 05_table_indirect_call.wasm" {
    const wasm = try readTestFile(testing.allocator, "05_table_indirect_call.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.tables.items.len > 0 or mod.num_imported_tables > 0);
    try testing.expect(mod.elements.items.len > 0);
}

test "Module — decode 06_globals.wasm" {
    const wasm = try readTestFile(testing.allocator, "06_globals.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.globals.items.len > 0);
}

test "Module — decode 07_wasi_hello.wasm" {
    const wasm = try readTestFile(testing.allocator, "07_wasi_hello.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.imports.items.len > 0);
    try testing.expectEqualStrings("wasi_snapshot_preview1", mod.imports.items[0].module);
}

test "Module — decode 08_multi_value.wasm" {
    const wasm = try readTestFile(testing.allocator, "08_multi_value.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var has_multi = false;
    for (mod.types.items) |td| {
        if (td.getFunc()) |ft| {
            if (ft.results.len > 1) has_multi = true;
        }
    }
    try testing.expect(has_multi);
}

test "Module — decode 09_go_math.wasm (large TinyGo module)" {
    const wasm = try readTestFile(testing.allocator, "09_go_math.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.functions.items.len > 10);
    try testing.expect(mod.codes.items.len > 10);
}

test "Module — decode 10_greet.wasm" {
    const wasm = try readTestFile(testing.allocator, "10_greet.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    // 10_greet.wasm has memory + globals + exported greet function
    try testing.expect(mod.memories.items.len > 0);
    try testing.expect(mod.getExport("greet", .func) != null);
}

test "Module — data section in imports module" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    // 04_imports.wasm has a data section with "Hello from Wasm!"
    try testing.expect(mod.datas.items.len > 0);
    try testing.expectEqualStrings("Hello from Wasm!", mod.datas.items[0].data);
}

test "Module — getExport nonexistent" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    try testing.expect(mod.getExport("nonexistent", .func) == null);
}

test "Module — getFuncType" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);
    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    const ft = mod.getFuncType(0);
    try testing.expect(ft != null);
    try testing.expectEqual(@as(usize, 2), ft.?.params.len);
    try testing.expectEqual(@as(usize, 1), ft.?.results.len);
}

test "Module — invalid magic" {
    const bad = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &bad);
    defer mod.deinit();
    try testing.expectError(error.InvalidWasm, mod.decode());
}

test "Module — too short" {
    const short = [_]u8{ 0x00, 0x61, 0x73 };
    var mod = Module.init(testing.allocator, &short);
    defer mod.deinit();
    try testing.expectError(error.InvalidWasm, mod.decode());
}

test "readLimits — i64 addrtype (memory64 table64)" {
    // Flag 0x04 = i64 addr, min only
    var bytes_04 = [_]u8{ 0x04, 0x03 }; // min=3
    var r04 = Reader.init(&bytes_04);
    const lim04 = try readLimits(&r04);
    try testing.expect(lim04.is_64);
    try testing.expectEqual(@as(u64, 3), lim04.min);
    try testing.expectEqual(@as(?u64, null), lim04.max);

    // Flag 0x05 = i64 addr, min+max
    var bytes_05 = [_]u8{ 0x05, 0x03, 0x08 }; // min=3, max=8
    var r05 = Reader.init(&bytes_05);
    const lim05 = try readLimits(&r05);
    try testing.expect(lim05.is_64);
    try testing.expectEqual(@as(u64, 3), lim05.min);
    try testing.expectEqual(@as(?u64, 8), lim05.max);

    // Flag 0x00 = i32 addr, min only (backwards compat)
    var bytes_00 = [_]u8{ 0x00, 0x05 }; // min=5
    var r00 = Reader.init(&bytes_00);
    const lim00 = try readLimits(&r00);
    try testing.expect(!lim00.is_64);
    try testing.expectEqual(@as(u64, 5), lim00.min);
    try testing.expectEqual(@as(?u64, null), lim00.max);

    // Flag 0x01 = i32 addr, min+max
    var bytes_01 = [_]u8{ 0x01, 0x01, 0x0A }; // min=1, max=10
    var r01 = Reader.init(&bytes_01);
    const lim01 = try readLimits(&r01);
    try testing.expect(!lim01.is_64);
    try testing.expectEqual(@as(u64, 1), lim01.min);
    try testing.expectEqual(@as(?u64, 10), lim01.max);
}

test "readLimits — custom page sizes" {
    // Flag 0x08 = custom page size, min only, page_exp=0 (2^0=1)
    var bytes_08 = [_]u8{ 0x08, 0x0a, 0x00 }; // min=10, page_size=1
    var r08 = Reader.init(&bytes_08);
    const lim08 = try readLimits(&r08);
    try testing.expectEqual(@as(u64, 10), lim08.min);
    try testing.expectEqual(@as(?u64, null), lim08.max);
    try testing.expectEqual(@as(u32, 1), lim08.page_size);

    // Flag 0x09 = custom page size + has_max, page_exp=16 (2^16=65536)
    var bytes_09 = [_]u8{ 0x09, 0x01, 0x0a, 0x10 }; // min=1, max=10, page_size=65536
    var r09 = Reader.init(&bytes_09);
    const lim09 = try readLimits(&r09);
    try testing.expectEqual(@as(u64, 1), lim09.min);
    try testing.expectEqual(@as(?u64, 10), lim09.max);
    try testing.expectEqual(@as(u32, 65536), lim09.page_size);

    // Invalid page size: 2^1=2 (not 1 or 65536)
    var bytes_bad = [_]u8{ 0x08, 0x00, 0x01 }; // min=0, page_exp=1 (2^1=2)
    var r_bad = Reader.init(&bytes_bad);
    try testing.expectError(error.InvalidWasm, readLimits(&r_bad));

    // Invalid page size: 2^17 > 65536
    var bytes_big = [_]u8{ 0x08, 0x00, 0x11 }; // min=0, page_exp=17
    var r_big = Reader.init(&bytes_big);
    try testing.expectError(error.InvalidWasm, readLimits(&r_big));
}

test "Module — tag section parsing" {
    // Build a minimal wasm module with:
    // - type section: one functype (param i32, result empty)
    // - tag section (13): one tag with attribute=0, type_idx=0
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x01, 0x00, 0x00, 0x00, // version
        // Type section (ID=1): 1 type, functype(i32)->(empty)
        0x01, 0x05, // section id=1, size=5
        0x01, // count=1
        0x60, // functype
        0x01, 0x7F, // params: [i32]
        0x00, // results: []
        // Tag section (ID=13): 1 tag
        0x0D, 0x03, // section id=13, size=3
        0x01, // count=1
        0x00, // attribute=0 (exception)
        0x00, // type_idx=0
    };

    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 1), m.tags.items.len);
    try testing.expectEqual(@as(u32, 0), m.tags.items[0].type_idx);
}

test "Module — branch hint custom section" {
    // Minimal wasm with custom section "metadata.code.branch_hint"
    const custom_section = [_]u8{
        0x00, // section_id = custom
        32, // section_size (LEB128) = 32 bytes
        25, // name_len = 25
    } ++ "metadata.code.branch_hint".* ++ [_]u8{
        0x01, // num_funcs = 1
        0x00, // func_idx = 0
        0x01, // num_hints = 1
        0x05, // byte_offset = 5
        0x01, // size = 1
        0x01, // value = 1 (likely taken)
    };

    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x01, 0x00, 0x00, 0x00, // version
    } ++ custom_section;

    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 1), m.branch_hints.items.len);
    try testing.expectEqual(@as(u32, 0), m.branch_hints.items[0].func_idx);
    try testing.expectEqual(@as(u32, 5), m.branch_hints.items[0].byte_offset);
    try testing.expectEqual(@as(u8, 1), m.branch_hints.items[0].hint);
}

test "Module — multi-memory (2 memories)" {
    // Module with 2 memories: (memory 1) (memory 2)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x01, 0x00, 0x00, 0x00, // version
        // Section 5: Memory (2 entries)
        0x05, // section id
        0x05, // section size (5 bytes)
        0x02, // count = 2
        0x00, 0x01, // memory 0: min=1, no max
        0x00, 0x02, // memory 1: min=2, no max
    };
    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 2), m.memories.items.len);
    try testing.expectEqual(@as(u32, 1), m.memories.items[0].limits.min);
    try testing.expectEqual(@as(u32, 2), m.memories.items[1].limits.min);
}

test "Module — GC struct type decode" {
    // Type section: struct { i32 mut, i64 const }
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // magic + version
        0x01, // type section
        7, // section size
        0x01, // 1 type
        0x5F, // struct
        0x02, // 2 fields
        0x7F, 0x01, // i32, mutable
        0x7E, 0x00, // i64, immutable
    };
    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 1), m.types.items.len);
    const td = m.types.items[0];
    try testing.expect(td.is_final);
    try testing.expectEqual(@as(usize, 0), td.super_types.len);
    switch (td.composite) {
        .struct_type => |st| {
            try testing.expectEqual(@as(usize, 2), st.fields.len);
            try testing.expectEqual(StorageType{ .val = .i32 }, st.fields[0].storage);
            try testing.expect(st.fields[0].mutable);
            try testing.expectEqual(StorageType{ .val = .i64 }, st.fields[1].storage);
            try testing.expect(!st.fields[1].mutable);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Module — GC array type decode" {
    // Type section: array { i8 mutable }
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, // type section
        4, // section size
        0x01, // 1 type
        0x5E, // array
        0x78, 0x01, // i8 packed, mutable
    };
    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 1), m.types.items.len);
    switch (m.types.items[0].composite) {
        .array_type => |at| {
            try testing.expectEqual(StorageType.i8, at.field.storage);
            try testing.expect(at.field.mutable);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "Module — GC sub type decode" {
    // Type section: 2 types
    //   type 0: func () -> ()
    //   type 1: sub type 0, func () -> ()  (non-final)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, // type section
        10, // section size
        0x02, // 2 types
        0x60, 0x00, 0x00, // func () -> ()
        0x50, // sub (non-final)
        0x01, 0x00, // 1 supertype: type 0
        0x60, 0x00, 0x00, // func () -> ()
    };
    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 2), m.types.items.len);
    // Type 0: plain func, final
    try testing.expect(m.types.items[0].is_final);
    try testing.expect(m.types.items[0].getFunc() != null);
    // Type 1: sub non-final, supertype [0]
    try testing.expect(!m.types.items[1].is_final);
    try testing.expectEqual(@as(usize, 1), m.types.items[1].super_types.len);
    try testing.expectEqual(@as(u32, 0), m.types.items[1].super_types[0]);
    try testing.expect(m.types.items[1].getFunc() != null);
}

test "Module — type canonicalization: structurally identical singletons" {
    // Types: (func (param i32)) × 2, (func (param i32 (ref null 0))) × 2
    // Type 0 and 1 are structurally identical → same canonical ID
    // Type 2: (func (param i32 (ref null <canon_of_0>))) — first of its kind
    // Type 3: (func (param i32 (ref null <canon_of_1>))) = same as 2 since canon(0)=canon(1)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, // type section
        21, // section size = 1 + 4 + 4 + 6 + 6
        0x04, // 4 types (each is a singleton rec group)
        0x60, 0x01, 0x7F, 0x00, // func (param i32) -> ()
        0x60, 0x01, 0x7F, 0x00, // func (param i32) -> ()    [same as type 0]
        0x60, 0x02, 0x7F, 0x63, 0x00, 0x00, // func (param i32 (ref null 0)) -> ()
        0x60, 0x02, 0x7F, 0x63, 0x01, 0x00, // func (param i32 (ref null 1)) -> ()
    };
    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 4), m.types.items.len);
    // Register types in TypeRegistry to get global IDs
    const store_mod = @import("store.zig");
    var reg = store_mod.TypeRegistry.init(testing.allocator);
    defer reg.deinit();
    const gids = try reg.registerModuleTypes(&m);
    defer testing.allocator.free(gids);
    // Types 0 and 1 should have same global ID
    try testing.expectEqual(gids[0], gids[1]);
    // Types 2 and 3 should have same global ID (both ref canon(0) which equals canon(1))
    try testing.expectEqual(gids[2], gids[3]);
    // Types 0 and 2 should be different
    try testing.expect(gids[0] != gids[2]);
}

test "Module — type canonicalization: structurally identical rec groups" {
    // Two identical rec groups: rec { func () -> (ref null self) }
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, // type section
        15, // section size = 1 + 2 + 5 + 2 + 5
        0x02, // 2 entries (each is a rec group)
        0x4E, 0x01, // rec, 1 type
        0x60, 0x00, 0x01, 0x63, 0x00, // func () -> (ref null 0)
        0x4E, 0x01, // rec, 1 type
        0x60, 0x00, 0x01, 0x63, 0x01, // func () -> (ref null 1)
    };
    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 2), m.types.items.len);
    // Both types should have same global ID (structurally identical rec groups)
    const store_mod = @import("store.zig");
    var reg = store_mod.TypeRegistry.init(testing.allocator);
    defer reg.deinit();
    const gids = try reg.registerModuleTypes(&m);
    defer testing.allocator.free(gids);
    try testing.expectEqual(gids[0], gids[1]);
}

test "Module — type canonicalization: ref_test.1 GC struct types" {
    // ref_test.1.wasm types (all singleton rec groups):
    //   0: sub() struct()              — $t0
    //   1: sub(0) struct(i32)          — $t1
    //   2: sub(0) struct(i32)          — $t1' (should be canon-equal to 1)
    //   3: sub(1) struct(i32, i32)     — $t2
    //   4: sub(2) struct(i32, i32)     — $t2' (should be canon-equal to 3)
    //   5: sub(0) struct(i32, i32)     — $t3
    //   6: sub(0) struct()             — $t0' (NOT same as 0: has super=[0])
    //   7: sub(6) struct(i32, i32)     — $t4
    //   8: func() -> ()
    const wasm = try std.fs.cwd().readFileAlloc(testing.allocator, "test/spec/json/ref_test.1.wasm", 1024 * 1024);
    defer testing.allocator.free(wasm);
    var m = Module.init(testing.allocator, wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 9), m.types.items.len);
    try testing.expectEqual(@as(usize, 9), m.rec_groups.items.len);

    // Register types in TypeRegistry to get global IDs
    const store_mod = @import("store.zig");
    var reg = store_mod.TypeRegistry.init(testing.allocator);
    defer reg.deinit();
    const gids = try reg.registerModuleTypes(&m);
    defer testing.allocator.free(gids);

    // Verify canonical equivalence pairs
    try testing.expectEqual(gids[1], gids[2]); // $t1 == $t1'
    try testing.expectEqual(gids[3], gids[4]); // $t2 == $t2'

    // These should NOT be equal
    try testing.expect(gids[0] != gids[1]); // $t0 != $t1
    try testing.expect(gids[0] != gids[6]); // $t0 != $t0' (different super_types)
    try testing.expect(gids[1] != gids[5]); // $t1 != $t3 (same struct but different super)
    try testing.expect(gids[3] != gids[5]); // $t2 != $t3 (same fields, different super chain)

    // Verify isConcreteSubtype with canonical equivalence
    const gc_mod = @import("gc.zig");
    // $t1 <: $t1' (canonical equivalence)
    try testing.expect(gc_mod.isConcreteSubtype(gids[1], gids[2], &reg));
    // $t1' <: $t1 (canonical equivalence)
    try testing.expect(gc_mod.isConcreteSubtype(gids[2], gids[1], &reg));
    // $t2 <: $t2' (canonical equivalence)
    try testing.expect(gc_mod.isConcreteSubtype(gids[3], gids[4], &reg));
    // $t2 <: $t1' (t2 sub(t1), t1 canon= t1')
    try testing.expect(gc_mod.isConcreteSubtype(gids[3], gids[2], &reg));
    // $t2' <: $t1 (t2' sub(t1'), t1' canon= t1)
    try testing.expect(gc_mod.isConcreteSubtype(gids[4], gids[1], &reg));
}

test "Module — GC rec group decode" {
    // Type section: 1 rec group with 2 types
    //   rec { func () -> (ref null 1), func (ref null 0) -> () }
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, // type section
        13, // section size
        0x01, // 1 entry (the rec group counts as 1 entry)
        0x4E, // rec
        0x02, // 2 types in group
        0x60, 0x00, 0x01, 0x63, 0x01, // func () -> (ref null 1)
        0x60, 0x01, 0x63, 0x00, 0x00, // func (ref null 0) -> ()
    };
    var m = Module.init(testing.allocator, &wasm);
    defer m.deinit();
    try m.decode();

    try testing.expectEqual(@as(usize, 2), m.types.items.len);
    // Both should be func types
    try testing.expect(m.types.items[0].getFunc() != null);
    try testing.expect(m.types.items[1].getFunc() != null);
    // Type 0: () -> (ref null 1) — 0 params, 1 result
    const ft0 = m.types.items[0].getFunc().?;
    try testing.expectEqual(@as(usize, 0), ft0.params.len);
    try testing.expectEqual(@as(usize, 1), ft0.results.len);
    // Type 1: (ref null 0) -> () — 1 param, 0 results
    const ft1 = m.types.items[1].getFunc().?;
    try testing.expectEqual(@as(usize, 1), ft1.params.len);
    try testing.expectEqual(@as(usize, 0), ft1.results.len);
}

// ============================================================
// Fuzz test — module decoder
// ============================================================

test "fuzz — module decode does not panic on arbitrary input" {
    const Ctx = struct { corpus: []const []const u8 };
    const corpus: []const []const u8 = &.{
        // Empty
        "",
        // Too short
        "\x00",
        // Valid magic, no version
        "\x00\x61\x73\x6d",
        // Valid magic + version, no sections
        "\x00\x61\x73\x6d\x01\x00\x00\x00",
        // Valid header + truncated type section
        "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\x04\x01\x60\x00\x00",
        // Valid header + invalid section id
        "\x00\x61\x73\x6d\x01\x00\x00\x00\xff\x00",
        // Valid header + oversized section length
        "\x00\x61\x73\x6d\x01\x00\x00\x00\x01\xff\xff\xff\x0f",
    };
    try std.testing.fuzz(
        Ctx{ .corpus = corpus },
        struct {
            fn f(_: Ctx, input: []const u8) anyerror!void {
                var m = Module.init(testing.allocator, input);
                defer m.deinit();
                m.decode() catch return;
            }
        }.f,
        .{},
    );
}
