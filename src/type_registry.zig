// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Store-level type registry with hash consing for cross-module type identity.
//!
//! Each rec group is canonicalized and deduplicated: structurally identical
//! rec groups from different modules share the same global type IDs.
//! This enables O(1) call_indirect type matching across modules.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const RecGroup = module_mod.RecGroup;
const TypeDef = module_mod.TypeDef;
const CompositeType = module_mod.CompositeType;
const StorageType = module_mod.StorageType;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;

/// Canonical representation of a single type within a rec group.
/// Intra-group references use relative offsets with a marker bit;
/// cross-group references use previously-assigned global IDs.
const CanonTypeDef = struct {
    composite: CanonComposite,
    super_type: u32, // global ID or NONE
    is_final: bool,

    const NONE: u32 = std.math.maxInt(u32);
};

const CanonComposite = union(enum) {
    func: struct { params: []const u32, results: []const u32 },
    struct_type: []const CanonField,
    array_type: CanonField,
};

const CanonField = struct {
    storage: u32, // canonical val encoding or PACKED_I8/PACKED_I16
    mutable: bool,

    const PACKED_I8: u32 = 0xFFFFFFFE;
    const PACKED_I16: u32 = 0xFFFFFFFD;
};

/// A registered rec group for deduplication scanning.
const RegisteredRecGroup = struct {
    count: u32,
    first_global_id: u32,
    canon_types: []CanonTypeDef,
};

/// Info about a registered type, indexed by global type ID.
const TypeInfo = struct {
    params: ?[]const ValType, // null for struct/array
    results: ?[]const ValType,
    super_type: u32, // global ID or NONE
    is_final: bool,
};

const NONE: u32 = std.math.maxInt(u32);

