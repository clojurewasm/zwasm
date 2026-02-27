// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Wasm module type checker (operand stack + control stack validation).
//!
//! Validates function bodies for type safety per the WebAssembly spec.
//! Called from `Module.validate()`, invoked by `zwasm validate`.
//! NOT called during `zwasm run` — no runtime performance impact.

const std = @import("std");
const Allocator = std.mem.Allocator;
const opcode = @import("opcode.zig");
const ValType = opcode.ValType;
const Opcode = opcode.Opcode;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const Reader = @import("leb128.zig").Reader;

const ConstGlobalInfo = struct { valtype: ValType, mutability: u8 };

/// Operand type: either a known ValType or Unknown (polymorphic after unreachable).
const Type = union(enum) {
    known: ValType,
    unknown: void,
};

/// Control frame for block/loop/if/else tracking.
const ControlFrame = struct {
    kind: FrameKind,
    start_types: []const ValType,
    end_types: []const ValType,
    height: usize, // operand stack height at frame entry
    unreachable_flag: bool,
    init_snapshot: ?[]bool, // local init state at block entry (null = no non-defaultable locals)
};

const FrameKind = enum { block, loop, @"if", @"else" };

pub const ValidateError = error{
    TypeMismatch,
    InvalidAlignment,
    InvalidLaneIndex,
    UnknownLocal,
    UninitializedLocal,
    UnknownGlobal,
    UnknownFunction,
    UnknownType,
    UnknownTable,
    UnknownMemory,
    UnknownLabel,
    UnknownDataSegment,
    UnknownElemSegment,
    ImmutableGlobal,
    InvalidResultArity,
    ConstantExprRequired,
    DataCountRequired,
    IllegalOpcode,
    DuplicateExportName,
    DuplicateStartSection,
    OutOfMemory,
    Overflow,
    EndOfStream,
};

