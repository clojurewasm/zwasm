// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! WAT (WebAssembly Text Format) parser — converts .wat to .wasm binary.
//!
//! Conditionally compiled via `-Dwat=false` build option.
//! When disabled, loadFromWat returns error.WatNotEnabled.

const std = @import("std");
const build_options = @import("build_options");
const SimdOpcode = @import("opcode.zig").SimdOpcode;
const MiscOpcode = @import("opcode.zig").MiscOpcode;
const AtomicOpcode = @import("opcode.zig").AtomicOpcode;
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
    // Use arena for parser intermediates — all freed when encode() returns
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var parser = Parser.init(arena_state.allocator(), wat_source);
    const module = try parser.parseModule();
    return encode(alloc, module);
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
    v128,
    funcref,
    externref,
    exnref,
};

pub const WatFuncType = struct {
    name: ?[]const u8 = null,
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
    v128_const: [16]u8,
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
    // try_table with catch clauses
    try_table: struct {
        label: ?[]const u8,
        block_type: ?WatValType,
        catches: []CatchClause,
        body: []WatInstr,
    },
    // end / else markers (for flat instruction sequences)
    end,
    @"else",

    pub const CatchClause = struct {
        kind: CatchKind,
        tag_idx: ?WatIndex, // for catch/catch_ref
        label: WatIndex,
    };

    pub const CatchKind = enum(u8) {
        @"catch" = 0,
        catch_ref = 1,
        catch_all = 2,
        catch_all_ref = 3,
    };
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

pub const WatDataMode = enum {
    active, // has offset expression, placed in memory at instantiation
    passive, // no offset, used with memory.init
};

pub const WatData = struct {
    name: ?[]const u8,
    memory_idx: WatIndex,
    mode: WatDataMode,
    offset: []WatInstr, // offset expression (active only)
    bytes: []const u8, // decoded byte content
};

pub const WatElem = struct {
    name: ?[]const u8,
    table_idx: WatIndex,
    offset: []WatInstr,
    func_indices: []WatIndex,
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
    data: []WatData,
    elements: []WatElem,
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
        var data_segments: std.ArrayListUnmanaged(WatData) = .empty;
        var elem_segments: std.ArrayListUnmanaged(WatElem) = .empty;

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
                if (start != null) return error.InvalidWat; // multiple start sections
                _ = self.advance();
                start = try self.parseIndex();
                _ = try self.expect(.rparen);
            } else if (std.mem.eql(u8, section, "data")) {
                _ = self.advance();
                data_segments.append(self.alloc, try self.parseData()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "elem")) {
                _ = self.advance();
                elem_segments.append(self.alloc, try self.parseElem()) catch return error.OutOfMemory;
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
            .data = data_segments.items,
            .elements = elem_segments.items,
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
        if (std.mem.eql(u8, text, "v128")) return .v128;
        if (std.mem.eql(u8, text, "funcref")) return .funcref;
        if (std.mem.eql(u8, text, "externref")) return .externref;
        if (std.mem.eql(u8, text, "exnref")) return .exnref;
        return error.InvalidWat;
    }

    fn parseTypeDef(self: *Parser) WatError!WatFuncType {
        // (type $name? (func (param ...) (result ...)))
        // We've already consumed "type"
        var type_name: ?[]const u8 = null;
        if (self.current.tag == .ident) type_name = self.advance().text;

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

        return .{ .name = type_name, .params = params.items, .results = results.items };
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

    /// Parse a data segment: (data $name? (memory $m)? (offset expr) "bytes"...)
    /// or passive: (data $name? "bytes"...)
    fn parseData(self: *Parser) WatError!WatData {
        // Optional name
        var name: ?[]const u8 = null;
        if (self.current.tag == .ident) {
            name = self.advance().text;
        }

        var memory_idx: WatIndex = .{ .num = 0 };
        var mode: WatDataMode = .passive;
        var offset_instrs: std.ArrayListUnmanaged(WatInstr) = .empty;

        // Check for offset expression — either (memory ...) or (offset ...) or (i32.const ...)
        if (self.current.tag == .lparen) {
            // Peek ahead to see if this is an offset expression or inline memory
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance(); // consume (

            if (self.current.tag == .keyword) {
                const kw = self.current.text;
                if (std.mem.eql(u8, kw, "memory")) {
                    // (memory $m) — explicit memory index
                    _ = self.advance();
                    memory_idx = try self.parseIndex();
                    _ = try self.expect(.rparen);
                    // Now parse offset expression
                    if (self.current.tag == .lparen) {
                        _ = self.advance();
                        try self.parseOffsetExpr(&offset_instrs);
                    } else return error.InvalidWat;
                    mode = .active;
                } else if (std.mem.eql(u8, kw, "offset")) {
                    // (offset expr)
                    _ = self.advance();
                    while (self.current.tag != .rparen) {
                        try self.parsePlainInstr(&offset_instrs);
                    }
                    _ = try self.expect(.rparen);
                    mode = .active;
                } else if (std.mem.eql(u8, kw, "i32.const") or
                    std.mem.eql(u8, kw, "i64.const") or
                    std.mem.eql(u8, kw, "global.get"))
                {
                    // Shorthand: (i32.const N) as offset expression
                    try self.parsePlainInstr(&offset_instrs);
                    _ = try self.expect(.rparen);
                    mode = .active;
                } else {
                    // Not an offset expression — restore and treat as passive
                    self.tok.pos = saved_pos;
                    self.current = saved_current;
                }
            } else {
                // Not a keyword after ( — restore
                self.tok.pos = saved_pos;
                self.current = saved_current;
            }
        }

        // Parse string literals (concatenated)
        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        while (self.current.tag == .string) {
            const str_tok = self.advance();
            const decoded = decodeWatString(self.alloc, stripQuotes(str_tok.text)) catch return error.OutOfMemory;
            bytes.appendSlice(self.alloc, decoded) catch return error.OutOfMemory;
        }

        _ = try self.expect(.rparen); // close (data ...)

        return .{
            .name = name,
            .memory_idx = memory_idx,
            .mode = mode,
            .offset = offset_instrs.items,
            .bytes = bytes.items,
        };
    }

    /// Helper to parse an offset expression that starts after the opening (
    fn parseOffsetExpr(self: *Parser, instrs: *std.ArrayListUnmanaged(WatInstr)) WatError!void {
        if (self.current.tag == .keyword) {
            const kw = self.current.text;
            if (std.mem.eql(u8, kw, "offset")) {
                _ = self.advance();
                while (self.current.tag != .rparen) {
                    try self.parsePlainInstr(instrs);
                }
                _ = try self.expect(.rparen);
            } else {
                // Shorthand expression like (i32.const N)
                try self.parsePlainInstr(instrs);
                _ = try self.expect(.rparen);
            }
        } else return error.InvalidWat;
    }

    /// Parse an elem segment: (elem $name? (table $t)? (offset expr) func $f...)
    fn parseElem(self: *Parser) WatError!WatElem {
        // Optional name
        var name: ?[]const u8 = null;
        if (self.current.tag == .ident) {
            name = self.advance().text;
        }

        var table_idx: WatIndex = .{ .num = 0 };
        var offset_instrs: std.ArrayListUnmanaged(WatInstr) = .empty;

        // Check for (table ...) or offset expression
        if (self.current.tag == .lparen) {
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance(); // consume (

            if (self.current.tag == .keyword) {
                const kw = self.current.text;
                if (std.mem.eql(u8, kw, "table")) {
                    // (table $t)
                    _ = self.advance();
                    table_idx = try self.parseIndex();
                    _ = try self.expect(.rparen);
                    // Now parse offset expression
                    if (self.current.tag == .lparen) {
                        _ = self.advance();
                        try self.parseOffsetExpr(&offset_instrs);
                    } else return error.InvalidWat;
                } else if (std.mem.eql(u8, kw, "offset")) {
                    _ = self.advance();
                    while (self.current.tag != .rparen) {
                        try self.parsePlainInstr(&offset_instrs);
                    }
                    _ = try self.expect(.rparen);
                } else if (std.mem.eql(u8, kw, "i32.const") or
                    std.mem.eql(u8, kw, "i64.const") or
                    std.mem.eql(u8, kw, "global.get"))
                {
                    try self.parsePlainInstr(&offset_instrs);
                    _ = try self.expect(.rparen);
                } else {
                    self.tok.pos = saved_pos;
                    self.current = saved_current;
                }
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
            }
        }

        // Parse "func" keyword then function indices
        var func_indices: std.ArrayListUnmanaged(WatIndex) = .empty;
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "func")) {
            _ = self.advance(); // consume "func"
        }
        while (self.current.tag == .integer or self.current.tag == .ident) {
            func_indices.append(self.alloc, try self.parseIndex()) catch return error.OutOfMemory;
        }

        _ = try self.expect(.rparen); // close (elem ...)

        return .{
            .name = name,
            .table_idx = table_idx,
            .offset = offset_instrs.items,
            .func_indices = func_indices.items,
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
        v128_const,
        mem_imm, // i32.load, i32.store, etc.
        block_type, // block, loop
        if_type, // if
        try_table_type, // try_table
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
        if (std.mem.eql(u8, name, "v128.const")) return .v128_const;

        // Control - block types
        if (std.mem.eql(u8, name, "block")) return .block_type;
        if (std.mem.eql(u8, name, "loop")) return .block_type;
        if (std.mem.eql(u8, name, "if")) return .if_type;
        if (std.mem.eql(u8, name, "try_table")) return .try_table_type;

        // Special control
        if (std.mem.eql(u8, name, "br_table")) return .br_table;
        if (std.mem.eql(u8, name, "call_indirect")) return .call_indirect;
        if (std.mem.eql(u8, name, "return_call_indirect")) return .call_indirect;
        if (std.mem.eql(u8, name, "select")) return .no_imm;

        // Index instructions
        if (std.mem.eql(u8, name, "local.get") or
            std.mem.eql(u8, name, "local.set") or
            std.mem.eql(u8, name, "local.tee") or
            std.mem.eql(u8, name, "global.get") or
            std.mem.eql(u8, name, "global.set") or
            std.mem.eql(u8, name, "call") or
            std.mem.eql(u8, name, "return_call") or
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
            std.mem.eql(u8, name, "memory.grow") or
            std.mem.eql(u8, name, "data.drop") or
            std.mem.eql(u8, name, "elem.drop") or
            std.mem.eql(u8, name, "memory.init") or
            std.mem.eql(u8, name, "table.init") or
            std.mem.eql(u8, name, "call_ref") or
            std.mem.eql(u8, name, "return_call_ref") or
            std.mem.eql(u8, name, "br_on_null") or
            std.mem.eql(u8, name, "br_on_non_null"))
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
            .try_table_type => {
                // try_table $label? (result type)? (catch tag $label)* body end
                var label: ?[]const u8 = null;
                var block_type: ?WatValType = null;
                if (self.current.tag == .ident) label = self.advance().text;
                // Parse optional (result type)
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
                // Parse catch clauses
                var catches: std.ArrayListUnmanaged(WatInstr.CatchClause) = .empty;
                while (self.current.tag == .lparen) {
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance();
                    if (self.current.tag != .keyword) {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                        break;
                    }
                    const catch_kw = self.current.text;
                    const kind: WatInstr.CatchKind = if (std.mem.eql(u8, catch_kw, "catch"))
                        .@"catch"
                    else if (std.mem.eql(u8, catch_kw, "catch_ref"))
                        .catch_ref
                    else if (std.mem.eql(u8, catch_kw, "catch_all"))
                        .catch_all
                    else if (std.mem.eql(u8, catch_kw, "catch_all_ref"))
                        .catch_all_ref
                    else {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                        break;
                    };
                    _ = self.advance(); // consume catch keyword
                    var tag_idx: ?WatIndex = null;
                    if (kind == .@"catch" or kind == .catch_ref) {
                        tag_idx = try self.parseIndex();
                    }
                    const catch_label = try self.parseIndex();
                    _ = try self.expect(.rparen);
                    catches.append(self.alloc, .{
                        .kind = kind,
                        .tag_idx = tag_idx,
                        .label = catch_label,
                    }) catch return error.OutOfMemory;
                }
                const body = try self.parseInstrList();
                _ = try self.expect(.rparen);
                instrs.append(self.alloc, .{ .try_table = .{
                    .label = label,
                    .block_type = block_type,
                    .catches = catches.items,
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
                // In folded form, immediates come before folded operands:
                //   (i32.store offset=4 (addr) (val))
                //   (br_if 0 (cond))
                //   (call $f (arg1) (arg2))
                // Parse the instruction (consuming immediates) first,
                // then parse folded operand expressions, insert before the op.
                const instr_pos = instrs.items.len;
                try self.emitInstr(instrs, op_name, cat);
                // Parse any nested folded expressions as operands
                const pre_fold_len = instrs.items.len;
                while (self.current.tag == .lparen) {
                    try self.parseFoldedInstr(instrs);
                }
                // Rotate: move the emitted instr after its folded operands
                if (instrs.items.len > pre_fold_len) {
                    const instr_val = instrs.items[instr_pos];
                    // Shift folded operands left by 1
                    var j = instr_pos;
                    while (j < instrs.items.len - 1) : (j += 1) {
                        instrs.items[j] = instrs.items[j + 1];
                    }
                    instrs.items[instrs.items.len - 1] = instr_val;
                }
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
            .try_table_type => {
                // try_table $label? (result type)? (catch ...)* body end
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
                // Parse catch clauses
                var catches: std.ArrayListUnmanaged(WatInstr.CatchClause) = .empty;
                while (self.current.tag == .lparen) {
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance();
                    if (self.current.tag != .keyword) {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                        break;
                    }
                    const catch_kw = self.current.text;
                    const kind: WatInstr.CatchKind = if (std.mem.eql(u8, catch_kw, "catch"))
                        .@"catch"
                    else if (std.mem.eql(u8, catch_kw, "catch_ref"))
                        .catch_ref
                    else if (std.mem.eql(u8, catch_kw, "catch_all"))
                        .catch_all
                    else if (std.mem.eql(u8, catch_kw, "catch_all_ref"))
                        .catch_all_ref
                    else {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                        break;
                    };
                    _ = self.advance();
                    var tag_idx: ?WatIndex = null;
                    if (kind == .@"catch" or kind == .catch_ref) {
                        tag_idx = try self.parseIndex();
                    }
                    const catch_label = try self.parseIndex();
                    _ = try self.expect(.rparen);
                    catches.append(self.alloc, .{
                        .kind = kind,
                        .tag_idx = tag_idx,
                        .label = catch_label,
                    }) catch return error.OutOfMemory;
                }
                const body = try self.parseBlockBody();
                instrs.append(self.alloc, .{ .try_table = .{
                    .label = label,
                    .block_type = block_type,
                    .catches = catches.items,
                    .body = body,
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
            .index_imm => blk: {
                // memory.size/memory.grow: index defaults to 0 when omitted
                if (std.mem.eql(u8, op_name, "memory.size") or
                    std.mem.eql(u8, op_name, "memory.grow"))
                {
                    if (self.current.tag == .integer or self.current.tag == .ident) {
                        break :blk .{ .index_op = .{ .op = op_name, .index = try self.parseIndex() } };
                    }
                    break :blk .{ .index_op = .{ .op = op_name, .index = .{ .num = 0 } } };
                }
                break :blk .{ .index_op = .{ .op = op_name, .index = try self.parseIndex() } };
            },
            .i32_const => .{ .i32_const = try self.parseI32() },
            .i64_const => .{ .i64_const = try self.parseI64() },
            .f32_const => .{ .f32_const = try self.parseF32() },
            .f64_const => .{ .f64_const = try self.parseF64() },
            .v128_const => .{ .v128_const = try self.parseV128Const() },
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
            .block_type, .if_type, .try_table_type => unreachable, // handled in caller
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
        if (std.mem.eql(u8, self.current.text, "v128")) { _ = self.advance(); return .v128; }
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

    fn parseV128Const(self: *Parser) WatError![16]u8 {
        // v128.const <shape> <values...>
        // shape: i8x16, i16x8, i32x4, i64x2, f32x4, f64x2
        if (self.current.tag != .keyword) return error.InvalidWat;
        const shape = self.advance().text;
        var bytes: [16]u8 = undefined;

        if (std.mem.eql(u8, shape, "i64x2")) {
            for (0..2) |i| {
                if (self.current.tag != .integer) return error.InvalidWat;
                const val = parseIntLiteral(u64, self.advance().text) catch return error.InvalidWat;
                const le = std.mem.toBytes(std.mem.nativeToLittle(u64, val));
                @memcpy(bytes[i * 8 ..][0..8], &le);
            }
        } else if (std.mem.eql(u8, shape, "i32x4")) {
            for (0..4) |i| {
                if (self.current.tag != .integer) return error.InvalidWat;
                const val = parseIntLiteral(u32, self.advance().text) catch return error.InvalidWat;
                const le = std.mem.toBytes(std.mem.nativeToLittle(u32, val));
                @memcpy(bytes[i * 4 ..][0..4], &le);
            }
        } else if (std.mem.eql(u8, shape, "i16x8")) {
            for (0..8) |i| {
                if (self.current.tag != .integer) return error.InvalidWat;
                const val = parseIntLiteral(u16, self.advance().text) catch return error.InvalidWat;
                const le = std.mem.toBytes(std.mem.nativeToLittle(u16, val));
                @memcpy(bytes[i * 2 ..][0..2], &le);
            }
        } else if (std.mem.eql(u8, shape, "i8x16")) {
            for (0..16) |i| {
                if (self.current.tag != .integer) return error.InvalidWat;
                const val = parseIntLiteral(u8, self.advance().text) catch return error.InvalidWat;
                bytes[i] = val;
            }
        } else if (std.mem.eql(u8, shape, "f64x2")) {
            for (0..2) |i| {
                if (self.current.tag != .float and self.current.tag != .integer) return error.InvalidWat;
                const val = parseFloatLiteral(f64, self.advance().text) catch return error.InvalidWat;
                const le = std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, @bitCast(val))));
                @memcpy(bytes[i * 8 ..][0..8], &le);
            }
        } else if (std.mem.eql(u8, shape, "f32x4")) {
            for (0..4) |i| {
                if (self.current.tag != .float and self.current.tag != .integer) return error.InvalidWat;
                const val = parseFloatLiteral(f32, self.advance().text) catch return error.InvalidWat;
                const le = std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @bitCast(val))));
                @memcpy(bytes[i * 4 ..][0..4], &le);
            }
        } else {
            return error.InvalidWat;
        }
        return bytes;
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
                // Alignment must be a power of 2 and non-zero
                if (alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidWat;
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
// Binary Encoder
// ============================================================

/// Encode a WatModule AST to Wasm binary format.
pub fn encode(alloc: Allocator, module: WatModule) WatError![]u8 {
    // Use arena for all intermediate allocations
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayListUnmanaged(u8) = .empty;

    // Header: magic + version
    out.appendSlice(arena, &[_]u8{ 0x00, 0x61, 0x73, 0x6D }) catch return error.OutOfMemory;
    out.appendSlice(arena, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }) catch return error.OutOfMemory;

    // Collect all function types (explicit + synthesized from funcs/imports)
    var all_types: std.ArrayListUnmanaged(WatFuncType) = .empty;
    // Add explicit types
    for (module.types) |t| {
        all_types.append(arena, t) catch return error.OutOfMemory;
    }

    // Build name maps
    var type_names: std.ArrayListUnmanaged(?[]const u8) = .empty;
    for (all_types.items) |t| {
        type_names.append(arena, t.name) catch return error.OutOfMemory;
    }
    var func_names: std.ArrayListUnmanaged(?[]const u8) = .empty;
    var mem_names: std.ArrayListUnmanaged(?[]const u8) = .empty;
    var table_names: std.ArrayListUnmanaged(?[]const u8) = .empty;
    var global_names: std.ArrayListUnmanaged(?[]const u8) = .empty;

    // Import counts per kind (imports come first in index space)
    var import_func_count: u32 = 0;
    for (module.imports) |imp| {
        switch (imp.kind) {
            .func => |f| {
                func_names.append(arena, imp.id) catch return error.OutOfMemory;
                if (f.type_use == null) {
                    // Synthesize type from params/results
                    const vts = extractValTypes(arena, f.params) catch return error.OutOfMemory;
                    const ft: WatFuncType = .{ .params = vts, .results = f.results };
                    _ = findOrAddType(arena, &all_types, ft) catch return error.OutOfMemory;
                }
                import_func_count += 1;
            },
            .memory => {
                mem_names.append(arena, imp.id) catch return error.OutOfMemory;
            },
            .table => {
                table_names.append(arena, imp.id) catch return error.OutOfMemory;
            },
            .global => {
                global_names.append(arena, imp.id) catch return error.OutOfMemory;
            },
        }
    }

    // Func type indices for defined functions
    var func_type_indices: std.ArrayListUnmanaged(u32) = .empty;
    for (module.functions) |f| {
        func_names.append(arena, f.name) catch return error.OutOfMemory;
        if (f.type_use) |tu| {
            const idx = resolveIndex(tu, null, null) catch return error.InvalidWat;
            func_type_indices.append(arena, idx) catch return error.OutOfMemory;
        } else {
            // Synthesize type
            const vts = extractValTypes(arena, f.params) catch return error.OutOfMemory;
            const ft: WatFuncType = .{ .params = vts, .results = f.results };
            const idx = findOrAddType(arena, &all_types, ft) catch return error.OutOfMemory;
            func_type_indices.append(arena, idx) catch return error.OutOfMemory;
        }
    }
    for (module.memories) |m| {
        mem_names.append(arena, m.name) catch return error.OutOfMemory;
    }
    for (module.tables) |t| {
        table_names.append(arena, t.name) catch return error.OutOfMemory;
    }
    for (module.globals) |g| {
        global_names.append(arena, g.name) catch return error.OutOfMemory;
    }
    // Pad type_names for any synthesized types added by findOrAddType
    while (type_names.items.len < all_types.items.len) {
        type_names.append(arena, null) catch return error.OutOfMemory;
    }

    // Section 1: Type
    if (all_types.items.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(all_types.items.len)) catch return error.OutOfMemory;
        for (all_types.items) |ft| {
            sec.append(arena, 0x60) catch return error.OutOfMemory; // func type marker
            lebEncodeU32(arena, &sec, @intCast(ft.params.len)) catch return error.OutOfMemory;
            for (ft.params) |vt| {
                sec.append(arena, valTypeByte(vt)) catch return error.OutOfMemory;
            }
            lebEncodeU32(arena, &sec, @intCast(ft.results.len)) catch return error.OutOfMemory;
            for (ft.results) |vt| {
                sec.append(arena, valTypeByte(vt)) catch return error.OutOfMemory;
            }
        }
        writeSection(arena, &out, 1, sec.items) catch return error.OutOfMemory;
    }

    // Section 2: Import
    if (module.imports.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.imports.len)) catch return error.OutOfMemory;
        for (module.imports) |imp| {
            lebEncodeU32(arena, &sec, @intCast(imp.module_name.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, imp.module_name) catch return error.OutOfMemory;
            lebEncodeU32(arena, &sec, @intCast(imp.name.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, imp.name) catch return error.OutOfMemory;
            switch (imp.kind) {
                .func => |f| {
                    sec.append(arena, 0x00) catch return error.OutOfMemory;
                    if (f.type_use) |tu| {
                        const idx = resolveIndex(tu, null, null) catch return error.InvalidWat;
                        lebEncodeU32(arena, &sec, idx) catch return error.OutOfMemory;
                    } else {
                        const vts = extractValTypes(arena, f.params) catch return error.OutOfMemory;
                        const ft: WatFuncType = .{ .params = vts, .results = f.results };
                        const idx = findOrAddType(arena, &all_types, ft) catch return error.OutOfMemory;
                        lebEncodeU32(arena, &sec, idx) catch return error.OutOfMemory;
                    }
                },
                .table => |t| {
                    sec.append(arena, 0x01) catch return error.OutOfMemory;
                    sec.append(arena, valTypeByte(t.reftype)) catch return error.OutOfMemory;
                    encodeLimits(arena, &sec, t.limits) catch return error.OutOfMemory;
                },
                .memory => |m| {
                    sec.append(arena, 0x02) catch return error.OutOfMemory;
                    encodeLimits(arena, &sec, m) catch return error.OutOfMemory;
                },
                .global => |g| {
                    sec.append(arena, 0x03) catch return error.OutOfMemory;
                    sec.append(arena, valTypeByte(g.valtype)) catch return error.OutOfMemory;
                    sec.append(arena, if (g.mutable) @as(u8, 0x01) else @as(u8, 0x00)) catch return error.OutOfMemory;
                },
            }
        }
        writeSection(arena, &out, 2, sec.items) catch return error.OutOfMemory;
    }

    // Section 3: Function (type indices)
    if (module.functions.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.functions.len)) catch return error.OutOfMemory;
        for (func_type_indices.items) |idx| {
            lebEncodeU32(arena, &sec, idx) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 3, sec.items) catch return error.OutOfMemory;
    }

    // Section 4: Table
    if (module.tables.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.tables.len)) catch return error.OutOfMemory;
        for (module.tables) |t| {
            sec.append(arena, valTypeByte(t.reftype)) catch return error.OutOfMemory;
            encodeLimits(arena, &sec, t.limits) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 4, sec.items) catch return error.OutOfMemory;
    }

    // Section 5: Memory
    if (module.memories.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.memories.len)) catch return error.OutOfMemory;
        for (module.memories) |m| {
            encodeLimits(arena, &sec, m.limits) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 5, sec.items) catch return error.OutOfMemory;
    }

    // Section 6: Global
    if (module.globals.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.globals.len)) catch return error.OutOfMemory;
        for (module.globals) |g| {
            sec.append(arena, valTypeByte(g.global_type.valtype)) catch return error.OutOfMemory;
            sec.append(arena, if (g.global_type.mutable) @as(u8, 0x01) else @as(u8, 0x00)) catch return error.OutOfMemory;
            var g_labels: std.ArrayListUnmanaged(?[]const u8) = .empty;
            encodeInstrList(arena, &sec, g.init, func_names.items, mem_names.items, table_names.items, global_names.items, &.{}, &g_labels, type_names.items) catch return error.OutOfMemory;
            sec.append(arena, 0x0B) catch return error.OutOfMemory; // end
        }
        writeSection(arena, &out, 6, sec.items) catch return error.OutOfMemory;
    }

    // Section 7: Export (explicit + inline)
    var all_exports: std.ArrayListUnmanaged(WatExport) = .empty;
    for (module.exports) |e| {
        all_exports.append(arena, e) catch return error.OutOfMemory;
    }
    for (module.functions, 0..) |f, i| {
        if (f.export_name) |ename| {
            all_exports.append(arena, .{
                .name = ename,
                .kind = .func,
                .index = .{ .num = @intCast(import_func_count + @as(u32, @intCast(i))) },
            }) catch return error.OutOfMemory;
        }
    }
    for (module.memories, 0..) |m, i| {
        if (m.export_name) |ename| {
            all_exports.append(arena, .{
                .name = ename,
                .kind = .memory,
                .index = .{ .num = @intCast(i) },
            }) catch return error.OutOfMemory;
        }
    }
    for (module.tables, 0..) |t, i| {
        if (t.export_name) |ename| {
            all_exports.append(arena, .{
                .name = ename,
                .kind = .table,
                .index = .{ .num = @intCast(i) },
            }) catch return error.OutOfMemory;
        }
    }
    for (module.globals, 0..) |g, i| {
        if (g.export_name) |ename| {
            all_exports.append(arena, .{
                .name = ename,
                .kind = .global,
                .index = .{ .num = @intCast(i) },
            }) catch return error.OutOfMemory;
        }
    }
    if (all_exports.items.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(all_exports.items.len)) catch return error.OutOfMemory;
        for (all_exports.items) |e| {
            lebEncodeU32(arena, &sec, @intCast(e.name.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, e.name) catch return error.OutOfMemory;
            sec.append(arena, switch (e.kind) {
                .func => 0x00,
                .table => 0x01,
                .memory => 0x02,
                .global => 0x03,
            }) catch return error.OutOfMemory;
            const idx = resolveNamedIndex(e.index, switch (e.kind) {
                .func => func_names.items,
                .table => table_names.items,
                .memory => mem_names.items,
                .global => global_names.items,
            }) catch return error.InvalidWat;
            lebEncodeU32(arena, &sec, idx) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 7, sec.items) catch return error.OutOfMemory;
    }

    // Section 8: Start
    if (module.start) |start_idx| {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        const idx = resolveNamedIndex(start_idx, func_names.items) catch return error.InvalidWat;
        lebEncodeU32(arena, &sec, idx) catch return error.OutOfMemory;
        writeSection(arena, &out, 8, sec.items) catch return error.OutOfMemory;
    }

    // Section 9: Element
    if (module.elements.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.elements.len)) catch return error.OutOfMemory;
        for (module.elements) |elem| {
            const table_resolved = resolveNamedIndex(elem.table_idx, table_names.items) catch return error.InvalidWat;
            if (table_resolved == 0) {
                // Flag 0x00: active, table 0, offset, vec(funcidx)
                sec.append(arena, 0x00) catch return error.OutOfMemory;
            } else {
                // Flag 0x02: active, explicit table index
                sec.append(arena, 0x02) catch return error.OutOfMemory;
                lebEncodeU32(arena, &sec, table_resolved) catch return error.OutOfMemory;
            }
            // Offset expression + end
            var e_labels: std.ArrayListUnmanaged(?[]const u8) = .empty;
            encodeInstrList(arena, &sec, elem.offset, func_names.items, mem_names.items, table_names.items, global_names.items, &.{}, &e_labels, type_names.items) catch return error.OutOfMemory;
            sec.append(arena, 0x0B) catch return error.OutOfMemory; // end
            if (table_resolved != 0) {
                // elemkind for flag 0x02
                sec.append(arena, 0x00) catch return error.OutOfMemory; // funcref
            }
            // Function indices
            lebEncodeU32(arena, &sec, @intCast(elem.func_indices.len)) catch return error.OutOfMemory;
            for (elem.func_indices) |fi| {
                const fidx = resolveNamedIndex(fi, func_names.items) catch return error.InvalidWat;
                lebEncodeU32(arena, &sec, fidx) catch return error.OutOfMemory;
            }
        }
        writeSection(arena, &out, 9, sec.items) catch return error.OutOfMemory;
    }

    // Section 12: DataCount (must appear before Code section)
    if (module.data.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.data.len)) catch return error.OutOfMemory;
        writeSection(arena, &out, 12, sec.items) catch return error.OutOfMemory;
    }

    // Section 10: Code
    if (module.functions.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.functions.len)) catch return error.OutOfMemory;
        for (module.functions) |f| {
            var code_body: std.ArrayListUnmanaged(u8) = .empty;

            var local_groups: std.ArrayListUnmanaged(struct { count: u32, valtype: WatValType }) = .empty;
            for (f.locals) |l| {
                if (local_groups.items.len > 0 and local_groups.items[local_groups.items.len - 1].valtype == l.valtype) {
                    local_groups.items[local_groups.items.len - 1].count += 1;
                } else {
                    local_groups.append(arena, .{ .count = 1, .valtype = l.valtype }) catch return error.OutOfMemory;
                }
            }
            lebEncodeU32(arena, &code_body, @intCast(local_groups.items.len)) catch return error.OutOfMemory;
            for (local_groups.items) |lg| {
                lebEncodeU32(arena, &code_body, lg.count) catch return error.OutOfMemory;
                code_body.append(arena, valTypeByte(lg.valtype)) catch return error.OutOfMemory;
            }

            // Build local name map: params then locals
            var f_local_names: std.ArrayListUnmanaged(?[]const u8) = .empty;
            for (f.params) |p| {
                f_local_names.append(arena, p.name) catch return error.OutOfMemory;
            }
            for (f.locals) |l| {
                f_local_names.append(arena, l.name) catch return error.OutOfMemory;
            }
            var f_labels: std.ArrayListUnmanaged(?[]const u8) = .empty;
            encodeInstrList(arena, &code_body, f.body, func_names.items, mem_names.items, table_names.items, global_names.items, f_local_names.items, &f_labels, type_names.items) catch return error.OutOfMemory;
            code_body.append(arena, 0x0B) catch return error.OutOfMemory; // end

            lebEncodeU32(arena, &sec, @intCast(code_body.items.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, code_body.items) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 10, sec.items) catch return error.OutOfMemory;
    }

    // Section 11: Data
    if (module.data.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.data.len)) catch return error.OutOfMemory;
        for (module.data) |data| {
            const mem_resolved = resolveNamedIndex(data.memory_idx, mem_names.items) catch return error.InvalidWat;
            if (data.mode == .active) {
                if (mem_resolved == 0) {
                    sec.append(arena, 0x00) catch return error.OutOfMemory; // flag: active, memory 0
                } else {
                    sec.append(arena, 0x02) catch return error.OutOfMemory; // flag: active, explicit memory
                    lebEncodeU32(arena, &sec, mem_resolved) catch return error.OutOfMemory;
                }
                // Offset expression + end
                var d_labels: std.ArrayListUnmanaged(?[]const u8) = .empty;
                encodeInstrList(arena, &sec, data.offset, func_names.items, mem_names.items, table_names.items, global_names.items, &.{}, &d_labels, type_names.items) catch return error.OutOfMemory;
                sec.append(arena, 0x0B) catch return error.OutOfMemory;
            } else {
                sec.append(arena, 0x01) catch return error.OutOfMemory; // flag: passive
            }
            // Byte content
            lebEncodeU32(arena, &sec, @intCast(data.bytes.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, data.bytes) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 11, sec.items) catch return error.OutOfMemory;
    }

    // Copy result to caller's allocator (arena will be freed on return)
    const result = alloc.dupe(u8, out.items) catch return error.OutOfMemory;
    return result;
}

