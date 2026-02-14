// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! Wasm stack-based VM — switch-based dispatch for all MVP opcodes.
//!
//! Design: direct bytecode execution (no IR). LEB128 immediates decoded inline.
//! Branch targets pre-computed on function entry via side table.
//! Cross-compile friendly: no .always_tail, pure switch dispatch.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const leb128 = @import("leb128.zig");
const Reader = leb128.Reader;
const opcode = @import("opcode.zig");
const Opcode = opcode.Opcode;
const ValType = opcode.ValType;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const WasmMemory = @import("memory.zig").Memory;
const module_mod = @import("module.zig");
const Module = module_mod.Module;
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const predecode_mod = @import("predecode.zig");
const PreInstr = predecode_mod.PreInstr;
const regalloc_mod = @import("regalloc.zig");
const RegInstr = regalloc_mod.RegInstr;
pub const jit_mod = @import("jit.zig");
const guard_mod = @import("guard.zig");
pub const trace_mod = @import("trace.zig");

pub const WasmError = error{
    Trap,
    StackOverflow,
    StackUnderflow,
    DivisionByZero,
    IntegerOverflow,
    InvalidConversion,
    OutOfBoundsMemoryAccess,
    UndefinedElement,
    MismatchedSignatures,
    Unreachable,
    OutOfMemory,
    FunctionIndexOutOfBounds,
    MemoryIndexOutOfBounds,
    TableIndexOutOfBounds,
    GlobalIndexOutOfBounds,
    BadFunctionIndex,
    BadMemoryIndex,
    BadTableIndex,
    BadGlobalIndex,
    InvalidWasm,
    InvalidInitExpr,
    ImportNotFound,
    ModuleNotDecoded,
    FunctionCodeMismatch,
    InvalidTypeIndex,
    BadElemAddr,
    BadDataAddr,
    EndOfStream,
    Overflow,
    OutOfBounds,
    FileNotFound,
    ElemIndexOutOfBounds,
    DataIndexOutOfBounds,
    /// Internal signal: back-edge counting triggered JIT compilation mid-execution.
    /// callFunction catches this and re-executes the function via JIT.
    JitRestart,
    /// Wasm exception thrown via `throw`/`throw_ref` — not caught by any try_table.
    WasmException,
    FuelExhausted,
};

const OPERAND_STACK_SIZE = 4096;
const FRAME_STACK_SIZE = 1024;
const LABEL_STACK_SIZE = 4096;

const Frame = struct {
    locals_start: usize, // index into operand stack where locals begin
    locals_count: usize, // total locals (params + locals)
    return_arity: usize,
    op_stack_base: usize, // operand stack base for this frame
    label_stack_base: usize,
    return_reader: Reader, // reader position to return to
    instance: *Instance,
};

const MAX_CATCH_CLAUSES = 8;

const CatchClause = struct {
    kind: u8, // 0x00=catch, 0x01=catch_ref, 0x02=catch_all, 0x03=catch_all_ref
    tag_id: u64, // for catch/catch_ref: globally unique tag identity
    label_depth: u32, // relative label depth to branch to when matched
};

const Label = struct {
    arity: usize,
    op_stack_base: usize,
    target: LabelTarget,
    // Exception handling: catch clauses for try_table labels
    catch_count: u8 = 0,
    catches: [MAX_CATCH_CLAUSES]CatchClause = undefined,
};

const LabelTarget = union(enum) {
    /// For block/if: jump past end (continue)
    forward: Reader, // reader state at the end opcode
    /// For loop: jump to loop header
    loop_start: Reader, // reader state at loop body start
    /// IR variants: jump targets are u32 indices into PreInstr array
    ir_forward: u32,
    ir_loop_start: u32,
};

/// Pre-computed branch target info for a function.
/// Maps bytecode offset → branch target offset.
pub const BranchTable = struct {
    /// block/if/loop start offset → end offset (position after the 'end' opcode)
    end_targets: std.AutoHashMapUnmanaged(usize, usize),
    /// if start offset → else body offset (position after the 'else' opcode)
    else_targets: std.AutoHashMapUnmanaged(usize, usize),
    alloc: Allocator,

    pub fn init(alloc: Allocator) BranchTable {
        return .{
            .end_targets = .empty,
            .else_targets = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *BranchTable) void {
        self.end_targets.deinit(self.alloc);
        self.else_targets.deinit(self.alloc);
    }
};

/// Compute branch target table for a function's bytecode.
/// Scans the code once and records block/if/loop → end/else offsets.
pub fn computeBranchTable(alloc: Allocator, code: []const u8) !*BranchTable {
    const bt = try alloc.create(BranchTable);
    bt.* = BranchTable.init(alloc);
    errdefer {
        bt.deinit();
        alloc.destroy(bt);
    }

    // Stack of (opcode_type, body_start_offset) for nesting
    const StructEntry = struct { kind: enum { block, loop, @"if" }, offset: usize };
    var stack: std.ArrayList(StructEntry) = .empty;
    defer stack.deinit(alloc);

    var reader = Reader.init(code);
    while (reader.hasMore()) {
        const pos_before = reader.pos;
        const byte = reader.readByte() catch break;
        const op: Opcode = @enumFromInt(byte);

        switch (op) {
            .block => {
                _ = readBlockType(&reader) catch break;
                // Record body start (after block type) — this is where block body begins
                try stack.append(alloc,.{ .kind = .block, .offset = reader.pos });
            },
            .loop => {
                _ = readBlockType(&reader) catch break;
                try stack.append(alloc,.{ .kind = .loop, .offset = reader.pos });
            },
            .@"if" => {
                _ = readBlockType(&reader) catch break;
                try stack.append(alloc,.{ .kind = .@"if", .offset = reader.pos });
            },
            .@"else" => {
                // Map the if's body_start → else body position
                if (stack.items.len > 0) {
                    const top = &stack.items[stack.items.len - 1];
                    if (top.kind == .@"if") {
                        try bt.else_targets.put(alloc, top.offset, reader.pos);
                    }
                }
            },
            .end => {
                if (stack.pop()) |entry| {
                    // Map body_start → position after end opcode
                    try bt.end_targets.put(alloc, entry.offset, reader.pos);
                }
                // else: function-level end, ignore
            },
            // Skip immediates for all other opcodes
            .br, .br_if, .br_on_null, .br_on_non_null => _ = reader.readU32() catch break,
            .br_table => {
                const count = reader.readU32() catch break;
                for (0..count + 1) |_| _ = reader.readU32() catch break;
            },
            .call, .return_call, .local_get, .local_set, .local_tee,
            .global_get, .global_set, .ref_func, .table_get, .table_set,
            .call_ref, .return_call_ref,
            => _ = reader.readU32() catch break,
            .call_indirect, .return_call_indirect => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
            .throw => _ = reader.readU32() catch break, // tag index
            .throw_ref => {},
            .try_table => {
                // blocktype + catch clause vector
                _ = readBlockType(&reader) catch break;
                const n_catches = reader.readU32() catch break;
                for (0..n_catches) |_| {
                    _ = reader.readByte() catch break; // catch kind
                    const catch_kind = reader.bytes[reader.pos - 1];
                    if (catch_kind == 0x00 or catch_kind == 0x01) _ = reader.readU32() catch break; // tag index
                    _ = reader.readU32() catch break; // label index
                }
                try stack.append(alloc, .{ .kind = .block, .offset = reader.pos });
            },
            .select_t => { const n = reader.readU32() catch break; for (0..n) |_| _ = reader.readByte() catch break; },
            .i32_const => _ = reader.readI32() catch break,
            .i64_const => _ = reader.readI64() catch break,
            .f32_const => _ = reader.readBytes(4) catch break,
            .f64_const => _ = reader.readBytes(8) catch break,
            .i32_load, .i64_load, .f32_load, .f64_load,
            .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u,
            .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u,
            .i64_load32_s, .i64_load32_u,
            .i32_store, .i64_store, .f32_store, .f64_store,
            .i32_store8, .i32_store16,
            .i64_store8, .i64_store16, .i64_store32,
            => {
                const align_flags = reader.readU32() catch break;
                if (align_flags & 0x40 != 0) _ = reader.readU32() catch break; // memidx
                _ = reader.readU32() catch break; // offset
            },
            .memory_size, .memory_grow => _ = reader.readU32() catch break,
            .ref_null => _ = reader.readI33() catch break,
            .misc_prefix => {
                const sub = reader.readU32() catch break;
                switch (sub) {
                    0x0A => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; }, // memory.copy
                    0x0B => _ = reader.readU32() catch break, // memory.fill
                    0x08 => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; }, // memory.init
                    0x09 => _ = reader.readU32() catch break,
                    0x0C => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
                    0x0D => _ = reader.readU32() catch break,
                    0x0E => { _ = reader.readU32() catch break; _ = reader.readU32() catch break; },
                    0x0F => _ = reader.readU32() catch break,
                    0x10 => _ = reader.readU32() catch break,
                    0x11 => _ = reader.readU32() catch break,
                    else => {},
                }
            },
            .gc_prefix => skipGcImmediates(&reader) catch break,
            .simd_prefix => skipSimdImmediates(&reader) catch break,
            .atomic_prefix => skipAtomicImmediates(&reader) catch break,
            else => {},
        }
        _ = pos_before;
    }

    return bt;
}


/// Profiling data collected during execution.
pub const Profile = struct {
    opcode_counts: [256]u64,
    misc_counts: [32]u64,
    call_count: u64,
    total_instrs: u64,

    pub fn init() Profile {
        return .{
            .opcode_counts = [_]u64{0} ** 256,
            .misc_counts = [_]u64{0} ** 32,
            .call_count = 0,
            .total_instrs = 0,
        };
    }
};

/// Maximum exception payload values (16 should cover all practical cases).
const MAX_EXCEPTION_VALUES = 16;

/// In-flight exception data stored in VM during exception propagation.
const PendingException = struct {
    tag_id: u64, // globally unique tag identity
    values: [MAX_EXCEPTION_VALUES]u64,
    value_count: usize,
};

pub const REG_STACK_SIZE = 32768; // register file storage for register IR (256KB)

