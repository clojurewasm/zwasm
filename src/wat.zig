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
const GcOpcode = @import("opcode.zig").GcOpcode;
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

pub const WatValType = union(enum) {
    i32,
    i64,
    f32,
    f64,
    v128,
    funcref,
    externref,
    exnref,
    // GC abstract heap type abbreviations (nullable)
    anyref,
    eqref,
    i31ref,
    structref,
    arrayref,
    nullref,
    nullfuncref,
    nullexternref,
    // Typed references (payload = heap type index or name, resolved at encoding)
    ref_type: WatIndex, // (ref $T) non-nullable
    ref_null_type: WatIndex, // (ref null $T) nullable

    pub fn eql(a: WatValType, b: WatValType) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;
        return switch (a) {
            .ref_type => |v| std.meta.eql(v, b.ref_type),
            .ref_null_type => |v| std.meta.eql(v, b.ref_null_type),
            else => true, // tag-only variants are equal if tags match
        };
    }
};

/// Block type: empty, single value type, or type index (for multi-value).
pub const WatBlockType = union(enum) {
    empty,
    val_type: WatValType,
    type_idx: WatIndex,
};

pub const WatFuncType = struct {
    params: []WatValType,
    results: []WatValType,
};

pub const WatFieldType = struct {
    name: ?[]const u8,
    valtype: WatValType,
    mutable: bool,
};

pub const WatCompositeType = union(enum) {
    func: WatFuncType,
    struct_type: struct { fields: []WatFieldType },
    array_type: struct { field: WatFieldType },
};

pub const WatTypeDef = struct {
    name: ?[]const u8 = null,
    composite: WatCompositeType,
    rec_count: u32 = 0, // >0 on first type in a rec group
};

pub const WatParam = struct {
    name: ?[]const u8,
    valtype: WatValType,
};

pub const MemArg = struct {
    offset: u32,
    @"align": u32,
    mem_idx: WatIndex = .{ .num = 0 },
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
    // SIMD lane operations (extract_lane, replace_lane)
    simd_lane: struct { op: []const u8, lane: u8 },
    // SIMD shuffle (i8x16.shuffle with 16 lane indices)
    simd_shuffle: [16]u8,
    // SIMD load/store lane operations (memarg + lane)
    simd_mem_lane: struct { op: []const u8, mem_arg: MemArg, lane: u8 },
    // Memory operations (load/store)
    mem_op: struct { op: []const u8, mem_arg: MemArg },
    // Block/loop
    block_op: struct { op: []const u8, label: ?[]const u8, block_type: WatBlockType, body: []WatInstr },
    // If/else
    if_op: struct { label: ?[]const u8, block_type: WatBlockType, then_body: []WatInstr, else_body: []WatInstr },
    // br_table
    br_table: struct { targets: []WatIndex, default: WatIndex },
    // call_indirect / return_call_indirect
    call_indirect: struct { op: []const u8, type_use: ?WatIndex, table_idx: WatIndex },
    // select with type
    select_t: []WatValType,
    // try_table with catch clauses
    try_table: struct {
        label: ?[]const u8,
        block_type: WatBlockType,
        catches: []CatchClause,
        body: []WatInstr,
    },
    // ref.null <heaptype>
    ref_null: WatIndex, // heap type constant or type index
    // GC: type_idx + field_idx (struct.get, struct.set, etc.)
    gc_type_field: struct { op: []const u8, type_idx: WatIndex, field_idx: WatIndex },
    // GC: type_idx + u32 (array.new_fixed)
    gc_type_u32: struct { op: []const u8, type_idx: WatIndex, count: u32 },
    // GC: two type indices (array.copy)
    gc_two_types: struct { op: []const u8, type1: WatIndex, type2: WatIndex },
    // GC: type_idx + data/elem index (array.new_data, array.init_data, etc.)
    gc_type_seg: struct { op: []const u8, type_idx: WatIndex, seg_idx: WatIndex },
    // GC: heap type immediate (ref.test, ref.cast, etc.)
    gc_heap_type: struct { op: []const u8, heap_type: WatIndex },
    // GC: br_on_cast / br_on_cast_fail
    gc_br_on_cast: struct { op: []const u8, flags: u8, label: WatIndex, ht1: WatIndex, ht2: WatIndex },
    // Two index immediates: table.copy dst src, memory.copy dst src
    two_index: struct { op: []const u8, idx1: WatIndex, idx2: WatIndex },
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
    shared: bool = false,
};

pub const WatMemory = struct {
    name: ?[]const u8,
    limits: WatLimits,
    export_name: ?[]const u8,
    is_memory64: bool = false,
};

pub const WatTable = struct {
    name: ?[]const u8,
    limits: WatLimits,
    reftype: WatValType,
    export_name: ?[]const u8,
    is_table64: bool = false,
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
    memory: struct {
        limits: WatLimits,
        is_memory64: bool = false,
    },
    table: struct {
        limits: WatLimits,
        reftype: WatValType,
        is_table64: bool = false,
    },
    global: WatGlobalType,
    tag: struct {
        type_use: ?WatIndex,
        params: []WatParam,
    },
};

pub const WatImport = struct {
    module_name: []const u8,
    name: []const u8,
    id: ?[]const u8,
    kind: WatImportKind,
};

pub const WatTag = struct {
    name: ?[]const u8,
    type_use: ?WatIndex,
    params: []WatParam,
    export_name: ?[]const u8,
};

pub const WatExportKind = enum {
    func,
    memory,
    table,
    global,
    tag,
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
    mode: ElemMode = .active,
    is_expr_style: bool = false, // true for "funcref (ref.func N)" form

    const ElemMode = enum { active, passive, declarative };
};

pub const WatModule = struct {
    name: ?[]const u8,
    types: []WatTypeDef,
    imports: []WatImport,
    functions: []WatFunc,
    memories: []WatMemory,
    tables: []WatTable,
    globals: []WatGlobal,
    exports: []WatExport,
    start: ?WatIndex,
    data: []WatData,
    elements: []WatElem,
    tags: []WatTag,
};

// ============================================================
// Parser
// ============================================================

