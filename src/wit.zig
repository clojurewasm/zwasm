// WIT (WebAssembly Interface Types) parser
// Implements lexing and parsing of WIT text format for the Component Model.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Token ──────────────────────────────────────────────────────────────

pub const TokenTag = enum {
    // Punctuation
    equals, // =
    comma, // ,
    colon, // :
    semicolon, // ;
    lparen, // (
    rparen, // )
    lbrace, // {
    rbrace, // }
    langle, // <
    rangle, // >
    arrow, // ->
    star, // *
    at, // @
    slash, // /
    plus, // +
    hyphen, // -
    dot, // .
    underscore, // _

    // Keywords
    kw_use,
    kw_type,
    kw_func,
    kw_record,
    kw_resource,
    kw_own,
    kw_borrow,
    kw_flags,
    kw_variant,
    kw_enum,
    kw_bool,
    kw_string,
    kw_option,
    kw_result,
    kw_list,
    kw_tuple,
    kw_as,
    kw_from,
    kw_static,
    kw_interface,
    kw_import,
    kw_export,
    kw_world,
    kw_package,
    kw_constructor,
    kw_include,
    kw_with,

    // Primitive type keywords
    kw_u8,
    kw_u16,
    kw_u32,
    kw_u64,
    kw_s8,
    kw_s16,
    kw_s32,
    kw_s64,
    kw_f32,
    kw_f64,
    kw_char,

    // Literals & identifiers
    ident, // kebab-case identifier (e.g. my-func-name)
    integer, // integer literal
    doc_comment, // /// doc comment

    // Special
    eof,
    err,
};

pub const Token = struct {
    tag: TokenTag,
    start: u32,
    len: u16,
};

// ── Lexer ──────────────────────────────────────────────────────────────

pub const Lexer = struct {
    source: []const u8,
    pos: u32,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source, .pos = 0 };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.source.len) {
            return .{ .tag = .eof, .start = self.pos, .len = 0 };
        }

        const start = self.pos;
        const c = self.source[self.pos];

        // Single-character tokens
        switch (c) {
            '=' => return self.single(.equals, start),
            ',' => return self.single(.comma, start),
            ':' => return self.single(.colon, start),
            ';' => return self.single(.semicolon, start),
            '(' => return self.single(.lparen, start),
            ')' => return self.single(.rparen, start),
            '{' => return self.single(.lbrace, start),
            '}' => return self.single(.rbrace, start),
            '<' => return self.single(.langle, start),
            '>' => return self.single(.rangle, start),
            '*' => return self.single(.star, start),
            '@' => return self.single(.at, start),
            '+' => return self.single(.plus, start),
            '.' => return self.single(.dot, start),
            '/' => {
                // Check for doc comment ///
                if (self.pos + 2 < self.source.len and self.source[self.pos + 1] == '/' and self.source[self.pos + 2] == '/') {
                    self.pos += 3;
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        self.pos += 1;
                    }
                    const len: u16 = @intCast(self.pos - start);
                    return .{ .tag = .doc_comment, .start = start, .len = len };
                }
                return self.single(.slash, start);
            },
            '-' => {
                // -> or just -
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '>') {
                    self.pos += 2;
                    return .{ .tag = .arrow, .start = start, .len = 2 };
                }
                return self.single(.hyphen, start);
            },
            '%' => {
                // Explicit identifier: %keyword-as-ident (always ident, never keyword)
                self.pos += 1;
                return self.lexExplicitIdent(start);
            },
            else => {},
        }

        // Integer literal
        if (std.ascii.isDigit(c)) {
            return self.lexInteger(start);
        }

        // Identifier or keyword
        if (std.ascii.isAlphabetic(c) or c == '_') {
            return self.lexIdent(start);
        }

        // Unknown character
        self.pos += 1;
        return .{ .tag = .err, .start = start, .len = 1 };
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.source[tok.start..tok.start + tok.len];
    }

    // ── Internal helpers ────────────────────────────────────────────────

    fn single(self: *Lexer, tag: TokenTag, start: u32) Token {
        self.pos += 1;
        return .{ .tag = tag, .start = start, .len = 1 };
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }
            if (c == '/' and self.pos + 1 < self.source.len) {
                if (self.source[self.pos + 1] == '/') {
                    // Check for doc comment (///)
                    if (self.pos + 2 < self.source.len and self.source[self.pos + 2] == '/') {
                        // Doc comment — don't skip, return as token
                        return;
                    }
                    // Line comment: skip to end of line
                    self.pos += 2;
                    while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                        self.pos += 1;
                    }
                    continue;
                }
                if (self.source[self.pos + 1] == '*') {
                    // Block comment: skip to */
                    self.pos += 2;
                    var depth: u32 = 1;
                    while (self.pos + 1 < self.source.len and depth > 0) {
                        if (self.source[self.pos] == '/' and self.source[self.pos + 1] == '*') {
                            depth += 1;
                            self.pos += 2;
                        } else if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                            depth -= 1;
                            self.pos += 2;
                        } else {
                            self.pos += 1;
                        }
                    }
                    continue;
                }
            }
            break;
        }
    }

    fn lexIdent(self: *Lexer, start: u32) Token {
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }
        const len: u16 = @intCast(self.pos - start);
        const word = self.source[start..self.pos];
        const tag = keywordLookup(word);
        return .{ .tag = tag, .start = start, .len = len };
    }

    fn lexExplicitIdent(self: *Lexer, start: u32) Token {
        // After %, consume identifier chars — always returns ident (never keyword)
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }
        const len: u16 = @intCast(self.pos - start);
        return .{ .tag = .ident, .start = start, .len = len };
    }

    fn lexInteger(self: *Lexer, start: u32) Token {
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        const len: u16 = @intCast(self.pos - start);
        return .{ .tag = .integer, .start = start, .len = len };
    }

    fn keywordLookup(word: []const u8) TokenTag {
        const map = std.StaticStringMap(TokenTag).initComptime(.{
            .{ "use", .kw_use },
            .{ "type", .kw_type },
            .{ "func", .kw_func },
            .{ "record", .kw_record },
            .{ "resource", .kw_resource },
            .{ "own", .kw_own },
            .{ "borrow", .kw_borrow },
            .{ "flags", .kw_flags },
            .{ "variant", .kw_variant },
            .{ "enum", .kw_enum },
            .{ "bool", .kw_bool },
            .{ "string", .kw_string },
            .{ "option", .kw_option },
            .{ "result", .kw_result },
            .{ "list", .kw_list },
            .{ "tuple", .kw_tuple },
            .{ "as", .kw_as },
            .{ "from", .kw_from },
            .{ "static", .kw_static },
            .{ "interface", .kw_interface },
            .{ "import", .kw_import },
            .{ "export", .kw_export },
            .{ "world", .kw_world },
            .{ "package", .kw_package },
            .{ "constructor", .kw_constructor },
            .{ "include", .kw_include },
            .{ "with", .kw_with },
            .{ "u8", .kw_u8 },
            .{ "u16", .kw_u16 },
            .{ "u32", .kw_u32 },
            .{ "u64", .kw_u64 },
            .{ "s8", .kw_s8 },
            .{ "s16", .kw_s16 },
            .{ "s32", .kw_s32 },
            .{ "s64", .kw_s64 },
            .{ "f32", .kw_f32 },
            .{ "f64", .kw_f64 },
            .{ "char", .kw_char },
            .{ "_", .underscore },
        });
        return map.get(word) orelse .ident;
    }
};

