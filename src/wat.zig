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
// AST
// ============================================================

pub const WatIndex = union(enum) {
    num: u32,
    name: []const u8,
};

pub const WatValType = enum {
    i32,
    i64,
    f32,
    f64,
    funcref,
    externref,
};

pub const WatFuncType = struct {
    params: []WatValType,
    results: []WatValType,
};

pub const WatParam = struct {
    name: ?[]const u8,
    valtype: WatValType,
};

pub const WatFunc = struct {
    name: ?[]const u8,
    type_use: ?WatIndex,
    params: []WatParam,
    results: []WatValType,
    locals: []WatParam,
    export_name: ?[]const u8,
    // body: instructions — added in 12.4
};

pub const WatLimits = struct {
    min: u64,
    max: ?u64,
};

pub const WatMemory = struct {
    name: ?[]const u8,
    limits: WatLimits,
    export_name: ?[]const u8,
};

pub const WatTable = struct {
    name: ?[]const u8,
    limits: WatLimits,
    reftype: WatValType,
    export_name: ?[]const u8,
};

pub const WatGlobalType = struct {
    valtype: WatValType,
    mutable: bool,
};

pub const WatGlobal = struct {
    name: ?[]const u8,
    global_type: WatGlobalType,
    export_name: ?[]const u8,
    // init: instructions — added in 12.4
};

pub const WatImportKind = union(enum) {
    func: struct {
        type_use: ?WatIndex,
        params: []WatParam,
        results: []WatValType,
    },
    memory: WatLimits,
    table: struct {
        limits: WatLimits,
        reftype: WatValType,
    },
    global: WatGlobalType,
};

pub const WatImport = struct {
    module_name: []const u8,
    name: []const u8,
    id: ?[]const u8,
    kind: WatImportKind,
};

pub const WatExportKind = enum {
    func,
    memory,
    table,
    global,
};

pub const WatExport = struct {
    name: []const u8,
    kind: WatExportKind,
    index: WatIndex,
};

pub const WatModule = struct {
    name: ?[]const u8,
    types: []WatFuncType,
    imports: []WatImport,
    functions: []WatFunc,
    memories: []WatMemory,
    tables: []WatTable,
    globals: []WatGlobal,
    exports: []WatExport,
    start: ?WatIndex,
};

// ============================================================
// Parser
// ============================================================