pub const Vm = struct {
    op_stack: [OPERAND_STACK_SIZE]u128,
    op_ptr: usize,
    frame_stack: [FRAME_STACK_SIZE]Frame,
    frame_ptr: usize,
    label_stack: [LABEL_STACK_SIZE]Label,
    label_ptr: usize,
    reg_stack: [REG_STACK_SIZE]u64,
    reg_ptr: usize,
    alloc: Allocator,
    current_instance: ?*Instance = null,
    current_branch_table: ?*BranchTable = null,
    pending_exception: ?PendingException = null,
    profile: ?*Profile = null,
    trace: ?*trace_mod.TraceConfig = null,
    max_memory_bytes: ?u64 = null,
    fuel: ?u64 = null,

    // Tail call support: when return_call is executed, the callee's func_ptr
    // is stored here and execute() returns normally. doCallDirect() then
    // loops to re-enter the new callee instead of returning.
    tail_call_func: ?*store_mod.Function = null,
    tail_call_args: [16]u64 = undefined,
    tail_call_arg_count: usize = 0,

    pub fn init(alloc: Allocator) Vm {
        return .{
            .op_stack = undefined,
            .op_ptr = 0,
            .frame_stack = undefined,
            .frame_ptr = 0,
            .label_stack = undefined,
            .label_ptr = 0,
            .reg_stack = undefined,
            .reg_ptr = 0,
            .alloc = alloc,
        };
    }

    /// Reset VM state for reuse — avoids reallocating the large stack arrays.
    pub fn reset(self: *Vm) void {
        self.op_ptr = 0;
        self.frame_ptr = 0;
        self.label_ptr = 0;
        self.reg_ptr = 0;
        self.current_instance = null;
        self.current_branch_table = null;
        self.pending_exception = null;
    }

    /// Invoke an exported function by name.
    pub fn invoke(
        self: *Vm,
        instance: *Instance,
        name: []const u8,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        const func_addr = instance.getExportFunc(name) orelse return error.FunctionIndexOutOfBounds;
        const func_ptr = try instance.store.getFunctionPtr(func_addr);
        try self.callFunction(instance, func_ptr, args, results);
    }

    /// Invoke a function by its module-local index (used for start functions).
    pub fn invokeByIndex(
        self: *Vm,
        instance: *Instance,
        func_idx: u32,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        const func_ptr = try instance.getFuncPtr(func_idx);
        try self.callFunction(instance, func_ptr, args, results);
    }

    /// Call a function (wasm or host) with given args, writing results.
    pub fn callFunction(
        self: *Vm,
        instance: *Instance,
        func_ptr: *store_mod.Function,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        if (self.profile) |p| p.call_count += 1;
        switch (func_ptr.subtype) {
            .wasm_function => |*wf| {
                const base = self.op_ptr;

                // Lazy IR predecoding (try IR first, fall back to branch table)
                if (wf.ir == null and !wf.ir_failed) {
                    wf.ir = predecode_mod.predecode(self.alloc, wf.code) catch null;
                    if (wf.ir == null) wf.ir_failed = true;
                }

                const inst: *Instance = @ptrCast(@alignCast(wf.instance));

                // Check if function has v128 params (skip regir/jit for top-level v128 calls)
                const has_v128 = blk: {
                    for (func_ptr.params) |pt| {
                        if (pt == .v128) break :blk true;
                    }
                    for (func_ptr.results) |rt| {
                        if (rt == .v128) break :blk true;
                    }
                    break :blk false;
                };

                // Try register IR conversion (requires predecoded IR)
                // Skip for: multi-value return, v128 params/results (u64 regs can't hold v128)
                if (wf.ir != null and wf.reg_ir == null and !wf.reg_ir_failed and
                    func_ptr.results.len <= 1 and !has_v128)
                {
                    const resolver = regalloc_mod.ParamResolver{
                        .ctx = @ptrCast(inst),
                        .resolve_fn = struct {
                            fn resolve(ctx: *anyopaque, func_idx: u32) ?regalloc_mod.FuncTypeInfo {
                                const i: *Instance = @ptrCast(@alignCast(ctx));
                                const fp = i.getFuncPtr(func_idx) catch return null;
                                return .{
                                    .param_count = @intCast(fp.params.len),
                                    .result_count = @intCast(fp.results.len),
                                };
                            }
                        }.resolve,
                        .resolve_type_fn = struct {
                            fn resolve(ctx: *anyopaque, type_idx: u32) ?regalloc_mod.FuncTypeInfo {
                                const i: *Instance = @ptrCast(@alignCast(ctx));
                                const t = i.module.getTypeFunc(type_idx) orelse return null;
                                return .{
                                    .param_count = @intCast(t.params.len),
                                    .result_count = @intCast(t.results.len),
                                };
                            }
                        }.resolve,
                    };
                    wf.reg_ir = regalloc_mod.convert(
                        self.alloc,
                        wf.ir.?.code,
                        wf.ir.?.pool64,
                        @intCast(func_ptr.params.len),
                        @intCast(wf.locals_count),
                        resolver,
                    ) catch null;
                    if (wf.reg_ir == null) {
                        wf.reg_ir_failed = true;
                        if (self.trace) |tc| trace_mod.traceRegirBail(tc, wf.func_idx, "conversion failed");
                    } else {
                        if (self.trace) |tc| trace_mod.traceRegirConvert(tc, wf.func_idx, @intCast(wf.ir.?.code.len), @intCast(wf.reg_ir.?.code.len), wf.reg_ir.?.reg_count);
                    }
                }

                if (has_v128) {
                    // Skip RegIR/JIT for v128 params — fall through to stack path
                } else if (wf.reg_ir) |reg| {
                    // Dump RegIR if requested (one-shot)
                    if (self.trace) |tc| {
                        if (tc.dump_regir_func) |dump_idx| {
                            if (dump_idx == wf.func_idx) {
                                var err_buf2: [4096]u8 = undefined;
                                var ew = std.fs.File.stderr().writer(&err_buf2);
                                trace_mod.dumpRegIR(&ew.interface, reg, wf.ir.?.pool64, wf.func_idx);
                                tc.dump_regir_func = null;
                            }
                        }
                    }

                    // JIT compilation: check hot threshold (skip when profiling)
                    if (comptime jit_mod.jitSupported()) {
                        if (self.profile == null and
                            wf.jit_code == null and !wf.jit_failed)
                        {
                            wf.call_count += 1;
                            if (wf.call_count >= jit_mod.HOT_THRESHOLD) {
                                wf.jit_code = jit_mod.compileFunction(self.alloc, reg, wf.ir.?.pool64, wf.func_idx, @intCast(func_ptr.params.len), @intCast(func_ptr.results.len), self.trace, jit_mod.getMinMemoryBytes(inst), jit_mod.getUseGuardPages(inst));
                                if (wf.jit_code == null) {
                                    wf.jit_failed = true;
                                    if (self.trace) |tc| trace_mod.traceJitBail(tc, wf.func_idx, "compilation failed");
                                } else {
                                    if (self.trace) |tc| trace_mod.traceJitCompile(tc, wf.func_idx, @intCast(reg.code.len), @intCast(wf.jit_code.?.buf.len));
                                }
                            }
                        }
                    }

                    // JIT path: execute native code (skip when profiling)
                    if (self.profile == null) {
                        if (wf.jit_code) |jc| {
                            if (self.trace) |tc| trace_mod.traceExecTier(tc, wf.func_idx, "jit", wf.call_count);
                            try self.executeJIT(jc, reg, inst, func_ptr, args, results);
                            return;
                        }
                    }

                    // Register IR path: register file instead of operand stack
                    // Back-edge counting may trigger JitRestart → re-execute via JIT
                    if (self.trace) |tc| trace_mod.traceExecTier(tc, wf.func_idx, "regir", wf.call_count);
                    self.executeRegIR(reg, wf.ir.?.pool64, inst, func_ptr, args, results) catch |err| {
                        if (err == error.JitRestart) {
                            if (wf.jit_code) |jc| {
                                if (self.trace) |tc| trace_mod.traceJitRestart(tc, wf.func_idx);
                                try self.executeJIT(jc, reg, inst, func_ptr, args, results);
                                return;
                            }
                        }
                        return err;
                    };
                    return;
                }

                // Stack-based paths: push args and locals to operand stack
                // v128 params consume 2 u64 slots in the args array
                {
                    var arg_idx: usize = 0;
                    for (func_ptr.params) |ptype| {
                        if (ptype == .v128 and arg_idx + 1 < args.len) {
                            const lo: u128 = args[arg_idx];
                            const hi: u128 = args[arg_idx + 1];
                            try self.pushV128(lo | (hi << 64));
                            arg_idx += 2;
                        } else if (arg_idx < args.len) {
                            try self.push(args[arg_idx]);
                            arg_idx += 1;
                        } else {
                            try self.push(0);
                        }
                    }
                }
                const param_slots = func_ptr.params.len;
                for (0..wf.locals_count) |_| try self.push(0);

                // Push frame
                try self.pushFrame(.{
                    .locals_start = base,
                    .locals_count = param_slots + wf.locals_count,
                    .return_arity = func_ptr.results.len,
                    .op_stack_base = base,
                    .label_stack_base = self.label_ptr,
                    .return_reader = Reader.init(&.{}),
                    .instance = @ptrCast(@alignCast(wf.instance)),
                });

                if (wf.ir) |ir| {
                    // IR path: fixed-width dispatch
                    try self.pushLabel(.{
                        .arity = func_ptr.results.len,
                        .op_stack_base = base + param_slots + wf.locals_count,
                        .target = .{ .ir_forward = @intCast(ir.code.len) },
                    });
                    try self.executeIR(ir.code, ir.pool64, inst);
                } else {
                    // Fallback: old bytecode path with branch table
                    if (wf.branch_table == null) {
                        wf.branch_table = computeBranchTable(self.alloc, wf.code) catch null;
                    }
                    self.current_branch_table = wf.branch_table;

                    var body_reader = Reader.init(wf.code);
                    try self.pushLabel(.{
                        .arity = func_ptr.results.len,
                        .op_stack_base = base + param_slots + wf.locals_count,
                        .target = .{ .forward = body_reader },
                    });
                    try self.execute(&body_reader, inst);
                }

                // Tail call loop: if execute() set tail_call_func, reuse frame
                while (self.tail_call_func) |next_fp| {
                    // Unwind current frame
                    const frame = self.popFrame();
                    self.label_ptr = frame.label_stack_base;
                    self.op_ptr = base;

                    // Push tail call args as new params
                    for (0..self.tail_call_arg_count) |i| {
                        try self.push(self.tail_call_args[i]);
                    }

                    self.tail_call_func = null;
                    const next_wf = &next_fp.subtype.wasm_function;
                    const next_inst: *Instance = @ptrCast(@alignCast(next_wf.instance));

                    // Zero-initialize callee locals
                    for (0..next_wf.locals_count) |_| try self.push(0);

                    // Push new frame
                    try self.pushFrame(.{
                        .locals_start = base,
                        .locals_count = next_fp.params.len + next_wf.locals_count,
                        .return_arity = next_fp.results.len,
                        .op_stack_base = base,
                        .label_stack_base = self.label_ptr,
                        .return_reader = Reader.init(&.{}),
                        .instance = next_inst,
                    });

                    if (next_wf.ir) |ir| {
                        try self.pushLabel(.{
                            .arity = next_fp.results.len,
                            .op_stack_base = base + next_fp.params.len + next_wf.locals_count,
                            .target = .{ .ir_forward = @intCast(ir.code.len) },
                        });
                        try self.executeIR(ir.code, ir.pool64, next_inst);
                    } else {
                        if (next_wf.branch_table == null) {
                            next_wf.branch_table = computeBranchTable(self.alloc, next_wf.code) catch null;
                        }
                        self.current_branch_table = next_wf.branch_table;

                        var body_reader = Reader.init(next_wf.code);
                        try self.pushLabel(.{
                            .arity = next_fp.results.len,
                            .op_stack_base = base + next_fp.params.len + next_wf.locals_count,
                            .target = .{ .forward = body_reader },
                        });
                        try self.execute(&body_reader, next_inst);
                    }
                }

                // Copy results (v128 uses 2 u64 slots in results array)
                const result_slots = func_ptr.results.len; // wasm-level result count
                const result_start = self.op_ptr - result_slots;
                {
                    var result_idx: usize = 0;
                    for (func_ptr.results, 0..) |rtype, slot| {
                        if (rtype == .v128) {
                            const v: u128 = self.op_stack[result_start + slot];
                            if (result_idx < results.len) results[result_idx] = @truncate(v);
                            if (result_idx + 1 < results.len) results[result_idx + 1] = @truncate(v >> 64);
                            result_idx += 2;
                        } else {
                            if (result_idx < results.len) results[result_idx] = @truncate(self.op_stack[result_start + slot]);
                            result_idx += 1;
                        }
                    }
                }
                self.op_ptr = base;
            },
            .host_function => |hf| {
                // Push args
                const base = self.op_ptr;
                for (args) |arg| try self.push(arg);

                // Call host function
                self.current_instance = instance;
                hf.func(@ptrCast(self), hf.context) catch return error.Trap;

                // Pop results
                for (results, 0..) |*r, i| {
                    if (base + i < self.op_ptr)
                        r.* = @truncate(self.op_stack[base + i])
                    else
                        r.* = 0;
                }
                self.op_ptr = base;
            },
        }
    }

    // ================================================================
    // GC collection trigger
    // ================================================================

    /// Check if GC collection is needed and run it if so.
    /// Scans op_stack, reg_stack, and globals for GC roots.
    fn tryCollectGarbage(self: *Vm, store: *store_mod.Store) void {
        if (!store.gc_heap.shouldCollect()) return;
        store.gc_heap.clearMarks();
        // Mark from op_stack (u128 — GC refs in low 64 bits)
        store.gc_heap.markRootsWide(self.op_stack[0..self.op_ptr]) catch {};
        // Mark from reg_stack (u64)
        store.gc_heap.markRoots(self.reg_stack[0..self.reg_ptr]) catch {};
        // Mark from globals (extract u64 from u128 values)
        if (store.globals.items.len > 0) {
            var g_roots = store.gc_heap.alloc.alloc(u64, store.globals.items.len) catch {
                // If OOM, skip global scanning — still correct, just may collect too much
                store.gc_heap.sweep();
                store.gc_heap.alloc_since_gc = 0;
                return;
            };
            defer store.gc_heap.alloc.free(g_roots);
            for (store.globals.items, 0..) |g, i| {
                g_roots[i] = @truncate(g.value);
            }
            store.gc_heap.markRoots(g_roots) catch {};
        }
        store.gc_heap.sweep();
        store.gc_heap.alloc_since_gc = 0;
    }

    // ================================================================
    // Main execution loop
    // ================================================================

    fn execute(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        while (reader.hasMore()) {
            const byte = try reader.readByte();
            const op: Opcode = @enumFromInt(byte);

            if (self.fuel) |*f| {
                if (f.* == 0) return error.FuelExhausted;
                f.* -= 1;
            }

            if (self.profile) |p| {
                p.opcode_counts[byte] += 1;
                p.total_instrs += 1;
            }

            switch (op) {
                // ---- Control flow ----
                .@"unreachable" => return error.Unreachable,
                .nop => {},
                .block => {
                    const bt = try readBlockType(reader);
                    const result_arity = blockTypeArity(bt, instance);
                    const body_start = reader.pos;
                    var end_reader: Reader = undefined;
                    if (self.current_branch_table) |cbt| {
                        if (cbt.end_targets.get(body_start)) |end_pos| {
                            end_reader = .{ .bytes = reader.bytes, .pos = end_pos };
                        } else {
                            end_reader = reader.*;
                            try skipToEnd(&end_reader);
                        }
                    } else {
                        end_reader = reader.*;
                        try skipToEnd(&end_reader);
                    }
                    try self.pushLabel(.{
                        .arity = result_arity,
                        .op_stack_base = self.op_ptr,
                        .target = .{ .forward = end_reader },
                    });
                },
                .loop => {
                    const bt = try readBlockType(reader);
                    // Loop branch arity = params count (values passed back on br)
                    const param_arity = blockTypeParamArity(bt, instance);
                    const loop_reader = reader.*;
                    try self.pushLabel(.{
                        .arity = param_arity,
                        .op_stack_base = self.op_ptr - param_arity,
                        .target = .{ .loop_start = loop_reader },
                    });
                },
                .@"if" => {
                    const bt = try readBlockType(reader);
                    const result_arity = blockTypeArity(bt, instance);
                    const cond = self.popI32();
                    const body_start = reader.pos;
                    var end_reader: Reader = undefined;
                    var else_reader: Reader = undefined;
                    var has_else = false;
                    if (self.current_branch_table) |cbt| {
                        if (cbt.end_targets.get(body_start)) |end_pos| {
                            end_reader = .{ .bytes = reader.bytes, .pos = end_pos };
                            if (cbt.else_targets.get(body_start)) |else_pos| {
                                else_reader = .{ .bytes = reader.bytes, .pos = else_pos };
                                has_else = true;
                            }
                        } else {
                            else_reader = reader.*;
                            end_reader = reader.*;
                            has_else = try findElseOrEnd(&else_reader, &end_reader);
                        }
                    } else {
                        else_reader = reader.*;
                        end_reader = reader.*;
                        has_else = try findElseOrEnd(&else_reader, &end_reader);
                    }

                    if (cond != 0) {
                        // True branch: execute, push label to end
                        try self.pushLabel(.{
                            .arity = result_arity,
                            .op_stack_base = self.op_ptr,
                            .target = .{ .forward = end_reader },
                        });
                    } else {
                        // False branch: skip to else or end
                        if (has_else) {
                            reader.* = else_reader;
                            try self.pushLabel(.{
                                .arity = result_arity,
                                .op_stack_base = self.op_ptr,
                                .target = .{ .forward = end_reader },
                            });
                        } else {
                            reader.* = end_reader;
                        }
                    }
                },
                .@"else" => {
                    // Reached else from true branch — jump to end
                    const label = self.peekLabel(0);
                    reader.* = switch (label.target) {
                        .forward => |r| r,
                        .loop_start => |r| r,
                        .ir_forward, .ir_loop_start => unreachable, // never in old path
                    };
                    _ = self.popLabel();
                },
                .end => {
                    if (self.label_ptr > 0 and (self.frame_ptr == 0 or
                        self.label_ptr > self.frame_stack[self.frame_ptr - 1].label_stack_base))
                    {
                        _ = self.popLabel();
                    } else {
                        // Function end — return
                        return;
                    }
                },
                .br => {
                    const depth = try reader.readU32();
                    try self.branchTo(depth, reader);
                },
                .br_if => {
                    const depth = try reader.readU32();
                    const cond = self.popI32();
                    if (cond != 0) {
                        try self.branchTo(depth, reader);
                    }
                },
                .br_on_null => {
                    const depth = try reader.readU32();
                    const ref_val = self.pop();
                    if (ref_val == 0) {
                        try self.branchTo(depth, reader);
                    } else {
                        try self.push(ref_val); // non-null: push back and continue
                    }
                },
                .br_on_non_null => {
                    const depth = try reader.readU32();
                    const ref_val = self.pop();
                    if (ref_val != 0) {
                        try self.push(ref_val); // non-null: push back and branch
                        try self.branchTo(depth, reader);
                    }
                    // null: drop and continue
                },
                .br_table => {
                    const count = try reader.readU32();
                    const idx = @as(u32, @bitCast(self.popI32()));
                    // Read all targets
                    var default_depth: u32 = 0;
                    var target_depth: ?u32 = null;
                    for (0..count) |i| {
                        const d = try reader.readU32();
                        if (i == idx) target_depth = d;
                    }
                    default_depth = try reader.readU32();
                    if (idx >= count) target_depth = default_depth;
                    try self.branchTo(target_depth orelse default_depth, reader);
                },
                .@"return" => return,
                .call => {
                    const func_idx = try reader.readU32();
                    self.doCall(instance, func_idx, reader) catch |err| {
                        if (err == error.WasmException and self.handleException(reader, instance))
                            continue;
                        return err;
                    };
                },
                .call_indirect => {
                    const type_idx = try reader.readU32();
                    const table_idx = try reader.readU32();
                    const t = try instance.getTable(table_idx);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    const func_addr = try t.lookup(elem_idx);
                    const func_ptr = try instance.store.getFunctionPtr(func_addr);

                    // Type check: compare param/result types, not just lengths
                    if (instance.module.getTypeFunc(type_idx)) |expected| {
                        if (!ValType.sliceEql(expected.params, func_ptr.params) or
                            !ValType.sliceEql(expected.results, func_ptr.results))
                            return error.MismatchedSignatures;
                    }

                    self.doCallDirect(instance, func_ptr, reader) catch |err| {
                        if (err == error.WasmException and self.handleException(reader, instance))
                            continue;
                        return err;
                    };
                },

                // ---- Tail call ----
                .return_call => {
                    const func_idx = try reader.readU32();
                    const func_ptr = try instance.getFuncPtr(func_idx);
                    const n_args = func_ptr.params.len;
                    // Save args from stack (in reverse, then restore order)
                    var i: usize = n_args;
                    while (i > 0) {
                        i -= 1;
                        self.tail_call_args[i] = self.pop();
                    }
                    self.tail_call_arg_count = n_args;
                    self.tail_call_func = func_ptr;
                    return; // exit execute(), doCallDirect will loop
                },
                .return_call_indirect => {
                    const type_idx = try reader.readU32();
                    const table_idx = try reader.readU32();
                    const t = try instance.getTable(table_idx);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    const func_addr = try t.lookup(elem_idx);
                    const func_ptr = try instance.store.getFunctionPtr(func_addr);
                    // Type check
                    if (instance.module.getTypeFunc(type_idx)) |expected| {
                        if (!ValType.sliceEql(expected.params, func_ptr.params) or
                            !ValType.sliceEql(expected.results, func_ptr.results))
                            return error.MismatchedSignatures;
                    }
                    const n_args = func_ptr.params.len;
                    var i: usize = n_args;
                    while (i > 0) {
                        i -= 1;
                        self.tail_call_args[i] = self.pop();
                    }
                    self.tail_call_arg_count = n_args;
                    self.tail_call_func = func_ptr;
                    return;
                },

                // ---- Exception handling ----
                .throw => {
                    const tag_idx = try reader.readU32();
                    if (tag_idx >= instance.tagaddrs.items.len)
                        return error.Trap;
                    const tag_addr = instance.tagaddrs.items[tag_idx];
                    const tag = instance.store.tags.items[tag_addr];
                    const ft = instance.module.getTypeFunc(tag.type_idx) orelse return error.Trap;
                    const param_count = ft.params.len;
                    if (param_count > MAX_EXCEPTION_VALUES) return error.Trap;

                    var exc = PendingException{
                        .tag_id = tag.tag_id,
                        .values = undefined,
                        .value_count = param_count,
                    };
                    // Pop values in reverse (stack order → first param at index 0)
                    var i: usize = param_count;
                    while (i > 0) {
                        i -= 1;
                        exc.values[i] = self.popU64();
                    }
                    self.pending_exception = exc;
                    // Try to handle in current function first
                    if (self.handleException(reader, instance)) continue;
                    return error.WasmException;
                },
                .throw_ref => {
                    // TODO: implement in 8.4 (needs exnref value representation)
                    return error.Trap;
                },
                .try_table => {
                    const bt = try readBlockType(reader);
                    const result_arity = blockTypeArity(bt, instance);
                    // Read catch clauses
                    const n_catches = try reader.readU32();
                    if (n_catches > MAX_CATCH_CLAUSES) return error.Trap;
                    var catches: [MAX_CATCH_CLAUSES]CatchClause = undefined;
                    for (0..n_catches) |ci| {
                        const kind = try reader.readByte();
                        var tid: u64 = 0;
                        if (kind == 0x00 or kind == 0x01) {
                            const tidx = try reader.readU32();
                            if (tidx >= instance.tagaddrs.items.len) return error.Trap;
                            const tag_addr = instance.tagaddrs.items[tidx];
                            tid = instance.store.tags.items[tag_addr].tag_id;
                        }
                        const label_depth = try reader.readU32();
                        catches[ci] = .{ .kind = kind, .tag_id = tid, .label_depth = label_depth };
                    }
                    // Push label like block, but with catch clause info
                    const body_start = reader.pos;
                    var end_reader: Reader = undefined;
                    if (self.current_branch_table) |cbt| {
                        if (cbt.end_targets.get(body_start)) |end_pos| {
                            end_reader = .{ .bytes = reader.bytes, .pos = end_pos };
                        } else {
                            end_reader = reader.*;
                            try skipToEnd(&end_reader);
                        }
                    } else {
                        end_reader = reader.*;
                        try skipToEnd(&end_reader);
                    }
                    var label = Label{
                        .arity = result_arity,
                        .op_stack_base = self.op_ptr,
                        .target = .{ .forward = end_reader },
                    };
                    label.catch_count = @intCast(n_catches);
                    label.catches = catches;
                    try self.pushLabel(label);
                },

                // ---- Parametric ----
                .drop => _ = self.pop(),
                .select, .select_t => {
                    if (op == .select_t) _ = try reader.readU32(); // skip type count + types
                    const cond = self.popI32();
                    // Use u128 ops to preserve v128 upper bits
                    self.op_ptr -= 1;
                    const val2 = self.op_stack[self.op_ptr];
                    self.op_ptr -= 1;
                    const val1 = self.op_stack[self.op_ptr];
                    self.op_stack[self.op_ptr] = if (cond != 0) val1 else val2;
                    self.op_ptr += 1;
                },

                // ---- Variable access ----
                .local_get => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    try self.pushV128(self.op_stack[frame.locals_start + idx]);
                },
                .local_set => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + idx] = self.popV128();
                },
                .local_tee => {
                    const idx = try reader.readU32();
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + idx] = self.op_stack[self.op_ptr - 1];
                },
                .global_get => {
                    const idx = try reader.readU32();
                    const g = try instance.getGlobal(idx);
                    try self.pushV128(g.value);
                },
                .global_set => {
                    const idx = try reader.readU32();
                    const g = try instance.getGlobal(idx);
                    g.value = self.popV128();
                },

                // ---- Table access ----
                .table_get => {
                    const table_idx = try reader.readU32();
                    const t = try instance.getTable(table_idx);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    const val = t.get(elem_idx) catch return error.OutOfBoundsMemoryAccess;
                    // Stack convention: addr+1 for valid refs, 0 for null
                    try self.push(if (val) |v| @as(u64, @intCast(v)) + 1 else 0);
                },
                .table_set => {
                    const table_idx = try reader.readU32();
                    const val = self.pop();
                    const t = try instance.getTable(table_idx);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    // Stack convention: 0 = null, addr+1 = valid ref
                    const ref_val: ?usize = if (val == 0) null else @intCast(val - 1);
                    t.set(elem_idx, ref_val) catch return error.OutOfBoundsMemoryAccess;
                },

                // ---- Memory load ----
                .i32_load => try self.memLoad(i32, u32, reader, instance),
                .i64_load => try self.memLoad(i64, u64, reader, instance),
                .f32_load => try self.memLoadFloat(f32, reader, instance),
                .f64_load => try self.memLoadFloat(f64, reader, instance),
                .i32_load8_s => try self.memLoad(i8, i32, reader, instance),
                .i32_load8_u => try self.memLoad(u8, u32, reader, instance),
                .i32_load16_s => try self.memLoad(i16, i32, reader, instance),
                .i32_load16_u => try self.memLoad(u16, u32, reader, instance),
                .i64_load8_s => try self.memLoad(i8, i64, reader, instance),
                .i64_load8_u => try self.memLoad(u8, u64, reader, instance),
                .i64_load16_s => try self.memLoad(i16, i64, reader, instance),
                .i64_load16_u => try self.memLoad(u16, u64, reader, instance),
                .i64_load32_s => try self.memLoad(i32, i64, reader, instance),
                .i64_load32_u => try self.memLoad(u32, u64, reader, instance),

                // ---- Memory store ----
                .i32_store => try self.memStore(u32, reader, instance),
                .i64_store => try self.memStore(u64, reader, instance),
                .f32_store => try self.memStoreFloat(f32, reader, instance),
                .f64_store => try self.memStoreFloat(f64, reader, instance),
                .i32_store8 => try self.memStore(u8, reader, instance),
                .i32_store16 => try self.memStore(u16, reader, instance),
                .i64_store8 => try self.memStoreTrunc(u8, u64, reader, instance),
                .i64_store16 => try self.memStoreTrunc(u16, u64, reader, instance),
                .i64_store32 => try self.memStoreTrunc(u32, u64, reader, instance),

                // ---- Memory misc ----
                .memory_size => {
                    const memidx = try reader.readU32();
                    const m = try instance.getMemory(@intCast(memidx));
                    try self.pushI32(@bitCast(m.size()));
                },
                .memory_grow => {
                    const memidx = try reader.readU32();
                    const pages = @as(u32, @bitCast(self.popI32()));
                    const m = try instance.getMemory(@intCast(memidx));
                    // Check memory ceiling before growing
                    if (self.max_memory_bytes) |ceiling| {
                        const new_bytes = m.data.items.len + @as(u64, pages) * m.page_size;
                        if (new_bytes > ceiling) {
                            try self.pushI32(-1);
                            continue;
                        }
                    }
                    const old = m.grow(pages) catch {
                        try self.pushI32(-1);
                        continue;
                    };
                    try self.pushI32(@bitCast(old));
                },

                // ---- Constants ----
                .i32_const => try self.pushI32(try reader.readI32()),
                .i64_const => try self.pushI64(try reader.readI64()),
                .f32_const => try self.pushF32(try reader.readF32()),
                .f64_const => try self.pushF64(try reader.readF64()),

                // ---- i32 comparison ----
                .i32_eqz => { const a = self.popI32(); try self.pushI32(b2i(a == 0)); },
                .i32_eq => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a == b)); },
                .i32_ne => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a != b)); },
                .i32_lt_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a < b)); },
                .i32_lt_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a < b)); },
                .i32_gt_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a > b)); },
                .i32_gt_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a > b)); },
                .i32_le_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a <= b)); },
                .i32_le_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a <= b)); },
                .i32_ge_s => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a >= b)); },
                .i32_ge_u => { const b = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a >= b)); },

                // ---- i64 comparison ----
                .i64_eqz => { const a = self.popI64(); try self.pushI32(b2i(a == 0)); },
                .i64_eq => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a == b)); },
                .i64_ne => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a != b)); },
                .i64_lt_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a < b)); },
                .i64_lt_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a < b)); },
                .i64_gt_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a > b)); },
                .i64_gt_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a > b)); },
                .i64_le_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a <= b)); },
                .i64_le_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a <= b)); },
                .i64_ge_s => { const b = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a >= b)); },
                .i64_ge_u => { const b = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a >= b)); },

                // ---- f32 comparison ----
                .f32_eq => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a == b)); },
                .f32_ne => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a != b)); },
                .f32_lt => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a < b)); },
                .f32_gt => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a > b)); },
                .f32_le => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a <= b)); },
                .f32_ge => { const b = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a >= b)); },

                // ---- f64 comparison ----
                .f64_eq => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a == b)); },
                .f64_ne => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a != b)); },
                .f64_lt => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a < b)); },
                .f64_gt => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a > b)); },
                .f64_le => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a <= b)); },
                .f64_ge => { const b = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a >= b)); },

                // ---- i32 arithmetic ----
                .i32_clz => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @clz(a)))); },
                .i32_ctz => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @ctz(a)))); },
                .i32_popcnt => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @popCount(a)))); },
                .i32_add => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(a +% b); },
                .i32_sub => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(a -% b); },
                .i32_mul => { const b = self.popI32(); const a = self.popI32(); try self.pushI32(a *% b); },
                .i32_div_s => {
                    const b = self.popI32(); const a = self.popI32();
                    if (b == 0) return error.DivisionByZero;
                    if (a == math.minInt(i32) and b == -1) return error.IntegerOverflow;
                    try self.pushI32(@divTrunc(a, b));
                },
                .i32_div_u => {
                    const b = self.popU32(); const a = self.popU32();
                    if (b == 0) return error.DivisionByZero;
                    try self.pushI32(@bitCast(a / b));
                },
                .i32_rem_s => {
                    const b = self.popI32(); const a = self.popI32();
                    if (b == 0) return error.DivisionByZero;
                    if (b == -1) { try self.pushI32(0); } else { try self.pushI32(@rem(a, b)); }
                },
                .i32_rem_u => {
                    const b = self.popU32(); const a = self.popU32();
                    if (b == 0) return error.DivisionByZero;
                    try self.pushI32(@bitCast(a % b));
                },
                .i32_and => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a & b)); },
                .i32_or => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a | b)); },
                .i32_xor => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a ^ b)); },
                .i32_shl => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a << @truncate(b % 32))); },
                .i32_shr_s => { const b = self.popU32(); const a = self.popI32(); try self.pushI32(a >> @truncate(@as(u32, @bitCast(b)) % 32)); },
                .i32_shr_u => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a >> @truncate(b % 32))); },
                .i32_rotl => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, math.rotl(u32, a, b % 32))); },
                .i32_rotr => { const b = self.popU32(); const a = self.popU32(); try self.push(@as(u64, math.rotr(u32, a, b % 32))); },

                // ---- i64 arithmetic ----
                .i64_clz => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @clz(a)))); },
                .i64_ctz => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @ctz(a)))); },
                .i64_popcnt => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @popCount(a)))); },
                .i64_add => { const b = self.popI64(); const a = self.popI64(); try self.pushI64(a +% b); },
                .i64_sub => { const b = self.popI64(); const a = self.popI64(); try self.pushI64(a -% b); },
                .i64_mul => { const b = self.popI64(); const a = self.popI64(); try self.pushI64(a *% b); },
                .i64_div_s => {
                    const b = self.popI64(); const a = self.popI64();
                    if (b == 0) return error.DivisionByZero;
                    if (a == math.minInt(i64) and b == -1) return error.IntegerOverflow;
                    try self.pushI64(@divTrunc(a, b));
                },
                .i64_div_u => {
                    const b = self.popU64(); const a = self.popU64();
                    if (b == 0) return error.DivisionByZero;
                    try self.pushI64(@bitCast(a / b));
                },
                .i64_rem_s => {
                    const b = self.popI64(); const a = self.popI64();
                    if (b == 0) return error.DivisionByZero;
                    if (b == -1) { try self.pushI64(0); } else { try self.pushI64(@rem(a, b)); }
                },
                .i64_rem_u => {
                    const b = self.popU64(); const a = self.popU64();
                    if (b == 0) return error.DivisionByZero;
                    try self.push(a % b);
                },
                .i64_and => { const b = self.pop(); const a = self.pop(); try self.push(a & b); },
                .i64_or => { const b = self.pop(); const a = self.pop(); try self.push(a | b); },
                .i64_xor => { const b = self.pop(); const a = self.pop(); try self.push(a ^ b); },
                .i64_shl => { const b = self.popU64(); const a = self.popU64(); try self.push(a << @truncate(b % 64)); },
                .i64_shr_s => { const b = self.popU64(); const a = self.popI64(); try self.pushI64(a >> @truncate(b % 64)); },
                .i64_shr_u => { const b = self.popU64(); const a = self.popU64(); try self.push(a >> @truncate(b % 64)); },
                .i64_rotl => { const b = self.popU64(); const a = self.popU64(); try self.push(math.rotl(u64, a, b % 64)); },
                .i64_rotr => { const b = self.popU64(); const a = self.popU64(); try self.push(math.rotr(u64, a, b % 64)); },

                // ---- f32 arithmetic ----
                .f32_abs => { const a = self.popF32(); try self.pushF32(@abs(a)); },
                .f32_neg => { const a = self.popF32(); try self.pushF32(-a); },
                .f32_ceil => { const a = self.popF32(); try self.pushF32(@ceil(a)); },
                .f32_floor => { const a = self.popF32(); try self.pushF32(@floor(a)); },
                .f32_trunc => { const a = self.popF32(); try self.pushF32(@trunc(a)); },
                .f32_nearest => { const a = self.popF32(); try self.pushF32(wasmNearest(f32, a)); },
                .f32_sqrt => { const a = self.popF32(); try self.pushF32(@sqrt(a)); },
                .f32_add => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a + b); },
                .f32_sub => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a - b); },
                .f32_mul => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a * b); },
                .f32_div => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(a / b); },
                .f32_min => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(wasmMin(f32, a, b)); },
                .f32_max => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(wasmMax(f32, a, b)); },
                .f32_copysign => { const b = self.popF32(); const a = self.popF32(); try self.pushF32(std.math.copysign(a, b)); },

                // ---- f64 arithmetic ----
                .f64_abs => { const a = self.popF64(); try self.pushF64(@abs(a)); },
                .f64_neg => { const a = self.popF64(); try self.pushF64(-a); },
                .f64_ceil => { const a = self.popF64(); try self.pushF64(@ceil(a)); },
                .f64_floor => { const a = self.popF64(); try self.pushF64(@floor(a)); },
                .f64_trunc => { const a = self.popF64(); try self.pushF64(@trunc(a)); },
                .f64_nearest => { const a = self.popF64(); try self.pushF64(wasmNearest(f64, a)); },
                .f64_sqrt => { const a = self.popF64(); try self.pushF64(@sqrt(a)); },
                .f64_add => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a + b); },
                .f64_sub => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a - b); },
                .f64_mul => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a * b); },
                .f64_div => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(a / b); },
                .f64_min => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(wasmMin(f64, a, b)); },
                .f64_max => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(wasmMax(f64, a, b)); },
                .f64_copysign => { const b = self.popF64(); const a = self.popF64(); try self.pushF64(std.math.copysign(a, b)); },

                // ---- Type conversions ----
                .i32_wrap_i64 => { const a = self.popI64(); try self.pushI32(@truncate(a)); },
                .i32_trunc_f32_s => { const a = self.popF32(); try self.pushI32(truncSat(i32, f32, a) orelse return error.InvalidConversion); },
                .i32_trunc_f32_u => { const a = self.popF32(); try self.pushI32(@bitCast(truncSat(u32, f32, a) orelse return error.InvalidConversion)); },
                .i32_trunc_f64_s => { const a = self.popF64(); try self.pushI32(truncSat(i32, f64, a) orelse return error.InvalidConversion); },
                .i32_trunc_f64_u => { const a = self.popF64(); try self.pushI32(@bitCast(truncSat(u32, f64, a) orelse return error.InvalidConversion)); },
                .i64_extend_i32_s => { const a = self.popI32(); try self.pushI64(@as(i64, a)); },
                .i64_extend_i32_u => { const a = self.popU32(); try self.pushI64(@as(i64, @as(i64, a))); },
                .i64_trunc_f32_s => { const a = self.popF32(); try self.pushI64(truncSat(i64, f32, a) orelse return error.InvalidConversion); },
                .i64_trunc_f32_u => { const a = self.popF32(); try self.pushI64(@bitCast(truncSat(u64, f32, a) orelse return error.InvalidConversion)); },
                .i64_trunc_f64_s => { const a = self.popF64(); try self.pushI64(truncSat(i64, f64, a) orelse return error.InvalidConversion); },
                .i64_trunc_f64_u => { const a = self.popF64(); try self.pushI64(@bitCast(truncSat(u64, f64, a) orelse return error.InvalidConversion)); },
                .f32_convert_i32_s => { const a = self.popI32(); try self.pushF32(@floatFromInt(a)); },
                .f32_convert_i32_u => { const a = self.popU32(); try self.pushF32(@floatFromInt(a)); },
                .f32_convert_i64_s => { const a = self.popI64(); try self.pushF32(@floatFromInt(a)); },
                .f32_convert_i64_u => { const a = self.popU64(); try self.pushF32(@floatFromInt(a)); },
                .f32_demote_f64 => { const a = self.popF64(); try self.pushF32(@floatCast(a)); },
                .f64_convert_i32_s => { const a = self.popI32(); try self.pushF64(@floatFromInt(a)); },
                .f64_convert_i32_u => { const a = self.popU32(); try self.pushF64(@floatFromInt(a)); },
                .f64_convert_i64_s => { const a = self.popI64(); try self.pushF64(@floatFromInt(a)); },
                .f64_convert_i64_u => { const a = self.popU64(); try self.pushF64(@floatFromInt(a)); },
                .f64_promote_f32 => { const a = self.popF32(); try self.pushF64(@as(f64, a)); },
                .i32_reinterpret_f32 => { const a = self.popF32(); try self.push(@as(u64, @as(u32, @bitCast(a)))); },
                .i64_reinterpret_f64 => { const a = self.popF64(); try self.push(@bitCast(a)); },
                .f32_reinterpret_i32 => { const a = self.popU32(); try self.pushF32(@bitCast(a)); },
                .f64_reinterpret_i64 => { const a = self.pop(); try self.pushF64(@bitCast(a)); },

                // ---- Sign extension ----
                .i32_extend8_s => { const a = self.popI32(); try self.pushI32(@as(i32, @as(i8, @truncate(a)))); },
                .i32_extend16_s => { const a = self.popI32(); try self.pushI32(@as(i32, @as(i16, @truncate(a)))); },
                .i64_extend8_s => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i8, @truncate(a)))); },
                .i64_extend16_s => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i16, @truncate(a)))); },
                .i64_extend32_s => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i32, @truncate(a)))); },

                // ---- Reference types ----
                .ref_null => { _ = try reader.readI33(); try self.push(0); },
                .ref_is_null => { const a = self.pop(); try self.pushI32(b2i(a == 0)); },
                .ref_eq => { const b = self.pop(); const a = self.pop(); try self.pushI32(b2i(a == b)); },
                .ref_func => {
                    const idx = try reader.readU32();
                    // Push store address + 1 (0 = null ref convention)
                    if (idx < instance.funcaddrs.items.len) {
                        try self.push(@as(u64, @intCast(instance.funcaddrs.items[idx])) + 1);
                    } else {
                        return error.FunctionIndexOutOfBounds;
                    }
                },
                .ref_as_non_null => {
                    const val = self.pop();
                    if (val == 0) return error.Trap; // null ref
                    try self.push(val);
                },
                .call_ref => {
                    const type_idx = try reader.readU32();
                    const ref_val = self.pop();
                    if (ref_val == 0) return error.Trap; // null ref
                    const func_addr = ref_val - 1;
                    const func_ptr = try instance.store.getFunctionPtr(@intCast(func_addr));
                    // Type check
                    if (instance.module.getTypeFunc(type_idx)) |expected| {
                        if (!ValType.sliceEql(expected.params, func_ptr.params) or
                            !ValType.sliceEql(expected.results, func_ptr.results))
                            return error.MismatchedSignatures;
                    }
                    self.doCallDirect(instance, func_ptr, reader) catch |err| {
                        if (err == error.WasmException and self.handleException(reader, instance))
                            continue;
                        return err;
                    };
                },
                .return_call_ref => {
                    const type_idx = try reader.readU32();
                    const ref_val = self.pop();
                    if (ref_val == 0) return error.Trap; // null ref
                    const func_addr = ref_val - 1;
                    const func_ptr = try instance.store.getFunctionPtr(@intCast(func_addr));
                    // Type check
                    if (instance.module.getTypeFunc(type_idx)) |expected| {
                        if (!ValType.sliceEql(expected.params, func_ptr.params) or
                            !ValType.sliceEql(expected.results, func_ptr.results))
                            return error.MismatchedSignatures;
                    }
                    const n_args = func_ptr.params.len;
                    var i: usize = n_args;
                    while (i > 0) {
                        i -= 1;
                        self.tail_call_args[i] = self.pop();
                    }
                    self.tail_call_arg_count = n_args;
                    self.tail_call_func = func_ptr;
                    return;
                },

                // ---- 0xFB prefix (GC) ----
                .gc_prefix => try self.executeGc(reader, instance),

                // ---- 0xFC prefix (misc) ----
                .misc_prefix => try self.executeMisc(reader, instance),

                // ---- SIMD prefix ----
                .simd_prefix => try self.executeSimd(reader, instance),
                .atomic_prefix => try self.executeAtomic(reader, instance),

                _ => return error.Trap,
            }
        }
    }

    fn executeGc(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        const gc_mod = @import("gc.zig");
        // Trigger GC collection if allocation threshold reached
        self.tryCollectGarbage(instance.store);
        const sub = reader.readU32() catch return error.Trap;
        const gc_op: opcode.GcOpcode = @enumFromInt(sub);
        switch (gc_op) {
            // ---- struct operations ----
            .struct_new => {
                const type_idx = reader.readU32() catch return error.Trap;
                const stype = self.getStructType(instance, type_idx) orelse return error.Trap;
                const n = stype.fields.len;
                // Pop n field values from stack (last field is on top, so reverse order)
                var fields_buf: [256]u64 = undefined;
                if (n > fields_buf.len) return error.Trap;
                var i: usize = n;
                while (i > 0) {
                    i -= 1;
                    fields_buf[i] = self.pop();
                }
                const addr = instance.store.gc_heap.allocStruct(type_idx, fields_buf[0..n]) catch return error.Trap;
                try self.push(gc_mod.GcHeap.encodeRef(addr));
            },
            .struct_new_default => {
                const type_idx = reader.readU32() catch return error.Trap;
                const stype = self.getStructType(instance, type_idx) orelse return error.Trap;
                const n = stype.fields.len;
                // Allocate with default values (0 for all — numeric=0, ref=null=0)
                const fields = instance.store.gc_heap.alloc.alloc(u64, n) catch return error.Trap;
                defer instance.store.gc_heap.alloc.free(fields);
                @memset(fields, 0);
                const addr = instance.store.gc_heap.allocStruct(type_idx, fields) catch return error.Trap;
                try self.push(gc_mod.GcHeap.encodeRef(addr));
            },
            .struct_get => {
                const type_idx = reader.readU32() catch return error.Trap;
                const field_idx = reader.readU32() catch return error.Trap;
                _ = type_idx;
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                const s = switch (obj.*) {
                    .struct_obj => |so| so,
                    else => return error.Trap,
                };
                if (field_idx >= s.fields.len) return error.Trap;
                try self.push(s.fields[field_idx]);
            },
            .struct_get_s => {
                const type_idx = reader.readU32() catch return error.Trap;
                const field_idx = reader.readU32() catch return error.Trap;
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                const s = switch (obj.*) {
                    .struct_obj => |so| so,
                    else => return error.Trap,
                };
                if (field_idx >= s.fields.len) return error.Trap;
                const raw: u32 = @truncate(s.fields[field_idx]);
                const stype = self.getStructType(instance, type_idx) orelse return error.Trap;
                const result: i32 = switch (stype.fields[field_idx].storage) {
                    .i8 => @as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw))))),
                    .i16 => @as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw))))),
                    else => @bitCast(raw),
                };
                try self.pushI32(result);
            },
            .struct_get_u => {
                const type_idx = reader.readU32() catch return error.Trap;
                const field_idx = reader.readU32() catch return error.Trap;
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                const s = switch (obj.*) {
                    .struct_obj => |so| so,
                    else => return error.Trap,
                };
                if (field_idx >= s.fields.len) return error.Trap;
                const raw: u32 = @truncate(s.fields[field_idx]);
                const stype = self.getStructType(instance, type_idx) orelse return error.Trap;
                const result: u32 = switch (stype.fields[field_idx].storage) {
                    .i8 => @as(u32, @as(u8, @truncate(raw))),
                    .i16 => @as(u32, @as(u16, @truncate(raw))),
                    else => raw,
                };
                try self.pushI32(@bitCast(result));
            },
            .struct_set => {
                const type_idx = reader.readU32() catch return error.Trap;
                const field_idx = reader.readU32() catch return error.Trap;
                _ = type_idx;
                const val = self.pop();
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                switch (obj.*) {
                    .struct_obj => |*so| {
                        if (field_idx >= so.fields.len) return error.Trap;
                        so.fields[field_idx] = val;
                    },
                    else => return error.Trap,
                }
            },

            // ---- array operations ----
            .array_new => {
                const type_idx = reader.readU32() catch return error.Trap;
                const len: u32 = @truncate(self.pop());
                const init_val = self.pop();
                const addr = instance.store.gc_heap.allocArray(type_idx, len, init_val) catch return error.Trap;
                try self.push(gc_mod.GcHeap.encodeRef(addr));
            },
            .array_new_default => {
                const type_idx = reader.readU32() catch return error.Trap;
                const len: u32 = @truncate(self.pop());
                const addr = instance.store.gc_heap.allocArray(type_idx, len, 0) catch return error.Trap;
                try self.push(gc_mod.GcHeap.encodeRef(addr));
            },
            .array_new_fixed => {
                const type_idx = reader.readU32() catch return error.Trap;
                const n = reader.readU32() catch return error.Trap;
                // Pop n values from stack (last element on top)
                var vals_buf: [256]u64 = undefined;
                if (n > vals_buf.len) return error.Trap;
                var i: u32 = n;
                while (i > 0) {
                    i -= 1;
                    vals_buf[i] = self.pop();
                }
                const addr = instance.store.gc_heap.allocArrayWithValues(type_idx, vals_buf[0..n]) catch return error.Trap;
                try self.push(gc_mod.GcHeap.encodeRef(addr));
            },
            .array_get => {
                const type_idx = reader.readU32() catch return error.Trap;
                _ = type_idx;
                const idx: u32 = @truncate(self.pop());
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                const a = switch (obj.*) {
                    .array_obj => |ao| ao,
                    else => return error.Trap,
                };
                if (idx >= a.elements.len) return error.Trap;
                try self.push(a.elements[idx]);
            },
            .array_get_s => {
                const type_idx = reader.readU32() catch return error.Trap;
                const idx: u32 = @truncate(self.pop());
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                const a = switch (obj.*) {
                    .array_obj => |ao| ao,
                    else => return error.Trap,
                };
                if (idx >= a.elements.len) return error.Trap;
                const raw: u32 = @truncate(a.elements[idx]);
                const atype = self.getArrayType(instance, type_idx) orelse return error.Trap;
                const result: i32 = switch (atype.field.storage) {
                    .i8 => @as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw))))),
                    .i16 => @as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw))))),
                    else => @bitCast(raw),
                };
                try self.pushI32(result);
            },
            .array_get_u => {
                const type_idx = reader.readU32() catch return error.Trap;
                const idx: u32 = @truncate(self.pop());
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                const a = switch (obj.*) {
                    .array_obj => |ao| ao,
                    else => return error.Trap,
                };
                if (idx >= a.elements.len) return error.Trap;
                const raw: u32 = @truncate(a.elements[idx]);
                const atype = self.getArrayType(instance, type_idx) orelse return error.Trap;
                const result: u32 = switch (atype.field.storage) {
                    .i8 => @as(u32, @as(u8, @truncate(raw))),
                    .i16 => @as(u32, @as(u16, @truncate(raw))),
                    else => raw,
                };
                try self.pushI32(@bitCast(result));
            },
            .array_set => {
                const type_idx = reader.readU32() catch return error.Trap;
                _ = type_idx;
                const val = self.pop();
                const idx: u32 = @truncate(self.pop());
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                switch (obj.*) {
                    .array_obj => |*ao| {
                        if (idx >= ao.elements.len) return error.Trap;
                        ao.elements[idx] = val;
                    },
                    else => return error.Trap,
                }
            },
            .array_len => {
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                const len: u32 = switch (obj.*) {
                    .array_obj => |ao| @intCast(ao.elements.len),
                    else => return error.Trap,
                };
                try self.pushI32(@bitCast(len));
            },

            // ---- array bulk operations ----
            .array_fill => {
                const type_idx = reader.readU32() catch return error.Trap;
                _ = type_idx;
                const size: u32 = @truncate(self.pop());
                const fill_val = self.pop();
                const offset: u32 = @truncate(self.pop());
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                switch (obj.*) {
                    .array_obj => |*ao| {
                        const end = @as(u64, offset) + @as(u64, size);
                        if (end > ao.elements.len) return error.Trap;
                        @memset(ao.elements[offset .. offset + size], fill_val);
                    },
                    else => return error.Trap,
                }
            },
            .array_copy => {
                const dst_type = reader.readU32() catch return error.Trap;
                const src_type = reader.readU32() catch return error.Trap;
                _ = dst_type;
                _ = src_type;
                const size: u32 = @truncate(self.pop());
                const src_off: u32 = @truncate(self.pop());
                const src_ref = self.pop();
                const dst_off: u32 = @truncate(self.pop());
                const dst_ref = self.pop();
                const src_addr = gc_mod.GcHeap.decodeRef(src_ref) catch return error.Trap;
                const dst_addr = gc_mod.GcHeap.decodeRef(dst_ref) catch return error.Trap;
                const src_obj = instance.store.gc_heap.getObject(src_addr) catch return error.Trap;
                const src_elems = switch (src_obj.*) {
                    .array_obj => |ao| ao.elements,
                    else => return error.Trap,
                };
                if (@as(u64, src_off) + @as(u64, size) > src_elems.len) return error.Trap;
                // Copy src slice to temp buffer to handle overlapping src/dst
                var tmp_buf: [4096]u64 = undefined;
                const tmp = if (size <= tmp_buf.len) tmp_buf[0..size] else return error.Trap;
                @memcpy(tmp, src_elems[src_off .. src_off + size]);
                // Now write to dst
                const dst_obj = instance.store.gc_heap.getObject(dst_addr) catch return error.Trap;
                switch (dst_obj.*) {
                    .array_obj => |*dao| {
                        if (@as(u64, dst_off) + @as(u64, size) > dao.elements.len) return error.Trap;
                        @memcpy(dao.elements[dst_off .. dst_off + size], tmp);
                    },
                    else => return error.Trap,
                }
            },
            .array_new_data => {
                const type_idx = reader.readU32() catch return error.Trap;
                const data_idx = reader.readU32() catch return error.Trap;
                const size: u32 = @truncate(self.pop());
                const offset: u32 = @truncate(self.pop());
                // Get data segment bytes
                if (data_idx >= instance.module.datas.items.len) return error.Trap;
                const data_seg = instance.module.datas.items[data_idx];
                // Determine element byte size from array type
                const atype = self.getArrayType(instance, type_idx) orelse return error.Trap;
                const elem_bytes: u32 = switch (atype.field.storage) {
                    .i8 => 1,
                    .i16 => 2,
                    .val => |v| switch (v) {
                        .i32, .f32 => @as(u32, 4),
                        .i64, .f64 => @as(u32, 8),
                        else => return error.Trap,
                    },
                };
                const byte_len = @as(u64, size) * @as(u64, elem_bytes);
                if (@as(u64, offset) + byte_len > data_seg.data.len) return error.Trap;
                // Read elements from data bytes
                const vals = instance.store.gc_heap.alloc.alloc(u64, size) catch return error.Trap;
                defer instance.store.gc_heap.alloc.free(vals);
                const src = data_seg.data[offset..];
                for (vals, 0..) |*v, i| {
                    const base = i * elem_bytes;
                    v.* = switch (atype.field.storage) {
                        .i8 => @as(u64, src[base]),
                        .i16 => @as(u64, std.mem.readInt(u16, src[base..][0..2], .little)),
                        .val => |vt| switch (vt) {
                            .i32, .f32 => @as(u64, std.mem.readInt(u32, src[base..][0..4], .little)),
                            .i64, .f64 => std.mem.readInt(u64, src[base..][0..8], .little),
                            else => return error.Trap,
                        },
                    };
                }
                const addr = instance.store.gc_heap.allocArrayWithValues(type_idx, vals) catch return error.Trap;
                try self.push(gc_mod.GcHeap.encodeRef(addr));
            },
            .array_new_elem => {
                const type_idx = reader.readU32() catch return error.Trap;
                const elem_idx = reader.readU32() catch return error.Trap;
                const size: u32 = @truncate(self.pop());
                const offset: u32 = @truncate(self.pop());
                // Get element segment
                if (elem_idx >= instance.module.elements.items.len) return error.Trap;
                const elem_seg = instance.module.elements.items[elem_idx];
                const func_indices = switch (elem_seg.init) {
                    .func_indices => |fi| fi,
                    .expressions => return error.Trap, // TODO: evaluate expressions
                };
                if (@as(u64, offset) + @as(u64, size) > func_indices.len) return error.Trap;
                const vals = instance.store.gc_heap.alloc.alloc(u64, size) catch return error.Trap;
                defer instance.store.gc_heap.alloc.free(vals);
                for (vals, 0..) |*v, i| {
                    const fidx = func_indices[offset + i];
                    if (fidx < instance.funcaddrs.items.len) {
                        v.* = @as(u64, @intCast(instance.funcaddrs.items[fidx])) + 1;
                    } else {
                        v.* = 0; // null ref
                    }
                }
                const addr = instance.store.gc_heap.allocArrayWithValues(type_idx, vals) catch return error.Trap;
                try self.push(gc_mod.GcHeap.encodeRef(addr));
            },
            .array_init_data => {
                const type_idx = reader.readU32() catch return error.Trap;
                const data_idx = reader.readU32() catch return error.Trap;
                const size: u32 = @truncate(self.pop());
                const src_off: u32 = @truncate(self.pop());
                const dst_off: u32 = @truncate(self.pop());
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                if (data_idx >= instance.module.datas.items.len) return error.Trap;
                const data_seg = instance.module.datas.items[data_idx];
                const atype = self.getArrayType(instance, type_idx) orelse return error.Trap;
                const elem_bytes: u32 = switch (atype.field.storage) {
                    .i8 => 1,
                    .i16 => 2,
                    .val => |v| switch (v) {
                        .i32, .f32 => @as(u32, 4),
                        .i64, .f64 => @as(u32, 8),
                        else => return error.Trap,
                    },
                };
                const byte_len = @as(u64, size) * @as(u64, elem_bytes);
                if (@as(u64, src_off) + byte_len > data_seg.data.len) return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                switch (obj.*) {
                    .array_obj => |*ao| {
                        if (@as(u64, dst_off) + @as(u64, size) > ao.elements.len) return error.Trap;
                        const src = data_seg.data[src_off..];
                        for (0..size) |i| {
                            const base = i * elem_bytes;
                            ao.elements[dst_off + i] = switch (atype.field.storage) {
                                .i8 => @as(u64, src[base]),
                                .i16 => @as(u64, std.mem.readInt(u16, src[base..][0..2], .little)),
                                .val => |vt| switch (vt) {
                                    .i32, .f32 => @as(u64, std.mem.readInt(u32, src[base..][0..4], .little)),
                                    .i64, .f64 => std.mem.readInt(u64, src[base..][0..8], .little),
                                    else => return error.Trap,
                                },
                            };
                        }
                    },
                    else => return error.Trap,
                }
            },
            .array_init_elem => {
                const type_idx = reader.readU32() catch return error.Trap;
                const elem_idx = reader.readU32() catch return error.Trap;
                _ = type_idx;
                const size: u32 = @truncate(self.pop());
                const src_off: u32 = @truncate(self.pop());
                const dst_off: u32 = @truncate(self.pop());
                const ref_val = self.pop();
                const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return error.Trap;
                if (elem_idx >= instance.module.elements.items.len) return error.Trap;
                const elem_seg = instance.module.elements.items[elem_idx];
                const func_indices = switch (elem_seg.init) {
                    .func_indices => |fi| fi,
                    .expressions => return error.Trap,
                };
                if (@as(u64, src_off) + @as(u64, size) > func_indices.len) return error.Trap;
                const obj = instance.store.gc_heap.getObject(addr) catch return error.Trap;
                switch (obj.*) {
                    .array_obj => |*ao| {
                        if (@as(u64, dst_off) + @as(u64, size) > ao.elements.len) return error.Trap;
                        for (0..size) |i| {
                            const fidx = func_indices[src_off + i];
                            if (fidx < instance.funcaddrs.items.len) {
                                ao.elements[dst_off + i] = @as(u64, @intCast(instance.funcaddrs.items[fidx])) + 1;
                            } else {
                                ao.elements[dst_off + i] = 0;
                            }
                        }
                    },
                    else => return error.Trap,
                }
            },

            // ---- i31 operations ----
            .ref_i31 => {
                const val: i32 = @bitCast(self.popI32());
                try self.push(gc_mod.encodeI31(val));
            },
            .i31_get_s => {
                const ref_val = self.pop();
                const result = gc_mod.decodeI31Signed(ref_val) catch return error.Trap;
                try self.pushI32(result);
            },
            .i31_get_u => {
                const ref_val = self.pop();
                const result = gc_mod.decodeI31Unsigned(ref_val) catch return error.Trap;
                try self.pushI32(result);
            },

            // ---- extern conversion (identity passthrough) ----
            .any_convert_extern, .extern_convert_any => {
                // No-op: value stays on stack unchanged.
                // In a fully typed runtime these would convert between anyref and externref,
                // but our untyped u64 stack makes them identity operations.
            },

            // ---- cast operations ----
            .ref_test, .ref_test_null => {
                const target_ht = readHeapType(reader) orelse return error.Trap;
                const ref_val = self.pop();
                const result: i32 = if (ref_val == 0)
                    (if (gc_op == .ref_test_null) @as(i32, 1) else @as(i32, 0))
                else if (gc_mod.matchesHeapTypeWithHeap(ref_val, target_ht, instance.module, &instance.store.gc_heap))
                    @as(i32, 1)
                else
                    @as(i32, 0);
                try self.pushI32(result);
            },
            .ref_cast, .ref_cast_null => {
                const target_ht = readHeapType(reader) orelse return error.Trap;
                const ref_val = self.pop();
                if (ref_val == 0) {
                    if (gc_op == .ref_cast_null) {
                        try self.push(ref_val); // null passes through
                    } else {
                        return error.Trap; // ref.cast traps on null
                    }
                } else if (gc_mod.matchesHeapTypeWithHeap(ref_val, target_ht, instance.module, &instance.store.gc_heap)) {
                    try self.push(ref_val); // match: pass through
                } else {
                    return error.Trap; // cast failure
                }
            },
            .br_on_cast => {
                const flags = reader.readByte() catch return error.Trap;
                const depth = reader.readU32() catch return error.Trap;
                _ = readHeapType(reader) orelse return error.Trap; // ht1 (source type, not used at runtime)
                const target_ht = readHeapType(reader) orelse return error.Trap; // ht2 (target type)
                const null_check = (flags & 0x02) != 0; // bit 1: target is nullable
                const ref_val = self.pop();
                const matches = if (ref_val == 0)
                    null_check // null matches if target is nullable
                else
                    gc_mod.matchesHeapTypeWithHeap(ref_val, target_ht, instance.module, &instance.store.gc_heap);
                if (matches) {
                    try self.push(ref_val);
                    try self.branchTo(depth, reader);
                } else {
                    try self.push(ref_val);
                }
            },
            .br_on_cast_fail => {
                const flags = reader.readByte() catch return error.Trap;
                const depth = reader.readU32() catch return error.Trap;
                _ = readHeapType(reader) orelse return error.Trap; // ht1 (source type, not used at runtime)
                const target_ht = readHeapType(reader) orelse return error.Trap; // ht2 (target type)
                const null_check = (flags & 0x02) != 0; // bit 1: target is nullable
                const ref_val = self.pop();
                const matches = if (ref_val == 0)
                    null_check
                else
                    gc_mod.matchesHeapTypeWithHeap(ref_val, target_ht, instance.module, &instance.store.gc_heap);
                if (!matches) {
                    try self.push(ref_val);
                    try self.branchTo(depth, reader);
                } else {
                    try self.push(ref_val);
                }
            },

            else => return error.Trap, // unimplemented GC opcodes
        }
    }

    /// Helper: get StructType from type index.
    fn getStructType(_: *Vm, instance: *Instance, type_idx: u32) ?module_mod.StructType {
        if (type_idx >= instance.module.types.items.len) return null;
        return switch (instance.module.types.items[type_idx].composite) {
            .struct_type => |st| st,
            else => null,
        };
    }

    /// Helper: get ArrayType from type index.
    fn getArrayType(_: *Vm, instance: *Instance, type_idx: u32) ?module_mod.ArrayType {
        if (type_idx >= instance.module.types.items.len) return null;
        return switch (instance.module.types.items[type_idx].composite) {
            .array_type => |at| at,
            else => null,
        };
    }

    fn executeMisc(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        const sub = try reader.readU32();
        if (self.profile) |p| {
            if (sub < 32) p.misc_counts[sub] += 1;
        }
        const misc: opcode.MiscOpcode = @enumFromInt(sub);
        switch (misc) {
            .i32_trunc_sat_f32_s => { const a = self.popF32(); try self.pushI32(truncSatClamp(i32, f32, a)); },
            .i32_trunc_sat_f32_u => { const a = self.popF32(); try self.pushI32(@bitCast(truncSatClamp(u32, f32, a))); },
            .i32_trunc_sat_f64_s => { const a = self.popF64(); try self.pushI32(truncSatClamp(i32, f64, a)); },
            .i32_trunc_sat_f64_u => { const a = self.popF64(); try self.pushI32(@bitCast(truncSatClamp(u32, f64, a))); },
            .i64_trunc_sat_f32_s => { const a = self.popF32(); try self.pushI64(truncSatClamp(i64, f32, a)); },
            .i64_trunc_sat_f32_u => { const a = self.popF32(); try self.pushI64(@bitCast(truncSatClamp(u64, f32, a))); },
            .i64_trunc_sat_f64_s => { const a = self.popF64(); try self.pushI64(truncSatClamp(i64, f64, a)); },
            .i64_trunc_sat_f64_u => { const a = self.popF64(); try self.pushI64(@bitCast(truncSatClamp(u64, f64, a))); },
            .memory_copy => {
                const dst_memidx: u16 = @intCast(try reader.readU32());
                const src_memidx: u16 = @intCast(try reader.readU32());
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const dst = @as(u32, @bitCast(self.popI32()));
                const dst_mem = try instance.getMemory(dst_memidx);
                if (dst_memidx == src_memidx) {
                    try dst_mem.copyWithin(dst, src, n);
                } else {
                    const src_mem = try instance.getMemory(src_memidx);
                    const src_data = src_mem.memory();
                    const dst_data = dst_mem.memory();
                    if (@as(u64, src) + n > src_data.len or @as(u64, dst) + n > dst_data.len)
                        return error.OutOfBoundsMemoryAccess;
                    if (n > 0) @memcpy(dst_data[dst..][0..n], src_data[src..][0..n]);
                }
            },
            .memory_fill => {
                const memidx: u16 = @intCast(try reader.readU32());
                const n = @as(u32, @bitCast(self.popI32()));
                const val = @as(u8, @truncate(@as(u32, @bitCast(self.popI32()))));
                const dst = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(memidx);
                try m.fill(dst, n, val);
            },
            .memory_init => {
                const data_idx = try reader.readU32();
                const memidx: u16 = @intCast(try reader.readU32());
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const dst = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(memidx);
                if (data_idx >= instance.dataaddrs.items.len) return error.Trap;
                const d = try instance.store.getData(instance.dataaddrs.items[data_idx]);
                // Dropped segments have effective length 0 (spec: n=0 succeeds even if dropped)
                const data_len: u64 = if (d.dropped) 0 else d.data.len;
                if (@as(u64, src) + n > data_len or @as(u64, dst) + n > m.memory().len)
                    return error.OutOfBoundsMemoryAccess;
                if (n > 0) @memcpy(m.memory()[dst..][0..n], d.data[src..][0..n]);
            },
            .data_drop => {
                const data_idx = try reader.readU32();
                if (data_idx >= instance.dataaddrs.items.len) return error.Trap;
                const d = try instance.store.getData(instance.dataaddrs.items[data_idx]);
                d.dropped = true;
            },
            .table_grow => {
                const table_idx = try reader.readU32();
                const t = try instance.store.getTable(table_idx);
                const n: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const val = self.pop();
                // Stack convention: 0 = null ref, addr+1 = valid ref
                const init_val: ?usize = if (val == 0) null else @intCast(val - 1);
                const old = t.grow(n, init_val) catch {
                    if (t.is_64) try self.pushI64(-1) else try self.pushI32(-1);
                    return;
                };
                if (t.is_64) try self.pushI64(@intCast(old)) else try self.pushI32(@bitCast(old));
            },
            .table_size => {
                const table_idx = try reader.readU32();
                const t = try instance.store.getTable(table_idx);
                if (t.is_64) try self.pushI64(@intCast(t.size())) else try self.pushI32(@bitCast(t.size()));
            },
            .table_fill => {
                const table_idx = try reader.readU32();
                const t = try instance.store.getTable(table_idx);
                const n: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const val = self.pop();
                const start: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                // Bounds check first (spec: trap if i + n > table.size)
                if (@as(u64, start) + n > t.size())
                    return error.OutOfBoundsMemoryAccess;
                // Stack convention: 0 = null ref, addr+1 = valid ref
                const ref_val: ?usize = if (val == 0) null else @intCast(val - 1);
                for (0..n) |i| {
                    t.set(start + @as(u32, @intCast(i)), ref_val) catch return error.OutOfBoundsMemoryAccess;
                }
            },
            .table_copy => {
                const dst_table_idx = try reader.readU32();
                const src_table_idx = try reader.readU32();
                const dst_t = try instance.getTable(dst_table_idx);
                const src_t = try instance.getTable(src_table_idx);
                // aN = min(aD, aS): if either table is i64, n is i64
                const n_64 = dst_t.is_64 or src_t.is_64;
                const n: u32 = if (n_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const src: u32 = if (src_t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const dst: u32 = if (dst_t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                // Bounds check
                if (@as(u64, src) + n > src_t.size() or @as(u64, dst) + n > dst_t.size())
                    return error.OutOfBoundsMemoryAccess;
                // Copy with overlap handling
                if (dst <= src) {
                    for (0..n) |i| {
                        const val = src_t.get(src + @as(u32, @intCast(i))) catch return error.OutOfBoundsMemoryAccess;
                        dst_t.set(dst + @as(u32, @intCast(i)), val) catch return error.OutOfBoundsMemoryAccess;
                    }
                } else {
                    var i: u32 = n;
                    while (i > 0) {
                        i -= 1;
                        const val = src_t.get(src + i) catch return error.OutOfBoundsMemoryAccess;
                        dst_t.set(dst + i, val) catch return error.OutOfBoundsMemoryAccess;
                    }
                }
            },
            .table_init => {
                const elem_idx = try reader.readU32();
                const table_idx = try reader.readU32();
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const t_for_addr = try instance.getTable(table_idx);
                const dst: u32 = if (t_for_addr.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                if (elem_idx >= instance.elemaddrs.items.len) return error.Trap;
                const e = try instance.store.getElem(instance.elemaddrs.items[elem_idx]);
                const t = try instance.getTable(table_idx);
                // Dropped segments have effective length 0 (spec: n=0 succeeds even if dropped)
                const elem_len: u64 = if (e.dropped) 0 else e.data.len;
                if (@as(u64, src) + n > elem_len or @as(u64, dst) + n > t.size())
                    return error.OutOfBoundsMemoryAccess;
                for (0..n) |i| {
                    const val = e.data[src + @as(u32, @intCast(i))];
                    const ref: ?usize = if (val == 0) null else @intCast(val - 1);
                    t.set(dst + @as(u32, @intCast(i)), ref) catch return error.OutOfBoundsMemoryAccess;
                }
            },
            .elem_drop => {
                const elem_idx = try reader.readU32();
                if (elem_idx >= instance.elemaddrs.items.len) return error.Trap;
                const e = try instance.store.getElem(instance.elemaddrs.items[elem_idx]);
                e.dropped = true;
            },
            // Wide arithmetic (i128 ops)
            .i64_add128 => {
                const rhs_hi: u64 = @bitCast(self.popI64());
                const rhs_lo: u64 = @bitCast(self.popI64());
                const lhs_hi: u64 = @bitCast(self.popI64());
                const lhs_lo: u64 = @bitCast(self.popI64());
                const lo = lhs_lo +% rhs_lo;
                const carry: u64 = if (lo < lhs_lo) 1 else 0;
                const hi = lhs_hi +% rhs_hi +% carry;
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            .i64_sub128 => {
                const rhs_hi: u64 = @bitCast(self.popI64());
                const rhs_lo: u64 = @bitCast(self.popI64());
                const lhs_hi: u64 = @bitCast(self.popI64());
                const lhs_lo: u64 = @bitCast(self.popI64());
                const lo = lhs_lo -% rhs_lo;
                const borrow: u64 = if (lhs_lo < rhs_lo) 1 else 0;
                const hi = lhs_hi -% rhs_hi -% borrow;
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            .i64_mul_wide_s => {
                const b: i64 = self.popI64();
                const a: i64 = self.popI64();
                const result: i128 = @as(i128, a) * @as(i128, b);
                const lo: u64 = @truncate(@as(u128, @bitCast(result)));
                const hi: u64 = @truncate(@as(u128, @bitCast(result)) >> 64);
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            .i64_mul_wide_u => {
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                const result: u128 = @as(u128, a) * @as(u128, b);
                const lo: u64 = @truncate(result);
                const hi: u64 = @truncate(result >> 64);
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            _ => return error.Trap,
        }
    }

    fn executeAtomic(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        const sub = try reader.readU32();
        const atomic_op: opcode.AtomicOpcode = @enumFromInt(sub);

        if (atomic_op == .atomic_fence) {
            // atomic.fence — no-op for single-threaded runtime
            const reserved = try reader.readByte();
            if (reserved != 0x00) return error.Trap;
            return;
        }

        // All other atomic ops have memarg (align + offset)
        const align_flags = try reader.readU32();
        const offset = try reader.readU32();
        _ = align_flags; // alignment validated at decode time
        const m = instance.getMemory(0) catch return error.OutOfBoundsMemoryAccess;

        switch (atomic_op) {
            .atomic_fence => unreachable, // handled above

            // ---- Wait/Notify ----
            .memory_atomic_notify => {
                _ = self.popI32(); // count
                const addr: u32 = @bitCast(self.popI32());
                if ((addr +% offset) % 4 != 0) return error.Trap; // unaligned atomic
                _ = m.read(u32, offset, addr) catch return error.OutOfBoundsMemoryAccess;
                try self.pushI32(0); // 0 waiters notified
            },
            .memory_atomic_wait32 => {
                _ = self.popI64(); // timeout
                const expected: i32 = self.popI32();
                const addr: u32 = @bitCast(self.popI32());
                if ((addr +% offset) % 4 != 0) return error.Trap; // unaligned atomic
                if (!m.is_shared_memory) return error.Trap; // expected shared memory
                const loaded = m.read(i32, offset, addr) catch return error.OutOfBoundsMemoryAccess;
                if (loaded != expected) {
                    try self.pushI32(1); // "not-equal"
                } else {
                    try self.pushI32(2); // "timed-out" (single-threaded: can never be woken)
                }
            },
            .memory_atomic_wait64 => {
                _ = self.popI64(); // timeout
                const expected: i64 = self.popI64();
                const addr: u32 = @bitCast(self.popI32());
                if ((addr +% offset) % 8 != 0) return error.Trap; // unaligned atomic
                if (!m.is_shared_memory) return error.Trap; // expected shared memory
                const loaded = m.read(i64, offset, addr) catch return error.OutOfBoundsMemoryAccess;
                if (loaded != expected) {
                    try self.pushI32(1); // "not-equal"
                } else {
                    try self.pushI32(2); // "timed-out"
                }
            },

            // ---- Atomic loads ----
            .i32_atomic_load => try self.atomicLoad(u32, u32, offset, m),
            .i64_atomic_load => try self.atomicLoad(u64, u64, offset, m),
            .i32_atomic_load8_u => try self.atomicLoad(u8, u32, offset, m),
            .i32_atomic_load16_u => try self.atomicLoad(u16, u32, offset, m),
            .i64_atomic_load8_u => try self.atomicLoad(u8, u64, offset, m),
            .i64_atomic_load16_u => try self.atomicLoad(u16, u64, offset, m),
            .i64_atomic_load32_u => try self.atomicLoad(u32, u64, offset, m),

            // ---- Atomic stores ----
            .i32_atomic_store => try self.atomicStore(u32, .i32, offset, m),
            .i64_atomic_store => try self.atomicStore(u64, .i64, offset, m),
            .i32_atomic_store8 => try self.atomicStore(u8, .i32, offset, m),
            .i32_atomic_store16 => try self.atomicStore(u16, .i32, offset, m),
            .i64_atomic_store8 => try self.atomicStore(u8, .i64, offset, m),
            .i64_atomic_store16 => try self.atomicStore(u16, .i64, offset, m),
            .i64_atomic_store32 => try self.atomicStore(u32, .i64, offset, m),

            // ---- RMW add ----
            .i32_atomic_rmw_add => try self.atomicRmw(u32, u32, .add, offset, m),
            .i64_atomic_rmw_add => try self.atomicRmw(u64, u64, .add, offset, m),
            .i32_atomic_rmw8_add_u => try self.atomicRmw(u8, u32, .add, offset, m),
            .i32_atomic_rmw16_add_u => try self.atomicRmw(u16, u32, .add, offset, m),
            .i64_atomic_rmw8_add_u => try self.atomicRmw(u8, u64, .add, offset, m),
            .i64_atomic_rmw16_add_u => try self.atomicRmw(u16, u64, .add, offset, m),
            .i64_atomic_rmw32_add_u => try self.atomicRmw(u32, u64, .add, offset, m),

            // ---- RMW sub ----
            .i32_atomic_rmw_sub => try self.atomicRmw(u32, u32, .sub, offset, m),
            .i64_atomic_rmw_sub => try self.atomicRmw(u64, u64, .sub, offset, m),
            .i32_atomic_rmw8_sub_u => try self.atomicRmw(u8, u32, .sub, offset, m),
            .i32_atomic_rmw16_sub_u => try self.atomicRmw(u16, u32, .sub, offset, m),
            .i64_atomic_rmw8_sub_u => try self.atomicRmw(u8, u64, .sub, offset, m),
            .i64_atomic_rmw16_sub_u => try self.atomicRmw(u16, u64, .sub, offset, m),
            .i64_atomic_rmw32_sub_u => try self.atomicRmw(u32, u64, .sub, offset, m),

            // ---- RMW and ----
            .i32_atomic_rmw_and => try self.atomicRmw(u32, u32, .@"and", offset, m),
            .i64_atomic_rmw_and => try self.atomicRmw(u64, u64, .@"and", offset, m),
            .i32_atomic_rmw8_and_u => try self.atomicRmw(u8, u32, .@"and", offset, m),
            .i32_atomic_rmw16_and_u => try self.atomicRmw(u16, u32, .@"and", offset, m),
            .i64_atomic_rmw8_and_u => try self.atomicRmw(u8, u64, .@"and", offset, m),
            .i64_atomic_rmw16_and_u => try self.atomicRmw(u16, u64, .@"and", offset, m),
            .i64_atomic_rmw32_and_u => try self.atomicRmw(u32, u64, .@"and", offset, m),

            // ---- RMW or ----
            .i32_atomic_rmw_or => try self.atomicRmw(u32, u32, .@"or", offset, m),
            .i64_atomic_rmw_or => try self.atomicRmw(u64, u64, .@"or", offset, m),
            .i32_atomic_rmw8_or_u => try self.atomicRmw(u8, u32, .@"or", offset, m),
            .i32_atomic_rmw16_or_u => try self.atomicRmw(u16, u32, .@"or", offset, m),
            .i64_atomic_rmw8_or_u => try self.atomicRmw(u8, u64, .@"or", offset, m),
            .i64_atomic_rmw16_or_u => try self.atomicRmw(u16, u64, .@"or", offset, m),
            .i64_atomic_rmw32_or_u => try self.atomicRmw(u32, u64, .@"or", offset, m),

            // ---- RMW xor ----
            .i32_atomic_rmw_xor => try self.atomicRmw(u32, u32, .xor, offset, m),
            .i64_atomic_rmw_xor => try self.atomicRmw(u64, u64, .xor, offset, m),
            .i32_atomic_rmw8_xor_u => try self.atomicRmw(u8, u32, .xor, offset, m),
            .i32_atomic_rmw16_xor_u => try self.atomicRmw(u16, u32, .xor, offset, m),
            .i64_atomic_rmw8_xor_u => try self.atomicRmw(u8, u64, .xor, offset, m),
            .i64_atomic_rmw16_xor_u => try self.atomicRmw(u16, u64, .xor, offset, m),
            .i64_atomic_rmw32_xor_u => try self.atomicRmw(u32, u64, .xor, offset, m),

            // ---- RMW xchg ----
            .i32_atomic_rmw_xchg => try self.atomicRmw(u32, u32, .xchg, offset, m),
            .i64_atomic_rmw_xchg => try self.atomicRmw(u64, u64, .xchg, offset, m),
            .i32_atomic_rmw8_xchg_u => try self.atomicRmw(u8, u32, .xchg, offset, m),
            .i32_atomic_rmw16_xchg_u => try self.atomicRmw(u16, u32, .xchg, offset, m),
            .i64_atomic_rmw8_xchg_u => try self.atomicRmw(u8, u64, .xchg, offset, m),
            .i64_atomic_rmw16_xchg_u => try self.atomicRmw(u16, u64, .xchg, offset, m),
            .i64_atomic_rmw32_xchg_u => try self.atomicRmw(u32, u64, .xchg, offset, m),

            // ---- RMW cmpxchg ----
            .i32_atomic_rmw_cmpxchg => try self.atomicCmpxchg(u32, u32, offset, m),
            .i64_atomic_rmw_cmpxchg => try self.atomicCmpxchg(u64, u64, offset, m),
            .i32_atomic_rmw8_cmpxchg_u => try self.atomicCmpxchg(u8, u32, offset, m),
            .i32_atomic_rmw16_cmpxchg_u => try self.atomicCmpxchg(u16, u32, offset, m),
            .i64_atomic_rmw8_cmpxchg_u => try self.atomicCmpxchg(u8, u64, offset, m),
            .i64_atomic_rmw16_cmpxchg_u => try self.atomicCmpxchg(u16, u64, offset, m),
            .i64_atomic_rmw32_cmpxchg_u => try self.atomicCmpxchg(u32, u64, offset, m),

            _ => return error.Trap,
        }
    }

    // Single-threaded atomic helpers — behave like regular ops

    const RmwOp = enum { add, sub, @"and", @"or", xor, xchg };

    fn atomicLoad(self: *Vm, comptime MemT: type, comptime ResultT: type, offset: u32, m: *WasmMemory) WasmError!void {
        const addr: u32 = @bitCast(self.popI32());
        if (@sizeOf(MemT) > 1 and (addr +% offset) % @sizeOf(MemT) != 0) return error.Trap;
        const val = m.read(MemT, offset, addr) catch return error.OutOfBoundsMemoryAccess;
        const result: ResultT = @intCast(val);
        try self.push(asU64(ResultT, result));
    }

    fn atomicStore(self: *Vm, comptime MemT: type, comptime pop_type: enum { i32, i64 }, offset: u32, m: *WasmMemory) WasmError!void {
        const val: MemT = switch (pop_type) {
            .i32 => @truncate(@as(u32, @bitCast(self.popI32()))),
            .i64 => @truncate(@as(u64, @bitCast(self.popI64()))),
        };
        const addr: u32 = @bitCast(self.popI32());
        if (@sizeOf(MemT) > 1 and (addr +% offset) % @sizeOf(MemT) != 0) return error.Trap;
        m.write(MemT, offset, addr, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn atomicRmw(self: *Vm, comptime MemT: type, comptime ResultT: type, comptime op: RmwOp, offset: u32, m: *WasmMemory) WasmError!void {
        const operand: MemT = switch (ResultT) {
            u32 => @truncate(@as(u32, @bitCast(self.popI32()))),
            u64 => @truncate(@as(u64, @bitCast(self.popI64()))),
            else => unreachable,
        };
        const addr: u32 = @bitCast(self.popI32());
        if (@sizeOf(MemT) > 1 and (addr +% offset) % @sizeOf(MemT) != 0) return error.Trap;
        const old = m.read(MemT, offset, addr) catch return error.OutOfBoundsMemoryAccess;
        const new_val: MemT = switch (op) {
            .add => old +% operand,
            .sub => old -% operand,
            .@"and" => old & operand,
            .@"or" => old | operand,
            .xor => old ^ operand,
            .xchg => operand,
        };
        m.write(MemT, offset, addr, new_val) catch return error.OutOfBoundsMemoryAccess;
        const result: ResultT = @intCast(old);
        try self.push(asU64(ResultT, result));
    }

    fn atomicCmpxchg(self: *Vm, comptime MemT: type, comptime ResultT: type, offset: u32, m: *WasmMemory) WasmError!void {
        const replacement: MemT = switch (ResultT) {
            u32 => @truncate(@as(u32, @bitCast(self.popI32()))),
            u64 => @truncate(@as(u64, @bitCast(self.popI64()))),
            else => unreachable,
        };
        const expected: MemT = switch (ResultT) {
            u32 => @truncate(@as(u32, @bitCast(self.popI32()))),
            u64 => @truncate(@as(u64, @bitCast(self.popI64()))),
            else => unreachable,
        };
        const addr: u32 = @bitCast(self.popI32());
        if (@sizeOf(MemT) > 1 and (addr +% offset) % @sizeOf(MemT) != 0) return error.Trap;
        const loaded = m.read(MemT, offset, addr) catch return error.OutOfBoundsMemoryAccess;
        if (loaded == expected) {
            m.write(MemT, offset, addr, replacement) catch return error.OutOfBoundsMemoryAccess;
        }
        const result: ResultT = @intCast(loaded);
        try self.push(asU64(ResultT, result));
    }

    fn executeSimd(self: *Vm, reader: *Reader, instance: *Instance) WasmError!void {
        const sub = try reader.readU32();
        const simd: opcode.SimdOpcode = @enumFromInt(sub);
        switch (simd) {
            // ---- Memory operations (36.2) ----
            .v128_load => {
                const ma = try readMemarg(reader, instance);
                const base = @as(u32, @bitCast(self.popI32()));
                const val = ma.mem.read(u128, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
                try self.pushV128(val);
            },
            .v128_store => {
                const ma = try readMemarg(reader, instance);
                const val = self.popV128();
                const base = @as(u32, @bitCast(self.popI32()));
                ma.mem.write(u128, ma.offset, base, val) catch return error.OutOfBoundsMemoryAccess;
            },
            .v128_const => {
                // 16 raw bytes (little-endian u128)
                var bytes: [16]u8 = undefined;
                for (&bytes) |*b| b.* = try reader.readByte();
                try self.pushV128(std.mem.readInt(u128, &bytes, .little));
            },

            // Splat loads
            .v128_load8_splat => {
                const ma = try readMemarg(reader, instance);
                const base = @as(u32, @bitCast(self.popI32()));
                const val = ma.mem.read(u8, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(16, u8) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .v128_load16_splat => {
                const ma = try readMemarg(reader, instance);
                const base = @as(u32, @bitCast(self.popI32()));
                const val = ma.mem.read(u16, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(8, u16) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .v128_load32_splat => {
                const ma = try readMemarg(reader, instance);
                const base = @as(u32, @bitCast(self.popI32()));
                const val = ma.mem.read(u32, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(4, u32) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .v128_load64_splat => {
                const ma = try readMemarg(reader, instance);
                const base = @as(u32, @bitCast(self.popI32()));
                const val = ma.mem.read(u64, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
                const vec: @Vector(2, u64) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },

            // Extending loads
            .v128_load8x8_s => try self.simdExtendLoad(i8, i16, reader, instance),
            .v128_load8x8_u => try self.simdExtendLoad(u8, u16, reader, instance),
            .v128_load16x4_s => try self.simdExtendLoad(i16, i32, reader, instance),
            .v128_load16x4_u => try self.simdExtendLoad(u16, u32, reader, instance),
            .v128_load32x2_s => try self.simdExtendLoad(i32, i64, reader, instance),
            .v128_load32x2_u => try self.simdExtendLoad(u32, u64, reader, instance),

            // Zero-extending loads
            .v128_load32_zero => {
                const ma = try readMemarg(reader, instance);
                const base = @as(u32, @bitCast(self.popI32()));
                const val = ma.mem.read(u32, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
                try self.pushV128(@as(u128, val));
            },
            .v128_load64_zero => {
                const ma = try readMemarg(reader, instance);
                const base = @as(u32, @bitCast(self.popI32()));
                const val = ma.mem.read(u64, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
                try self.pushV128(@as(u128, val));
            },

            // Lane loads — load N bytes from memory into a specific lane
            .v128_load8_lane => try self.simdLoadLane(u8, 16, reader, instance),
            .v128_load16_lane => try self.simdLoadLane(u16, 8, reader, instance),
            .v128_load32_lane => try self.simdLoadLane(u32, 4, reader, instance),
            .v128_load64_lane => try self.simdLoadLane(u64, 2, reader, instance),

            // Lane stores — store N bytes from a specific lane to memory
            .v128_store8_lane => try self.simdStoreLane(u8, 16, reader, instance),
            .v128_store16_lane => try self.simdStoreLane(u16, 8, reader, instance),
            .v128_store32_lane => try self.simdStoreLane(u32, 4, reader, instance),
            .v128_store64_lane => try self.simdStoreLane(u64, 2, reader, instance),

            // ---- Splat ----
            .i8x16_splat => {
                const val: u8 = @truncate(self.pop());
                const vec: @Vector(16, u8) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .i16x8_splat => {
                const val: u16 = @truncate(self.pop());
                const vec: @Vector(8, u16) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .i32x4_splat => {
                const val: u32 = @truncate(self.pop());
                const vec: @Vector(4, u32) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .i64x2_splat => {
                const val = self.pop();
                const vec: @Vector(2, u64) = @splat(val);
                try self.pushV128(@bitCast(vec));
            },
            .f32x4_splat => {
                const val = self.popF32();
                const bits: u32 = @bitCast(val);
                const vec: @Vector(4, u32) = @splat(bits);
                try self.pushV128(@bitCast(vec));
            },
            .f64x2_splat => {
                const val = self.popF64();
                const bits: u64 = @bitCast(val);
                const vec: @Vector(2, u64) = @splat(bits);
                try self.pushV128(@bitCast(vec));
            },

            // ---- Extract / replace lane ----
            .i8x16_extract_lane_s => {
                const lane = try reader.readByte();
                const vec: @Vector(16, i8) = @bitCast(self.popV128());
                try self.pushI32(@as(i32, vec[lane]));
            },
            .i8x16_extract_lane_u => {
                const lane = try reader.readByte();
                const vec: @Vector(16, u8) = @bitCast(self.popV128());
                try self.push(@as(u64, vec[lane]));
            },
            .i8x16_replace_lane => {
                const lane = try reader.readByte();
                const val: u8 = @truncate(self.pop());
                var vec: @Vector(16, u8) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .i16x8_extract_lane_s => {
                const lane = try reader.readByte();
                const vec: @Vector(8, i16) = @bitCast(self.popV128());
                try self.pushI32(@as(i32, vec[lane]));
            },
            .i16x8_extract_lane_u => {
                const lane = try reader.readByte();
                const vec: @Vector(8, u16) = @bitCast(self.popV128());
                try self.push(@as(u64, vec[lane]));
            },
            .i16x8_replace_lane => {
                const lane = try reader.readByte();
                const val: u16 = @truncate(self.pop());
                var vec: @Vector(8, u16) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .i32x4_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(4, i32) = @bitCast(self.popV128());
                try self.pushI32(vec[lane]);
            },
            .i32x4_replace_lane => {
                const lane = try reader.readByte();
                const val = self.popI32();
                var vec: @Vector(4, i32) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .i64x2_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(2, i64) = @bitCast(self.popV128());
                try self.pushI64(vec[lane]);
            },
            .i64x2_replace_lane => {
                const lane = try reader.readByte();
                const val = self.popI64();
                var vec: @Vector(2, i64) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .f32x4_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(4, u32) = @bitCast(self.popV128());
                try self.pushF32(@bitCast(vec[lane]));
            },
            .f32x4_replace_lane => {
                const lane = try reader.readByte();
                const val: u32 = @bitCast(self.popF32());
                var vec: @Vector(4, u32) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },
            .f64x2_extract_lane => {
                const lane = try reader.readByte();
                const vec: @Vector(2, u64) = @bitCast(self.popV128());
                try self.pushF64(@bitCast(vec[lane]));
            },
            .f64x2_replace_lane => {
                const lane = try reader.readByte();
                const val: u64 = @bitCast(self.popF64());
                var vec: @Vector(2, u64) = @bitCast(self.popV128());
                vec[lane] = val;
                try self.pushV128(@bitCast(vec));
            },

            // ---- Shuffle / swizzle ----
            .i8x16_shuffle => {
                var lanes: [16]u8 = undefined;
                for (&lanes) |*l| l.* = try reader.readByte();
                const b: @Vector(16, u8) = @bitCast(self.popV128());
                const a: @Vector(16, u8) = @bitCast(self.popV128());
                // Concatenate a ++ b (32 bytes), select by lane indices
                var result: [16]u8 = undefined;
                const a_bytes: [16]u8 = @bitCast(a);
                const b_bytes: [16]u8 = @bitCast(b);
                for (lanes, 0..) |idx, i| {
                    result[i] = if (idx < 16) a_bytes[idx] else b_bytes[idx - 16];
                }
                try self.pushV128(@bitCast(@as(@Vector(16, u8), result)));
            },
            .i8x16_swizzle => {
                const indices: @Vector(16, u8) = @bitCast(self.popV128());
                const vec: [16]u8 = @bitCast(self.popV128());
                var result: [16]u8 = undefined;
                for (0..16) |i| {
                    const idx = indices[i];
                    result[i] = if (idx < 16) vec[idx] else 0;
                }
                try self.pushV128(@bitCast(@as(@Vector(16, u8), result)));
            },

            // ---- Bitwise (36.3) ----
            .v128_not => { const a = self.popV128(); try self.pushV128(~a); },
            .v128_and => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a & b); },
            .v128_andnot => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a & ~b); },
            .v128_or => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a | b); },
            .v128_xor => { const b = self.popV128(); const a = self.popV128(); try self.pushV128(a ^ b); },
            .v128_bitselect => {
                const c = self.popV128();
                const b = self.popV128();
                const a = self.popV128();
                try self.pushV128((a & c) | (b & ~c));
            },
            .v128_any_true => {
                const a = self.popV128();
                try self.pushI32(b2i(a != 0));
            },

            // ---- Integer comparison (36.3) ----
            .i8x16_eq => try self.simdCmpOp(i8, 16, .eq),
            .i8x16_ne => try self.simdCmpOp(i8, 16, .ne),
            .i8x16_lt_s => try self.simdCmpOp(i8, 16, .lt),
            .i8x16_lt_u => try self.simdCmpOp(u8, 16, .lt),
            .i8x16_gt_s => try self.simdCmpOp(i8, 16, .gt),
            .i8x16_gt_u => try self.simdCmpOp(u8, 16, .gt),
            .i8x16_le_s => try self.simdCmpOp(i8, 16, .le),
            .i8x16_le_u => try self.simdCmpOp(u8, 16, .le),
            .i8x16_ge_s => try self.simdCmpOp(i8, 16, .ge),
            .i8x16_ge_u => try self.simdCmpOp(u8, 16, .ge),
            .i16x8_eq => try self.simdCmpOp(i16, 8, .eq),
            .i16x8_ne => try self.simdCmpOp(i16, 8, .ne),
            .i16x8_lt_s => try self.simdCmpOp(i16, 8, .lt),
            .i16x8_lt_u => try self.simdCmpOp(u16, 8, .lt),
            .i16x8_gt_s => try self.simdCmpOp(i16, 8, .gt),
            .i16x8_gt_u => try self.simdCmpOp(u16, 8, .gt),
            .i16x8_le_s => try self.simdCmpOp(i16, 8, .le),
            .i16x8_le_u => try self.simdCmpOp(u16, 8, .le),
            .i16x8_ge_s => try self.simdCmpOp(i16, 8, .ge),
            .i16x8_ge_u => try self.simdCmpOp(u16, 8, .ge),
            .i32x4_eq => try self.simdCmpOp(i32, 4, .eq),
            .i32x4_ne => try self.simdCmpOp(i32, 4, .ne),
            .i32x4_lt_s => try self.simdCmpOp(i32, 4, .lt),
            .i32x4_lt_u => try self.simdCmpOp(u32, 4, .lt),
            .i32x4_gt_s => try self.simdCmpOp(i32, 4, .gt),
            .i32x4_gt_u => try self.simdCmpOp(u32, 4, .gt),
            .i32x4_le_s => try self.simdCmpOp(i32, 4, .le),
            .i32x4_le_u => try self.simdCmpOp(u32, 4, .le),
            .i32x4_ge_s => try self.simdCmpOp(i32, 4, .ge),
            .i32x4_ge_u => try self.simdCmpOp(u32, 4, .ge),
            .i64x2_eq => try self.simdCmpOp(i64, 2, .eq),
            .i64x2_ne => try self.simdCmpOp(i64, 2, .ne),
            .i64x2_lt_s => try self.simdCmpOp(i64, 2, .lt),
            .i64x2_gt_s => try self.simdCmpOp(i64, 2, .gt),
            .i64x2_le_s => try self.simdCmpOp(i64, 2, .le),
            .i64x2_ge_s => try self.simdCmpOp(i64, 2, .ge),

            // ---- Integer unary (36.3) ----
            .i8x16_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(16, i8), @bitCast(self.popV128()))))); },
            .i16x8_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(8, i16), @bitCast(self.popV128()))))); },
            .i32x4_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(4, i32), @bitCast(self.popV128()))))); },
            .i64x2_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(2, i64), @bitCast(self.popV128()))))); },
            .i8x16_neg => { const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(16, i8), @splat(@as(i8, 0))) -% a)); },
            .i16x8_neg => { const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(8, i16), @splat(@as(i16, 0))) -% a)); },
            .i32x4_neg => { const a: @Vector(4, i32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(4, i32), @splat(@as(i32, 0))) -% a)); },
            .i64x2_neg => { const a: @Vector(2, i64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@as(@Vector(2, i64), @splat(@as(i64, 0))) -% a)); },
            .i8x16_popcnt => {
                const a: @Vector(16, u8) = @bitCast(self.popV128());
                const counts: @Vector(16, u4) = @popCount(a);
                const widened: @Vector(16, u8) = counts;
                try self.pushV128(@bitCast(widened));
            },
            .i8x16_all_true => try self.simdAllTrue(u8, 16),
            .i16x8_all_true => try self.simdAllTrue(u16, 8),
            .i32x4_all_true => try self.simdAllTrue(u32, 4),
            .i64x2_all_true => try self.simdAllTrue(u64, 2),
            .i8x16_bitmask => try self.simdBitmask(16, 8),
            .i16x8_bitmask => try self.simdBitmask(8, 16),
            .i32x4_bitmask => try self.simdBitmask(4, 32),
            .i64x2_bitmask => try self.simdBitmask(2, 64),

            // ---- Narrowing (36.3) ----
            .i8x16_narrow_i16x8_s => try self.simdNarrow(i8, i16, 8),
            .i8x16_narrow_i16x8_u => try self.simdNarrow(u8, i16, 8),
            .i16x8_narrow_i32x4_s => try self.simdNarrow(i16, i32, 4),
            .i16x8_narrow_i32x4_u => try self.simdNarrow(u16, i32, 4),

            // ---- Extending (36.3) ----
            .i16x8_extend_low_i8x16_s => try self.simdExtend(i16, i8, 8, true),
            .i16x8_extend_high_i8x16_s => try self.simdExtend(i16, i8, 8, false),
            .i16x8_extend_low_i8x16_u => try self.simdExtend(i16, u8, 8, true),
            .i16x8_extend_high_i8x16_u => try self.simdExtend(i16, u8, 8, false),
            .i32x4_extend_low_i16x8_s => try self.simdExtend(i32, i16, 4, true),
            .i32x4_extend_high_i16x8_s => try self.simdExtend(i32, i16, 4, false),
            .i32x4_extend_low_i16x8_u => try self.simdExtend(i32, u16, 4, true),
            .i32x4_extend_high_i16x8_u => try self.simdExtend(i32, u16, 4, false),
            .i64x2_extend_low_i32x4_s => try self.simdExtend(i64, i32, 2, true),
            .i64x2_extend_high_i32x4_s => try self.simdExtend(i64, i32, 2, false),
            .i64x2_extend_low_i32x4_u => try self.simdExtend(i64, u32, 2, true),
            .i64x2_extend_high_i32x4_u => try self.simdExtend(i64, u32, 2, false),

            // ---- Shift (36.3) ----
            .i8x16_shl => try self.simdShift(u8, 16, .shl),
            .i8x16_shr_s => try self.simdShift(i8, 16, .shr),
            .i8x16_shr_u => try self.simdShift(u8, 16, .shr),
            .i16x8_shl => try self.simdShift(u16, 8, .shl),
            .i16x8_shr_s => try self.simdShift(i16, 8, .shr),
            .i16x8_shr_u => try self.simdShift(u16, 8, .shr),
            .i32x4_shl => try self.simdShift(u32, 4, .shl),
            .i32x4_shr_s => try self.simdShift(i32, 4, .shr),
            .i32x4_shr_u => try self.simdShift(u32, 4, .shr),
            .i64x2_shl => try self.simdShift(u64, 2, .shl),
            .i64x2_shr_s => try self.simdShift(i64, 2, .shr),
            .i64x2_shr_u => try self.simdShift(u64, 2, .shr),

            // ---- Wrapping arithmetic (36.3) ----
            .i8x16_add => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i8x16_sub => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i16x8_add => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i16x8_sub => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i16x8_mul => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a *% b)); },
            .i32x4_add => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i32x4_sub => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i32x4_mul => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a *% b)); },
            .i64x2_add => { const b: @Vector(2, u64) = @bitCast(self.popV128()); const a: @Vector(2, u64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +% b)); },
            .i64x2_sub => { const b: @Vector(2, u64) = @bitCast(self.popV128()); const a: @Vector(2, u64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -% b)); },
            .i64x2_mul => { const b: @Vector(2, u64) = @bitCast(self.popV128()); const a: @Vector(2, u64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a *% b)); },

            // ---- Saturating arithmetic (36.3) ----
            .i8x16_add_sat_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i8x16_add_sat_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i8x16_sub_sat_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },
            .i8x16_sub_sat_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },
            .i16x8_add_sat_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i16x8_add_sat_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a +| b)); },
            .i16x8_sub_sat_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },
            .i16x8_sub_sat_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a -| b)); },

            // ---- Min / max (36.3) ----
            .i8x16_min_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i8x16_min_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i8x16_max_s => { const b: @Vector(16, i8) = @bitCast(self.popV128()); const a: @Vector(16, i8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i8x16_max_u => { const b: @Vector(16, u8) = @bitCast(self.popV128()); const a: @Vector(16, u8) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i16x8_min_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i16x8_min_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i16x8_max_s => { const b: @Vector(8, i16) = @bitCast(self.popV128()); const a: @Vector(8, i16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i16x8_max_u => { const b: @Vector(8, u16) = @bitCast(self.popV128()); const a: @Vector(8, u16) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i32x4_min_s => { const b: @Vector(4, i32) = @bitCast(self.popV128()); const a: @Vector(4, i32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i32x4_min_u => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@min(a, b))); },
            .i32x4_max_s => { const b: @Vector(4, i32) = @bitCast(self.popV128()); const a: @Vector(4, i32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },
            .i32x4_max_u => { const b: @Vector(4, u32) = @bitCast(self.popV128()); const a: @Vector(4, u32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@max(a, b))); },

            // ---- Unsigned rounding average (36.3) ----
            .i8x16_avgr_u => {
                const b: [16]u8 = @bitCast(self.popV128());
                const a: [16]u8 = @bitCast(self.popV128());
                var r: [16]u8 = undefined;
                inline for (0..16) |i| r[i] = @truncate((@as(u16, a[i]) + @as(u16, b[i]) + 1) / 2);
                try self.pushV128(@bitCast(r));
            },
            .i16x8_avgr_u => {
                const b: [8]u16 = @bitCast(self.popV128());
                const a: [8]u16 = @bitCast(self.popV128());
                var r: [8]u16 = undefined;
                inline for (0..8) |i| r[i] = @truncate((@as(u32, a[i]) + @as(u32, b[i]) + 1) / 2);
                try self.pushV128(@bitCast(r));
            },

            // ---- Extended pairwise addition (36.3) ----
            .i16x8_extadd_pairwise_i8x16_s => try self.simdExtAddPairwise(i8, i16),
            .i16x8_extadd_pairwise_i8x16_u => try self.simdExtAddPairwise(u8, u16),
            .i32x4_extadd_pairwise_i16x8_s => try self.simdExtAddPairwise(i16, i32),
            .i32x4_extadd_pairwise_i16x8_u => try self.simdExtAddPairwise(u16, u32),

            // ---- Extended multiply (36.3) ----
            .i16x8_extmul_low_i8x16_s => try self.simdExtMul(i8, i16, 8, true),
            .i16x8_extmul_high_i8x16_s => try self.simdExtMul(i8, i16, 8, false),
            .i16x8_extmul_low_i8x16_u => try self.simdExtMul(u8, u16, 8, true),
            .i16x8_extmul_high_i8x16_u => try self.simdExtMul(u8, u16, 8, false),
            .i32x4_extmul_low_i16x8_s => try self.simdExtMul(i16, i32, 4, true),
            .i32x4_extmul_high_i16x8_s => try self.simdExtMul(i16, i32, 4, false),
            .i32x4_extmul_low_i16x8_u => try self.simdExtMul(u16, u32, 4, true),
            .i32x4_extmul_high_i16x8_u => try self.simdExtMul(u16, u32, 4, false),
            .i64x2_extmul_low_i32x4_s => try self.simdExtMul(i32, i64, 2, true),
            .i64x2_extmul_high_i32x4_s => try self.simdExtMul(i32, i64, 2, false),
            .i64x2_extmul_low_i32x4_u => try self.simdExtMul(u32, u64, 2, true),
            .i64x2_extmul_high_i32x4_u => try self.simdExtMul(u32, u64, 2, false),

            // ---- Dot product (36.3) ----
            .i32x4_dot_i16x8_s => {
                const b: [8]i16 = @bitCast(self.popV128());
                const a: [8]i16 = @bitCast(self.popV128());
                var r: [4]i32 = undefined;
                inline for (0..4) |i| {
                    const p0 = @as(i32, a[i * 2]) *% @as(i32, b[i * 2]);
                    const p1 = @as(i32, a[i * 2 + 1]) *% @as(i32, b[i * 2 + 1]);
                    r[i] = p0 +% p1;
                }
                try self.pushV128(@bitCast(r));
            },

            // ---- Q15 saturating multiply (36.3) ----
            .i16x8_q15mulr_sat_s => {
                const b: [8]i16 = @bitCast(self.popV128());
                const a: [8]i16 = @bitCast(self.popV128());
                var r: [8]i16 = undefined;
                inline for (0..8) |i| {
                    const product: i32 = @as(i32, a[i]) * @as(i32, b[i]);
                    r[i] = @intCast(std.math.clamp((product + 0x4000) >> 15, -32768, 32767));
                }
                try self.pushV128(@bitCast(r));
            },

            // ---- Float comparison (36.4) ----
            .f32x4_eq => try self.simdCmpOp(f32, 4, .eq),
            .f32x4_ne => try self.simdCmpOp(f32, 4, .ne),
            .f32x4_lt => try self.simdCmpOp(f32, 4, .lt),
            .f32x4_gt => try self.simdCmpOp(f32, 4, .gt),
            .f32x4_le => try self.simdCmpOp(f32, 4, .le),
            .f32x4_ge => try self.simdCmpOp(f32, 4, .ge),
            .f64x2_eq => try self.simdCmpOp(f64, 2, .eq),
            .f64x2_ne => try self.simdCmpOp(f64, 2, .ne),
            .f64x2_lt => try self.simdCmpOp(f64, 2, .lt),
            .f64x2_gt => try self.simdCmpOp(f64, 2, .gt),
            .f64x2_le => try self.simdCmpOp(f64, 2, .le),
            .f64x2_ge => try self.simdCmpOp(f64, 2, .ge),

            // ---- Float unary (36.4) ----
            .f32x4_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(4, f32), @bitCast(self.popV128()))))); },
            .f64x2_abs => { try self.pushV128(@bitCast(@abs(@as(@Vector(2, f64), @bitCast(self.popV128()))))); },
            .f32x4_neg => {
                const a_bits: @Vector(4, u32) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(a_bits ^ @as(@Vector(4, u32), @splat(@as(u32, 0x80000000)))));
            },
            .f64x2_neg => {
                const a_bits: @Vector(2, u64) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(a_bits ^ @as(@Vector(2, u64), @splat(@as(u64, 0x8000000000000000)))));
            },
            .f32x4_sqrt => { try self.pushV128(@bitCast(@sqrt(@as(@Vector(4, f32), @bitCast(self.popV128()))))); },
            .f64x2_sqrt => { try self.pushV128(@bitCast(@sqrt(@as(@Vector(2, f64), @bitCast(self.popV128()))))); },

            // ---- Float arithmetic (36.4) ----
            .f32x4_add => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a + b)); },
            .f32x4_sub => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a - b)); },
            .f32x4_mul => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a * b)); },
            .f32x4_div => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a / b)); },
            .f64x2_add => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a + b)); },
            .f64x2_sub => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a - b)); },
            .f64x2_mul => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a * b)); },
            .f64x2_div => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(a / b)); },

            // ---- Float min/max (36.4) — IEEE 754 semantics with NaN propagation ----
            .f32x4_min => { try self.simdMinMax(f32, 4, .min); },
            .f32x4_max => { try self.simdMinMax(f32, 4, .max); },
            .f64x2_min => { try self.simdMinMax(f64, 2, .min); },
            .f64x2_max => { try self.simdMinMax(f64, 2, .max); },

            // ---- Float pseudo min/max (36.4) — simple comparison, no NaN propagation ----
            .f32x4_pmin => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f32, b < a, b, a))); },
            .f32x4_pmax => { const b: @Vector(4, f32) = @bitCast(self.popV128()); const a: @Vector(4, f32) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f32, a < b, b, a))); },
            .f64x2_pmin => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f64, b < a, b, a))); },
            .f64x2_pmax => { const b: @Vector(2, f64) = @bitCast(self.popV128()); const a: @Vector(2, f64) = @bitCast(self.popV128()); try self.pushV128(@bitCast(@select(f64, a < b, b, a))); },

            // ---- Float rounding (36.4) ----
            .f32x4_ceil => try self.simdRound(f32, 4, .ceil),
            .f32x4_floor => try self.simdRound(f32, 4, .floor),
            .f32x4_trunc => try self.simdRound(f32, 4, .trunc_fn),
            .f32x4_nearest => try self.simdRound(f32, 4, .nearest),
            .f64x2_ceil => try self.simdRound(f64, 2, .ceil),
            .f64x2_floor => try self.simdRound(f64, 2, .floor),
            .f64x2_trunc => try self.simdRound(f64, 2, .trunc_fn),
            .f64x2_nearest => try self.simdRound(f64, 2, .nearest),

            // ---- Float conversion (36.4) ----
            .i32x4_trunc_sat_f32x4_s => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]i32 = undefined;
                inline for (0..4) |i| r[i] = truncSatClamp(i32, f32, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_trunc_sat_f32x4_u => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]u32 = undefined;
                inline for (0..4) |i| r[i] = truncSatClamp(u32, f32, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_convert_i32x4_s => {
                const a: [4]i32 = @bitCast(self.popV128());
                var r: [4]f32 = undefined;
                inline for (0..4) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_convert_i32x4_u => {
                const a: [4]u32 = @bitCast(self.popV128());
                var r: [4]f32 = undefined;
                inline for (0..4) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_trunc_sat_f64x2_s_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]i32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = truncSatClamp(i32, f64, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_trunc_sat_f64x2_u_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]u32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = truncSatClamp(u32, f64, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_convert_low_i32x4_s => {
                const a: [4]i32 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_convert_low_i32x4_u => {
                const a: [4]u32 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @floatFromInt(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_demote_f64x2_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]f32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = @floatCast(a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_promote_low_f32x4 => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @floatCast(a[i]);
                try self.pushV128(@bitCast(r));
            },

            // ---- Relaxed SIMD (Wasm 3.0) ----
            .i8x16_relaxed_swizzle => {
                const indices: @Vector(16, u8) = @bitCast(self.popV128());
                const vec: [16]u8 = @bitCast(self.popV128());
                var result: [16]u8 = undefined;
                for (0..16) |i| {
                    const idx = indices[i];
                    result[i] = if (idx < 16) vec[idx] else 0;
                }
                try self.pushV128(@bitCast(@as(@Vector(16, u8), result)));
            },
            .i32x4_relaxed_trunc_f32x4_s => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]i32 = undefined;
                inline for (0..4) |i| r[i] = truncSatClamp(i32, f32, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_relaxed_trunc_f32x4_u => {
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]u32 = undefined;
                inline for (0..4) |i| r[i] = truncSatClamp(u32, f32, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_relaxed_trunc_f64x2_s_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]i32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = truncSatClamp(i32, f64, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .i32x4_relaxed_trunc_f64x2_u_zero => {
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [4]u32 = .{ 0, 0, 0, 0 };
                inline for (0..2) |i| r[i] = truncSatClamp(u32, f64, a[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_relaxed_madd => {
                const c: [4]f32 = @bitCast(self.popV128());
                const b: [4]f32 = @bitCast(self.popV128());
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]f32 = undefined;
                inline for (0..4) |i| r[i] = @mulAdd(f32, a[i], b[i], c[i]);
                try self.pushV128(@bitCast(r));
            },
            .f32x4_relaxed_nmadd => {
                const c: [4]f32 = @bitCast(self.popV128());
                const b: [4]f32 = @bitCast(self.popV128());
                const a: [4]f32 = @bitCast(self.popV128());
                var r: [4]f32 = undefined;
                inline for (0..4) |i| r[i] = @mulAdd(f32, -a[i], b[i], c[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_relaxed_madd => {
                const c: [2]f64 = @bitCast(self.popV128());
                const b: [2]f64 = @bitCast(self.popV128());
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @mulAdd(f64, a[i], b[i], c[i]);
                try self.pushV128(@bitCast(r));
            },
            .f64x2_relaxed_nmadd => {
                const c: [2]f64 = @bitCast(self.popV128());
                const b: [2]f64 = @bitCast(self.popV128());
                const a: [2]f64 = @bitCast(self.popV128());
                var r: [2]f64 = undefined;
                inline for (0..2) |i| r[i] = @mulAdd(f64, -a[i], b[i], c[i]);
                try self.pushV128(@bitCast(r));
            },
            .i8x16_relaxed_laneselect, .i16x8_relaxed_laneselect, .i32x4_relaxed_laneselect, .i64x2_relaxed_laneselect => {
                // Bitselect: for each bit, pick from a (if mask bit=1) or b (if mask bit=0)
                const m: u128 = self.popV128();
                const b: u128 = self.popV128();
                const a: u128 = self.popV128();
                try self.pushV128((a & m) | (b & ~m));
            },
            .f32x4_relaxed_min => {
                const b: @Vector(4, f32) = @bitCast(self.popV128());
                const a: @Vector(4, f32) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(@min(a, b)));
            },
            .f32x4_relaxed_max => {
                const b: @Vector(4, f32) = @bitCast(self.popV128());
                const a: @Vector(4, f32) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(@max(a, b)));
            },
            .f64x2_relaxed_min => {
                const b: @Vector(2, f64) = @bitCast(self.popV128());
                const a: @Vector(2, f64) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(@min(a, b)));
            },
            .f64x2_relaxed_max => {
                const b: @Vector(2, f64) = @bitCast(self.popV128());
                const a: @Vector(2, f64) = @bitCast(self.popV128());
                try self.pushV128(@bitCast(@max(a, b)));
            },
            .i16x8_relaxed_q15mulr_s => {
                const b: [8]i16 = @bitCast(self.popV128());
                const a: [8]i16 = @bitCast(self.popV128());
                var r: [8]i16 = undefined;
                inline for (0..8) |i| {
                    const prod: i32 = @as(i32, a[i]) * @as(i32, b[i]);
                    const shifted: i32 = @truncate((prod + 0x4000) >> 15);
                    // Saturate: overflow (INT16_MIN * INT16_MIN) returns INT16_MAX
                    r[i] = if (shifted > 32767) 32767 else @intCast(shifted);
                }
                try self.pushV128(@bitCast(r));
            },
            .i16x8_relaxed_dot_i8x16_i7x16_s => {
                const b_raw: [16]u8 = @bitCast(self.popV128());
                const a_raw: [16]i8 = @bitCast(self.popV128());
                var r: [8]i16 = undefined;
                inline for (0..8) |i| {
                    const a0: i16 = a_raw[i * 2];
                    const a1: i16 = a_raw[i * 2 + 1];
                    // Treat b as signed (implementation-defined for high bit set)
                    const b0: i16 = @as(i16, @as(i8, @bitCast(b_raw[i * 2])));
                    const b1: i16 = @as(i16, @as(i8, @bitCast(b_raw[i * 2 + 1])));
                    r[i] = @truncate(a0 * b0 + a1 * b1);
                }
                try self.pushV128(@bitCast(r));
            },
            .i32x4_relaxed_dot_i8x16_i7x16_add_s => {
                const c: [4]i32 = @bitCast(self.popV128());
                const b_raw: [16]u8 = @bitCast(self.popV128());
                const a_raw: [16]i8 = @bitCast(self.popV128());
                var r: [4]i32 = undefined;
                inline for (0..4) |i| {
                    var sum: i32 = 0;
                    inline for (0..4) |j| {
                        const a_val: i32 = a_raw[i * 4 + j];
                        const b_val: i32 = @as(i32, @as(i8, @bitCast(b_raw[i * 4 + j])));
                        sum += a_val * b_val;
                    }
                    r[i] = sum + c[i];
                }
                try self.pushV128(@bitCast(r));
            },

            _ => return error.Trap,
        }
    }

    // SIMD helper: extending load (e.g. load 8 i8 values, extend to 8 i16 values)
    fn simdExtendLoad(
        self: *Vm,
        comptime NarrowT: type,
        comptime WideT: type,
        reader: *Reader,
        instance: *Instance,
    ) WasmError!void {
        const N = 16 / @sizeOf(WideT); // number of lanes
        const ma = try readMemarg(reader, instance);
        const base = @as(u32, @bitCast(self.popI32()));
        const m = ma.mem;
        // Read N narrow values
        const byte_count = N * @sizeOf(NarrowT);
        const effective = @as(u33, ma.offset) + @as(u33, base);
        if (effective + byte_count > m.data.items.len) return error.OutOfBoundsMemoryAccess;
        var narrow: [N]NarrowT = undefined;
        for (&narrow, 0..) |*n, i| {
            const ptr: *const [@sizeOf(NarrowT)]u8 = @ptrCast(&m.data.items[effective + i * @sizeOf(NarrowT)]);
            n.* = std.mem.readInt(NarrowT, ptr, .little);
        }
        // Extend to wide
        var wide: @Vector(N, WideT) = undefined;
        for (0..N) |i| {
            wide[i] = @as(WideT, narrow[i]);
        }
        try self.pushV128(@bitCast(wide));
    }

    // SIMD helper: load a value from memory into a specific lane of v128
    fn simdLoadLane(
        self: *Vm,
        comptime T: type,
        comptime N: comptime_int,
        reader: *Reader,
        instance: *Instance,
    ) WasmError!void {
        const ma = try readMemarg(reader, instance);
        const lane = try reader.readByte();
        var vec: @Vector(N, T) = @bitCast(self.popV128());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = ma.mem;
        const val = m.read(T, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
        vec[lane] = val;
        try self.pushV128(@bitCast(vec));
    }

    // SIMD helper: store a specific lane of v128 to memory
    fn simdStoreLane(
        self: *Vm,
        comptime T: type,
        comptime N: comptime_int,
        reader: *Reader,
        instance: *Instance,
    ) WasmError!void {
        const ma = try readMemarg(reader, instance);
        const lane = try reader.readByte();
        const vec: @Vector(N, T) = @bitCast(self.popV128());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = ma.mem;
        m.write(T, ma.offset, base, vec[lane]) catch return error.OutOfBoundsMemoryAccess;
    }

    // SIMD helper: lane-wise comparison producing all-ones/all-zeros result
    fn simdCmpOp(self: *Vm, comptime T: type, comptime N: comptime_int, comptime op: enum { eq, ne, lt, gt, le, ge }) WasmError!void {
        const VT = @Vector(N, T);
        const b: VT = @bitCast(self.popV128());
        const a: VT = @bitCast(self.popV128());
        const mask = switch (op) {
            .eq => a == b,
            .ne => a != b,
            .lt => a < b,
            .gt => a > b,
            .le => a <= b,
            .ge => a >= b,
        };
        const ResultT = std.meta.Int(.signed, @bitSizeOf(T));
        try self.pushV128(@bitCast(@select(ResultT, mask, @as(@Vector(N, ResultT), @splat(@as(ResultT, -1))), @as(@Vector(N, ResultT), @splat(@as(ResultT, 0))))));
    }

    // SIMD helper: shift by scalar amount (mod lane_bits)
    fn simdShift(self: *Vm, comptime T: type, comptime N: comptime_int, comptime dir: enum { shl, shr }) WasmError!void {
        const ShiftT = std.math.Log2Int(T);
        const shift: ShiftT = @truncate(@as(u32, @bitCast(self.popI32())));
        const vec: @Vector(N, T) = @bitCast(self.popV128());
        try self.pushV128(@bitCast(switch (dir) {
            .shl => vec << @splat(shift),
            .shr => vec >> @splat(shift),
        }));
    }

    // SIMD helper: narrowing with saturation (two wide vectors → one narrow vector)
    fn simdNarrow(self: *Vm, comptime DstT: type, comptime SrcT: type, comptime SrcN: comptime_int) WasmError!void {
        const DstN = SrcN * 2;
        const b: [SrcN]SrcT = @bitCast(self.popV128());
        const a: [SrcN]SrcT = @bitCast(self.popV128());
        const min_val: SrcT = std.math.minInt(DstT);
        const max_val: SrcT = std.math.maxInt(DstT);
        var result: [DstN]DstT = undefined;
        inline for (0..SrcN) |i| result[i] = @intCast(std.math.clamp(a[i], min_val, max_val));
        inline for (0..SrcN) |i| result[SrcN + i] = @intCast(std.math.clamp(b[i], min_val, max_val));
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: extend half of narrow vector to wider lanes
    fn simdExtend(self: *Vm, comptime DstT: type, comptime SrcT: type, comptime DstN: comptime_int, comptime low: bool) WasmError!void {
        const SrcN = DstN * 2;
        const src: [SrcN]SrcT = @bitCast(self.popV128());
        const offset = if (low) 0 else DstN;
        var result: [DstN]DstT = undefined;
        inline for (0..DstN) |i| result[i] = src[offset + i];
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: extended (widening) multiply of half-width lanes
    fn simdExtMul(self: *Vm, comptime NarrowT: type, comptime WideT: type, comptime N: comptime_int, comptime low: bool) WasmError!void {
        const SrcN = N * 2;
        const b: [SrcN]NarrowT = @bitCast(self.popV128());
        const a: [SrcN]NarrowT = @bitCast(self.popV128());
        const offset = if (low) 0 else N;
        var result: [N]WideT = undefined;
        inline for (0..N) |i| result[i] = @as(WideT, a[offset + i]) * @as(WideT, b[offset + i]);
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: extended pairwise addition (adjacent lane pairs summed into wider lanes)
    fn simdExtAddPairwise(self: *Vm, comptime NarrowT: type, comptime WideT: type) WasmError!void {
        const WideN = 16 / @sizeOf(WideT);
        const a: [WideN * 2]NarrowT = @bitCast(self.popV128());
        var result: [WideN]WideT = undefined;
        inline for (0..WideN) |i| result[i] = @as(WideT, a[i * 2]) + @as(WideT, a[i * 2 + 1]);
        try self.pushV128(@bitCast(result));
    }

    // SIMD helper: all_true — 1 if all lanes non-zero
    fn simdAllTrue(self: *Vm, comptime T: type, comptime N: comptime_int) WasmError!void {
        const a: @Vector(N, T) = @bitCast(self.popV128());
        try self.pushI32(b2i(@reduce(.And, a != @as(@Vector(N, T), @splat(@as(T, 0))))));
    }

    // SIMD helper: bitmask — extract high bit of each lane into i32
    fn simdBitmask(self: *Vm, comptime N: comptime_int, comptime bits: comptime_int) WasmError!void {
        const T = std.meta.Int(.signed, bits);
        const a: [N]T = @bitCast(self.popV128());
        var mask: u32 = 0;
        inline for (0..N) |i| {
            if (a[i] < 0) mask |= @as(u32, 1) << @as(u5, i);
        }
        try self.pushI32(@bitCast(mask));
    }

    // SIMD helper: IEEE 754 min/max with NaN propagation and -0/+0 handling
    fn simdMinMax(self: *Vm, comptime T: type, comptime N: comptime_int, comptime op: enum { min, max }) WasmError!void {
        const b: [N]T = @bitCast(self.popV128());
        const a: [N]T = @bitCast(self.popV128());
        var r: [N]T = undefined;
        inline for (0..N) |i| {
            r[i] = switch (op) {
                .min => wasmMin(T, a[i], b[i]),
                .max => wasmMax(T, a[i], b[i]),
            };
        }
        try self.pushV128(@bitCast(r));
    }

    fn simdRound(self: *Vm, comptime T: type, comptime N: comptime_int, comptime op: enum { ceil, floor, trunc_fn, nearest }) WasmError!void {
        var a: [N]T = @bitCast(self.popV128());
        inline for (0..N) |i| {
            a[i] = switch (op) {
                .ceil => @ceil(a[i]),
                .floor => @floor(a[i]),
                .trunc_fn => @trunc(a[i]),
                .nearest => roundToEven(T, a[i]),
            };
        }
        try self.pushV128(@bitCast(a));
    }

    // ================================================================
    // Call helpers
    // ================================================================

    fn doCall(self: *Vm, instance: *Instance, func_idx: u32, reader: *Reader) WasmError!void {
        const func_ptr = try instance.getFuncPtr(func_idx);
        try self.doCallDirect(instance, func_ptr, reader);
    }

    fn doCallDirect(self: *Vm, instance: *Instance, func_ptr: *store_mod.Function, reader: *Reader) WasmError!void {
        var current_fp = func_ptr;
        var current_inst = instance;

        while (true) {
            if (self.profile) |p| p.call_count += 1;
            switch (current_fp.subtype) {
                .wasm_function => |*wf| {
                    const param_count = current_fp.params.len;
                    const locals_start = self.op_ptr - param_count;

                    // Zero-initialize locals
                    for (0..wf.locals_count) |_| try self.push(0);

                    // Lazy branch table computation
                    if (wf.branch_table == null) {
                        wf.branch_table = computeBranchTable(self.alloc, wf.code) catch null;
                    }
                    const saved_bt = self.current_branch_table;
                    self.current_branch_table = wf.branch_table;

                    try self.pushFrame(.{
                        .locals_start = locals_start,
                        .locals_count = param_count + wf.locals_count,
                        .return_arity = current_fp.results.len,
                        .op_stack_base = locals_start,
                        .label_stack_base = self.label_ptr,
                        .return_reader = reader.*,
                        .instance = current_inst,
                    });

                    var body_reader = Reader.init(wf.code);
                    try self.pushLabel(.{
                        .arity = current_fp.results.len,
                        .op_stack_base = self.op_ptr,
                        .target = .{ .forward = body_reader },
                    });

                    const callee_inst: *Instance = @ptrCast(@alignCast(wf.instance));
                    self.execute(&body_reader, callee_inst) catch |err| {
                        // On any error, unwind callee frame before propagating
                        const frame = self.popFrame();
                        self.label_ptr = frame.label_stack_base;
                        self.op_ptr = frame.op_stack_base;
                        self.current_branch_table = saved_bt;
                        reader.* = frame.return_reader;
                        return err;
                    };

                    // Check for tail call: execute() returned with tail_call_func set
                    if (self.tail_call_func) |next_fp| {
                        // Unwind current frame (like return)
                        const frame = self.popFrame();
                        self.label_ptr = frame.label_stack_base;
                        self.current_branch_table = saved_bt;
                        self.op_ptr = frame.op_stack_base;
                        reader.* = frame.return_reader;

                        // Push tail call args back onto stack
                        for (0..self.tail_call_arg_count) |i| {
                            try self.push(self.tail_call_args[i]);
                        }

                        // Clear tail call state and loop
                        self.tail_call_func = null;
                        current_fp = next_fp;
                        current_inst = callee_inst;
                        continue;
                    }

                    // Normal return: move results to correct position
                    const frame = self.popFrame();
                    self.label_ptr = frame.label_stack_base;
                    self.current_branch_table = saved_bt;
                    const n = frame.return_arity;
                    if (n > 0) {
                        const src_start = self.op_ptr - n;
                        for (0..n) |i| {
                            self.op_stack[frame.op_stack_base + i] = self.op_stack[src_start + i];
                        }
                    }
                    self.op_ptr = frame.op_stack_base + n;
                    reader.* = frame.return_reader;
                    return;
                },
                .host_function => |hf| {
                    self.current_instance = current_inst;
                    hf.func(@ptrCast(self), hf.context) catch return error.Trap;
                    return;
                },
            }
        }
    }

    // ================================================================
    // Branch helpers
    // ================================================================

    fn branchTo(self: *Vm, depth: u32, reader: *Reader) WasmError!void {
        const label = self.peekLabel(depth);
        const arity = label.arity;

        // Save results from top of stack (u128 to preserve v128 values)
        var results: [16]u128 = undefined;
        var i: usize = arity;
        while (i > 0) {
            i -= 1;
            self.op_ptr -= 1;
            results[i] = self.op_stack[self.op_ptr];
        }

        // Unwind operand stack to label base
        self.op_ptr = label.op_stack_base;

        // Push results back
        for (0..arity) |j| try self.pushV128(results[j]);

        // Set reader to target and pop labels
        switch (label.target) {
            .forward => |r| {
                reader.* = r;
                // Pop labels up to and including target
                self.label_ptr -= (depth + 1);
            },
            .loop_start => |r| {
                // For loops: save label, pop intermediates, re-push loop label
                // so the loop can branch again on next iteration
                const loop_label = label;
                self.label_ptr -= (depth + 1);
                try self.pushLabel(.{
                    .arity = loop_label.arity,
                    .op_stack_base = self.op_ptr - loop_label.arity,
                    .target = .{ .loop_start = r },
                });
                reader.* = r;
            },
            .ir_forward, .ir_loop_start => unreachable, // never in old path
        }
    }

    fn branchToIR(self: *Vm, depth: u32, pc: *u32) WasmError!void {
        const label = self.peekLabel(depth);
        const arity = label.arity;

        // u128 to preserve v128 values during branch unwind
        var results: [16]u128 = undefined;
        var i: usize = arity;
        while (i > 0) {
            i -= 1;
            self.op_ptr -= 1;
            results[i] = self.op_stack[self.op_ptr];
        }
        self.op_ptr = label.op_stack_base;
        for (0..arity) |j| try self.pushV128(results[j]);

        switch (label.target) {
            .ir_forward => |target_pc| {
                pc.* = target_pc;
                self.label_ptr -= (depth + 1);
            },
            .ir_loop_start => |target_pc| {
                const loop_label = label;
                self.label_ptr -= (depth + 1);
                try self.pushLabel(.{
                    .arity = loop_label.arity,
                    .op_stack_base = self.op_ptr - loop_label.arity,
                    .target = .{ .ir_loop_start = target_pc },
                });
                pc.* = target_pc;
            },
            .forward, .loop_start => unreachable, // never in IR path
        }
    }

    // ================================================================
    // JIT execution (D105)
    // ================================================================

    fn executeJIT(
        self: *Vm,
        jc: *jit_mod.JitCode,
        reg: *regalloc_mod.RegFunc,
        instance: *Instance,
        func_ptr: *store_mod.Function,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        _ = func_ptr;
        // Set up register file on Vm's reg_stack
        // Reserve +4 slots: +2 for JIT memory cache, +2 for VM/instance pointers
        const base = self.reg_ptr;
        const needed: usize = reg.reg_count + 4;
        if (base + needed > REG_STACK_SIZE) return error.Trap;
        const regs = self.reg_stack[base .. base + needed];
        self.reg_ptr = base + needed;
        defer self.reg_ptr = base;

        // Copy args to registers
        for (args, 0..) |arg, i| regs[i] = arg;
        for (args.len..reg.local_count) |i| regs[i] = 0;

        // Set guard page recovery point before entering JIT code
        if (jc.oob_exit_offset != 0) {
            const buf_start = @intFromPtr(jc.buf.ptr);
            guard_mod.setRecovery(.{
                .oob_exit_pc = buf_start + jc.oob_exit_offset,
                .jit_code_start = buf_start,
                .jit_code_end = buf_start + jc.code_len,
                .active = true,
            });
        }

        // Call JIT-compiled function
        const err_code = jc.entry(regs.ptr, @ptrCast(self), @ptrCast(instance));

        // Clear recovery point after JIT code returns
        guard_mod.clearRecovery();

        if (err_code != 0) {
            return switch (err_code) {
                1 => error.Trap,
                2 => error.StackOverflow,
                3 => error.DivisionByZero,
                4 => error.IntegerOverflow,
                5 => error.Unreachable,
                6 => error.OutOfBoundsMemoryAccess,
                7 => error.WasmException,
                8 => error.InvalidConversion,
                else => error.Trap,
            };
        }

        // Result is in regs[0]
        if (results.len > 0) results[0] = regs[0];
    }

    // ================================================================
    // Register IR execution (D104)
    // ================================================================

    /// Back-edge JIT trigger: count loop iterations, compile on threshold.
    /// Returns JitRestart if compilation succeeds (caller should re-execute via JIT).
    inline fn checkBackEdgeJit(
        count: *u32,
        wf: *store_mod.WasmFunction,
        alloc: Allocator,
        reg: *regalloc_mod.RegFunc,
        pool64: []const u64,
        param_count: u16,
        result_count: u16,
        trace: ?*trace_mod.TraceConfig,
        min_memory_bytes: u32,
        use_guard_pages: bool,
    ) WasmError!void {
        count.* += 1;
        if (count.* == jit_mod.BACK_EDGE_THRESHOLD) {
            wf.jit_code = jit_mod.compileFunction(alloc, reg, pool64, wf.func_idx, param_count, result_count, trace, min_memory_bytes, use_guard_pages);
            if (wf.jit_code != null) {
                if (trace) |tc| trace_mod.traceJitBackEdge(tc, wf.func_idx, @intCast(reg.code.len), @intCast(wf.jit_code.?.buf.len));
                return error.JitRestart;
            }
            wf.jit_failed = true;
            if (trace) |tc| trace_mod.traceJitBail(tc, wf.func_idx, "back-edge compilation failed");
        }
    }

    fn executeRegIR(
        self: *Vm,
        reg: *regalloc_mod.RegFunc,
        pool64: []const u64,
        instance: *Instance,
        func_ptr: *store_mod.Function,
        args: []const u64,
        results: []u64,
    ) WasmError!void {
        // Register file — allocated from Vm's reg_stack (heap, cache-friendly)
        const base = self.reg_ptr;
        const needed: usize = reg.reg_count;
        if (base + needed > REG_STACK_SIZE) return error.Trap;
        const regs = self.reg_stack[base..base + needed];
        self.reg_ptr = base + needed;
        defer self.reg_ptr = base;

        // Copy args to registers (r0..rN = params)
        for (args, 0..) |arg, i| regs[i] = arg;
        // Zero-initialize remaining locals
        for (args.len..reg.local_count) |i| regs[i] = 0;

        const code = reg.code;
        const code_len: u32 = @intCast(code.len);
        const cached_mem: ?*WasmMemory = instance.getMemory(0) catch null;
        var pc: u32 = 0;

        // Back-edge counting for JIT hot loop detection (ARM64 only)
        var back_edge_count: u32 = 0;
        const wf: ?*store_mod.WasmFunction = if (func_ptr.subtype == .wasm_function)
            &func_ptr.subtype.wasm_function
        else
            null;
        const jit_eligible = if (!comptime jit_mod.jitSupported()) false else
            self.profile == null and wf != null and wf.?.jit_code == null and !wf.?.jit_failed;
        const jit_param_count: u16 = @intCast(func_ptr.params.len);
        const jit_result_count: u16 = @intCast(func_ptr.results.len);
        const jit_min_mem_bytes: u32 = jit_mod.getMinMemoryBytes(instance);
        const jit_use_guard_pages: bool = jit_mod.getUseGuardPages(instance);

        while (pc < code_len) {
            const instr = code[pc];
            pc += 1;

            if (self.fuel) |*f| {
                if (f.* == 0) return error.FuelExhausted;
                f.* -= 1;
            }

            if (self.profile) |p| {
                if (instr.op < 256)
                    p.opcode_counts[@as(u8, @truncate(instr.op))] += 1;
                p.total_instrs += 1;
            }

            switch (instr.op) {
                // ---- Register ops ----
                regalloc_mod.OP_MOV => regs[instr.rd] = regs[instr.rs1],

                regalloc_mod.OP_CONST32 => regs[instr.rd] = instr.operand,

                regalloc_mod.OP_CONST64 => regs[instr.rd] = pool64[instr.operand],

                // ---- Control flow ----
                regalloc_mod.OP_BR => {
                    if (jit_eligible and instr.operand < pc)
                        try checkBackEdgeJit(&back_edge_count, wf.?, self.alloc, reg, pool64, jit_param_count, jit_result_count, self.trace, jit_min_mem_bytes, jit_use_guard_pages);
                    pc = instr.operand;
                },

                regalloc_mod.OP_BR_IF => {
                    if (regs[instr.rd] != 0) {
                        if (jit_eligible and instr.operand < pc)
                            try checkBackEdgeJit(&back_edge_count, wf.?, self.alloc, reg, pool64, jit_param_count, jit_result_count, self.trace, jit_min_mem_bytes, jit_use_guard_pages);
                        pc = instr.operand;
                    }
                },

                regalloc_mod.OP_BR_IF_NOT => {
                    if (regs[instr.rd] == 0) {
                        if (jit_eligible and instr.operand < pc)
                            try checkBackEdgeJit(&back_edge_count, wf.?, self.alloc, reg, pool64, jit_param_count, jit_result_count, self.trace, jit_min_mem_bytes, jit_use_guard_pages);
                        pc = instr.operand;
                    }
                },

                regalloc_mod.OP_RETURN => {
                    if (results.len > 0) results[0] = regs[instr.rd];
                    return;
                },

                regalloc_mod.OP_RETURN_VOID => return,

                // ---- Call ----
                regalloc_mod.OP_CALL => {
                    const func_idx = instr.operand;
                    const data = code[pc];
                    pc += 1;
                    // Skip second data word if present (for >4 args)
                    const callee_fn = instance.getFuncPtr(func_idx) catch return error.Trap;
                    const n_args = callee_fn.params.len;

                    // Collect args from register file via data word
                    var call_args: [8]u64 = undefined;
                    if (n_args > 0) call_args[0] = regs[data.rd];
                    if (n_args > 1) call_args[1] = regs[data.rs1];
                    if (n_args > 2) call_args[2] = regs[@as(u8, @truncate(data.operand))];
                    if (n_args > 3) call_args[3] = regs[@as(u8, @truncate(data.operand >> 8))];
                    if (n_args > 4) {
                        const data2 = code[pc];
                        pc += 1;
                        if (n_args > 4) call_args[4] = regs[data2.rd];
                        if (n_args > 5) call_args[5] = regs[data2.rs1];
                        if (n_args > 6) call_args[6] = regs[@as(u8, @truncate(data2.operand))];
                        if (n_args > 7) call_args[7] = regs[@as(u8, @truncate(data2.operand >> 8))];
                    }

                    var call_results: [1]u64 = .{0};
                    const n_results = callee_fn.results.len;
                    try self.callFunction(instance, callee_fn, call_args[0..n_args], call_results[0..n_results]);
                    if (n_results > 0) regs[instr.rd] = call_results[0];
                },

                regalloc_mod.OP_CALL_INDIRECT => {
                    const type_idx = instr.operand & 0xFFFFFF;
                    const table_idx: u8 = @truncate(instr.operand >> 24);
                    const elem_idx: u32 = @truncate(regs[instr.rs1]);
                    const data = code[pc];
                    pc += 1;

                    const t = try instance.getTable(table_idx);
                    const func_addr = try t.lookup(elem_idx);
                    const callee_fn = try instance.store.getFunctionPtr(func_addr);

                    // Type check
                    if (instance.module.getTypeFunc(type_idx)) |expected| {
                        if (!ValType.sliceEql(expected.params, callee_fn.params) or
                            !ValType.sliceEql(expected.results, callee_fn.results))
                            return error.MismatchedSignatures;
                    }

                    const n_args = callee_fn.params.len;
                    var call_args: [8]u64 = undefined;
                    if (n_args > 0) call_args[0] = regs[data.rd];
                    if (n_args > 1) call_args[1] = regs[data.rs1];
                    if (n_args > 2) call_args[2] = regs[@as(u8, @truncate(data.operand))];
                    if (n_args > 3) call_args[3] = regs[@as(u8, @truncate(data.operand >> 8))];
                    if (n_args > 4) {
                        const data2 = code[pc];
                        pc += 1;
                        if (n_args > 4) call_args[4] = regs[data2.rd];
                        if (n_args > 5) call_args[5] = regs[data2.rs1];
                        if (n_args > 6) call_args[6] = regs[@as(u8, @truncate(data2.operand))];
                        if (n_args > 7) call_args[7] = regs[@as(u8, @truncate(data2.operand >> 8))];
                    }

                    var call_results: [1]u64 = .{0};
                    const n_results = callee_fn.results.len;
                    try self.callFunction(instance, callee_fn, call_args[0..n_args], call_results[0..n_results]);
                    if (n_results > 0) regs[instr.rd] = call_results[0];
                },

                regalloc_mod.OP_NOP => {}, // data word, skip

                // ---- i32 arithmetic ----
                0x6A => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) +% @as(u32, @truncate(regs[instr.rs2()])),
                0x6B => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) -% @as(u32, @truncate(regs[instr.rs2()])),
                0x6C => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) *% @as(u32, @truncate(regs[instr.rs2()])),
                0x6D => { // i32.div_s
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()])));
                    if (b == 0) return error.DivisionByZero;
                    if (a == std.math.minInt(i32) and b == -1) return error.IntegerOverflow;
                    regs[instr.rd] = @as(u32, @bitCast(@divTrunc(a, b)));
                },
                0x6E => { // i32.div_u
                    const b: u32 = @truncate(regs[instr.rs2()]);
                    if (b == 0) return error.DivisionByZero;
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) / b;
                },
                0x6F => { // i32.rem_s
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()])));
                    if (b == 0) return error.DivisionByZero;
                    if (a == std.math.minInt(i32) and b == -1)
                        regs[instr.rd] = 0
                    else
                        regs[instr.rd] = @as(u32, @bitCast(@rem(a, b)));
                },
                0x70 => { // i32.rem_u
                    const b: u32 = @truncate(regs[instr.rs2()]);
                    if (b == 0) return error.DivisionByZero;
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) % b;
                },
                0x71 => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) & @as(u32, @truncate(regs[instr.rs2()])),
                0x72 => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) | @as(u32, @truncate(regs[instr.rs2()])),
                0x73 => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) ^ @as(u32, @truncate(regs[instr.rs2()])),
                0x74 => { // i32.shl
                    const shift: u5 = @truncate(regs[instr.rs2()]);
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) << shift;
                },
                0x75 => { // i32.shr_s
                    const shift: u5 = @truncate(regs[instr.rs2()]);
                    const val: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    regs[instr.rd] = @as(u32, @bitCast(val >> shift));
                },

                // ---- i32 comparison ----
                0x45 => regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) == 0), // i32.eqz
                0x46 => regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) == @as(u32, @truncate(regs[instr.rs2()]))),
                0x47 => regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) != @as(u32, @truncate(regs[instr.rs2()]))),
                0x48 => { // i32.lt_s
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()])));
                    regs[instr.rd] = @intFromBool(a < b);
                },
                0x49 => regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) < @as(u32, @truncate(regs[instr.rs2()]))), // lt_u
                0x4A => { // i32.gt_s
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()])));
                    regs[instr.rd] = @intFromBool(a > b);
                },
                0x4B => regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) > @as(u32, @truncate(regs[instr.rs2()]))), // gt_u
                0x4C => { // i32.le_s
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()])));
                    regs[instr.rd] = @intFromBool(a <= b);
                },
                0x4D => regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) <= @as(u32, @truncate(regs[instr.rs2()]))), // le_u
                0x4E => { // i32.ge_s
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()])));
                    regs[instr.rd] = @intFromBool(a >= b);
                },
                0x4F => regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) >= @as(u32, @truncate(regs[instr.rs2()]))), // ge_u

                // ---- i32 unary ----
                0x67 => regs[instr.rd] = @clz(@as(u32, @truncate(regs[instr.rs1]))), // i32.clz
                0x68 => regs[instr.rd] = @ctz(@as(u32, @truncate(regs[instr.rs1]))), // i32.ctz
                0x69 => regs[instr.rd] = @popCount(@as(u32, @truncate(regs[instr.rs1]))), // i32.popcnt
                0x76 => { // i32.shr_u
                    const shift: u5 = @truncate(regs[instr.rs2()]);
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) >> shift;
                },
                0x77 => { // i32.rotl
                    regs[instr.rd] = std.math.rotl(u32, @truncate(regs[instr.rs1]), @as(u32, @truncate(regs[instr.rs2()])));
                },
                0x78 => { // i32.rotr
                    regs[instr.rd] = std.math.rotr(u32, @truncate(regs[instr.rs1]), @as(u32, @truncate(regs[instr.rs2()])));
                },

                // ---- i64 arithmetic ----
                0x7C => regs[instr.rd] = regs[instr.rs1] +% regs[instr.rs2()], // i64.add
                0x7D => regs[instr.rd] = regs[instr.rs1] -% regs[instr.rs2()], // i64.sub
                0x7E => regs[instr.rd] = regs[instr.rs1] *% regs[instr.rs2()], // i64.mul
                0x7F => { // i64.div_s
                    const a: i64 = @bitCast(regs[instr.rs1]);
                    const b: i64 = @bitCast(regs[instr.rs2()]);
                    if (b == 0) return error.DivisionByZero;
                    if (a == std.math.minInt(i64) and b == -1) return error.IntegerOverflow;
                    regs[instr.rd] = @bitCast(@divTrunc(a, b));
                },
                0x80 => { // i64.div_u
                    const b = regs[instr.rs2()];
                    if (b == 0) return error.DivisionByZero;
                    regs[instr.rd] = regs[instr.rs1] / b;
                },
                0x81 => { // i64.rem_s
                    const a: i64 = @bitCast(regs[instr.rs1]);
                    const b: i64 = @bitCast(regs[instr.rs2()]);
                    if (b == 0) return error.DivisionByZero;
                    if (a == std.math.minInt(i64) and b == -1) regs[instr.rd] = 0 else regs[instr.rd] = @bitCast(@rem(a, b));
                },
                0x82 => { // i64.rem_u
                    const b = regs[instr.rs2()];
                    if (b == 0) return error.DivisionByZero;
                    regs[instr.rd] = regs[instr.rs1] % b;
                },
                0x83 => regs[instr.rd] = regs[instr.rs1] & regs[instr.rs2()], // i64.and
                0x84 => regs[instr.rd] = regs[instr.rs1] | regs[instr.rs2()], // i64.or
                0x85 => regs[instr.rd] = regs[instr.rs1] ^ regs[instr.rs2()], // i64.xor
                0x86 => { // i64.shl
                    const shift: u6 = @truncate(regs[instr.rs2()]);
                    regs[instr.rd] = regs[instr.rs1] << shift;
                },
                0x87 => { // i64.shr_s
                    const shift: u6 = @truncate(regs[instr.rs2()]);
                    const val: i64 = @bitCast(regs[instr.rs1]);
                    regs[instr.rd] = @bitCast(val >> shift);
                },
                0x88 => { // i64.shr_u
                    const shift: u6 = @truncate(regs[instr.rs2()]);
                    regs[instr.rd] = regs[instr.rs1] >> shift;
                },
                0x89 => regs[instr.rd] = std.math.rotl(u64, regs[instr.rs1], regs[instr.rs2()]), // i64.rotl
                0x8A => regs[instr.rd] = std.math.rotr(u64, regs[instr.rs1], regs[instr.rs2()]), // i64.rotr

                // ---- i64 comparison ----
                0x50 => regs[instr.rd] = @intFromBool(regs[instr.rs1] == 0), // i64.eqz
                0x51 => regs[instr.rd] = @intFromBool(regs[instr.rs1] == regs[instr.rs2()]), // i64.eq
                0x52 => regs[instr.rd] = @intFromBool(regs[instr.rs1] != regs[instr.rs2()]), // i64.ne
                0x53 => { const a: i64 = @bitCast(regs[instr.rs1]); const b: i64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a < b); }, // i64.lt_s
                0x54 => regs[instr.rd] = @intFromBool(regs[instr.rs1] < regs[instr.rs2()]), // i64.lt_u
                0x55 => { const a: i64 = @bitCast(regs[instr.rs1]); const b: i64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a > b); }, // i64.gt_s
                0x56 => regs[instr.rd] = @intFromBool(regs[instr.rs1] > regs[instr.rs2()]), // i64.gt_u
                0x57 => { const a: i64 = @bitCast(regs[instr.rs1]); const b: i64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a <= b); }, // i64.le_s
                0x58 => regs[instr.rd] = @intFromBool(regs[instr.rs1] <= regs[instr.rs2()]), // i64.le_u
                0x59 => { const a: i64 = @bitCast(regs[instr.rs1]); const b: i64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a >= b); }, // i64.ge_s
                0x5A => regs[instr.rd] = @intFromBool(regs[instr.rs1] >= regs[instr.rs2()]), // i64.ge_u

                // ---- i64 unary ----
                0x79 => regs[instr.rd] = @clz(regs[instr.rs1]), // i64.clz
                0x7A => regs[instr.rd] = @ctz(regs[instr.rs1]), // i64.ctz
                0x7B => regs[instr.rd] = @popCount(regs[instr.rs1]), // i64.popcnt

                // ---- f64 arithmetic ----
                0xA0 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @bitCast(a + b); }, // f64.add
                0xA1 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @bitCast(a - b); }, // f64.sub
                0xA2 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @bitCast(a * b); }, // f64.mul
                0xA3 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @bitCast(a / b); }, // f64.div
                0xA4 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @bitCast(wasmMin(f64, a, b)); }, // f64.min
                0xA5 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @bitCast(wasmMax(f64, a, b)); }, // f64.max
                0xA6 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @bitCast(math.copysign(a, b)); }, // f64.copysign

                // ---- f64 comparison ----
                0x61 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a == b); }, // f64.eq
                0x62 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a != b); }, // f64.ne
                0x63 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a < b); }, // f64.lt
                0x64 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a > b); }, // f64.gt
                0x65 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a <= b); }, // f64.le
                0x66 => { const a: f64 = @bitCast(regs[instr.rs1]); const b: f64 = @bitCast(regs[instr.rs2()]); regs[instr.rd] = @intFromBool(a >= b); }, // f64.ge

                // ---- f64 unary ----
                0x99 => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(@abs(v)); }, // f64.abs
                0x9A => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(-v); }, // f64.neg
                0x9B => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(@ceil(v)); }, // f64.ceil
                0x9C => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(@floor(v)); }, // f64.floor
                0x9D => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(@trunc(v)); }, // f64.trunc
                0x9E => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(wasmNearest(f64, v)); }, // f64.nearest
                0x9F => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(@sqrt(v)); }, // f64.sqrt

                // ---- f32 arithmetic ----
                0x92 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @as(u32, @bitCast(a + b)); },
                0x93 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @as(u32, @bitCast(a - b)); },
                0x94 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @as(u32, @bitCast(a * b)); },
                0x95 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @as(u32, @bitCast(a / b)); },
                0x96 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @as(u32, @bitCast(wasmMin(f32, a, b))); },
                0x97 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @as(u32, @bitCast(wasmMax(f32, a, b))); },
                0x98 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @as(u32, @bitCast(math.copysign(a, b))); },

                // ---- f32 comparison ----
                0x5B => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @intFromBool(a == b); },
                0x5C => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @intFromBool(a != b); },
                0x5D => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @intFromBool(a < b); },
                0x5E => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @intFromBool(a > b); },
                0x5F => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @intFromBool(a <= b); },
                0x60 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); const b: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs2()]))); regs[instr.rd] = @intFromBool(a >= b); },

                // ---- f32 unary ----
                0x8B => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@abs(v))); },
                0x8C => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(-v)); },
                0x8D => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@ceil(v))); },
                0x8E => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@floor(v))); },
                0x8F => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@trunc(v))); },
                0x90 => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(wasmNearest(f32, v))); },
                0x91 => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@sqrt(v))); },

                // ---- Conversions ----
                0xA7 => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])), // i32.wrap_i64
                0xA8 => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const i: i32 = @intFromFloat(v); regs[instr.rd] = @as(u32, @bitCast(i)); }, // i32.trunc_f32_s
                0xA9 => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const u: u32 = @intFromFloat(v); regs[instr.rd] = u; }, // i32.trunc_f32_u
                0xAA => { const v: f64 = @bitCast(regs[instr.rs1]); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const i: i32 = @intFromFloat(v); regs[instr.rd] = @as(u32, @bitCast(i)); }, // i32.trunc_f64_s
                0xAB => { const v: f64 = @bitCast(regs[instr.rs1]); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const u: u32 = @intFromFloat(v); regs[instr.rd] = u; }, // i32.trunc_f64_u
                0xAC => regs[instr.rd] = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(regs[instr.rs1])))))), // i64.extend_i32_s
                0xAD => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])), // i64.extend_i32_u
                0xAE => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const i: i64 = @intFromFloat(v); regs[instr.rd] = @bitCast(i); }, // i64.trunc_f32_s
                0xAF => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const u: u64 = @intFromFloat(v); regs[instr.rd] = u; }, // i64.trunc_f32_u
                0xB0 => { const v: f64 = @bitCast(regs[instr.rs1]); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const i: i64 = @intFromFloat(v); regs[instr.rd] = @bitCast(i); }, // i64.trunc_f64_s
                0xB1 => { const v: f64 = @bitCast(regs[instr.rs1]); if (math.isNan(v) or math.isInf(v)) return error.InvalidConversion; const u: u64 = @intFromFloat(v); regs[instr.rd] = u; }, // i64.trunc_f64_u
                0xB2 => { const v: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@as(f32, @floatFromInt(v)))); }, // f32.convert_i32_s
                0xB3 => { const v: u32 = @truncate(regs[instr.rs1]); regs[instr.rd] = @as(u32, @bitCast(@as(f32, @floatFromInt(v)))); }, // f32.convert_i32_u
                0xB4 => { const v: i64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @as(u32, @bitCast(@as(f32, @floatFromInt(v)))); }, // f32.convert_i64_s
                0xB5 => { const v: u64 = regs[instr.rs1]; regs[instr.rd] = @as(u32, @bitCast(@as(f32, @floatFromInt(v)))); }, // f32.convert_i64_u
                0xB6 => { const v: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @as(u32, @bitCast(@as(f32, @floatCast(v)))); }, // f32.demote_f64
                0xB7 => { const v: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @bitCast(@as(f64, @floatFromInt(v))); }, // f64.convert_i32_s
                0xB8 => { const v: u32 = @truncate(regs[instr.rs1]); regs[instr.rd] = @bitCast(@as(f64, @floatFromInt(v))); }, // f64.convert_i32_u
                0xB9 => { const v: i64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(@as(f64, @floatFromInt(v))); }, // f64.convert_i64_s
                0xBA => { const v: u64 = regs[instr.rs1]; regs[instr.rd] = @bitCast(@as(f64, @floatFromInt(v))); }, // f64.convert_i64_u
                0xBB => { const v: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @bitCast(@as(f64, @floatCast(v))); }, // f64.promote_f32
                0xBC => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])), // i32.reinterpret_f32
                0xBD => regs[instr.rd] = regs[instr.rs1], // i64.reinterpret_f64
                0xBE => regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])), // f32.reinterpret_i32
                0xBF => regs[instr.rd] = regs[instr.rs1], // f64.reinterpret_i64

                // ---- Sign extension (Wasm 2.0) ----
                0xC0 => { const v: i8 = @bitCast(@as(u8, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@as(i32, v))); }, // i32.extend8_s
                0xC1 => { const v: i16 = @bitCast(@as(u16, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(@as(i32, v))); }, // i32.extend16_s
                0xC2 => { const v: i8 = @bitCast(@as(u8, @truncate(regs[instr.rs1]))); regs[instr.rd] = @bitCast(@as(i64, v)); }, // i64.extend8_s
                0xC3 => { const v: i16 = @bitCast(@as(u16, @truncate(regs[instr.rs1]))); regs[instr.rd] = @bitCast(@as(i64, v)); }, // i64.extend16_s
                0xC4 => { const v: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @bitCast(@as(i64, v)); }, // i64.extend32_s

                // ---- Memory load ----
                // rd = dest, rs1 = base addr reg, operand = offset
                0x28 => { // i32.load
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    regs[instr.rd] = m.read(u32, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                },
                0x29 => { // i64.load
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    regs[instr.rd] = m.read(u64, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                },
                0x2A => { // f32.load
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val = m.read(f32, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @as(u32, @bitCast(val));
                },
                0x2B => { // f64.load
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val = m.read(f64, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @bitCast(val);
                },
                0x2C => { // i32.load8_s
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val = m.read(i8, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @as(u32, @bitCast(@as(i32, val)));
                },
                0x2D => { // i32.load8_u
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    regs[instr.rd] = m.read(u8, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                },
                0x2E => { // i32.load16_s
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val = m.read(i16, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @as(u32, @bitCast(@as(i32, val)));
                },
                0x2F => { // i32.load16_u
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    regs[instr.rd] = m.read(u16, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                },
                0x30 => { // i64.load8_s
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val = m.read(i8, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @bitCast(@as(i64, val));
                },
                0x31 => { // i64.load8_u
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    regs[instr.rd] = m.read(u8, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                },
                0x32 => { // i64.load16_s
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val = m.read(i16, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @bitCast(@as(i64, val));
                },
                0x33 => { // i64.load16_u
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    regs[instr.rd] = m.read(u16, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                },
                0x34 => { // i64.load32_s
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val = m.read(i32, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @bitCast(@as(i64, val));
                },
                0x35 => { // i64.load32_u
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    regs[instr.rd] = m.read(u32, instr.operand, addr) catch return error.OutOfBoundsMemoryAccess;
                },

                // ---- Memory store ----
                // rd = value reg, rs1 = base addr reg, operand = offset
                0x36 => { // i32.store
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: u32 = @truncate(regs[instr.rd]);
                    m.write(u32, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },
                0x37 => { // i64.store
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    m.write(u64, instr.operand, addr, regs[instr.rd]) catch return error.OutOfBoundsMemoryAccess;
                },
                0x38 => { // f32.store
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: f32 = @bitCast(@as(u32, @truncate(regs[instr.rd])));
                    m.write(f32, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },
                0x39 => { // f64.store
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: f64 = @bitCast(regs[instr.rd]);
                    m.write(f64, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },
                0x3A => { // i32.store8
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: u8 = @truncate(regs[instr.rd]);
                    m.write(u8, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },
                0x3B => { // i32.store16
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: u16 = @truncate(regs[instr.rd]);
                    m.write(u16, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },
                0x3C => { // i64.store8
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: u8 = @truncate(regs[instr.rd]);
                    m.write(u8, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },
                0x3D => { // i64.store16
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: u16 = @truncate(regs[instr.rd]);
                    m.write(u16, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },
                0x3E => { // i64.store32
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const addr: u32 = @truncate(regs[instr.rs1]);
                    const val: u32 = @truncate(regs[instr.rd]);
                    m.write(u32, instr.operand, addr, val) catch return error.OutOfBoundsMemoryAccess;
                },

                // ---- Memory size/grow ----
                0x3F => { // memory.size
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    regs[instr.rd] = @intCast(m.size());
                },
                0x40 => { // memory.grow
                    const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
                    const pages: u32 = @truncate(regs[instr.rs1]);
                    if (self.max_memory_bytes) |ceiling| {
                        const new_bytes = m.data.items.len + @as(u64, pages) * m.page_size;
                        if (new_bytes > ceiling) {
                            regs[instr.rd] = @bitCast(@as(i64, -1));
                            continue;
                        }
                    }
                    const prev = m.grow(pages) catch {
                        regs[instr.rd] = @bitCast(@as(i64, -1));
                        continue;
                    };
                    regs[instr.rd] = @intCast(prev);
                },

                // ---- Select ----
                0x1B => { // select: rd = cond ? val1 : val2
                    const val2: u8 = @truncate(instr.operand);
                    const cond: u8 = @truncate(instr.operand >> 8);
                    regs[instr.rd] = if (regs[cond] != 0) regs[instr.rs1] else regs[val2];
                },

                // ---- Drop ----
                0x1A => {}, // no-op in register IR

                // ---- Global get/set ----
                0x23 => { // global.get
                    const g = try instance.getGlobal(instr.operand);
                    regs[instr.rd] = @truncate(g.value);
                },
                0x24 => { // global.set
                    const g = try instance.getGlobal(instr.operand);
                    g.value = regs[instr.rd];
                },

                // ---- Immediate-operand fused instructions ----
                regalloc_mod.OP_ADDI32 => {
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) +% instr.operand;
                },
                regalloc_mod.OP_SUBI32 => {
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) -% instr.operand;
                },
                regalloc_mod.OP_MULI32 => {
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) *% instr.operand;
                },
                regalloc_mod.OP_ANDI32 => {
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) & instr.operand;
                },
                regalloc_mod.OP_ORI32 => {
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) | instr.operand;
                },
                regalloc_mod.OP_XORI32 => {
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) ^ instr.operand;
                },
                regalloc_mod.OP_SHLI32 => {
                    const shift: u5 = @truncate(instr.operand);
                    regs[instr.rd] = @as(u32, @truncate(regs[instr.rs1])) << shift;
                },
                regalloc_mod.OP_EQ_I32 => {
                    regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) == instr.operand);
                },
                regalloc_mod.OP_NE_I32 => {
                    regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) != instr.operand);
                },
                regalloc_mod.OP_LT_S_I32 => {
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(instr.operand);
                    regs[instr.rd] = @intFromBool(a < b);
                },
                regalloc_mod.OP_LT_U_I32 => {
                    regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) < instr.operand);
                },
                regalloc_mod.OP_GT_S_I32 => {
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(instr.operand);
                    regs[instr.rd] = @intFromBool(a > b);
                },
                regalloc_mod.OP_LE_S_I32 => {
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(instr.operand);
                    regs[instr.rd] = @intFromBool(a <= b);
                },
                regalloc_mod.OP_GE_S_I32 => {
                    const a: i32 = @bitCast(@as(u32, @truncate(regs[instr.rs1])));
                    const b: i32 = @bitCast(instr.operand);
                    regs[instr.rd] = @intFromBool(a >= b);
                },
                regalloc_mod.OP_GE_U_I32 => {
                    regs[instr.rd] = @intFromBool(@as(u32, @truncate(regs[instr.rs1])) >= instr.operand);
                },

                // ---- br_table ----
                regalloc_mod.OP_BR_TABLE => {
                    const count = instr.operand;
                    const idx = @as(u32, @truncate(regs[instr.rd]));
                    const target_entry = if (idx < count) idx else count; // default is last
                    const target_pc = code[pc + target_entry].operand;
                    if (jit_eligible and target_pc < pc)
                        try checkBackEdgeJit(&back_edge_count, wf.?, self.alloc, reg, pool64, jit_param_count, jit_result_count, self.trace, jit_min_mem_bytes, jit_use_guard_pages);
                    pc = target_pc;
                    continue;
                },

                // ---- Bulk memory operations ----
                regalloc_mod.OP_MEMORY_FILL => {
                    const dst = @as(u32, @truncate(regs[instr.rd]));
                    const val = @as(u8, @truncate(regs[instr.rs1]));
                    const n = @as(u32, @truncate(regs[instr.rs2()]));
                    const m = try instance.getMemory(0);
                    try m.fill(dst, n, val);
                },
                regalloc_mod.OP_MEMORY_COPY => {
                    const dst = @as(u32, @truncate(regs[instr.rd]));
                    const src = @as(u32, @truncate(regs[instr.rs1]));
                    const n = @as(u32, @truncate(regs[instr.rs2()]));
                    const m = try instance.getMemory(0);
                    try m.copyWithin(dst, src, n);
                },

                // ---- Truncation saturating (misc prefix) ----
                predecode_mod.MISC_BASE | 0x00 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @as(u32, @bitCast(truncSatClamp(i32, f32, a))); },
                predecode_mod.MISC_BASE | 0x01 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = truncSatClamp(u32, f32, a); },
                predecode_mod.MISC_BASE | 0x02 => { const a: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @as(u32, @bitCast(truncSatClamp(i32, f64, a))); },
                predecode_mod.MISC_BASE | 0x03 => { const a: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = truncSatClamp(u32, f64, a); },
                predecode_mod.MISC_BASE | 0x04 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = @bitCast(truncSatClamp(i64, f32, a)); },
                predecode_mod.MISC_BASE | 0x05 => { const a: f32 = @bitCast(@as(u32, @truncate(regs[instr.rs1]))); regs[instr.rd] = truncSatClamp(u64, f32, a); },
                predecode_mod.MISC_BASE | 0x06 => { const a: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = @bitCast(truncSatClamp(i64, f64, a)); },
                predecode_mod.MISC_BASE | 0x07 => { const a: f64 = @bitCast(regs[instr.rs1]); regs[instr.rd] = truncSatClamp(u64, f64, a); },

                // ---- Unreachable ----
                0x00 => return error.Unreachable,

                // ---- Unsupported opcode in register IR — shouldn't happen ----
                else => return error.Trap,
            }
        }

        // Fell off the end without return — void return
    }

    // ================================================================
    // Predecoded IR execution
    // ================================================================

    fn executeIR(self: *Vm, code: []const PreInstr, pool64: []const u64, instance: *Instance) WasmError!void {
        var pc: u32 = 0;
        const code_len: u32 = @intCast(code.len);
        // Cache memory pointer to avoid triple-indirection per load/store
        const cached_mem: ?*WasmMemory = instance.getMemory(0) catch null;
        while (pc < code_len) {
            const instr = code[pc];
            pc += 1;

            if (self.fuel) |*f| {
                if (f.* == 0) return error.FuelExhausted;
                f.* -= 1;
            }

            if (self.profile) |p| {
                if (instr.opcode < 256)
                    p.opcode_counts[instr.opcode] += 1
                else if (instr.opcode >= 0xFC00 and instr.opcode < 0xFC00 + 32)
                    p.misc_counts[instr.opcode - 0xFC00] += 1;
                p.total_instrs += 1;
            }

            switch (instr.opcode) {
                // ---- Control flow ----
                0x00 => return error.Unreachable, // unreachable
                0x01 => {}, // nop
                0x02 => { // block
                    const arity = resolveArityIR(instr.extra, instance);
                    try self.pushLabel(.{
                        .arity = arity,
                        .op_stack_base = self.op_ptr,
                        .target = .{ .ir_forward = instr.operand },
                    });
                },
                0x03 => { // loop
                    // Loop branch arity = params count (values passed back on br)
                    const param_arity = resolveParamArityIR(instr.extra, instance);
                    try self.pushLabel(.{
                        .arity = param_arity,
                        .op_stack_base = self.op_ptr - param_arity,
                        .target = .{ .ir_loop_start = instr.operand },
                    });
                },
                0x04 => { // if
                    const cond = self.popI32();
                    const data = code[pc];
                    pc += 1;
                    const has_else = data.extra != 0;
                    const end_pc = data.operand;
                    const arity = resolveArityIR(instr.extra, instance);

                    if (cond != 0) {
                        try self.pushLabel(.{
                            .arity = arity,
                            .op_stack_base = self.op_ptr,
                            .target = .{ .ir_forward = end_pc },
                        });
                    } else if (has_else) {
                        pc = instr.operand;
                        try self.pushLabel(.{
                            .arity = arity,
                            .op_stack_base = self.op_ptr,
                            .target = .{ .ir_forward = end_pc },
                        });
                    } else {
                        pc = instr.operand;
                    }
                },
                0x05 => { // else
                    pc = instr.operand;
                    _ = self.popLabel();
                },
                0x0B => { // end
                    if (self.label_ptr > 0 and (self.frame_ptr == 0 or
                        self.label_ptr > self.frame_stack[self.frame_ptr - 1].label_stack_base))
                    {
                        _ = self.popLabel();
                    } else {
                        return;
                    }
                },
                0x0C => try self.branchToIR(instr.operand, &pc), // br
                0x0D => { // br_if
                    const cond = self.popI32();
                    if (cond != 0) try self.branchToIR(instr.operand, &pc);
                },
                0x0E => { // br_table
                    const count = instr.operand;
                    const idx = @as(u32, @bitCast(self.popI32()));
                    var target_depth: u32 = code[pc + count].operand; // default
                    if (idx < count) target_depth = code[pc + idx].operand;
                    pc += count + 1; // skip entries
                    try self.branchToIR(target_depth, &pc);
                },
                0x0F => return, // return
                0x10 => try self.doCallIR(instance, instr.operand), // call
                0x11 => { // call_indirect
                    const type_idx = instr.operand;
                    const table_idx = instr.extra;
                    const t = try instance.getTable(table_idx);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    const func_addr = try t.lookup(elem_idx);
                    const func_ptr = try instance.store.getFunctionPtr(func_addr);
                    if (instance.module.getTypeFunc(type_idx)) |expected| {
                        if (!ValType.sliceEql(expected.params, func_ptr.params) or
                            !ValType.sliceEql(expected.results, func_ptr.results))
                            return error.MismatchedSignatures;
                    }
                    try self.doCallDirectIR(instance, func_ptr);
                },
                0x12 => { // return_call
                    const func_ptr = try instance.getFuncPtr(instr.operand);
                    const n_args = func_ptr.params.len;
                    var i: usize = n_args;
                    while (i > 0) {
                        i -= 1;
                        self.tail_call_args[i] = self.pop();
                    }
                    self.tail_call_arg_count = n_args;
                    self.tail_call_func = func_ptr;
                    return;
                },
                0x13 => { // return_call_indirect
                    const type_idx = instr.operand;
                    const table_idx = instr.extra;
                    const t = try instance.getTable(table_idx);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    const func_addr = try t.lookup(elem_idx);
                    const func_ptr = try instance.store.getFunctionPtr(func_addr);
                    if (instance.module.getTypeFunc(type_idx)) |expected| {
                        if (!ValType.sliceEql(expected.params, func_ptr.params) or
                            !ValType.sliceEql(expected.results, func_ptr.results))
                            return error.MismatchedSignatures;
                    }
                    const n_args = func_ptr.params.len;
                    var i: usize = n_args;
                    while (i > 0) {
                        i -= 1;
                        self.tail_call_args[i] = self.pop();
                    }
                    self.tail_call_arg_count = n_args;
                    self.tail_call_func = func_ptr;
                    return;
                },

                // ---- Parametric ----
                0x1A => _ = self.pop(), // drop
                0x1B => { // select (u128 to preserve v128)
                    const cond = self.popI32();
                    self.op_ptr -= 1;
                    const val2 = self.op_stack[self.op_ptr];
                    self.op_ptr -= 1;
                    const val1 = self.op_stack[self.op_ptr];
                    self.op_stack[self.op_ptr] = if (cond != 0) val1 else val2;
                    self.op_ptr += 1;
                },

                // ---- Variable access ----
                0x20 => { // local_get
                    const frame = self.peekFrame();
                    try self.pushV128(self.op_stack[frame.locals_start + instr.operand]);
                },
                0x21 => { // local_set
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + instr.operand] = self.popV128();
                },
                0x22 => { // local_tee
                    const frame = self.peekFrame();
                    self.op_stack[frame.locals_start + instr.operand] = self.op_stack[self.op_ptr - 1];
                },
                0x23 => { // global_get
                    const g = try instance.getGlobal(instr.operand);
                    try self.pushV128(g.value);
                },
                0x24 => { // global_set
                    const g = try instance.getGlobal(instr.operand);
                    g.value = self.popV128();
                },

                // ---- Table access ----
                0x25 => { // table_get
                    const t = try instance.getTable(instr.operand);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    const val = t.get(elem_idx) catch return error.OutOfBoundsMemoryAccess;
                    try self.push(if (val) |v| @as(u64, @intCast(v)) + 1 else 0);
                },
                0x26 => { // table_set
                    const val = self.pop();
                    const t = try instance.getTable(instr.operand);
                    const elem_idx: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                    const ref_val: ?usize = if (val == 0) null else @intCast(val - 1);
                    t.set(elem_idx, ref_val) catch return error.OutOfBoundsMemoryAccess;
                },

                // ---- Memory load (offset in operand, memidx in extra) ----
                0x28 => try self.memLoadCached(i32, u32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x29 => try self.memLoadCached(i64, u64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x2A => try self.memLoadFloatCached(f32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x2B => try self.memLoadFloatCached(f64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x2C => try self.memLoadCached(i8, i32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x2D => try self.memLoadCached(u8, u32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x2E => try self.memLoadCached(i16, i32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x2F => try self.memLoadCached(u16, u32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x30 => try self.memLoadCached(i8, i64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x31 => try self.memLoadCached(u8, u64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x32 => try self.memLoadCached(i16, i64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x33 => try self.memLoadCached(u16, u64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x34 => try self.memLoadCached(i32, i64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x35 => try self.memLoadCached(u32, u64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),

                // ---- Memory store (memidx in extra) ----
                0x36 => try self.memStoreCached(u32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x37 => try self.memStoreCached(u64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x38 => try self.memStoreFloatCached(f32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x39 => try self.memStoreFloatCached(f64, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x3A => try self.memStoreCached(u8, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x3B => try self.memStoreCached(u16, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x3C => try self.memStoreTruncCached(u8, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x3D => try self.memStoreTruncCached(u16, instr.operand, resolveMem(cached_mem, instr.extra, instance)),
                0x3E => try self.memStoreTruncCached(u32, instr.operand, resolveMem(cached_mem, instr.extra, instance)),

                // ---- Memory misc (memidx in extra) ----
                0x3F => { // memory_size
                    const m = resolveMem(cached_mem, instr.extra, instance) orelse return error.OutOfBoundsMemoryAccess;
                    try self.pushI32(@bitCast(m.size()));
                },
                0x40 => { // memory_grow
                    const pages = @as(u32, @bitCast(self.popI32()));
                    const m = resolveMem(cached_mem, instr.extra, instance) orelse return error.OutOfBoundsMemoryAccess;
                    if (self.max_memory_bytes) |ceiling| {
                        const new_bytes = m.data.items.len + @as(u64, pages) * m.page_size;
                        if (new_bytes > ceiling) {
                            try self.pushI32(-1);
                            continue;
                        }
                    }
                    const old = m.grow(pages) catch {
                        try self.pushI32(-1);
                        continue;
                    };
                    try self.pushI32(@bitCast(old));
                },

                // ---- Constants ----
                0x41 => try self.pushI32(@bitCast(instr.operand)), // i32.const
                0x42 => try self.pushI64(@bitCast(pool64[instr.operand])), // i64.const
                0x43 => try self.pushF32(@bitCast(instr.operand)), // f32.const
                0x44 => try self.pushF64(@bitCast(pool64[instr.operand])), // f64.const

                // ---- i32 comparison ----
                0x45 => { const a = self.popI32(); try self.pushI32(b2i(a == 0)); },
                0x46 => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a == bv)); },
                0x47 => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a != bv)); },
                0x48 => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a < bv)); },
                0x49 => { const bv = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a < bv)); },
                0x4A => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a > bv)); },
                0x4B => { const bv = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a > bv)); },
                0x4C => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a <= bv)); },
                0x4D => { const bv = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a <= bv)); },
                0x4E => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(b2i(a >= bv)); },
                0x4F => { const bv = self.popU32(); const a = self.popU32(); try self.pushI32(b2i(a >= bv)); },

                // ---- i64 comparison ----
                0x50 => { const a = self.popI64(); try self.pushI32(b2i(a == 0)); },
                0x51 => { const bv = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a == bv)); },
                0x52 => { const bv = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a != bv)); },
                0x53 => { const bv = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a < bv)); },
                0x54 => { const bv = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a < bv)); },
                0x55 => { const bv = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a > bv)); },
                0x56 => { const bv = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a > bv)); },
                0x57 => { const bv = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a <= bv)); },
                0x58 => { const bv = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a <= bv)); },
                0x59 => { const bv = self.popI64(); const a = self.popI64(); try self.pushI32(b2i(a >= bv)); },
                0x5A => { const bv = self.popU64(); const a = self.popU64(); try self.pushI32(b2i(a >= bv)); },

                // ---- f32 comparison ----
                0x5B => { const bv = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a == bv)); },
                0x5C => { const bv = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a != bv)); },
                0x5D => { const bv = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a < bv)); },
                0x5E => { const bv = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a > bv)); },
                0x5F => { const bv = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a <= bv)); },
                0x60 => { const bv = self.popF32(); const a = self.popF32(); try self.pushI32(b2i(a >= bv)); },

                // ---- f64 comparison ----
                0x61 => { const bv = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a == bv)); },
                0x62 => { const bv = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a != bv)); },
                0x63 => { const bv = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a < bv)); },
                0x64 => { const bv = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a > bv)); },
                0x65 => { const bv = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a <= bv)); },
                0x66 => { const bv = self.popF64(); const a = self.popF64(); try self.pushI32(b2i(a >= bv)); },

                // ---- i32 arithmetic ----
                0x67 => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @clz(a)))); },
                0x68 => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @ctz(a)))); },
                0x69 => { const a = self.popU32(); try self.pushI32(@bitCast(@as(u32, @popCount(a)))); },
                0x6A => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(a +% bv); },
                0x6B => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(a -% bv); },
                0x6C => { const bv = self.popI32(); const a = self.popI32(); try self.pushI32(a *% bv); },
                0x6D => {
                    const bv = self.popI32(); const a = self.popI32();
                    if (bv == 0) return error.DivisionByZero;
                    if (a == math.minInt(i32) and bv == -1) return error.IntegerOverflow;
                    try self.pushI32(@divTrunc(a, bv));
                },
                0x6E => {
                    const bv = self.popU32(); const a = self.popU32();
                    if (bv == 0) return error.DivisionByZero;
                    try self.pushI32(@bitCast(a / bv));
                },
                0x6F => {
                    const bv = self.popI32(); const a = self.popI32();
                    if (bv == 0) return error.DivisionByZero;
                    if (bv == -1) { try self.pushI32(0); } else { try self.pushI32(@rem(a, bv)); }
                },
                0x70 => {
                    const bv = self.popU32(); const a = self.popU32();
                    if (bv == 0) return error.DivisionByZero;
                    try self.pushI32(@bitCast(a % bv));
                },
                0x71 => { const bv = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a & bv)); },
                0x72 => { const bv = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a | bv)); },
                0x73 => { const bv = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a ^ bv)); },
                0x74 => { const bv = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a << @truncate(bv % 32))); },
                0x75 => { const bv = self.popU32(); const a = self.popI32(); try self.pushI32(a >> @truncate(@as(u32, @bitCast(bv)) % 32)); },
                0x76 => { const bv = self.popU32(); const a = self.popU32(); try self.push(@as(u64, a >> @truncate(bv % 32))); },
                0x77 => { const bv = self.popU32(); const a = self.popU32(); try self.push(@as(u64, math.rotl(u32, a, bv % 32))); },
                0x78 => { const bv = self.popU32(); const a = self.popU32(); try self.push(@as(u64, math.rotr(u32, a, bv % 32))); },

                // ---- i64 arithmetic ----
                0x79 => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @clz(a)))); },
                0x7A => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @ctz(a)))); },
                0x7B => { const a = self.popU64(); try self.pushI64(@bitCast(@as(u64, @popCount(a)))); },
                0x7C => { const bv = self.popI64(); const a = self.popI64(); try self.pushI64(a +% bv); },
                0x7D => { const bv = self.popI64(); const a = self.popI64(); try self.pushI64(a -% bv); },
                0x7E => { const bv = self.popI64(); const a = self.popI64(); try self.pushI64(a *% bv); },
                0x7F => {
                    const bv = self.popI64(); const a = self.popI64();
                    if (bv == 0) return error.DivisionByZero;
                    if (a == math.minInt(i64) and bv == -1) return error.IntegerOverflow;
                    try self.pushI64(@divTrunc(a, bv));
                },
                0x80 => {
                    const bv = self.popU64(); const a = self.popU64();
                    if (bv == 0) return error.DivisionByZero;
                    try self.pushI64(@bitCast(a / bv));
                },
                0x81 => {
                    const bv = self.popI64(); const a = self.popI64();
                    if (bv == 0) return error.DivisionByZero;
                    if (bv == -1) { try self.pushI64(0); } else { try self.pushI64(@rem(a, bv)); }
                },
                0x82 => {
                    const bv = self.popU64(); const a = self.popU64();
                    if (bv == 0) return error.DivisionByZero;
                    try self.push(a % bv);
                },
                0x83 => { const bv = self.pop(); const a = self.pop(); try self.push(a & bv); },
                0x84 => { const bv = self.pop(); const a = self.pop(); try self.push(a | bv); },
                0x85 => { const bv = self.pop(); const a = self.pop(); try self.push(a ^ bv); },
                0x86 => { const bv = self.popU64(); const a = self.popU64(); try self.push(a << @truncate(bv % 64)); },
                0x87 => { const bv = self.popU64(); const a = self.popI64(); try self.pushI64(a >> @truncate(bv % 64)); },
                0x88 => { const bv = self.popU64(); const a = self.popU64(); try self.push(a >> @truncate(bv % 64)); },
                0x89 => { const bv = self.popU64(); const a = self.popU64(); try self.push(math.rotl(u64, a, bv % 64)); },
                0x8A => { const bv = self.popU64(); const a = self.popU64(); try self.push(math.rotr(u64, a, bv % 64)); },

                // ---- f32 arithmetic ----
                0x8B => { const a = self.popF32(); try self.pushF32(@abs(a)); },
                0x8C => { const a = self.popF32(); try self.pushF32(-a); },
                0x8D => { const a = self.popF32(); try self.pushF32(@ceil(a)); },
                0x8E => { const a = self.popF32(); try self.pushF32(@floor(a)); },
                0x8F => { const a = self.popF32(); try self.pushF32(@trunc(a)); },
                0x90 => { const a = self.popF32(); try self.pushF32(wasmNearest(f32, a)); },
                0x91 => { const a = self.popF32(); try self.pushF32(@sqrt(a)); },
                0x92 => { const bv = self.popF32(); const a = self.popF32(); try self.pushF32(a + bv); },
                0x93 => { const bv = self.popF32(); const a = self.popF32(); try self.pushF32(a - bv); },
                0x94 => { const bv = self.popF32(); const a = self.popF32(); try self.pushF32(a * bv); },
                0x95 => { const bv = self.popF32(); const a = self.popF32(); try self.pushF32(a / bv); },
                0x96 => { const bv = self.popF32(); const a = self.popF32(); try self.pushF32(wasmMin(f32, a, bv)); },
                0x97 => { const bv = self.popF32(); const a = self.popF32(); try self.pushF32(wasmMax(f32, a, bv)); },
                0x98 => { const bv = self.popF32(); const a = self.popF32(); try self.pushF32(std.math.copysign(a, bv)); },

                // ---- f64 arithmetic ----
                0x99 => { const a = self.popF64(); try self.pushF64(@abs(a)); },
                0x9A => { const a = self.popF64(); try self.pushF64(-a); },
                0x9B => { const a = self.popF64(); try self.pushF64(@ceil(a)); },
                0x9C => { const a = self.popF64(); try self.pushF64(@floor(a)); },
                0x9D => { const a = self.popF64(); try self.pushF64(@trunc(a)); },
                0x9E => { const a = self.popF64(); try self.pushF64(wasmNearest(f64, a)); },
                0x9F => { const a = self.popF64(); try self.pushF64(@sqrt(a)); },
                0xA0 => { const bv = self.popF64(); const a = self.popF64(); try self.pushF64(a + bv); },
                0xA1 => { const bv = self.popF64(); const a = self.popF64(); try self.pushF64(a - bv); },
                0xA2 => { const bv = self.popF64(); const a = self.popF64(); try self.pushF64(a * bv); },
                0xA3 => { const bv = self.popF64(); const a = self.popF64(); try self.pushF64(a / bv); },
                0xA4 => { const bv = self.popF64(); const a = self.popF64(); try self.pushF64(wasmMin(f64, a, bv)); },
                0xA5 => { const bv = self.popF64(); const a = self.popF64(); try self.pushF64(wasmMax(f64, a, bv)); },
                0xA6 => { const bv = self.popF64(); const a = self.popF64(); try self.pushF64(std.math.copysign(a, bv)); },

                // ---- Type conversions ----
                0xA7 => { const a = self.popI64(); try self.pushI32(@truncate(a)); },
                0xA8 => { const a = self.popF32(); try self.pushI32(truncSat(i32, f32, a) orelse return error.InvalidConversion); },
                0xA9 => { const a = self.popF32(); try self.pushI32(@bitCast(truncSat(u32, f32, a) orelse return error.InvalidConversion)); },
                0xAA => { const a = self.popF64(); try self.pushI32(truncSat(i32, f64, a) orelse return error.InvalidConversion); },
                0xAB => { const a = self.popF64(); try self.pushI32(@bitCast(truncSat(u32, f64, a) orelse return error.InvalidConversion)); },
                0xAC => { const a = self.popI32(); try self.pushI64(@as(i64, a)); },
                0xAD => { const a = self.popU32(); try self.pushI64(@as(i64, @as(i64, a))); },
                0xAE => { const a = self.popF32(); try self.pushI64(truncSat(i64, f32, a) orelse return error.InvalidConversion); },
                0xAF => { const a = self.popF32(); try self.pushI64(@bitCast(truncSat(u64, f32, a) orelse return error.InvalidConversion)); },
                0xB0 => { const a = self.popF64(); try self.pushI64(truncSat(i64, f64, a) orelse return error.InvalidConversion); },
                0xB1 => { const a = self.popF64(); try self.pushI64(@bitCast(truncSat(u64, f64, a) orelse return error.InvalidConversion)); },
                0xB2 => { const a = self.popI32(); try self.pushF32(@floatFromInt(a)); },
                0xB3 => { const a = self.popU32(); try self.pushF32(@floatFromInt(a)); },
                0xB4 => { const a = self.popI64(); try self.pushF32(@floatFromInt(a)); },
                0xB5 => { const a = self.popU64(); try self.pushF32(@floatFromInt(a)); },
                0xB6 => { const a = self.popF64(); try self.pushF32(@floatCast(a)); },
                0xB7 => { const a = self.popI32(); try self.pushF64(@floatFromInt(a)); },
                0xB8 => { const a = self.popU32(); try self.pushF64(@floatFromInt(a)); },
                0xB9 => { const a = self.popI64(); try self.pushF64(@floatFromInt(a)); },
                0xBA => { const a = self.popU64(); try self.pushF64(@floatFromInt(a)); },
                0xBB => { const a = self.popF32(); try self.pushF64(@as(f64, a)); },
                0xBC => { const a = self.popF32(); try self.push(@as(u64, @as(u32, @bitCast(a)))); },
                0xBD => { const a = self.popF64(); try self.push(@bitCast(a)); },
                0xBE => { const a = self.popU32(); try self.pushF32(@bitCast(a)); },
                0xBF => { const a = self.pop(); try self.pushF64(@bitCast(a)); },

                // ---- Sign extension ----
                0xC0 => { const a = self.popI32(); try self.pushI32(@as(i32, @as(i8, @truncate(a)))); },
                0xC1 => { const a = self.popI32(); try self.pushI32(@as(i32, @as(i16, @truncate(a)))); },
                0xC2 => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i8, @truncate(a)))); },
                0xC3 => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i16, @truncate(a)))); },
                0xC4 => { const a = self.popI64(); try self.pushI64(@as(i64, @as(i32, @truncate(a)))); },

                // ---- Reference types ----
                0xD0 => try self.push(0), // ref_null
                0xD1 => { const a = self.pop(); try self.pushI32(b2i(a == 0)); }, // ref_is_null
                0xD3 => { const b = self.pop(); const a = self.pop(); try self.pushI32(b2i(a == b)); }, // ref_eq
                0xD2 => { // ref_func — push store address + 1 (0 = null)
                    if (instr.operand < instance.funcaddrs.items.len) {
                        try self.push(@as(u64, @intCast(instance.funcaddrs.items[instr.operand])) + 1);
                    } else {
                        return error.FunctionIndexOutOfBounds;
                    }
                },

                // ---- Misc prefix (flattened) ----
                0xFC00...0xFCFF => try self.executeMiscIR(instr, instance),

                // ---- Fused superinstructions ----
                predecode_mod.OP_LOCAL_GET_GET => {
                    const frame = self.peekFrame();
                    try self.pushV128(self.op_stack[frame.locals_start + instr.extra]);
                    try self.pushV128(self.op_stack[frame.locals_start + instr.operand]);
                    pc += 1;
                },
                predecode_mod.OP_LOCAL_GET_CONST => {
                    const frame = self.peekFrame();
                    try self.pushV128(self.op_stack[frame.locals_start + instr.extra]);
                    try self.pushI32(@bitCast(instr.operand));
                    pc += 1;
                },
                predecode_mod.OP_LOCALS_ADD => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const b = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.operand]))));
                    try self.pushI32(a +% b);
                    pc += 2;
                },
                predecode_mod.OP_LOCALS_SUB => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const b = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.operand]))));
                    try self.pushI32(a -% b);
                    pc += 2;
                },
                predecode_mod.OP_LOCAL_CONST_ADD => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const c = @as(i32, @bitCast(instr.operand));
                    try self.pushI32(a +% c);
                    pc += 2;
                },
                predecode_mod.OP_LOCAL_CONST_SUB => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const c = @as(i32, @bitCast(instr.operand));
                    try self.pushI32(a -% c);
                    pc += 2;
                },
                predecode_mod.OP_LOCAL_CONST_LT_S => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const c = @as(i32, @bitCast(instr.operand));
                    try self.pushI32(b2i(a < c));
                    pc += 2;
                },
                predecode_mod.OP_LOCAL_CONST_GE_S => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const c = @as(i32, @bitCast(instr.operand));
                    try self.pushI32(b2i(a >= c));
                    pc += 2;
                },
                predecode_mod.OP_LOCAL_CONST_LT_U => {
                    const frame = self.peekFrame();
                    const a = @as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]));
                    const c = instr.operand;
                    try self.pushI32(b2i(a < c));
                    pc += 2;
                },
                predecode_mod.OP_LOCALS_GT_S => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const b = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.operand]))));
                    try self.pushI32(b2i(a > b));
                    pc += 2;
                },
                predecode_mod.OP_LOCALS_LE_S => {
                    const frame = self.peekFrame();
                    const a = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.extra]))));
                    const b = @as(i32, @bitCast(@as(u32, @truncate(self.op_stack[frame.locals_start + instr.operand]))));
                    try self.pushI32(b2i(a <= b));
                    pc += 2;
                },

                else => return error.Trap,
            }
        }
    }

    fn doCallIR(self: *Vm, instance: *Instance, func_idx: u32) WasmError!void {
        const func_ptr = try instance.getFuncPtr(func_idx);
        try self.doCallDirectIR(instance, func_ptr);
    }

    fn doCallDirectIR(self: *Vm, instance: *Instance, initial_fp: *store_mod.Function) WasmError!void {
        var current_fp = initial_fp;
        while (true) {
            if (self.profile) |p| p.call_count += 1;
            switch (current_fp.subtype) {
                .wasm_function => |*wf| {
                    const param_count = current_fp.params.len;
                    const locals_start = self.op_ptr - param_count;

                    // Lazy IR predecoding (try IR first, fall back to branch table)
                    if (wf.ir == null and !wf.ir_failed) {
                        wf.ir = predecode_mod.predecode(self.alloc, wf.code) catch null;
                        if (wf.ir == null) wf.ir_failed = true;
                    }

                    // Trigger regIR conversion for callees of stack-IR functions.
                    if (wf.ir != null and wf.reg_ir == null and !wf.reg_ir_failed and
                        current_fp.results.len <= 1)
                    {
                        const callee_inst: *Instance = @ptrCast(@alignCast(wf.instance));
                        const resolver = regalloc_mod.ParamResolver{
                            .ctx = @ptrCast(callee_inst),
                            .resolve_fn = struct {
                                fn resolve(ctx: *anyopaque, func_idx: u32) ?regalloc_mod.FuncTypeInfo {
                                    const i: *Instance = @ptrCast(@alignCast(ctx));
                                    const fp = i.getFuncPtr(func_idx) catch return null;
                                    return .{
                                        .param_count = @intCast(fp.params.len),
                                        .result_count = @intCast(fp.results.len),
                                    };
                                }
                            }.resolve,
                            .resolve_type_fn = struct {
                                fn resolve(ctx: *anyopaque, type_idx: u32) ?regalloc_mod.FuncTypeInfo {
                                    const i: *Instance = @ptrCast(@alignCast(ctx));
                                    const t = i.module.getTypeFunc(type_idx) orelse return null;
                                    return .{
                                        .param_count = @intCast(t.params.len),
                                        .result_count = @intCast(t.results.len),
                                    };
                                }
                            }.resolve,
                        };
                        wf.reg_ir = regalloc_mod.convert(
                            self.alloc,
                            wf.ir.?.code,
                            wf.ir.?.pool64,
                            @intCast(current_fp.params.len),
                            @intCast(wf.locals_count),
                            resolver,
                        ) catch null;
                        if (wf.reg_ir == null) {
                            wf.reg_ir_failed = true;
                            if (self.trace) |tc| trace_mod.traceRegirBail(tc, wf.func_idx, "conversion failed");
                        } else {
                            if (self.trace) |tc| trace_mod.traceRegirConvert(tc, wf.func_idx, @intCast(wf.ir.?.code.len), @intCast(wf.reg_ir.?.code.len), wf.reg_ir.?.reg_count);
                        }
                    }

                    // JIT compilation + fast execution for hot callees.
                    if (wf.reg_ir) |reg| {
                        if (comptime jit_mod.jitSupported()) {
                            if (self.profile == null and
                                wf.jit_code == null and !wf.jit_failed)
                            {
                                wf.call_count += 1;
                                if (wf.call_count >= jit_mod.HOT_THRESHOLD) {
                                    const jit_inst: *Instance = @ptrCast(@alignCast(wf.instance));
                                    wf.jit_code = jit_mod.compileFunction(self.alloc, reg, wf.ir.?.pool64, wf.func_idx, @intCast(current_fp.params.len), @intCast(current_fp.results.len), self.trace, jit_mod.getMinMemoryBytes(jit_inst), jit_mod.getUseGuardPages(jit_inst));
                                    if (wf.jit_code == null) {
                                        wf.jit_failed = true;
                                        if (self.trace) |tc| trace_mod.traceJitBail(tc, wf.func_idx, "compilation failed");
                                    } else {
                                        if (self.trace) |tc| trace_mod.traceJitCompile(tc, wf.func_idx, @intCast(reg.code.len), @intCast(wf.jit_code.?.buf.len));
                                    }
                                }
                            }
                        }

                        if (self.profile == null) {
                            if (wf.jit_code) |jc| {
                                if (param_count <= 16) {
                                    var arg_buf: [16]u64 = undefined;
                                    for (0..param_count) |i| {
                                        arg_buf[i] = @truncate(self.op_stack[locals_start + i]);
                                    }
                                    self.op_ptr = locals_start;
                                    var call_results: [1]u64 = .{0};
                                    const n_results = current_fp.results.len;
                                    try self.executeJIT(jc, reg, instance, current_fp, arg_buf[0..param_count], call_results[0..n_results]);
                                    if (n_results > 0) try self.push(call_results[0]);
                                    return;
                                }
                            }
                        }
                    }

                    for (0..wf.locals_count) |_| try self.push(0);

                    const saved_bt = self.current_branch_table;

                    try self.pushFrame(.{
                        .locals_start = locals_start,
                        .locals_count = param_count + wf.locals_count,
                        .return_arity = current_fp.results.len,
                        .op_stack_base = locals_start,
                        .label_stack_base = self.label_ptr,
                        .return_reader = Reader.init(&.{}),
                        .instance = instance,
                    });

                    const callee_inst: *Instance = @ptrCast(@alignCast(wf.instance));

                    if (wf.ir) |ir| {
                        try self.pushLabel(.{
                            .arity = current_fp.results.len,
                            .op_stack_base = self.op_ptr,
                            .target = .{ .ir_forward = @intCast(ir.code.len) },
                        });
                        self.executeIR(ir.code, ir.pool64, callee_inst) catch |err| {
                            const f = self.popFrame();
                            self.label_ptr = f.label_stack_base;
                            self.op_ptr = f.op_stack_base;
                            self.current_branch_table = saved_bt;
                            return err;
                        };
                    } else {
                        if (wf.branch_table == null) {
                            wf.branch_table = computeBranchTable(self.alloc, wf.code) catch null;
                        }
                        self.current_branch_table = wf.branch_table;

                        var body_reader = Reader.init(wf.code);
                        try self.pushLabel(.{
                            .arity = current_fp.results.len,
                            .op_stack_base = self.op_ptr,
                            .target = .{ .forward = body_reader },
                        });
                        self.execute(&body_reader, callee_inst) catch |err| {
                            const f = self.popFrame();
                            self.label_ptr = f.label_stack_base;
                            self.op_ptr = f.op_stack_base;
                            self.current_branch_table = saved_bt;
                            return err;
                        };
                    }

                    // Tail call: executeIR/execute set tail_call_func, reuse frame
                    if (self.tail_call_func) |next_fp| {
                        const frame = self.popFrame();
                        self.label_ptr = frame.label_stack_base;
                        self.current_branch_table = saved_bt;
                        self.op_ptr = frame.op_stack_base;

                        for (0..self.tail_call_arg_count) |i| {
                            try self.push(self.tail_call_args[i]);
                        }
                        self.tail_call_func = null;
                        current_fp = next_fp;
                        continue;
                    }

                    // Normal return: move results to correct position
                    const frame = self.popFrame();
                    self.label_ptr = frame.label_stack_base;
                    self.current_branch_table = saved_bt;
                    const n = frame.return_arity;
                    if (n > 0) {
                        const src_start = self.op_ptr - n;
                        for (0..n) |i| {
                            self.op_stack[frame.op_stack_base + i] = self.op_stack[src_start + i];
                        }
                    }
                    self.op_ptr = frame.op_stack_base + n;
                },
                .host_function => |hf| {
                    self.current_instance = instance;
                    hf.func(@ptrCast(self), hf.context) catch return error.Trap;
                },
            }
            return;
        }
    }

    fn executeMiscIR(self: *Vm, instr: PreInstr, instance: *Instance) WasmError!void {
        const sub = instr.opcode - predecode_mod.MISC_BASE;
        if (self.profile) |p| {
            if (sub < 32) p.misc_counts[sub] += 1;
        }
        switch (sub) {
            0x00 => { const a = self.popF32(); try self.pushI32(truncSatClamp(i32, f32, a)); },
            0x01 => { const a = self.popF32(); try self.pushI32(@bitCast(truncSatClamp(u32, f32, a))); },
            0x02 => { const a = self.popF64(); try self.pushI32(truncSatClamp(i32, f64, a)); },
            0x03 => { const a = self.popF64(); try self.pushI32(@bitCast(truncSatClamp(u32, f64, a))); },
            0x04 => { const a = self.popF32(); try self.pushI64(truncSatClamp(i64, f32, a)); },
            0x05 => { const a = self.popF32(); try self.pushI64(@bitCast(truncSatClamp(u64, f32, a))); },
            0x06 => { const a = self.popF64(); try self.pushI64(truncSatClamp(i64, f64, a)); },
            0x07 => { const a = self.popF64(); try self.pushI64(@bitCast(truncSatClamp(u64, f64, a))); },
            0x0A => { // memory.copy (extra=dst_memidx, operand=src_memidx)
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const dst = @as(u32, @bitCast(self.popI32()));
                const dst_mem = try instance.getMemory(instr.extra);
                if (instr.extra == instr.operand) {
                    try dst_mem.copyWithin(dst, src, n);
                } else {
                    const src_mem = try instance.getMemory(@intCast(instr.operand));
                    const src_data = src_mem.memory();
                    const dst_data = dst_mem.memory();
                    if (@as(u64, src) + n > src_data.len or @as(u64, dst) + n > dst_data.len)
                        return error.OutOfBoundsMemoryAccess;
                    if (n > 0) @memcpy(dst_data[dst..][0..n], src_data[src..][0..n]);
                }
            },
            0x0B => { // memory.fill (operand=memidx)
                const n = @as(u32, @bitCast(self.popI32()));
                const val = @as(u8, @truncate(@as(u32, @bitCast(self.popI32()))));
                const dst = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(@intCast(instr.operand));
                try m.fill(dst, n, val);
            },
            0x08 => { // memory.init (extra=memidx, operand=data_idx)
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const dst = @as(u32, @bitCast(self.popI32()));
                const m = try instance.getMemory(instr.extra);
                if (instr.operand >= instance.dataaddrs.items.len) return error.Trap;
                const d = try instance.store.getData(instance.dataaddrs.items[instr.operand]);
                const data_len: u64 = if (d.dropped) 0 else d.data.len;
                if (@as(u64, src) + n > data_len or @as(u64, dst) + n > m.memory().len)
                    return error.OutOfBoundsMemoryAccess;
                if (n > 0) @memcpy(m.memory()[dst..][0..n], d.data[src..][0..n]);
            },
            0x09 => { // data.drop
                if (instr.operand >= instance.dataaddrs.items.len) return error.Trap;
                const d = try instance.store.getData(instance.dataaddrs.items[instr.operand]);
                d.dropped = true;
            },
            0x0C => { // table.init
                const n = @as(u32, @bitCast(self.popI32()));
                const src = @as(u32, @bitCast(self.popI32()));
                const t = try instance.getTable(instr.extra);
                const dst: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                if (instr.operand >= instance.elemaddrs.items.len) return error.Trap;
                const e = try instance.store.getElem(instance.elemaddrs.items[instr.operand]);
                const elem_len: u64 = if (e.dropped) 0 else e.data.len;
                if (@as(u64, src) + n > elem_len or @as(u64, dst) + n > t.size())
                    return error.OutOfBoundsMemoryAccess;
                for (0..n) |i| {
                    const val = e.data[src + @as(u32, @intCast(i))];
                    const ref: ?usize = if (val == 0) null else @intCast(val - 1);
                    t.set(dst + @as(u32, @intCast(i)), ref) catch return error.OutOfBoundsMemoryAccess;
                }
            },
            0x0D => { // elem.drop
                if (instr.operand >= instance.elemaddrs.items.len) return error.Trap;
                const e = try instance.store.getElem(instance.elemaddrs.items[instr.operand]);
                e.dropped = true;
            },
            0x0E => { // table.copy
                const dst_t = try instance.getTable(instr.extra);
                const src_t = try instance.getTable(instr.operand);
                const n_64 = dst_t.is_64 or src_t.is_64;
                const n: u32 = if (n_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const src: u32 = if (src_t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const dst: u32 = if (dst_t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                if (@as(u64, src) + n > src_t.size() or @as(u64, dst) + n > dst_t.size())
                    return error.OutOfBoundsMemoryAccess;
                if (dst <= src) {
                    for (0..n) |i| {
                        const val = src_t.get(src + @as(u32, @intCast(i))) catch return error.OutOfBoundsMemoryAccess;
                        dst_t.set(dst + @as(u32, @intCast(i)), val) catch return error.OutOfBoundsMemoryAccess;
                    }
                } else {
                    var idx: u32 = n;
                    while (idx > 0) {
                        idx -= 1;
                        const val = src_t.get(src + idx) catch return error.OutOfBoundsMemoryAccess;
                        dst_t.set(dst + idx, val) catch return error.OutOfBoundsMemoryAccess;
                    }
                }
            },
            0x0F => { // table.grow
                const t = try instance.store.getTable(instr.operand);
                const n: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const val = self.pop();
                const init_val: ?usize = if (val == 0) null else @intCast(val - 1);
                const old = t.grow(n, init_val) catch {
                    if (t.is_64) try self.pushI64(-1) else try self.pushI32(-1);
                    return;
                };
                if (t.is_64) try self.pushI64(@intCast(old)) else try self.pushI32(@bitCast(old));
            },
            0x10 => { // table.size
                const t = try instance.store.getTable(instr.operand);
                if (t.is_64) try self.pushI64(@intCast(t.size())) else try self.pushI32(@bitCast(t.size()));
            },
            0x11 => { // table.fill
                const t = try instance.store.getTable(instr.operand);
                const n: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                const val = self.pop();
                const start: u32 = if (t.is_64) @truncate(self.popU64()) else @as(u32, @bitCast(self.popI32()));
                // Bounds check first (spec: trap if i + n > table.size)
                if (@as(u64, start) + n > t.size())
                    return error.OutOfBoundsMemoryAccess;
                const ref_val: ?usize = if (val == 0) null else @intCast(val - 1);
                for (0..n) |i| {
                    t.set(start + @as(u32, @intCast(i)), ref_val) catch return error.OutOfBoundsMemoryAccess;
                }
            },
            // Wide arithmetic (i128 ops)
            0x13 => { // i64.add128
                const rhs_hi: u64 = @bitCast(self.popI64());
                const rhs_lo: u64 = @bitCast(self.popI64());
                const lhs_hi: u64 = @bitCast(self.popI64());
                const lhs_lo: u64 = @bitCast(self.popI64());
                const lo = lhs_lo +% rhs_lo;
                const carry: u64 = if (lo < lhs_lo) 1 else 0;
                const hi = lhs_hi +% rhs_hi +% carry;
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            0x14 => { // i64.sub128
                const rhs_hi: u64 = @bitCast(self.popI64());
                const rhs_lo: u64 = @bitCast(self.popI64());
                const lhs_hi: u64 = @bitCast(self.popI64());
                const lhs_lo: u64 = @bitCast(self.popI64());
                const lo = lhs_lo -% rhs_lo;
                const borrow: u64 = if (lhs_lo < rhs_lo) 1 else 0;
                const hi = lhs_hi -% rhs_hi -% borrow;
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            0x15 => { // i64.mul_wide_s
                const b: i64 = self.popI64();
                const a: i64 = self.popI64();
                const result: i128 = @as(i128, a) * @as(i128, b);
                const lo: u64 = @truncate(@as(u128, @bitCast(result)));
                const hi: u64 = @truncate(@as(u128, @bitCast(result)) >> 64);
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            0x16 => { // i64.mul_wide_u
                const b: u64 = @bitCast(self.popI64());
                const a: u64 = @bitCast(self.popI64());
                const result: u128 = @as(u128, a) * @as(u128, b);
                const lo: u64 = @truncate(result);
                const hi: u64 = @truncate(result >> 64);
                try self.pushI64(@bitCast(lo));
                try self.pushI64(@bitCast(hi));
            },
            else => return error.Trap,
        }
    }

    // ---- IR memory helpers (offset pre-decoded) ----

    fn memLoadIR(self: *Vm, comptime LoadT: type, comptime ResultT: type, offset: u32, instance: *Instance) WasmError!void {
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        const val = m.read(LoadT, offset, base) catch return error.OutOfBoundsMemoryAccess;
        const result: ResultT = if (@bitSizeOf(LoadT) == @bitSizeOf(ResultT))
            @bitCast(val)
        else
            @intCast(val);
        try self.push(asU64(ResultT, result));
    }

    fn memLoadFloatIR(self: *Vm, comptime T: type, offset: u32, instance: *Instance) WasmError!void {
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        const val = m.read(T, offset, base) catch return error.OutOfBoundsMemoryAccess;
        switch (T) {
            f32 => try self.pushF32(val),
            f64 => try self.pushF64(val),
            else => unreachable,
        }
    }

    fn memStoreIR(self: *Vm, comptime T: type, offset: u32, instance: *Instance) WasmError!void {
        const val: T = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        m.write(T, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreFloatIR(self: *Vm, comptime T: type, offset: u32, instance: *Instance) WasmError!void {
        const val = switch (T) {
            f32 => self.popF32(),
            f64 => self.popF64(),
            else => unreachable,
        };
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        m.write(T, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreTruncIR(self: *Vm, comptime StoreT: type, offset: u32, instance: *Instance) WasmError!void {
        const val: StoreT = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = try instance.getMemory(0);
        m.write(StoreT, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    // ================================================================
    // Multi-memory resolution
    // ================================================================

    fn resolveMem(cached_mem: ?*WasmMemory, memidx: u16, instance: *Instance) ?*WasmMemory {
        if (memidx == 0) return cached_mem;
        return instance.getMemory(memidx) catch null;
    }

    // ================================================================
    // Cached-memory IR helpers (avoid triple-indirection per load/store)
    // ================================================================

    fn memLoadCached(self: *Vm, comptime LoadT: type, comptime ResultT: type, offset: u32, cached_mem: ?*WasmMemory) WasmError!void {
        const base = @as(u32, @bitCast(self.popI32()));
        const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
        const val = m.read(LoadT, offset, base) catch return error.OutOfBoundsMemoryAccess;
        const result: ResultT = if (@bitSizeOf(LoadT) == @bitSizeOf(ResultT))
            @bitCast(val)
        else
            @intCast(val);
        try self.push(asU64(ResultT, result));
    }

    fn memLoadFloatCached(self: *Vm, comptime T: type, offset: u32, cached_mem: ?*WasmMemory) WasmError!void {
        const base = @as(u32, @bitCast(self.popI32()));
        const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
        const val = m.read(T, offset, base) catch return error.OutOfBoundsMemoryAccess;
        switch (T) {
            f32 => try self.pushF32(val),
            f64 => try self.pushF64(val),
            else => unreachable,
        }
    }

    fn memStoreCached(self: *Vm, comptime T: type, offset: u32, cached_mem: ?*WasmMemory) WasmError!void {
        const val: T = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
        m.write(T, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreFloatCached(self: *Vm, comptime T: type, offset: u32, cached_mem: ?*WasmMemory) WasmError!void {
        const val = switch (T) {
            f32 => self.popF32(),
            f64 => self.popF64(),
            else => unreachable,
        };
        const base = @as(u32, @bitCast(self.popI32()));
        const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
        m.write(T, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreTruncCached(self: *Vm, comptime StoreT: type, offset: u32, cached_mem: ?*WasmMemory) WasmError!void {
        const val: StoreT = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        const m = cached_mem orelse return error.OutOfBoundsMemoryAccess;
        m.write(StoreT, offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    // ================================================================
    // Memory helpers
    // ================================================================

    /// Read memarg from bytecode stream, returning offset and resolved memory.
    /// Handles multi-memory: bit 6 of alignment signals memidx follows.
    fn readMemarg(reader: *Reader, instance: *Instance) !struct { offset: u32, mem: *WasmMemory } {
        const align_flags = try reader.readU32();
        const memidx: u16 = if (align_flags & 0x40 != 0) @intCast(try reader.readU32()) else 0;
        const offset = try reader.readU32();
        const m = instance.getMemory(memidx) catch return error.OutOfBoundsMemoryAccess;
        return .{ .offset = offset, .mem = m };
    }

    fn memLoad(self: *Vm, comptime LoadT: type, comptime ResultT: type, reader: *Reader, instance: *Instance) WasmError!void {
        const ma = try readMemarg(reader, instance);
        const base = @as(u32, @bitCast(self.popI32()));
        const val = ma.mem.read(LoadT, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
        const result: ResultT = if (@bitSizeOf(LoadT) == @bitSizeOf(ResultT))
            @bitCast(val)
        else
            @intCast(val);
        try self.push(asU64(ResultT, result));
    }

    fn memLoadFloat(self: *Vm, comptime T: type, reader: *Reader, instance: *Instance) WasmError!void {
        const ma = try readMemarg(reader, instance);
        const base = @as(u32, @bitCast(self.popI32()));
        const val = ma.mem.read(T, ma.offset, base) catch return error.OutOfBoundsMemoryAccess;
        switch (T) {
            f32 => try self.pushF32(val),
            f64 => try self.pushF64(val),
            else => unreachable,
        }
    }

    fn memStore(self: *Vm, comptime T: type, reader: *Reader, instance: *Instance) WasmError!void {
        const ma = try readMemarg(reader, instance);
        const val: T = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        ma.mem.write(T, ma.offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreFloat(self: *Vm, comptime T: type, reader: *Reader, instance: *Instance) WasmError!void {
        const ma = try readMemarg(reader, instance);
        const val = switch (T) {
            f32 => self.popF32(),
            f64 => self.popF64(),
            else => unreachable,
        };
        const base = @as(u32, @bitCast(self.popI32()));
        ma.mem.write(T, ma.offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    fn memStoreTrunc(self: *Vm, comptime StoreT: type, comptime _: type, reader: *Reader, instance: *Instance) WasmError!void {
        const ma = try readMemarg(reader, instance);
        const val: StoreT = @truncate(self.pop());
        const base = @as(u32, @bitCast(self.popI32()));
        ma.mem.write(StoreT, ma.offset, base, val) catch return error.OutOfBoundsMemoryAccess;
    }

    // ================================================================
    // Stack operations
    // ================================================================

    fn push(self: *Vm, val: u64) WasmError!void {
        if (self.op_ptr >= OPERAND_STACK_SIZE) return error.StackOverflow;
        self.op_stack[self.op_ptr] = @as(u128, val);
        self.op_ptr += 1;
    }

    fn pop(self: *Vm) u64 {
        self.op_ptr -= 1;
        return @truncate(self.op_stack[self.op_ptr]);
    }

    fn peek(self: *Vm) u64 {
        return @truncate(self.op_stack[self.op_ptr - 1]);
    }

    fn pushV128(self: *Vm, val: u128) WasmError!void {
        if (self.op_ptr >= OPERAND_STACK_SIZE) return error.StackOverflow;
        self.op_stack[self.op_ptr] = val;
        self.op_ptr += 1;
    }

    fn popV128(self: *Vm) u128 {
        self.op_ptr -= 1;
        return self.op_stack[self.op_ptr];
    }

    fn pushI32(self: *Vm, val: i32) WasmError!void { try self.push(@as(u64, @as(u32, @bitCast(val)))); }
    fn pushI64(self: *Vm, val: i64) WasmError!void { try self.push(@bitCast(val)); }
    fn pushF32(self: *Vm, val: f32) WasmError!void { try self.push(@as(u64, @as(u32, @bitCast(val)))); }
    fn pushF64(self: *Vm, val: f64) WasmError!void { try self.push(@bitCast(val)); }

    fn popI32(self: *Vm) i32 { return @bitCast(@as(u32, @truncate(self.pop()))); }
    fn popU32(self: *Vm) u32 { return @truncate(self.pop()); }
    fn popI64(self: *Vm) i64 { return @bitCast(self.pop()); }
    fn popU64(self: *Vm) u64 { return self.pop(); }
    fn popF32(self: *Vm) f32 { return @bitCast(@as(u32, @truncate(self.pop()))); }
    fn popF64(self: *Vm) f64 { return @bitCast(self.pop()); }

    // Host function stack access (for WASI and host callbacks)
    pub fn pushOperand(self: *Vm, val: u64) WasmError!void { try self.push(val); }
    pub fn popOperand(self: *Vm) u64 { return self.pop(); }
    pub fn popOperandI32(self: *Vm) i32 { return self.popI32(); }
    pub fn popOperandU32(self: *Vm) u32 { return self.popU32(); }
    pub fn popOperandI64(self: *Vm) i64 { return self.popI64(); }

    /// Get memory from the current instance (for host/WASI functions).
    pub fn getMemory(self: *Vm, idx: u32) !*WasmMemory {
        const inst = self.current_instance orelse return error.Trap;
        return inst.getMemory(idx);
    }

    fn pushFrame(self: *Vm, frame: Frame) WasmError!void {
        if (self.frame_ptr >= FRAME_STACK_SIZE) return error.StackOverflow;
        self.frame_stack[self.frame_ptr] = frame;
        self.frame_ptr += 1;
    }

    fn popFrame(self: *Vm) Frame {
        self.frame_ptr -= 1;
        return self.frame_stack[self.frame_ptr];
    }

    fn peekFrame(self: *Vm) Frame {
        return self.frame_stack[self.frame_ptr - 1];
    }

    fn pushLabel(self: *Vm, label: Label) WasmError!void {
        if (self.label_ptr >= LABEL_STACK_SIZE) return error.StackOverflow;
        self.label_stack[self.label_ptr] = label;
        self.label_ptr += 1;
    }

    fn popLabel(self: *Vm) Label {
        self.label_ptr -= 1;
        return self.label_stack[self.label_ptr];
    }

    fn peekLabel(self: *Vm, depth: u32) Label {
        return self.label_stack[self.label_ptr - 1 - depth];
    }

    /// Search the current function's label stack for a try_table with a matching
    /// catch clause for the pending exception. If found, unwind to the catch
    /// target and return true (caller should continue execution). If not found,
    /// return false (caller should propagate the exception).
    fn handleException(self: *Vm, reader: *Reader, _: *Instance) bool {
        const exc = self.pending_exception orelse return false;
        const frame = self.peekFrame();
        const label_base = frame.label_stack_base;

        // Search labels from innermost to outermost in current frame
        var scan = self.label_ptr;
        while (scan > label_base) {
            scan -= 1;
            const label = self.label_stack[scan];
            if (label.catch_count == 0) continue;

            // This is a try_table label — check catch clauses
            for (label.catches[0..label.catch_count]) |clause| {
                const matched = switch (clause.kind) {
                    0x00, 0x01 => clause.tag_id == exc.tag_id, // catch / catch_ref
                    0x02, 0x03 => true, // catch_all / catch_all_ref
                    else => false,
                };
                if (!matched) continue;

                // Match found! The catch clause's label_depth is relative to
                // the try_table's enclosing scope (before the try_table pushes
                // its own label). So depth 0 = the block enclosing the try_table.
                if (scan < label_base + 1 + clause.label_depth) continue;
                const target_label_idx = scan - 1 - clause.label_depth;

                const target_label = self.label_stack[target_label_idx];

                // Unwind operand stack to target label's base
                self.op_ptr = target_label.op_stack_base;

                // Push exception payload values
                if (clause.kind == 0x00 or clause.kind == 0x01) {
                    // catch/catch_ref: push tag parameter values
                    for (0..exc.value_count) |vi| {
                        self.op_stack[self.op_ptr] = @as(u128, exc.values[vi]);
                        self.op_ptr += 1;
                    }
                }
                // catch_ref/catch_all_ref: also push exnref
                if (clause.kind == 0x01 or clause.kind == 0x03) {
                    // TODO: push actual exnref value (for now push a non-null sentinel)
                    self.op_stack[self.op_ptr] = 1; // placeholder exnref
                    self.op_ptr += 1;
                }

                // Branch to the target label and consume it (like br)
                switch (target_label.target) {
                    .forward => |r| {
                        reader.* = r;
                        self.label_ptr = target_label_idx;
                    },
                    .loop_start => |r| {
                        reader.* = r;
                        // For loops: keep the loop label for re-entry
                        self.label_ptr = target_label_idx + 1;
                    },
                    .ir_forward, .ir_loop_start => {},
                }

                self.pending_exception = null;
                return true;
            }
        }
        return false; // no matching catch found in this frame
    }
};

// ============================================================
// Helper functions
// ============================================================

fn b2i(b: bool) i32 { return if (b) 1 else 0; }

fn resolveArityIR(extra: u16, instance: *Instance) usize {
    if (extra & predecode_mod.ARITY_TYPE_INDEX_FLAG != 0) {
        const idx = extra & ~predecode_mod.ARITY_TYPE_INDEX_FLAG;
        if (instance.module.getTypeFunc(idx)) |ft|
            return ft.results.len;
        return 0;
    }
    return extra;
}

fn resolveParamArityIR(extra: u16, instance: *Instance) usize {
    if (extra & predecode_mod.ARITY_TYPE_INDEX_FLAG != 0) {
        const idx = extra & ~predecode_mod.ARITY_TYPE_INDEX_FLAG;
        if (instance.module.getTypeFunc(idx)) |ft|
            return ft.params.len;
        return 0;
    }
    return 0; // simple blocktypes have 0 params
}

fn asU64(comptime T: type, val: T) u64 {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed) @bitCast(@as(i64, val)) else @as(u64, val),
        else => @compileError("unsupported type"),
    };
}

fn readBlockType(reader: *Reader) !opcode.BlockType {
    const byte = reader.bytes[reader.pos];
    if (byte == 0x40) {
        reader.pos += 1;
        return .empty;
    }
    // Check if it's a valtype (0x7F..0x70)
    if (byte >= 0x6F and byte <= 0x7F) {
        reader.pos += 1;
        return .{ .val_type = ValType.fromByte(byte) orelse return error.InvalidWasm };
    }
    // ref type encoding: 0x63 = (ref null ht), 0x64 = (ref ht)
    if (byte == 0x63 or byte == 0x64) {
        reader.pos += 1;
        _ = try reader.readI33(); // consume heap type
        return .{ .val_type = .funcref }; // treat as funcref for arity purposes
    }
    // Otherwise it's a type index (s33)
    const idx = try reader.readI33();
    return .{ .type_index = @intCast(idx) };
}

fn blockTypeArity(bt: opcode.BlockType, instance: *Instance) usize {
    return switch (bt) {
        .empty => 0,
        .val_type => 1,
        .type_index => |idx| blk: {
            if (instance.module.getTypeFunc(idx)) |ft|
                break :blk ft.results.len;
            break :blk 0;
        },
    };
}

fn blockTypeParamArity(bt: opcode.BlockType, instance: *Instance) usize {
    return switch (bt) {
        .empty, .val_type => 0,
        .type_index => |idx| blk: {
            if (instance.module.getTypeFunc(idx)) |ft|
                break :blk ft.params.len;
            break :blk 0;
        },
    };
}

/// Skip bytecode until matching `end`, handling nesting.
fn skipToEnd(reader: *Reader) !void {
    var depth: u32 = 1;
    while (depth > 0 and reader.hasMore()) {
        const byte = try reader.readByte();
        const op: Opcode = @enumFromInt(byte);
        switch (op) {
            .block, .loop, .@"if" => {
                _ = try readBlockType(reader);
                depth += 1;
            },
            .end => depth -= 1,
            .@"else" => if (depth == 1) {}, // same depth, continue
            .br, .br_if, .br_on_null, .br_on_non_null => _ = try reader.readU32(),
            .br_table => {
                const count = try reader.readU32();
                for (0..count + 1) |_| _ = try reader.readU32();
            },
            .call, .return_call, .local_get, .local_set, .local_tee,
            .global_get, .global_set, .ref_func, .table_get, .table_set,
            .call_ref, .return_call_ref,
            => _ = try reader.readU32(),
            .call_indirect, .return_call_indirect => { _ = try reader.readU32(); _ = try reader.readU32(); },
            .throw => _ = try reader.readU32(),
            .throw_ref => {},
            .try_table => {
                _ = try readBlockType(reader);
                const n_catches = try reader.readU32();
                for (0..n_catches) |_| {
                    const catch_kind = try reader.readByte();
                    if (catch_kind == 0x00 or catch_kind == 0x01) _ = try reader.readU32();
                    _ = try reader.readU32();
                }
                depth += 1;
            },
            .select_t => { const n = try reader.readU32(); for (0..n) |_| _ = try reader.readByte(); },
            .i32_const => _ = try reader.readI32(),
            .i64_const => _ = try reader.readI64(),
            .f32_const => _ = try reader.readBytes(4),
            .f64_const => _ = try reader.readBytes(8),
            .i32_load, .i64_load, .f32_load, .f64_load,
            .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u,
            .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u,
            .i64_load32_s, .i64_load32_u,
            .i32_store, .i64_store, .f32_store, .f64_store,
            .i32_store8, .i32_store16,
            .i64_store8, .i64_store16, .i64_store32,
            => {
                const align_flags = try reader.readU32();
                if (align_flags & 0x40 != 0) _ = try reader.readU32(); // memidx
                _ = try reader.readU32(); // offset
            },
            .memory_size, .memory_grow => _ = try reader.readU32(),
            .ref_null => _ = try reader.readI33(),
            .misc_prefix => {
                const sub = try reader.readU32();
                switch (sub) {
                    0x0A => { _ = try reader.readU32(); _ = try reader.readU32(); }, // memory.copy
                    0x0B => _ = try reader.readU32(), // memory.fill
                    0x08 => { _ = try reader.readU32(); _ = try reader.readU32(); }, // memory.init
                    0x09 => _ = try reader.readU32(), // data.drop
                    0x0C => { _ = try reader.readU32(); _ = try reader.readU32(); }, // table.init
                    0x0D => _ = try reader.readU32(), // elem.drop
                    0x0E => { _ = try reader.readU32(); _ = try reader.readU32(); }, // table.copy
                    0x0F => _ = try reader.readU32(), // table.grow
                    0x10 => _ = try reader.readU32(), // table.size
                    0x11 => _ = try reader.readU32(), // table.fill
                    else => {},
                }
            },
            .gc_prefix => skipGcImmediates(reader) catch return,
            .simd_prefix => try skipSimdImmediates(reader),
            .atomic_prefix => try skipAtomicImmediates(reader),
            else => {}, // Simple opcodes with no immediates
        }
    }
}

/// Find the matching `else` (if present) and `end` for an `if` block.
/// Returns true if `else` was found.
fn findElseOrEnd(else_reader: *Reader, end_reader: *Reader) !bool {
    var depth: u32 = 1;
    var found_else = false;
    const reader = end_reader;
    while (depth > 0 and reader.hasMore()) {
        const pos_before = reader.pos;
        const byte = try reader.readByte();
        const op: Opcode = @enumFromInt(byte);
        switch (op) {
            .block, .loop, .@"if" => {
                _ = try readBlockType(reader);
                depth += 1;
            },
            .end => {
                depth -= 1;
                if (depth == 0) return found_else;
            },
            .@"else" => if (depth == 1) {
                else_reader.* = reader.*;
                _ = pos_before; // else_reader is set to AFTER the else opcode
                found_else = true;
            },
            .br, .br_if, .br_on_null, .br_on_non_null => _ = try reader.readU32(),
            .br_table => {
                const count = try reader.readU32();
                for (0..count + 1) |_| _ = try reader.readU32();
            },
            .call, .return_call, .local_get, .local_set, .local_tee,
            .global_get, .global_set, .ref_func, .table_get, .table_set,
            .call_ref, .return_call_ref,
            => _ = try reader.readU32(),
            .call_indirect, .return_call_indirect => { _ = try reader.readU32(); _ = try reader.readU32(); },
            .throw => _ = try reader.readU32(),
            .throw_ref => {},
            .try_table => {
                _ = try readBlockType(reader);
                const n_catches = try reader.readU32();
                for (0..n_catches) |_| {
                    const catch_kind = try reader.readByte();
                    if (catch_kind == 0x00 or catch_kind == 0x01) _ = try reader.readU32();
                    _ = try reader.readU32();
                }
                depth += 1;
            },
            .select_t => { const n = try reader.readU32(); for (0..n) |_| _ = try reader.readByte(); },
            .i32_const => _ = try reader.readI32(),
            .i64_const => _ = try reader.readI64(),
            .f32_const => _ = try reader.readBytes(4),
            .f64_const => _ = try reader.readBytes(8),
            .i32_load, .i64_load, .f32_load, .f64_load,
            .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u,
            .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u,
            .i64_load32_s, .i64_load32_u,
            .i32_store, .i64_store, .f32_store, .f64_store,
            .i32_store8, .i32_store16,
            .i64_store8, .i64_store16, .i64_store32,
            => {
                const align_flags = try reader.readU32();
                if (align_flags & 0x40 != 0) _ = try reader.readU32(); // memidx
                _ = try reader.readU32(); // offset
            },
            .memory_size, .memory_grow => _ = try reader.readU32(),
            .ref_null => _ = try reader.readI33(),
            .misc_prefix => {
                const sub = try reader.readU32();
                switch (sub) {
                    0x0A => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x0B => _ = try reader.readU32(),
                    0x08 => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x09 => _ = try reader.readU32(),
                    0x0C => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x0D => _ = try reader.readU32(),
                    0x0E => { _ = try reader.readU32(); _ = try reader.readU32(); },
                    0x0F => _ = try reader.readU32(),
                    0x10 => _ = try reader.readU32(),
                    0x11 => _ = try reader.readU32(),
                    else => {},
                }
            },
            .gc_prefix => skipGcImmediates(reader) catch return false,
            .simd_prefix => try skipSimdImmediates(reader),
            .atomic_prefix => try skipAtomicImmediates(reader),
            else => {},
        }
    }
    return found_else;
}

/// Skip GC instruction immediates when scanning bytecode (for skipToEnd/findElseOrEnd).
/// Read a heap type immediate (S33) and convert to u32 sentinel.
/// Negative values map to abstract heap types, non-negative to type indices.
fn readHeapType(reader: *Reader) ?u32 {
    const ht = reader.readI33() catch return null;
    if (ht >= 0) return @intCast(ht); // concrete type index
    return switch (ht) {
        -16 => opcode.ValType.HEAP_FUNC,
        -17 => opcode.ValType.HEAP_EXTERN,
        -18 => opcode.ValType.HEAP_ANY,
        -19 => opcode.ValType.HEAP_EQ,
        -20 => opcode.ValType.HEAP_I31,
        -21 => opcode.ValType.HEAP_STRUCT,
        -22 => opcode.ValType.HEAP_ARRAY,
        -15 => opcode.ValType.HEAP_NONE,
        -13 => opcode.ValType.HEAP_NOFUNC,
        -14 => opcode.ValType.HEAP_NOEXTERN,
        -24 => opcode.ValType.HEAP_EXN,
        -25 => opcode.ValType.HEAP_NOEXN,
        else => null,
    };
}

fn skipGcImmediates(reader: *Reader) !void {
    const sub = reader.readU32() catch return;
    switch (sub) {
        0x00, 0x01, 0x06, 0x07 => _ = reader.readU32() catch return, // typeidx
        0x02, 0x03, 0x04, 0x05 => { // struct.get/set: typeidx + fieldidx
            _ = reader.readU32() catch return;
            _ = reader.readU32() catch return;
        },
        0x08 => { _ = reader.readU32() catch return; _ = reader.readU32() catch return; }, // array.new_fixed
        0x09, 0x0A => { _ = reader.readU32() catch return; _ = reader.readU32() catch return; },
        0x0B, 0x0C, 0x0D, 0x0E => _ = reader.readU32() catch return, // array.get/set
        0x0F => {}, // array.len
        0x10 => _ = reader.readU32() catch return, // array.fill
        0x11 => { _ = reader.readU32() catch return; _ = reader.readU32() catch return; }, // array.copy
        0x12, 0x13 => { _ = reader.readU32() catch return; _ = reader.readU32() catch return; },
        0x14, 0x15 => _ = reader.readI33() catch return, // ref.test
        0x16, 0x17 => _ = reader.readI33() catch return, // ref.cast
        0x18, 0x19 => { // br_on_cast
            _ = reader.readByte() catch return;
            _ = reader.readU32() catch return;
            _ = reader.readI33() catch return;
            _ = reader.readI33() catch return;
        },
        0x1A, 0x1B, 0x1C, 0x1D, 0x1E => {}, // no immediates
        else => {},
    }
}

/// Skip SIMD instruction immediates when scanning bytecode (for skipToEnd/findElseOrEnd).
fn skipSimdImmediates(reader: *Reader) !void {
    const sub = try reader.readU32();
    switch (sub) {
        // Memory ops: memarg (align u32 [+ memidx u32] + offset u32)
        0x00...0x0B, 0x5C, 0x5D => {
            const align_flags = try reader.readU32();
            if (align_flags & 0x40 != 0) _ = try reader.readU32(); // memidx
            _ = try reader.readU32(); // offset
        },
        // v128.const: 16 raw bytes
        0x0C => _ = try reader.readBytes(16),
        // i8x16.shuffle: 16 lane indices
        0x0D => _ = try reader.readBytes(16),
        // Extract/replace lane: 1 byte lane index
        0x15...0x22 => _ = try reader.readByte(),
        // Lane load/store: memarg (align u32 [+ memidx u32] + offset u32) + 1 byte lane index
        0x54...0x5B => {
            const align_flags = try reader.readU32();
            if (align_flags & 0x40 != 0) _ = try reader.readU32(); // memidx
            _ = try reader.readU32(); // offset
            _ = try reader.readByte(); // lane
        },
        // All other ops: no immediates
        else => {},
    }
}

fn skipAtomicImmediates(reader: *Reader) !void {
    const sub = try reader.readU32();
    if (sub == 0x03) {
        // atomic.fence: reserved byte 0x00
        _ = try reader.readByte();
    } else {
        // All other atomic ops: memarg (align + offset)
        _ = try reader.readU32(); // align
        _ = try reader.readU32(); // offset
    }
}

/// Wasm nearest (round-to-even).
fn wasmNearest(comptime T: type, val: T) T {
    return roundToEven(T, val);
}

/// Wasm min (propagate NaN, handle -0).
fn wasmMin(comptime T: type, a: T, b: T) T {
    if (math.isNan(a)) return a;
    if (math.isNan(b)) return b;
    if (a == 0 and b == 0) {
        // -0 < +0 in wasm
        if (math.signbit(a) != math.signbit(b))
            return if (math.signbit(a)) a else b;
    }
    return @min(a, b);
}

/// Wasm max (propagate NaN, handle -0).
fn wasmMax(comptime T: type, a: T, b: T) T {
    if (math.isNan(a)) return a;
    if (math.isNan(b)) return b;
    if (a == 0 and b == 0) {
        if (math.signbit(a) != math.signbit(b))
            return if (math.signbit(a)) b else a;
    }
    return @max(a, b);
}

/// Truncate float to int, returning null for NaN/overflow (trapping version).
/// Uses power-of-2 bounds which are exactly representable in all float types.
fn truncSat(comptime I: type, comptime F: type, val: F) ?I {
    if (math.isNan(val)) return null;
    if (math.isInf(val)) return null;
    const trunc_val = @trunc(val);
    const info = @typeInfo(I).int;
    // Upper bound: 2^(N-1) for signed, 2^N for unsigned (exact power of 2)
    const upper: F = comptime blk: {
        const exp = if (info.signedness == .signed) info.bits - 1 else info.bits;
        var r: F = 1.0;
        for (0..exp) |_| r *= 2.0;
        break :blk r;
    };
    if (info.signedness == .signed) {
        if (trunc_val >= upper or trunc_val < -upper) return null;
    } else {
        if (trunc_val >= upper or trunc_val < 0.0) return null;
    }
    return @intFromFloat(trunc_val);
}

/// Truncate float to int with saturation (non-trapping version).
fn truncSatClamp(comptime I: type, comptime F: type, val: F) I {
    if (math.isNan(val)) return 0;
    const trunc_val = @trunc(val);
    const info = @typeInfo(I).int;
    const upper: F = comptime blk: {
        const exp = if (info.signedness == .signed) info.bits - 1 else info.bits;
        var r: F = 1.0;
        for (0..exp) |_| r *= 2.0;
        break :blk r;
    };
    if (info.signedness == .signed) {
        if (trunc_val >= upper) return math.maxInt(I);
        if (trunc_val < -upper) return math.minInt(I);
    } else {
        if (trunc_val >= upper) return math.maxInt(I);
        if (trunc_val < 0.0) return 0;
    }
    return @intFromFloat(trunc_val);
}

/// IEEE 754 roundToIntegralTiesToEven (Wasm nearest).
fn roundToEven(comptime T: type, x: T) T {
    if (math.isNan(x) or math.isInf(x) or x == 0) return x;
    const magic: T = switch (T) {
        f32 => 8388608.0, // 2^23
        f64 => 4503599627370496.0, // 2^52
        else => unreachable,
    };
    const ax = @abs(x);
    if (ax >= magic) return x;
    const result = if (x > 0) (x + magic) - magic else (x - magic) + magic;
    // Preserve sign: small negatives round to -0.0, not +0.0
    if (result == 0 and math.signbit(x)) return -result;
    return result;
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


test "VM — add(3, 4) = 7" {
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

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try vm.invoke(&inst, "add", &args, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "VM — add(100, -50) = 50" {
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

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{ 100, @bitCast(@as(i64, -50)) };
    var results = [_]u64{0};
    try vm.invoke(&inst, "add", &args, &results);
    // i32 wrapping: 100 + (-50) = 50
    try testing.expectEqual(@as(u32, 50), @as(u32, @truncate(results[0])));
}

test "VM — fib(10) = 55" {
    const wasm = try readTestFile(testing.allocator, "02_fibonacci.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{10};
    var results = [_]u64{0};
    try vm.invoke(&inst, "fib", &args, &results);
    try testing.expectEqual(@as(u64, 55), results[0]);
}

test "VM — memory store/load" {
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

    var vm = Vm.init(testing.allocator);

    // store(0, 42)
    var store_args = [_]u64{ 0, 42 };
    var store_results = [_]u64{};
    try vm.invoke(&inst, "store", &store_args, &store_results);

    // load(0) should be 42
    var load_args = [_]u64{0};
    var load_results = [_]u64{0};
    try vm.invoke(&inst, "load", &load_args, &load_results);
    try testing.expectEqual(@as(u64, 42), load_results[0]);
}

test "VM — globals" {
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

    var vm = Vm.init(testing.allocator);

    // Test get_counter and increment
    var args = [_]u64{};
    var results = [_]u64{0};
    try vm.invoke(&inst, "get_counter", &args, &results);
    const initial = results[0];

    try vm.invoke(&inst, "increment", &args, &results);
    try vm.invoke(&inst, "get_counter", &args, &results);
    try testing.expectEqual(initial + 1, results[0]);
}

test "VM — memory sum_range (loop branch)" {
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

    var vm = Vm.init(testing.allocator);

    // Store values: mem[100]=10, mem[104]=20, mem[108]=30
    var s1 = [_]u64{ 100, 10 };
    var s2 = [_]u64{ 104, 20 };
    var s3 = [_]u64{ 108, 30 };
    var no_results = [_]u64{};
    try vm.invoke(&inst, "store", &s1, &no_results);
    try vm.invoke(&inst, "store", &s2, &no_results);
    try vm.invoke(&inst, "store", &s3, &no_results);

    // sum_range(100, 3) should return 60
    var sum_args = [_]u64{ 100, 3 };
    var sum_results = [_]u64{0};
    try vm.invoke(&inst, "sum_range", &sum_args, &sum_results);
    try testing.expectEqual(@as(u64, 60), sum_results[0]);
}

test "VM — table indirect call" {
    const wasm = try readTestFile(testing.allocator, "05_table_indirect_call.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);

    // dispatch(0, 10, 20) — calls function at table[0]
    var args0 = [_]u64{ 0, 10, 20 };
    var results = [_]u64{0};
    try vm.invoke(&inst, "dispatch", &args0, &results);
    const r0 = @as(u32, @truncate(results[0]));

    // dispatch(1, 10, 20) — calls function at table[1]
    var args1 = [_]u64{ 1, 10, 20 };
    try vm.invoke(&inst, "dispatch", &args1, &results);
    const r1 = @as(u32, @truncate(results[0]));

    // Two different functions should return different results (add vs sub)
    try testing.expect(r0 != r1);
}

test "VM — multi-value return" {
    const wasm = try readTestFile(testing.allocator, "08_multi_value.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);

    // swap(10, 20) should return (20, 10)
    var args = [_]u64{ 10, 20 };
    var results = [_]u64{ 0, 0 };
    try vm.invoke(&inst, "swap", &args, &results);
    try testing.expectEqual(@as(u64, 20), results[0]);
    try testing.expectEqual(@as(u64, 10), results[1]);
}

test "VM — host function imports" {
    const alloc = testing.allocator;
    const wasm = try readTestFile(alloc, "04_imports.wasm");
    defer alloc.free(wasm);

    var mod = Module.init(alloc, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(alloc);
    defer store.deinit();

    // Stub host functions — pop args from the Vm operand stack
    const stub_i32 = struct {
        fn f(ctx: *anyopaque, _: usize) anyerror!void {
            const vm_inner: *Vm = @ptrCast(@alignCast(ctx));
            _ = vm_inner.popOperand(); // value
        }
    }.f;

    const stub_i32_i32 = struct {
        fn f(ctx: *anyopaque, _: usize) anyerror!void {
            const vm_inner: *Vm = @ptrCast(@alignCast(ctx));
            _ = vm_inner.popOperand(); // len
            _ = vm_inner.popOperand(); // offset
        }
    }.f;

    try store.exposeHostFunction("env", "print_i32", &stub_i32, 0,
        &.{.i32}, &.{});
    try store.exposeHostFunction("env", "print_str", &stub_i32_i32, 0,
        &.{ .i32, .i32 }, &.{});

    var inst = Instance.init(alloc, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm_inst = Vm.init(alloc);

    // greet() should succeed (calls print_str host function)
    var no_args = [_]u64{};
    var no_results = [_]u64{};
    try vm_inst.invoke(&inst, "greet", &no_args, &no_results);

    // compute_and_print(10, 20) should succeed
    var compute_args = [_]u64{ 10, 20 };
    try vm_inst.invoke(&inst, "compute_and_print", &compute_args, &no_results);
}

test "VM — fib(20) = 6765" {
    const wasm = try readTestFile(testing.allocator, "02_fibonacci.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{20};
    var results = [_]u64{0};
    try vm.invoke(&inst, "fib", &args, &results);
    try testing.expectEqual(@as(u64, 6765), results[0]);
}

// --- Conformance tests ---

test "Conformance — block control flow" {
    const wasm = try readTestFile(testing.allocator, "conformance/block.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // block_result: returns 42
    try vm.invoke(&inst, "block_result", &.{}, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);

    // nested_br: param=0 → falls through inner block, drop, return 20
    var args0 = [_]u64{0};
    try vm.invoke(&inst, "nested_br", &args0, &results);
    try testing.expectEqual(@as(u64, 20), results[0]);

    // nested_br: param=1 → br_if 1 jumps to outer with value 99
    var args1 = [_]u64{1};
    try vm.invoke(&inst, "nested_br", &args1, &results);
    try testing.expectEqual(@as(u64, 99), results[0]);

    // loop_sum: sum(10) = 55
    var args10 = [_]u64{10};
    try vm.invoke(&inst, "loop_sum", &args10, &results);
    try testing.expectEqual(@as(u64, 55), results[0]);

    // if_else: true → 1, false → 0
    try vm.invoke(&inst, "if_else", &args1, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);
    try vm.invoke(&inst, "if_else", &args0, &results);
    try testing.expectEqual(@as(u64, 0), results[0]);
}

test "Conformance — i32 arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/i32_arith.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // add(7, 3) = 10
    var args_add = [_]u64{ 7, 3 };
    try vm.invoke(&inst, "add", &args_add, &results);
    try testing.expectEqual(@as(u64, 10), results[0]);

    // sub(10, 4) = 6
    var args_sub = [_]u64{ 10, 4 };
    try vm.invoke(&inst, "sub", &args_sub, &results);
    try testing.expectEqual(@as(u64, 6), results[0]);

    // mul(6, 7) = 42
    var args_mul = [_]u64{ 6, 7 };
    try vm.invoke(&inst, "mul", &args_mul, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);

    // div_s(-10, 3) = -3 (signed)
    var args_divs = [_]u64{ @bitCast(@as(i64, -10)), 3 };
    try vm.invoke(&inst, "div_s", &args_divs, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -3))), @as(u32, @truncate(results[0])));

    // div_u(10, 3) = 3 (unsigned)
    var args_divu = [_]u64{ 10, 3 };
    try vm.invoke(&inst, "div_u", &args_divu, &results);
    try testing.expectEqual(@as(u64, 3), results[0]);

    // rem_s(10, 3) = 1
    var args_rem = [_]u64{ 10, 3 };
    try vm.invoke(&inst, "rem_s", &args_rem, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // clz(1) = 31
    var args_clz = [_]u64{1};
    try vm.invoke(&inst, "clz", &args_clz, &results);
    try testing.expectEqual(@as(u64, 31), results[0]);

    // ctz(0x80) = 7
    var args_ctz = [_]u64{0x80};
    try vm.invoke(&inst, "ctz", &args_ctz, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);

    // popcnt(0xFF) = 8
    var args_pop = [_]u64{0xFF};
    try vm.invoke(&inst, "popcnt", &args_pop, &results);
    try testing.expectEqual(@as(u64, 8), results[0]);

    // rotl(0x80000001, 1) = 0x00000003
    var args_rotl = [_]u64{ 0x80000001, 1 };
    try vm.invoke(&inst, "rotl", &args_rotl, &results);
    try testing.expectEqual(@as(u64, 0x00000003), results[0]);

    // rotr(0x80000001, 1) = 0xC0000000
    var args_rotr = [_]u64{ 0x80000001, 1 };
    try vm.invoke(&inst, "rotr", &args_rotr, &results);
    try testing.expectEqual(@as(u64, 0xC0000000), results[0]);
}

test "Conformance — i64 arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/i64_arith.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // add
    var args_add = [_]u64{ 100, 200 };
    try vm.invoke(&inst, "add", &args_add, &results);
    try testing.expectEqual(@as(u64, 300), results[0]);

    // sub
    var args_sub = [_]u64{ 500, 200 };
    try vm.invoke(&inst, "sub", &args_sub, &results);
    try testing.expectEqual(@as(u64, 300), results[0]);

    // mul
    var args_mul = [_]u64{ 1000000, 1000000 };
    try vm.invoke(&inst, "mul", &args_mul, &results);
    try testing.expectEqual(@as(u64, 1000000000000), results[0]);

    // div_s(-100, 3) = -33
    var args_divs = [_]u64{@bitCast(@as(i64, -100)), 3};
    try vm.invoke(&inst, "div_s", &args_divs, &results);
    try testing.expectEqual(@as(i64, -33), @as(i64, @bitCast(results[0])));

    // clz(1) = 63
    var args_clz = [_]u64{1};
    try vm.invoke(&inst, "clz", &args_clz, &results);
    try testing.expectEqual(@as(u64, 63), results[0]);

    // popcnt(0xFF) = 8
    var args_pop = [_]u64{0xFF};
    try vm.invoke(&inst, "popcnt", &args_pop, &results);
    try testing.expectEqual(@as(u64, 8), results[0]);

    // eqz(0) = 1, eqz(5) = 0
    var args_eqz0 = [_]u64{0};
    try vm.invoke(&inst, "eqz", &args_eqz0, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);
    var args_eqz5 = [_]u64{5};
    try vm.invoke(&inst, "eqz", &args_eqz5, &results);
    try testing.expectEqual(@as(u64, 0), results[0]);
}

test "Conformance — f64 arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/f64_arith.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // add(1.5, 2.5) = 4.0
    var args_add = [_]u64{ @bitCast(@as(f64, 1.5)), @bitCast(@as(f64, 2.5)) };
    try vm.invoke(&inst, "add", &args_add, &results);
    try testing.expectEqual(@as(f64, 4.0), @as(f64, @bitCast(results[0])));

    // mul(3.0, 4.0) = 12.0
    var args_mul = [_]u64{ @bitCast(@as(f64, 3.0)), @bitCast(@as(f64, 4.0)) };
    try vm.invoke(&inst, "mul", &args_mul, &results);
    try testing.expectEqual(@as(f64, 12.0), @as(f64, @bitCast(results[0])));

    // sqrt(9.0) = 3.0
    var args_sqrt = [_]u64{@bitCast(@as(f64, 9.0))};
    try vm.invoke(&inst, "sqrt", &args_sqrt, &results);
    try testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(results[0])));

    // min(3.0, 5.0) = 3.0
    var args_min = [_]u64{ @bitCast(@as(f64, 3.0)), @bitCast(@as(f64, 5.0)) };
    try vm.invoke(&inst, "min", &args_min, &results);
    try testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(results[0])));

    // max(3.0, 5.0) = 5.0
    var args_max = [_]u64{ @bitCast(@as(f64, 3.0)), @bitCast(@as(f64, 5.0)) };
    try vm.invoke(&inst, "max", &args_max, &results);
    try testing.expectEqual(@as(f64, 5.0), @as(f64, @bitCast(results[0])));

    // floor(3.7) = 3.0
    var args_floor = [_]u64{@bitCast(@as(f64, 3.7))};
    try vm.invoke(&inst, "floor", &args_floor, &results);
    try testing.expectEqual(@as(f64, 3.0), @as(f64, @bitCast(results[0])));

    // ceil(3.2) = 4.0
    var args_ceil = [_]u64{@bitCast(@as(f64, 3.2))};
    try vm.invoke(&inst, "ceil", &args_ceil, &results);
    try testing.expectEqual(@as(f64, 4.0), @as(f64, @bitCast(results[0])));

    // abs(-5.0) = 5.0
    var args_abs = [_]u64{@bitCast(@as(f64, -5.0))};
    try vm.invoke(&inst, "abs", &args_abs, &results);
    try testing.expectEqual(@as(f64, 5.0), @as(f64, @bitCast(results[0])));

    // neg(5.0) = -5.0
    var args_neg = [_]u64{@bitCast(@as(f64, 5.0))};
    try vm.invoke(&inst, "neg", &args_neg, &results);
    try testing.expectEqual(@as(f64, -5.0), @as(f64, @bitCast(results[0])));
}

test "Conformance — type conversions" {
    const wasm = try readTestFile(testing.allocator, "conformance/conversions.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // i64_extend_i32_s(-1) = -1 as i64
    var args_ext_s = [_]u64{@bitCast(@as(i64, -1))};
    try vm.invoke(&inst, "i64_extend_i32_s", &args_ext_s, &results);
    try testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(results[0])));

    // i64_extend_i32_u(0xFFFFFFFF) = 0xFFFFFFFF as u64
    var args_ext_u = [_]u64{0xFFFFFFFF};
    try vm.invoke(&inst, "i64_extend_i32_u", &args_ext_u, &results);
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), results[0]);

    // i32_wrap_i64(0x100000042) = 0x42
    var args_wrap = [_]u64{0x100000042};
    try vm.invoke(&inst, "i32_wrap_i64", &args_wrap, &results);
    try testing.expectEqual(@as(u64, 0x42), results[0]);

    // f64_convert_i32_s(-42) = -42.0
    var args_cvt = [_]u64{@bitCast(@as(i64, -42))};
    try vm.invoke(&inst, "f64_convert_i32_s", &args_cvt, &results);
    try testing.expectEqual(@as(f64, -42.0), @as(f64, @bitCast(results[0])));

    // i32_trunc_f64_s(3.9) = 3
    var args_trunc = [_]u64{@bitCast(@as(f64, 3.9))};
    try vm.invoke(&inst, "i32_trunc_f64_s", &args_trunc, &results);
    try testing.expectEqual(@as(u64, 3), results[0]);

    // f32_reinterpret_i32(0x40490FDB) ≈ pi
    var args_reint = [_]u64{0x40490FDB};
    try vm.invoke(&inst, "f32_reinterpret_i32", &args_reint, &results);
    const f32_val: f32 = @bitCast(@as(u32, @truncate(results[0])));
    try testing.expect(@abs(f32_val - 3.14159265) < 0.001);
}

test "Conformance — sign extension (Wasm 2.0)" {
    const wasm = try readTestFile(testing.allocator, "conformance/sign_extension.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // i32_extend8_s(0x80) = -128 (sign-extend from bit 7)
    var args_8s = [_]u64{0x80};
    try vm.invoke(&inst, "i32_extend8_s", &args_8s, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -128))), @as(u32, @truncate(results[0])));

    // i32_extend8_s(0x7F) = 127
    var args_7f = [_]u64{0x7F};
    try vm.invoke(&inst, "i32_extend8_s", &args_7f, &results);
    try testing.expectEqual(@as(u64, 127), results[0]);

    // i32_extend16_s(0x8000) = -32768
    var args_16s = [_]u64{0x8000};
    try vm.invoke(&inst, "i32_extend16_s", &args_16s, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -32768))), @as(u32, @truncate(results[0])));

    // i64_extend8_s(0xFF) = -1
    var args_i64_8s = [_]u64{0xFF};
    try vm.invoke(&inst, "i64_extend8_s", &args_i64_8s, &results);
    try testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(results[0])));

    // i64_extend32_s(0xFFFFFFFF) = -1
    var args_i64_32s = [_]u64{0xFFFFFFFF};
    try vm.invoke(&inst, "i64_extend32_s", &args_i64_32s, &results);
    try testing.expectEqual(@as(i64, -1), @as(i64, @bitCast(results[0])));
}

test "Conformance — memory operations" {
    const wasm = try readTestFile(testing.allocator, "conformance/memory_ops.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // i32 store+load
    var args_i32 = [_]u64{ 0, 12345 };
    try vm.invoke(&inst, "i32_store_load", &args_i32, &results);
    try testing.expectEqual(@as(u64, 12345), results[0]);

    // i64 store+load
    var args_i64 = [_]u64{ 8, 0xDEADBEEFCAFE };
    try vm.invoke(&inst, "i64_store_load", &args_i64, &results);
    try testing.expectEqual(@as(u64, 0xDEADBEEFCAFE), results[0]);

    // i32.store8 + i32.load8_u: 0xFF → 255
    var args_8u = [_]u64{ 16, 0xFF };
    try vm.invoke(&inst, "i32_store8_load8_u", &args_8u, &results);
    try testing.expectEqual(@as(u64, 255), results[0]);

    // i32.store8 + i32.load8_s: 0xFF → -1 (sign-extended)
    var args_8s = [_]u64{ 17, 0xFF };
    try vm.invoke(&inst, "i32_store8_load8_s", &args_8s, &results);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), @as(u32, @truncate(results[0])));

    // memory_size = 1 (one page)
    try vm.invoke(&inst, "memory_size", &.{}, &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // memory_grow(2) returns old size 1, new size 3
    var args_grow = [_]u64{2};
    try vm.invoke(&inst, "memory_grow", &args_grow, &results);
    try testing.expectEqual(@as(u64, 1), results[0]); // old size
    try vm.invoke(&inst, "memory_size", &.{}, &results);
    try testing.expectEqual(@as(u64, 3), results[0]); // new size
}

test "Conformance — bulk memory (Wasm 2.0)" {
    const wasm = try readTestFile(testing.allocator, "conformance/bulk_memory.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};

    // memory.fill: fill 4 bytes at offset 0 with value 0xAB
    var args_fill = [_]u64{ 0, 0xAB, 4 };
    try vm.invoke(&inst, "memory_fill", &args_fill, &.{});

    // verify: load i32 at offset 0 = 0xABABABAB
    var args_load = [_]u64{0};
    try vm.invoke(&inst, "load_i32", &args_load, &results);
    try testing.expectEqual(@as(u64, 0xABABABAB), results[0]);

    // store at offset 16: 0xDEADBEEF
    var args_store = [_]u64{ 16, 0xDEADBEEF };
    try vm.invoke(&inst, "store_i32", &args_store, &.{});

    // memory.copy: copy 4 bytes from offset 16 to offset 32
    var args_copy = [_]u64{ 32, 16, 4 };
    try vm.invoke(&inst, "memory_copy", &args_copy, &.{});

    // verify: load i32 at offset 32 = 0xDEADBEEF
    var args_load32 = [_]u64{32};
    try vm.invoke(&inst, "load_i32", &args_load32, &results);
    try testing.expectEqual(@as(u64, 0xDEADBEEF), results[0]);
}

test "Conformance — SIMD basic" {
    const wasm = try readTestFile(testing.allocator, "conformance/simd_basic.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};
    const no_args = [_]u64{};

    // v128.const + i32x4.extract_lane 0 = 42
    try vm.invoke(&inst, "const_extract", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 42), results[0]);

    // v128.const + i32x4.extract_lane 2 = 30
    try vm.invoke(&inst, "const_extract_lane2", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 30), results[0]);

    // i32x4.splat(7) + extract_lane 0 = 7
    var args_splat = [_]u64{7};
    try vm.invoke(&inst, "splat_i32", &args_splat, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);

    // i8x16.splat(0xAB) + extract_lane_u 5 = 0xAB
    var args_i8 = [_]u64{0xAB};
    try vm.invoke(&inst, "splat_i8", &args_i8, &results);
    try testing.expectEqual(@as(u64, 0xAB), results[0]);

    // v128.store + v128.load roundtrip, lane 1 = 200
    try vm.invoke(&inst, "store_load", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 200), results[0]);

    // v128.not(0) = all 1s, extract byte 0 = 255
    try vm.invoke(&inst, "v128_not", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 255), results[0]);

    // v128.and(0xFF00FF, 0x00FFFF) = 0x0000FF
    try vm.invoke(&inst, "v128_and", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0x0000FF), results[0]);

    // v128.or(0xF0, 0x0F) = 0xFF
    try vm.invoke(&inst, "v128_or", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0xFF), results[0]);

    // v128.xor(0xFF, 0x0F) = 0xF0
    try vm.invoke(&inst, "v128_xor", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0xF0), results[0]);

    // v128.any_true(0,0,1,0) = 1
    try vm.invoke(&inst, "any_true_yes", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // v128.any_true(0,0,0,0) = 0
    try vm.invoke(&inst, "any_true_no", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0), results[0]);

    // i8x16.shuffle — swap first two bytes: 0x01,0x02,0x03,0x04 → byte 0 = 0x02
    try vm.invoke(&inst, "shuffle_swap", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0x02), results[0]);

    // i32x4.replace_lane 2 with 999, extract lane 2 = 999
    try vm.invoke(&inst, "replace_lane", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 999), results[0]);

    // v128.load32_zero: lane 1 should be 0 (only lane 0 loaded)
    try vm.invoke(&inst, "load32_zero", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0), results[0]);

    // v128.load8_splat: byte 7 at offset 0, splat to all lanes, extract lane 15 = 7
    try vm.invoke(&inst, "load8_splat", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "Conformance — SIMD integer arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/simd_integer.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};
    const no_args = [_]u64{};

    // i32x4.eq: lane 0 matches → -1 (all ones)
    try vm.invoke(&inst, "i32x4_eq", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, 0xFFFFFFFF)), results[0]);

    // i32x4.lt_s: -1 < 0 → -1
    try vm.invoke(&inst, "i32x4_lt_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, 0xFFFFFFFF)), results[0]);

    // i8x16.add: 0x64 + 0x01 = 0x65 = 101
    try vm.invoke(&inst, "i8x16_add", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 101), results[0]);

    // i16x8.mul: 10 * 3 = 30
    try vm.invoke(&inst, "i16x8_mul", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 30), results[0]);

    // i8x16.add_sat_s: 120 + 120 saturated = 127
    try vm.invoke(&inst, "i8x16_add_sat_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 127), results[0]);

    // i32x4.shl: 1 << 2 = 4
    try vm.invoke(&inst, "i32x4_shl", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 4), results[0]);

    // i32x4.shr_s: -8 >> 1 = -4
    try vm.invoke(&inst, "i32x4_shr_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -4)))), results[0]);

    // i32x4.abs: |-5| = 5
    try vm.invoke(&inst, "i32x4_abs", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 5), results[0]);

    // i32x4.neg: -(5) = -5
    try vm.invoke(&inst, "i32x4_neg", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -5)))), results[0]);

    // i8x16.min_s: min(10, 20) = 10
    try vm.invoke(&inst, "i8x16_min_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 10), results[0]);

    // i32x4.max_s: max(10, 20) = 20
    try vm.invoke(&inst, "i32x4_max_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 20), results[0]);

    // i16x8.narrow_i32x4_s: 32768 saturated to i16 → 32767
    try vm.invoke(&inst, "narrow_sat", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 32767), results[0]);

    // i32x4.extend_low_i16x8_s: -5 sign-extended to i32
    try vm.invoke(&inst, "extend_low_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -5)))), results[0]);

    // i32x4.extmul_low_i16x8_s: -10 * 5 = -50
    try vm.invoke(&inst, "extmul_low_s", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -50)))), results[0]);

    // i32x4.dot_i16x8_s: 1*2 + 3*4 = 14
    try vm.invoke(&inst, "dot_product", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 14), results[0]);

    // i8x16.all_true: all non-zero → 1
    try vm.invoke(&inst, "all_true_yes", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // i8x16.all_true: has zero → 0
    try vm.invoke(&inst, "all_true_no", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 0), results[0]);

    // i32x4.bitmask: (-1, 0, -1, 0) → 0b0101 = 5
    try vm.invoke(&inst, "bitmask", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 5), results[0]);

    // i8x16.popcnt: popcount(0xFF) = 8
    try vm.invoke(&inst, "popcnt", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 8), results[0]);

    // i16x8.extadd_pairwise: (-1) + 2 = 1
    try vm.invoke(&inst, "extadd_pairwise", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 1), results[0]);

    // i8x16.avgr_u: (10 + 20 + 1) / 2 = 15 (truncated)
    try vm.invoke(&inst, "avgr_u", @constCast(&no_args), &results);
    try testing.expectEqual(@as(u64, 15), results[0]);
}