// ── AST ────────────────────────────────────────────────────────────────

/// A parsed WIT document (one .wit file).
pub const Document = struct {
    package: ?PackageName,
    interfaces: []Interface,
    worlds: []World,

    pub fn deinit(self: *Document, alloc: Allocator) void {
        for (self.interfaces) |*iface| iface.deinit(alloc);
        alloc.free(self.interfaces);
        for (self.worlds) |*w| w.deinit(alloc);
        alloc.free(self.worlds);
    }
};

pub const PackageName = struct {
    namespace: []const u8, // e.g. "wasi"
    name: []const u8, // e.g. "io"
    version: ?[]const u8, // e.g. "0.2.0"
};

pub const Interface = struct {
    name: []const u8,
    items: []InterfaceItem,

    pub fn deinit(self: *Interface, alloc: Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
    }
};

pub const InterfaceItem = union(enum) {
    func_def: FuncDef,
    type_def: TypeDef,
    use_decl: UseDecl,

    pub fn deinit(self: *InterfaceItem, alloc: Allocator) void {
        switch (self.*) {
            .func_def => |*f| alloc.free(f.params),
            .type_def => {},
            .use_decl => |*u| alloc.free(u.names),
        }
    }
};

pub const FuncDef = struct {
    name: []const u8,
    params: []Param,
    result: ?TypeRef,
};

pub const Param = struct {
    name: []const u8,
    type_ref: TypeRef,
};

/// Reference to a WIT type.
pub const TypeRef = union(enum) {
    primitive: PrimitiveType,
    named: []const u8, // user-defined type name
    list_of: *const TypeRef,
    option_of: *const TypeRef,
    result_type: ResultType,
    tuple_of: []const TypeRef,
    handle_own: []const u8, // own<resource-name>
    handle_borrow: []const u8, // borrow<resource-name>
};

pub const PrimitiveType = enum {
    u8,
    u16,
    u32,
    u64,
    s8,
    s16,
    s32,
    s64,
    f32,
    f64,
    bool_,
    char_,
    string_,
};

pub const ResultType = struct {
    ok: ?*const TypeRef,
    err: ?*const TypeRef,
};

pub const TypeDef = struct {
    name: []const u8,
    kind: TypeDefKind,
};

pub const TypeDefKind = union(enum) {
    record: []Field,
    variant: []Case,
    enum_: []const []const u8,
    flags: []const []const u8,
    type_alias: TypeRef,
    resource, // resource with no body details (simplified)
};

pub const Field = struct {
    name: []const u8,
    type_ref: TypeRef,
};

pub const Case = struct {
    name: []const u8,
    type_ref: ?TypeRef,
};

pub const UseDecl = struct {
    path: []const u8,
    names: []UseName,
};

pub const UseName = struct {
    name: []const u8,
    alias: ?[]const u8, // "as" alias
};

pub const World = struct {
    name: []const u8,
    items: []WorldItem,

    pub fn deinit(self: *World, alloc: Allocator) void {
        alloc.free(self.items);
    }
};

pub const WorldItem = union(enum) {
    import_interface: []const u8, // import iface-name;
    export_interface: []const u8, // export iface-name;
    import_func: FuncDef, // import name: func(...);
    export_func: FuncDef, // export name: func(...);
    include_world: []const u8, // include world-name;
};

// ── Parser ─────────────────────────────────────────────────────────────

pub const ParseError = error{
    WitSyntaxError,
    OutOfMemory,
};

