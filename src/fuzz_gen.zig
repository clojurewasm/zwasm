// Structure-aware fuzz module generator.
//
// Generates valid-but-tricky WebAssembly modules that exercise corner cases:
// - Deep block nesting (validate/predecode stack pressure)
// - Many locals (regalloc stress near MAX_PHYS_REGS boundary)
// - Unreachable code paths (polymorphic stack)
// - Multi-value blocks
// - Complex control flow (nested loops with br_table)
// - Large type sections
// - Many exports/functions
// - Exception handling patterns
// - Memory operations near boundary
//
// Each generator produces a valid wasm binary that should load without crashing.

const std = @import("std");
const testing = std.testing;
const zwasm = @import("types.zig");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

// ============================================================
// Wasm binary builder helpers
// ============================================================

const WasmBuilder = struct {
    buf: ArrayList(u8),

    fn init(alloc: Allocator) WasmBuilder {
        return .{ .buf = ArrayList(u8).init(alloc) };
    }

    fn deinit(self: *WasmBuilder) void {
        self.buf.deinit();
    }

    fn toOwnedSlice(self: *WasmBuilder) ![]u8 {
        return self.buf.toOwnedSlice();
    }

    fn emit(self: *WasmBuilder, bytes: []const u8) !void {
        try self.buf.appendSlice(bytes);
    }

    fn emitByte(self: *WasmBuilder, byte: u8) !void {
        try self.buf.append(byte);
    }

    fn emitU32Leb(self: *WasmBuilder, value: u32) !void {
        var val = value;
        while (true) {
            const byte: u8 = @truncate(val & 0x7F);
            val >>= 7;
            if (val == 0) {
                try self.buf.append(byte);
                break;
            } else {
                try self.buf.append(byte | 0x80);
            }
        }
    }

    fn emitS32Leb(self: *WasmBuilder, value: i32) !void {
        var val = value;
        while (true) {
            const byte: u8 = @truncate(@as(u32, @bitCast(val)) & 0x7F);
            val >>= 7;
            if ((val == 0 and (byte & 0x40) == 0) or (val == -1 and (byte & 0x40) != 0)) {
                try self.buf.append(byte);
                break;
            } else {
                try self.buf.append(byte | 0x80);
            }
        }
    }

    fn emitS64Leb(self: *WasmBuilder, value: i64) !void {
        var val = value;
        while (true) {
            const byte: u8 = @truncate(@as(u64, @bitCast(val)) & 0x7F);
            val >>= 7;
            if ((val == 0 and (byte & 0x40) == 0) or (val == -1 and (byte & 0x40) != 0)) {
                try self.buf.append(byte);
                break;
            } else {
                try self.buf.append(byte | 0x80);
            }
        }
    }

    // Emit a section: id + length-prefixed content
    fn emitSection(self: *WasmBuilder, id: u8, content: []const u8) !void {
        try self.emitByte(id);
        try self.emitU32Leb(@intCast(content.len));
        try self.emit(content);
    }

    fn emitHeader(self: *WasmBuilder) !void {
        try self.emit(&.{ 0x00, 0x61, 0x73, 0x6d }); // magic
        try self.emit(&.{ 0x01, 0x00, 0x00, 0x00 }); // version
    }
};

// Build a section body into a temporary buffer
fn buildSection(alloc: Allocator, comptime buildFn: anytype, args: anytype) ![]u8 {
    var b = WasmBuilder.init(alloc);
    defer b.deinit();
    try @call(.auto, buildFn, .{&b} ++ args);
    return b.toOwnedSlice();
}

// ============================================================
// Module generators
// ============================================================

