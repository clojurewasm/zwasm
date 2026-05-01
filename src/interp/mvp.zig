//! MVP interp handlers (Phase 2 / §9.2 / 2.2 — chunk 1).
//!
//! Per ROADMAP §4.5 / §A12, each handler is registered into the
//! central `DispatchTable.interp` via `register(*DispatchTable)`.
//! The dispatcher (`src/interp/dispatch.zig`) calls them with an
//! opaque `*InterpCtx` cast back to the concrete `*Runtime` from
//! `src/interp/mod.zig`.
//!
//! Chunk-1 scope: const (i32/i64/f32/f64), drop, locals
//! (get/set/tee), globals (get/set), and the **i32 numeric**
//! family (binops / relops / unops / testop). Subsequent chunks
//! add i64 / f32 / f64 numeric, conversions, control flow,
//! loads/stores, calls.
//!
//! Wraparound semantics for integer arithmetic: Wasm `add` /
//! `sub` / `mul` are mod 2^N (`+%` / `-%` / `*%` in Zig). `div_s`
//! / `div_u` / `rem_s` / `rem_u` trap on divisor=0 and (signed
//! div only) on INT_MIN/-1 (`Trap.IntOverflow`). Shifts use the
//! lower-N-bits-of-shift-amount rule (`& (N-1)`).
//!
//! Zone 2 (`src/interp/`) — feature-MVP handlers live alongside
//! the engine they wire into so the Zone-1 / Zone-2 boundary is
//! clean: `src/feature/mvp/mod.zig` (Zone 1) covers parser-side
//! handlers, this file (Zone 2) covers interp-side handlers, and
//! Phase-6+ `src/jit_*/mvp.zig` (Zone 2) will mirror the pattern
//! for JIT emitters. ROADMAP §4.5's "feature modules" concept is
//! split per-engine in practice.
//!
//! Imports Zone 0 (`util/`) + Zone 1 (`ir/`) + sibling Zone 2
//! (`mod.zig`, `dispatch.zig`).

const std = @import("std");

const dispatch = @import("../ir/dispatch_table.zig");
const zir = @import("../ir/zir.zig");
const interp = @import("mod.zig");
const memory_ops = @import("memory_ops.zig");

const ZirOp = zir.ZirOp;
const ZirInstr = zir.ZirInstr;
const DispatchTable = dispatch.DispatchTable;
const InterpCtx = dispatch.InterpCtx;
const Runtime = interp.Runtime;
const Value = interp.Value;
const Trap = interp.Trap;

// ============================================================
// Public registration
// ============================================================