pub const TypeRegistry = struct {
    alloc: Allocator,
    registered_groups: ArrayList(RegisteredRecGroup),
    type_info: ArrayList(TypeInfo),

    pub fn init(alloc: Allocator) TypeRegistry {
        return .{
            .alloc = alloc,
            .registered_groups = .empty,
            .type_info = .empty,
        };
    }

    pub fn deinit(self: *TypeRegistry) void {
        for (self.registered_groups.items) |grp| {
            for (grp.canon_types) |ct| {
                switch (ct.composite) {
                    .func => |f| {
                        self.alloc.free(f.params);
                        self.alloc.free(f.results);
                    },
                    .struct_type => |fields| self.alloc.free(fields),
                    .array_type => {},
                }
            }
            self.alloc.free(grp.canon_types);
        }
        self.registered_groups.deinit(self.alloc);
        self.type_info.deinit(self.alloc);
    }

    /// Register all rec groups from a module. Returns a mapping from
    /// module-local type index to global type ID.
    pub fn registerModuleTypes(self: *TypeRegistry, module: *const Module) ![]u32 {
        const n = module.types.items.len;
        if (n == 0) return &.{};

        const mapping = try self.alloc.alloc(u32, n);
        errdefer self.alloc.free(mapping);

        for (module.rec_groups.items) |group| {
            // Build canonical representation for this rec group
            const canon_types = try self.alloc.alloc(CanonTypeDef, group.count);
            errdefer self.alloc.free(canon_types);

            for (0..group.count) |i| {
                const type_idx = group.start + @as(u32, @intCast(i));
                const td = module.types.items[type_idx];
                canon_types[i] = try self.canonicalize(td, group, mapping, module);
            }

            // Linear scan for a matching existing group
            var matched: ?u32 = null;
            for (self.registered_groups.items) |existing| {
                if (existing.count != group.count) continue;
                if (canonGroupsEqual(canon_types, existing.canon_types)) {
                    matched = existing.first_global_id;
                    break;
                }
            }

            if (matched) |first_id| {
                // Reuse existing global IDs
                for (0..group.count) |i| {
                    mapping[group.start + i] = first_id + @as(u32, @intCast(i));
                }
                // Free the canon_types we built since we're reusing
                for (canon_types) |ct| {
                    switch (ct.composite) {
                        .func => |f| {
                            self.alloc.free(f.params);
                            self.alloc.free(f.results);
                        },
                        .struct_type => |fields| self.alloc.free(fields),
                        .array_type => {},
                    }
                }
                self.alloc.free(canon_types);
            } else {
                // Allocate new global IDs
                const first_id: u32 = @intCast(self.type_info.items.len);
                for (0..group.count) |i| {
                    const type_idx = group.start + @as(u32, @intCast(i));
                    const td = module.types.items[type_idx];
                    const ft = td.getFunc();

                    // Resolve super_type to global ID
                    var super_global: u32 = NONE;
                    if (td.super_types.len > 0) {
                        const s = td.super_types[0];
                        if (s >= group.start and s < group.start + group.count) {
                            // Intra-group ref
                            super_global = first_id + (s - group.start);
                        } else if (s < mapping.len) {
                            super_global = mapping[s];
                        }
                    }

                    try self.type_info.append(self.alloc, .{
                        .params = if (ft) |f| f.params else null,
                        .results = if (ft) |f| f.results else null,
                        .super_type = super_global,
                        .is_final = td.is_final,
                    });
                    mapping[group.start + i] = first_id + @as(u32, @intCast(i));
                }

                try self.registered_groups.append(self.alloc, .{
                    .count = group.count,
                    .first_global_id = first_id,
                    .canon_types = canon_types,
                });
            }
        }

        return mapping;
    }

    /// Register a standalone func type (for cross-store function copies).
    /// Returns the global type ID, reusing an existing one if structurally identical.
    pub fn registerFuncType(self: *TypeRegistry, params: []const ValType, results: []const ValType) !u32 {
        // Build canonical representation
        const canon_params = try self.canonValTypeSlice(params, .{ .start = 0, .count = 0 }, &.{}, null);
        errdefer self.alloc.free(canon_params);
        const canon_results = try self.canonValTypeSlice(results, .{ .start = 0, .count = 0 }, &.{}, null);
        errdefer self.alloc.free(canon_results);

        // Search existing single-type groups for a match
        for (self.registered_groups.items) |existing| {
            if (existing.count != 1) continue;
            const ct = existing.canon_types[0];
            if (!ct.is_final) continue;
            if (ct.super_type != NONE) continue;
            switch (ct.composite) {
                .func => |f| {
                    if (std.mem.eql(u32, f.params, canon_params) and
                        std.mem.eql(u32, f.results, canon_results))
                    {
                        self.alloc.free(canon_params);
                        self.alloc.free(canon_results);
                        return existing.first_global_id;
                    }
                },
                else => {},
            }
        }

        // Not found — allocate new
        const global_id: u32 = @intCast(self.type_info.items.len);
        try self.type_info.append(self.alloc, .{
            .params = params,
            .results = results,
            .super_type = NONE,
            .is_final = true,
        });

        const canon_types = try self.alloc.alloc(CanonTypeDef, 1);
        canon_types[0] = .{
            .composite = .{ .func = .{ .params = canon_params, .results = canon_results } },
            .super_type = NONE,
            .is_final = true,
        };
        try self.registered_groups.append(self.alloc, .{
            .count = 1,
            .first_global_id = global_id,
            .canon_types = canon_types,
        });

        return global_id;
    }

    /// Check if global type `sub` is a subtype of (or equal to) global type `super`.
    pub fn isSubtype(self: *const TypeRegistry, sub: u32, super: u32) bool {
        if (sub == super) return true;
        if (sub >= self.type_info.items.len) return false;
        var current = sub;
        while (true) {
            if (current >= self.type_info.items.len) return false;
            const info = self.type_info.items[current];
            if (info.super_type == NONE) return false;
            current = info.super_type;
            if (current == super) return true;
        }
    }

    // ---- Internal helpers ----

    fn canonicalize(self: *TypeRegistry, td: TypeDef, group: RecGroup, mapping: []const u32, module: *const Module) !CanonTypeDef {
        const super_type = if (td.super_types.len > 0)
            self.canonRef(td.super_types[0], group, mapping)
        else
            NONE;

        const composite: CanonComposite = switch (td.composite) {
            .func => |f| .{ .func = .{
                .params = try self.canonValTypeSlice(f.params, group, mapping, module),
                .results = try self.canonValTypeSlice(f.results, group, mapping, module),
            } },
            .struct_type => |s| .{ .struct_type = try self.canonFieldSlice(s.fields, group, mapping, module) },
            .array_type => |a| .{ .array_type = self.canonField(a.field, group, mapping, module) },
        };

        return .{
            .composite = composite,
            .super_type = super_type,
            .is_final = td.is_final,
        };
    }

    fn canonValTypeSlice(self: *TypeRegistry, types: []const ValType, group: RecGroup, mapping: []const u32, module: ?*const Module) ![]u32 {
        const result = try self.alloc.alloc(u32, types.len);
        for (types, 0..) |vt, i| {
            result[i] = canonValType(vt, group, mapping, module);
        }
        return result;
    }

    fn canonFieldSlice(self: *TypeRegistry, fields: []const module_mod.FieldType, group: RecGroup, mapping: []const u32, module: ?*const Module) ![]CanonField {
        const result = try self.alloc.alloc(CanonField, fields.len);
        for (fields, 0..) |f, i| {
            result[i] = self.canonField(f, group, mapping, module);
        }
        return result;
    }

    fn canonField(_: *TypeRegistry, field: module_mod.FieldType, group: RecGroup, mapping: []const u32, module: ?*const Module) CanonField {
        const storage: u32 = switch (field.storage) {
            .i8 => CanonField.PACKED_I8,
            .i16 => CanonField.PACKED_I16,
            .val => |vt| canonValType(vt, group, mapping, module),
        };
        return .{ .storage = storage, .mutable = field.mutable };
    }

    fn canonRef(_: *TypeRegistry, idx: u32, group: RecGroup, mapping: []const u32) u32 {
        // Abstract heap type codes (>= 0x69) are not type indices
        if (idx >= 0x69) return idx;
        // Intra-group reference: relative offset with marker bit
        if (idx >= group.start and idx < group.start + group.count) {
            return 0x80000000 | (idx - group.start);
        }
        // Cross-group reference: use already-computed global ID
        if (idx < mapping.len) return mapping[idx];
        return idx;
    }

    fn canonValType(vt: ValType, group: RecGroup, mapping: []const u32, module: ?*const Module) u32 {
        _ = module;
        return switch (vt) {
            .i32 => 0x7F,
            .i64 => 0x7E,
            .f32 => 0x7D,
            .f64 => 0x7C,
            .v128 => 0x7B,
            .funcref => 0x70,
            .externref => 0x6F,
            .exnref => 0x69,
            .ref_type => |idx| blk: {
                // Encode as: nullable_bit(0) | canonRef << 1
                const canon = canonRefStatic(idx, group, mapping);
                break :blk 0x40000000 | canon;
            },
            .ref_null_type => |idx| blk: {
                const canon = canonRefStatic(idx, group, mapping);
                break :blk 0x20000000 | canon;
            },
        };
    }

    fn canonRefStatic(idx: u32, group: RecGroup, mapping: []const u32) u32 {
        if (idx >= 0x69) return idx;
        if (idx >= group.start and idx < group.start + group.count) {
            return 0x80000000 | (idx - group.start);
        }
        if (idx < mapping.len) return mapping[idx];
        return idx;
    }

    fn canonGroupsEqual(a: []const CanonTypeDef, b: []const CanonTypeDef) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (!canonTypeDefsEqual(ca, cb)) return false;
        }
        return true;
    }

    fn canonTypeDefsEqual(a: CanonTypeDef, b: CanonTypeDef) bool {
        if (a.is_final != b.is_final) return false;
        if (a.super_type != b.super_type) return false;
        return canonCompositeEqual(a.composite, b.composite);
    }

    fn canonCompositeEqual(a: CanonComposite, b: CanonComposite) bool {
        switch (a) {
            .func => |fa| {
                const fb = switch (b) {
                    .func => |f| f,
                    else => return false,
                };
                return std.mem.eql(u32, fa.params, fb.params) and
                    std.mem.eql(u32, fa.results, fb.results);
            },
            .struct_type => |sa| {
                const sb = switch (b) {
                    .struct_type => |s| s,
                    else => return false,
                };
                if (sa.len != sb.len) return false;
                for (sa, sb) |fa, fb| {
                    if (fa.storage != fb.storage or fa.mutable != fb.mutable) return false;
                }
                return true;
            },
            .array_type => |aa| {
                const ab = switch (b) {
                    .array_type => |arr| arr,
                    else => return false,
                };
                return aa.storage == ab.storage and aa.mutable == ab.mutable;
            },
        }
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "TypeRegistry — same func type gets same global ID" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    // Simulate two modules with the same func type (i32, i32) -> i32
    // Module A: one rec group with one func type
    const mod_a = createTestModule(testing.allocator, &.{.i32}, &.{ .i32, .i32 }, &.{.i32});
    defer destroyTestModule(testing.allocator, mod_a);
    const mapping_a = try reg.registerModuleTypes(&mod_a);
    defer testing.allocator.free(mapping_a);

    // Module B: same structure
    const mod_b = createTestModule(testing.allocator, &.{.i32}, &.{ .i32, .i32 }, &.{.i32});
    defer destroyTestModule(testing.allocator, mod_b);
    const mapping_b = try reg.registerModuleTypes(&mod_b);
    defer testing.allocator.free(mapping_b);

    // Same structure → same global ID
    try testing.expectEqual(mapping_a[0], mapping_b[0]);
}

