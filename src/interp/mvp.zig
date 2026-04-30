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
}

inline fn op(t: ZirOp) usize {
    return @intFromEnum(t);
}

// ============================================================
// Handlers
// ============================================================

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