/// Decode WAT string escapes: \n, \t, \\, \", \xx (hex byte)
/// Returns a slice backed by the allocator (arena-friendly).
fn decodeWatString(alloc: Allocator, input: []const u8) ![]u8 {
    // Check if any escapes exist — fast path for no-escape strings
    var has_escape = false;
    for (input) |c| {
        if (c == '\\') {
            has_escape = true;
            break;
        }
    }
    if (!has_escape) {
        const result = alloc.alloc(u8, input.len) catch return error.OutOfMemory;
        @memcpy(result, input);
        return result;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            // Try \xx hex escape first (two hex digits)
            if (i + 2 < input.len) {
                const hi = hexDigit(next);
                const lo = hexDigit(input[i + 2]);
                if (hi != null and lo != null) {
                    out.append(alloc, hi.? * 16 + lo.?) catch return error.OutOfMemory;
                    i += 3;
                    continue;
                }
            }
            switch (next) {
                'n' => {
                    out.append(alloc, '\n') catch return error.OutOfMemory;
                    i += 2;
                },
                't' => {
                    out.append(alloc, '\t') catch return error.OutOfMemory;
                    i += 2;
                },
                'r' => {
                    out.append(alloc, '\r') catch return error.OutOfMemory;
                    i += 2;
                },
                '\\' => {
                    out.append(alloc, '\\') catch return error.OutOfMemory;
                    i += 2;
                },
                '"' => {
                    out.append(alloc, '"') catch return error.OutOfMemory;
                    i += 2;
                },
                '\'' => {
                    out.append(alloc, '\'') catch return error.OutOfMemory;
                    i += 2;
                },
                else => {
                    out.append(alloc, input[i]) catch return error.OutOfMemory;
                    i += 1;
                },
            }
        } else {
            out.append(alloc, input[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    // Return owned slice from ArrayList
    return out.toOwnedSlice(alloc) catch return error.OutOfMemory;
}

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn valTypeByte(vt: WatValType) u8 {
    return switch (vt) {
        .i32 => 0x7F,
        .i64 => 0x7E,
        .f32 => 0x7D,
        .f64 => 0x7C,
        .v128 => 0x7B,
        .funcref => 0x70,
        .externref => 0x6F,
        .exnref => 0x69,
    };
}

fn writeSection(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), id: u8, body: []const u8) !void {
    out.append(alloc, id) catch return error.OutOfMemory;
    lebEncodeU32(alloc, out, @intCast(body.len)) catch return error.OutOfMemory;
    out.appendSlice(alloc, body) catch return error.OutOfMemory;
}

fn lebEncodeU32(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), value: u32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            out.append(alloc, byte) catch return error.OutOfMemory;
            return;
        }
        out.append(alloc, byte | 0x80) catch return error.OutOfMemory;
    }
}

