// Component Model binary format decoder
// Parses WebAssembly Component binary format (layer 1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("leb128.zig").Reader;
const opcode = @import("opcode.zig");
const types = @import("types.zig");

// ── Constants ─────────────────────────────────────────────────────────

/// Component binary version+layer: version 0x0d, layer 0x01
pub const COMPONENT_VERSION = [4]u8{ 0x0D, 0x00, 0x01, 0x00 };

// ── Section IDs ───────────────────────────────────────────────────────

pub const SectionId = enum(u8) {
    core_custom = 0,
    core_module = 1,
    core_instance = 2,
    core_type = 3,
    component = 4,
    instance = 5,
    alias = 6,
    @"type" = 7,
    canonical = 8,
    start = 9,
    @"import" = 10,
    @"export" = 11,
    _,
};

// ── External Kind ─────────────────────────────────────────────────────

pub const ExternKind = enum(u8) {
    core_module = 0x00,
    func = 0x01,
    value = 0x02,
    @"type" = 0x03,
    component = 0x04,
    instance = 0x05,
    _,
};

// ── Canonical Options ─────────────────────────────────────────────────

pub const CanonOp = enum(u8) {
    lift = 0x00,
    lower = 0x01,
    resource_new = 0x02,
    resource_drop = 0x03,
    resource_rep = 0x04,
    _,
};

pub const CanonOpt = enum(u8) {
    utf8 = 0x00,
    utf16 = 0x01,
    compact_utf16 = 0x02,
    memory = 0x03,
    realloc = 0x04,
    post_return = 0x05,
    _,
};

// ── Alias Kind ────────────────────────────────────────────────────────

pub const AliasSort = enum(u8) {
    instance_export = 0x00,
    core_instance_export = 0x01,
    outer = 0x02,
    _,
};

// ── Component Type Opcodes ────────────────────────────────────────────

pub const ComponentTypeOp = enum(u8) {
    defined_type = 0x40,
    func_type = 0x41,
    component_type = 0x42,
    instance_type = 0x43,
    resource_type = 0x3f,
    _,
};

// ── Component Value Types ─────────────────────────────────────────────

pub const ValType = enum(u8) {
    bool_ = 0x7f,
    s8 = 0x7e,
    u8_ = 0x7d,
    s16 = 0x7c,
    u16_ = 0x7b,
    s32 = 0x7a,
    u32_ = 0x79,
    s64 = 0x78,
    u64_ = 0x77,
    f32_ = 0x76,
    f64_ = 0x75,
    char_ = 0x74,
    string_ = 0x73,
    // Compound types (followed by type data)
    record = 0x72,
    variant = 0x71,
    list = 0x70,
    tuple = 0x6f,
    flags = 0x6e,
    @"enum" = 0x6d,
    option = 0x6c,
    result = 0x6b,
    own = 0x69,
    borrow = 0x68,
    _,
};

// ── Decoded Component Types ──────────────────────────────────────────

pub const ComponentType = union(enum) {
    defined: DefinedType,
    func: ComponentFuncType,
    component: ComponentComponentType,
    instance: ComponentInstanceType,
    resource: ResourceType,
};

pub const DefinedType = union(enum) {
    primitive: ValType,
    record: []FieldType,
    variant: []VariantCase,
    list: u32, // type index
    tuple: []u32, // type indices
    flags: []const []const u8, // field names
    enum_: []const []const u8, // case names
    option: u32, // type index
    result: ResultTypeDesc,
    own: u32, // resource type index
    borrow: u32, // resource type index
};

pub const FieldType = struct {
    name: []const u8,
    type_idx: u32,
};

pub const VariantCase = struct {
    name: []const u8,
    type_idx: ?u32, // null if no payload
    refines: ?u32, // optional refines index
};

pub const ResultTypeDesc = struct {
    ok: ?u32, // type index or null
    err: ?u32, // type index or null
};

pub const ComponentFuncType = struct {
    params: []NamedType,
    result: FuncResult,
};

pub const NamedType = struct {
    name: []const u8,
    type_idx: u32,
};

pub const FuncResult = union(enum) {
    unnamed: u32, // single type index
    named: []NamedType, // multiple named results
};

pub const ComponentComponentType = struct {
    // Simplified: just track import/export declarations
    decl_count: u32,
};

pub const ComponentInstanceType = struct {
    // Simplified: just track export declarations
    decl_count: u32,
};

pub const ResourceType = struct {
    rep: ValType, // representation type (usually i32)
    dtor: ?u32, // optional destructor function index
};

// ── Canonical Functions ───────────────────────────────────────────────

pub const CanonicalFunc = union(enum) {
    lift: LiftFunc,
    lower: LowerFunc,
    resource_new: u32, // resource type index
    resource_drop: u32, // resource type index
    resource_rep: u32, // resource type index
};

pub const LiftFunc = struct {
    core_func_idx: u32,
    options: CanonOptions,
};

pub const LowerFunc = struct {
    func_idx: u32,
    options: CanonOptions,
};

pub const CanonOptions = struct {
    string_encoding: StringEncoding = .utf8,
    memory: ?u32 = null,
    realloc: ?u32 = null,
    post_return: ?u32 = null,
};

pub const StringEncoding = enum {
    utf8,
    utf16,
    compact_utf16,
};

// ── Alias Declarations ───────────────────────────────────────────────

pub const AliasDecl = union(enum) {
    instance_export: struct { instance_idx: u32, name: []const u8 },
    core_instance_export: struct { instance_idx: u32, name: []const u8 },
    outer: struct { outer_count: u32, kind: u8, idx: u32 },
};

// ── Start Function ───────────────────────────────────────────────────

pub const StartFunc = struct {
    func_idx: u32,
    args: []u32, // value indices passed as arguments
    result_count: u32,
};

// ── Instances ────────────────────────────────────────────────────────

pub const CoreInstance = union(enum) {
    instantiate: struct {
        module_idx: u32,
        args: []InstantiateArg,
    },
    from_exports: []CoreExportArg,
};

