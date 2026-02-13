// Component Model binary format decoder
// Parses WebAssembly Component binary format (layer 1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("leb128.zig").Reader;
const opcode = @import("opcode.zig");

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
        };
    }

    pub fn deinit(self: *Component) void {
        self.sections.deinit(self.alloc);
        self.core_modules.deinit(self.alloc);
        self.imports.deinit(self.alloc);
        self.exports.deinit(self.alloc);
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
                .@"import" => {
                    self.decodeImportSection(payload) catch {};
                },
                .@"export" => {
                    self.decodeExportSection(payload) catch {};
                },
                else => {},
            }
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

    fn readComponentName(_: *Component, r: *Reader) ?[]const u8 {
        // Component names: discriminant byte + name string
        // 0x00 = kebab name, 0x01 = interface name
        _ = r.readByte() catch return null;
        const len = r.readU32() catch return null;
        const name = r.readBytes(len) catch return null;
        return name;
    }
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
