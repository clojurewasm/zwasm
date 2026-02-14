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

    pub fn deinit(self: *JitCode, alloc: Allocator) void {
        std.posix.munmap(self.buf);
        alloc.destroy(self);
    }
};

/// Returns true if JIT compilation is supported on the current CPU architecture.
pub fn jitSupported() bool {
    return builtin.cpu.arch == .aarch64 or builtin.cpu.arch == .x86_64;
}

/// Hot function call threshold — JIT after this many calls.
pub const HOT_THRESHOLD: u32 = 10;

/// Back-edge threshold — JIT after this many loop iterations in a single call.
pub const BACK_EDGE_THRESHOLD: u32 = 1000;

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
                .vs => .vs,
                .vc => .vc,
            };
        }
    };

    /// Load a 64-bit immediate into register using MOVZ + MOVK sequence.
    fn loadImm64(rd: u5, value: u64) [4]u32 {
        var instrs: [4]u32 = undefined;
        var count: usize = 0;
        const w0: u16 = @truncate(value);
        const w1: u16 = @truncate(value >> 16);
        const w2: u16 = @truncate(value >> 32);
        const w3: u16 = @truncate(value >> 48);

        instrs[0] = movz64(rd, w0, 0);
        count = 1;
        if (w1 != 0) {
            instrs[count] = movk64(rd, w1, 1);
            count += 1;
        }
        if (w2 != 0) {
            instrs[count] = movk64(rd, w2, 2);
            count += 1;
        }
        if (w3 != 0) {
            instrs[count] = movk64(rd, w3, 3);
            count += 1;
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

    // --- NEON/AdvSIMD (for popcnt) ---

    /// CNT V<d>.8B, V<n>.8B — count set bits per byte (8-bit lanes)
    fn cntV8b(vd: u5, vn: u5) u32 {
        return 0x0E205800 | (@as(u32, vn) << 5) | vd;
    }

    /// ADDV Bd, V<n>.8B — add across vector (sum all bytes into scalar)
    fn addvB(vd: u5, vn: u5) u32 {
        return 0x0E31B800 | (@as(u32, vn) << 5) | vd;
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
fn vregToPhys(vreg: u8) ?u5 {
    if (vreg <= 4) return @intCast(vreg + 22); // x22-x26 (callee-saved)
    if (vreg <= 11) return @intCast(vreg - 5 + 9); // x9-x15 (caller-saved)
    if (vreg <= 13) return @intCast(vreg - 12 + 20); // x20-x21 (callee-saved)
    if (vreg <= 19) return @intCast(vreg - 14 + 2); // x2-x7 (caller-saved)
    return null; // spill to memory
}

/// Maximum virtual registers mappable to physical registers.
const MAX_PHYS_REGS: u8 = 20; // 5 callee + 7 caller + 2 callee + 6 caller

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
    pool64: []const u64,
    has_memory: bool,
    has_self_call: bool,
    self_func_idx: u32,
    param_count: u16,
    result_count: u16,
    reg_ptr_offset: u32,
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
    scratch_vreg: ?u8,
    /// FP register cache: maps D2-D7 to vregs holding f64 values.
    /// fp_dreg[i] = vreg whose f64 value is in D(i+2), null if register free.
    /// Allows FP operations to use D registers directly, avoiding GPR↔FPR round-trips.
    fp_dreg: [6]?u8,
    /// True when the D register value has not been written back to GPR/vreg array.
    fp_dreg_dirty: [6]bool,
    /// True when vm_ptr is cached in x20 (only when reg_count <= 12 and has self-calls).
    vm_ptr_cached: bool,
    /// True when inst_ptr is cached in x21 (only when reg_count <= 13 and has self-calls).
    inst_ptr_cached: bool,
    /// Live vreg bitmap at current call site (set by spillCallerSavedLive).
    /// Bit N = 1 means vreg N is live and must be spilled/reloaded across the call.
    call_live_set: u32,
    /// Index of the shared error epilogue in the code array (for signal handler recovery).
    shared_exit_idx: u32,
    /// True when the memory has guard pages — skip explicit bounds checks.
    use_guard_pages: bool,

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
            .pool64 = &.{},
            .has_memory = false,
            .has_self_call = false,
            .self_func_idx = 0,
            .param_count = 0,
            .result_count = 0,
            .reg_ptr_offset = 0,
            .min_memory_bytes = 0,
            .prologue_load_mask = 0xFFFFF, // default: load all (20 vregs)
            .known_consts = .{null} ** 128,
            .written_vregs = 0,
            .scratch_vreg = null,
            .fp_dreg = .{null} ** 6,
            .fp_dreg_dirty = .{false} ** 6,
            .vm_ptr_cached = false,
            .inst_ptr_cached = false,
            .call_live_set = 0,
            .shared_exit_idx = 0,
            .use_guard_pages = false,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.code.deinit(self.alloc);
        self.pc_map.deinit(self.alloc);
        self.patches.deinit(self.alloc);
        self.error_stubs.deinit(self.alloc);
    }

    fn emit(self: *Compiler, inst: u32) void {
        self.code.append(self.alloc, inst) catch {};
    }

    fn currentIdx(self: *const Compiler) u32 {
        return @intCast(self.code.items.len);
    }

    /// Load virtual register value into physical register.
    /// If vreg maps to a physical reg, emit MOV. Otherwise, load from memory.
    fn loadVreg(self: *Compiler, dst: u5, vreg: u8) void {
        if (vregToPhys(vreg)) |phys| {
            if (phys != dst) self.emit(a64.mov64(dst, phys));
        } else {
            self.emit(a64.ldr64(dst, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    /// Store value from physical register to virtual register.
    fn storeVreg(self: *Compiler, vreg: u8, src: u5) void {
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
    fn getOrLoad(self: *Compiler, vreg: u8, scratch: u5) u5 {
        if (vregToPhys(vreg)) |phys| return phys;
        // Check FP D-register cache — if value is only in a D-reg, materialize to GPR
        if (self.fpCacheFind(vreg)) |slot| {
            if (self.fp_dreg_dirty[slot]) {
                const dreg = fpSlotToDreg(slot);
                self.emit(a64.fmovToGp64(scratch, dreg));
                // Write back to memory for consistency
                self.emit(a64.str64(scratch, REGS_PTR, @as(u16, vreg) * 8));
                self.fp_dreg_dirty[slot] = false;
                if (scratch == SCRATCH) self.scratch_vreg = vreg;
                return scratch;
            }
        }
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
    fn destReg(vreg: u8) u5 {
        return vregToPhys(vreg) orelse SCRATCH;
    }

    // --- FP D-register cache (D2-D7) ---

    /// Number of FP cache registers (D2-D7).
    const FP_CACHE_SIZE = 6;

    /// Convert cache slot index (0-5) to ARM64 D register number (2-7).
    fn fpSlotToDreg(slot: u3) u5 {
        return @as(u5, slot) + 2;
    }

    /// Find which D-register cache slot holds a vreg's f64 value.
    /// Returns the slot index (0-5) or null if not cached.
    fn fpCacheFind(self: *Compiler, vreg: u8) ?u3 {
        for (0..FP_CACHE_SIZE) |i| {
            if (self.fp_dreg[i]) |cached| {
                if (cached == vreg) return @intCast(i);
            }
        }
        return null;
    }

    /// Allocate a D-register cache slot for a vreg. Evicts LRU (slot 0) if full.
    /// Returns the slot index (0-5).
    fn fpCacheAlloc(self: *Compiler) u3 {
        // Find a free slot
        for (0..FP_CACHE_SIZE) |i| {
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

    /// Evict all dirty FP cache entries. Called before BLR, branch targets, calls.
    fn fpCacheEvictAll(self: *Compiler) void {
        for (0..FP_CACHE_SIZE) |i| {
            self.fpCacheEvictSlot(i);
        }
    }

    /// Invalidate a vreg in the FP cache (without write-back).
    /// Called when a vreg is overwritten via GPR (e.g., storeVreg for integer result).
    fn fpCacheInvalidate(self: *Compiler, vreg: u8) void {
        if (self.fpCacheFind(vreg)) |slot| {
            // Value overwritten in GPR — D-reg copy is stale
            self.fp_dreg[slot] = null;
            self.fp_dreg_dirty[slot] = false;
        }
    }

    /// Load an f64 vreg into a D-register. Returns the D register number (2-7).
    /// If already cached, returns the existing D register. Otherwise allocates one.
    fn fpLoadToDreg(self: *Compiler, vreg: u8) u5 {
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
    fn fpAllocResult(self: *Compiler, vreg: u8) u5 {
        // If vreg already cached, reuse slot (overwrite is fine)
        if (self.fpCacheFind(vreg)) |slot| {
            self.fp_dreg_dirty[slot] = true;
            return fpSlotToDreg(slot);
        }
        const slot = self.fpCacheAlloc();
        const dreg = fpSlotToDreg(slot);
        self.fp_dreg[slot] = vreg;
        self.fp_dreg_dirty[slot] = true;
        return dreg;
    }

    /// Materialize an FP-cached vreg to GPR. Used when non-FP code needs the value.
    fn fpMaterializeToGpr(self: *Compiler, vreg: u8) void {
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

    /// Load VM pointer from memory slot into dst register.
    fn emitLoadVmPtr(self: *Compiler, dst: u5) void {
        self.emit(a64.ldr64(dst, REGS_PTR, @intCast((@as(u32, self.reg_count) + 2) * 8)));
    }

    /// Load instance pointer from memory slot into dst register.
    fn emitLoadInstPtr(self: *Compiler, dst: u5) void {
        self.emit(a64.ldr64(dst, REGS_PTR, @intCast((@as(u32, self.reg_count) + 3) * 8)));
    }

    /// Spill caller-saved virtual regs (r5-r11 → x9-x15, r14-r19 → x2-x7) to memory.
    /// Callee-saved regs (r0-r4 → x22-x26, r12-r13 → x20-x21) are preserved.
    fn spillCallerSaved(self: *Compiler) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        for (5..max) |i| {
            const vreg: u8 = @intCast(i);
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
    fn spillVregIfCalleeSaved(self: *Compiler, vreg: u8) void {
        if (vregToPhys(vreg)) |phys| {
            // Caller-saved ranges: x9-x15 (vregs 5-11), x2-x7 (vregs 14-19)
            if ((phys >= 9 and phys <= 15) or (phys >= 2 and phys <= 7)) return;
            // Callee-saved: spill to make visible to trampoline
            self.emit(a64.str64(phys, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    /// Reload caller-saved virtual regs from memory (after function calls).
    /// Callee-saved regs (r0-r4 → x22-x26, r12-r13 → x20-x21) are preserved across BLR.
    fn reloadCallerSaved(self: *Compiler) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        for (5..max) |i| {
            const vreg: u8 = @intCast(i);
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
            const vreg: u8 = @intCast(i);
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
                const op_low: u8 = @truncate(instr.operand);
                const op_high: u8 = @truncate(instr.operand >> 8);
                if (op_low != 0) markCallerSavedUse(&live, &resolved, op_low);
                if (op_high != 0) markCallerSavedUse(&live, &resolved, op_high);
                continue;
            }

            // Check uses first (rs1, rs2) — if used before defined, vreg is live
            // Note: OP_CALL rs1 = n_args (not a vreg), skip it.
            // OP_CALL_INDIRECT rs1 = elem_idx_reg (IS a vreg), don't skip.
            if (instr.op != regalloc_mod.OP_CALL) {
                markCallerSavedUse(&live, &resolved, instr.rs1);
            }
            // rs2 for binary ops (op uses operand low byte as rs2)
            if (instrHasRs2(instr)) {
                markCallerSavedUse(&live, &resolved, instr.rs2());
            }

            // Check definition (rd) — if defined before used, vreg is dead
            if (instrDefinesRd(instr)) {
                if (isCallerSavedVreg(instr.rd)) {
                    resolved |= @as(u32, 1) << @as(u5, @intCast(instr.rd));
                }
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
    fn markCallerSavedUse(live: *u32, resolved: *u32, vreg: u8) void {
        if (isCallerSavedVreg(vreg) and (resolved.* & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) {
            live.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
            resolved.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
        }
    }

    /// Check if a vreg is in the caller-saved range (5-11 or 14-19).
    fn isCallerSavedVreg(vreg: u8) bool {
        return (vreg >= 5 and vreg <= 11 and vreg != 12 and vreg != 13) or
            (vreg >= 14 and vreg < MAX_PHYS_REGS);
    }

    /// Check if an instruction has an rs2 operand (binary ops).
    /// Conservative: returns true for all binary arithmetic/comparison ops.
    fn instrHasRs2(instr: RegInstr) bool {
        const op = instr.op;
        return switch (op) {
            // i32/i64/f32/f64 binary ops (comparisons + arithmetic): 0x46-0x8A, 0x92-0x97, 0xA0-0xA6
            0x46...0x8A, 0x92...0x97, 0xA0...0xA6,
            // memory.fill/copy have rs2 in operand
            regalloc_mod.OP_MEMORY_FILL, regalloc_mod.OP_MEMORY_COPY,
            => true,
            else => false,
        };
    }

    /// Check if an instruction defines rd (writes to rd register).
    fn instrDefinesRd(instr: RegInstr) bool {
        const op = instr.op;
        return switch (op) {
            regalloc_mod.OP_NOP, regalloc_mod.OP_DELETED, regalloc_mod.OP_BLOCK_END,
            regalloc_mod.OP_BR, regalloc_mod.OP_BR_IF, regalloc_mod.OP_BR_IF_NOT,
            regalloc_mod.OP_RETURN, regalloc_mod.OP_RETURN_VOID, regalloc_mod.OP_BR_TABLE,
            => false,
            // Memory stores use rd as VALUE source, not a definition
            0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E,
            => false,
            else => true,
        };
    }

    /// Spill only caller-saved vregs that are live after the call.
    /// call_pc: the PC of the OP_CALL instruction in the IR.
    fn spillCallerSavedLive(self: *Compiler, ir: []const RegInstr, call_pc: u32) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        const live_set = computeCallLiveSet(ir, call_pc);
        self.call_live_set = live_set;
        for (5..max) |i| {
            const vreg: u8 = @intCast(i);
            if (vreg == 12 or vreg == 13) continue;
            if (vreg < 128 and (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg)))) == 0) continue;
            // Only spill if vreg is live after the call
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
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
            const vreg: u8 = @intCast(i);
            if (vreg == 12 or vreg == 13) continue;
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Reload caller-saved live vregs, optionally skipping one vreg (result of call).
    fn reloadCallerSavedLiveExcept(self: *Compiler, skip_vreg: ?u8) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        if (max <= 5) return;
        const live_set = self.call_live_set;
        for (5..max) |i| {
            const vreg: u8 = @intCast(i);
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
    fn reloadVreg(self: *Compiler, vreg: u8) void {
        if (vregToPhys(vreg)) |phys| {
            self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    // --- Fast-Path Base Case ---

    /// Emit a fast-path check for self-recursive base cases.
    /// Pattern: IR[0] = cmp_imm(param, const), IR[1] = br_if_not, IR[2] = return param.
    /// Emitted BEFORE the prologue — base cases return without callee-saved save/restore.
    fn emitBaseCaseFastPath(self: *Compiler, ir: []const RegInstr) void {
        if (ir.len < 3) return;
        if (self.result_count == 0) return;

        // Check for self-calls in the IR
        var has_self_call = false;
        for (ir) |instr| {
            if (instr.op == regalloc_mod.OP_CALL and instr.operand == self.self_func_idx) {
                has_self_call = true;
                break;
            }
        }
        if (!has_self_call) return;

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

        // --- Emit fast path (before prologue) ---
        // x0 = callee regs pointer (from caller)

        // 1. Load param from callee frame
        self.emit(a64.ldr64(SCRATCH, 0, param_offset)); // x8 = regs[param]

        // 2. Compare (32-bit signed/unsigned)
        self.emit(a64.cmpImm32(SCRATCH, @intCast(imm)));

        // 3. Branch to prologue if NOT base case
        const branch_idx = self.currentIdx();
        self.emit(a64.bCond(skip_cond, 0)); // placeholder

        // 4. Store result to regs[0] if return vreg != 0
        if (ret_instr.rd != 0) {
            // Result is a different param — copy to regs[0]
            if (ret_instr.rd != cmp_instr.rs1) {
                // Load the return param
                self.emit(a64.ldr64(SCRATCH, 0, @intCast(@as(u32, ret_instr.rd) * 8)));
            }
            self.emit(a64.str64(SCRATCH, 0, 0)); // regs[0] = result
        }
        // If ret_instr.rd == 0: result already in regs[0], no copy needed

        // 5. Return success
        self.emit(a64.movz64(0, 0, 0)); // x0 = 0
        self.emit(a64.ret_());

        // Patch branch to point to next instruction (start of prologue)
        const prologue_start = self.currentIdx();
        const disp: i19 = @intCast(@as(i32, @intCast(prologue_start)) - @as(i32, @intCast(branch_idx)));
        self.code.items[branch_idx] = a64.bCond(skip_cond, disp);
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
            // Cache vm.reg_ptr VALUE in x27 for inline self-calls (non-memory functions).
            // Also cache &vm.reg_ptr in regs[reg_count] to avoid recomputing the large offset
            // on every self-call (non-memory functions don't use regs[reg_count] for mem cache).
            self.emitLoadRegPtrAddr(SCRATCH);
            self.emit(a64.ldr64(REG_PTR_VAL, SCRATCH, 0)); // x27 = vm.reg_ptr value
            // Store &vm.reg_ptr in regs[reg_count] for fast access in self-calls
            self.emit(a64.str64(SCRATCH, REGS_PTR, @intCast(@as(u16, self.reg_count) * 8)));
            // Cache REG_STACK_SIZE in x28 (avoids MOV immediate per call).
            self.emit(a64.movz64(28, vm_mod.REG_STACK_SIZE, 0));
            // Cache vm_ptr/inst_ptr in callee-saved regs when vreg slots are unused.
            if (self.reg_count <= 12) {
                self.emitLoadVmPtr(20); // x20 = vm_ptr
                self.vm_ptr_cached = true;
            }
            if (self.reg_count <= 13) {
                self.emitLoadInstPtr(21); // x21 = inst_ptr
                self.inst_ptr_cached = true;
            }
        }

        // Load virtual registers from regs[] into physical registers.
        // Must be AFTER emitLoadMemCache() which calls BLR (trashes x0-x18).
        // Only load vregs that are read before written (prologue_load_mask).
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        for (0..max) |i| {
            const vreg: u8 = @intCast(i);
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

    fn emitEpilogue(self: *Compiler, result_vreg: ?u8) void {
        // Store result to regs[0] if needed
        if (result_vreg) |rv| {
            if (vregToPhys(rv)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, 0));
            } else {
                self.emit(a64.ldr64(SCRATCH, REGS_PTR, @as(u16, rv) * 8));
                self.emit(a64.str64(SCRATCH, REGS_PTR, 0));
            }
        }

        // Restore callee-saved registers (reverse order)
        self.emit(a64.ldpPost(27, 28, 31, 2));
        self.emit(a64.ldpPost(25, 26, 31, 2));
        self.emit(a64.ldpPost(23, 24, 31, 2));
        self.emit(a64.ldpPost(21, 22, 31, 2));
        self.emit(a64.ldpPost(19, 20, 31, 2));
        self.emit(a64.ldpPost(29, 30, 31, 2));

        // Return success (x0 = 0)
        self.emit(a64.movz64(0, 0, 0));
        self.emit(a64.ret_());
    }

    fn emitErrorReturn(self: *Compiler, error_code: u16) void {
        // Restore callee-saved and return error
        self.emit(a64.ldpPost(27, 28, 31, 2));
        self.emit(a64.ldpPost(25, 26, 31, 2));
        self.emit(a64.ldpPost(23, 24, 31, 2));
        self.emit(a64.ldpPost(21, 22, 31, 2));
        self.emit(a64.ldpPost(19, 20, 31, 2));
        self.emit(a64.ldpPost(29, 30, 31, 2));
        self.emit(a64.movz64(0, error_code, 0));
        self.emit(a64.ret_());
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

        // Scan IR for memory opcodes and self-calls
        self.has_memory = scanForMemoryOps(reg_func.code);
        self.has_self_call = for (reg_func.code) |instr| {
            if (instr.op == regalloc_mod.OP_CALL and instr.operand == self_func_idx) break true;
        } else false;

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

        // Mark params as written (they're initialized by the caller)
        for (0..self.param_count) |i| {
            if (i < 128) self.written_vregs |= @as(u128, 1) << @as(u7, @intCast(i));
        }

        while (pc < ir.len) {
            // Record ARM64 code offset at actual RegInstr PC
            self.pc_map.items[pc] = self.currentIdx();
            const instr = ir[pc];

            // Clear caches at branch targets (merge points)
            if (pc < branch_targets.len and branch_targets[pc]) {
                self.known_consts = .{null} ** 128;
                self.scratch_vreg = null;
                self.fpCacheEvictAll();
            }

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

        // Finalize: copy to executable memory
        return self.finalize();
    }

    fn compileInstr(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        switch (instr.op) {
            // --- Register ops ---
            regalloc_mod.OP_MOV => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.storeVreg(instr.rd, src);
            },
            regalloc_mod.OP_CONST32 => {
                const d = destReg(instr.rd);
                const val = instr.operand;
                if (val <= 0xFFFF) {
                    self.emit(a64.movz64(d, @truncate(val), 0));
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
                const d = destReg(instr.rd);
                self.emit(a64.cmp32(src, 31)); // CMP Wn, WZR
                self.emit(a64.cset32(d, .eq));
                self.storeVreg(instr.rd, d);
            },
            0x46 => self.emitCmp32(.eq, instr),
            0x47 => self.emitCmp32(.ne, instr),
            0x48 => self.emitCmp32(.lt, instr), // lt_s
            0x49 => self.emitCmp32(.lo, instr), // lt_u
            0x4A => self.emitCmp32(.gt, instr), // gt_s
            0x4B => self.emitCmp32(.hi, instr), // gt_u
            0x4C => self.emitCmp32(.le, instr), // le_s
            0x4D => self.emitCmp32(.ls, instr), // le_u
            0x4E => self.emitCmp32(.ge, instr), // ge_s
            0x4F => self.emitCmp32(.hs, instr), // ge_u

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
                const d = destReg(instr.rd);
                self.emit(a64.cmpImm64(src, 0));
                self.emit(a64.cset64(d, .eq));
                self.storeVreg(instr.rd, d);
            },
            0x51 => self.emitCmp64(.eq, instr),
            0x52 => self.emitCmp64(.ne, instr),
            0x53 => self.emitCmp64(.lt, instr),
            0x54 => self.emitCmp64(.lo, instr),
            0x55 => self.emitCmp64(.gt, instr),
            0x56 => self.emitCmp64(.hi, instr),
            0x57 => self.emitCmp64(.le, instr),
            0x58 => self.emitCmp64(.ls, instr),
            0x59 => self.emitCmp64(.ge, instr),
            0x5A => self.emitCmp64(.hs, instr),

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
            0x2B => self.emitMemLoad(instr, .x64, 8),   // f64.load (same bits as i64)
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
            0x39 => self.emitMemStore(instr, .x64, 8),  // f64.store
            0x3A => self.emitMemStore(instr, .b8, 1),   // i32.store8
            0x3B => self.emitMemStore(instr, .h16, 1),  // i32.store16
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
            regalloc_mod.OP_EQ_I32 => self.emitCmpImm32(.eq, instr),
            regalloc_mod.OP_NE_I32 => self.emitCmpImm32(.ne, instr),
            regalloc_mod.OP_LT_S_I32 => self.emitCmpImm32(.lt, instr),
            regalloc_mod.OP_GT_S_I32 => self.emitCmpImm32(.gt, instr),
            regalloc_mod.OP_LE_S_I32 => self.emitCmpImm32(.le, instr),
            regalloc_mod.OP_GE_S_I32 => self.emitCmpImm32(.ge, instr),
            regalloc_mod.OP_LT_U_I32 => self.emitCmpImm32(.lo, instr),
            regalloc_mod.OP_GE_U_I32 => self.emitCmpImm32(.hs, instr),

            // --- Select ---
            0x1B => { // select: rd = cond ? val1 : val2
                const val2_idx: u8 = @truncate(instr.operand);
                const cond_idx: u8 = @truncate(instr.operand >> 8);
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

            // Unsupported opcode — bail out, function can't be JIT compiled
            else => return false,
        }
        return true;
    }

    // --- Helper emitters ---

    const BinOp32 = enum { add, sub, mul, @"and", @"or", xor, shl, shr_s, shr_u };

    fn emitBinop32(self: *Compiler, op: BinOp32, instr: RegInstr) void {
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

    fn emitCmp32(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
        const rs2_vreg = instr.rs2();
        // Use CMP-immediate when rs2 is a known small constant
        if (rs2_vreg < 128) {
            if (self.known_consts[rs2_vreg]) |c| {
                if (c <= 0xFFF) {
                    const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                    const d = destReg(instr.rd);
                    self.emit(a64.cmpImm32(rs1, @intCast(c)));
                    self.emit(a64.cset32(d, cond));
                    self.storeVreg(instr.rd, d);
                    return;
                }
            }
        }
        // Also check if rs1 is a known constant (swap operands, invert condition)
        if (instr.rs1 < 128) {
            if (self.known_consts[instr.rs1]) |c| {
                if (c <= 0xFFF) {
                    const rs2 = self.getOrLoad(rs2_vreg, SCRATCH);
                    const d = destReg(instr.rd);
                    self.emit(a64.cmpImm32(rs2, @intCast(c)));
                    self.emit(a64.cset32(d, cond.swap()));
                    self.storeVreg(instr.rd, d);
                    return;
                }
            }
        }
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(rs2_vreg, SCRATCH2);
        const d = destReg(instr.rd);
        self.emit(a64.cmp32(rs1, rs2));
        self.emit(a64.cset32(d, cond));
        self.storeVreg(instr.rd, d);
    }

    fn emitCmp64(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        self.emit(a64.cmp64(rs1, rs2));
        self.emit(a64.cset64(d, cond));
        self.storeVreg(instr.rd, d);
    }

    fn emitCmpImm32(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const d = destReg(instr.rd);
        const imm = instr.operand;
        if (imm <= 0xFFF) {
            self.emit(a64.cmpImm32(rs1, @intCast(imm)));
        } else {
            self.emit(a64.movz32(SCRATCH2, @truncate(imm), 0));
            if (imm > 0xFFFF)
                self.emit(a64.movk64(SCRATCH2, @truncate(imm >> 16), 1));
            self.emit(a64.cmp32(rs1, SCRATCH2));
        }
        self.emit(a64.cset32(d, cond));
        self.storeVreg(instr.rd, d);
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

    fn emitDiv32(self: *Compiler, sign: Signedness, instr: RegInstr) void {
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

    fn emitRem32(self: *Compiler, sign: Signedness, instr: RegInstr) void {
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

    fn emitDiv64(self: *Compiler, sign: Signedness, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const d = destReg(instr.rd);
        // Check divisor == 0
        self.emit(a64.cmpImm64(rs2, 0));
        self.emitCondError(.eq, 3);
        if (sign == .signed) {
            // Check INT_MIN / -1 → overflow
            // Load -1 into SCRATCH via MOVN
            self.emit(a64.movz64(SCRATCH, 0, 0));
            self.emit(a64.movk64(SCRATCH, 0xFFFF, 0));
            self.emit(a64.movk64(SCRATCH, 0xFFFF, 1));
            self.emit(a64.movk64(SCRATCH, 0xFFFF, 2));
            self.emit(a64.movk64(SCRATCH, 0xFFFF, 3));
            self.emit(a64.cmp64(rs2, SCRATCH));
            const skip_idx = self.currentIdx();
            self.emit(a64.bCond(.ne, 0));
            // Load INT_MIN (0x8000000000000000)
            self.emit(a64.movz64(SCRATCH, 0, 0));
            self.emit(a64.movk64(SCRATCH, 0x8000, 3));
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
    fn isConstAddrSafe(self: *const Compiler, addr_vreg: u8, offset: u32, access_size: u32) ?u32 {
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
            const val_reg = self.getOrLoad(instr.rd, SCRATCH2);
            self.emit(emitStoreInstr(kind, val_reg, MEM_BASE, SCRATCH));
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
        // Reload caller-saved FIRST (x0 is untouched), then write result
        self.reloadCallerSaved();
        const d = destReg(instr.rd);
        self.emit(a64.mov64(d, 0));
        self.storeVreg(instr.rd, d);
        // BLR clobbered SCRATCH — if rd was physical, storeVreg didn't update cache
        if (d != SCRATCH) self.scratch_vreg = null;
    }

    /// global.set: call jitGlobalSet(instance, idx, val)
    fn emitGlobalSet(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll();
        self.spillCallerSaved();
        // Args: x0 = instance, w1 = global_idx, x2 = value
        self.emitLoadInstPtr(0);
        self.emit(a64.movz32(1, @truncate(instr.operand), 0));
        const val_reg = self.getOrLoad(instr.rd, SCRATCH);
        self.emit(a64.mov64(2, val_reg));
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

    fn emitCall(self: *Compiler, rd: u8, func_idx: u32, n_args: u16, data: RegInstr, data2: ?RegInstr, ir: []const RegInstr, call_pc: u32) void {
        // Self-call optimization: direct BL instead of trampoline.
        // Non-memory: uses cached &vm.reg_ptr in x27.
        // Memory: recomputes &vm.reg_ptr into SCRATCH each time.
        if (func_idx == self.self_func_idx) {
            self.emitInlineSelfCall(rd, data, data2, ir, call_pc);
            return;
        }

        // 1. Spill caller-saved regs + arg vregs needed by trampoline
        self.fpCacheEvictAll(); // Write back D-cache before BLR clobbers D-regs
        self.spillCallerSavedLive(ir, call_pc);
        // Trampoline reads args from regs[] — spill callee-saved arg vregs
        if (n_args > 0) self.spillVregIfCalleeSaved(data.rd);
        if (n_args > 1) self.spillVregIfCalleeSaved(data.rs1);
        if (n_args > 2) self.spillVregIfCalleeSaved(@truncate(data.operand));
        if (n_args > 3) self.spillVregIfCalleeSaved(@truncate(data.operand >> 8));
        if (n_args > 4) {
            if (data2) |d2| {
                if (n_args > 4) self.spillVregIfCalleeSaved(d2.rd);
                if (n_args > 5) self.spillVregIfCalleeSaved(d2.rs1);
                if (n_args > 6) self.spillVregIfCalleeSaved(@truncate(d2.operand));
                if (n_args > 7) self.spillVregIfCalleeSaved(@truncate(d2.operand >> 8));
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
        self.emit(a64.movz32(4, @as(u16, rd), 0));
        // Pack data word as u64 into x5
        const data_u64: u64 = @bitCast(data);
        const d_instrs = a64.loadImm64(5, data_u64);
        for (d_instrs) |inst| self.emit(inst);
        // data2 into x6 (0 if no second data word)
        if (data2) |d2| {
            const d2_u64: u64 = @bitCast(d2);
            const d2_instrs = a64.loadImm64(6, d2_u64);
            for (d2_instrs) |inst| self.emit(inst);
        } else {
            self.emit(a64.movz64(6, 0, 0));
        }

        // 3. Load trampoline address and call
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

        // 5. Reload memory cache FIRST (BLR clobbers x0-x15)
        //    Trampoline already wrote result to regs[rd], so it survives this BLR.
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
        self.spillVregIfCalleeSaved(@truncate(data.operand));
        self.spillVregIfCalleeSaved(@truncate(data.operand >> 8));
        if (data2) |d2| {
            self.spillVregIfCalleeSaved(d2.rd);
            self.spillVregIfCalleeSaved(d2.rs1);
            self.spillVregIfCalleeSaved(@truncate(d2.operand));
            self.spillVregIfCalleeSaved(@truncate(d2.operand >> 8));
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
        self.emit(a64.movz32(4, @as(u16, instr.rd), 0));
        // x5 = data word
        const data_u64: u64 = @bitCast(data);
        const d_instrs = a64.loadImm64(5, data_u64);
        for (d_instrs) |inst| self.emit(inst);
        // x6 = data2 word
        if (data2) |d2| {
            const d2_u64: u64 = @bitCast(d2);
            const d2_instrs = a64.loadImm64(6, d2_u64);
            for (d2_instrs) |inst| self.emit(inst);
        } else {
            self.emit(a64.movz64(6, 0, 0));
        }
        // w7 = elem_idx (load from regs[instr.rs1])
        self.emit(a64.ldr64(7, REGS_PTR, @as(u12, instr.rs1) * 8));
        // Truncate to 32 bits (elem_idx is u32)

        // 3. Load call_indirect trampoline address and call
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

        // 5. Reload memory cache FIRST (BLR clobbers x0-x15)
        //    Trampoline already wrote result to regs[rd], so it survives this BLR.
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // 6. Reload caller-saved regs AFTER all BLRs, then result register
        self.reloadCallerSaved();
        self.reloadVreg(instr.rd);
    }

    /// Inline self-call: direct BL to function entry, bypassing trampoline.
    /// Manages reg_ptr and callee frame setup inline for maximum performance.
    /// Non-memory functions use cached REG_PTR_VAL (x27) holding the actual value.
    /// Memory functions recompute &vm.reg_ptr into SCRATCH each time.
    fn emitInlineSelfCall(self: *Compiler, rd: u8, data: RegInstr, data2: ?RegInstr, ir: []const RegInstr, call_pc: u32) void {
        const needed: u32 = @as(u32, self.reg_count) + 4;
        const needed_bytes: u32 = needed * 8;

        // 1. Spill only caller-saved regs that are live after this call
        self.fpCacheEvictAll(); // Write back D-cache before BL clobbers D-regs
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
            // Must store updated value to memory so callee's prologue can read it.
            if (needed <= 0xFFF) {
                self.emit(a64.addImm64(REG_PTR_VAL, REG_PTR_VAL, @intCast(needed)));
            } else {
                self.emit(a64.movz64(SCRATCH2, @truncate(needed), 0));
                self.emit(a64.add64(REG_PTR_VAL, REG_PTR_VAL, SCRATCH2));
            }
            // Check: new reg_ptr > REG_STACK_SIZE → stack overflow
            // REG_STACK_SIZE cached in x28 (loaded in prologue)
            self.emit(a64.cmp64(REG_PTR_VAL, 28));
            self.emitCondError(.hi, 2); // StackOverflow if new > max
            // Write updated reg_ptr to memory (callee prologue reads from memory).
            // Load cached &vm.reg_ptr from regs[reg_count] (stored in prologue).
            self.emit(a64.ldr64(SCRATCH, REGS_PTR, @intCast(@as(u16, self.reg_count) * 8)));
            self.emit(a64.str64(REG_PTR_VAL, SCRATCH, 0));
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
        if (n_args > 2) self.emitArgCopyDirect(0, @truncate(data.operand), 16);
        if (n_args > 3) self.emitArgCopyDirect(0, @truncate(data.operand >> 8), 24);
        if (n_args > 4) {
            if (data2) |d2| {
                if (n_args > 4) self.emitArgCopyDirect(0, d2.rd, 32);
                if (n_args > 5) self.emitArgCopyDirect(0, d2.rs1, 40);
                if (n_args > 6) self.emitArgCopyDirect(0, @truncate(d2.operand), 48);
                if (n_args > 7) self.emitArgCopyDirect(0, @truncate(d2.operand >> 8), 56);
            }
        }

        // 5. Zero-init remaining locals (params..local_count)
        for (n_args..self.local_count) |i| {
            const offset: u16 = @intCast(i * 8);
            self.emit(a64.str64(31, 0, offset)); // XZR → callee regs[i]
        }

        // 6. Set up BL args: x0 = callee regs (already), x1 = vm, x2 = instance
        if (self.vm_ptr_cached) {
            self.emit(a64.mov64(1, 20)); // x1 = x20 (cached vm_ptr)
        } else {
            self.emitLoadVmPtr(1);
        }
        if (self.inst_ptr_cached) {
            self.emit(a64.mov64(2, 21)); // x2 = x21 (cached inst_ptr)
        } else {
            self.emitLoadInstPtr(2);
        }

        // 7. BL to self (backward branch to instruction 0)
        const bl_idx = self.currentIdx();
        const bl_offset: i26 = -@as(i26, @intCast(bl_idx));
        self.emit(a64.bl(bl_offset));

        // 8. After return: callee-saved regs (x19-x28) restored by callee's epilogue.
        //    x0 = error code (0 = success).

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

        // 11-12. Copy result and reload caller-saved regs.
        //     For callee-saved rd: load result directly into physical reg before reload.
        //     For caller-saved rd: reload others first, then load result directly.
        //     For memory-backed rd: store to memory (no physical reg).
        const rd_phys = if (self.result_count > 0) vregToPhys(rd) else null;
        const rd_callee_saved = if (rd_phys) |p| (p >= 19 and p <= 28) else false;

        if (self.result_count > 0 and rd_callee_saved) {
            // Callee-saved: load directly, survives reloadCallerSaved
            self.emitLoadCalleeResult(rd_phys.?, needed_bytes);
        }

        self.reloadCallerSavedLiveExcept(if (rd_phys != null and !rd_callee_saved) rd else null);

        if (self.result_count > 0 and !rd_callee_saved) {
            if (rd_phys) |phys| {
                // Caller-saved: load directly after reload (skipped in reload above)
                self.emitLoadCalleeResult(phys, needed_bytes);
            } else {
                // Memory-backed: must go through SCRATCH → memory
                self.emitLoadCalleeResult(SCRATCH, needed_bytes);
                self.emit(a64.str64(SCRATCH, REGS_PTR, @as(u16, rd) * 8));
            }
        }

        // 13. Reload memory cache (memory may have grown during call)
        if (self.has_memory) {
            self.emitLoadMemCache();
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
    fn emitArgCopyDirect(self: *Compiler, callee_base: u5, src_vreg: u8, offset: u16) void {
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
    }

    /// f64 binary with direct FP instruction (min/max).
    fn emitFpBinopDirect64(self: *Compiler, fpOp: fn (u5, u5, u5) u32, instr: RegInstr) void {
        const dn = self.fpLoadToDreg(instr.rs1);
        const dm = self.fpLoadToDreg(instr.rs2());
        const dd = self.fpAllocResult(instr.rd);
        self.emit(fpOp(dd, dn, dm));
    }

    /// f64 unary (sqrt/abs/neg). Uses D-register cache.
    fn emitFpUnop64(self: *Compiler, fpOp: fn (u5, u5) u32, instr: RegInstr) void {
        const dn = self.fpLoadToDreg(instr.rs1);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(fpOp(dd, dn));
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
    }

    /// f64.convert_i32_u: UCVTF Dd, Wn
    fn emitFpConvert_f64_i32_u(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(0x1E630000 | (@as(u32, src) << 5) | @as(u32, dd));
    }

    /// f64.convert_i64_s: SCVTF Dd, Xn
    fn emitFpConvert_f64_i64_s(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(0x9E620000 | (@as(u32, src) << 5) | @as(u32, dd));
    }

    /// f64.convert_i64_u: UCVTF Dd, Xn
    fn emitFpConvert_f64_i64_u(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(0x9E630000 | (@as(u32, src) << 5) | @as(u32, dd));
    }

    /// f64.promote_f32: FCVT Dd, Sn
    fn emitFpPromote(self: *Compiler, instr: RegInstr) void {
        self.fpCacheEvictAll(); // f32 input uses S register
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const dd = self.fpAllocResult(instr.rd);
        self.emit(a64.fmovToFp32(FP_SCRATCH0, src));
        self.emit(a64.fcvt_d_s(dd, FP_SCRATCH0));
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
        if (self.error_stubs.items.len == 0 and !self.use_guard_pages) return;

        // Shared error epilogue: restore callee-saved regs and return (x0 has error code)
        const shared_exit = self.currentIdx();
        self.shared_exit_idx = shared_exit;
        self.emit(a64.ldpPost(27, 28, 31, 2));
        self.emit(a64.ldpPost(25, 26, 31, 2));
        self.emit(a64.ldpPost(23, 24, 31, 2));
        self.emit(a64.ldpPost(21, 22, 31, 2));
        self.emit(a64.ldpPost(19, 20, 31, 2));
        self.emit(a64.ldpPost(29, 30, 31, 2));
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

        const PROT = std.posix.PROT;
        const buf = std.posix.mmap(
            null,
            buf_size,
            PROT.READ | PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch return null;
        const aligned_buf: []align(std.heap.page_size_min) u8 = @alignCast(buf);

        // Copy instructions to executable buffer
        const src_bytes = std.mem.sliceAsBytes(self.code.items);
        @memcpy(aligned_buf[0..src_bytes.len], src_bytes);

        // Make executable (W^X transition)
        std.posix.mprotect(aligned_buf, PROT.READ | PROT.EXEC) catch {
            std.posix.munmap(aligned_buf);
            return null;
        };

        // Flush instruction cache
        icacheInvalidate(aligned_buf.ptr, code_size);

        // Allocate JitCode struct
        const jit_code = self.alloc.create(JitCode) catch {
            std.posix.munmap(aligned_buf);
            return null;
        };
        jit_code.* = .{
            .buf = aligned_buf,
            .entry = @ptrCast(@alignCast(aligned_buf.ptr)),
            .code_len = @intCast(self.code.items.len * 4),
            .oob_exit_offset = self.shared_exit_idx * 4,
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
    const data: RegInstr = @bitCast(data_raw);

    const func_ptr = instance.getFuncPtr(func_idx) catch return 1;
    const n_args = func_ptr.params.len;
    const n_results = func_ptr.results.len;

    // Collect args from register file
    var call_args: [8]u64 = undefined;
    if (n_args > 0) call_args[0] = regs[data.rd];
    if (n_args > 1) call_args[1] = regs[data.rs1];
    if (n_args > 2) call_args[2] = regs[@as(u8, @truncate(data.operand))];
    if (n_args > 3) call_args[3] = regs[@as(u8, @truncate(data.operand >> 8))];
    if (n_args > 4 and data2_raw != 0) {
        const data2: RegInstr = @bitCast(@as([8]u8, @bitCast(data2_raw)));
        if (n_args > 4) call_args[4] = regs[data2.rd];
        if (n_args > 5) call_args[5] = regs[data2.rs1];
        if (n_args > 6) call_args[6] = regs[@as(u8, @truncate(data2.operand))];
        if (n_args > 7) call_args[7] = regs[@as(u8, @truncate(data2.operand >> 8))];
    }

    // Fast path: if callee is already JIT-compiled, call directly (skip callFunction)
    if (func_ptr.subtype == .wasm_function) {
        const wf = &func_ptr.subtype.wasm_function;
        if (wf.jit_code) |jc| {
            if (wf.reg_ir) |reg| {
                const base = vm.reg_ptr;
                const needed: usize = reg.reg_count + 4; // +4: mem cache + VM/inst ptrs
                if (base + needed > vm_mod.REG_STACK_SIZE) return 2; // StackOverflow
                const callee_regs = vm.reg_stack[base .. base + needed];
                vm.reg_ptr = base + needed;

                for (call_args[0..n_args], 0..) |arg, i| callee_regs[i] = arg;
                for (n_args..reg.local_count) |i| callee_regs[i] = 0;

                const err = jc.entry(callee_regs.ptr, vm_opaque, instance_opaque);
                vm.reg_ptr = base;
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

    // Type check
    if (instance.module.getTypeFunc(type_idx)) |expected| {
        if (!ValType.sliceEql(expected.params, func_ptr.params) or
            !ValType.sliceEql(expected.results, func_ptr.results))
            return 1; // MismatchedSignatures → Trap
    }

    const n_args = func_ptr.params.len;
    const n_results = func_ptr.results.len;

    // Collect args from register file
    const data: RegInstr = @bitCast(data_raw);
    var call_args: [8]u64 = undefined;
    if (n_args > 0) call_args[0] = regs[data.rd];
    if (n_args > 1) call_args[1] = regs[data.rs1];
    if (n_args > 2) call_args[2] = regs[@as(u8, @truncate(data.operand))];
    if (n_args > 3) call_args[3] = regs[@as(u8, @truncate(data.operand >> 8))];
    if (n_args > 4 and data2_raw != 0) {
        const data2: RegInstr = @bitCast(@as([8]u8, @bitCast(data2_raw)));
        if (n_args > 4) call_args[4] = regs[data2.rd];
        if (n_args > 5) call_args[5] = regs[data2.rs1];
        if (n_args > 6) call_args[6] = regs[@as(u8, @truncate(data2.operand))];
        if (n_args > 7) call_args[7] = regs[@as(u8, @truncate(data2.operand >> 8))];
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

                const err = jc.entry(callee_regs.ptr, vm_opaque, instance_opaque);
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
) ?*JitCode {
    // x86_64 dispatch — delegate to separate backend
    if (builtin.cpu.arch == .x86_64) {
        const x86 = @import("x86.zig");
        return x86.compileFunction(alloc, reg_func, pool64, self_func_idx, param_count, result_count, trace, min_memory_bytes, use_guard_pages);
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

    var compiler = Compiler.init(alloc);
    compiler.min_memory_bytes = min_memory_bytes;
    compiler.use_guard_pages = use_guard_pages;

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

fn icacheInvalidate(ptr: [*]const u8, len: usize) void {
    if (builtin.os.tag == .macos) {
        const func = @extern(*const fn ([*]const u8, usize) callconv(.c) void, .{
            .name = "sys_icache_invalidate",
        });
        func(ptr, len);
    } else if (builtin.os.tag == .linux) {
        const func = @extern(*const fn ([*]const u8, [*]const u8) callconv(.c) void, .{
            .name = "__clear_cache",
        });
        func(ptr, ptr + len);
    }
}

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
    // r20+ → null (spill)
    try testing.expectEqual(@as(?u5, null), vregToPhys(20));
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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
        .{ .op = 0x6A, .rd = 2, .rs1 = 0, .operand = 1 }, // rs2 = 1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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
        .{ .op = 0x6D, .rd = 2, .rs1 = 0, .operand = 1 }, // i32.div_s r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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
        .{ .op = 0x6F, .rd = 2, .rs1 = 0, .operand = 1 }, // i32.rem_s r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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
    const mem_idx = try store.addMemory(1, null, 65536, false);
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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
    const mem_idx = try store.addMemory(1, null, 65536, false);
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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
    const mem_idx = try store.addMemory(1, null, 65536, false);
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
        .{ .op = 0x6A, .rd = 4, .rs1 = 1, .operand = 3 }, // i32.add r4 = r1 + r3
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
    const jit_opt = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 65536, false) orelse
        return error.CompilationFailed;
    defer jit_opt.deinit(alloc);

    // Compile without optimization (min_memory_bytes = 0)
    const jit_noopt = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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