pub const InstantiateArg = struct {
    name: []const u8,
    kind: u8,
    idx: u32,
};

pub const CoreExportArg = struct {
    name: []const u8,
    kind: u8,
    idx: u32,
};

pub const Instance = union(enum) {
    instantiate: struct {
        component_idx: u32,
        args: []InstantiateArg,
    },
    from_exports: []ComponentExportArg,
};

pub const ComponentExportArg = struct {
    name: []const u8,
    kind: ExternKind,
    idx: u32,
};

// ── Raw Section ───────────────────────────────────────────────────────

pub const RawSection = struct {
    id: SectionId,
    payload: []const u8,
};

// ── Component ─────────────────────────────────────────────────────────

pub const Component = struct {
    alloc: Allocator,
    bytes: []const u8,
    sections: std.ArrayListUnmanaged(RawSection),
    // Extracted core modules (section payloads)
    core_modules: std.ArrayListUnmanaged([]const u8),
    // Import and export names
    imports: std.ArrayListUnmanaged(ComponentImport),
    exports: std.ArrayListUnmanaged(ComponentExport),
    // Decoded component types (from type sections)
    types: std.ArrayListUnmanaged(ComponentType),
    // Decoded canonical functions
    canon_funcs: std.ArrayListUnmanaged(CanonicalFunc),
    // Decoded aliases
    aliases: std.ArrayListUnmanaged(AliasDecl),
    // Start function index
    start_func: ?StartFunc = null,
    // Core instances
    core_instances: std.ArrayListUnmanaged(CoreInstance),
    // Component instances
    instances: std.ArrayListUnmanaged(Instance),

    pub const ComponentImport = struct {
        name: []const u8,
        kind: ExternKind,
    };

    pub const ComponentExport = struct {
        name: []const u8,
        kind: ExternKind,
    };

    pub fn init(alloc: Allocator, bytes: []const u8) Component {
        return .{
            .alloc = alloc,
            .bytes = bytes,
            .sections = .empty,
            .core_modules = .empty,
            .imports = .empty,
            .exports = .empty,
            .types = .empty,
            .canon_funcs = .empty,
            .aliases = .empty,
            .core_instances = .empty,
            .instances = .empty,
        };
    }

    pub fn deinit(self: *Component) void {
        self.sections.deinit(self.alloc);
        self.core_modules.deinit(self.alloc);
        self.imports.deinit(self.alloc);
        self.exports.deinit(self.alloc);
        self.types.deinit(self.alloc);
        self.canon_funcs.deinit(self.alloc);
        self.aliases.deinit(self.alloc);
        if (self.start_func) |sf| self.alloc.free(sf.args);
        self.core_instances.deinit(self.alloc);
        self.instances.deinit(self.alloc);
    }

    pub fn decode(self: *Component) !void {
        if (self.bytes.len < 8) return error.InvalidComponent;

        // Verify magic
        if (!std.mem.eql(u8, self.bytes[0..4], &opcode.MAGIC))
            return error.InvalidComponent;

        // Verify component version+layer
        if (!std.mem.eql(u8, self.bytes[4..8], &COMPONENT_VERSION))
            return error.InvalidComponent;

        var reader = Reader.init(self.bytes[8..]);

        while (reader.hasMore()) {
            const section_id_byte = reader.readByte() catch return error.InvalidComponent;
            const section_id: SectionId = @enumFromInt(section_id_byte);
            const size = reader.readU32() catch return error.InvalidComponent;

            if (reader.pos + size > reader.bytes.len) return error.InvalidComponent;

            const payload = reader.bytes[reader.pos..][0..size];
            reader.pos += size;

            self.sections.append(self.alloc, .{
                .id = section_id,
                .payload = payload,
            }) catch return error.OutOfMemory;

            switch (section_id) {
                .core_module => {
                    self.core_modules.append(self.alloc, payload) catch return error.OutOfMemory;
                },
                .@"type" => {
                    self.decodeTypeSection(payload) catch {};
                },
                .@"import" => {
                    self.decodeImportSection(payload) catch {};
                },
                .@"export" => {
                    self.decodeExportSection(payload) catch {};
                },
                .canonical => {
                    self.decodeCanonSection(payload) catch {};
                },
                .alias => {
                    self.decodeAliasSection(payload) catch {};
                },
                .start => {
                    self.decodeStartSection(payload) catch {};
                },
                .core_instance => {
                    self.decodeCoreInstanceSection(payload) catch {};
                },
                .instance => {
                    self.decodeInstanceSection(payload) catch {};
                },
                else => {},
            }
        }
    }

    fn decodeTypeSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const disc = r.readByte() catch return;
            const ct: ComponentType = switch (disc) {
                @intFromEnum(ComponentTypeOp.defined_type) => .{
                    .defined = self.decodeDefinedType(&r) orelse return,
                },
                @intFromEnum(ComponentTypeOp.func_type) => .{
                    .func = self.decodeFuncType(&r) orelse return,
                },
                @intFromEnum(ComponentTypeOp.resource_type) => .{
                    .resource = self.decodeResourceType(&r) orelse return,
                },
                @intFromEnum(ComponentTypeOp.component_type) => blk: {
                    // Skip component type body (count + declarations)
                    const decl_count = r.readU32() catch return;
                    self.skipDeclarations(&r, decl_count);
                    break :blk .{ .component = .{ .decl_count = decl_count } };
                },
                @intFromEnum(ComponentTypeOp.instance_type) => blk: {
                    const decl_count = r.readU32() catch return;
                    self.skipDeclarations(&r, decl_count);
                    break :blk .{ .instance = .{ .decl_count = decl_count } };
                },
                else => return,
            };
            self.types.append(self.alloc, ct) catch return error.OutOfMemory;
        }
    }

    fn decodeDefinedType(_: *Component, r: *Reader) ?DefinedType {
        const vt_byte = r.readByte() catch return null;
        const vt: ValType = @enumFromInt(vt_byte);
        return switch (vt) {
            // Primitive types
            .bool_, .s8, .u8_, .s16, .u16_, .s32, .u32_, .s64, .u64_, .f32_, .f64_, .char_, .string_ => .{ .primitive = vt },
            // Compound types
            .list => .{ .list = r.readU32() catch return null },
            .option => .{ .option = r.readU32() catch return null },
            .own => .{ .own = r.readU32() catch return null },
            .borrow => .{ .borrow = r.readU32() catch return null },
            .result => blk: {
                // result has ok? and err? type indices
                const ok_tag = r.readByte() catch return null;
                var ok: ?u32 = null;
                if (ok_tag == 0x00) {
                    ok = r.readU32() catch return null;
                }
                const err_tag = r.readByte() catch return null;
                var err: ?u32 = null;
                if (err_tag == 0x00) {
                    err = r.readU32() catch return null;
                }
                break :blk .{ .result = .{ .ok = ok, .err = err } };
            },
            .record => blk: {
                const field_count = r.readU32() catch return null;
                // Skip field data for now (name + type_idx per field)
                for (0..field_count) |_| {
                    const name_len = r.readU32() catch return null;
                    _ = r.readBytes(name_len) catch return null;
                    _ = r.readU32() catch return null;
                }
                break :blk .{ .record = &[_]FieldType{} };
            },
            .variant => blk: {
                const case_count = r.readU32() catch return null;
                for (0..case_count) |_| {
                    const name_len = r.readU32() catch return null;
                    _ = r.readBytes(name_len) catch return null;
                    const has_type = r.readByte() catch return null;
                    if (has_type == 0x00) {
                        _ = r.readU32() catch return null;
                    }
                    // optional refines
                    const has_refines = r.readByte() catch return null;
                    if (has_refines == 0x00) {
                        _ = r.readU32() catch return null;
                    }
                }
                break :blk .{ .variant = &[_]VariantCase{} };
            },
            .tuple => blk: {
                const elem_count = r.readU32() catch return null;
                for (0..elem_count) |_| {
                    _ = r.readU32() catch return null;
                }
                break :blk .{ .tuple = &[_]u32{} };
            },
            .flags => blk: {
                const flag_count = r.readU32() catch return null;
                for (0..flag_count) |_| {
                    const name_len = r.readU32() catch return null;
                    _ = r.readBytes(name_len) catch return null;
                }
                break :blk .{ .flags = &[_][]const u8{} };
            },
            .@"enum" => blk: {
                const case_count = r.readU32() catch return null;
                for (0..case_count) |_| {
                    const name_len = r.readU32() catch return null;
                    _ = r.readBytes(name_len) catch return null;
                }
                break :blk .{ .enum_ = &[_][]const u8{} };
            },
            _ => null,
        };
    }

    fn decodeFuncType(self: *Component, r: *Reader) ?ComponentFuncType {
        // Params: vec<(name, type_idx)>
        const param_count = r.readU32() catch return null;
        var params = std.ArrayListUnmanaged(NamedType).empty;
        for (0..param_count) |_| {
            const name_len = r.readU32() catch return null;
            const name = r.readBytes(name_len) catch return null;
            const type_idx = r.readU32() catch return null;
            params.append(self.alloc, .{ .name = name, .type_idx = type_idx }) catch return null;
        }
        // Result: 0x00 = named results, 0x01 = single type
        const result_tag = r.readByte() catch return null;
        const result: FuncResult = if (result_tag == 0x01) blk: {
            break :blk .{ .unnamed = r.readU32() catch return null };
        } else blk: {
            const res_count = r.readU32() catch return null;
            var results = std.ArrayListUnmanaged(NamedType).empty;
            for (0..res_count) |_| {
                const name_len = r.readU32() catch return null;
                const name = r.readBytes(name_len) catch return null;
                const type_idx = r.readU32() catch return null;
                results.append(self.alloc, .{ .name = name, .type_idx = type_idx }) catch return null;
            }
            break :blk .{ .named = results.toOwnedSlice(self.alloc) catch return null };
        };
        return .{
            .params = params.toOwnedSlice(self.alloc) catch return null,
            .result = result,
        };
    }

    fn decodeResourceType(_: *Component, r: *Reader) ?ResourceType {
        const rep_byte = r.readByte() catch return null;
        const has_dtor = r.readByte() catch return null;
        var dtor: ?u32 = null;
        if (has_dtor == 0x00) {
            dtor = r.readU32() catch return null;
        }
        return .{
            .rep = @enumFromInt(rep_byte),
            .dtor = dtor,
        };
    }

    fn skipDeclarations(_: *Component, r: *Reader, count: u32) void {
        // Skip declaration bodies — each starts with a discriminant
        for (0..count) |_| {
            _ = r.readByte() catch return;
            // Skip remaining bytes until next declaration
            // This is a simplification — real impl would parse each decl type
        }
    }

    fn decodeImportSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const name = self.readComponentName(&r) orelse return;
            const kind_byte = r.readByte() catch return;
            // Skip type index
            _ = r.readU32() catch return;
            self.imports.append(self.alloc, .{
                .name = name,
                .kind = @enumFromInt(kind_byte),
            }) catch return error.OutOfMemory;
        }
    }

    fn decodeExportSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const name = self.readComponentName(&r) orelse return;
            const kind_byte = r.readByte() catch return;
            // Skip index
            _ = r.readU32() catch return;
            // Optional extern desc (0x00 = none, else type)
            if (r.hasMore()) {
                const has_desc = r.readByte() catch return;
                if (has_desc != 0x00) {
                    _ = r.readU32() catch return;
                }
            }
            self.exports.append(self.alloc, .{
                .name = name,
                .kind = @enumFromInt(kind_byte),
            }) catch return error.OutOfMemory;
        }
    }

    fn decodeCanonSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const op_byte = r.readByte() catch return;
            const sub_byte = r.readByte() catch return;
            _ = sub_byte; // sub-opcode (0x00 for most ops)
            const cf: CanonicalFunc = switch (op_byte) {
                @intFromEnum(CanonOp.lift) => blk: {
                    const core_func_idx = r.readU32() catch return;
                    const opts = self.decodeCanonOptions(&r);
                    break :blk .{ .lift = .{ .core_func_idx = core_func_idx, .options = opts } };
                },
                @intFromEnum(CanonOp.lower) => blk: {
                    const func_idx = r.readU32() catch return;
                    const opts = self.decodeCanonOptions(&r);
                    break :blk .{ .lower = .{ .func_idx = func_idx, .options = opts } };
                },
                @intFromEnum(CanonOp.resource_new) => .{
                    .resource_new = r.readU32() catch return,
                },
                @intFromEnum(CanonOp.resource_drop) => .{
                    .resource_drop = r.readU32() catch return,
                },
                @intFromEnum(CanonOp.resource_rep) => .{
                    .resource_rep = r.readU32() catch return,
                },
                else => return,
            };
            self.canon_funcs.append(self.alloc, cf) catch return error.OutOfMemory;
        }
    }

    fn decodeCanonOptions(_: *Component, r: *Reader) CanonOptions {
        var opts = CanonOptions{};
        const opt_count = r.readU32() catch return opts;
        for (0..opt_count) |_| {
            const opt_byte = r.readByte() catch return opts;
            switch (opt_byte) {
                @intFromEnum(CanonOpt.utf8) => opts.string_encoding = .utf8,
                @intFromEnum(CanonOpt.utf16) => opts.string_encoding = .utf16,
                @intFromEnum(CanonOpt.compact_utf16) => opts.string_encoding = .compact_utf16,
                @intFromEnum(CanonOpt.memory) => opts.memory = r.readU32() catch return opts,
                @intFromEnum(CanonOpt.realloc) => opts.realloc = r.readU32() catch return opts,
                @intFromEnum(CanonOpt.post_return) => opts.post_return = r.readU32() catch return opts,
                else => {},
            }
        }
        return opts;
    }

    fn decodeAliasSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const sort_byte = r.readByte() catch return;
            const alias: AliasDecl = switch (sort_byte) {
                @intFromEnum(AliasSort.instance_export) => blk: {
                    const inst_idx = r.readU32() catch return;
                    const name_len = r.readU32() catch return;
                    const name = r.readBytes(name_len) catch return;
                    break :blk .{ .instance_export = .{ .instance_idx = inst_idx, .name = name } };
                },
                @intFromEnum(AliasSort.core_instance_export) => blk: {
                    const inst_idx = r.readU32() catch return;
                    const name_len = r.readU32() catch return;
                    const name = r.readBytes(name_len) catch return;
                    break :blk .{ .core_instance_export = .{ .instance_idx = inst_idx, .name = name } };
                },
                @intFromEnum(AliasSort.outer) => blk: {
                    const outer_count = r.readU32() catch return;
                    const kind = r.readByte() catch return;
                    const idx = r.readU32() catch return;
                    break :blk .{ .outer = .{ .outer_count = outer_count, .kind = kind, .idx = idx } };
                },
                else => return,
            };
            self.aliases.append(self.alloc, alias) catch return error.OutOfMemory;
        }
    }

    fn decodeStartSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const func_idx = r.readU32() catch return;
        const arg_count = r.readU32() catch return;
        var args = std.ArrayListUnmanaged(u32).empty;
        for (0..arg_count) |_| {
            args.append(self.alloc, r.readU32() catch return) catch return error.OutOfMemory;
        }
        const result_count = r.readU32() catch return;
        self.start_func = .{
            .func_idx = func_idx,
            .args = args.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
            .result_count = result_count,
        };
    }

    fn decodeCoreInstanceSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const tag = r.readByte() catch return;
            const ci: CoreInstance = switch (tag) {
                0x00 => blk: {
                    // instantiate: module_idx + args
                    const module_idx = r.readU32() catch return;
                    const arg_count = r.readU32() catch return;
                    var args = std.ArrayListUnmanaged(InstantiateArg).empty;
                    for (0..arg_count) |_| {
                        const name_len = r.readU32() catch return;
                        const name = r.readBytes(name_len) catch return;
                        const kind = r.readByte() catch return;
                        const idx = r.readU32() catch return;
                        args.append(self.alloc, .{ .name = name, .kind = kind, .idx = idx }) catch return error.OutOfMemory;
                    }
                    break :blk .{ .instantiate = .{
                        .module_idx = module_idx,
                        .args = args.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
                    } };
                },
                0x01 => blk: {
                    // from_exports: vec<(name, sort, idx)>
                    const exp_count = r.readU32() catch return;
                    var exports = std.ArrayListUnmanaged(CoreExportArg).empty;
                    for (0..exp_count) |_| {
                        const name_len = r.readU32() catch return;
                        const name = r.readBytes(name_len) catch return;
                        const kind = r.readByte() catch return;
                        const idx = r.readU32() catch return;
                        exports.append(self.alloc, .{ .name = name, .kind = kind, .idx = idx }) catch return error.OutOfMemory;
                    }
                    break :blk .{ .from_exports = exports.toOwnedSlice(self.alloc) catch return error.OutOfMemory };
                },
                else => return,
            };
            self.core_instances.append(self.alloc, ci) catch return error.OutOfMemory;
        }
    }

    fn decodeInstanceSection(self: *Component, payload: []const u8) !void {
        var r = Reader.init(payload);
        const count = r.readU32() catch return;
        for (0..count) |_| {
            const tag = r.readByte() catch return;
            const inst: Instance = switch (tag) {
                0x00 => blk: {
                    const comp_idx = r.readU32() catch return;
                    const arg_count = r.readU32() catch return;
                    var args = std.ArrayListUnmanaged(InstantiateArg).empty;
                    for (0..arg_count) |_| {
                        const name_len = r.readU32() catch return;
                        const name = r.readBytes(name_len) catch return;
                        const kind = r.readByte() catch return;
                        const idx = r.readU32() catch return;
                        args.append(self.alloc, .{ .name = name, .kind = kind, .idx = idx }) catch return error.OutOfMemory;
                    }
                    break :blk .{ .instantiate = .{
                        .component_idx = comp_idx,
                        .args = args.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
                    } };
                },
                0x01 => blk: {
                    const exp_count = r.readU32() catch return;
                    var exports = std.ArrayListUnmanaged(ComponentExportArg).empty;
                    for (0..exp_count) |_| {
                        const name = self.readComponentName(&r) orelse return;
                        const kind_byte = r.readByte() catch return;
                        const idx = r.readU32() catch return;
                        exports.append(self.alloc, .{
                            .name = name,
                            .kind = @enumFromInt(kind_byte),
                            .idx = idx,
                        }) catch return error.OutOfMemory;
                    }
                    break :blk .{ .from_exports = exports.toOwnedSlice(self.alloc) catch return error.OutOfMemory };
                },
                else => return,
            };
            self.instances.append(self.alloc, inst) catch return error.OutOfMemory;
        }
    }

    fn readComponentName(_: *Component, r: *Reader) ?[]const u8 {
        // Component names: discriminant byte + name string
        // 0x00 = kebab name, 0x01 = interface name
        _ = r.readByte() catch return null;
        const len = r.readU32() catch return null;
        const name = r.readBytes(len) catch return null;
        return name;
    }
};