fn lebEncodeI32(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), value: i32) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(@as(u32, @bitCast(v)) & 0x7F);
        v >>= 7;
        if ((v == 0 and (byte & 0x40) == 0) or (v == -1 and (byte & 0x40) != 0)) {
            out.append(alloc, byte) catch return error.OutOfMemory;
            return;
        }
        out.append(alloc, byte | 0x80) catch return error.OutOfMemory;
    }
}

fn lebEncodeI64(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), value: i64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7F);
        v >>= 7;
        if ((v == 0 and (byte & 0x40) == 0) or (v == -1 and (byte & 0x40) != 0)) {
            out.append(alloc, byte) catch return error.OutOfMemory;
            return;
        }
        out.append(alloc, byte | 0x80) catch return error.OutOfMemory;
    }
}

fn encodeLimits(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), limits: WatLimits) !void {
    if (limits.max != null) {
        out.append(alloc, 0x01) catch return error.OutOfMemory; // has_max
        lebEncodeU32(alloc, out, @intCast(limits.min)) catch return error.OutOfMemory;
        lebEncodeU32(alloc, out, @intCast(limits.max.?)) catch return error.OutOfMemory;
    } else {
        out.append(alloc, 0x00) catch return error.OutOfMemory;
        lebEncodeU32(alloc, out, @intCast(limits.min)) catch return error.OutOfMemory;
    }
}