test "Conformance — SIMD float arithmetic" {
    const wasm = try readTestFile(testing.allocator, "conformance/simd_float.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    const no_args = [_]u64{};

    // f32 results use bit comparison via u64
    var r64 = [_]u64{0};

    // f32x4.add: 1.5 + 0.5 = 2.0
    try vm.invoke(&inst, "f32x4_add", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f64x2.mul: 2.0 * 4.0 = 8.0
    try vm.invoke(&inst, "f64x2_mul", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 8.0))), r64[0]);

    // f32x4.eq: 1.0 == 1.0 → all-ones (0xFFFFFFFF)
    try vm.invoke(&inst, "f32x4_eq", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, 0xFFFFFFFF), r64[0]);

    // f32x4.abs: |-1.5| = 1.5
    try vm.invoke(&inst, "f32x4_abs", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.5)))), r64[0]);

    // f32x4.neg: -(1.0) = -1.0
    try vm.invoke(&inst, "f32x4_neg", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, -1.0)))), r64[0]);

    // f32x4.sqrt: sqrt(4.0) = 2.0
    try vm.invoke(&inst, "f32x4_sqrt", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.ceil: ceil(1.3) = 2.0
    try vm.invoke(&inst, "f32x4_ceil", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.floor: floor(1.7) = 1.0
    try vm.invoke(&inst, "f32x4_floor", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.0)))), r64[0]);

    // f32x4.nearest: nearest(2.5) = 2.0 (round to even)
    try vm.invoke(&inst, "f32x4_nearest", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.min: min(1.0, 2.0) = 1.0
    try vm.invoke(&inst, "f32x4_min", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.0)))), r64[0]);

    // f32x4.max: max(1.0, 2.0) = 2.0
    try vm.invoke(&inst, "f32x4_max", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 2.0)))), r64[0]);

    // f32x4.pmin: pmin(3.0, 1.0) = 1.0
    try vm.invoke(&inst, "f32x4_pmin", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 1.0)))), r64[0]);

    // i32x4.trunc_sat_f32x4_s: trunc(2.9) = 2
    try vm.invoke(&inst, "trunc_sat_s", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, 2), r64[0]);

    // f32x4.convert_i32x4_s: convert(42) = 42.0
    try vm.invoke(&inst, "convert_s", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 42.0)))), r64[0]);

    // f32x4.demote: lane 2 = 0.0 (zero-padded)
    try vm.invoke(&inst, "demote", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(f32, 0.0)))), r64[0]);

    // f64x2.promote_low_f32x4: promote(1.5f) ≈ 1.5
    try vm.invoke(&inst, "promote", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, 1.5))), r64[0]);

    // f64x2.convert_low_i32x4_s: convert(-7) = -7.0
    try vm.invoke(&inst, "f64_convert_s", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -7.0))), r64[0]);

    // i32x4.trunc_sat_f64x2_s_zero: lane 2 = 0 (zero-padded)
    try vm.invoke(&inst, "trunc_f64_zero", @constCast(&no_args), &r64);
    try testing.expectEqual(@as(u64, 0), r64[0]);
}