// ── WASI P1 → P2 Adapter ─────────────────────────────────────────────

/// Maps WASI Preview 2 interface names to their Preview 1 equivalents.
/// Used by ComponentInstance to resolve P2 imports via zwasm's existing P1 support.
pub const WasiAdapter = struct {
    /// A mapping from a P2 interface to its P1 function group.
    pub const Mapping = struct {
        p2_interface: []const u8,
        p1_module: []const u8,
        p1_functions: []const []const u8,
    };

    /// Check if a component import name is a recognized WASI P2 interface.
    pub fn isWasiP2Import(name: []const u8) bool {
        for (&p2_to_p1_map) |m| {
            if (std.mem.eql(u8, m.p2_interface, name)) return true;
        }
        return false;
    }

    /// Get the P1 module name for a P2 interface.
    /// All WASI P1 functions live under "wasi_snapshot_preview1".
    pub fn getP1ModuleName(_: *const WasiAdapter, name: []const u8) ?[]const u8 {
        for (&p2_to_p1_map) |m| {
            if (std.mem.eql(u8, m.p2_interface, name)) return m.p1_module;
        }
        return null;
    }

    /// Get the list of P1 functions that implement a P2 interface.
    pub fn getP1Functions(name: []const u8) ?[]const []const u8 {
        for (&p2_to_p1_map) |m| {
            if (std.mem.eql(u8, m.p2_interface, name)) return m.p1_functions;
        }
        return null;
    }

    // P2 interface → P1 function group mapping table
    const p2_to_p1_map = [_]Mapping{
        .{
            .p2_interface = "wasi:cli/stdin",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"fd_read"},
        },
        .{
            .p2_interface = "wasi:cli/stdout",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"fd_write"},
        },
        .{
            .p2_interface = "wasi:cli/stderr",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"fd_write"},
        },
        .{
            .p2_interface = "wasi:cli/environment",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{ "environ_get", "environ_sizes_get" },
        },
        .{
            .p2_interface = "wasi:cli/arguments",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{ "args_get", "args_sizes_get" },
        },
        .{
            .p2_interface = "wasi:cli/exit",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"proc_exit"},
        },
        .{
            .p2_interface = "wasi:clocks/wall-clock",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"clock_time_get"},
        },
        .{
            .p2_interface = "wasi:clocks/monotonic-clock",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"clock_time_get"},
        },
        .{
            .p2_interface = "wasi:filesystem/types",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{
                "fd_read",           "fd_write",     "fd_close",
                "fd_seek",           "fd_tell",      "fd_sync",
                "fd_filestat_get",   "fd_readdir",   "path_open",
                "path_create_directory",
                "path_remove_directory",
                "path_unlink_file",  "path_rename",  "path_filestat_get",
                "fd_prestat_get",    "fd_prestat_dir_name",
            },
        },
        .{
            .p2_interface = "wasi:filesystem/preopens",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{ "fd_prestat_get", "fd_prestat_dir_name" },
        },
        .{
            .p2_interface = "wasi:random/random",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"random_get"},
        },
        .{
            .p2_interface = "wasi:io/poll",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{"poll_oneoff"},
        },
        .{
            .p2_interface = "wasi:io/streams",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{ "fd_read", "fd_write" },
        },
        .{
            .p2_interface = "wasi:sockets/tcp",
            .p1_module = "wasi_snapshot_preview1",
            .p1_functions = &.{ "sock_accept", "sock_recv", "sock_send", "sock_shutdown" },
        },
    };

    /// Number of recognized P2 interfaces.
    pub const interface_count = p2_to_p1_map.len;
};