pub const Parser = struct {
    lex: Lexer,
    alloc: Allocator,
    // One-token lookahead
    peeked: ?Token,

    pub fn init(alloc: Allocator, source: []const u8) Parser {
        return .{
            .lex = Lexer.init(source),
            .alloc = alloc,
            .peeked = null,
        };
    }

    pub fn parseDocument(self: *Parser) ParseError!Document {
        var pkg: ?PackageName = null;
        var interfaces = std.ArrayList(Interface).empty;
        var worlds = std.ArrayList(World).empty;

        while (true) {
            const tok = self.next();
            switch (tok.tag) {
                .eof => break,
                .kw_package => pkg = try self.parsePackageName(),
                .kw_interface => {
                    const iface = try self.parseInterface();
                    interfaces.append(self.alloc, iface) catch return error.OutOfMemory;
                },
                .kw_world => {
                    const w = try self.parseWorld();
                    worlds.append(self.alloc, w) catch return error.OutOfMemory;
                },
                .kw_use => {
                    // top-level use — skip for now
                    self.skipToSemicolon();
                },
                else => {},
            }
        }

        return .{
            .package = pkg,
            .interfaces = interfaces.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
            .worlds = worlds.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
        };
    }

    // ── Package ─────────────────────────────────────────────

    fn parsePackageName(self: *Parser) ParseError!PackageName {
        const ns = self.expectIdent() orelse return error.WitSyntaxError;
        self.expect(.colon) orelse return error.WitSyntaxError;
        const name = self.expectIdent() orelse return error.WitSyntaxError;

        var version: ?[]const u8 = null;
        const maybe_at = self.peek();
        if (maybe_at.tag == .at) {
            _ = self.next(); // consume @
            version = self.consumeVersionString();
        }

        // Consume semicolon
        const semi = self.peek();
        if (semi.tag == .semicolon) _ = self.next();

        return .{ .namespace = ns, .name = name, .version = version };
    }

    fn consumeVersionString(self: *Parser) []const u8 {
        // Version is "1.0.0" — a sequence of integers and dots
        const start = self.lex.pos;
        while (self.lex.pos < self.lex.source.len) {
            const c = self.lex.source[self.lex.pos];
            if (std.ascii.isDigit(c) or c == '.') {
                self.lex.pos += 1;
            } else {
                break;
            }
        }
        return self.lex.source[start..self.lex.pos];
    }

    // ── Interface ───────────────────────────────────────────

    fn parseInterface(self: *Parser) ParseError!Interface {
        const name = self.expectIdent() orelse return error.WitSyntaxError;
        self.expect(.lbrace) orelse return error.WitSyntaxError;

        var items = std.ArrayList(InterfaceItem).empty;

        while (true) {
            const tok = self.peek();
            if (tok.tag == .rbrace or tok.tag == .eof) {
                _ = self.next();
                break;
            }

            if (tok.tag == .doc_comment) {
                _ = self.next(); // skip doc comments
                continue;
            }

            if (tok.tag == .kw_use) {
                _ = self.next();
                const u = try self.parseUseDecl();
                items.append(self.alloc, .{ .use_decl = u }) catch return error.OutOfMemory;
                continue;
            }

            if (tok.tag == .kw_record or tok.tag == .kw_variant or
                tok.tag == .kw_enum or tok.tag == .kw_flags or
                tok.tag == .kw_resource or tok.tag == .kw_type)
            {
                _ = self.next();
                const td = try self.parseTypeDef(tok.tag);
                items.append(self.alloc, .{ .type_def = td }) catch return error.OutOfMemory;
                continue;
            }

            // Otherwise: func-name: func(...)
            if (tok.tag == .ident) {
                _ = self.next();
                const name_text = self.lex.text(tok);
                const colon = self.peek();
                if (colon.tag == .colon) {
                    _ = self.next();
                    const kw = self.peek();
                    if (kw.tag == .kw_func) {
                        _ = self.next();
                        const f = try self.parseFuncBody(name_text);
                        items.append(self.alloc, .{ .func_def = f }) catch return error.OutOfMemory;
                        continue;
                    }
                }
            }

            // Skip unknown token
            _ = self.next();
        }

        return .{
            .name = name,
            .items = items.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
        };
    }

    // ── World ───────────────────────────────────────────────

    fn parseWorld(self: *Parser) ParseError!World {
        const name = self.expectIdent() orelse return error.WitSyntaxError;
        self.expect(.lbrace) orelse return error.WitSyntaxError;

        var items = std.ArrayList(WorldItem).empty;

        while (true) {
            const tok = self.peek();
            if (tok.tag == .rbrace or tok.tag == .eof) {
                _ = self.next();
                break;
            }

            if (tok.tag == .doc_comment) {
                _ = self.next();
                continue;
            }

            if (tok.tag == .kw_import or tok.tag == .kw_export) {
                _ = self.next();
                const item = try self.parseWorldImportExport(tok.tag == .kw_import);
                items.append(self.alloc, item) catch return error.OutOfMemory;
                continue;
            }

            if (tok.tag == .kw_include) {
                _ = self.next();
                const inc_name = self.expectIdent() orelse return error.WitSyntaxError;
                const item = WorldItem{ .include_world = inc_name };
                items.append(self.alloc, item) catch return error.OutOfMemory;
                self.skipToSemicolon();
                continue;
            }

            _ = self.next(); // skip unknown
        }

        return .{
            .name = name,
            .items = items.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
        };
    }

    fn parseWorldImportExport(self: *Parser, is_import: bool) ParseError!WorldItem {
        const tok = self.next();
        if (tok.tag == .ident) {
            const name = self.lex.text(tok);
            const next_tok = self.peek();
            if (next_tok.tag == .colon) {
                _ = self.next();
                const kw = self.peek();
                if (kw.tag == .kw_func) {
                    _ = self.next();
                    const f = try self.parseFuncBody(name);
                    return if (is_import) .{ .import_func = f } else .{ .export_func = f };
                }
                // interface { ... } inline
                if (kw.tag == .kw_interface) {
                    _ = self.next();
                    self.skipBraces();
                }
            }
            // Simple interface name import/export
            const semi = self.peek();
            if (semi.tag == .semicolon) _ = self.next();
            return if (is_import) .{ .import_interface = name } else .{ .export_interface = name };
        }
        self.skipToSemicolon();
        return if (is_import) .{ .import_interface = "" } else .{ .export_interface = "" };
    }

    // ── Use declarations ────────────────────────────────────

    fn parseUseDecl(self: *Parser) ParseError!UseDecl {
        // use path.{name1, name2 as alias, ...};
        // Path is a single ident in most cases (e.g. "types" in "use types.{...}")
        const first_tok = self.next();
        const path: []const u8 = if (first_tok.tag == .ident or first_tok.tag == .kw_interface)
            self.lex.text(first_tok)
        else
            "";

        // Skip any remaining dotted path segments (e.g. "a.b.c") until we hit '.'
        // For now, use the last segment before '{'
        // Most WIT files use: `use iface-name.{names}`
        // The dot before `{` is consumed here
        if (self.peek().tag == .dot) {
            _ = self.next(); // consume dot
        }

        // Parse {name1, name2 as alias}
        var names = std.ArrayList(UseName).empty;
        if (self.peek().tag == .lbrace) {
            _ = self.next();
            while (true) {
                const t = self.peek();
                if (t.tag == .rbrace or t.tag == .eof) {
                    _ = self.next();
                    break;
                }
                if (t.tag == .comma) {
                    _ = self.next();
                    continue;
                }
                _ = self.next();
                const n = self.lex.text(t);
                var alias: ?[]const u8 = null;
                if (self.peek().tag == .kw_as) {
                    _ = self.next();
                    alias = self.expectIdent();
                }
                names.append(self.alloc, .{ .name = n, .alias = alias }) catch return error.OutOfMemory;
            }
        }

        self.skipToSemicolon();

        return .{
            .path = path,
            .names = names.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
        };
    }

    // ── Type definitions ────────────────────────────────────

    fn parseTypeDef(self: *Parser, kw_tag: TokenTag) ParseError!TypeDef {
        const name = self.expectIdent() orelse return error.WitSyntaxError;

        switch (kw_tag) {
            .kw_record => {
                self.expect(.lbrace) orelse return error.WitSyntaxError;
                var fields = std.ArrayList(Field).empty;
                while (true) {
                    const t = self.peek();
                    if (t.tag == .rbrace or t.tag == .eof) {
                        _ = self.next();
                        break;
                    }
                    if (t.tag == .comma or t.tag == .doc_comment) {
                        _ = self.next();
                        continue;
                    }
                    _ = self.next();
                    const field_name = self.lex.text(t);
                    self.expect(.colon) orelse return error.WitSyntaxError;
                    const tr = try self.parseTypeRef();
                    fields.append(self.alloc, .{ .name = field_name, .type_ref = tr }) catch return error.OutOfMemory;
                    // optional trailing comma
                    if (self.peek().tag == .comma) _ = self.next();
                }
                return .{ .name = name, .kind = .{ .record = fields.toOwnedSlice(self.alloc) catch return error.OutOfMemory } };
            },
            .kw_variant => {
                self.expect(.lbrace) orelse return error.WitSyntaxError;
                var cases = std.ArrayList(Case).empty;
                while (true) {
                    const t = self.peek();
                    if (t.tag == .rbrace or t.tag == .eof) {
                        _ = self.next();
                        break;
                    }
                    if (t.tag == .comma or t.tag == .doc_comment) {
                        _ = self.next();
                        continue;
                    }
                    _ = self.next();
                    const case_name = self.lex.text(t);
                    var case_type: ?TypeRef = null;
                    if (self.peek().tag == .lparen) {
                        _ = self.next();
                        case_type = try self.parseTypeRef();
                        self.expect(.rparen) orelse return error.WitSyntaxError;
                    }
                    cases.append(self.alloc, .{ .name = case_name, .type_ref = case_type }) catch return error.OutOfMemory;
                    if (self.peek().tag == .comma) _ = self.next();
                }
                return .{ .name = name, .kind = .{ .variant = cases.toOwnedSlice(self.alloc) catch return error.OutOfMemory } };
            },
            .kw_enum => {
                self.expect(.lbrace) orelse return error.WitSyntaxError;
                var values = std.ArrayList([]const u8).empty;
                while (true) {
                    const t = self.peek();
                    if (t.tag == .rbrace or t.tag == .eof) {
                        _ = self.next();
                        break;
                    }
                    if (t.tag == .comma or t.tag == .doc_comment) {
                        _ = self.next();
                        continue;
                    }
                    _ = self.next();
                    values.append(self.alloc, self.lex.text(t)) catch return error.OutOfMemory;
                    if (self.peek().tag == .comma) _ = self.next();
                }
                return .{ .name = name, .kind = .{ .enum_ = values.toOwnedSlice(self.alloc) catch return error.OutOfMemory } };
            },
            .kw_flags => {
                self.expect(.lbrace) orelse return error.WitSyntaxError;
                var values = std.ArrayList([]const u8).empty;
                while (true) {
                    const t = self.peek();
                    if (t.tag == .rbrace or t.tag == .eof) {
                        _ = self.next();
                        break;
                    }
                    if (t.tag == .comma or t.tag == .doc_comment) {
                        _ = self.next();
                        continue;
                    }
                    _ = self.next();
                    values.append(self.alloc, self.lex.text(t)) catch return error.OutOfMemory;
                    if (self.peek().tag == .comma) _ = self.next();
                }
                return .{ .name = name, .kind = .{ .flags = values.toOwnedSlice(self.alloc) catch return error.OutOfMemory } };
            },
            .kw_resource => {
                // resource name { ... } or resource name;
                if (self.peek().tag == .lbrace) {
                    self.skipBraces();
                }
                return .{ .name = name, .kind = .resource };
            },
            .kw_type => {
                // type alias = type-ref;
                self.expect(.equals) orelse return error.WitSyntaxError;
                const tr = try self.parseTypeRef();
                self.skipToSemicolon();
                return .{ .name = name, .kind = .{ .type_alias = tr } };
            },
            else => return error.WitSyntaxError,
        }
    }

    // ── Function body ───────────────────────────────────────

    fn parseFuncBody(self: *Parser, name: []const u8) ParseError!FuncDef {
        self.expect(.lparen) orelse return error.WitSyntaxError;

        var params = std.ArrayList(Param).empty;
        while (true) {
            const t = self.peek();
            if (t.tag == .rparen or t.tag == .eof) {
                _ = self.next();
                break;
            }
            if (t.tag == .comma) {
                _ = self.next();
                continue;
            }
            _ = self.next();
            const param_name = self.lex.text(t);
            self.expect(.colon) orelse return error.WitSyntaxError;
            const tr = try self.parseTypeRef();
            params.append(self.alloc, .{ .name = param_name, .type_ref = tr }) catch return error.OutOfMemory;
        }

        var result: ?TypeRef = null;
        if (self.peek().tag == .arrow) {
            _ = self.next();
            result = try self.parseTypeRef();
        }

        // Consume semicolon
        if (self.peek().tag == .semicolon) _ = self.next();

        return .{
            .name = name,
            .params = params.toOwnedSlice(self.alloc) catch return error.OutOfMemory,
            .result = result,
        };
    }

    // ── Type references ─────────────────────────────────────

    fn parseTypeRef(self: *Parser) ParseError!TypeRef {
        const tok = self.next();
        return switch (tok.tag) {
            .kw_u8 => .{ .primitive = .u8 },
            .kw_u16 => .{ .primitive = .u16 },
            .kw_u32 => .{ .primitive = .u32 },
            .kw_u64 => .{ .primitive = .u64 },
            .kw_s8 => .{ .primitive = .s8 },
            .kw_s16 => .{ .primitive = .s16 },
            .kw_s32 => .{ .primitive = .s32 },
            .kw_s64 => .{ .primitive = .s64 },
            .kw_f32 => .{ .primitive = .f32 },
            .kw_f64 => .{ .primitive = .f64 },
            .kw_bool => .{ .primitive = .bool_ },
            .kw_char => .{ .primitive = .char_ },
            .kw_string => .{ .primitive = .string_ },
            .kw_list => {
                self.expect(.langle) orelse return error.WitSyntaxError;
                const inner = try self.allocTypeRef(try self.parseTypeRef());
                self.expect(.rangle) orelse return error.WitSyntaxError;
                return .{ .list_of = inner };
            },
            .kw_option => {
                self.expect(.langle) orelse return error.WitSyntaxError;
                const inner = try self.allocTypeRef(try self.parseTypeRef());
                self.expect(.rangle) orelse return error.WitSyntaxError;
                return .{ .option_of = inner };
            },
            .kw_result => {
                if (self.peek().tag != .langle) {
                    // bare result (no type params)
                    return .{ .result_type = .{ .ok = null, .err = null } };
                }
                _ = self.next(); // consume <
                // result<ok, err> or result<ok> or result<_, err>
                var ok_type: ?*const TypeRef = null;
                var err_type: ?*const TypeRef = null;

                if (self.peek().tag == .underscore) {
                    _ = self.next(); // wildcard _
                } else {
                    ok_type = try self.allocTypeRef(try self.parseTypeRef());
                }

                if (self.peek().tag == .comma) {
                    _ = self.next();
                    err_type = try self.allocTypeRef(try self.parseTypeRef());
                }

                self.expect(.rangle) orelse return error.WitSyntaxError;
                return .{ .result_type = .{ .ok = ok_type, .err = err_type } };
            },
            .kw_tuple => {
                self.expect(.langle) orelse return error.WitSyntaxError;
                var types = std.ArrayList(TypeRef).empty;
                while (self.peek().tag != .rangle and self.peek().tag != .eof) {
                    if (self.peek().tag == .comma) {
                        _ = self.next();
                        continue;
                    }
                    const tr = try self.parseTypeRef();
                    types.append(self.alloc, tr) catch return error.OutOfMemory;
                }
                self.expect(.rangle) orelse return error.WitSyntaxError;
                return .{ .tuple_of = types.toOwnedSlice(self.alloc) catch return error.OutOfMemory };
            },
            .kw_own => {
                self.expect(.langle) orelse return error.WitSyntaxError;
                const n = self.expectIdent() orelse return error.WitSyntaxError;
                self.expect(.rangle) orelse return error.WitSyntaxError;
                return .{ .handle_own = n };
            },
            .kw_borrow => {
                self.expect(.langle) orelse return error.WitSyntaxError;
                const n = self.expectIdent() orelse return error.WitSyntaxError;
                self.expect(.rangle) orelse return error.WitSyntaxError;
                return .{ .handle_borrow = n };
            },
            .ident => .{ .named = self.lex.text(tok) },
            else => return error.WitSyntaxError,
        };
    }

    fn allocTypeRef(self: *Parser, tr: TypeRef) ParseError!*const TypeRef {
        const ptr = self.alloc.create(TypeRef) catch return error.OutOfMemory;
        ptr.* = tr;
        return ptr;
    }

    // ── Helpers ─────────────────────────────────────────────

    fn next(self: *Parser) Token {
        if (self.peeked) |tok| {
            self.peeked = null;
            return tok;
        }
        return self.lex.next();
    }

    fn peek(self: *Parser) Token {
        if (self.peeked) |tok| return tok;
        self.peeked = self.lex.next();
        return self.peeked.?;
    }

    fn expect(self: *Parser, tag: TokenTag) ?void {
        const tok = self.next();
        if (tok.tag != tag) return null;
    }

    fn expectIdent(self: *Parser) ?[]const u8 {
        const tok = self.next();
        if (tok.tag == .ident) return self.lex.text(tok);
        return null;
    }

    fn skipToSemicolon(self: *Parser) void {
        while (true) {
            const tok = self.next();
            if (tok.tag == .semicolon or tok.tag == .eof) break;
        }
    }

    fn skipBraces(self: *Parser) void {
        // Assumes opening { was already consumed or about to be consumed
        if (self.peek().tag == .lbrace) _ = self.next();
        var depth: u32 = 1;
        while (depth > 0) {
            const tok = self.next();
            if (tok.tag == .lbrace) depth += 1;
            if (tok.tag == .rbrace) depth -= 1;
            if (tok.tag == .eof) break;
        }
    }
};