fn findOrAddType(alloc: Allocator, types: *std.ArrayListUnmanaged(WatFuncType), ft: WatFuncType) !u32 {
    for (types.items, 0..) |existing, i| {
        if (std.mem.eql(WatValType, existing.params, ft.params) and
            std.mem.eql(WatValType, existing.results, ft.results))
        {
            return @intCast(i);
        }
    }
    const idx: u32 = @intCast(types.items.len);
    types.append(alloc, ft) catch return error.OutOfMemory;
    return idx;
}

fn extractValTypes(alloc: Allocator, params: []const WatParam) ![]WatValType {
    var vts: std.ArrayListUnmanaged(WatValType) = .empty;
    for (params) |p| {
        vts.append(alloc, p.valtype) catch return error.OutOfMemory;
    }
    return vts.items;
}

fn resolveIndex(idx: WatIndex, names: ?[]const ?[]const u8, _: ?void) !u32 {
    switch (idx) {
        .num => |n| return n,
        .name => |name| {
            if (names) |ns| {
                for (ns, 0..) |n, i| {
                    if (n != null and std.mem.eql(u8, n.?, name)) return @intCast(i);
                }
            }
            return error.InvalidWat;
        },
    }
}

fn resolveNamedIndex(idx: WatIndex, names: []const ?[]const u8) !u32 {
    return resolveIndex(idx, names, null);
}

