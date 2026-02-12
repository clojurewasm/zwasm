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

pub const MemArg = struct {
    offset: u32,
    @"align": u32,
};

pub const WatInstr = union(enum) {
    // No immediates: i32.add, drop, nop, unreachable, return, etc.
    simple: []const u8,
    // Index immediate: local.get, call, br, global.get, ref.func, etc.
    index_op: struct { op: []const u8, index: WatIndex },
    // Constants
    i32_const: i32,
    i64_const: i64,
    f32_const: f32,
    f64_const: f64,
    // Memory operations (load/store)
    mem_op: struct { op: []const u8, mem_arg: MemArg },
    // Block/loop
    block_op: struct { op: []const u8, label: ?[]const u8, block_type: ?WatValType, body: []WatInstr },
    // If/else
    if_op: struct { label: ?[]const u8, block_type: ?WatValType, then_body: []WatInstr, else_body: []WatInstr },
    // br_table
    br_table: struct { targets: []WatIndex, default: WatIndex },
    // call_indirect
    call_indirect: struct { type_use: ?WatIndex, table_idx: u32 },
    // select with type
    select_t: []WatValType,
    // end / else markers (for flat instruction sequences)
    end,
    @"else",
};

pub const WatFunc = struct {
    name: ?[]const u8,
    type_use: ?WatIndex,
    params: []WatParam,
    results: []WatValType,
    locals: []WatParam,
    export_name: ?[]const u8,
    body: []WatInstr,
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
    init: []WatInstr,
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

        // Parse body instructions
        const body = try self.parseInstrList();
        _ = try self.expect(.rparen); // close (func ...)

        // Handle inline export
        if (export_name != null) {
            _ = exports; // inline exports handled in binary encoder
        }

        return .{
            .name = func_name,
            .type_use = type_use,
            .params = params.items,
            .results = results.items,
            .locals = locals.items,
            .export_name = export_name,
            .body = body,
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

        // Parse init expression
        const init_instrs = try self.parseInstrList();
        _ = try self.expect(.rparen); // close (global ...)

        return .{
            .name = glob_name,
            .global_type = global_type,
            .export_name = export_name,
            .init = init_instrs,
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

    // ============================================================
    // Instruction parsing
    // ============================================================

    /// Classify WAT instruction name into immediate category.
    const InstrCategory = enum {
        no_imm, // i32.add, drop, nop, unreachable, return, etc.
        index_imm, // local.get, call, br, global.get, ref.func, etc.
        i32_const,
        i64_const,
        f32_const,
        f64_const,
        mem_imm, // i32.load, i32.store, etc.
        block_type, // block, loop
        if_type, // if
        br_table,
        call_indirect,
        select_t,
    };

    fn classifyInstr(name: []const u8) InstrCategory {
        // Constants
        if (std.mem.eql(u8, name, "i32.const")) return .i32_const;
        if (std.mem.eql(u8, name, "i64.const")) return .i64_const;
        if (std.mem.eql(u8, name, "f32.const")) return .f32_const;
        if (std.mem.eql(u8, name, "f64.const")) return .f64_const;

        // Control - block types
        if (std.mem.eql(u8, name, "block")) return .block_type;
        if (std.mem.eql(u8, name, "loop")) return .block_type;
        if (std.mem.eql(u8, name, "if")) return .if_type;

        // Special control
        if (std.mem.eql(u8, name, "br_table")) return .br_table;
        if (std.mem.eql(u8, name, "call_indirect")) return .call_indirect;
        if (std.mem.eql(u8, name, "select")) return .no_imm;

        // Index instructions
        if (std.mem.eql(u8, name, "local.get") or
            std.mem.eql(u8, name, "local.set") or
            std.mem.eql(u8, name, "local.tee") or
            std.mem.eql(u8, name, "global.get") or
            std.mem.eql(u8, name, "global.set") or
            std.mem.eql(u8, name, "call") or
            std.mem.eql(u8, name, "br") or
            std.mem.eql(u8, name, "br_if") or
            std.mem.eql(u8, name, "ref.func") or
            std.mem.eql(u8, name, "table.get") or
            std.mem.eql(u8, name, "table.set") or
            std.mem.eql(u8, name, "table.size") or
            std.mem.eql(u8, name, "table.grow") or
            std.mem.eql(u8, name, "table.fill") or
            std.mem.eql(u8, name, "throw") or
            std.mem.eql(u8, name, "memory.size") or
            std.mem.eql(u8, name, "memory.grow"))
            return .index_imm;

        // Memory load/store
        if (isMemoryOp(name)) return .mem_imm;

        // Default: no immediate
        return .no_imm;
    }

    fn isMemoryOp(name: []const u8) bool {
        const prefixes = [_][]const u8{
            "i32.load", "i64.load", "f32.load", "f64.load",
            "i32.store", "i64.store", "f32.store", "f64.store",
        };
        for (prefixes) |prefix| {
            if (std.mem.eql(u8, name, prefix)) return true;
            if (name.len > prefix.len and std.mem.startsWith(u8, name, prefix)) return true;
        }
        return false;
    }

    /// Parse instruction list until ) or end-of-block.
    /// Does NOT consume the closing ).
    fn parseInstrList(self: *Parser) WatError![]WatInstr {
        var instrs: std.ArrayListUnmanaged(WatInstr) = .empty;

        while (self.current.tag != .rparen and self.current.tag != .eof) {
            if (self.current.tag == .lparen) {
                // Folded S-expression: (op args...)
                try self.parseFoldedInstr(&instrs);
            } else if (self.current.tag == .keyword) {
                // Flat instruction
                try self.parsePlainInstr(&instrs);
            } else {
                break;
            }
        }

        return instrs.items;
    }

    /// Parse a folded S-expression instruction.
    /// (op folded-args... plain-args...)
    /// Unfolded: inner args first, then outer op.
    fn parseFoldedInstr(self: *Parser, instrs: *std.ArrayListUnmanaged(WatInstr)) WatError!void {
        _ = self.advance(); // consume (

        if (self.current.tag != .keyword) return error.InvalidWat;
        const op_name = self.advance().text;
        const cat = classifyInstr(op_name);

        switch (cat) {
            .block_type => {
                // (block $label? (result type)? instr*)
                var label: ?[]const u8 = null;
                var block_type: ?WatValType = null;
                if (self.current.tag == .ident) label = self.advance().text;
                if (self.current.tag == .lparen) {
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance();
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "result")) {
                        _ = self.advance();
                        block_type = try self.parseValType();
                        _ = try self.expect(.rparen);
                    } else {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                    }
                }
                const body = try self.parseInstrList();
                _ = try self.expect(.rparen);
                instrs.append(self.alloc, .{ .block_op = .{
                    .op = op_name,
                    .label = label,
                    .block_type = block_type,
                    .body = body,
                } }) catch return error.OutOfMemory;
            },
            .if_type => {
                // (if $label? (result type)? (then instr*) (else instr*)?)
                var label: ?[]const u8 = null;
                var block_type: ?WatValType = null;
                if (self.current.tag == .ident) label = self.advance().text;
                if (self.current.tag == .lparen) {
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance();
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "result")) {
                        _ = self.advance();
                        block_type = try self.parseValType();
                        _ = try self.expect(.rparen);
                    } else {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                    }
                }

                // Parse condition (folded exprs before then/else)
                while (self.current.tag == .lparen) {
                    // Check if next is (then or (else
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance();
                    if (self.current.tag == .keyword and
                        (std.mem.eql(u8, self.current.text, "then") or
                        std.mem.eql(u8, self.current.text, "else")))
                    {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                        break;
                    }
                    self.tok.pos = saved_pos;
                    self.current = saved_current;
                    try self.parseFoldedInstr(instrs);
                }

                var then_body: []WatInstr = &.{};
                var else_body: []WatInstr = &.{};

                // (then instr*)
                if (self.current.tag == .lparen) {
                    _ = self.advance();
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "then")) {
                        _ = self.advance();
                        then_body = try self.parseInstrList();
                        _ = try self.expect(.rparen);
                    }
                }
                // (else instr*)
                if (self.current.tag == .lparen) {
                    _ = self.advance();
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "else")) {
                        _ = self.advance();
                        else_body = try self.parseInstrList();
                        _ = try self.expect(.rparen);
                    }
                }

                _ = try self.expect(.rparen); // close (if ...)

                instrs.append(self.alloc, .{ .if_op = .{
                    .label = label,
                    .block_type = block_type,
                    .then_body = then_body,
                    .else_body = else_body,
                } }) catch return error.OutOfMemory;
            },
            else => {
                // Generic folded: (op folded-args... immediates)
                // First parse any nested folded expressions
                while (self.current.tag == .lparen) {
                    try self.parseFoldedInstr(instrs);
                }
                // Then parse the instruction with its immediates
                try self.emitInstr(instrs, op_name, cat);
                _ = try self.expect(.rparen);
            },
        }
    }

    /// Parse a plain (non-folded) instruction.
    fn parsePlainInstr(self: *Parser, instrs: *std.ArrayListUnmanaged(WatInstr)) WatError!void {
        const op_name = self.advance().text;
        const cat = classifyInstr(op_name);

        switch (cat) {
            .block_type => {
                // block $label? (result type)? ... end
                var label: ?[]const u8 = null;
                var block_type: ?WatValType = null;
                if (self.current.tag == .ident) label = self.advance().text;
                // Check for (result type)
                if (self.current.tag == .lparen) {
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance();
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "result")) {
                        _ = self.advance();
                        block_type = try self.parseValType();
                        _ = try self.expect(.rparen);
                    } else {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                    }
                }
                // inline valtype (e.g. "block i32 ...")
                if (block_type == null and self.current.tag == .keyword) {
                    const vt = self.tryParseValType();
                    if (vt != null) block_type = vt;
                }
                const body = try self.parseBlockBody();
                instrs.append(self.alloc, .{ .block_op = .{
                    .op = op_name,
                    .label = label,
                    .block_type = block_type,
                    .body = body,
                } }) catch return error.OutOfMemory;
            },
            .if_type => {
                var label: ?[]const u8 = null;
                var block_type: ?WatValType = null;
                if (self.current.tag == .ident) label = self.advance().text;
                if (self.current.tag == .lparen) {
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance();
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "result")) {
                        _ = self.advance();
                        block_type = try self.parseValType();
                        _ = try self.expect(.rparen);
                    } else {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                    }
                }
                if (block_type == null and self.current.tag == .keyword) {
                    const vt = self.tryParseValType();
                    if (vt != null) block_type = vt;
                }
                // Parse then body until "else" or "end"
                const then_body = try self.parseIfBody();
                var else_body: []WatInstr = &.{};
                // Check for "else"
                if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "else")) {
                    _ = self.advance();
                    else_body = try self.parseBlockBody();
                }
                instrs.append(self.alloc, .{ .if_op = .{
                    .label = label,
                    .block_type = block_type,
                    .then_body = then_body,
                    .else_body = else_body,
                } }) catch return error.OutOfMemory;
            },
            else => {
                try self.emitInstr(instrs, op_name, cat);
            },
        }
    }

    /// Emit a single instruction with its immediates.
    fn emitInstr(self: *Parser, instrs: *std.ArrayListUnmanaged(WatInstr), op_name: []const u8, cat: InstrCategory) WatError!void {
        const instr: WatInstr = switch (cat) {
            .no_imm => .{ .simple = op_name },
            .index_imm => .{ .index_op = .{ .op = op_name, .index = try self.parseIndex() } },
            .i32_const => .{ .i32_const = try self.parseI32() },
            .i64_const => .{ .i64_const = try self.parseI64() },
            .f32_const => .{ .f32_const = try self.parseF32() },
            .f64_const => .{ .f64_const = try self.parseF64() },
            .mem_imm => .{ .mem_op = .{ .op = op_name, .mem_arg = try self.parseMemArg() } },
            .br_table => blk: {
                var targets: std.ArrayListUnmanaged(WatIndex) = .empty;
                while (self.current.tag == .integer or self.current.tag == .ident) {
                    targets.append(self.alloc, try self.parseIndex()) catch return error.OutOfMemory;
                }
                if (targets.items.len == 0) return error.InvalidWat;
                const default = targets.items[targets.items.len - 1];
                break :blk .{ .br_table = .{
                    .targets = targets.items[0 .. targets.items.len - 1],
                    .default = default,
                } };
            },
            .call_indirect => blk: {
                // call_indirect (type $t)? $table?
                var type_idx: ?WatIndex = null;
                var table_idx: u32 = 0;
                if (self.current.tag == .lparen) {
                    _ = self.advance();
                    try self.expectKeyword("type");
                    type_idx = try self.parseIndex();
                    _ = try self.expect(.rparen);
                }
                if (self.current.tag == .integer) {
                    const text = self.advance().text;
                    table_idx = std.fmt.parseInt(u32, text, 10) catch return error.InvalidWat;
                }
                break :blk .{ .call_indirect = .{ .type_use = type_idx, .table_idx = table_idx } };
            },
            .select_t => blk: {
                // select (result type)
                var types: std.ArrayListUnmanaged(WatValType) = .empty;
                if (self.current.tag == .lparen) {
                    _ = self.advance();
                    try self.expectKeyword("result");
                    while (self.current.tag == .keyword) {
                        types.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                    }
                    _ = try self.expect(.rparen);
                }
                break :blk .{ .select_t = types.items };
            },
            .block_type, .if_type => unreachable, // handled in caller
        };
        instrs.append(self.alloc, instr) catch return error.OutOfMemory;
    }

    /// Parse flat block body until "end" keyword.
    fn parseBlockBody(self: *Parser) WatError![]WatInstr {
        var instrs: std.ArrayListUnmanaged(WatInstr) = .empty;
        while (self.current.tag != .eof) {
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "end")) {
                _ = self.advance();
                break;
            }
            if (self.current.tag == .lparen) {
                try self.parseFoldedInstr(&instrs);
            } else if (self.current.tag == .keyword) {
                try self.parsePlainInstr(&instrs);
            } else {
                break;
            }
        }
        return instrs.items;
    }

    /// Parse flat if body until "else" or "end" keyword.
    fn parseIfBody(self: *Parser) WatError![]WatInstr {
        var instrs: std.ArrayListUnmanaged(WatInstr) = .empty;
        while (self.current.tag != .eof) {
            if (self.current.tag == .keyword and
                (std.mem.eql(u8, self.current.text, "end") or
                std.mem.eql(u8, self.current.text, "else")))
            {
                if (std.mem.eql(u8, self.current.text, "end")) {
                    _ = self.advance();
                }
                break;
            }
            if (self.current.tag == .lparen) {
                try self.parseFoldedInstr(&instrs);
            } else if (self.current.tag == .keyword) {
                try self.parsePlainInstr(&instrs);
            } else {
                break;
            }
        }
        return instrs.items;
    }

    fn tryParseValType(self: *Parser) ?WatValType {
        if (self.current.tag != .keyword) return null;
        if (std.mem.eql(u8, self.current.text, "i32")) { _ = self.advance(); return .i32; }
        if (std.mem.eql(u8, self.current.text, "i64")) { _ = self.advance(); return .i64; }
        if (std.mem.eql(u8, self.current.text, "f32")) { _ = self.advance(); return .f32; }
        if (std.mem.eql(u8, self.current.text, "f64")) { _ = self.advance(); return .f64; }
        return null;
    }

    fn parseI32(self: *Parser) WatError!i32 {
        if (self.current.tag != .integer) return error.InvalidWat;
        const text = self.advance().text;
        return parseIntLiteral(i32, text) catch return error.InvalidWat;
    }

    fn parseI64(self: *Parser) WatError!i64 {
        if (self.current.tag != .integer) return error.InvalidWat;
        const text = self.advance().text;
        return parseIntLiteral(i64, text) catch return error.InvalidWat;
    }

    fn parseF32(self: *Parser) WatError!f32 {
        if (self.current.tag != .float and self.current.tag != .integer) return error.InvalidWat;
        const text = self.advance().text;
        return parseFloatLiteral(f32, text) catch return error.InvalidWat;
    }

    fn parseF64(self: *Parser) WatError!f64 {
        if (self.current.tag != .float and self.current.tag != .integer) return error.InvalidWat;
        const text = self.advance().text;
        return parseFloatLiteral(f64, text) catch return error.InvalidWat;
    }

    fn parseMemArg(self: *Parser) WatError!MemArg {
        var offset: u32 = 0;
        var alignment: u32 = 0;
        // Parse offset=N and align=N in any order
        while (self.current.tag == .keyword) {
            if (std.mem.startsWith(u8, self.current.text, "offset=")) {
                const val_text = self.current.text["offset=".len..];
                offset = parseIntLiteral(u32, val_text) catch return error.InvalidWat;
                _ = self.advance();
            } else if (std.mem.startsWith(u8, self.current.text, "align=")) {
                const val_text = self.current.text["align=".len..];
                alignment = parseIntLiteral(u32, val_text) catch return error.InvalidWat;
                _ = self.advance();
            } else {
                break;
            }
        }
        return .{ .offset = offset, .@"align" = alignment };
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
// Number literal parsing
// ============================================================

/// Parse WAT integer literal: decimal, hex (0x), with optional sign and underscores.
fn parseIntLiteral(comptime T: type, text: []const u8) !T {
    var s = text;
    var negative = false;
    if (s.len > 0 and s[0] == '-') {
        negative = true;
        s = s[1..];
    } else if (s.len > 0 and s[0] == '+') {
        s = s[1..];
    }

    // Remove underscores
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    for (s) |c| {
        if (c != '_') {
            if (len >= buf.len) return error.Overflow;
            buf[len] = c;
            len += 1;
        }
    }
    const clean = buf[0..len];

    if (clean.len >= 2 and clean[0] == '0' and (clean[1] == 'x' or clean[1] == 'X')) {
        // Hex
        const hex = clean[2..];
        if (@typeInfo(T).int.signedness == .signed) {
            const U = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
            const val = std.fmt.parseInt(U, hex, 16) catch return error.Overflow;
            const result: T = @bitCast(val);
            return if (negative) -%result else result;
        } else {
            return std.fmt.parseInt(T, hex, 16) catch return error.Overflow;
        }
    }

    // Decimal
    if (@typeInfo(T).int.signedness == .signed) {
        const val = std.fmt.parseInt(T, clean, 10) catch return error.Overflow;
        return if (negative) -val else val;
    } else {
        return std.fmt.parseInt(T, clean, 10) catch return error.Overflow;
    }
}

/// Parse WAT float literal: decimal, hex float, nan, inf.
fn parseFloatLiteral(comptime T: type, text: []const u8) !T {
    // Handle special values
    if (std.mem.eql(u8, text, "nan")) return std.math.nan(T);
    if (std.mem.eql(u8, text, "+nan") or std.mem.eql(u8, text, "-nan")) return std.math.nan(T);
    if (std.mem.eql(u8, text, "inf") or std.mem.eql(u8, text, "+inf")) return std.math.inf(T);
    if (std.mem.eql(u8, text, "-inf")) return -std.math.inf(T);

    // Handle nan:0xN canonical NaN payload
    if (std.mem.startsWith(u8, text, "nan:0x")) return std.math.nan(T);

    // Remove underscores
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        if (c != '_') {
            if (len >= buf.len) return error.Overflow;
            buf[len] = c;
            len += 1;
        }
    }
    const clean = buf[0..len];

    return std.fmt.parseFloat(T, clean) catch return error.Overflow;
}

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

