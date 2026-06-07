//! WIT **parser** (CM campaign chunk A3; spec `component-model/design/mvp/WIT.md`).
//!
//! Parses the WIT token stream into an AST for the primitive subset:
//! `package` decl + `interface` (with `func` items over primitive / named-ref
//! params and an optional single result) + `world` (import/export items). The
//! richer surface — `use`, `type` aliases, `record`/`variant`/`enum`/`flags`,
//! resources/handles, named & multiple results, `@version` semver — is decoded
//! in later chunks (A4 resolver + B/C); here those forms surface a typed
//! `ParseError`, never a silent skip (`no_workaround`).
//!
//! No-copy: re-derived from the current `WIT.md`. Primitive type names reuse
//! `component.types.PrimValType` (one axis: "which interface primitive"), kept
//! distinct from `runtime.Value` per `single_slot_dual_meaning`.

const std = @import("std");

const lexer = @import("lexer.zig");
const types = @import("../types.zig");

const Allocator = std.mem.Allocator;
const Lexer = lexer.Lexer;
const Token = lexer.Token;
const TokenTag = lexer.TokenTag;

/// WIT primitive type set (same primitives as the binary `primvaltype`).
pub const PrimType = types.PrimValType;

/// A WIT type in the primitive subset: a primitive, or a reference to a named
/// type resolved later (A4).
pub const Type = union(enum) {
    primitive: PrimType,
    named: []const u8,
};

pub const Param = struct {
    name: []const u8,
    ty: Type,
};

pub const Func = struct {
    name: []const u8,
    params: []const Param,
    result: ?Type,
};

pub const Interface = struct {
    name: []const u8,
    funcs: []const Func,
};

pub const ExternKind = enum { import, @"export" };

/// A `world` import/export of a named interface/func (the named-ref form;
/// inline interfaces defer to a later chunk).
pub const WorldItem = struct {
    kind: ExternKind,
    name: []const u8,
};

pub const World = struct {
    name: []const u8,
    items: []const WorldItem,
};

pub const PackageId = struct {
    namespace: []const u8,
    name: []const u8,
};

/// Parsed WIT file. Owns its allocations in `arena`; all slices borrow text
/// from the source string.
pub const Ast = struct {
    arena: std.heap.ArenaAllocator,
    package: ?PackageId,
    interfaces: []const Interface,
    worlds: []const World,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
    }
};

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    UnknownPrimitive,
    UnsupportedItem,
    OutOfMemory,
} || lexer.Error;