pub fn register(table: *DispatchTable) void {
    // Trap-only / no-op control
    table.interp[op(.@"unreachable")] = unreachableOp;
    table.interp[op(.nop)] = nopOp;
    table.interp[op(.select)] = selectOp;

    // Control flow
    table.interp[op(.@"block")] = blockOp;
    table.interp[op(.@"loop")] = loopOp;
    table.interp[op(.@"if")] = ifOp;
    table.interp[op(.@"else")] = elseOp;
    table.interp[op(.@"end")] = endOp;
    table.interp[op(.@"br")] = brOp;
    table.interp[op(.@"br_if")] = brIfOp;
    table.interp[op(.@"br_table")] = brTableOp;
    table.interp[op(.@"return")] = returnOp;
    table.interp[op(.@"call")] = callOp;
    table.interp[op(.@"call_indirect")] = callIndirectOp;

    // Constants
    table.interp[op(.@"i32.const")] = i32Const;
    table.interp[op(.@"i64.const")] = i64Const;
    table.interp[op(.@"f32.const")] = f32Const;
    table.interp[op(.@"f64.const")] = f64Const;

    // Parametric
    table.interp[op(.drop)] = drop;

    // Locals + globals
    table.interp[op(.@"local.get")] = localGet;
    table.interp[op(.@"local.set")] = localSet;
    table.interp[op(.@"local.tee")] = localTee;
    table.interp[op(.@"global.get")] = globalGet;
    table.interp[op(.@"global.set")] = globalSet;

    // i32 testop / unops
    table.interp[op(.@"i32.eqz")] = i32Eqz;
    table.interp[op(.@"i32.clz")] = i32Clz;
    table.interp[op(.@"i32.ctz")] = i32Ctz;
    table.interp[op(.@"i32.popcnt")] = i32Popcnt;

    // i32 binops
    table.interp[op(.@"i32.add")] = i32Add;
    table.interp[op(.@"i32.sub")] = i32Sub;
    table.interp[op(.@"i32.mul")] = i32Mul;
    table.interp[op(.@"i32.div_s")] = i32DivS;
    table.interp[op(.@"i32.div_u")] = i32DivU;
    table.interp[op(.@"i32.rem_s")] = i32RemS;
    table.interp[op(.@"i32.rem_u")] = i32RemU;
    table.interp[op(.@"i32.and")] = i32And;
    table.interp[op(.@"i32.or")] = i32Or;
    table.interp[op(.@"i32.xor")] = i32Xor;
    table.interp[op(.@"i32.shl")] = i32Shl;
    table.interp[op(.@"i32.shr_s")] = i32ShrS;
    table.interp[op(.@"i32.shr_u")] = i32ShrU;
    table.interp[op(.@"i32.rotl")] = i32Rotl;
    table.interp[op(.@"i32.rotr")] = i32Rotr;

    // i32 relops
    table.interp[op(.@"i32.eq")] = i32Eq;
    table.interp[op(.@"i32.ne")] = i32Ne;
    table.interp[op(.@"i32.lt_s")] = i32LtS;
    table.interp[op(.@"i32.lt_u")] = i32LtU;
    table.interp[op(.@"i32.gt_s")] = i32GtS;
    table.interp[op(.@"i32.gt_u")] = i32GtU;
    table.interp[op(.@"i32.le_s")] = i32LeS;
    table.interp[op(.@"i32.le_u")] = i32LeU;
    table.interp[op(.@"i32.ge_s")] = i32GeS;
    table.interp[op(.@"i32.ge_u")] = i32GeU;

    // i64 testop / unops
    table.interp[op(.@"i64.eqz")] = i64Eqz;
    table.interp[op(.@"i64.clz")] = i64Clz;
    table.interp[op(.@"i64.ctz")] = i64Ctz;
    table.interp[op(.@"i64.popcnt")] = i64Popcnt;

    // i64 binops
    table.interp[op(.@"i64.add")] = i64Add;
    table.interp[op(.@"i64.sub")] = i64Sub;
    table.interp[op(.@"i64.mul")] = i64Mul;
    table.interp[op(.@"i64.div_s")] = i64DivS;
    table.interp[op(.@"i64.div_u")] = i64DivU;
    table.interp[op(.@"i64.rem_s")] = i64RemS;
    table.interp[op(.@"i64.rem_u")] = i64RemU;
    table.interp[op(.@"i64.and")] = i64And;
    table.interp[op(.@"i64.or")] = i64Or;
    table.interp[op(.@"i64.xor")] = i64Xor;
    table.interp[op(.@"i64.shl")] = i64Shl;
    table.interp[op(.@"i64.shr_s")] = i64ShrS;
    table.interp[op(.@"i64.shr_u")] = i64ShrU;
    table.interp[op(.@"i64.rotl")] = i64Rotl;
    table.interp[op(.@"i64.rotr")] = i64Rotr;

    // i64 relops
    table.interp[op(.@"i64.eq")] = i64Eq;
    table.interp[op(.@"i64.ne")] = i64Ne;
    table.interp[op(.@"i64.lt_s")] = i64LtS;
    table.interp[op(.@"i64.lt_u")] = i64LtU;
    table.interp[op(.@"i64.gt_s")] = i64GtS;
    table.interp[op(.@"i64.gt_u")] = i64GtU;
    table.interp[op(.@"i64.le_s")] = i64LeS;
    table.interp[op(.@"i64.le_u")] = i64LeU;
    table.interp[op(.@"i64.ge_s")] = i64GeS;
    table.interp[op(.@"i64.ge_u")] = i64GeU;

    // f32 relops
    table.interp[op(.@"f32.eq")] = f32Eq;
    table.interp[op(.@"f32.ne")] = f32Ne;
    table.interp[op(.@"f32.lt")] = f32Lt;
    table.interp[op(.@"f32.gt")] = f32Gt;
    table.interp[op(.@"f32.le")] = f32Le;
    table.interp[op(.@"f32.ge")] = f32Ge;

    // f32 unops
    table.interp[op(.@"f32.abs")] = f32Abs;
    table.interp[op(.@"f32.neg")] = f32Neg;
    table.interp[op(.@"f32.ceil")] = f32Ceil;
    table.interp[op(.@"f32.floor")] = f32Floor;
    table.interp[op(.@"f32.trunc")] = f32Trunc;
    table.interp[op(.@"f32.nearest")] = f32Nearest;
    table.interp[op(.@"f32.sqrt")] = f32Sqrt;

    // f32 binops
    table.interp[op(.@"f32.add")] = f32Add;
    table.interp[op(.@"f32.sub")] = f32Sub;
    table.interp[op(.@"f32.mul")] = f32Mul;
    table.interp[op(.@"f32.div")] = f32Div;
    table.interp[op(.@"f32.min")] = f32Min;
    table.interp[op(.@"f32.max")] = f32Max;
    table.interp[op(.@"f32.copysign")] = f32Copysign;

    // f64 relops
    table.interp[op(.@"f64.eq")] = f64Eq;
    table.interp[op(.@"f64.ne")] = f64Ne;
    table.interp[op(.@"f64.lt")] = f64Lt;
    table.interp[op(.@"f64.gt")] = f64Gt;
    table.interp[op(.@"f64.le")] = f64Le;
    table.interp[op(.@"f64.ge")] = f64Ge;

    // f64 unops
    table.interp[op(.@"f64.abs")] = f64Abs;
    table.interp[op(.@"f64.neg")] = f64Neg;
    table.interp[op(.@"f64.ceil")] = f64Ceil;
    table.interp[op(.@"f64.floor")] = f64Floor;
    table.interp[op(.@"f64.trunc")] = f64Trunc;
    table.interp[op(.@"f64.nearest")] = f64Nearest;
    table.interp[op(.@"f64.sqrt")] = f64Sqrt;

    // f64 binops
    table.interp[op(.@"f64.add")] = f64Add;
    table.interp[op(.@"f64.sub")] = f64Sub;
    table.interp[op(.@"f64.mul")] = f64Mul;
    table.interp[op(.@"f64.div")] = f64Div;
    table.interp[op(.@"f64.min")] = f64Min;
    table.interp[op(.@"f64.max")] = f64Max;
    table.interp[op(.@"f64.copysign")] = f64Copysign;

    // Conversions (0xA7..0xBF)
    table.interp[op(.@"i32.wrap_i64")] = i32WrapI64;
    table.interp[op(.@"i32.trunc_f32_s")] = i32TruncF32S;
    table.interp[op(.@"i32.trunc_f32_u")] = i32TruncF32U;
    table.interp[op(.@"i32.trunc_f64_s")] = i32TruncF64S;
    table.interp[op(.@"i32.trunc_f64_u")] = i32TruncF64U;
    table.interp[op(.@"i64.extend_i32_s")] = i64ExtendI32S;
    table.interp[op(.@"i64.extend_i32_u")] = i64ExtendI32U;
    table.interp[op(.@"i64.trunc_f32_s")] = i64TruncF32S;
    table.interp[op(.@"i64.trunc_f32_u")] = i64TruncF32U;
    table.interp[op(.@"i64.trunc_f64_s")] = i64TruncF64S;
    table.interp[op(.@"i64.trunc_f64_u")] = i64TruncF64U;
    table.interp[op(.@"f32.convert_i32_s")] = f32ConvertI32S;
    table.interp[op(.@"f32.convert_i32_u")] = f32ConvertI32U;
    table.interp[op(.@"f32.convert_i64_s")] = f32ConvertI64S;
    table.interp[op(.@"f32.convert_i64_u")] = f32ConvertI64U;
    table.interp[op(.@"f32.demote_f64")] = f32DemoteF64;
    table.interp[op(.@"f64.convert_i32_s")] = f64ConvertI32S;
    table.interp[op(.@"f64.convert_i32_u")] = f64ConvertI32U;
    table.interp[op(.@"f64.convert_i64_s")] = f64ConvertI64S;
    table.interp[op(.@"f64.convert_i64_u")] = f64ConvertI64U;
    table.interp[op(.@"f64.promote_f32")] = f64PromoteF32;
    table.interp[op(.@"i32.reinterpret_f32")] = i32ReinterpretF32;
    table.interp[op(.@"i64.reinterpret_f64")] = i64ReinterpretF64;
    table.interp[op(.@"f32.reinterpret_i32")] = f32ReinterpretI32;
    table.interp[op(.@"f64.reinterpret_i64")] = f64ReinterpretI64;

    // Loads / stores / memory ops live in memory_ops.zig
    memory_ops.register(table);
}