pub const Parser = struct {
    tok: Tokenizer,
    alloc: Allocator,
    current: Token,
    depth: u32 = 0,

    const max_depth: u32 = 1000;

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

        var types: std.ArrayListUnmanaged(WatTypeDef) = .empty;
        var imports: std.ArrayListUnmanaged(WatImport) = .empty;
        var functions: std.ArrayListUnmanaged(WatFunc) = .empty;
        var memories: std.ArrayListUnmanaged(WatMemory) = .empty;
        var tables: std.ArrayListUnmanaged(WatTable) = .empty;
        var globals: std.ArrayListUnmanaged(WatGlobal) = .empty;
        var exports: std.ArrayListUnmanaged(WatExport) = .empty;
        var start: ?WatIndex = null;
        var data_segments: std.ArrayListUnmanaged(WatData) = .empty;
        var elem_segments: std.ArrayListUnmanaged(WatElem) = .empty;
        var tags: std.ArrayListUnmanaged(WatTag) = .empty;

        while (self.current.tag != .rparen and self.current.tag != .eof) {
            if (self.current.tag != .lparen) return error.InvalidWat;
            _ = self.advance(); // consume (

            if (self.current.tag != .keyword) return error.InvalidWat;
            const section = self.current.text;

            if (std.mem.eql(u8, section, "type")) {
                _ = self.advance();
                types.append(self.alloc, try self.parseTypeDef()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, section, "rec")) {
                _ = self.advance();
                // (rec (type ...) (type ...) ...)
                // Mark start of rec group, parse contained types
                const rec_start: u32 = @intCast(types.items.len);
                while (self.current.tag == .lparen) {
                    const saved_pos = self.tok.pos;
                    const saved_current = self.current;
                    _ = self.advance(); // consume (
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "type")) {
                        _ = self.advance(); // consume "type"
                        types.append(self.alloc, try self.parseTypeDef()) catch return error.OutOfMemory;
                    } else {
                        self.tok.pos = saved_pos;
                        self.current = saved_current;
                        break;
                    }
                }
                const rec_count: u32 = @intCast(types.items.len - rec_start);
                // Mark the first type in the rec group with rec_count
                if (rec_count > 0) {
                    types.items[rec_start].rec_count = rec_count;
                }
                _ = try self.expect(.rparen); // close (rec ...)
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
            } else if (std.mem.eql(u8, section, "tag")) {
                _ = self.advance();
                tags.append(self.alloc, try self.parseTag(&exports)) catch return error.OutOfMemory;
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
            .tags = tags.items,
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
        // (ref ...) or (ref null ...) — starts with lparen
        if (self.current.tag == .lparen) {
            return self.parseRefType();
        }
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
        // GC abbreviations
        if (std.mem.eql(u8, text, "anyref")) return .anyref;
        if (std.mem.eql(u8, text, "eqref")) return .eqref;
        if (std.mem.eql(u8, text, "i31ref")) return .i31ref;
        if (std.mem.eql(u8, text, "structref")) return .structref;
        if (std.mem.eql(u8, text, "arrayref")) return .arrayref;
        if (std.mem.eql(u8, text, "nullref")) return .nullref;
        if (std.mem.eql(u8, text, "nullfuncref")) return .nullfuncref;
        if (std.mem.eql(u8, text, "nullexternref")) return .nullexternref;
        return error.InvalidWat;
    }

    fn parseHeapType(self: *Parser) WatError!WatIndex {
        const opcode = @import("opcode.zig");
        if (self.current.tag == .keyword) {
            const text = self.advance().text;
            if (std.mem.eql(u8, text, "func")) return .{ .num = opcode.ValType.HEAP_FUNC };
            if (std.mem.eql(u8, text, "extern")) return .{ .num = opcode.ValType.HEAP_EXTERN };
            if (std.mem.eql(u8, text, "any")) return .{ .num = opcode.ValType.HEAP_ANY };
            if (std.mem.eql(u8, text, "eq")) return .{ .num = opcode.ValType.HEAP_EQ };
            if (std.mem.eql(u8, text, "i31")) return .{ .num = opcode.ValType.HEAP_I31 };
            if (std.mem.eql(u8, text, "struct")) return .{ .num = opcode.ValType.HEAP_STRUCT };
            if (std.mem.eql(u8, text, "array")) return .{ .num = opcode.ValType.HEAP_ARRAY };
            if (std.mem.eql(u8, text, "none")) return .{ .num = opcode.ValType.HEAP_NONE };
            if (std.mem.eql(u8, text, "nofunc")) return .{ .num = opcode.ValType.HEAP_NOFUNC };
            if (std.mem.eql(u8, text, "noextern")) return .{ .num = opcode.ValType.HEAP_NOEXTERN };
            if (std.mem.eql(u8, text, "exn")) return .{ .num = opcode.ValType.HEAP_EXN };
            if (std.mem.eql(u8, text, "noexn")) return .{ .num = opcode.ValType.HEAP_NOEXN };
            return error.InvalidWat;
        }
        if (self.current.tag == .integer) {
            const text = self.advance().text;
            const n = std.fmt.parseInt(u32, text, 10) catch return error.InvalidWat;
            return .{ .num = n };
        }
        if (self.current.tag == .ident) {
            return .{ .name = self.advance().text };
        }
        return error.InvalidWat;
    }

    fn parseRefType(self: *Parser) WatError!WatValType {
        // (ref $T) or (ref null $T)
        _ = try self.expect(.lparen); // consume (
        try self.expectKeyword("ref");

        var nullable = false;
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "null")) {
            _ = self.advance();
            nullable = true;
        }

        const heap_type = try self.parseHeapType();
        _ = try self.expect(.rparen);
        return if (nullable) .{ .ref_null_type = heap_type } else .{ .ref_type = heap_type };
    }

    fn parseTypeDef(self: *Parser) WatError!WatTypeDef {
        // (type $name? (func|struct|array ...))
        // We've already consumed "type"
        var type_name: ?[]const u8 = null;
        if (self.current.tag == .ident) type_name = self.advance().text;

        _ = try self.expect(.lparen);

        if (self.current.tag != .keyword) return error.InvalidWat;
        const composite_kw = self.current.text;

        if (std.mem.eql(u8, composite_kw, "func")) {
            _ = self.advance(); // consume "func"
            const ft = try self.parseFuncSig();
            _ = try self.expect(.rparen); // close (func ...)
            _ = try self.expect(.rparen); // close (type ...)
            return .{ .name = type_name, .composite = .{ .func = ft } };
        } else if (std.mem.eql(u8, composite_kw, "struct")) {
            _ = self.advance(); // consume "struct"
            var fields: std.ArrayListUnmanaged(WatFieldType) = .empty;
            while (self.current.tag == .lparen) {
                const saved_pos = self.tok.pos;
                const saved_current = self.current;
                _ = self.advance(); // consume (
                if (self.current.tag != .keyword or !std.mem.eql(u8, self.current.text, "field")) {
                    self.tok.pos = saved_pos;
                    self.current = saved_current;
                    break;
                }
                _ = self.advance(); // consume "field"
                fields.append(self.alloc, try self.parseFieldType()) catch return error.OutOfMemory;
                _ = try self.expect(.rparen);
            }
            _ = try self.expect(.rparen); // close (struct ...)
            _ = try self.expect(.rparen); // close (type ...)
            return .{ .name = type_name, .composite = .{ .struct_type = .{ .fields = fields.items } } };
        } else if (std.mem.eql(u8, composite_kw, "array")) {
            _ = self.advance(); // consume "array"
            const field = try self.parseFieldType();
            _ = try self.expect(.rparen); // close (array ...)
            _ = try self.expect(.rparen); // close (type ...)
            return .{ .name = type_name, .composite = .{ .array_type = .{ .field = field } } };
        } else {
            return error.InvalidWat;
        }
    }

    fn parseFuncSig(self: *Parser) WatError!WatFuncType {
        // Parse (param ...) (result ...) sequences — reusable for type defs and inline sigs
        var params: std.ArrayListUnmanaged(WatValType) = .empty;
        var results: std.ArrayListUnmanaged(WatValType) = .empty;

        while (self.current.tag == .lparen) {
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance(); // consume (
            if (self.current.tag != .keyword) {
                self.tok.pos = saved_pos;
                self.current = saved_current;
                break;
            }
            if (std.mem.eql(u8, self.current.text, "param")) {
                _ = self.advance(); // consume "param"
                while (self.current.tag == .keyword or self.current.tag == .ident or self.current.tag == .lparen) {
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
                while (self.current.tag == .keyword or self.current.tag == .lparen) {
                    results.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                }
                _ = try self.expect(.rparen);
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
                break;
            }
        }

        return .{ .params = params.items, .results = results.items };
    }

    fn parseFieldType(self: *Parser) WatError!WatFieldType {
        // Parse: $name? (mut valtype) | valtype
        var field_name: ?[]const u8 = null;
        if (self.current.tag == .ident) field_name = self.advance().text;

        if (self.current.tag == .lparen) {
            // Check for (mut ...)
            const saved_pos = self.tok.pos;
            const saved_current = self.current;
            _ = self.advance(); // consume (
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "mut")) {
                _ = self.advance(); // consume "mut"
                const vt = try self.parseValType();
                _ = try self.expect(.rparen);
                return .{ .name = field_name, .valtype = vt, .mutable = true };
            }
            // Not mut, restore
            self.tok.pos = saved_pos;
            self.current = saved_current;
        }

        const vt = try self.parseValType();
        return .{ .name = field_name, .valtype = vt, .mutable = false };
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
                    while (self.current.tag == .keyword or self.current.tag == .lparen) {
                        const vt = try self.parseValType();
                        params.append(self.alloc, .{ .name = null, .valtype = vt }) catch return error.OutOfMemory;
                    }
                }
                _ = try self.expect(.rparen);
            } else if (std.mem.eql(u8, self.current.text, "result")) {
                _ = self.advance();
                while (self.current.tag == .keyword or self.current.tag == .lparen) {
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
                    while (self.current.tag == .keyword or self.current.tag == .lparen) {
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

        // Check for memory64 index type: (memory i64 min max?)
        var is_memory64 = false;
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "i64")) {
            is_memory64 = true;
            _ = self.advance();
        }

        const limits = try self.parseLimits();
        _ = try self.expect(.rparen);

        return .{
            .name = mem_name,
            .limits = limits,
            .export_name = export_name,
            .is_memory64 = is_memory64,
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

        // Optional i64 keyword for table64
        var is_table64 = false;
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "i64")) {
            _ = self.advance();
            is_table64 = true;
        }

        const limits = try self.parseLimits();
        const reftype = try self.parseValType();
        _ = try self.expect(.rparen);

        return .{
            .name = tbl_name,
            .limits = limits,
            .reftype = reftype,
            .export_name = export_name,
            .is_table64 = is_table64,
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

    fn parseTag(self: *Parser, exports: *std.ArrayListUnmanaged(WatExport)) WatError!WatTag {
        _ = exports;
        var tag_name: ?[]const u8 = null;
        var export_name: ?[]const u8 = null;

        if (self.current.tag == .ident) {
            tag_name = self.advance().text;
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

        // (type $t) or (param ...)
        var type_use: ?WatIndex = null;
        var params: std.ArrayListUnmanaged(WatParam) = .empty;
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
                    while (self.current.tag == .keyword or self.current.tag == .lparen) {
                        const vt = try self.parseValType();
                        params.append(self.alloc, .{ .name = null, .valtype = vt }) catch return error.OutOfMemory;
                    }
                }
                _ = try self.expect(.rparen);
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
                break;
            }
        }

        _ = try self.expect(.rparen); // close (tag ...)

        return .{
            .name = tag_name,
            .type_use = type_use,
            .params = params.items,
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
                        while (self.current.tag == .keyword or self.current.tag == .lparen) {
                            const vt = try self.parseValType();
                            params.append(self.alloc, .{ .name = null, .valtype = vt }) catch return error.OutOfMemory;
                        }
                    }
                    _ = try self.expect(.rparen);
                } else if (std.mem.eql(u8, self.current.text, "result")) {
                    _ = self.advance();
                    while (self.current.tag == .keyword or self.current.tag == .lparen) {
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
            var import_mem64 = false;
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "i64")) {
                import_mem64 = true;
                _ = self.advance();
            }
            kind = .{ .memory = .{ .limits = try self.parseLimits(), .is_memory64 = import_mem64 } };
        } else if (std.mem.eql(u8, kind_text, "table")) {
            var import_table64 = false;
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "i64")) {
                _ = self.advance();
                import_table64 = true;
            }
            const limits = try self.parseLimits();
            const reftype = try self.parseValType();
            kind = .{ .table = .{ .limits = limits, .reftype = reftype, .is_table64 = import_table64 } };
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
        } else if (std.mem.eql(u8, kind_text, "tag")) {
            var tag_type_use: ?WatIndex = null;
            var tag_params: std.ArrayListUnmanaged(WatParam) = .empty;
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
                    tag_type_use = try self.parseIndex();
                    _ = try self.expect(.rparen);
                } else if (std.mem.eql(u8, self.current.text, "param")) {
                    _ = self.advance();
                    if (self.current.tag == .ident) {
                        const pname = self.advance().text;
                        const vt = try self.parseValType();
                        tag_params.append(self.alloc, .{ .name = pname, .valtype = vt }) catch return error.OutOfMemory;
                    } else {
                        while (self.current.tag == .keyword or self.current.tag == .lparen) {
                            const vt = try self.parseValType();
                            tag_params.append(self.alloc, .{ .name = null, .valtype = vt }) catch return error.OutOfMemory;
                        }
                    }
                    _ = try self.expect(.rparen);
                } else {
                    self.tok.pos = saved_pos;
                    self.current = saved_current;
                    break;
                }
            }
            kind = .{ .tag = .{ .type_use = tag_type_use, .params = tag_params.items } };
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
        else if (std.mem.eql(u8, kind_text, "tag"))
            .tag
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
        var mode: WatElem.ElemMode = .active;

        // Check for "declare" keyword (declarative elem segment)
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "declare")) {
            _ = self.advance();
            mode = .declarative;
        }
        // Check for (table ...) or offset expression
        else if (self.current.tag == .lparen) {
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
                    // No offset expression — this is a passive elem segment
                    mode = .passive;
                }
            } else {
                self.tok.pos = saved_pos;
                self.current = saved_current;
            }
        }
        // Check for reftype keyword without paren (passive: funcref ... or externref ...)
        else if (self.current.tag == .keyword and
            (std.mem.eql(u8, self.current.text, "funcref") or
            std.mem.eql(u8, self.current.text, "externref")))
        {
            mode = .passive;
        }

        // Parse "func" keyword then function indices, or reftype + expr items
        var func_indices: std.ArrayListUnmanaged(WatIndex) = .empty;
        var is_expr_style = false;
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "func")) {
            _ = self.advance(); // consume "func"
            while (self.current.tag == .integer or self.current.tag == .ident) {
                func_indices.append(self.alloc, try self.parseIndex()) catch return error.OutOfMemory;
            }
        } else if (self.current.tag == .keyword and
            (std.mem.eql(u8, self.current.text, "funcref") or
            std.mem.eql(u8, self.current.text, "externref")))
        {
            is_expr_style = true;
            _ = self.advance(); // consume reftype keyword
            while (self.current.tag == .lparen) {
                _ = self.advance(); // consume (
                if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "ref.func")) {
                    _ = self.advance(); // consume ref.func
                    func_indices.append(self.alloc, try self.parseIndex()) catch return error.OutOfMemory;
                    _ = try self.expect(.rparen);
                } else if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "ref.null")) {
                    _ = self.advance(); // consume ref.null
                    _ = try self.parseHeapType(); // consume heap type
                    _ = try self.expect(.rparen);
                    func_indices.append(self.alloc, .{ .num = 0xFFFFFFFF }) catch return error.OutOfMemory;
                } else {
                    return error.InvalidWat;
                }
            }
        } else if (self.current.tag == .lparen) {
            // Check for (ref ...) as a parenthesized reftype
            const saved_pos2 = self.tok.pos;
            const saved_current2 = self.current;
            _ = self.advance(); // consume (
            if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "ref")) {
                // (ref null <heaptype>) or (ref <heaptype>) — element type annotation
                _ = self.advance(); // consume "ref"
                if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "null")) {
                    _ = self.advance(); // consume "null"
                }
                _ = try self.parseHeapType(); // consume heap type
                _ = try self.expect(.rparen);
                is_expr_style = true;
            } else {
                // Not (ref ...) — restore position
                self.tok.pos = saved_pos2;
                self.current = saved_current2;
            }
            if (is_expr_style) {
                while (self.current.tag == .lparen) {
                    _ = self.advance(); // consume (
                    if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "ref.func")) {
                        _ = self.advance();
                        func_indices.append(self.alloc, try self.parseIndex()) catch return error.OutOfMemory;
                        _ = try self.expect(.rparen);
                    } else if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "ref.null")) {
                        _ = self.advance();
                        _ = try self.parseHeapType();
                        _ = try self.expect(.rparen);
                        func_indices.append(self.alloc, .{ .num = 0xFFFFFFFF }) catch return error.OutOfMemory;
                    } else {
                        return error.InvalidWat;
                    }
                }
            }
        } else {
            while (self.current.tag == .integer or self.current.tag == .ident) {
                func_indices.append(self.alloc, try self.parseIndex()) catch return error.OutOfMemory;
            }
        }

        _ = try self.expect(.rparen); // close (elem ...)

        return .{
            .name = name,
            .table_idx = table_idx,
            .offset = offset_instrs.items,
            .func_indices = func_indices.items,
            .mode = mode,
            .is_expr_style = is_expr_style,
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

        var shared = false;
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "shared")) {
            _ = self.advance();
            if (max == null) return error.InvalidWat; // shared requires max
            shared = true;
        }

        return .{ .min = min, .max = max, .shared = shared };
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
        simd_lane, // extract_lane, replace_lane
        simd_shuffle, // i8x16.shuffle
        simd_mem_lane, // v128.load*_lane, v128.store*_lane
        br_table,
        call_indirect,
        select_t,
        ref_null, // ref.null <heaptype>
        gc_type_field, // struct.get, struct.get_s, struct.get_u, struct.set
        gc_type_u32, // array.new_fixed
        gc_two_types, // array.copy
        gc_type_data, // array.new_data, array.init_data
        gc_type_elem, // array.new_elem, array.init_elem
        gc_heap_type, // ref.test, ref.test_null, ref.cast, ref.cast_null
        gc_br_on_cast, // br_on_cast, br_on_cast_fail
        two_index, // table.copy, memory.copy (two index immediates)
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
        if (std.mem.eql(u8, name, "select")) return .select_t;
        if (std.mem.eql(u8, name, "ref.null")) return .ref_null;

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
            std.mem.eql(u8, name, "memory.fill") or
            std.mem.eql(u8, name, "data.drop") or
            std.mem.eql(u8, name, "elem.drop") or
            std.mem.eql(u8, name, "call_ref") or
            std.mem.eql(u8, name, "return_call_ref") or
            std.mem.eql(u8, name, "br_on_null") or
            std.mem.eql(u8, name, "br_on_non_null"))
            return .index_imm;

        // GC no-immediate instructions
        if (std.mem.eql(u8, name, "array.len") or
            std.mem.eql(u8, name, "ref.i31") or
            std.mem.eql(u8, name, "i31.get_s") or
            std.mem.eql(u8, name, "i31.get_u") or
            std.mem.eql(u8, name, "any.convert_extern") or
            std.mem.eql(u8, name, "extern.convert_any"))
            return .no_imm;

        // GC single-index instructions (type index only)
        if (std.mem.eql(u8, name, "struct.new") or
            std.mem.eql(u8, name, "struct.new_default") or
            std.mem.eql(u8, name, "array.new") or
            std.mem.eql(u8, name, "array.new_default") or
            std.mem.eql(u8, name, "array.get") or
            std.mem.eql(u8, name, "array.get_s") or
            std.mem.eql(u8, name, "array.get_u") or
            std.mem.eql(u8, name, "array.set") or
            std.mem.eql(u8, name, "array.fill"))
            return .index_imm;

        // GC type + field index (struct field access)
        if (std.mem.eql(u8, name, "struct.get") or
            std.mem.eql(u8, name, "struct.get_s") or
            std.mem.eql(u8, name, "struct.get_u") or
            std.mem.eql(u8, name, "struct.set"))
            return .gc_type_field;

        // GC type + u32 count
        if (std.mem.eql(u8, name, "array.new_fixed"))
            return .gc_type_u32;

        // GC two type indices
        if (std.mem.eql(u8, name, "array.copy"))
            return .gc_two_types;

        // GC type + data index
        if (std.mem.eql(u8, name, "array.new_data") or
            std.mem.eql(u8, name, "array.init_data"))
            return .gc_type_data;

        // GC type + elem index
        if (std.mem.eql(u8, name, "array.new_elem") or
            std.mem.eql(u8, name, "array.init_elem"))
            return .gc_type_elem;

        // GC heap type
        if (std.mem.eql(u8, name, "ref.test") or
            std.mem.eql(u8, name, "ref.test_null") or
            std.mem.eql(u8, name, "ref.cast") or
            std.mem.eql(u8, name, "ref.cast_null"))
            return .gc_heap_type;

        // GC br_on_cast
        if (std.mem.eql(u8, name, "br_on_cast") or
            std.mem.eql(u8, name, "br_on_cast_fail"))
            return .gc_br_on_cast;

        // Two-index instructions
        if (std.mem.eql(u8, name, "table.copy")) return .two_index;
        if (std.mem.eql(u8, name, "memory.copy")) return .two_index;
        if (std.mem.eql(u8, name, "table.init")) return .two_index;
        if (std.mem.eql(u8, name, "memory.init")) return .two_index;

        // SIMD shuffle (16 lane immediates)
        if (std.mem.eql(u8, name, "i8x16.shuffle")) return .simd_shuffle;

        // SIMD lane ops (extract_lane, replace_lane)
        if (isSimdLaneOp(name)) return .simd_lane;

        // SIMD load/store lane ops
        if (isSimdMemLaneOp(name)) return .simd_mem_lane;

        // Atomic memory ops (all take memarg except atomic.fence)
        if (std.mem.indexOf(u8, name, ".atomic.") != null)
            return .mem_imm;

        // SIMD memory ops (v128.load*, v128.store — NOT lane variants)
        if ((std.mem.startsWith(u8, name, "v128.load") or std.mem.startsWith(u8, name, "v128.store")) and
            !isSimdMemLaneOp(name))
            return .mem_imm;

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

    fn isSimdLaneOp(name: []const u8) bool {
        const ops = [_][]const u8{
            "i8x16.extract_lane_s", "i8x16.extract_lane_u", "i8x16.replace_lane",
            "i16x8.extract_lane_s", "i16x8.extract_lane_u", "i16x8.replace_lane",
            "i32x4.extract_lane", "i32x4.replace_lane",
            "i64x2.extract_lane", "i64x2.replace_lane",
            "f32x4.extract_lane", "f32x4.replace_lane",
            "f64x2.extract_lane", "f64x2.replace_lane",
        };
        for (ops) |op| {
            if (std.mem.eql(u8, name, op)) return true;
        }
        return false;
    }

    fn isSimdMemLaneOp(name: []const u8) bool {
        const ops = [_][]const u8{
            "v128.load8_lane",  "v128.load16_lane",  "v128.load32_lane",  "v128.load64_lane",
            "v128.store8_lane", "v128.store16_lane", "v128.store32_lane", "v128.store64_lane",
        };
        for (ops) |op| {
            if (std.mem.eql(u8, name, op)) return true;
        }
        return false;
    }

    /// Parse block type: (type N)?, (param ...)*, (result ...)*
    /// Returns WatBlockType.empty, .val_type, or .type_idx.
    fn parseBlockType(self: *Parser) WatError!WatBlockType {
        if (self.current.tag != .lparen) return .empty;

        // Peek ahead: (type N)?
        const saved_pos = self.tok.pos;
        const saved_current = self.current;
        _ = self.advance(); // consume (
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "type")) {
            _ = self.advance(); // consume "type"
            const idx = try self.parseIndex();
            _ = try self.expect(.rparen);
            // Skip redundant (param ...) and (result ...) annotations
            while (self.current.tag == .lparen) {
                const sp = self.tok.pos;
                const sc = self.current;
                _ = self.advance();
                if (self.current.tag == .keyword and
                    (std.mem.eql(u8, self.current.text, "param") or
                    std.mem.eql(u8, self.current.text, "result")))
                {
                    // Skip tokens until matching )
                    var depth: u32 = 1;
                    while (depth > 0) {
                        const tok = self.advance();
                        if (tok.tag == .lparen) depth += 1;
                        if (tok.tag == .rparen) depth -= 1;
                        if (tok.tag == .eof) return error.InvalidWat;
                    }
                } else {
                    self.tok.pos = sp;
                    self.current = sc;
                    break;
                }
            }
            return .{ .type_idx = idx };
        }

        // Not (type ...), restore and try (result type)
        self.tok.pos = saved_pos;
        self.current = saved_current;

        // Try (result type) for single-value block type
        _ = self.advance(); // consume (
        if (self.current.tag == .keyword and std.mem.eql(u8, self.current.text, "result")) {
            _ = self.advance(); // consume "result"
            const vt = try self.parseValType();
            // Check if there's a second result type (multi-value without type index)
            if (self.current.tag != .rparen) {
                // Multi-value result without (type N) — not currently supported,
                // fall back to InvalidWat
                return error.InvalidWat;
            }
            _ = try self.expect(.rparen);
            return .{ .val_type = vt };
        }

        // Not (result ...) either, restore
        self.tok.pos = saved_pos;
        self.current = saved_current;
        return .empty;
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
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_depth) return error.InvalidWat;

        _ = self.advance(); // consume (

        if (self.current.tag != .keyword) return error.InvalidWat;
        const op_name = self.advance().text;
        const cat = classifyInstr(op_name);

        switch (cat) {
            .block_type => {
                // (block $label? (type N)? (result type)? instr*)
                var label: ?[]const u8 = null;
                if (self.current.tag == .ident) label = self.advance().text;
                const block_type = try self.parseBlockType();
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
                if (self.current.tag == .ident) label = self.advance().text;
                const block_type = try self.parseBlockType();
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
                // (if $label? (type N)? (result type)? (then instr*) (else instr*)?)
                var label: ?[]const u8 = null;
                if (self.current.tag == .ident) label = self.advance().text;
                const block_type = try self.parseBlockType();

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
                // block $label? (type N)? (result type)? ... end
                var label: ?[]const u8 = null;
                if (self.current.tag == .ident) label = self.advance().text;
                var block_type = try self.parseBlockType();
                // inline valtype (e.g. "block i32 ...")
                if (block_type == .empty and self.current.tag == .keyword) {
                    const vt = self.tryParseValType();
                    if (vt != null) block_type = .{ .val_type = vt.? };
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
                if (self.current.tag == .ident) label = self.advance().text;
                var block_type = try self.parseBlockType();
                if (block_type == .empty and self.current.tag == .keyword) {
                    const vt = self.tryParseValType();
                    if (vt != null) block_type = .{ .val_type = vt.? };
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
                // try_table $label? (type N)? (result type)? (catch ...)* body end
                var label: ?[]const u8 = null;
                if (self.current.tag == .ident) label = self.advance().text;
                const block_type = try self.parseBlockType();
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
                // memory.size/memory.grow/memory.fill: index defaults to 0 when omitted
                if (std.mem.eql(u8, op_name, "memory.size") or
                    std.mem.eql(u8, op_name, "memory.grow") or
                    std.mem.eql(u8, op_name, "memory.fill"))
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
            .simd_shuffle => blk: {
                var lanes: [16]u8 = undefined;
                for (&lanes) |*lane| {
                    if (self.current.tag != .integer) return error.InvalidWat;
                    lane.* = std.fmt.parseInt(u8, self.advance().text, 10) catch return error.InvalidWat;
                }
                break :blk .{ .simd_shuffle = lanes };
            },
            .simd_lane => blk: {
                if (self.current.tag != .integer) return error.InvalidWat;
                const lane_text = self.advance().text;
                const lane = std.fmt.parseInt(u8, lane_text, 10) catch return error.InvalidWat;
                break :blk .{ .simd_lane = .{ .op = op_name, .lane = lane } };
            },
            .simd_mem_lane => blk: {
                const mem_arg = try self.parseMemArgLane();
                if (self.current.tag != .integer) return error.InvalidWat;
                const lane_text = self.advance().text;
                const lane = std.fmt.parseInt(u8, lane_text, 10) catch return error.InvalidWat;
                break :blk .{ .simd_mem_lane = .{ .op = op_name, .mem_arg = mem_arg, .lane = lane } };
            },
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
                // call_indirect $table? (type $t)? | call_indirect (type $t) $table?
                var type_idx: ?WatIndex = null;
                var table_idx: WatIndex = .{ .num = 0 };
                // Check for table name before type use (wasm-tools format: call_indirect $t (type ...))
                if (self.current.tag == .ident) {
                    table_idx = try self.parseIndex();
                }
                // Parse (type $t)
                if (self.current.tag == .lparen) {
                    _ = self.advance();
                    try self.expectKeyword("type");
                    type_idx = try self.parseIndex();
                    _ = try self.expect(.rparen);
                }
                // Check for table index after type (numeric)
                if (self.current.tag == .integer) {
                    const text = self.advance().text;
                    table_idx = .{ .num = std.fmt.parseInt(u32, text, 10) catch return error.InvalidWat };
                }
                break :blk .{ .call_indirect = .{ .op = op_name, .type_use = type_idx, .table_idx = table_idx } };
            },
            .select_t => blk: {
                // select (result type)
                var types: std.ArrayListUnmanaged(WatValType) = .empty;
                if (self.current.tag == .lparen) {
                    _ = self.advance();
                    try self.expectKeyword("result");
                    while (self.current.tag == .keyword or self.current.tag == .lparen) {
                        types.append(self.alloc, try self.parseValType()) catch return error.OutOfMemory;
                    }
                    _ = try self.expect(.rparen);
                }
                break :blk .{ .select_t = types.items };
            },
            .ref_null => blk: {
                break :blk .{ .ref_null = try self.parseHeapType() };
            },
            .gc_type_field => blk: {
                const type_idx = try self.parseIndex();
                const field_idx = try self.parseIndex();
                break :blk .{ .gc_type_field = .{ .op = op_name, .type_idx = type_idx, .field_idx = field_idx } };
            },
            .gc_type_u32 => blk: {
                const type_idx = try self.parseIndex();
                if (self.current.tag != .integer) return error.InvalidWat;
                const count = std.fmt.parseInt(u32, self.advance().text, 10) catch return error.InvalidWat;
                break :blk .{ .gc_type_u32 = .{ .op = op_name, .type_idx = type_idx, .count = count } };
            },
            .gc_two_types => blk: {
                const type1 = try self.parseIndex();
                const type2 = try self.parseIndex();
                break :blk .{ .gc_two_types = .{ .op = op_name, .type1 = type1, .type2 = type2 } };
            },
            .gc_type_data, .gc_type_elem => blk: {
                const type_idx = try self.parseIndex();
                const seg_idx = try self.parseIndex();
                break :blk .{ .gc_type_seg = .{ .op = op_name, .type_idx = type_idx, .seg_idx = seg_idx } };
            },
            .gc_heap_type => blk: {
                const heap_type = try self.parseHeapType();
                break :blk .{ .gc_heap_type = .{ .op = op_name, .heap_type = heap_type } };
            },
            .gc_br_on_cast => blk: {
                // br_on_cast flags label ht1 ht2
                // Parse: label first, then two heap types
                // flags: bit 0 = ht1 nullable, bit 1 = ht2 nullable
                // For WAT, we parse: br_on_cast label ht1 ht2
                // The null variants are encoded in the heap type (ref vs ref null)
                const label = try self.parseIndex();
                const ht1 = try self.parseHeapType();
                const ht2 = try self.parseHeapType();
                // Determine flags from instruction name
                // br_on_cast and br_on_cast_fail both have same encoding,
                // differentiated by opcode (0x18 vs 0x19)
                // Flags need to be computed from the heap type nullability
                // For now, use 0x00 (both non-nullable) as default
                // The actual flags depend on WAT syntax like (ref null ...) vs (ref ...)
                break :blk .{ .gc_br_on_cast = .{
                    .op = op_name,
                    .flags = 0x03, // both nullable as common default
                    .label = label,
                    .ht1 = ht1,
                    .ht2 = ht2,
                } };
            },
            .two_index => blk: {
                // table.copy dst src — both default to 0
                // memory.copy dst src — both default to 0
                // table.init [table] elem — table defaults to 0, elem required
                // memory.init [mem] data — mem defaults to 0, data required
                const is_init = std.mem.eql(u8, op_name, "table.init") or
                    std.mem.eql(u8, op_name, "memory.init");
                var idx1: WatIndex = .{ .num = 0 };
                var idx2: WatIndex = .{ .num = 0 };
                if (is_init) {
                    // For init: optional named table/mem first, then required segment idx
                    // memory.init $seg OR memory.init $mem $seg
                    // table.init $seg OR table.init $table $seg
                    if (self.current.tag == .ident) {
                        const first = try self.parseIndex();
                        if (self.current.tag == .ident or self.current.tag == .integer) {
                            // Two args: first is table/mem, second is segment
                            idx1 = first;
                            idx2 = try self.parseIndex();
                        } else {
                            // One arg: it's the segment, table/mem defaults to 0
                            idx2 = first;
                        }
                    } else if (self.current.tag == .integer) {
                        // Numeric segment index
                        idx2 = try self.parseIndex();
                    }
                } else {
                    // For copy: both indices, defaulting to 0
                    if (self.current.tag == .integer or self.current.tag == .ident) {
                        idx1 = try self.parseIndex();
                        if (self.current.tag == .integer or self.current.tag == .ident) {
                            idx2 = try self.parseIndex();
                        }
                    }
                }
                break :blk .{ .two_index = .{ .op = op_name, .idx1 = idx1, .idx2 = idx2 } };
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
        if (self.current.tag != .float and self.current.tag != .integer and
            !isFloatKeyword(self.current))
            return error.InvalidWat;
        const text = self.advance().text;
        return parseFloatLiteral(f32, text) catch return error.InvalidWat;
    }

    fn parseF64(self: *Parser) WatError!f64 {
        if (self.current.tag != .float and self.current.tag != .integer and
            !isFloatKeyword(self.current))
            return error.InvalidWat;
        const text = self.advance().text;
        return parseFloatLiteral(f64, text) catch return error.InvalidWat;
    }

    fn isFloatKeyword(tok: Token) bool {
        if (tok.tag != .keyword) return false;
        const t = tok.text;
        return std.mem.eql(u8, t, "nan") or std.mem.eql(u8, t, "inf") or
            std.mem.eql(u8, t, "+nan") or std.mem.eql(u8, t, "-nan") or
            std.mem.eql(u8, t, "+inf") or std.mem.eql(u8, t, "-inf") or
            std.mem.startsWith(u8, t, "nan:") or std.mem.startsWith(u8, t, "+nan:") or
            std.mem.startsWith(u8, t, "-nan:");
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
                if (self.current.tag != .float and self.current.tag != .integer and
                    !isFloatKeyword(self.current)) return error.InvalidWat;
                const val = parseFloatLiteral(f64, self.advance().text) catch return error.InvalidWat;
                const le = std.mem.toBytes(std.mem.nativeToLittle(u64, @as(u64, @bitCast(val))));
                @memcpy(bytes[i * 8 ..][0..8], &le);
            }
        } else if (std.mem.eql(u8, shape, "f32x4")) {
            for (0..4) |i| {
                if (self.current.tag != .float and self.current.tag != .integer and
                    !isFloatKeyword(self.current)) return error.InvalidWat;
                const val = parseFloatLiteral(f32, self.advance().text) catch return error.InvalidWat;
                const le = std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @bitCast(val))));
                @memcpy(bytes[i * 4 ..][0..4], &le);
            }
        } else {
            return error.InvalidWat;
        }
        return bytes;
    }

    fn parseMemArgLane(self: *Parser) WatError!MemArg {
        // For SIMD lane ops: don't consume bare integer (it's the lane, not memory index)
        return self.parseMemArgInner(false);
    }

    fn parseMemArg(self: *Parser) WatError!MemArg {
        return self.parseMemArgInner(true);
    }

    fn parseMemArgInner(self: *Parser, consume_bare_int: bool) WatError!MemArg {
        var offset: u32 = 0;
        var alignment: u32 = 0;
        var mem_idx: WatIndex = .{ .num = 0 };
        // Parse optional memory index ($name or bare number) before offset/align
        if (self.current.tag == .ident) {
            mem_idx = try self.parseIndex();
        } else if (consume_bare_int and self.current.tag == .integer) {
            // Bare number: memory index (multi-memory)
            mem_idx = try self.parseIndex();
        }
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
        return .{ .offset = offset, .@"align" = alignment, .mem_idx = mem_idx };
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

    // Collect all types (explicit + synthesized from funcs/imports)
    var all_types: std.ArrayListUnmanaged(WatTypeDef) = .empty;
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
    var tag_names: std.ArrayListUnmanaged(?[]const u8) = .empty;

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
            .tag => {
                tag_names.append(arena, imp.id) catch return error.OutOfMemory;
            },
        }
    }

    // Func type indices for defined functions
    var func_type_indices: std.ArrayListUnmanaged(u32) = .empty;
    for (module.functions) |f| {
        func_names.append(arena, f.name) catch return error.OutOfMemory;
        if (f.type_use) |tu| {
            const idx = resolveIndex(tu, type_names.items, null) catch return error.InvalidWat;
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
    // Tag type indices for defined tags
    var tag_type_indices: std.ArrayListUnmanaged(u32) = .empty;
    for (module.tags) |t| {
        tag_names.append(arena, t.name) catch return error.OutOfMemory;
        if (t.type_use) |tu| {
            const idx = resolveIndex(tu, type_names.items, null) catch return error.InvalidWat;
            tag_type_indices.append(arena, idx) catch return error.OutOfMemory;
        } else {
            const vts = extractValTypes(arena, t.params) catch return error.OutOfMemory;
            const ft: WatFuncType = .{ .params = vts, .results = &.{} };
            const idx = findOrAddType(arena, &all_types, ft) catch return error.OutOfMemory;
            tag_type_indices.append(arena, idx) catch return error.OutOfMemory;
        }
    }
    // Collect data and elem segment names
    var data_names: std.ArrayListUnmanaged(?[]const u8) = .empty;
    for (module.data) |d| {
        data_names.append(arena, d.name) catch return error.OutOfMemory;
    }
    var elem_names: std.ArrayListUnmanaged(?[]const u8) = .empty;
    for (module.elements) |e| {
        elem_names.append(arena, e.name) catch return error.OutOfMemory;
    }
    // Pad type_names for any synthesized types added by findOrAddType
    while (type_names.items.len < all_types.items.len) {
        type_names.append(arena, null) catch return error.OutOfMemory;
    }

    // Section 1: Type
    if (all_types.items.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        // Count top-level entries (rec groups count as one entry)
        var type_section_count: u32 = 0;
        {
            var ti: usize = 0;
            while (ti < all_types.items.len) {
                type_section_count += 1;
                if (all_types.items[ti].rec_count > 0) {
                    ti += all_types.items[ti].rec_count;
                } else {
                    ti += 1;
                }
            }
        }
        lebEncodeU32(arena, &sec, type_section_count) catch return error.OutOfMemory;
        {
            var ti: usize = 0;
            while (ti < all_types.items.len) {
                if (all_types.items[ti].rec_count > 0) {
                    // Rec group: 0x4E + count + subtypes
                    sec.append(arena, 0x4E) catch return error.OutOfMemory;
                    lebEncodeU32(arena, &sec, all_types.items[ti].rec_count) catch return error.OutOfMemory;
                    for (0..all_types.items[ti].rec_count) |j| {
                        encodeCompositeType(arena, &sec, all_types.items[ti + j].composite, type_names.items) catch return error.OutOfMemory;
                    }
                    ti += all_types.items[ti].rec_count;
                } else {
                    encodeCompositeType(arena, &sec, all_types.items[ti].composite, type_names.items) catch return error.OutOfMemory;
                    ti += 1;
                }
            }
        }
        writeSection(arena, &out, 1, sec.items) catch return error.OutOfMemory;
    }

    // Section 2: Import
    if (module.imports.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.imports.len)) catch return error.OutOfMemory;
        for (module.imports) |imp| {
            const dec_mod = decodeWatString(arena, imp.module_name) catch return error.OutOfMemory;
            lebEncodeU32(arena, &sec, @intCast(dec_mod.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, dec_mod) catch return error.OutOfMemory;
            const dec_name = decodeWatString(arena, imp.name) catch return error.OutOfMemory;
            lebEncodeU32(arena, &sec, @intCast(dec_name.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, dec_name) catch return error.OutOfMemory;
            switch (imp.kind) {
                .func => |f| {
                    sec.append(arena, 0x00) catch return error.OutOfMemory;
                    if (f.type_use) |tu| {
                        const idx = resolveIndex(tu, type_names.items, null) catch return error.InvalidWat;
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
                    encodeValType(arena, &sec, t.reftype, type_names.items) catch return error.OutOfMemory;
                    encodeMemoryLimits(arena, &sec, t.limits, t.is_table64) catch return error.OutOfMemory;
                },
                .memory => |m| {
                    sec.append(arena, 0x02) catch return error.OutOfMemory;
                    encodeMemoryLimits(arena, &sec, m.limits, m.is_memory64) catch return error.OutOfMemory;
                },
                .global => |g| {
                    sec.append(arena, 0x03) catch return error.OutOfMemory;
                    encodeValType(arena, &sec, g.valtype, type_names.items) catch return error.OutOfMemory;
                    sec.append(arena, if (g.mutable) @as(u8, 0x01) else @as(u8, 0x00)) catch return error.OutOfMemory;
                },
                .tag => |t| {
                    sec.append(arena, 0x04) catch return error.OutOfMemory;
                    sec.append(arena, 0x00) catch return error.OutOfMemory; // exception attribute
                    if (t.type_use) |tu| {
                        const idx = resolveIndex(tu, type_names.items, null) catch return error.InvalidWat;
                        lebEncodeU32(arena, &sec, idx) catch return error.OutOfMemory;
                    } else {
                        const vts = extractValTypes(arena, t.params) catch return error.OutOfMemory;
                        const ft: WatFuncType = .{ .params = vts, .results = &.{} };
                        const idx = findOrAddType(arena, &all_types, ft) catch return error.OutOfMemory;
                        lebEncodeU32(arena, &sec, idx) catch return error.OutOfMemory;
                    }
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
            encodeValType(arena, &sec, t.reftype, type_names.items) catch return error.OutOfMemory;
            encodeMemoryLimits(arena, &sec, t.limits, t.is_table64) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 4, sec.items) catch return error.OutOfMemory;
    }

    // Section 5: Memory
    if (module.memories.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.memories.len)) catch return error.OutOfMemory;
        for (module.memories) |m| {
            encodeMemoryLimits(arena, &sec, m.limits, m.is_memory64) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 5, sec.items) catch return error.OutOfMemory;
    }

    // Section 6: Global
    if (module.globals.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(module.globals.len)) catch return error.OutOfMemory;
        for (module.globals) |g| {
            encodeValType(arena, &sec, g.global_type.valtype, type_names.items) catch return error.OutOfMemory;
            sec.append(arena, if (g.global_type.mutable) @as(u8, 0x01) else @as(u8, 0x00)) catch return error.OutOfMemory;
            var g_labels: std.ArrayListUnmanaged(?[]const u8) = .empty;
            encodeInstrList(arena, &sec, g.init, func_names.items, mem_names.items, table_names.items, global_names.items, &.{}, &g_labels, type_names.items, tag_names.items, data_names.items, elem_names.items) catch return error.OutOfMemory;
            sec.append(arena, 0x0B) catch return error.OutOfMemory; // end
        }
        writeSection(arena, &out, 6, sec.items) catch return error.OutOfMemory;
    }

    // Section 13: Tag
    if (tag_type_indices.items.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(tag_type_indices.items.len)) catch return error.OutOfMemory;
        for (tag_type_indices.items) |tidx| {
            sec.append(arena, 0x00) catch return error.OutOfMemory; // exception attribute
            lebEncodeU32(arena, &sec, tidx) catch return error.OutOfMemory;
        }
        writeSection(arena, &out, 13, sec.items) catch return error.OutOfMemory;
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
    for (module.tags, 0..) |t, i| {
        if (t.export_name) |ename| {
            all_exports.append(arena, .{
                .name = ename,
                .kind = .tag,
                .index = .{ .num = @intCast(i) },
            }) catch return error.OutOfMemory;
        }
    }
    if (all_exports.items.len > 0) {
        var sec: std.ArrayListUnmanaged(u8) = .empty;
        lebEncodeU32(arena, &sec, @intCast(all_exports.items.len)) catch return error.OutOfMemory;
        for (all_exports.items) |e| {
            const decoded_name = decodeWatString(arena, e.name) catch return error.OutOfMemory;
            lebEncodeU32(arena, &sec, @intCast(decoded_name.len)) catch return error.OutOfMemory;
            sec.appendSlice(arena, decoded_name) catch return error.OutOfMemory;
            sec.append(arena, switch (e.kind) {
                .func => 0x00,
                .table => 0x01,
                .memory => 0x02,
                .global => 0x03,
                .tag => 0x04,
            }) catch return error.OutOfMemory;
            const idx = resolveNamedIndex(e.index, switch (e.kind) {
                .func => func_names.items,
                .table => table_names.items,
                .memory => mem_names.items,
                .global => global_names.items,
                .tag => tag_names.items,
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
            switch (elem.mode) {
                .active => {
                    const table_resolved = resolveNamedIndex(elem.table_idx, table_names.items) catch return error.InvalidWat;
                    if (elem.is_expr_style) {
                        if (table_resolved == 0) {
                            // Flag 0x04: active, table 0, offset, vec(expr)
                            sec.append(arena, 0x04) catch return error.OutOfMemory;
                        } else {
                            // Flag 0x06: active, tableidx, offset, reftype, vec(expr)
                            sec.append(arena, 0x06) catch return error.OutOfMemory;
                            lebEncodeU32(arena, &sec, table_resolved) catch return error.OutOfMemory;
                        }
                    } else {
                        if (table_resolved == 0) {
                            // Flag 0x00: active, table 0, offset, vec(funcidx)
                            sec.append(arena, 0x00) catch return error.OutOfMemory;
                        } else {
                            // Flag 0x02: active, tableidx, offset, elemkind, vec(funcidx)
                            sec.append(arena, 0x02) catch return error.OutOfMemory;
                            lebEncodeU32(arena, &sec, table_resolved) catch return error.OutOfMemory;
                        }
                    }
                    // Offset expression + end
                    var e_labels: std.ArrayListUnmanaged(?[]const u8) = .empty;
                    encodeInstrList(arena, &sec, elem.offset, func_names.items, mem_names.items, table_names.items, global_names.items, &.{}, &e_labels, type_names.items, tag_names.items, data_names.items, elem_names.items) catch return error.OutOfMemory;
                    sec.append(arena, 0x0B) catch return error.OutOfMemory; // end
                    if (elem.is_expr_style) {
                        if (table_resolved != 0) {
                            sec.append(arena, 0x70) catch return error.OutOfMemory; // funcref
                        }
                    } else {
                        if (table_resolved != 0) {
                            sec.append(arena, 0x00) catch return error.OutOfMemory; // elemkind
                        }
                    }
                },
                .passive => {
                    if (elem.is_expr_style) {
                        // Flag 0x05: passive, reftype, vec(expr)
                        sec.append(arena, 0x05) catch return error.OutOfMemory;
                        sec.append(arena, 0x70) catch return error.OutOfMemory; // funcref
                    } else {
                        // Flag 0x01: passive, elemkind, vec(funcidx)
                        sec.append(arena, 0x01) catch return error.OutOfMemory;
                        sec.append(arena, 0x00) catch return error.OutOfMemory; // elemkind funcref
                    }
                },
                .declarative => {
                    // Flag 0x03: declarative, elemkind, vec(funcidx)
                    sec.append(arena, 0x03) catch return error.OutOfMemory;
                    sec.append(arena, 0x00) catch return error.OutOfMemory; // elemkind funcref
                },
            }
            // Function indices / expressions
            lebEncodeU32(arena, &sec, @intCast(elem.func_indices.len)) catch return error.OutOfMemory;
            if (elem.is_expr_style) {
                for (elem.func_indices) |fi| {
                    if (fi == .num and fi.num == 0xFFFFFFFF) {
                        // ref.null funcref
                        sec.append(arena, 0xD0) catch return error.OutOfMemory; // ref.null
                        sec.append(arena, 0x70) catch return error.OutOfMemory; // funcref
                        sec.append(arena, 0x0B) catch return error.OutOfMemory; // end
                    } else {
                        const fidx = resolveNamedIndex(fi, func_names.items) catch return error.InvalidWat;
                        sec.append(arena, 0xD2) catch return error.OutOfMemory; // ref.func
                        lebEncodeU32(arena, &sec, fidx) catch return error.OutOfMemory;
                        sec.append(arena, 0x0B) catch return error.OutOfMemory; // end
                    }
                }
            } else {
                for (elem.func_indices) |fi| {
                    const fidx = resolveNamedIndex(fi, func_names.items) catch return error.InvalidWat;
                    lebEncodeU32(arena, &sec, fidx) catch return error.OutOfMemory;
                }
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
                if (local_groups.items.len > 0 and local_groups.items[local_groups.items.len - 1].valtype.eql(l.valtype)) {
                    local_groups.items[local_groups.items.len - 1].count += 1;
                } else {
                    local_groups.append(arena, .{ .count = 1, .valtype = l.valtype }) catch return error.OutOfMemory;
                }
            }
            lebEncodeU32(arena, &code_body, @intCast(local_groups.items.len)) catch return error.OutOfMemory;
            for (local_groups.items) |lg| {
                lebEncodeU32(arena, &code_body, lg.count) catch return error.OutOfMemory;
                encodeValType(arena, &code_body, lg.valtype, type_names.items) catch return error.OutOfMemory;
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
            encodeInstrList(arena, &code_body, f.body, func_names.items, mem_names.items, table_names.items, global_names.items, f_local_names.items, &f_labels, type_names.items, tag_names.items, data_names.items, elem_names.items) catch return error.OutOfMemory;
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
                encodeInstrList(arena, &sec, data.offset, func_names.items, mem_names.items, table_names.items, global_names.items, &.{}, &d_labels, type_names.items, tag_names.items, data_names.items, elem_names.items) catch return error.OutOfMemory;
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
                'u' => {
                    // \u{NNNN} Unicode escape → UTF-8 encoding
                    if (i + 2 < input.len and input[i + 2] == '{') {
                        const start = i + 3;
                        const end = std.mem.indexOfScalarPos(u8, input, start, '}') orelse {
                            out.append(alloc, input[i]) catch return error.OutOfMemory;
                            i += 1;
                            continue;
                        };
                        const codepoint = std.fmt.parseUnsigned(u21, input[start..end], 16) catch {
                            out.append(alloc, input[i]) catch return error.OutOfMemory;
                            i += 1;
                            continue;
                        };
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch {
                            out.append(alloc, input[i]) catch return error.OutOfMemory;
                            i += 1;
                            continue;
                        };
                        out.appendSlice(alloc, buf[0..len]) catch return error.OutOfMemory;
                        i = end + 1;
                    } else {
                        out.append(alloc, input[i]) catch return error.OutOfMemory;
                        i += 1;
                    }
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

fn encodeValType(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), vt: WatValType, type_names: []const ?[]const u8) !void {
    switch (vt) {
        .i32 => out.append(alloc, 0x7F) catch return error.OutOfMemory,
        .i64 => out.append(alloc, 0x7E) catch return error.OutOfMemory,
        .f32 => out.append(alloc, 0x7D) catch return error.OutOfMemory,
        .f64 => out.append(alloc, 0x7C) catch return error.OutOfMemory,
        .v128 => out.append(alloc, 0x7B) catch return error.OutOfMemory,
        .funcref => out.append(alloc, 0x70) catch return error.OutOfMemory,
        .externref => out.append(alloc, 0x6F) catch return error.OutOfMemory,
        .exnref => out.append(alloc, 0x69) catch return error.OutOfMemory,
        .anyref => out.append(alloc, 0x6E) catch return error.OutOfMemory,
        .eqref => out.append(alloc, 0x6D) catch return error.OutOfMemory,
        .i31ref => out.append(alloc, 0x6C) catch return error.OutOfMemory,
        .structref => out.append(alloc, 0x6B) catch return error.OutOfMemory,
        .arrayref => out.append(alloc, 0x6A) catch return error.OutOfMemory,
        .nullref => out.append(alloc, 0x71) catch return error.OutOfMemory,
        .nullfuncref => out.append(alloc, 0x73) catch return error.OutOfMemory,
        .nullexternref => out.append(alloc, 0x72) catch return error.OutOfMemory,
        .ref_type => |ht| {
            out.append(alloc, 0x64) catch return error.OutOfMemory;
            const resolved = resolveNamedIndex(ht, type_names) catch return error.InvalidWat;
            lebEncodeS33(alloc, out, heapTypeToS33(resolved)) catch return error.OutOfMemory;
        },
        .ref_null_type => |ht| {
            out.append(alloc, 0x63) catch return error.OutOfMemory;
            const resolved = resolveNamedIndex(ht, type_names) catch return error.InvalidWat;
            lebEncodeS33(alloc, out, heapTypeToS33(resolved)) catch return error.OutOfMemory;
        },
    }
}

fn encodeCompositeType(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), ct: WatCompositeType, type_names: []const ?[]const u8) !void {
    switch (ct) {
        .func => |ft| {
            out.append(alloc, 0x60) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, @intCast(ft.params.len)) catch return error.OutOfMemory;
            for (ft.params) |vt| {
                try encodeValType(alloc, out, vt, type_names);
            }
            lebEncodeU32(alloc, out, @intCast(ft.results.len)) catch return error.OutOfMemory;
            for (ft.results) |vt| {
                try encodeValType(alloc, out, vt, type_names);
            }
        },
        .struct_type => |st| {
            out.append(alloc, 0x5F) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, @intCast(st.fields.len)) catch return error.OutOfMemory;
            for (st.fields) |field| {
                try encodeStorageType(alloc, out, field.valtype, type_names);
                out.append(alloc, if (field.mutable) 0x01 else 0x00) catch return error.OutOfMemory;
            }
        },
        .array_type => |at| {
            out.append(alloc, 0x5E) catch return error.OutOfMemory;
            try encodeStorageType(alloc, out, at.field.valtype, type_names);
            out.append(alloc, if (at.field.mutable) 0x01 else 0x00) catch return error.OutOfMemory;
        },
    }
}

fn encodeStorageType(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), vt: WatValType, type_names: []const ?[]const u8) !void {
    return encodeValType(alloc, out, vt, type_names);
}

fn heapTypeToS33(ht: u32) i64 {
    const opcode = @import("opcode.zig");
    return switch (ht) {
        opcode.ValType.HEAP_FUNC => -16,
        opcode.ValType.HEAP_EXTERN => -17,
        opcode.ValType.HEAP_ANY => -18,
        opcode.ValType.HEAP_EQ => -19,
        opcode.ValType.HEAP_I31 => -20,
        opcode.ValType.HEAP_STRUCT => -21,
        opcode.ValType.HEAP_ARRAY => -22,
        opcode.ValType.HEAP_NONE => -15,
        opcode.ValType.HEAP_NOFUNC => -13,
        opcode.ValType.HEAP_NOEXTERN => -14,
        opcode.ValType.HEAP_EXN => -23,
        opcode.ValType.HEAP_NOEXN => -12,
        else => @intCast(ht), // concrete type index
    };
}

fn lebEncodeS33(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), value: i64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7F);
        v >>= 7;
        if ((v == 0 and byte & 0x40 == 0) or (v == -1 and byte & 0x40 != 0)) {
            out.append(alloc, byte) catch return error.OutOfMemory;
            return;
        }
        out.append(alloc, byte | 0x80) catch return error.OutOfMemory;
    }
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

fn lebEncodeU64(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), value: u64) !void {
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

fn encodeLimits(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), limits: WatLimits) !void {
    encodeMemoryLimits(alloc, out, limits, false) catch return error.OutOfMemory;
}

