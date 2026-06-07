//! WIT **lexer** (CM campaign chunk A3; spec `component-model/design/mvp/WIT.md`).
//!
//! Tokenizes the WIT IDL into the token stream the parser consumes. WIT
//! identifiers are kebab-case (`is-even`, `no-return`) with an optional `%`
//! raw-identifier escape; comments are `//` line and `/* */` block (block
//! comments nest, per WIT.md). Token `text` borrows from the source.
//!
//! No-copy: re-derived from the current `WIT.md`. v1 `wit_parser.zig`'s
//! tokenizer is the structural textbook (single-char dispatch + ident run +
//! whitespace/comment skip) but lacked nested block comments and the
//! `@ . / =` punctuation this subset needs.

const std = @import("std");

pub const TokenTag = enum {
    ident,
    colon,
    semicolon,
    comma,
    lparen,
    rparen,
    lbrace,
    rbrace,
    langle,
    rangle,
    arrow, // ->
    at, // @
    dot, // .
    slash, // /
    eq, // =
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    text: []const u8,
};

pub const Error = error{
    UnterminatedBlockComment,
    UnexpectedChar,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    /// Produce the next token, or `eof` at end of input.
    pub fn next(self: *Lexer) Error!Token {
        try self.skipTrivia();
        if (self.pos >= self.src.len) return .{ .tag = .eof, .text = "" };

        const c = self.src[self.pos];

        if (singleChar(c)) |tag| {
            self.pos += 1;
            return .{ .tag = tag, .text = self.src[self.pos - 1 .. self.pos] };
        }

        // Arrow `->`
        if (c == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '>') {
            self.pos += 2;
            return .{ .tag = .arrow, .text = "->" };
        }

        if (isIdentStart(c)) {
            const start = self.pos;
            self.pos += 1;
            while (self.pos < self.src.len and isIdentCont(self.src[self.pos])) self.pos += 1;
            return .{ .tag = .ident, .text = self.src[start..self.pos] };
        }

        return Error.UnexpectedChar;
    }

    /// Peek the next token without consuming input.
    pub fn peek(self: *Lexer) Error!Token {
        const save = self.pos;
        const tok = try self.next();
        self.pos = save;
        return tok;
    }

    fn skipTrivia(self: *Lexer) Error!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    if (self.pos + 1 >= self.src.len) return;
                    switch (self.src[self.pos + 1]) {
                        '/' => {
                            self.pos += 2;
                            while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                        },
                        '*' => try self.skipBlockComment(),
                        else => return,
                    }
                },
                else => return,
            }
        }
    }

    /// Block comments nest (`WIT.md`): track depth so `/* /* */ */` closes
    /// cleanly.
    fn skipBlockComment(self: *Lexer) Error!void {
        self.pos += 2; // opening /*
        var depth: usize = 1;
        while (self.pos < self.src.len) {
            if (self.pos + 1 < self.src.len and self.src[self.pos] == '/' and self.src[self.pos + 1] == '*') {
                depth += 1;
                self.pos += 2;
            } else if (self.pos + 1 < self.src.len and self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                depth -= 1;
                self.pos += 2;
                if (depth == 0) return;
            } else {
                self.pos += 1;
            }
        }
        return Error.UnterminatedBlockComment;
    }
};

fn singleChar(c: u8) ?TokenTag {
    return switch (c) {
        ':' => .colon,
        ';' => .semicolon,
        ',' => .comma,
        '(' => .lparen,
        ')' => .rparen,
        '{' => .lbrace,
        '}' => .rbrace,
        '<' => .langle,
        '>' => .rangle,
        '@' => .at,
        '.' => .dot,
        '/' => .slash,
        '=' => .eq,
        else => null,
    };
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '%';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
}

// ============================================================
// Tests
// ============================================================
const testing = std.testing;

fn tagsOf(src: []const u8, out: []TokenTag) !usize {
    var lex = Lexer.init(src);
    var i: usize = 0;
    while (true) {
        const tok = try lex.next();
        if (tok.tag == .eof) break;
        out[i] = tok.tag;
        i += 1;
    }
    return i;
}

test "lex: a func signature tokenizes" {
    var buf: [32]TokenTag = undefined;
    const n = try tagsOf("greet: func(name: string) -> string;", &buf);
    const expect = [_]TokenTag{ .ident, .colon, .ident, .lparen, .ident, .colon, .ident, .rparen, .arrow, .ident, .semicolon };
    try testing.expectEqualSlices(TokenTag, &expect, buf[0..n]);
}

test "lex: kebab identifiers stay whole" {
    var lex = Lexer.init("is-even no-return");
    try testing.expectEqualStrings("is-even", (try lex.next()).text);
    try testing.expectEqualStrings("no-return", (try lex.next()).text);
    try testing.expectEqual(TokenTag.eof, (try lex.next()).tag);
}

test "lex: line + nested block comments are skipped" {
    var lex = Lexer.init("// line\n/* outer /* inner */ still */ foo");
    const tok = try lex.next();
    try testing.expectEqual(TokenTag.ident, tok.tag);
    try testing.expectEqualStrings("foo", tok.text);
}

test "lex: package + interface path punctuation (: / @ .)" {
    // semver digits after `@` are a separate lexical context (deferred);
    // exercise the punctuation tokens with letter-only idents.
    var buf: [16]TokenTag = undefined;
    const n = try tagsOf("wasi:clocks/wall-clock @ a.b ;", &buf);
    const expect = [_]TokenTag{ .ident, .colon, .ident, .slash, .ident, .at, .ident, .dot, .ident, .semicolon };
    try testing.expectEqualSlices(TokenTag, &expect, buf[0..n]);
}

test "lex: peek does not consume" {
    var lex = Lexer.init("foo bar");
    try testing.expectEqualStrings("foo", (try lex.peek()).text);
    try testing.expectEqualStrings("foo", (try lex.next()).text);
    try testing.expectEqualStrings("bar", (try lex.next()).text);
}

test "lex: unterminated block comment errors" {
    var lex = Lexer.init("/* never closed");
    try testing.expectError(Error.UnterminatedBlockComment, lex.next());
}