// ── Utility ───────────────────────────────────────────────────────────

/// Returns true if the given bytes represent a component (not a core module).
pub fn isComponent(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    return std.mem.eql(u8, bytes[0..4], &opcode.MAGIC) and
        std.mem.eql(u8, bytes[4..8], &COMPONENT_VERSION);
}

/// Returns true if the given bytes represent a core WebAssembly module.
pub fn isCoreModule(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    return std.mem.eql(u8, bytes[0..4], &opcode.MAGIC) and
        std.mem.eql(u8, bytes[4..8], &opcode.VERSION);
}

// ── Component Instance ────────────────────────────────────────────────

/// Runtime instance of a component.
/// Created by instantiating a decoded Component with resolved imports.
pub const ComponentInstance = struct {
    alloc: Allocator,
    comp: *Component,
    // Core module instances (indexed by core instance order)
    core_modules: std.ArrayListUnmanaged(*types.WasmModule),
    // Exported component function/value names
    export_funcs: std.StringHashMapUnmanaged(ExportedFunc),

    pub const ExportedFunc = struct {
        core_instance_idx: u32,
        func_name: []const u8,
    };

    pub fn init(alloc: Allocator, comp: *Component) ComponentInstance {
        return .{
            .alloc = alloc,
            .comp = comp,
            .core_modules = .empty,
            .export_funcs = .{},
        };
    }

    pub fn deinit(self: *ComponentInstance) void {
        for (self.core_modules.items) |m| {
            m.deinit();
            self.alloc.destroy(m);
        }
        self.core_modules.deinit(self.alloc);
        self.export_funcs.deinit(self.alloc);
    }

    /// Instantiate the component: load embedded core modules,
    /// process core instance declarations, and build export map.
    pub fn instantiate(self: *ComponentInstance) !void {
        // Phase 1: Load embedded core modules
        for (self.comp.core_modules.items) |mod_bytes| {
            const m = try types.WasmModule.load(self.alloc, mod_bytes);
            self.core_modules.append(self.alloc, m) catch return error.OutOfMemory;
        }

        // Phase 2: Build export map from component exports
        for (self.comp.exports.items) |exp| {
            if (exp.kind == .func) {
                self.export_funcs.put(self.alloc, exp.name, .{
                    .core_instance_idx = 0,
                    .func_name = exp.name,
                }) catch return error.OutOfMemory;
            }
        }
    }

    /// Instantiate with imports provided as WasmModule import entries.
    pub fn instantiateWithImports(self: *ComponentInstance, imports: []const types.ImportEntry) !void {
        // Phase 1: Load embedded core modules with imports
        for (self.comp.core_modules.items) |mod_bytes| {
            const m = if (imports.len > 0)
                try types.WasmModule.loadWithImports(self.alloc, mod_bytes, imports)
            else
                try types.WasmModule.load(self.alloc, mod_bytes);
            self.core_modules.append(self.alloc, m) catch return error.OutOfMemory;
        }

        // Phase 2: Build export map from component exports
        for (self.comp.exports.items) |exp| {
            if (exp.kind == .func) {
                self.export_funcs.put(self.alloc, exp.name, .{
                    .core_instance_idx = 0,
                    .func_name = exp.name,
                }) catch return error.OutOfMemory;
            }
        }
    }

    /// Look up an exported function by name.
    pub fn getExport(self: *const ComponentInstance, name: []const u8) ?ExportedFunc {
        return self.export_funcs.get(name);
    }

    /// Get the number of loaded core module instances.
    pub fn coreModuleCount(self: *const ComponentInstance) usize {
        return self.core_modules.items.len;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "isComponent — identifies component vs module" {
    // Component magic+version
    const comp_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00 };
    try std.testing.expect(isComponent(&comp_bytes));
    try std.testing.expect(!isCoreModule(&comp_bytes));

    // Core module magic+version
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expect(!isComponent(&mod_bytes));
    try std.testing.expect(isCoreModule(&mod_bytes));

    // Too short
    try std.testing.expect(!isComponent(&[_]u8{ 0x00, 0x61 }));
}

test "SectionId — enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(SectionId.core_custom));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(SectionId.core_module));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(SectionId.@"type"));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(SectionId.canonical));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(SectionId.@"import"));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(SectionId.@"export"));
}