// ============================================================
// Instruction Parser Tests
// ============================================================

test "WAT parser — func with i32.add body" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func $add (param i32 i32) (result i32)
        \\    local.get 0
        \\    local.get 1
        \\    i32.add
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.functions.len);
    const body = mod.functions[0].body;
    try testing.expectEqual(@as(usize, 3), body.len);
    // local.get 0
    try testing.expectEqualStrings("local.get", body[0].index_op.op);
    try testing.expectEqual(@as(u32, 0), body[0].index_op.index.num);
    // local.get 1
    try testing.expectEqual(@as(u32, 1), body[1].index_op.index.num);
    // i32.add
    try testing.expectEqualStrings("i32.add", body[2].simple);
}

test "WAT parser — i32.const instruction" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func (result i32)
        \\    i32.const 42
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    const body = mod.functions[0].body;
    try testing.expectEqual(@as(usize, 1), body.len);
    try testing.expectEqual(@as(i32, 42), body[0].i32_const);
}

test "WAT parser — folded S-expression" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func $add (param i32 i32) (result i32)
        \\    (i32.add (local.get 0) (local.get 1))
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    const body = mod.functions[0].body;
    // Unfolded: local.get 0, local.get 1, i32.add
    try testing.expectEqual(@as(usize, 3), body.len);
    try testing.expectEqualStrings("local.get", body[0].index_op.op);
    try testing.expectEqual(@as(u32, 0), body[0].index_op.index.num);
    try testing.expectEqualStrings("local.get", body[1].index_op.op);
    try testing.expectEqual(@as(u32, 1), body[1].index_op.index.num);
    try testing.expectEqualStrings("i32.add", body[2].simple);
}

