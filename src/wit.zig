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