const Validator = struct {
    op_stack: std.ArrayList(Type),
    ctrl_stack: std.ArrayList(ControlFrame),
    module: *const Module,
    // Local types for current function (params + locals)
    local_types: std.ArrayList(ValType),
    // Local initialization tracking (function-references proposal)
    local_inits: std.ArrayList(bool),
    has_non_defaultable: bool, // fast path: skip init tracking if all locals are defaultable
    alloc: Allocator,

    fn init(alloc: Allocator, mod: *const Module) Validator {
        return .{
            .op_stack = .empty,
            .ctrl_stack = .empty,
            .module = mod,
            .local_types = .empty,
            .local_inits = .empty,
            .has_non_defaultable = false,
            .alloc = alloc,
        };
    }

    fn deinit(self: *Validator) void {
        self.op_stack.deinit(self.alloc);
        // Free any remaining init snapshots in control frames
        for (self.ctrl_stack.items) |frame| {
            if (frame.init_snapshot) |s| self.alloc.free(s);
        }
        self.ctrl_stack.deinit(self.alloc);
        self.local_types.deinit(self.alloc);
        self.local_inits.deinit(self.alloc);
    }

    // ---- Operand stack ----

    fn pushOperand(self: *Validator, t: Type) !void {
        try self.op_stack.append(self.alloc, t);
    }

    fn pushVal(self: *Validator, vt: ValType) !void {
        try self.op_stack.append(self.alloc, .{ .known = vt });
    }

    fn popOperand(self: *Validator) !Type {
        const frame = self.ctrl_stack.items[self.ctrl_stack.items.len - 1];
        if (self.op_stack.items.len == frame.height) {
            if (frame.unreachable_flag) return .unknown;
            return error.TypeMismatch;
        }
        return self.op_stack.pop().?;
    }

    fn popExpecting(self: *Validator, expected: ValType) !Type {
        const actual = try self.popOperand();
        switch (actual) {
            .unknown => return actual,
            .known => |vt| {
                if (!vt.eql(expected)) return error.TypeMismatch;
                return actual;
            },
        }
    }

    fn popI32(self: *Validator) !void {
        _ = try self.popExpecting(.i32);
    }

    fn popI64(self: *Validator) !void {
        _ = try self.popExpecting(.i64);
    }

    fn popF32(self: *Validator) !void {
        _ = try self.popExpecting(.f32);
    }

    fn popF64(self: *Validator) !void {
        _ = try self.popExpecting(.f64);
    }

    fn popV128(self: *Validator) !void {
        _ = try self.popExpecting(.v128);
    }

    /// Pop a value that must be a subtype of eqref.
    fn popExpectingEqRef(self: *Validator) !void {
        const actual = try self.popOperand();
        switch (actual) {
            .unknown => {}, // OK after unreachable
            .known => |vt| {
                // eqref subtypes: eqref, i31ref, structref, arrayref, nullref, none,
                // or any (ref null $t) where $t is struct/array/i31
                if (!isEqRefSubtype(vt)) return error.TypeMismatch;
            },
        }
    }

    fn isEqRefSubtype(vt: ValType) bool {
        const ht = heapType(vt) orelse return false;
        const H = ValType;
        return ht == H.HEAP_EQ or ht == H.HEAP_I31 or ht == H.HEAP_STRUCT or
            ht == H.HEAP_ARRAY or ht == H.HEAP_NONE or
            ht < H.HEAP_NOEXN; // concrete type indices (struct/array) are subtypes of eq
    }

    /// Check if a function index is "declared" for ref.func usage.
    /// A function is declared if it appears in element segments or exports.
    fn isFuncDeclared(self: *Validator, func_idx: u32) bool {
        // Check exports
        for (self.module.exports.items) |exp| {
            if (exp.kind == .func and exp.index == func_idx) return true;
        }
        // Check element segment func_indices
        for (self.module.elements.items) |seg| {
            switch (seg.init) {
                .func_indices => |indices| {
                    for (indices) |idx| {
                        if (idx == func_idx) return true;
                    }
                },
                .expressions => |exprs| {
                    for (exprs) |expr| {
                        // Check for ref.func within the expression
                        if (exprContainsRefFunc(expr, func_idx)) return true;
                    }
                },
            }
        }
        return false;
    }

    /// Pop a value that must be a func-typed reference compatible with type_idx.
    fn popExpectingFuncRef(self: *Validator, type_idx: u32) !void {
        const actual = try self.popOperand();
        switch (actual) {
            .unknown => {}, // OK after unreachable
            .known => |vt| {
                // Must be a typed func ref: (ref null $t), (ref $t), or nofuncref
                const ht = heapType(vt) orelse return error.TypeMismatch;
                if (ht == ValType.HEAP_NOFUNC) return; // bottom type, subtype of all func types
                if (ht == ValType.HEAP_FUNC) return error.TypeMismatch; // supertype, not subtype
                if (ht == type_idx) return; // exact type match
                // Check if ht is a subtype of type_idx via super_types chain
                if (ht < ValType.HEAP_NOEXN) {
                    // concrete type index — check supertype chain
                    if (isConcreteSubtype(self.module, ht, type_idx)) return;
                    return error.TypeMismatch;
                }
                return error.TypeMismatch;
            },
        }
    }

    // ---- Control stack ----

    fn pushCtrl(self: *Validator, kind: FrameKind, in_types: []const ValType, out_types: []const ValType) !void {
        const snapshot = if (self.has_non_defaultable)
            try self.alloc.dupe(bool, self.local_inits.items)
        else
            null;
        try self.ctrl_stack.append(self.alloc, .{
            .kind = kind,
            .start_types = in_types,
            .end_types = out_types,
            .height = self.op_stack.items.len,
            .unreachable_flag = false,
            .init_snapshot = snapshot,
        });
    }

    fn popCtrl(self: *Validator) !ControlFrame {
        if (self.ctrl_stack.items.len == 0) return error.TypeMismatch;
        const frame = self.ctrl_stack.items[self.ctrl_stack.items.len - 1];
        // Check that end_types match what's on the stack
        try self.popExpectingTypes(frame.end_types);
        if (self.op_stack.items.len != frame.height) return error.TypeMismatch;
        _ = self.ctrl_stack.pop();
        // Restore local init state from snapshot (block-scoped init doesn't leak)
        if (frame.init_snapshot) |snapshot| {
            @memcpy(self.local_inits.items, snapshot);
            self.alloc.free(snapshot);
        }
        return frame;
    }

    fn labelTypes(frame: ControlFrame) []const ValType {
        return if (frame.kind == .loop) frame.start_types else frame.end_types;
    }

    fn setUnreachable(self: *Validator) void {
        const frame = &self.ctrl_stack.items[self.ctrl_stack.items.len - 1];
        self.op_stack.shrinkRetainingCapacity(frame.height);
        frame.unreachable_flag = true;
    }

    fn popExpectingTypes(self: *Validator, types: []const ValType) !void {
        // Pop types in reverse order
        var i: usize = types.len;
        while (i > 0) {
            i -= 1;
            _ = try self.popExpecting(types[i]);
        }
    }

    fn pushTypes(self: *Validator, types: []const ValType) !void {
        for (types) |t| {
            try self.pushVal(t);
        }
    }

    // ---- Block type resolution ----

    // Static single-element type slices for resolveBlockType results.
    const single_i32 = [1]ValType{.i32};
    const single_i64 = [1]ValType{.i64};
    const single_f32 = [1]ValType{.f32};
    const single_f64 = [1]ValType{.f64};
    const single_v128 = [1]ValType{.v128};
    const single_funcref = [1]ValType{.funcref};
    const single_externref = [1]ValType{.externref};
    const single_exnref = [1]ValType{.exnref};

    fn singleTypeSlice(vt: ValType) []const ValType {
        return switch (vt) {
            .i32 => &single_i32,
            .i64 => &single_i64,
            .f32 => &single_f32,
            .f64 => &single_f64,
            .v128 => &single_v128,
            .funcref => &single_funcref,
            .externref => &single_externref,
            .exnref => &single_exnref,
            .ref_type, .ref_null_type => &single_funcref, // temporary: treat typed refs as funcref for now
        };
    }

    fn resolveBlockType(self: *Validator, reader: *Reader) !struct { params: []const ValType, results: []const ValType } {
        const byte = try reader.readByte();
        if (byte == 0x40) {
            // Empty block type
            return .{ .params = &.{}, .results = &.{} };
        }
        // Single value type
        const vt: ?ValType = ValType.fromByte(byte);
        if (vt) |v| {
            return .{ .params = &.{}, .results = singleTypeSlice(v) };
        }
        // Type index (s33 — we already read first byte, need to decode LEB128)
        // Re-read as s33 by backing up
        reader.pos -= 1;
        const type_idx = try reader.readI32();
        const idx: u32 = @bitCast(type_idx);
        if (idx >= self.module.types.items.len) return error.UnknownType;
        const ft = self.module.types.items[idx].getFunc() orelse return error.UnknownType;
        return .{ .params = ft.params, .results = ft.results };
    }

    // ---- Natural alignment for memory ops ----

    fn naturalAlignment(op: Opcode) ?u5 {
        return switch (op) {
            .i32_load8_s, .i32_load8_u, .i64_load8_s, .i64_load8_u, .i32_store8, .i64_store8 => 0,
            .i32_load16_s, .i32_load16_u, .i64_load16_s, .i64_load16_u, .i32_store16, .i64_store16 => 1,
            .i32_load, .f32_load, .i32_store, .f32_store, .i64_load32_s, .i64_load32_u, .i64_store32 => 2,
            .i64_load, .f64_load, .i64_store, .f64_store => 3,
            else => null,
        };
    }

    // ---- Address type for memory ops (memory64 support) ----

    fn memAddrType(self: *Validator, memidx: u32) ValType {
        const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
        if (memidx >= total_mems) return .i32; // will fail at index check
        // Check imported memories first
        if (memidx < self.module.num_imported_memories) {
            // For imported memories, check if they're memory64
            // For now, default to i32
            return .i32;
        }
        const def_idx = memidx - self.module.num_imported_memories;
        if (def_idx < self.module.memories.items.len) {
            return if (self.module.memories.items[def_idx].limits.is_64) .i64 else .i32;
        }
        return .i32;
    }

    fn tableAddrType(self: *Validator, table_idx: u32) ValType {
        if (table_idx < self.module.num_imported_tables) {
            var count: u32 = 0;
            for (self.module.imports.items) |imp| {
                if (imp.kind == .table) {
                    if (count == table_idx) {
                        if (imp.table_type) |t| return if (t.limits.is_64) .i64 else .i32;
                        return .i32;
                    }
                    count += 1;
                }
            }
            return .i32;
        }
        const def_idx = table_idx - self.module.num_imported_tables;
        if (def_idx < self.module.tables.items.len) {
            return if (self.module.tables.items[def_idx].limits.is_64) .i64 else .i32;
        }
        return .i32;
    }

    // ---- Main validation for a single function ----

    fn validateFunction(self: *Validator, func_idx: usize) !void {
        const code_idx = func_idx - self.module.num_imported_funcs;
        if (code_idx >= self.module.codes.items.len) return error.UnknownFunction;
        if (code_idx >= self.module.functions.items.len) return error.UnknownFunction;

        const type_idx = self.module.functions.items[code_idx].type_idx;
        if (type_idx >= self.module.types.items.len) return error.UnknownType;
        const func_type = self.module.types.items[type_idx].getFunc() orelse return error.UnknownType;
        const code = self.module.codes.items[code_idx];

        // Build local types: params + declared locals
        self.local_types.clearRetainingCapacity();
        self.local_inits.clearRetainingCapacity();
        self.has_non_defaultable = false;
        for (func_type.params) |p| {
            try self.local_types.append(self.alloc, p);
            try self.local_inits.append(self.alloc, true); // params are always initialized
        }
        for (code.locals) |local_decl| {
            // Check type index bounds for typed ref locals
            if (isTypeIndexRef(local_decl.valtype)) |tidx| {
                if (tidx >= self.module.types.items.len) return error.UnknownType;
            }
            const defaultable = local_decl.valtype.isDefaultable();
            if (!defaultable) self.has_non_defaultable = true;
            for (0..local_decl.count) |_| {
                try self.local_types.append(self.alloc, local_decl.valtype);
                try self.local_inits.append(self.alloc, defaultable);
            }
        }

        // Clear stacks
        self.op_stack.clearRetainingCapacity();
        // Free any remaining init snapshots from previous function
        for (self.ctrl_stack.items) |frame| {
            if (frame.init_snapshot) |s| self.alloc.free(s);
        }
        self.ctrl_stack.clearRetainingCapacity();

        // Push initial control frame for the function body
        try self.pushCtrl(.block, func_type.params, func_type.results);

        // Parse and validate the function body
        var reader = Reader.init(code.body);
        while (reader.hasMore()) {
            try self.validateOpcode(&reader);
        }

        // Function must end with the control stack empty (only the initial frame consumed by end)
        if (self.ctrl_stack.items.len != 0) return error.TypeMismatch;
    }

    fn validateOpcode(self: *Validator, reader: *Reader) ValidateError!void {
        const byte = try reader.readByte();
        const op: Opcode = @enumFromInt(byte);

        switch (op) {
            // ---- Control ----
            .@"unreachable" => self.setUnreachable(),

            .nop => {},

            .block => {
                const bt = try self.resolveBlockType(reader);
                try self.popExpectingTypes(bt.params);
                try self.pushCtrl(.block, bt.params, bt.results);
                try self.pushTypes(bt.params);
            },

            .loop => {
                const bt = try self.resolveBlockType(reader);
                try self.popExpectingTypes(bt.params);
                try self.pushCtrl(.loop, bt.params, bt.results);
                try self.pushTypes(bt.params);
            },

            .@"if" => {
                const bt = try self.resolveBlockType(reader);
                try self.popI32(); // condition
                try self.popExpectingTypes(bt.params);
                try self.pushCtrl(.@"if", bt.params, bt.results);
                try self.pushTypes(bt.params);
            },

            .@"else" => {
                const frame = try self.popCtrl();
                if (frame.kind != .@"if") return error.TypeMismatch;
                try self.pushCtrl(.@"else", frame.start_types, frame.end_types);
                try self.pushTypes(frame.start_types);
            },

            .end => {
                const frame = try self.popCtrl();
                // An if without else must have empty results
                if (frame.kind == .@"if" and frame.end_types.len > 0) return error.TypeMismatch;
                try self.pushTypes(frame.end_types);
            },

            .br => {
                const label = try reader.readU32();
                if (label >= self.ctrl_stack.items.len) return error.UnknownLabel;
                const frame = self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - label];
                try self.popExpectingTypes(labelTypes(frame));
                self.setUnreachable();
            },

            .br_if => {
                const label = try reader.readU32();
                if (label >= self.ctrl_stack.items.len) return error.UnknownLabel;
                try self.popI32(); // condition
                const frame = self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - label];
                const ltypes = labelTypes(frame);
                try self.popExpectingTypes(ltypes);
                try self.pushTypes(ltypes);
            },

            .br_table => {
                const count = try reader.readU32();
                // Save reader position to re-check label arities
                const labels_start = reader.pos;
                // First pass: read and validate all labels exist
                var i: u32 = 0;
                while (i <= count) : (i += 1) {
                    const label = try reader.readU32();
                    if (label >= self.ctrl_stack.items.len) return error.UnknownLabel;
                }
                // Default label is the last one
                const labels_end = reader.pos;
                // Re-read to find default label
                reader.pos = labels_start;
                var j: u32 = 0;
                var default_label: u32 = 0;
                while (j <= count) : (j += 1) {
                    default_label = try reader.readU32();
                }
                const default_frame = self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - default_label];
                const default_arity = labelTypes(default_frame).len;
                // Re-read to check all labels have same arity
                reader.pos = labels_start;
                var k: u32 = 0;
                while (k < count) : (k += 1) {
                    const label = try reader.readU32();
                    const frame = self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - label];
                    if (labelTypes(frame).len != default_arity) return error.TypeMismatch;
                }
                reader.pos = labels_end;
                try self.popI32(); // selector
                try self.popExpectingTypes(labelTypes(default_frame));
                self.setUnreachable();
            },

            .@"return" => {
                // Return types are the outermost block's end_types
                const frame = self.ctrl_stack.items[0];
                try self.popExpectingTypes(frame.end_types);
                self.setUnreachable();
            },

            .call => {
                const func_idx = try reader.readU32();
                const total_funcs = self.module.num_imported_funcs + self.module.functions.items.len;
                if (func_idx >= total_funcs) return error.UnknownFunction;
                const ft = self.getFuncType(func_idx) orelse return error.UnknownType;
                try self.popExpectingTypes(ft.params);
                try self.pushTypes(ft.results);
            },

            .call_indirect => {
                const type_idx = try reader.readU32();
                const table_idx = try reader.readU32();
                if (type_idx >= self.module.types.items.len) return error.UnknownType;
                const total_tables = self.module.num_imported_tables + self.module.tables.items.len;
                if (table_idx >= total_tables) return error.UnknownTable;
                if (!self.getTableRefType(table_idx).eql(.funcref)) return error.TypeMismatch;
                try self.popI32(); // table index
                const ft = self.module.types.items[type_idx].getFunc() orelse return error.UnknownType;
                try self.popExpectingTypes(ft.params);
                try self.pushTypes(ft.results);
            },

            .return_call => {
                const func_idx = try reader.readU32();
                const total_funcs = self.module.num_imported_funcs + self.module.functions.items.len;
                if (func_idx >= total_funcs) return error.UnknownFunction;
                const ft = self.getFuncType(func_idx) orelse return error.UnknownType;
                // return_call: callee's results must match caller's results
                const caller_results = self.ctrl_stack.items[0].end_types;
                if (ft.results.len != caller_results.len) return error.TypeMismatch;
                for (ft.results, caller_results) |a, b| {
                    if (!a.eql(b)) return error.TypeMismatch;
                }
                try self.popExpectingTypes(ft.params);
                self.setUnreachable();
            },

            .return_call_indirect => {
                const type_idx = try reader.readU32();
                const table_idx = try reader.readU32();
                if (type_idx >= self.module.types.items.len) return error.UnknownType;
                const total_tables = self.module.num_imported_tables + @as(u32, @intCast(self.module.tables.items.len));
                if (table_idx >= total_tables) return error.UnknownTable;
                if (!self.getTableRefType(table_idx).eql(.funcref)) return error.TypeMismatch;
                try self.popI32();
                const ft = self.module.types.items[type_idx].getFunc() orelse return error.UnknownType;
                // return_call_indirect: callee's results must match caller's results
                const caller_results = self.ctrl_stack.items[0].end_types;
                if (ft.results.len != caller_results.len) return error.TypeMismatch;
                for (ft.results, caller_results) |a, b| {
                    if (!a.eql(b)) return error.TypeMismatch;
                }
                try self.popExpectingTypes(ft.params);
                self.setUnreachable();
            },

            // ---- Function references ----
            .call_ref => {
                const type_idx = try reader.readU32();
                if (type_idx >= self.module.types.items.len) return error.UnknownType;
                // Pop (ref null $type_idx) — must be a func-typed ref
                try self.popExpectingFuncRef(type_idx);
                const ft = self.module.types.items[type_idx].getFunc() orelse return error.UnknownType;
                try self.popExpectingTypes(ft.params);
                try self.pushTypes(ft.results);
            },
            .return_call_ref => {
                const type_idx = try reader.readU32();
                if (type_idx >= self.module.types.items.len) return error.UnknownType;
                try self.popExpectingFuncRef(type_idx);
                const ft = self.module.types.items[type_idx].getFunc() orelse return error.UnknownType;
                const caller_results = self.ctrl_stack.items[0].end_types;
                if (ft.results.len != caller_results.len) return error.TypeMismatch;
                for (ft.results, caller_results) |a, b| {
                    if (!a.eql(b)) return error.TypeMismatch;
                }
                try self.popExpectingTypes(ft.params);
                self.setUnreachable();
            },
            .ref_as_non_null => {
                _ = try self.popExpecting(.funcref); // pop nullable ref
                try self.pushVal(.funcref); // push non-nullable (simplified)
            },
            .br_on_null => {
                const depth = try reader.readU32();
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                _ = try self.popExpecting(.funcref); // pop nullable ref
                // if null: branch (label types already validated by branchTo path)
                // if non-null: push non-null ref back
                try self.pushVal(.funcref);
            },
            .br_on_non_null => {
                const depth = try reader.readU32();
                if (depth >= self.ctrl_stack.items.len) return error.UnknownLabel;
                _ = try self.popExpecting(.funcref);
                // if non-null: push ref and branch
                // if null: drop and continue
            },

            // ---- Exception handling ----
            .throw => {
                const tag_idx = try reader.readU32();
                const total_tags = self.module.num_imported_tags + @as(u32, @intCast(self.module.tags.items.len));
                if (tag_idx >= total_tags) return error.UnknownType;
                // Pop tag params
                const tag_type_idx = self.getTagTypeIdx(tag_idx);
                if (tag_type_idx) |tidx| {
                    if (tidx < self.module.types.items.len) {
                        if (self.module.types.items[tidx].getFunc()) |ft| {
                            try self.popExpectingTypes(ft.params);
                        }
                    }
                }
                self.setUnreachable();
            },
            .throw_ref => {
                _ = try self.popOperand(); // exnref
                self.setUnreachable();
            },
            .try_table => {
                const bt = try self.resolveBlockType(reader);
                const handler_count = try reader.readU32();
                for (0..handler_count) |_| {
                    const kind = try reader.readByte();
                    var tag_params: []const ValType = &.{};
                    if (kind == 0 or kind == 1) {
                        // catch / catch_ref — have tag index
                        const tag_idx = try reader.readU32();
                        const total_tags = self.module.num_imported_tags + @as(u32, @intCast(self.module.tags.items.len));
                        if (tag_idx < total_tags) {
                            if (self.getTagTypeIdx(tag_idx)) |tidx| {
                                if (tidx < self.module.types.items.len) {
                                    if (self.module.types.items[tidx].getFunc()) |ft| {
                                        tag_params = ft.params;
                                    }
                                }
                            }
                        }
                    }
                    const label_idx = try reader.readU32();
                    // Validate: catch clause types must match label types
                    if (label_idx < self.ctrl_stack.items.len) {
                        const target = self.ctrl_stack.items[self.ctrl_stack.items.len - 1 - label_idx];
                        const label_types = labelTypes(target);
                        // Build expected types from catch clause
                        // catch: tag params
                        // catch_ref: tag params + exnref
                        // catch_all: (empty)
                        // catch_all_ref: exnref
                        const has_exnref = (kind == 1 or kind == 3); // catch_ref or catch_all_ref
                        const expected_len = tag_params.len + @as(usize, if (has_exnref) 1 else 0);
                        if (expected_len != label_types.len) return error.TypeMismatch;
                        // Check tag params match prefix of label types
                        for (tag_params, 0..) |tp, i| {
                            if (!tp.eql(label_types[i])) return error.TypeMismatch;
                        }
                        // Check exnref at the end if applicable
                        if (has_exnref) {
                            if (!label_types[label_types.len - 1].eql(.exnref)) return error.TypeMismatch;
                        }
                    }
                }
                try self.popExpectingTypes(bt.params);
                try self.pushCtrl(.block, bt.params, bt.results);
                try self.pushTypes(bt.params);
            },

            // ---- Parametric ----
            .drop => {
                _ = try self.popOperand();
            },

            .select => {
                try self.popI32(); // condition
                const t1 = try self.popOperand();
                const t2 = try self.popOperand();
                // Both must be same type (or one/both unknown)
                switch (t1) {
                    .unknown => try self.pushOperand(t2),
                    .known => |vt1| {
                        switch (t2) {
                            .unknown => try self.pushVal(vt1),
                            .known => |vt2| {
                                if (!vt1.eql(vt2)) return error.TypeMismatch;
                                // select (without type) only works on numeric types (not ref or v128)
                                if (vt1.isRef() or vt1.eql(.v128)) return error.TypeMismatch;
                                try self.pushVal(vt1);
                            },
                        }
                    },
                }
            },

            .select_t => {
                const count = try reader.readU32();
                if (count != 1) return error.InvalidResultArity;
                const vt: ValType = ValType.fromByte(try reader.readByte()) orelse return error.TypeMismatch;
                try self.popI32();
                _ = try self.popExpecting(vt);
                _ = try self.popExpecting(vt);
                try self.pushVal(vt);
            },

            // ---- Locals ----
            .local_get => {
                const idx = try reader.readU32();
                if (idx >= self.local_types.items.len) return error.UnknownLocal;
                // Non-defaultable locals must be initialized before use
                if (self.has_non_defaultable and !self.local_inits.items[idx])
                    return error.UninitializedLocal;
                try self.pushVal(self.local_types.items[idx]);
            },
            .local_set => {
                const idx = try reader.readU32();
                if (idx >= self.local_types.items.len) return error.UnknownLocal;
                _ = try self.popExpecting(self.local_types.items[idx]);
                if (self.has_non_defaultable) self.local_inits.items[idx] = true;
            },
            .local_tee => {
                const idx = try reader.readU32();
                if (idx >= self.local_types.items.len) return error.UnknownLocal;
                const vt = self.local_types.items[idx];
                _ = try self.popExpecting(vt);
                try self.pushVal(vt);
                if (self.has_non_defaultable) self.local_inits.items[idx] = true;
            },

            // ---- Globals ----
            .global_get => {
                const idx = try reader.readU32();
                const gt = self.getGlobalType(idx) orelse return error.UnknownGlobal;
                try self.pushVal(gt.valtype);
            },
            .global_set => {
                const idx = try reader.readU32();
                const gt = self.getGlobalType(idx) orelse return error.UnknownGlobal;
                if (gt.mutability == 0) return error.ImmutableGlobal;
                _ = try self.popExpecting(gt.valtype);
            },

            // ---- Table ----
            .table_get => {
                const idx = try reader.readU32();
                const total = self.module.num_imported_tables + @as(u32, @intCast(self.module.tables.items.len));
                if (idx >= total) return error.UnknownTable;
                try self.popI32(); // table index
                const rt = self.getTableRefType(idx);
                try self.pushVal(rt);
            },
            .table_set => {
                const idx = try reader.readU32();
                const total = self.module.num_imported_tables + @as(u32, @intCast(self.module.tables.items.len));
                if (idx >= total) return error.UnknownTable;
                const rt = self.getTableRefType(idx);
                _ = try self.popExpecting(rt); // ref value
                try self.popI32(); // table index
            },

            // ---- Memory load/store ----
            .i32_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u => {
                try self.validateMemOp(op, reader, .i32);
            },
            .i64_load, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u => {
                try self.validateMemOp(op, reader, .i64);
            },
            .f32_load => try self.validateMemOp(op, reader, .f32),
            .f64_load => try self.validateMemOp(op, reader, .f64),

            .i32_store, .i32_store8, .i32_store16 => {
                try self.validateMemStore(op, reader, .i32);
            },
            .i64_store, .i64_store8, .i64_store16, .i64_store32 => {
                try self.validateMemStore(op, reader, .i64);
            },
            .f32_store => try self.validateMemStore(op, reader, .f32),
            .f64_store => try self.validateMemStore(op, reader, .f64),

            // ---- Memory size/grow ----
            .memory_size => {
                const memidx = try self.readMemIdx(reader);
                const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
                if (memidx >= total_mems) return error.UnknownMemory;
                try self.pushVal(self.memAddrType(memidx));
            },
            .memory_grow => {
                const memidx = try self.readMemIdx(reader);
                const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
                if (memidx >= total_mems) return error.UnknownMemory;
                const at = self.memAddrType(memidx);
                _ = try self.popExpecting(at);
                try self.pushVal(at);
            },

            // ---- Constants ----
            .i32_const => {
                _ = try reader.readI32();
                try self.pushVal(.i32);
            },
            .i64_const => {
                _ = try reader.readI64();
                try self.pushVal(.i64);
            },
            .f32_const => {
                _ = try reader.readBytes(4);
                try self.pushVal(.f32);
            },
            .f64_const => {
                _ = try reader.readBytes(8);
                try self.pushVal(.f64);
            },

            // ---- i32 comparison ----
            .i32_eqz => { try self.popI32(); try self.pushVal(.i32); },
            .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => {
                try self.popI32(); try self.popI32(); try self.pushVal(.i32);
            },

            // ---- i64 comparison ----
            .i64_eqz => { try self.popI64(); try self.pushVal(.i32); },
            .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => {
                try self.popI64(); try self.popI64(); try self.pushVal(.i32);
            },

            // ---- f32 comparison ----
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => {
                try self.popF32(); try self.popF32(); try self.pushVal(.i32);
            },

            // ---- f64 comparison ----
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => {
                try self.popF64(); try self.popF64(); try self.pushVal(.i32);
            },

            // ---- i32 arithmetic ----
            .i32_clz, .i32_ctz, .i32_popcnt => { try self.popI32(); try self.pushVal(.i32); },
            .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u,
            .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => {
                try self.popI32(); try self.popI32(); try self.pushVal(.i32);
            },

            // ---- i64 arithmetic ----
            .i64_clz, .i64_ctz, .i64_popcnt => { try self.popI64(); try self.pushVal(.i64); },
            .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u,
            .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => {
                try self.popI64(); try self.popI64(); try self.pushVal(.i64);
            },

            // ---- f32 arithmetic ----
            .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => {
                try self.popF32(); try self.pushVal(.f32);
            },
            .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => {
                try self.popF32(); try self.popF32(); try self.pushVal(.f32);
            },

            // ---- f64 arithmetic ----
            .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => {
                try self.popF64(); try self.pushVal(.f64);
            },
            .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => {
                try self.popF64(); try self.popF64(); try self.pushVal(.f64);
            },

            // ---- Conversions ----
            .i32_wrap_i64 => { try self.popI64(); try self.pushVal(.i32); },
            .i32_trunc_f32_s, .i32_trunc_f32_u => { try self.popF32(); try self.pushVal(.i32); },
            .i32_trunc_f64_s, .i32_trunc_f64_u => { try self.popF64(); try self.pushVal(.i32); },
            .i64_extend_i32_s, .i64_extend_i32_u => { try self.popI32(); try self.pushVal(.i64); },
            .i64_trunc_f32_s, .i64_trunc_f32_u => { try self.popF32(); try self.pushVal(.i64); },
            .i64_trunc_f64_s, .i64_trunc_f64_u => { try self.popF64(); try self.pushVal(.i64); },
            .f32_convert_i32_s, .f32_convert_i32_u => { try self.popI32(); try self.pushVal(.f32); },
            .f32_convert_i64_s, .f32_convert_i64_u => { try self.popI64(); try self.pushVal(.f32); },
            .f32_demote_f64 => { try self.popF64(); try self.pushVal(.f32); },
            .f64_convert_i32_s, .f64_convert_i32_u => { try self.popI32(); try self.pushVal(.f64); },
            .f64_convert_i64_s, .f64_convert_i64_u => { try self.popI64(); try self.pushVal(.f64); },
            .f64_promote_f32 => { try self.popF32(); try self.pushVal(.f64); },
            .i32_reinterpret_f32 => { try self.popF32(); try self.pushVal(.i32); },
            .i64_reinterpret_f64 => { try self.popF64(); try self.pushVal(.i64); },
            .f32_reinterpret_i32 => { try self.popI32(); try self.pushVal(.f32); },
            .f64_reinterpret_i64 => { try self.popI64(); try self.pushVal(.f64); },

            // ---- Sign extension ----
            .i32_extend8_s, .i32_extend16_s => { try self.popI32(); try self.pushVal(.i32); },
            .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => { try self.popI64(); try self.pushVal(.i64); },

            // ---- Reference types ----
            .ref_null => {
                _ = try reader.readI33(); // heap type (S33)
                try self.pushVal(.funcref); // simplified: push generic ref
            },
            .ref_is_null => {
                _ = try self.popOperand(); // any ref type
                try self.pushVal(.i32);
            },
            .ref_eq => {
                // Both operands must be subtypes of eqref
                try self.popExpectingEqRef();
                try self.popExpectingEqRef();
                try self.pushVal(.i32);
            },
            .ref_func => {
                const idx = try reader.readU32();
                const total = self.module.num_imported_funcs + self.module.functions.items.len;
                if (idx >= total) return error.UnknownFunction;
                // ref.func requires the function to be "declared" (in elem segments or exports)
                if (!self.isFuncDeclared(idx)) return error.UnknownFunction;
                try self.pushVal(.funcref);
            },

            // ---- 0xFC prefix (misc) ----
            .misc_prefix => {
                try self.validateMiscOp(reader);
            },

            // ---- 0xFB prefix (GC) ----
            .gc_prefix => {
                try self.validateGcOp(reader);
            },

            // ---- 0xFD prefix (SIMD) ----
            .simd_prefix => {
                try self.validateSimdOp(reader);
            },

            // ---- 0xFE prefix (Atomic/Threads) ----
            .atomic_prefix => {
                try self.validateAtomicOp(reader);
            },

            _ => {
                return error.IllegalOpcode;
            },
        }
    }

    fn validateMemOp(self: *Validator, op: Opcode, reader: *Reader, result_type: ValType) !void {
        const align_byte = try reader.readU32();
        // Bits 7+ are reserved and must be 0
        if (align_byte >= 0x80) return error.InvalidAlignment;
        const align_val = align_byte & 0x3F;
        const has_memidx = (align_byte & 0x40) != 0;
        const memidx: u32 = if (has_memidx) try reader.readU32() else 0;
        _ = try reader.readU32(); // offset

        if (naturalAlignment(op)) |nat| {
            if (align_val > nat) return error.InvalidAlignment;
        }
        const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
        if (memidx >= total_mems) return error.UnknownMemory;

        _ = try self.popExpecting(self.memAddrType(memidx)); // address
        try self.pushVal(result_type);
    }

    fn validateMemStore(self: *Validator, op: Opcode, reader: *Reader, value_type: ValType) !void {
        const align_byte = try reader.readU32();
        if (align_byte >= 0x80) return error.InvalidAlignment;
        const align_val = align_byte & 0x3F;
        const has_memidx = (align_byte & 0x40) != 0;
        const memidx: u32 = if (has_memidx) try reader.readU32() else 0;
        _ = try reader.readU32(); // offset

        if (naturalAlignment(op)) |nat| {
            if (align_val > nat) return error.InvalidAlignment;
        }
        const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
        if (memidx >= total_mems) return error.UnknownMemory;

        _ = try self.popExpecting(value_type); // value
        _ = try self.popExpecting(self.memAddrType(memidx)); // address
    }

    fn readMemIdx(self: *Validator, reader: *Reader) !u32 {
        _ = self;
        const byte = try reader.readByte();
        if (byte == 0) return 0;
        // Multi-memory: treat as LEB128 memidx
        reader.pos -= 1;
        return try reader.readU32();
    }

    fn validateMiscOp(self: *Validator, reader: *Reader) !void {
        const sub_op = try reader.readU32();
        switch (sub_op) {
            // i32.trunc_sat_f32_s/u, i32.trunc_sat_f64_s/u
            0, 1 => { try self.popF32(); try self.pushVal(.i32); },
            2, 3 => { try self.popF64(); try self.pushVal(.i32); },
            // i64.trunc_sat_f32_s/u, i64.trunc_sat_f64_s/u
            4, 5 => { try self.popF32(); try self.pushVal(.i64); },
            6, 7 => { try self.popF64(); try self.pushVal(.i64); },

            // memory.init
            8 => {
                const data_idx = try reader.readU32();
                const memidx = try reader.readByte();
                if (data_idx >= self.module.datas.items.len) return error.UnknownDataSegment;
                const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
                if (memidx >= total_mems) return error.UnknownMemory;
                try self.popI32(); // size
                try self.popI32(); // src offset
                _ = try self.popExpecting(self.memAddrType(memidx)); // dst
            },
            // data.drop
            9 => {
                const data_idx = try reader.readU32();
                if (data_idx >= self.module.datas.items.len) return error.UnknownDataSegment;
            },
            // memory.copy: [t_d, t_s, t_d] -> [] where t_d/t_s = addr type of dst/src mem
            10 => {
                const dst_mem = try reader.readByte();
                const src_mem = try reader.readByte();
                const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
                if (dst_mem >= total_mems or src_mem >= total_mems) return error.UnknownMemory;
                _ = try self.popExpecting(self.memAddrType(dst_mem)); // size
                _ = try self.popExpecting(self.memAddrType(src_mem)); // src
                _ = try self.popExpecting(self.memAddrType(dst_mem)); // dst
            },
            // memory.fill
            11 => {
                const memidx = try reader.readByte();
                const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
                if (memidx >= total_mems) return error.UnknownMemory;
                const at = self.memAddrType(memidx);
                _ = try self.popExpecting(at); // size
                try self.popI32(); // value
                _ = try self.popExpecting(at); // dst
            },
            // table.init
            12 => {
                const elem_idx = try reader.readU32();
                const table_idx = try reader.readU32();
                if (elem_idx >= self.module.elements.items.len) return error.UnknownElemSegment;
                const total_tables = self.module.num_imported_tables + self.module.tables.items.len;
                if (table_idx >= total_tables) return error.UnknownTable;
                // Check element type matches table type
                const seg = self.module.elements.items[elem_idx];
                const seg_ref: ValType = if (seg.reftype == .funcref) .funcref else .externref;
                const table_vt = self.getTableRefType(table_idx);
                if (!seg_ref.eql(table_vt)) return error.TypeMismatch;
                try self.popI32(); try self.popI32(); try self.popI32();
            },
            // elem.drop
            13 => {
                const elem_idx = try reader.readU32();
                if (elem_idx >= self.module.elements.items.len) return error.UnknownElemSegment;
            },
            // table.copy
            14 => {
                const dst_idx = try reader.readU32();
                const src_idx = try reader.readU32();
                const total_tables = self.module.num_imported_tables + self.module.tables.items.len;
                if (dst_idx >= total_tables or src_idx >= total_tables) return error.UnknownTable;
                // Source element type must be subtype of destination element type
                if (getTableFullRefType(self.module, dst_idx)) |dst_frt| {
                    if (getTableFullRefType(self.module, src_idx)) |src_frt| {
                        if (!isValTypeSubtype(src_frt, dst_frt)) return error.TypeMismatch;
                    }
                }
                // Operands: len src_offset dst_offset (in stack order: dst, src, len)
                const dst_at = self.tableAddrType(dst_idx);
                const src_at = self.tableAddrType(src_idx);
                // len uses min(dst_at, src_at) — i64 only if both tables are i64
                const len_at: ValType = if (dst_at.eql(.i64) and src_at.eql(.i64)) .i64 else .i32;
                _ = try self.popExpecting(len_at); // n (length)
                _ = try self.popExpecting(src_at); // s (source offset)
                _ = try self.popExpecting(dst_at); // d (dest offset)
            },
            // table.grow
            15 => {
                const table_idx = try reader.readU32();
                const total_tables = self.module.num_imported_tables + @as(u32, @intCast(self.module.tables.items.len));
                if (table_idx >= total_tables) return error.UnknownTable;
                try self.popI32(); // size
                _ = try self.popExpecting(self.getTableRefType(table_idx)); // init value
                try self.pushVal(.i32);
            },
            // table.size
            16 => {
                const table_idx = try reader.readU32();
                const total_tables = self.module.num_imported_tables + self.module.tables.items.len;
                if (table_idx >= total_tables) return error.UnknownTable;
                try self.pushVal(.i32);
            },
            // table.fill
            17 => {
                const table_idx = try reader.readU32();
                const total_tables = self.module.num_imported_tables + @as(u32, @intCast(self.module.tables.items.len));
                if (table_idx >= total_tables) return error.UnknownTable;
                try self.popI32(); // count
                _ = try self.popExpecting(self.getTableRefType(table_idx)); // val
                try self.popI32(); // idx
            },
            else => return error.IllegalOpcode,
        }
    }

    fn validateGcOp(self: *Validator, reader: *Reader) !void {
        const sub_op = try reader.readU32();
        switch (sub_op) {
            0x00, 0x01 => _ = try reader.readU32(), // struct.new/new_default (typeidx)
            0x02, 0x03, 0x04, 0x05 => { // struct.get/get_s/get_u/set
                _ = try reader.readU32();
                _ = try reader.readU32();
            },
            0x06, 0x07 => _ = try reader.readU32(), // array.new/new_default
            0x08 => { _ = try reader.readU32(); _ = try reader.readU32(); }, // array.new_fixed
            0x09, 0x0A => { _ = try reader.readU32(); _ = try reader.readU32(); }, // array.new_data/elem
            0x0B, 0x0C, 0x0D, 0x0E => _ = try reader.readU32(), // array.get/set
            0x0F => {}, // array.len
            0x10 => _ = try reader.readU32(), // array.fill
            0x11 => { _ = try reader.readU32(); _ = try reader.readU32(); }, // array.copy
            0x12, 0x13 => { _ = try reader.readU32(); _ = try reader.readU32(); }, // array.init_data/elem
            0x14, 0x15 => _ = try reader.readI33(), // ref.test/ref.test_null
            0x16, 0x17 => _ = try reader.readI33(), // ref.cast/ref.cast_null
            0x18, 0x19 => { // br_on_cast/br_on_cast_fail
                _ = try reader.readByte(); // flags
                _ = try reader.readU32(); // labelidx
                const ht1_raw = try reader.readI33(); // heaptype1 (source)
                const ht2_raw = try reader.readI33(); // heaptype2 (target)
                const ht1 = i33ToHeapType(ht1_raw);
                const ht2 = i33ToHeapType(ht2_raw);
                // target must be a subtype of source
                if (!isHeapSubtypeOf(self.module, ht2, ht1)) return error.TypeMismatch;
            },
            0x1A, 0x1B => {}, // any.convert_extern, extern.convert_any
            0x1C, 0x1D, 0x1E => {}, // ref.i31, i31.get_s, i31.get_u
            else => {},
        }
    }

    fn validateAtomicOp(self: *Validator, reader: *Reader) !void {
        const sub_op = try reader.readU32();
        if (sub_op == 0x03) {
            // atomic.fence
            const reserved = try reader.readByte();
            if (reserved != 0x00) return error.IllegalOpcode;
            return;
        }
        if (sub_op > 0x4E) return error.IllegalOpcode;
        // All other atomic ops have memarg
        const align_byte = try reader.readU32();
        const align_val = align_byte & 0x3F;
        const has_memidx = (align_byte & 0x40) != 0;
        const memidx: u32 = if (has_memidx) try reader.readU32() else 0;
        _ = try reader.readU32(); // offset

        // Check memory index
        const total_mems = self.module.num_imported_memories + self.module.memories.items.len;
        if (memidx >= total_mems) return error.UnknownMemory;

        // Check natural alignment for atomic ops
        const nat_align = atomicNaturalAlignment(sub_op);
        if (align_val != nat_align) return error.InvalidAlignment;
    }

    /// Return the required (exact) alignment for atomic operations.
    fn atomicNaturalAlignment(sub_op: u32) u32 {
        return switch (sub_op) {
            // *.atomic.load8_u, *.atomic.store8, *.atomic.rmw8.*_u, *.atomic.rmw8.cmpxchg_u
            0x12, 0x19, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x27,
            0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x35,
            0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x43,
            0x4A, 0x4B, 0x4C, 0x4D, 0x4E,
            => 0, // 1 byte = 2^0
            // *.atomic.load16_u, *.atomic.store16, *.atomic.rmw16.*_u, *.atomic.rmw16.cmpxchg_u
            0x13, 0x1A, 0x26, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D,
            0x34, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B,
            0x42, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
            => 1, // 2 bytes = 2^1
            // i32.atomic.load, i32.atomic.store, i32.atomic.rmw.*, i32.atomic.rmw.cmpxchg
            // i64.atomic.load32_u, i64.atomic.store32, i64.atomic.rmw32.*
            0x10, 0x17, 0x1E, 0x1F,
            0x14, 0x1B,
            => 2, // 4 bytes = 2^2
            // i64.atomic.load, i64.atomic.store, i64.atomic.rmw.*, i64.atomic.rmw.cmpxchg
            0x11, 0x18, 0x1C, 0x1D,
            0x15, 0x16,
            => 3, // 8 bytes = 2^3
            // memory.atomic.notify (i32), memory.atomic.wait32 (i32), memory.atomic.wait64 (i64)
            0x00 => 2, // i32 = 4 bytes
            0x01 => 2, // i32 wait
            0x02 => 3, // i64 wait
            else => 0,
        };
    }

    fn validateSimdOp(self: *Validator, reader: *Reader) !void {
        const sub_op = try reader.readU32();
        switch (sub_op) {
            // v128.load — memarg
            0 => {
                const align_byte = try reader.readU32();
                const align_val = align_byte & 0x3F;
                const has_memidx = (align_byte & 0x40) != 0;
                if (has_memidx) _ = try reader.readU32();
                _ = try reader.readU32(); // offset
                if (align_val > 4) return error.InvalidAlignment; // natural = 16 = 2^4
                try self.popI32(); // address
                try self.pushVal(.v128);
            },
            // v128.load8x8_s/u, load16x4_s/u, load32x2_s/u (1-6) — memarg, natural align 8 (2^3)
            1, 2, 3, 4, 5, 6 => {
                const align_byte = try reader.readU32();
                const align_val = align_byte & 0x3F;
                const has_memidx = (align_byte & 0x40) != 0;
                if (has_memidx) _ = try reader.readU32();
                _ = try reader.readU32();
                if (align_val > 3) return error.InvalidAlignment;
                try self.popI32();
                try self.pushVal(.v128);
            },
            // v128.load8_splat(7), load16_splat(8), load32_splat(9), load64_splat(10) — memarg
            7 => { try self.validateSimdLoad(reader, 0); },
            8 => { try self.validateSimdLoad(reader, 1); },
            9 => { try self.validateSimdLoad(reader, 2); },
            10 => { try self.validateSimdLoad(reader, 3); },
            // v128.store (11) — memarg, natural align 16 (2^4)
            11 => {
                const align_byte = try reader.readU32();
                const align_val = align_byte & 0x3F;
                const has_memidx = (align_byte & 0x40) != 0;
                if (has_memidx) _ = try reader.readU32();
                _ = try reader.readU32();
                if (align_val > 4) return error.InvalidAlignment;
                try self.popV128(); // value
                try self.popI32(); // address
            },
            // v128.const (12) — 16 bytes immediate
            12 => { _ = try reader.readBytes(16); try self.pushVal(.v128); },
            // i8x16.shuffle (13) — 16 byte lane indices (each must be < 32)
            13 => {
                const lanes = try reader.readBytes(16);
                for (lanes) |lane| {
                    if (lane >= 32) return error.InvalidLaneIndex;
                }
                try self.popV128(); try self.popV128(); try self.pushVal(.v128);
            },

            // v128 unary ops: v128 -> v128
            // i8x16: abs(0x60=96), neg(0x61=97), popcnt(0x62=98)
            96, 97, 98,
            // i16x8: abs(0x80=128), neg(0x81=129)
            128, 129,
            // i32x4: abs(0xA0=160), neg(0xA1=161)
            160, 161,
            // i64x2: abs(0xC0=192), neg(0xC1=193)
            192, 193,
            // i8x16.narrow_i16x8_s/u (0x65=101, 0x66=102) — binary actually
            // f32x4: ceil(0x67=103), floor(0x68=104), trunc(0x69=105), nearest(0x6A=106)
            103, 104, 105, 106,
            // f64x2: ceil(0x74=116), floor(0x75=117)
            116, 117,
            // f64x2: trunc(0x7A=122)
            122,
            // extadd_pairwise: i16x8(0x7C=124, 0x7D=125), i32x4(0x7E=126, 0x7F=127)
            124, 125, 126, 127,
            // f64x2: nearest(0x94=148)
            148,
            // v128.not (0x4D=77)
            77,
            // f32x4: abs(0xE0=224), neg(0xE1=225), sqrt(0xE3=227)
            224, 225, 227,
            // f64x2: abs(0xEC=236), neg(0xED=237), sqrt(0xEF=239)
            236, 237, 239,
            // Conversions (all unary v128 -> v128):
            // f32x4.demote_f64x2_zero(0x5E=94), f64x2.promote_low_f32x4(0x5F=95)
            94, 95,
            // i32x4.trunc_sat_f32x4_s/u(0xF8=248, 0xF9=249)
            248, 249,
            // f32x4.convert_i32x4_s/u(0xFA=250, 0xFB=251)
            250, 251,
            // i32x4.trunc_sat_f64x2_s/u_zero(0xFC=252, 0xFD=253)
            252, 253,
            // f64x2.convert_low_i32x4_s/u(0xFE=254, 0xFF=255)
            254, 255,
            => {
                // Unary: v128 -> v128
                try self.popV128();
                try self.pushVal(.v128);
            },

            // v128 -> i32 ops
            // all_true: i8x16(0x63=99), i16x8(0x83=131), i32x4(0xA3=163), i64x2(0xC3=195)
            99, 131, 163, 195,
            // bitmask: i8x16(0x64=100), i16x8(0x84=132), i32x4(0xA4=164), i64x2(0xC4=196)
            100, 132, 164, 196,
            // v128.any_true(0x53=83)
            83,
            => {
                try self.popV128();
                try self.pushVal(.i32);
            },

            // Shift ops: v128, i32 -> v128
            // i8x16: shl(0x6B=107), shr_s(0x6C=108), shr_u(0x6D=109)
            107, 108, 109,
            // i16x8: shl(0x8B=139), shr_s(0x8C=140), shr_u(0x8D=141)
            139, 140, 141,
            // i32x4: shl(0xAB=171), shr_s(0xAC=172), shr_u(0xAD=173)
            171, 172, 173,
            // i64x2: shl(0xCB=203), shr_s(0xCC=204), shr_u(0xCD=205)
            203, 204, 205,
            => {
                try self.popI32(); // shift amount
                try self.popV128(); // vector
                try self.pushVal(.v128);
            },

            // v128.bitselect (0x52=82): v128, v128, v128 -> v128
            82 => {
                try self.popV128(); // mask
                try self.popV128(); // val2
                try self.popV128(); // val1
                try self.pushVal(.v128);
            },

            // Splat ops: scalar -> v128
            15 => { try self.popI32(); try self.pushVal(.v128); }, // i8x16.splat
            16 => { try self.popI32(); try self.pushVal(.v128); }, // i16x8.splat
            17 => { try self.popI32(); try self.pushVal(.v128); }, // i32x4.splat
            18 => { try self.popI64(); try self.pushVal(.v128); }, // i64x2.splat
            19 => { try self.popF32(); try self.pushVal(.v128); }, // f32x4.splat
            20 => { try self.popF64(); try self.pushVal(.v128); }, // f64x2.splat

            // Extract lane: v128 + lane -> scalar
            21 => { try self.validateLane(reader, 16); try self.popV128(); try self.pushVal(.i32); }, // i8x16.extract_lane_s
            22 => { try self.validateLane(reader, 16); try self.popV128(); try self.pushVal(.i32); }, // i8x16.extract_lane_u
            23 => { try self.validateLane(reader, 16); try self.popI32(); try self.popV128(); try self.pushVal(.v128); }, // i8x16.replace_lane
            24 => { try self.validateLane(reader, 8); try self.popV128(); try self.pushVal(.i32); }, // i16x8.extract_lane_s
            25 => { try self.validateLane(reader, 8); try self.popV128(); try self.pushVal(.i32); }, // i16x8.extract_lane_u
            26 => { try self.validateLane(reader, 8); try self.popI32(); try self.popV128(); try self.pushVal(.v128); }, // i16x8.replace_lane
            27 => { try self.validateLane(reader, 4); try self.popV128(); try self.pushVal(.i32); }, // i32x4.extract_lane
            28 => { try self.validateLane(reader, 4); try self.popI32(); try self.popV128(); try self.pushVal(.v128); }, // i32x4.replace_lane
            29 => { try self.validateLane(reader, 2); try self.popV128(); try self.pushVal(.i64); }, // i64x2.extract_lane
            30 => { try self.validateLane(reader, 2); try self.popI64(); try self.popV128(); try self.pushVal(.v128); }, // i64x2.replace_lane
            31 => { try self.validateLane(reader, 4); try self.popV128(); try self.pushVal(.f32); }, // f32x4.extract_lane
            32 => { try self.validateLane(reader, 4); try self.popF32(); try self.popV128(); try self.pushVal(.v128); }, // f32x4.replace_lane
            33 => { try self.validateLane(reader, 2); try self.popV128(); try self.pushVal(.f64); }, // f64x2.extract_lane
            34 => { try self.validateLane(reader, 2); try self.popF64(); try self.popV128(); try self.pushVal(.v128); }, // f64x2.replace_lane

            // v128 load_zero (92, 93) — memarg
            92 => { try self.validateSimdLoad(reader, 2); }, // v128.load32_zero
            93 => { try self.validateSimdLoad(reader, 3); }, // v128.load64_zero

            // v128 load_lane / store_lane (84-91) — memarg + lane
            84 => { try self.validateSimdLoadLane(reader, 0, 16); },
            85 => { try self.validateSimdLoadLane(reader, 1, 8); },
            86 => { try self.validateSimdLoadLane(reader, 2, 4); },
            87 => { try self.validateSimdLoadLane(reader, 3, 2); },
            88 => { try self.validateSimdStoreLane(reader, 0, 16); },
            89 => { try self.validateSimdStoreLane(reader, 1, 8); },
            90 => { try self.validateSimdStoreLane(reader, 2, 4); },
            91 => { try self.validateSimdStoreLane(reader, 3, 2); },

            else => {
                // Binary v128 ops (the majority): v128 x v128 -> v128
                // This covers: eq, ne, lt, gt, le, ge, add, sub, mul, and, or, xor, etc.
                // All take 2 x v128 and produce v128
                try self.popV128();
                try self.popV128();
                try self.pushVal(.v128);
            },
        }
    }

    fn validateSimdLoad(self: *Validator, reader: *Reader, natural_align: u5) !void {
        const align_byte = try reader.readU32();
        const align_val = align_byte & 0x3F;
        const has_memidx = (align_byte & 0x40) != 0;
        if (has_memidx) _ = try reader.readU32();
        _ = try reader.readU32(); // offset
        if (align_val > natural_align) return error.InvalidAlignment;
        try self.popI32(); // address
        try self.pushVal(.v128);
    }

    fn validateSimdLoadLane(self: *Validator, reader: *Reader, natural_align: u5, max_lanes: u8) !void {
        const align_byte = try reader.readU32();
        const align_val = align_byte & 0x3F;
        const has_memidx = (align_byte & 0x40) != 0;
        if (has_memidx) _ = try reader.readU32();
        _ = try reader.readU32(); // offset
        const lane = try reader.readByte();
        if (align_val > natural_align) return error.InvalidAlignment;
        if (lane >= max_lanes) return error.InvalidLaneIndex;
        try self.popV128(); // existing vector
        try self.popI32(); // address
        try self.pushVal(.v128);
    }

    fn validateSimdStoreLane(self: *Validator, reader: *Reader, natural_align: u5, max_lanes: u8) !void {
        const align_byte = try reader.readU32();
        const align_val = align_byte & 0x3F;
        const has_memidx = (align_byte & 0x40) != 0;
        if (has_memidx) _ = try reader.readU32();
        _ = try reader.readU32(); // offset
        const lane = try reader.readByte();
        if (align_val > natural_align) return error.InvalidAlignment;
        if (lane >= max_lanes) return error.InvalidLaneIndex;
        try self.popV128(); // vector value
        try self.popI32(); // address
    }

    fn validateLane(self: *Validator, reader: *Reader, max_lanes: u8) !void {
        _ = self;
        const lane = try reader.readByte();
        if (lane >= max_lanes) return error.InvalidLaneIndex;
    }

    // ---- Helpers ----

    fn getFuncType(self: *Validator, func_idx: u32) ?module_mod.FuncType {
        return self.module.getFuncType(func_idx);
    }

    fn getTagTypeIdx(self: *Validator, tag_idx: u32) ?u32 {
        if (tag_idx < self.module.num_imported_tags) {
            var import_tag_idx: u32 = 0;
            for (self.module.imports.items) |imp| {
                if (imp.kind == .tag) {
                    if (import_tag_idx == tag_idx) return imp.index;
                    import_tag_idx += 1;
                }
            }
            return null;
        }
        const local_idx = tag_idx - self.module.num_imported_tags;
        if (local_idx >= self.module.tags.items.len) return null;
        return self.module.tags.items[local_idx].type_idx;
    }

    fn getTableRefType(self: *Validator, idx: u32) ValType {
        if (idx < self.module.num_imported_tables) {
            var import_table_idx: u32 = 0;
            for (self.module.imports.items) |imp| {
                if (imp.kind == .table) {
                    if (import_table_idx == idx) {
                        const td = imp.table_type orelse return .funcref;
                        return if (td.reftype == .funcref) .funcref else .externref;
                    }
                    import_table_idx += 1;
                }
            }
            return .funcref;
        }
        const local_idx = idx - self.module.num_imported_tables;
        if (local_idx < self.module.tables.items.len) {
            return if (self.module.tables.items[local_idx].reftype == .funcref) .funcref else .externref;
        }
        return .funcref;
    }

    fn getGlobalType(self: *Validator, idx: u32) ?ConstGlobalInfo {
        if (idx < self.module.num_imported_globals) {
            var import_global_idx: u32 = 0;
            for (self.module.imports.items) |imp| {
                if (imp.kind == .global) {
                    if (import_global_idx == idx) {
                        // Import global has index field pointing to global def
                        // But for imports, the type info is in the import entry itself
                        const gt = imp.global_type orelse return null;
                        return .{ .valtype = gt.valtype, .mutability = gt.mutability };
                    }
                    import_global_idx += 1;
                }
            }
            return null;
        }
        const local_idx = idx - self.module.num_imported_globals;
        if (local_idx >= self.module.globals.items.len) return null;
        const g = self.module.globals.items[local_idx];
        return .{ .valtype = g.valtype, .mutability = g.mutability };
    }
};