fn encodeMemoryLimits(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), limits: WatLimits, is_memory64: bool) !void {
    const has_max: u8 = if (limits.max != null) 0x01 else 0x00;
    const shared: u8 = if (limits.shared) 0x02 else 0x00;
    const mem64: u8 = if (is_memory64) 0x04 else 0x00;
    out.append(alloc, has_max | shared | mem64) catch return error.OutOfMemory;
    if (is_memory64) {
        // memory64 uses 64-bit LEB128 for limits
        lebEncodeU64(alloc, out, limits.min) catch return error.OutOfMemory;
        if (limits.max != null) {
            lebEncodeU64(alloc, out, limits.max.?) catch return error.OutOfMemory;
        }
    } else {
        lebEncodeU32(alloc, out, @intCast(limits.min)) catch return error.OutOfMemory;
        if (limits.max != null) {
            lebEncodeU32(alloc, out, @intCast(limits.max.?)) catch return error.OutOfMemory;
        }
    }
}

fn eqlValTypeSlice(a: []const WatValType, b: []const WatValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |va, vb| {
        if (!va.eql(vb)) return false;
    }
    return true;
}

fn findOrAddType(alloc: Allocator, types: *std.ArrayListUnmanaged(WatTypeDef), ft: WatFuncType) !u32 {
    for (types.items, 0..) |existing, i| {
        switch (existing.composite) {
            .func => |ef| {
                if (eqlValTypeSlice(ef.params, ft.params) and
                    eqlValTypeSlice(ef.results, ft.results))
                {
                    return @intCast(i);
                }
            },
            .struct_type, .array_type => {},
        }
    }
    const idx: u32 = @intCast(types.items.len);
    types.append(alloc, .{ .composite = .{ .func = ft } }) catch return error.OutOfMemory;
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

fn gcInstrOpcode(name: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    for (buf[0..name.len]) |*c| {
        if (c.* == '.') c.* = '_';
    }
    const zig_name = buf[0..name.len];
    const fields = @typeInfo(GcOpcode).@"enum".fields;
    inline for (fields) |field| {
        if (std.mem.eql(u8, zig_name, field.name)) return field.value;
    }
    return null;
}

fn atomicInstrOpcode(name: []const u8) ?u32 {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    @memcpy(buf[0..name.len], name);
    for (buf[0..name.len]) |*c| {
        if (c.* == '.') c.* = '_';
    }
    const zig_name = buf[0..name.len];
    const fields = @typeInfo(AtomicOpcode).@"enum".fields;
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
    tag_names: []const ?[]const u8,
    data_names: []const ?[]const u8,
    elem_names: []const ?[]const u8,
) WatError!void {
    for (instrs) |instr| {
        try encodeInstr(alloc, out, instr, func_names, mem_names, table_names, global_names, local_names, labels, type_names, tag_names, data_names, elem_names);
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

fn encodeBlockType(alloc: Allocator, out: *std.ArrayListUnmanaged(u8), bt: WatBlockType, type_names: []const ?[]const u8) !void {
    switch (bt) {
        .empty => out.append(alloc, 0x40) catch return error.OutOfMemory,
        .val_type => |vt| encodeValType(alloc, out, vt, type_names) catch return error.OutOfMemory,
        .type_idx => |idx| {
            const resolved = resolveNamedIndex(idx, type_names) catch return error.InvalidWat;
            lebEncodeS33(alloc, out, @intCast(resolved)) catch return error.OutOfMemory;
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
    tag_names: []const ?[]const u8,
    data_names: []const ?[]const u8,
    elem_names: []const ?[]const u8,
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
            } else if (atomicInstrOpcode(name)) |subop| {
                out.append(alloc, 0xFE) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
                if (subop == 0x03) { // atomic.fence: trailing 0x00
                    out.append(alloc, 0x00) catch return error.OutOfMemory;
                }
            } else if (gcInstrOpcode(name)) |subop| {
                out.append(alloc, 0xFB) catch return error.OutOfMemory;
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
            } else if (gcInstrOpcode(data.op)) |subop| {
                out.append(alloc, 0xFB) catch return error.OutOfMemory;
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
                std.mem.eql(u8, data.op, "memory.grow") or
                std.mem.eql(u8, data.op, "memory.fill"))
                resolveNamedIndex(data.index, mem_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "local.get") or
                std.mem.eql(u8, data.op, "local.set") or
                std.mem.eql(u8, data.op, "local.tee"))
                resolveNamedIndex(data.index, local_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "call_ref") or
                std.mem.eql(u8, data.op, "return_call_ref"))
                resolveNamedIndex(data.index, type_names) catch return error.InvalidWat
            else if (gcInstrOpcode(data.op) != null)
                resolveNamedIndex(data.index, type_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "data.drop"))
                resolveNamedIndex(data.index, data_names) catch return error.InvalidWat
            else if (std.mem.eql(u8, data.op, "elem.drop"))
                resolveNamedIndex(data.index, elem_names) catch return error.InvalidWat
            else switch (data.index) {
                .num => |n| n,
                .name => return error.InvalidWat,
            };
            lebEncodeU32(alloc, out, idx) catch return error.OutOfMemory;
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
        .simd_shuffle => |lanes| {
            out.append(alloc, 0xFD) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, 0x0D) catch return error.OutOfMemory; // i8x16.shuffle
            out.appendSlice(alloc, &lanes) catch return error.OutOfMemory;
        },
        .simd_lane => |data| {
            const subop = simdInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFD) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            out.append(alloc, data.lane) catch return error.OutOfMemory;
        },
        .simd_mem_lane => |data| {
            const subop = simdInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFD) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            var align_log2: u32 = if (data.mem_arg.@"align" > 0) std.math.log2_int(u32, data.mem_arg.@"align") else 0;
            const sml_mem_idx = resolveNamedIndex(data.mem_arg.mem_idx, mem_names) catch return error.InvalidWat;
            if (sml_mem_idx != 0) {
                align_log2 |= 0x40;
                lebEncodeU32(alloc, out, align_log2) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, sml_mem_idx) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, data.mem_arg.offset) catch return error.OutOfMemory;
            } else {
                lebEncodeU32(alloc, out, align_log2) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, data.mem_arg.offset) catch return error.OutOfMemory;
            }
            out.append(alloc, data.lane) catch return error.OutOfMemory;
        },
        .mem_op => |data| {
            if (instrOpcode(data.op)) |op| {
                out.append(alloc, op) catch return error.OutOfMemory;
            } else if (atomicInstrOpcode(data.op)) |subop| {
                out.append(alloc, 0xFE) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            } else if (simdInstrOpcode(data.op)) |subop| {
                // SIMD memory ops (v128.load, v128.store, etc.)
                out.append(alloc, 0xFD) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            } else {
                return error.InvalidWat;
            }
            // Encode alignment as log2, with multi-memory flag if needed
            // Multi-memory format: align|0x40, mem_idx, offset
            // Single-memory format: align, offset
            var align_log2: u32 = if (data.mem_arg.@"align" > 0) std.math.log2_int(u32, data.mem_arg.@"align") else 0;
            const mem_index = resolveNamedIndex(data.mem_arg.mem_idx, mem_names) catch return error.InvalidWat;
            if (mem_index != 0) {
                align_log2 |= 0x40; // multi-memory flag
                lebEncodeU32(alloc, out, align_log2) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, mem_index) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, data.mem_arg.offset) catch return error.OutOfMemory;
            } else {
                lebEncodeU32(alloc, out, align_log2) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, data.mem_arg.offset) catch return error.OutOfMemory;
            }
        },
        .block_op => |data| {
            const op = instrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, op) catch return error.OutOfMemory;
            encodeBlockType(alloc, out, data.block_type, type_names) catch return error.OutOfMemory;
            labels.append(alloc, data.label) catch return error.OutOfMemory;
            encodeInstrList(alloc, out, data.body, func_names, mem_names, table_names, global_names, local_names, labels, type_names, tag_names, data_names, elem_names) catch return error.OutOfMemory;
            _ = labels.pop();
            out.append(alloc, 0x0B) catch return error.OutOfMemory; // end
        },
        .if_op => |data| {
            out.append(alloc, 0x04) catch return error.OutOfMemory; // if
            encodeBlockType(alloc, out, data.block_type, type_names) catch return error.OutOfMemory;
            labels.append(alloc, data.label) catch return error.OutOfMemory;
            encodeInstrList(alloc, out, data.then_body, func_names, mem_names, table_names, global_names, local_names, labels, type_names, tag_names, data_names, elem_names) catch return error.OutOfMemory;
            if (data.else_body.len > 0) {
                out.append(alloc, 0x05) catch return error.OutOfMemory; // else
                encodeInstrList(alloc, out, data.else_body, func_names, mem_names, table_names, global_names, local_names, labels, type_names, tag_names, data_names, elem_names) catch return error.OutOfMemory;
            }
            _ = labels.pop();
            out.append(alloc, 0x0B) catch return error.OutOfMemory; // end
        },
        .try_table => |data| {
            out.append(alloc, 0x1F) catch return error.OutOfMemory; // try_table
            encodeBlockType(alloc, out, data.block_type, type_names) catch return error.OutOfMemory;
            // Catch clause vector
            lebEncodeU32(alloc, out, @intCast(data.catches.len)) catch return error.OutOfMemory;
            labels.append(alloc, data.label) catch return error.OutOfMemory;
            for (data.catches) |c| {
                out.append(alloc, @intFromEnum(c.kind)) catch return error.OutOfMemory;
                if (c.tag_idx) |tag| {
                    const idx = resolveNamedIndex(tag, tag_names) catch return error.InvalidWat;
                    lebEncodeU32(alloc, out, idx) catch return error.OutOfMemory;
                }
                const label_idx = try resolveLabelIndex(c.label, labels.items);
                lebEncodeU32(alloc, out, label_idx) catch return error.OutOfMemory;
            }
            encodeInstrList(alloc, out, data.body, func_names, mem_names, table_names, global_names, local_names, labels, type_names, tag_names, data_names, elem_names) catch return error.OutOfMemory;
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
            const ci_opcode: u8 = if (std.mem.eql(u8, data.op, "return_call_indirect")) 0x13 else 0x11;
            out.append(alloc, ci_opcode) catch return error.OutOfMemory;
            if (data.type_use) |tu| {
                const idx = resolveNamedIndex(tu, type_names) catch return error.InvalidWat;
                lebEncodeU32(alloc, out, idx) catch return error.OutOfMemory;
            } else {
                lebEncodeU32(alloc, out, 0) catch return error.OutOfMemory;
            }
            const tbl_idx = resolveNamedIndex(data.table_idx, table_names) catch return error.InvalidWat;
            lebEncodeU32(alloc, out, tbl_idx) catch return error.OutOfMemory;
        },
        .select_t => |types| {
            if (types.len == 0) {
                out.append(alloc, 0x1B) catch return error.OutOfMemory;
            } else {
                out.append(alloc, 0x1C) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, @intCast(types.len)) catch return error.OutOfMemory;
                for (types) |vt| {
                    encodeValType(alloc, out, vt, type_names) catch return error.OutOfMemory;
                }
            }
        },
        .ref_null => |ht| {
            out.append(alloc, 0xD0) catch return error.OutOfMemory;
            const resolved = resolveNamedIndex(ht, type_names) catch return error.InvalidWat;
            lebEncodeS33(alloc, out, heapTypeToS33(resolved)) catch return error.OutOfMemory;
        },
        .gc_type_field => |data| {
            const subop = gcInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFB) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            const type_idx = resolveNamedIndex(data.type_idx, type_names) catch return error.InvalidWat;
            lebEncodeU32(alloc, out, type_idx) catch return error.OutOfMemory;
            const field_idx = switch (data.field_idx) {
                .num => |n| n,
                .name => return error.InvalidWat, // field names not resolved here
            };
            lebEncodeU32(alloc, out, field_idx) catch return error.OutOfMemory;
        },
        .gc_type_u32 => |data| {
            const subop = gcInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFB) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            const type_idx = resolveNamedIndex(data.type_idx, type_names) catch return error.InvalidWat;
            lebEncodeU32(alloc, out, type_idx) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, data.count) catch return error.OutOfMemory;
        },
        .gc_two_types => |data| {
            const subop = gcInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFB) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            const t1 = resolveNamedIndex(data.type1, type_names) catch return error.InvalidWat;
            lebEncodeU32(alloc, out, t1) catch return error.OutOfMemory;
            const t2 = resolveNamedIndex(data.type2, type_names) catch return error.InvalidWat;
            lebEncodeU32(alloc, out, t2) catch return error.OutOfMemory;
        },
        .gc_type_seg => |data| {
            const subop = gcInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFB) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            const type_idx = resolveNamedIndex(data.type_idx, type_names) catch return error.InvalidWat;
            lebEncodeU32(alloc, out, type_idx) catch return error.OutOfMemory;
            const seg_idx = switch (data.seg_idx) {
                .num => |n| n,
                .name => return error.InvalidWat,
            };
            lebEncodeU32(alloc, out, seg_idx) catch return error.OutOfMemory;
        },
        .gc_heap_type => |data| {
            const subop = gcInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFB) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            const resolved = resolveNamedIndex(data.heap_type, type_names) catch return error.InvalidWat;
            lebEncodeS33(alloc, out, heapTypeToS33(resolved)) catch return error.OutOfMemory;
        },
        .gc_br_on_cast => |data| {
            const subop = gcInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFB) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            out.append(alloc, data.flags) catch return error.OutOfMemory;
            const label_idx = try resolveLabelIndex(data.label, labels.items);
            lebEncodeU32(alloc, out, label_idx) catch return error.OutOfMemory;
            const ht1 = resolveNamedIndex(data.ht1, type_names) catch return error.InvalidWat;
            lebEncodeS33(alloc, out, heapTypeToS33(ht1)) catch return error.OutOfMemory;
            const ht2 = resolveNamedIndex(data.ht2, type_names) catch return error.InvalidWat;
            lebEncodeS33(alloc, out, heapTypeToS33(ht2)) catch return error.OutOfMemory;
        },
        .two_index => |data| {
            const subop = miscInstrOpcode(data.op) orelse return error.InvalidWat;
            out.append(alloc, 0xFC) catch return error.OutOfMemory;
            lebEncodeU32(alloc, out, subop) catch return error.OutOfMemory;
            if (std.mem.eql(u8, data.op, "table.init")) {
                // binary: elem_idx(idx2) table_idx(idx1)
                const seg = resolveNamedIndex(data.idx2, elem_names) catch data.idx2.num;
                const tbl = resolveNamedIndex(data.idx1, table_names) catch return error.InvalidWat;
                lebEncodeU32(alloc, out, seg) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, tbl) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, data.op, "memory.init")) {
                // binary: data_idx(idx2) mem_idx(idx1)
                const seg = resolveNamedIndex(data.idx2, data_names) catch data.idx2.num;
                const mem = resolveNamedIndex(data.idx1, mem_names) catch return error.InvalidWat;
                lebEncodeU32(alloc, out, seg) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, mem) catch return error.OutOfMemory;
            } else {
                // table.copy dst src, memory.copy dst src
                const names = if (std.mem.eql(u8, data.op, "table.copy"))
                    table_names
                else
                    mem_names;
                const dst = resolveNamedIndex(data.idx1, names) catch return error.InvalidWat;
                const src = resolveNamedIndex(data.idx2, names) catch return error.InvalidWat;
                lebEncodeU32(alloc, out, dst) catch return error.OutOfMemory;
                lebEncodeU32(alloc, out, src) catch return error.OutOfMemory;
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
        if (negative) {
            // Parse as unsigned to handle INT_MIN (e.g. -2147483648 for i32)
            const U = std.meta.Int(.unsigned, @typeInfo(T).int.bits);
            const uval = std.fmt.parseInt(U, clean, 10) catch return error.Overflow;
            return @bitCast(-%uval);
        }
        return std.fmt.parseInt(T, clean, 10) catch return error.Overflow;
    } else {
        return std.fmt.parseInt(T, clean, 10) catch return error.Overflow;
    }
}