test "Component.decode — minimal component" {
    // Minimal component: magic + version + no sections
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00 };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();
    try std.testing.expectEqual(@as(usize, 0), comp.sections.items.len);
}

test "Component.decode — reject core module" {
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try std.testing.expectError(error.InvalidComponent, comp.decode());
}

test "Component.decode — component with core module section" {
    // Component containing one core_module section
    // Section: id=1 (core_module), size=8, payload=wasm module header
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        0x01, // section id: core_module
        0x08, // section size: 8 bytes
        0x00, 0x61, 0x73, 0x6D, // embedded module magic
        0x01, 0x00, 0x00, 0x00, // embedded module version
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 1), comp.sections.items.len);
    try std.testing.expectEqual(SectionId.core_module, comp.sections.items[0].id);
    try std.testing.expectEqual(@as(usize, 8), comp.sections.items[0].payload.len);
    try std.testing.expectEqual(@as(usize, 1), comp.core_modules.items.len);
    // Verify the embedded module is valid wasm
    try std.testing.expect(isCoreModule(comp.core_modules.items[0]));
}

test "Component.decode — multiple sections" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Section 1: core_module (id=1), size=8
        0x01, 0x08,
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // Section 2: type (id=7), size=2, payload=dummy
        0x07, 0x02, 0xAA, 0xBB,
        // Section 3: canonical (id=8), size=1, payload=dummy
        0x08, 0x01, 0xCC,
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 3), comp.sections.items.len);
    try std.testing.expectEqual(SectionId.core_module, comp.sections.items[0].id);
    try std.testing.expectEqual(SectionId.@"type", comp.sections.items[1].id);
    try std.testing.expectEqual(SectionId.canonical, comp.sections.items[2].id);
    try std.testing.expectEqual(@as(usize, 1), comp.core_modules.items.len);
}