inline fn op(t: ZirOp) usize {
    return @intFromEnum(t);
}

// ============================================================
// Handlers
// ============================================================

fn unreachableOp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {
    return Trap.Unreachable;
}

fn nopOp(_: *InterpCtx, _: *const ZirInstr) anyerror!void {}

fn selectOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const cond = rt.popOperand().i32;
    const b = rt.popOperand();
    const a = rt.popOperand();
    try rt.pushOperand(if (cond != 0) a else b);
}

// --- Control flow ---

inline fn blockArity(blocktype_byte: u32) u32 {
    return if (blocktype_byte == 0x40) 0 else 1;
}

fn blockOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    try frame.pushLabel(.{
        .height = rt.operand_len,
        .arity = blockArity(instr.extra),
        .target_pc = blk.end_inst + 1,
    });
}

fn loopOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    try frame.pushLabel(.{
        .height = rt.operand_len,
        .arity = 0, // br to a loop discards the body's results.
        .target_pc = blk.start_inst + 1,
    });
}

fn ifOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const cond = rt.popOperand().i32;
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    const blk = fnz.blocks.items[instr.payload];
    try frame.pushLabel(.{
        .height = rt.operand_len,
        .arity = blockArity(instr.extra),
        .target_pc = blk.end_inst + 1,
    });
    if (cond == 0) {
        // Skip to else (if any) or directly past end.
        frame.pc = if (blk.else_inst) |e| e + 1 else blk.end_inst;
    }
}

fn elseOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    // Reaching else from the then-branch — jump to the matching `end`.
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const fnz = frame.func orelse return Trap.Unreachable;
    if (instr.payload >= fnz.blocks.items.len) return Trap.Unreachable;
    frame.pc = fnz.blocks.items[instr.payload].end_inst;
}

fn endOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    if (frame.label_len == 0) {
        // Function-level end: the run loop terminates after this step.
        frame.done = true;
        return;
    }
    const label = frame.popLabel();
    try restoreToLabel(rt, label);
}

inline fn restoreToLabel(rt: *Runtime, label: interp.Label) Trap!void {
    // Save `arity` topmost values, drop down to label.height, push back.
    if (label.arity == 0) {
        rt.operand_len = label.height;
        return;
    }
    // arity == 1 in MVP. Wasm 2.0 multivalue widens this; revisit later.
    if (label.arity != 1) return Trap.Unreachable;
    const top = rt.popOperand();
    rt.operand_len = label.height;
    try rt.pushOperand(top);
}

inline fn doBranch(rt: *Runtime, frame: *interp.Frame, depth: u32) Trap!void {
    if (depth >= frame.label_len) return Trap.Unreachable;
    const target = frame.labelAt(depth);
    // Pop (depth + 1) labels off the control stack — except for loop
    // labels, br re-enters them (the loop opcode at target_pc will
    // re-push the label). Easier: pop all (depth+1), let the loop
    // opcode re-push if needed.
    var i: u32 = 0;
    while (i <= depth) : (i += 1) _ = frame.popLabel();
    try restoreToLabel(rt, target);
    frame.pc = target.target_pc;
}

fn brOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try doBranch(rt, rt.currentFrame(), instr.payload);
}

fn brIfOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const cond = rt.popOperand().i32;
    if (cond != 0) {
        try doBranch(rt, rt.currentFrame(), instr.payload);
    }
}

fn brTableOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const idx = rt.popOperand().u32;
    const count = instr.payload;
    const start = instr.extra;
    const fnz = frame.func orelse return Trap.Unreachable;
    const targets = fnz.branch_targets.items;
    const end_idx = start + count;
    if (end_idx >= targets.len) return Trap.Unreachable;
    const depth = if (idx < count) targets[start + idx] else targets[end_idx];
    try doBranch(rt, frame, depth);
}

/// Recursive call. Pops args, allocates locals (params + zero-init
/// declared locals), pushes a frame, recursively runs the callee
/// body, then pops the frame on return.
fn callOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    if (idx >= rt.funcs.len) return Trap.Unreachable;
    const callee = rt.funcs[idx];
    const tbl = rt.table orelse return Trap.Unreachable;
    try invoke(rt, tbl, callee);
}

/// `call_indirect type_idx`: pops i32 selector, indexes the
/// function table, invokes the callee. Type-equality check
/// against the expected `type_idx` requires plumbing the
/// module's type section through Runtime; that lands in a
/// follow-up chunk together with the proper element-section
/// table population. For now the selector simply indexes
/// `rt.funcs` (a stand-in for the table) and the callee's sig
/// is trusted.
fn callIndirectOp(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    _ = instr;
    const rt = Runtime.fromOpaque(c);
    const sel = rt.popOperand().u32;
    if (sel >= rt.funcs.len) return Trap.OutOfBoundsTableAccess;
    const callee = rt.funcs[sel];
    const tbl = rt.table orelse return Trap.Unreachable;
    try invoke(rt, tbl, callee);
}

fn invoke(rt: *Runtime, table: *const DispatchTable, callee: *const zir.ZirFunc) anyerror!void {
    const params_len = callee.sig.params.len;
    const total = params_len + callee.locals.len;
    const locals = try rt.alloc.alloc(interp.Value, total);
    defer rt.alloc.free(locals);

    // Pop args in reverse (last param popped first lands at locals[params_len-1]).
    var i: usize = params_len;
    while (i > 0) {
        i -= 1;
        if (rt.operand_len == 0) return Trap.StackOverflow;
        locals[i] = rt.popOperand();
    }
    // Zero-init declared locals.
    var j: usize = params_len;
    while (j < total) : (j += 1) locals[j] = interp.Value.zero;

    try rt.pushFrame(.{
        .sig = callee.sig,
        .locals = locals,
        .operand_base = rt.operand_len,
        .pc = 0,
        .func = callee,
    });

    const dispatch_loop_local = @import("dispatch.zig");
    const run_err = dispatch_loop_local.run(rt, table, callee.instrs.items);
    _ = rt.popFrame();
    try run_err;
}