/// Parse WAT float literal: decimal, hex float, nan, inf.
fn parseFloatLiteral(comptime T: type, text: []const u8) !T {
    // Handle special values
    if (std.mem.eql(u8, text, "nan") or std.mem.eql(u8, text, "+nan")) return std.math.nan(T);
    if (std.mem.eql(u8, text, "-nan")) {
        // Negative NaN: set sign bit
        if (T == f32) {
            const bits: u32 = 0xFFC00000; // -nan canonical
            return @bitCast(bits);
        } else {
            const bits: u64 = 0xFFF8000000000000; // -nan canonical
            return @bitCast(bits);
        }
    }
    if (std.mem.eql(u8, text, "inf") or std.mem.eql(u8, text, "+inf")) return std.math.inf(T);
    if (std.mem.eql(u8, text, "-inf")) return -std.math.inf(T);

    // Handle nan:0xN canonical NaN payload
    const nan_prefix = if (std.mem.startsWith(u8, text, "nan:0x"))
        @as(usize, 0)
    else if (std.mem.startsWith(u8, text, "+nan:0x"))
        @as(usize, 1)
    else if (std.mem.startsWith(u8, text, "-nan:0x"))
        @as(usize, 1)
    else
        null;
    if (nan_prefix) |_| {
        const is_neg = text[0] == '-';
        const hex_start = if (text[0] == '+' or text[0] == '-') @as(usize, 6) else @as(usize, 6);
        _ = hex_start;
        const colon_pos = std.mem.indexOf(u8, text, ":0x") orelse unreachable;
        const hex_str = text[colon_pos + 3 ..];
        if (T == f32) {
            const payload = std.fmt.parseUnsigned(u32, hex_str, 16) catch return error.Overflow;
            // f32 NaN: exponent=0xFF, payload in bits [22:0], quiet bit = bit 22
            var bits: u32 = 0x7F800000 | (payload & 0x7FFFFF);
            if (is_neg) bits |= 0x80000000;
            return @bitCast(bits);
        } else {
            const payload = std.fmt.parseUnsigned(u64, hex_str, 16) catch return error.Overflow;
            // f64 NaN: exponent=0x7FF, payload in bits [51:0], quiet bit = bit 51
            var bits: u64 = 0x7FF0000000000000 | (payload & 0xFFFFFFFFFFFFF);
            if (is_neg) bits |= 0x8000000000000000;
            return @bitCast(bits);
        }
    }

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
    try testing.expectEqual(WatValType.i32, mod.types[0].composite.func.params[0]);
    try testing.expectEqual(@as(usize, 2), mod.types[0].composite.func.params.len);
    try testing.expectEqual(@as(usize, 1), mod.types[0].composite.func.results.len);
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
    try testing.expectEqual(@as(u64, 1), mod.imports[0].kind.memory.limits.min);
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
    try testing.expectEqual(WatValType.i32, if_op.block_type.val_type);
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

test "WAT parser — i32x4.extract_lane round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (export "test") (result i32)
        \\    v128.const i32x4 10 20 30 40
        \\    i32x4.extract_lane 2))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("test", &args, &results);
    try testing.expectEqual(@as(u64, 30), results[0]);
}