test "TypeRegistry — different func types get different global IDs" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    // Module A: (i32, i32) -> i32
    const mod_a = createTestModule(testing.allocator, &.{.i32}, &.{ .i32, .i32 }, &.{.i32});
    defer destroyTestModule(testing.allocator, mod_a);
    const mapping_a = try reg.registerModuleTypes(&mod_a);
    defer testing.allocator.free(mapping_a);

    // Module B: (i64) -> i64
    const mod_b = createTestModule(testing.allocator, &.{.i64}, &.{.i64}, &.{.i64});
    defer destroyTestModule(testing.allocator, mod_b);
    const mapping_b = try reg.registerModuleTypes(&mod_b);
    defer testing.allocator.free(mapping_b);

    // Different structure → different global IDs
    try testing.expect(mapping_a[0] != mapping_b[0]);
}

test "TypeRegistry — registerFuncType standalone dedup" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    const params = &[_]ValType{ .i32, .i32 };
    const results = &[_]ValType{.i32};
    const id1 = try reg.registerFuncType(params, results);
    const id2 = try reg.registerFuncType(params, results);
    try testing.expectEqual(id1, id2);

    // Different type → different ID
    const id3 = try reg.registerFuncType(&.{.i64}, &.{.i64});
    try testing.expect(id3 != id1);
}