fn returnOp(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const frame = rt.currentFrame();
    const arity: u32 = @intCast(frame.sig.results.len);
    if (arity > 1) return Trap.Unreachable; // MVP single-value
    if (arity == 1) {
        const top = rt.popOperand();
        rt.operand_len = frame.operand_base;
        try rt.pushOperand(top);
    } else {
        rt.operand_len = frame.operand_base;
    }
    frame.label_len = 0;
    frame.done = true;
}

fn i32Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .i32 = @bitCast(instr.payload) });
}

fn i64Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const lo: u64 = instr.payload;
    const hi: u64 = instr.extra;
    try rt.pushOperand(.{ .u64 = lo | (hi << 32) });
}

fn f32Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .bits64 = instr.payload });
}

fn f64Const(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const lo: u64 = instr.payload;
    const hi: u64 = instr.extra;
    try rt.pushOperand(.{ .bits64 = lo | (hi << 32) });
}

fn drop(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    _ = rt.popOperand();
}

fn localGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    try rt.pushOperand(frame.locals[idx]);
}

fn localSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    frame.locals[idx] = rt.popOperand();
}

fn localTee(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    const frame = rt.currentFrame();
    if (idx >= frame.locals.len) return Trap.Unreachable;
    frame.locals[idx] = rt.topOperand();
}

fn globalGet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    if (idx >= rt.globals.len) return Trap.Unreachable;
    try rt.pushOperand(rt.globals[idx]);
}

fn globalSet(c: *InterpCtx, instr: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const idx = instr.payload;
    if (idx >= rt.globals.len) return Trap.Unreachable;
    rt.globals[idx] = rt.popOperand();
}

// --- i32 unops / testop ---

fn i32Eqz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i32;
    try rt.pushOperand(.{ .i32 = if (x == 0) 1 else 0 });
}

fn i32Clz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    const r: i32 = @intCast(@clz(x));
    try rt.pushOperand(.{ .i32 = r });
}

fn i32Ctz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    const r: i32 = @intCast(@ctz(x));
    try rt.pushOperand(.{ .i32 = r });
}

fn i32Popcnt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    const r: i32 = @intCast(@popCount(x));
    try rt.pushOperand(.{ .i32 = r });
}

// --- i32 binops ---

fn popI32Pair(rt: *Runtime) struct { a: i32, b: i32 } {
    const b = rt.popOperand().i32;
    const a = rt.popOperand().i32;
    return .{ .a = a, .b = b };
}

fn popU32Pair(rt: *Runtime) struct { a: u32, b: u32 } {
    const b = rt.popOperand().u32;
    const a = rt.popOperand().u32;
    return .{ .a = a, .b = b };
}

fn i32Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try rt.pushOperand(.{ .i32 = p.a +% p.b });
}

fn i32Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try rt.pushOperand(.{ .i32 = p.a -% p.b });
}

fn i32Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try rt.pushOperand(.{ .i32 = p.a *% p.b });
}

fn i32DivS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    if (p.a == std.math.minInt(i32) and p.b == -1) return Trap.IntOverflow;
    try rt.pushOperand(.{ .i32 = @divTrunc(p.a, p.b) });
}

fn i32DivU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u32 = p.a / p.b });
}

fn i32RemS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    // INT_MIN % -1 = 0 in Wasm; @rem would overflow.
    if (p.a == std.math.minInt(i32) and p.b == -1) {
        try rt.pushOperand(.{ .i32 = 0 });
        return;
    }
    try rt.pushOperand(.{ .i32 = @rem(p.a, p.b) });
}

fn i32RemU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u32 = p.a % p.b });
}

fn i32And(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    try rt.pushOperand(.{ .u32 = p.a & p.b });
}

fn i32Or(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    try rt.pushOperand(.{ .u32 = p.a | p.b });
}

fn i32Xor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    try rt.pushOperand(.{ .u32 = p.a ^ p.b });
}

fn i32Shl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = p.a << sh });
}

fn i32ShrS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    const sh: u5 = @intCast(@as(u32, @bitCast(p.b)) & 31);
    try rt.pushOperand(.{ .i32 = p.a >> sh });
}

fn i32ShrU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = p.a >> sh });
}

fn i32Rotl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = std.math.rotl(u32, p.a, sh) });
}

fn i32Rotr(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    const sh: u5 = @intCast(p.b & 31);
    try rt.pushOperand(.{ .u32 = std.math.rotr(u32, p.a, sh) });
}

// --- i32 relops ---

inline fn pushBool(rt: *Runtime, b: bool) anyerror!void {
    try rt.pushOperand(.{ .i32 = if (b) 1 else 0 });
}

fn i32Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn i32Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn i32LtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i32LtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i32GtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i32GtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i32LeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i32LeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i32GeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI32Pair(rt);
    try pushBool(rt, p.a >= p.b);
}
fn i32GeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU32Pair(rt);
    try pushBool(rt, p.a >= p.b);
}

// --- i64 unops / testop ---

fn i64Eqz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i64;
    try rt.pushOperand(.{ .i32 = if (x == 0) 1 else 0 });
}

fn i64Clz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    const r: i64 = @intCast(@clz(x));
    try rt.pushOperand(.{ .i64 = r });
}

fn i64Ctz(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    const r: i64 = @intCast(@ctz(x));
    try rt.pushOperand(.{ .i64 = r });
}

fn i64Popcnt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    const r: i64 = @intCast(@popCount(x));
    try rt.pushOperand(.{ .i64 = r });
}

// --- i64 binops ---

fn popI64Pair(rt: *Runtime) struct { a: i64, b: i64 } {
    const b = rt.popOperand().i64;
    const a = rt.popOperand().i64;
    return .{ .a = a, .b = b };
}

fn popU64Pair(rt: *Runtime) struct { a: u64, b: u64 } {
    const b = rt.popOperand().u64;
    const a = rt.popOperand().u64;
    return .{ .a = a, .b = b };
}

fn i64Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try rt.pushOperand(.{ .i64 = p.a +% p.b });
}

fn i64Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try rt.pushOperand(.{ .i64 = p.a -% p.b });
}

fn i64Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try rt.pushOperand(.{ .i64 = p.a *% p.b });
}

fn i64DivS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    if (p.a == std.math.minInt(i64) and p.b == -1) return Trap.IntOverflow;
    try rt.pushOperand(.{ .i64 = @divTrunc(p.a, p.b) });
}