/// Generate a module with deeply nested blocks.
fn genDeepNesting(alloc: Allocator, depth: u32) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type section: () -> i32
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 type
            try b.emitByte(0x60); // func
            try b.emitU32Leb(0); // 0 params
            try b.emitU32Leb(1); // 1 result
            try b.emitByte(0x7F); // i32
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    // Function section: 1 function
    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 func
            try b.emitU32Leb(0); // type 0
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    // Export section: export func 0 as "f"
    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 export
            try b.emitU32Leb(1); // name len
            try b.emitByte('f'); // name
            try b.emitByte(0x00); // func
            try b.emitU32Leb(0); // func idx
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code section: deeply nested blocks
    var code_body = WasmBuilder.init(alloc);
    defer code_body.deinit();
    try code_body.emitU32Leb(0); // 0 locals

    // Nest `depth` blocks, each producing i32
    for (0..depth) |_| {
        try code_body.emitByte(0x02); // block
        try code_body.emitByte(0x7F); // result: i32
    }
    // Innermost: i32.const 42
    try code_body.emitByte(0x41); // i32.const
    try code_body.emitS32Leb(42);
    // Close all blocks
    for (0..depth) |_| {
        try code_body.emitByte(0x0B); // end
    }
    try code_body.emitByte(0x0B); // function end

    const body_bytes = try code_body.toOwnedSlice();
    defer alloc.free(body_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1); // 1 function body
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{body_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate a module with many locals (stress regalloc).
fn genManyLocals(alloc: Allocator, local_count: u32) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: () -> i32
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F); // i32
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: declare N locals, use some of them
    var code_body = WasmBuilder.init(alloc);
    defer code_body.deinit();

    // Locals: local_count i32 locals (as 1 entry)
    try code_body.emitU32Leb(1); // 1 local declaration
    try code_body.emitU32Leb(local_count);
    try code_body.emitByte(0x7F); // i32

    // Set each local to its index, then sum a few
    const use_count = @min(local_count, 10);
    for (0..use_count) |i| {
        try code_body.emitByte(0x41); // i32.const
        try code_body.emitS32Leb(@intCast(i));
        try code_body.emitByte(0x21); // local.set
        try code_body.emitU32Leb(@intCast(i));
    }

    // Sum first use_count locals
    try code_body.emitByte(0x41); // i32.const 0 (accumulator)
    try code_body.emitS32Leb(0);
    for (0..use_count) |i| {
        try code_body.emitByte(0x20); // local.get
        try code_body.emitU32Leb(@intCast(i));
        try code_body.emitByte(0x6A); // i32.add
    }

    try code_body.emitByte(0x0B); // end

    const body_bytes = try code_body.toOwnedSlice();
    defer alloc.free(body_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{body_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate a module with unreachable code paths (polymorphic stack).
fn genUnreachableCode(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: () -> i32
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: block with unreachable followed by valid instructions
    // block $b (result i32)
    //   i32.const 1
    //   br $b           ;; branch out of block
    //   unreachable      ;; dead code — polymorphic stack
    //   i32.add          ;; valid after unreachable (type-checks with polymorphic)
    //   drop
    // end
    const code_body: []const u8 = &.{
        0x00, // 0 locals
        0x02, 0x7F, // block (result i32)
        0x41, 0x01, //   i32.const 1
        0x0C, 0x00, //   br 0
        0x00, //   unreachable
        0x6A, //   i32.add (polymorphic stack)
        0x1A, //   drop
        0x0B, // end block
        0x0B, // end func
    };

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{code_body});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate a module with many types (large type section).
fn genManyTypes(alloc: Allocator, count: u32) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type section: `count` func types with varying signatures
    var type_body = WasmBuilder.init(alloc);
    defer type_body.deinit();
    try type_body.emitU32Leb(count);
    for (0..count) |i| {
        try type_body.emitByte(0x60); // func
        const nparams: u32 = @intCast(i % 5);
        try type_body.emitU32Leb(nparams);
        for (0..nparams) |_| {
            try type_body.emitByte(0x7F); // i32
        }
        const nresults: u32 = @intCast(i % 3);
        try type_body.emitU32Leb(nresults);
        for (0..nresults) |_| {
            try type_body.emitByte(0x7F); // i32
        }
    }
    const type_bytes = try type_body.toOwnedSlice();
    defer alloc.free(type_bytes);
    try w.emitSection(1, type_bytes);

    // At least 1 function (type 0 = ()→())
    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    // Code: empty function
    const code_body: []const u8 = &.{ 0x00, 0x0B };
    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{code_body});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate a module with many functions (stress function table/export handling).
fn genManyFunctions(alloc: Allocator, count: u32) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: ()→i32
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    // Function section: all type 0
    var func_body = WasmBuilder.init(alloc);
    defer func_body.deinit();
    try func_body.emitU32Leb(count);
    for (0..count) |_| {
        try func_body.emitU32Leb(0);
    }
    const func_bytes = try func_body.toOwnedSlice();
    defer alloc.free(func_bytes);
    try w.emitSection(3, func_bytes);

    // Export first function
    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: each function returns its index
    var code_content = WasmBuilder.init(alloc);
    defer code_content.deinit();
    try code_content.emitU32Leb(count);
    for (0..count) |i| {
        var body = WasmBuilder.init(alloc);
        defer body.deinit();
        try body.emitU32Leb(0); // 0 locals
        try body.emitByte(0x41); // i32.const
        try body.emitS32Leb(@intCast(i));
        try body.emitByte(0x0B); // end
        const body_bytes = try body.toOwnedSlice();
        defer alloc.free(body_bytes);
        try code_content.emitU32Leb(@intCast(body_bytes.len));
        try code_content.emit(body_bytes);
    }
    const code_bytes = try code_content.toOwnedSlice();
    defer alloc.free(code_bytes);
    try w.emitSection(10, code_bytes);

    return w.toOwnedSlice();
}