/// Validate all functions and module sections.
pub fn validateModule(alloc: Allocator, mod: *const Module) ValidateError!void {
    // Section-level validation
    try validateTypeDefinitions(mod);
    try validateImports(mod);
    try validateExports(mod);
    try validateStart(mod);
    try validateTags(mod);
    try validateTables(mod);
    try validateDataSegments(mod);
    try validateElementSegments(mod);
    try validateElementSegmentTypes(mod);
    try validateGlobalInits(mod);

    // Check data count section required
    try validateDataCountRequired(mod);

    // Function body validation
    var v = Validator.init(alloc, mod);
    defer v.deinit();

    const total_funcs = mod.num_imported_funcs + mod.functions.items.len;
    var func_idx: usize = mod.num_imported_funcs;
    while (func_idx < total_funcs) : (func_idx += 1) {
        v.validateFunction(func_idx) catch |err| {
            return err;
        };
    }
}

fn validateDataCountRequired(mod: *const Module) ValidateError!void {
    if (mod.data_count != null) return; // data count present, OK
    // Scan code bodies for memory.init (0xFC 8) or data.drop (0xFC 9)
    for (mod.codes.items) |code| {
        var reader = Reader.init(code.body);
        while (reader.hasMore()) {
            const byte = reader.readByte() catch break;
            switch (byte) {
                0xFC => {
                    const sub_op = reader.readU32() catch break;
                    if (sub_op == 8 or sub_op == 9) return error.DataCountRequired;
                    // Skip immediates for other 0xFC ops
                    switch (sub_op) {
                        0...7 => {}, // trunc_sat — no extra immediates
                        10 => { // memory.copy — 2 byte immediates
                            _ = reader.readByte() catch break;
                            _ = reader.readByte() catch break;
                        },
                        11 => { _ = reader.readByte() catch break; }, // memory.fill — 1 byte
                        12 => { // table.init — u32 + u32
                            _ = reader.readU32() catch break;
                            _ = reader.readU32() catch break;
                        },
                        13 => { _ = reader.readU32() catch break; }, // elem.drop
                        14 => { // table.copy — u32 + u32
                            _ = reader.readU32() catch break;
                            _ = reader.readU32() catch break;
                        },
                        15, 16, 17 => { _ = reader.readU32() catch break; }, // table ops
                        else => {},
                    }
                },
                // Skip bytes consumed by other instructions
                0x02, 0x03, 0x04 => { _ = reader.readByte() catch break; }, // block types
                0x0C, 0x0D => { _ = reader.readU32() catch break; }, // br, br_if
                0x0E => { // br_table
                    const n = reader.readU32() catch break;
                    var idx: u32 = 0;
                    while (idx <= n) : (idx += 1) _ = reader.readU32() catch break;
                },
                0x10 => { _ = reader.readU32() catch break; }, // call
                0x11 => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; }, // call_indirect
                0x12 => { _ = reader.readU32() catch break; }, // return_call
                0x13 => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; }, // return_call_indirect
                0x1F => { _ = reader.readU32() catch break; }, // try_table — complex, skip
                0x20, 0x21, 0x22, 0x23, 0x24 => { _ = reader.readU32() catch break; }, // local/global
                0x25, 0x26 => { _ = reader.readU32() catch break; }, // table
                0xD0 => { _ = reader.readByte() catch break; }, // ref.null
                0xD2 => { _ = reader.readU32() catch break; }, // ref.func
                0x28...0x3E => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; }, // load/store memarg
                0x3F, 0x40 => { _ = reader.readByte() catch break; }, // memory.size/grow
                0x41 => { _ = reader.readI32() catch break; }, // i32.const
                0x42 => { _ = reader.readI64() catch break; }, // i64.const
                0x43 => { _ = reader.readBytes(4) catch break; }, // f32.const
                0x44 => { _ = reader.readBytes(8) catch break; }, // f64.const
                0xFD => { // SIMD prefix — skip variable-length
                    _ = reader.readU32() catch break;
                    // Most SIMD ops have no extra immediates, but some have memarg or lane
                    // Simplified: just skip the sub-opcode, let byte scanning continue
                },
                else => {},
            }
        }
    }
}