test "Component.decode — truncated section" {
    // Section claims size=100 but only 2 bytes follow
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00,
        0x07, 0x64, // section id=7, size=100 (0x64)
        0xAA, 0xBB, // only 2 bytes
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try std.testing.expectError(error.InvalidComponent, comp.decode());
}

test "ExternKind — enum values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(ExternKind.core_module));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(ExternKind.func));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(ExternKind.@"type"));
    try std.testing.expectEqual(@as(u8, 0x05), @intFromEnum(ExternKind.instance));
}

test "Component.decode — type section with primitive defined types" {
    // Component with type section containing: bool, string, u32
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Type section (id=7)
        0x07,
        0x07, // section size: 7 bytes
        0x03, // count: 3 types
        // Type 0: defined(bool)
        0x40, 0x7f,
        // Type 1: defined(string)
        0x40, 0x73,
        // Type 2: defined(u32)
        0x40, 0x79,
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 3), comp.types.items.len);
    try std.testing.expectEqual(ValType.bool_, comp.types.items[0].defined.primitive);
    try std.testing.expectEqual(ValType.string_, comp.types.items[1].defined.primitive);
    try std.testing.expectEqual(ValType.u32_, comp.types.items[2].defined.primitive);
}

test "Component.decode — type section with list and option" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Type section (id=7)
        0x07,
        0x09, // section size: 9 bytes
        0x03, // count: 3 types
        // Type 0: defined(u8)
        0x40, 0x7d,
        // Type 1: defined(list<type 0>)
        0x40, 0x70, 0x00, // list of type index 0
        // Type 2: defined(option<type 0>)
        0x40, 0x6c, 0x00, // option of type index 0
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 3), comp.types.items.len);
    try std.testing.expectEqual(ValType.u8_, comp.types.items[0].defined.primitive);
    try std.testing.expectEqual(@as(u32, 0), comp.types.items[1].defined.list);
    try std.testing.expectEqual(@as(u32, 0), comp.types.items[2].defined.option);
}