/// Generate a module with nested loops and br_table.
fn genBrTable(alloc: Allocator, label_count: u32) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: (i32)→i32
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F); // param: i32
            try b.emitU32Leb(1);
            try b.emitByte(0x7F); // result: i32
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: block wrapping br_table with many labels
    // block $outer (result i32)
    //   block $b0
    //     block $b1
    //       ...
    //         local.get 0
    //         br_table 0 1 2 ... N  (default=0)
    //       end
    //     end
    //   end
    //   i32.const 99
    // end
    var code_body = WasmBuilder.init(alloc);
    defer code_body.deinit();
    try code_body.emitU32Leb(0); // 0 locals

    // Outer block (result i32)
    try code_body.emitByte(0x02); // block
    try code_body.emitByte(0x7F); // result: i32

    // Inner blocks (void)
    for (0..label_count) |_| {
        try code_body.emitByte(0x02); // block
        try code_body.emitByte(0x40); // void
    }

    // br_table
    try code_body.emitByte(0x20); // local.get
    try code_body.emitU32Leb(0); // param 0
    try code_body.emitByte(0x0E); // br_table
    try code_body.emitU32Leb(label_count); // N labels
    for (0..label_count) |i| {
        try code_body.emitU32Leb(@intCast(i)); // label i
    }
    try code_body.emitU32Leb(0); // default label

    // Close inner blocks
    for (0..label_count) |_| {
        try code_body.emitByte(0x0B); // end
    }

    // After blocks: return value
    try code_body.emitByte(0x41); // i32.const
    try code_body.emitS32Leb(99);
    try code_body.emitByte(0x0B); // end outer block
    try code_body.emitByte(0x0B); // end func

    const body_bytes = try code_body.toOwnedSlice();
    defer alloc.free(body_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{body_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate module with memory and boundary operations.
fn genMemoryBoundary(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: ()→i32
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    // Memory: 1 page min, 1 page max
    const mem_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 memory
            try b.emitByte(0x01); // has max
            try b.emitU32Leb(1); // min = 1
            try b.emitU32Leb(1); // max = 1
        }
    }.f, .{});
    defer alloc.free(mem_sec);
    try w.emitSection(5, mem_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: load from boundary offset (64K - 4), store, grow, load again
    const code_body: []const u8 = &.{
        0x00, // 0 locals
        // i32.const 65532 (64K - 4)
        0x41, 0xFC, 0xFF, 0x03,
        // i32.load offset=0 align=2
        0x28, 0x02, 0x00,
        // drop
        0x1A,
        // i32.const 65532
        0x41, 0xFC, 0xFF, 0x03,
        // i32.const 42
        0x41, 0x2A,
        // i32.store offset=0 align=2
        0x36, 0x02, 0x00,
        // memory.size
        0x3F, 0x00,
        // end
        0x0B,
    };

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{code_body});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate module with if/else chains (stress control flow).
fn genIfElseChain(alloc: Allocator, depth: u32) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: (i32)→i32
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: nested if/else
    var code_body = WasmBuilder.init(alloc);
    defer code_body.deinit();
    try code_body.emitU32Leb(0); // 0 locals

    for (0..depth) |_| {
        try code_body.emitByte(0x20); // local.get 0
        try code_body.emitU32Leb(0);
        try code_body.emitByte(0x04); // if (result i32)
        try code_body.emitByte(0x7F);
    }

    // Innermost then: i32.const 1
    try code_body.emitByte(0x41);
    try code_body.emitS32Leb(1);

    // Close ifs with else clauses
    for (0..depth) |i| {
        try code_body.emitByte(0x05); // else
        try code_body.emitByte(0x41); // i32.const
        try code_body.emitS32Leb(@intCast(i + 2));
        try code_body.emitByte(0x0B); // end
    }

    try code_body.emitByte(0x0B); // end func

    const body_bytes = try code_body.toOwnedSlice();
    defer alloc.free(body_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{body_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

// ============================================================
// Feature-specific generators
// ============================================================

/// Generate module with table + funcref elements + call_indirect dispatch.
fn genCallIndirect(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type section: 2 types
    // type 0: () -> i32 (target functions)
    // type 1: (i32) -> i32 (dispatch function)
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(2);
            // type 0: () -> i32
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
            // type 1: (i32) -> i32
            try b.emitByte(0x60);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    // Function section: 3 functions (func0=type0, func1=type0, func2=type1)
    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(3);
            try b.emitU32Leb(0); // func 0: type 0
            try b.emitU32Leb(0); // func 1: type 0
            try b.emitU32Leb(1); // func 2: type 1
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    // Table section: 1 funcref table, min=2
    const table_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 table
            try b.emitByte(0x70); // funcref
            try b.emitByte(0x00); // no max
            try b.emitU32Leb(2); // min = 2
        }
    }.f, .{});
    defer alloc.free(table_sec);
    try w.emitSection(4, table_sec);

    // Export section: export func 2 as "f"
    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1); // name len
            try b.emitByte('f');
            try b.emitByte(0x00); // func
            try b.emitU32Leb(2); // func idx
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Element section: funcref elems [func0, func1] at offset 0
    const elem_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 element segment
            try b.emitByte(0x00); // active, table 0, offset expr
            try b.emitByte(0x41); // i32.const
            try b.emitS32Leb(0); // offset 0
            try b.emitByte(0x0B); // end
            try b.emitU32Leb(2); // 2 func indices
            try b.emitU32Leb(0); // func 0
            try b.emitU32Leb(1); // func 1
        }
    }.f, .{});
    defer alloc.free(elem_sec);
    try w.emitSection(9, elem_sec);

    // Code section: 3 function bodies
    var code_content = WasmBuilder.init(alloc);
    defer code_content.deinit();
    try code_content.emitU32Leb(3);

    // func 0: return 10
    const body0: []const u8 = &.{ 0x00, 0x41, 0x0A, 0x0B }; // 0 locals, i32.const 10, end
    try code_content.emitU32Leb(@intCast(body0.len));
    try code_content.emit(body0);

    // func 1: return 20
    const body1: []const u8 = &.{ 0x00, 0x41, 0x14, 0x0B }; // 0 locals, i32.const 20, end
    try code_content.emitU32Leb(@intCast(body1.len));
    try code_content.emit(body1);

    // func 2 (dispatch): call_indirect(type 0, table 0) with param as index
    const body2: []const u8 = &.{
        0x00, // 0 locals
        0x20, 0x00, // local.get 0 (table index)
        0x11, 0x00, 0x00, // call_indirect type=0 table=0
        0x0B, // end
    };
    try code_content.emitU32Leb(@intCast(body2.len));
    try code_content.emit(body2);

    const code_bytes = try code_content.toOwnedSlice();
    defer alloc.free(code_bytes);
    try w.emitSection(10, code_bytes);

    return w.toOwnedSlice();
}