// ── Resolver ──────────────────────────────────────────────────────────

/// Resolved interface with all types (including imported via `use`) and functions.
pub const ResolvedInterface = struct {
    name: []const u8,
    types: std.StringHashMapUnmanaged(TypeDef),
    funcs: std.StringHashMapUnmanaged(FuncDef),

    fn init(name: []const u8) ResolvedInterface {
        return .{ .name = name, .types = .empty, .funcs = .empty };
    }

    fn deinit(self: *ResolvedInterface, alloc: Allocator) void {
        self.types.deinit(alloc);
        self.funcs.deinit(alloc);
    }

    pub fn getType(self: *const ResolvedInterface, name: []const u8) ?TypeDef {
        return self.types.get(name);
    }

    pub fn getFunc(self: *const ResolvedInterface, name: []const u8) ?FuncDef {
        return self.funcs.get(name);
    }
};

/// Resolved world with import/export interface references.
pub const ResolvedWorld = struct {
    name: []const u8,
    imports: std.StringHashMapUnmanaged(void),
    exports: std.StringHashMapUnmanaged(void),

    fn init(name: []const u8) ResolvedWorld {
        return .{ .name = name, .imports = .empty, .exports = .empty };
    }

    fn deinit(self: *ResolvedWorld, alloc: Allocator) void {
        self.imports.deinit(alloc);
        self.exports.deinit(alloc);
    }
};