test "Profile — fib(10) opcode counting" {
    const wasm = try readTestFile(testing.allocator, "02_fibonacci.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var profile = Profile.init();
    var vm = Vm.init(testing.allocator);
    vm.profile = &profile;

    var args = [_]u64{10};
    var results = [_]u64{0};
    try vm.invoke(&inst, "fib", &args, &results);
    try testing.expectEqual(@as(u64, 55), results[0]);

    // Profiling data should be populated
    try testing.expect(profile.total_instrs > 0);
    try testing.expect(profile.call_count > 0); // fib is recursive

    // In register IR: i32.add (0x6A) or i32.sub (0x6B) or their fused forms (0xD0/0xD1)
    try testing.expect(profile.opcode_counts[0x6A] > 0 or profile.opcode_counts[0x6B] > 0 or
        profile.opcode_counts[0xD0] > 0 or profile.opcode_counts[0xD1] > 0);
}

test "Tiered — back-edge counting triggers JIT for single-call loop function" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    // sieve(100) is called once but has a hot inner loop.
    // Back-edge counting should trigger JIT mid-execution and restart via JIT.
    const wasm = blk: {
        const prefixes = [_][]const u8{ "bench/wasm/", "../bench/wasm/" };
        for (prefixes) |prefix| {
            const path = try std.fmt.allocPrint(testing.allocator, "{s}sieve.wasm", .{prefix});
            defer testing.allocator.free(path);
            const file = std.fs.cwd().openFile(path, .{}) catch continue;
            defer file.close();
            const stat = try file.stat();
            const data = try testing.allocator.alloc(u8, stat.size);
            const read = try file.readAll(data);
            break :blk data[0..read];
        }
        return error.SkipZigTest; // sieve.wasm not found
    };
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);

    // Get the function pointer to check JIT state
    const func_addr = inst.getExportFunc("sieve") orelse return error.FunctionIndexOutOfBounds;
    const func_ptr = try inst.store.getFunctionPtr(func_addr);

    const wf = &func_ptr.subtype.wasm_function;

    // Before: no JIT code, call_count = 0
    try testing.expect(wf.jit_code == null);
    try testing.expectEqual(@as(u32, 0), wf.call_count);

    // Single call — sieve(10000) has enough loop iterations to trigger back-edge JIT
    var args = [_]u64{10000};
    var results = [_]u64{0};
    try vm.invoke(&inst, "sieve", &args, &results);

    // sieve(10000) should return 1229 (primes up to 10000)
    try testing.expectEqual(@as(u64, 1229), results[0]);

    // reg_ir should have been created (lazy conversion)
    try testing.expect(wf.reg_ir != null);

    // After single call: JIT should have been triggered by back-edge counting
    try testing.expect(wf.jit_code != null);
}