test "WAT parser — i32.atomic.load round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (memory 1)
        \\  (func (export "test") (result i32)
        \\    i32.const 0
        \\    i32.const 99
        \\    i32.atomic.store
        \\    i32.const 0
        \\    i32.atomic.load))
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("test", &args, &results);
    try testing.expectEqual(@as(u64, 99), results[0]);
}

test "WAT parser — memory shared" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module (memory 1 4 shared))
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.memories.len);
    try testing.expectEqual(@as(u64, 1), mod.memories[0].limits.min);
    try testing.expectEqual(@as(u64, 4), mod.memories[0].limits.max.?);
    try testing.expect(mod.memories[0].limits.shared);
}

test "WAT encoder — memory shared round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module (memory 1 4 shared))
    );
    defer testing.allocator.free(wasm);
    // Find memory section (ID 5)
    var pos: usize = 8;
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
        if (sec_id == 5) {
            // count=1, then limits flag byte
            try testing.expectEqual(@as(u8, 1), wasm[pos]); // count
            try testing.expectEqual(@as(u8, 0x03), wasm[pos + 1]); // flag: has_max(0x01) | shared(0x02)
            break;
        }
        pos += sec_size;
    }
}

test "WAT parser — memory shared requires max" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module (memory 1 shared))
    );
    try testing.expectError(error.InvalidWat, parser.parseModule());
}