/// WAT instruction name → opcode byte(s).
fn instrOpcode(name: []const u8) ?u8 {
    // Replace dots with underscores for enum lookup
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    for (buf[0..name.len]) |*c| {
        if (c.* == '.') c.* = '_';
    }
    const zig_name = buf[0..name.len];

    // Use the Opcode enum from opcode.zig via build's import
    // Since we can't import opcode.zig directly, use a manual mapping
    // for the most common opcodes
    const map = .{
        .{ "unreachable", 0x00 },
        .{ "nop", 0x01 },
        .{ "block", 0x02 },
        .{ "loop", 0x03 },
        .{ "if", 0x04 },
        .{ "else", 0x05 },
        .{ "end", 0x0B },
        .{ "br", 0x0C },
        .{ "br_if", 0x0D },
        .{ "br_table", 0x0E },
        .{ "return", 0x0F },
        .{ "call", 0x10 },
        .{ "call_indirect", 0x11 },
        .{ "return_call", 0x12 },
        .{ "return_call_indirect", 0x13 },
        .{ "drop", 0x1A },
        .{ "select", 0x1B },
        .{ "local_get", 0x20 },
        .{ "local_set", 0x21 },
        .{ "local_tee", 0x22 },
        .{ "global_get", 0x23 },
        .{ "global_set", 0x24 },
        .{ "table_get", 0x25 },
        .{ "table_set", 0x26 },
        .{ "i32_load", 0x28 },
        .{ "i64_load", 0x29 },
        .{ "f32_load", 0x2A },
        .{ "f64_load", 0x2B },
        .{ "i32_load8_s", 0x2C },
        .{ "i32_load8_u", 0x2D },
        .{ "i32_load16_s", 0x2E },
        .{ "i32_load16_u", 0x2F },
        .{ "i64_load8_s", 0x30 },
        .{ "i64_load8_u", 0x31 },
        .{ "i64_load16_s", 0x32 },
        .{ "i64_load16_u", 0x33 },
        .{ "i64_load32_s", 0x34 },
        .{ "i64_load32_u", 0x35 },
        .{ "i32_store", 0x36 },
        .{ "i64_store", 0x37 },
        .{ "f32_store", 0x38 },
        .{ "f64_store", 0x39 },
        .{ "i32_store8", 0x3A },
        .{ "i32_store16", 0x3B },
        .{ "i64_store8", 0x3C },
        .{ "i64_store16", 0x3D },
        .{ "i64_store32", 0x3E },
        .{ "memory_size", 0x3F },
        .{ "memory_grow", 0x40 },
        .{ "i32_const", 0x41 },
        .{ "i64_const", 0x42 },
        .{ "f32_const", 0x43 },
        .{ "f64_const", 0x44 },
        .{ "i32_eqz", 0x45 },
        .{ "i32_eq", 0x46 },
        .{ "i32_ne", 0x47 },
        .{ "i32_lt_s", 0x48 },
        .{ "i32_lt_u", 0x49 },
        .{ "i32_gt_s", 0x4A },
        .{ "i32_gt_u", 0x4B },
        .{ "i32_le_s", 0x4C },
        .{ "i32_le_u", 0x4D },
        .{ "i32_ge_s", 0x4E },
        .{ "i32_ge_u", 0x4F },
        .{ "i64_eqz", 0x50 },
        .{ "i64_eq", 0x51 },
        .{ "i64_ne", 0x52 },
        .{ "i64_lt_s", 0x53 },
        .{ "i64_lt_u", 0x54 },
        .{ "i64_gt_s", 0x55 },
        .{ "i64_gt_u", 0x56 },
        .{ "i64_le_s", 0x57 },
        .{ "i64_le_u", 0x58 },
        .{ "i64_ge_s", 0x59 },
        .{ "i64_ge_u", 0x5A },
        .{ "f32_eq", 0x5B },
        .{ "f32_ne", 0x5C },
        .{ "f32_lt", 0x5D },
        .{ "f32_gt", 0x5E },
        .{ "f32_le", 0x5F },
        .{ "f32_ge", 0x60 },
        .{ "f64_eq", 0x61 },
        .{ "f64_ne", 0x62 },
        .{ "f64_lt", 0x63 },
        .{ "f64_gt", 0x64 },
        .{ "f64_le", 0x65 },
        .{ "f64_ge", 0x66 },
        .{ "i32_clz", 0x67 },
        .{ "i32_ctz", 0x68 },
        .{ "i32_popcnt", 0x69 },
        .{ "i32_add", 0x6A },
        .{ "i32_sub", 0x6B },
        .{ "i32_mul", 0x6C },
        .{ "i32_div_s", 0x6D },
        .{ "i32_div_u", 0x6E },
        .{ "i32_rem_s", 0x6F },
        .{ "i32_rem_u", 0x70 },
        .{ "i32_and", 0x71 },
        .{ "i32_or", 0x72 },
        .{ "i32_xor", 0x73 },
        .{ "i32_shl", 0x74 },
        .{ "i32_shr_s", 0x75 },
        .{ "i32_shr_u", 0x76 },
        .{ "i32_rotl", 0x77 },
        .{ "i32_rotr", 0x78 },
        .{ "i64_clz", 0x79 },
        .{ "i64_ctz", 0x7A },
        .{ "i64_popcnt", 0x7B },
        .{ "i64_add", 0x7C },
        .{ "i64_sub", 0x7D },
        .{ "i64_mul", 0x7E },
        .{ "i64_div_s", 0x7F },
        .{ "i64_div_u", 0x80 },
        .{ "i64_rem_s", 0x81 },
        .{ "i64_rem_u", 0x82 },
        .{ "i64_and", 0x83 },
        .{ "i64_or", 0x84 },
        .{ "i64_xor", 0x85 },
        .{ "i64_shl", 0x86 },
        .{ "i64_shr_s", 0x87 },
        .{ "i64_shr_u", 0x88 },
        .{ "i64_rotl", 0x89 },
        .{ "i64_rotr", 0x8A },
        .{ "f32_abs", 0x8B },
        .{ "f32_neg", 0x8C },
        .{ "f32_ceil", 0x8D },
        .{ "f32_floor", 0x8E },
        .{ "f32_trunc", 0x8F },
        .{ "f32_nearest", 0x90 },
        .{ "f32_sqrt", 0x91 },
        .{ "f32_add", 0x92 },
        .{ "f32_sub", 0x93 },
        .{ "f32_mul", 0x94 },
        .{ "f32_div", 0x95 },
        .{ "f32_min", 0x96 },
        .{ "f32_max", 0x97 },
        .{ "f32_copysign", 0x98 },
        .{ "f64_abs", 0x99 },
        .{ "f64_neg", 0x9A },
        .{ "f64_ceil", 0x9B },
        .{ "f64_floor", 0x9C },
        .{ "f64_trunc", 0x9D },
        .{ "f64_nearest", 0x9E },
        .{ "f64_sqrt", 0x9F },
        .{ "f64_add", 0xA0 },
        .{ "f64_sub", 0xA1 },
        .{ "f64_mul", 0xA2 },
        .{ "f64_div", 0xA3 },
        .{ "f64_min", 0xA4 },
        .{ "f64_max", 0xA5 },
        .{ "f64_copysign", 0xA6 },
        .{ "i32_wrap_i64", 0xA7 },
        .{ "i32_trunc_f32_s", 0xA8 },
        .{ "i32_trunc_f32_u", 0xA9 },
        .{ "i32_trunc_f64_s", 0xAA },
        .{ "i32_trunc_f64_u", 0xAB },
        .{ "i64_extend_i32_s", 0xAC },
        .{ "i64_extend_i32_u", 0xAD },
        .{ "i64_trunc_f32_s", 0xAE },
        .{ "i64_trunc_f32_u", 0xAF },
        .{ "i64_trunc_f64_s", 0xB0 },
        .{ "i64_trunc_f64_u", 0xB1 },
        .{ "f32_convert_i32_s", 0xB2 },
        .{ "f32_convert_i32_u", 0xB3 },
        .{ "f32_convert_i64_s", 0xB4 },
        .{ "f32_convert_i64_u", 0xB5 },
        .{ "f32_demote_f64", 0xB6 },
        .{ "f64_convert_i32_s", 0xB7 },
        .{ "f64_convert_i32_u", 0xB8 },
        .{ "f64_convert_i64_s", 0xB9 },
        .{ "f64_convert_i64_u", 0xBA },
        .{ "f64_promote_f32", 0xBB },
        .{ "i32_reinterpret_f32", 0xBC },
        .{ "i64_reinterpret_f64", 0xBD },
        .{ "f32_reinterpret_i32", 0xBE },
        .{ "f64_reinterpret_i64", 0xBF },
        .{ "i32_extend8_s", 0xC0 },
        .{ "i32_extend16_s", 0xC1 },
        .{ "i64_extend8_s", 0xC2 },
        .{ "i64_extend16_s", 0xC3 },
        .{ "i64_extend32_s", 0xC4 },
        .{ "ref_null", 0xD0 },
        .{ "ref_is_null", 0xD1 },
        .{ "ref_func", 0xD2 },
        .{ "ref_eq", 0xD3 },
        .{ "ref_as_non_null", 0xD4 },
        .{ "br_on_null", 0xD5 },
        .{ "br_on_non_null", 0xD6 },
        .{ "call_ref", 0x14 },
        .{ "return_call_ref", 0x15 },
        .{ "throw_ref", 0x0A },
        .{ "throw", 0x08 },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, zig_name, entry[0])) return entry[1];
    }
    return null;
}