const Parser = struct {
    lex: Lexer,
    arena: Allocator,

    fn expect(self: *Parser, tag: TokenTag) Error!Token {
        const tok = try self.lex.next();
        if (tok.tag != tag) return Error.UnexpectedToken;
        return tok;
    }

    fn expectIdent(self: *Parser) Error![]const u8 {
        return (try self.expect(.ident)).text;
    }

    fn eat(self: *Parser, tag: TokenTag) Error!bool {
        if ((try self.lex.peek()).tag == tag) {
            _ = try self.lex.next();
            return true;
        }
        return false;
    }

    /// `package <ns>:<name> ;` (the `@version` suffix defers — see file head).
    fn parsePackage(self: *Parser) Error!PackageId {
        const namespace = try self.expectIdent();
        _ = try self.expect(.colon);
        const name = try self.expectIdent();
        if ((try self.lex.peek()).tag == .at) return Error.UnsupportedItem; // @version deferred
        _ = try self.expect(.semicolon);
        return .{ .namespace = namespace, .name = name };
    }

    fn parsePrimType(name: []const u8) Error!PrimType {
        const map = std.StaticStringMap(PrimType).initComptime(.{
            .{ "bool", .bool },     .{ "s8", .s8 },   .{ "u8", .u8 },
            .{ "s16", .s16 },       .{ "u16", .u16 }, .{ "s32", .s32 },
            .{ "u32", .u32 },       .{ "s64", .s64 }, .{ "u64", .u64 },
            .{ "f32", .f32 },       .{ "f64", .f64 }, .{ "char", .char },
            .{ "string", .string },
        });
        return map.get(name) orelse Error.UnknownPrimitive;
    }

    /// A type position: a primitive keyword, or a named-type reference.
    fn parseType(self: *Parser) Error!Type {
        const name = try self.expectIdent();
        if (parsePrimType(name)) |p| {
            return .{ .primitive = p };
        } else |err| switch (err) {
            Error.UnknownPrimitive => return .{ .named = name },
            else => return err,
        }
    }

    /// `<name>: func( <params> ) [-> <result>] ;`
    fn parseFunc(self: *Parser, name: []const u8) Error!Func {
        _ = try self.expect(.colon);
        const kw = try self.expectIdent();
        if (!std.mem.eql(u8, kw, "func")) return Error.UnsupportedItem;
        _ = try self.expect(.lparen);

        var params: std.ArrayList(Param) = .empty;
        if ((try self.lex.peek()).tag != .rparen) {
            while (true) {
                const pname = try self.expectIdent();
                _ = try self.expect(.colon);
                const ty = try self.parseType();
                try params.append(self.arena, .{ .name = pname, .ty = ty });
                if (try self.eat(.comma)) continue;
                break;
            }
        }
        _ = try self.expect(.rparen);

        var result: ?Type = null;
        if (try self.eat(.arrow)) {
            // Named/tuple results `(a: t, ...)` defer; single-type only here.
            if ((try self.lex.peek()).tag == .lparen) return Error.UnsupportedItem;
            result = try self.parseType();
        }
        _ = try self.expect(.semicolon);
        return .{ .name = name, .params = try params.toOwnedSlice(self.arena), .result = result };
    }

    /// `interface <name> { (<func>)* }`
    fn parseInterface(self: *Parser) Error!Interface {
        const name = try self.expectIdent();
        _ = try self.expect(.lbrace);
        var funcs: std.ArrayList(Func) = .empty;
        while ((try self.lex.peek()).tag != .rbrace) {
            const item_name = try self.expectIdent();
            try funcs.append(self.arena, try self.parseFunc(item_name));
        }
        _ = try self.expect(.rbrace);
        return .{ .name = name, .funcs = try funcs.toOwnedSlice(self.arena) };
    }

    /// `world <name> { (import|export <ident> ;)* }`
    fn parseWorld(self: *Parser) Error!World {
        const name = try self.expectIdent();
        _ = try self.expect(.lbrace);
        var items: std.ArrayList(WorldItem) = .empty;
        while ((try self.lex.peek()).tag != .rbrace) {
            const kw = try self.expectIdent();
            const kind: ExternKind = if (std.mem.eql(u8, kw, "import"))
                .import
            else if (std.mem.eql(u8, kw, "export"))
                .@"export"
            else
                return Error.UnsupportedItem;
            const item_name = try self.expectIdent();
            // Inline `: func(...)` / `: interface {...}` world items defer.
            if ((try self.lex.peek()).tag != .semicolon) return Error.UnsupportedItem;
            _ = try self.expect(.semicolon);
            try items.append(self.arena, .{ .kind = kind, .name = item_name });
        }
        _ = try self.expect(.rbrace);
        return .{ .name = name, .items = try items.toOwnedSlice(self.arena) };
    }
};