fn i64DivU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u64 = p.a / p.b });
}

fn i64RemS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    if (p.a == std.math.minInt(i64) and p.b == -1) {
        try rt.pushOperand(.{ .i64 = 0 });
        return;
    }
    try rt.pushOperand(.{ .i64 = @rem(p.a, p.b) });
}

fn i64RemU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    if (p.b == 0) return Trap.DivByZero;
    try rt.pushOperand(.{ .u64 = p.a % p.b });
}

fn i64And(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try rt.pushOperand(.{ .u64 = p.a & p.b });
}

fn i64Or(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try rt.pushOperand(.{ .u64 = p.a | p.b });
}

fn i64Xor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try rt.pushOperand(.{ .u64 = p.a ^ p.b });
}

fn i64Shl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = p.a << sh });
}

fn i64ShrS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    const sh: u6 = @intCast(@as(u64, @bitCast(p.b)) & 63);
    try rt.pushOperand(.{ .i64 = p.a >> sh });
}

fn i64ShrU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = p.a >> sh });
}

fn i64Rotl(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = std.math.rotl(u64, p.a, sh) });
}

fn i64Rotr(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    const sh: u6 = @intCast(p.b & 63);
    try rt.pushOperand(.{ .u64 = std.math.rotr(u64, p.a, sh) });
}

// --- i64 relops ---

fn i64Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn i64Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn i64LtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i64LtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn i64GtS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i64GtU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn i64LeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i64LeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn i64GeS(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popI64Pair(rt);
    try pushBool(rt, p.a >= p.b);
}
fn i64GeU(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popU64Pair(rt);
    try pushBool(rt, p.a >= p.b);
}

// ============================================================
// f32 / f64 numeric
// ============================================================

// Wasm 1.0 §6.2.3 specifies "canonical NaN" semantics for arithmetic
// outputs: the implementation may return any NaN, but tests typically
// only assert non-NaN equality. Strict canonicalisation lands in 2.4.

fn popF32Pair(rt: *Runtime) struct { a: f32, b: f32 } {
    const b = rt.popOperand().f32;
    const a = rt.popOperand().f32;
    return .{ .a = a, .b = b };
}
fn popF64Pair(rt: *Runtime) struct { a: f64, b: f64 } {
    const b = rt.popOperand().f64;
    const a = rt.popOperand().f64;
    return .{ .a = a, .b = b };
}

// --- f32 relops ---
fn f32Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn f32Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn f32Lt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn f32Gt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn f32Le(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn f32Ge(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try pushBool(rt, p.a >= p.b);
}

// --- f32 unops ---
fn f32Abs(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @abs(rt.popOperand().f32) });
}
fn f32Neg(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = -rt.popOperand().f32 });
}
fn f32Ceil(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @ceil(rt.popOperand().f32) });
}
fn f32Floor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floor(rt.popOperand().f32) });
}
fn f32Trunc(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @trunc(rt.popOperand().f32) });
}
fn f32Nearest(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @round(rt.popOperand().f32) });
}
fn f32Sqrt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @sqrt(rt.popOperand().f32) });
}

// --- f32 binops ---
fn f32Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a + p.b });
}
fn f32Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a - p.b });
}
fn f32Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a * p.b });
}
fn f32Div(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = p.a / p.b });
}
fn f32Min(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    } else {
        try rt.pushOperand(.{ .f32 = @min(p.a, p.b) });
    }
}
fn f32Max(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    } else {
        try rt.pushOperand(.{ .f32 = @max(p.a, p.b) });
    }
}
fn f32Copysign(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF32Pair(rt);
    try rt.pushOperand(.{ .f32 = std.math.copysign(p.a, p.b) });
}

// --- f64 relops ---
fn f64Eq(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a == p.b);
}
fn f64Ne(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a != p.b);
}
fn f64Lt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a < p.b);
}
fn f64Gt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a > p.b);
}
fn f64Le(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a <= p.b);
}
fn f64Ge(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try pushBool(rt, p.a >= p.b);
}

// --- f64 unops ---
fn f64Abs(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @abs(rt.popOperand().f64) });
}
fn f64Neg(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = -rt.popOperand().f64 });
}
fn f64Ceil(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @ceil(rt.popOperand().f64) });
}
fn f64Floor(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floor(rt.popOperand().f64) });
}
fn f64Trunc(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @trunc(rt.popOperand().f64) });
}
fn f64Nearest(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @round(rt.popOperand().f64) });
}
fn f64Sqrt(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @sqrt(rt.popOperand().f64) });
}

// --- f64 binops ---
fn f64Add(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a + p.b });
}
fn f64Sub(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a - p.b });
}
fn f64Mul(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a * p.b });
}
fn f64Div(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = p.a / p.b });
}
fn f64Min(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f64 = std.math.nan(f64) });
    } else {
        try rt.pushOperand(.{ .f64 = @min(p.a, p.b) });
    }
}
fn f64Max(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    if (std.math.isNan(p.a) or std.math.isNan(p.b)) {
        try rt.pushOperand(.{ .f64 = std.math.nan(f64) });
    } else {
        try rt.pushOperand(.{ .f64 = @max(p.a, p.b) });
    }
}
fn f64Copysign(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const p = popF64Pair(rt);
    try rt.pushOperand(.{ .f64 = std.math.copysign(p.a, p.b) });
}

// ============================================================
// Conversions
// ============================================================

// Float → int truncation: trap on NaN / ±inf, trap on out-of-range.
// Spec §3.3.1.6: "trunc_f32_s" et al. produce InvalidConversionToInt
// on NaN, IntOverflow on saturating-out-of-range. Wasm 2.0 adds
// trunc_sat_* variants that don't trap; those land separately.

fn truncFloatToInt(comptime DstInt: type, x: anytype) !DstInt {
    if (std.math.isNan(x)) return Trap.InvalidConversionToInt;
    if (std.math.isInf(x)) return Trap.IntOverflow;
    const truncated = @trunc(x);
    const min_f = @as(@TypeOf(x), @floatFromInt(std.math.minInt(DstInt)));
    const max_f = @as(@TypeOf(x), @floatFromInt(std.math.maxInt(DstInt)));
    if (truncated < min_f or truncated > max_f) return Trap.IntOverflow;
    return @intFromFloat(truncated);
}