pub const Parser = struct {
    tok: Tokenizer,
    alloc: Allocator,
    current: Token,

    pub fn init(alloc: Allocator, source: []const u8) Parser {
        var tok = Tokenizer.init(source);
        const current = tok.next();
        return .{ .tok = tok, .alloc = alloc, .current = current };
    }

    fn advance(self: *Parser) Token {
        const prev = self.current;
        self.current = self.tok.next();
        return prev;
    }

    fn expect(self: *Parser, tag: TokenTag) WatError!Token {
        if (self.current.tag != tag) return error.InvalidWat;
        return self.advance();
    }

    fn expectKeyword(self: *Parser, kw: []const u8) WatError!void {
        if (self.current.tag != .keyword or !std.mem.eql(u8, self.current.text, kw))
            return error.InvalidWat;
        _ = self.advance();
    }

    pub fn parseModule(self: *Parser) WatError!WatModule {
        _ = try self.expect(.lparen);
        try self.expectKeyword("module");

        // Optional module name
        var mod_name: ?[]const u8 = null;
        if (self.current.tag == .ident) {
            mod_name = self.advance().text;
        }

        var types: std.ArrayListUnmanaged(WatFuncType) = .empty;
        var imports: std.ArrayListUnmanaged(WatImport) = .empty;
        var functions: std.ArrayListUnmanaged(WatFunc) = .empty;
        var memories: std.ArrayListUnmanaged(WatMemory) = .empty;
        var tables: std.ArrayListUnmanaged(WatTable) = .empty;
        var globals: std.ArrayListUnmanaged(WatGlobal) = .empty;
        var exports: std.ArrayListUnmanaged(WatExport) = .empty;
        var start: ?WatIndex = null;

        while (self.current.tag != .rparen and self.current.tag != .eof) {
            if (self.current.tag != .lparen) return error.InvalidWat;
            _ = self.advance(); // consume (

            if (self.current.tag != .keyword) return error.InvalidWat;
            const section = self.current.text;

            if (std.mem.eql(u8, section, "type")) {
                _ = self.advance();
                types.append(self.alloc, try self.parseTypeDef()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "func")) {
                _ = self.advance();
                const func = try self.parseFunc(&exports);
                functions.append(self.alloc, func) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "memory")) {
                _ = self.advance();
                memories.append(self.alloc, try self.parseMemory(&exports)) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "table")) {
                _ = self.advance();
                tables.append(self.alloc, try self.parseTable(&exports)) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "global")) {
                _ = self.advance();
                globals.append(self.alloc, try self.parseGlobal(&exports)) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "import")) {
                _ = self.advance();
                imports.append(self.alloc, try self.parseImport()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "export")) {
                _ = self.advance();
                exports.append(self.alloc, try self.parseExport()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "start")) {
                _ = self.advance();
                start = try self.parseIndex();
                _ = try self.expect(.rparen);
            } else {
                // Skip unknown sections
                try self.skipSExpr();
            }
        }

        _ = try self.expect(.rparen);

        return .{
            .name = mod_name,
            .types = types.items,
            .imports = imports.items,
            .functions = functions.items,
            .memories = memories.items,
            .tables = tables.items,
            .globals = globals.items,
            .exports = exports.items,
            .start = start,
        };
    }

    fn parseIndex(self: *Parser) WatError!WatIndex {
        if (self.current.tag == .integer) {
            const text = self.advance().text;
            const val = std.fmt.parseInt(u32, text, 10) catch return error.InvalidWat;
            return .{ .num = val };
        }
        if (self.current.tag == .ident) {
            return .{ .name = self.advance().text };
        }
        return error.InvalidWat;
    }

    fn parseValType(self: *Parser) WatError!WatValType {
        if (self.current.tag != .keyword) return error.InvalidWat;
        const text = self.advance().text;
        if (std.mem.eql(u8, text, "i32")) return .i32;
        if (std.mem.eql(u8, text, "i64")) return .i64;
        if (std.mem.eql(u8, text, "f32")) return .f32;
        if (std.mem.eql(u8, text, "f64")) return .f64;
        if (std.mem.eql(u8, text, "funcref")) return .funcref;
        if (std.mem.eql(u8, text, "externref")) return .externref;
        return error.InvalidWat;
    }

    fn parseTypeDef(self: *Parser) WatError!WatFuncType {
        // (type $name? (func (param ...) (result ...)))
        // We've already consumed "type"
        if (self.current.tag == .ident) _ = self.advance(); // skip optional $name

        _ = try self.expect(.lparen);
        try self.expectKeyword("func");

        var params: std.ArrayListUnmanaged(WatValType) = .empty;
        var results: std.ArrayListUnmanaged(WatValType) = .empty;

        while (self.current.tag == .lparen) {
            // Peek at the keyword after (
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance(); // consume (
            if (self.current.tag != .keyword) {
                // Restore and break
                self.tok.pos = saved_pos;
                self.current = saved_current;
                break;
            }
            if (std.mem.eql(u8, self.current.text, "param")) {
                _ = self.advance(); // consume "param"
                while (self.current.tag == .keyword or self.current.tag == .ident) {
                    if (self.current.tag == .ident) {
                        _ = self.advance(); // skip param name
                        params.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                    } else {
                        params.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                    }
                }
                _ = try self.expect(.rparen);
            } else if (std.mem.eql(u8, self.current.text, "result")) {
                _ = self.advance(); // consume "result"
                while (self.current.tag == .keyword) {
                    results.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                }
                _ = try self.expect(.rparen);
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
                break;
            }
        }

        _ = try self.expect(.rparen); // close (func ...)
        _ = try self.expect(.rparen); // close (type ...)

        return .{ .params = params.items, .results = results.items };
    }

    fn parseFunc(self: *Parser, exports: *std.ArrayListUnmanaged(WatExport)) WatError!WatFunc {
        // (func $name? (export "name")? (type $t)? (param ...)* (result ...)* (local ...)* body...)
        // We've already consumed "func"
        var func_name: ?[]const u8 = null;
        if (self.current.tag == .ident) {
            func_name = self.advance().text;
        }

        var export_name: ?[]const u8 = null;
        var type_use: ?WatIndex = null;
        var params: std.ArrayListUnmanaged(WatParam) = .empty;
        var results: std.ArrayListUnmanaged(WatValType) = .empty;
        var locals: std.ArrayListUnmanaged(WatParam) = .empty;

        while (self.current.tag == .lparen) {
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance(); // consume (
            if (self.current.tag != .keyword) {
                self.tok.pos = saved_pos;
                self.current = saved_current;
                break;
            }
            if (std.mem.eql(u8, self.current.text, "export")) {
                _ = self.advance();
                const name_tok = try self.expect(.string);
                export_name = stripQuotes(name_tok.text);
                _ = try self.expect(.rparen);
            } else if (std.mem.eql(u8, self.current.text, "type")) {
                _ = self.advance();
                type_use = try self.parseIndex();
                _ = try self.expect(.rparen);
            } else if (std.mem.eql(u8, self.current.text, "param")) {
                _ = self.advance();
                // (param $name type) or (param type type ...)
                if (self.current.tag == .ident) {
                    const pname = self.advance().text;
                    const vt = try self.parseValType();
                    params.append(self.alloc, .{ .name = pname, .valtype = vt }) catch return error.OutOfMemory;
                } else {
                    while (self.current.tag == .keyword) {
                        const vt = try self.parseValType();
                        params.append(self.alloc, .{ .name = null, .valtype = vt }) catch return error.OutOfMemory;
                    }
                }
                _ = try self.expect(.rparen);
            } else if (std.mem.eql(u8, self.current.text, "result")) {
                _ = self.advance();
                while (self.current.tag == .keyword) {
                    results.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                }
                _ = try self.expect(.rparen);
            } else if (std.mem.eql(u8, self.current.text, "local")) {
                _ = self.advance();
                if (self.current.tag == .ident) {
                    const lname = self.advance().text;
                    const vt = try self.parseValType();
                    locals.append(self.alloc, .{ .name = lname, .valtype = vt }) catch return error.OutOfMemory;
                } else {
                    while (self.current.tag == .keyword) {
                        const vt = try self.parseValType();
                        locals.append(self.alloc, .{ .name = null, .valtype = vt }) catch return error.OutOfMemory;
                    }
                }
                _ = try self.expect(.rparen);
            } else {
                // Not a declaration — restore and break (body starts here)
                self.tok.pos = saved_pos;
                self.current = saved_current;
                break;
            }
        }

        // Skip body instructions for now (12.4)
        try self.skipToCloseParen();

        // Handle inline export
        if (export_name != null) {
            // func_index will be resolved later; for now use count as placeholder
            _ = exports; // inline exports handled in binary encoder
        }

        return .{
            .name = func_name,
            .type_use = type_use,
            .params = params.items,
            .results = results.items,
            .locals = locals.items,
            .export_name = export_name,
        };
    }

    fn parseMemory(self: *Parser, exports: *std.ArrayListUnmanaged(WatExport)) WatError!WatMemory {
        _ = exports;
        var mem_name: ?[]const u8 = null;
        var export_name: ?[]const u8 = null;

        if (self.current.tag == .ident) {
            mem_name = self.advance().text;
        }

        // Inline export
        if (self.current.tag == .lparen) {
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance();
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "export")) {
                _ = self.advance();
                const name_tok = try self.expect(.string);
                export_name = stripQuotes(name_tok.text);
                _ = try self.expect(.rparen);
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
            }
        }

        const limits = try self.parseLimits();
        _ = try self.expect(.rparen);

        return .{
            .name = mem_name,
            .limits = limits,
            .export_name = export_name,
        };
    }

    fn parseTable(self: *Parser, exports: *std.ArrayListUnmanaged(WatExport)) WatError!WatTable {
        _ = exports;
        var tbl_name: ?[]const u8 = null;
        var export_name: ?[]const u8 = null;

        if (self.current.tag == .ident) {
            tbl_name = self.advance().text;
        }

        // Inline export
        if (self.current.tag == .lparen) {
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance();
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "export")) {
                _ = self.advance();
                const name_tok = try self.expect(.string);
                export_name = stripQuotes(name_tok.text);
                _ = try self.expect(.rparen);
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
            }
        }

        const limits = try self.parseLimits();
        const reftype = try self.parseValType();
        _ = try self.expect(.rparen);

        return .{
            .name = tbl_name,
            .limits = limits,
            .reftype = reftype,
            .export_name = export_name,
        };
    }

    fn parseGlobal(self: *Parser, exports: *std.ArrayListUnmanaged(WatExport)) WatError!WatGlobal {
        _ = exports;
        var glob_name: ?[]const u8 = null;
        var export_name: ?[]const u8 = null;

        if (self.current.tag == .ident) {
            glob_name = self.advance().text;
        }

        // Inline export
        if (self.current.tag == .lparen) {
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance();
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "export")) {
                _ = self.advance();
                const name_tok = try self.expect(.string);
                export_name = stripQuotes(name_tok.text);
                _ = try self.expect(.rparen);
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
            }
        }

        // Global type: valtype or (mut valtype)
        var global_type: WatGlobalType = undefined;
        if (self.current.tag == .lparen) {
            _ = self.advance();
            try self.expectKeyword("mut");
            global_type = .{ .valtype = try self.parseValType(), .mutable = true };
            _ = try self.expect(.rparen);
        } else {
            global_type = .{ .valtype = try self.parseValType(), .mutable = false };
        }

        // Skip init expression for now (12.4)
        try self.skipToCloseParen();

        return .{
            .name = glob_name,
            .global_type = global_type,
            .export_name = export_name,
        };
    }

    fn parseImport(self: *Parser) WatError!WatImport {
        // (import "module" "name" (func $id? (type $t)? (param ...)* (result ...)*))
        const mod_tok = try self.expect(.string);
        const name_tok = try self.expect(.string);
        _ = try self.expect(.lparen);

        if (self.current.tag != .keyword) return error.InvalidWat;
        const kind_text = self.advance().text;

        var id: ?[]const u8 = null;
        if (self.current.tag == .ident) {
            id = self.advance().text;
        }

        var kind: WatImportKind = undefined;

        if (std.mem.eql(u8, kind_text, "func")) {
            var type_use: ?WatIndex = null;
            var params: std.ArrayListUnmanaged(WatParam) = .empty;
            var results: std.ArrayListUnmanaged(WatValType) = .empty;

            while (self.current.tag == .lparen) {
                const saved_pos = self.tok.pos;
                const saved_current = self.current;
                _ = self.advance();
                if (self.current.tag != .keyword) {
                    self.tok.pos = saved_pos;
                    self.current = saved_current;
                    break;
                }
                if (std.mem.eql(u8, self.current.text, "type")) {
                    _ = self.advance();
                    type_use = try self.parseIndex();
                    _ = try self.expect(.rparen);
                } else if (std.mem.eql(u8, self.current.text, "param")) {
                    _ = self.advance();
                    if (self.current.tag == .ident) {
                        const pname = self.advance().text;
                        const vt = try self.parseValType();
                        params.append(self.alloc, .{ .name = pname, .valtype = vt }) catch return error.OutOfMemory;
                    } else {
                        while (self.current.tag == .keyword) {
                            const vt = try self.parseValType();
                            params.append(self.alloc, .{ .name = null, .valtype = vt }) catch return error.OutOfMemory;
                        }
                    }
                    _ = try self.expect(.rparen);
                } else if (std.mem.eql(u8, self.current.text, "result")) {
                    _ = self.advance();
                    while (self.current.tag == .keyword) {
                        results.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                    }
                    _ = try self.expect(.rparen);
                } else {
                    self.tok.pos = saved_pos;
                    self.current = saved_current;
                    break;
                }
            }

            kind = .{ .func = .{ .type_use = type_use, .params = params.items, .results = results.items } };
        } else if (std.mem.eql(u8, kind_text, "memory")) {
            kind = .{ .memory = try self.parseLimits() };
        } else if (std.mem.eql(u8, kind_text, "table")) {
            const limits = try self.parseLimits();
            const reftype = try self.parseValType();
            kind = .{ .table = .{ .limits = limits, .reftype = reftype } };
        } else if (std.mem.eql(u8, kind_text, "global")) {
            if (self.current.tag == .lparen) {
                _ = self.advance();
                try self.expectKeyword("mut");
                const vt = try self.parseValType();
                _ = try self.expect(.rparen);
                kind = .{ .global = .{ .valtype = vt, .mutable = true } };
            } else {
                kind = .{ .global = .{ .valtype = try self.parseValType(), .mutable = false } };
            }
        } else {
            return error.InvalidWat;
        }

        _ = try self.expect(.rparen); // close inner (func/memory/...)
        _ = try self.expect(.rparen); // close (import ...)

        return .{
            .module_name = stripQuotes(mod_tok.text),
            .name = stripQuotes(name_tok.text),
            .id = id,
            .kind = kind,
        };
    }

    fn parseExport(self: *Parser) WatError!WatExport {
        // (export "name" (func $idx))
        const name_tok = try self.expect(.string);
        _ = try self.expect(.lparen);

        if (self.current.tag != .keyword) return error.InvalidWat;
        const kind_text = self.advance().text;

        const kind: WatExportKind = if (std.mem.eql(u8, kind_text, "func"))
            .func
        else if (std.mem.eql(u8, kind_text, "memory"))
            .memory
        else if (std.mem.eql(u8, kind_text, "table"))
            .table
        else if (std.mem.eql(u8, kind_text, "global"))
            .global
        else
            return error.InvalidWat;

        const index = try self.parseIndex();
        _ = try self.expect(.rparen); // close inner
        _ = try self.expect(.rparen); // close (export ...)

        return .{
            .name = stripQuotes(name_tok.text),
            .kind = kind,
            .index = index,
        };
    }

    fn parseLimits(self: *Parser) WatError!WatLimits {
        if (self.current.tag != .integer) return error.InvalidWat;
        const min_text = self.advance().text;
        const min = std.fmt.parseInt(u64, min_text, 10) catch return error.InvalidWat;

        var max: ?u64 = null;
        if (self.current.tag == .integer) {
            const max_text = self.advance().text;
            max = std.fmt.parseInt(u64, max_text, 10) catch return error.InvalidWat;
        }

        return .{ .min = min, .max = max };
    }

    fn skipSExpr(self: *Parser) WatError!void {
        // Already consumed opening ( and keyword — skip until matching )
        var depth: usize = 1;
        while (depth > 0 and self.current.tag != .eof) {
            if (self.current.tag == .lparen) depth += 1;
            if (self.current.tag == .rparen) depth -= 1;
            _ = self.advance();
        }
    }

    fn skipToCloseParen(self: *Parser) WatError!void {
        // Skip tokens until the matching ) for current depth
        var depth: usize = 0;
        while (self.current.tag != .eof) {
            if (self.current.tag == .lparen) {
                depth += 1;
            } else if (self.current.tag == .rparen) {
                if (depth == 0) {
                    _ = self.advance(); // consume the )
                    return;
                }
                depth -= 1;
            }
            _ = self.advance();
        }
        return error.InvalidWat;
    }

    fn stripQuotes(text: []const u8) []const u8 {
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
            return text[1 .. text.len - 1];
        }
        return text;
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

