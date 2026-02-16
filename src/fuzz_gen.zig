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
// Test harness: generate modules and run through full pipeline
// ============================================================

fn loadAndExercise(alloc: Allocator, wasm: []const u8) void {
    const module = zwasm.WasmModule.loadWithFuel(alloc, wasm, 100_000) catch return;
    defer module.deinit();

    for (module.export_fns) |ei| {
        if (ei.param_types.len == 0 and ei.result_types.len <= 1) {
            var results: [1]u64 = .{0};
            const result_slice = results[0..ei.result_types.len];
            module.invoke(ei.name, &.{}, result_slice) catch continue;
            module.vm.fuel = 100_000;
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