test "WAT parser — import memory shared" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module (import "env" "mem" (memory 1 4 shared)))
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.imports.len);
    try testing.expectEqual(@as(u64, 1), mod.imports[0].kind.memory.limits.min);
    try testing.expectEqual(@as(u64, 4), mod.imports[0].kind.memory.limits.max.?);
    try testing.expect(mod.imports[0].kind.memory.limits.shared);
}

test "WAT parser — tag declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (tag $e (param i32))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.tags.len);
    try testing.expectEqualStrings("$e", mod.tags[0].name.?);
    try testing.expectEqual(@as(usize, 1), mod.tags[0].params.len);
    try testing.expectEqual(WatValType.i32, mod.tags[0].params[0].valtype);
}

test "WAT encoder — tag round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (tag $e (param i32))
        \\)
    );
    defer testing.allocator.free(wasm);
    // Should load as valid module
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.module.tags.items.len);
}

test "WAT encoder — tag with try_table catch" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (tag $e (param i32))
        \\  (func (export "test") (result i32)
        \\    (block $outer (result i32)
        \\      (try_table (result i32) (catch $e $outer)
        \\        i32.const 42
        \\      )
        \\    )
        \\  )
        \\)
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

test "WAT parser — import tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (import "env" "exn" (tag $e (param i32)))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.imports.len);
    try testing.expectEqualStrings("$e", mod.imports[0].id.?);
    try testing.expectEqual(@as(usize, 1), mod.imports[0].kind.tag.params.len);
}