/// Generate module with bulk memory operations: memory.copy, memory.fill, memory.init, data.drop.
fn genBulkMemory(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: () -> ()
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    // Memory: 1 page
    const mem_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x00); // no max
            try b.emitU32Leb(1); // min = 1
        }
    }.f, .{});
    defer alloc.free(mem_sec);
    try w.emitSection(5, mem_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Data count section (required for memory.init)
    const datacount_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 data segment
        }
    }.f, .{});
    defer alloc.free(datacount_sec);
    try w.emitSection(12, datacount_sec);

    // Code: memory.fill, memory.copy, memory.init, data.drop
    const code_body: []const u8 = &.{
        0x00, // 0 locals
        // memory.fill(dst=0, val=0x42, len=8)
        0x41, 0x00, // i32.const 0 (dst)
        0x41, 0x42, // i32.const 0x42 (val)
        0x41, 0x08, // i32.const 8 (len)
        0xFC, 0x0B, 0x00, // memory.fill mem=0
        // memory.copy(dst=16, src=0, len=8)
        0x41, 0x10, // i32.const 16 (dst)
        0x41, 0x00, // i32.const 0 (src)
        0x41, 0x08, // i32.const 8 (len)
        0xFC, 0x0A, 0x00, 0x00, // memory.copy dst_mem=0 src_mem=0
        // memory.init(dst=32, src_offset=0, len=4) segment=0
        0x41, 0x20, // i32.const 32 (dst)
        0x41, 0x00, // i32.const 0 (src offset)
        0x41, 0x04, // i32.const 4 (len)
        0xFC, 0x08, 0x00, 0x00, // memory.init segment=0 mem=0
        // data.drop segment=0
        0xFC, 0x09, 0x00, // data.drop segment=0
        0x0B, // end
    };

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{code_body});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    // Data section: 1 passive segment with 4 bytes
    const data_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 data segment
            try b.emitByte(0x01); // passive
            try b.emitU32Leb(4); // 4 bytes
            try b.emit(&.{ 0xDE, 0xAD, 0xBE, 0xEF });
        }
    }.f, .{});
    defer alloc.free(data_sec);
    try w.emitSection(11, data_sec);

    return w.toOwnedSlice();
}

/// Generate module with multi-value returns (2-4 values).
fn genMultiValue(alloc: Allocator, result_count: u32) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: () -> (i32, i32, ...) with result_count results
    var type_body = WasmBuilder.init(alloc);
    defer type_body.deinit();
    try type_body.emitU32Leb(1);
    try type_body.emitByte(0x60);
    try type_body.emitU32Leb(0);
    try type_body.emitU32Leb(result_count);
    for (0..result_count) |_| {
        try type_body.emitByte(0x7F); // i32
    }
    const type_bytes = try type_body.toOwnedSlice();
    defer alloc.free(type_bytes);
    try w.emitSection(1, type_bytes);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: push result_count i32 constants
    var code_body = WasmBuilder.init(alloc);
    defer code_body.deinit();
    try code_body.emitU32Leb(0); // 0 locals
    for (0..result_count) |i| {
        try code_body.emitByte(0x41); // i32.const
        try code_body.emitS32Leb(@intCast(i + 1));
    }
    try code_body.emitByte(0x0B); // end

    const body_bytes = try code_body.toOwnedSlice();
    defer alloc.free(body_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{body_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate module with return_call + return_call_indirect chains.
fn genTailCall(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type section: 2 types
    // type 0: (i32) -> i32 (leaf and recursive)
    // type 1: (i32) -> i32 (dispatch via return_call_indirect)
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            // type 0: (i32) -> i32
            try b.emitByte(0x60);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    // Function section: 3 functions, all type 0
    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(3);
            try b.emitU32Leb(0);
            try b.emitU32Leb(0);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    // Table section: 1 funcref table, min=2
    const table_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x70); // funcref
            try b.emitByte(0x00); // no max
            try b.emitU32Leb(2); // min
        }
    }.f, .{});
    defer alloc.free(table_sec);
    try w.emitSection(4, table_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(2); // export func 2
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Element section: [func0, func1] at table offset 0
    const elem_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x00); // active, table 0
            try b.emitByte(0x41); // i32.const
            try b.emitS32Leb(0);
            try b.emitByte(0x0B); // end
            try b.emitU32Leb(2);
            try b.emitU32Leb(0); // func 0
            try b.emitU32Leb(1); // func 1
        }
    }.f, .{});
    defer alloc.free(elem_sec);
    try w.emitSection(9, elem_sec);

    // Code section
    var code_content = WasmBuilder.init(alloc);
    defer code_content.deinit();
    try code_content.emitU32Leb(3);

    // func 0 (leaf): if param <= 0 then return param, else return_call func1(param - 1)
    const body0: []const u8 = &.{
        0x00, // 0 locals
        0x20, 0x00, // local.get 0
        0x41, 0x01, // i32.const 1
        0x48, // i32.lt_s
        0x04, 0x7F, // if (result i32)
        0x20, 0x00, // local.get 0
        0x05, // else
        0x20, 0x00, // local.get 0
        0x41, 0x01, // i32.const 1
        0x6B, // i32.sub
        0x12, 0x01, // return_call func 1
        0x0B, // end if
        0x0B, // end func
    };
    try code_content.emitU32Leb(@intCast(body0.len));
    try code_content.emit(body0);

    // func 1 (relay): return_call func0(param)
    const body1: []const u8 = &.{
        0x00, // 0 locals
        0x20, 0x00, // local.get 0
        0x12, 0x00, // return_call func 0
        0x0B, // end
    };
    try code_content.emitU32Leb(@intCast(body1.len));
    try code_content.emit(body1);

    // func 2 (dispatch): return_call_indirect via table
    // Clamp index to 0..1 range to avoid trap, then return_call_indirect
    const body2: []const u8 = &.{
        0x00, // 0 locals
        0x20, 0x00, // local.get 0 (will be passed as arg)
        0x41, 0x00, // i32.const 0 (table index)
        0x13, 0x00, 0x00, // return_call_indirect type=0 table=0
        0x0B, // end
    };
    try code_content.emitU32Leb(@intCast(body2.len));
    try code_content.emit(body2);

    const code_bytes = try code_content.toOwnedSlice();
    defer alloc.free(code_bytes);
    try w.emitSection(10, code_bytes);

    return w.toOwnedSlice();
}