test "Component.decode — type section with result type" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Type section
        0x07,
        0x0A, // section size
        0x03, // count: 3 types
        // Type 0: defined(u32)
        0x40, 0x79,
        // Type 1: defined(string)
        0x40, 0x73,
        // Type 2: defined(result<type 0, type 1>)
        0x40, 0x6b,
        0x00, 0x00, // ok = present, type idx 0
        0x00, 0x01, // err = present, type idx 1
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 3), comp.types.items.len);
    const rt = comp.types.items[2].defined.result;
    try std.testing.expectEqual(@as(u32, 0), rt.ok.?);
    try std.testing.expectEqual(@as(u32, 1), rt.err.?);
}

test "Component.decode — func type" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Type section
        0x07,
        0x10, // section size
        0x02, // count: 2 types
        // Type 0: defined(string)
        0x40, 0x73,
        // Type 1: func(name: type0) -> type0
        0x41,
        0x01, // 1 param
        0x04, 'n', 'a', 'm', 'e', // param name "name"
        0x00, // param type index 0
        0x01, // result tag: single unnamed
        0x00, // result type index 0
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 2), comp.types.items.len);
    const ft = comp.types.items[1].func;
    try std.testing.expectEqual(@as(usize, 1), ft.params.len);
    try std.testing.expectEqualStrings("name", ft.params[0].name);
    try std.testing.expectEqual(@as(u32, 0), ft.params[0].type_idx);
    try std.testing.expectEqual(@as(u32, 0), ft.result.unnamed);
}

test "Component.decode — resource type" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Type section
        0x07,
        0x05, // section size
        0x01, // count: 1 type
        // Type 0: resource(rep=i32, no dtor)
        0x3f,
        0x79, // rep = u32 (0x79)
        0x01, // no destructor (0x01 = absent)
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 1), comp.types.items.len);
    const rt = comp.types.items[0].resource;
    try std.testing.expectEqual(ValType.u32_, rt.rep);
    try std.testing.expect(rt.dtor == null);
}

test "Component.decode — canonical lift/lower" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Canon section (id=8)
        0x08,
        0x10, // section size
        0x02, // count: 2 canon funcs
        // Canon 0: lift core_func_idx=0, opts=[utf8, memory=0]
        0x00, 0x00, // op=lift, sub=0x00
        0x00, // core_func_idx=0
        0x02, // 2 options
        0x00, // utf8
        0x03, 0x00, // memory idx=0
        // Canon 1: lower func_idx=1, opts=[utf8, memory=0, realloc=2]
        0x01, 0x00, // op=lower, sub=0x00
        0x01, // func_idx=1
        0x03, // 3 options
        0x00, // utf8
        0x03, 0x00, // memory idx=0
        0x04, 0x02, // realloc idx=2
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 2), comp.canon_funcs.items.len);

    // Lift
    const lift = comp.canon_funcs.items[0].lift;
    try std.testing.expectEqual(@as(u32, 0), lift.core_func_idx);
    try std.testing.expectEqual(StringEncoding.utf8, lift.options.string_encoding);
    try std.testing.expectEqual(@as(u32, 0), lift.options.memory.?);

    // Lower
    const lower = comp.canon_funcs.items[1].lower;
    try std.testing.expectEqual(@as(u32, 1), lower.func_idx);
    try std.testing.expectEqual(@as(u32, 0), lower.options.memory.?);
    try std.testing.expectEqual(@as(u32, 2), lower.options.realloc.?);
}

test "Component.decode — canonical resource ops" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Canon section (id=8)
        0x08,
        0x0A, // section size
        0x03, // count: 3 canon funcs
        // resource.new(type=0)
        0x02, 0x00, 0x00,
        // resource.drop(type=0)
        0x03, 0x00, 0x00,
        // resource.rep(type=0)
        0x04, 0x00, 0x00,
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 3), comp.canon_funcs.items.len);
    try std.testing.expectEqual(@as(u32, 0), comp.canon_funcs.items[0].resource_new);
    try std.testing.expectEqual(@as(u32, 0), comp.canon_funcs.items[1].resource_drop);
    try std.testing.expectEqual(@as(u32, 0), comp.canon_funcs.items[2].resource_rep);
}

test "Component.decode — alias section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Alias section (id=6)
        0x06,
        0x0D, // section size
        0x02, // count: 2 aliases
        // Alias 0: instance export (inst=0, name="foo")
        0x00, // sort = instance_export
        0x00, // instance_idx = 0
        0x03, 'f', 'o', 'o', // name = "foo"
        // Alias 1: core instance export (inst=1, name="mem")
        0x01, // sort = core_instance_export
        0x01, // instance_idx = 1
        0x03, 'm', 'e', 'm', // name = "mem"
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 2), comp.aliases.items.len);
    const a0 = comp.aliases.items[0].instance_export;
    try std.testing.expectEqual(@as(u32, 0), a0.instance_idx);
    try std.testing.expectEqualStrings("foo", a0.name);
    const a1 = comp.aliases.items[1].core_instance_export;
    try std.testing.expectEqual(@as(u32, 1), a1.instance_idx);
    try std.testing.expectEqualStrings("mem", a1.name);
}

