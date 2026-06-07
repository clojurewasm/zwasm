//! WIT **resolver** (CM campaign chunk A4; spec `component-model/design/mvp/WIT.md`).
//!
//! Takes the parsed `Ast` and binds its name references into a resolved model
//! — the input the canonical ABI (B-chunks) consumes. For the primitive
//! subset that means: index the file's interfaces by name and resolve each
//! `world` import/export item to a concrete interface (local index) or mark it
//! `external` (a name defined in another package, bound at link time). Func
//! param/result types are already concrete primitives at the AST level; named
//! type references (records / aliases / `use`) resolve once those forms land
//! (A4+ / B / C) — until then a named ref surfaces a typed `UnresolvedType`,
//! never a silent skip (`no_workaround`).
//!
//! No-copy: re-derived from `WIT.md`'s name-resolution rules; v1 `wit.zig` is
//! the structural textbook for the resolved-model shape.

const std = @import("std");

const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;
const Interface = parser.Interface;
const ExternKind = parser.ExternKind;
const PackageId = parser.PackageId;
const Type = parser.Type;

/// A resolved interface reference: a local interface (index into
/// `ResolvedModel.interfaces`) or an unresolved external name (another
/// package), to be bound when the package graph is linked.
pub const InterfaceRef = union(enum) {
    local: u32,
    external: []const u8,
};

pub const ResolvedWorldItem = struct {
    kind: ExternKind,
    iface: InterfaceRef,
};

pub const ResolvedWorld = struct {
    name: []const u8,
    items: []const ResolvedWorldItem,
};

/// The resolved WIT model. Borrows interface/identifier data from the source
/// `Ast` (which must outlive it); owns the resolved-world allocations in
/// `arena`.
pub const ResolvedModel = struct {
    arena: std.heap.ArenaAllocator,
    package: ?PackageId,
    interfaces: []const Interface,
    worlds: []const ResolvedWorld,

    pub fn deinit(self: *ResolvedModel) void {
        self.arena.deinit();
    }

    /// Find a local interface by name.
    pub fn interfaceIndex(self: *const ResolvedModel, name: []const u8) ?u32 {
        for (self.interfaces, 0..) |iface, i| {
            if (std.mem.eql(u8, iface.name, name)) return @intCast(i);
        }
        return null;
    }
};

pub const Error = error{
    DuplicateInterface,
    UnresolvedType,
    OutOfMemory,
};

/// Validate that a type is fully concrete in the current model. Primitives are
/// always concrete; named references are unresolved until type defs land.
fn checkType(ty: Type) Error!void {
    switch (ty) {
        .primitive => {},
        .named => return Error.UnresolvedType,
    }
}

/// Resolve an `Ast` into a `ResolvedModel`. `ast` must outlive the result.
pub fn resolve(parent: Allocator, ast: *const parser.Ast) Error!ResolvedModel {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Reject duplicate interface names (a name must resolve unambiguously).
    for (ast.interfaces, 0..) |iface, i| {
        for (ast.interfaces[0..i]) |prev| {
            if (std.mem.eql(u8, iface.name, prev.name)) return Error.DuplicateInterface;
        }
        // Every func type in a local interface must be concrete.
        for (iface.funcs) |f| {
            for (f.params) |p| try checkType(p.ty);
            if (f.result) |r| try checkType(r);
        }
    }

    var worlds: std.ArrayList(ResolvedWorld) = .empty;
    for (ast.worlds) |w| {
        var items: std.ArrayList(ResolvedWorldItem) = .empty;
        for (w.items) |item| {
            const ref: InterfaceRef = blk: {
                for (ast.interfaces, 0..) |iface, i| {
                    if (std.mem.eql(u8, iface.name, item.name)) break :blk .{ .local = @intCast(i) };
                }
                break :blk .{ .external = item.name };
            };
            try items.append(a, .{ .kind = item.kind, .iface = ref });
        }
        try worlds.append(a, .{ .name = w.name, .items = try items.toOwnedSlice(a) });
    }

    return .{
        .arena = arena,
        .package = ast.package,
        .interfaces = ast.interfaces,
        .worlds = try worlds.toOwnedSlice(a),
    };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

fn resolveSrc(src: []const u8) !struct { ast: parser.Ast, model: ResolvedModel } {
    var ast = try parser.parse(testing.allocator, src);
    errdefer ast.deinit();
    const model = try resolve(testing.allocator, &ast);
    return .{ .ast = ast, .model = model };
}

test "resolve: multi-interface world binds import/export to local interfaces" {
    const src =
        \\package example:app;
        \\interface producer { make: func() -> u32; }
        \\interface consumer { take: func(v: u32); }
        \\world app {
        \\  import producer;
        \\  export consumer;
        \\}
    ;
    var r = try resolveSrc(src);
    defer r.ast.deinit();
    defer r.model.deinit();

    try testing.expectEqual(@as(usize, 2), r.model.interfaces.len);
    try testing.expectEqual(@as(usize, 1), r.model.worlds.len);

    const items = r.model.worlds[0].items;
    try testing.expectEqual(ExternKind.import, items[0].kind);
    try testing.expectEqual(@as(u32, 0), items[0].iface.local); // producer
    try testing.expectEqual(ExternKind.@"export", items[1].kind);
    try testing.expectEqual(@as(u32, 1), items[1].iface.local); // consumer

    try testing.expectEqual(@as(?u32, 0), r.model.interfaceIndex("producer"));
    try testing.expectEqual(@as(?u32, null), r.model.interfaceIndex("missing"));
}

test "resolve: a world item naming another package is external" {
    const src =
        \\world app { import wasi-clocks; }
    ;
    var r = try resolveSrc(src);
    defer r.ast.deinit();
    defer r.model.deinit();
    try testing.expectEqualStrings("wasi-clocks", r.model.worlds[0].items[0].iface.external);
}

test "resolve: duplicate interface name is rejected" {
    const src =
        \\interface i { a: func(); }
        \\interface i { b: func(); }
    ;
    var ast = try parser.parse(testing.allocator, src);
    defer ast.deinit();
    try testing.expectError(Error.DuplicateInterface, resolve(testing.allocator, &ast));
}

test "resolve: an unresolved named type in a func is rejected" {
    var ast = try parser.parse(testing.allocator, "interface i { f: func(p: undefined-type); }");
    defer ast.deinit();
    try testing.expectError(Error.UnresolvedType, resolve(testing.allocator, &ast));
}

test "resolve: primitive-only model resolves clean (Tier 0 close)" {
    const src =
        \\package example:greet;
        \\interface greet { greet: func(name: string) -> string; }
    ;
    var r = try resolveSrc(src);
    defer r.ast.deinit();
    defer r.model.deinit();
    try testing.expectEqualStrings("example", r.model.package.?.namespace);
    try testing.expectEqual(@as(usize, 0), r.model.worlds.len);
    try testing.expectEqual(parser.PrimType.string, r.model.interfaces[0].funcs[0].result.?.primitive);
}