/// Generate module with basic SIMD: v128.const, i32x4.add, v128 load/store.
fn genSimdBasic(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: () -> ()
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    // Memory: 1 page (needed for v128 load/store)
    const mem_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x00);
            try b.emitU32Leb(1);
        }
    }.f, .{});
    defer alloc.free(mem_sec);
    try w.emitSection(5, mem_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: v128.const + v128.const + i32x4.add + v128.store
    const code_body: []const u8 = &.{
        0x00, // 0 locals
        // v128.const [1,2,3,4] as i32x4
        0xFD, 0x0C,
        0x01, 0x00, 0x00, 0x00, // 1
        0x02, 0x00, 0x00, 0x00, // 2
        0x03, 0x00, 0x00, 0x00, // 3
        0x04, 0x00, 0x00, 0x00, // 4
        // v128.const [10,20,30,40] as i32x4
        0xFD, 0x0C,
        0x0A, 0x00, 0x00, 0x00, // 10
        0x14, 0x00, 0x00, 0x00, // 20
        0x1E, 0x00, 0x00, 0x00, // 30
        0x28, 0x00, 0x00, 0x00, // 40
        // i32x4.add
        0xFD, 0xAE, 0x01,
        // i32.const 0 (store address)
        0x41, 0x00,
        // v128.store offset=0 align=4 (swap: addr must be under value on stack)
        // Actually v128.store expects [addr, v128] — need to reorder.
        // Let me fix: push addr first, then the v128 value
    };
    // The above has a stack ordering issue. Let me build it properly.
    _ = code_body;

    var cb = WasmBuilder.init(alloc);
    defer cb.deinit();
    try cb.emitU32Leb(0); // 0 locals

    // Store address first for v128.store
    try cb.emitByte(0x41); // i32.const 0
    try cb.emitS32Leb(0);

    // v128.const [1,2,3,4]
    try cb.emitByte(0xFD);
    try cb.emitU32Leb(0x0C); // v128.const
    try cb.emit(&.{
        0x01, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00,
        0x04, 0x00, 0x00, 0x00,
    });

    // v128.const [10,20,30,40]
    try cb.emitByte(0xFD);
    try cb.emitU32Leb(0x0C); // v128.const
    try cb.emit(&.{
        0x0A, 0x00, 0x00, 0x00,
        0x14, 0x00, 0x00, 0x00,
        0x1E, 0x00, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00,
    });

    // i32x4.add (0xFD 0xAE 0x01)
    try cb.emitByte(0xFD);
    try cb.emitU32Leb(0xAE); // i32x4.add

    // v128.store align=4 offset=0 (stack: [addr, v128])
    try cb.emitByte(0xFD);
    try cb.emitU32Leb(0x0B); // v128.store
    try cb.emitByte(0x04); // align = 2^4 = 16
    try cb.emitU32Leb(0); // offset

    // v128.load from 0 and drop
    try cb.emitByte(0x41); // i32.const 0
    try cb.emitS32Leb(0);
    try cb.emitByte(0xFD);
    try cb.emitU32Leb(0x00); // v128.load
    try cb.emitByte(0x04); // align
    try cb.emitU32Leb(0); // offset
    try cb.emitByte(0x1A); // drop

    try cb.emitByte(0x0B); // end

    const cb_bytes = try cb.toOwnedSlice();
    defer alloc.free(cb_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{cb_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate module with GC struct type: struct.new + struct.get + struct.set.
fn genGcStruct(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type section: struct type (2 fields: i32 mutable, i64 mutable) + func type
    var type_body = WasmBuilder.init(alloc);
    defer type_body.deinit();
    try type_body.emitU32Leb(2); // 2 types

    // type 0: struct { field0: i32 mut, field1: i64 mut }
    try type_body.emitByte(0x5F); // struct
    try type_body.emitU32Leb(2); // 2 fields
    try type_body.emitByte(0x7F); // i32
    try type_body.emitByte(0x01); // mutable
    try type_body.emitByte(0x7E); // i64
    try type_body.emitByte(0x01); // mutable

    // type 1: () -> i32
    try type_body.emitByte(0x60); // func
    try type_body.emitU32Leb(0);
    try type_body.emitU32Leb(1);
    try type_body.emitByte(0x7F); // i32

    const type_bytes = try type_body.toOwnedSlice();
    defer alloc.free(type_bytes);
    try w.emitSection(1, type_bytes);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1); // type 1
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: struct.new, struct.set, struct.get
    var cb = WasmBuilder.init(alloc);
    defer cb.deinit();
    try cb.emitU32Leb(0); // 0 locals

    // struct.new type=0 (push field values: i32, i64)
    try cb.emitByte(0x41); // i32.const 42
    try cb.emitS32Leb(42);
    try cb.emitByte(0x42); // i64.const 100
    try cb.emitS64Leb(100);
    try cb.emitByte(0xFB); // GC prefix
    try cb.emitU32Leb(0x00); // struct.new
    try cb.emitU32Leb(0); // type idx 0

    // struct.set type=0 field=0 (set field 0 to 99)
    try cb.emitByte(0x41); // i32.const 99
    try cb.emitS32Leb(99);
    try cb.emitByte(0xFB);
    try cb.emitU32Leb(0x05); // struct.set
    try cb.emitU32Leb(0); // type idx
    try cb.emitU32Leb(0); // field idx

    // struct.get type=0 field=0 -> i32 (return value)
    try cb.emitByte(0xFB);
    try cb.emitU32Leb(0x02); // struct.get
    try cb.emitU32Leb(0); // type idx
    try cb.emitU32Leb(0); // field idx

    try cb.emitByte(0x0B); // end

    const cb_bytes = try cb.toOwnedSlice();
    defer alloc.free(cb_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{cb_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate module with GC array type: array.new + array.get + array.set + array.len.
fn genGcArray(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type section: array type (i32 mutable) + func type
    var type_body = WasmBuilder.init(alloc);
    defer type_body.deinit();
    try type_body.emitU32Leb(2); // 2 types

    // type 0: array (field: i32 mutable)
    try type_body.emitByte(0x5E); // array
    try type_body.emitByte(0x7F); // i32
    try type_body.emitByte(0x01); // mutable

    // type 1: () -> i32
    try type_body.emitByte(0x60); // func
    try type_body.emitU32Leb(0);
    try type_body.emitU32Leb(1);
    try type_body.emitByte(0x7F); // i32

    const type_bytes = try type_body.toOwnedSlice();
    defer alloc.free(type_bytes);
    try w.emitSection(1, type_bytes);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1); // type 1
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: array.new_default, array.set, array.get, array.len
    var cb = WasmBuilder.init(alloc);
    defer cb.deinit();
    try cb.emitU32Leb(0); // 0 locals

    // array.new_default type=0 len=4
    try cb.emitByte(0x41); // i32.const 4 (length)
    try cb.emitS32Leb(4);
    try cb.emitByte(0xFB);
    try cb.emitU32Leb(0x07); // array.new_default
    try cb.emitU32Leb(0); // type idx

    // array.set type=0 idx=0 val=42 (need: arrayref, idx, val)
    // Stack has arrayref. Need to duplicate it for later use. No dup in wasm, so use local.
    // Actually, we don't have locals. Let's restructure: create array, set, get, return len.
    // We need the ref multiple times. Let's add a local for (ref type 0).

    // Restart with 1 local
    cb.buf.clearRetainingCapacity();
    try cb.emitU32Leb(1); // 1 local declaration
    try cb.emitU32Leb(1); // count=1
    // local type: (ref 0) — nullable ref to type 0
    try cb.emitByte(0x63); // ref null
    try cb.emitU32Leb(0); // type idx 0

    // array.new_default type=0 len=4
    try cb.emitByte(0x41); // i32.const 4
    try cb.emitS32Leb(4);
    try cb.emitByte(0xFB);
    try cb.emitU32Leb(0x07); // array.new_default
    try cb.emitU32Leb(0);
    // local.set 0 (save ref)
    try cb.emitByte(0x21); // local.set
    try cb.emitU32Leb(0);

    // array.set type=0: [ref, idx, val]
    try cb.emitByte(0x20); // local.get 0
    try cb.emitU32Leb(0);
    try cb.emitByte(0x41); // i32.const 0 (index)
    try cb.emitS32Leb(0);
    try cb.emitByte(0x41); // i32.const 42 (value)
    try cb.emitS32Leb(42);
    try cb.emitByte(0xFB);
    try cb.emitU32Leb(0x0E); // array.set
    try cb.emitU32Leb(0);

    // array.get type=0: [ref, idx] -> i32
    try cb.emitByte(0x20); // local.get 0
    try cb.emitU32Leb(0);
    try cb.emitByte(0x41); // i32.const 0
    try cb.emitS32Leb(0);
    try cb.emitByte(0xFB);
    try cb.emitU32Leb(0x0B); // array.get
    try cb.emitU32Leb(0);
    try cb.emitByte(0x1A); // drop

    // array.len: [ref] -> i32
    try cb.emitByte(0x20); // local.get 0
    try cb.emitU32Leb(0);
    try cb.emitByte(0xFB);
    try cb.emitU32Leb(0x0F); // array.len

    try cb.emitByte(0x0B); // end

    const cb_bytes = try cb.toOwnedSlice();
    defer alloc.free(cb_bytes);

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{cb_bytes});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

/// Generate module with exception handling: tag + throw + try_table with catch.
fn genExceptionHandling(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type section: 2 types
    // type 0: (i32) -> () — tag signature
    // type 1: () -> i32 — exported function
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(2);
            // type 0: (i32) -> ()
            try b.emitByte(0x60);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
            try b.emitU32Leb(0);
            // type 1: () -> i32
            try b.emitByte(0x60);
            try b.emitU32Leb(0);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F);
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(2);
            try b.emitU32Leb(1); // func 0: type 1
            try b.emitU32Leb(1); // func 1: type 1
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Tag section: 1 tag, type 0
    const tag_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1); // 1 tag
            try b.emitByte(0x00); // attribute: exception
            try b.emitU32Leb(0); // type index 0
        }
    }.f, .{});
    defer alloc.free(tag_sec);
    try w.emitSection(13, tag_sec);

    // Code section: 2 functions
    var code_content = WasmBuilder.init(alloc);
    defer code_content.deinit();
    try code_content.emitU32Leb(2);

    // func 0: try_table catches exception, returns caught value
    // block $catch (result i32)
    //   try_table (result i32) (catch tag=0 $catch)
    //     call func1     ;; throws
    //     i32.const -1   ;; unreachable
    //   end
    // end
    const body0: []const u8 = &.{
        0x00, // 0 locals
        0x02, 0x7F, // block (result i32) — catch target
        0x1F, // try_table
        0x7F, // result i32
        0x01, // 1 catch clause
        0x00, // catch kind=0 (catch with tag)
        0x00, // tag index 0
        0x01, // branch label depth 1 (to outer block)
        0x10, 0x01, // call func 1
        0x41, 0x7F, // i32.const -1 (fallthrough if no throw)
        0x0B, // end try_table
        0x0B, // end block
        0x0B, // end func
    };
    try code_content.emitU32Leb(@intCast(body0.len));
    try code_content.emit(body0);

    // func 1: throw tag 0 with value 99
    const body1: []const u8 = &.{
        0x00, // 0 locals
        0x41, 0x63, // i32.const 99
        0x08, 0x00, // throw tag=0
        0x41, 0x00, // i32.const 0 (unreachable, for type checking)
        0x0B, // end
    };
    try code_content.emitU32Leb(@intCast(body1.len));
    try code_content.emit(body1);

    const code_bytes = try code_content.toOwnedSlice();
    defer alloc.free(code_bytes);
    try w.emitSection(10, code_bytes);

    return w.toOwnedSlice();
}