test "Tiered — JIT-to-JIT fast path for recursive calls" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    // fib(20) = 6765, involves ~21891 recursive calls.
    // With HOT_THRESHOLD=10, JIT kicks in early. The fast JIT-to-JIT path
    // should handle most of the recursive calls without going through callFunction.
    const wasm = try readTestFile(testing.allocator, "02_fibonacci.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);

    var args = [_]u64{20};
    var results = [_]u64{0};
    try vm.invoke(&inst, "fib", &args, &results);
    try testing.expectEqual(@as(u64, 6765), results[0]);

    // Verify fib was JIT compiled
    const func_addr = inst.getExportFunc("fib") orelse return error.FunctionIndexOutOfBounds;
    const func_ptr = try inst.store.getFunctionPtr(func_addr);
    try testing.expect(func_ptr.subtype.wasm_function.jit_code != null);
}

test "Profile — disabled by default (no overhead)" {
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

    var vm = Vm.init(testing.allocator);
    // profile is null by default
    try testing.expect(vm.profile == null);

    var args = [_]u64{ 3, 4 };
    var results = [_]u64{0};
    try vm.invoke(&inst, "add", &args, &results);
    try testing.expectEqual(@as(u64, 7), results[0]);
}

test "Exception — simple throw and catch" {
    // Module: 2 types, 1 tag(type=0), 1 func(type=1 -> i32):
    //   block void
    //     try_table (result i32) (catch tag=0 label=0)
    //       throw tag=0
    //       i32.const 42  (dead code)
    //     end
    //     return
    //   end
    //   i32.const 23
    //   end
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        // Type section (id=1)
        0x01, 0x08,
        0x02, // 2 types
        0x60, 0x00, 0x00, // type[0]: () -> ()
        0x60, 0x00, 0x01, 0x7f, // type[1]: () -> (i32)
        // Function section (id=3)
        0x03, 0x02, 0x01, 0x01, // 1 function, type index 1
        // Tag section (id=13)
        0x0d, 0x03, 0x01, 0x00, 0x00, // 1 tag, attr=0, type_idx=0
        // Export section (id=7)
        0x07, 0x08, 0x01, // 1 export
        0x04, 0x74, 0x65, 0x73, 0x74, // name "test"
        0x00, 0x00, // func export, index 0
        // Code section (id=10)
        0x0a, 0x15, 0x01, // 1 body
        0x13, // body size = 19 bytes
        0x00, // 0 locals
        // block void
        0x02, 0x40,
        // try_table (result i32) 1 catch: kind=0x00, tag=0, label=0
        0x1f, 0x7f, 0x01, 0x00, 0x00, 0x00,
        // throw tag=0
        0x08, 0x00,
        // i32.const 42 (dead code for type validation)
        0x41, 0x2a,
        // end (try_table)
        0x0b,
        // return
        0x0f,
        // end (block)
        0x0b,
        // i32.const 23
        0x41, 0x17,
        // end (function)
        0x0b,
    };

    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};
    try vm.invoke(&inst, "test", &.{}, &results);
    try testing.expectEqual(@as(u64, 23), results[0]);
}