fn truncFloatToUint(comptime DstUint: type, x: anytype) !DstUint {
    if (std.math.isNan(x)) return Trap.InvalidConversionToInt;
    if (std.math.isInf(x)) return Trap.IntOverflow;
    const truncated = @trunc(x);
    const max_f = @as(@TypeOf(x), @floatFromInt(std.math.maxInt(DstUint)));
    if (truncated < 0 or truncated > max_f) return Trap.IntOverflow;
    return @intFromFloat(truncated);
}

fn i32WrapI64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u64;
    try rt.pushOperand(.{ .u32 = @truncate(x) });
}

fn i32TruncF32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToInt(i32, x);
    try rt.pushOperand(.{ .i32 = r });
}
fn i32TruncF32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToUint(u32, x);
    try rt.pushOperand(.{ .u32 = r });
}
fn i32TruncF64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToInt(i32, x);
    try rt.pushOperand(.{ .i32 = r });
}
fn i32TruncF64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToUint(u32, x);
    try rt.pushOperand(.{ .u32 = r });
}

fn i64ExtendI32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().i32;
    try rt.pushOperand(.{ .i64 = @as(i64, x) });
}
fn i64ExtendI32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().u32;
    try rt.pushOperand(.{ .u64 = @as(u64, x) });
}

fn i64TruncF32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToInt(i64, x);
    try rt.pushOperand(.{ .i64 = r });
}
fn i64TruncF32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f32;
    const r = try truncFloatToUint(u64, x);
    try rt.pushOperand(.{ .u64 = r });
}
fn i64TruncF64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToInt(i64, x);
    try rt.pushOperand(.{ .i64 = r });
}
fn i64TruncF64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const x = rt.popOperand().f64;
    const r = try truncFloatToUint(u64, x);
    try rt.pushOperand(.{ .u64 = r });
}

fn f32ConvertI32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().i32) });
}
fn f32ConvertI32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().u32) });
}
fn f32ConvertI64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().i64) });
}
fn f32ConvertI64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatFromInt(rt.popOperand().u64) });
}
fn f32DemoteF64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f32 = @floatCast(rt.popOperand().f64) });
}

fn f64ConvertI32S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().i32) });
}
fn f64ConvertI32U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().u32) });
}
fn f64ConvertI64S(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().i64) });
}
fn f64ConvertI64U(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatFromInt(rt.popOperand().u64) });
}
fn f64PromoteF32(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    try rt.pushOperand(.{ .f64 = @floatCast(rt.popOperand().f32) });
}

// Reinterpret: copy bits, no value conversion. The Value union is
// extern, so f32 and u32 share storage; popping as `.bits64` and
// pushing back is the canonical bit-preserving move.
fn i32ReinterpretF32(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .u32 = @truncate(v.bits64) });
}
fn i64ReinterpretF64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .u64 = v.bits64 });
}
fn f32ReinterpretI32(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .bits64 = @as(u64, v.u32) });
}
fn f64ReinterpretI64(c: *InterpCtx, _: *const ZirInstr) anyerror!void {
    const rt = Runtime.fromOpaque(c);
    const v = rt.popOperand();
    try rt.pushOperand(.{ .bits64 = v.u64 });
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;
const dispatch_loop = @import("dispatch.zig");

fn driveOne(rt: *Runtime, table: *const DispatchTable, t: ZirOp, payload: u32, extra: u32) !void {
    const instr: ZirInstr = .{ .op = t, .payload = payload, .extra = extra };
    try dispatch_loop.step(rt, table, &instr);
}

test "register: const + drop slots populated" {
    var t = DispatchTable.init();
    register(&t);
    try testing.expect(t.interp[op(.@"i32.const")] != null);
    try testing.expect(t.interp[op(.@"i64.const")] != null);
    try testing.expect(t.interp[op(.drop)] != null);
}

test "i32.const: pushes the bitcast u32 value" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -7)), 0);
    try testing.expectEqual(@as(i32, -7), rt.popOperand().i32);
}

test "i64.const: low/high split round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const v: i64 = -1;
    const u: u64 = @bitCast(v);
    try driveOne(&rt, &t, .@"i64.const", @truncate(u), @truncate(u >> 32));
    try testing.expectEqual(@as(i64, -1), rt.popOperand().i64);
}

test "i32.add wraps modulo 2^32" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, std.math.maxInt(i32))), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 1)), 0);
    try driveOne(&rt, &t, .@"i32.add", 0, 0);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), rt.popOperand().i32);
}

test "i32.div_s: 0 divisor traps DivByZero" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 7)), 0);
    try driveOne(&rt, &t, .@"i32.const", 0, 0);
    try testing.expectError(Trap.DivByZero, driveOne(&rt, &t, .@"i32.div_s", 0, 0));
}

test "i32.div_s: INT_MIN/-1 traps IntOverflow" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, std.math.minInt(i32))), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try testing.expectError(Trap.IntOverflow, driveOne(&rt, &t, .@"i32.div_s", 0, 0));
}

test "i32.rem_s: INT_MIN % -1 = 0 (no trap, spec rule)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, std.math.minInt(i32))), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.rem_s", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i32.shl: shift amount is masked to 5 bits" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", 1, 0);
    try driveOne(&rt, &t, .@"i32.const", 33, 0); // 33 mod 32 = 1
    try driveOne(&rt, &t, .@"i32.shl", 0, 0);
    try testing.expectEqual(@as(u32, 2), rt.popOperand().u32);
}

test "i32 relops: lt_s/lt_u differ for sign" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    // -1 vs 1 — signed: -1 < 1 = true; unsigned: 0xFFFFFFFF > 1 = false.
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 1)), 0);
    try driveOne(&rt, &t, .@"i32.lt_s", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 1)), 0);
    try driveOne(&rt, &t, .@"i32.lt_u", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i32.eqz: 0 → 1, nonzero → 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", 0, 0);
    try driveOne(&rt, &t, .@"i32.eqz", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", 7, 0);
    try driveOne(&rt, &t, .@"i32.eqz", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "i32.clz / ctz / popcnt round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i32.const", 1, 0);
    try driveOne(&rt, &t, .@"i32.clz", 0, 0);
    try testing.expectEqual(@as(i32, 31), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", 8, 0);
    try driveOne(&rt, &t, .@"i32.ctz", 0, 0);
    try testing.expectEqual(@as(i32, 3), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, -1)), 0);
    try driveOne(&rt, &t, .@"i32.popcnt", 0, 0);
    try testing.expectEqual(@as(i32, 32), rt.popOperand().i32);
}

