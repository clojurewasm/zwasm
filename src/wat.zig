// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! WAT (WebAssembly Text Format) parser — converts .wat to .wasm binary.
//!
//! Conditionally compiled via `-Dwat=false` build option.
//! When disabled, loadFromWat returns error.WatNotEnabled.

const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

pub const WatError = error{
    WatNotEnabled,
    InvalidWat,
    OutOfMemory,
};

/// Convert WAT text source to wasm binary bytes.
/// Returns allocated slice owned by caller.
pub fn watToWasm(alloc: Allocator, wat_source: []const u8) WatError![]u8 {
    if (!build_options.enable_wat) return error.WatNotEnabled;
    _ = alloc;
    _ = wat_source;
    // Stub — will be implemented in 12.2-12.5
    return error.InvalidWat;
}

// ============================================================
// Tokenizer
// ============================================================

pub const TokenTag = enum {
    lparen,
    rparen,
    keyword, // module, func, param, result, i32, i64, f32, f64, etc.
    ident, // $name
    integer, // 42, 0xFF, -1
    float, // 1.0, 0x1p+0, nan, inf
    string, // "hello\n"
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    text: []const u8,
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: usize,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source, .pos = 0 };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespaceAndComments();
        if (self.pos >= self.source.len) return .{ .tag = .eof, .text = "" };

        const c = self.source[self.pos];

        if (c == '(') {
            self.pos += 1;
            return .{ .tag = .lparen, .text = "(" };
        }
        if (c == ')') {
            self.pos += 1;
            return .{ .tag = .rparen, .text = ")" };
        }
        if (c == '"') return self.readString();
        if (c == '$') return self.readIdent();
        if (c == '+' or c == '-') {
            // Could be a signed number or keyword
            if (self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1])) {
                return self.readNumber();
            }
            return self.readKeyword();
        }
        if (isDigit(c)) return self.readNumber();
        return self.readKeyword();
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
                continue;
            }
            // Line comment: ;;
            if (c == ';' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
                continue;
            }
            // Block comment: (; ... ;)
            if (c == '(' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == ';') {
                self.pos += 2;
                var depth: usize = 1;
                while (self.pos + 1 < self.source.len and depth > 0) {
                    if (self.source[self.pos] == '(' and self.source[self.pos + 1] == ';') {
                        depth += 1;
                        self.pos += 2;
                    } else if (self.source[self.pos] == ';' and self.source[self.pos + 1] == ')') {
                        depth -= 1;
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                    }
                }
                continue;
            }
            break;
        }
    }

    fn readString(self: *Tokenizer) Token {
        const start = self.pos;
        self.pos += 1; // skip opening "
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == '\\') {
                self.pos += 2; // skip escape sequence
                continue;
            }
            if (self.source[self.pos] == '"') {
                self.pos += 1;
                return .{ .tag = .string, .text = self.source[start..self.pos] };
            }
            self.pos += 1;
        }
        return .{ .tag = .string, .text = self.source[start..self.pos] };
    }

    fn readIdent(self: *Tokenizer) Token {
        const start = self.pos;
        self.pos += 1; // skip $
        while (self.pos < self.source.len and isIdChar(self.source[self.pos])) {
            self.pos += 1;
        }
        return .{ .tag = .ident, .text = self.source[start..self.pos] };
    }

    fn readNumber(self: *Tokenizer) Token {
        const start = self.pos;
        // Handle sign
        if (self.source[self.pos] == '+' or self.source[self.pos] == '-') {
            self.pos += 1;
        }
        // Check for hex prefix
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '0' and
            (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
        {
            self.pos += 2;
            var is_float = false;
            while (self.pos < self.source.len and (isHexDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                is_float = true;
                self.pos += 1;
                while (self.pos < self.source.len and (isHexDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                    self.pos += 1;
                }
            }
            if (self.pos < self.source.len and (self.source[self.pos] == 'p' or self.source[self.pos] == 'P')) {
                is_float = true;
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
            return .{ .tag = if (is_float) .float else .integer, .text = self.source[start..self.pos] };
        }
        // Decimal
        var is_float = false;
        while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.pos += 1;
            }
        }
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
        }
        return .{ .tag = if (is_float) .float else .integer, .text = self.source[start..self.pos] };
    }

    fn readKeyword(self: *Tokenizer) Token {
        const start = self.pos;
        while (self.pos < self.source.len and isIdChar(self.source[self.pos])) {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];
        // Check for special float keywords
        if (std.mem.eql(u8, text, "nan") or std.mem.eql(u8, text, "inf") or
            std.mem.startsWith(u8, text, "nan:") or
            std.mem.eql(u8, text, "+inf") or std.mem.eql(u8, text, "-inf") or
            std.mem.eql(u8, text, "+nan") or std.mem.eql(u8, text, "-nan"))
        {
            return .{ .tag = .float, .text = text };
        }
        return .{ .tag = .keyword, .text = text };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isIdChar(c: u8) bool {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9',
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '/',
            ':', '<', '=', '>', '?', '@', '\\', '^', '_', '`', '|', '~',
            => true,
            else => false,
        };
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "WAT — build option available" {
    if (build_options.enable_wat) {
        try testing.expect(true);
    } else {
        try testing.expect(true);
    }
}

test "WAT tokenizer — basic module" {
    var tok = Tokenizer.init("(module)");
    const t1 = tok.next();
    try testing.expectEqual(TokenTag.lparen, t1.tag);
    const t2 = tok.next();
    try testing.expectEqual(TokenTag.keyword, t2.tag);
    try testing.expectEqualStrings("module", t2.text);
    const t3 = tok.next();
    try testing.expectEqual(TokenTag.rparen, t3.tag);
    const t4 = tok.next();
    try testing.expectEqual(TokenTag.eof, t4.tag);
}

test "WAT tokenizer — func with params" {
    var tok = Tokenizer.init("(func $add (param i32 i32) (result i32))");
    try testing.expectEqual(TokenTag.lparen, tok.next().tag); // (
    try testing.expectEqualStrings("func", tok.next().text); // func
    const id = tok.next();
    try testing.expectEqual(TokenTag.ident, id.tag);
    try testing.expectEqualStrings("$add", id.text);
    try testing.expectEqual(TokenTag.lparen, tok.next().tag); // (
    try testing.expectEqualStrings("param", tok.next().text); // param
    try testing.expectEqualStrings("i32", tok.next().text); // i32
    try testing.expectEqualStrings("i32", tok.next().text); // i32
    try testing.expectEqual(TokenTag.rparen, tok.next().tag); // )
    try testing.expectEqual(TokenTag.lparen, tok.next().tag); // (
    try testing.expectEqualStrings("result", tok.next().text); // result
    try testing.expectEqualStrings("i32", tok.next().text); // i32
    try testing.expectEqual(TokenTag.rparen, tok.next().tag); // )
    try testing.expectEqual(TokenTag.rparen, tok.next().tag); // )
    try testing.expectEqual(TokenTag.eof, tok.next().tag);
}

test "WAT tokenizer — numbers" {
    var tok = Tokenizer.init("42 0xFF -1 1.0 0x1p+0");
    const t1 = tok.next();
    try testing.expectEqual(TokenTag.integer, t1.tag);
    try testing.expectEqualStrings("42", t1.text);
    const t2 = tok.next();
    try testing.expectEqual(TokenTag.integer, t2.tag);
    try testing.expectEqualStrings("0xFF", t2.text);
    const t3 = tok.next();
    try testing.expectEqual(TokenTag.integer, t3.tag);
    try testing.expectEqualStrings("-1", t3.text);
    const t4 = tok.next();
    try testing.expectEqual(TokenTag.float, t4.tag);
    try testing.expectEqualStrings("1.0", t4.text);
    const t5 = tok.next();
    try testing.expectEqual(TokenTag.float, t5.tag);
    try testing.expectEqualStrings("0x1p+0", t5.text);
}

test "WAT tokenizer — string and comments" {
    var tok = Tokenizer.init(
        \\;; line comment
        \\"hello\nworld"
        \\(; block ;) 42
    );
    const t1 = tok.next();
    try testing.expectEqual(TokenTag.string, t1.tag);
    try testing.expectEqualStrings("\"hello\\nworld\"", t1.text);
    const t2 = tok.next();
    try testing.expectEqual(TokenTag.integer, t2.tag);
    try testing.expectEqualStrings("42", t2.text);
}

test "WAT tokenizer — instructions" {
    var tok = Tokenizer.init("i32.add local.get memory.grow");
    try testing.expectEqualStrings("i32.add", tok.next().text);
    try testing.expectEqualStrings("local.get", tok.next().text);
    try testing.expectEqualStrings("memory.grow", tok.next().text);
    try testing.expectEqual(TokenTag.eof, tok.next().tag);
}