/// Generate module with typed select (select t) for different value types.
fn genSelect(alloc: Allocator) ![]u8 {
    var w = WasmBuilder.init(alloc);
    defer w.deinit();
    try w.emitHeader();

    // Type: (i32) -> i64 (demonstrate typed select with i64)
    const type_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitByte(0x60);
            try b.emitU32Leb(1);
            try b.emitByte(0x7F); // param: i32 (condition)
            try b.emitU32Leb(1);
            try b.emitByte(0x7E); // result: i64
        }
    }.f, .{});
    defer alloc.free(type_sec);
    try w.emitSection(1, type_sec);

    const func_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(func_sec);
    try w.emitSection(3, func_sec);

    const export_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(1);
            try b.emitByte('f');
            try b.emitByte(0x00);
            try b.emitU32Leb(0);
        }
    }.f, .{});
    defer alloc.free(export_sec);
    try w.emitSection(7, export_sec);

    // Code: i64.const 100, i64.const 200, local.get 0 (condition), select (t i64)
    const code_body: []const u8 = &.{
        0x00, // 0 locals
        0x42, 0xE4, 0x00, // i64.const 100
        0x42, 0xC8, 0x01, // i64.const 200
        0x20, 0x00, // local.get 0 (condition)
        0x1C, 0x01, 0x7E, // select (t i64) — 1 type, i64
        0x0B, // end
    };

    const code_sec = try buildSection(alloc, struct {
        fn f(b: *WasmBuilder, body: []const u8) !void {
            try b.emitU32Leb(1);
            try b.emitU32Leb(@intCast(body.len));
            try b.emit(body);
        }
    }.f, .{code_body});
    defer alloc.free(code_sec);
    try w.emitSection(10, code_sec);

    return w.toOwnedSlice();
}

