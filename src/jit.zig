// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! ARM64 JIT compiler — compiles register IR to native machine code.
//! Design: D105 in .dev/decisions.md.
//!
//! Tiered execution: Tier 2 (RegInstr interpreter) → Tier 3 (ARM64 JIT).
//! Compiles hot functions after a call count threshold.
//!
//! Register mapping (ARM64):
//!   x19: regs_ptr (virtual register file base)
//!   x20: vm_ptr
//!   x21: instance_ptr
//!   x22-x26: virtual r0-r4 (callee-saved)
//!   x27: mem_base (linear memory base pointer, callee-saved)
//!   x28: mem_size (linear memory size in bytes, callee-saved)
//!   x9-x15:  virtual r5-r11 (caller-saved)
//!   x8:      scratch
//!
//! JIT function signature (C calling convention):
//!   fn(regs: [*]u64, vm: *anyopaque, instance: *anyopaque) callconv(.c) u64
//!   Returns: 0 = success, non-zero = WasmError ordinal

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const regalloc_mod = @import("regalloc.zig");
const RegInstr = regalloc_mod.RegInstr;
const RegFunc = regalloc_mod.RegFunc;
const store_mod = @import("store.zig");
const Instance = @import("instance.zig").Instance;
const ValType = @import("opcode.zig").ValType;
const WasmMemory = @import("memory.zig").Memory;
const trace_mod = @import("trace.zig");
const predecode_mod = @import("predecode.zig");
const platform = @import("platform.zig");

/// JIT-compiled function pointer type.
/// Args: regs_ptr, vm_ptr, instance_ptr.
/// Returns: 0 on success, non-zero WasmError ordinal on failure.
pub const JitFn = *const fn ([*]u64, *anyopaque, *anyopaque) callconv(.c) u64;

/// Compiled native code for a single function.
pub const JitCode = struct {
    buf: []align(std.heap.page_size_min) u8,
    entry: JitFn,
    code_len: u32,
    /// Offset of the OOB error return stub within buf (for signal handler recovery).
    oob_exit_offset: u32 = 0,
    /// OSR (On-Stack Replacement) entry: alternative entry point that jumps to a
    /// loop body, bypassing the function's init section. Used for back-edge JIT
    /// of functions with reentry guards (C/C++ init patterns).
    osr_entry: ?JitFn = null,

    pub fn deinit(self: *JitCode, alloc: Allocator) void {
        platform.freePages(self.buf);
        alloc.destroy(self);
    }
};

/// Returns true if JIT compilation is supported on the current CPU architecture and host OS.
pub fn jitSupported() bool {
    return switch (builtin.os.tag) {
        .linux, .macos => builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64,
        .windows => builtin.cpu.arch == .x86_64,
        else => false,
    };
}

/// Hot function call threshold — JIT after this many calls.
pub const HOT_THRESHOLD: u32 = 10;

/// Back-edge threshold — JIT after this many loop iterations in a single call.
pub const BACK_EDGE_THRESHOLD: u32 = 1000;

/// Maximum IR instruction count for JIT compilation.
/// Functions exceeding this limit fall back to the register IR interpreter.
/// Prevents single-pass regalloc from producing excessively spill-heavy code
/// for very large library functions (e.g., vfprintf at 3000+ IR instrs).
pub const MAX_JIT_IR_INSTRS: u32 = 1500;

// ================================================================
// ARM64 instruction encoding
// ================================================================

const a64 = struct {
    // --- Data processing (register) ---

    /// ADD Xd, Xn, Xm (64-bit)
    fn add64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// ADD Wd, Wn, Wm (32-bit)
    fn add32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x0B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// SUB Xd, Xn, Xm (64-bit)
    fn sub64(rd: u5, rn: u5, rm: u5) u32 {
        return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// SUB Wd, Wn, Wm (32-bit)
    fn sub32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x4B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// MUL Wd, Wn, Wm (32-bit, alias for MADD Wd, Wn, Wm, WZR)
    fn mul32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x1B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// MUL Xd, Xn, Xm (64-bit)
    fn mul64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x9B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// AND Wd, Wn, Wm (32-bit)
    fn and32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x0A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// AND Xd, Xn, Xm (64-bit)
    fn and64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x8A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// ORR Wd, Wn, Wm (32-bit)
    fn orr32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x2A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// ORR Xd, Xn, Xm (64-bit)
    fn orr64(rd: u5, rn: u5, rm: u5) u32 {
        return 0xAA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// EOR Wd, Wn, Wm (32-bit)
    fn eor32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x4A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// EOR Xd, Xn, Xm (64-bit)
    fn eor64(rd: u5, rn: u5, rm: u5) u32 {
        return 0xCA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// LSLV Wd, Wn, Wm (32-bit variable shift left)
    fn lslv32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x1AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// ASRV Wd, Wn, Wm (32-bit arithmetic shift right)
    fn asrv32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x1AC02800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// LSRV Wd, Wn, Wm (32-bit logical shift right)
    fn lsrv32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x1AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// LSLV Xd, Xn, Xm (64-bit)
    fn lslv64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x9AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// ASRV Xd, Xn, Xm (64-bit)
    fn asrv64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x9AC02800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// LSRV Xd, Xn, Xm (64-bit)
    fn lsrv64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x9AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// RORV Wd, Wn, Wm (32-bit rotate right)
    fn rorv32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x1AC02C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// RORV Xd, Xn, Xm (64-bit rotate right)
    fn rorv64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x9AC02C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// CLZ Wd, Wn (32-bit count leading zeros)
    fn clz32(rd: u5, rn: u5) u32 {
        return 0x5AC01000 | (@as(u32, rn) << 5) | rd;
    }

    /// CLZ Xd, Xn (64-bit)
    fn clz64(rd: u5, rn: u5) u32 {
        return 0xDAC01000 | (@as(u32, rn) << 5) | rd;
    }

    /// RBIT Wd, Wn (32-bit reverse bits)
    fn rbit32(rd: u5, rn: u5) u32 {
        return 0x5AC00000 | (@as(u32, rn) << 5) | rd;
    }

    /// RBIT Xd, Xn (64-bit)
    fn rbit64(rd: u5, rn: u5) u32 {
        return 0xDAC00000 | (@as(u32, rn) << 5) | rd;
    }

    /// REV Wd, Wn (32-bit reverse bytes — for popcount trick)
    fn neg32(rd: u5, rn: u5) u32 {
        // NEG Wd, Wn = SUB Wd, WZR, Wn
        return sub32(rd, 31, rn);
    }

    /// NEG Xd, Xn = SUB Xd, XZR, Xn
    fn neg64(rd: u5, rn: u5) u32 {
        return sub64(rd, 31, rn);
    }

    /// SDIV Wd, Wn, Wm (32-bit signed divide)
    fn sdiv32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x1AC00C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// UDIV Wd, Wn, Wm (32-bit unsigned divide)
    fn udiv32(rd: u5, rn: u5, rm: u5) u32 {
        return 0x1AC00800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// SDIV Xd, Xn, Xm (64-bit signed divide)
    fn sdiv64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x9AC00C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// UDIV Xd, Xn, Xm (64-bit unsigned divide)
    fn udiv64(rd: u5, rn: u5, rm: u5) u32 {
        return 0x9AC00800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd;
    }

    /// UMULL Xd, Wn, Wm — unsigned 32×32→64 multiply (alias for UMADDL Xd, Wn, Wm, XZR)
    fn umull(xd: u5, wn: u5, wm: u5) u32 {
        return 0x9BA07C00 | (@as(u32, wm) << 16) | (@as(u32, wn) << 5) | xd;
    }

    /// MSUB Wd, Wn, Wm, Wa (rd = ra - rn*rm, 32-bit) — for remainder
    fn msub32(rd: u5, rn: u5, rm: u5, ra: u5) u32 {
        return 0x1B008000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | rd;
    }

    /// MSUB Xd, Xn, Xm, Xa (64-bit)
    fn msub64(rd: u5, rn: u5, rm: u5, ra: u5) u32 {
        return 0x9B008000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | rd;
    }

    // --- Data processing (immediate) ---

    /// ADD Xd, Xn, #imm12 (64-bit)
    fn addImm64(rd: u5, rn: u5, imm12: u12) u32 {
        return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
    }

    /// ADD Wd, Wn, #imm12 (32-bit)
    fn addImm32(rd: u5, rn: u5, imm12: u12) u32 {
        return 0x11000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
    }

    /// SUB Xd, Xn, #imm12 (64-bit)
    fn subImm64(rd: u5, rn: u5, imm12: u12) u32 {
        return 0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
    }

    /// SUBS Xd, Xn, #imm12 (64-bit, sets flags)
    fn subsImm64(rd: u5, rn: u5, imm12: u12) u32 {
        return 0xF1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
    }

    /// SUB Wd, Wn, #imm12 (32-bit)
    fn subImm32(rd: u5, rn: u5, imm12: u12) u32 {
        return 0x51000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rd;
    }

    // --- Comparison ---

    /// CMP Xn, Xm (SUBS XZR, Xn, Xm, 64-bit)
    fn cmp64(rn: u5, rm: u5) u32 {
        return 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
    }

    /// CMP Wn, Wm (SUBS WZR, Wn, Wm, 32-bit)
    fn cmp32(rn: u5, rm: u5) u32 {
        return 0x6B00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
    }

    /// CMP Xn, #imm12 (64-bit)
    fn cmpImm64(rn: u5, imm12: u12) u32 {
        return 0xF100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
    }

    /// CMP Wn, #imm12 (32-bit)
    fn cmpImm32(rn: u5, imm12: u12) u32 {
        return 0x7100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
    }

    /// CSEL Xd, Xn, Xm, cond — conditional select (64-bit).
    fn csel64(rd: u5, rn: u5, rm: u5, cond: Cond) u32 {
        return 0x9A800000 | (@as(u32, rm) << 16) | (@as(u32, @intFromEnum(cond)) << 12) | (@as(u32, rn) << 5) | rd;
    }

    /// CSET Wd, <cond> — set register to 1 if condition, 0 otherwise.
    /// Encoded as CSINC Wd, WZR, WZR, <inv_cond>.
    fn cset32(rd: u5, cond: Cond) u32 {
        const inv = cond.invert();
        return 0x1A9F07E0 | (@as(u32, @intFromEnum(inv)) << 12) | rd;
    }

    /// CSET Xd, <cond> (64-bit)
    fn cset64(rd: u5, cond: Cond) u32 {
        const inv = cond.invert();
        return 0x9A9F07E0 | (@as(u32, @intFromEnum(inv)) << 12) | rd;
    }

    // --- Branches ---

    /// B.cond — conditional branch, offset in instructions.
    fn bCond(cond: Cond, offset: i19) u32 {
        const imm: u19 = @bitCast(offset);
        return 0x54000000 | (@as(u32, imm) << 5) | @intFromEnum(cond);
    }

    /// B — unconditional branch, offset in instructions.
    fn b(offset: i26) u32 {
        const imm: u26 = @bitCast(offset);
        return 0x14000000 | @as(u32, imm);
    }

    /// BL — branch with link, offset in instructions.
    fn bl(offset: i26) u32 {
        const imm: u26 = @bitCast(offset);
        return 0x94000000 | @as(u32, imm);
    }

    /// BLR Xn — branch with link to register.
    fn blr(rn: u5) u32 {
        return 0xD63F0000 | (@as(u32, rn) << 5);
    }

    /// CBZ Wn, offset — compare and branch if zero (32-bit).
    fn cbz32(rt: u5, offset: i19) u32 {
        const imm: u19 = @bitCast(offset);
        return 0x34000000 | (@as(u32, imm) << 5) | rt;
    }

    /// CBNZ Wn, offset — compare and branch if not zero (32-bit).
    fn cbnz32(rt: u5, offset: i19) u32 {
        const imm: u19 = @bitCast(offset);
        return 0x35000000 | (@as(u32, imm) << 5) | rt;
    }

    /// CBZ Xn, offset (64-bit).
    fn cbz64(rt: u5, offset: i19) u32 {
        const imm: u19 = @bitCast(offset);
        return 0xB4000000 | (@as(u32, imm) << 5) | rt;
    }

    /// CBNZ Xn, offset (64-bit).
    fn cbnz64(rt: u5, offset: i19) u32 {
        const imm: u19 = @bitCast(offset);
        return 0xB5000000 | (@as(u32, imm) << 5) | rt;
    }

    /// RET (via x30).
    fn ret_() u32 {
        return 0xD65F03C0;
    }

    // --- Load/Store ---

    /// LDR Xt, [Xn, #imm] — load 64-bit, imm is byte offset (must be 8-aligned).
    fn ldr64(rt: u5, rn: u5, imm_bytes: u16) u32 {
        const imm12: u12 = @intCast(imm_bytes / 8);
        return 0xF9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
    }

    /// STR Xt, [Xn, #imm] — store 64-bit.
    fn str64(rt: u5, rn: u5, imm_bytes: u16) u32 {
        const imm12: u12 = @intCast(imm_bytes / 8);
        return 0xF9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | rt;
    }

    // --- Register-offset loads (for Wasm memory access) ---

    /// LDR Wt, [Xn, Xm] — load 32-bit, register offset.
    fn ldr32Reg(rt: u5, rn: u5, rm: u5) u32 {
        return 0xB8606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDR Xt, [Xn, Xm] — load 64-bit, register offset.
    fn ldr64Reg(rt: u5, rn: u5, rm: u5) u32 {
        return 0xF8606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDR Dt, [Xn, Xm] — load 64-bit FP, register offset.
    fn ldrFp64Reg(dt: u5, xn: u5, xm: u5) u32 {
        return 0xFC606800 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | dt;
    }

    /// STR Dt, [Xn, Xm] — store 64-bit FP, register offset.
    fn strFp64Reg(dt: u5, xn: u5, xm: u5) u32 {
        return 0xFC206800 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | dt;
    }

    /// LDRB Wt, [Xn, Xm] — load byte unsigned, register offset.
    fn ldrbReg(rt: u5, rn: u5, rm: u5) u32 {
        return 0x38606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDRSB Wt, [Xn, Xm] — load byte signed, register offset.
    fn ldrsbReg(rt: u5, rn: u5, rm: u5) u32 {
        return 0x38E06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDRSH Wt, [Xn, Xm] — load halfword signed to 32-bit, register offset.
    fn ldrshReg(rt: u5, rn: u5, rm: u5) u32 {
        // size=01, opc=11 (signed to Wt)
        return 0x78E06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDRH Wt, [Xn, Xm] — load halfword unsigned, register offset.
    fn ldrhReg(rt: u5, rn: u5, rm: u5) u32 {
        return 0x78606800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDRSW Xt, [Xn, Xm] — load word signed to 64-bit, register offset.
    fn ldrswReg(rt: u5, rn: u5, rm: u5) u32 {
        return 0xB8A06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// STR Wt, [Xn, Xm] — store 32-bit, register offset.
    fn str32Reg(rt: u5, rn: u5, rm: u5) u32 {
        return 0xB8206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// STR Xt, [Xn, Xm] — store 64-bit, register offset.
    fn str64Reg(rt: u5, rn: u5, rm: u5) u32 {
        return 0xF8206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// STRB Wt, [Xn, Xm] — store byte, register offset.
    fn strbReg(rt: u5, rn: u5, rm: u5) u32 {
        return 0x38206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// STRH Wt, [Xn, Xm] — store halfword, register offset.
    fn strhReg(rt: u5, rn: u5, rm: u5) u32 {
        return 0x78206800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDRSB Xt, [Xn, Xm] — load byte signed to 64-bit, register offset.
    fn ldrsb64Reg(rt: u5, rn: u5, rm: u5) u32 {
        return 0x38A06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// LDRSH Xt, [Xn, Xm] — load halfword signed to 64-bit, register offset.
    fn ldrsh64Reg(rt: u5, rn: u5, rm: u5) u32 {
        return 0x78A06800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rt;
    }

    /// STP Xt1, Xt2, [Xn, #imm]! — store pair, pre-indexed.
    fn stpPre(rt1: u5, rt2: u5, rn: u5, imm7: i7) u32 {
        const imm: u7 = @bitCast(imm7);
        return 0xA9800000 | (@as(u32, imm) << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | rt1;
    }

    /// LDP Xt1, Xt2, [Xn], #imm — load pair, post-indexed.
    fn ldpPost(rt1: u5, rt2: u5, rn: u5, imm7: i7) u32 {
        const imm: u7 = @bitCast(imm7);
        return 0xA8C00000 | (@as(u32, imm) << 15) | (@as(u32, rt2) << 10) | (@as(u32, rn) << 5) | rt1;
    }

    /// STP Dt1, Dt2, [Xn, #imm]! — store FP pair, pre-indexed (imm in units of 8 bytes).
    fn stpFpPre(dt1: u5, dt2: u5, xn: u5, imm7: i7) u32 {
        const imm: u7 = @bitCast(imm7);
        return 0x6D800000 | (@as(u32, imm) << 15) | (@as(u32, dt2) << 10) | (@as(u32, xn) << 5) | dt1;
    }

    /// LDP Dt1, Dt2, [Xn], #imm — load FP pair, post-indexed (imm in units of 8 bytes).
    fn ldpFpPost(dt1: u5, dt2: u5, xn: u5, imm7: i7) u32 {
        const imm: u7 = @bitCast(imm7);
        return 0x6CC00000 | (@as(u32, imm) << 15) | (@as(u32, dt2) << 10) | (@as(u32, xn) << 5) | dt1;
    }

    // --- Move ---

    /// MOV Xd, Xm (ORR Xd, XZR, Xm)
    fn mov64(rd: u5, rm: u5) u32 {
        return orr64(rd, 31, rm);
    }

    /// MOV Wd, Wm (ORR Wd, WZR, Wm)
    fn mov32(rd: u5, rm: u5) u32 {
        return orr32(rd, 31, rm);
    }

    /// MOVZ Xd, #imm16, LSL #(shift*16)
    fn movz64(rd: u5, imm16: u16, shift: u2) u32 {
        return 0xD2800000 | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | rd;
    }

    /// MOVZ Wd, #imm16, LSL #(shift*16)
    fn movz32(rd: u5, imm16: u16, shift: u2) u32 {
        return 0x52800000 | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | rd;
    }

    /// MOVK Xd, #imm16, LSL #(shift*16)
    fn movk64(rd: u5, imm16: u16, shift: u2) u32 {
        return 0xF2800000 | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | rd;
    }

    /// MOVN Wd, #imm16 — move wide with NOT (for negative constants)
    fn movn32(rd: u5, imm16: u16) u32 {
        return 0x12800000 | (@as(u32, imm16) << 5) | rd;
    }

    /// MOVN Xd, #imm16{, LSL #shift} — 64-bit move wide with NOT
    fn movn64(rd: u5, imm16: u16, shift: u2) u32 {
        return 0x92800000 | (@as(u32, shift) << 21) | (@as(u32, imm16) << 5) | rd;
    }

    // --- Sign/zero extension ---

    /// SXTW Xd, Wn — sign-extend 32-bit to 64-bit (SBFM Xd, Xn, #0, #31)
    fn sxtw(rd: u5, rn: u5) u32 {
        return 0x93407C00 | (@as(u32, rn) << 5) | rd;
    }

    /// UXTW — zero-extend 32-bit to 64-bit (MOV Wd, Wn clears upper 32)
    /// On ARM64, writing to Wd automatically zeros the upper 32 bits.
    /// So UXTW is just MOV Wd, Wn.
    fn uxtw(rd: u5, rn: u5) u32 {
        return mov32(rd, rn);
    }

    /// Condition codes.
    const Cond = enum(u4) {
        eq = 0b0000, // equal
        ne = 0b0001, // not equal
        hs = 0b0010, // unsigned >= / carry set
        lo = 0b0011, // unsigned < / carry clear
        mi = 0b0100, // minus / negative (N=1) — used for FP less-than
        pl = 0b0101, // plus / positive (N=0) — invert of mi
        vs = 0b0110, // overflow set (FP unordered / NaN)
        vc = 0b0111, // overflow clear
        hi = 0b1000, // unsigned >
        ls = 0b1001, // unsigned <= / FP less-or-equal
        ge = 0b1010, // signed >= / FP greater-or-equal
        lt = 0b1011, // signed <
        gt = 0b1100, // signed > / FP greater-than
        le = 0b1101, // signed <=

        fn invert(self: Cond) Cond {
            return @enumFromInt(@intFromEnum(self) ^ 1);
        }

        /// Swap operand order: a op b → b op a (e.g., GT → LT, GE → LE)
        fn swap(self: Cond) Cond {
            return switch (self) {
                .eq => .eq,
                .ne => .ne,
                .hi => .lo,
                .lo => .hi,
                .hs => .ls,
                .ls => .hs,
                .gt => .lt,
                .lt => .gt,
                .ge => .le,
                .le => .ge,
                .mi => .mi,
                .pl => .pl,
                .vs => .vs,
                .vc => .vc,
            };
        }
    };

    /// Load a 64-bit immediate into register using MOVZ/MOVN + MOVK sequence.
    fn loadImm64(rd: u5, value: u64) [4]u32 {
        var instrs: [4]u32 = undefined;
        var count: usize = 0;

        const inv = ~value;
        const w0: u16 = @truncate(value);
        const w1: u16 = @truncate(value >> 16);
        const w2: u16 = @truncate(value >> 32);
        const w3: u16 = @truncate(value >> 48);
        const iw0: u16 = @truncate(inv);
        const iw1: u16 = @truncate(inv >> 16);
        const iw2: u16 = @truncate(inv >> 32);
        const iw3: u16 = @truncate(inv >> 48);

        // Count non-zero halfwords for MOVZ vs MOVN
        var nz_pos: u8 = 0;
        if (w0 != 0) nz_pos += 1;
        if (w1 != 0) nz_pos += 1;
        if (w2 != 0) nz_pos += 1;
        if (w3 != 0) nz_pos += 1;
        var nz_neg: u8 = 0;
        if (iw0 != 0) nz_neg += 1;
        if (iw1 != 0) nz_neg += 1;
        if (iw2 != 0) nz_neg += 1;
        if (iw3 != 0) nz_neg += 1;

        if (nz_neg < nz_pos) {
            // MOVN + MOVK sequence is shorter
            instrs[0] = movn64(rd, iw0, 0);
            count = 1;
            if (iw1 != 0) { instrs[count] = movk64(rd, w1, 1); count += 1; }
            if (iw2 != 0) { instrs[count] = movk64(rd, w2, 2); count += 1; }
            if (iw3 != 0) { instrs[count] = movk64(rd, w3, 3); count += 1; }
        } else {
            // MOVZ + MOVK sequence
            instrs[0] = movz64(rd, w0, 0);
            count = 1;
            if (w1 != 0) { instrs[count] = movk64(rd, w1, 1); count += 1; }
            if (w2 != 0) { instrs[count] = movk64(rd, w2, 2); count += 1; }
            if (w3 != 0) { instrs[count] = movk64(rd, w3, 3); count += 1; }
        }
        // Pad remaining with NOPs
        while (count < 4) : (count += 1) {
            instrs[count] = nop();
        }
        return instrs;
    }

    /// NOP
    fn nop() u32 {
        return 0xD503201F;
    }

    /// UBFM Xd, Xn, #immr, #imms — unsigned bitfield move (used for LSR)
    /// LSR Xd, Xn, #shift  ≡  UBFM Xd, Xn, #shift, #63
    fn lsr64Imm(xd: u5, xn: u5, shift: u6) u32 {
        return 0xD340FC00 | (@as(u32, shift) << 16) | (@as(u32, xn) << 5) | xd;
    }

    /// LSR Wd, Wn, #shift  ≡  UBFM Wd, Wn, #shift, #31
    fn lsr32Imm(wd: u5, wn: u5, shift: u5) u32 {
        return 0x53007C00 | (@as(u32, shift) << 16) | (@as(u32, wn) << 5) | wd;
    }

    // --- NEON/AdvSIMD ---

    /// CNT V<d>.8B, V<n>.8B — count set bits per byte (8-bit lanes)
    fn cntV8b(vd: u5, vn: u5) u32 {
        return 0x0E205800 | (@as(u32, vn) << 5) | vd;
    }

    /// ADDV Bd, V<n>.8B — add across vector (sum all bytes into scalar)
    fn addvB(vd: u5, vn: u5) u32 {
        return 0x0E31B800 | (@as(u32, vn) << 5) | vd;
    }

    // --- NEON v128 (128-bit SIMD) ---

    /// LDR Qt, [Xn, #imm] — load 128-bit vector, unsigned offset (imm is byte offset / 16)
    fn ldrQ(qt: u5, xn: u5, imm_div16: u12) u32 {
        return 0x3DC00000 | (@as(u32, imm_div16) << 10) | (@as(u32, xn) << 5) | qt;
    }

    /// STR Qt, [Xn, #imm] — store 128-bit vector, unsigned offset (imm is byte offset / 16)
    fn strQ(qt: u5, xn: u5, imm_div16: u12) u32 {
        return 0x3D800000 | (@as(u32, imm_div16) << 10) | (@as(u32, xn) << 5) | qt;
    }

    /// LDR Qt, [Xn, Xm] — load 128-bit vector, register offset
    fn ldrQreg(qt: u5, xn: u5, xm: u5) u32 {
        return 0x3CE06800 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | qt;
    }

    /// STR Qt, [Xn, Xm] — store 128-bit vector, register offset
    fn strQreg(qt: u5, xn: u5, xm: u5) u32 {
        return 0x3CA06800 | (@as(u32, xm) << 16) | (@as(u32, xn) << 5) | qt;
    }

    /// MOVI Vd.2D, #0 — zero 128-bit vector
    fn moviV2d_zero(vd: u5) u32 {
        return 0x6F00E400 | @as(u32, vd);
    }

    /// FADD Vd.4S, Vn.4S, Vm.4S — f32x4 add
    fn faddV4s(vd: u5, vn: u5, vm: u5) u32 {
        return 0x4E20D400 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// FSUB Vd.4S, Vn.4S, Vm.4S — f32x4 sub
    fn fsubV4s(vd: u5, vn: u5, vm: u5) u32 {
        return 0x4EA0D400 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// FMUL Vd.4S, Vn.4S, Vm.4S — f32x4 mul
    fn fmulV4s(vd: u5, vn: u5, vm: u5) u32 {
        return 0x6E20DC00 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// FDIV Vd.4S, Vn.4S, Vm.4S — f32x4 div
    fn fdivV4s(vd: u5, vn: u5, vm: u5) u32 {
        return 0x6E20FC00 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// ADD Vd.4S, Vn.4S, Vm.4S — i32x4 add
    fn addV4s(vd: u5, vn: u5, vm: u5) u32 {
        return 0x4EA08400 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// SUB Vd.4S, Vn.4S, Vm.4S — i32x4 sub
    fn subV4s(vd: u5, vn: u5, vm: u5) u32 {
        return 0x6EA08400 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// FADD Vd.2D, Vn.2D, Vm.2D — f64x2 add
    fn faddV2d(vd: u5, vn: u5, vm: u5) u32 {
        return 0x4E60D400 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// FMUL Vd.2D, Vn.2D, Vm.2D — f64x2 mul
    fn fmulV2d(vd: u5, vn: u5, vm: u5) u32 {
        return 0x6E60DC00 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// ORR Vd.16B, Vn.16B, Vm.16B — bitwise OR (v128.or)
    fn orrV16b(vd: u5, vn: u5, vm: u5) u32 {
        return 0x4EA01C00 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// AND Vd.16B, Vn.16B, Vm.16B — bitwise AND (v128.and)
    fn andV16b(vd: u5, vn: u5, vm: u5) u32 {
        return 0x4E201C00 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// EOR Vd.16B, Vn.16B, Vm.16B — bitwise XOR (v128.xor)
    fn eorV16b(vd: u5, vn: u5, vm: u5) u32 {
        return 0x6E201C00 | (@as(u32, vm) << 16) | (@as(u32, vn) << 5) | vd;
    }

    /// NOT Vd.16B, Vn.16B — bitwise NOT (v128.not)
    fn notV16b(vd: u5, vn: u5) u32 {
        return 0x6E205800 | (@as(u32, vn) << 5) | vd;
    }

    /// INS Vd.D[1], Xn — insert GP register into vector lane D[1] (upper 64 bits)
    fn insVdD1(vd: u5, xn: u5) u32 {
        return 0x4E180000 | (@as(u32, xn) << 5) | @as(u32, vd);
    }

    /// UMOV Xd, Vn.D[1] — extract vector lane D[1] to GP register
    fn umovXdD1(xd: u5, vn: u5) u32 {
        return 0x4E183C00 | (@as(u32, vn) << 5) | @as(u32, xd);
    }

    /// LDR Dt, [Xn, #imm] — load 64-bit FP/SIMD, unsigned offset (imm_bytes / 8)
    fn ldrFp64(dt: u5, xn: u5, imm_bytes: u16) u32 {
        const imm12: u12 = @intCast(imm_bytes / 8);
        return 0xFD400000 | (@as(u32, imm12) << 10) | (@as(u32, xn) << 5) | dt;
    }

    /// STR Dt, [Xn, #imm] — store 64-bit FP/SIMD, unsigned offset (imm_bytes / 8)
    fn strFp64(dt: u5, xn: u5, imm_bytes: u16) u32 {
        const imm12: u12 = @intCast(imm_bytes / 8);
        return 0xFD000000 | (@as(u32, imm12) << 10) | (@as(u32, xn) << 5) | dt;
    }

    /// MOV Vd.16B, Vn.16B — copy 128-bit vector (alias for ORR Vd, Vn, Vn)
    fn movV16b(vd: u5, vn: u5) u32 {
        return orrV16b(vd, vn, vn);
    }

    // --- Floating-point (double-precision, f64) ---

    /// FMOV Dd, Xn — move 64-bit GPR to FP register.
    fn fmovToFp64(dd: u5, xn: u5) u32 {
        return 0x9E670000 | (@as(u32, xn) << 5) | dd;
    }

    /// FMOV Xd, Dn — move FP register to 64-bit GPR.
    fn fmovToGp64(xd: u5, dn: u5) u32 {
        return 0x9E660000 | (@as(u32, dn) << 5) | xd;
    }

    /// FMOV Dd, Dn — copy between FP registers (scalar f64).
    fn fmovDD(dd: u5, dn: u5) u32 {
        return 0x1E604000 | (@as(u32, dn) << 5) | dd;
    }

    /// FADD Dd, Dn, Dm (f64)
    fn fadd64(dd: u5, dn: u5, dm: u5) u32 {
        return 0x1E602800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd;
    }

    /// FSUB Dd, Dn, Dm (f64)
    fn fsub64(dd: u5, dn: u5, dm: u5) u32 {
        return 0x1E603800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd;
    }

    /// FMUL Dd, Dn, Dm (f64)
    fn fmul64(dd: u5, dn: u5, dm: u5) u32 {
        return 0x1E600800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd;
    }

    /// FDIV Dd, Dn, Dm (f64)
    fn fdiv64(dd: u5, dn: u5, dm: u5) u32 {
        return 0x1E601800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd;
    }

    /// FSQRT Dd, Dn (f64)
    fn fsqrt64(dd: u5, dn: u5) u32 {
        return 0x1E61C000 | (@as(u32, dn) << 5) | dd;
    }

    /// FABS Dd, Dn (f64)
    fn fabs64(dd: u5, dn: u5) u32 {
        return 0x1E60C000 | (@as(u32, dn) << 5) | dd;
    }

    /// FNEG Dd, Dn (f64)
    fn fneg64(dd: u5, dn: u5) u32 {
        return 0x1E614000 | (@as(u32, dn) << 5) | dd;
    }

    /// FMIN Dd, Dn, Dm (f64) — IEEE 754 minimum
    fn fmin64(dd: u5, dn: u5, dm: u5) u32 {
        return 0x1E605800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd;
    }

    /// FMAX Dd, Dn, Dm (f64) — IEEE 754 maximum
    fn fmax64(dd: u5, dn: u5, dm: u5) u32 {
        return 0x1E604800 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5) | dd;
    }

    /// FCMP Dn, Dm (f64) — compare, sets NZCV flags.
    fn fcmp64(dn: u5, dm: u5) u32 {
        return 0x1E602000 | (@as(u32, dm) << 16) | (@as(u32, dn) << 5);
    }

    /// FCVT Sd, Dn — convert f64 to f32 (double to single)
    fn fcvt_s_d(sd: u5, dn: u5) u32 {
        return 0x1E624000 | (@as(u32, dn) << 5) | sd;
    }

    /// FCVT Dd, Sn — convert f32 to f64 (single to double)
    fn fcvt_d_s(dd: u5, sn: u5) u32 {
        return 0x1E22C000 | (@as(u32, sn) << 5) | dd;
    }

    /// FMOV Sd, Wn — move 32-bit GPR to single FP register.
    fn fmovToFp32(sd: u5, wn: u5) u32 {
        return 0x1E270000 | (@as(u32, wn) << 5) | sd;
    }

    /// FMOV Wd, Sn — move single FP register to 32-bit GPR.
    fn fmovToGp32(wd: u5, sn: u5) u32 {
        return 0x1E260000 | (@as(u32, sn) << 5) | wd;
    }

    // --- Floating-point (single-precision, f32) ---

    /// FADD Sd, Sn, Sm (f32)
    fn fadd32(sd: u5, sn: u5, sm: u5) u32 {
        return 0x1E202800 | (@as(u32, sm) << 16) | (@as(u32, sn) << 5) | sd;
    }

    /// FSUB Sd, Sn, Sm (f32)
    fn fsub32(sd: u5, sn: u5, sm: u5) u32 {
        return 0x1E203800 | (@as(u32, sm) << 16) | (@as(u32, sn) << 5) | sd;
    }

    /// FMUL Sd, Sn, Sm (f32)
    fn fmul32(sd: u5, sn: u5, sm: u5) u32 {
        return 0x1E200800 | (@as(u32, sm) << 16) | (@as(u32, sn) << 5) | sd;
    }

    /// FDIV Sd, Sn, Sm (f32)
    fn fdiv32(sd: u5, sn: u5, sm: u5) u32 {
        return 0x1E201800 | (@as(u32, sm) << 16) | (@as(u32, sn) << 5) | sd;
    }

    /// FSQRT Sd, Sn (f32)
    fn fsqrt32(sd: u5, sn: u5) u32 {
        return 0x1E21C000 | (@as(u32, sn) << 5) | sd;
    }

    /// FABS Sd, Sn (f32)
    fn fabs32(sd: u5, sn: u5) u32 {
        return 0x1E20C000 | (@as(u32, sn) << 5) | sd;
    }

    /// FNEG Sd, Sn (f32)
    fn fneg32(sd: u5, sn: u5) u32 {
        return 0x1E214000 | (@as(u32, sn) << 5) | sd;
    }

    /// FMIN Sd, Sn, Sm (f32)
    fn fmin32(sd: u5, sn: u5, sm: u5) u32 {
        return 0x1E205800 | (@as(u32, sm) << 16) | (@as(u32, sn) << 5) | sd;
    }

    /// FMAX Sd, Sn, Sm (f32)
    fn fmax32(sd: u5, sn: u5, sm: u5) u32 {
        return 0x1E204800 | (@as(u32, sm) << 16) | (@as(u32, sn) << 5) | sd;
    }

    /// FCMP Sn, Sm (f32)
    fn fcmp32(sn: u5, sm: u5) u32 {
        return 0x1E202000 | (@as(u32, sm) << 16) | (@as(u32, sn) << 5);
    }

    // --- Float-to-integer truncation (FCVTZS/FCVTZU) ---
    /// FCVTZS Wd, Dn (f64 → i32 signed)
    fn fcvtzs_w_d(wd: u5, dn: u5) u32 { return 0x1E780000 | (@as(u32, dn) << 5) | wd; }
    /// FCVTZU Wd, Dn (f64 → u32)
    fn fcvtzu_w_d(wd: u5, dn: u5) u32 { return 0x1E790000 | (@as(u32, dn) << 5) | wd; }
    /// FCVTZS Xd, Dn (f64 → i64 signed)
    fn fcvtzs_x_d(xd: u5, dn: u5) u32 { return 0x9E780000 | (@as(u32, dn) << 5) | xd; }
    /// FCVTZU Xd, Dn (f64 → u64)
    fn fcvtzu_x_d(xd: u5, dn: u5) u32 { return 0x9E790000 | (@as(u32, dn) << 5) | xd; }
    /// FCVTZS Wd, Sn (f32 → i32 signed)
    fn fcvtzs_w_s(wd: u5, sn: u5) u32 { return 0x1E380000 | (@as(u32, sn) << 5) | wd; }
    /// FCVTZU Wd, Sn (f32 → u32)
    fn fcvtzu_w_s(wd: u5, sn: u5) u32 { return 0x1E390000 | (@as(u32, sn) << 5) | wd; }
    /// FCVTZS Xd, Sn (f32 → i64 signed)
    fn fcvtzs_x_s(xd: u5, sn: u5) u32 { return 0x9E380000 | (@as(u32, sn) << 5) | xd; }
    /// FCVTZU Xd, Sn (f32 → u64)
    fn fcvtzu_x_s(xd: u5, sn: u5) u32 { return 0x9E390000 | (@as(u32, sn) << 5) | xd; }
};

// ================================================================
// Virtual register → ARM64 physical register mapping
// ================================================================

/// Map virtual register index to ARM64 physical register.
/// r0-r4 → x22-x26 (callee-saved)
/// r5-r11 → x9-x15 (caller-saved)
/// r12-r13 → x20-x21 (callee-saved, VM/INST ptrs moved to memory)
/// r14+ → memory (via regs_ptr at x19)
/// x27/x28 reserved for memory base/size cache.
/// Pack 4 register indices from a RegInstr into a u64 data word for trampoline calls.
/// Layout: [rd:16 | rs1:16 | rs2:16 | arg3:16]
fn packDataWord(instr: RegInstr) u64 {
    return @as(u64, instr.rd) |
        (@as(u64, instr.rs1) << 16) |
        (@as(u64, instr.rs2_field) << 32) |
        (@as(u64, @as(u16, @truncate(instr.operand))) << 48);
}

/// Unpack register indices from a u64 data word (inverse of packDataWord).
fn unpackDataWord(raw: u64) struct { r0: u16, r1: u16, r2: u16, r3: u16 } {
    return .{
        .r0 = @truncate(raw),
        .r1 = @truncate(raw >> 16),
        .r2 = @truncate(raw >> 32),
        .r3 = @truncate(raw >> 48),
    };
}

fn vregToPhys(vreg: u16) ?u5 {
    if (vreg <= 4) return @intCast(vreg + 22); // x22-x26 (callee-saved)
    if (vreg <= 11) return @intCast(vreg - 5 + 9); // x9-x15 (caller-saved)
    if (vreg <= 13) return @intCast(vreg - 12 + 20); // x20-x21 (callee-saved)
    if (vreg <= 19) return @intCast(vreg - 14 + 2); // x2-x7 (caller-saved)
    if (vreg <= 21) return @intCast(vreg - 20); // x0-x1 (caller-saved)
    if (vreg == 22) return 17; // x17 (caller-saved, IP1 — safe in JIT)
    return null; // spill to memory
}

/// Maximum virtual registers mappable to physical registers.
const MAX_PHYS_REGS: u8 = 23; // 5 callee + 7 caller + 2 callee + 6 caller + 3 caller

/// Scratch register for temporaries.
const SCRATCH: u5 = 8; // x8
/// Second scratch for two-operand memory ops.
const SCRATCH2: u5 = 16; // x16 (IP0)
/// Registers saved in prologue.
const REGS_PTR: u5 = 19; // x19
// VM_PTR and INST_PTR stored in regs[reg_count+2] and regs[reg_count+3].
// x20 and x21 are now used for vreg 12-13 (callee-saved).
/// Memory cache (callee-saved, preserved across calls).
const MEM_BASE: u5 = 27; // x27 — linear memory base pointer
const MEM_SIZE: u5 = 28; // x28 — linear memory size in bytes
/// Cached vm.reg_ptr VALUE for functions with self-calls (reuses x27 when !has_memory).
/// Contains the actual reg_ptr value (stack offset), not the address.
/// Interpreter restores reg_ptr via defer, so JIT doesn't need to write back.
const REG_PTR_VAL: u5 = 27; // x27 — vm.reg_ptr value (non-memory functions only)

/// Scratch FP registers for floating-point operations.
/// d0 and d1 are caller-saved volatile FP regs on ARM64.
const FP_SCRATCH0: u5 = 0; // d0
const FP_SCRATCH1: u5 = 1; // d1

// ================================================================
// JIT Compiler
// ================================================================

pub const Compiler = struct {
    code: std.ArrayList(u32),
    /// Map from RegInstr PC → ARM64 instruction index.
    pc_map: std.ArrayList(u32),
    /// Forward branch patches: (arm64_idx, target_reg_pc).
    patches: std.ArrayList(Patch),
    /// Error stubs: branch-to-error sites to be patched at end of function.
    error_stubs: std.ArrayList(ErrorStub),
    /// Branch indices from fuel checks — all patched to a single shared fuel exit.
    fuel_check_branches: std.ArrayList(u32),
    alloc: Allocator,
    reg_count: u16,
    local_count: u16,
    trampoline_addr: u64,
    mem_info_addr: u64,
    global_get_addr: u64,
    global_set_addr: u64,
    mem_grow_addr: u64,
    mem_fill_addr: u64,
    mem_copy_addr: u64,
    call_indirect_addr: u64,
    gc_trampoline_addr: u64,
    pool64: []const u64,
    has_memory: bool,
    has_self_call: bool,
    /// True when the only calls are self-calls (no trampoline/indirect calls).
    /// Enables aggressive self-call optimization: skip reg_ptr memory sync.
    self_call_only: bool,
    self_func_idx: u32,
    /// IR PC of reentry guard branch (br_if/br_if_not → unreachable in first 8 instrs).
    /// When set, the JIT skips this branch so JitRestart doesn't trigger the guard trap.
    guard_branch_pc: ?u32,
    /// OSR target IR PC — emit a second entry point that jumps directly to this PC.
    osr_target_pc: ?u32,
    /// Instruction index of OSR prologue (for finalize to compute osr_entry offset).
    osr_prologue_idx: u32,
    param_count: u16,
    result_count: u16,
    reg_ptr_offset: u32,
    jit_fuel_offset: u32,
    simd_hi_offset: u32,
    min_memory_bytes: u32,
    /// Bitmask of vregs that need loading in the prologue.
    /// Bit N = 1 means vreg N is read before written and must be loaded.
    prologue_load_mask: u32,
    /// Track known constant values per vreg for bounds check elision.
    /// Index = vreg number, null = unknown. Max 128 vregs tracked.
    known_consts: [128]?u32,
    /// Bitset of vregs that have been written to (for spill optimization).
    written_vregs: u128,
    /// Which memory-backed vreg's value is currently in SCRATCH (x8).
    /// Valid only at instruction boundaries — used to skip redundant loads.
    scratch_vreg: ?u16,
    /// FP register cache: maps D2-D15 to vregs holding f64 values.
    /// fp_dreg[i] = vreg whose f64 value is in D(i+2), null if register free.
    /// Slots 0-5 = D2-D7 (caller-saved), slots 6-13 = D8-D15 (callee-saved).
    fp_dreg: [FP_CACHE_SIZE]?u16,
    /// True when the D register value has not been written back to GPR/vreg array.
    fp_dreg_dirty: [FP_CACHE_SIZE]bool,
    /// True when vm_ptr is cached in x20 (only when reg_count <= 12 and has self-calls).
    vm_ptr_cached: bool,
    /// True when inst_ptr is cached in x21 (only when reg_count <= 13 and has self-calls).
    inst_ptr_cached: bool,
    /// True when call_depth is cached in x28 (non-memory self-call functions only).
    /// Eliminates per-call memory load/store for depth tracking.
    depth_reg_cached: bool,
    /// Effective FP cache size: 14 (D2-D15) for non-self-call functions,
    /// 6 (D2-D7) for self-call functions (self-call entry skips D8-D15 save).
    fp_cache_limit: u5,
    /// Live vreg bitmap at current call site (set by spillCallerSavedLive).
    /// Bit N = 1 means vreg N is live and must be spilled/reloaded across the call.
    call_live_set: u32,
    /// Live callee-saved vreg bitmap (set by spillCalleeSavedLive).
    /// Bit N = 1 means callee-saved vreg N must be saved/restored by the CALLER
    /// when using lightweight self-call (callee skips STP/LDP x19-x28).
    callee_live_set: u32,
    /// Index of the shared error epilogue in the code array (for signal handler recovery).
    shared_exit_idx: u32,
    /// True when the memory has guard pages — skip explicit bounds checks.
    use_guard_pages: bool,
    /// ARM64 instruction index of the self-call entry point (after base-case fast-path).
    /// Self-calls BL here instead of instruction 0 to skip callee-saved STP.
    self_call_entry_idx: u32,
    /// Saved fast-path pattern from emitBaseCaseFastPath for duplication at self-call entry.
    fast_path_info: ?FastPathInfo,
    /// IR slice and branch targets for peephole fusion (set during compile).
    ir_slice: []const RegInstr = &.{},
    branch_targets_slice: []bool = &.{},

    const FastPathInfo = struct {
        param_offset: u16,
        imm: u12,
        skip_cond: a64.Cond,
        ret_rd: u16,
        cmp_rs1: u16,
    };

    const Patch = struct {
        arm64_idx: u32, // index in code array
        target_pc: u32, // target RegInstr PC
        kind: PatchKind,
    };

    const PatchKind = enum { b, b_cond, cbz32, cbnz32 };

    const ErrorStub = struct {
        branch_idx: u32, // index of B.cond placeholder in code
        error_code: u16, // 0 = error code already in x0 (call errors)
        kind: enum { b_cond_inverted, cbnz64 },
        cond: a64.Cond, // only used for b_cond_inverted
    };

    pub fn init(alloc: Allocator) Compiler {
        return .{
            .code = .empty,
            .pc_map = .empty,
            .patches = .empty,
            .error_stubs = .empty,
            .fuel_check_branches = .empty,
            .alloc = alloc,
            .reg_count = 0,
            .local_count = 0,
            .trampoline_addr = 0,
            .mem_info_addr = 0,
            .global_get_addr = 0,
            .global_set_addr = 0,
            .mem_grow_addr = 0,
            .mem_fill_addr = 0,
            .mem_copy_addr = 0,
            .call_indirect_addr = 0,
            .gc_trampoline_addr = 0,
            .pool64 = &.{},
            .has_memory = false,
            .has_self_call = false,
            .self_call_only = false,
            .self_func_idx = 0,
            .guard_branch_pc = null,
            .osr_target_pc = null,
            .osr_prologue_idx = 0,
            .param_count = 0,
            .result_count = 0,
            .reg_ptr_offset = 0,
            .jit_fuel_offset = 0,
            .simd_hi_offset = 0,
            .min_memory_bytes = 0,
            .prologue_load_mask = 0xFFFFF, // default: load all (20 vregs)
            .known_consts = .{null} ** 128,
            .written_vregs = 0,
            .scratch_vreg = null,
            .fp_dreg = .{null} ** FP_CACHE_SIZE,
            .fp_dreg_dirty = .{false} ** FP_CACHE_SIZE,
            .vm_ptr_cached = false,
            .inst_ptr_cached = false,
            .depth_reg_cached = false,
            .fp_cache_limit = FP_CACHE_SIZE,
            .call_live_set = 0,
            .callee_live_set = 0,
            .shared_exit_idx = 0,
            .use_guard_pages = false,
            .self_call_entry_idx = 0,
            .fast_path_info = null,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.code.deinit(self.alloc);
        self.pc_map.deinit(self.alloc);
        self.patches.deinit(self.alloc);
        self.error_stubs.deinit(self.alloc);
        self.fuel_check_branches.deinit(self.alloc);
    }

    fn emit(self: *Compiler, inst: u32) void {
        self.code.append(self.alloc, inst) catch {};
    }

    fn currentIdx(self: *const Compiler) u32 {
        return @intCast(self.code.items.len);
    }

    /// Load virtual register value into physical register.
    /// If vreg maps to a physical reg, emit MOV. Otherwise, load from memory.
    fn loadVreg(self: *Compiler, dst: u5, vreg: u16) void {
        if (vregToPhys(vreg)) |phys| {
            if (phys != dst) self.emit(a64.mov64(dst, phys));
        } else {
            self.emit(a64.ldr64(dst, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    /// Store value from physical register to virtual register.
    fn storeVreg(self: *Compiler, vreg: u16, src: u5) void {
        if (vregToPhys(vreg)) |phys| {
            if (phys != src) self.emit(a64.mov64(phys, src));
            // SCRATCH may have been reused as temp — invalidate stale cache
            if (src == SCRATCH) self.scratch_vreg = null;
        } else {
            self.emit(a64.str64(src, REGS_PTR, @as(u16, vreg) * 8));
            // Update scratch cache
            if (src == SCRATCH) {
                self.scratch_vreg = vreg; // SCRATCH still holds this vreg's value
            } else if (self.scratch_vreg) |cached| {
                // Another reg overwrote this memory slot — invalidate stale cache
                if (cached == vreg) self.scratch_vreg = null;
            }
        }
        // Invalidate FP D-register cache — GPR write makes D-reg copy stale
        self.fpCacheInvalidate(vreg);
    }

    /// Get the physical register for a vreg, or load to scratch.
    fn getOrLoad(self: *Compiler, vreg: u16, scratch: u5) u5 {
        // Check FP D-register cache FIRST — if value is dirty in a D-reg,
        // the GPR (physical or memory) is stale and must be materialized.
        if (self.fpCacheFind(vreg)) |slot| {
            if (self.fp_dreg_dirty[slot]) {
                const dreg = fpSlotToDreg(slot);
                const target = vregToPhys(vreg) orelse scratch;
                self.emit(a64.fmovToGp64(target, dreg));
                self.fp_dreg_dirty[slot] = false;
                // Also write back to memory if vreg is spilled (no phys reg)
                if (vregToPhys(vreg) == null) {
                    self.emit(a64.str64(scratch, REGS_PTR, @as(u16, vreg) * 8));
                    if (scratch == SCRATCH) self.scratch_vreg = vreg;
                }
                return target;
            }
        }
        if (vregToPhys(vreg)) |phys| return phys;
        // Check scratch register cache — skip redundant load if value already in SCRATCH
        if (scratch == SCRATCH) {
            if (self.scratch_vreg) |cached| {
                if (cached == vreg) return SCRATCH;
            }
            self.scratch_vreg = vreg;
        }
        self.emit(a64.ldr64(scratch, REGS_PTR, @as(u16, vreg) * 8));
        return scratch;
    }

    /// Get destination register: physical register if mapped, otherwise SCRATCH.
    /// Use with storeVreg(rd, dest) which is a no-op when dest == physical.
    fn destReg(vreg: u16) u5 {
        return vregToPhys(vreg) orelse SCRATCH;
    }

    // --- FP D-register cache (D2-D15) ---

    /// Number of FP cache registers: D2-D7 (caller-saved) + D8-D15 (callee-saved).
    const FP_CACHE_SIZE = 14;
    /// Slots 0-5 are caller-saved (D2-D7), clobbered by BLR.
    const FP_CALLER_SAVED_SLOTS = 6;

    /// Convert cache slot index (0-13) to ARM64 D register number (2-15).
    fn fpSlotToDreg(slot: u4) u5 {
        return @as(u5, slot) + 2;
    }

    /// Find which D-register cache slot holds a vreg's f64 value.
    /// Returns the slot index (0-5) or null if not cached.
    fn fpCacheFind(self: *Compiler, vreg: u16) ?u4 {
        for (0..FP_CACHE_SIZE) |i| {
            if (self.fp_dreg[i]) |cached| {
                if (cached == vreg) return @intCast(i);
            }
        }
        return null;
    }

    /// Allocate a D-register cache slot for a vreg. Evicts slot 0 if full.
    fn fpCacheAlloc(self: *Compiler) u4 {
        // Find a free slot within the effective limit
        const limit = self.fp_cache_limit;
        for (0..limit) |i| {
            if (self.fp_dreg[i] == null) return @intCast(i);
        }
        // No free slot — evict slot 0 (simple round-robin)
        self.fpCacheEvictSlot(0);
        return 0;
    }

    /// Evict a single FP cache slot: write-back dirty value to GPR/vreg array.
    fn fpCacheEvictSlot(self: *Compiler, slot: usize) void {
        if (self.fp_dreg_dirty[slot]) {
            if (self.fp_dreg[slot]) |vreg| {
                const dreg = fpSlotToDreg(@intCast(slot));
                // FMOV GPR, Dn — move value to GPR, then store
                self.emit(a64.fmovToGp64(SCRATCH, dreg));
                self.storeVreg(vreg, SCRATCH);
            }
            self.fp_dreg_dirty[slot] = false;
        }
        self.fp_dreg[slot] = null;
    }

    /// Evict all FP cache entries. Called at branch targets (merge points).
    fn fpCacheEvictAll(self: *Compiler) void {
        for (0..FP_CACHE_SIZE) |i| {
            self.fpCacheEvictSlot(i);
        }
    }

    /// Evict only caller-saved FP cache entries (D2-D7, slots 0-5).
    /// Called before BLR — D8-D15 are callee-saved, preserved by callee.
    fn fpCacheEvictCallerSaved(self: *Compiler) void {
        for (0..FP_CALLER_SAVED_SLOTS) |i| {
            self.fpCacheEvictSlot(i);
        }
    }

    /// Invalidate a vreg in the FP cache (without write-back).
    /// Called when a vreg is overwritten via GPR (e.g., storeVreg for integer result).
    fn fpCacheInvalidate(self: *Compiler, vreg: u16) void {
        if (self.fpCacheFind(vreg)) |slot| {
            // Value overwritten in GPR — D-reg copy is stale
            self.fp_dreg[slot] = null;
            self.fp_dreg_dirty[slot] = false;
        }
    }

    /// Load an f64 vreg into a D-register. Returns the D register number (2-7).
    /// If already cached, returns the existing D register. Otherwise allocates one.
    fn fpLoadToDreg(self: *Compiler, vreg: u16) u5 {
        // Check if already in D-cache
        if (self.fpCacheFind(vreg)) |slot| {
            return fpSlotToDreg(slot);
        }
        // Allocate a D-register and load from GPR
        const slot = self.fpCacheAlloc();
        const dreg = fpSlotToDreg(slot);
        const src = self.getOrLoad(vreg, SCRATCH);
        self.emit(a64.fmovToFp64(dreg, src));
        self.fp_dreg[slot] = vreg;
        self.fp_dreg_dirty[slot] = false; // not dirty — GPR has same value
        return dreg;
    }

    /// Allocate a D-register for an FP result. Returns the D register number.
    /// Marks the slot as dirty (value only in D-reg, not in GPR).
    fn fpAllocResult(self: *Compiler, vreg: u16) u5 {
        // If vreg already cached, reuse slot (overwrite is fine — D-reg has valid value)
        if (self.fpCacheFind(vreg)) |slot| {
            self.fp_dreg_dirty[slot] = true;
            return fpSlotToDreg(slot);
        }
        const slot = self.fpCacheAlloc();
        const dreg = fpSlotToDreg(slot);
        self.fp_dreg[slot] = vreg;
        // Don't mark dirty yet — D-register doesn't have the new value.
        // Caller MUST call fpMarkResultDirty(vreg) after the actual write.
        // Without this, getOrLoad(rs1=rd) would materialize a stale D-reg value.
        return dreg;
    }

    /// Mark an FP cache entry as dirty after the D-register has been written.
    /// Must be called after fpAllocResult for new entries.
    fn fpMarkResultDirty(self: *Compiler, vreg: u16) void {
        if (self.fpCacheFind(vreg)) |slot| {
            self.fp_dreg_dirty[slot] = true;
        }
    }

    /// Materialize an FP-cached vreg to GPR. Used when non-FP code needs the value.
    fn fpMaterializeToGpr(self: *Compiler, vreg: u16) void {
        if (self.fpCacheFind(vreg)) |slot| {
            if (self.fp_dreg_dirty[slot]) {
                const dreg = fpSlotToDreg(slot);
                const d = destReg(vreg);
                self.emit(a64.fmovToGp64(d, dreg));
                self.storeVreg(vreg, d);
                self.fp_dreg_dirty[slot] = false;
            }
        }
    }

    /// Load VM pointer from memory slot (or cached x20) into dst register.
    fn emitLoadVmPtr(self: *Compiler, dst: u5) void {
        if (self.vm_ptr_cached and dst != 20) {
            self.emit(a64.mov64(dst, 20)); // x20 holds vm_ptr
        } else {
            self.emit(a64.ldr64(dst, REGS_PTR, @intCast((@as(u32, self.reg_count) + 2) * 8)));
        }
    }

    /// Load instance pointer from memory slot (or cached x21) into dst register.
    fn emitLoadInstPtr(self: *Compiler, dst: u5) void {
        if (self.inst_ptr_cached and dst != 21) {
            self.emit(a64.mov64(dst, 21)); // x21 holds inst_ptr
        } else {
            self.emit(a64.ldr64(dst, REGS_PTR, @intCast((@as(u32, self.reg_count) + 3) * 8)));
        }
    }

    /// Spill caller-saved virtual regs (r5-r11 → x9-x15, r14-r19 → x2-x7) to memory.
    /// Callee-saved regs (r0-r4 → x22-x26, r12-r13 → x20-x21) are preserved.
    fn spillCallerSaved(self: *Compiler) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        for (5..max) |i| {
            const vreg: u16 = @intCast(i);
            // Skip callee-saved vregs 12-13 (x20-x21) — preserved across calls
            if (vreg == 12 or vreg == 13) continue;
            // Skip unwritten vregs — they contain garbage from caller frame
            if (vreg < 128 and (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Spill a single vreg if it's callee-saved (r0-r4, r12-r13). No-op for caller-saved
    /// vregs (already spilled by spillCallerSaved) or unmapped vregs (always in memory).
    fn spillVregIfCalleeSaved(self: *Compiler, vreg: u16) void {
        if (vregToPhys(vreg)) |phys| {
            // Caller-saved vregs: 5-11, 14-22. Callee-saved: 0-4, 12-13.
            if (isCallerSavedVreg(vreg)) return;
            // Callee-saved: spill to make visible to trampoline
            self.emit(a64.str64(phys, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    /// Spill a single vreg unconditionally. Used for call args that the trampoline
    /// reads from regs[] — these must be stored even if caller-saved and not live after call.
    fn spillVreg(self: *Compiler, vreg: u16) void {
        if (vregToPhys(vreg)) |phys| {
            self.emit(a64.str64(phys, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    /// Reload caller-saved virtual regs from memory (after function calls).
    /// Callee-saved regs (r0-r4 → x22-x26, r12-r13 → x20-x21) are preserved across BLR.
    fn reloadCallerSaved(self: *Compiler) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        for (5..max) |i| {
            const vreg: u16 = @intCast(i);
            // Skip callee-saved vregs 12-13 (x20-x21) — preserved across calls
            if (vreg == 12 or vreg == 13) continue;
            // Skip unwritten vregs — they were never initialized
            if (vreg < 128 and (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Reload caller-saved regs, optionally skipping one vreg (result of inline call).
    fn reloadCallerSavedExcept(self: *Compiler, skip_vreg: ?u8) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        for (5..max) |i| {
            const vreg: u16 = @intCast(i);
            if (vreg == 12 or vreg == 13) continue;
            if (skip_vreg) |sv| {
                if (vreg == sv) continue;
            }
            if (vreg < 128 and (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Compute live vreg bitmap at a call site by forward-scanning the IR.
    /// A vreg is live if it's read (as rs1/rs2) before being overwritten (as rd).
    /// Only tracks caller-saved vregs (5-11, 14-19) since callee-saved are preserved.
    pub fn computeCallLiveSet(ir: []const RegInstr, call_pc: u32) u32 {
        var live: u32 = 0;
        var resolved: u32 = 0; // vregs whose liveness is determined
        var pc = call_pc + 1;
        // Skip NOP data words that follow the call at call_pc
        while (pc < ir.len and (ir[pc].op == regalloc_mod.OP_NOP or ir[pc].op == regalloc_mod.OP_DELETED)) : (pc += 1) {}

        while (pc < ir.len) : (pc += 1) {
            const instr = ir[pc];
            if (instr.op == regalloc_mod.OP_DELETED or
                instr.op == regalloc_mod.OP_BLOCK_END) continue;
            // NOP data words (following OP_CALL) contain arg vregs — extract them as uses
            if (instr.op == regalloc_mod.OP_NOP) {
                markCallerSavedUse(&live, &resolved, instr.rd);
                markCallerSavedUse(&live, &resolved, instr.rs1);
                if (instr.rs2_field != 0) markCallerSavedUse(&live, &resolved, instr.rs2_field);
                const arg3: u16 = @truncate(instr.operand);
                if (arg3 != 0) markCallerSavedUse(&live, &resolved, arg3);
                continue;
            }

            // Check uses first (rs1, rs2) — if used before defined, vreg is live
            // Note: OP_CALL rs1 = n_args (not a vreg), skip it.
            // GC struct.new rs1 = n_fields (not a vreg), skip it.
            // OP_CALL_INDIRECT rs1 = elem_idx_reg (IS a vreg), don't skip.
            if (instr.op != regalloc_mod.OP_CALL and
                instr.op != (predecode_mod.GC_BASE | 0x00))
            {
                markCallerSavedUse(&live, &resolved, instr.rs1);
            }
            // rs2 for binary ops (op uses operand low byte as rs2)
            if (instrHasRs2(instr)) {
                markCallerSavedUse(&live, &resolved, instr.rs2());
            }
            // select: condition register stored in operand
            if (instr.op == 0x1B) {
                const cond_vreg: u16 = @truncate(instr.operand);
                markCallerSavedUse(&live, &resolved, cond_vreg);
            }

            // Check definition (rd) — if defined before used, vreg is dead
            if (instrDefinesRd(instr)) {
                if (isCallerSavedVreg(instr.rd)) {
                    resolved |= @as(u32, 1) << @as(u5, @intCast(instr.rd));
                }
            } else if (instr.op != regalloc_mod.OP_NOP and
                instr.op != regalloc_mod.OP_DELETED and
                instr.op != regalloc_mod.OP_BLOCK_END and
                instr.op != regalloc_mod.OP_BR)
            {
                // rd is a USE (not a define) for: return, stores, br_if, br_table, global.set
                markCallerSavedUse(&live, &resolved, instr.rd);
            }

            // At backward branches (loop back-edges), be conservative: mark all
            // unresolved written vregs as live since they may be used in next iteration.
            if (instr.op == regalloc_mod.OP_BR or instr.op == regalloc_mod.OP_BR_IF or
                instr.op == regalloc_mod.OP_BR_IF_NOT)
            {
                if (instr.operand <= call_pc) {
                    // Back-edge: mark all unresolved caller-saved as live (conservative)
                    return live | ~resolved;
                }
            }
        }
        return live;
    }

    /// Mark a vreg as used (live) if it's caller-saved and not yet resolved.
    fn markCallerSavedUse(live: *u32, resolved: *u32, vreg: u16) void {
        if (isCallerSavedVreg(vreg) and (resolved.* & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) {
            live.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
            resolved.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
        }
    }

    /// Check if a vreg is in the caller-saved range (5-11 or 14-19).
    fn isCallerSavedVreg(vreg: u16) bool {
        return (vreg >= 5 and vreg <= 11 and vreg != 12 and vreg != 13) or
            (vreg >= 14 and vreg < MAX_PHYS_REGS);
    }

    /// Check if an instruction has an rs2 operand (binary ops).
    /// Conservative: returns true for all binary arithmetic/comparison ops.
    pub fn instrHasRs2(instr: RegInstr) bool {
        const op = instr.op;
        return switch (op) {
            // i32/i64/f32/f64 binary ops (comparisons + arithmetic): 0x46-0x8A, 0x92-0x97, 0xA0-0xA6
            0x46...0x8A, 0x92...0x97, 0xA0...0xA6,
            // memory.fill/copy have rs2 in operand
            regalloc_mod.OP_MEMORY_FILL, regalloc_mod.OP_MEMORY_COPY,
            // select: rs2_field = val2
            0x1B,
            => true,
            else => false,
        };
    }

    /// Check if an instruction defines rd (writes to rd register).
    pub fn instrDefinesRd(instr: RegInstr) bool {
        const op = instr.op;
        return switch (op) {
            regalloc_mod.OP_NOP, regalloc_mod.OP_DELETED, regalloc_mod.OP_BLOCK_END,
            regalloc_mod.OP_BR, regalloc_mod.OP_BR_IF, regalloc_mod.OP_BR_IF_NOT,
            regalloc_mod.OP_RETURN, regalloc_mod.OP_RETURN_VOID, regalloc_mod.OP_BR_TABLE,
            => false,
            // Memory stores use rd as VALUE source, not a definition
            0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
            => false,
            // global.set: rd = value to write (a use, not a definition)
            0x24 => false,
            // memory.fill/copy: rd = destination address (a use, not a definition)
            regalloc_mod.OP_MEMORY_FILL, regalloc_mod.OP_MEMORY_COPY => false,
            // GC struct.set: rd = ref_reg (a use, not a definition)
            predecode_mod.GC_BASE | 0x05 => false,
            else => true,
        };
    }

    /// Spill caller-saved vregs that are live after the call.
    fn spillCallerSavedLive(self: *Compiler, ir: []const RegInstr, call_pc: u32) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        const live_set = computeCallLiveSet(ir, call_pc);
        self.call_live_set = live_set;
        for (5..max) |i| {
            const vreg: u16 = @intCast(i);
            if (vreg == 12 or vreg == 13) continue;
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
            if (vreg < 128 and (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Reload only caller-saved vregs that were spilled as live.
    fn reloadCallerSavedLive(self: *Compiler) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        const live_set = self.call_live_set;
        for (5..max) |i| {
            const vreg: u16 = @intCast(i);
            if (vreg == 12 or vreg == 13) continue;
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Reload caller-saved live vregs, optionally skipping one vreg (result of call).
    fn reloadCallerSavedLiveExcept(self: *Compiler, skip_vreg: ?u16) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        const live_set = self.call_live_set;
        for (5..max) |i| {
            const vreg: u16 = @intCast(i);
            if (vreg == 12 or vreg == 13) continue;
            if (skip_vreg) |sv| {
                if (vreg == sv) continue;
            }
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Reload a single virtual register from memory.
    fn reloadVreg(self: *Compiler, vreg: u16) void {
        if (vregToPhys(vreg)) |phys| {
            self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    // --- Callee-Saved Spill/Reload for Lightweight Self-Call ---

    /// Check if a vreg maps to a callee-saved physical register that needs
    /// explicit save/restore in lightweight self-call (callee skips STP/LDP x19-x28).
    fn isCalleeSavedVreg(self: *const Compiler, vreg: u16) bool {
        if (vreg >= self.reg_count) return false; // non-existent vreg
        if (vreg <= 4) return true; // x22-x26
        if (vreg == 12 and !self.vm_ptr_cached) return true; // x20 as vreg
        if (vreg == 13 and !self.inst_ptr_cached) return true; // x21 as vreg
        return false;
    }

    /// Compute liveness bitmap for callee-saved vregs after a call site.
    /// Forward-scans from call_pc to find vregs used before being redefined.
    fn computeCalleeSavedLiveSet(self: *const Compiler, ir: []const RegInstr, call_pc: u32) u32 {
        var live: u32 = 0;
        var resolved: u32 = 0;
        var pc = call_pc + 1;
        // Skip NOP data words that follow the call
        while (pc < ir.len and (ir[pc].op == regalloc_mod.OP_NOP or ir[pc].op == regalloc_mod.OP_DELETED)) : (pc += 1) {}

        while (pc < ir.len) : (pc += 1) {
            const instr = ir[pc];
            if (instr.op == regalloc_mod.OP_DELETED or
                instr.op == regalloc_mod.OP_BLOCK_END) continue;
            if (instr.op == regalloc_mod.OP_NOP) {
                self.markCalleeSavedUse(&live, &resolved, instr.rd);
                self.markCalleeSavedUse(&live, &resolved, instr.rs1);
                if (instr.rs2_field != 0) self.markCalleeSavedUse(&live, &resolved, instr.rs2_field);
                const arg3: u16 = @truncate(instr.operand);
                if (arg3 != 0) self.markCalleeSavedUse(&live, &resolved, arg3);
                continue;
            }

            if (instr.op != regalloc_mod.OP_CALL and
                instr.op != (predecode_mod.GC_BASE | 0x00))
            {
                self.markCalleeSavedUse(&live, &resolved, instr.rs1);
            }
            if (instrHasRs2(instr)) {
                self.markCalleeSavedUse(&live, &resolved, instr.rs2());
            }
            // select: condition register stored in operand
            if (instr.op == 0x1B) {
                const cond_vreg: u16 = @truncate(instr.operand);
                self.markCalleeSavedUse(&live, &resolved, cond_vreg);
            }

            if (instrDefinesRd(instr)) {
                if (self.isCalleeSavedVreg(instr.rd)) {
                    resolved |= @as(u32, 1) << @as(u5, @intCast(instr.rd));
                }
            } else if (instr.op != regalloc_mod.OP_NOP and
                instr.op != regalloc_mod.OP_DELETED and
                instr.op != regalloc_mod.OP_BLOCK_END and
                instr.op != regalloc_mod.OP_BR)
            {
                // rd is a USE (not a define) for: return, stores, br_if, br_table, global.set
                self.markCalleeSavedUse(&live, &resolved, instr.rd);
            }

            // Backward branches: conservatively mark unresolved callee-saved vregs as live
            if (instr.op == regalloc_mod.OP_BR or instr.op == regalloc_mod.OP_BR_IF or
                instr.op == regalloc_mod.OP_BR_IF_NOT)
            {
                if (instr.operand <= call_pc) {
                    return live | (~resolved & self.calleeSavedVregMask());
                }
            }
        }
        return live;
    }

    fn markCalleeSavedUse(self: *const Compiler, live: *u32, resolved: *u32, vreg: u16) void {
        if (self.isCalleeSavedVreg(vreg) and (resolved.* & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) {
            live.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
            resolved.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
        }
    }

    /// Bitmask of all callee-saved vreg positions.
    fn calleeSavedVregMask(self: *const Compiler) u32 {
        // Only include vregs that actually exist (< reg_count)
        var mask: u32 = 0x1F; // vreg 0-4 always callee-saved
        if (!self.vm_ptr_cached) mask |= (1 << 12);
        if (!self.inst_ptr_cached) mask |= (1 << 13);
        // Mask off non-existent vregs
        if (self.reg_count < 32) {
            mask &= (@as(u32, 1) << @as(u5, @intCast(self.reg_count))) -% 1;
        }
        return mask;
    }

    /// Spill callee-saved vregs that are live after the self-call to regs[].
    /// exclude_rd: the call result vreg (defined by the call, not live across it).
    fn spillCalleeSavedLive(self: *Compiler, ir: []const RegInstr, call_pc: u32, exclude_rd: ?u16) void {
        var live_set = self.computeCalleeSavedLiveSet(ir, call_pc);
        // Exclude call result vreg — it's defined by the call, not live across it
        if (exclude_rd) |erd| {
            live_set &= ~(@as(u32, 1) << @as(u5, @intCast(erd)));
        }
        self.callee_live_set = live_set;
        for (0..5) |i| {
            const vreg: u16 = @intCast(i);
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
        // vreg 12, 13 if they're callee-saved vregs (not cached)
        if (!self.vm_ptr_cached and (live_set & (1 << 12)) != 0) {
            if (vregToPhys(12)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, 12 * 8));
            }
        }
        if (!self.inst_ptr_cached and (live_set & (1 << 13)) != 0) {
            if (vregToPhys(13)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, 13 * 8));
            }
        }
    }

    /// Reload callee-saved vregs that were spilled by spillCalleeSavedLive.
    fn reloadCalleeSavedLive(self: *Compiler) void {
        const live_set = self.callee_live_set;
        for (0..5) |i| {
            const vreg: u16 = @intCast(i);
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
        if (!self.vm_ptr_cached and (live_set & (1 << 12)) != 0) {
            if (vregToPhys(12)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, 12 * 8));
            }
        }
        if (!self.inst_ptr_cached and (live_set & (1 << 13)) != 0) {
            if (vregToPhys(13)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, 13 * 8));
            }
        }
    }

    // --- Fast-Path Base Case ---

    /// Analyze IR for base-case fast-path pattern and emit it before the prologue.
    /// Pattern: IR[0] = cmp_imm(param, const), IR[1] = br_if_not, IR[2] = return param.
    /// Saves pattern info in fast_path_info for duplication at self-call entry.
    fn emitBaseCaseFastPath(self: *Compiler, ir: []const RegInstr) void {
        if (ir.len < 3) return;
        if (self.result_count == 0) return;

        // Check for self-calls in the IR
        if (!self.has_self_call) return;

        const cmp_instr = ir[0];
        const br_instr = ir[1];
        const ret_instr = ir[2];

        // Must be: compare_imm + br_if_not + return
        if (br_instr.op != regalloc_mod.OP_BR_IF_NOT) return;
        if (ret_instr.op != regalloc_mod.OP_RETURN) return;
        if (br_instr.rd != cmp_instr.rd) return; // branch tests compare result
        if (br_instr.operand <= 2) return; // target must be after the return

        // Compare must be on a parameter with immediate
        if (cmp_instr.rs1 >= self.param_count) return;

        // Return must return a parameter (cheap — no computation needed)
        if (ret_instr.rd >= self.param_count) return;

        // Immediate must fit CMP imm12
        const imm = cmp_instr.operand;
        if (imm > 0xFFF) return;

        // Determine ARM64 condition to skip to prologue (invert the comparison)
        const skip_cond: a64.Cond = switch (cmp_instr.op) {
            regalloc_mod.OP_LT_S_I32 => .ge, // n >= imm → not base case
            regalloc_mod.OP_LT_U_I32 => .hs, // n >= imm unsigned
            regalloc_mod.OP_LE_S_I32 => .gt,
            regalloc_mod.OP_GE_S_I32 => .lt,
            regalloc_mod.OP_GT_S_I32 => .le,
            regalloc_mod.OP_EQ_I32 => .ne,
            regalloc_mod.OP_NE_I32 => .eq,
            else => return,
        };

        const param_offset: u16 = @intCast(@as(u32, cmp_instr.rs1) * 8);

        // Save pattern info for self-call entry duplication
        self.fast_path_info = .{
            .param_offset = param_offset,
            .imm = @intCast(imm),
            .skip_cond = skip_cond,
            .ret_rd = ret_instr.rd,
            .cmp_rs1 = cmp_instr.rs1,
        };

        // Emit fast path and patch branch to next instruction (prologue start)
        const branch_idx = self.emitFastPathBlock(param_offset, @intCast(imm), skip_cond, ret_instr.rd, cmp_instr.rs1);
        const prologue_start = self.currentIdx();
        const disp: i19 = @intCast(@as(i32, @intCast(prologue_start)) - @as(i32, @intCast(branch_idx)));
        self.code.items[branch_idx] = a64.bCond(skip_cond, disp);
    }

    /// Emit a base-case fast-path block: LDR → CMP → B.cond → [STR result] → RET.
    /// Returns the branch_idx for the caller to patch the B.cond target.
    fn emitFastPathBlock(self: *Compiler, param_offset: u16, imm: u12, skip_cond: a64.Cond, ret_rd: u16, cmp_rs1: u16) u32 {
        // x0 = callee regs pointer (from caller)
        self.emit(a64.ldr64(SCRATCH, 0, param_offset)); // x8 = regs[param]
        self.emit(a64.cmpImm32(SCRATCH, imm));
        const branch_idx = self.currentIdx();
        self.emit(a64.bCond(skip_cond, 0)); // placeholder — caller patches

        if (ret_rd != 0) {
            if (ret_rd != cmp_rs1) {
                self.emit(a64.ldr64(SCRATCH, 0, @intCast(@as(u32, ret_rd) * 8)));
            }
            self.emit(a64.str64(SCRATCH, 0, 0)); // regs[0] = result
        }

        self.emit(a64.movz64(0, 0, 0)); // x0 = 0 (success)
        self.emit(a64.ret_());
        return branch_idx;
    }

    // --- Vreg Liveness Pre-scan ---

    /// Compute which vregs need loading in the prologue.
    /// A vreg needs loading if it's read before being written on ANY execution path.
    /// Returns a bitmask where bit N = 1 means vreg N must be loaded.
    /// Compute prologue load mask: only params and locals need loading.
    /// Regalloc temporaries (vreg >= local_count) are SSA — always written before read.
    fn computePrologueLoads(local_count: u16) u32 {
        if (local_count >= 20) return 0xFFFFF; // all 20 vregs
        if (local_count == 0) return 0;
        return (@as(u32, 1) << @intCast(local_count)) - 1;
    }
    // --- Prologue / Epilogue ---

    fn emitPrologue(self: *Compiler) void {
        // Precompute caching flags for non-memory self-call functions.
        // Must be set before emitting self-call entry block (used by emitLoadRegPtrAddr).
        if (!self.has_memory and self.has_self_call) {
            self.depth_reg_cached = true;
            if (self.reg_count <= 12) self.vm_ptr_cached = true;
            if (self.reg_count <= 13) self.inst_ptr_cached = true;
        }

        // Save callee-saved registers and set up frame.
        // stp x29, x30, [sp, #-16]!
        self.emit(a64.stpPre(29, 30, 31, -2)); // -2 * 8 = -16
        // stp x19, x20, [sp, #-16]!
        self.emit(a64.stpPre(19, 20, 31, -2));
        // stp x21, x22, [sp, #-16]!
        self.emit(a64.stpPre(21, 22, 31, -2));
        // stp x23, x24, [sp, #-16]!
        self.emit(a64.stpPre(23, 24, 31, -2));
        // stp x25, x26, [sp, #-16]!
        self.emit(a64.stpPre(25, 26, 31, -2));
        // stp x27, x28, [sp, #-16]!
        self.emit(a64.stpPre(27, 28, 31, -2));

        // Save callee-saved FP registers D8-D15 for expanded FP cache (14 slots).
        // Only for non-self-call functions — self-call entry skips this.
        if (!self.has_self_call) {
            self.emit(a64.stpFpPre(8, 9, 31, -2));
            self.emit(a64.stpFpPre(10, 11, 31, -2));
            self.emit(a64.stpFpPre(12, 13, 31, -2));
            self.emit(a64.stpFpPre(14, 15, 31, -2));
        }

        var b_vreg_load_idx: u32 = 0; // Patched later: self-call B to vreg loading

        if (self.has_self_call) {
            // Normal entry: x29 = SP (nonzero) — epilogue does full LDP x19-x28.
            self.emit(a64.addImm64(29, 31, 0)); // MOV x29, SP

            // Branch over self-call entry block to shared setup.
            const b_shared_idx = self.currentIdx();
            self.emit(0x14000000); // B placeholder

            // --- Self-call entry point ---
            // Self-calls BL here; skips callee-saved STP x19-x28.
            self.self_call_entry_idx = self.currentIdx();

            // Duplicated base-case fast-path at self-call entry.
            if (self.fast_path_info) |fp| {
                const br_idx = self.emitFastPathBlock(fp.param_offset, fp.imm, fp.skip_cond, fp.ret_rd, fp.cmp_rs1);
                // Patch B.cond to fall through to self-call prologue
                const target = self.currentIdx();
                const disp: i19 = @intCast(@as(i32, @intCast(target)) - @as(i32, @intCast(br_idx)));
                self.code.items[br_idx] = a64.bCond(fp.skip_cond, disp);
            }

            // Self-call prologue: only save x29,x30 (link register).
            self.emit(a64.stpPre(29, 30, 31, -2));
            self.emit(a64.movz64(29, 0, 0)); // MOV x29, #0 (zero = self-call entry)

            // --- Minimal self-call setup (bypass shared setup) ---
            // Self-call preserves callee-saved: x19-x28 unchanged from caller.
            // Only need to set REGS_PTR to callee's frame.
            self.emit(a64.mov64(REGS_PTR, 0)); // x19 = callee regs (from x0)

            // Store vm/inst ptrs to callee frame only when not register-cached.
            // When cached (x20/x21), callee-saved regs are preserved across self-call.
            if (!self.vm_ptr_cached) {
                self.emit(a64.str64(1, REGS_PTR, @intCast((@as(u32, self.reg_count) + 2) * 8)));
            }
            if (!self.inst_ptr_cached) {
                self.emit(a64.str64(2, REGS_PTR, @intCast((@as(u32, self.reg_count) + 3) * 8)));
            }

            // Cache &vm.reg_ptr only when function has non-self calls (trampoline needs it).
            if (!self.self_call_only) {
                self.emitLoadRegPtrAddr(SCRATCH);
                self.emit(a64.str64(SCRATCH, REGS_PTR, @intCast(@as(u16, self.reg_count) * 8)));
            }

            // Branch over shared setup to vreg loading (patched below).
            b_vreg_load_idx = self.currentIdx();
            self.emit(0x14000000); // B placeholder

            // Patch B to shared setup (current position).
            const shared_setup = self.currentIdx();
            const b_offset: i26 = @intCast(@as(i32, @intCast(shared_setup)) - @as(i32, @intCast(b_shared_idx)));
            self.code.items[b_shared_idx] = a64.b(b_offset);
        }

        // --- Shared setup (normal entry only when has_self_call) ---

        // Save args: x0 = regs (→ callee-saved x19), x1 = vm, x2 = instance (→ memory slots)
        self.emit(a64.mov64(REGS_PTR, 0)); // x19 = regs
        // Store VM and instance pointers to regs[reg_count+2] and [reg_count+3]
        self.emit(a64.str64(1, REGS_PTR, @intCast((@as(u32, self.reg_count) + 2) * 8)));
        self.emit(a64.str64(2, REGS_PTR, @intCast((@as(u32, self.reg_count) + 3) * 8)));

        // Load memory cache BEFORE loading virtual registers.
        // emitLoadMemCache() calls jitGetMemInfo via BLR, which trashes all
        // caller-saved registers (x0-x18). Loading vregs after ensures their
        // values in x2-x7, x9-x15 are not corrupted by the call.
        if (self.has_memory) {
            self.emitLoadMemCache();
        } else if (self.has_self_call) {
            // Normal entry: load reg_ptr, depth, vm/inst into cached registers.
            // Self-call entry bypasses this (registers preserved from caller).
            // Load cached vm/inst ptrs FIRST — emitLoadRegPtrAddr uses cached x20.
            if (self.vm_ptr_cached) self.emitLoadVmPtr(20); // x20 = vm_ptr
            if (self.inst_ptr_cached) self.emitLoadInstPtr(21); // x21 = inst_ptr
            self.emitLoadRegPtrAddr(SCRATCH);
            self.emit(a64.ldr64(REG_PTR_VAL, SCRATCH, 0)); // x27 = vm.reg_ptr value
            self.emit(a64.str64(SCRATCH, REGS_PTR, @intCast(@as(u16, self.reg_count) * 8)));
            self.emit(a64.ldr64(28, SCRATCH, 8)); // x28 = vm.call_depth
        }

        // --- Vreg loading (self-call B target) ---
        if (self.has_self_call) {
            // Patch B from self-call path to here.
            const vreg_load_start = self.currentIdx();
            const b_vreg_offset: i26 = @intCast(@as(i32, @intCast(vreg_load_start)) - @as(i32, @intCast(b_vreg_load_idx)));
            self.code.items[b_vreg_load_idx] = a64.b(b_vreg_offset);
        }

        // Load virtual registers from regs[] into physical registers.
        // Must be AFTER emitLoadMemCache() which calls BLR (trashes x0-x18).
        // Only load vregs that are read before written (prologue_load_mask).
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        for (0..max) |i| {
            const vreg: u16 = @intCast(i);
            if (vreg < 20 and self.prologue_load_mask & (@as(u32, 1) << @intCast(vreg)) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Emit call to jitGetMemInfo and load results into x27/x28.
    fn emitLoadMemCache(self: *Compiler) void {
        // jitGetMemInfo(instance, out) — out = &regs[reg_count]
        // x0 = instance, x1 = &regs[reg_count]
        self.emitLoadInstPtr(0);
        self.emit(a64.addImm64(1, REGS_PTR, @as(u12, @intCast(self.reg_count)) * 8));
        // Load jitGetMemInfo address into scratch and call
        const addr_instrs = a64.loadImm64(SCRATCH, self.mem_info_addr);
        for (addr_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));
        // Load results: mem_base = regs[reg_count], mem_size = regs[reg_count+1]
        self.emit(a64.ldr64(MEM_BASE, REGS_PTR, @as(u16, self.reg_count) * 8));
        self.emit(a64.ldr64(MEM_SIZE, REGS_PTR, @as(u16, self.reg_count) * 8 + 8));
    }

    /// Saturating truncation: FCVTZS/FCVTZU without trapping on NaN/overflow.
    fn emitTruncSat(self: *Compiler, instr: RegInstr) void {
        const sub = @as(u8, @truncate(instr.op & 0xFF)); // 0x00..0x07
        const is_f64 = (sub & 0x02) != 0; // bit 1: f64 vs f32
        const is_unsigned = (sub & 0x01) != 0; // bit 0: unsigned vs signed
        const is_i64 = (sub & 0x04) != 0; // bit 2: i64 vs i32
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const d = destReg(instr.rd);

        // Move source to FP register
        if (is_f64) {
            self.emit(a64.fmovToFp64(FP_SCRATCH0, src));
        } else {
            self.emit(a64.fmovToFp32(FP_SCRATCH0, src));
        }

        // FCVTZS/FCVTZU — ARM64 saturates automatically
        if (is_i64) {
            if (is_unsigned) {
                if (is_f64) self.emit(a64.fcvtzu_x_d(d, FP_SCRATCH0))
                else self.emit(a64.fcvtzu_x_s(d, FP_SCRATCH0));
            } else {
                if (is_f64) self.emit(a64.fcvtzs_x_d(d, FP_SCRATCH0))
                else self.emit(a64.fcvtzs_x_s(d, FP_SCRATCH0));
            }
        } else {
            if (is_unsigned) {
                if (is_f64) self.emit(a64.fcvtzu_w_d(d, FP_SCRATCH0))
                else self.emit(a64.fcvtzu_w_s(d, FP_SCRATCH0));
            } else {
                if (is_f64) self.emit(a64.fcvtzs_w_d(d, FP_SCRATCH0))
                else self.emit(a64.fcvtzs_w_s(d, FP_SCRATCH0));
            }
        }
        self.storeVreg(instr.rd, d);
    }

    /// Emit br_table: cascading CMP + B.EQ for each target, default B at end.
    fn emitBrTable(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        const count = instr.operand;
        if (count > 4095) return false; // Too many cases for CMP imm12
        const idx_reg = self.getOrLoad(instr.rd, SCRATCH);
        self.fpCacheEvictAll();

        var i: u32 = 0;
        while (i < count + 1 and pc.* < ir.len) : (i += 1) {
            const entry = ir[pc.*];
            pc.* += 1;

            if (i < count) {
                // Case i: CMP idx, i; B.EQ target
                self.emit(a64.cmpImm32(idx_reg, @intCast(i)));
                const arm_idx = self.currentIdx();
                self.emit(a64.bCond(.eq, 0)); // placeholder
                self.patches.append(self.alloc, .{
                    .arm64_idx = arm_idx,
                    .target_pc = entry.operand,
                    .kind = .b_cond,
                }) catch return false;
            } else {
                // Default: unconditional branch
                const arm_idx = self.currentIdx();
                self.emit(a64.b(0)); // placeholder
                self.patches.append(self.alloc, .{
                    .arm64_idx = arm_idx,
                    .target_pc = entry.operand,
                    .kind = .b,
                }) catch return false;
            }
        }
        return true;
    }

    fn emitEpilogue(self: *Compiler, result_vreg: ?u16) void {
        // Store result to regs[0] if needed
        if (result_vreg) |rv| {
            if (vregToPhys(rv)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, 0));
            } else {
                self.emit(a64.ldr64(SCRATCH, REGS_PTR, @as(u16, rv) * 8));
                self.emit(a64.str64(SCRATCH, REGS_PTR, 0));
            }
        }
        self.emitCalleeSavedRestore();
        self.emit(a64.movz64(0, 0, 0));
        self.emit(a64.ret_());
    }

    fn emitErrorReturn(self: *Compiler, error_code: u16) void {
        self.emitCalleeSavedRestore();
        self.emit(a64.movz64(0, error_code, 0));
        self.emit(a64.ret_());
    }

    /// Emit callee-saved register restore sequence.
    /// For self-call functions: CBZ x29 skips the normal path (depth flush + 5 LDPs),
    /// landing directly on the final LDP x29,x30 + RET.
    /// When depth_reg_cached, flushes x28 to vm.call_depth before LDP restores x28.
    fn emitCalleeSavedRestore(self: *Compiler) void {
        var cbz_idx: u32 = 0;
        if (self.has_self_call) {
            cbz_idx = self.currentIdx();
            self.emit(a64.cbz64(29, 0)); // placeholder — patched below
        }
        // Normal path only: flush depth counter before LDP clobbers x28.
        // Use emitLoadRegPtrAddr (computes from vm_ptr/x20, not REGS_PTR/x19) to avoid
        // crash when REGS_PTR is stale after self-call error propagation.
        if (self.depth_reg_cached) {
            self.emitLoadRegPtrAddr(SCRATCH); // SCRATCH = &vm.reg_ptr (from x20)
            self.emit(a64.str64(28, SCRATCH, 8)); // vm.call_depth = x28
        }
        // Restore callee-saved FP registers D8-D15 (only for non-self-call).
        if (!self.has_self_call) {
            self.emit(a64.ldpFpPost(14, 15, 31, 2));
            self.emit(a64.ldpFpPost(12, 13, 31, 2));
            self.emit(a64.ldpFpPost(10, 11, 31, 2));
            self.emit(a64.ldpFpPost(8, 9, 31, 2));
        }
        self.emit(a64.ldpPost(27, 28, 31, 2));
        self.emit(a64.ldpPost(25, 26, 31, 2));
        self.emit(a64.ldpPost(23, 24, 31, 2));
        self.emit(a64.ldpPost(21, 22, 31, 2));
        self.emit(a64.ldpPost(19, 20, 31, 2));
        // Patch CBZ to land on the final LDP x29,x30 (self-call path).
        if (self.has_self_call) {
            const target = self.currentIdx();
            const skip: i19 = @intCast(@as(i32, @intCast(target)) - @as(i32, @intCast(cbz_idx)));
            self.code.items[cbz_idx] = a64.cbz64(29, skip);
        }
        self.emit(a64.ldpPost(29, 30, 31, 2));
    }

    /// Flush x28 (depth counter) to vm.call_depth before trampoline calls.
    fn emitDepthFlush(self: *Compiler) void {
        const rp_slot: u16 = @intCast(@as(u32, self.reg_count) * 8);
        self.emit(a64.ldr64(SCRATCH, REGS_PTR, rp_slot)); // &vm.reg_ptr
        self.emit(a64.str64(28, SCRATCH, 8)); // vm.call_depth = x28
    }

    /// Emit OSR (On-Stack Replacement) prologue: a second entry point that sets up
    /// callee-saved registers and jumps directly to the loop body at osr_target_pc.
    /// Used for back-edge JIT of functions with reentry guards (C/C++ init patterns).
    fn emitOsrPrologue(self: *Compiler, target_pc: u32) void {
        self.osr_prologue_idx = self.currentIdx();

        // Same callee-saved pushes as normal prologue (must match epilogue)
        self.emit(a64.stpPre(29, 30, 31, -2)); // stp x29, x30, [sp, #-16]!
        self.emit(a64.stpPre(19, 20, 31, -2)); // stp x19, x20, [sp, #-16]!
        self.emit(a64.stpPre(21, 22, 31, -2)); // stp x21, x22, [sp, #-16]!
        self.emit(a64.stpPre(23, 24, 31, -2)); // stp x23, x24, [sp, #-16]!
        self.emit(a64.stpPre(25, 26, 31, -2)); // stp x25, x26, [sp, #-16]!
        self.emit(a64.stpPre(27, 28, 31, -2)); // stp x27, x28, [sp, #-16]!

        // Must match normal prologue: save FP callee-saved D8-D15 for non-self-call.
        // The shared epilogue pops these, so OSR must push them too.
        if (!self.has_self_call) {
            self.emit(a64.stpFpPre(8, 9, 31, -2));
            self.emit(a64.stpFpPre(10, 11, 31, -2));
            self.emit(a64.stpFpPre(12, 13, 31, -2));
            self.emit(a64.stpFpPre(14, 15, 31, -2));
        }

        // Self-call marker: x29 = SP (nonzero = normal entry, full epilogue)
        if (self.has_self_call) {
            self.emit(a64.addImm64(29, 31, 0)); // MOV x29, SP
        }

        // x19 (REGS_PTR) = x0 (first arg: register file pointer)
        self.emit(a64.mov64(REGS_PTR, 0));

        // Store VM pointer (x1) and Instance pointer (x2) to register file slots
        self.emit(a64.str64(1, REGS_PTR, @intCast((@as(u32, self.reg_count) + 2) * 8)));
        self.emit(a64.str64(2, REGS_PTR, @intCast((@as(u32, self.reg_count) + 3) * 8)));

        // Load memory cache (if function uses memory)
        // Must be BEFORE loading vregs — BLR trashes caller-saved (x0-x18).
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // Load ALL physically-mapped vregs from register file.
        // Unlike normal prologue (which uses prologue_load_mask), OSR must load all
        // because we're entering mid-function with interpreter's register state.
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        for (0..max) |i| {
            const vreg: u16 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }

        // Jump to the loop body at pc_map[target_pc]
        const target_idx = self.pc_map.items[target_pc];
        const current = self.currentIdx();
        const disp: i26 = @intCast(@as(i32, @intCast(target_idx)) - @as(i32, @intCast(current)));
        self.emit(a64.b(disp));
    }

    /// Reload x28 (depth counter) from vm.call_depth after trampoline calls.
    fn emitDepthReload(self: *Compiler) void {
        const rp_slot: u16 = @intCast(@as(u32, self.reg_count) * 8);
        self.emit(a64.ldr64(SCRATCH, REGS_PTR, rp_slot)); // &vm.reg_ptr
        self.emit(a64.ldr64(28, SCRATCH, 8)); // x28 = vm.call_depth
    }

    pub fn scanForMemoryOps(ir: []const RegInstr) bool {
        for (ir) |instr| {
            // 0x28-0x3E: load/store, 0x3F: memory.size, 0x40: memory.grow
            if (instr.op >= 0x28 and instr.op <= 0x40) return true;
            // Bulk memory ops also use linear memory
            if (instr.op == regalloc_mod.OP_MEMORY_FILL or
                instr.op == regalloc_mod.OP_MEMORY_COPY) return true;
        }
        return false;
    }

    /// Pre-scan IR to find all branch targets (PCs that can be jumped to).
    fn scanBranchTargets(self: *Compiler, ir: []const RegInstr) ?[]bool {
        const targets = self.alloc.alloc(bool, ir.len) catch return null;
        @memset(targets, false);
        var scan_pc: u32 = 0;
        while (scan_pc < ir.len) {
            const instr = ir[scan_pc];
            scan_pc += 1;
            switch (instr.op) {
                regalloc_mod.OP_BR => {
                    // operand = target PC
                    if (instr.operand < ir.len) targets[instr.operand] = true;
                },
                regalloc_mod.OP_BR_IF, regalloc_mod.OP_BR_IF_NOT => {
                    // operand = target PC
                    if (instr.operand < ir.len) targets[instr.operand] = true;
                },
                regalloc_mod.OP_BR_TABLE => {
                    // Next N+1 entries are NOP placeholders with targets in operand
                    const count = instr.operand;
                    var i: u32 = 0;
                    while (i < count + 1 and scan_pc < ir.len) : (i += 1) {
                        const entry = ir[scan_pc];
                        scan_pc += 1;
                        if (entry.operand < ir.len) targets[entry.operand] = true;
                    }
                },
                regalloc_mod.OP_BLOCK_END => {
                    // Block end is a merge point
                    targets[scan_pc - 1] = true;
                },
                else => {},
            }
        }
        return targets;
    }

    fn isControlFlowOp(_: *const Compiler, op: u16) bool {
        return switch (op) {
            regalloc_mod.OP_BR,
            regalloc_mod.OP_BR_IF,
            regalloc_mod.OP_BR_IF_NOT,
            regalloc_mod.OP_BR_TABLE,
            regalloc_mod.OP_BLOCK_END,
            regalloc_mod.OP_CALL,
            regalloc_mod.OP_CALL_INDIRECT,
            regalloc_mod.OP_RETURN,
            regalloc_mod.OP_RETURN_VOID,
            => true,
            else => false,
        };
    }

    // --- Main compilation ---

    pub fn compile(
        self: *Compiler,
        reg_func: *RegFunc,
        pool64: []const u64,
        trampoline_addr: u64,
        mem_info_addr: u64,
        global_get_addr: u64,
        global_set_addr: u64,
        mem_grow_addr: u64,
        mem_fill_addr: u64,
        mem_copy_addr: u64,
        call_indirect_addr: u64,
        self_func_idx: u32,
        param_count: u16,
        result_count: u16,
        reg_ptr_offset: u32,
    ) ?*JitCode {
        if (builtin.cpu.arch != .aarch64) return null;

        self.reg_count = reg_func.reg_count;
        self.local_count = reg_func.local_count;
        self.trampoline_addr = trampoline_addr;
        self.mem_info_addr = mem_info_addr;
        self.global_get_addr = global_get_addr;
        self.global_set_addr = global_set_addr;
        self.mem_grow_addr = mem_grow_addr;
        self.mem_fill_addr = mem_fill_addr;
        self.mem_copy_addr = mem_copy_addr;
        self.call_indirect_addr = call_indirect_addr;
        self.pool64 = pool64;
        self.self_func_idx = self_func_idx;
        self.param_count = param_count;
        self.result_count = result_count;
        self.reg_ptr_offset = reg_ptr_offset;

        // Scan IR for memory opcodes, self-calls, and non-self calls
        self.has_memory = scanForMemoryOps(reg_func.code);
        var found_self_call = false;
        var found_other_call = false;
        for (reg_func.code) |instr| {
            if (instr.op == regalloc_mod.OP_CALL) {
                if (instr.operand == self_func_idx) {
                    found_self_call = true;
                } else {
                    found_other_call = true;
                }
            } else if (instr.op == regalloc_mod.OP_CALL_INDIRECT) {
                found_other_call = true;
            } else if (instr.op >= predecode_mod.GC_BASE and instr.op <= predecode_mod.GC_BASE + 0x05) {
                found_other_call = true; // GC ops use BLR trampoline
            }
        }
        self.has_self_call = found_self_call;
        self.self_call_only = found_self_call and !found_other_call;
        // Self-call functions can't use D8-D15 (self-call entry skips D8-D15 save).
        self.fp_cache_limit = if (found_self_call) FP_CALLER_SAVED_SLOTS else FP_CACHE_SIZE;

        // Detect reentry guard: early branch to unreachable in first 8 IR instructions.
        // JitRestart re-executes from pc=0; guard already passed, so skip it in JIT code.
        const guard_limit = @min(reg_func.code.len, 8);
        for (reg_func.code[0..guard_limit], 0..) |ginstr, gi| {
            if (ginstr.op == regalloc_mod.OP_BR_IF_NOT or ginstr.op == regalloc_mod.OP_BR_IF) {
                const target = ginstr.operand;
                if (target < reg_func.code.len and reg_func.code[target].op == 0x00) {
                    self.guard_branch_pc = @intCast(gi);
                    break;
                }
            }
        }

        // Pre-scan: compute which vregs need loading in prologue
        self.prologue_load_mask = computePrologueLoads(self.local_count);

        // Emit fast-path for self-recursive base cases (before prologue).
        // Base cases return without callee-saved save/restore overhead.
        self.emitBaseCaseFastPath(reg_func.code);

        self.emitPrologue();

        const ir = reg_func.code;
        var pc: u32 = 0;

        // Pre-allocate pc_map indexed by RegInstr PC (not loop iteration)
        self.pc_map.appendNTimes(self.alloc, 0, ir.len + 1) catch return null;

        // Pre-scan: find branch targets for known_consts invalidation
        const branch_targets = self.scanBranchTargets(ir) orelse return null;
        defer self.alloc.free(branch_targets);

        // Store IR and branch targets for peephole fusion
        self.ir_slice = ir;
        self.branch_targets_slice = branch_targets;

        // Mark params as written (they're initialized by the caller)
        for (0..self.param_count) |i| {
            if (i < 128) self.written_vregs |= @as(u128, 1) << @as(u7, @intCast(i));
        }

        while (pc < ir.len) {
            const instr = ir[pc];

            // Clear caches at branch targets (merge points).
            // Evict BEFORE recording pc_map so fall-through paths get eviction
            // code but branches (which use pc_map) skip over it.
            if (pc < branch_targets.len and branch_targets[pc]) {
                self.known_consts = .{null} ** 128;
                self.scratch_vreg = null;
                self.fpCacheEvictAll();
            }

            // Record ARM64 code offset AFTER eviction — branches jump here.
            self.pc_map.items[pc] = self.currentIdx();

            pc += 1;

            if (!self.compileInstr(instr, ir, &pc)) return null;

            // Track known constants for bounds check elision
            if (instr.op == regalloc_mod.OP_CONST32) {
                if (instr.rd < 128) self.known_consts[instr.rd] = instr.operand;
            } else if (self.isControlFlowOp(instr.op)) {
                // After branches/calls, clear all — next basic block starts fresh
                self.known_consts = .{null} ** 128;
                self.scratch_vreg = null;
                self.fpCacheEvictAll();
            } else if (instr.rd < 128) {
                // Non-const write to rd invalidates that vreg's known const
                self.known_consts[instr.rd] = null;
            }
            // Track written vregs for spill optimization
            // Include CALL/CALL_INDIRECT results — they write to rd and must be spilled
            if (instr.rd < 128) {
                const op = instr.op;
                if (!self.isControlFlowOp(op) or op == regalloc_mod.OP_CALL or op == regalloc_mod.OP_CALL_INDIRECT) {
                    self.written_vregs |= @as(u128, 1) << @as(u7, @intCast(instr.rd));
                }
            }
        }
        // Trailing entry for end-of-function
        self.pc_map.items[ir.len] = self.currentIdx();

        // Emit error stubs (after all code including epilogue, before patching)
        self.emitErrorStubs();

        // Patch forward branches
        self.patchBranches() catch return null;

        // Emit OSR prologue if requested (for back-edge JIT with reentry guard)
        if (self.osr_target_pc) |target_pc| {
            if (target_pc < self.pc_map.items.len) {
                self.emitOsrPrologue(target_pc);
            }
        }

        // Finalize: copy to executable memory
        return self.finalize();
    }

    fn compileInstr(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        switch (instr.op) {
            // --- Register ops ---
            regalloc_mod.OP_MOV => {
                // FP-cache-aware MOV: if source is in D-reg cache, copy D-reg
                // directly instead of materializing to GPR and back.
                if (self.fpCacheFind(instr.rs1)) |src_slot| {
                    const src_dreg = fpSlotToDreg(src_slot);
                    // Invalidate destination's old FP cache entry
                    self.fpCacheInvalidate(instr.rd);
                    // Allocate D-reg for destination
                    const dst_dreg = self.fpAllocResult(instr.rd);
                    if (dst_dreg != src_dreg) {
                        self.emit(a64.fmovDD(dst_dreg, src_dreg));
                    }
                    self.fpMarkResultDirty(instr.rd);
                } else {
                    const src = self.getOrLoad(instr.rs1, SCRATCH);
                    self.storeVreg(instr.rd, src);
                }
            },
            regalloc_mod.OP_CONST32 => {
                const d = destReg(instr.rd);
                const val = instr.operand;
                if (val <= 0xFFFF) {
                    self.emit(a64.movz64(d, @truncate(val), 0));
                } else if ((~val & 0xFFFFFFFF) <= 0xFFFF) {
                    // Use MOVN for values like 0xFFFFxxxx (saves 1 insn)
                    self.emit(a64.movn32(d, @truncate(~val)));
                } else {
                    self.emit(a64.movz64(d, @truncate(val), 0));
                    self.emit(a64.movk64(d, @truncate(val >> 16), 1));
                }
                self.storeVreg(instr.rd, d);
            },
            regalloc_mod.OP_CONST64 => {
                const d = destReg(instr.rd);
                const val = self.pool64[instr.operand];
                const instrs = a64.loadImm64(d, val);
                for (instrs) |inst| self.emit(inst);
                self.storeVreg(instr.rd, d);
            },

            // --- Control flow ---
            regalloc_mod.OP_BR => {
                self.fpCacheEvictAll();
                const target = instr.operand;
                // Fuel check at back-edges (target <= current pc)
                if (target <= pc.* - 1) self.emitFuelCheck();
                const arm_idx = self.currentIdx();
                self.emit(a64.b(0)); // placeholder
                self.patches.append(self.alloc, .{
                    .arm64_idx = arm_idx,
                    .target_pc = target,
                    .kind = .b,
                }) catch return false;
            },
            regalloc_mod.OP_BR_IF => {
                self.fpCacheEvictAll();
                // Fuel check at back-edges (before the conditional branch)
                if (instr.operand <= pc.* - 1) self.emitFuelCheck();
                // Branch if rd != 0
                const cond_reg = self.getOrLoad(instr.rd, SCRATCH);
                const arm_idx = self.currentIdx();
                self.emit(a64.cbnz32(cond_reg, 0)); // placeholder
                self.patches.append(self.alloc, .{
                    .arm64_idx = arm_idx,
                    .target_pc = instr.operand,
                    .kind = .cbnz32,
                }) catch return false;
            },
            regalloc_mod.OP_BR_IF_NOT => {
                self.fpCacheEvictAll();
                // Fuel check at back-edges
                if (instr.operand <= pc.* - 1) self.emitFuelCheck();
                const cond_reg = self.getOrLoad(instr.rd, SCRATCH);
                const arm_idx = self.currentIdx();
                self.emit(a64.cbz32(cond_reg, 0)); // placeholder
                self.patches.append(self.alloc, .{
                    .arm64_idx = arm_idx,
                    .target_pc = instr.operand,
                    .kind = .cbz32,
                }) catch return false;
            },
            regalloc_mod.OP_RETURN => {
                self.fpCacheEvictAll();
                self.emitEpilogue(instr.rd);
            },
            regalloc_mod.OP_RETURN_VOID => {
                self.fpCacheEvictAll();
                self.emitEpilogue(null);
            },

            // --- Function call ---
            regalloc_mod.OP_CALL => {
                const func_idx = instr.operand;
                const n_args: u16 = @intCast(instr.rs1);
                const call_pc = pc.* - 1; // PC of this OP_CALL instruction
                const data = ir[pc.*];
                pc.* += 1;
                // Skip second data word if present
                const has_data2 = (pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP);
                var data2: RegInstr = undefined;
                if (has_data2) {
                    data2 = ir[pc.*];
                    pc.* += 1;
                }
                self.emitCall(instr.rd, func_idx, n_args, data, if (has_data2) data2 else null, ir, call_pc);
            },
            regalloc_mod.OP_CALL_INDIRECT => {
                const data = ir[pc.*];
                pc.* += 1;
                const has_data2 = (pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP);
                var data2: RegInstr = undefined;
                if (has_data2) {
                    data2 = ir[pc.*];
                    pc.* += 1;
                }
                self.emitCallIndirect(instr, data, if (has_data2) data2 else null);
            },
            regalloc_mod.OP_NOP => {}, // data word, already consumed
            regalloc_mod.OP_BLOCK_END => {}, // no-op in JIT
            regalloc_mod.OP_DELETED => {}, // no-op

            // --- i32 arithmetic ---
            0x6A => self.emitBinop32(.add, instr),
            0x6B => self.emitBinop32(.sub, instr),
            0x6C => self.emitBinop32(.mul, instr),
            0x6D => self.emitDiv32(.signed, instr),
            0x6E => self.emitDiv32(.unsigned, instr),
            0x6F => self.emitRem32(.signed, instr),
            0x70 => self.emitRem32(.unsigned, instr),
            0x71 => self.emitBinop32(.@"and", instr),
            0x72 => self.emitBinop32(.@"or", instr),
            0x73 => self.emitBinop32(.xor, instr),
            0x74 => self.emitBinop32(.shl, instr),
            0x75 => self.emitBinop32(.shr_s, instr),
            0x76 => self.emitBinop32(.shr_u, instr),
            0x77 => { // i32.rotl — RORV(n, 32-count)
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
                const d = destReg(instr.rd);
                self.emit(a64.neg32(SCRATCH2, rs2)); // negate shift amount
                self.emit(a64.rorv32(d, rs1, SCRATCH2));
                self.storeVreg(instr.rd, d);
            },
            0x78 => { // i32.rotr
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
                const d = destReg(instr.rd);
                self.emit(a64.rorv32(d, rs1, rs2));
                self.storeVreg(instr.rd, d);
            },
            0x67 => { // i32.clz
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.clz32(d, src));
                self.storeVreg(instr.rd, d);
            },
            0x68 => { // i32.ctz — RBIT then CLZ
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.rbit32(d, src));
                self.emit(a64.clz32(d, d));
                self.storeVreg(instr.rd, d);
            },
            0x69 => self.emitPopcnt32(instr), // i32.popcnt

            // --- i32 comparison ---
            0x45 => { // i32.eqz
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.cmp32(src, 31)); // CMP Wn, WZR
                if (!self.emitCmpResult(.eq, instr.rd, pc, false)) return false;
            },
            0x46 => if (!self.emitCmp32(.eq, instr, pc)) return false,
            0x47 => if (!self.emitCmp32(.ne, instr, pc)) return false,
            0x48 => if (!self.emitCmp32(.lt, instr, pc)) return false, // lt_s
            0x49 => if (!self.emitCmp32(.lo, instr, pc)) return false, // lt_u
            0x4A => if (!self.emitCmp32(.gt, instr, pc)) return false, // gt_s
            0x4B => if (!self.emitCmp32(.hi, instr, pc)) return false, // gt_u
            0x4C => if (!self.emitCmp32(.le, instr, pc)) return false, // le_s
            0x4D => if (!self.emitCmp32(.ls, instr, pc)) return false, // le_u
            0x4E => if (!self.emitCmp32(.ge, instr, pc)) return false, // ge_s
            0x4F => if (!self.emitCmp32(.hs, instr, pc)) return false, // ge_u

            // --- i64 arithmetic ---
            0x7C => self.emitBinop64(.add, instr),
            0x7D => self.emitBinop64(.sub, instr),
            0x7E => self.emitBinop64(.mul, instr),
            0x7F => self.emitDiv64(.signed, instr),
            0x80 => self.emitDiv64(.unsigned, instr),
            0x81 => self.emitRem64(.signed, instr),
            0x82 => self.emitRem64(.unsigned, instr),
            0x83 => self.emitBinop64(.@"and", instr),
            0x84 => self.emitBinop64(.@"or", instr),
            0x85 => self.emitBinop64(.xor, instr),
            0x86 => self.emitBinop64(.shl, instr),
            0x87 => self.emitBinop64(.shr_s, instr),
            0x88 => self.emitBinop64(.shr_u, instr),
            0x89 => { // i64.rotl
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
                const d = destReg(instr.rd);
                self.emit(a64.neg64(SCRATCH2, rs2));
                self.emit(a64.rorv64(d, rs1, SCRATCH2));
                self.storeVreg(instr.rd, d);
            },
            0x8A => { // i64.rotr
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
                const d = destReg(instr.rd);
                self.emit(a64.rorv64(d, rs1, rs2));
                self.storeVreg(instr.rd, d);
            },
            0x79 => { // i64.clz
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.clz64(d, src));
                self.storeVreg(instr.rd, d);
            },
            0x7A => { // i64.ctz
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.rbit64(d, src));
                self.emit(a64.clz64(d, d));
                self.storeVreg(instr.rd, d);
            },
            0x7B => self.emitPopcnt64(instr), // i64.popcnt

            // --- i64 comparison ---
            0x50 => { // i64.eqz
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.cmpImm64(src, 0));
                if (!self.emitCmpResult(.eq, instr.rd, pc, true)) return false;
            },
            0x51 => if (!self.emitCmp64(.eq, instr, pc)) return false,
            0x52 => if (!self.emitCmp64(.ne, instr, pc)) return false,
            0x53 => if (!self.emitCmp64(.lt, instr, pc)) return false,
            0x54 => if (!self.emitCmp64(.lo, instr, pc)) return false,
            0x55 => if (!self.emitCmp64(.gt, instr, pc)) return false,
            0x56 => if (!self.emitCmp64(.hi, instr, pc)) return false,
            0x57 => if (!self.emitCmp64(.le, instr, pc)) return false,
            0x58 => if (!self.emitCmp64(.ls, instr, pc)) return false,
            0x59 => if (!self.emitCmp64(.ge, instr, pc)) return false,
            0x5A => if (!self.emitCmp64(.hs, instr, pc)) return false,

            // --- Conversions ---
            0xA7 => { // i32.wrap_i64
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.uxtw(d, src));
                self.storeVreg(instr.rd, d);
            },
            0xAC => { // i64.extend_i32_s
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.sxtw(d, src));
                self.storeVreg(instr.rd, d);
            },
            0xAD => { // i64.extend_i32_u
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.uxtw(d, src));
                self.storeVreg(instr.rd, d);
            },

            // --- Reinterpret (bit-preserving) ---
            0xBC, 0xBE => { // i32.reinterpret_f32, f32.reinterpret_i32
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.uxtw(d, src)); // truncate to 32-bit
                self.storeVreg(instr.rd, d);
            },
            0xBD, 0xBF => { // i64.reinterpret_f64, f64.reinterpret_i64
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.storeVreg(instr.rd, src); // 64-bit copy
            },

            // --- f64 binary arithmetic ---
            0xA0, 0xA1, 0xA2, 0xA3 => self.emitFpBinop64(instr),
            // --- f64 unary ops ---
            0x9F => self.emitFpUnop64(a64.fsqrt64, instr), // f64.sqrt
            0x99 => self.emitFpUnop64(a64.fabs64, instr),  // f64.abs
            0x9A => self.emitFpUnop64(a64.fneg64, instr),  // f64.neg
            // --- f64 min/max ---
            0xA4 => self.emitFpBinopDirect64(a64.fmin64, instr), // f64.min
            0xA5 => self.emitFpBinopDirect64(a64.fmax64, instr), // f64.max
            // --- f64 comparisons (NaN-safe: mi/ls not lt/le) ---
            0x61 => self.emitFpCmp64(.eq, instr), // f64.eq
            0x62 => self.emitFpCmp64(.ne, instr), // f64.ne
            0x63 => self.emitFpCmp64(.mi, instr), // f64.lt  (MI: N=1, false for NaN)
            0x64 => self.emitFpCmp64(.gt, instr), // f64.gt  (GT: Z=0∧N=V, false for NaN)
            0x65 => self.emitFpCmp64(.ls, instr), // f64.le  (LS: C=0∨Z=1, false for NaN)
            0x66 => self.emitFpCmp64(.ge, instr), // f64.ge  (GE: N=V, false for NaN)

            // --- f32 binary arithmetic ---
            0x92, 0x93, 0x94, 0x95 => self.emitFpBinop32(instr),
            // --- f32 unary ops ---
            0x91 => self.emitFpUnop32(a64.fsqrt32, instr), // f32.sqrt
            0x8B => self.emitFpUnop32(a64.fabs32, instr),  // f32.abs
            0x8C => self.emitFpUnop32(a64.fneg32, instr),  // f32.neg
            // --- f32 min/max ---
            0x96 => self.emitFpBinopDirect32(a64.fmin32, instr), // f32.min
            0x97 => self.emitFpBinopDirect32(a64.fmax32, instr), // f32.max
            // --- f32 comparisons (NaN-safe: mi/ls not lt/le) ---
            0x5B => self.emitFpCmp32(.eq, instr), // f32.eq
            0x5C => self.emitFpCmp32(.ne, instr), // f32.ne
            0x5D => self.emitFpCmp32(.mi, instr), // f32.lt
            0x5E => self.emitFpCmp32(.gt, instr), // f32.gt
            0x5F => self.emitFpCmp32(.ls, instr), // f32.le
            0x60 => self.emitFpCmp32(.ge, instr), // f32.ge

            // --- f64 conversions ---
            0xB7 => self.emitFpConvert_f64_i32_s(instr),  // f64.convert_i32_s
            0xB8 => self.emitFpConvert_f64_i32_u(instr),  // f64.convert_i32_u
            0xB9 => self.emitFpConvert_f64_i64_s(instr),  // f64.convert_i64_s
            0xBA => self.emitFpConvert_f64_i64_u(instr),  // f64.convert_i64_u
            0xBB => self.emitFpPromote(instr),             // f64.promote_f32
            // --- f32 conversions ---
            0xB2 => self.emitFpConvert_f32_i32_s(instr),  // f32.convert_i32_s
            0xB3 => self.emitFpConvert_f32_i32_u(instr),  // f32.convert_i32_u
            0xB4 => self.emitFpConvert_f32_i64_s(instr),  // f32.convert_i64_s
            0xB5 => self.emitFpConvert_f32_i64_u(instr),  // f32.convert_i64_u
            0xB6 => self.emitFpDemote(instr),              // f32.demote_f64
            // --- f32/f64 copysign ---
            0x98 => self.emitFpCopysign32(instr),
            0xA6 => self.emitFpCopysign64(instr),
            // --- f64 rounding ---
            0x9B => self.emitFpRound64(0x1E64C000, instr), // f64.ceil: FRINTP Dd, Dn
            0x9C => self.emitFpRound64(0x1E654000, instr), // f64.floor: FRINTM Dd, Dn
            0x9D => self.emitFpRound64(0x1E65C000, instr), // f64.trunc: FRINTZ Dd, Dn
            0x9E => self.emitFpRound64(0x1E644000, instr), // f64.nearest: FRINTN Dd, Dn
            // --- f32 rounding ---
            0x8D => self.emitFpRound32(0x1E24C000, instr), // f32.ceil: FRINTP Sd, Sn
            0x8E => self.emitFpRound32(0x1E254000, instr), // f32.floor: FRINTM Sd, Sn
            0x8F => self.emitFpRound32(0x1E25C000, instr), // f32.trunc: FRINTZ Sd, Sn
            0x90 => self.emitFpRound32(0x1E244000, instr), // f32.nearest: FRINTN Sd, Sn
            // --- float to int truncation ---
            0xA8 => self.emitTruncToI32(instr, false, true),   // i32.trunc_f32_s
            0xA9 => self.emitTruncToI32(instr, false, false),  // i32.trunc_f32_u
            0xAA => self.emitTruncToI32(instr, true, true),    // i32.trunc_f64_s
            0xAB => self.emitTruncToI32(instr, true, false),   // i32.trunc_f64_u
            0xAE => self.emitTruncToI64(instr, false, true),   // i64.trunc_f32_s
            0xAF => self.emitTruncToI64(instr, false, false),  // i64.trunc_f32_u
            0xB0 => self.emitTruncToI64(instr, true, true),    // i64.trunc_f64_s
            0xB1 => self.emitTruncToI64(instr, true, false),   // i64.trunc_f64_u

            // --- Sign extension (Wasm 2.0) ---
            0xC0 => { // i32.extend8_s — SXTB Wd, Wn
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(0x13001C00 | (@as(u32, src) << 5) | d);
                self.storeVreg(instr.rd, d);
            },
            0xC1 => { // i32.extend16_s — SXTH Wd, Wn
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(0x13003C00 | (@as(u32, src) << 5) | d);
                self.storeVreg(instr.rd, d);
            },
            0xC2 => { // i64.extend8_s — SXTB Xd, Wn
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(0x93401C00 | (@as(u32, src) << 5) | d);
                self.storeVreg(instr.rd, d);
            },
            0xC3 => { // i64.extend16_s — SXTH Xd, Wn
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(0x93403C00 | (@as(u32, src) << 5) | d);
                self.storeVreg(instr.rd, d);
            },
            0xC4 => { // i64.extend32_s — SXTW Xd, Wn
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.sxtw(d, src));
                self.storeVreg(instr.rd, d);
            },

            // --- Memory load ---
            // rd = dest, rs1 = base addr reg, operand = static offset
            0x28 => self.emitMemLoad(instr, .w32, 4),   // i32.load
            0x29 => self.emitMemLoad(instr, .x64, 8),   // i64.load
            0x2A => self.emitMemLoad(instr, .w32, 4),   // f32.load (same bits as i32)
            0x2B => self.emitFpMemLoad64(instr),          // f64.load → FP cache direct
            0x2C => self.emitMemLoad(instr, .s8_32, 1),  // i32.load8_s
            0x2D => self.emitMemLoad(instr, .u8, 1),    // i32.load8_u
            0x2E => self.emitMemLoad(instr, .s16_32, 2), // i32.load16_s
            0x2F => self.emitMemLoad(instr, .u16, 2),   // i32.load16_u
            0x30 => self.emitMemLoad(instr, .s8_64, 1),  // i64.load8_s
            0x31 => self.emitMemLoad(instr, .u8, 1),    // i64.load8_u
            0x32 => self.emitMemLoad(instr, .s16_64, 2), // i64.load16_s
            0x33 => self.emitMemLoad(instr, .u16, 2),   // i64.load16_u
            0x34 => self.emitMemLoad(instr, .s32_64, 4), // i64.load32_s
            0x35 => self.emitMemLoad(instr, .w32, 4),   // i64.load32_u

            // --- Memory store ---
            // rd = value reg, rs1 = base addr reg, operand = static offset
            0x36 => self.emitMemStore(instr, .w32, 4),  // i32.store
            0x37 => self.emitMemStore(instr, .x64, 8),  // i64.store
            0x38 => self.emitMemStore(instr, .w32, 4),  // f32.store
            0x39 => self.emitFpMemStore64(instr),         // f64.store → FP cache direct
            0x3A => self.emitMemStore(instr, .b8, 1),   // i32.store8
            0x3B => self.emitMemStore(instr, .h16, 2),  // i32.store16
            0x3C => self.emitMemStore(instr, .b8, 1),   // i64.store8
            0x3D => self.emitMemStore(instr, .h16, 2),  // i64.store16
            0x3E => self.emitMemStore(instr, .w32, 4),  // i64.store32

            // --- Fused immediate ops ---
            regalloc_mod.OP_ADDI32 => self.emitImmOp32(.add, instr),
            regalloc_mod.OP_SUBI32 => self.emitImmOp32(.sub, instr),
            regalloc_mod.OP_MULI32 => {
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.movz32(SCRATCH2, @truncate(instr.operand), 0));
                if (instr.operand > 0xFFFF) {
                    self.emit(a64.movk64(SCRATCH2, @truncate(instr.operand >> 16), 1));
                }
                self.emit(a64.mul32(d, rs1, SCRATCH2));
                self.storeVreg(instr.rd, d);
            },
            regalloc_mod.OP_ANDI32, regalloc_mod.OP_ORI32, regalloc_mod.OP_XORI32 => {
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.movz32(SCRATCH2, @truncate(instr.operand), 0));
                if (instr.operand > 0xFFFF) {
                    self.emit(a64.movk64(SCRATCH2, @truncate(instr.operand >> 16), 1));
                }
                const enc: u32 = switch (instr.op) {
                    regalloc_mod.OP_ANDI32 => a64.and32(d, rs1, SCRATCH2),
                    regalloc_mod.OP_ORI32 => a64.orr32(d, rs1, SCRATCH2),
                    regalloc_mod.OP_XORI32 => a64.eor32(d, rs1, SCRATCH2),
                    else => unreachable,
                };
                self.emit(enc);
                self.storeVreg(instr.rd, d);
            },
            regalloc_mod.OP_SHLI32 => {
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.movz32(SCRATCH2, @truncate(instr.operand), 0));
                self.emit(a64.lslv32(d, rs1, SCRATCH2));
                self.storeVreg(instr.rd, d);
            },

            // --- Fused comparison with immediate ---
            regalloc_mod.OP_EQ_I32 => if (!self.emitCmpImm32(.eq, instr, pc)) return false,
            regalloc_mod.OP_NE_I32 => if (!self.emitCmpImm32(.ne, instr, pc)) return false,
            regalloc_mod.OP_LT_S_I32 => if (!self.emitCmpImm32(.lt, instr, pc)) return false,
            regalloc_mod.OP_GT_S_I32 => if (!self.emitCmpImm32(.gt, instr, pc)) return false,
            regalloc_mod.OP_LE_S_I32 => if (!self.emitCmpImm32(.le, instr, pc)) return false,
            regalloc_mod.OP_GE_S_I32 => if (!self.emitCmpImm32(.ge, instr, pc)) return false,
            regalloc_mod.OP_LT_U_I32 => if (!self.emitCmpImm32(.lo, instr, pc)) return false,
            regalloc_mod.OP_GE_U_I32 => if (!self.emitCmpImm32(.hs, instr, pc)) return false,

            // --- Select ---
            0x1B => { // select: rd = cond ? val1 : val2
                const val2_idx = instr.rs2_field;
                const cond_idx: u16 = @truncate(instr.operand);
                const d = destReg(instr.rd);
                // Compare condition first (before clobbering scratch regs)
                const cond_reg = self.getOrLoad(cond_idx, SCRATCH);
                self.emit(a64.cmpImm32(cond_reg, 0));
                // Load val1 and val2
                const val1 = self.getOrLoad(instr.rs1, SCRATCH);
                const val2_reg = self.getOrLoad(val2_idx, SCRATCH2);
                // CSEL: if cond != 0 (ne), select val1; else val2
                self.emit(a64.csel64(d, val1, val2_reg, .ne));
                self.storeVreg(instr.rd, d);
            },

            // --- Drop ---
            0x1A => {}, // no-op

            // --- br_table ---
            regalloc_mod.OP_BR_TABLE => {
                if (!self.emitBrTable(instr, ir, pc)) return false;
            },

            // --- Unreachable ---
            0x00 => {
                self.emitErrorReturn(1); // Trap
            },

            // --- Global get/set ---
            0x23 => self.emitGlobalGet(instr), // global.get
            0x24 => self.emitGlobalSet(instr), // global.set

            // --- Memory size/grow ---
            0x3F => { // memory.size: rd = memory pages
                // MEM_SIZE (x28) = memory size in bytes.  pages = bytes >> 16 (PAGE_SIZE=65536)
                const d = destReg(instr.rd);
                self.emit(a64.lsr64Imm(d, MEM_SIZE, 16));
                self.storeVreg(instr.rd, d);
            },
            0x40 => { // memory.grow: rd = old_pages | -1
                self.emitMemGrow(instr);
            },

            // --- Bulk memory: fill/copy ---
            regalloc_mod.OP_MEMORY_FILL => self.emitMemFill(instr),
            regalloc_mod.OP_MEMORY_COPY => self.emitMemCopy(instr),

            // --- Saturating truncation (0xFC prefix) ---
            0xFC00, 0xFC01, // i32.trunc_sat_f32_s/u
            0xFC02, 0xFC03, // i32.trunc_sat_f64_s/u
            0xFC04, 0xFC05, // i64.trunc_sat_f32_s/u
            0xFC06, 0xFC07, // i64.trunc_sat_f64_s/u
            => self.emitTruncSat(instr),

            // --- ref.null / ref.is_null ---
            regalloc_mod.OP_REF_NULL => {
                const d = destReg(instr.rd);
                self.emit(a64.movz64(d, 0, 0)); // null ref = 0
                self.storeVreg(instr.rd, d);
            },
            regalloc_mod.OP_REF_IS_NULL => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const d = destReg(instr.rd);
                self.emit(a64.cmp64(src, 31)); // CMP Xn, XZR
                self.emit(a64.cset64(d, .eq)); // rd = (src == 0) ? 1 : 0
                self.storeVreg(instr.rd, d);
            },

            // --- GC struct operations (BLR to runtime helper) ---
            predecode_mod.GC_BASE | 0x00 => { // struct.new
                const n_fields: u16 = instr.rs1;
                const call_pc = pc.* - 1;
                const data = ir[pc.*]; pc.* += 1;
                const has_data2 = (pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP);
                var data2: RegInstr = undefined;
                if (has_data2) { data2 = ir[pc.*]; pc.* += 1; }
                self.emitGcStructNew(instr.rd, instr.operand, n_fields, data, if (has_data2) data2 else null, ir, call_pc);
            },
            predecode_mod.GC_BASE | 0x01 => self.emitGcSimple(instr, ir, pc.* - 1), // struct.new_default
            predecode_mod.GC_BASE | 0x02 => self.emitGcSimple(instr, ir, pc.* - 1), // struct.get
            predecode_mod.GC_BASE | 0x03 => self.emitGcSimple(instr, ir, pc.* - 1), // struct.get_s
            predecode_mod.GC_BASE | 0x04 => self.emitGcSimple(instr, ir, pc.* - 1), // struct.get_u
            predecode_mod.GC_BASE | 0x05 => self.emitGcSimple(instr, ir, pc.* - 1), // struct.set

            // ---- SIMD opcodes: native NEON or trampoline fallback ----
            predecode_mod.SIMD_BASE...predecode_mod.SIMD_BASE + 0x113 => {
                if (!self.emitSimdNative(instr, ir, pc)) {
                    self.emitSimdTrampoline(instr, ir, pc);
                }
            },

            // Unsupported opcode — bail out, function can't be JIT compiled
            else => return false,
        }
        return true;
    }

    // --- Helper emitters ---

    const BinOp32 = enum { add, sub, mul, @"and", @"or", xor, shl, shr_s, shr_u };

    fn emitBinop32(self: *Compiler, op: BinOp32, instr: RegInstr) void {
        // Constant-folding for ADD/SUB with imm12 operand
        if (op == .add or op == .sub) {
            if (self.tryEmitBinopImm32(op, instr)) return;
        }
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        const enc: u32 = switch (op) {
            .add => a64.add32(d, rs1, rs2),
            .sub => a64.sub32(d, rs1, rs2),
            .mul => a64.mul32(d, rs1, rs2),
            .@"and" => a64.and32(d, rs1, rs2),
            .@"or" => a64.orr32(d, rs1, rs2),
            .xor => a64.eor32(d, rs1, rs2),
            .shl => a64.lslv32(d, rs1, rs2),
            .shr_s => a64.asrv32(d, rs1, rs2),
            .shr_u => a64.lsrv32(d, rs1, rs2),
        };
        self.emit(enc);
        self.storeVreg(instr.rd, d);
    }

    const BinOp64 = enum { add, sub, mul, @"and", @"or", xor, shl, shr_s, shr_u };

    fn emitBinop64(self: *Compiler, op: BinOp64, instr: RegInstr) void {
        // Constant-folding for ADD/SUB with imm12 operand
        if (op == .add or op == .sub) {
            if (self.tryEmitBinopImm64(op, instr)) return;
        }
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        const enc: u32 = switch (op) {
            .add => a64.add64(d, rs1, rs2),
            .sub => a64.sub64(d, rs1, rs2),
            .mul => a64.mul64(d, rs1, rs2),
            .@"and" => a64.and64(d, rs1, rs2),
            .@"or" => a64.orr64(d, rs1, rs2),
            .xor => a64.eor64(d, rs1, rs2),
            .shl => a64.lslv64(d, rs1, rs2),
            .shr_s => a64.asrv64(d, rs1, rs2),
            .shr_u => a64.lsrv64(d, rs1, rs2),
        };
        self.emit(enc);
        self.storeVreg(instr.rd, d);
    }

    /// Try to emit ADD/SUB with immediate operand (saves one register load).
    /// Returns true if emitted, false if not applicable.
    fn tryEmitBinopImm32(self: *Compiler, op: BinOp32, instr: RegInstr) bool {
        const rs2_vreg = instr.rs2();
        // Check rs2 for known constant
        if (rs2_vreg < 128) {
            if (self.known_consts[rs2_vreg]) |c| {
                if (c <= 0xFFF) {
                    const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                    const d = destReg(instr.rd);
                    self.emit(if (op == .add) a64.addImm32(d, rs1, @intCast(c)) else a64.subImm32(d, rs1, @intCast(c)));
                    self.storeVreg(instr.rd, d);
                    return true;
                }
            }
        }
        // For ADD (commutative): check if rs1 is a known constant
        if (op == .add and instr.rs1 < 128) {
            if (self.known_consts[instr.rs1]) |c| {
                if (c <= 0xFFF) {
                    const rs2 = self.getOrLoad(rs2_vreg, SCRATCH);
                    const d = destReg(instr.rd);
                    self.emit(a64.addImm32(d, rs2, @intCast(c)));
                    self.storeVreg(instr.rd, d);
                    return true;
                }
            }
        }
        return false;
    }

    /// Try to emit ADD/SUB with immediate operand (64-bit).
    fn tryEmitBinopImm64(self: *Compiler, op: BinOp64, instr: RegInstr) bool {
        const rs2_vreg = instr.rs2();
        if (rs2_vreg < 128) {
            if (self.known_consts[rs2_vreg]) |c| {
                if (c <= 0xFFF) {
                    const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                    const d = destReg(instr.rd);
                    self.emit(if (op == .add) a64.addImm64(d, rs1, @intCast(c)) else a64.subImm64(d, rs1, @intCast(c)));
                    self.storeVreg(instr.rd, d);
                    return true;
                }
            }
        }
        if (op == .add and instr.rs1 < 128) {
            if (self.known_consts[instr.rs1]) |c| {
                if (c <= 0xFFF) {
                    const rs2 = self.getOrLoad(rs2_vreg, SCRATCH);
                    const d = destReg(instr.rd);
                    self.emit(a64.addImm64(d, rs2, @intCast(c)));
                    self.storeVreg(instr.rd, d);
                    return true;
                }
            }
        }
        return false;
    }

    /// Try to fuse a CMP result with a following BR_IF/BR_IF_NOT.
    /// If fuseable: emits B.cond placeholder, adds patch, advances pc past the BR_IF.
    /// Returns true if fused, false if not fuseable. Returns error (null bool) on OOM.
    fn tryFuseBranch(self: *Compiler, cond: a64.Cond, rd: u16, pc: *u32) ?bool {
        if (pc.* >= self.ir_slice.len) return false;
        const next = self.ir_slice[pc.*];
        // Only fuse if next is BR_IF/BR_IF_NOT consuming this rd
        if (next.op != regalloc_mod.OP_BR_IF and next.op != regalloc_mod.OP_BR_IF_NOT) return false;
        if (next.rd != rd) return false;
        // Don't fuse if the BR_IF is a branch target (merge point)
        if (pc.* < self.branch_targets_slice.len and self.branch_targets_slice[pc.*]) return false;

        // Fuse: emit B.cond instead of CSET + CBNZ/CBZ
        self.fpCacheEvictAll();
        const actual_cond = if (next.op == regalloc_mod.OP_BR_IF) cond else cond.invert();
        const arm_idx = self.currentIdx();
        self.emit(a64.bCond(actual_cond, 0)); // placeholder
        self.patches.append(self.alloc, .{
            .arm64_idx = arm_idx,
            .target_pc = next.operand,
            .kind = .b_cond,
        }) catch return null; // OOM

        // Record pc_map for the skipped BR_IF and advance past it
        self.pc_map.items[pc.*] = self.currentIdx();
        pc.* += 1;

        // Match unfused behavior: conditional branch is a control flow point
        self.known_consts = .{null} ** 128;
        self.scratch_vreg = null;
        return true;
    }

    /// After CMP emission: try fusion with following BR_IF, or fall back to CSET + store.
    fn emitCmpResult(self: *Compiler, cond: a64.Cond, rd: u16, pc: *u32, is64: bool) bool {
        if (self.tryFuseBranch(cond, rd, pc)) |fused| {
            if (fused) return true;
        } else return false; // OOM
        // No fusion — emit CSET + store
        const d = destReg(rd);
        if (is64) {
            self.emit(a64.cset64(d, cond));
        } else {
            self.emit(a64.cset32(d, cond));
        }
        self.storeVreg(rd, d);
        return true;
    }

    fn emitCmp32(self: *Compiler, cond: a64.Cond, instr: RegInstr, pc: *u32) bool {
        const rs2_vreg = instr.rs2();
        // Use CMP-immediate when rs2 is a known small constant
        if (rs2_vreg < 128) {
            if (self.known_consts[rs2_vreg]) |c| {
                if (c <= 0xFFF) {
                    const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                    self.emit(a64.cmpImm32(rs1, @intCast(c)));
                    return self.emitCmpResult(cond, instr.rd, pc, false);
                }
            }
        }
        // Also check if rs1 is a known constant (swap operands, invert condition)
        if (instr.rs1 < 128) {
            if (self.known_consts[instr.rs1]) |c| {
                if (c <= 0xFFF) {
                    const rs2 = self.getOrLoad(rs2_vreg, SCRATCH);
                    self.emit(a64.cmpImm32(rs2, @intCast(c)));
                    return self.emitCmpResult(cond.swap(), instr.rd, pc, false);
                }
            }
        }
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(rs2_vreg, SCRATCH2);
        self.emit(a64.cmp32(rs1, rs2));
        return self.emitCmpResult(cond, instr.rd, pc, false);
    }

    fn emitCmp64(self: *Compiler, cond: a64.Cond, instr: RegInstr, pc: *u32) bool {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        self.emit(a64.cmp64(rs1, rs2));
        return self.emitCmpResult(cond, instr.rd, pc, true);
    }

    fn emitCmpImm32(self: *Compiler, cond: a64.Cond, instr: RegInstr, pc: *u32) bool {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const imm = instr.operand;
        if (imm <= 0xFFF) {
            self.emit(a64.cmpImm32(rs1, @intCast(imm)));
        } else {
            self.emit(a64.movz32(SCRATCH2, @truncate(imm), 0));
            if (imm > 0xFFFF)
                self.emit(a64.movk64(SCRATCH2, @truncate(imm >> 16), 1));
            self.emit(a64.cmp32(rs1, SCRATCH2));
        }
        return self.emitCmpResult(cond, instr.rd, pc, false);
    }

    fn emitImmOp32(self: *Compiler, op: enum { add, sub }, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const d = destReg(instr.rd);
        const imm = instr.operand;
        if (imm <= 0xFFF) {
            const enc: u32 = switch (op) {
                .add => a64.addImm32(d, rs1, @intCast(imm)),
                .sub => a64.subImm32(d, rs1, @intCast(imm)),
            };
            self.emit(enc);
        } else if (op == .add and imm >= 0xFFFFF001) {
            // Large add is really a small sub: add rs1, -N → sub rs1, N
            const neg: u12 = @intCast(0 -% imm);
            self.emit(a64.subImm32(d, rs1, neg));
        } else if (op == .sub and imm >= 0xFFFFF001) {
            // Large sub is really a small add: sub rs1, -N → add rs1, N
            const neg: u12 = @intCast(0 -% imm);
            self.emit(a64.addImm32(d, rs1, neg));
        } else {
            self.emit(a64.movz32(SCRATCH2, @truncate(imm), 0));
            if (imm > 0xFFFF)
                self.emit(a64.movk64(SCRATCH2, @truncate(imm >> 16), 1));
            const enc: u32 = switch (op) {
                .add => a64.add32(d, rs1, SCRATCH2),
                .sub => a64.sub32(d, rs1, SCRATCH2),
            };
            self.emit(enc);
        }
        self.storeVreg(instr.rd, d);
    }

    const Signedness = enum { signed, unsigned };

    const MagicU32 = struct { magic: u32, shift: u6 };

    /// Compute magic multiplier for unsigned 32-bit division by constant.
    /// Returns (magic, shift) such that: floor(n/d) = floor((u64(n) * magic) >> shift)
    /// Returns null for divisors that require the "add fixup" (not handled).
    fn computeMagicU32(d: u32) ?MagicU32 {
        if (d < 2) return null;
        // Power of 2: handled separately by caller
        if (d & (d - 1) == 0) return null;
        // Find smallest p >= 32 where ceil(2^p/d) fits in u32 and is correct
        for (32..64) |p| {
            const two_p: u64 = @as(u64, 1) << @intCast(p);
            const magic: u64 = (two_p + d - 1) / d; // ceil(2^p / d)
            if (magic > 0xFFFFFFFF) continue;
            // Correctness condition: (d - remainder) * (2^32 - 1) < 2^p
            const rem = two_p % d;
            const err = if (rem == 0) 0 else d - @as(u32, @intCast(rem));
            if (@as(u64, err) * 0xFFFFFFFF < two_p) {
                return .{ .magic = @intCast(magic), .shift = @intCast(p) };
            }
        }
        return null;
    }

    fn emitDiv32(self: *Compiler, sign: Signedness, instr: RegInstr) void {
        // Fast path: unsigned division by known constant
        if (sign == .unsigned) {
            const rs2_vreg = instr.rs2();
            if (rs2_vreg < 128) {
                if (self.known_consts[rs2_vreg]) |divisor| {
                    if (divisor >= 2 and self.tryEmitDivByConstU32(instr, divisor))
                        return;
                }
            }
        }
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        // Check divisor == 0 → DivisionByZero
        self.emit(a64.cmpImm32(rs2, 0));
        self.emitCondError(.eq, 3); // error code 3 = DivisionByZero
        if (sign == .signed) {
            // Check INT_MIN / -1 → IntegerOverflow
            // INT_MIN (i32) = 0x80000000
            self.emit(a64.movn32(SCRATCH, 0)); // SCRATCH = -1 (0xFFFFFFFF)
            self.emit(a64.cmp32(rs2, SCRATCH));
            const skip_idx = self.currentIdx();
            self.emit(a64.bCond(.ne, 0)); // if rs2 != -1, skip overflow check
            self.emit(a64.movz32(SCRATCH, 0, 0));
            self.emit(a64.movk64(SCRATCH, 0x8000, 1)); // SCRATCH = 0x80000000
            self.emit(a64.cmp32(rs1, SCRATCH));
            self.emitCondError(.eq, 4); // error code 4 = IntegerOverflow
            // Patch skip branch
            const here = self.currentIdx();
            self.code.items[skip_idx] = a64.bCond(.ne, @intCast(@as(i32, @intCast(here)) - @as(i32, @intCast(skip_idx))));
            // Reload rs1/rs2 since we clobbered SCRATCH
            const rs1b = self.getOrLoad(instr.rs1, SCRATCH);
            const rs2b = self.getOrLoad(instr.rs2(), SCRATCH2);
            self.emit(a64.sdiv32(d, rs1b, rs2b));
        } else {
            self.emit(a64.udiv32(d, rs1, rs2));
        }
        self.storeVreg(instr.rd, d);
    }

    /// Emit unsigned division by known constant using multiply-by-reciprocal.
    fn tryEmitDivByConstU32(self: *Compiler, instr: RegInstr, divisor: u32) bool {
        // Power of 2: just LSR
        if (divisor & (divisor - 1) == 0) {
            const shift: u5 = @intCast(@ctz(divisor));
            const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
            const d = destReg(instr.rd);
            self.emit(a64.lsr32Imm(d, rs1, shift));
            self.storeVreg(instr.rd, d);
            return true;
        }
        const m = computeMagicU32(divisor) orelse return false;
        // Codegen: MOVZ+MOVK magic → UMULL → LSR
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        self.emitLoadImm(SCRATCH2, m.magic);
        // UMULL Xscratch, Wrs1, Wscratch2 — 32×32→64
        self.emit(a64.umull(SCRATCH, rs1, SCRATCH2));
        self.scratch_vreg = null; // UMULL clobbers SCRATCH
        // LSR Xscratch, Xscratch, #shift — extract quotient
        self.emit(a64.lsr64Imm(SCRATCH, SCRATCH, m.shift));
        const d = destReg(instr.rd);
        if (d != SCRATCH) self.emit(a64.mov32(d, SCRATCH));
        self.storeVreg(instr.rd, d);
        return true;
    }

    fn emitRem32(self: *Compiler, sign: Signedness, instr: RegInstr) void {
        // Fast path: unsigned remainder by known constant
        if (sign == .unsigned) {
            const rs2_vreg = instr.rs2();
            if (rs2_vreg < 128) {
                if (self.known_consts[rs2_vreg]) |divisor| {
                    if (divisor >= 2 and self.tryEmitRemByConstU32(instr, divisor))
                        return;
                }
            }
        }
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        // Check divisor == 0 → DivisionByZero
        self.emit(a64.cmpImm32(rs2, 0));
        self.emitCondError(.eq, 3);
        // rem = rs1 - (rs1/rs2)*rs2  via SDIV + MSUB
        if (sign == .signed) {
            self.emit(a64.sdiv32(d, rs1, rs2));
        } else {
            self.emit(a64.udiv32(d, rs1, rs2));
        }
        self.emit(a64.msub32(d, d, rs2, rs1));
        self.storeVreg(instr.rd, d);
    }

    /// Emit unsigned remainder by known constant: r = n - (n/d)*d
    fn tryEmitRemByConstU32(self: *Compiler, instr: RegInstr, divisor: u32) bool {
        // Power of 2: AND with (d-1)
        if (divisor & (divisor - 1) == 0) {
            const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
            const d = destReg(instr.rd);
            self.emitLoadImm(SCRATCH2, divisor - 1);
            self.emit(a64.and32(d, rs1, SCRATCH2));
            self.storeVreg(instr.rd, d);
            return true;
        }
        const m = computeMagicU32(divisor) orelse return false;
        // 1. Compute quotient: q = (n * magic) >> shift
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        self.emitLoadImm(SCRATCH2, m.magic);
        self.emit(a64.umull(SCRATCH, rs1, SCRATCH2));
        self.scratch_vreg = null; // UMULL clobbers SCRATCH
        self.emit(a64.lsr64Imm(SCRATCH, SCRATCH, m.shift));
        // 2. Compute q * d (clobbers quotient, no longer needed)
        self.emitLoadImm(SCRATCH2, divisor);
        self.emit(a64.mul32(SCRATCH, SCRATCH, SCRATCH2));
        // 3. Remainder: r = n - q*d. SCRATCH2 is now free for reloading rs1.
        const rs1b = self.getOrLoad(instr.rs1, SCRATCH2);
        const d = destReg(instr.rd);
        self.emit(a64.sub32(d, rs1b, SCRATCH));
        self.storeVreg(instr.rd, d);
        return true;
    }

    fn emitDiv64(self: *Compiler, sign: Signedness, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        // Check divisor == 0
        self.emit(a64.cmpImm64(rs2, 0));
        self.emitCondError(.eq, 3);
        if (sign == .signed) {
            // Check INT_MIN / -1 → overflow
            // -1 = ~0, use MOVN (1 insn instead of 5)
            self.emit(a64.movn64(SCRATCH, 0, 0));
            self.emit(a64.cmp64(rs2, SCRATCH));
            const skip_idx = self.currentIdx();
            self.emit(a64.bCond(.ne, 0));
            // INT_MIN = 0x8000000000000000 (1 insn instead of 2)
            self.emit(a64.movz64(SCRATCH, 0x8000, 3));
            self.emit(a64.cmp64(rs1, SCRATCH));
            self.emitCondError(.eq, 4);
            const here = self.currentIdx();
            self.code.items[skip_idx] = a64.bCond(.ne, @intCast(@as(i32, @intCast(here)) - @as(i32, @intCast(skip_idx))));
            const rs1b = self.getOrLoad(instr.rs1, SCRATCH);
            const rs2b = self.getOrLoad(instr.rs2(), SCRATCH2);
            self.emit(a64.sdiv64(d, rs1b, rs2b));
        } else {
            self.emit(a64.udiv64(d, rs1, rs2));
        }
        self.storeVreg(instr.rd, d);
    }

    fn emitRem64(self: *Compiler, sign: Signedness, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        self.emit(a64.cmpImm64(rs2, 0));
        self.emitCondError(.eq, 3);
        if (sign == .signed) {
            self.emit(a64.sdiv64(d, rs1, rs2));
        } else {
            self.emit(a64.udiv64(d, rs1, rs2));
        }
        self.emit(a64.msub64(d, d, rs2, rs1));
        self.storeVreg(instr.rd, d);
    }

    /// Emit fuel check at a loop back-edge.
    /// Decrements jit_fuel in the VM struct; if negative, branches to a shared
    /// fuel-exhausted exit (emitted once at end of function by emitErrorStubs).
    fn emitFuelCheck(self: *Compiler) void {
        // Skip when offset is 0 (unit tests without Vm struct)
        if (self.jit_fuel_offset == 0) return;
        // Load vm_ptr → SCRATCH (x8)
        self.emitLoadVmPtr(SCRATCH);
        const fuel_reg: u5 = 0; // x0: safe — not mapped to any vreg
        // Compute address of jit_fuel: ADD SCRATCH, SCRATCH, #offset
        // jit_fuel offset exceeds u16 (Vm struct is >500KB), so use ADD imm.
        const fuel_off = self.jit_fuel_offset;
        // ADD can encode up to 12-bit immediate (4095). If larger, use two-step.
        if (fuel_off <= 4095) {
            self.emit(a64.addImm64(SCRATCH, SCRATCH, @intCast(fuel_off)));
        } else {
            // MOVZ x0, #(fuel_off & 0xFFFF), LSL#0
            self.emit(a64.movz64(fuel_reg, @truncate(fuel_off), 0));
            if (fuel_off > 0xFFFF) {
                self.emit(a64.movk64(fuel_reg, @truncate(fuel_off >> 16), 1));
            }
            self.emit(a64.add64(SCRATCH, SCRATCH, fuel_reg));
        }
        // Now SCRATCH points to &vm.jit_fuel
        self.emit(a64.ldr64(fuel_reg, SCRATCH, 0));
        self.emit(a64.subsImm64(fuel_reg, fuel_reg, 1));
        self.emit(a64.str64(fuel_reg, SCRATCH, 0));
        self.scratch_vreg = null;
        // Branch to shared fuel exit (patched in emitErrorStubs)
        const branch_idx = self.currentIdx();
        self.emit(a64.bCond(.mi, 0)); // placeholder
        self.fuel_check_branches.append(self.alloc, branch_idx) catch {};
    }

    /// Emit conditional error: if condition is true, branch to shared error stub.
    /// Error stubs are emitted at function end by emitErrorStubs().
    fn emitCondError(self: *Compiler, cond: a64.Cond, error_code: u16) void {
        const branch_idx = self.currentIdx();
        self.emit(a64.bCond(cond, 0)); // placeholder: branch TO error if condition met
        self.error_stubs.append(self.alloc, .{
            .branch_idx = branch_idx,
            .error_code = error_code,
            .kind = .b_cond_inverted,
            .cond = cond,
        }) catch {};
    }

    // --- Memory access helpers ---

    const LoadKind = enum { w32, x64, u8, s8_32, s8_64, u16, s16_32, s16_64, s32_64 };
    const StoreKind = enum { w32, x64, b8, h16 };

    fn emitLoadInstr(kind: LoadKind, rd: u5, base: u5, offset: u5) u32 {
        return switch (kind) {
            .w32 => a64.ldr32Reg(rd, base, offset),
            .x64 => a64.ldr64Reg(rd, base, offset),
            .u8 => a64.ldrbReg(rd, base, offset),
            .s8_32 => a64.ldrsbReg(rd, base, offset),
            .s8_64 => a64.ldrsb64Reg(rd, base, offset),
            .u16 => a64.ldrhReg(rd, base, offset),
            .s16_32 => a64.ldrshReg(rd, base, offset),
            .s16_64 => a64.ldrsh64Reg(rd, base, offset),
            .s32_64 => a64.ldrswReg(rd, base, offset),
        };
    }

    fn emitStoreInstr(kind: StoreKind, rt: u5, base: u5, offset: u5) u32 {
        return switch (kind) {
            .w32 => a64.str32Reg(rt, base, offset),
            .x64 => a64.str64Reg(rt, base, offset),
            .b8 => a64.strbReg(rt, base, offset),
            .h16 => a64.strhReg(rt, base, offset),
        };
    }

    /// Check if a memory access with known const address can skip bounds check.
    fn isConstAddrSafe(self: *const Compiler, addr_vreg: u16, offset: u32, access_size: u32) ?u32 {
        if (self.min_memory_bytes == 0) return null;
        if (addr_vreg >= 128) return null;
        const base_addr = self.known_consts[addr_vreg] orelse return null;
        const effective = @as(u64, base_addr) + offset + access_size;
        if (effective <= self.min_memory_bytes) return base_addr + offset;
        return null;
    }

    /// Emit inline memory load with bounds check.
    /// RegInstr encoding: rd=dest, rs1=base_addr, operand=static_offset
    fn emitMemLoad(self: *Compiler, instr: RegInstr, kind: LoadKind, access_size: u32) void {
        // Fast path: const-addr with guaranteed in-bounds → skip bounds check
        if (self.isConstAddrSafe(instr.rs1, instr.operand, access_size)) |eff_addr| {
            self.emitLoadImm(SCRATCH, eff_addr);
            self.emit(emitLoadInstr(kind, SCRATCH, MEM_BASE, SCRATCH));
            self.storeVreg(instr.rd, SCRATCH);
            return;
        }

        // 1. Compute effective address: SCRATCH = zero_extend(addr) + offset
        const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.uxtw(SCRATCH, addr_reg)); // zero-extend 32→64
        self.emitAddOffset(SCRATCH, instr.operand);

        // 2. Bounds check (skipped when guard pages handle OOB via signal handler)
        if (!self.use_guard_pages) {
            if (access_size <= 0xFFF) {
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, @intCast(access_size)));
            } else {
                self.emit(a64.mov64(SCRATCH2, SCRATCH));
                self.emitAddOffset(SCRATCH2, access_size);
            }
            self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
            self.emitCondError(.hi, 6); // OutOfBoundsMemoryAccess
        }

        // 3. Load: dst = mem_base[effective]
        self.emit(emitLoadInstr(kind, SCRATCH, MEM_BASE, SCRATCH));
        self.storeVreg(instr.rd, SCRATCH);
    }

    /// Emit inline memory store with bounds check.
    /// RegInstr encoding: rd=value, rs1=base_addr, operand=static_offset
    fn emitMemStore(self: *Compiler, instr: RegInstr, kind: StoreKind, access_size: u32) void {
        // Fast path: const-addr with guaranteed in-bounds → skip bounds check
        if (self.isConstAddrSafe(instr.rs1, instr.operand, access_size)) |eff_addr| {
            self.emitLoadImm(SCRATCH, eff_addr);
            const val_reg2 = self.getOrLoad(instr.rd, SCRATCH2);
            self.emit(emitStoreInstr(kind, val_reg2, MEM_BASE, SCRATCH));
            self.scratch_vreg = null;
            return;
        }

        // 1. Compute effective address
        const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.uxtw(SCRATCH, addr_reg));
        self.emitAddOffset(SCRATCH, instr.operand);

        // 2. Bounds check (skipped when guard pages handle OOB via signal handler)
        if (!self.use_guard_pages) {
            if (access_size <= 0xFFF) {
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, @intCast(access_size)));
            } else {
                self.emit(a64.mov64(SCRATCH2, SCRATCH));
                self.emitAddOffset(SCRATCH2, access_size);
            }
            self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
            self.emitCondError(.hi, 6);
        }

        // 3. Store: mem_base[effective] = value
        // Value is in rd; need to load it to SCRATCH2 without clobbering SCRATCH (effective addr)
        const val_reg = self.getOrLoad(instr.rd, SCRATCH2);
        self.emit(emitStoreInstr(kind, val_reg, MEM_BASE, SCRATCH));
        // SCRATCH holds effective address, not a vreg value — invalidate cache
        self.scratch_vreg = null;
    }

    /// Emit f64.load directly into FP D-register cache (skips GPR intermediate).
    fn emitFpMemLoad64(self: *Compiler, instr: RegInstr) void {
        // Allocate FP result D-reg FIRST — eviction may clobber SCRATCH.
        const dreg = self.fpAllocResult(instr.rd);

        // Fast path: const-addr with guaranteed in-bounds
        if (self.isConstAddrSafe(instr.rs1, instr.operand, 8)) |eff_addr| {
            self.emitLoadImm(SCRATCH, eff_addr);
            self.emit(a64.ldrFp64Reg(dreg, MEM_BASE, SCRATCH));
            self.fpMarkResultDirty(instr.rd);
            return;
        }

        // 1. Compute effective address
        const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.uxtw(SCRATCH, addr_reg));
        self.emitAddOffset(SCRATCH, instr.operand);

        // 2. Bounds check
        if (!self.use_guard_pages) {
            self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
            self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
            self.emitCondError(.hi, 6);
        }

        // 3. Load directly to D-register (no GPR intermediate)
        self.emit(a64.ldrFp64Reg(dreg, MEM_BASE, SCRATCH));
        self.fpMarkResultDirty(instr.rd);
        self.scratch_vreg = null;
    }

    /// Emit f64.store directly from FP D-register cache (skips GPR intermediate).
    fn emitFpMemStore64(self: *Compiler, instr: RegInstr) void {
        // Load value to D-register FIRST — fpLoadToDreg may clobber SCRATCH.
        const dreg = self.fpLoadToDreg(instr.rd);

        // Fast path: const-addr with guaranteed in-bounds
        if (self.isConstAddrSafe(instr.rs1, instr.operand, 8)) |eff_addr| {
            self.emitLoadImm(SCRATCH, eff_addr);
            self.emit(a64.strFp64Reg(dreg, MEM_BASE, SCRATCH));
            self.scratch_vreg = null;
            return;
        }

        // 1. Compute effective address
        const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.uxtw(SCRATCH, addr_reg));
        self.emitAddOffset(SCRATCH, instr.operand);

        // 2. Bounds check
        if (!self.use_guard_pages) {
            self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
            self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
            self.emitCondError(.hi, 6);
        }

        // 3. Store from D-register directly (no GPR intermediate)
        self.emit(a64.strFp64Reg(dreg, MEM_BASE, SCRATCH));
        self.scratch_vreg = null;
    }

    /// Emit MOV Xd, #imm32 (1-2 instructions).
    fn emitLoadImm(self: *Compiler, rd: u5, value: u32) void {
        self.emit(a64.movz64(rd, @truncate(value), 0));
        if (value > 0xFFFF) {
            self.emit(a64.movk64(rd, @truncate(value >> 16), 1));
        }
    }

    /// Emit ADD Xd, Xd, #offset (handles large offsets).
    fn emitAddOffset(self: *Compiler, rd: u5, offset: u32) void {
        if (offset == 0) return;
        if (offset <= 0xFFF) {
            self.emit(a64.addImm64(rd, rd, @intCast(offset)));
        } else {
            // Load offset into SCRATCH2, then ADD
            self.emit(a64.movz64(SCRATCH2, @truncate(offset), 0));
            if (offset > 0xFFFF) {
                self.emit(a64.movk64(SCRATCH2, @truncate(offset >> 16), 1));
            }
            self.emit(a64.add64(rd, rd, SCRATCH2));
        }
    }

    // --- Global ops emitters ---

    /// global.get: call jitGlobalGet(instance, idx) → u64
    fn emitGlobalGet(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll(); // D-cache → GPR/regs[] before BLR clobbers D-regs
        self.spillCallerSaved();
        // Args: x0 = instance, w1 = global_idx
        self.emitLoadInstPtr(0);
        self.emit(a64.movz32(1, @truncate(instr.operand), 0));
        // Call jitGlobalGet
        const addr_instrs = a64.loadImm64(SCRATCH, self.global_get_addr);
        for (addr_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));
        // Store result to regs[rd] BEFORE reload — x0 may be overwritten by
        // vreg 20 reload when reg_count > 20 (same pattern as emitMemGrow).
        self.emit(a64.str64(0, REGS_PTR, @as(u16, instr.rd) * 8));
        self.reloadCallerSaved();
        // Callee-saved destinations (0-4, 12-13) aren't reloaded by
        // reloadCallerSaved; reload explicitly.
        self.reloadVreg(instr.rd);
        self.scratch_vreg = null;
    }

    /// global.set: call jitGlobalSet(instance, idx, val)
    fn emitGlobalSet(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        self.spillCallerSaved();
        // Read value FIRST — ABI arg setup clobbers x0/x1 which are vregs r20/r21
        // when reg_count > 20. Reading after movz32(1,...) would get the clobbered value.
        const val_reg = self.getOrLoad(instr.rd, SCRATCH);
        self.emit(a64.mov64(2, val_reg));
        // Args: x0 = instance, w1 = global_idx, x2 = value (already set)
        self.emitLoadInstPtr(0);
        self.emit(a64.movz32(1, @truncate(instr.operand), 0));
        // Call jitGlobalSet
        const addr_instrs = a64.loadImm64(SCRATCH, self.global_set_addr);
        for (addr_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));
        self.reloadCallerSaved();
        self.scratch_vreg = null; // BLR clobbered SCRATCH
    }

    // --- Memory ops emitters ---

    /// memory.grow: call jitMemGrow(instance, pages) → old_pages or -1
    /// Then reload mem cache since memory may have grown.
    fn emitMemGrow(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        self.spillCallerSaved();
        // Args: x0 = instance, x1 = pages (from rs1 vreg, truncated to 32-bit)
        self.emitLoadInstPtr(0);
        const pages_reg = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.mov32(1, pages_reg)); // zero-extend to w1
        // Call jitMemGrow
        const addr_instrs = a64.loadImm64(SCRATCH, self.mem_grow_addr);
        for (addr_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));
        // Result in w0 (u32): old_pages or 0xFFFFFFFF
        // Store result to regs[rd] in memory immediately (before x0 is clobbered)
        self.emit(a64.str64(0, REGS_PTR, @as(u16, instr.rd) * 8));
        // Reload memory cache FIRST (BLR clobbers x0-x15)
        if (self.has_memory) {
            self.emitLoadMemCache();
        }
        // Reload caller-saved regs AFTER all BLRs (regs[rd] has result from str above)
        self.reloadCallerSaved();
        if (instr.rd <= 4) self.reloadVreg(instr.rd);
        self.scratch_vreg = null; // BLR clobbered SCRATCH
    }

    /// memory.fill: call jitMemFill(instance, dst, val, n)
    fn emitMemFill(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        self.spillCallerSaved();
        // Args: x0 = instance, w1 = dst (rd), w2 = val (rs1), w3 = n (rs2)
        self.emitLoadInstPtr(0);
        const dst_reg = self.getOrLoad(instr.rd, SCRATCH);
        self.emit(a64.mov32(1, dst_reg));
        const val_reg = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.mov32(2, val_reg));
        const n_reg = self.getOrLoad(instr.rs2(), SCRATCH);
        self.emit(a64.mov32(3, n_reg));
        // Call jitMemFill
        const addr_instrs = a64.loadImm64(SCRATCH, self.mem_fill_addr);
        for (addr_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));
        // Check error (w0 != 0 → OOB)
        self.emit(a64.cmpImm32(0, 0));
        self.emitCondError(.ne, 6); // OutOfBoundsMemoryAccess
        self.reloadCallerSaved();
        self.scratch_vreg = null; // BLR clobbered SCRATCH
    }

    /// memory.copy: call jitMemCopy(instance, dst, src, n)
    fn emitMemCopy(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        self.spillCallerSaved();
        // Args: x0 = instance, w1 = dst (rd), w2 = src (rs1), w3 = n (rs2)
        self.emitLoadInstPtr(0);
        const dst_reg = self.getOrLoad(instr.rd, SCRATCH);
        self.emit(a64.mov32(1, dst_reg));
        const src_reg = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.mov32(2, src_reg));
        const n_reg = self.getOrLoad(instr.rs2(), SCRATCH);
        self.emit(a64.mov32(3, n_reg));
        // Call jitMemCopy
        const addr_instrs = a64.loadImm64(SCRATCH, self.mem_copy_addr);
        for (addr_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));
        // Check error
        self.emit(a64.cmpImm32(0, 0));
        self.emitCondError(.ne, 6);
        self.reloadCallerSaved();
        self.scratch_vreg = null; // BLR clobbered SCRATCH
    }

    /// i32.popcnt: count set bits in a 32-bit value
    /// Software implementation: Hamming weight via bit manipulation
    fn emitPopcnt32(self: *Compiler, instr: RegInstr) void {
        // Use FMOV + CNT + ADDV on ARM64 NEON
        // FMOV S0, Wn; CNT V0.8B, V0.8B; ADDV B0, V0.8B; FMOV Wd, S0
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, src)); // FMOV S0, Wn
        self.emit(a64.cntV8b(FP_SCRATCH0, FP_SCRATCH0)); // CNT V0.8B, V0.8B
        self.emit(a64.addvB(FP_SCRATCH0, FP_SCRATCH0)); // ADDV B0, V0.8B
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0)); // FMOV Wd, S0
        self.storeVreg(instr.rd, d);
    }

    /// i64.popcnt: count set bits in a 64-bit value
    fn emitPopcnt64(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToFp64(FP_SCRATCH0, src)); // FMOV D0, Xn
        self.emit(a64.cntV8b(FP_SCRATCH0, FP_SCRATCH0)); // CNT V0.8B, V0.8B
        self.emit(a64.addvB(FP_SCRATCH0, FP_SCRATCH0)); // ADDV B0, V0.8B
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0)); // FMOV Wd, S0 (result fits in 32 bits)
        self.storeVreg(instr.rd, d);
    }

    fn emitCall(self: *Compiler, rd: u16, func_idx: u32, n_args: u16, data: RegInstr, data2: ?RegInstr, ir: []const RegInstr, call_pc: u32) void {
        // Self-call: use lightweight inline path with call_depth guard
        if (func_idx == self.self_func_idx) {
            self.emitInlineSelfCall(rd, data, data2, ir, call_pc);
            return;
        }

        // 1. Spill caller-saved regs + arg vregs needed by trampoline
        self.fpCacheEvictAll(); // Write back D-cache before BLR clobbers D-regs
        self.spillCallerSavedLive(ir, call_pc);
        // Trampoline reads args from regs[] — spill ALL arg vregs unconditionally.
        // spillCallerSavedLive only spills live-after-call vregs, but call args may be
        // dead after the call yet still needed by the trampoline to pass to the callee.
        if (n_args > 0) self.spillVreg(data.rd);
        if (n_args > 1) self.spillVreg(data.rs1);
        if (n_args > 2) self.spillVreg(data.rs2_field);
        if (n_args > 3) self.spillVreg(@truncate(data.operand));
        if (n_args > 4) {
            if (data2) |d2| {
                if (n_args > 4) self.spillVreg(d2.rd);
                if (n_args > 5) self.spillVreg(d2.rs1);
                if (n_args > 6) self.spillVreg(d2.rs2_field);
                if (n_args > 7) self.spillVreg(@truncate(d2.operand));
            }
        }

        // 2. Set up trampoline args (C calling convention):
        //    x0 = vm, x1 = instance, x2 = regs, w3 = func_idx,
        //    w4 = rd (result reg), x5 = data_word, x6 = data2_word
        self.emitLoadVmPtr(0);
        self.emitLoadInstPtr(1);
        self.emit(a64.mov64(2, REGS_PTR));
        // Load func_idx into w3
        if (func_idx <= 0xFFFF) {
            self.emit(a64.movz32(3, @truncate(func_idx), 0));
        } else {
            self.emit(a64.movz32(3, @truncate(func_idx), 0));
            self.emit(a64.movk64(3, @truncate(func_idx >> 16), 1));
        }
        // Load rd into w4
        self.emit(a64.movz32(4, rd, 0));
        // Pack data word as u64 into x5: [rd:16|rs1:16|rs2:16|arg3:16]
        const data_u64: u64 = packDataWord(data);
        const d_instrs = a64.loadImm64(5, data_u64);
        for (d_instrs) |inst| self.emit(inst);
        // data2 into x6 (0 if no second data word)
        if (data2) |d2| {
            const d2_u64: u64 = packDataWord(d2);
            const d2_instrs = a64.loadImm64(6, d2_u64);
            for (d2_instrs) |inst| self.emit(inst);
        } else {
            self.emit(a64.movz64(6, 0, 0));
        }

        // 3. Flush depth counter before trampoline (trampoline reads vm.call_depth)
        if (self.depth_reg_cached) self.emitDepthFlush();

        // 3a. Load trampoline address and call
        const t_instrs = a64.loadImm64(SCRATCH, self.trampoline_addr);
        for (t_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));

        // 4. Check error (x0 != 0 → error) — branch to shared error epilogue
        const error_branch = self.currentIdx();
        self.emit(a64.cbnz64(0, 0)); // placeholder — patched by emitErrorStubs
        self.error_stubs.append(self.alloc, .{
            .branch_idx = error_branch,
            .error_code = 0, // 0 = x0 already has error code from trampoline
            .kind = .cbnz64,
            .cond = .eq, // unused
        }) catch {};

        // 5. Reload depth counter (trampoline may have changed call_depth)
        if (self.depth_reg_cached) self.emitDepthReload();

        // 5a. Reload memory cache FIRST (BLR clobbers x0-x15)
        //     Trampoline already wrote result to regs[rd], so it survives this BLR.
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // 6. Reload caller-saved regs AFTER all BLRs, then result register
        self.reloadCallerSavedLive();
        self.reloadVreg(rd);
    }

    /// Emit call_indirect: table lookup + type check + function call via trampoline.
    /// instr: rd=result_reg, rs1=elem_idx_reg, operand=type_idx|(table_idx<<24)
    fn emitCallIndirect(self: *Compiler, instr: RegInstr, data: RegInstr, data2: ?RegInstr) void {
        // 1. Spill caller-saved regs + arg vregs
        self.fpCacheEvictAll(); // Write back D-cache before BLR clobbers D-regs
        self.spillCallerSaved();
        self.spillVregIfCalleeSaved(data.rd);
        self.spillVregIfCalleeSaved(data.rs1);
        self.spillVregIfCalleeSaved(data.rs2_field);
        self.spillVregIfCalleeSaved(@truncate(data.operand));
        if (data2) |d2| {
            self.spillVregIfCalleeSaved(d2.rd);
            self.spillVregIfCalleeSaved(d2.rs1);
            self.spillVregIfCalleeSaved(d2.rs2_field);
            self.spillVregIfCalleeSaved(@truncate(d2.operand));
        }
        // Also spill the elem_idx vreg
        self.spillVregIfCalleeSaved(instr.rs1);

        // 2. Set up trampoline args (C calling convention, 8 args):
        //    x0=vm, x1=instance, x2=regs, w3=type_idx_table_idx,
        //    w4=result_reg, x5=data_word, x6=data2_word, w7=elem_idx
        self.emitLoadVmPtr(0);
        self.emitLoadInstPtr(1);
        self.emit(a64.mov64(2, REGS_PTR));
        // w3 = type_idx | (table_idx << 24) from instr.operand
        const type_idx_table_idx = instr.operand;
        if (type_idx_table_idx <= 0xFFFF) {
            self.emit(a64.movz32(3, @truncate(type_idx_table_idx), 0));
        } else {
            self.emit(a64.movz32(3, @truncate(type_idx_table_idx), 0));
            self.emit(a64.movk64(3, @truncate(type_idx_table_idx >> 16), 1));
        }
        // w4 = result_reg
        self.emit(a64.movz32(4, instr.rd, 0));
        // x5 = data word (packed register indices)
        const data_u64: u64 = packDataWord(data);
        const d_instrs = a64.loadImm64(5, data_u64);
        for (d_instrs) |inst| self.emit(inst);
        // x6 = data2 word
        if (data2) |d2| {
            const d2_u64: u64 = packDataWord(d2);
            const d2_instrs = a64.loadImm64(6, d2_u64);
            for (d2_instrs) |inst| self.emit(inst);
        } else {
            self.emit(a64.movz64(6, 0, 0));
        }
        // w7 = elem_idx (load from regs[instr.rs1])
        self.emit(a64.ldr64(7, REGS_PTR, @as(u12, @intCast(instr.rs1)) * 8));
        // Truncate to 32 bits (elem_idx is u32)

        // 3. Flush depth counter before trampoline
        if (self.depth_reg_cached) self.emitDepthFlush();

        // 3a. Load call_indirect trampoline address and call
        const t_instrs = a64.loadImm64(SCRATCH, self.call_indirect_addr);
        for (t_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));

        // 4. Check error
        const error_branch = self.currentIdx();
        self.emit(a64.cbnz64(0, 0));
        self.error_stubs.append(self.alloc, .{
            .branch_idx = error_branch,
            .error_code = 0,
            .kind = .cbnz64,
            .cond = .eq,
        }) catch {};

        // 5. Reload depth counter
        if (self.depth_reg_cached) self.emitDepthReload();

        // 5a. Reload memory cache FIRST (BLR clobbers x0-x15)
        //     Trampoline already wrote result to regs[rd], so it survives this BLR.
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // 6. Reload caller-saved regs AFTER all BLRs, then result register
        self.reloadCallerSaved();
        self.reloadVreg(instr.rd);
    }

    /// Emit GC struct.new via BLR to runtime helper.
    /// Similar to emitCall: spill, set up trampoline args, BLR, error check, reload.
    fn emitGcStructNew(self: *Compiler, rd: u16, type_idx: u32, n_fields: u16, data: RegInstr, data2: ?RegInstr, ir: []const RegInstr, call_pc: u32) void {
        // 1. Spill caller-saved regs + field vregs
        self.fpCacheEvictAll();
        self.spillCallerSavedLive(ir, call_pc);
        // Spill all field vregs (trampoline reads from regs[])
        if (n_fields > 0) self.spillVreg(data.rd);
        if (n_fields > 1) self.spillVreg(data.rs1);
        if (n_fields > 2) self.spillVreg(data.rs2_field);
        if (n_fields > 3) self.spillVreg(@truncate(data.operand));
        if (n_fields > 4) {
            if (data2) |d2| {
                if (n_fields > 4) self.spillVreg(d2.rd);
                if (n_fields > 5) self.spillVreg(d2.rs1);
                if (n_fields > 6) self.spillVreg(d2.rs2_field);
                if (n_fields > 7) self.spillVreg(@truncate(d2.operand));
            }
        }

        // 2. Set up GC trampoline args (C ABI):
        //    x0 = instance, x1 = regs, w2 = sub_op(0x00), w3 = type_idx,
        //    w4 = rd, w5 = n_fields, w6 = 0 (field_idx unused), x7 = data_raw
        self.emitLoadInstPtr(0);
        self.emit(a64.mov64(1, REGS_PTR));
        self.emit(a64.movz32(2, 0x00, 0)); // sub_op = struct.new
        if (type_idx <= 0xFFFF) {
            self.emit(a64.movz32(3, @truncate(type_idx), 0));
        } else {
            self.emit(a64.movz32(3, @truncate(type_idx), 0));
            self.emit(a64.movk64(3, @truncate(type_idx >> 16), 1));
        }
        self.emit(a64.movz32(4, rd, 0));
        self.emit(a64.movz32(5, n_fields, 0));
        self.emit(a64.movz32(6, 0, 0)); // field_idx unused
        const data_u64 = packDataWord(data);
        const d_instrs = a64.loadImm64(7, data_u64);
        for (d_instrs) |inst| self.emit(inst);

        // 3. BLR to GC trampoline
        const t_instrs = a64.loadImm64(SCRATCH, self.gc_trampoline_addr);
        for (t_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));

        // 4. Error check
        const error_branch = self.currentIdx();
        self.emit(a64.cbnz64(0, 0));
        self.error_stubs.append(self.alloc, .{
            .branch_idx = error_branch,
            .error_code = 0,
            .kind = .cbnz64,
            .cond = .eq,
        }) catch {};

        // 5. Reload memory + caller-saved regs + result
        if (self.has_memory) self.emitLoadMemCache();
        self.reloadCallerSavedLive();
        self.reloadVreg(rd);
    }

    /// Emit simple GC op (struct.get/set/new_default) via BLR to runtime helper.
    fn emitGcSimple(self: *Compiler, instr: RegInstr, ir: []const RegInstr, call_pc: u32) void {
        const sub_op: u16 = instr.op - predecode_mod.GC_BASE;

        // 1. Spill caller-saved + operand vregs
        self.fpCacheEvictAll();
        self.spillCallerSavedLive(ir, call_pc);
        // Spill operand vregs so trampoline can read them
        if (sub_op >= 0x02 and sub_op <= 0x04) {
            // struct.get: rs1 = ref_reg
            self.spillVreg(instr.rs1);
        } else if (sub_op == 0x05) {
            // struct.set: rd = ref_reg, rs1 = val_reg
            self.spillVreg(instr.rd);
            self.spillVreg(instr.rs1);
        }

        // 2. Set up GC trampoline args:
        //    x0 = instance, x1 = regs, w2 = sub_op, w3 = type_idx,
        //    w4 = rd, w5 = rs1, w6 = field_idx (rs2_field), x7 = 0
        self.emitLoadInstPtr(0);
        self.emit(a64.mov64(1, REGS_PTR));
        self.emit(a64.movz32(2, sub_op, 0));
        const type_idx = instr.operand;
        if (type_idx <= 0xFFFF) {
            self.emit(a64.movz32(3, @truncate(type_idx), 0));
        } else {
            self.emit(a64.movz32(3, @truncate(type_idx), 0));
            self.emit(a64.movk64(3, @truncate(type_idx >> 16), 1));
        }
        self.emit(a64.movz32(4, instr.rd, 0));
        self.emit(a64.movz32(5, instr.rs1, 0));
        self.emit(a64.movz32(6, instr.rs2_field, 0)); // field_idx
        self.emit(a64.movz64(7, 0, 0)); // data_raw unused

        // 3. BLR to GC trampoline
        const t_instrs = a64.loadImm64(SCRATCH, self.gc_trampoline_addr);
        for (t_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));

        // 4. Error check
        const error_branch = self.currentIdx();
        self.emit(a64.cbnz64(0, 0));
        self.error_stubs.append(self.alloc, .{
            .branch_idx = error_branch,
            .error_code = 0,
            .kind = .cbnz64,
            .cond = .eq,
        }) catch {};

        // 5. Reload
        if (self.has_memory) self.emitLoadMemCache();
        self.reloadCallerSavedLive();
        // Reload result register (for get ops and struct.new_default)
        if (sub_op <= 0x04) self.reloadVreg(instr.rd);
    }

    // --- SIMD v128 helpers ---

    /// NEON scratch registers for SIMD. Using Q0/Q1 (caller-saved, volatile).
    const SIMD_SCRATCH0: u5 = 0; // V0/Q0
    const SIMD_SCRATCH1: u5 = 1; // V1/Q1

    /// Load v128 from regs[vreg] + simd_hi[vreg] into NEON Q register.
    /// Uses SCRATCH (x8) as temp. 3 instructions.
    fn emitLoadV128(self: *Compiler, qd: u5, vreg: u16) void {
        const vreg_offset: u16 = vreg * 8;
        // Step 1: LDR Dd, [REGS_PTR, #vreg*8] — load lower 64 bits into D register
        //         (upper 64 bits of Qd are zeroed by LDR D)
        self.emit(a64.ldrFp64(qd, REGS_PTR, vreg_offset));
        // Step 2: LDR X8, [VM_PTR, #simd_hi_offset + vreg*8] — load upper 64 bits to GP
        self.emitLoadVmPtr(SCRATCH);
        const hi_offset = self.simd_hi_offset + @as(u32, vreg) * 8;
        if (hi_offset <= 32760) {
            self.emit(a64.ldr64(SCRATCH, SCRATCH, @intCast(hi_offset)));
        } else {
            // Large offset: use SCRATCH2 for address
            const hi_instrs = a64.loadImm64(SCRATCH2, hi_offset);
            for (hi_instrs) |inst| self.emit(inst);
            self.emit(a64.add64(SCRATCH, SCRATCH, SCRATCH2));
            self.emit(a64.ldr64(SCRATCH, SCRATCH, 0));
        }
        // Step 3: INS Vd.D[1], X8 — insert upper half
        self.emit(a64.insVdD1(qd, SCRATCH));
    }

    /// Store NEON Q register to regs[vreg] + simd_hi[vreg].
    /// Uses SCRATCH (x8) as temp. 3 instructions.
    fn emitStoreV128(self: *Compiler, qs: u5, vreg: u16) void {
        const vreg_offset: u16 = vreg * 8;
        // Step 1: STR Ds, [REGS_PTR, #vreg*8] — store lower 64 bits from D register
        self.emit(a64.strFp64(qs, REGS_PTR, vreg_offset));
        // Step 2: UMOV X8, Vs.D[1] — extract upper 64 bits to GP
        self.emit(a64.umovXdD1(SCRATCH, qs));
        // Step 3: STR X8, [VM_PTR, #simd_hi_offset + vreg*8] — store upper 64 bits
        self.emitLoadVmPtr(SCRATCH2);
        const hi_offset = self.simd_hi_offset + @as(u32, vreg) * 8;
        if (hi_offset <= 32760) {
            self.emit(a64.str64(SCRATCH, SCRATCH2, @intCast(hi_offset)));
        } else {
            const hi_instrs = a64.loadImm64(17, hi_offset); // use x17 as temp
            for (hi_instrs) |inst| self.emit(inst);
            self.emit(a64.add64(SCRATCH2, SCRATCH2, 17));
            self.emit(a64.str64(SCRATCH, SCRATCH2, 0));
        }
    }

    /// Emit native NEON instruction for a binary v128 op.
    /// Pattern: load rs1 → Q0, load rs2 → Q1, op Q0 ← Q0,Q1, store Q0 → rd.
    fn emitSimdBinaryNeon(self: *Compiler, instr: RegInstr, neon_insn: u32) void {
        self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
        self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
        // Replace Vd/Vn/Vm fields in neon_insn with SCRATCH0/SCRATCH1
        const insn = (neon_insn & 0xFFE0FC00) | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0;
        self.emit(insn);
        self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
    }

    /// Emit native NEON instruction for a unary v128 op.
    fn emitSimdUnaryNeon(self: *Compiler, instr: RegInstr, neon_insn: u32) void {
        self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
        const insn = (neon_insn & 0xFFFFFC00) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0;
        self.emit(insn);
        self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
    }

    /// Try to emit native NEON for a SIMD opcode. Returns true if handled.
    fn emitSimdNative(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        const sub: u32 = instr.op - predecode_mod.SIMD_BASE;

        // Peek at trailing NOP for extra metadata (lane index etc.)
        var extra: u16 = 0;
        const has_nop = pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP;
        if (has_nop) extra = ir[pc.*].rd;

        const handled = self.emitSimdNativeInner(instr, sub, extra);
        if (handled and has_nop) pc.* += 1; // consume NOP
        return handled;
    }

    fn emitSimdNativeInner(self: *Compiler, instr: RegInstr, sub: u32, extra: u16) bool {
        switch (sub) {
            // --- f32x4 arithmetic ---
            0xE4 => { self.emitSimdBinaryNeon(instr, a64.faddV4s(0, 0, 0)); return true; }, // f32x4.add
            0xE5 => { self.emitSimdBinaryNeon(instr, a64.fsubV4s(0, 0, 0)); return true; }, // f32x4.sub
            0xE6 => { self.emitSimdBinaryNeon(instr, a64.fmulV4s(0, 0, 0)); return true; }, // f32x4.mul
            0xE7 => { self.emitSimdBinaryNeon(instr, a64.fdivV4s(0, 0, 0)); return true; }, // f32x4.div
            // --- f64x2 arithmetic ---
            0xF0 => { self.emitSimdBinaryNeon(instr, a64.faddV2d(0, 0, 0)); return true; }, // f64x2.add
            0xF2 => { self.emitSimdBinaryNeon(instr, a64.fmulV2d(0, 0, 0)); return true; }, // f64x2.mul
            // --- i32x4 arithmetic ---
            0xAE => { self.emitSimdBinaryNeon(instr, a64.addV4s(0, 0, 0)); return true; }, // i32x4.add
            0xB1 => { self.emitSimdBinaryNeon(instr, a64.subV4s(0, 0, 0)); return true; }, // i32x4.sub
            // --- v128 bitwise ---
            0x4E => { self.emitSimdBinaryNeon(instr, a64.andV16b(0, 0, 0)); return true; }, // v128.and
            0x4F => { // v128.andnot — ARM64: BIC Vd, Vn, Vm (= Vn AND NOT Vm)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                // BIC Vd.16B, Vn.16B, Vm.16B = 0x4E601C00
                self.emit(0x4E601C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x50 => { self.emitSimdBinaryNeon(instr, a64.orrV16b(0, 0, 0)); return true; }, // v128.or
            0x51 => { self.emitSimdBinaryNeon(instr, a64.eorV16b(0, 0, 0)); return true; }, // v128.xor
            0x4D => { self.emitSimdUnaryNeon(instr, a64.notV16b(0, 0)); return true; }, // v128.not

            // --- splat ---
            0x0F => { // i8x16.splat
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                // DUP V0.16B, Wn = 0x4E010C00 | (Rn << 5) | Vd
                self.emit(0x4E010C00 | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x10 => { // i16x8.splat
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                // DUP V0.8H, Wn = 0x4E020C00
                self.emit(0x4E020C00 | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x11 => { // i32x4.splat
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                // DUP V0.4S, Wn = 0x4E040C00
                self.emit(0x4E040C00 | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x12 => { // i64x2.splat
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                // DUP V0.2D, Xn = 0x4E080C00
                self.emit(0x4E080C00 | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x13 => { // f32x4.splat — same as i32x4.splat (bit pattern)
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(0x4E040C00 | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x14 => { // f64x2.splat — same as i64x2.splat
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(0x4E080C00 | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- extract_lane ---
            0x15 => { // i8x16.extract_lane_s — SMOV Wd, Vn.B[lane]
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = destReg(instr.rd);
                self.emit(0x0E012C00 | (@as(u32, @as(u4, @truncate(extra))) << 17) | (@as(u32, SIMD_SCRATCH0) << 5) | d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x16 => { // i8x16.extract_lane_u — UMOV Wd, Vn.B[lane]
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = destReg(instr.rd);
                self.emit(0x0E013C00 | (@as(u32, @as(u4, @truncate(extra))) << 17) | (@as(u32, SIMD_SCRATCH0) << 5) | d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x18 => { // i16x8.extract_lane_s — SMOV Wd, Vn.H[lane]
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = destReg(instr.rd);
                self.emit(0x0E022C00 | (@as(u32, @as(u3, @truncate(extra))) << 19) | (@as(u32, SIMD_SCRATCH0) << 5) | d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x19 => { // i16x8.extract_lane_u — UMOV Wd, Vn.H[lane]
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = destReg(instr.rd);
                self.emit(0x0E023C00 | (@as(u32, @as(u3, @truncate(extra))) << 19) | (@as(u32, SIMD_SCRATCH0) << 5) | d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x1B, 0x1F => { // i32x4/f32x4.extract_lane — UMOV Wd, Vn.S[lane]
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = destReg(instr.rd);
                self.emit(0x0E043C00 | (@as(u32, @as(u2, @truncate(extra))) << 21) | (@as(u32, SIMD_SCRATCH0) << 5) | d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x1D, 0x21 => { // i64x2/f64x2.extract_lane — UMOV Xd, Vn.D[lane]
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = destReg(instr.rd);
                // UMOV Xd, Vn.D[lane] (Q=1) = 0x4E083C00
                self.emit(0x4E083C00 | (@as(u32, @as(u1, @truncate(extra))) << 20) | (@as(u32, SIMD_SCRATCH0) << 5) | d);
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- replace_lane ---
            0x17 => { // i8x16.replace_lane — INS Vd.B[lane], Wn
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                const imm5 = (@as(u32, @as(u4, @truncate(extra))) << 1) | 1;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x1A => { // i16x8.replace_lane — INS Vd.H[lane], Wn
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                const imm5 = (@as(u32, @as(u3, @truncate(extra))) << 2) | 2;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x1C, 0x20 => { // i32x4/f32x4.replace_lane — INS Vd.S[lane], Wn
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                const imm5 = (@as(u32, @as(u2, @truncate(extra))) << 3) | 4;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x1E, 0x22 => { // i64x2/f64x2.replace_lane — INS Vd.D[lane], Xn
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                const imm5 = (@as(u32, @as(u1, @truncate(extra))) << 4) | 8;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, src) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i8x16 comparisons ---
            0x23 => { self.emitSimdBinaryNeon(instr, 0x6E208C00); return true; }, // i8x16.eq — CMEQ .16B
            0x24 => { // i8x16.ne — CMEQ + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x6E208C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emit(a64.notV16b(SIMD_SCRATCH0, SIMD_SCRATCH0));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x27 => { self.emitSimdBinaryNeon(instr, 0x4E203400); return true; }, // i8x16.gt_s — CMGT .16B
            0x28 => { self.emitSimdBinaryNeon(instr, 0x6E203400); return true; }, // i8x16.gt_u — CMHI .16B
            0x2B => { self.emitSimdBinaryNeon(instr, 0x4E203C00); return true; }, // i8x16.ge_s — CMGE .16B
            0x2C => { self.emitSimdBinaryNeon(instr, 0x6E203C00); return true; }, // i8x16.ge_u — CMHS .16B
            0x25 => { // i8x16.lt_s — CMGT swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x4E203400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x26 => { // i8x16.lt_u — CMHI swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6E203400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x29 => { // i8x16.le_s — CMGE swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x4E203C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x2A => { // i8x16.le_u — CMHS swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6E203C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i16x8 comparisons ---
            0x2D => { self.emitSimdBinaryNeon(instr, 0x6E608C00); return true; }, // i16x8.eq — CMEQ .8H
            0x2E => { // i16x8.ne — CMEQ + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x6E608C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emit(a64.notV16b(SIMD_SCRATCH0, SIMD_SCRATCH0));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x31 => { self.emitSimdBinaryNeon(instr, 0x4E603400); return true; }, // i16x8.gt_s — CMGT .8H
            0x32 => { self.emitSimdBinaryNeon(instr, 0x6E603400); return true; }, // i16x8.gt_u — CMHI .8H
            0x35 => { self.emitSimdBinaryNeon(instr, 0x4E603C00); return true; }, // i16x8.ge_s — CMGE .8H
            0x36 => { self.emitSimdBinaryNeon(instr, 0x6E603C00); return true; }, // i16x8.ge_u — CMHS .8H
            0x2F => { // i16x8.lt_s — CMGT swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x4E603400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x30 => { // i16x8.lt_u — CMHI swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6E603400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x33 => { // i16x8.le_s — CMGE swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x4E603C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x34 => { // i16x8.le_u — CMHS swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6E603C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i64x2.mul (5-instr sequence: REV64+MUL+ADDP+SHL+UMLAL) ---
            0xD5 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // a → V0
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // b → V1
                const V2: u5 = 2;
                // REV64 V2.4S, V1.4S — swap 32-bit halves within each 64-bit lane
                self.emit(0x4EA00800 | (@as(u32, SIMD_SCRATCH1) << 5) | V2);
                // MUL V2.4S, V2.4S, V0.4S — cross products [a_lo*b_hi, a_hi*b_lo]
                self.emit(0x4EA09C00 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, V2) << 5) | V2);
                // ADDP V2.4S, V2.4S, V2.4S — pairwise: cross_sum per lane in S[0],S[1]
                self.emit(0x4EA0BC00 | (@as(u32, V2) << 16) | (@as(u32, V2) << 5) | V2);
                // SHL V2.2D, V2.2D, #32 — shift cross terms left 32
                self.emit(0x4F605400 | (@as(u32, V2) << 5) | V2);
                // UMLAL V2.2D, V0.2S, V1.2S — accumulate a_lo * b_lo (widening)
                self.emit(0x2EA08000 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | V2);
                self.emitStoreV128(V2, instr.rd);
                return true;
            },

            // --- i64x2 extmul ---
            0xDC => { self.emitSimdBinaryNeon(instr, 0x0EA0C000); return true; }, // i64x2.extmul_low_i32x4_s — SMULL .2D
            0xDD => { self.emitSimdBinaryNeon(instr, 0x4EA0C000); return true; }, // i64x2.extmul_high_i32x4_s — SMULL2 .2D
            0xDE => { self.emitSimdBinaryNeon(instr, 0x2EA0C000); return true; }, // i64x2.extmul_low_i32x4_u — UMULL .2D
            0xDF => { self.emitSimdBinaryNeon(instr, 0x6EA0C000); return true; }, // i64x2.extmul_high_i32x4_u — UMULL2 .2D

            // --- i64x2 comparisons (signed only, no unsigned in wasm) ---
            0xD6 => { self.emitSimdBinaryNeon(instr, 0x6EE08C00); return true; }, // i64x2.eq — CMEQ .2D
            0xD7 => { // i64x2.ne — CMEQ + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x6EE08C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emit(a64.notV16b(SIMD_SCRATCH0, SIMD_SCRATCH0));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xD9 => { self.emitSimdBinaryNeon(instr, 0x4EE03400); return true; }, // i64x2.gt_s — CMGT .2D
            0xDB => { self.emitSimdBinaryNeon(instr, 0x4EE03C00); return true; }, // i64x2.ge_s — CMGE .2D
            0xD8 => { // i64x2.lt_s — CMGT swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x4EE03400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xDA => { // i64x2.le_s — CMGE swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x4EE03C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- bitmask ---
            0x64 => { // i8x16.bitmask — SSHR + USHR/SLI ladder + extract
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // SSHR V0.16B, V0.16B, #7 — sign bits → 0xFF/0x00
                self.emit(0x4F090400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // Pack 2 bits per 16-bit lane
                self.emit(0x6F190400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH1); // USHR V1.8H, V0.8H, #7
                self.emit(0x6F115400 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SLI V0.8H, V1.8H, #1
                // Pack 4 bits per 32-bit lane
                self.emit(0x6F320400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH1); // USHR V1.4S, V0.4S, #14
                self.emit(0x6F225400 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SLI V0.4S, V1.4S, #2
                // Pack 8 bits per 64-bit lane
                self.emit(0x6F640400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH1); // USHR V1.2D, V0.2D, #28
                self.emit(0x6F445400 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SLI V0.2D, V1.2D, #4
                // Extract and combine: UMOV lo + hi, ORR
                const d = destReg(instr.rd);
                self.emit(0x0E013C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.B[0]
                self.emit(0x0E013C00 | (8 << 17) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH); // UMOV W_SCRATCH, V0.B[8]
                // ORR Wd, Wd, W_SCRATCH, LSL #8
                self.emit(0x2A000000 | (@as(u32, SCRATCH) << 16) | (8 << 10) | (@as(u32, d) << 5) | d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x84 => { // i16x8.bitmask
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x4F110400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // SSHR V0.8H, #15
                self.emit(0x6F310400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH1); // USHR V1.4S, V0.4S, #15
                self.emit(0x6F215400 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SLI V0.4S, V1.4S, #1
                self.emit(0x6F620400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH1); // USHR V1.2D, V0.2D, #30
                self.emit(0x6F425400 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SLI V0.2D, V1.2D, #2
                const d = destReg(instr.rd);
                self.emit(0x0E013C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.B[0]
                self.emit(0x0E013C00 | (8 << 17) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH); // UMOV W, V0.B[8]
                self.emit(0x2A000000 | (@as(u32, SCRATCH) << 16) | (4 << 10) | (@as(u32, d) << 5) | d); // ORR Wd, Wd, W, LSL #4
                self.storeVreg(instr.rd, d);
                return true;
            },
            0xA4 => { // i32x4.bitmask
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x4F210400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // SSHR V0.4S, #31
                self.emit(0x6F610400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH1); // USHR V1.2D, V0.2D, #31
                self.emit(0x6F415400 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SLI V0.2D, V1.2D, #1
                const d = destReg(instr.rd);
                self.emit(0x0E013C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.B[0]
                self.emit(0x0E013C00 | (8 << 17) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH); // UMOV W, V0.B[8]
                self.emit(0x2A000000 | (@as(u32, SCRATCH) << 16) | (2 << 10) | (@as(u32, d) << 5) | d); // ORR Wd, Wd, W, LSL #2
                self.storeVreg(instr.rd, d);
                return true;
            },
            0xC4 => { // i64x2.bitmask
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x6F410400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // USHR V0.2D, #63
                const d = destReg(instr.rd);
                self.emit(0x0E043C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.S[0]
                // V0.S[2] = low 32 bits of V0.D[1] (lane index 2 for .S)
                self.emit(0x0E043C00 | (@as(u32, 2) << 21) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH); // UMOV W, V0.S[2]
                self.emit(0x2A000000 | (@as(u32, SCRATCH) << 16) | (1 << 10) | (@as(u32, d) << 5) | d); // ORR Wd, Wd, W, LSL #1
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- v128.any_true ---
            0x53 => { // v128.any_true — UMAXV + check
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // UMAXV Bd, V0.16B = 0x6E30A800
                self.emit(0x6E30A800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // UMOV Wd, V0.B[0] = 0x0E013C00
                const d = destReg(instr.rd);
                self.emit(0x0E013C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d);
                // CMP Wd, #0 → CSET Wd, ne
                self.emit(a64.cmpImm32(d, 0));
                self.emit(a64.cset32(d, .ne));
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- all_true ---
            0x63 => { // i8x16.all_true — UMINV + check
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // UMINV Bd, V0.16B = 0x6E31A800
                self.emit(0x6E31A800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                const d = destReg(instr.rd);
                self.emit(0x0E013C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.B[0]
                self.emit(a64.cmpImm32(d, 0));
                self.emit(a64.cset32(d, .ne));
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x83 => { // i16x8.all_true — UMINV + check
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // UMINV Hd, V0.8H = 0x6E71A800
                self.emit(0x6E71A800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                const d = destReg(instr.rd);
                self.emit(0x0E023C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.H[0]
                self.emit(a64.cmpImm32(d, 0));
                self.emit(a64.cset32(d, .ne));
                self.storeVreg(instr.rd, d);
                return true;
            },
            0xA3 => { // i32x4.all_true — UMINV + check
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // UMINV Sd, V0.4S = 0x6EB1A800
                self.emit(0x6EB1A800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                const d = destReg(instr.rd);
                self.emit(0x0E043C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.S[0]
                self.emit(a64.cmpImm32(d, 0));
                self.emit(a64.cset32(d, .ne));
                self.storeVreg(instr.rd, d);
                return true;
            },
            0xC3 => { // i64x2.all_true — CMEQ zero + UMAXV + check
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // CMEQ V0.2D, V0.2D, #0 = 0x4EE09800 (marks zero lanes as all-ones)
                self.emit(0x4EE09800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // UMAXV Bd, V0.16B → if any byte set, a lane was zero
                self.emit(0x6E30A800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                const d = destReg(instr.rd);
                self.emit(0x0E013C00 | (@as(u32, SIMD_SCRATCH0) << 5) | d); // UMOV Wd, V0.B[0]
                self.emit(a64.cmpImm32(d, 0));
                self.emit(a64.cset32(d, .eq)); // eq means no zero lanes found → all_true
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- i8x16 ops ---
            0x6E => { self.emitSimdBinaryNeon(instr, 0x4E208400); return true; }, // i8x16.add — ADD .16B
            0x71 => { self.emitSimdBinaryNeon(instr, 0x6E208400); return true; }, // i8x16.sub — SUB .16B
            0x60 => { self.emitSimdUnaryNeon(instr, 0x4E20B800); return true; }, // i8x16.abs — ABS .16B
            0x61 => { self.emitSimdUnaryNeon(instr, 0x6E20B800); return true; }, // i8x16.neg — NEG .16B
            0x76 => { self.emitSimdBinaryNeon(instr, 0x4E206C00); return true; }, // i8x16.min_s — SMIN .16B
            0x77 => { self.emitSimdBinaryNeon(instr, 0x6E206C00); return true; }, // i8x16.min_u — UMIN .16B
            0x78 => { self.emitSimdBinaryNeon(instr, 0x4E206400); return true; }, // i8x16.max_s — SMAX .16B
            0x79 => { self.emitSimdBinaryNeon(instr, 0x6E206400); return true; }, // i8x16.max_u — UMAX .16B
            0x6F => { self.emitSimdBinaryNeon(instr, 0x4E200C00); return true; }, // i8x16.add_sat_s — SQADD .16B
            0x70 => { self.emitSimdBinaryNeon(instr, 0x6E200C00); return true; }, // i8x16.add_sat_u — UQADD .16B
            0x72 => { self.emitSimdBinaryNeon(instr, 0x4E202C00); return true; }, // i8x16.sub_sat_s — SQSUB .16B
            0x73 => { self.emitSimdBinaryNeon(instr, 0x6E202C00); return true; }, // i8x16.sub_sat_u — UQSUB .16B
            // --- i16x8 arithmetic ---
            0x8E => { self.emitSimdBinaryNeon(instr, 0x4E608400); return true; }, // i16x8.add — ADD .8H
            0x91 => { self.emitSimdBinaryNeon(instr, 0x6E608400); return true; }, // i16x8.sub — SUB .8H
            0x95 => { self.emitSimdBinaryNeon(instr, 0x4E609C00); return true; }, // i16x8.mul — MUL .8H
            0x80 => { self.emitSimdUnaryNeon(instr, 0x4E60B800); return true; }, // i16x8.abs — ABS .8H
            0x81 => { self.emitSimdUnaryNeon(instr, 0x6E60B800); return true; }, // i16x8.neg — NEG .8H
            0x96 => { self.emitSimdBinaryNeon(instr, 0x4E606C00); return true; }, // i16x8.min_s — SMIN .8H
            0x97 => { self.emitSimdBinaryNeon(instr, 0x6E606C00); return true; }, // i16x8.min_u — UMIN .8H
            0x98 => { self.emitSimdBinaryNeon(instr, 0x4E606400); return true; }, // i16x8.max_s — SMAX .8H
            0x99 => { self.emitSimdBinaryNeon(instr, 0x6E606400); return true; }, // i16x8.max_u — UMAX .8H
            0x82 => { self.emitSimdBinaryNeon(instr, 0x6E60B400); return true; }, // i16x8.q15mulr_sat_s — SQRDMULH .8H
            0x94 => { self.emitSimdUnaryNeon(instr, 0x4E618800); return true; }, // f64x2.nearest — FRINTN .2D
            0x9B => { self.emitSimdBinaryNeon(instr, 0x6E601400); return true; }, // i16x8.avgr_u — URHADD .8H
            // --- i16x8 extmul ---
            0x9C => { self.emitSimdBinaryNeon(instr, 0x0E20C000); return true; }, // i16x8.extmul_low_i8x16_s — SMULL .8H
            0x9D => { self.emitSimdBinaryNeon(instr, 0x4E20C000); return true; }, // i16x8.extmul_high_i8x16_s — SMULL2 .8H
            0x9E => { self.emitSimdBinaryNeon(instr, 0x2E20C000); return true; }, // i16x8.extmul_low_i8x16_u — UMULL .8H
            0x9F => { self.emitSimdBinaryNeon(instr, 0x6E20C000); return true; }, // i16x8.extmul_high_i8x16_u — UMULL2 .8H
            0x8F => { self.emitSimdBinaryNeon(instr, 0x4E600C00); return true; }, // i16x8.add_sat_s — SQADD .8H
            0x90 => { self.emitSimdBinaryNeon(instr, 0x6E600C00); return true; }, // i16x8.add_sat_u — UQADD .8H
            0x92 => { self.emitSimdBinaryNeon(instr, 0x4E602C00); return true; }, // i16x8.sub_sat_s — SQSUB .8H
            0x93 => { self.emitSimdBinaryNeon(instr, 0x6E602C00); return true; }, // i16x8.sub_sat_u — UQSUB .8H

            // --- i32x4 extend from i16x8 ---
            0xA7 => { // i32x4.extend_low_i16x8_s — SSHLL .4S, .4H, #0
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x0F10A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xA8 => { // i32x4.extend_high_i16x8_s — SSHLL2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x4F10A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xA9 => { // i32x4.extend_low_i16x8_u — USHLL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x2F10A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xAA => { // i32x4.extend_high_i16x8_u — USHLL2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x6F10A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i64x2 extend from i32x4 ---
            0xC7 => { // i64x2.extend_low_i32x4_s — SSHLL .2D, .2S, #0
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x0F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xC8 => { // i64x2.extend_high_i32x4_s — SSHLL2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x4F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xC9 => { // i64x2.extend_low_i32x4_u — USHLL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x2F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xCA => { // i64x2.extend_high_i32x4_u — USHLL2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x6F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i16x8 narrow from i32x4 ---
            0x85 => { // i16x8.narrow_i32x4_s — SQXTN + SQXTN2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x0E614800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // SQXTN .4H
                self.emit(0x4E614800 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SQXTN2 .8H
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x86 => { // i16x8.narrow_i32x4_u — SQXTUN + SQXTUN2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x2E612800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // SQXTUN .4H
                self.emit(0x6E612800 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0); // SQXTUN2 .8H
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i8x16.swizzle — TBL ---
            0x0E => { // i8x16.swizzle — TBL Vd.16B, {Vn.16B}, Vm.16B
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // table
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // indices
                // TBL Vd.16B, {Vn.16B}, Vm.16B = 0x4E000000
                self.emit(0x4E000000 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i8x16.popcnt — CNT ---
            0x62 => { self.emitSimdUnaryNeon(instr, 0x4E205800); return true; }, // i8x16.popcnt — CNT .16B

            // --- v128.bitselect — BSL ---
            0x52 => { // v128.bitselect(v1, v2, mask) — BSL Vd, Vn, Vm
                // mask (c) is in trailing NOP rd field
                self.emitLoadV128(SIMD_SCRATCH0, extra); // mask → V0
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1); // v1 → V1
                const SIMD_SCRATCH2_V: u5 = 2; // use V2 as third scratch
                self.emitLoadV128(SIMD_SCRATCH2_V, instr.rs2_field); // v2 → V2
                // BSL V0.16B, V1.16B, V2.16B = 0x6E601C00 | (Vm << 16) | (Vn << 5) | Vd
                self.emit(0x6E601C00 | (@as(u32, SIMD_SCRATCH2_V) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i16x8 extend (unary) ---
            0x87 => { // i16x8.extend_low_i8x16_s — SXTL V.8H, V.8B
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // SSHLL Vd.8H, Vn.8B, #0 = 0x0F08A400
                self.emit(0x0F08A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x88 => { // i16x8.extend_high_i8x16_s — SSHLL2 V.8H, V.16B, #0
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // SSHLL2 = 0x4F08A400
                self.emit(0x4F08A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x89 => { // i16x8.extend_low_i8x16_u — USHLL V.8H, V.8B, #0
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // USHLL = 0x2F08A400
                self.emit(0x2F08A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x8A => { // i16x8.extend_high_i8x16_u — USHLL2 V.8H, V.16B, #0
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // USHLL2 = 0x6F08A400
                self.emit(0x6F08A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i8x16 narrow (binary → unary-like: takes 2 v128, produces 1) ---
            0x65 => { // i8x16.narrow_i16x8_s — SQXTN + SQXTN2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // lower half source
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // upper half source
                // SQXTN Vd.8B, Vn.8H = 0x0E214800
                self.emit(0x0E214800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // SQXTN2 Vd.16B, Vn.8H = 0x4E214800 (appends to upper half)
                self.emit(0x4E214800 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x66 => { // i8x16.narrow_i16x8_u — SQXTUN + SQXTUN2
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                // SQXTUN Vd.8B, Vn.8H = 0x2E212800
                self.emit(0x2E212800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // SQXTUN2 Vd.16B, Vn.8H = 0x6E212800
                self.emit(0x6E212800 | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- extadd_pairwise ---
            0x7C => { self.emitSimdUnaryNeon(instr, 0x4E202800); return true; }, // i16x8.extadd_pairwise_i8x16_s — SADDLP .8H
            0x7D => { self.emitSimdUnaryNeon(instr, 0x6E202800); return true; }, // i16x8.extadd_pairwise_i8x16_u — UADDLP .8H
            0x7E => { self.emitSimdUnaryNeon(instr, 0x4E602800); return true; }, // i32x4.extadd_pairwise_i16x8_s — SADDLP .4S
            0x7F => { self.emitSimdUnaryNeon(instr, 0x6E602800); return true; }, // i32x4.extadd_pairwise_i16x8_u — UADDLP .4S

            // --- i16x8 shift ---
            0x8B => { // i16x8.shl — SSHL (actually SHL by scalar)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                // DUP V1.8H, Wn (broadcast shift amount)
                self.emit(0x4E020C00 | (@as(u32, shift_reg) << 5) | SIMD_SCRATCH1);
                // SSHL Vd.8H, Vn.8H, Vm.8H = 0x4E604400
                self.emit(0x4E604400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x8C => { // i16x8.shr_s — negate shift amount + SSHL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg)); // negate: 0 - shift (wrap to mod 16)
                self.emit(0x4E020C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                self.emit(0x4E604400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x8D => { // i16x8.shr_u — negate shift amount + USHL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg));
                self.emit(0x4E020C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                // USHL Vd.8H, Vn.8H, Vm.8H = 0x6E604400
                self.emit(0x6E604400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f32x4 rounding ---
            0x67 => { self.emitSimdUnaryNeon(instr, 0x4EA18800); return true; }, // f32x4.ceil — FRINTP .4S
            0x68 => { self.emitSimdUnaryNeon(instr, 0x4E219800); return true; }, // f32x4.floor — FRINTM .4S
            0x69 => { self.emitSimdUnaryNeon(instr, 0x4EA19800); return true; }, // f32x4.trunc — FRINTZ .4S
            0x6A => { self.emitSimdUnaryNeon(instr, 0x4E218800); return true; }, // f32x4.nearest — FRINTN .4S

            // --- f64x2 rounding (some subs split across ranges) ---
            0x74 => { self.emitSimdUnaryNeon(instr, 0x4EE18800); return true; }, // f64x2.ceil — FRINTP .2D
            0x75 => { self.emitSimdUnaryNeon(instr, 0x4E619800); return true; }, // f64x2.floor — FRINTM .2D
            0x7A => { self.emitSimdUnaryNeon(instr, 0x4EE19800); return true; }, // f64x2.trunc — FRINTZ .2D

            // --- i8x16 shift ---
            0x6B => { // i8x16.shl — DUP + SSHL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(0x4E010C00 | (@as(u32, shift_reg) << 5) | SIMD_SCRATCH1); // DUP V1.16B, Wn
                self.emit(0x4E204400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // SSHL .16B
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x6C => { // i8x16.shr_s — negate + DUP + SSHL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg));
                self.emit(0x4E010C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                self.emit(0x4E204400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x6D => { // i8x16.shr_u — negate + DUP + USHL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg));
                self.emit(0x4E010C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                self.emit(0x6E204400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // USHL .16B
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            0x7B => { // i8x16.avgr_u — URHADD V.16B
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                // URHADD Vd.16B, Vn.16B, Vm.16B = 0x6E201400
                self.emit(0x6E201400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i32x4 comparisons ---
            0x37 => { // i32x4.eq — CMEQ Vd.4S
                self.emitSimdBinaryNeon(instr, 0x6EA08C00);
                return true;
            },
            0x38 => { // i32x4.ne — CMEQ + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                // CMEQ Vd.4S, Vn.4S, Vm.4S = 0x6EA08C00
                self.emit(0x6EA08C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // NOT Vd.16B, Vn.16B = 0x6E205800
                self.emit(a64.notV16b(SIMD_SCRATCH0, SIMD_SCRATCH0));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3B => { // i32x4.gt_s — CMGT Vd.4S (signed)
                self.emitSimdBinaryNeon(instr, 0x4EA03400);
                return true;
            },
            0x3C => { // i32x4.gt_u — CMHI Vd.4S (unsigned)
                self.emitSimdBinaryNeon(instr, 0x6EA03400);
                return true;
            },
            0x3F => { // i32x4.ge_s — CMGE Vd.4S (signed)
                self.emitSimdBinaryNeon(instr, 0x4EA03C00);
                return true;
            },
            0x40 => { // i32x4.ge_u — CMHS Vd.4S (unsigned)
                self.emitSimdBinaryNeon(instr, 0x6EA03C00);
                return true;
            },
            0x39 => { // i32x4.lt_s — CMGT with swapped operands
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field); // swap: rs2 as Vn
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1); // swap: rs1 as Vm
                // CMGT Vd.4S, Vn.4S, Vm.4S = 0x4EA03400
                self.emit(0x4EA03400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3A => { // i32x4.lt_u — CMHI with swapped operands
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                // CMHI Vd.4S = 0x6EA03400
                self.emit(0x6EA03400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3D => { // i32x4.le_s — CMGE with swapped operands
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                // CMGE Vd.4S = 0x4EA03C00
                self.emit(0x4EA03C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3E => { // i32x4.le_u — CMHS with swapped operands
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                // CMHS Vd.4S = 0x6EA03C00
                self.emit(0x6EA03C00 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i32x4 arithmetic ---
            0xB5 => { self.emitSimdBinaryNeon(instr, 0x4EA09C00); return true; }, // i32x4.mul — MUL .4S
            0xA0 => { self.emitSimdUnaryNeon(instr, 0x4EA0B800); return true; }, // i32x4.abs — ABS .4S
            0xA1 => { self.emitSimdUnaryNeon(instr, 0x6EA0B800); return true; }, // i32x4.neg — NEG .4S
            0xB6 => { self.emitSimdBinaryNeon(instr, 0x4EA06C00); return true; }, // i32x4.min_s — SMIN .4S
            0xB7 => { self.emitSimdBinaryNeon(instr, 0x6EA06C00); return true; }, // i32x4.min_u — UMIN .4S
            0xB8 => { self.emitSimdBinaryNeon(instr, 0x4EA06400); return true; }, // i32x4.max_s — SMAX .4S
            0xB9 => { self.emitSimdBinaryNeon(instr, 0x6EA06400); return true; }, // i32x4.max_u — UMAX .4S
            // --- i32x4 shift ---
            0xAB => { // i32x4.shl
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(0x4E040C00 | (@as(u32, shift_reg) << 5) | SIMD_SCRATCH1); // DUP V1.4S, Wn
                self.emit(0x4EA04400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // SSHL .4S
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xAC => { // i32x4.shr_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg));
                self.emit(0x4E040C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                self.emit(0x4EA04400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xAD => { // i32x4.shr_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg));
                self.emit(0x4E040C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                self.emit(0x6EA04400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // USHL .4S
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i32x4.dot_i16x8_s — SMULL + SMULL2 + ADDP ---
            0xBA => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // a → V0
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // b → V1
                const SIMD_SCRATCH2_V: u5 = 2;
                // SMULL V2.4S, V0.4H, V1.4H = 0x0E60C000 (lower half multiply)
                self.emit(0x0E60C000 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH2_V);
                // SMULL2 V0.4S, V0.8H, V1.8H = 0x4E60C000 (upper half multiply)
                self.emit(0x4E60C000 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // ADDP V0.4S, V2.4S, V0.4S = 0x4EA0BC00 (pairwise add)
                self.emit(0x4EA0BC00 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, SIMD_SCRATCH2_V) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i32x4 extmul ---
            0xBC => { self.emitSimdBinaryNeon(instr, 0x0E60C000); return true; }, // i32x4.extmul_low_i16x8_s — SMULL .4S
            0xBD => { self.emitSimdBinaryNeon(instr, 0x4E60C000); return true; }, // i32x4.extmul_high_i16x8_s — SMULL2 .4S
            0xBE => { self.emitSimdBinaryNeon(instr, 0x2E60C000); return true; }, // i32x4.extmul_low_i16x8_u — UMULL .4S
            0xBF => { self.emitSimdBinaryNeon(instr, 0x6E60C000); return true; }, // i32x4.extmul_high_i16x8_u — UMULL2 .4S

            // --- i64x2 arithmetic ---
            0xCE => { self.emitSimdBinaryNeon(instr, 0x4EE08400); return true; }, // i64x2.add — ADD .2D
            0xD1 => { self.emitSimdBinaryNeon(instr, 0x6EE08400); return true; }, // i64x2.sub — SUB .2D
            0xC0 => { self.emitSimdUnaryNeon(instr, 0x4EE0B800); return true; }, // i64x2.abs — ABS .2D
            0xC1 => { self.emitSimdUnaryNeon(instr, 0x6EE0B800); return true; }, // i64x2.neg — NEG .2D
            // --- i64x2 shift ---
            0xCB => { // i64x2.shl
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(0x4E080C00 | (@as(u32, shift_reg) << 5) | SIMD_SCRATCH1); // DUP V1.2D, Xn
                self.emit(0x4EE04400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // SSHL .2D
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xCC => { // i64x2.shr_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg));
                self.emit(0x4E080C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                self.emit(0x4EE04400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xCD => { // i64x2.shr_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                self.emit(a64.sub32(SCRATCH, 31, shift_reg));
                self.emit(0x4E080C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH1);
                self.emit(0x6EE04400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0); // USHL .2D
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f32x4 comparisons ---
            0x41 => { self.emitSimdBinaryNeon(instr, 0x4E20E400); return true; }, // f32x4.eq — FCMEQ .4S
            0x42 => { // f32x4.ne — FCMEQ + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x4E20E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emit(a64.notV16b(SIMD_SCRATCH0, SIMD_SCRATCH0));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x44 => { self.emitSimdBinaryNeon(instr, 0x6EA0E400); return true; }, // f32x4.gt — FCMGT .4S
            0x46 => { self.emitSimdBinaryNeon(instr, 0x6E20E400); return true; }, // f32x4.ge — FCMGE .4S
            0x43 => { // f32x4.lt — FCMGT swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6EA0E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x45 => { // f32x4.le — FCMGE swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6E20E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f64x2 comparisons ---
            0x47 => { self.emitSimdBinaryNeon(instr, 0x4E60E400); return true; }, // f64x2.eq — FCMEQ .2D
            0x48 => { // f64x2.ne — FCMEQ + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x4E60E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emit(a64.notV16b(SIMD_SCRATCH0, SIMD_SCRATCH0));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x4A => { self.emitSimdBinaryNeon(instr, 0x6EE0E400); return true; }, // f64x2.gt — FCMGT .2D
            0x4C => { self.emitSimdBinaryNeon(instr, 0x6E60E400); return true; }, // f64x2.ge — FCMGE .2D
            0x49 => { // f64x2.lt — FCMGT swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6EE0E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x4B => { // f64x2.le — FCMGE swapped
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                self.emit(0x6E60E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f32x4/f64x2 pmin/pmax ---
            0xEA => { // f32x4.pmin — FCMGT + BSL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // a → V0
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // b → V1
                const SIMD_SCRATCH2_V: u5 = 2;
                // FCMGT V2.4S, V0.4S, V1.4S → mask where a > b
                self.emit(0x6EA0E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH2_V);
                // BSL V2.16B, V1.16B, V0.16B → b where a>b, else a = pmin
                self.emit(0x6E601C00 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH2_V);
                self.emitStoreV128(SIMD_SCRATCH2_V, instr.rd);
                return true;
            },
            0xEB => { // f32x4.pmax — FCMGT(b,a) + BSL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // a → V0
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // b → V1
                const SIMD_SCRATCH2_V: u5 = 2;
                // FCMGT V2.4S, V1.4S, V0.4S → mask where b > a
                self.emit(0x6EA0E400 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH2_V);
                // BSL V2.16B, V1.16B, V0.16B → b where b>a, else a = pmax
                self.emit(0x6E601C00 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH2_V);
                self.emitStoreV128(SIMD_SCRATCH2_V, instr.rd);
                return true;
            },
            0xF6 => { // f64x2.pmin — FCMGT + BSL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                const SIMD_SCRATCH2_V: u5 = 2;
                self.emit(0x6EE0E400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH2_V);
                self.emit(0x6E601C00 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH2_V);
                self.emitStoreV128(SIMD_SCRATCH2_V, instr.rd);
                return true;
            },
            0xF7 => { // f64x2.pmax — FCMGT(b,a) + BSL
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                const SIMD_SCRATCH2_V: u5 = 2;
                self.emit(0x6EE0E400 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH2_V);
                self.emit(0x6E601C00 | (@as(u32, SIMD_SCRATCH0) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH2_V);
                self.emitStoreV128(SIMD_SCRATCH2_V, instr.rd);
                return true;
            },

            // --- f32x4 min/max/abs/neg/sqrt ---
            0xE8 => { self.emitSimdBinaryNeon(instr, 0x4EA0F400); return true; }, // f32x4.min — FMIN Vd.4S
            0xE9 => { self.emitSimdBinaryNeon(instr, 0x4E20F400); return true; }, // f32x4.max — FMAX Vd.4S
            0xE0 => { self.emitSimdUnaryNeon(instr, 0x4EA0F800); return true; }, // f32x4.abs — FABS Vd.4S
            0xE1 => { self.emitSimdUnaryNeon(instr, 0x6EA0F800); return true; }, // f32x4.neg — FNEG Vd.4S
            0xE3 => { self.emitSimdUnaryNeon(instr, 0x6EA1F800); return true; }, // f32x4.sqrt — FSQRT Vd.4S

            // --- f64x2 sub/div/min/max/abs/neg/sqrt ---
            0xF1 => { self.emitSimdBinaryNeon(instr, 0x4EE0D400); return true; }, // f64x2.sub — FSUB Vd.2D
            0xF3 => { self.emitSimdBinaryNeon(instr, 0x6E60FC00); return true; }, // f64x2.div — FDIV Vd.2D
            0xF4 => { self.emitSimdBinaryNeon(instr, 0x4EE0F400); return true; }, // f64x2.min — FMIN Vd.2D
            0xF5 => { self.emitSimdBinaryNeon(instr, 0x4E60F400); return true; }, // f64x2.max — FMAX Vd.2D
            0xEC => { self.emitSimdUnaryNeon(instr, 0x4EE0F800); return true; }, // f64x2.abs — FABS Vd.2D
            0xED => { self.emitSimdUnaryNeon(instr, 0x6EE0F800); return true; }, // f64x2.neg — FNEG Vd.2D
            0xEF => { self.emitSimdUnaryNeon(instr, 0x6EE1F800); return true; }, // f64x2.sqrt — FSQRT Vd.2D

            // --- trunc/convert ---
            0xF8 => { self.emitSimdUnaryNeon(instr, 0x4EA1B800); return true; }, // i32x4.trunc_sat_f32x4_s — FCVTZS .4S
            0xF9 => { self.emitSimdUnaryNeon(instr, 0x6EA1B800); return true; }, // i32x4.trunc_sat_f32x4_u — FCVTZU .4S
            0xFA => { self.emitSimdUnaryNeon(instr, 0x4E21B800); return true; }, // f32x4.convert_i32x4_s — SCVTF .4S
            0xFB => { self.emitSimdUnaryNeon(instr, 0x6E21B800); return true; }, // f32x4.convert_i32x4_u — UCVTF .4S

            // --- i32x4_trunc_sat_f64x2 ---
            0xFC => { // i32x4_trunc_sat_f64x2_s_zero — FCVTZS .2D + SQXTN .2S
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // FCVTZS V0.2D, V0.2D = 0x4EE1B800
                self.emit(0x4EE1B800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // SQXTN V0.2S, V0.2D = 0x0EA14800 (Q=0 zeroes upper half)
                self.emit(0x0EA14800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xFD => { // i32x4_trunc_sat_f64x2_u_zero — FCVTZU .2D + UQXTN .2S
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // FCVTZU V0.2D, V0.2D = 0x6EE1B800
                self.emit(0x6EE1B800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // UQXTN V0.2S, V0.2D = 0x2EA14800 (Q=0 zeroes upper half)
                self.emit(0x2EA14800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f32x4 demote / f64x2 promote ---
            0x5E => { // f32x4.demote_f64x2_zero — FCVTN Vd.2S, Vn.2D (upper zeroed)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // FCVTN Vd.2S, Vn.2D = 0x0E616800 (Q=0 zeroes upper)
                self.emit(0x0E616800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x5F => { // f64x2.promote_low_f32x4 — FCVTL Vd.2D, Vn.2S
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // FCVTL Vd.2D, Vn.2S = 0x0E617800
                self.emit(0x0E617800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f64x2 convert from low i32x4 ---
            0xFE => { // f64x2.convert_low_i32x4_s — SSHLL + SCVTF
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // SSHLL Vd.2D, Vn.2S, #0 = 0x0F20A400
                self.emit(0x0F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // SCVTF Vd.2D, Vn.2D = 0x4E61B800
                self.emit(0x4E61B800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xFF => { // f64x2.convert_low_i32x4_u — USHLL + UCVTF
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // USHLL Vd.2D, Vn.2S, #0 = 0x2F20A400
                self.emit(0x2F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                // UCVTF Vd.2D, Vn.2D = 0x6E61B800
                self.emit(0x6E61B800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // --- i8x16.shuffle: TBL with 2-register table ---
            0x0D => {
                // Load both v128 inputs into consecutive V registers (V0, V1)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // table[0] → V0
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // table[1] → V1
                // Load shuffle mask from pool64 into V2
                const pool_idx = instr.operand;
                if (pool_idx + 1 < self.pool64.len) {
                    const V2: u5 = 2;
                    const lo = self.pool64[pool_idx];
                    const hi = self.pool64[pool_idx + 1];
                    const lo_instrs = a64.loadImm64(SCRATCH, lo);
                    for (lo_instrs) |inst| self.emit(inst);
                    self.emit(a64.movz64(SCRATCH2, 0, 0)); // clear SCRATCH2 for hi
                    // MOVQ to V2: use GP→NEON
                    // FMOV Dd, Xn = 0x9E670000 | (Xn << 5) | Vd
                    self.emit(0x9E670000 | (@as(u32, SCRATCH) << 5) | V2);
                    const hi_instrs = a64.loadImm64(SCRATCH, hi);
                    for (hi_instrs) |inst| self.emit(inst);
                    // INS V2.D[1], SCRATCH
                    self.emit(a64.insVdD1(V2, SCRATCH));
                    // TBL Vd.16B, {V0.16B, V1.16B}, V2.16B
                    // TBL 2-register: 0x4E000000 | (len=01 << 13) | (Vm << 16) | (Vn << 5) | Vd
                    // len=01 means 2 consecutive registers starting from Vn
                    self.emit(0x4E002000 | (@as(u32, V2) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                    self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                    return true;
                }
                return false;
            },

            // --- relaxed ops: map to non-relaxed equivalents ---
            // relaxed_swizzle (0x100) = same as swizzle (0x0E)
            0x100 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emit(0x4E000000 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // relaxed_trunc (0x101-0x104) = same as trunc_sat
            0x101 => { self.emitSimdUnaryNeon(instr, 0x4EA1B800); return true; }, // relaxed i32x4.trunc_sat_f32x4_s
            0x102 => { self.emitSimdUnaryNeon(instr, 0x6EA1B800); return true; }, // relaxed i32x4.trunc_sat_f32x4_u
            // relaxed_madd (0x105,0x107): FMA — load c, FMLA Vd+=Vn*Vm
            0x105 => { // f32x4.relaxed_madd(a,b,c) = a*b+c
                self.emitLoadV128(SIMD_SCRATCH0, extra); // c → V0 (accumulator)
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1); // a → V1
                const V2: u5 = 2;
                self.emitLoadV128(V2, instr.rs2_field); // b → V2
                // FMLA V0.4S, V1.4S, V2.4S = 0x4E20CC00
                self.emit(0x4E20CC00 | (@as(u32, V2) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x107 => { // f64x2.relaxed_madd
                self.emitLoadV128(SIMD_SCRATCH0, extra);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                const V2: u5 = 2;
                self.emitLoadV128(V2, instr.rs2_field);
                // FMLA V0.2D = 0x4E60CC00
                self.emit(0x4E60CC00 | (@as(u32, V2) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x106 => { // f32x4.relaxed_nmadd(a,b,c) = c - a*b
                self.emitLoadV128(SIMD_SCRATCH0, extra);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                const V2: u5 = 2;
                self.emitLoadV128(V2, instr.rs2_field);
                // FMLS V0.4S = 0x4EA0CC00
                self.emit(0x4EA0CC00 | (@as(u32, V2) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x108 => { // f64x2.relaxed_nmadd
                self.emitLoadV128(SIMD_SCRATCH0, extra);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                const V2: u5 = 2;
                self.emitLoadV128(V2, instr.rs2_field);
                // FMLS V0.2D = 0x4EE0CC00
                self.emit(0x4EE0CC00 | (@as(u32, V2) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // relaxed_laneselect (0x109-0x10C): same as bitselect (BSL)
            0x109, 0x10A, 0x10B, 0x10C => {
                self.emitLoadV128(SIMD_SCRATCH0, extra); // mask → V0
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1); // v1 → V1
                const V2: u5 = 2;
                self.emitLoadV128(V2, instr.rs2_field); // v2 → V2
                self.emit(0x6E601C00 | (@as(u32, V2) << 16) | (@as(u32, SIMD_SCRATCH1) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // relaxed_q15mulr (0x111): same as non-relaxed
            0x111 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                // SQRDMULH .8H = 0x6E60B400
                self.emit(0x6E60B400 | (@as(u32, SIMD_SCRATCH1) << 16) | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // relaxed_trunc_f64x2 (0x103-0x104): same as non-relaxed trunc_sat
            0x103 => { // FCVTZS .2D + SQXTN .2S (same as 0xFC)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x4EE1B800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emit(0x0EA14800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x104 => { // FCVTZU .2D + UQXTN .2S (same as 0xFD)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emit(0x6EE1B800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emit(0x2EA14800 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // relaxed_min/max (0x10D-0x110): same as min/max
            0x10D => { self.emitSimdBinaryNeon(instr, 0x4EA0F400); return true; }, // f32x4.relaxed_min = fmin
            0x10E => { self.emitSimdBinaryNeon(instr, 0x4E20F400); return true; }, // f32x4.relaxed_max = fmax
            0x10F => { self.emitSimdBinaryNeon(instr, 0x4EE0F400); return true; }, // f64x2.relaxed_min
            0x110 => { self.emitSimdBinaryNeon(instr, 0x4E60F400); return true; }, // f64x2.relaxed_max
            // relaxed_q15mulr (0x111) = same as q15mulr
            // relaxed_dot (0x112-0x113): trampoline (ternary)

            // --- v128.load ---
            0x00 => {
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                // Always emit explicit bounds check for v128 (16 bytes)
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 16));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6); // OutOfBoundsMemoryAccess
                // LDR Q0, [MEM_BASE, SCRATCH]
                self.emit(a64.ldrQreg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // --- v128.store ---
            0x0B => {
                if (!self.has_memory) return false;
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                // Always emit explicit bounds check for v128 (16 bytes)
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 16));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                // STR Q0, [MEM_BASE, SCRATCH]
                self.emit(a64.strQreg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                return true;
            },
            // --- v128.load_splat ---
            0x07 => { // v128.load8_splat: load 1 byte, splat to 16 lanes
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 1));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldrbReg(SCRATCH, MEM_BASE, SCRATCH));
                // DUP V0.16B, Wn = 0x4E010C00
                self.emit(0x4E010C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x08 => { // v128.load16_splat: load 2 bytes, splat to 8 lanes
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 2));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldrhReg(SCRATCH, MEM_BASE, SCRATCH));
                // DUP V0.8H, Wn = 0x4E020C00
                self.emit(0x4E020C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x09 => { // v128.load32_splat: load 4 bytes, splat to 4 lanes
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 4));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldr32Reg(SCRATCH, MEM_BASE, SCRATCH));
                // DUP V0.4S, Wn = 0x4E040C00
                self.emit(0x4E040C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x0A => { // v128.load64_splat: load 8 bytes, splat to 2 lanes
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldr64Reg(SCRATCH, MEM_BASE, SCRATCH));
                // DUP V0.2D, Xn = 0x4E080C00
                self.emit(0x4E080C00 | (@as(u32, SCRATCH) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- v128.load_zero ---
            0x5C => { // v128.load32_zero: load 4 bytes into lane 0, zero rest
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 4));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldr32Reg(SCRATCH, MEM_BASE, SCRATCH));
                // Store as GP vreg (lo = value, hi = 0)
                const d = destReg(instr.rd);
                self.emit(a64.mov32(d, SCRATCH));
                self.storeVreg(instr.rd, d);
                // Zero simd_hi
                self.emitLoadVmPtr(SCRATCH2);
                const hi_offset = self.simd_hi_offset + @as(u32, instr.rd) * 8;
                if (hi_offset <= 32760) {
                    self.emit(a64.str64(31, SCRATCH2, @intCast(hi_offset))); // XZR
                } else {
                    const off_instrs = a64.loadImm64(SCRATCH, hi_offset);
                    for (off_instrs) |inst| self.emit(inst);
                    self.emit(a64.add64(SCRATCH2, SCRATCH2, SCRATCH));
                    self.emit(a64.str64(31, SCRATCH2, 0));
                }
                return true;
            },
            0x5D => { // v128.load64_zero: load 8 bytes into lane 0, zero rest
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldr64Reg(SCRATCH, MEM_BASE, SCRATCH));
                // Store as GP vreg (lo = value, hi = 0)
                const d = destReg(instr.rd);
                self.emit(a64.mov64(d, SCRATCH));
                self.storeVreg(instr.rd, d);
                // Zero simd_hi
                self.emitLoadVmPtr(SCRATCH2);
                const hi_offset = self.simd_hi_offset + @as(u32, instr.rd) * 8;
                if (hi_offset <= 32760) {
                    self.emit(a64.str64(31, SCRATCH2, @intCast(hi_offset)));
                } else {
                    const off_instrs = a64.loadImm64(SCRATCH, hi_offset);
                    for (off_instrs) |inst| self.emit(inst);
                    self.emit(a64.add64(SCRATCH2, SCRATCH2, SCRATCH));
                    self.emit(a64.str64(31, SCRATCH2, 0));
                }
                return true;
            },

            // --- v128.load_lane ---
            0x54 => { // v128.load8_lane: load 1 byte into lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 1));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field); // existing v128
                self.emit(a64.ldrbReg(SCRATCH2, MEM_BASE, SCRATCH)); // load byte
                // INS Vd.B[lane], Wn: imm5 = (lane << 1) | 1
                const lane = extra;
                const imm5 = (@as(u32, @as(u4, @truncate(lane))) << 1) | 1;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, SCRATCH2) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x55 => { // v128.load16_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 2));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emit(a64.ldrhReg(SCRATCH2, MEM_BASE, SCRATCH));
                const imm5 = (@as(u32, @as(u3, @truncate(extra))) << 2) | 2;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, SCRATCH2) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x56 => { // v128.load32_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 4));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emit(a64.ldr32Reg(SCRATCH2, MEM_BASE, SCRATCH));
                const imm5 = (@as(u32, @as(u2, @truncate(extra))) << 3) | 4;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, SCRATCH2) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x57 => { // v128.load64_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emit(a64.ldr64Reg(SCRATCH2, MEM_BASE, SCRATCH));
                const imm5 = (@as(u32, @as(u1, @truncate(extra))) << 4) | 8;
                self.emit(0x4E001C00 | (imm5 << 16) | (@as(u32, SCRATCH2) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- v128.store_lane ---
            0x58 => { // v128.store8_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 1));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd); // v128 value
                // UMOV Wd, Vn.B[lane]
                self.emit(0x0E013C00 | (@as(u32, @as(u4, @truncate(extra))) << 17) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH2);
                self.emit(a64.strbReg(SCRATCH2, MEM_BASE, SCRATCH));
                return true;
            },
            0x59 => { // v128.store16_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 2));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                // UMOV Wd, Vn.H[lane]
                self.emit(0x0E023C00 | (@as(u32, @as(u3, @truncate(extra))) << 19) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH2);
                self.emit(a64.strhReg(SCRATCH2, MEM_BASE, SCRATCH));
                return true;
            },
            0x5A => { // v128.store32_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 4));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                // UMOV Wd, Vn.S[lane]
                self.emit(0x0E043C00 | (@as(u32, @as(u2, @truncate(extra))) << 21) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH2);
                self.emit(a64.str32Reg(SCRATCH2, MEM_BASE, SCRATCH));
                return true;
            },
            0x5B => { // v128.store64_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                // UMOV Xd, Vn.D[lane] (Q=1)
                self.emit(0x4E083C00 | (@as(u32, @as(u1, @truncate(extra))) << 20) | (@as(u32, SIMD_SCRATCH0) << 5) | SCRATCH2);
                self.emit(a64.str64Reg(SCRATCH2, MEM_BASE, SCRATCH));
                return true;
            },

            // --- v128.load_extend ---
            0x01 => { // v128.load8x8_s: load 8 bytes, sign-extend to 8 halfwords
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                // LDR D0, [MEM_BASE, SCRATCH] — load 64 bits into lower half
                self.emit(a64.ldrFp64Reg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                // SSHLL V0.8H, V0.8B, #0 = 0x0F08A400
                self.emit(0x0F08A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x02 => { // v128.load8x8_u: load 8 bytes, zero-extend to 8 halfwords
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldrFp64Reg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                // USHLL V0.8H, V0.8B, #0 = 0x2F08A400
                self.emit(0x2F08A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x03 => { // v128.load16x4_s: load 8 bytes, sign-extend 4 halfwords to 4 words
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldrFp64Reg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                // SSHLL V0.4S, V0.4H, #0 = 0x0F10A400
                self.emit(0x0F10A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x04 => { // v128.load16x4_u
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldrFp64Reg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                // USHLL V0.4S, V0.4H, #0 = 0x2F10A400
                self.emit(0x2F10A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x05 => { // v128.load32x2_s: load 8 bytes, sign-extend 2 words to 2 doublewords
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldrFp64Reg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                // SSHLL V0.2D, V0.2S, #0 = 0x0F20A400
                self.emit(0x0F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x06 => { // v128.load32x2_u
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, addr_reg));
                self.emitAddOffset(SCRATCH, instr.operand);
                self.emit(a64.addImm64(SCRATCH2, SCRATCH, 8));
                self.emit(a64.cmp64(SCRATCH2, MEM_SIZE));
                self.emitCondError(.hi, 6);
                self.emit(a64.ldrFp64Reg(SIMD_SCRATCH0, MEM_BASE, SCRATCH));
                // USHLL V0.2D, V0.2S, #0 = 0x2F20A400
                self.emit(0x2F20A400 | (@as(u32, SIMD_SCRATCH0) << 5) | SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- v128.const ---
            0x0C => {
                // Load 128-bit constant from pool64[operand] (2x u64)
                const pool_idx = instr.operand;
                if (pool_idx + 1 < self.pool64.len) {
                    const lo = self.pool64[pool_idx];
                    const hi = self.pool64[pool_idx + 1];
                    // Store lo to regs[rd], hi to simd_hi[rd]
                    const d = destReg(instr.rd);
                    const lo_instrs = a64.loadImm64(d, lo);
                    for (lo_instrs) |inst| self.emit(inst);
                    self.storeVreg(instr.rd, d);
                    // Store hi to simd_hi[rd]
                    const hi_instrs = a64.loadImm64(SCRATCH, hi);
                    for (hi_instrs) |inst| self.emit(inst);
                    self.emitLoadVmPtr(SCRATCH2);
                    const hi_offset = self.simd_hi_offset + @as(u32, instr.rd) * 8;
                    if (hi_offset <= 32760) {
                        self.emit(a64.str64(SCRATCH, SCRATCH2, @intCast(hi_offset)));
                    } else {
                        const off_instrs = a64.loadImm64(17, hi_offset);
                        for (off_instrs) |inst| self.emit(inst);
                        self.emit(a64.add64(SCRATCH2, SCRATCH2, 17));
                        self.emit(a64.str64(SCRATCH, SCRATCH2, 0));
                    }
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Emit SIMD trampoline call: spill → set up args → BLR → error check → reload.
    fn emitSimdTrampoline(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) void {
        const sub = instr.op - predecode_mod.SIMD_BASE;
        const effect = regalloc_mod.simdStackEffect(sub) orelse return;

        // Check for trailing NOP (extra metadata)
        var extra: u16 = 0;
        var third_operand: u16 = 0;
        if (pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP) {
            const nop = ir[pc.*];
            if (effect.pop == 3) {
                third_operand = nop.rd;
                extra = nop.rs1;
            } else {
                extra = nop.rd;
            }
            pc.* += 1;
        }

        // 1. Spill all caller-saved regs
        self.fpCacheEvictAll();
        self.spillCallerSavedLive(ir, pc.* - 1);
        // Spill operand vregs
        if (effect.pop >= 1) self.spillVreg(instr.rs1);
        if (effect.pop >= 2) self.spillVreg(instr.rs2_field);
        if (effect.push == 0 and effect.pop == 2) self.spillVreg(instr.rd); // store: rd is value

        // 2. Set up trampoline args (ARM64 C ABI: x0-x7)
        //    x0 = vm_ptr, x1 = instance_ptr, x2 = regs_ptr
        self.emitLoadVmPtr(0);
        self.emitLoadInstPtr(1);
        self.emit(a64.mov64(2, REGS_PTR));

        //    x3 = opcode | (extra << 32)
        const op_extra_lo: u16 = @truncate(instr.op);
        self.emit(a64.movz64(3, op_extra_lo, 0));
        if (extra != 0) {
            self.emit(a64.movk64(3, extra, 2)); // bits 32-47
        }

        //    x4 = rd | (rs1 << 16) | (rs2 << 32) | (third << 48)
        self.emit(a64.movz64(4, instr.rd, 0));
        self.emit(a64.movk64(4, instr.rs1, 1));
        if (effect.pop >= 2) self.emit(a64.movk64(4, instr.rs2_field, 2));
        if (effect.pop == 3) self.emit(a64.movk64(4, third_operand, 3));

        //    w5 = operand
        if (instr.operand <= 0xFFFF) {
            self.emit(a64.movz32(5, @truncate(instr.operand), 0));
        } else {
            self.emit(a64.movz32(5, @truncate(instr.operand), 0));
            self.emit(a64.movk64(5, @truncate(instr.operand >> 16), 1));
        }

        //    x6 = pool64 ptr, x7 = pool64 len
        const pool64_instrs = a64.loadImm64(6, @intFromPtr(self.pool64.ptr));
        for (pool64_instrs) |inst| self.emit(inst);
        const pool64_len_instrs = a64.loadImm64(7, self.pool64.len);
        for (pool64_len_instrs) |inst| self.emit(inst);

        // 3. BLR to SIMD trampoline
        const simd_trampoline_addr = @intFromPtr(&jitSimdTrampoline);
        const t_instrs = a64.loadImm64(SCRATCH, simd_trampoline_addr);
        for (t_instrs) |inst| self.emit(inst);
        self.emit(a64.blr(SCRATCH));

        // 4. Error check (x0 = 0 success, 1 error)
        const error_branch = self.currentIdx();
        self.emit(a64.cbnz64(0, 0));
        self.error_stubs.append(self.alloc, .{
            .branch_idx = error_branch,
            .error_code = 0,
            .kind = .cbnz64,
            .cond = .eq,
        }) catch {};

        // 5. Reload
        if (self.has_memory) self.emitLoadMemCache();
        self.reloadCallerSavedLive();
        if (effect.push == 1) self.reloadVreg(instr.rd);
    }

    /// Inline self-call: direct BL to function entry, bypassing trampoline.
    /// Manages reg_ptr and callee frame setup inline for maximum performance.
    /// Non-memory functions use cached REG_PTR_VAL (x27) holding the actual value.
    /// Memory functions recompute &vm.reg_ptr into SCRATCH each time.
    fn emitInlineSelfCall(self: *Compiler, rd: u16, data: RegInstr, data2: ?RegInstr, ir: []const RegInstr, call_pc: u32) void {
        const needed: u32 = @as(u32, self.reg_count) + 4;
        const needed_bytes: u32 = needed * 8;

        // 0. Call depth guard — check BEFORE any state modifications.
        if (self.depth_reg_cached) {
            // Register-cached path: x28 holds call_depth. Check-then-increment
            // avoids needing to undo the increment on error (balanced by step 8a SUB).
            self.emit(a64.cmpImm64(28, @intCast(vm_mod.MAX_CALL_DEPTH)));
            self.emitCondError(.ge, 2); // StackOverflow if depth >= MAX
            self.emit(a64.addImm64(28, 28, 1));
        } else {
            // Memory path (memory functions): load-increment-check-store.
            self.emitLoadRegPtrAddr(SCRATCH); // SCRATCH = &vm.reg_ptr
            self.emit(a64.ldr64(SCRATCH2, SCRATCH, 8)); // SCRATCH2 = vm.call_depth
            self.emit(a64.addImm64(SCRATCH2, SCRATCH2, 1));
            self.emit(a64.cmpImm64(SCRATCH2, @intCast(vm_mod.MAX_CALL_DEPTH)));
            self.emitCondError(.ge, 2); // StackOverflow if call_depth >= MAX
            self.emit(a64.str64(SCRATCH2, SCRATCH, 8)); // vm.call_depth = old + 1
        }

        // 1. Spill live regs before self-call.
        self.fpCacheEvictAll(); // Write back D-cache before BL clobbers D-regs
        // Callee-saved spill: lightweight self-call skips STP x19-x28 in callee,
        // so caller must save live callee-saved vregs to regs[] explicitly.
        const callee_exclude: ?u16 = if (self.result_count > 0 and self.isCalleeSavedVreg(rd)) rd else null;
        self.spillCalleeSavedLive(ir, call_pc, callee_exclude);
        self.spillCallerSavedLive(ir, call_pc);

        // 2. Advance vm.reg_ptr and check overflow.
        //    Non-memory: x27 holds reg_ptr VALUE directly — add/sub in register (0 mem).
        //    Memory: compute &vm.reg_ptr into SCRATCH, load/store through it.
        if (self.has_memory) {
            // Memory path: x27 = MEM_BASE, must use SCRATCH for &vm.reg_ptr
            self.emitLoadRegPtrAddr(SCRATCH);
            self.emit(a64.ldr64(SCRATCH2, SCRATCH, 0)); // x16 = vm.reg_ptr
            if (needed <= 0xFFF) {
                self.emit(a64.addImm64(SCRATCH2, SCRATCH2, @intCast(needed)));
            } else {
                self.emit(a64.movz64(0, @truncate(needed), 0));
                self.emit(a64.add64(SCRATCH2, SCRATCH2, 0));
            }
            self.emit(a64.movz64(0, vm_mod.REG_STACK_SIZE, 0));
            self.emit(a64.cmp64(SCRATCH2, 0));
            self.emitCondError(.hi, 2); // StackOverflow if new > max
            self.emit(a64.str64(SCRATCH2, SCRATCH, 0)); // Store back through address
        } else {
            // Non-memory path: x27 = reg_ptr VALUE, operate directly in register.
            if (needed <= 0xFFF) {
                self.emit(a64.addImm64(REG_PTR_VAL, REG_PTR_VAL, @intCast(needed)));
            } else {
                self.emit(a64.movz64(SCRATCH2, @truncate(needed), 0));
                self.emit(a64.add64(REG_PTR_VAL, REG_PTR_VAL, SCRATCH2));
            }
            // For self-call-only: depth check (MAX_CALL_DEPTH) subsumes overflow check
            // when MAX_CALL_DEPTH * frame_size <= REG_STACK_SIZE (true for reg_count <= 28).
            if (!self.self_call_only or @as(u32, vm_mod.MAX_CALL_DEPTH) * needed > vm_mod.REG_STACK_SIZE) {
                // Check: new reg_ptr > REG_STACK_SIZE → stack overflow
                self.emit(a64.movz64(SCRATCH, vm_mod.REG_STACK_SIZE, 0));
                self.emit(a64.cmp64(REG_PTR_VAL, SCRATCH));
                self.emitCondError(.hi, 2); // StackOverflow if new > max
            }
            if (!self.self_call_only) {
                // Write updated reg_ptr to memory for trampoline calls to read.
                // Self-call-only functions keep reg_ptr purely in x27 (no memory sync).
                self.emit(a64.ldr64(SCRATCH, REGS_PTR, @intCast(@as(u16, self.reg_count) * 8)));
                self.emit(a64.str64(REG_PTR_VAL, SCRATCH, 0));
            }
        }

        // 3. Compute callee REGS_PTR: x0 = REGS_PTR + needed*8
        if (needed_bytes <= 0xFFF) {
            self.emit(a64.addImm64(0, REGS_PTR, @intCast(needed_bytes)));
        } else {
            self.emit(a64.movz64(0, @truncate(needed_bytes), 0));
            if (needed_bytes > 0xFFFF) {
                self.emit(a64.movk64(0, @truncate(needed_bytes >> 16), 1));
            }
            self.emit(a64.add64(0, REGS_PTR, 0));
        }

        // 4. Copy args directly from physical regs to callee frame (no spill+load)
        const n_args = self.param_count;
        if (n_args > 0) self.emitArgCopyDirect(0, data.rd, 0);
        if (n_args > 1) self.emitArgCopyDirect(0, data.rs1, 8);
        if (n_args > 2) self.emitArgCopyDirect(0, data.rs2_field, 16);
        if (n_args > 3) self.emitArgCopyDirect(0, @truncate(data.operand), 24);
        if (n_args > 4) {
            if (data2) |d2| {
                if (n_args > 4) self.emitArgCopyDirect(0, d2.rd, 32);
                if (n_args > 5) self.emitArgCopyDirect(0, d2.rs1, 40);
                if (n_args > 6) self.emitArgCopyDirect(0, d2.rs2_field, 48);
                if (n_args > 7) self.emitArgCopyDirect(0, @truncate(d2.operand), 56);
            }
        }

        // 5. Zero-init remaining locals (params..local_count)
        for (n_args..self.local_count) |i| {
            const offset: u16 = @intCast(i * 8);
            self.emit(a64.str64(31, 0, offset)); // XZR → callee regs[i]
        }

        // 6. Set up BL args: x0 = callee regs (already), x1 = vm, x2 = instance
        // Self-call-only with cached ptrs: callee's self-call path skips STR x1/x2,
        // so these MOVs are unnecessary (callee uses x20/x21 directly).
        if (!self.self_call_only or !self.vm_ptr_cached) {
            if (self.vm_ptr_cached) {
                self.emit(a64.mov64(1, 20)); // x1 = x20 (cached vm_ptr)
            } else {
                self.emitLoadVmPtr(1);
            }
        }
        if (!self.self_call_only or !self.inst_ptr_cached) {
            if (self.inst_ptr_cached) {
                self.emit(a64.mov64(2, 21)); // x2 = x21 (cached inst_ptr)
            } else {
                self.emitLoadInstPtr(2);
            }
        }

        // 7. BL to self-call entry (skips callee-saved STP x19-x28)
        const bl_idx = self.currentIdx();
        const bl_target: i32 = @as(i32, @intCast(self.self_call_entry_idx)) - @as(i32, @intCast(bl_idx));
        self.emit(a64.bl(@intCast(bl_target)));

        // 8. After return: callee-saved regs (x19-x28) NOT restored by callee
        //    (lightweight self-call skips LDP x19-x28). x0 = error code.
        //    x29 = caller's original (restored by callee's LDP x29,x30).

        // 8a. Decrement call_depth (unconditionally — must balance even on error).
        if (self.depth_reg_cached) {
            // Register path: 1 instruction.
            self.emit(a64.subImm64(28, 28, 1));
        } else {
            // Memory path: load-sub-store through vm_ptr.
            const vm_slot: u16 = @intCast((@as(u32, self.reg_count) + 2) * 8);
            const cd_addr_offset = self.reg_ptr_offset + 8;
            self.emit(a64.ldr64(SCRATCH, REGS_PTR, vm_slot)); // SCRATCH = vm_ptr
            if (cd_addr_offset <= 0xFFF) {
                self.emit(a64.addImm64(SCRATCH, SCRATCH, @intCast(cd_addr_offset)));
            } else {
                self.emit(a64.movz64(SCRATCH2, @truncate(cd_addr_offset), 0));
                if (cd_addr_offset > 0xFFFF) {
                    self.emit(a64.movk64(SCRATCH2, @truncate(cd_addr_offset >> 16), 1));
                }
                self.emit(a64.add64(SCRATCH, SCRATCH, SCRATCH2));
            }
            self.emit(a64.ldr64(SCRATCH2, SCRATCH, 0));
            self.emit(a64.subImm64(SCRATCH2, SCRATCH2, 1));
            self.emit(a64.str64(SCRATCH2, SCRATCH, 0));
        }

        // 9. Restore vm.reg_ptr
        if (self.has_memory) {
            // Memory path: reload address, load-sub-store through memory
            self.emitLoadRegPtrAddr(SCRATCH);
            self.emit(a64.ldr64(SCRATCH2, SCRATCH, 0));
            if (needed <= 0xFFF) {
                self.emit(a64.subImm64(SCRATCH2, SCRATCH2, @intCast(needed)));
            } else {
                self.emit(a64.movz64(1, @truncate(needed), 0));
                self.emit(a64.sub64(SCRATCH2, SCRATCH2, 1));
            }
            self.emit(a64.str64(SCRATCH2, SCRATCH, 0));
        } else {
            // Non-memory path: subtract directly from x27 (0 mem accesses)
            if (needed <= 0xFFF) {
                self.emit(a64.subImm64(REG_PTR_VAL, REG_PTR_VAL, @intCast(needed)));
            } else {
                self.emit(a64.movz64(SCRATCH2, @truncate(needed), 0));
                self.emit(a64.sub64(REG_PTR_VAL, REG_PTR_VAL, SCRATCH2));
            }
        }

        // 10. Check error — branch to shared error epilogue
        const error_branch = self.currentIdx();
        self.emit(a64.cbnz64(0, 0));
        self.error_stubs.append(self.alloc, .{
            .branch_idx = error_branch,
            .error_code = 0,
            .kind = .cbnz64,
            .cond = .eq,
        }) catch {};

        // 10a. Recover caller's REGS_PTR.
        // After self-call: x19 = callee's REGS_PTR = caller's + needed_bytes.
        if (needed_bytes <= 0xFFF) {
            self.emit(a64.subImm64(REGS_PTR, REGS_PTR, @intCast(needed_bytes)));
        } else {
            self.emit(a64.movz64(SCRATCH, @truncate(needed_bytes), 0));
            if (needed_bytes > 0xFFFF) {
                self.emit(a64.movk64(SCRATCH, @truncate(needed_bytes >> 16), 1));
            }
            self.emit(a64.sub64(REGS_PTR, REGS_PTR, SCRATCH));
        }

        // 10b. Reload callee-saved vregs from regs[] (caller saved them before BL).
        self.reloadCalleeSavedLive();

        // 11-13. Reload memory cache, result, and caller-saved regs.
        //     emitLoadMemCache calls jitGetMemInfo via BLR which clobbers all caller-saved
        //     registers (x0-x7, x9-x15). Must reload memory cache BEFORE caller-saved regs,
        //     matching the same ordering as emitCall (step 5a there).
        const rd_phys = if (self.result_count > 0) vregToPhys(rd) else null;
        const rd_callee_saved = if (rd_phys) |p| (p >= 19 and p <= 28) else false;

        // 11a. Callee-saved result: load before BLR (survives BLR since callee-saved).
        if (self.result_count > 0 and rd_callee_saved) {
            self.emitLoadCalleeResult(rd_phys.?, needed_bytes);
        }

        // 12. Reload memory cache BEFORE caller-saved regs (BLR clobbers x0-x15).
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // 13. Reload caller-saved regs AFTER all BLRs, then caller-saved result last.
        self.reloadCallerSavedLiveExcept(if (rd_phys != null and !rd_callee_saved) rd else null);

        if (self.result_count > 0 and !rd_callee_saved) {
            if (rd_phys) |phys| {
                self.emitLoadCalleeResult(phys, needed_bytes);
            } else {
                // Memory-backed: must go through SCRATCH → memory
                self.emitLoadCalleeResult(SCRATCH, needed_bytes);
                self.emit(a64.str64(SCRATCH, REGS_PTR, @as(u16, rd) * 8));
            }
        }
    }

    /// Load callee result (regs[0] at callee frame) into a target register.
    fn emitLoadCalleeResult(self: *Compiler, target: u5, needed_bytes: u32) void {
        if (needed_bytes <= 0xFFF) {
            self.emit(a64.ldr64(target, REGS_PTR, @intCast(needed_bytes)));
        } else {
            self.emit(a64.movz64(target, @truncate(needed_bytes), 0));
            if (needed_bytes > 0xFFFF) {
                self.emit(a64.movk64(target, @truncate(needed_bytes >> 16), 1));
            }
            self.emit(a64.add64(target, REGS_PTR, target));
            self.emit(a64.ldr64(target, target, 0));
        }
    }

    /// Copy a single arg directly from physical register to callee frame.
    /// Uses physical reg if available, otherwise loads from memory via SCRATCH2.
    fn emitArgCopyDirect(self: *Compiler, callee_base: u5, src_vreg: u16, offset: u16) void {
        if (vregToPhys(src_vreg)) |phys| {
            self.emit(a64.str64(phys, callee_base, offset));
        } else {
            self.emit(a64.ldr64(SCRATCH2, REGS_PTR, @as(u16, src_vreg) * 8));
            self.emit(a64.str64(SCRATCH2, callee_base, offset));
        }
    }

    /// Emit code to compute &vm.reg_ptr (VM_PTR + offset) into dst register.
    fn emitLoadRegPtrAddr(self: *Compiler, dst: u5) void {
        const offset = self.reg_ptr_offset;
        // Load VM pointer from memory into dst first
        self.emitLoadVmPtr(dst);
        if (offset <= 0xFFF) {
            self.emit(a64.addImm64(dst, dst, @intCast(offset)));
        } else {
            const tmp = if (dst == SCRATCH) SCRATCH2 else SCRATCH;
            self.emit(a64.movz64(tmp, @truncate(offset), 0));
            if (offset > 0xFFFF) {
                self.emit(a64.movk64(tmp, @truncate(offset >> 16), 1));
            }
            self.emit(a64.add64(dst, dst, tmp));
        }
    }

    // --- Floating-point emitters (f64) ---

    /// f64 binary: add/sub/mul/div. Uses D2-D7 cache to avoid GPR↔FPR round-trips.
    fn emitFpBinop64(self: *Compiler, instr: RegInstr) void {
        // Load operands into D-registers (from cache or GPR)
        const dn = self.fpLoadToDreg(instr.rs1);
        const dm = self.fpLoadToDreg(instr.rs2());
        // Allocate result D-register
        const dd = self.fpAllocResult(instr.rd);
        const enc: u32 = switch (instr.op) {
            0xA0 => a64.fadd64(dd, dn, dm),
            0xA1 => a64.fsub64(dd, dn, dm),
            0xA2 => a64.fmul64(dd, dn, dm),
            0xA3 => a64.fdiv64(dd, dn, dm),
            else => unreachable,
        };
        self.emit(enc);
        self.fpMarkResultDirty(instr.rd);
    }

    /// f64 binary with direct FP instruction (min/max).
    fn emitFpBinopDirect64(self: *Compiler, fpOp: fn (u5, u5, u5) u32, instr: RegInstr) void {
        const dn = self.fpLoadToDreg(instr.rs1);
        const dm = self.fpLoadToDreg(instr.rs2());
        const dd = self.fpAllocResult(instr.rd);
        self.emit(fpOp(dd, dn, dm));
        self.fpMarkResultDirty(instr.rd);
    }

    /// f64 unary (sqrt/abs/neg). Uses D-register cache.
    fn emitFpUnop64(self: *Compiler, fpOp: fn (u5, u5) u32, instr: RegInstr) void {
        const dn = self.fpLoadToDreg(instr.rs1);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(fpOp(dd, dn));
        self.fpMarkResultDirty(instr.rd);
    }

    /// f64 comparison: FCMP + CSET. Inputs from D-cache, result is integer.
    fn emitFpCmp64(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
        const dn = self.fpLoadToDreg(instr.rs1);
        const dm = self.fpLoadToDreg(instr.rs2());
        self.emit(a64.fcmp64(dn, dm));
        const d = destReg(instr.rd);
        self.emit(a64.cset32(d, cond));
        self.storeVreg(instr.rd, d);
    }

    // --- Floating-point emitters (f32) ---

    /// f32 binary: add/sub/mul/div. GPR→FPR, compute, FPR→GPR.
    fn emitFpBinop32(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll(); // f32 uses S0/S1 which alias D0/D1; also clobbers upper D bits
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, rs1));
        self.emit(a64.fmovToFp32(FP_SCRATCH1, rs2));
        const enc: u32 = switch (instr.op) {
            0x92 => a64.fadd32(FP_SCRATCH0, FP_SCRATCH0, FP_SCRATCH1),
            0x93 => a64.fsub32(FP_SCRATCH0, FP_SCRATCH0, FP_SCRATCH1),
            0x94 => a64.fmul32(FP_SCRATCH0, FP_SCRATCH0, FP_SCRATCH1),
            0x95 => a64.fdiv32(FP_SCRATCH0, FP_SCRATCH0, FP_SCRATCH1),
            else => unreachable,
        };
        self.emit(enc);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    /// f32 binary with direct FP instruction (min/max).
    fn emitFpBinopDirect32(self: *Compiler, fpOp: fn (u5, u5, u5) u32, instr: RegInstr) void {
        self.fpCacheEvictAll();
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, rs1));
        self.emit(a64.fmovToFp32(FP_SCRATCH1, rs2));
        self.emit(fpOp(FP_SCRATCH0, FP_SCRATCH0, FP_SCRATCH1));
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    /// f32 unary (sqrt/abs/neg).
    fn emitFpUnop32(self: *Compiler, fpOp: fn (u5, u5) u32, instr: RegInstr) void {
        self.fpCacheEvictAll();
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, src));
        self.emit(fpOp(FP_SCRATCH0, FP_SCRATCH0));
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    /// f32 comparison: FCMP + CSET.
    fn emitFpCmp32(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
        self.fpCacheEvictAll();
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, rs1));
        self.emit(a64.fmovToFp32(FP_SCRATCH1, rs2));
        self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
        const d = destReg(instr.rd);
        self.emit(a64.cset32(d, cond));
        self.storeVreg(instr.rd, d);
    }

    // --- Floating-point conversion emitters ---

    /// f64.convert_i32_s: SCVTF Dd, Wn — result into D-cache.
    fn emitFpConvert_f64_i32_s(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(0x1E620000 | (@as(u32, src) << 5) | @as(u32, dd));
        self.fpMarkResultDirty(instr.rd);
    }

    /// f64.convert_i32_u: UCVTF Dd, Wn
    fn emitFpConvert_f64_i32_u(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(0x1E630000 | (@as(u32, src) << 5) | @as(u32, dd));
        self.fpMarkResultDirty(instr.rd);
    }

    /// f64.convert_i64_s: SCVTF Dd, Xn
    fn emitFpConvert_f64_i64_s(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(0x9E620000 | (@as(u32, src) << 5) | @as(u32, dd));
        self.fpMarkResultDirty(instr.rd);
    }

    /// f64.convert_i64_u: UCVTF Dd, Xn
    fn emitFpConvert_f64_i64_u(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(0x9E630000 | (@as(u32, src) << 5) | @as(u32, dd));
        self.fpMarkResultDirty(instr.rd);
    }

    /// f64.promote_f32: FCVT Dd, Sn
    fn emitFpPromote(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll(); // f32 input uses S register
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, src));
        self.emit(a64.fcvt_d_s(dd, FP_SCRATCH0));
        self.fpMarkResultDirty(instr.rd);
    }

    /// f32.convert_i32_s: SCVTF Sd, Wn
    fn emitFpConvert_f32_i32_s(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(0x1E220000 | (@as(u32, src) << 5) | FP_SCRATCH0);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    /// f32.convert_i32_u: UCVTF Sd, Wn
    fn emitFpConvert_f32_i32_u(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(0x1E230000 | (@as(u32, src) << 5) | FP_SCRATCH0);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    /// f32.convert_i64_s: SCVTF Sd, Xn
    fn emitFpConvert_f32_i64_s(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(0x9E220000 | (@as(u32, src) << 5) | FP_SCRATCH0);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    /// f32.convert_i64_u: UCVTF Sd, Xn
    fn emitFpConvert_f32_i64_u(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(0x9E230000 | (@as(u32, src) << 5) | FP_SCRATCH0);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    /// f32.demote_f64: FCVT Sd, Dn — loads f64 from D-cache if available.
    fn emitFpDemote(self: *Compiler, instr: RegInstr) void {
        // Load f64 source from D-cache or GPR
        if (self.fpCacheFind(instr.rs1)) |slot| {
            const dn = fpSlotToDreg(slot);
            self.fpCacheEvictAll();
            self.emit(a64.fcvt_s_d(FP_SCRATCH0, dn));
        } else {
            self.fpCacheEvictAll();
            const src = self.getOrLoad(instr.rs1, SCRATCH);
            self.emit(a64.fmovToFp64(FP_SCRATCH0, src));
            self.emit(a64.fcvt_s_d(FP_SCRATCH0, FP_SCRATCH0));
        }
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    // --- Copysign ---

    /// f32.copysign: result = (rs1 & 0x7FFFFFFF) | (rs2 & 0x80000000)
    fn emitFpCopysign32(self: *Compiler, instr: RegInstr) void {
        const a = self.getOrLoad(instr.rs1, SCRATCH);
        const b_reg = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        // Load 0x7FFFFFFF into a temp
        self.emit(a64.movz64(SCRATCH, 0xFFFF, 0));
        self.emit(a64.movk64(SCRATCH, 0x7FFF, 1));
        self.emit(a64.and32(d, a, SCRATCH)); // d = a & 0x7FFFFFFF
        // Load 0x80000000 into temp
        self.emit(a64.movz64(SCRATCH, 0, 0));
        self.emit(a64.movk64(SCRATCH, 0x8000, 1));
        self.emit(a64.and32(SCRATCH, b_reg, SCRATCH)); // scratch = b & 0x80000000
        self.emit(a64.orr32(d, d, SCRATCH)); // d = abs(a) | sign(b)
        self.storeVreg(instr.rd, d);
    }

    /// f64.copysign: result = (rs1 & 0x7FFF...) | (rs2 & 0x8000...)
    fn emitFpCopysign64(self: *Compiler, instr: RegInstr) void {
        const a = self.getOrLoad(instr.rs1, SCRATCH);
        const b_reg = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        // Load 0x7FFFFFFFFFFFFFFF (abs mask)
        for (a64.loadImm64(SCRATCH, 0x7FFFFFFFFFFFFFFF)) |inst| self.emit(inst);
        self.emit(a64.and64(d, a, SCRATCH)); // d = a & abs_mask
        // Sign of b: shift right by 63, shift left by 63 (or load sign_mask)
        for (a64.loadImm64(SCRATCH, 0x8000000000000000)) |inst| self.emit(inst);
        self.emit(a64.and64(SCRATCH, b_reg, SCRATCH)); // scratch = b & sign_mask
        self.emit(a64.orr64(d, d, SCRATCH)); // d = abs(a) | sign(b)
        self.storeVreg(instr.rd, d);
    }

    // --- Rounding ---

    fn emitFpRound64(self: *Compiler, encoding: u32, instr: RegInstr) void {
        // f64 rounding: use D-cache (encoding format = base | (Rn<<5) | Rd)
        const dn = self.fpLoadToDreg(instr.rs1);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(encoding | (@as(u32, dn) << 5) | dd);
        self.fpMarkResultDirty(instr.rd);
    }

    fn emitFpRound32(self: *Compiler, encoding: u32, instr: RegInstr) void {
        // Uses S0/D0 (FP_SCRATCH0=0), doesn't alias D2-D7 cache
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, src));
        self.emit(encoding | (@as(u32, FP_SCRATCH0) << 5) | FP_SCRATCH0);
        const d = destReg(instr.rd);
        self.emit(a64.fmovToGp32(d, FP_SCRATCH0));
        self.storeVreg(instr.rd, d);
    }

    // --- Float-to-integer truncation ---

    /// i32.trunc_f32/f64_s/u: NaN check + boundary check + FCVTZS/FCVTZU
    fn emitTruncToI32(self: *Compiler, instr: RegInstr, is_f64: bool, signed: bool) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        // Move to FP register for comparison
        if (is_f64) {
            self.emit(a64.fmovToFp64(FP_SCRATCH0, src));
            self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH0)); // NaN check
        } else {
            self.emit(a64.fmovToFp32(FP_SCRATCH0, src));
            self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH0));
        }
        self.emitCondError(.vs, 8); // NaN → InvalidConversion

        // Boundary check: load min/max boundary as float, compare
        if (signed) {
            // i32 signed: valid if -2147483649.0 < float < 2147483648.0
            if (is_f64) {
                // -2147483649.0 as f64 = 0xC1E0000000200000
                for (a64.loadImm64(SCRATCH2, 0xC1E0000000200000)) |inst| self.emit(inst);
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8); // float <= -2147483649.0 → overflow
                // 2147483648.0 as f64 = 0x41E0000000000000
                for (a64.loadImm64(SCRATCH2, 0x41E0000000000000)) |inst| self.emit(inst);
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8); // float >= 2147483648.0 → overflow
            } else {
                // -2147483904.0 as f32 = 0xCF000001 (just below -2^31)
                self.emitLoadImm(SCRATCH2, 0xCF000001);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8); // overflow
                // 2147483648.0 as f32 = 0x4F000000
                self.emitLoadImm(SCRATCH2, 0x4F000000);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8); // overflow
            }
            // Convert
            const d = destReg(instr.rd);
            if (is_f64) {
                self.emit(a64.fcvtzs_w_d(d, FP_SCRATCH0));
            } else {
                self.emit(a64.fcvtzs_w_s(d, FP_SCRATCH0));
            }
            self.storeVreg(instr.rd, d);
        } else {
            // u32: valid if -1.0 < float < 4294967296.0
            if (is_f64) {
                // -1.0 as f64 = 0xBFF0000000000000
                for (a64.loadImm64(SCRATCH2, 0xBFF0000000000000)) |inst| self.emit(inst);
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8); // float <= -1.0 → overflow
                // 4294967296.0 as f64 = 0x41F0000000000000
                for (a64.loadImm64(SCRATCH2, 0x41F0000000000000)) |inst| self.emit(inst);
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8); // overflow
            } else {
                // -1.0 as f32 = 0xBF800000
                self.emitLoadImm(SCRATCH2, 0xBF800000);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8);
                // 4294967296.0 as f32 = 0x4F800000
                self.emitLoadImm(SCRATCH2, 0x4F800000);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8);
            }
            const d = destReg(instr.rd);
            if (is_f64) {
                self.emit(a64.fcvtzu_w_d(d, FP_SCRATCH0));
            } else {
                self.emit(a64.fcvtzu_w_s(d, FP_SCRATCH0));
            }
            self.storeVreg(instr.rd, d);
        }
    }

    /// i64.trunc_f32/f64_s/u: NaN check + boundary check + FCVTZS/FCVTZU
    fn emitTruncToI64(self: *Compiler, instr: RegInstr, is_f64: bool, signed: bool) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        if (is_f64) {
            self.emit(a64.fmovToFp64(FP_SCRATCH0, src));
            self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH0));
        } else {
            self.emit(a64.fmovToFp32(FP_SCRATCH0, src));
            self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH0));
        }
        self.emitCondError(.vs, 8); // NaN → InvalidConversion

        if (signed) {
            // i64 signed: valid if -9223372036854777856.0 < float < 9223372036854775808.0
            if (is_f64) {
                // -9223372036854775809.0 as f64 = 0xC3E0000000000000 (= -2^63 exactly, but we
                // need strictly less, so check <= -2^63 - 1. However -2^63 is valid for i64.
                // -2^63 as f64 = 0xC3E0000000000000. This is exactly representable.
                // Valid range: [-2^63, 2^63-1]. Since 2^63 as f64 = 0x43E0000000000000,
                // we check: float >= 2^63 → overflow, float < -2^63 → overflow
                // But float == -2^63 is valid (it truncates to -2^63 = i64 min)
                for (a64.loadImm64(SCRATCH2, 0x43E0000000000000)) |inst| self.emit(inst); // 2^63
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8); // float >= 2^63 → overflow
                // Check float < -2^63 - 1 (which is not exactly representable in f64)
                // -2^63 - 1 rounds to -2^63 in f64, so we need: float < -2^63 is overflow
                // But -2^63 IS valid! So: strictly < -2^63 → overflow
                // Next representable f64 below -2^63 is -9223372036854777856.0 = 0xC3E0000000000001
                for (a64.loadImm64(SCRATCH2, 0xC3E0000000000001)) |inst| self.emit(inst);
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8); // float <= next_below(-2^63) → overflow
            } else {
                // 2^63 as f32 = 0x5F000000
                self.emitLoadImm(SCRATCH2, 0x5F000000);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8);
                // -2^63 as f32 = 0xDF000000. This is exactly -2^63. Valid.
                // Next f32 below -2^63 is 0xDF000001
                self.emitLoadImm(SCRATCH2, 0xDF000001);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8);
            }
            const d = destReg(instr.rd);
            if (is_f64) {
                self.emit(a64.fcvtzs_x_d(d, FP_SCRATCH0));
            } else {
                self.emit(a64.fcvtzs_x_s(d, FP_SCRATCH0));
            }
            self.storeVreg(instr.rd, d);
        } else {
            // u64: valid if -1.0 < float < 2^64
            if (is_f64) {
                // -1.0 as f64 = 0xBFF0000000000000
                for (a64.loadImm64(SCRATCH2, 0xBFF0000000000000)) |inst| self.emit(inst);
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8);
                // 2^64 as f64 = 0x43F0000000000000
                for (a64.loadImm64(SCRATCH2, 0x43F0000000000000)) |inst| self.emit(inst);
                self.emit(a64.fmovToFp64(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp64(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8);
            } else {
                // -1.0 as f32 = 0xBF800000
                self.emitLoadImm(SCRATCH2, 0xBF800000);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ls, 8);
                // 2^64 as f32 = 0x5F800000
                self.emitLoadImm(SCRATCH2, 0x5F800000);
                self.emit(a64.fmovToFp32(FP_SCRATCH1, SCRATCH2));
                self.emit(a64.fcmp32(FP_SCRATCH0, FP_SCRATCH1));
                self.emitCondError(.ge, 8);
            }
            const d = destReg(instr.rd);
            if (is_f64) {
                self.emit(a64.fcvtzu_x_d(d, FP_SCRATCH0));
            } else {
                self.emit(a64.fcvtzu_x_s(d, FP_SCRATCH0));
            }
            self.storeVreg(instr.rd, d);
        }
    }

    // --- Error stub emission ---

    /// Emit error stubs and shared error epilogue at end of function.
    /// Each error site branches to a stub that sets x0 and jumps to shared exit.
    fn emitErrorStubs(self: *Compiler) void {
        if (self.error_stubs.items.len == 0 and self.fuel_check_branches.items.len == 0 and !self.use_guard_pages) return;

        // Shared error epilogue: restore callee-saved regs and return (x0 has error code)
        const shared_exit = self.currentIdx();
        self.shared_exit_idx = shared_exit;
        self.emitCalleeSavedRestore();
        self.emit(a64.ret_());

        // Emit per-error stubs and patch branch sites
        for (self.error_stubs.items) |stub| {
            if (stub.error_code == 0) {
                // Call error: x0 already has error code, branch directly to shared exit
                const offset: i32 = @as(i32, @intCast(shared_exit)) - @as(i32, @intCast(stub.branch_idx));
                switch (stub.kind) {
                    .cbnz64 => {
                        const imm: i19 = @intCast(offset);
                        self.code.items[stub.branch_idx] = a64.cbnz64(0, imm);
                    },
                    .b_cond_inverted => unreachable, // call errors always use cbnz64
                }
            } else {
                // Condition error: emit stub with MOVZ + B shared_exit
                const stub_idx = self.currentIdx();
                self.emit(a64.movz64(0, stub.error_code, 0)); // x0 = error_code
                const exit_offset: i26 = @intCast(@as(i32, @intCast(shared_exit)) - @as(i32, @intCast(self.currentIdx())));
                self.emit(a64.b(exit_offset));

                // Patch the original branch to point to this stub
                const offset: i32 = @as(i32, @intCast(stub_idx)) - @as(i32, @intCast(stub.branch_idx));
                switch (stub.kind) {
                    .b_cond_inverted => {
                        const imm: u19 = @bitCast(@as(i19, @intCast(offset)));
                        self.code.items[stub.branch_idx] = 0x54000000 | (@as(u32, imm) << 5) | @as(u32, @intFromEnum(stub.cond));
                    },
                    .cbnz64 => unreachable, // condition errors always use b_cond
                }
            }
        }

        // Emit shared fuel-exhausted exit and patch all fuel check branches.
        // Single stub: MOVZ x0, #9 + B shared_exit. All back-edge checks branch here.
        if (self.fuel_check_branches.items.len > 0) {
            const fuel_stub_idx = self.currentIdx();
            self.emit(a64.movz64(0, 9, 0)); // x0 = 9 (FuelExhausted)
            const exit_offset: i26 = @intCast(@as(i32, @intCast(shared_exit)) - @as(i32, @intCast(self.currentIdx())));
            self.emit(a64.b(exit_offset));

            // Patch all fuel check B.MI branches to point to this stub
            for (self.fuel_check_branches.items) |branch_idx| {
                const offset: i32 = @as(i32, @intCast(fuel_stub_idx)) - @as(i32, @intCast(branch_idx));
                const imm: u19 = @bitCast(@as(i19, @intCast(offset)));
                self.code.items[branch_idx] = 0x54000000 | (@as(u32, imm) << 5) | @as(u32, @intFromEnum(a64.Cond.mi));
            }
        }
    }

    // --- Branch patching ---

    fn patchBranches(self: *Compiler) !void {
        for (self.patches.items) |patch| {
            if (patch.target_pc >= self.pc_map.items.len) return error.InvalidBranchTarget;
            const target_arm_idx = self.pc_map.items[patch.target_pc];
            const offset: i32 = @as(i32, @intCast(target_arm_idx)) - @as(i32, @intCast(patch.arm64_idx));
            switch (patch.kind) {
                .b => {
                    const imm: i26 = @intCast(offset);
                    self.code.items[patch.arm64_idx] = a64.b(imm);
                },
                .b_cond => {
                    // Extract condition from existing placeholder
                    const existing = self.code.items[patch.arm64_idx];
                    const cond_bits: u4 = @truncate(existing);
                    const imm: u19 = @bitCast(@as(i19, @intCast(offset)));
                    self.code.items[patch.arm64_idx] = 0x54000000 | (@as(u32, imm) << 5) | cond_bits;
                },
                .cbz32 => {
                    const existing = self.code.items[patch.arm64_idx];
                    const rt: u5 = @truncate(existing);
                    const imm: i19 = @intCast(offset);
                    self.code.items[patch.arm64_idx] = a64.cbz32(rt, imm);
                },
                .cbnz32 => {
                    const existing = self.code.items[patch.arm64_idx];
                    const rt: u5 = @truncate(existing);
                    const imm: i19 = @intCast(offset);
                    self.code.items[patch.arm64_idx] = a64.cbnz32(rt, imm);
                },
            }
        }
    }

    // --- Finalization ---

    fn finalize(self: *Compiler) ?*JitCode {
        const code_size = self.code.items.len * 4;
        const page_size = std.heap.page_size_min;
        const buf_size = std.mem.alignForward(usize, code_size, page_size);

        const aligned_buf = platform.allocatePages(buf_size, .read_write) catch return null;

        // Copy instructions to executable buffer
        const src_bytes = std.mem.sliceAsBytes(self.code.items);
        @memcpy(aligned_buf[0..src_bytes.len], src_bytes);

        // Make executable (W^X transition)
        platform.protectPages(aligned_buf, .read_exec) catch {
            platform.freePages(aligned_buf);
            return null;
        };

        // Flush instruction cache
        platform.flushInstructionCache(aligned_buf.ptr, code_size);

        // Allocate JitCode struct
        const jit_code = self.alloc.create(JitCode) catch {
            platform.freePages(aligned_buf);
            return null;
        };
        jit_code.* = .{
            .buf = aligned_buf,
            .entry = @ptrCast(@alignCast(aligned_buf.ptr)),
            .code_len = @intCast(self.code.items.len * 4),
            .oob_exit_offset = self.shared_exit_idx * 4,
            .osr_entry = if (self.osr_prologue_idx > 0)
                @ptrCast(@alignCast(aligned_buf.ptr + self.osr_prologue_idx * 4))
            else
                null,
        };
        return jit_code;
    }
};

// ================================================================
// Call trampoline — called from JIT code for function calls
// ================================================================

const vm_mod = @import("vm.zig");

/// Trampoline for JIT→interpreter function calls.
/// Called with C calling convention from JIT-compiled code.
///
/// Args: x0=vm, x1=instance, x2=regs, w3=func_idx,
///       w4=result_reg, x5=data_word, x6=data2_word
/// Returns: 0 on success, non-zero WasmError ordinal.
pub fn jitCallTrampoline(
    vm_opaque: *anyopaque,
    instance_opaque: *anyopaque,
    regs: [*]u64,
    func_idx: u32,
    result_reg: u32,
    data_raw: u64,
    data2_raw: u64,
) callconv(.c) u64 {
    const vm: *vm_mod.Vm = @ptrCast(@alignCast(vm_opaque));
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));

    // Decode data word to get arg register indices
    const data = unpackDataWord(data_raw);

    const func_ptr = instance.getFuncPtr(func_idx) catch return 1;
    const n_args = func_ptr.params.len;
    const n_results = func_ptr.results.len;

    // Collect args from register file
    var call_args: [8]u64 = undefined;
    if (n_args > 0) call_args[0] = regs[data.r0];
    if (n_args > 1) call_args[1] = regs[data.r1];
    if (n_args > 2) call_args[2] = regs[data.r2];
    if (n_args > 3) call_args[3] = regs[data.r3];
    if (n_args > 4 and data2_raw != 0) {
        const d2 = unpackDataWord(data2_raw);
        if (n_args > 4) call_args[4] = regs[d2.r0];
        if (n_args > 5) call_args[5] = regs[d2.r1];
        if (n_args > 6) call_args[6] = regs[d2.r2];
        if (n_args > 7) call_args[7] = regs[d2.r3];
    }

    // Fast path: if callee is already JIT-compiled, call directly (skip callFunction)
    if (vm.call_depth < vm_mod.MAX_CALL_DEPTH and func_ptr.subtype == .wasm_function) {
        const wf = &func_ptr.subtype.wasm_function;
        if (wf.jit_code) |jc| {
            if (wf.reg_ir) |reg| {
                const base = vm.reg_ptr;
                const needed: usize = reg.reg_count + 4; // +4: mem cache + VM/inst ptrs
                if (base + needed > vm_mod.REG_STACK_SIZE) return 2; // StackOverflow
                const callee_regs = vm.reg_stack[base .. base + needed];
                vm.reg_ptr = base + needed;
                vm.call_depth += 1;

                for (call_args[0..n_args], 0..) |arg, i| callee_regs[i] = arg;
                for (n_args..reg.local_count) |i| callee_regs[i] = 0;

                // Save/restore guard page recovery: callee's recovery must not
                // clobber caller's — otherwise caller crashes on guard page faults
                // after this trampoline returns.
                const guard_mod = @import("guard.zig");
                const saved_recovery = guard_mod.getRecovery().*;
                if (jc.oob_exit_offset != 0) {
                    const buf_start = @intFromPtr(jc.buf.ptr);
                    guard_mod.setRecovery(.{
                        .oob_exit_pc = buf_start + jc.oob_exit_offset,
                        .jit_code_start = buf_start,
                        .jit_code_end = buf_start + jc.code_len,
                        .active = true,
                    });
                }

                const err = jc.entry(callee_regs.ptr, vm_opaque, instance_opaque);

                guard_mod.setRecovery(saved_recovery);
                vm.reg_ptr = base;
                vm.call_depth -= 1;
                if (err != 0) return err;

                if (n_results > 0) regs[result_reg] = callee_regs[0];
                return 0;
            }
        }
    }

    // Slow path: full callFunction (interpreter dispatch)
    var call_results: [1]u64 = .{0};
    vm.callFunction(instance, func_ptr, call_args[0..n_args], call_results[0..@min(n_results, 1)]) catch |e| {
        return wasmErrorToCode(e);
    };

    if (n_results > 0) {
        regs[result_reg] = call_results[0];
    }
    return 0;
}

/// JIT trampoline for call_indirect: table lookup + type check + callFunction.
pub fn jitCallIndirectTrampoline(
    vm_opaque: *anyopaque,
    instance_opaque: *anyopaque,
    regs: [*]u64,
    type_idx_table_idx: u32,
    result_reg: u32,
    data_raw: u64,
    data2_raw: u64,
    elem_idx: u32,
) callconv(.c) u64 {
    const vm: *vm_mod.Vm = @ptrCast(@alignCast(vm_opaque));
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));

    const type_idx = type_idx_table_idx & 0xFFFFFF;
    const table_idx: u8 = @truncate(type_idx_table_idx >> 24);

    // Table lookup
    const t = instance.getTable(table_idx) catch return 1;
    const func_addr = t.lookup(elem_idx) catch {
        return 6; // OutOfBoundsMemoryAccess
    };
    const func_ptr = instance.store.getFunctionPtr(func_addr) catch return 1;

    // Type check: canonical type ID with structural fallback
    if (!instance.matchesCallIndirectType(type_idx, func_ptr))
        return 1; // MismatchedSignatures → Trap

    const n_args = func_ptr.params.len;
    const n_results = func_ptr.results.len;

    // Collect args from register file
    const data = unpackDataWord(data_raw);
    var call_args: [8]u64 = undefined;
    if (n_args > 0) call_args[0] = regs[data.r0];
    if (n_args > 1) call_args[1] = regs[data.r1];
    if (n_args > 2) call_args[2] = regs[data.r2];
    if (n_args > 3) call_args[3] = regs[data.r3];
    if (n_args > 4 and data2_raw != 0) {
        const d2 = unpackDataWord(data2_raw);
        if (n_args > 4) call_args[4] = regs[d2.r0];
        if (n_args > 5) call_args[5] = regs[d2.r1];
        if (n_args > 6) call_args[6] = regs[d2.r2];
        if (n_args > 7) call_args[7] = regs[d2.r3];
    }

    // Fast path: JIT-compiled callee
    if (func_ptr.subtype == .wasm_function) {
        const wf = &func_ptr.subtype.wasm_function;
        if (wf.jit_code) |jc| {
            if (wf.reg_ir) |reg| {
                const base = vm.reg_ptr;
                const needed: usize = reg.reg_count + 4; // +4: mem cache + VM/inst ptrs
                if (base + needed > vm_mod.REG_STACK_SIZE) return 2;
                const callee_regs = vm.reg_stack[base .. base + needed];
                vm.reg_ptr = base + needed;

                for (call_args[0..n_args], 0..) |arg, i| callee_regs[i] = arg;
                for (n_args..reg.local_count) |i| callee_regs[i] = 0;

                // Save/restore guard page recovery for nested JIT calls
                const guard_mod = @import("guard.zig");
                const saved_recovery = guard_mod.getRecovery().*;
                if (jc.oob_exit_offset != 0) {
                    const buf_start = @intFromPtr(jc.buf.ptr);
                    guard_mod.setRecovery(.{
                        .oob_exit_pc = buf_start + jc.oob_exit_offset,
                        .jit_code_start = buf_start,
                        .jit_code_end = buf_start + jc.code_len,
                        .active = true,
                    });
                }

                const err = jc.entry(callee_regs.ptr, vm_opaque, instance_opaque);

                guard_mod.setRecovery(saved_recovery);
                vm.reg_ptr = base;
                if (err != 0) return err;

                if (n_results > 0) regs[result_reg] = callee_regs[0];
                return 0;
            }
        }
    }

    // Slow path: full callFunction
    var call_results: [1]u64 = .{0};
    vm.callFunction(instance, func_ptr, call_args[0..n_args], call_results[0..@min(n_results, 1)]) catch |e| {
        return wasmErrorToCode(e);
    };
    if (n_results > 0) regs[result_reg] = call_results[0];
    return 0;
}

fn wasmErrorToCode(err: vm_mod.WasmError) u64 {
    return switch (err) {
        error.Trap => 1,
        error.StackOverflow => 2,
        error.DivisionByZero => 3,
        error.IntegerOverflow => 4,
        error.Unreachable => 5,
        error.OutOfBoundsMemoryAccess => 6,
        error.WasmException => 7,
        else => 1, // generic trap
    };
}

// ================================================================
// GC trampoline — called from JIT code for struct operations
// ================================================================

/// Unified GC struct trampoline: handles struct.new, struct.new_default,
/// struct.get/get_s/get_u, struct.set. Returns 0 on success, 1 on error.
pub fn jitGcTrampoline(
    instance_opaque: *anyopaque,
    regs: [*]u64,
    sub_op: u32,
    type_idx: u32,
    rd: u32,
    rs1_or_nfields: u32,
    field_idx: u32,
    data_raw: u64,
) callconv(.c) u64 {
    const gc_mod = @import("gc.zig");
    const module_mod = @import("module.zig");
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));

    switch (sub_op) {
        0x00 => { // struct.new: pop N fields from regs, push ref
            const n_fields: usize = rs1_or_nfields;
            // Unpack field vreg numbers from data_raw
            const data = unpackDataWord(data_raw);
            var field_vals: [8]u64 = undefined;
            if (n_fields > 0) field_vals[0] = regs[data.r0];
            if (n_fields > 1) field_vals[1] = regs[data.r1];
            if (n_fields > 2) field_vals[2] = regs[data.r2];
            if (n_fields > 3) field_vals[3] = regs[data.r3];
            // Note: data2 not passed for now (max 4 fields via single data word)
            // Structs with > 4 fields would need extension
            const addr = instance.store.gc_heap.allocStruct(type_idx, field_vals[0..n_fields]) catch return 1;
            regs[rd] = gc_mod.GcHeap.encodeRef(addr);
        },
        0x01 => { // struct.new_default
            if (type_idx >= instance.module.types.items.len) return 1;
            const n = switch (instance.module.types.items[type_idx].composite) {
                .struct_type => |st| st.fields.len,
                else => return 1,
            };
            var fields_buf: [256]u64 = undefined;
            @memset(fields_buf[0..n], 0);
            const addr = instance.store.gc_heap.allocStruct(type_idx, fields_buf[0..n]) catch return 1;
            regs[rd] = gc_mod.GcHeap.encodeRef(addr);
        },
        0x02 => { // struct.get
            const ref_val = regs[rs1_or_nfields];
            const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return 1;
            const obj = instance.store.gc_heap.getObject(addr) catch return 1;
            const s = switch (obj.*) { .struct_obj => |so| so, else => return 1 };
            if (field_idx >= s.fields.len) return 1;
            regs[rd] = s.fields[field_idx];
        },
        0x03 => { // struct.get_s
            const ref_val = regs[rs1_or_nfields];
            const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return 1;
            const obj = instance.store.gc_heap.getObject(addr) catch return 1;
            const s = switch (obj.*) { .struct_obj => |so| so, else => return 1 };
            if (field_idx >= s.fields.len) return 1;
            const raw: u32 = @truncate(s.fields[field_idx]);
            if (type_idx >= instance.module.types.items.len) return 1;
            const stype: module_mod.StructType = switch (instance.module.types.items[type_idx].composite) {
                .struct_type => |st| st,
                else => return 1,
            };
            if (field_idx >= stype.fields.len) return 1;
            const result: i32 = switch (stype.fields[field_idx].storage) {
                .i8 => @as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw))))),
                .i16 => @as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw))))),
                else => @bitCast(raw),
            };
            regs[rd] = @as(u32, @bitCast(result));
        },
        0x04 => { // struct.get_u
            const ref_val = regs[rs1_or_nfields];
            const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return 1;
            const obj = instance.store.gc_heap.getObject(addr) catch return 1;
            const s = switch (obj.*) { .struct_obj => |so| so, else => return 1 };
            if (field_idx >= s.fields.len) return 1;
            const raw: u32 = @truncate(s.fields[field_idx]);
            if (type_idx >= instance.module.types.items.len) return 1;
            const stype: module_mod.StructType = switch (instance.module.types.items[type_idx].composite) {
                .struct_type => |st| st,
                else => return 1,
            };
            if (field_idx >= stype.fields.len) return 1;
            const result: u32 = switch (stype.fields[field_idx].storage) {
                .i8 => @as(u32, @as(u8, @truncate(raw))),
                .i16 => @as(u32, @as(u16, @truncate(raw))),
                else => raw,
            };
            regs[rd] = result;
        },
        0x05 => { // struct.set: rd=ref_reg, rs1=val_reg, rs2=field_idx
            const ref_val = regs[rd];
            const val = regs[rs1_or_nfields];
            const addr = gc_mod.GcHeap.decodeRef(ref_val) catch return 1;
            const obj = instance.store.gc_heap.getObject(addr) catch return 1;
            const s = switch (obj.*) { .struct_obj => |so| so, else => return 1 };
            if (field_idx >= s.fields.len) return 1;
            s.fields[field_idx] = val;
        },
        else => return 1,
    }
    return 0; // success
}

// ================================================================
// Memory info helper — called from JIT code
// ================================================================

/// Get linear memory base pointer and size.
/// Called from JIT code at function entry and after function calls.
/// Writes base to out[0], size to out[1].
pub fn jitGetMemInfo(instance_opaque: *anyopaque, out: [*]u64) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    const m = instance.getMemory(0) catch {
        out[0] = 0;
        out[1] = 0;
        return;
    };
    out[0] = @intFromPtr(m.data.items.ptr);
    out[1] = m.data.items.len;
}

/// JIT helper: global.get — read a global variable's value.
pub fn jitGlobalGet(instance_opaque: *anyopaque, idx: u32) callconv(.c) u64 {
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    const g = instance.getGlobal(idx) catch return 0;
    return @truncate(g.value);
}

/// JIT helper: global.set — write a value to a global variable.
pub fn jitGlobalSet(instance_opaque: *anyopaque, idx: u32, val: u64) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    const g = instance.getGlobal(idx) catch return;
    g.value = val;
}

/// JIT helper: memory.grow — grow linear memory by n pages.
/// Returns old size in pages on success, or 0xFFFFFFFF (-1 as u32) on failure.
pub fn jitMemGrow(instance_opaque: *anyopaque, pages: u32) callconv(.c) u32 {
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    const m = instance.getMemory(0) catch return 0xFFFFFFFF;
    return m.grow(pages) catch 0xFFFFFFFF;
}

/// JIT helper: memory.fill — fill memory[dst..dst+n] with val.
/// Returns 0 on success, 1 on out-of-bounds.
pub fn jitMemFill(instance_opaque: *anyopaque, dst: u32, val: u32, n: u32) callconv(.c) u32 {
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    const m = instance.getMemory(0) catch return 1;
    m.fill(dst, n, @truncate(val)) catch return 1;
    return 0;
}

/// JIT helper: memory.copy — copy memory[src..src+n] to memory[dst..dst+n].
/// Returns 0 on success, 1 on out-of-bounds.
pub fn jitMemCopy(instance_opaque: *anyopaque, dst: u32, src: u32, n: u32) callconv(.c) u32 {
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    const m = instance.getMemory(0) catch return 1;
    m.copyWithin(dst, src, n) catch return 1;
    return 0;
}

// SIMD trampoline is in vm.zig (needs access to Vm internals)
const jitSimdTrampoline = vm_mod.Vm.jitSimdTrampoline;

// ================================================================
// Public API
// ================================================================

/// Attempt to JIT-compile a register IR function.
/// Returns null if compilation fails (unsupported opcodes, etc.).
/// self_func_idx: module-level function index for inline self-call optimization.
/// Get minimum guaranteed memory bytes from an Instance (for bounds check elision).
pub fn getMinMemoryBytes(instance: *Instance) u32 {
    const mem = instance.getMemory(0) catch return 0;
    return mem.min * mem.page_size;
}

pub fn getUseGuardPages(instance: *Instance) bool {
    const mem = instance.getMemory(0) catch return false;
    return mem.hasGuardPages();
}

/// param_count: number of parameters for the function.
/// osr_target_pc: if non-null, emit an OSR entry that jumps to this IR PC
/// (for back-edge JIT of functions with reentry guards).
pub fn compileFunction(
    alloc: Allocator,
    reg_func: *RegFunc,
    pool64: []const u64,
    self_func_idx: u32,
    param_count: u16,
    result_count: u16,
    trace: ?*trace_mod.TraceConfig,
    min_memory_bytes: u32,
    use_guard_pages: bool,
    osr_target_pc: ?u32,
) ?*JitCode {
    // x86_64 dispatch — delegate to separate backend
    if (builtin.cpu.arch == .x86_64) {
        const x86 = @import("x86.zig");
        return x86.compileFunction(alloc, reg_func, pool64, self_func_idx, param_count, result_count, trace, min_memory_bytes, use_guard_pages, osr_target_pc);
    }

    if (builtin.cpu.arch != .aarch64) return null;

    const trampoline_addr = @intFromPtr(&jitCallTrampoline);
    const mem_info_addr = @intFromPtr(&jitGetMemInfo);
    const global_get_addr = @intFromPtr(&jitGlobalGet);
    const global_set_addr = @intFromPtr(&jitGlobalSet);
    const mem_grow_addr = @intFromPtr(&jitMemGrow);
    const mem_fill_addr = @intFromPtr(&jitMemFill);
    const mem_copy_addr = @intFromPtr(&jitMemCopy);
    const call_indirect_addr = @intFromPtr(&jitCallIndirectTrampoline);
    const reg_ptr_offset: u32 = @intCast(@offsetOf(vm_mod.Vm, "reg_ptr"));

    const gc_trampoline_addr = @intFromPtr(&jitGcTrampoline);

    var compiler = Compiler.init(alloc);
    compiler.min_memory_bytes = min_memory_bytes;
    compiler.use_guard_pages = use_guard_pages;
    compiler.osr_target_pc = osr_target_pc;
    compiler.gc_trampoline_addr = gc_trampoline_addr;
    compiler.jit_fuel_offset = @intCast(@offsetOf(vm_mod.Vm, "jit_fuel"));
    compiler.simd_hi_offset = @intCast(@offsetOf(vm_mod.Vm, "simd_hi"));

    // Dump JIT code before deinit (pc_map still alive, one-shot)
    if (trace) |tc| {
        if (tc.dump_jit_func) |dump_idx| {
            if (dump_idx == self_func_idx) {
                const result = compiler.compile(reg_func, pool64, trampoline_addr, mem_info_addr, global_get_addr, global_set_addr, mem_grow_addr, mem_fill_addr, mem_copy_addr, call_indirect_addr, self_func_idx, param_count, result_count, reg_ptr_offset);
                trace_mod.dumpJitCode(alloc, compiler.code.items, compiler.pc_map.items, self_func_idx);
                tc.dump_jit_func = null;
                compiler.deinit();
                return result;
            }
        }
    }

    defer compiler.deinit();
    return compiler.compile(reg_func, pool64, trampoline_addr, mem_info_addr, global_get_addr, global_set_addr, mem_grow_addr, mem_fill_addr, mem_copy_addr, call_indirect_addr, self_func_idx, param_count, result_count, reg_ptr_offset);
}

// ================================================================
// Instruction cache flush
// ================================================================

// ================================================================
// Tests
// ================================================================

const testing = std.testing;

test "ARM64 instruction encoding" {
    if (builtin.cpu.arch != .aarch64) return;

    // ADD X3, X4, X5
    try testing.expectEqual(@as(u32, 0x8B050083), a64.add64(3, 4, 5));
    // ADD W3, W4, W5
    try testing.expectEqual(@as(u32, 0x0B050083), a64.add32(3, 4, 5));
    // SUB X3, X4, X5
    try testing.expectEqual(@as(u32, 0xCB050083), a64.sub64(3, 4, 5));
    // CMP X3, X4
    try testing.expectEqual(@as(u32, 0xEB04007F), a64.cmp64(3, 4));
    // CMP W3, W4
    try testing.expectEqual(@as(u32, 0x6B04007F), a64.cmp32(3, 4));
    // RET
    try testing.expectEqual(@as(u32, 0xD65F03C0), a64.ret_());
    // MOV X3, X4 (ORR X3, XZR, X4)
    try testing.expectEqual(@as(u32, 0xAA0403E3), a64.mov64(3, 4));
    // MOVZ X3, #42
    try testing.expectEqual(@as(u32, 0xD2800543), a64.movz64(3, 42, 0));
    // NOP
    try testing.expectEqual(@as(u32, 0xD503201F), a64.nop());
    // BLR X8
    try testing.expectEqual(@as(u32, 0xD63F0100), a64.blr(8));
    // STP X29, X30, [SP, #-16]! (imm7 = -16/8 = -2)
    try testing.expectEqual(@as(u32, 0xA9BF7BFD), a64.stpPre(29, 30, 31, -2));
    // CSET W8, le = CSINC W8, WZR, WZR, gt
    // gt = 0b1100, Rn=WZR(31), Rm=WZR(31)
    try testing.expectEqual(@as(u32, 0x1A9FC7E8), a64.cset32(8, .le));
    // CSET W0, eq = CSINC W0, WZR, WZR, ne
    try testing.expectEqual(@as(u32, 0x1A9F17E0), a64.cset32(0, .eq));
}

test "virtual register mapping" {
    if (builtin.cpu.arch != .aarch64) return;

    // r0-r4 → x22-x26 (callee-saved)
    try testing.expectEqual(@as(u5, 22), vregToPhys(0).?);
    try testing.expectEqual(@as(u5, 26), vregToPhys(4).?);
    // r5-r11 → x9-x15 (caller-saved)
    try testing.expectEqual(@as(u5, 9), vregToPhys(5).?);
    try testing.expectEqual(@as(u5, 15), vregToPhys(11).?);
    // r12-r13 → x20-x21 (callee-saved, repurposed from VM/INST ptrs)
    try testing.expectEqual(@as(u5, 20), vregToPhys(12).?);
    try testing.expectEqual(@as(u5, 21), vregToPhys(13).?);
    // r14-r19 → x2-x7 (caller-saved)
    try testing.expectEqual(@as(u5, 2), vregToPhys(14).?);
    try testing.expectEqual(@as(u5, 7), vregToPhys(19).?);
    // r20-r22 → x0, x1, x17 (caller-saved)
    try testing.expectEqual(@as(u5, 0), vregToPhys(20).?);
    try testing.expectEqual(@as(u5, 1), vregToPhys(21).?);
    try testing.expectEqual(@as(u5, 17), vregToPhys(22).?);
    // r23+ → null (spill)
    try testing.expectEqual(@as(?u5, null), vregToPhys(23));
}

test "compile and execute constant return" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // Build a simple RegFunc: CONST32 r0, 42; RETURN r0
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 0, .rs1 = 0, .operand = 42 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 1,
        .local_count = 0,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // Execute: regs[0] should become 42 (needs reg_count+4 slots)
    var regs: [5]u64 = .{ 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, undefined);
    try testing.expectEqual(@as(u64, 0), result); // success
    try testing.expectEqual(@as(u64, 42), regs[0]); // result
}

test "compile and execute i32 add" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // add(a, b) = a + b
    // Params: r0 = a, r1 = b
    // CONST32 not needed — args pre-loaded in r0, r1
    // i32.add r2, r0, r1  (opcode 0x6A)
    // RETURN r2
    var code = [_]RegInstr{
        .{ .op = 0x6A, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // rs2 = 1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    var regs: [7]u64 = .{ 10, 32, 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, undefined);
    try testing.expectEqual(@as(u64, 0), result);
    try testing.expectEqual(@as(u64, 42), regs[0]); // 10 + 32 = 42
}

test "compile and execute branch (LE_S + BR_IF_NOT)" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // if (n <= 1) return 100 else return 200
    var code = [_]RegInstr{
        // [0] LE_S_I32 r2, r0, 1
        .{ .op = regalloc_mod.OP_LE_S_I32, .rd = 2, .rs1 = 0, .operand = 1 },
        // [1] BR_IF_NOT r2, target=4
        .{ .op = regalloc_mod.OP_BR_IF_NOT, .rd = 2, .rs1 = 0, .operand = 4 },
        // [2] CONST32 r1, 100  (then: base case)
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 100 },
        // [3] RETURN r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
        // [4] CONST32 r1, 200  (else: recursive case)
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 200 },
        // [5] RETURN r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 1,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // n=0: 0 <= 1 is true → return 100
    {
        var regs: [7]u64 = .{ 0, 0, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 100), regs[0]);
    }

    // n=1: 1 <= 1 is true → return 100
    {
        var regs: [7]u64 = .{ 1, 0, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 100), regs[0]);
    }

    // n=10: 10 <= 1 is false → return 200
    {
        var regs: [7]u64 = .{ 10, 0, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 200), regs[0]);
    }
}

test "compile and execute i32 division" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // div_s(a, b) = a / b
    var code = [_]RegInstr{
        .{ .op = 0x6D, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.div_s r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // 10 / 3 = 3
    {
        var regs: [7]u64 = .{ 10, 3, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 3), regs[0]);
    }

    // Division by zero → error code 3
    {
        var regs: [7]u64 = .{ 10, 0, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 3), result); // DivisionByZero
    }

    // -7 / 2 = -3 (signed)
    {
        const neg7: u32 = @bitCast(@as(i32, -7));
        var regs: [7]u64 = .{ neg7, 2, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        const expected: u32 = @bitCast(@as(i32, -3));
        try testing.expectEqual(@as(u64, expected), regs[0]);
    }
}

test "compile and execute i32 remainder" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // rem_s(a, b) = a % b
    var code = [_]RegInstr{
        .{ .op = 0x6F, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.rem_s r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // 10 % 3 = 1
    {
        var regs: [7]u64 = .{ 10, 3, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 1), regs[0]);
    }

    // Division by zero → error code 3
    {
        var regs: [7]u64 = .{ 10, 0, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 3), result); // DivisionByZero
    }
}

test "compile and execute memory load/store" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;

    // Set up a Store with one memory page (64KB)
    var store = store_mod.Store.init(alloc);
    defer store.deinit();
    const mem_idx = try store.addMemory(1, null, 65536, false, false);
    const mem = try store.getMemory(mem_idx);
    try mem.allocateInitial();

    // Pre-fill memory: write 42 at byte offset 16
    try mem.write(u32, 16, 0, 42);
    // Write 0xDEADBEEF at byte offset 100
    try mem.write(u32, 100, 0, 0xDEADBEEF);

    // Create a minimal Instance with memaddrs pointing to our memory.
    // Instance.init requires a Module, but we only need getMemory to work.
    // Use a struct hack: manually set up the necessary fields.
    const module_mod = @import("module.zig");
    var dummy_module = module_mod.Module.init(alloc, &.{});
    var inst = Instance.init(alloc, &store, &dummy_module);
    defer inst.deinit();
    try inst.memaddrs.append(alloc, mem_idx);

    // Verify jitGetMemInfo works with our instance
    var info: [2]u64 = .{ 0, 0 };
    jitGetMemInfo(@ptrCast(&inst), &info);
    try testing.expect(info[0] != 0); // base pointer
    try testing.expectEqual(@as(u64, 64 * 1024), info[1]); // 1 page = 64KB

    // Build a RegFunc that loads from memory:
    // r0 = base addr (param), load i32 at r0+16, return result
    var code = [_]RegInstr{
        // [0] i32.load r1, [r0 + 16]
        .{ .op = 0x28, .rd = 1, .rs1 = 0, .operand = 16 },
        // [1] RETURN r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 2,
        .local_count = 1,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // Execute: load from addr=0, offset=16 → should read 42
    // regs needs +4 extra for memory cache + VM/instance pointers
    var regs: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, @ptrCast(&inst));
    try testing.expectEqual(@as(u64, 0), result); // success
    try testing.expectEqual(@as(u64, 42), regs[0]); // loaded value

    // Execute: load from addr=84, offset=16 → addr+offset=100 → 0xDEADBEEF
    {
        var regs2: [6]u64 = .{ 84, 0, 0, 0, 0, 0 };
        const result2 = jit_code.entry(&regs2, undefined, @ptrCast(&inst));
        try testing.expectEqual(@as(u64, 0), result2);
        try testing.expectEqual(@as(u64, 0xDEADBEEF), regs2[0]);
    }

    // Out of bounds: addr=65535, offset=16 → 65551 > 65536
    {
        var regs3: [6]u64 = .{ 65535, 0, 0, 0, 0, 0 };
        const result3 = jit_code.entry(&regs3, undefined, @ptrCast(&inst));
        try testing.expectEqual(@as(u64, 6), result3); // OutOfBoundsMemoryAccess
    }
}

test "compile and execute memory store then load" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;

    var store = store_mod.Store.init(alloc);
    defer store.deinit();
    const mem_idx = try store.addMemory(1, null, 65536, false, false);
    const mem = try store.getMemory(mem_idx);
    try mem.allocateInitial();

    const module_mod = @import("module.zig");
    var dummy_module = module_mod.Module.init(alloc, &.{});
    var inst = Instance.init(alloc, &store, &dummy_module);
    defer inst.deinit();
    try inst.memaddrs.append(alloc, mem_idx);

    // Function: store r0 at addr=0, offset=0, then load it back
    // r0 = value (param), r1 = addr 0 (const)
    var code = [_]RegInstr{
        // [0] CONST32 r1, 0
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 0 },
        // [1] i32.store [r1 + 0] = r0  (rd=value, rs1=base)
        .{ .op = 0x36, .rd = 0, .rs1 = 1, .operand = 0 },
        // [2] i32.load r2, [r1 + 0]
        .{ .op = 0x28, .rd = 2, .rs1 = 1, .operand = 0 },
        // [3] RETURN r2
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 1,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // Store 99, then load it back
    var regs: [7]u64 = .{ 99, 0, 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, @ptrCast(&inst));
    try testing.expectEqual(@as(u64, 0), result);
    try testing.expectEqual(@as(u64, 99), regs[0]);

    // Verify memory was actually written
    const val = try mem.read(u32, 0, 0);
    try testing.expectEqual(@as(u32, 99), val);
}

test "const-addr memory load elides bounds check" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;

    var store = store_mod.Store.init(alloc);
    defer store.deinit();
    const mem_idx = try store.addMemory(1, null, 65536, false, false);
    const mem = try store.getMemory(mem_idx);
    try mem.allocateInitial();

    // Write test values at const addresses
    try mem.write(u32, 0, 0, 111);
    try mem.write(u32, 100, 0, 222);

    const module_mod = @import("module.zig");
    var dummy_module = module_mod.Module.init(alloc, &.{});
    var inst = Instance.init(alloc, &store, &dummy_module);
    defer inst.deinit();
    try inst.memaddrs.append(alloc, mem_idx);

    // Function: two const-addr loads, add results, return
    // r0 = const 0, r1 = load [r0+0], r2 = const 100, r3 = load [r2+0]
    // r4 = r1 + r3, return r4
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 0, .rs1 = 0, .operand = 0 },
        .{ .op = 0x28, .rd = 1, .rs1 = 0, .operand = 0 }, // i32.load [r0+0]
        .{ .op = regalloc_mod.OP_CONST32, .rd = 2, .rs1 = 0, .operand = 100 },
        .{ .op = 0x28, .rd = 3, .rs1 = 2, .operand = 0 }, // i32.load [r2+0]
        .{ .op = 0x6A, .rd = 4, .rs1 = 1, .rs2_field = 3 }, // i32.add r4 = r1 + r3
        .{ .op = regalloc_mod.OP_RETURN, .rd = 4, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 5,
        .local_count = 0,
        .alloc = alloc,
    };

    // Compile with min_memory_bytes = 65536 (1 page, all const addrs safe)
    const jit_opt = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 65536, false, null) orelse
        return error.CompilationFailed;
    defer jit_opt.deinit(alloc);

    // Compile without optimization (min_memory_bytes = 0)
    const jit_noopt = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_noopt.deinit(alloc);

    // Both should produce correct result
    var regs1: [9]u64 = .{0} ** 9;
    const r1 = jit_opt.entry(&regs1, undefined, @ptrCast(&inst));
    try testing.expectEqual(@as(u64, 0), r1);
    try testing.expectEqual(@as(u64, 333), regs1[0]); // 111 + 222

    var regs2: [9]u64 = .{0} ** 9;
    const r2 = jit_noopt.entry(&regs2, undefined, @ptrCast(&inst));
    try testing.expectEqual(@as(u64, 0), r2);
    try testing.expectEqual(@as(u64, 333), regs2[0]);

    // Optimized version should have fewer instructions (bounds checks elided)
    try testing.expect(jit_opt.code_len < jit_noopt.code_len);
}

test "wasmErrorToCode maps WasmException to distinct code" {
    // WasmException must not collapse to generic trap (code 1).
    // Code 7 allows JIT callers to propagate exceptions correctly.
    const code = wasmErrorToCode(error.WasmException);
    try testing.expect(code != 1); // must NOT be generic trap
    try testing.expectEqual(@as(u64, 7), code);

    // Verify all specific error codes are distinct
    try testing.expectEqual(@as(u64, 1), wasmErrorToCode(error.Trap));
    try testing.expectEqual(@as(u64, 2), wasmErrorToCode(error.StackOverflow));
    try testing.expectEqual(@as(u64, 3), wasmErrorToCode(error.DivisionByZero));
    try testing.expectEqual(@as(u64, 4), wasmErrorToCode(error.IntegerOverflow));
    try testing.expectEqual(@as(u64, 5), wasmErrorToCode(error.Unreachable));
    try testing.expectEqual(@as(u64, 6), wasmErrorToCode(error.OutOfBoundsMemoryAccess));
}

test "CMP+B.cond fusion saves one instruction per compare-and-branch" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // if (a == b) return 42 else return 99
    // Pattern: i32.eq (r0, r1 -> r2) + BR_IF r2 — should fuse to CMP + B.eq
    var code = [_]RegInstr{
        // [0] i32.eq r2, r0, r1
        .{ .op = 0x46, .rd = 2, .rs1 = 0, .rs2_field = 1 },
        // [1] BR_IF r2, target=4
        .{ .op = regalloc_mod.OP_BR_IF, .rd = 2, .rs1 = 0, .operand = 4 },
        // [2] CONST32 r1, 99  (else: not equal)
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 99 },
        // [3] RETURN r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
        // [4] CONST32 r1, 42  (then: equal)
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 42 },
        // [5] RETURN r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
    };

    // Also compile the same logic WITHOUT fusion opportunity
    // (use different rd for CMP and BR_IF so they can't fuse)
    var code_nofuse = [_]RegInstr{
        // [0] i32.eq r2, r0, r1
        .{ .op = 0x46, .rd = 2, .rs1 = 0, .rs2_field = 1 },
        // [1] BR_IF r3, target=4  — different rd, can't fuse
        .{ .op = regalloc_mod.OP_BR_IF, .rd = 3, .rs1 = 0, .operand = 4 },
        // [2] CONST32 r1, 99
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 99 },
        // [3] RETURN r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
        // [4] CONST32 r1, 42
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 42 },
        // [5] RETURN r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
    };

    var reg_func = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 4, .local_count = 2, .alloc = alloc };
    var reg_func_nofuse = RegFunc{ .code = &code_nofuse, .pool64 = &.{}, .reg_count = 4, .local_count = 2, .alloc = alloc };

    const jit_fused = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_fused.deinit(alloc);

    const jit_nofuse = compileFunction(alloc, &reg_func_nofuse, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_nofuse.deinit(alloc);

    // Functional: a == b → 42
    {
        var regs: [8]u64 = .{ 5, 5, 0, 0, 0, 0, 0, 0 };
        const result = jit_fused.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 42), regs[0]);
    }

    // Functional: a != b → 99
    {
        var regs: [8]u64 = .{ 5, 7, 0, 0, 0, 0, 0, 0 };
        const result = jit_fused.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 99), regs[0]);
    }

    // Fusion check: fused code should be shorter (saves 1 insn = 4 bytes per fusion)
    try testing.expect(jit_fused.code_len < jit_nofuse.code_len);
}

test "constant materialization uses MOVN for negative values" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // Return -1 as 32-bit constant (0xFFFFFFFF).
    // With MOVN: MOVN Wd, #0 (1 insn). Without: MOVZ + MOVK (2 insns).
    var code_neg = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 0, .rs1 = 0, .operand = 0xFFFFFFFF },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    // Return 0x10001 (always needs 2 insns: MOVZ + MOVK)
    var code_pos = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 0, .rs1 = 0, .operand = 0x10001 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 0, .rs1 = 0, .operand = 0 },
    };

    var rf_neg = RegFunc{ .code = &code_neg, .pool64 = &.{}, .reg_count = 1, .local_count = 1, .alloc = alloc };
    var rf_pos = RegFunc{ .code = &code_pos, .pool64 = &.{}, .reg_count = 1, .local_count = 1, .alloc = alloc };

    const jit_neg = compileFunction(alloc, &rf_neg, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_neg.deinit(alloc);

    const jit_pos = compileFunction(alloc, &rf_pos, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit_pos.deinit(alloc);

    // Functional: -1 as u32
    {
        var regs: [5]u64 = .{ 0, 0, 0, 0, 0 };
        _ = jit_neg.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0xFFFFFFFF), regs[0]);
    }

    // MOVN optimization: -1 should use fewer bytes than 0x10001
    try testing.expect(jit_neg.code_len < jit_pos.code_len);
}

test "computeMagicU32 correctness" {
    // d=10: magic=0xCCCCCCCD, shift=35
    {
        const m = Compiler.computeMagicU32(10).?;
        try testing.expectEqual(@as(u32, 0xCCCCCCCD), m.magic);
        try testing.expectEqual(@as(u6, 35), m.shift);
        // Verify for representative values
        for ([_]u32{ 0, 1, 9, 10, 99, 100, 255, 1000, 0xFFFFFFFF }) |n| {
            const expected = n / 10;
            const actual: u32 = @truncate((@as(u64, n) * m.magic) >> m.shift);
            try testing.expectEqual(expected, actual);
        }
    }
    // d=3: magic=0xAAAAAAAB, shift=33
    {
        const m = Compiler.computeMagicU32(3).?;
        try testing.expectEqual(@as(u32, 0xAAAAAAAB), m.magic);
        try testing.expectEqual(@as(u6, 33), m.shift);
        for ([_]u32{ 0, 1, 2, 3, 100, 0xFFFFFFFF }) |n| {
            const expected = n / 3;
            const actual: u32 = @truncate((@as(u64, n) * m.magic) >> m.shift);
            try testing.expectEqual(expected, actual);
        }
    }
    // d=5: magic=0xCCCCCCCD, shift=34
    {
        const m = Compiler.computeMagicU32(5).?;
        try testing.expectEqual(@as(u32, 0xCCCCCCCD), m.magic);
        try testing.expectEqual(@as(u6, 34), m.shift);
    }
    // d=1: should return null (identity division)
    try testing.expect(Compiler.computeMagicU32(1) == null);
    // d=0: should return null
    try testing.expect(Compiler.computeMagicU32(0) == null);
    // Powers of 2: should return null (handled by LSR)
    try testing.expect(Compiler.computeMagicU32(2) == null);
    try testing.expect(Compiler.computeMagicU32(4) == null);
    try testing.expect(Compiler.computeMagicU32(256) == null);
}

test "div-by-constant JIT: unsigned i32.div_u by known 10" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // r1 = 10 (const); r2 = r0 / r1 (div_u with known const divisor)
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 10 },
        .{ .op = 0x6E, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.div_u r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var rf = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 3, .local_count = 1, .alloc = alloc };
    const jit = compileFunction(alloc, &rf, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit.deinit(alloc);

    for ([_]u32{ 0, 1, 9, 10, 99, 100, 12345, 0xFFFFFFFF }) |n| {
        var regs: [7]u64 = .{ n, 0, 0, 0, 0, 0, 0 };
        const result = jit.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result); // no error
        try testing.expectEqual(@as(u64, n / 10), regs[0]);
    }
}

test "div-by-constant JIT: power-of-2 divisor uses LSR" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    // r1 = 8 (power of 2); r2 = r0 / r1
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 8 },
        .{ .op = 0x6E, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.div_u r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var rf = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 3, .local_count = 1, .alloc = alloc };
    const jit = compileFunction(alloc, &rf, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit.deinit(alloc);

    for ([_]u32{ 0, 7, 8, 64, 100, 0xFFFFFFFF }) |n| {
        var regs: [7]u64 = .{ n, 0, 0, 0, 0, 0, 0 };
        const result = jit.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, n / 8), regs[0]);
    }
}

test "rem-by-constant JIT: unsigned i32.rem_u by known 10" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 10 },
        .{ .op = 0x70, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.rem_u r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var rf = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 3, .local_count = 1, .alloc = alloc };
    const jit = compileFunction(alloc, &rf, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit.deinit(alloc);

    for ([_]u32{ 0, 1, 9, 10, 99, 100, 12345, 0xFFFFFFFF }) |n| {
        var regs: [7]u64 = .{ n, 0, 0, 0, 0, 0, 0 };
        const result = jit.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, n % 10), regs[0]);
    }
}

test "rem-by-constant JIT: power-of-2 divisor uses AND" {
    if (builtin.cpu.arch != .aarch64) return;

    const alloc = testing.allocator;
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 16 },
        .{ .op = 0x70, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.rem_u r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var rf = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 3, .local_count = 1, .alloc = alloc };
    const jit = compileFunction(alloc, &rf, &.{}, 0, 0, 1, null, 0, false, null) orelse
        return error.CompilationFailed;
    defer jit.deinit(alloc);

    for ([_]u32{ 0, 1, 15, 16, 31, 32, 255, 0xFFFFFFFF }) |n| {
        var regs: [7]u64 = .{ n, 0, 0, 0, 0, 0, 0 };
        const result = jit.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, n % 16), regs[0]);
    }
}

test "NEON instruction encoding — v128 ops" {
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    // LDR Q0, [X1, #0] = 0x3DC00020
    try testing.expectEqual(@as(u32, 0x3DC00020), a64.ldrQ(0, 1, 0));
    // LDR Q2, [X3, #16] = offset 16/16=1 → 0x3DC00462
    try testing.expectEqual(@as(u32, 0x3DC00462), a64.ldrQ(2, 3, 1));
    // STR Q0, [X1, #0] = 0x3D800020
    try testing.expectEqual(@as(u32, 0x3D800020), a64.strQ(0, 1, 0));
    // MOVI V0.2D, #0 = 0x6F00E400
    try testing.expectEqual(@as(u32, 0x6F00E400), a64.moviV2d_zero(0));
    // FADD V0.4S, V1.4S, V2.4S = 0x4E22D420
    try testing.expectEqual(@as(u32, 0x4E22D420), a64.faddV4s(0, 1, 2));
    // FMUL V3.4S, V4.4S, V5.4S = 0x6E25DC83
    try testing.expectEqual(@as(u32, 0x6E25DC83), a64.fmulV4s(3, 4, 5));
    // NOT V0.16B, V1.16B = 0x6E205820
    try testing.expectEqual(@as(u32, 0x6E205820), a64.notV16b(0, 1));
}