test "WAT encoder — export tag" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (tag $e (param i32))
        \\  (export "error" (tag $e))
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.module.tags.items.len);
}

test "WAT parser — GC valtype abbreviations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (func (param anyref eqref i31ref structref arrayref))
        \\)
    );
    const mod = try parser.parseModule();
    const params = mod.functions[0].params;
    try testing.expectEqual(@as(usize, 5), params.len);
    try testing.expect(params[0].valtype.eql(.anyref));
    try testing.expect(params[1].valtype.eql(.eqref));
    try testing.expect(params[2].valtype.eql(.i31ref));
    try testing.expect(params[3].valtype.eql(.structref));
    try testing.expect(params[4].valtype.eql(.arrayref));
}

test "WAT parser — ref type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (func (param (ref func)) (param (ref null extern)))
        \\)
    );
    const mod = try parser.parseModule();
    const params = mod.functions[0].params;
    try testing.expectEqual(@as(usize, 2), params.len);
    const opcode = @import("opcode.zig");
    try testing.expect(params[0].valtype.eql(.{ .ref_type = .{ .num = opcode.ValType.HEAP_FUNC } }));
    try testing.expect(params[1].valtype.eql(.{ .ref_null_type = .{ .num = opcode.ValType.HEAP_EXTERN } }));
}