test "locals: get/set/tee round-trip via current frame" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var locals = [_]Value{ Value.fromI32(0), Value.fromI32(0) };
    const sig: zir.FuncType = .{ .params = &.{}, .results = &.{} };
    try rt.pushFrame(.{ .sig = sig, .locals = &locals, .operand_base = 0, .pc = 0 });

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 42)), 0);
    try driveOne(&rt, &t, .@"local.set", 0, 0);
    try testing.expectEqual(@as(i32, 42), locals[0].i32);

    try driveOne(&rt, &t, .@"local.get", 0, 0);
    try testing.expectEqual(@as(i32, 42), rt.popOperand().i32);

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 99)), 0);
    try driveOne(&rt, &t, .@"local.tee", 1, 0);
    try testing.expectEqual(@as(i32, 99), locals[1].i32);
    try testing.expectEqual(@as(i32, 99), rt.popOperand().i32);
}

test "i64.add wraps modulo 2^64" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const lo_max: u64 = @bitCast(@as(i64, std.math.maxInt(i64)));
    try driveOne(&rt, &t, .@"i64.const", @truncate(lo_max), @truncate(lo_max >> 32));
    try driveOne(&rt, &t, .@"i64.const", 1, 0);
    try driveOne(&rt, &t, .@"i64.add", 0, 0);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), rt.popOperand().i64);
}

test "i64.div_s: INT_MIN/-1 traps IntOverflow" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    const min_lo: u64 = @bitCast(@as(i64, std.math.minInt(i64)));
    try driveOne(&rt, &t, .@"i64.const", @truncate(min_lo), @truncate(min_lo >> 32));
    const minus_one: u64 = @bitCast(@as(i64, -1));
    try driveOne(&rt, &t, .@"i64.const", @truncate(minus_one), @truncate(minus_one >> 32));
    try testing.expectError(Trap.IntOverflow, driveOne(&rt, &t, .@"i64.div_s", 0, 0));
}

test "i64.shl masks shift count to 6 bits" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i64.const", 1, 0);
    try driveOne(&rt, &t, .@"i64.const", 65, 0); // 65 mod 64 = 1
    try driveOne(&rt, &t, .@"i64.shl", 0, 0);
    try testing.expectEqual(@as(u64, 2), rt.popOperand().u64);
}

test "i64.eqz: 0 → 1, nonzero → 0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try driveOne(&rt, &t, .@"i64.const", 0, 0);
    try driveOne(&rt, &t, .@"i64.eqz", 0, 0);
    try testing.expectEqual(@as(i32, 1), rt.popOperand().i32);
}

test "i64.lt_u: high bits respected" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    // 0x1_0000_0000 vs 0x2 — unsigned: a > b
    try driveOne(&rt, &t, .@"i64.const", 0, 1);
    try driveOne(&rt, &t, .@"i64.const", 2, 0);
    try driveOne(&rt, &t, .@"i64.lt_u", 0, 0);
    try testing.expectEqual(@as(i32, 0), rt.popOperand().i32);
}

test "f32.add: 1.0 + 2.0 = 3.0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = 1.0 });
    try rt.pushOperand(.{ .f32 = 2.0 });
    try driveOne(&rt, &t, .@"f32.add", 0, 0);
    try testing.expectEqual(@as(f32, 3.0), rt.popOperand().f32);
}

test "f32.div: 1.0 / 0.0 = inf (no trap)" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = 1.0 });
    try rt.pushOperand(.{ .f32 = 0.0 });
    try driveOne(&rt, &t, .@"f32.div", 0, 0);
    try testing.expect(std.math.isInf(rt.popOperand().f32));
}

test "f32.min: NaN propagates" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    try rt.pushOperand(.{ .f32 = 1.0 });
    try driveOne(&rt, &t, .@"f32.min", 0, 0);
    try testing.expect(std.math.isNan(rt.popOperand().f32));
}

test "f64.sqrt: 4.0 → 2.0" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 4.0 });
    try driveOne(&rt, &t, .@"f64.sqrt", 0, 0);
    try testing.expectEqual(@as(f64, 2.0), rt.popOperand().f64);
}

test "f64.copysign: magnitude from a, sign from b" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 3.0 });
    try rt.pushOperand(.{ .f64 = -1.0 });
    try driveOne(&rt, &t, .@"f64.copysign", 0, 0);
    try testing.expectEqual(@as(f64, -3.0), rt.popOperand().f64);
}

test "i32.wrap_i64 takes the low 32 bits" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .u64 = 0xDEAD_BEEF_CAFE_BABE });
    try driveOne(&rt, &t, .@"i32.wrap_i64", 0, 0);
    try testing.expectEqual(@as(u32, 0xCAFE_BABE), rt.popOperand().u32);
}

test "i64.extend_i32_s sign-extends" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = -1 });
    try driveOne(&rt, &t, .@"i64.extend_i32_s", 0, 0);
    try testing.expectEqual(@as(i64, -1), rt.popOperand().i64);
}

test "i64.extend_i32_u zero-extends" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = -1 });
    try driveOne(&rt, &t, .@"i64.extend_i32_u", 0, 0);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), rt.popOperand().u64);
}

test "i32.trunc_f32_s: NaN traps InvalidConversionToInt" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = std.math.nan(f32) });
    try testing.expectError(Trap.InvalidConversionToInt, driveOne(&rt, &t, .@"i32.trunc_f32_s", 0, 0));
}

test "i32.trunc_f64_s: out of range traps IntOverflow" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 1e30 });
    try testing.expectError(Trap.IntOverflow, driveOne(&rt, &t, .@"i32.trunc_f64_s", 0, 0));
}

test "i32.trunc_f32_u: -0.5 truncates to 0" {
    // Wasm spec: trunc_*_u accepts inputs in (-1, max+1) range.
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = -0.5 });
    try driveOne(&rt, &t, .@"i32.trunc_f32_u", 0, 0);
    try testing.expectEqual(@as(u32, 0), rt.popOperand().u32);
}

test "f32.demote_f64 + f64.promote_f32 round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f64 = 3.5 });
    try driveOne(&rt, &t, .@"f32.demote_f64", 0, 0);
    try driveOne(&rt, &t, .@"f64.promote_f32", 0, 0);
    try testing.expectEqual(@as(f64, 3.5), rt.popOperand().f64);
}