test "WAT parser — nested folded expressions" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func (result i32)
        \\    (i32.add (i32.const 1) (i32.mul (i32.const 2) (i32.const 3)))
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    const body = mod.functions[0].body;
    // Unfolded: i32.const 1, i32.const 2, i32.const 3, i32.mul, i32.add
    try testing.expectEqual(@as(usize, 5), body.len);
    try testing.expectEqual(@as(i32, 1), body[0].i32_const);
    try testing.expectEqual(@as(i32, 2), body[1].i32_const);
    try testing.expectEqual(@as(i32, 3), body[2].i32_const);
    try testing.expectEqualStrings("i32.mul", body[3].simple);
    try testing.expectEqualStrings("i32.add", body[4].simple);
}

test "WAT parser — block instruction" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func
        \\    (block $outer
        \\      (br 0)
        \\    )
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    const body = mod.functions[0].body;
    try testing.expectEqual(@as(usize, 1), body.len);
    const blk = body[0].block_op;
    try testing.expectEqualStrings("block", blk.op);
    try testing.expectEqualStrings("$outer", blk.label.?);
    try testing.expectEqual(@as(usize, 1), blk.body.len);
}

test "WAT parser — if/then/else" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func (param i32) (result i32)
        \\    (if (result i32) (local.get 0)
        \\      (then (i32.const 1))
        \\      (else (i32.const 0))
        \\    )
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    const body = mod.functions[0].body;
    // Condition (local.get 0) is unfolded before the if
    try testing.expectEqual(@as(usize, 2), body.len);
    try testing.expectEqualStrings("local.get", body[0].index_op.op);
    const if_op = body[1].if_op;
    try testing.expectEqual(WatValType.i32, if_op.block_type.?);
    try testing.expectEqual(@as(usize, 1), if_op.then_body.len);
    try testing.expectEqual(@as(usize, 1), if_op.else_body.len);
}