// ============================================================
// Test harness: generate modules and run through full pipeline
// ============================================================

const FUZZ_FUEL: u64 = 100_000;
const FUZZ_JIT_CALLS: u32 = 4; // HOT_THRESHOLD(3) + 1
const FUZZ_MAX_ARGS: usize = 8;
const FUZZ_MAX_RESULTS: usize = 8;

fn loadAndExercise(alloc: Allocator, wasm: []const u8) void {
    const module = zwasm.WasmModule.loadWithFuel(alloc, wasm, FUZZ_FUEL) catch return;
    defer module.deinit();

    for (module.export_fns) |ei| {
        const nparams = ei.param_types.len;
        const nresults = ei.result_types.len;
        if (nparams > FUZZ_MAX_ARGS or nresults > FUZZ_MAX_RESULTS) continue;

        // Synthesize deterministic args (zeros)
        var args: [FUZZ_MAX_ARGS]u64 = .{0} ** FUZZ_MAX_ARGS;
        const arg_slice = args[0..nparams];
        var results: [FUZZ_MAX_RESULTS]u64 = .{0} ** FUZZ_MAX_RESULTS;
        const result_slice = results[0..nresults];

        // Call multiple times to trigger JIT compilation
        for (0..FUZZ_JIT_CALLS) |_| {
            module.vm.fuel = FUZZ_FUEL;
            module.invoke(ei.name, arg_slice, result_slice) catch break;
        }
    }
}

test "fuzz-gen — deep nesting (10, 50, 100, 200)" {
    const alloc = testing.allocator;
    for ([_]u32{ 10, 50, 100, 200 }) |depth| {
        const wasm = try genDeepNesting(alloc, depth);
        defer alloc.free(wasm);
        loadAndExercise(alloc, wasm);
    }
}

test "fuzz-gen — many locals (1, 10, 20, 50, 100, 500)" {
    const alloc = testing.allocator;
    for ([_]u32{ 1, 10, 20, 50, 100, 500 }) |count| {
        const wasm = try genManyLocals(alloc, count);
        defer alloc.free(wasm);
        loadAndExercise(alloc, wasm);
    }
}