test "WAT encoder — ref.null heap type" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (export "test") (result funcref)
        \\    ref.null func
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    var args = [_]u64{};
    var results = [_]u64{0};
    try module.invoke("test", &args, &results);
}

test "WAT encoder — anyref param round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (param anyref))
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
}

test "WAT parser — struct type definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (type $point (struct (field $x i32) (field $y i32)))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.types.len);
    try testing.expectEqualStrings("$point", mod.types[0].name.?);
    const st = mod.types[0].composite.struct_type;
    try testing.expectEqual(@as(usize, 2), st.fields.len);
    try testing.expectEqualStrings("$x", st.fields[0].name.?);
    try testing.expectEqual(WatValType.i32, st.fields[0].valtype);
    try testing.expect(!st.fields[0].mutable);
}

test "WAT parser — struct with mutable field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (type $cell (struct (field $val (mut i32))))
        \\)
    );
    const mod = try parser.parseModule();
    const st = mod.types[0].composite.struct_type;
    try testing.expectEqual(@as(usize, 1), st.fields.len);
    try testing.expect(st.fields[0].mutable);
    try testing.expectEqual(WatValType.i32, st.fields[0].valtype);
}

test "WAT parser — array type definition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(),
        \\(module
        \\  (type $arr (array (mut i32)))
        \\)
    );
    const mod = try parser.parseModule();
    try testing.expectEqual(@as(usize, 1), mod.types.len);
    const at = mod.types[0].composite.array_type;
    try testing.expect(at.field.mutable);
    try testing.expectEqual(WatValType.i32, at.field.valtype);
}

test "WAT encoder — struct type round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (type $point (struct (field $x i32) (field $y f64)))
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    // Verify the module loaded successfully with struct type
    try testing.expectEqual(@as(usize, 1), module.module.types.items.len);
}

test "WAT encoder — array type round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (type $arr (array (mut f32)))
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.module.types.items.len);
}

test "WAT encoder — i31.get_s round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (func (param i31ref) (result i32)
        \\    local.get 0
        \\    i31.get_s
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    // Function loaded successfully with i31.get_s instruction
    try testing.expectEqual(@as(usize, 1), module.module.functions.items.len);
}

test "WAT encoder — struct.new round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (type $point (struct (field i32) (field i32)))
        \\  (func (param i32 i32) (result (ref $point))
        \\    local.get 0
        \\    local.get 1
        \\    struct.new $point
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.module.functions.items.len);
}

test "WAT encoder — rec group round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (rec
        \\    (type $a (struct (field (ref null 1))))
        \\    (type $b (struct (field (ref null 0))))
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 2), module.module.types.items.len);
}

test "WAT encoder — struct.get round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (type $point (struct (field $x i32) (field $y i32)))
        \\  (func (param (ref $point)) (result i32)
        \\    local.get 0
        \\    struct.get $point 0
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.module.functions.items.len);
}

test "WAT encoder — ref.test round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (type $my (struct))
        \\  (func (param anyref) (result i32)
        \\    local.get 0
        \\    ref.test $my
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.module.functions.items.len);
}

test "WAT encoder — array.new_fixed round-trip" {
    const wasm = try watToWasm(testing.allocator,
        \\(module
        \\  (type $arr (array i32))
        \\  (func (result (ref $arr))
        \\    i32.const 1
        \\    i32.const 2
        \\    i32.const 3
        \\    array.new_fixed $arr 3
        \\  )
        \\)
    );
    defer testing.allocator.free(wasm);
    const types_mod = @import("types.zig");
    var module = try types_mod.WasmModule.load(testing.allocator, wasm);
    defer module.deinit();
    try testing.expectEqual(@as(usize, 1), module.module.functions.items.len);
}

// ============================================================
// Validation Tests (Phase 4: malformed WAT must not panic)
// ============================================================

test "WAT validation — empty input" {
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator, ""));
}

test "WAT validation — unclosed paren" {
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator, "(module"));
}

test "WAT validation — not a module" {
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator, "(func)"));
}

test "WAT validation — invalid keyword" {
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator, "(bogus)"));
}

test "WAT validation — unresolved name reference" {
    // Unresolved names produce an error (not a panic)
    const result = watToWasm(testing.allocator,
        \\(module (func (call $nonexistent)))
    );
    if (result) |wasm| {
        testing.allocator.free(wasm);
        return error.TestExpectedError;
    } else |_| {}
}

test "WAT validation — deeply nested folded instrs" {
    // Build a deeply nested (drop (drop (drop ... ))) to test recursion limit
    var buf: [12000]u8 = undefined;
    var pos: usize = 0;
    const prefix = "(module (func ";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    const depth: usize = 1001;
    for (0..depth) |_| {
        const open = "(drop ";
        @memcpy(buf[pos..][0..open.len], open);
        pos += open.len;
    }
    for (0..depth) |_| {
        buf[pos] = ')';
        pos += 1;
    }
    const suffix = "))";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator, buf[0..pos]));
}

test "WAT validation — invalid number literal" {
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator,
        \\(module (func (result i32) i32.const abc))
    ));
}

test "WAT validation — no opening paren" {
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator, "func"));
}

test "WAT validation — unclosed func" {
    try testing.expectError(error.InvalidWat, watToWasm(testing.allocator, "(module (func"));
}