test "Exception — cross-function throw with i32 param" {
    // Module: tag $e(i32), func $do_throw(i32) { throw $e(local.get 0) },
    //         func "test"(i32)(i32) {
    //           block (result i32) {
    //             try_table (result i32) (catch $e label=0) {
    //               call $do_throw(local.get 0)
    //               i32.const 0
    //             }
    //             return
    //           }
    //         }
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        // Type section (id=1)
        0x01, 0x0d,
        0x03, // 3 types
        0x60, 0x01, 0x7f, 0x00, // type[0]: (i32) -> ()  [tag type + $do_throw]
        0x60, 0x01, 0x7f, 0x01, 0x7f, // type[1]: (i32) -> (i32)  ["test"]
        0x60, 0x00, 0x00, // type[2]: () -> ()
        // Function section (id=3)
        0x03, 0x03, 0x02, 0x00, 0x01, // 2 functions: type 0, type 1
        // Tag section (id=13)
        0x0d, 0x03, 0x01, 0x00, 0x00, // 1 tag, attr=0, type_idx=0 (i32)->()
        // Export section (id=7)
        0x07, 0x08, 0x01, // 1 export
        0x04, 0x74, 0x65, 0x73, 0x74, // name "test"
        0x00, 0x01, // func export, index 1
        // Code section (id=10, size=28)
        0x0a, 0x1c, 0x02, // 2 bodies
        // Body 0: $do_throw — size=6
        0x06, 0x00, // size=6, 0 locals
        0x20, 0x00, // local.get 0
        0x08, 0x00, // throw tag=0
        0x0b, // end
        // Body 1: "test" — size=19
        0x13, 0x00, // size=19, 0 locals
        // block (result i32)
        0x02, 0x7f,
        // try_table (result i32) 1 catch: kind=0x00, tag=0, label=0
        0x1f, 0x7f, 0x01, 0x00, 0x00, 0x00,
        // local.get 0
        0x20, 0x00,
        // call $do_throw (func 0)
        0x10, 0x00,
        // i32.const 0 (dead code)
        0x41, 0x00,
        // end (try_table)
        0x0b,
        // return
        0x0f,
        // end (block)
        0x0b,
        // end (function)
        0x0b,
    };

    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var args = [_]u64{42};
    var results = [_]u64{0};
    try vm.invoke(&inst, "test", &args, &results);
    try testing.expectEqual(@as(u64, 42), results[0]);
}