fn validateImports(mod: *const Module) ValidateError!void {
    for (mod.imports.items) |imp| {
        if (imp.kind == .func) {
            // import func: type index must be valid
            if (imp.index >= mod.types.items.len) return error.UnknownType;
        }
    }
}

fn validateExports(mod: *const Module) ValidateError!void {
    const total_funcs = mod.num_imported_funcs + mod.functions.items.len;
    const total_tables = mod.num_imported_tables + @as(u32, @intCast(mod.tables.items.len));
    const total_memories = mod.num_imported_memories + @as(u32, @intCast(mod.memories.items.len));
    const total_globals = mod.num_imported_globals + @as(u32, @intCast(mod.globals.items.len));

    for (mod.exports.items) |exp| {
        switch (exp.kind) {
            .func => if (exp.index >= total_funcs) return error.UnknownFunction,
            .table => if (exp.index >= total_tables) return error.UnknownTable,
            .memory => if (exp.index >= total_memories) return error.UnknownMemory,
            .global => if (exp.index >= total_globals) return error.UnknownGlobal,
            else => {},
        }
    }
}

fn validateStart(mod: *const Module) ValidateError!void {
    const start_idx = mod.start orelse return;
    const total_funcs = mod.num_imported_funcs + mod.functions.items.len;
    if (start_idx >= total_funcs) return error.UnknownFunction;

    // Start function must have type [] -> []
    var type_idx: u32 = undefined;
    if (start_idx < mod.num_imported_funcs) {
        var import_func_idx: u32 = 0;
        for (mod.imports.items) |imp| {
            if (imp.kind == .func) {
                if (import_func_idx == start_idx) {
                    type_idx = imp.index;
                    break;
                }
                import_func_idx += 1;
            }
        }
    } else {
        const local_idx = start_idx - mod.num_imported_funcs;
        if (local_idx >= mod.functions.items.len) return error.UnknownFunction;
        type_idx = mod.functions.items[local_idx].type_idx;
    }
    if (type_idx >= mod.types.items.len) return error.UnknownType;
    const ft = mod.types.items[type_idx].getFunc() orelse return error.UnknownType;
    if (ft.params.len != 0 or ft.results.len != 0) return error.TypeMismatch;
}