/// Resolves WIT `use` declarations and builds lookup tables for types and functions.
pub const Resolver = struct {
    alloc: Allocator,
    // Raw parsed interfaces, indexed by name
    raw_interfaces: std.StringHashMapUnmanaged(Interface),
    // Raw parsed worlds
    raw_worlds: std.StringHashMapUnmanaged(World),
    // Resolved output
    interfaces: std.StringHashMapUnmanaged(ResolvedInterface),
    worlds: std.StringHashMapUnmanaged(ResolvedWorld),

    pub fn init(alloc: Allocator) Resolver {
        return .{
            .alloc = alloc,
            .raw_interfaces = .empty,
            .raw_worlds = .empty,
            .interfaces = .empty,
            .worlds = .empty,
        };
    }

    pub fn deinit(self: *Resolver) void {
        self.raw_interfaces.deinit(self.alloc);
        self.raw_worlds.deinit(self.alloc);
        var it = self.interfaces.valueIterator();
        while (it.next()) |ri| ri.deinit(self.alloc);
        self.interfaces.deinit(self.alloc);
        var wit = self.worlds.valueIterator();
        while (wit.next()) |rw| rw.deinit(self.alloc);
        self.worlds.deinit(self.alloc);
    }

    pub fn addDocument(self: *Resolver, doc: *const Document) !void {
        for (doc.interfaces) |iface| {
            self.raw_interfaces.put(self.alloc, iface.name, iface) catch return error.OutOfMemory;
        }
        for (doc.worlds) |w| {
            self.raw_worlds.put(self.alloc, w.name, w) catch return error.OutOfMemory;
        }
    }

    pub fn resolve(self: *Resolver) !void {
        // Phase 1: Build resolved interfaces with their own types/funcs
        var raw_it = self.raw_interfaces.iterator();
        while (raw_it.next()) |entry| {
            var ri = ResolvedInterface.init(entry.key_ptr.*);

            for (entry.value_ptr.items) |item| {
                switch (item) {
                    .type_def => |td| {
                        ri.types.put(self.alloc, td.name, td) catch return error.OutOfMemory;
                    },
                    .func_def => |fd| {
                        ri.funcs.put(self.alloc, fd.name, fd) catch return error.OutOfMemory;
                    },
                    .use_decl => {}, // handled in phase 2
                }
            }

            self.interfaces.put(self.alloc, entry.key_ptr.*, ri) catch return error.OutOfMemory;
        }

        // Phase 2: Resolve `use` declarations
        raw_it = self.raw_interfaces.iterator();
        while (raw_it.next()) |entry| {
            const ri = self.interfaces.getPtr(entry.key_ptr.*) orelse continue;

            for (entry.value_ptr.items) |item| {
                switch (item) {
                    .use_decl => |use| {
                        const source_iface = self.interfaces.get(use.path) orelse continue;
                        for (use.names) |use_name| {
                            const src_type = source_iface.types.get(use_name.name) orelse continue;
                            const target_name = use_name.alias orelse use_name.name;
                            ri.types.put(self.alloc, target_name, src_type) catch return error.OutOfMemory;
                        }
                    },
                    else => {},
                }
            }
        }

        // Phase 3: Resolve worlds
        var world_it = self.raw_worlds.iterator();
        while (world_it.next()) |entry| {
            var rw = ResolvedWorld.init(entry.key_ptr.*);

            for (entry.value_ptr.items) |item| {
                switch (item) {
                    .import_interface => |name| {
                        rw.imports.put(self.alloc, name, {}) catch return error.OutOfMemory;
                    },
                    .export_interface => |name| {
                        rw.exports.put(self.alloc, name, {}) catch return error.OutOfMemory;
                    },
                    .import_func => |fd| {
                        rw.imports.put(self.alloc, fd.name, {}) catch return error.OutOfMemory;
                    },
                    .export_func => |fd| {
                        rw.exports.put(self.alloc, fd.name, {}) catch return error.OutOfMemory;
                    },
                    .include_world => {}, // TODO: resolve included worlds
                }
            }

            self.worlds.put(self.alloc, entry.key_ptr.*, rw) catch return error.OutOfMemory;
        }
    }

    pub fn getInterface(self: *const Resolver, name: []const u8) ?*const ResolvedInterface {
        return self.interfaces.getPtr(name);
    }

    pub fn getWorld(self: *const Resolver, name: []const u8) ?*const ResolvedWorld {
        return self.worlds.getPtr(name);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "Lexer — punctuation tokens" {
    var lex = Lexer.init("= , : ; ( ) { } < > -> * @ / + . -");
    try std.testing.expectEqual(.equals, lex.next().tag);
    try std.testing.expectEqual(.comma, lex.next().tag);
    try std.testing.expectEqual(.colon, lex.next().tag);
    try std.testing.expectEqual(.semicolon, lex.next().tag);
    try std.testing.expectEqual(.lparen, lex.next().tag);
    try std.testing.expectEqual(.rparen, lex.next().tag);
    try std.testing.expectEqual(.lbrace, lex.next().tag);
    try std.testing.expectEqual(.rbrace, lex.next().tag);
    try std.testing.expectEqual(.langle, lex.next().tag);
    try std.testing.expectEqual(.rangle, lex.next().tag);
    try std.testing.expectEqual(.arrow, lex.next().tag);
    try std.testing.expectEqual(.star, lex.next().tag);
    try std.testing.expectEqual(.at, lex.next().tag);
    try std.testing.expectEqual(.slash, lex.next().tag);
    try std.testing.expectEqual(.plus, lex.next().tag);
    try std.testing.expectEqual(.dot, lex.next().tag);
    try std.testing.expectEqual(.hyphen, lex.next().tag);
    try std.testing.expectEqual(.eof, lex.next().tag);
}

test "Lexer — keywords" {
    var lex = Lexer.init("package interface world use type func record variant enum flags");
    try std.testing.expectEqual(.kw_package, lex.next().tag);
    try std.testing.expectEqual(.kw_interface, lex.next().tag);
    try std.testing.expectEqual(.kw_world, lex.next().tag);
    try std.testing.expectEqual(.kw_use, lex.next().tag);
    try std.testing.expectEqual(.kw_type, lex.next().tag);
    try std.testing.expectEqual(.kw_func, lex.next().tag);
    try std.testing.expectEqual(.kw_record, lex.next().tag);
    try std.testing.expectEqual(.kw_variant, lex.next().tag);
    try std.testing.expectEqual(.kw_enum, lex.next().tag);
    try std.testing.expectEqual(.kw_flags, lex.next().tag);
    try std.testing.expectEqual(.eof, lex.next().tag);
}

test "Lexer — primitive types" {
    var lex = Lexer.init("u8 u16 u32 u64 s8 s16 s32 s64 f32 f64 char bool string");
    try std.testing.expectEqual(.kw_u8, lex.next().tag);
    try std.testing.expectEqual(.kw_u16, lex.next().tag);
    try std.testing.expectEqual(.kw_u32, lex.next().tag);
    try std.testing.expectEqual(.kw_u64, lex.next().tag);
    try std.testing.expectEqual(.kw_s8, lex.next().tag);
    try std.testing.expectEqual(.kw_s16, lex.next().tag);
    try std.testing.expectEqual(.kw_s32, lex.next().tag);
    try std.testing.expectEqual(.kw_s64, lex.next().tag);
    try std.testing.expectEqual(.kw_f32, lex.next().tag);
    try std.testing.expectEqual(.kw_f64, lex.next().tag);
    try std.testing.expectEqual(.kw_char, lex.next().tag);
    try std.testing.expectEqual(.kw_bool, lex.next().tag);
    try std.testing.expectEqual(.kw_string, lex.next().tag);
    try std.testing.expectEqual(.eof, lex.next().tag);
}

test "Lexer — kebab-case identifiers" {
    var lex = Lexer.init("my-func tuple-arg get-value");
    const t1 = lex.next();
    try std.testing.expectEqual(.ident, t1.tag);
    try std.testing.expectEqualStrings("my-func", lex.text(t1));
    const t2 = lex.next();
    try std.testing.expectEqual(.ident, t2.tag);
    try std.testing.expectEqualStrings("tuple-arg", lex.text(t2));
    const t3 = lex.next();
    try std.testing.expectEqual(.ident, t3.tag);
    try std.testing.expectEqualStrings("get-value", lex.text(t3));
}

test "Lexer — integer literals" {
    var lex = Lexer.init("0 42 100");
    const t1 = lex.next();
    try std.testing.expectEqual(.integer, t1.tag);
    try std.testing.expectEqualStrings("0", lex.text(t1));
    const t2 = lex.next();
    try std.testing.expectEqual(.integer, t2.tag);
    try std.testing.expectEqualStrings("42", lex.text(t2));
    const t3 = lex.next();
    try std.testing.expectEqual(.integer, t3.tag);
    try std.testing.expectEqualStrings("100", lex.text(t3));
}

test "Lexer — comments" {
    var lex = Lexer.init("a // line comment\nb /* block */ c");
    const t1 = lex.next();
    try std.testing.expectEqual(.ident, t1.tag);
    try std.testing.expectEqualStrings("a", lex.text(t1));
    // line comment skipped, 'b' is next
    const t2 = lex.next();
    try std.testing.expectEqual(.ident, t2.tag);
    try std.testing.expectEqualStrings("b", lex.text(t2));
    // block comment skipped
    const t3 = lex.next();
    try std.testing.expectEqual(.ident, t3.tag);
    try std.testing.expectEqualStrings("c", lex.text(t3));
}

test "Lexer — doc comments" {
    var lex = Lexer.init("/// A doc comment\nfoo");
    const t1 = lex.next();
    try std.testing.expectEqual(.doc_comment, t1.tag);
    try std.testing.expectEqualStrings("/// A doc comment", lex.text(t1));
    const t2 = lex.next();
    try std.testing.expectEqual(.ident, t2.tag);
    try std.testing.expectEqualStrings("foo", lex.text(t2));
}

test "Lexer — package declaration" {
    var lex = Lexer.init("package foo:bar@1.0.0;");
    try std.testing.expectEqual(.kw_package, lex.next().tag);
    const name = lex.next();
    try std.testing.expectEqual(.ident, name.tag);
    try std.testing.expectEqualStrings("foo", lex.text(name));
    try std.testing.expectEqual(.colon, lex.next().tag);
    const pkg = lex.next();
    try std.testing.expectEqual(.ident, pkg.tag);
    try std.testing.expectEqualStrings("bar", lex.text(pkg));
    try std.testing.expectEqual(.at, lex.next().tag);
    const ver = lex.next();
    try std.testing.expectEqual(.integer, ver.tag);
    try std.testing.expectEqualStrings("1", lex.text(ver));
    try std.testing.expectEqual(.dot, lex.next().tag);
    const ver2 = lex.next();
    try std.testing.expectEqual(.integer, ver2.tag);
    try std.testing.expectEqualStrings("0", lex.text(ver2));
    try std.testing.expectEqual(.dot, lex.next().tag);
    const ver3 = lex.next();
    try std.testing.expectEqual(.integer, ver3.tag);
    try std.testing.expectEqualStrings("0", lex.text(ver3));
    try std.testing.expectEqual(.semicolon, lex.next().tag);
    try std.testing.expectEqual(.eof, lex.next().tag);
}

test "Lexer — nested block comments" {
    var lex = Lexer.init("a /* outer /* inner */ still outer */ b");
    const t1 = lex.next();
    try std.testing.expectEqualStrings("a", lex.text(t1));
    const t2 = lex.next();
    try std.testing.expectEqualStrings("b", lex.text(t2));
}

test "Lexer — explicit identifier with percent" {
    var lex = Lexer.init("%use %type");
    // %use should be ident, not keyword
    const t1 = lex.next();
    try std.testing.expectEqual(.ident, t1.tag);
    // text includes % prefix
    const t2 = lex.next();
    try std.testing.expectEqual(.ident, t2.tag);
}

test "Lexer — underscore as wildcard" {
    var lex = Lexer.init("result<_, e1>");
    try std.testing.expectEqual(.kw_result, lex.next().tag);
    try std.testing.expectEqual(.langle, lex.next().tag);
    try std.testing.expectEqual(.underscore, lex.next().tag);
    try std.testing.expectEqual(.comma, lex.next().tag);
    const e1 = lex.next();
    try std.testing.expectEqual(.ident, e1.tag);
    try std.testing.expectEqualStrings("e1", lex.text(e1));
    try std.testing.expectEqual(.rangle, lex.next().tag);
}

// ── Parser Tests ───────────────────────────────────────────────────────

test "Parser — package declaration" {
    const source = "package wasi:io@0.2.0;";
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    try std.testing.expect(doc.package != null);
    const pkg = doc.package.?;
    try std.testing.expectEqualStrings("wasi", pkg.namespace);
    try std.testing.expectEqualStrings("io", pkg.name);
    try std.testing.expect(pkg.version != null);
    try std.testing.expectEqualStrings("0.2.0", pkg.version.?);
}

test "Parser — empty interface" {
    const source = "interface empty {}";
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.interfaces.len);
    try std.testing.expectEqualStrings("empty", doc.interfaces[0].name);
    try std.testing.expectEqual(@as(usize, 0), doc.interfaces[0].items.len);
}

test "Parser — interface with function" {
    const source =
        \\interface my-iface {
        \\  do-something: func(name: string, count: u32) -> bool;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.interfaces.len);
    const iface = doc.interfaces[0];
    try std.testing.expectEqualStrings("my-iface", iface.name);
    try std.testing.expectEqual(@as(usize, 1), iface.items.len);

    const func_def = iface.items[0].func_def;
    try std.testing.expectEqualStrings("do-something", func_def.name);
    try std.testing.expectEqual(@as(usize, 2), func_def.params.len);
    try std.testing.expectEqualStrings("name", func_def.params[0].name);
    try std.testing.expectEqual(TypeRef{ .primitive = .string_ }, func_def.params[0].type_ref);
    try std.testing.expectEqualStrings("count", func_def.params[1].name);
    try std.testing.expectEqual(TypeRef{ .primitive = .u32 }, func_def.params[1].type_ref);
    try std.testing.expect(func_def.result != null);
    try std.testing.expectEqual(TypeRef{ .primitive = .bool_ }, func_def.result.?);
}

test "Parser — record type" {
    const source =
        \\interface types {
        \\  record point {
        \\    x: f64,
        \\    y: f64,
        \\  }
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const iface = doc.interfaces[0];
    try std.testing.expectEqual(@as(usize, 1), iface.items.len);
    const td = iface.items[0].type_def;
    try std.testing.expectEqualStrings("point", td.name);
    const fields = td.kind.record;
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("x", fields[0].name);
    try std.testing.expectEqual(TypeRef{ .primitive = .f64 }, fields[0].type_ref);
    try std.testing.expectEqualStrings("y", fields[1].name);
}

test "Parser — enum type" {
    const source =
        \\interface colors {
        \\  enum color {
        \\    red,
        \\    green,
        \\    blue,
        \\  }
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const td = doc.interfaces[0].items[0].type_def;
    try std.testing.expectEqualStrings("color", td.name);
    const values = td.kind.enum_;
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("red", values[0]);
    try std.testing.expectEqualStrings("green", values[1]);
    try std.testing.expectEqualStrings("blue", values[2]);
}

test "Parser — variant type" {
    const source =
        \\interface vals {
        \\  variant val {
        \\    num(s64),
        \\    text(string),
        \\    none,
        \\  }
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const td = doc.interfaces[0].items[0].type_def;
    try std.testing.expectEqualStrings("val", td.name);
    const cases = td.kind.variant;
    try std.testing.expectEqual(@as(usize, 3), cases.len);
    try std.testing.expectEqualStrings("num", cases[0].name);
    try std.testing.expect(cases[0].type_ref != null);
    try std.testing.expectEqual(TypeRef{ .primitive = .s64 }, cases[0].type_ref.?);
    try std.testing.expectEqualStrings("text", cases[1].name);
    try std.testing.expectEqual(TypeRef{ .primitive = .string_ }, cases[1].type_ref.?);
    try std.testing.expectEqualStrings("none", cases[2].name);
    try std.testing.expect(cases[2].type_ref == null);
}

test "Parser — flags type" {
    const source =
        \\interface perms {
        \\  flags permissions {
        \\    read,
        \\    write,
        \\    exec,
        \\  }
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const td = doc.interfaces[0].items[0].type_def;
    try std.testing.expectEqualStrings("permissions", td.name);
    const flags = td.kind.flags;
    try std.testing.expectEqual(@as(usize, 3), flags.len);
    try std.testing.expectEqualStrings("read", flags[0]);
    try std.testing.expectEqualStrings("write", flags[1]);
    try std.testing.expectEqualStrings("exec", flags[2]);
}

test "Parser — type alias" {
    const source =
        \\interface types {
        \\  type my-string = string;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const td = doc.interfaces[0].items[0].type_def;
    try std.testing.expectEqualStrings("my-string", td.name);
    try std.testing.expectEqual(TypeRef{ .primitive = .string_ }, td.kind.type_alias);
}

test "Parser — list and option types" {
    const source =
        \\interface container {
        \\  get-items: func() -> list<u32>;
        \\  find: func(key: string) -> option<u64>;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const iface = doc.interfaces[0];
    try std.testing.expectEqual(@as(usize, 2), iface.items.len);

    // get-items returns list<u32>
    const f1 = iface.items[0].func_def;
    try std.testing.expectEqualStrings("get-items", f1.name);
    try std.testing.expect(f1.result != null);
    try std.testing.expectEqual(TypeRef{ .primitive = .u32 }, f1.result.?.list_of.*);

    // find returns option<u64>
    const f2 = iface.items[1].func_def;
    try std.testing.expect(f2.result != null);
    try std.testing.expectEqual(TypeRef{ .primitive = .u64 }, f2.result.?.option_of.*);
}

test "Parser — result type" {
    const source =
        \\interface err {
        \\  try-op: func() -> result<u32, string>;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const f = doc.interfaces[0].items[0].func_def;
    try std.testing.expect(f.result != null);
    const rt = f.result.?.result_type;
    try std.testing.expect(rt.ok != null);
    try std.testing.expectEqual(TypeRef{ .primitive = .u32 }, rt.ok.?.*);
    try std.testing.expect(rt.err != null);
    try std.testing.expectEqual(TypeRef{ .primitive = .string_ }, rt.err.?.*);
}

test "Parser — world with imports and exports" {
    const source =
        \\world my-world {
        \\  import logging;
        \\  export handler;
        \\  import do-work: func(input: string) -> u32;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), doc.worlds.len);
    const w = doc.worlds[0];
    try std.testing.expectEqualStrings("my-world", w.name);
    try std.testing.expectEqual(@as(usize, 3), w.items.len);

    // import logging
    try std.testing.expectEqualStrings("logging", w.items[0].import_interface);
    // export handler
    try std.testing.expectEqualStrings("handler", w.items[1].export_interface);
    // import do-work: func(...)
    const imp_func = w.items[2].import_func;
    try std.testing.expectEqualStrings("do-work", imp_func.name);
    try std.testing.expectEqual(@as(usize, 1), imp_func.params.len);
}

test "Parser — function with no return" {
    const source =
        \\interface logger {
        \\  log: func(msg: string);
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const f = doc.interfaces[0].items[0].func_def;
    try std.testing.expectEqualStrings("log", f.name);
    try std.testing.expectEqual(@as(usize, 1), f.params.len);
    try std.testing.expect(f.result == null);
}

test "Parser — tuple type" {
    const source =
        \\interface t {
        \\  get-pair: func() -> tuple<u32, string>;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const f = doc.interfaces[0].items[0].func_def;
    const tup = f.result.?.tuple_of;
    try std.testing.expectEqual(@as(usize, 2), tup.len);
    try std.testing.expectEqual(TypeRef{ .primitive = .u32 }, tup[0]);
    try std.testing.expectEqual(TypeRef{ .primitive = .string_ }, tup[1]);
}

test "Parser — own and borrow handles" {
    const source =
        \\interface res {
        \\  resource file-handle;
        \\  open: func(path: string) -> own<file-handle>;
        \\  read: func(f: borrow<file-handle>) -> list<u8>;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const iface = doc.interfaces[0];
    try std.testing.expectEqual(@as(usize, 3), iface.items.len);

    // resource declaration
    try std.testing.expectEqualStrings("file-handle", iface.items[0].type_def.name);
    try std.testing.expectEqual(TypeDefKind.resource, iface.items[0].type_def.kind);

    // open returns own<file-handle>
    const f1 = iface.items[1].func_def;
    try std.testing.expectEqualStrings("file-handle", f1.result.?.handle_own);

    // read takes borrow<file-handle>
    const f2 = iface.items[2].func_def;
    try std.testing.expectEqualStrings("file-handle", f2.params[0].type_ref.handle_borrow);
}

test "Parser — package without version" {
    const source = "package my-org:my-pkg;";
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    try std.testing.expect(doc.package != null);
    const pkg = doc.package.?;
    try std.testing.expectEqualStrings("my-org", pkg.namespace);
    try std.testing.expectEqualStrings("my-pkg", pkg.name);
    try std.testing.expect(pkg.version == null);
}

test "Parser — multiple interfaces" {
    const source =
        \\interface a {
        \\  foo: func();
        \\}
        \\interface b {
        \\  bar: func(x: u32);
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), doc.interfaces.len);
    try std.testing.expectEqualStrings("a", doc.interfaces[0].name);
    try std.testing.expectEqualStrings("b", doc.interfaces[1].name);
}

test "Parser — use declaration" {
    const source =
        \\interface consumer {
        \\  use types.{my-type, other as ot};
        \\  process: func(v: my-type) -> u32;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    const iface = doc.interfaces[0];
    try std.testing.expectEqual(@as(usize, 2), iface.items.len);

    const use = iface.items[0].use_decl;
    try std.testing.expectEqualStrings("types", use.path);
    try std.testing.expectEqual(@as(usize, 2), use.names.len);
    try std.testing.expectEqualStrings("my-type", use.names[0].name);
    try std.testing.expect(use.names[0].alias == null);
    try std.testing.expectEqualStrings("other", use.names[1].name);
    try std.testing.expect(use.names[1].alias != null);
    try std.testing.expectEqualStrings("ot", use.names[1].alias.?);
}

test "Parser — full document" {
    const source =
        \\package example:demo@1.0.0;
        \\
        \\interface types {
        \\  record point {
        \\    x: f64,
        \\    y: f64,
        \\  }
        \\  enum color { red, green, blue }
        \\}
        \\
        \\interface api {
        \\  draw: func(p: point, c: color);
        \\}
        \\
        \\world canvas {
        \\  import types;
        \\  export api;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    try std.testing.expect(doc.package != null);
    try std.testing.expectEqualStrings("example", doc.package.?.namespace);
    try std.testing.expectEqual(@as(usize, 2), doc.interfaces.len);
    try std.testing.expectEqual(@as(usize, 1), doc.worlds.len);
    try std.testing.expectEqualStrings("canvas", doc.worlds[0].name);
}

test "Resolver — resolve use declaration" {
    const source =
        \\interface types {
        \\  record point {
        \\    x: f64,
        \\    y: f64,
        \\  }
        \\  enum color { red, green, blue }
        \\}
        \\
        \\interface canvas {
        \\  use types.{point, color};
        \\  draw: func(p: point, c: color);
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    try resolver.addDocument(&doc);
    try resolver.resolve();

    // After resolution, "canvas" interface should have types from "types"
    const canvas = resolver.getInterface("canvas") orelse return error.WitSyntaxError;
    try std.testing.expect(canvas.getType("point") != null);
    try std.testing.expect(canvas.getType("color") != null);
    try std.testing.expect(canvas.getFunc("draw") != null);
}

test "Resolver — use with alias" {
    const source =
        \\interface base {
        \\  record item {
        \\    id: u32,
        \\  }
        \\}
        \\
        \\interface consumer {
        \\  use base.{item as base-item};
        \\  process: func(i: base-item) -> bool;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    try resolver.addDocument(&doc);
    try resolver.resolve();

    const consumer = resolver.getInterface("consumer") orelse return error.WitSyntaxError;
    // aliased as "base-item"
    try std.testing.expect(consumer.getType("base-item") != null);
    // original name should NOT be present
    try std.testing.expect(consumer.getType("item") == null);
}

test "Resolver — world resolution" {
    const source =
        \\interface logger {
        \\  log: func(msg: string);
        \\}
        \\
        \\world my-app {
        \\  import logger;
        \\  export logger;
        \\}
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var doc = try parser.parseDocument();
    defer doc.deinit(std.testing.allocator);

    var resolver = Resolver.init(std.testing.allocator);
    defer resolver.deinit();
    try resolver.addDocument(&doc);
    try resolver.resolve();

    const world = resolver.getWorld("my-app") orelse return error.WitSyntaxError;
    try std.testing.expectEqual(@as(usize, 1), world.imports.count());
    try std.testing.expectEqual(@as(usize, 1), world.exports.count());
    try std.testing.expect(world.imports.contains("logger"));
    try std.testing.expect(world.exports.contains("logger"));
}