/// WAT SIMD instruction name → subopcode (after 0xFD prefix).
/// Uses SimdOpcode enum from opcode.zig via reflection.
fn miscInstrOpcode(name: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    for (buf[0..name.len]) |*c| {
        if (c.* == '.') c.* = '_';
    }
    const zig_name = buf[0..name.len];
    const fields = @typeInfo(MiscOpcode).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, zig_name, field.name)) return field.value;
    }
    return null;
}

fn simdInstrOpcode(name: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    for (buf[0..name.len]) |*c| {
        if (c.* == '.') c.* = '_';
    }
    const zig_name = buf[0..name.len];
    const fields = @typeInfo(SimdOpcode).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, zig_name, field.name)) return field.value;
    }
    return null;
}

fn encodeInstrList(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    instrs: []const WatInstr,
    func_names: []const ?[]const u8,
    mem_names: []const ?[]const u8,
    table_names: []const ?[]const u8,
    global_names: []const ?[]const u8,
    local_names: []const ?[]const u8,
    labels: *std.ArrayListUnmanaged(?[]const u8),
    type_names: []const ?[]const u8,
) WatError!void {
    for (instrs) |instr| {
        try encodeInstr(alloc, out, instr, func_names, mem_names, table_names, global_names, local_names, labels, type_names);
    }
}

fn resolveLabelIndex(idx: WatIndex, labels: []const ?[]const u8) WatError!u32 {
    switch (idx) {
        .num => |n| return n,
        .name => |name| {
            // Search from top of label stack (most recent = depth 0)
            var i: usize = labels.len;
            while (i > 0) {
                i -= 1;
                if (labels[i]) |lbl| {
                    if (std.mem.eql(u8, lbl, name)) {
                        return @intCast(labels.len - 1 - i);
                    }
                }
            }
            return error.InvalidWat;
        },
    }
}