fn validateDataSegments(mod: *const Module) ValidateError!void {
    const total_memories = mod.num_imported_memories + @as(u32, @intCast(mod.memories.items.len));
    const total_globals = mod.num_imported_globals + @as(u32, @intCast(mod.globals.items.len));

    for (mod.datas.items) |seg| {
        switch (seg.mode) {
            .passive => {},
            .active => |a| {
                if (a.mem_idx >= total_memories) return error.UnknownMemory;
                // Determine expected type: i64 for memory64, i32 for memory32
                const expected_type: ValType = blk: {
                    if (a.mem_idx < mod.num_imported_memories) {
                        // Check imported memory for memory64
                        var import_mem_idx: u32 = 0;
                        for (mod.imports.items) |imp| {
                            if (imp.kind == .memory) {
                                if (import_mem_idx == a.mem_idx) {
                                    const md = imp.memory_type orelse break :blk .i32;
                                    break :blk if (md.limits.is_64) .i64 else .i32;
                                }
                                import_mem_idx += 1;
                            }
                        }
                        break :blk .i32;
                    }
                    const def_idx = a.mem_idx - mod.num_imported_memories;
                    if (def_idx < mod.memories.items.len) {
                        break :blk if (mod.memories.items[def_idx].limits.is_64) .i64 else .i32;
                    }
                    break :blk .i32;
                };
                try validateTypedConstExpr(mod, a.offset_expr, expected_type, total_globals);
            },
        }
    }
}