test "fuzz-gen — unreachable code paths" {
    const alloc = testing.allocator;
    const wasm = try genUnreachableCode(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — many types (10, 100, 500)" {
    const alloc = testing.allocator;
    for ([_]u32{ 10, 100, 500 }) |count| {
        const wasm = try genManyTypes(alloc, count);
        defer alloc.free(wasm);
        loadAndExercise(alloc, wasm);
    }
}

test "fuzz-gen — many functions (10, 100, 500)" {
    const alloc = testing.allocator;
    for ([_]u32{ 10, 100, 500 }) |count| {
        const wasm = try genManyFunctions(alloc, count);
        defer alloc.free(wasm);
        loadAndExercise(alloc, wasm);
    }
}

test "fuzz-gen — br_table (5, 20, 100)" {
    const alloc = testing.allocator;
    for ([_]u32{ 5, 20, 100 }) |count| {
        const wasm = try genBrTable(alloc, count);
        defer alloc.free(wasm);
        loadAndExercise(alloc, wasm);
    }
}

test "fuzz-gen — memory boundary operations" {
    const alloc = testing.allocator;
    const wasm = try genMemoryBoundary(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — if/else chain (5, 20, 50, 100)" {
    const alloc = testing.allocator;
    for ([_]u32{ 5, 20, 50, 100 }) |depth| {
        const wasm = try genIfElseChain(alloc, depth);
        defer alloc.free(wasm);
        loadAndExercise(alloc, wasm);
    }
}

test "fuzz-gen — call_indirect dispatch" {
    const alloc = testing.allocator;
    const wasm = try genCallIndirect(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — bulk memory operations" {
    const alloc = testing.allocator;
    const wasm = try genBulkMemory(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — multi-value returns (2, 3, 4)" {
    const alloc = testing.allocator;
    for ([_]u32{ 2, 3, 4 }) |count| {
        const wasm = try genMultiValue(alloc, count);
        defer alloc.free(wasm);
        loadAndExercise(alloc, wasm);
    }
}

test "fuzz-gen — tail call chains" {
    const alloc = testing.allocator;
    const wasm = try genTailCall(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — SIMD basic operations" {
    const alloc = testing.allocator;
    const wasm = try genSimdBasic(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — GC struct operations" {
    const alloc = testing.allocator;
    const wasm = try genGcStruct(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — GC array operations" {
    const alloc = testing.allocator;
    const wasm = try genGcArray(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — exception handling" {
    const alloc = testing.allocator;
    const wasm = try genExceptionHandling(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

test "fuzz-gen — typed select" {
    const alloc = testing.allocator;
    const wasm = try genSelect(alloc);
    defer alloc.free(wasm);
    loadAndExercise(alloc, wasm);
}

// ============================================================
// Phase-separate fuzz tests
//
// Each test targets a single pipeline stage with arbitrary input,
// verifying that stage never panics regardless of input quality.
// ============================================================

const module_mod = @import("module.zig");
const Module = module_mod.Module;
const validate_mod = @import("validate.zig");
const predecode_mod = @import("predecode.zig");
const regalloc_mod = @import("regalloc.zig");

// Corpus of valid function bodies (bytecode between locals and end).
// Used as seeds for predecode and regalloc fuzz tests.
const body_corpus = &[_][]const u8{
    // Empty body (just end)
    &.{0x0B},
    // nop + end
    &.{ 0x01, 0x0B },
    // i32.const 0 + end
    &.{ 0x41, 0x00, 0x0B },
    // i32.const 0 + drop + end
    &.{ 0x41, 0x00, 0x1A, 0x0B },
    // block (void) + end + end
    &.{ 0x02, 0x40, 0x0B, 0x0B },
    // loop (void) + end + end
    &.{ 0x03, 0x40, 0x0B, 0x0B },
    // if (void) + end + end
    &.{ 0x41, 0x01, 0x04, 0x40, 0x0B, 0x0B },
    // block, i32.const, br 0, end
    &.{ 0x02, 0x40, 0x41, 0x00, 0x1A, 0x0C, 0x00, 0x0B, 0x0B },
    // local.get 0 + local.set 0 + end (requires 1 local)
    &.{ 0x20, 0x00, 0x21, 0x00, 0x0B },
    // i32.const 1 + i32.const 2 + i32.add + drop + end
    &.{ 0x41, 0x01, 0x41, 0x02, 0x6A, 0x1A, 0x0B },
    // Nested blocks: block { block { nop } } end
    &.{ 0x02, 0x40, 0x02, 0x40, 0x01, 0x0B, 0x0B, 0x0B },
    // i32.const 1 + if (i32) + i32.const 2 + else + i32.const 3 + end + drop + end
    &.{ 0x41, 0x01, 0x04, 0x7F, 0x41, 0x02, 0x05, 0x41, 0x03, 0x0B, 0x1A, 0x0B },
};

test "fuzz-phase — decoder does not panic on arbitrary bytes" {
    const Ctx = struct { corpus: []const []const u8 };
    try std.testing.fuzz(
        Ctx{ .corpus = module_mod.fuzz_corpus },
        struct {
            fn f(_: Ctx, input: []const u8) anyerror!void {
                var m = Module.init(testing.allocator, input);
                defer m.deinit();
                m.decode() catch return;
            }
        }.f,
        .{},
    );
}

test "fuzz-phase — validator does not panic on decoded modules" {
    const Ctx = struct { corpus: []const []const u8 };
    try std.testing.fuzz(
        Ctx{ .corpus = module_mod.fuzz_corpus },
        struct {
            fn f(_: Ctx, input: []const u8) anyerror!void {
                var m = Module.init(testing.allocator, input);
                defer m.deinit();
                m.decode() catch return;
                validate_mod.validateModule(testing.allocator, &m) catch return;
            }
        }.f,
        .{},
    );
}

test "fuzz-phase — predecode does not panic on arbitrary bytecode" {
    const Ctx = struct { corpus: []const []const u8 };
    try std.testing.fuzz(
        Ctx{ .corpus = body_corpus },
        struct {
            fn f(_: Ctx, input: []const u8) anyerror!void {
                const ir = predecode_mod.predecode(testing.allocator, input) catch return;
                if (ir) |func| {
                    func.deinit();
                    testing.allocator.destroy(func);
                }
            }
        }.f,
        .{},
    );
}

test "fuzz-phase — regalloc does not panic on predecoded IR" {
    const Ctx = struct { corpus: []const []const u8 };
    try std.testing.fuzz(
        Ctx{ .corpus = body_corpus },
        struct {
            fn f(_: Ctx, input: []const u8) anyerror!void {
                const ir = predecode_mod.predecode(testing.allocator, input) catch return;
                const func = ir orelse return;
                defer {
                    func.deinit();
                    testing.allocator.destroy(func);
                }

                const reg = regalloc_mod.convert(
                    testing.allocator,
                    func.code,
                    func.pool64,
                    0, // param_count
                    0, // local_count
                    1, // result_count
                    null, // resolver
                ) catch return;
                if (reg) |rf| {
                    rf.deinit();
                    testing.allocator.destroy(rf);
                }
            }
        }.f,
        .{},
    );
}