test "TypeRegistry — registerFuncType matches module registration" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    // Register via module first
    const mod = createTestModule(testing.allocator, &.{.i32}, &.{ .i32, .i32 }, &.{.i32});
    defer destroyTestModule(testing.allocator, mod);
    const mapping = try reg.registerModuleTypes(&mod);
    defer testing.allocator.free(mapping);

    // Then register same type standalone
    const standalone_id = try reg.registerFuncType(&.{ .i32, .i32 }, &.{.i32});
    try testing.expectEqual(mapping[0], standalone_id);
}

test "TypeRegistry — isSubtype walks chain" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    // Create a module with subtype chain: type 0 (base), type 1 (sub of 0)
    var mod = createTestModuleWithSubtype(testing.allocator);
    defer destroyTestModuleWithSubtype(testing.allocator, &mod);
    const mapping = try reg.registerModuleTypes(&mod);
    defer testing.allocator.free(mapping);

    // type 1 is subtype of type 0
    try testing.expect(reg.isSubtype(mapping[1], mapping[0]));
    // type 0 is NOT subtype of type 1
    try testing.expect(!reg.isSubtype(mapping[0], mapping[1]));
    // reflexive
    try testing.expect(reg.isSubtype(mapping[0], mapping[0]));
}

test "TypeRegistry — empty module returns empty" {
    var reg = TypeRegistry.init(testing.allocator);
    defer reg.deinit();

    var mod = Module.init(testing.allocator, "");
    defer mod.deinit();
    // Empty module (no types)
    const mapping = try reg.registerModuleTypes(&mod);
    try testing.expectEqual(@as(usize, 0), mapping.len);
}

// ---- Test helpers ----

/// Create a minimal Module with one func type in one rec group.
fn createTestModule(alloc: Allocator, vt_slice: []const ValType, params: []const ValType, results: []const ValType) Module {
    _ = vt_slice;
    var mod = Module.init(alloc, "");
    mod.types.append(alloc, .{
        .composite = .{ .func = .{ .params = params, .results = results } },
    }) catch unreachable;
    mod.rec_groups.append(alloc, .{ .start = 0, .count = 1 }) catch unreachable;
    return mod;
}

fn destroyTestModule(alloc: Allocator, mod: Module) void {
    // Don't free params/results — they're comptime slices
    var m = mod;
    m.types.deinit(alloc);
    m.rec_groups.deinit(alloc);
}

/// Create a module with two func types where type 1 is a subtype of type 0.
fn createTestModuleWithSubtype(alloc: Allocator) Module {
    var mod = Module.init(alloc, "");
    // Type 0: base func () -> ()
    mod.types.append(alloc, .{
        .composite = .{ .func = .{ .params = &.{}, .results = &.{} } },
        .is_final = false,
    }) catch unreachable;
    // Type 1: sub of type 0, same signature
    const supers = alloc.alloc(u32, 1) catch unreachable;
    supers[0] = 0;
    mod.types.append(alloc, .{
        .composite = .{ .func = .{ .params = &.{}, .results = &.{} } },
        .super_types = supers,
        .is_final = true,
    }) catch unreachable;
    // Two separate rec groups (each containing one type)
    mod.rec_groups.append(alloc, .{ .start = 0, .count = 1 }) catch unreachable;
    mod.rec_groups.append(alloc, .{ .start = 1, .count = 1 }) catch unreachable;
    return mod;
}

fn destroyTestModuleWithSubtype(alloc: Allocator, mod: *Module) void {
    if (mod.types.items.len > 1 and mod.types.items[1].super_types.len > 0) {
        alloc.free(mod.types.items[1].super_types);
    }
    mod.types.deinit(alloc);
    mod.rec_groups.deinit(alloc);
}