fn validateElementSegments(mod: *const Module) ValidateError!void {
    const total_tables = mod.num_imported_tables + @as(u32, @intCast(mod.tables.items.len));
    const total_funcs = mod.num_imported_funcs + mod.functions.items.len;
    const total_globals = mod.num_imported_globals + @as(u32, @intCast(mod.globals.items.len));

    for (mod.elements.items) |seg| {
        const seg_ref: ValType = if (seg.reftype == .funcref) .funcref else .externref;
        switch (seg.mode) {
            .passive, .declarative => {},
            .active => |a| {
                if (a.table_idx >= total_tables) return error.UnknownTable;
                // Element segment reftype must match table element type
                const table_ref = getTableRefType(mod, a.table_idx) orelse return error.UnknownTable;
                if (!seg_ref.eql(table_ref)) return error.TypeMismatch;
                try validateTypedConstExpr(mod, a.offset_expr, .i32, total_globals);
            },
        }
        // Validate func indices in element init
        switch (seg.init) {
            .func_indices => |indices| {
                for (indices) |idx| {
                    if (idx >= total_funcs) return error.UnknownFunction;
                }
            },
            .expressions => |exprs| {
                for (exprs) |expr| {
                    try validateRefConstExpr(mod, expr, seg_ref, total_globals);
                }
            },
        }
    }
}

fn validateGlobalInits(mod: *const Module) ValidateError!void {
    const total_globals_imported = mod.num_imported_globals;

    for (mod.globals.items, 0..) |g, i| {
        _ = i;
        try validateGlobalInitExpr(mod, g.init_expr, g.valtype, total_globals_imported);
    }
}