/// Parse a WIT source string into an `Ast`. The returned AST owns its
/// allocations (`deinit`) and borrows identifier text from `src`.
pub fn parse(parent: Allocator, src: []const u8) Error!Ast {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    var p = Parser{ .lex = Lexer.init(src), .arena = arena.allocator() };

    var package: ?PackageId = null;
    var interfaces: std.ArrayList(Interface) = .empty;
    var worlds: std.ArrayList(World) = .empty;

    while (true) {
        const tok = try p.lex.peek();
        if (tok.tag == .eof) break;
        if (tok.tag != .ident) return Error.UnexpectedToken;

        if (std.mem.eql(u8, tok.text, "package")) {
            _ = try p.lex.next();
            package = try p.parsePackage();
        } else if (std.mem.eql(u8, tok.text, "interface")) {
            _ = try p.lex.next();
            try interfaces.append(p.arena, try p.parseInterface());
        } else if (std.mem.eql(u8, tok.text, "world")) {
            _ = try p.lex.next();
            try worlds.append(p.arena, try p.parseWorld());
        } else {
            // `use` / top-level `type` defer to A4.
            return Error.UnsupportedItem;
        }
    }

    return .{
        .arena = arena,
        .package = package,
        .interfaces = try interfaces.toOwnedSlice(p.arena),
        .worlds = try worlds.toOwnedSlice(p.arena),
    };
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

test "parse: 10_greet-class interface (string -> string)" {
    const src =
        \\// A simple greeting interface for testing WIT parsing.
        \\package example:greet;
        \\
        \\interface greet {
        \\  // Greet a person by name.
        \\  greet: func(name: string) -> string;
        \\}
    ;
    var ast = try parse(testing.allocator, src);
    defer ast.deinit();

    try testing.expectEqualStrings("example", ast.package.?.namespace);
    try testing.expectEqualStrings("greet", ast.package.?.name);
    try testing.expectEqual(@as(usize, 1), ast.interfaces.len);

    const iface = ast.interfaces[0];
    try testing.expectEqualStrings("greet", iface.name);
    try testing.expectEqual(@as(usize, 1), iface.funcs.len);
    try testing.expectEqualStrings("greet", iface.funcs[0].name);
    try testing.expectEqualStrings("name", iface.funcs[0].params[0].name);
    try testing.expectEqual(PrimType.string, iface.funcs[0].params[0].ty.primitive);
    try testing.expectEqual(PrimType.string, iface.funcs[0].result.?.primitive);
}

test "parse: 11_math-class interface (multiple primitive funcs + no-return)" {
    const src =
        \\package example:math;
        \\interface math {
        \\  add: func(a: s32, b: s32) -> s32;
        \\  multiply: func(x: f64, y: f64) -> f64;
        \\  is-even: func(n: u32) -> bool;
        \\  negate: func(value: s64) -> s64;
        \\  no-return: func(msg: string);
        \\}
    ;
    var ast = try parse(testing.allocator, src);
    defer ast.deinit();

    const f = ast.interfaces[0].funcs;
    try testing.expectEqual(@as(usize, 5), f.len);

    try testing.expectEqualStrings("add", f[0].name);
    try testing.expectEqual(PrimType.s32, f[0].params[0].ty.primitive);
    try testing.expectEqual(PrimType.s32, f[0].params[1].ty.primitive);
    try testing.expectEqual(PrimType.s32, f[0].result.?.primitive);

    try testing.expectEqualStrings("is-even", f[2].name);
    try testing.expectEqual(PrimType.u32, f[2].params[0].ty.primitive);
    try testing.expectEqual(PrimType.bool, f[2].result.?.primitive);

    // `no-return` has no `-> result`.
    try testing.expectEqualStrings("no-return", f[4].name);
    try testing.expectEqual(@as(?Type, null), f[4].result);
}

test "parse: zero-param func" {
    var ast = try parse(testing.allocator, "interface i { now: func() -> u64; }");
    defer ast.deinit();
    const fn0 = ast.interfaces[0].funcs[0];
    try testing.expectEqual(@as(usize, 0), fn0.params.len);
    try testing.expectEqual(PrimType.u64, fn0.result.?.primitive);
}

test "parse: named-type param reference resolves later (A4)" {
    var ast = try parse(testing.allocator, "interface i { f: func(p: my-type) -> other; }");
    defer ast.deinit();
    const fn0 = ast.interfaces[0].funcs[0];
    try testing.expectEqualStrings("my-type", fn0.params[0].ty.named);
    try testing.expectEqualStrings("other", fn0.result.?.named);
}

test "parse: world with import/export items" {
    const src =
        \\package p:w;
        \\world app {
        \\  import logging;
        \\  export run;
        \\}
    ;
    var ast = try parse(testing.allocator, src);
    defer ast.deinit();
    try testing.expectEqual(@as(usize, 1), ast.worlds.len);
    try testing.expectEqualStrings("app", ast.worlds[0].name);
    try testing.expectEqual(ExternKind.import, ast.worlds[0].items[0].kind);
    try testing.expectEqualStrings("logging", ast.worlds[0].items[0].name);
    try testing.expectEqual(ExternKind.@"export", ast.worlds[0].items[1].kind);
}

test "parse: no package decl is allowed" {
    var ast = try parse(testing.allocator, "interface i { f: func(); }");
    defer ast.deinit();
    try testing.expectEqual(@as(?PackageId, null), ast.package);
    try testing.expectEqual(@as(usize, 1), ast.interfaces.len);
}

test "parse: @version defers with UnsupportedItem" {
    try testing.expectError(Error.UnsupportedItem, parse(testing.allocator, "package p:n@1.0.0;"));
}

test "parse: top-level `type` defers with UnsupportedItem" {
    try testing.expectError(Error.UnsupportedItem, parse(testing.allocator, "type t = u32;"));
}

test "parse: a non-func interface item defers with UnsupportedItem" {
    try testing.expectError(Error.UnsupportedItem, parse(testing.allocator, "interface i { r: record { a: u8 } }"));
}

test "parse: missing semicolon errors" {
    try testing.expectError(Error.UnexpectedToken, parse(testing.allocator, "interface i { f: func() }"));
}