test "WAT parser — global with init" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (global $g i32 (i32.const 42))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.globals.len);
    try testing.expect(!mod.globals[0].global_type.mutable);
    try testing.expectEqual(@as(usize, 1), mod.globals[0].init.len);
    try testing.expectEqual(@as(i32, 42), mod.globals[0].init[0].i32_const);
}

test "WAT parser — memory load/store" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func (param i32)
        \\    (i32.store offset=4 align=4 (i32.const 0) (local.get 0))
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    const body = mod.functions[0].body;
    // Unfolded: i32.const 0, local.get 0, i32.store
    try testing.expectEqual(@as(usize, 3), body.len);
    try testing.expectEqual(@as(i32, 0), body[0].i32_const);
    try testing.expectEqualStrings("local.get", body[1].index_op.op);
    const store = body[2].mem_op;
    try testing.expectEqualStrings("i32.store", store.op);
    try testing.expectEqual(@as(u32, 4), store.mem_arg.offset);
    try testing.expectEqual(@as(u32, 4), store.mem_arg.@"align");
}

test "WAT parser — loop with br_if" {
    var parser = Parser.init(testing.allocator,
        \\(module
        \\  (func (param i32)
        \\    (loop $L
        \\      (br_if 0 (local.get 0))
        \\    )
        \\  )
        \\)
    );
    const mod = try parser.parseModule();
    const body = mod.functions[0].body;
    try testing.expectEqual(@as(usize, 1), body.len);
    const lp = body[0].block_op;
    try testing.expectEqualStrings("loop", lp.op);
    try testing.expectEqualStrings("$L", lp.label.?);
    // Loop body: local.get 0, br_if 0
    try testing.expectEqual(@as(usize, 2), lp.body.len);
}

test "WAT parser — number literals" {
    try testing.expectEqual(@as(i32, 42), try parseIntLiteral(i32, "42"));
    try testing.expectEqual(@as(i32, -1), try parseIntLiteral(i32, "-1"));
    try testing.expectEqual(@as(i32, 255), try parseIntLiteral(i32, "0xFF"));
    try testing.expectEqual(@as(i32, 1000), try parseIntLiteral(i32, "1_000"));
    try testing.expectEqual(@as(i64, 0x7FFFFFFFFFFFFFFF), try parseIntLiteral(i64, "0x7FFFFFFFFFFFFFFF"));
}