fn encodeInstr(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    instr: WatInstr,
    func_names: []const ?[]const u8,
    mem_names: []const ?[]const u8,
    table_names: []const ?[]const u8,
    global_names: []const ?[]const u8,
    local_names: []const ?[]const u8,
    labels: *std.ArrayListUnmanaged(?[]const u8),
    type_names: []const ?[]const u8,
) WatError!void {
    switch (instr) {
        .simple => |name| {
            if (instrOpcode(name)) |op| {
                out.append(alloc, op) catch return error.OutOfMemory;
            } else if (miscInstrOpcode(name)) |subop| {
                out.append(alloc, 0xFC) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
                // Some 0xFC ops need trailing zero bytes for memory/table indices
                switch (subop) {
                    0x0A => { // memory.copy: dst_mem(0) + src_mem(0)
                        out.append(alloc, 0x00) catch return error.OutOfMemory;
                        out.append(alloc, 0x00) catch return error.OutOfMemory;
                    },
                    0x0B => { // memory.fill: mem(0)
                        out.append(alloc, 0x00) catch return error.OutOfMemory;
                    },
                    0x0E => { // table.copy: dst_table(0) + src_table(0)
                        out.append(alloc, 0x00) catch return error.OutOfMemory;
                        out.append(alloc, 0x00) catch return error.OutOfMemory;
                    },
                    else => {},
                }
            } else if (simdInstrOpcode(name)) |subop| {
                out.append(alloc, 0xFD) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            } else {
                return error.InvalidWat;
            }
        },
        .index_op => |data| {
            if (instrOpcode(data.op)) |op| {
                out.append(alloc, op) catch return error.OutOfMemory;
            } else if (miscInstrOpcode(data.op)) |subop| {
                out.append(alloc, 0xFC) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            } else {
                return error.InvalidWat;
            }
            // Resolve index: br/br_if/br_on_* use label stack, others use namespace maps
            const is_branch = std.mem.eql(u8, data.op, "br") or
                std.mem.eql(u8, data.op, "br_if") or
                std.mem.eql(u8, data.op, "br_on_null") or
                std.mem.eql(u8, data.op, "br_on_non_null");
            const idx = if (is_branch)
                try resolveLabelIndex(data.index, labels.items)
            else if (std.mem.eql(u8, data.op, "call") or
                std.mem.eql(u8, data.op, "ref.func") or
                std.mem.eql(u8, data.op, "return_call"))
                resolveNamedIndex(data.index, func_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "global.get") or
                std.mem.eql(u8, data.op, "global.set"))
                resolveNamedIndex(data.index, global_names) catch return error.InvalidWat
            else if (std.mem.startsWith(u8, data.op, "table."))
                resolveNamedIndex(data.index, table_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "memory.size") or
                std.mem.eql(u8, data.op, "memory.grow"))
                resolveNamedIndex(data.index, mem_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "local.get") or
                std.mem.eql(u8, data.op, "local.set") or
                std.mem.eql(u8, data.op, "local.tee"))
                resolveNamedIndex(data.index, local_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "call_ref") or
                std.mem.eql(u8, data.op, "return_call_ref"))
                resolveNamedIndex(data.index, type_names) catch return error.InvalidWat
            else switch (data.index) {
                .num => |n| n,
                .name => return error.InvalidWat,
            };
            lebEncodeU32(alloc, out, idx) catch return error.OutOfMemory;
            // 0xFC ops with trailing memory/table index (default 0)
            if (std.mem.eql(u8, data.op, "memory.init") or
                std.mem.eql(u8, data.op, "table.init"))
            {
                out.append(alloc, 0x00) catch return error.OutOfMemory; // trailing mem/table idx
            }
        },
        .i32_const => |val| {
            out.append(alloc, 0x41) catch return error.OutOfMemory;
            lebEncodeI32(alloc, out, val) catch return error.OutOfMemory;
        },
        .i64_const => |val| {
            out.append(alloc, 0x42) catch return error.OutOfMemory;
            lebEncodeI64(alloc, out, val) catch return error.OutOfMemory;
        },
        .f32_const => |val| {
            out.append(alloc, 0x43) catch return error.OutOfMemory;
            const bytes = @as([4]u8, @bitCast(val));
            out.appendSlice(alloc, &bytes) catch return error.OutOfMemory;
        },
        .f64_const => |val| {
            out.append(alloc, 0x44) catch return error.OutOfMemory;
            const bytes = @as([8]u8, @bitCast(val));
            out.appendSlice(alloc, &bytes) catch return error.OutOfMemory;
        },
        .v128_const => |val| {
            out.append(alloc, 0xFD) catch return error.OutOfMemory; // SIMD prefix
            lebEncodeU32(alloc, out, 0x0C) catch return error.OutOfMemory; // v128.const
            out.appendSlice(alloc, &val) catch return error.OutOfMemory;
        },
        .mem_op => |data| {
            const op = instrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, op) catch return error.OutOfMemory;
            // Encode alignment as log2
            const align_log2: u32 = if (data.mem_arg.@"align" > 0) std.math.log2_int(u32, data.mem_arg.@"align") else 0;
            lebEncodeU32(alloc, out, align_log2) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, data.mem_arg.offset) catch return error.OutOfMemory;
        },
        .block_op => |data| {
            const op = instrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, op) catch return error.OutOfMemory;
            // Block type
            if (data.block_type) |vt| {
                out.append(alloc, valTypeByte(vt)) catch return error.OutOfMemory;
            } else {
                out.append(alloc, 0x40) catch return error.OutOfMemory; // empty block type
            }
            labels.append(alloc, data.label) catch return error.OutOfMemory;
            encodeInstrList(alloc, out, data.body, func_names, mem_names, table_names, global_names, local_names, labels, type_names) catch return error.OutOfMemory;
            _ = labels.pop();
            out.append(alloc, 0x0B) catch return error.OutOfMemory; // end
        },
        .if_op => |data| {
            out.append(alloc, 0x04) catch return error.OutOfMemory; // if
            if (data.block_type) |vt| {
                out.append(alloc, valTypeByte(vt)) catch return error.OutOfMemory;
            } else {
                out.append(alloc, 0x40) catch return error.OutOfMemory;
            }
            labels.append(alloc, data.label) catch return error.OutOfMemory;
            encodeInstrList(alloc, out, data.then_body, func_names, mem_names, table_names, global_names, local_names, labels, type_names) catch return error.OutOfMemory;
            if (data.else_body.len > 0) {
                out.append(alloc, 0x05) catch return error.OutOfMemory; // else
                encodeInstrList(alloc, out, data.else_body, func_names, mem_names, table_names, global_names, local_names, labels, type_names) catch return error.OutOfMemory;
            }
            _ = labels.pop();
            out.append(alloc, 0x0B) catch return error.OutOfMemory; // end
        },
        .try_table => |data| {
            out.append(alloc, 0x1F) catch return error.OutOfMemory; // try_table
            if (data.block_type) |vt| {
                out.append(alloc, valTypeByte(vt)) catch return error.OutOfMemory;
            } else {
                out.append(alloc, 0x40) catch return error.OutOfMemory;
            }
            // Catch clause vector
            lebEncodeU32(alloc, out, @intCast(data.catches.len)) catch return error.OutOfMemory;
            labels.append(alloc, data.label) catch return error.OutOfMemory;
            for (data.catches) |c| {
                out.append(alloc, @intFromEnum(c.kind)) catch return error.OutOfMemory;
                if (c.tag_idx) |tag| {
                    const idx = resolveNamedIndex(tag, &.{}) catch return error.InvalidWat;
                    lebEncodeU32(alloc, out, idx) catch return error.OutOfMemory;
                }
                const label_idx = try resolveLabelIndex(c.label, labels.items);
                lebEncodeU32(alloc, out, label_idx) catch return error.OutOfMemory;
            }
            encodeInstrList(alloc, out, data.body, func_names, mem_names, table_names, global_names, local_names, labels, type_names) catch return error.OutOfMemory;
            _ = labels.pop();
            out.append(alloc, 0x0B) catch return error.OutOfMemory; // end
        },
        .br_table => |data| {
            out.append(alloc, 0x0E) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, @intCast(data.targets.len)) catch return error.OutOfMemory;
            for (data.targets) |t| {
                const idx = try resolveLabelIndex(t, labels.items);
                lebEncodeU32(alloc, out, idx) catch return error.OutOfMemory;
            }
            const default = try resolveLabelIndex(data.default, labels.items);
            lebEncodeU32(alloc, out, default) catch return error.OutOfMemory;
        },
        .call_indirect => |data| {
            out.append(alloc, 0x11) catch return error.OutOfMemory;
            if (data.type_use) |tu| {
                const idx = resolveNamedIndex(tu, type_names) catch return error.InvalidWat;
                lebEncodeU32(alloc, out, idx) catch return error.OutOfMemory;
            } else {
                lebEncodeU32(alloc, out, 0) catch return error.OutOfMemory;
            }
            lebEncodeU32(alloc, out, data.table_idx) catch return error.OutOfMemory;
        },
        .select_t => |types| {
            out.append(alloc, 0x1C) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, @intCast(types.len)) catch return error.OutOfMemory;
            for (types) |vt| {
                out.append(alloc, valTypeByte(vt)) catch return error.OutOfMemory;
            }
        },
        .end => {
            out.append(alloc, 0x0B) catch return error.OutOfMemory;
        },
        .@"else" => {
            out.append(alloc, 0x05) catch return error.OutOfMemory;
        },
    }
}

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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "(module)");
    const mod = try parser.parseModule();
    try testing.expect(mod.name == null);
    try testing.expectEqual(@as(usize, 0), mod.types.len);
    try testing.expectEqual(@as(usize, 0), mod.functions.len);
    try testing.expectEqual(@as(usize, 0), mod.memories.len);
    try testing.expectEqual(@as(usize, 0), mod.exports.len);
    try testing.expect(mod.start == null);
}

test "WAT parser — named module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), "(module $test)");
    const mod = try parser.parseModule();
    try testing.expectEqualStrings("$test", mod.name.?);
}

test "WAT parser — type definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module (memory 1 256))
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.memories.len);
    try testing.expectEqual(@as(u64, 1), mod.memories[0].limits.min);
    try testing.expectEqual(@as(u64, 256), mod.memories[0].limits.max.?);
}

test "WAT parser — export" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (import "env" "mem" (memory 1))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.imports.len);
    try testing.expectEqual(@as(u64, 1), mod.imports[0].kind.memory.min);
}

test "WAT parser — global mutable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module (table 10 funcref))
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.tables.len);
    try testing.expectEqual(@as(u64, 10), mod.tables[0].limits.min);
    try testing.expectEqual(WatValType.funcref, mod.tables[0].reftype);
}

test "WAT parser — start function" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (func)
        \\  (start 0)
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(u32, 0), mod.start.?.num);
}

test "WAT parser — inline export on func" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (func $add (export "add") (param i32 i32) (result i32))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.functions.len);
    try testing.expectEqualStrings("add", mod.functions[0].export_name.?);
}

test "WAT parser — multiple sections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
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