/// Validate a typed constant expression (e.g. data offset, element offset, global init).
/// Checks both type correctness and that the expression produces exactly 1 value.
fn validateTypedConstExpr(mod: *const Module, expr: []const u8, expected_type: ValType, total_globals: u32) ValidateError!void {
    if (expr.len == 0) return;
    var reader = Reader.init(expr);
    var stack_depth: i32 = 0;
    while (reader.hasMore()) {
        const byte = reader.readByte() catch return;
        switch (byte) {
            0x41 => { // i32.const
                _ = reader.readI32() catch return;
                if (!expected_type.eql(.i32)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0x42 => { // i64.const
                _ = reader.readI64() catch return;
                if (!expected_type.eql(.i64)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0x43 => { // f32.const
                _ = reader.readBytes(4) catch return;
                if (!expected_type.eql(.f32)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0x44 => { // f64.const
                _ = reader.readBytes(8) catch return;
                if (!expected_type.eql(.f64)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0x23 => { // global.get
                const idx = reader.readU32() catch return;
                if (idx >= total_globals) return error.UnknownGlobal;
                // Check global is immutable (required for const expressions)
                const gt = getGlobalInfo(mod, idx) orelse return error.UnknownGlobal;
                if (gt.mutability != 0) return error.ConstantExprRequired;
                // Check type matches expected
                if (!gt.valtype.eql(expected_type)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0xD0 => { // ref.null
                _ = reader.readByte() catch return;
                if (!expected_type.eql(.funcref) and !expected_type.eql(.externref) and !expected_type.eql(.exnref)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0xD2 => { // ref.func
                const idx = reader.readU32() catch return;
                const total_funcs = mod.num_imported_funcs + mod.functions.items.len;
                if (idx >= total_funcs) return error.UnknownFunction;
                if (!expected_type.eql(.funcref)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0xFD => { // v128.const
                const sub_op = reader.readU32() catch return;
                if (sub_op == 12) {
                    _ = reader.readBytes(16) catch return;
                    if (!expected_type.eql(.v128)) return error.TypeMismatch;
                    stack_depth += 1;
                }
            },
            // extended_const: i32/i64 arithmetic (pop 2, push 1 = net -1)
            0x6A, 0x6B, 0x6C => { // i32.add, i32.sub, i32.mul
                if (!expected_type.eql(.i32)) return error.TypeMismatch;
                stack_depth -= 1; // net: pop 2, push 1
            },
            0x7C, 0x7D, 0x7E => { // i64.add, i64.sub, i64.mul
                if (!expected_type.eql(.i64)) return error.TypeMismatch;
                stack_depth -= 1;
            },
            0x0B => { // end
                if (stack_depth != 1) return error.TypeMismatch;
                return;
            },
            else => return error.ConstantExprRequired,
        }
    }
}

/// Validate a ref-typed constant expression (element segment init).
fn validateRefConstExpr(mod: *const Module, expr: []const u8, expected_ref: ValType, total_globals: u32) ValidateError!void {
    if (expr.len == 0) return;
    var reader = Reader.init(expr);
    var stack_depth: i32 = 0;
    while (reader.hasMore()) {
        const byte = reader.readByte() catch return;
        switch (byte) {
            0xD0 => { // ref.null
                const rt = reader.readByte() catch return;
                const elem_type: ValType = ValType.fromByte(rt) orelse return error.TypeMismatch;
                if (!elem_type.eql(expected_ref)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0xD2 => { // ref.func
                const idx = reader.readU32() catch return;
                const total_funcs = mod.num_imported_funcs + mod.functions.items.len;
                if (idx >= total_funcs) return error.UnknownFunction;
                if (!expected_ref.eql(.funcref)) return error.TypeMismatch;
                stack_depth += 1;
            },
            0x23 => { // global.get
                const idx = reader.readU32() catch return;
                if (idx >= total_globals) return error.UnknownGlobal;
                const gt = getGlobalInfo(mod, idx) orelse return error.UnknownGlobal;
                if (gt.mutability != 0) return error.ConstantExprRequired;
                stack_depth += 1;
            },
            0x0B => { // end
                if (stack_depth != 1) return error.TypeMismatch;
                return;
            },
            else => return error.ConstantExprRequired,
        }
    }
}

fn getTableRefType(mod: *const Module, idx: u32) ?ValType {
    const opcode_mod = @import("opcode.zig");
    if (idx < mod.num_imported_tables) {
        var import_idx: u32 = 0;
        for (mod.imports.items) |imp| {
            if (imp.table_type) |tt| {
                if (import_idx == idx) return if (tt.reftype == opcode_mod.RefType.funcref) .funcref else .externref;
                import_idx += 1;
            }
        }
        return null;
    }
    const local_idx = idx - mod.num_imported_tables;
    if (local_idx >= mod.tables.items.len) return null;
    return if (mod.tables.items[local_idx].reftype == opcode_mod.RefType.funcref) .funcref else .externref;
}

fn getGlobalInfo(mod: *const Module, idx: u32) ?ConstGlobalInfo {
    if (idx < mod.num_imported_globals) {
        // Imported global
        var import_idx: u32 = 0;
        for (mod.imports.items) |imp| {
            if (imp.global_type) |gt| {
                if (import_idx == idx) return .{ .valtype = gt.valtype, .mutability = gt.mutability };
                import_idx += 1;
            }
        }
        return null;
    }
    const local_idx = idx - mod.num_imported_globals;
    if (local_idx >= mod.globals.items.len) return null;
    const g = mod.globals.items[local_idx];
    return .{ .valtype = g.valtype, .mutability = g.mutability };
}

fn validateGlobalInitExpr(mod: *const Module, expr: []const u8, expected_type: ValType, num_imported_globals: u32) ValidateError!void {
    // For global init, only imported globals are allowed (not same-module globals)
    try validateTypedConstExpr(mod, expr, expected_type, num_imported_globals);
}

/// Validate type definitions: type index bounds, supertype compatibility.
fn validateTypeDefinitions(mod: *const Module) ValidateError!void {
    // Build a mapping: for each type index, what is the end of its rec group?
    // Types can only reference indices within their own rec group or earlier groups.
    for (mod.types.items, 0..) |td, i| {
        // Find which rec group this type belongs to
        const max_valid_idx = recGroupEndForType(mod, @intCast(i));

        // Check supertype indices are valid
        for (td.super_types) |super_idx| {
            if (super_idx >= max_valid_idx) return error.UnknownType;
            // Super must have same composite kind and must not be final
            const super_td = mod.types.items[super_idx];
            if (super_td.is_final) return error.TypeMismatch; // can't subtype a final type
            // Check structural compatibility
            if (!isValidSubtype(mod, td, super_td)) return error.TypeMismatch;
        }

        // Check type index references within composite types
        switch (td.composite) {
            .struct_type => |st| {
                for (st.fields) |field| {
                    if (storageTypeIndex(field.storage)) |tidx| {
                        if (tidx >= max_valid_idx) return error.UnknownType;
                    }
                }
            },
            .array_type => |at| {
                if (storageTypeIndex(at.field.storage)) |tidx| {
                    if (tidx >= max_valid_idx) return error.UnknownType;
                }
            },
            .func => |ft| {
                for (ft.params) |p| {
                    if (isTypeIndexRef(p)) |tidx| {
                        if (tidx >= max_valid_idx) return error.UnknownType;
                    }
                }
                for (ft.results) |r| {
                    if (isTypeIndexRef(r)) |tidx| {
                        if (tidx >= max_valid_idx) return error.UnknownType;
                    }
                }
            },
        }
    }
}

/// Get the end index (exclusive) of valid type references for a type at the given index.
/// Types can reference: all types in their own rec group + all earlier rec groups.
fn recGroupEndForType(mod: *const Module, type_idx: u32) u32 {
    for (mod.rec_groups.items) |rg| {
        if (type_idx >= rg.start and type_idx < rg.start + rg.count) {
            return rg.start + rg.count; // end of current rec group
        }
    }
    // Fallback: if no rec group info, allow all types
    return @intCast(mod.types.items.len);
}

/// Check if a ValType references a type index, return it if so.
fn isTypeIndexRef(vt: ValType) ?u32 {
    return switch (vt) {
        .ref_type => |idx| if (idx < ValType.HEAP_NOEXN) idx else null,
        .ref_null_type => |idx| if (idx < ValType.HEAP_NOEXN) idx else null,
        else => null,
    };
}

/// Check if a StorageType contains a type index reference.
fn storageTypeIndex(st: module_mod.StorageType) ?u32 {
    return switch (st) {
        .val => |vt| isTypeIndexRef(vt),
        .i8, .i16 => null,
    };
}

/// Check if sub_td is a valid structural subtype of super_td.
fn isValidSubtype(mod: *const Module, sub_td: module_mod.TypeDef, super_td: module_mod.TypeDef) bool {
    _ = mod;
    return switch (sub_td.composite) {
        .func => |sub_ft| switch (super_td.composite) {
            .func => |super_ft| {
                // Function subtypes: params contravariant, results covariant
                if (sub_ft.params.len != super_ft.params.len) return false;
                if (sub_ft.results.len != super_ft.results.len) return false;
                for (sub_ft.params, super_ft.params) |a, b| {
                    if (!isValTypeSubtype(a, b)) return false;
                }
                for (sub_ft.results, super_ft.results) |a, b| {
                    if (!isValTypeSubtype(a, b)) return false;
                }
                return true;
            },
            else => false,
        },
        .struct_type => |sub_st| switch (super_td.composite) {
            .struct_type => |super_st| {
                // Struct subtypes: must have at least as many fields, first N must match
                if (sub_st.fields.len < super_st.fields.len) return false;
                for (super_st.fields, sub_st.fields[0..super_st.fields.len]) |super_f, sub_f| {
                    if (!fieldTypeMatch(sub_f, super_f)) return false;
                }
                return true;
            },
            else => false,
        },
        .array_type => |sub_at| switch (super_td.composite) {
            .array_type => |super_at| {
                return fieldTypeMatch(sub_at.field, super_at.field);
            },
            else => false,
        },
    };
}

/// Check if sub_field is a valid subtype of super_field.
fn fieldTypeMatch(sub_f: module_mod.FieldType, super_f: module_mod.FieldType) bool {
    if (sub_f.mutable != super_f.mutable) return false;
    if (sub_f.mutable) {
        // Mutable: storage types must be exactly equal
        return storageTypeEql(sub_f.storage, super_f.storage);
    } else {
        // Immutable: covariant (subtype relationship)
        return storageTypeSubtype(sub_f.storage, super_f.storage);
    }
}

fn storageTypeEql(a: module_mod.StorageType, b: module_mod.StorageType) bool {
    const tag_a: @typeInfo(module_mod.StorageType).@"union".tag_type.? = a;
    const tag_b: @typeInfo(module_mod.StorageType).@"union".tag_type.? = b;
    if (tag_a != tag_b) return false;
    return switch (a) {
        .val => |va| va.eql(b.val),
        .i8, .i16 => true, // same packed type
    };
}

fn storageTypeSubtype(sub: module_mod.StorageType, sup: module_mod.StorageType) bool {
    const tag_sub: @typeInfo(module_mod.StorageType).@"union".tag_type.? = sub;
    const tag_sup: @typeInfo(module_mod.StorageType).@"union".tag_type.? = sup;
    if (tag_sub != tag_sup) return false;
    return switch (sub) {
        .val => |va| isValTypeSubtype(va, sup.val),
        .i8, .i16 => true,
    };
}

/// Check if val type a is a subtype of val type b (a <: b).
fn isValTypeSubtype(a: ValType, b: ValType) bool {
    // Same type is always a subtype
    if (a.eql(b)) return true;
    // Bottom types are subtypes of everything in their hierarchy
    // none <: any/eq/i31/struct/array/func/extern (actually only same hierarchy)
    // Check heap type subtyping for ref types
    const a_heap = heapType(a);
    const b_heap = heapType(b);
    if (a_heap != null and b_heap != null) {
        // Nullable subtype of nullable, non-null subtype of nullable or non-null
        const a_null = isNullable(a);
        const b_null = isNullable(b);
        if (a_null and !b_null) return false; // nullable NOT <: non-nullable
        return isHeapSubtype(a_heap.?, b_heap.?);
    }
    return false;
}

fn heapType(vt: ValType) ?u32 {
    return switch (vt) {
        .funcref => ValType.HEAP_FUNC,
        .externref => ValType.HEAP_EXTERN,
        .exnref => ValType.HEAP_EXN,
        .ref_type => |idx| idx,
        .ref_null_type => |idx| idx,
        else => null,
    };
}

fn isNullable(vt: ValType) bool {
    return switch (vt) {
        .funcref, .externref, .exnref, .ref_null_type => true,
        .ref_type => false,
        else => false,
    };
}

/// Check if heap type a is a subtype of heap type b.
fn isHeapSubtype(a: u32, b: u32) bool {
    if (a == b) return true;
    const H = ValType;
    // Bottom types
    if (a == H.HEAP_NONE) return b == H.HEAP_ANY or b == H.HEAP_EQ or b == H.HEAP_I31 or
        b == H.HEAP_STRUCT or b == H.HEAP_ARRAY or b == H.HEAP_NONE;
    if (a == H.HEAP_NOFUNC) return b == H.HEAP_FUNC or b == H.HEAP_NOFUNC;
    if (a == H.HEAP_NOEXTERN) return b == H.HEAP_EXTERN or b == H.HEAP_NOEXTERN;
    if (a == H.HEAP_NOEXN) return b == H.HEAP_EXN or b == H.HEAP_NOEXN;
    // i31, struct, array <: eq <: any
    if (a == H.HEAP_I31) return b == H.HEAP_EQ or b == H.HEAP_ANY;
    if (a == H.HEAP_STRUCT) return b == H.HEAP_EQ or b == H.HEAP_ANY;
    if (a == H.HEAP_ARRAY) return b == H.HEAP_EQ or b == H.HEAP_ANY;
    if (a == H.HEAP_EQ) return b == H.HEAP_ANY;
    // Concrete type indices: $t <: struct/array/func/eq/any depending on composite kind
    if (a < H.HEAP_NOEXN) {
        // a is a concrete type index — it's a subtype of its abstract parent
        if (b == H.HEAP_ANY or b == H.HEAP_EQ) return true; // TODO: only if not func/extern
        if (b == H.HEAP_FUNC or b == H.HEAP_STRUCT or b == H.HEAP_ARRAY) return true;
        // Also check if b is a concrete type that a extends (via super_types chain)
        // For now: concrete <: abstract only
        return false;
    }
    return false;
}

/// Check if concrete type index `sub_idx` is a subtype of `super_idx` via supertype chain.
fn isConcreteSubtype(mod: *const Module, sub_idx: u32, super_idx: u32) bool {
    if (sub_idx == super_idx) return true;
    if (sub_idx >= mod.types.items.len) return false;
    // Walk supertype chain (max depth = number of types to prevent infinite loops)
    var current = sub_idx;
    var depth: u32 = 0;
    const max_depth = @as(u32, @intCast(mod.types.items.len));
    while (depth < max_depth) : (depth += 1) {
        if (current >= mod.types.items.len) return false;
        const td = mod.types.items[current];
        if (td.super_types.len == 0) return false;
        const parent = td.super_types[0];
        if (parent == super_idx) return true;
        current = parent;
    }
    return false;
}

/// Convert i33 heap type immediate to internal HEAP_* sentinel or concrete type index.
fn i33ToHeapType(raw: i64) u32 {
    if (raw >= 0) return @intCast(raw); // concrete type index
    const H = ValType;
    return switch (raw) {
        -16 => H.HEAP_FUNC,
        -17 => H.HEAP_EXTERN,
        -18 => H.HEAP_ANY,
        -19 => H.HEAP_EQ,
        -20 => H.HEAP_I31,
        -21 => H.HEAP_STRUCT,
        -22 => H.HEAP_ARRAY,
        -15 => H.HEAP_NONE,
        -13 => H.HEAP_NOFUNC,
        -14 => H.HEAP_NOEXTERN,
        -23 => H.HEAP_EXN,
        -12 => H.HEAP_NOEXN,
        else => H.HEAP_ANY, // fallback
    };
}

/// Check if heap type `a` is a subtype of `b`, supporting both abstract and concrete types.
fn isHeapSubtypeOf(mod: *const Module, a: u32, b: u32) bool {
    if (a == b) return true;
    // If both are abstract, use abstract hierarchy
    if (a >= ValType.HEAP_NOEXN and b >= ValType.HEAP_NOEXN) return isHeapSubtype(a, b);
    // If a is concrete and b is abstract
    if (a < ValType.HEAP_NOEXN and b >= ValType.HEAP_NOEXN) {
        // Check what kind of composite type a is
        if (a < mod.types.items.len) {
            const td = mod.types.items[a];
            return switch (td.composite) {
                .func => b == ValType.HEAP_FUNC,
                .struct_type => isHeapSubtype(ValType.HEAP_STRUCT, b),
                .array_type => isHeapSubtype(ValType.HEAP_ARRAY, b),
            };
        }
        return false;
    }
    // If a is concrete and b is concrete
    if (a < ValType.HEAP_NOEXN and b < ValType.HEAP_NOEXN) {
        return isConcreteSubtype(mod, a, b);
    }
    // a is abstract, b is concrete — never a subtype
    return false;
}

/// Check if a constant expression contains ref.func for a specific function index.
fn exprContainsRefFunc(expr: []const u8, func_idx: u32) bool {
    var reader = Reader.init(expr);
    while (reader.hasMore()) {
        const byte = reader.readByte() catch return false;
        if (byte == 0xD2) { // ref.func
            const idx = reader.readU32() catch return false;
            if (idx == func_idx) return true;
        } else if (byte == 0xD0) { // ref.null — skip heap type
            _ = reader.readByte() catch return false;
        } else if (byte == 0x23) { // global.get
            _ = reader.readU32() catch return false;
        }
        // 0x0B (end) or other: continue
    }
    return false;
}

/// Validate tag definitions: result type must be empty.
fn validateTags(mod: *const Module) ValidateError!void {
    // Check imported tags
    for (mod.imports.items) |imp| {
        if (imp.kind == .tag) {
            if (imp.index >= mod.types.items.len) return error.UnknownType;
            const ft = mod.types.items[imp.index].getFunc() orelse return error.TypeMismatch;
            if (ft.results.len != 0) return error.TypeMismatch;
        }
    }
    // Check local tags
    for (mod.tags.items) |tag| {
        if (tag.type_idx >= mod.types.items.len) return error.UnknownType;
        const ft = mod.types.items[tag.type_idx].getFunc() orelse return error.TypeMismatch;
        // Tags must have empty result type (exception handling spec)
        if (ft.results.len != 0) return error.TypeMismatch;
    }
}

/// Validate tables: type index bounds, non-nullable constraints, init expression type.
fn validateTables(mod: *const Module) ValidateError!void {
    const num_imported_globals = mod.num_imported_globals;
    // Validate imported tables
    for (mod.imports.items) |imp| {
        if (imp.kind == .table) {
            if (imp.table_type) |table| {
                if (isTypeIndexRef(table.full_reftype)) |tidx| {
                    if (tidx >= mod.types.items.len) return error.UnknownType;
                }
            }
        }
    }
    // Validate local tables
    for (mod.tables.items) |table| {
        // Check type index bounds in full reftype
        if (isTypeIndexRef(table.full_reftype)) |tidx| {
            if (tidx >= mod.types.items.len) return error.UnknownType;
        }
        // Non-nullable ref types require either init expression or zero-size table
        const frt = table.full_reftype;
        const is_non_nullable = switch (frt) {
            .ref_type => true,
            else => false,
        };
        if (is_non_nullable) {
            if (table.init_expr == null) {
                // No init expression — only valid if table size is 0
                // Any non-nullable table without initializer is invalid per spec
                return error.TypeMismatch;
            }
        }
        if (table.init_expr) |init_expr| {
            // Table init expression must produce a value that is a subtype of table element type
            validateTableInitExpr(mod, init_expr, table.full_reftype, num_imported_globals) catch return error.TypeMismatch;
        }
    }
}

/// Validate element segments: reftype must be subtype of target table's element type.
fn validateElementSegmentTypes(mod: *const Module) ValidateError!void {
    const total_tables = mod.num_imported_tables + @as(u32, @intCast(mod.tables.items.len));
    for (mod.elements.items) |seg| {
        // Check type index bounds in element reftype
        if (isTypeIndexRef(seg.full_reftype)) |tidx| {
            if (tidx >= mod.types.items.len) return error.UnknownType;
        }
        switch (seg.mode) {
            .active => |active| {
                if (active.table_idx >= total_tables) continue; // bounds checked elsewhere
                // Get target table's full reftype
                const table_frt = getTableFullRefType(mod, active.table_idx) orelse continue;
                // Element segment reftype must be a subtype of table element type
                if (!isValTypeSubtype(seg.full_reftype, table_frt)) return error.TypeMismatch;
            },
            else => {},
        }
    }
}

/// Get the full_reftype for a table by index (imported or local).
fn getTableFullRefType(mod: *const Module, idx: u32) ?ValType {
    if (idx < mod.num_imported_tables) {
        var table_count: u32 = 0;
        for (mod.imports.items) |imp| {
            if (imp.kind == .table) {
                if (table_count == idx) {
                    if (imp.table_type) |t| return t.full_reftype;
                    return null;
                }
                table_count += 1;
            }
        }
        return null;
    }
    const local_idx = idx - mod.num_imported_tables;
    if (local_idx < mod.tables.items.len) return mod.tables.items[local_idx].full_reftype;
    return null;
}

/// Validate table_copy: source and destination table element types must be compatible.
fn validateTableCopyTypes(mod: *const Module) ValidateError!void {
    _ = mod;
    // table.copy type checking is done in opcode validation (validateMiscOp)
}

/// Validate table init expression type against the table's full element type.
fn validateTableInitExpr(mod: *const Module, expr: []const u8, expected: ValType, total_globals: u32) ValidateError!void {
    if (expr.len == 0) return;
    var reader = Reader.init(expr);
    while (reader.hasMore()) {
        const byte = reader.readByte() catch return;
        switch (byte) {
            0xD0 => { // ref.null — produces nullable ref
                const ht_byte = reader.readByte() catch return;
                // ref.null produces a nullable ref. If expected is non-nullable, it's a mismatch.
                if (!isNullable(expected)) return error.TypeMismatch;
                // Check heap type family compatibility
                const null_ht = refNullHeapType(ht_byte);
                const exp_ht = heapType(expected) orelse return error.TypeMismatch;
                if (!isHeapSubtypeOf(mod, null_ht, exp_ht)) return error.TypeMismatch;
            },
            0xD2 => { // ref.func — produces (ref func_type)
                const idx = reader.readU32() catch return;
                const total_funcs = mod.num_imported_funcs + mod.functions.items.len;
                if (idx >= total_funcs) return error.UnknownFunction;
                // ref.func produces a non-nullable typed func ref
                // Check if that's compatible with expected table type
                const exp_ht = heapType(expected) orelse return error.TypeMismatch;
                if (exp_ht != ValType.HEAP_FUNC and exp_ht != ValType.HEAP_ANY and exp_ht != ValType.HEAP_EQ) {
                    // Expected is a concrete type — check func's type matches
                    if (exp_ht < ValType.HEAP_NOEXN) {
                        // Expected is a concrete type index; would need to check func's type
                        // For now accept if both are in the func family
                    }
                }
            },
            0x23 => { // global.get
                const idx = reader.readU32() catch return;
                if (idx >= total_globals) return error.UnknownGlobal;
                const gt = getGlobalInfo(mod, idx) orelse return error.UnknownGlobal;
                if (gt.mutability != 0) return error.ConstantExprRequired;
                if (!isValTypeSubtype(gt.valtype, expected)) return error.TypeMismatch;
            },
            0xFB => { // GC prefix
                _ = reader.readU32() catch return; // sub-opcode
                // GC const exprs (struct.new, array.new_fixed, etc.) — skip validation
            },
            0x0B => return, // end
            else => return error.ConstantExprRequired,
        }
    }
}

/// Get the heap type sentinel from a ref.null's type byte.
fn refNullHeapType(byte: u8) u32 {
    return switch (byte) {
        0x70 => ValType.HEAP_FUNC,
        0x6F => ValType.HEAP_EXTERN,
        0x69 => ValType.HEAP_EXN,
        0x6E => ValType.HEAP_ANY,
        0x6D => ValType.HEAP_EQ,
        0x6C => ValType.HEAP_I31,
        0x6B => ValType.HEAP_STRUCT,
        0x6A => ValType.HEAP_ARRAY,
        0x71 => ValType.HEAP_NONE,
        0x73 => ValType.HEAP_NOFUNC,
        0x72 => ValType.HEAP_NOEXTERN,
        0x74 => ValType.HEAP_NOEXN,
        else => ValType.HEAP_ANY,
    };
}

// ---- Tests ----

const testing = std.testing;

test "validate — simple i32 add function" {
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // header
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // type: (i32,i32)->i32
        0x03, 0x02, 0x01, 0x00, // func section: 1 func, type 0
        0x0a, 0x09, 0x01, 0x07, 0x00, // code section: 1 body, 7 bytes, 0 locals
        0x20, 0x00, // local.get 0
        0x20, 0x01, // local.get 1
        0x6a, // i32.add
        0x0b, // end
    };
    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();
    try validateModule(testing.allocator, &mod);
}

test "validate — type mismatch detected" {
    // Function body: local.get 0 (i32) + f32.neg (expects f32) = type error
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x01, 0x7f, 0x00, // type: (i32)->()
        0x03, 0x02, 0x01, 0x00,
        0x0a, 0x07, 0x01, 0x05, 0x00,
        0x20, 0x00, // local.get 0 (i32)
        0x8c, // f32.neg — expects f32 on stack
        0x1a, // drop
        0x0b,
    };
    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();
    try testing.expectError(error.TypeMismatch, validateModule(testing.allocator, &mod));
}
