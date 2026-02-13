// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Wasm module instance — instantiation, import resolution, and invoke API.
//!
//! Links a decoded Module with a Store, resolving imports, allocating memories/
//! tables/globals, applying data/element initializers, and running start fn.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const wasi_mod = @import("wasi.zig");
pub const WasiContext = wasi_mod.WasiContext;
const WasmMemory = @import("memory.zig").Memory;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const gc_mod = @import("gc.zig");

pub const Instance = struct {
    alloc: Allocator,
    module: *const Module,
    store: *Store,

    // Address mappings — module-local indices → store addresses
    funcaddrs: ArrayList(usize),
    memaddrs: ArrayList(usize),
    tableaddrs: ArrayList(usize),
    globaladdrs: ArrayList(usize),
    elemaddrs: ArrayList(usize),
    dataaddrs: ArrayList(usize),
    tagaddrs: ArrayList(usize),

    // WASI context (optional, set before instantiate for WASI modules)
    wasi: ?*WasiContext = null,

    pub fn init(alloc: Allocator, store: *Store, module: *const Module) Instance {
        return .{
            .alloc = alloc,
            .module = module,
            .store = store,
            .funcaddrs = .empty,
            .memaddrs = .empty,
            .tableaddrs = .empty,
            .globaladdrs = .empty,
            .elemaddrs = .empty,
            .dataaddrs = .empty,
            .tagaddrs = .empty,
        };
    }

    pub fn deinit(self: *Instance) void {
        self.funcaddrs.deinit(self.alloc);
        self.memaddrs.deinit(self.alloc);
        self.tableaddrs.deinit(self.alloc);
        self.globaladdrs.deinit(self.alloc);
        self.elemaddrs.deinit(self.alloc);
        self.dataaddrs.deinit(self.alloc);
        self.tagaddrs.deinit(self.alloc);
    }

    pub fn instantiate(self: *Instance) !void {
        if (!self.module.decoded) return error.ModuleNotDecoded;

        try self.resolveImports();
        try self.instantiateFunctions();
        try self.instantiateMemories();
        try self.instantiateTables();
        try self.instantiateGlobals();
        try self.instantiateTags();
        try self.instantiateElems();
        try self.instantiateData();
        try self.applyActiveElements();
        try self.applyActiveData();

        // Start function is deferred — needs VM (35W.6)
    }

    // ---- Lookup helpers ----

    pub fn getFunc(self: *Instance, idx: usize) !store_mod.Function {
        if (idx >= self.funcaddrs.items.len) return error.FunctionIndexOutOfBounds;
        return self.store.getFunction(self.funcaddrs.items[idx]);
    }

    pub fn getFuncPtr(self: *Instance, idx: usize) !*store_mod.Function {
        if (idx >= self.funcaddrs.items.len) return error.FunctionIndexOutOfBounds;
        return self.store.getFunctionPtr(self.funcaddrs.items[idx]);
    }

    pub fn getMemory(self: *Instance, idx: usize) !*WasmMemory {
        if (idx >= self.memaddrs.items.len) return error.MemoryIndexOutOfBounds;
        return self.store.getMemory(self.memaddrs.items[idx]);
    }

    pub fn getTable(self: *Instance, idx: usize) !*store_mod.Table {
        if (idx >= self.tableaddrs.items.len) return error.TableIndexOutOfBounds;
        return self.store.getTable(self.tableaddrs.items[idx]);
    }

    /// Get the number of fields for a struct type (from module type section).
    pub fn getStructFieldCount(self: *const Instance, type_idx: u32) usize {
        if (type_idx < self.module.types.items.len) {
            switch (self.module.types.items[type_idx].composite) {
                .struct_type => |st| return st.fields.len,
                else => return 0,
            }
        }
        return 0;
    }

    pub fn getGlobal(self: *Instance, idx: usize) !*store_mod.Global {
        if (idx >= self.globaladdrs.items.len) return error.GlobalIndexOutOfBounds;
        return self.store.getGlobal(self.globaladdrs.items[idx]);
    }

    // ---- Export lookup ----

    /// Find an exported function's store address by name.
    pub fn getExportFunc(self: *const Instance, name: []const u8) ?usize {
        const idx = self.module.getExport(name, .func) orelse return null;
        if (idx >= self.funcaddrs.items.len) return null;
        return self.funcaddrs.items[idx];
    }

    /// Find the exported memory by index (usually 0).
    pub fn getExportMemory(self: *Instance, name: []const u8) ?*WasmMemory {
        const idx = self.module.getExport(name, .memory) orelse return null;
        if (idx >= self.memaddrs.items.len) return null;
        return self.store.getMemory(self.memaddrs.items[idx]) catch null;
    }

    /// Find an exported memory's store address by name.
    pub fn getExportMemAddr(self: *const Instance, name: []const u8) ?usize {
        const idx = self.module.getExport(name, .memory) orelse return null;
        if (idx >= self.memaddrs.items.len) return null;
        return self.memaddrs.items[idx];
    }

    /// Find an exported table's store address by name.
    pub fn getExportTableAddr(self: *const Instance, name: []const u8) ?usize {
        const idx = self.module.getExport(name, .table) orelse return null;
        if (idx >= self.tableaddrs.items.len) return null;
        return self.tableaddrs.items[idx];
    }

    /// Find an exported global's store address by name.
    pub fn getExportGlobalAddr(self: *const Instance, name: []const u8) ?usize {
        const idx = self.module.getExport(name, .global) orelse return null;
        if (idx >= self.globaladdrs.items.len) return null;
        return self.globaladdrs.items[idx];
    }

    pub fn getExportTagAddr(self: *const Instance, name: []const u8) ?usize {
        const idx = self.module.getExport(name, .tag) orelse return null;
        if (idx >= self.tagaddrs.items.len) return null;
        return self.tagaddrs.items[idx];
    }

    // ---- Instantiation steps ----

    fn resolveImports(self: *Instance) !void {
        for (self.module.imports.items) |imp| {
            const handle = self.store.lookupImport(imp.module, imp.name, imp.kind) catch
                return error.ImportNotFound;

            switch (imp.kind) {
                .func => {
                    // Validate function signature matches expected type
                    if (self.module.getTypeFunc(imp.index)) |expected| {
                        const func = self.store.getFunction(handle) catch
                            return error.ImportNotFound;
                        if (!opcode.ValType.sliceEql(func.params, expected.params) or
                            !opcode.ValType.sliceEql(func.results, expected.results))
                        {
                            return error.ImportTypeMismatch;
                        }
                    }
                    try self.funcaddrs.append(self.alloc, handle);
                },
                .memory => try self.memaddrs.append(self.alloc, handle),
                .table => try self.tableaddrs.append(self.alloc, handle),
                .global => try self.globaladdrs.append(self.alloc, handle),
                .tag => try self.tagaddrs.append(self.alloc, handle),
            }
        }
    }

    fn instantiateFunctions(self: *Instance) !void {
        const num_imports: u32 = @intCast(self.funcaddrs.items.len);
        for (self.module.functions.items, 0..) |func_def, i| {
            if (i >= self.module.codes.items.len) return error.FunctionCodeMismatch;
            const code = self.module.codes.items[i];
            const func_type = self.module.getTypeFunc(func_def.type_idx) orelse
                return error.InvalidTypeIndex;

            const addr = try self.store.addFunction(.{
                .params = func_type.params,
                .results = func_type.results,
                .subtype = .{ .wasm_function = .{
                    .locals_count = code.locals_count,
                    .code = code.body,
                    .instance = @ptrCast(self),
                    .func_idx = num_imports + @as(u32, @intCast(i)),
                } },
            });
            try self.funcaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateMemories(self: *Instance) !void {
        for (self.module.memories.items) |mem_def| {
            const addr = try self.store.addMemory(mem_def.limits.min, mem_def.limits.max, mem_def.limits.page_size);
            const m = try self.store.getMemory(addr);
            try m.allocateInitial();
            try self.memaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateTables(self: *Instance) !void {
        for (self.module.tables.items) |tab_def| {
            const addr = try self.store.addTable(
                tab_def.reftype,
                tab_def.limits.min,
                tab_def.limits.max,
                tab_def.limits.is_64,
            );
            try self.tableaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateGlobals(self: *Instance) !void {
        for (self.module.globals.items) |glob_def| {
            const init_val = try evalInitExpr(glob_def.init_expr, self);
            const addr = try self.store.addGlobal(.{
                .value = init_val,
                .valtype = glob_def.valtype,
                .mutability = @enumFromInt(glob_def.mutability),
            });
            try self.globaladdrs.append(self.alloc, addr);
        }
    }

    fn instantiateTags(self: *Instance) !void {
        for (self.module.tags.items) |tag_def| {
            const addr = try self.store.addTag(tag_def.type_idx);
            try self.tagaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateElems(self: *Instance) !void {
        for (self.module.elements.items) |elem_seg| {
            const count: u32 = switch (elem_seg.init) {
                .func_indices => |indices| @intCast(indices.len),
                .expressions => |exprs| @intCast(exprs.len),
            };
            const addr = try self.store.addElem(elem_seg.reftype, count);
            const elem = try self.store.getElem(addr);

            // Populate store elem: convention 0 = null, addr+1 = valid ref
            switch (elem_seg.init) {
                .func_indices => |indices| {
                    for (indices, 0..) |func_idx, i| {
                        if (func_idx < self.funcaddrs.items.len) {
                            elem.set(i, @intCast(self.funcaddrs.items[func_idx] + 1));
                        }
                    }
                },
                .expressions => |exprs| {
                    for (exprs, 0..) |expr, i| {
                        // evalInitExpr uses 0=null, addr+1=valid ref convention
                        const val = try evalInitExpr(expr, self);
                        elem.set(i, @truncate(val));
                    }
                },
            }
            try self.elemaddrs.append(self.alloc, addr);
        }
    }

    fn instantiateData(self: *Instance) !void {
        for (self.module.datas.items) |data_seg| {
            const addr = try self.store.addData(@intCast(data_seg.data.len));
            const d = try self.store.getData(addr);
            // Copy data segment content to store
            @memcpy(d.data, data_seg.data);
            try self.dataaddrs.append(self.alloc, addr);
        }
    }

    fn applyActiveElements(self: *Instance) !void {
        for (self.module.elements.items, 0..) |elem_seg, seg_idx| {
            switch (elem_seg.mode) {
                .active => |active| {
                    const offset = try evalInitExpr(active.offset_expr, self);
                    const table_idx = active.table_idx;
                    const t = try self.getTable(table_idx);

                    // Pre-check: offset + count must fit within table size.
                    // Per spec, if out-of-bounds, no elements are written (no partial init).
                    const count: u64 = switch (elem_seg.init) {
                        .func_indices => |indices| @intCast(indices.len),
                        .expressions => |exprs| @intCast(exprs.len),
                    };
                    const end = @as(u64, @truncate(offset)) + count;
                    if (end > t.data.items.len) {
                        return error.ElementSegmentDoesNotFit;
                    }

                    switch (elem_seg.init) {
                        .func_indices => |indices| {
                            for (indices, 0..) |func_idx, i| {
                                const dest: u32 = @intCast(@as(u64, @truncate(offset)) + i);
                                const func_addr = if (func_idx < self.funcaddrs.items.len)
                                    self.funcaddrs.items[func_idx]
                                else
                                    return error.FunctionIndexOutOfBounds;
                                try t.set(dest, func_addr);
                            }
                        },
                        .expressions => |exprs| {
                            for (exprs, 0..) |expr, i| {
                                const dest: u32 = @intCast(@as(u64, @truncate(offset)) + i);
                                // evalInitExpr uses 0=null, addr+1=valid ref convention
                                const val = try evalInitExpr(expr, self);
                                if (val == 0) {
                                    try t.set(dest, null);
                                } else {
                                    try t.set(dest, @truncate(val - 1));
                                }
                            }
                        },
                    }
                    // Per spec: active element segments are dropped after application
                    if (seg_idx < self.elemaddrs.items.len) {
                        const e = self.store.getElem(self.elemaddrs.items[seg_idx]) catch continue;
                        e.dropped = true;
                    }
                },
                .passive => {},
                .declarative => {
                    // Per spec: declarative segments are dropped at instantiation
                    if (seg_idx < self.elemaddrs.items.len) {
                        const e = self.store.getElem(self.elemaddrs.items[seg_idx]) catch continue;
                        e.dropped = true;
                    }
                },
            }
        }
    }

    fn applyActiveData(self: *Instance) !void {
        for (self.module.datas.items, 0..) |data_seg, seg_idx| {
            switch (data_seg.mode) {
                .active => |active| {
                    const offset = try evalInitExpr(active.offset_expr, self);
                    const m = try self.getMemory(active.mem_idx);
                    try m.copy(@truncate(offset), data_seg.data);
                    // Per spec: active data segments are dropped after application
                    if (seg_idx < self.dataaddrs.items.len) {
                        const d = self.store.getData(self.dataaddrs.items[seg_idx]) catch continue;
                        d.dropped = true;
                    }
                },
                .passive => {},
            }
        }
    }
};

/// Evaluate a constant init expression (i32.const, i64.const, f32.const,
/// f64.const, global.get, ref.null, ref.func). Returns u64.
pub fn evalInitExpr(expr: []const u8, instance: *Instance) !u128 {
    var reader = Reader.init(expr);
    var stack: [16]u128 = undefined;
    var sp: usize = 0;
    while (reader.hasMore()) {
        const byte = try reader.readByte();
        const op: opcode.Opcode = @enumFromInt(byte);
        switch (op) {
            .i32_const => {
                const val = try reader.readI32();
                if (sp >= stack.len) return error.InvalidInitExpr;
                stack[sp] = @as(u128, @as(u64, @bitCast(@as(i64, val))));
                sp += 1;
            },
            .i64_const => {
                const val = try reader.readI64();
                if (sp >= stack.len) return error.InvalidInitExpr;
                stack[sp] = @as(u128, @as(u64, @bitCast(val)));
                sp += 1;
            },
            .f32_const => {
                const val = try reader.readF32();
                if (sp >= stack.len) return error.InvalidInitExpr;
                stack[sp] = @as(u128, @as(u32, @bitCast(val)));
                sp += 1;
            },
            .f64_const => {
                const val = try reader.readF64();
                if (sp >= stack.len) return error.InvalidInitExpr;
                stack[sp] = @as(u128, @as(u64, @bitCast(val)));
                sp += 1;
            },
            .global_get => {
                const idx = try reader.readU32();
                const g = try instance.getGlobal(idx);
                if (sp >= stack.len) return error.InvalidInitExpr;
                stack[sp] = g.value;
                sp += 1;
            },
            .ref_null => {
                _ = try reader.readI33(); // heap type (S33 LEB128)
                if (sp >= stack.len) return error.InvalidInitExpr;
                stack[sp] = 0; // null ref
                sp += 1;
            },
            .ref_func => {
                const idx = try reader.readU32();
                if (sp >= stack.len) return error.InvalidInitExpr;
                // Resolve to store address + 1 (0 = null ref convention)
                if (idx < instance.funcaddrs.items.len) {
                    stack[sp] = @as(u128, @intCast(instance.funcaddrs.items[idx])) + 1;
                } else {
                    return error.FunctionIndexOutOfBounds;
                }
                sp += 1;
            },
            // Extended constant expressions (Wasm 3.0)
            .i32_add, .i32_sub, .i32_mul => {
                if (sp < 2) return error.InvalidInitExpr;
                const b: i32 = @truncate(@as(i64, @bitCast(@as(u64, @truncate(stack[sp - 1])))));
                const a: i32 = @truncate(@as(i64, @bitCast(@as(u64, @truncate(stack[sp - 2])))));
                const result: i32 = switch (op) {
                    .i32_add => a +% b,
                    .i32_sub => a -% b,
                    .i32_mul => a *% b,
                    else => unreachable,
                };
                sp -= 1;
                stack[sp - 1] = @as(u128, @as(u64, @bitCast(@as(i64, result))));
            },
            .i64_add, .i64_sub, .i64_mul => {
                if (sp < 2) return error.InvalidInitExpr;
                const b: i64 = @bitCast(@as(u64, @truncate(stack[sp - 1])));
                const a: i64 = @bitCast(@as(u64, @truncate(stack[sp - 2])));
                const result: i64 = switch (op) {
                    .i64_add => a +% b,
                    .i64_sub => a -% b,
                    .i64_mul => a *% b,
                    else => unreachable,
                };
                sp -= 1;
                stack[sp - 1] = @as(u128, @as(u64, @bitCast(result)));
            },
            // GC prefix — struct/array constructors and conversions
            .gc_prefix => {
                const gc_op = try reader.readU32();
                switch (gc_op) {
                    0x00 => { // struct.new
                        const type_idx = try reader.readU32();
                        const n = instance.getStructFieldCount(type_idx);
                        if (sp < n) return error.InvalidInitExpr;
                        var fields_buf: [32]u64 = undefined;
                        for (0..n) |i| {
                            fields_buf[n - 1 - i] = @truncate(stack[sp - 1 - i]);
                        }
                        sp -= n;
                        const addr = instance.store.gc_heap.allocStruct(type_idx, fields_buf[0..n]) catch return error.InvalidInitExpr;
                        if (sp >= stack.len) return error.InvalidInitExpr;
                        stack[sp] = @as(u128, gc_mod.GcHeap.encodeRef(addr));
                        sp += 1;
                    },
                    0x01 => { // struct.new_default
                        const type_idx = try reader.readU32();
                        const n = instance.getStructFieldCount(type_idx);
                        var fields_buf: [32]u64 = undefined;
                        @memset(fields_buf[0..n], 0);
                        const addr = instance.store.gc_heap.allocStruct(type_idx, fields_buf[0..n]) catch return error.InvalidInitExpr;
                        if (sp >= stack.len) return error.InvalidInitExpr;
                        stack[sp] = @as(u128, gc_mod.GcHeap.encodeRef(addr));
                        sp += 1;
                    },
                    0x06 => { // array.new
                        const type_idx = try reader.readU32();
                        if (sp < 2) return error.InvalidInitExpr;
                        const len: u32 = @truncate(@as(u64, @truncate(stack[sp - 1])));
                        const init_val: u64 = @truncate(stack[sp - 2]);
                        sp -= 2;
                        const addr = instance.store.gc_heap.allocArray(type_idx, len, init_val) catch return error.InvalidInitExpr;
                        if (sp >= stack.len) return error.InvalidInitExpr;
                        stack[sp] = @as(u128, gc_mod.GcHeap.encodeRef(addr));
                        sp += 1;
                    },
                    0x07 => { // array.new_default
                        const type_idx = try reader.readU32();
                        if (sp < 1) return error.InvalidInitExpr;
                        const len: u32 = @truncate(@as(u64, @truncate(stack[sp - 1])));
                        sp -= 1;
                        const addr = instance.store.gc_heap.allocArray(type_idx, len, 0) catch return error.InvalidInitExpr;
                        if (sp >= stack.len) return error.InvalidInitExpr;
                        stack[sp] = @as(u128, gc_mod.GcHeap.encodeRef(addr));
                        sp += 1;
                    },
                    0x08 => { // array.new_fixed
                        const type_idx = try reader.readU32();
                        const n = try reader.readU32();
                        if (sp < n) return error.InvalidInitExpr;
                        var vals_buf: [256]u64 = undefined;
                        const count: usize = @min(n, 256);
                        for (0..count) |i| {
                            vals_buf[count - 1 - i] = @truncate(stack[sp - 1 - i]);
                        }
                        sp -= count;
                        const addr = instance.store.gc_heap.allocArrayWithValues(type_idx, vals_buf[0..count]) catch return error.InvalidInitExpr;
                        if (sp >= stack.len) return error.InvalidInitExpr;
                        stack[sp] = @as(u128, gc_mod.GcHeap.encodeRef(addr));
                        sp += 1;
                    },
                    0x1A => { // any.convert_extern
                        // Pass-through: extern ref value is the same as any ref
                    },
                    0x1B => { // extern.convert_any
                        // Pass-through: any ref value is the same as extern ref
                    },
                    0x1C => { // ref.i31
                        if (sp < 1) return error.InvalidInitExpr;
                        const val: u32 = @truncate(@as(u64, @truncate(stack[sp - 1])));
                        stack[sp - 1] = @as(u128, @as(u64, val & 0x7FFFFFFF) | gc_mod.I31_TAG);
                    },
                    else => return error.InvalidInitExpr,
                }
            },
            // SIMD v128.const in init expressions
            .simd_prefix => {
                const simd_op = try reader.readU32();
                if (simd_op == 0x0C) { // v128.const
                    const bytes = try reader.readBytes(16);
                    if (sp >= stack.len) return error.InvalidInitExpr;
                    stack[sp] = std.mem.readInt(u128, bytes[0..16], .little);
                    sp += 1;
                } else {
                    return error.InvalidInitExpr;
                }
            },
            .end => {
                if (sp == 0) return 0; // empty init expr
                return stack[sp - 1];
            },
            else => return error.InvalidInitExpr,
        }
    }
    return if (sp > 0) stack[sp - 1] else 0;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn readTestFile(alloc: Allocator, name: []const u8) ![]const u8 {
    const prefixes = [_][]const u8{ "src/testdata/", "testdata/", "src/wasm/testdata/" };
    for (prefixes) |prefix| {
        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, name });
        defer alloc.free(path);
        const file = std.fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();
        const stat = try file.stat();
        const data = try alloc.alloc(u8, stat.size);
        const read = try file.readAll(data);
        return data[0..read];
    }
    return error.FileNotFound;
}


test "Instance — instantiate 01_add.wasm" {
    const wasm = try readTestFile(testing.allocator, "01_add.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    // Should have one function
    try testing.expectEqual(@as(usize, 1), inst.funcaddrs.items.len);

    // Should be able to look up "add" export
    const add_addr = inst.getExportFunc("add");
    try testing.expect(add_addr != null);
}

test "Instance — instantiate 03_memory.wasm" {
    const wasm = try readTestFile(testing.allocator, "03_memory.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    // Should have memory
    try testing.expect(inst.memaddrs.items.len > 0);
    const m = try inst.getMemory(0);
    try testing.expect(m.size() > 0);
}

test "Instance — instantiate 04_imports.wasm with host functions" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Register host functions that the module imports
    const dummy_fn: store_mod.HostFn = @ptrFromInt(@intFromPtr(&struct {
        fn f(_: *anyopaque, _: usize) anyerror!void {}
    }.f));

    try store.exposeHostFunction("env", "print_i32", dummy_fn, 0,
        &[_]ValType{.i32}, &[_]ValType{});
    try store.exposeHostFunction("env", "print_str", dummy_fn, 0,
        &[_]ValType{ .i32, .i32 }, &[_]ValType{});

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    // 2 imported + 2 local functions
    try testing.expectEqual(@as(usize, 4), inst.funcaddrs.items.len);

    // Data segment should have been applied
    const m = try inst.getMemory(0);
    const bytes = m.memory();
    try testing.expectEqualStrings("Hello from Wasm!", bytes[0..16]);
}

test "Instance — instantiate 06_globals.wasm" {
    const wasm = try readTestFile(testing.allocator, "06_globals.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    // Should have globals
    try testing.expect(inst.globaladdrs.items.len > 0);
}

test "Instance — missing import returns error" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Don't register any imports
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try testing.expectError(error.ImportNotFound, inst.instantiate());
}

test "Import validation — type mismatch" {
    const wasm = try readTestFile(testing.allocator, "04_imports.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Register print_i32 with WRONG signature: () -> (i32) instead of (i32) -> ()
    const nop_fn = struct {
        fn call(_: *anyopaque, _: usize) anyerror!void {}
    }.call;
    try store.exposeHostFunction("env", "print_i32", nop_fn, 0, &.{}, &.{.i32});
    // Register print_str correctly: (i32, i32) -> ()
    try store.exposeHostFunction("env", "print_str", nop_fn, 0, &.{ .i32, .i32 }, &.{});

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    // Should fail due to type mismatch on print_i32
    try testing.expectError(error.ImportTypeMismatch, inst.instantiate());
}

test "evalInitExpr — i32.const" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i32.const 42, end
    const expr = [_]u8{ 0x41, 42, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    try testing.expectEqual(@as(u128, 42), val);
}

test "evalInitExpr — i32.const negative" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i32.const -1, end
    const expr = [_]u8{ 0x41, 0x7F, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    // -1 as i32 sign-extended to i64 then bitcast to u64
    const expected: u128 = @as(u64, @bitCast(@as(i64, -1)));
    try testing.expectEqual(expected, val);
}

test "evalInitExpr — i64.const" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i64.const 100, end
    const expr = [_]u8{ 0x42, 0xE4, 0x00, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    try testing.expectEqual(@as(u128, 100), val);
}

test "evalInitExpr — extended const i32.add" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i32.const 20, i32.const 22, i32.add, end => 42
    const expr = [_]u8{ 0x41, 20, 0x41, 22, 0x6A, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    try testing.expectEqual(@as(u128, @as(u64, @bitCast(@as(i64, 42)))), val);
}

test "evalInitExpr — extended const i32.sub/mul" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i32.const 20, i32.const 2, i32.mul, i32.const 2, i32.sub, i32.const 4, i32.add, end => 42
    // (i32.add (i32.sub (i32.mul 20 2) 2) 4) = (40 - 2) + 4 = 42
    const expr = [_]u8{ 0x41, 20, 0x41, 2, 0x6C, 0x41, 2, 0x6B, 0x41, 4, 0x6A, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    try testing.expectEqual(@as(u128, @as(u64, @bitCast(@as(i64, 42)))), val);
}

test "evalInitExpr — extended const i64.add" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    const mod_bytes = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    var mod = Module.init(testing.allocator, &mod_bytes);
    defer mod.deinit();
    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();

    // i64.const 100, i64.const 200, i64.add, end => 300
    const expr = [_]u8{ 0x42, 0xE4, 0x00, 0x42, 0xC8, 0x01, 0x7C, 0x0B };
    const val = try evalInitExpr(&expr, &inst);
    try testing.expectEqual(@as(u128, 300), val);
}