// ============================================================
// Parser Tests
// ============================================================

test "WAT parser — empty module" {
    var parser = Parser.init(testing.allocator, "(module)");
    const mod = try parser.parseModule();
    try testing.expect(mod.name == null);
    try testing.expectEqual(@as(usize, 0), mod.types.len);
    try testing.expectEqual(@as(usize, 0), mod.functions.len);
    try testing.expectEqual(@as(usize, 0), mod.memories.len);
    try testing.expectEqual(@as(usize, 0), mod.exports.len);
    try testing.expect(mod.start == null);
}

test "WAT parser — named module" {
    var parser = Parser.init(testing.allocator, "(module $test)");
    const mod = try parser.parseModule();
    try testing.expectEqualStrings("$test", mod.name.?);
}

test "WAT parser — type definition" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (type (func (param i32 i32) (result i32)))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.types.len);
    try testing.expectEqual(@as(usize, 2), mod.types[0].params.len);
    try testing.expectEqual(WatValType.i32, mod.types[0].params[0]);
    try testing.expectEqual(@as(usize, 1), mod.types[0].results.len);
}

test "WAT parser — func with params and result" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func $add (param $a i32) (param $b i32) (result i32))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.functions.len);
    const f = mod.functions[0];
    try testing.expectEqualStrings("$add", f.name.?);
    try testing.expectEqual(@as(usize, 2), f.params.len);
    try testing.expectEqualStrings("$a", f.params[0].name.?);
    try testing.expectEqual(WatValType.i32, f.params[0].valtype);
    try testing.expectEqual(@as(usize, 1), f.results.len);
}