test "Wide arithmetic — i64.add128" {
    // Module: func "test"(i64 i64 i64 i64)(i64 i64) {
    //   local.get 0; local.get 1; local.get 2; local.get 3; i64.add128
    // }
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, // magic + version
        // Type section: (i64 i64 i64 i64) -> (i64 i64)
        0x01, 0x0a, 0x01, 0x60, 0x04, 0x7e, 0x7e, 0x7e, 0x7e, 0x02, 0x7e, 0x7e,
        // Function section: 1 func, type 0
        0x03, 0x02, 0x01, 0x00,
        // Export section: "test" -> func 0
        0x07, 0x08, 0x01, 0x04, 0x74, 0x65, 0x73, 0x74, 0x00, 0x00,
        // Code section: local.get 0-3, i64.add128 (0xFC 0x13), end
        0x0a, 0x0e, 0x01, 0x0c, 0x00,
        0x20, 0x00, 0x20, 0x01, 0x20, 0x02, 0x20, 0x03,
        0xfc, 0x13, 0x0b,
    };

    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);

    // Test: 1 + 0 = 1 (lo=1, hi=0, lo=0, hi=0)
    var args1 = [_]u64{ 1, 0, 0, 0 };
    var results1 = [_]u64{ 0, 0 };
    try vm.invoke(&inst, "test", &args1, &results1);
    try testing.expectEqual(@as(u64, 1), results1[0]); // lo
    try testing.expectEqual(@as(u64, 0), results1[1]); // hi

    // Test: carry: lo=0xFFFFFFFFFFFFFFFF + lo=1 = (0, 1)
    var args2 = [_]u64{ 0xFFFFFFFFFFFFFFFF, 0, 1, 0 };
    var results2 = [_]u64{ 0, 0 };
    try vm.invoke(&inst, "test", &args2, &results2);
    try testing.expectEqual(@as(u64, 0), results2[0]); // lo
    try testing.expectEqual(@as(u64, 1), results2[1]); // hi
}