test "i32.reinterpret_f32 + f32.reinterpret_i32: bit-preserving" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .f32 = 1.0 });
    try driveOne(&rt, &t, .@"i32.reinterpret_f32", 0, 0);
    try testing.expectEqual(@as(u32, 0x3F800000), rt.popOperand().u32);

    try rt.pushOperand(.{ .u32 = 0x3F800000 });
    try driveOne(&rt, &t, .@"f32.reinterpret_i32", 0, 0);
    try testing.expectEqual(@as(f32, 1.0), rt.popOperand().f32);
}

test "call: invokes callee, args pop and result push round-trip" {
    // callee: fn (i32, i32) -> i32 { local.get 0 ; local.get 1 ; i32.add ; end }
    const param_arr = [_]zir.ValType{ .i32, .i32 };
    const result_arr = [_]zir.ValType{.i32};
    var callee = zir.ZirFunc.init(0, .{ .params = &param_arr, .results = &result_arr }, &.{});
    defer callee.deinit(testing.allocator);
    try callee.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"local.get", .payload = 1, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"i32.add", .payload = 0, .extra = 0 });
    try callee.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    // caller: fn () -> i32 { i32.const 5 ; i32.const 7 ; call 0 ; end }
    var caller = zir.ZirFunc.init(1, .{ .params = &.{}, .results = &result_arr }, &.{});
    defer caller.deinit(testing.allocator);
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 5, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"call", .payload = 0, .extra = 0 });
    try caller.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    const funcs = [_]*const zir.ZirFunc{&callee};
    rt.funcs = &funcs;

    try rt.pushFrame(.{ .sig = caller.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &caller });
    defer _ = rt.popFrame();
    try dispatch_loop.run(&rt, &t, caller.instrs.items);

    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 12), rt.popOperand().u32);
}

test "block + end: arity=0, operand stack restored" {
    // ZirFunc with 1 block (start=0, end=2). instrs: [block, i32.const 7, end, i32.const 99, end]
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 2 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"block", .payload = 0, .extra = 0x40 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 7)), .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = @bitCast(@as(i32, 99)), .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // After block (arity=0): operand stack popped back to 0, then i32.const 99
    // pushed, then function-level end fires.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(i32, 99), rt.popOperand().i32);
}

test "br 0 from inside block: jumps past end" {
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &.{} }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .block, .start_inst = 0, .end_inst = 4 });
    // block; i32.const 1; br 0; i32.const 2 (skipped); end; i32.const 3; end
    try fnz.instrs.append(testing.allocator, .{ .op = .@"block", .payload = 0, .extra = 0x40 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"br", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 3, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);

    // br 0 (arity=0) discarded the i32.const 1 result. Then i32.const 3 pushed.
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 3), rt.popOperand().u32);
}

test "if cond=0 skips to end; cond=1 runs then-branch" {
    // (if (then i32.const 1) (else i32.const 2)) — sig: () -> i32
    // instrs: i32.const cond ; if ; i32.const 1 ; else ; i32.const 2 ; end ; end
    const i32_arr = [_]zir.ValType{.i32};
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer fnz.deinit(testing.allocator);
    try fnz.blocks.append(testing.allocator, .{ .kind = .else_open, .start_inst = 1, .end_inst = 5, .else_inst = 3 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 1, .extra = 0 }); // cond
    try fnz.instrs.append(testing.allocator, .{ .op = .@"if", .payload = 0, .extra = 0x7F }); // if i32
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 11, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"else", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 22, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);
    try testing.expectEqual(@as(u32, 11), rt.popOperand().u32);
}

test "return: ends function execution and produces sig.results" {
    const i32_arr = [_]zir.ValType{.i32};
    var fnz = zir.ZirFunc.init(0, .{ .params = &.{}, .results = &i32_arr }, &.{});
    defer fnz.deinit(testing.allocator);
    // i32.const 7 ; return ; i32.const 99 ; end
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 7, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"return", .payload = 0, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"i32.const", .payload = 99, .extra = 0 });
    try fnz.instrs.append(testing.allocator, .{ .op = .@"end", .payload = 0, .extra = 0 });

    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushFrame(.{ .sig = fnz.sig, .locals = &.{}, .operand_base = 0, .pc = 0, .func = &fnz });
    defer _ = rt.popFrame();

    try dispatch_loop.run(&rt, &t, fnz.instrs.items);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
    try testing.expectEqual(@as(u32, 7), rt.popOperand().u32);
}

test "unreachable: traps Trap.Unreachable" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try testing.expectError(Trap.Unreachable, driveOne(&rt, &t, .@"unreachable", 0, 0));
}

test "nop: leaves stack untouched" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 7 });
    try driveOne(&rt, &t, .nop, 0, 0);
    try testing.expectEqual(@as(u32, 1), rt.operand_len);
}

test "select: cond != 0 picks first operand" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 11 }); // a
    try rt.pushOperand(.{ .i32 = 22 }); // b
    try rt.pushOperand(.{ .i32 = 1 }); // cond
    try driveOne(&rt, &t, .select, 0, 0);
    try testing.expectEqual(@as(i32, 11), rt.popOperand().i32);
}

test "select: cond == 0 picks second operand" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();
    try rt.pushOperand(.{ .i32 = 11 });
    try rt.pushOperand(.{ .i32 = 22 });
    try rt.pushOperand(.{ .i32 = 0 });
    try driveOne(&rt, &t, .select, 0, 0);
    try testing.expectEqual(@as(i32, 22), rt.popOperand().i32);
}

test "globals: get/set round-trip" {
    var t = DispatchTable.init();
    register(&t);
    var rt = Runtime.init(testing.allocator);
    defer rt.deinit();

    var globals = [_]Value{Value.fromI32(0)};
    rt.globals = &globals;
    defer rt.globals = &.{}; // prevent deinit from freeing the stack slice

    try driveOne(&rt, &t, .@"i32.const", @bitCast(@as(i32, 17)), 0);
    try driveOne(&rt, &t, .@"global.set", 0, 0);
    try testing.expectEqual(@as(i32, 17), globals[0].i32);

    try driveOne(&rt, &t, .@"global.get", 0, 0);
    try testing.expectEqual(@as(i32, 17), rt.popOperand().i32);
}