test "Component.decode — start section" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Start section (id=9)
        0x09,
        0x04, // section size
        0x03, // func_idx=3
        0x01, // 1 arg
        0x00, // arg value idx=0
        0x00, // 0 results
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expect(comp.start_func != null);
    const sf = comp.start_func.?;
    try std.testing.expectEqual(@as(u32, 3), sf.func_idx);
    try std.testing.expectEqual(@as(usize, 1), sf.args.len);
    try std.testing.expectEqual(@as(u32, 0), sf.args[0]);
    try std.testing.expectEqual(@as(u32, 0), sf.result_count);
}

test "Component.decode — core instance instantiate" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Core instance section (id=2)
        0x02,
        0x09, // section size
        0x01, // count: 1
        0x00, // tag=instantiate
        0x00, // module_idx=0
        0x01, // 1 arg
        0x03, 'e', 'n', 'v', // arg name="env"
        0x05, // kind=instance
        0x00, // idx=0
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 1), comp.core_instances.items.len);
    const ci = comp.core_instances.items[0].instantiate;
    try std.testing.expectEqual(@as(u32, 0), ci.module_idx);
    try std.testing.expectEqual(@as(usize, 1), ci.args.len);
    try std.testing.expectEqualStrings("env", ci.args[0].name);
}

test "Component.decode — component instance" {
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // Instance section (id=5)
        0x05,
        0x09, // section size
        0x01, // count: 1
        0x00, // tag=instantiate
        0x02, // component_idx=2
        0x01, // 1 arg
        0x03, 'a', 'p', 'i', // arg name="api"
        0x01, // kind=func
        0x05, // idx=5
    };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    try std.testing.expectEqual(@as(usize, 1), comp.instances.items.len);
    const inst = comp.instances.items[0].instantiate;
    try std.testing.expectEqual(@as(u32, 2), inst.component_idx);
    try std.testing.expectEqual(@as(usize, 1), inst.args.len);
    try std.testing.expectEqualStrings("api", inst.args[0].name);
}

test "ComponentInstance — instantiate empty component" {
    // Component with no core modules and no exports
    const bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x0D, 0x00, 0x01, 0x00 };
    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    var ci = ComponentInstance.init(std.testing.allocator, &comp);
    defer ci.deinit();
    try ci.instantiate();

    try std.testing.expectEqual(@as(usize, 0), ci.coreModuleCount());
    try std.testing.expectEqual(@as(?ComponentInstance.ExportedFunc, null), ci.getExport("anything"));
}

test "ComponentInstance — instantiate with core module" {
    // Build a component containing one minimal core wasm module
    // The core module is: magic + version + empty (no sections)
    const core_mod = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        0x01, // section id: core_module
        0x08, // section size: 8 bytes
    } ++ core_mod;

    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    var ci = ComponentInstance.init(std.testing.allocator, &comp);
    defer ci.deinit();
    try ci.instantiate();

    try std.testing.expectEqual(@as(usize, 1), ci.coreModuleCount());
}

test "ComponentInstance — export map built from component exports" {
    // Component with export section declaring a func export
    const core_mod = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    const bytes = [_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x0D, 0x00, 0x01, 0x00, // component version
        // core_module section
        0x01, 0x08,
    } ++ core_mod ++ [_]u8{
        // export section (id=11)
        0x0B,
        0x09, // section size
        0x01, // count: 1 export
        // export name: kebab-case "run"
        0x00, // discriminant: kebab
        0x03, 'r', 'u', 'n', // name
        0x01, // kind: func
        0x00, // idx: 0
    };

    var comp = Component.init(std.testing.allocator, &bytes);
    defer comp.deinit();
    try comp.decode();

    var ci = ComponentInstance.init(std.testing.allocator, &comp);
    defer ci.deinit();
    try ci.instantiate();

    try std.testing.expectEqual(@as(usize, 1), ci.coreModuleCount());
    const exp = ci.getExport("run");
    try std.testing.expect(exp != null);
    try std.testing.expectEqual(@as(u32, 0), exp.?.core_instance_idx);
}

test "WasiAdapter — recognizes P2 interfaces" {
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:cli/stdin"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:cli/stdout"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:cli/stderr"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:cli/environment"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:cli/arguments"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:cli/exit"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:clocks/wall-clock"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:clocks/monotonic-clock"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:filesystem/types"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:filesystem/preopens"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:random/random"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:io/poll"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:io/streams"));
    try std.testing.expect(WasiAdapter.isWasiP2Import("wasi:sockets/tcp"));
    // Unknown interface
    try std.testing.expect(!WasiAdapter.isWasiP2Import("wasi:http/handler"));
    try std.testing.expect(!WasiAdapter.isWasiP2Import("custom:foo/bar"));
}

test "WasiAdapter — P1 function lookup" {
    // stdin maps to fd_read
    const stdin_fns = WasiAdapter.getP1Functions("wasi:cli/stdin").?;
    try std.testing.expectEqual(@as(usize, 1), stdin_fns.len);
    try std.testing.expectEqualStrings("fd_read", stdin_fns[0]);

    // environment maps to environ_get + environ_sizes_get
    const env_fns = WasiAdapter.getP1Functions("wasi:cli/environment").?;
    try std.testing.expectEqual(@as(usize, 2), env_fns.len);
    try std.testing.expectEqualStrings("environ_get", env_fns[0]);
    try std.testing.expectEqualStrings("environ_sizes_get", env_fns[1]);

    // filesystem/types has many functions
    const fs_fns = WasiAdapter.getP1Functions("wasi:filesystem/types").?;
    try std.testing.expect(fs_fns.len >= 10);

    // Unknown returns null
    try std.testing.expectEqual(@as(?[]const []const u8, null), WasiAdapter.getP1Functions("wasi:http/handler"));
}

test "WasiAdapter — interface count" {
    try std.testing.expectEqual(@as(usize, 14), WasiAdapter.interface_count);
}