test "Custom page sizes — memory with page_size=1" {
    // Module: memory (page_size=1, min=0), funcs: size, grow, load, store
    // Matches wasmtime custom-page-sizes.wast test pattern.
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0f, 0x03, 0x60, 0x00, 0x01, 0x7f, 0x60,
        0x01, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x00, 0x03, 0x05, 0x04, 0x00, 0x01, 0x01, 0x02,
        0x05, 0x04, 0x01, 0x08, 0x00, 0x00, 0x07, 0x1e, 0x04, 0x04, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x00,
        0x04, 0x67, 0x72, 0x6f, 0x77, 0x00, 0x01, 0x04, 0x6c, 0x6f, 0x61, 0x64, 0x00, 0x02, 0x05, 0x73,
        0x74, 0x6f, 0x72, 0x65, 0x00, 0x03, 0x0a, 0x1f, 0x04, 0x04, 0x00, 0x3f, 0x00, 0x0b, 0x06, 0x00,
        0x20, 0x00, 0x40, 0x00, 0x0b, 0x07, 0x00, 0x20, 0x00, 0x2d, 0x00, 0x00, 0x0b, 0x09, 0x00, 0x20,
        0x00, 0x20, 0x01, 0x3a, 0x00, 0x00, 0x0b,
    };

    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm_inst = Vm.init(testing.allocator);
    var r = [_]u64{0};

    // Initial size = 0 (no pages)
    try vm_inst.invoke(&inst, "size", &.{}, &r);
    try testing.expectEqual(@as(u64, 0), r[0]);

    // Load from 0 should trap (no memory)
    var a0 = [_]u64{0};
    try testing.expectError(error.OutOfBoundsMemoryAccess,
        vm_inst.invoke(&inst, "load", &a0, &r));

    // Grow by 65536 bytes (= 65536 pages with page_size=1)
    var a_grow = [_]u64{65536};
    try vm_inst.invoke(&inst, "grow", &a_grow, &r);
    try testing.expectEqual(@as(u64, 0), r[0]); // old size = 0

    // Size should now be 65536
    try vm_inst.invoke(&inst, "size", &.{}, &r);
    try testing.expectEqual(@as(u64, 65536), r[0]);

    // Load last byte should succeed
    var a_last = [_]u64{65535};
    try vm_inst.invoke(&inst, "load", &a_last, &r);
    try testing.expectEqual(@as(u64, 0), r[0]);

    // Store + load roundtrip
    var a_store = [_]u64{ 65535, 42 };
    try vm_inst.invoke(&inst, "store", &a_store, &.{});
    try vm_inst.invoke(&inst, "load", &a_last, &r);
    try testing.expectEqual(@as(u64, 42), r[0]);

    // Load one past end should trap
    var a_oob = [_]u64{65536};
    try testing.expectError(error.OutOfBoundsMemoryAccess,
        vm_inst.invoke(&inst, "load", &a_oob, &r));
}

test "Resource limits — memory ceiling" {
    // Module with 1 initial page, exports memory_grow and memory_size
    const wasm = try readTestFile(testing.allocator, "conformance/memory_ops.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    // Set memory ceiling to 2 pages (128 KiB)
    vm.max_memory_bytes = 2 * 65536;

    var results = [_]u64{0};

    // Grow by 1 page: 1 → 2 pages, should succeed (within ceiling)
    var args_grow1 = [_]u64{1};
    try vm.invoke(&inst, "memory_grow", &args_grow1, &results);
    try testing.expectEqual(@as(u64, 1), results[0]); // old size

    // Grow by 1 more page: 2 → 3 pages, should fail (exceeds ceiling)
    var args_grow2 = [_]u64{1};
    try vm.invoke(&inst, "memory_grow", &args_grow2, &results);
    // memory_grow returns -1 on failure (i32 sign-extended to i64 in regIR)
    try testing.expect(results[0] == @as(u64, @as(u32, @bitCast(@as(i32, -1)))) or
        results[0] == @as(u64, @bitCast(@as(i64, -1))));
}

test "Multi-memory — store/load on memory 1" {
    // Module with 2 memories and 2 functions:
    //   func "store1": stores 42 to memory 1 at offset 0
    //   func "load0":  loads i32 from memory 0 at offset 0 (should be 0, not 42)
    const wasm = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // magic + version
        // Section 1: Type — 2 types
        0x01, 0x08, 0x02,
        0x60, 0x00, 0x00, // type 0: () -> ()
        0x60, 0x00, 0x01, 0x7F, // type 1: () -> i32
        // Section 3: Function — 2 funcs
        0x03, 0x03, 0x02, 0x00, 0x01,
        // Section 5: Memory — 2 memories: min=1, min=1
        0x05, 0x05, 0x02, 0x00, 0x01, 0x00, 0x01,
        // Section 7: Export — "store1" -> func 0, "load0" -> func 1
        0x07, 0x12, 0x02,
        0x06, 's', 't', 'o', 'r', 'e', '1', 0x00, 0x00,
        0x05, 'l', 'o', 'a', 'd', '0', 0x00, 0x01,
        // Section 10: Code — 2 function bodies
        0x0A, 0x14, // section id + size (20 bytes)
        0x02, // 2 bodies
        // Body 0: store1 — i32.const 0, i32.const 42, i32.store mem=1, end
        0x0A, // body size (10 bytes)
        0x00, // 0 locals
        0x41, 0x00, // i32.const 0
        0x41, 0x2A, // i32.const 42
        0x36, 0x40, 0x01, 0x00, // i32.store align=0|0x40 memidx=1 offset=0
        0x0B, // end
        // Body 1: load0 — i32.const 0, i32.load mem=0, end
        0x07, // body size (7 bytes)
        0x00, // 0 locals
        0x41, 0x00, // i32.const 0
        0x28, 0x02, 0x00, // i32.load align=2 offset=0 (memory 0, no bit 6)
        0x0B, // end
    };

    var mod = Module.init(testing.allocator, &wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    var results = [_]u64{0};
    // Store 42 to memory 1
    try vm.invoke(&inst, "store1", &.{}, &[_]u64{});
    // Load from memory 0 — should be 0 (untouched)
    try vm.invoke(&inst, "load0", &.{}, &results);
    try testing.expectEqual(@as(u64, 0), results[0]);
}

test "Resource limits — fuel metering" {
    // Module with a simple function that does some arithmetic
    const wasm = try readTestFile(testing.allocator, "conformance/memory_ops.wasm");
    defer testing.allocator.free(wasm);

    var mod = Module.init(testing.allocator, wasm);
    defer mod.deinit();
    try mod.decode();

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var inst = Instance.init(testing.allocator, &store, &mod);
    defer inst.deinit();
    try inst.instantiate();

    var vm = Vm.init(testing.allocator);
    // Set fuel to 0 — should fail immediately on first instruction
    vm.fuel = 0;

    var results = [_]u64{0};
    // memory_size needs at least 1 instruction, should exhaust fuel
    try testing.expectError(error.FuelExhausted, vm.invoke(&inst, "memory_size", &.{}, &results));
}