test "WAT parser — memory" {
    var parser = Parser.init(testing.allocator,
        \\(module (memory 1 256))
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.memories.len);
    try testing.expectEqual(@as(u64, 1), mod.memories[0].limits.min);
    try testing.expectEqual(@as(u64, 256), mod.memories[0].limits.max.?);
}

test "WAT parser — export" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func)
        \\  (export "main" (func 0))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.exports.len);
    try testing.expectEqualStrings("main", mod.exports[0].name);
    try testing.expectEqual(WatExportKind.func, mod.exports[0].kind);
    try testing.expectEqual(@as(u32, 0), mod.exports[0].index.num);
}

test "WAT parser — import func" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (import "env" "log" (func $log (param i32)))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.imports.len);
    try testing.expectEqualStrings("env", mod.imports[0].module_name);
    try testing.expectEqualStrings("log", mod.imports[0].name);
    try testing.expectEqualStrings("$log", mod.imports[0].id.?);
    const func_kind = mod.imports[0].kind.func;
    try testing.expectEqual(@as(usize, 1), func_kind.params.len);
}

test "WAT parser — import memory" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (import "env" "mem" (memory 1))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.imports.len);
    try testing.expectEqual(@as(u64, 1), mod.imports[0].kind.memory.min);
}

test "WAT parser — global mutable" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (global $g (mut i32) (i32.const 0))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.globals.len);
    try testing.expect(mod.globals[0].global_type.mutable);
    try testing.expectEqual(WatValType.i32, mod.globals[0].global_type.valtype);
}

test "WAT parser — table" {
    var parser = Parser.init(testing.allocator,
        \\(module (table 10 funcref))
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.tables.len);
    try testing.expectEqual(@as(u64, 10), mod.tables[0].limits.min);
    try testing.expectEqual(WatValType.funcref, mod.tables[0].reftype);
}

test "WAT parser — start function" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func)
        \\  (start 0)
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(u32, 0), mod.start.?.num);
}

test "WAT parser — inline export on func" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func $add (export "add") (param i32 i32) (result i32))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.functions.len);
    try testing.expectEqualStrings("add", mod.functions[0].export_name.?);
}

test "WAT parser — multiple sections" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (type (func (param i32) (result i32)))
        \\  (import "env" "print" (func (param i32)))
        \\  (memory 1)
        \\  (func $double (param i32) (result i32))
        \\  (export "double" (func 1))
        \\  (export "mem" (memory 0))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.types.len);
    try testing.expectEqual(@as(usize, 1), mod.imports.len);
    try testing.expectEqual(@as(usize, 1), mod.memories.len);
    try testing.expectEqual(@as(usize, 1), mod.functions.len);
    try testing.expectEqual(@as(usize, 2), mod.exports.len);
}