// ============================================================
// Binary Encoder Tests
// ============================================================

test "WAT encoder — empty module" {
    const wasm = try watToWasm(testing.allocator, "(module)");
    defer testing.allocator.free(wasm);
    try testing.expectEqual(@as(usize, 8), wasm.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 }, wasm);
}

test "WAT encoder — add function bytes" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func $add (param i32 i32) (result i32)
        \\    local.get 0
        \\    local.get 1
        \\    i32.add
        \\  )
        \\  (export "add" (func $add))
        \\)
    );
    defer testing.allocator.free(wasm);

    const expected = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // header
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01, 0x7F, // type section
        0x03, 0x02, 0x01, 0x00, // function section
        0x07, 0x07, 0x01, 0x03, 0x61, 0x64, 0x64, 0x00, 0x00, // export section
        0x0A, 0x09, 0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A, 0x0B, // code section
    };
    try testing.expectEqualSlices(u8, &expected, wasm);
}

test "WAT encoder — module with memory" {
    const wasm = try watToWasm(testing.allocator,
        \\(module (memory 1))
    );
    defer testing.allocator.free(wasm);
    // Header(8) + memory section
    try testing.expect(wasm.len > 8);
    // Check memory section starts after header
    try testing.expectEqual(@as(u8, 5), wasm[8]); // section ID 5 = memory
}

test "WAT encoder — i32.const function" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (result i32)
        \\    i32.const 42
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    try testing.expect(wasm.len > 8);
    // Should have type section (1), function section (3), code section (10)
    var found_type = false;
    var found_func = false;
    var found_code = false;
    var pos: usize = 8;
    while (pos < wasm.len) {
        const sec_id = wasm[pos];
        pos += 1;
        // Read section size (simple LEB128 for small values)
        var sec_size: usize = 0;
        var shift: u5 = 0;
        while (pos < wasm.len) {
            const b = wasm[pos];
            pos += 1;
            sec_size |= @as(usize, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        if (sec_id == 1) found_type = true;
        if (sec_id == 3) found_func = true;
        if (sec_id == 10) found_code = true;
        pos += sec_size;
    }
    try testing.expect(found_type);
    try testing.expect(found_func);
    try testing.expect(found_code);
}

test "WAT encoder — LEB128 encoding" {
    // Test u32 LEB128
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try lebEncodeU32(testing.allocator, &buf, 0);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, buf.items);
    buf.clearRetainingCapacity();

    try lebEncodeU32(testing.allocator, &buf, 127);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf.items);
    buf.clearRetainingCapacity();

    try lebEncodeU32(testing.allocator, &buf, 128);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, buf.items);
    buf.clearRetainingCapacity();

    // Test i32 LEB128
    try lebEncodeI32(testing.allocator, &buf, 0);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, buf.items);
    buf.clearRetainingCapacity();

    try lebEncodeI32(testing.allocator, &buf, -1);
    try testing.expectEqualSlices(u8, &[_]u8{0x7F}, buf.items);
    buf.clearRetainingCapacity();

    try lebEncodeI32(testing.allocator, &buf, 42);
    try testing.expectEqualSlices(u8, &[_]u8{0x2A}, buf.items);
    buf.clearRetainingCapacity();
}

test "WAT encoder — export with name resolution" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func $add (param i32 i32) (result i32)
        \\    local.get 0
        \\    local.get 1
        \\    i32.add
        \\  )
        \\  (export "add" (func $add))
        \\)
    );
    defer testing.allocator.free(wasm);
    try testing.expect(wasm.len > 8);
    // Verify export section exists (section 7)
    var pos: usize = 8;
    var found_export = false;
    while (pos < wasm.len) {
        const sec_id = wasm[pos];
        pos += 1;
        var sec_size: usize = 0;
        var shift: u5 = 0;
        while (pos < wasm.len) {
            const b = wasm[pos];
            pos += 1;
            sec_size |= @as(usize, b & 0x7F) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        if (sec_id == 7) found_export = true;
        pos += sec_size;
    }
    try testing.expect(found_export);
}

test "WAT round-trip — v128.const SIMD" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (export "hi") (result v128)
        \\    (local $i v128)
        \\    v128.const i64x2 0xfa2675c080000000 0xe8a433230a7479e5
        \\    local.set $i
        \\    local.get $i
        \\    local.get $i
        \\    local.get $i
        \\    i32x4.min_s
        \\    i32x4.lt_s
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    // Verify it loads and runs
    const types = @import("types.zig");
    var module = try types.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{ 0, 0 };
    try module.invoke("hi", &args, &results);
}

test "WAT parser — memory.size default index" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (func (export "size") (result i32)
        \\    memory.size))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("size", &args, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);
}

test "WAT parser — memory.grow default index" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (func (export "grow") (result i32)
        \\    i32.const 1
        \\    memory.grow))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("grow", &args, &results);
    // memory.grow returns previous size (1 page)
    try testing.expectEqual(@as(u64, 1), results[0]);
}

test "WAT parser — data section round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory (export "mem") 1)
        \\  (data (i32.const 0) "Hello")
        \\  (func (export "load") (result i32)
        \\    i32.const 0
        \\    i32.load8_u))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("load", &args, &results);
    try testing.expectEqual(@as(u64, 'H'), results[0]);
}

test "WAT parser — data section with escape sequences" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (data (i32.const 0) "\48\65\6c\6c\6f")
        \\  (func (export "load") (result i32)
        \\    i32.const 4
        \\    i32.load8_u))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("load", &args, &results);
    try testing.expectEqual(@as(u64, 'o'), results[0]);
}

test "WAT parser — data section with offset keyword" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (data (offset i32.const 10) "AB")
        \\  (func (export "load") (result i32)
        \\    i32.const 10
        \\    i32.load8_u))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("load", &args, &results);
    try testing.expectEqual(@as(u64, 'A'), results[0]);
}

test "WAT parser — elem section round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (type $t (func (result i32)))
        \\  (table 2 funcref)
        \\  (func $f0 (result i32) i32.const 42)
        \\  (func $f1 (result i32) i32.const 99)
        \\  (elem (i32.const 0) func $f0 $f1)
        \\  (func (export "call") (param i32) (result i32)
        \\    local.get 0
        \\    call_indirect (type $t)))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args0 = [_]u64{0};
    var results = [_]u64{0};
    try module.invoke("call", &args0, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);
    var args1 = [_]u64{1};
    try module.invoke("call", &args1, &results);
    try testing.expectEqual(@as(u64, 99), results[0]);
}

test "decodeWatString — basic escapes" {
    const result = try decodeWatString(testing.allocator, "Hello\\nWorld");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello\nWorld", result);
}

test "decodeWatString — hex escapes" {
    const result = try decodeWatString(testing.allocator, "\\48\\65\\6c\\6c\\6f");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello", result);
}

test "WAT parser — i32.trunc_sat_f64_s round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (export "sat") (param f64) (result i32)
        \\    local.get 0
        \\    i32.trunc_sat_f64_s))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    // 1e30 should clamp to i32.max = 2147483647
    var args = [_]u64{@bitCast(@as(f64, 1e30))};
    var results = [_]u64{0};
    try module.invoke("sat", &args, &results);
    try testing.expectEqual(@as(u64, 2147483647), results[0]);
}

test "WAT parser — memory.fill round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (func (export "test") (result i32)
        \\    i32.const 0
        \\    i32.const 42
        \\    i32.const 4
        \\    memory.fill
        \\    i32.const 0
        \\    i32.load8_u))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("test", &args, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);
}

test "WAT parser — memory.copy round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (data (i32.const 0) "Hello")
        \\  (func (export "test") (result i32)
        \\    i32.const 10
        \\    i32.const 0
        \\    i32.const 5
        \\    memory.copy
        \\    i32.const 10
        \\    i32.load8_u))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("test", &args, &results);
    try testing.expectEqual(@as(u64, 'H'), results[0]);
}

test "WAT parser — table.fill round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (table 3 funcref)
        \\  (func $f (result i32) i32.const 99)
        \\  (func (export "test") (result i32)
        \\    i32.const 0
        \\    ref.func $f
        \\    i32.const 3
        \\    table.fill 0
        \\    i32.const 0
        \\    table.get 0
        \\    ref.is_null
        \\    i32.eqz))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("test", &args, &results);
    // table.fill wrote non-null refs, so ref.is_null returns 0, i32.eqz gives 1
    try testing.expectEqual(@as(u64, 1), results[0]);
}

test "WAT parser — try_table encode round-trip" {
    // Verify try_table parses and encodes to valid wasm binary
    // Uses catch_all (no tag needed) with body that returns normally
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (export "test") (result i32)
        \\    (block $outer (result i32)
        \\      (try_table (result i32) (catch_all $outer)
        \\        i32.const 42))))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("test", &args, &results);
    // No exception thrown, try_table body returns 42
    try testing.expectEqual(@as(u64, 42), results[0]);
}
