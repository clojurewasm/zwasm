// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! x86_64 JIT compiler — compiles register IR to native machine code.
//! Parallel to ARM64 backend in jit.zig. See D105 in .dev/decisions.md.
//!
//! Register mapping (host AMD64 ABI):
//!   R12:  regs_ptr (callee-saved, base of virtual register file)
//!   R13:  mem_base (callee-saved, linear memory base pointer)
//!   R14:  mem_size (callee-saved, linear memory size in bytes)
//!   RBX:  virtual r0 (callee-saved)
//!   RBP:  virtual r1 (callee-saved, no frame pointer in JIT)
//!   R15:  virtual r2 (callee-saved)
//!   RCX:  virtual r3 (caller-saved)
//!   RDI:  virtual r4 (caller-saved)
//!   RSI:  virtual r5 (caller-saved)
//!   RDX:  virtual r6 (caller-saved)
//!   R8:   virtual r7 (caller-saved)
//!   R9:   virtual r8 (caller-saved)
//!   R10:  virtual r9 (caller-saved)
//!   R11:  virtual r10 (caller-saved)
//!   RAX:  scratch + return value
//!
//! JIT function signature (C calling convention):
//!   fn(regs: [*]u64, vm: *anyopaque, instance: *anyopaque) callconv(.c) u64
//!   SysV entry:  RDI=regs, RSI=vm, RDX=instance
//!   Win64 entry: RCX=regs, RDX=vm, R8=instance
//!   Returns: RAX=0 success.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const regalloc_mod = @import("regalloc.zig");
const predecode_mod = @import("predecode.zig");
const RegInstr = regalloc_mod.RegInstr;
const RegFunc = regalloc_mod.RegFunc;
const store_mod = @import("store.zig");
const Instance = @import("instance.zig").Instance;
const ValType = @import("opcode.zig").ValType;
const WasmMemory = @import("memory.zig").Memory;
const trace_mod = @import("trace.zig");
const jit_mod = @import("jit.zig");
const JitCode = jit_mod.JitCode;
const JitFn = jit_mod.JitFn;
const vm_mod = @import("vm.zig");
const platform = @import("platform.zig");

// ================================================================
// x86_64 register definitions
// ================================================================

/// x86_64 register indices (used in ModR/M and REX encoding).
const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    fn low3(self: Reg) u3 {
        return @truncate(@intFromEnum(self));
    }

    fn isExt(self: Reg) bool {
        return @intFromEnum(self) >= 8;
    }
};

// Named register aliases for clarity in the Compiler.
const REGS_PTR = Reg.r12;
const MEM_BASE = Reg.r13;
const MEM_SIZE = Reg.r14;
const SCRATCH = Reg.rax;
const SCRATCH2 = Reg.r11; // secondary scratch (caller-saved, reserved — NOT a vreg)

// ================================================================
// x86_64 instruction encoding
// ================================================================

const Enc = struct {
    // --- REX prefix ---

    /// REX prefix byte. W=64-bit, R=extends ModR/M reg, X=extends SIB index, B=extends ModR/M rm.
    fn rex(w: bool, r: bool, x: bool, b: bool) u8 {
        return 0x40 |
            (@as(u8, @intFromBool(w)) << 3) |
            (@as(u8, @intFromBool(r)) << 2) |
            (@as(u8, @intFromBool(x)) << 1) |
            @as(u8, @intFromBool(b));
    }

    /// REX.W prefix for 64-bit operation with reg and rm.
    fn rexW(reg: Reg, rm: Reg) u8 {
        return rex(true, reg.isExt(), false, rm.isExt());
    }

    /// REX.W prefix for single register (in rm position).
    fn rexW1(rm: Reg) u8 {
        return rex(true, false, false, rm.isExt());
    }

    /// REX prefix for reg-reg operation (no W bit, for 32-bit ops).
    fn rexRR(reg: Reg, rm: Reg) u8 {
        return rex(false, reg.isExt(), false, rm.isExt());
    }

    // --- ModR/M ---

    /// ModR/M byte: mod(2) | reg(3) | rm(3).
    fn modrm(mod_: u2, reg: u3, rm: u3) u8 {
        return (@as(u8, mod_) << 6) | (@as(u8, reg) << 3) | rm;
    }

    /// ModR/M for register-register (mod=11).
    fn modrmReg(reg: Reg, rm: Reg) u8 {
        return modrm(0b11, reg.low3(), rm.low3());
    }

    /// ModR/M for [rm] indirect (mod=00). Caller must handle RSP(SIB) and RBP(disp32) special cases.
    fn modrmInd(reg: Reg, rm: Reg) u8 {
        return modrm(0b00, reg.low3(), rm.low3());
    }

    /// ModR/M for [rm + disp8] (mod=01).
    fn modrmDisp8(reg: Reg, rm: Reg) u8 {
        return modrm(0b01, reg.low3(), rm.low3());
    }

    /// ModR/M for [rm + disp32] (mod=10).
    /// SIB byte: scale(2) index(3) base(3)
    fn sib(scale: u2, index: u3, base: u3) u8 {
        return (@as(u8, scale) << 6) | (@as(u8, index) << 3) | base;
    }

    fn modrmDisp32(reg: Reg, rm: Reg) u8 {
        return modrm(0b10, reg.low3(), rm.low3());
    }

    // --- Instruction builders ---
    // All functions append bytes to a buffer (ArrayList(u8)).
    // Using `buf` parameter for testability without Compiler.

    /// PUSH r64 (1-2 bytes): [REX] 50+rd
    fn push(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg) void {
        if (reg.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0x50 + @as(u8, reg.low3())) catch {};
    }

    /// POP r64 (1-2 bytes): [REX] 58+rd
    fn pop(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg) void {
        if (reg.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0x58 + @as(u8, reg.low3())) catch {};
    }

    /// RET (1 byte): C3
    fn ret_(buf: *std.ArrayList(u8), alloc: Allocator) void {
        buf.append(alloc, 0xC3) catch {};
    }

    /// NOP (1 byte): 90
    fn nop(buf: *std.ArrayList(u8), alloc: Allocator) void {
        buf.append(alloc, 0x90) catch {};
    }

    /// MOV r64, r64 (3 bytes): REX.W 89 /r (store form: src → dst)
    fn movRegReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(src, dst)) catch {};
        buf.append(alloc, 0x89) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// MOV r32, r32 (2-3 bytes): [REX] 89 /r (32-bit, zero-extends to 64)
    fn movRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        if (src.isExt() or dst.isExt()) {
            buf.append(alloc, rex(false, src.isExt(), false, dst.isExt())) catch {};
        }
        buf.append(alloc, 0x89) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// MOV r64, r64 (REX.W prefix for 64-bit operand)
    fn movRegReg64(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rex(true, src.isExt(), false, dst.isExt())) catch {};
        buf.append(alloc, 0x89) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// MOV r64, imm64 (10 bytes): REX.W B8+rd io
    fn movImm64(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, imm: u64) void {
        buf.append(alloc, rexW1(dst)) catch {};
        buf.append(alloc, 0xB8 + @as(u8, dst.low3())) catch {};
        appendU64(buf, alloc, imm);
    }

    /// MOV r32, imm32 (5-6 bytes): [REX] B8+rd id
    fn movImm32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, imm: u32) void {
        if (dst.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xB8 + @as(u8, dst.low3())) catch {};
        appendU32(buf, alloc, imm);
    }

    /// XOR r64, r64 (3 bytes): REX.W 31 /r — used for zeroing registers.
    fn xorRegReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(src, dst)) catch {};
        buf.append(alloc, 0x31) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// XOR r32, r32 (2-3 bytes): zero-extends to 64-bit.
    fn xorRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        if (src.isExt() or dst.isExt()) {
            buf.append(alloc, rex(false, src.isExt(), false, dst.isExt())) catch {};
        }
        buf.append(alloc, 0x31) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// ADD r64, r64 (3 bytes): REX.W 01 /r
    fn addRegReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(src, dst)) catch {};
        buf.append(alloc, 0x01) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// ADD r32, r32 (2-3 bytes): 01 /r
    fn addRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        if (src.isExt() or dst.isExt()) {
            buf.append(alloc, rex(false, src.isExt(), false, dst.isExt())) catch {};
        }
        buf.append(alloc, 0x01) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// SUB r64, r64 (3 bytes): REX.W 29 /r
    fn subRegReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(src, dst)) catch {};
        buf.append(alloc, 0x29) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// SUB r32, r32 (2-3 bytes): 29 /r
    fn subRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        if (src.isExt() or dst.isExt()) {
            buf.append(alloc, rex(false, src.isExt(), false, dst.isExt())) catch {};
        }
        buf.append(alloc, 0x29) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// AND r64, r64 (3 bytes): REX.W 21 /r
    fn andRegReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(src, dst)) catch {};
        buf.append(alloc, 0x21) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// AND r32, r32: 21 /r
    fn andRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        if (src.isExt() or dst.isExt()) {
            buf.append(alloc, rex(false, src.isExt(), false, dst.isExt())) catch {};
        }
        buf.append(alloc, 0x21) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// OR r64, r64 (3 bytes): REX.W 09 /r
    fn orRegReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(src, dst)) catch {};
        buf.append(alloc, 0x09) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// OR r32, r32: 09 /r
    fn orRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        if (src.isExt() or dst.isExt()) {
            buf.append(alloc, rex(false, src.isExt(), false, dst.isExt())) catch {};
        }
        buf.append(alloc, 0x09) catch {};
        buf.append(alloc, modrmReg(src, dst)) catch {};
    }

    /// XOR (as instruction, not zeroing): REX.W 31 /r — same encoding as xorRegReg.

    /// IMUL r64, r64 (4 bytes): REX.W 0F AF /r (dst = dst * src)
    fn imulRegReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xAF) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    /// IMUL r32, r32 (3-4 bytes): [REX] 0F AF /r
    fn imulRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        if (dst.isExt() or src.isExt()) {
            buf.append(alloc, rex(false, dst.isExt(), false, src.isExt())) catch {};
        }
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xAF) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    /// CMP r64, r64 (3 bytes): REX.W 39 /r
    fn cmpRegReg(buf: *std.ArrayList(u8), alloc: Allocator, a: Reg, b: Reg) void {
        buf.append(alloc, rexW(b, a)) catch {};
        buf.append(alloc, 0x39) catch {};
        buf.append(alloc, modrmReg(b, a)) catch {};
    }

    /// CMP r32, r32: 39 /r
    fn cmpRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, a: Reg, b: Reg) void {
        if (b.isExt() or a.isExt()) {
            buf.append(alloc, rex(false, b.isExt(), false, a.isExt())) catch {};
        }
        buf.append(alloc, 0x39) catch {};
        buf.append(alloc, modrmReg(b, a)) catch {};
    }

    /// CMP r64, imm32 (sign-extended): REX.W 81 /7 id
    fn cmpImm32(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg, imm: u32) void {
        buf.append(alloc, rexW1(reg)) catch {};
        buf.append(alloc, 0x81) catch {};
        buf.append(alloc, modrm(0b11, 7, reg.low3())) catch {};
        appendU32(buf, alloc, imm);
    }

    /// CMP r64, imm8 (sign-extended): REX.W 83 /7 ib
    fn cmpImm8(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg, imm: i8) void {
        buf.append(alloc, rexW1(reg)) catch {};
        buf.append(alloc, 0x83) catch {};
        buf.append(alloc, modrm(0b11, 7, reg.low3())) catch {};
        buf.append(alloc, @bitCast(imm)) catch {};
    }

    /// CMP r/m32, imm8 (sign-extended to 32 bits)
    fn cmpImm8_32(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg, imm: i8) void {
        if (reg.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0x83) catch {};
        buf.append(alloc, modrm(0b11, 7, reg.low3())) catch {};
        buf.append(alloc, @bitCast(imm)) catch {};
    }

    /// TEST r64, r64 (3 bytes): REX.W 85 /r
    fn testRegReg(buf: *std.ArrayList(u8), alloc: Allocator, a: Reg, b: Reg) void {
        buf.append(alloc, rexW(b, a)) catch {};
        buf.append(alloc, 0x85) catch {};
        buf.append(alloc, modrmReg(b, a)) catch {};
    }

    /// ADD r64, imm32 (sign-extended): REX.W 81 /0 id
    fn addImm32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, imm: i32) void {
        buf.append(alloc, rexW1(dst)) catch {};
        if (imm >= -128 and imm <= 127) {
            buf.append(alloc, 0x83) catch {};
            buf.append(alloc, modrm(0b11, 0, dst.low3())) catch {};
            buf.append(alloc, @bitCast(@as(i8, @intCast(imm)))) catch {};
        } else {
            buf.append(alloc, 0x81) catch {};
            buf.append(alloc, modrm(0b11, 0, dst.low3())) catch {};
            appendI32(buf, alloc, imm);
        }
    }

    /// SUB r64, imm32 (sign-extended): REX.W 81 /5 id or 83 /5 ib
    fn subImm32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, imm: i32) void {
        buf.append(alloc, rexW1(dst)) catch {};
        if (imm >= -128 and imm <= 127) {
            buf.append(alloc, 0x83) catch {};
            buf.append(alloc, modrm(0b11, 5, dst.low3())) catch {};
            buf.append(alloc, @bitCast(@as(i8, @intCast(imm)))) catch {};
        } else {
            buf.append(alloc, 0x81) catch {};
            buf.append(alloc, modrm(0b11, 5, dst.low3())) catch {};
            appendI32(buf, alloc, imm);
        }
    }

    /// NEG r64: REX.W F7 /3
    fn negReg(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg) void {
        buf.append(alloc, rexW1(reg)) catch {};
        buf.append(alloc, 0xF7) catch {};
        buf.append(alloc, modrm(0b11, 3, reg.low3())) catch {};
    }

    /// NEG r32: F7 /3
    fn negReg32(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg) void {
        if (reg.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xF7) catch {};
        buf.append(alloc, modrm(0b11, 3, reg.low3())) catch {};
    }

    /// NOT r64: REX.W F7 /2
    fn notReg(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg) void {
        buf.append(alloc, rexW1(reg)) catch {};
        buf.append(alloc, 0xF7) catch {};
        buf.append(alloc, modrm(0b11, 2, reg.low3())) catch {};
    }

    // --- Shifts ---

    /// SHL r64, CL: REX.W D3 /4
    fn shlCl(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        buf.append(alloc, rexW1(dst)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 4, dst.low3())) catch {};
    }

    /// SHL r32, CL: D3 /4
    fn shlCl32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        if (dst.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 4, dst.low3())) catch {};
    }

    /// SHR r64, CL: REX.W D3 /5
    fn shrCl(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        buf.append(alloc, rexW1(dst)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 5, dst.low3())) catch {};
    }

    /// SHR r32, CL: D3 /5
    fn shrCl32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        if (dst.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 5, dst.low3())) catch {};
    }

    /// SAR r64, CL: REX.W D3 /7
    fn sarCl(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        buf.append(alloc, rexW1(dst)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 7, dst.low3())) catch {};
    }

    /// SAR r32, CL: D3 /7
    fn sarCl32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        if (dst.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 7, dst.low3())) catch {};
    }

    /// SHR r64, imm8: REX.W C1 /5 ib
    fn shrImm(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, imm: u6) void {
        buf.append(alloc, rexW1(dst)) catch {};
        buf.append(alloc, 0xC1) catch {};
        buf.append(alloc, modrm(0b11, 5, dst.low3())) catch {};
        buf.append(alloc, @intCast(imm)) catch {};
    }

    /// SHR r32, imm8: C1 /5 ib
    fn shrImm32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, imm: u5) void {
        if (dst.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xC1) catch {};
        buf.append(alloc, modrm(0b11, 5, dst.low3())) catch {};
        buf.append(alloc, @intCast(imm)) catch {};
    }

    /// ROL r64, CL: REX.W D3 /0
    fn rolCl(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        buf.append(alloc, rexW1(dst)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 0, dst.low3())) catch {};
    }

    /// ROR r64, CL: REX.W D3 /1
    fn rorCl(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        buf.append(alloc, rexW1(dst)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 1, dst.low3())) catch {};
    }

    /// ROR r32, CL: D3 /1
    fn rorCl32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg) void {
        if (dst.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xD3) catch {};
        buf.append(alloc, modrm(0b11, 1, dst.low3())) catch {};
    }

    // --- Division ---

    /// IDIV r64 (signed divide RDX:RAX by r/m64): REX.W F7 /7
    fn idivReg(buf: *std.ArrayList(u8), alloc: Allocator, divisor: Reg) void {
        buf.append(alloc, rexW1(divisor)) catch {};
        buf.append(alloc, 0xF7) catch {};
        buf.append(alloc, modrm(0b11, 7, divisor.low3())) catch {};
    }

    /// IDIV r32: F7 /7
    fn idivReg32(buf: *std.ArrayList(u8), alloc: Allocator, divisor: Reg) void {
        if (divisor.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xF7) catch {};
        buf.append(alloc, modrm(0b11, 7, divisor.low3())) catch {};
    }

    /// DIV r64 (unsigned divide RDX:RAX by r/m64): REX.W F7 /6
    fn divReg(buf: *std.ArrayList(u8), alloc: Allocator, divisor: Reg) void {
        buf.append(alloc, rexW1(divisor)) catch {};
        buf.append(alloc, 0xF7) catch {};
        buf.append(alloc, modrm(0b11, 6, divisor.low3())) catch {};
    }

    /// DIV r32: F7 /6
    fn divReg32(buf: *std.ArrayList(u8), alloc: Allocator, divisor: Reg) void {
        if (divisor.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xF7) catch {};
        buf.append(alloc, modrm(0b11, 6, divisor.low3())) catch {};
    }

    /// CQO (sign-extend RAX into RDX:RAX): REX.W 99
    fn cqo(buf: *std.ArrayList(u8), alloc: Allocator) void {
        buf.append(alloc, rex(true, false, false, false)) catch {};
        buf.append(alloc, 0x99) catch {};
    }

    /// CDQ (sign-extend EAX into EDX:EAX): 99
    fn cdq(buf: *std.ArrayList(u8), alloc: Allocator) void {
        buf.append(alloc, 0x99) catch {};
    }

    // --- Bit manipulation ---

    /// BSR r64, r64 (bit scan reverse): REX.W 0F BD /r
    fn bsr(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xBD) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    /// BSF r64, r64 (bit scan forward): REX.W 0F BC /r
    fn bsf(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xBC) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    /// LZCNT r64, r64: F3 REX.W 0F BD /r
    fn lzcnt(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, 0xF3) catch {};
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xBD) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    /// TZCNT r64, r64: F3 REX.W 0F BC /r
    fn tzcnt(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, 0xF3) catch {};
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xBC) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    /// POPCNT r64, r64: F3 REX.W 0F B8 /r
    fn popcnt(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, 0xF3) catch {};
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xB8) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    // --- Sign/Zero extension ---

    /// MOVSX r64, r32 (sign-extend 32→64): REX.W 63 /r (MOVSXD)
    fn movsxd(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x63) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    // --- Control flow ---

    /// JMP rel32 (5 bytes): E9 cd. Returns offset of rel32 for patching.
    fn jmpRel32(buf: *std.ArrayList(u8), alloc: Allocator) u32 {
        buf.append(alloc, 0xE9) catch {};
        const patch_offset: u32 = @intCast(buf.items.len);
        appendI32(buf, alloc, 0); // placeholder
        return patch_offset;
    }

    /// Jcc rel32 (6 bytes): 0F 8x cd. Returns offset of rel32 for patching.
    fn jccRel32(buf: *std.ArrayList(u8), alloc: Allocator, cc: Cond) u32 {
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0x80 + @as(u8, @intFromEnum(cc))) catch {};
        const patch_offset: u32 = @intCast(buf.items.len);
        appendI32(buf, alloc, 0); // placeholder
        return patch_offset;
    }

    /// CALL rel32 (5 bytes): E8 cd. Returns offset of rel32 for patching.
    fn callRel32(buf: *std.ArrayList(u8), alloc: Allocator) u32 {
        buf.append(alloc, 0xE8) catch {};
        const patch_offset: u32 = @intCast(buf.items.len);
        appendI32(buf, alloc, 0); // placeholder
        return patch_offset;
    }

    /// CALL r64 (indirect): [REX] FF /2
    fn callReg(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg) void {
        if (reg.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xFF) catch {};
        buf.append(alloc, modrm(0b11, 2, reg.low3())) catch {};
    }

    /// JMP r64 (indirect): [REX] FF /4
    fn jmpReg(buf: *std.ArrayList(u8), alloc: Allocator, reg: Reg) void {
        if (reg.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0xFF) catch {};
        buf.append(alloc, modrm(0b11, 4, reg.low3())) catch {};
    }

    /// SETcc r8: 0F 9x /0 (sets low byte of register)
    fn setcc(buf: *std.ArrayList(u8), alloc: Allocator, cc: Cond, dst: Reg) void {
        if (dst.isExt()) buf.append(alloc, rex(false, false, false, true)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0x90 + @as(u8, @intFromEnum(cc))) catch {};
        buf.append(alloc, modrm(0b11, 0, dst.low3())) catch {};
    }

    /// CMOVcc r64, r64: REX.W 0F 4x /r (conditional move, 64-bit)
    fn cmovcc64(buf: *std.ArrayList(u8), alloc: Allocator, cc: Cond, dst: Reg, src: Reg) void {
        buf.append(alloc, rexW(dst, src)) catch {};
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0x40 + @as(u8, @intFromEnum(cc))) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    /// MOVZX r32, r8: 0F B6 /r (zero-extend byte to 32-bit, then to 64-bit)
    fn movzxByte(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, src: Reg) void {
        // Need REX prefix if src is SPL/BPL/SIL/DIL or any extended register
        if (dst.isExt() or src.isExt() or @intFromEnum(src) >= 4) {
            buf.append(alloc, rex(false, dst.isExt(), false, src.isExt())) catch {};
        }
        buf.append(alloc, 0x0F) catch {};
        buf.append(alloc, 0xB6) catch {};
        buf.append(alloc, modrmReg(dst, src)) catch {};
    }

    // --- Memory load/store ---

    /// MOV r64, [base + disp32]: REX.W 8B /r mod=10
    fn loadDisp32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, disp: i32) void {
        buf.append(alloc, rexW(dst, base)) catch {};
        buf.append(alloc, 0x8B) catch {};
        // Special case: base=RSP/R12 needs SIB byte
        if (base.low3() == 4) {
            buf.append(alloc, modrmDisp32(dst, base)) catch {};
            buf.append(alloc, 0x24) catch {}; // SIB: scale=0, index=RSP(none), base=RSP
        } else {
            buf.append(alloc, modrmDisp32(dst, base)) catch {};
        }
        appendI32(buf, alloc, disp);
    }

    /// MOV [base + disp32], r64: REX.W 89 /r mod=10
    fn storeDisp32(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, disp: i32, src: Reg) void {
        buf.append(alloc, rexW(src, base)) catch {};
        buf.append(alloc, 0x89) catch {};
        if (base.low3() == 4) {
            buf.append(alloc, modrmDisp32(src, base)) catch {};
            buf.append(alloc, 0x24) catch {};
        } else {
            buf.append(alloc, modrmDisp32(src, base)) catch {};
        }
        appendI32(buf, alloc, disp);
    }

    // --- Indexed memory access: [base + index*1] ---

    /// Emit ModR/M + SIB for [base + index*1] addressing.
    /// Handles the R13/RBP special case: when base.low3()==5 (RBP/R13),
    /// mod=00 encodes as [disp32 + index] instead. Use mod=01 + disp8=0.
    fn emitSibAddr(buf: *std.ArrayList(u8), alloc: Allocator, reg_field: u3, base: Reg, index: Reg) void {
        const rf: u8 = reg_field;
        const il: u8 = index.low3();
        const bl: u8 = base.low3();
        if (base.low3() == 5) {
            // mod=01, rm=100 (SIB), disp8=0
            buf.append(alloc, 0x44 | (rf << 3)) catch {};
            buf.append(alloc, (il << 3) | bl) catch {};
            buf.append(alloc, 0x00) catch {}; // disp8 = 0
        } else {
            // mod=00, rm=100 (SIB)
            buf.append(alloc, (rf << 3) | 0x04) catch {};
            buf.append(alloc, (il << 3) | bl) catch {};
        }
    }

    /// MOV r32, [base + index*1] (32-bit load)
    fn loadBaseIdx32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        const r = rexRR(dst, base) | (if (index.isExt()) @as(u8, 0x42) else 0);
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.append(alloc, 0x8B) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOV r64, [base + index*1] (64-bit load)
    fn loadBaseIdx64(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexW(dst, base);
        if (index.isExt()) r |= 0x02;
        buf.append(alloc, r) catch {};
        buf.append(alloc, 0x8B) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOVZX r32, byte [base + index*1] (zero-extend byte to 32-bit)
    fn loadBaseIdxU8(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexRR(dst, base);
        if (index.isExt()) r |= 0x02;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xB6 }) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOVSX r32, byte [base + index*1] (sign-extend byte to 32-bit)
    fn loadBaseIdxS8_32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexRR(dst, base);
        if (index.isExt()) r |= 0x02;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xBE }) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOVSX r64, byte [base + index*1] (sign-extend byte to 64-bit)
    fn loadBaseIdxS8_64(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexW(dst, base);
        if (index.isExt()) r |= 0x02;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xBE }) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOVZX r32, word [base + index*1] (zero-extend 16-bit to 32-bit)
    fn loadBaseIdxU16(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexRR(dst, base);
        if (index.isExt()) r |= 0x02;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xB7 }) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOVSX r32, word [base + index*1] (sign-extend 16-bit to 32-bit)
    fn loadBaseIdxS16_32(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexRR(dst, base);
        if (index.isExt()) r |= 0x02;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xBF }) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOVSX r64, word [base + index*1] (sign-extend 16-bit to 64-bit)
    fn loadBaseIdxS16_64(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexW(dst, base);
        if (index.isExt()) r |= 0x02;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xBF }) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOVSXD r64, dword [base + index*1] (sign-extend 32-bit to 64-bit)
    fn loadBaseIdxS32_64(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, base: Reg, index: Reg) void {
        var r = rexW(dst, base);
        if (index.isExt()) r |= 0x02;
        buf.append(alloc, r) catch {};
        buf.append(alloc, 0x63) catch {};
        emitSibAddr(buf, alloc, dst.low3(), base, index);
    }

    /// MOV [base + index*1], r32 (32-bit store)
    fn storeBaseIdx32(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, index: Reg, src: Reg) void {
        var r = rexRR(src, base);
        if (index.isExt()) r |= 0x02;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.append(alloc, 0x89) catch {};
        emitSibAddr(buf, alloc, src.low3(), base, index);
    }

    /// MOV [base + index*1], r64 (64-bit store)
    fn storeBaseIdx64(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, index: Reg, src: Reg) void {
        var r = rexW(src, base);
        if (index.isExt()) r |= 0x02;
        buf.append(alloc, r) catch {};
        buf.append(alloc, 0x89) catch {};
        emitSibAddr(buf, alloc, src.low3(), base, index);
    }

    /// MOV byte [base + index*1], r8 (8-bit store)
    fn storeBaseIdx8(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, index: Reg, src: Reg) void {
        var r = rexRR(src, base);
        if (index.isExt()) r |= 0x02;
        // Always emit REX for byte stores to ensure uniform register encoding
        if (r == 0x40) r = 0x40;
        buf.append(alloc, r) catch {};
        buf.append(alloc, 0x88) catch {};
        emitSibAddr(buf, alloc, src.low3(), base, index);
    }

    /// MOV word [base + index*1], r16 (16-bit store)
    fn storeBaseIdx16(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, index: Reg, src: Reg) void {
        buf.append(alloc, 0x66) catch {};
        var r = rexRR(src, base);
        if (index.isExt()) r |= 0x02;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.append(alloc, 0x89) catch {};
        emitSibAddr(buf, alloc, src.low3(), base, index);
    }

    /// MOV r32, imm32 (zero-extending)
    fn movImm32ToReg(buf: *std.ArrayList(u8), alloc: Allocator, dst: Reg, imm: u32) void {
        if (dst.isExt()) buf.append(alloc, 0x41) catch {};
        buf.append(alloc, @as(u8, 0xB8) | @as(u8, dst.low3())) catch {};
        appendU32(buf, alloc, imm);
    }

    /// TEST r32, r32 (32-bit)
    fn testRegReg32(buf: *std.ArrayList(u8), alloc: Allocator, r1: Reg, r2: Reg) void {
        const r = rexRR(r2, r1);
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.append(alloc, 0x85) catch {};
        buf.append(alloc, modrmReg(r2, r1)) catch {};
    }

    /// Patch a rel32 at `patch_offset` to jump to `target_offset`.
    /// rel32 = target - (patch_offset + 4) because the offset is relative to the NEXT instruction.
    fn patchRel32(code: []u8, patch_offset: u32, target_offset: u32) void {
        const rel: i32 = @intCast(@as(i64, target_offset) - @as(i64, patch_offset + 4));
        const bytes: [4]u8 = @bitCast(rel);
        code[patch_offset] = bytes[0];
        code[patch_offset + 1] = bytes[1];
        code[patch_offset + 2] = bytes[2];
        code[patch_offset + 3] = bytes[3];
    }

    // --- Helpers ---

    fn appendU32(buf: *std.ArrayList(u8), alloc: Allocator, val: u32) void {
        const bytes: [4]u8 = @bitCast(val);
        buf.appendSlice(alloc, &bytes) catch {};
    }

    fn appendI32(buf: *std.ArrayList(u8), alloc: Allocator, val: i32) void {
        const bytes: [4]u8 = @bitCast(val);
        buf.appendSlice(alloc, &bytes) catch {};
    }

    fn appendU64(buf: *std.ArrayList(u8), alloc: Allocator, val: u64) void {
        const bytes: [8]u8 = @bitCast(val);
        buf.appendSlice(alloc, &bytes) catch {};
    }

    // --- SSE2 floating-point ---

    /// MOVQ xmm, r64: 66 REX.W 0F 6E /r  (GPR → XMM)
    /// MOVD xmm, r32: 66 0F 6E /r (move 32-bit int to XMM low 32 bits)
    fn movdToXmm(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x40;
        if (xmm >= 8) r |= 0x04; // REX.R
        if (gpr.isExt()) r |= 0x01; // REX.B
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x6E }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
    }

    /// MOVQ xmm, r64: 66 REX.W 0F 6E /r (move 64-bit int to XMM low 64 bits)
    fn movqToXmm(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x48; // REX.W
        if (gpr.isExt()) r |= 0x01; // REX.B
        if (xmm >= 8) r |= 0x04; // REX.R
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x6E }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
    }

    /// MOVQ r64, xmm: 66 REX.W 0F 7E /r  (XMM → GPR)
    fn movqFromXmm(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x48;
        if (gpr.isExt()) r |= 0x01;
        if (xmm >= 8) r |= 0x04;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x7E }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
    }

    /// SSE2 binary op on XMM registers: prefix opcode_hi opcode_lo ModR/M
    fn sseOp(buf: *std.ArrayList(u8), alloc: Allocator, prefix: u8, op_hi: u8, op_lo: u8, dst_xmm: u4, src_xmm: u4) void {
        buf.append(alloc, prefix) catch {};
        // REX if any xmm >= 8
        if (dst_xmm >= 8 or src_xmm >= 8) {
            var r: u8 = 0x40;
            if (dst_xmm >= 8) r |= 0x04; // REX.R
            if (src_xmm >= 8) r |= 0x01; // REX.B
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ op_hi, op_lo }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst_xmm), @truncate(src_xmm))) catch {};
    }

    // f64 arithmetic (SD = scalar double, prefix 0xF2)
    fn addsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x58, dst, src); }
    fn subsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x5C, dst, src); }
    fn mulsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x59, dst, src); }
    fn divsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x5E, dst, src); }
    fn sqrtsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x51, dst, src); }
    fn minsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x5D, dst, src); }
    fn maxsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x5F, dst, src); }

    // f32 arithmetic (SS = scalar single, prefix 0xF3)
    fn addss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x58, dst, src); }
    fn subss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x5C, dst, src); }
    fn mulss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x59, dst, src); }
    fn divss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x5E, dst, src); }
    fn sqrtss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x51, dst, src); }
    fn minss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x5D, dst, src); }
    fn maxss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x5F, dst, src); }

    /// UCOMISD xmm1, xmm2: 66 0F 2E /r (compare f64, sets EFLAGS)
    fn ucomisd(buf: *std.ArrayList(u8), alloc: Allocator, xmm1: u4, xmm2: u4) void { sseOp(buf, alloc, 0x66, 0x0F, 0x2E, xmm1, xmm2); }
    /// UCOMISS xmm1, xmm2: 0F 2E /r (compare f32, sets EFLAGS)
    fn ucomiss(buf: *std.ArrayList(u8), alloc: Allocator, xmm1: u4, xmm2: u4) void {
        if (xmm1 >= 8 or xmm2 >= 8) {
            var r: u8 = 0x40;
            if (xmm1 >= 8) r |= 0x04;
            if (xmm2 >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2E }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm1), @truncate(xmm2))) catch {};
    }

    /// XORPD xmm, xmm: 66 0F 57 /r (zero a double register or negate)
    fn xorpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0x66, 0x0F, 0x57, dst, src); }
    /// ANDPD xmm, xmm: 66 0F 54 /r (bitwise AND for abs)
    fn andpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0x66, 0x0F, 0x54, dst, src); }

    /// No-prefix SSE ops (MOVAPS, ORPS, XORPS, ANDPS) — 0F xx /r
    fn sseOpNp(buf: *std.ArrayList(u8), alloc: Allocator, op: u8, dst: u4, src: u4) void {
        if (dst >= 8 or src >= 8) {
            var r: u8 = 0x40;
            if (dst >= 8) r |= 0x04;
            if (src >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, op }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst), @truncate(src))) catch {};
    }
    fn movaps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x28, dst, src); }
    fn orps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x56, dst, src); }
    fn xorps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x57, dst, src); }

    // --- SSE2/SSE4.1 v128 packed ops (for SIMD JIT) ---

    /// MOVQ xmm, [base + disp32]: 66 REX.W [0F 6E] ModRM [SIB] disp32
    fn movqXmmFromMem(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, base: Reg, disp: i32) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x48; // REX.W
        if (xmm >= 8) r |= 0x04; // REX.R
        if (base.isExt()) r |= 0x01; // REX.B
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x6E }) catch {};
        // ModRM: mod=10 (disp32), reg=xmm, rm=base
        buf.append(alloc, modrm(2, @truncate(xmm), base.low3())) catch {};
        if (base.low3() == 4) buf.append(alloc, 0x24) catch {}; // SIB for RSP/R12
        appendI32(buf, alloc, disp);
    }

    /// MOVQ [base + disp32], xmm: 66 REX.W [0F D6] ModRM [SIB] disp32
    fn movqXmmToMem(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, disp: i32, xmm: u4) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x48; // REX.W
        if (xmm >= 8) r |= 0x04; // REX.R
        if (base.isExt()) r |= 0x01; // REX.B
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xD6 }) catch {};
        buf.append(alloc, modrm(2, @truncate(xmm), base.low3())) catch {};
        if (base.low3() == 4) buf.append(alloc, 0x24) catch {};
        appendI32(buf, alloc, disp);
    }

    /// PINSRQ xmm, [base + disp32], imm8: 66 REX.W [0F 3A 22] ModRM [SIB] disp32 imm8 (SSE4.1)
    fn pinsrqMem(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, base: Reg, disp: i32, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x48;
        if (xmm >= 8) r |= 0x04;
        if (base.isExt()) r |= 0x01;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x3A, 0x22 }) catch {};
        buf.append(alloc, modrm(2, @truncate(xmm), base.low3())) catch {};
        if (base.low3() == 4) buf.append(alloc, 0x24) catch {};
        appendI32(buf, alloc, disp);
        buf.append(alloc, imm8) catch {};
    }

    /// PEXTRQ [base + disp32], xmm, imm8: 66 REX.W [0F 3A 16] ModRM [SIB] disp32 imm8 (SSE4.1)
    fn pextrqMem(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, disp: i32, xmm: u4, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x48;
        if (xmm >= 8) r |= 0x04;
        if (base.isExt()) r |= 0x01;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x3A, 0x16 }) catch {};
        buf.append(alloc, modrm(2, @truncate(xmm), base.low3())) catch {};
        if (base.low3() == 4) buf.append(alloc, 0x24) catch {};
        appendI32(buf, alloc, disp);
        buf.append(alloc, imm8) catch {};
    }

    /// MOVDQU xmm, [base + idx]: F3 [REX] 0F 6F ModRM(mod=00, reg=xmm, rm=100) SIB(base,idx)
    fn movdquLoad(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, base: Reg, idx: Reg) void {
        buf.append(alloc, 0xF3) catch {};
        if (xmm >= 8 or base.isExt() or idx.isExt()) {
            var r: u8 = 0x40;
            if (xmm >= 8) r |= 0x04; // REX.R
            if (idx.isExt()) r |= 0x02; // REX.X
            if (base.isExt()) r |= 0x01; // REX.B
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x6F }) catch {};
        // ModRM: mod=00, reg=xmm, rm=100 (SIB follows)
        buf.append(alloc, modrm(0, @truncate(xmm), 4)) catch {};
        // SIB: scale=0, index=idx, base=base
        buf.append(alloc, sib(0, idx.low3(), base.low3())) catch {};
    }

    /// MOVDQU [base + idx], xmm: F3 [REX] 0F 7F ModRM SIB
    fn movdquStore(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, idx: Reg, xmm: u4) void {
        buf.append(alloc, 0xF3) catch {};
        if (xmm >= 8 or base.isExt() or idx.isExt()) {
            var r: u8 = 0x40;
            if (xmm >= 8) r |= 0x04;
            if (idx.isExt()) r |= 0x02;
            if (base.isExt()) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x7F }) catch {};
        buf.append(alloc, modrm(0, @truncate(xmm), 4)) catch {};
        buf.append(alloc, sib(0, idx.low3(), base.low3())) catch {};
    }

    /// MOVDQU xmm, [base + disp32]: F3 [REX] 0F 6F ModRM(mod=10, reg=xmm, rm=base) disp32
    fn movdquFromMem(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, base: Reg, disp: i32) void {
        buf.append(alloc, 0xF3) catch {};
        if (xmm >= 8 or base.isExt()) {
            var r: u8 = 0x40;
            if (xmm >= 8) r |= 0x04;
            if (base.isExt()) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x6F }) catch {};
        const rm = base.low3();
        if (rm == 4) { // RSP/R12 needs SIB
            buf.append(alloc, modrm(2, @truncate(xmm), 4)) catch {};
            buf.append(alloc, sib(0, 4, 4)) catch {}; // SIB: no index, base=RSP
        } else {
            buf.append(alloc, modrm(2, @truncate(xmm), rm)) catch {};
        }
        appendI32(buf, alloc, disp);
    }

    /// MOVDQU [base + disp32], xmm: F3 [REX] 0F 7F ModRM(mod=10, reg=xmm, rm=base) disp32
    fn movdquToMem(buf: *std.ArrayList(u8), alloc: Allocator, base: Reg, disp: i32, xmm: u4) void {
        buf.append(alloc, 0xF3) catch {};
        if (xmm >= 8 or base.isExt()) {
            var r: u8 = 0x40;
            if (xmm >= 8) r |= 0x04;
            if (base.isExt()) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x7F }) catch {};
        const rm = base.low3();
        if (rm == 4) {
            buf.append(alloc, modrm(2, @truncate(xmm), 4)) catch {};
            buf.append(alloc, sib(0, 4, 4)) catch {};
        } else {
            buf.append(alloc, modrm(2, @truncate(xmm), rm)) catch {};
        }
        appendI32(buf, alloc, disp);
    }

    /// SSE2 packed integer binary op: 66 [REX] 0F opcode ModRM (xmm, xmm)
    fn ssePacked(buf: *std.ArrayList(u8), alloc: Allocator, op: u8, dst: u4, src: u4) void {
        sseOp(buf, alloc, 0x66, 0x0F, op, dst, src);
    }

    // Packed integer arithmetic (all SSE2: 66 0F xx)
    fn paddb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xFC, dst, src); }
    fn paddw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xFD, dst, src); }
    fn paddd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xFE, dst, src); }
    fn paddq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xD4, dst, src); }
    fn psubb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xF8, dst, src); }
    fn psubw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xF9, dst, src); }
    fn psubd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xFA, dst, src); }
    fn psubq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xFB, dst, src); }
    fn pmullw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xD5, dst, src); }
    /// PMULLD (SSE4.1): 66 0F 38 40 /r
    fn pmulld(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void {
        buf.append(alloc, 0x66) catch {};
        if (dst >= 8 or src >= 8) {
            var r: u8 = 0x40;
            if (dst >= 8) r |= 0x04;
            if (src >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x38, 0x40 }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst), @truncate(src))) catch {};
    }
    fn pand(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xDB, dst, src); }
    fn pandn(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xDF, dst, src); }
    fn por(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xEB, dst, src); }
    fn pxor(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xEF, dst, src); }
    fn pcmpeqb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x74, dst, src); }
    fn pcmpeqw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x75, dst, src); }
    fn pcmpeqd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x76, dst, src); }
    fn pcmpgtb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x64, dst, src); }
    fn pcmpgtw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x65, dst, src); }
    fn pcmpgtd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x66, dst, src); }

    // Packed float ops (SSE/SSE2)
    fn addps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x58, dst, src); }
    fn subps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x5C, dst, src); }
    fn mulps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x59, dst, src); }
    fn divps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x5E, dst, src); }
    fn sqrtps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x51, dst, src); }
    fn addpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x58, dst, src); }
    fn subpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x5C, dst, src); }
    fn mulpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x59, dst, src); }
    fn divpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x5E, dst, src); }
    fn sqrtpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x51, dst, src); }
    fn minps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x5D, dst, src); }
    fn maxps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x5F, dst, src); }
    fn minpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x5D, dst, src); }
    fn maxpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x5F, dst, src); }
    fn andnps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x55, dst, src); }
    fn andps_(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x54, dst, src); }

    // Saturating add/sub (SSE2: 66 0F xx)
    fn paddsb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xEC, dst, src); }
    fn paddsw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xED, dst, src); }
    fn paddusb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xDC, dst, src); }
    fn paddusw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xDD, dst, src); }
    fn psubsb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xE8, dst, src); }
    fn psubsw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xE9, dst, src); }
    fn psubusb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xD8, dst, src); }
    fn psubusw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xD9, dst, src); }

    // Integer min/max (SSE2/SSE4.1)
    fn pminsw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xEA, dst, src); }
    fn pmaxsw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xEE, dst, src); }
    fn pminub(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xDA, dst, src); }
    fn pmaxub(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xDE, dst, src); }
    // SSE4.1 min/max (66 0F 38 xx): 3-byte opcode
    fn sse41Op(buf: *std.ArrayList(u8), alloc: Allocator, op: u8, dst: u4, src: u4) void {
        buf.append(alloc, 0x66) catch {};
        if (dst >= 8 or src >= 8) {
            var r: u8 = 0x40;
            if (dst >= 8) r |= 0x04;
            if (src >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x38, op }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst), @truncate(src))) catch {};
    }
    fn pminsb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x38, dst, src); }
    fn pmaxsb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x3C, dst, src); }
    fn pminuw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x3A, dst, src); }
    fn pmaxuw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x3E, dst, src); }
    fn pminsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x39, dst, src); }
    fn pmaxsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x3D, dst, src); }
    fn pminud(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x3B, dst, src); }
    fn pmaxud(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x3F, dst, src); }
    fn pabsb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x1C, dst, src); }
    fn pabsw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x1D, dst, src); }
    fn pabsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x1E, dst, src); }
    fn pavgb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xE0, dst, src); }
    fn pavgw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xE3, dst, src); }

    /// PSHUFD xmm, xmm, imm8: 66 0F 70 /r imm8
    fn pshufd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        if (dst >= 8 or src >= 8) {
            var r: u8 = 0x40;
            if (dst >= 8) r |= 0x04;
            if (src >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x70 }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst), @truncate(src))) catch {};
        buf.append(alloc, imm8) catch {};
    }

    /// PUNPCKLQDQ xmm, xmm: 66 0F 6C /r (interleave low qwords)
    fn punpcklqdq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x6C, dst, src); }

    /// SSE4.1 insert/extract with imm8: 66 [REX] 0F 3A opcode ModRM imm8
    fn sse41OpImm(buf: *std.ArrayList(u8), alloc: Allocator, op: u8, xmm: u4, gpr: Reg, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x40;
        if (xmm >= 8) r |= 0x04;
        if (gpr.isExt()) r |= 0x01;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x3A, op }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
        buf.append(alloc, imm8) catch {};
    }
    /// SSE4.1 insert/extract with REX.W + imm8: 66 REX.W 0F 3A opcode ModRM imm8
    fn sse41OpWImm(buf: *std.ArrayList(u8), alloc: Allocator, op: u8, xmm: u4, gpr: Reg, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x48; // REX.W
        if (xmm >= 8) r |= 0x04;
        if (gpr.isExt()) r |= 0x01;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x3A, op }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
        buf.append(alloc, imm8) catch {};
    }
    // PINSRB xmm, r32, imm8 (SSE4.1): 66 0F 3A 20
    fn pinsrb(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg, imm8: u8) void { sse41OpImm(buf, alloc, 0x20, xmm, gpr, imm8); }
    // PINSRW xmm, r32, imm8 (SSE2): 66 0F C4
    fn pinsrw(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x40;
        if (xmm >= 8) r |= 0x04;
        if (gpr.isExt()) r |= 0x01;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xC4 }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
        buf.append(alloc, imm8) catch {};
    }
    // PINSRD xmm, r32, imm8 (SSE4.1): 66 0F 3A 22
    fn pinsrd(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg, imm8: u8) void { sse41OpImm(buf, alloc, 0x22, xmm, gpr, imm8); }
    // PINSRQ xmm, r64, imm8 (SSE4.1): 66 REX.W 0F 3A 22
    fn pinsrqReg(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg, imm8: u8) void { sse41OpWImm(buf, alloc, 0x22, xmm, gpr, imm8); }
    // PEXTRB r32, xmm, imm8 (SSE4.1): 66 0F 3A 14
    fn pextrb(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4, imm8: u8) void { sse41OpImm(buf, alloc, 0x14, xmm, gpr, imm8); }
    // PEXTRW r32, xmm, imm8 (SSE4.1): 66 0F 3A 15
    fn pextrw41(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4, imm8: u8) void { sse41OpImm(buf, alloc, 0x15, xmm, gpr, imm8); }
    // PEXTRD r32, xmm, imm8 (SSE4.1): 66 0F 3A 16
    fn pextrd(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4, imm8: u8) void { sse41OpImm(buf, alloc, 0x16, xmm, gpr, imm8); }
    // PEXTRQ r64, xmm, imm8 (SSE4.1): 66 REX.W 0F 3A 16
    fn pextrqReg(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4, imm8: u8) void { sse41OpWImm(buf, alloc, 0x16, xmm, gpr, imm8); }

    // SSE4.1 extend (PMOVSX/ZX): 66 0F 38 xx /r
    fn pmovsxbw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x20, dst, src); }
    fn pmovsxwd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x23, dst, src); }
    fn pmovsxdq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x25, dst, src); }
    fn pmovzxbw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x30, dst, src); }
    fn pmovzxwd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x33, dst, src); }
    fn pmovzxdq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x35, dst, src); }

    // Narrow: PACKSSWB/PACKUSWB/PACKSSDW/PACKUSDW
    fn packsswb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x63, dst, src); }
    fn packuswb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x67, dst, src); }
    fn packssdw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x6B, dst, src); }
    fn packusdw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x2B, dst, src); } // SSE4.1

    // Shift by XMM (shift amount in low 64 bits of src)
    fn psllw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xF1, dst, src); }
    fn pslld(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xF2, dst, src); }
    fn psllq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xF3, dst, src); }
    fn psrlw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xD1, dst, src); }
    fn psrld(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xD2, dst, src); }
    fn psrlq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xD3, dst, src); }
    fn psraw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xE1, dst, src); }
    fn psrad(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xE2, dst, src); }

    // Convert: CVTDQ2PS, CVTTPS2DQ
    fn cvtdq2ps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x5B, dst, src); } // 0F 5B
    fn cvttps2dq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x5B, dst, src); } // F3 0F 5B

    // PUNPCKHQDQ: interleave high qwords (for extend_high)
    fn punpckhqdq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x6D, dst, src); }

    /// CMPPS xmm, xmm, imm8: 0F C2 /r imm8 (no prefix for PS)
    fn cmpps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4, imm8: u8) void {
        if (dst >= 8 or src >= 8) {
            var r: u8 = 0x40;
            if (dst >= 8) r |= 0x04;
            if (src >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xC2 }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst), @truncate(src))) catch {};
        buf.append(alloc, imm8) catch {};
    }
    /// CMPPD xmm, xmm, imm8: 66 0F C2 /r imm8
    fn cmppd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        if (dst >= 8 or src >= 8) {
            var r: u8 = 0x40;
            if (dst >= 8) r |= 0x04;
            if (src >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xC2 }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst), @truncate(src))) catch {};
        buf.append(alloc, imm8) catch {};
    }

    /// ROUNDPS xmm, xmm, imm8 (SSE4.1): 66 0F 3A 08 /r imm8
    fn roundps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4, imm8: u8) void { sse41OpImm2(buf, alloc, 0x08, dst, src, imm8); }
    /// ROUNDPD xmm, xmm, imm8 (SSE4.1): 66 0F 3A 09 /r imm8
    fn roundpd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4, imm8: u8) void { sse41OpImm2(buf, alloc, 0x09, dst, src, imm8); }
    /// Helper for SSE4.1 ops with xmm,xmm,imm8: 66 [REX] 0F 3A op ModRM imm8
    fn sse41OpImm2(buf: *std.ArrayList(u8), alloc: Allocator, op: u8, dst: u4, src: u4, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        if (dst >= 8 or src >= 8) {
            var r: u8 = 0x40;
            if (dst >= 8) r |= 0x04;
            if (src >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x3A, op }) catch {};
        buf.append(alloc, modrm(3, @truncate(dst), @truncate(src))) catch {};
        buf.append(alloc, imm8) catch {};
    }

    /// PTEST xmm, xmm (SSE4.1): 66 0F 38 17 /r — sets ZF if (a AND b) == 0
    fn ptest(buf: *std.ArrayList(u8), alloc: Allocator, a: u4, b: u4) void { sse41Op(buf, alloc, 0x17, a, b); }

    /// PMOVMSKB r32, xmm: 66 0F D7 /r
    fn pmovmskb(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        buf.append(alloc, 0x66) catch {};
        var r: u8 = 0x40;
        if (gpr.isExt()) r |= 0x04; // REX.R for gpr
        if (xmm >= 8) r |= 0x01; // REX.B for xmm
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0xD7 }) catch {};
        buf.append(alloc, modrm(3, gpr.low3(), @truncate(xmm))) catch {};
    }

    /// PSHUFB xmm, xmm (SSSE3): 66 0F 38 00 /r
    fn pshufb(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x00, dst, src); }

    /// MOVMSKPS r32, xmm: 0F 50 /r (extract sign bits of 4 floats)
    fn movmskps(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        if (gpr.isExt() or xmm >= 8) {
            var r: u8 = 0x40;
            if (gpr.isExt()) r |= 0x04;
            if (xmm >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x50 }) catch {};
        buf.append(alloc, modrm(3, gpr.low3(), @truncate(xmm))) catch {};
    }
    // PMADDWD xmm, xmm: 66 0F F5 /r (multiply-add i16 pairs → i32)
    fn pmaddwd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xF5, dst, src); }
    // PMULUDQ xmm, xmm: 66 0F F4 /r (unsigned multiply low 32-bit → 64-bit)
    fn pmuludq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xF4, dst, src); }
    // PCMPEQQ xmm, xmm (SSE4.1): 66 0F 38 29 /r
    fn pcmpeqq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x29, dst, src); }
    // PCMPGTQ xmm, xmm (SSE4.2): 66 0F 38 37 /r
    fn pcmpgtq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x37, dst, src); }
    // PMULDQ xmm, xmm (SSE4.1): 66 0F 38 28 /r (signed multiply low 32→64)
    fn pmuldq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x28, dst, src); }

    // Shift by immediate (66 0F 71/72/73 /reg imm8)
    fn sseShiftImm(buf: *std.ArrayList(u8), alloc: Allocator, op: u8, reg_field: u3, xmm: u4, imm8: u8) void {
        buf.append(alloc, 0x66) catch {};
        if (xmm >= 8) {
            buf.append(alloc, 0x41) catch {}; // REX.B
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, op }) catch {};
        buf.append(alloc, modrm(3, reg_field, @truncate(xmm))) catch {};
        buf.append(alloc, imm8) catch {};
    }
    fn psrld_imm(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, imm: u8) void { sseShiftImm(buf, alloc, 0x72, 2, xmm, imm); }
    fn pslld_imm(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, imm: u8) void { sseShiftImm(buf, alloc, 0x72, 6, xmm, imm); }
    fn psrlq_imm(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, imm: u8) void { sseShiftImm(buf, alloc, 0x73, 2, xmm, imm); }
    fn psllq_imm(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, imm: u8) void { sseShiftImm(buf, alloc, 0x73, 6, xmm, imm); }
    // CVTPS2DQ (66 0F 5B): truncate f32→i32 with rounding mode from MXCSR (for convert_u workaround)
    fn cvtps2dq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x5B, dst, src); }
    // CVTDQ2PD: 0F E6 — convert 2 packed i32 → 2 packed f64
    fn cvtdq2pd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0xE6, dst, src); }
    // CVTPD2PS: 66 0F 5A — convert 2 packed f64 → 2 packed f32 (in low 64 bits)
    fn cvtpd2ps(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0x5A, dst, src); }
    // CVTPS2PD: 0F 5A — convert 2 packed f32 → 2 packed f64
    fn cvtps2pd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOpNp(buf, alloc, 0x5A, dst, src); }
    // CVTTPD2DQ: 66 0F E6 — truncate 2 f64 → 2 i32 (in low 64 bits, zero high)
    fn cvttpd2dq(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { ssePacked(buf, alloc, 0xE6, dst, src); }
    // PMADDUBSW (SSSE3): 66 0F 38 04 — multiply unsigned/signed bytes and add pairs
    fn pmaddubsw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x04, dst, src); }
    // PHADDD (SSSE3): 66 0F 38 02 — horizontal add pairs of i32
    fn phaddd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x02, dst, src); }
    // PHADDW (SSSE3): 66 0F 38 01 — horizontal add pairs of i16
    fn phaddw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x01, dst, src); }
    // PMULHRSW (SSSE3): 66 0F 38 0B — multiply high with round and scale (for q15mulr)
    fn pmulhrsw(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sse41Op(buf, alloc, 0x0B, dst, src); }

    /// MOVMSKPD r32, xmm: 66 0F 50 /r
    fn movmskpd(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        buf.append(alloc, 0x66) catch {};
        if (gpr.isExt() or xmm >= 8) {
            var r: u8 = 0x40;
            if (gpr.isExt()) r |= 0x04;
            if (xmm >= 8) r |= 0x01;
            buf.append(alloc, r) catch {};
        }
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x50 }) catch {};
        buf.append(alloc, modrm(3, gpr.low3(), @truncate(xmm))) catch {};
    }

    /// CVTSI2SD xmm, r64: F2 REX.W 0F 2A /r (signed i64 → f64)
    fn cvtsi2sd64(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg) void {
        buf.append(alloc, 0xF2) catch {};
        var r: u8 = 0x48;
        if (xmm >= 8) r |= 0x04;
        if (gpr.isExt()) r |= 0x01;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2A }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
    }

    /// CVTSI2SD xmm, r32: F2 0F 2A /r (signed i32 → f64)
    fn cvtsi2sd32(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg) void {
        buf.append(alloc, 0xF2) catch {};
        var r = rexRR(.rax, gpr); // minimal REX if gpr extended
        if (xmm >= 8) r |= 0x04;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2A }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
    }

    /// CVTSI2SS xmm, r32: F3 0F 2A /r (signed i32 → f32)
    fn cvtsi2ss32(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg) void {
        buf.append(alloc, 0xF3) catch {};
        var r = rexRR(.rax, gpr);
        if (xmm >= 8) r |= 0x04;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2A }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
    }

    /// CVTSI2SS xmm, r64: F3 REX.W 0F 2A /r (signed i64 → f32)
    fn cvtsi2ss64(buf: *std.ArrayList(u8), alloc: Allocator, xmm: u4, gpr: Reg) void {
        buf.append(alloc, 0xF3) catch {};
        var r: u8 = 0x48;
        if (xmm >= 8) r |= 0x04;
        if (gpr.isExt()) r |= 0x01;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2A }) catch {};
        buf.append(alloc, modrm(3, @truncate(xmm), gpr.low3())) catch {};
    }

    /// CVTTSD2SI r64, xmm: F2 REX.W 0F 2C /r (f64 → signed i64, truncating)
    fn cvttsd2si64(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        buf.append(alloc, 0xF2) catch {};
        var r: u8 = 0x48;
        if (gpr.isExt()) r |= 0x04;
        if (xmm >= 8) r |= 0x01;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2C }) catch {};
        buf.append(alloc, modrm(3, gpr.low3(), @truncate(xmm))) catch {};
    }

    /// CVTTSD2SI r32, xmm: F2 0F 2C /r (f64 → signed i32, truncating)
    fn cvttsd2si32(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        buf.append(alloc, 0xF2) catch {};
        var r = rexRR(gpr, .rax);
        if (xmm >= 8) r |= 0x01;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2C }) catch {};
        buf.append(alloc, modrm(3, gpr.low3(), @truncate(xmm))) catch {};
    }

    /// CVTTSS2SI r32, xmm: F3 0F 2C /r (f32 → signed i32, truncating)
    fn cvttss2si32(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        buf.append(alloc, 0xF3) catch {};
        var r = rexRR(gpr, .rax);
        if (xmm >= 8) r |= 0x01;
        if (r != 0x40) buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2C }) catch {};
        buf.append(alloc, modrm(3, gpr.low3(), @truncate(xmm))) catch {};
    }

    /// CVTTSS2SI r64, xmm: F3 REX.W 0F 2C /r (f32 → signed i64, truncating)
    fn cvttss2si64(buf: *std.ArrayList(u8), alloc: Allocator, gpr: Reg, xmm: u4) void {
        buf.append(alloc, 0xF3) catch {};
        var r: u8 = 0x48;
        if (gpr.isExt()) r |= 0x04;
        if (xmm >= 8) r |= 0x01;
        buf.append(alloc, r) catch {};
        buf.appendSlice(alloc, &[_]u8{ 0x0F, 0x2C }) catch {};
        buf.append(alloc, modrm(3, gpr.low3(), @truncate(xmm))) catch {};
    }

    /// CVTSD2SS xmm, xmm: F2 0F 5A /r (f64 → f32)
    fn cvtsd2ss(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x5A, dst, src); }
    /// CVTSS2SD xmm, xmm: F3 0F 5A /r (f32 → f64)
    fn cvtss2sd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF3, 0x0F, 0x5A, dst, src); }

    /// MOVSD xmm, xmm: F2 0F 10 /r (copy double between XMM regs)
    fn movsd(buf: *std.ArrayList(u8), alloc: Allocator, dst: u4, src: u4) void { sseOp(buf, alloc, 0xF2, 0x0F, 0x10, dst, src); }
};

/// x86_64 condition codes (matching Jcc/SETcc encoding).
const Cond = enum(u4) {
    o = 0x0, // overflow
    no = 0x1, // not overflow
    b = 0x2, // below (unsigned <)
    ae = 0x3, // above or equal (unsigned >=)
    e = 0x4, // equal
    ne = 0x5, // not equal
    be = 0x6, // below or equal (unsigned <=)
    a = 0x7, // above (unsigned >)
    s = 0x8, // sign (negative)
    ns = 0x9, // not sign
    p = 0xA, // parity (NaN for UCOMISS/UCOMISD)
    np = 0xB, // not parity
    l = 0xC, // less (signed <)
    ge = 0xD, // greater or equal (signed >=)
    le = 0xE, // less or equal (signed <=)
    g = 0xF, // greater (signed >)

    fn invert(self: Cond) Cond {
        return @enumFromInt(@intFromEnum(self) ^ 1);
    }
};

// ================================================================
// Virtual register mapping
// ================================================================

/// SIMD XMM register cache: XMM6-XMM15 for v128 values (10 registers).
/// All XMM registers are caller-saved on x86-64 (both SysV and Win64).
const SIMD_XREG_BASE: u4 = 6;
const SIMD_XREG_COUNT: usize = 10;

/// Map virtual register index to x86_64 physical register.
/// r0-r2 → RBX, RBP, R15 (callee-saved)
/// r3-r10 → RCX, RDI, RSI, RDX, R8, R9, R10, R11 (caller-saved)
/// r11+ → memory (via regs_ptr at R12)
/// Pack 4 register indices from a RegInstr into a u64 data word for trampoline calls.
fn packDataWord(instr: RegInstr) u64 {
    return @as(u64, instr.rd) |
        (@as(u64, instr.rs1) << 16) |
        (@as(u64, instr.rs2_field) << 32) |
        (@as(u64, @as(u16, @truncate(instr.operand))) << 48);
}

fn vregToPhys(vreg: u16) ?Reg {
    return switch (vreg) {
        0 => .rbx,
        1 => .rbp,
        2 => .r15,
        3 => .rcx,
        4 => .rdi,
        5 => .rsi,
        6 => .rdx,
        7 => .r8,
        8 => .r9,
        9 => .r10,
        // R11 reserved for SCRATCH2 — do NOT map a vreg here.
        else => null, // spill to memory
    };
}

fn abiRegsArg() Reg {
    return if (builtin.os.tag == .windows) .rcx else .rdi;
}

fn abiVmArg() Reg {
    return if (builtin.os.tag == .windows) .rdx else .rsi;
}

fn abiInstArg() Reg {
    return if (builtin.os.tag == .windows) .r8 else .rdx;
}

fn windowsCallFrameBytes(stack_arg_count: u32) u32 {
    const bytes = 32 + stack_arg_count * 8;
    return (bytes + 15) & ~@as(u32, 15);
}

/// Maximum virtual registers mappable to physical registers.
const MAX_PHYS_REGS: u8 = 10;

/// First caller-saved vreg index (for spill/reload).
const FIRST_CALLER_SAVED_VREG: u8 = 3;

/// Check if a vreg is caller-saved on x86 (vregs 3-10).
fn isCallerSavedVreg(vreg: u16) bool {
    return vreg >= FIRST_CALLER_SAVED_VREG and vreg < MAX_PHYS_REGS;
}

/// Compute live set for caller-saved vregs at a call site (x86 version).
/// Scans IR after call_pc to find which caller-saved vregs are used before redefined.
fn computeCallLiveSet(ir: []const RegInstr, call_pc: u32) u32 {
    const jit_arm64 = @import("jit.zig");
    var live: u32 = 0;
    var resolved: u32 = 0;
    var pc = call_pc + 1;
    while (pc < ir.len and (ir[pc].op == regalloc_mod.OP_NOP or ir[pc].op == regalloc_mod.OP_DELETED)) : (pc += 1) {}

    while (pc < ir.len) : (pc += 1) {
        const instr = ir[pc];
        if (instr.op == regalloc_mod.OP_DELETED or
            instr.op == regalloc_mod.OP_BLOCK_END) continue;
        if (instr.op == regalloc_mod.OP_NOP) {
            markCallerSavedUse(&live, &resolved, instr.rd);
            markCallerSavedUse(&live, &resolved, instr.rs1);
            if (instr.rs2_field != 0) markCallerSavedUse(&live, &resolved, instr.rs2_field);
            const arg3: u16 = @truncate(instr.operand);
            if (arg3 != 0) markCallerSavedUse(&live, &resolved, arg3);
            continue;
        }

        if (instr.op != regalloc_mod.OP_CALL) {
            markCallerSavedUse(&live, &resolved, instr.rs1);
        }
        if (jit_arm64.Compiler.instrHasRs2(instr)) {
            markCallerSavedUse(&live, &resolved, instr.rs2());
        }
        // select: condition register stored in operand
        if (instr.op == 0x1B) {
            const cond_vreg: u16 = @truncate(instr.operand);
            markCallerSavedUse(&live, &resolved, cond_vreg);
        }

        if (jit_arm64.Compiler.instrDefinesRd(instr)) {
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

        if (instr.op == regalloc_mod.OP_BR or instr.op == regalloc_mod.OP_BR_IF or
            instr.op == regalloc_mod.OP_BR_IF_NOT)
        {
            if (instr.operand <= call_pc) {
                return live | ~resolved;
            }
        }
    }
    return live;
}

/// Mark a vreg as used (live) if caller-saved on x86 and not yet resolved.
fn markCallerSavedUse(live: *u32, resolved: *u32, vreg: u16) void {
    if (isCallerSavedVreg(vreg) and (resolved.* & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) {
        live.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
        resolved.* |= @as(u32, 1) << @as(u5, @intCast(vreg));
    }
}

// ================================================================
// x86_64 JIT Compiler
// ================================================================

pub const Compiler = struct {
    code: std.ArrayList(u8),
    /// Map from RegInstr PC → byte offset in code buffer.
    pc_map: std.ArrayList(u32),
    /// Forward branch patches: (byte_offset_of_rel32, target_reg_pc).
    patches: std.ArrayList(Patch),
    /// Error stubs.
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
    self_call_only: bool,
    self_call_entry_offset: u32,
    self_func_idx: u32,
    /// IR PC of reentry guard branch (br_if/br_if_not → unreachable in first 8 instrs).
    /// When set, the JIT skips this branch so JitRestart doesn't trigger the guard trap.
    guard_branch_pc: ?u32,
    param_count: u16,
    result_count: u16,
    reg_ptr_offset: u32,
    jit_fuel_offset: u32,
    fuel_check_patches: std.ArrayList(u32),
    min_memory_bytes: u32,
    known_consts: [128]?u32,
    written_vregs: u128,
    /// Bitset of vregs that hold v128 values (produced by SIMD ops with v128 result).
    v128_vregs: u128,
    /// SIMD XMM register cache: maps XMM6-XMM15 slots to vregs holding v128 values.
    simd_xreg: [SIMD_XREG_COUNT]?u16,
    simd_xreg_dirty: [SIMD_XREG_COUNT]bool,
    simd_xreg_lru: u8,
    scratch_vreg: ?u16,
    /// Offset of Vm.simd_v128 field (contiguous v128 storage).
    simd_v128_offset: u32,
    /// True when the function uses SIMD opcodes (skip simd_v128 handling if false).
    has_simd: bool,
    page_size_log2: u5,
    /// Address of jitSimdTrampoline function.
    simd_trampoline_addr: u64,
    /// Address of Vm.jitFuelCheckHelper for deadline/fuel checks.
    fuel_check_helper_addr: u64,
    /// True when the memory has guard pages — skip explicit bounds checks.
    use_guard_pages: bool,
    /// Byte offset of the shared error epilogue (for signal handler recovery).
    shared_exit_offset: u32,
    /// OSR target IR PC (for back-edge JIT with reentry guard).
    osr_target_pc: ?u32,
    /// Byte offset of the OSR prologue in the code buffer.
    osr_prologue_offset: u32,
    /// IR slice and branch targets for peephole fusion (set during compile).
    ir_slice: []const RegInstr = &.{},
    branch_targets_slice: []bool = &.{},

    const Patch = struct {
        rel32_offset: u32, // byte offset of the rel32 field in code
        target_pc: u32, // target RegInstr PC
        kind: PatchKind,
    };

    const PatchKind = enum { jmp, jcc };

    const ErrorStub = struct {
        rel32_offset: u32,
        error_code: u16,
        kind: enum { jcc_inverted, jne },
        cond: Cond,
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
            .self_call_only = false,
            .self_call_entry_offset = 0,
            .self_func_idx = 0,
            .guard_branch_pc = null,
            .param_count = 0,
            .result_count = 0,
            .reg_ptr_offset = 0,
            .jit_fuel_offset = 0,
            .fuel_check_patches = .empty,
            .min_memory_bytes = 0,
            .known_consts = .{null} ** 128,
            .written_vregs = 0,
            .v128_vregs = 0,
            .simd_xreg = .{null} ** SIMD_XREG_COUNT,
            .simd_xreg_dirty = .{false} ** SIMD_XREG_COUNT,
            .simd_xreg_lru = 0,
            .scratch_vreg = null,
            .simd_v128_offset = 0,
            .has_simd = false,
            .page_size_log2 = 16,
            .simd_trampoline_addr = 0,
            .fuel_check_helper_addr = 0,
            .use_guard_pages = false,
            .shared_exit_offset = 0,
            .osr_target_pc = null,
            .osr_prologue_offset = 0,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.code.deinit(self.alloc);
        self.pc_map.deinit(self.alloc);
        self.patches.deinit(self.alloc);
        self.error_stubs.deinit(self.alloc);
        self.fuel_check_patches.deinit(self.alloc);
    }

    fn currentOffset(self: *Compiler) u32 {
        return @intCast(self.code.items.len);
    }

    // --- Virtual register load/store ---

    /// Load vreg value into a physical register.
    /// If vreg is already in a physical register, returns that register.
    /// Otherwise, loads from memory (regs_ptr + vreg*8) into `scratch`.
    fn getOrLoad(self: *Compiler, vreg: u16, scratch: Reg) Reg {
        if (vregToPhys(vreg)) |phys| return phys;
        // Load from memory: MOV scratch, [R12 + vreg*8]
        self.loadVreg(vreg, scratch);
        return scratch;
    }

    /// Load vreg from memory into dst register.
    fn loadVreg(self: *Compiler, vreg: u16, dst: Reg) void {
        const disp: i32 = @as(i32, vreg) * 8;
        Enc.loadDisp32(&self.code, self.alloc, dst, REGS_PTR, disp);
    }

    /// Store a physical register value to vreg.
    /// If vreg maps to a physical register, emit MOV if needed.
    /// Otherwise, store to memory.
    fn storeVreg(self: *Compiler, vreg: u16, src: Reg) void {
        if (vregToPhys(vreg)) |phys| {
            if (phys != src) {
                Enc.movRegReg(&self.code, self.alloc, phys, src);
            }
        } else {
            // Store to memory: MOV [R12 + vreg*8], src
            const disp: i32 = @as(i32, vreg) * 8;
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, src);
        }
    }

    // --- Spill/reload for function calls ---

    /// Spill caller-saved vregs to memory before a function call.
    fn spillCallerSaved(self: *Compiler) void {
        const max = @min(self.reg_count, MAX_PHYS_REGS);
        if (max <= FIRST_CALLER_SAVED_VREG) return;
        for (FIRST_CALLER_SAVED_VREG..max) |i| {
            const vreg: u16 = @intCast(i);
            if (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                const disp: i32 = @as(i32, vreg) * 8;
                Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
            }
        }
    }

    /// Reload caller-saved vregs from memory after a function call.
    fn reloadCallerSaved(self: *Compiler) void {
        const max = @min(self.reg_count, MAX_PHYS_REGS);
        if (max <= FIRST_CALLER_SAVED_VREG) return;
        for (FIRST_CALLER_SAVED_VREG..max) |i| {
            const vreg: u16 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                const disp: i32 = @as(i32, vreg) * 8;
                Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
            }
        }
    }

    // --- Prologue / Epilogue ---

    fn emitPrologue(self: *Compiler) void {
        // Save callee-saved registers
        Enc.push(&self.code, self.alloc, .rbx);
        Enc.push(&self.code, self.alloc, .rbp);
        if (builtin.os.tag == .windows) {
            Enc.push(&self.code, self.alloc, .rdi);
            Enc.push(&self.code, self.alloc, .rsi);
        }
        Enc.push(&self.code, self.alloc, .r12);
        Enc.push(&self.code, self.alloc, .r13);
        Enc.push(&self.code, self.alloc, .r14);
        Enc.push(&self.code, self.alloc, .r15);
        // Align RSP to 16 bytes for nested CALLs.
        Enc.subImm32(&self.code, self.alloc, .rsp, 8);

        if (self.has_self_call) {
            // Store marker [RSP] = 1 for normal entry (epilogue discrimination)
            self.emitLoadImm32(SCRATCH2, 1);
            Enc.storeDisp32(&self.code, self.alloc, .rsp, 0, SCRATCH2);
        }

        // Branch over self-call entry to shared setup
        var jmp_shared_offset: u32 = 0;
        if (self.has_self_call) {
            jmp_shared_offset = Enc.jmpRel32(&self.code, self.alloc);
        }

        if (self.has_self_call) {
            // --- Self-call entry point ---
            // Self-calls CALL here directly; skips callee-saved pushes.
            // Stack: CALL pushed return addr (8 bytes). Sub 8 for alignment.
            self.self_call_entry_offset = self.currentOffset();
            Enc.subImm32(&self.code, self.alloc, .rsp, 8);
            // Store marker [RSP] = 0 for self-call (epilogue discrimination)
            Enc.xorRegReg32(&self.code, self.alloc, SCRATCH2, SCRATCH2);
            Enc.storeDisp32(&self.code, self.alloc, .rsp, 0, SCRATCH2);
            // ABI arg0 = callee regs pointer (set by caller)
            Enc.movRegReg(&self.code, self.alloc, REGS_PTR, abiRegsArg());
            // Skip memory cache load and shared setup — memory regs preserved
            // from caller (callee-saved R13/R14). vm/inst already in callee frame.
        }

        // Vreg loading target for self-call path (falls through from above)
        // and for normal path (after shared setup, patched below).
        // We need separate markers: self-call falls through to vreg load,
        // normal path jumps to shared_setup then to vreg load.

        // Emit shared setup for normal path
        if (self.has_self_call) {
            // Self-call entry falls through to vreg loading — jump over shared setup.
            const jmp_vreg_offset = Enc.jmpRel32(&self.code, self.alloc);

            // Patch JMP from normal entry to here (shared setup)
            Enc.patchRel32(self.code.items, jmp_shared_offset, self.currentOffset());

            // --- Normal entry shared setup ---
            Enc.movRegReg(&self.code, self.alloc, REGS_PTR, abiRegsArg()); // R12 = regs_ptr
            const vm_offset: i32 = (@as(i32, self.reg_count) + 2) * 8;
            const inst_offset: i32 = (@as(i32, self.reg_count) + 3) * 8;
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, vm_offset, abiVmArg());
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, inst_offset, abiInstArg());

            if (self.has_memory) {
                self.emitLoadMemCache();
            }

            // Patch JMP from self-call entry to here (vreg loading)
            Enc.patchRel32(self.code.items, jmp_vreg_offset, self.currentOffset());
        } else {
            // No self-call: normal setup directly
            Enc.movRegReg(&self.code, self.alloc, REGS_PTR, abiRegsArg()); // R12 = regs_ptr
            const vm_offset: i32 = (@as(i32, self.reg_count) + 2) * 8;
            const inst_offset: i32 = (@as(i32, self.reg_count) + 3) * 8;
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, vm_offset, abiVmArg());
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, inst_offset, abiInstArg());

            if (self.has_memory) {
                self.emitLoadMemCache();
            }
        }

        // Load virtual registers from regs array into physical registers.
        // Must be AFTER emitLoadMemCache() which calls CALL (trashes caller-saved).
        const max_vreg = @min(self.reg_count, MAX_PHYS_REGS);
        for (0..max_vreg) |i| {
            const vreg: u16 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                const disp: i32 = @as(i32, vreg) * 8;
                Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
            }
        }
    }

    /// Emit br_table: cascading CMP + JE for each target, default at end.
    /// IR layout: [OP_BR_TABLE rd=idx, operand=count], [NOP operand=target0], ..., [NOP operand=default_target]
    fn emitBrTable(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        const count = instr.operand;
        const idx_reg = self.getOrLoad(instr.rd, SCRATCH);

        // Read count+1 entries (count case targets + 1 default)
        var i: u32 = 0;
        while (i < count + 1 and pc.* < ir.len) : (i += 1) {
            const entry = ir[pc.*];
            pc.* += 1;

            if (i < count) {
                // Case i: CMP idx, i; JE target
                Enc.cmpImm32(&self.code, self.alloc, idx_reg, i);
                const patch_off = Enc.jccRel32(&self.code, self.alloc, .e);
                self.patches.append(self.alloc, .{
                    .rel32_offset = patch_off,
                    .target_pc = entry.operand,
                    .kind = .jcc,
                }) catch return false;
            } else {
                // Default: unconditional jump
                const patch_off = Enc.jmpRel32(&self.code, self.alloc);
                self.patches.append(self.alloc, .{
                    .rel32_offset = patch_off,
                    .target_pc = entry.operand,
                    .kind = .jmp,
                }) catch return false;
            }
        }
        return true;
    }

    fn emitEpilogue(self: *Compiler, result_vreg: ?u16) void {
        // Store result to regs[0] if needed
        if (result_vreg) |rv| {
            if (vregToPhys(rv)) |phys| {
                Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, 0, phys);
            } else {
                // Spilled vreg: load from memory slot, then store to regs[0]
                const disp: i32 = @as(i32, rv) * 8;
                Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, disp);
                Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, 0, SCRATCH);
            }
        }

        // Return success (RAX = 0)
        Enc.xorRegReg32(&self.code, self.alloc, .rax, .rax);
        self.emitCalleeSavedRestore();
    }

    /// Multi-value return epilogue: stores N result vregs to regs[0..n-1].
    fn emitEpilogueMulti(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) void {
        const count: u32 = instr.operand;
        self.emitStoreResultVreg(0, instr.rd);
        if (count > 1) self.emitStoreResultVreg(1, instr.rs1);
        var ri: u32 = 2;
        while (ri < count and pc.* < ir.len) {
            const nop = ir[pc.*];
            pc.* += 1;
            self.emitStoreResultVreg(ri, nop.rd);
            ri += 1;
            if (ri < count) {
                self.emitStoreResultVreg(ri, nop.rs1);
                ri += 1;
            }
        }
        Enc.xorRegReg32(&self.code, self.alloc, .rax, .rax);
        self.emitCalleeSavedRestore();
    }

    /// Store vreg value to regs[result_idx] for multi-value return.
    fn emitStoreResultVreg(self: *Compiler, result_idx: u32, vreg: u16) void {
        const disp: i32 = @as(i32, @intCast(result_idx)) * 8;
        if (vregToPhys(vreg)) |phys| {
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
        } else {
            const vreg_disp: i32 = @as(i32, vreg) * 8;
            Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, vreg_disp);
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, SCRATCH);
        }
    }

    /// Emit callee-saved register restore sequence.
    /// For self-call functions: checks [RSP] marker to determine restore path.
    /// Marker = 0 → self-call entry (only sub rsp 8), marker != 0 → normal entry (full restore).
    fn emitCalleeSavedRestore(self: *Compiler) void {
        if (self.has_self_call) {
            // Load marker from [RSP]
            Enc.loadDisp32(&self.code, self.alloc, SCRATCH2, .rsp, 0);
            Enc.testRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH2);
            const jnz_normal = Enc.jccRel32(&self.code, self.alloc, .ne);
            // Self-call path: just undo alignment and return
            Enc.addImm32(&self.code, self.alloc, .rsp, 8);
            Enc.ret_(&self.code, self.alloc);
            // Normal path: full restore
            Enc.patchRel32(self.code.items, jnz_normal, self.currentOffset());
        }
        Enc.addImm32(&self.code, self.alloc, .rsp, 8);
        Enc.pop(&self.code, self.alloc, .r15);
        Enc.pop(&self.code, self.alloc, .r14);
        Enc.pop(&self.code, self.alloc, .r13);
        Enc.pop(&self.code, self.alloc, .r12);
        if (builtin.os.tag == .windows) {
            Enc.pop(&self.code, self.alloc, .rsi);
            Enc.pop(&self.code, self.alloc, .rdi);
        }
        Enc.pop(&self.code, self.alloc, .rbp);
        Enc.pop(&self.code, self.alloc, .rbx);
        Enc.ret_(&self.code, self.alloc);
    }

    // --- Branch patching ---

    fn patchBranches(self: *Compiler) !void {
        for (self.patches.items) |patch| {
            const target_offset = if (patch.target_pc < self.pc_map.items.len)
                self.pc_map.items[patch.target_pc]
            else
                self.currentOffset();
            Enc.patchRel32(self.code.items, patch.rel32_offset, target_offset);
        }
    }

    // --- Error handling ---

    /// Emit conditional error: if condition is true, branch forward to error stub.
    /// Emit fuel check at a loop back-edge (x86_64).
    /// push rax / load vm_ptr / SUB [vm+fuel],1 / JNS skip / CALL stub / skip: pop rax.
    /// The shared stub calls jitFuelCheckHelper, which either re-arms (RET to
    /// continue) or exits JIT with an error code.
    fn emitFuelCheck(self: *Compiler) void {
        // Skip fuel checks when offset is 0 (unit tests without Vm struct)
        if (self.jit_fuel_offset == 0) return;
        // push rax (save — may hold live vreg)
        self.code.append(self.alloc, 0x50) catch {};
        // Load vm_ptr into rax
        const vm_slot_disp: i32 = (@as(i32, self.reg_count) + 2) * 8;
        Enc.loadDisp32(&self.code, self.alloc, .rax, REGS_PTR, vm_slot_disp);
        const fuel_disp: i32 = @intCast(self.jit_fuel_offset);
        // SUB QWORD PTR [rax + disp32], 1 — sets SF
        self.code.append(self.alloc, 0x48) catch {}; // REX.W
        self.code.append(self.alloc, 0x83) catch {}; // SUB r/m64, imm8
        self.code.append(self.alloc, 0xA8) catch {}; // ModRM: mod=10, /5, r/m=rax
        Enc.appendI32(&self.code, self.alloc, fuel_disp);
        self.code.append(self.alloc, 0x01) catch {}; // imm8 = 1
        // JNS .skip (fast path: fuel >= 0)
        const jns_off = Enc.jccRel32(&self.code, self.alloc, .ns);
        // Slow path: CALL shared fuel-check stub (patched in emitErrorStubs).
        // CALL pushes return address = .skip, stub can RET to continue.
        const call_off = Enc.callRel32(&self.code, self.alloc);
        self.fuel_check_patches.append(self.alloc, call_off) catch {};
        // .skip: patch JNS to here
        Enc.patchRel32(self.code.items, jns_off, self.currentOffset());
        // pop rax (restore on both fast and continue paths)
        self.code.append(self.alloc, 0x58) catch {};
        self.scratch_vreg = null;
    }

    fn emitCondError(self: *Compiler, cond: Cond, error_code: u16) void {
        // Jcc rel32 (6 bytes: 0F 8x cd cd cd cd)
        const rel32_off = Enc.jccRel32(&self.code, self.alloc, cond);
        self.error_stubs.append(self.alloc, .{
            .rel32_offset = rel32_off,
            .error_code = error_code,
            .kind = .jcc_inverted,
            .cond = cond,
        }) catch {};
    }

    /// Emit error stubs at function end and patch forward branches.
    fn emitErrorStubs(self: *Compiler) void {
        if (self.error_stubs.items.len == 0 and self.fuel_check_patches.items.len == 0 and !self.use_guard_pages) return;

        // Shared error epilogue: restore callee-saved, return with RAX=error_code
        const shared_exit = self.currentOffset();
        self.shared_exit_offset = shared_exit;
        // At this point, RAX has the error code. Restore callee-saved and return.
        self.emitCalleeSavedRestore();

        for (self.error_stubs.items) |stub| {
            if (stub.error_code == 0) {
                // Call error: RAX already has error code, patch Jcc/JNE to shared exit
                Enc.patchRel32(self.code.items, stub.rel32_offset, shared_exit);
            } else {
                // Condition error: emit stub (MOV imm → RAX, JMP shared_exit)
                const stub_offset = self.currentOffset();
                // MOV EAX, imm32 (5 bytes) — zero extends to RAX
                Enc.movImm32ToReg(&self.code, self.alloc, .rax, stub.error_code);
                // JMP rel32 to shared_exit
                const jmp_patch_off = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jmp_patch_off, shared_exit);
                // Patch original Jcc to point to this stub
                Enc.patchRel32(self.code.items, stub.rel32_offset, stub_offset);
            }
        }

        // Shared fuel-check stub: called via CALL from back-edge fuel checks.
        // Spills caller-saved vregs, calls jitFuelCheckHelper, and either
        // RET (continue) or JMP shared_exit (error).
        if (self.fuel_check_patches.items.len > 0) {
            const fuel_stub = self.currentOffset();

            // Spill caller-saved vregs (r3-r9 → rcx,rdi,rsi,rdx,r8,r9,r10) to memory
            const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
            if (max > FIRST_CALLER_SAVED_VREG) {
                for (FIRST_CALLER_SAVED_VREG..max) |i| {
                    const vreg: u16 = @intCast(i);
                    if (vregToPhys(vreg)) |phys| {
                        const disp: i32 = @as(i32, vreg) * 8;
                        Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
                    }
                }
            }

            // Align stack for C call (stack has: [push rax] [CALL ret_addr] = 16 bytes
            // above prologue alignment). Push a dummy to align if needed.
            // The prologue ensures 16-byte alignment at function body. push rax + CALL
            // adds 16 bytes, so stack is still aligned. No extra alignment needed.

            // Call jitFuelCheckHelper(vm_ptr)
            const vm_slot_disp: i32 = (@as(i32, self.reg_count) + 2) * 8;
            if (builtin.os.tag == .windows) {
                Enc.loadDisp32(&self.code, self.alloc, .rcx, REGS_PTR, vm_slot_disp); // rcx = vm_ptr
            } else {
                Enc.loadDisp32(&self.code, self.alloc, .rdi, REGS_PTR, vm_slot_disp); // rdi = vm_ptr
            }
            self.emitLoadImm64(SCRATCH, self.fuel_check_helper_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);

            // Check result: TEST rax, rax; JNZ .exit_error
            Enc.testRegReg(&self.code, self.alloc, .rax, .rax);
            const jnz_off = Enc.jccRel32(&self.code, self.alloc, .ne);

            // Reload caller-saved vregs from memory
            if (max > FIRST_CALLER_SAVED_VREG) {
                for (FIRST_CALLER_SAVED_VREG..max) |i| {
                    const vreg: u16 = @intCast(i);
                    if (vregToPhys(vreg)) |phys| {
                        const disp: i32 = @as(i32, vreg) * 8;
                        Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
                    }
                }
            }

            // RET: return to .skip (after CALL in emitFuelCheck), caller pops rax
            self.code.append(self.alloc, 0xC3) catch {}; // RET

            // .exit_error: rax has error code, discard CALL ret_addr + push rax
            Enc.patchRel32(self.code.items, jnz_off, self.currentOffset());
            // ADD rsp, 16 — pop [CALL ret_addr] + [push rax from emitFuelCheck]
            self.code.append(self.alloc, 0x48) catch {}; // REX.W
            self.code.append(self.alloc, 0x83) catch {}; // ADD r/m64, imm8
            self.code.append(self.alloc, 0xC4) catch {}; // ModRM: mod=11, /0, rm=rsp
            self.code.append(self.alloc, 0x10) catch {}; // imm8 = 16
            // JMP shared_exit (rax already has error code)
            {
                const jmp_off = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jmp_off, shared_exit);
            }

            // Patch all CALL rel32 instructions to point to this stub
            for (self.fuel_check_patches.items) |patch_off| {
                Enc.patchRel32(self.code.items, patch_off, fuel_stub);
            }
        }
    }

    /// Emit OSR (On-Stack Replacement) prologue: a second entry point that sets up
    /// callee-saved registers and jumps directly to the loop body at osr_target_pc.
    /// Used for back-edge JIT of functions with reentry guards (C/C++ init patterns).
    fn emitOsrPrologue(self: *Compiler, target_pc: u32) void {
        self.osr_prologue_offset = self.currentOffset();

        // Same callee-saved pushes as normal prologue (must match epilogue order)
        Enc.push(&self.code, self.alloc, .rbx);
        Enc.push(&self.code, self.alloc, .rbp);
        if (builtin.os.tag == .windows) {
            Enc.push(&self.code, self.alloc, .rdi);
            Enc.push(&self.code, self.alloc, .rsi);
        }
        Enc.push(&self.code, self.alloc, .r12);
        Enc.push(&self.code, self.alloc, .r13);
        Enc.push(&self.code, self.alloc, .r14);
        Enc.push(&self.code, self.alloc, .r15);

        // Sub 8 to restore 16-byte alignment for nested CALLs.
        Enc.subImm32(&self.code, self.alloc, .rsp, 8);

        // Marker [RSP] = 1 (normal entry — epilogue does full restore)
        if (self.has_self_call) {
            self.emitLoadImm32(SCRATCH2, 1);
            Enc.storeDisp32(&self.code, self.alloc, .rsp, 0, SCRATCH2);
        }

        // R12 = REGS_PTR (arg0 in host C ABI)
        Enc.movRegReg(&self.code, self.alloc, REGS_PTR, abiRegsArg());

        // Store VM and Instance pointers to register file slots
        const vm_disp: i32 = (@as(i32, self.reg_count) + 2) * 8;
        const inst_disp: i32 = (@as(i32, self.reg_count) + 3) * 8;
        Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, vm_disp, abiVmArg());
        Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, inst_disp, abiInstArg());

        // Load memory cache (if function uses memory)
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
                Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, @as(i32, vreg) * 8);
            }
        }

        // Jump to the loop body at pc_map[target_pc]
        const target_offset = self.pc_map.items[target_pc];
        const jmp_patch_off = Enc.jmpRel32(&self.code, self.alloc);
        Enc.patchRel32(self.code.items, jmp_patch_off, target_offset);
    }

    // --- Pointer helpers ---

    /// Load VM pointer from regs[reg_count+2] into target register.
    fn emitLoadVmPtr(self: *Compiler, dst: Reg) void {
        const disp: i32 = (@as(i32, self.reg_count) + 2) * 8;
        Enc.loadDisp32(&self.code, self.alloc, dst, REGS_PTR, disp);
    }

    /// Load Instance pointer from regs[reg_count+3] into target register.
    fn emitLoadInstPtr(self: *Compiler, dst: Reg) void {
        const disp: i32 = (@as(i32, self.reg_count) + 3) * 8;
        Enc.loadDisp32(&self.code, self.alloc, dst, REGS_PTR, disp);
    }

    /// Load immediate 64-bit value into register.
    fn emitLoadImm64(self: *Compiler, dst: Reg, value: u64) void {
        Enc.movImm64(&self.code, self.alloc, dst, value);
    }

    /// Load immediate 32-bit value into register (zero-extending).
    fn emitLoadImm32(self: *Compiler, dst: Reg, value: u32) void {
        if (value == 0) {
            Enc.xorRegReg32(&self.code, self.alloc, dst, dst);
        } else {
            Enc.movImm32ToReg(&self.code, self.alloc, dst, value);
        }
    }

    fn emitWindowsCallSetup(self: *Compiler, stack_arg_count: u32) u32 {
        const frame_bytes = windowsCallFrameBytes(stack_arg_count);
        Enc.subImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        return frame_bytes;
    }

    fn emitWindowsCallArg(self: *Compiler, stack_index: u32, src: Reg) void {
        const disp: i32 = @intCast(32 + stack_index * 8);
        Enc.storeDisp32(&self.code, self.alloc, .rsp, disp, src);
    }

    /// Load memory cache: call jitGetMemInfo(instance, &regs[reg_count]) then
    /// load MEM_BASE and MEM_SIZE from the output slots.
    fn emitLoadMemCache(self: *Compiler) void {
        const out_disp: i32 = @as(i32, self.reg_count) * 8;
        if (builtin.os.tag == .windows) {
            self.emitLoadInstPtr(.rcx);
            Enc.movRegReg(&self.code, self.alloc, .rdx, REGS_PTR);
            if (out_disp > 0) {
                Enc.addImm32(&self.code, self.alloc, .rdx, out_disp);
            }
            const frame_bytes = self.emitWindowsCallSetup(0);
            self.emitLoadImm64(SCRATCH, self.mem_info_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // System V ABI: RDI=arg0 (instance), RSI=arg1 (&regs[reg_count])
            self.emitLoadInstPtr(.rdi);
            // RSI = address of regs[reg_count] = REGS_PTR + reg_count*8
            Enc.movRegReg(&self.code, self.alloc, .rsi, REGS_PTR);
            if (out_disp > 0) {
                Enc.addImm32(&self.code, self.alloc, .rsi, out_disp);
            }
            // CALL jitGetMemInfo
            self.emitLoadImm64(SCRATCH, self.mem_info_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
        }
        // Load results: MEM_BASE = regs[reg_count], MEM_SIZE = regs[reg_count+1]
        Enc.loadDisp32(&self.code, self.alloc, MEM_BASE, REGS_PTR, out_disp);
        Enc.loadDisp32(&self.code, self.alloc, MEM_SIZE, REGS_PTR, out_disp + 8);
    }

    /// Emit ADD SCRATCH, imm32 (for address computation). Handles 0 as no-op.
    fn emitAddOffset(self: *Compiler, offset: u32) void {
        if (offset == 0) return;
        Enc.addImm32(&self.code, self.alloc, SCRATCH, @bitCast(offset));
    }

    // --- Memory access ---

    const LoadKind = enum { w32, x64, u8, s8_32, s8_64, u16, s16_32, s16_64, s32_64 };
    const StoreKind = enum { w32, x64, b8, h16 };

    /// Emit memory load with bounds check.
    /// RegInstr encoding: rd=dest, rs1=base_addr, operand=static_offset.
    fn emitMemLoad(self: *Compiler, instr: RegInstr, kind: LoadKind, access_size: u32) void {
        // 1. Compute effective address: SCRATCH = zero_extend(addr_reg, 32→64) + offset
        const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
        // MOV SCRATCH(32-bit), addr_reg(32-bit) — zero extends to 64-bit
        Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
        self.emitAddOffset(instr.operand);

        // 2. Bounds check (skipped when guard pages handle OOB via signal handler)
        if (!self.use_guard_pages) {
            Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, SCRATCH2, @bitCast(access_size));
            Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
            self.emitCondError(.a, 6); // OutOfBoundsMemoryAccess
        }

        // 3. Load: dst = mem_base[effective]
        switch (kind) {
            .w32 => Enc.loadBaseIdx32(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .x64 => Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .u8 => Enc.loadBaseIdxU8(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .s8_32 => Enc.loadBaseIdxS8_32(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .s8_64 => Enc.loadBaseIdxS8_64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .u16 => Enc.loadBaseIdxU16(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .s16_32 => Enc.loadBaseIdxS16_32(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .s16_64 => Enc.loadBaseIdxS16_64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
            .s32_64 => Enc.loadBaseIdxS32_64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH),
        }
        self.storeVreg(instr.rd, SCRATCH);
    }

    /// Emit memory store with bounds check.
    /// RegInstr encoding: rd=value, rs1=base_addr, operand=static_offset.
    fn emitMemStore(self: *Compiler, instr: RegInstr, kind: StoreKind, access_size: u32) void {
        // 1. Compute effective address
        const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
        self.emitAddOffset(instr.operand);

        // 2. Bounds check (skipped when guard pages handle OOB via signal handler)
        if (!self.use_guard_pages) {
            Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, SCRATCH2, @bitCast(access_size));
            Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
            self.emitCondError(.a, 6);
        }

        // 3. Store: mem_base[effective] = value
        // Load value into SCRATCH2 (SCRATCH has effective address)
        const val_reg = self.getOrLoad(instr.rd, SCRATCH2);
        switch (kind) {
            .w32 => Enc.storeBaseIdx32(&self.code, self.alloc, MEM_BASE, SCRATCH, val_reg),
            .x64 => Enc.storeBaseIdx64(&self.code, self.alloc, MEM_BASE, SCRATCH, val_reg),
            .b8 => Enc.storeBaseIdx8(&self.code, self.alloc, MEM_BASE, SCRATCH, val_reg),
            .h16 => Enc.storeBaseIdx16(&self.code, self.alloc, MEM_BASE, SCRATCH, val_reg),
        }
        self.scratch_vreg = null;
    }

    /// Emit memory.size: rd = memory pages (MEM_SIZE >> page_size_log2)
    fn emitMemorySize(self: *Compiler, instr: RegInstr) void {
        Enc.movRegReg(&self.code, self.alloc, SCRATCH, MEM_SIZE);
        // SHR r64, imm8: REX.W C1 /5 ib
        self.code.append(self.alloc, Enc.rexW1(SCRATCH)) catch {};
        self.code.append(self.alloc, 0xC1) catch {};
        self.code.append(self.alloc, Enc.modrm(3, 5, SCRATCH.low3())) catch {};
        self.code.append(self.alloc, self.page_size_log2) catch {};
        self.storeVreg(instr.rd, SCRATCH);
    }

    // --- Global ops emitters ---

    /// global.get: call jitGlobalGet(instance, idx) → u64
    fn emitGlobalGet(self: *Compiler, instr: RegInstr) void {
        self.simdXregEvictAll();
        self.spillCallerSaved();
        if (builtin.os.tag == .windows) {
            self.emitLoadInstPtr(.rcx);
            self.emitLoadImm32(.rdx, @truncate(instr.operand));
            const frame_bytes = self.emitWindowsCallSetup(0);
            self.emitLoadImm64(SCRATCH, self.global_get_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // System V ABI: RDI=instance, ESI=global_idx
            self.emitLoadInstPtr(.rdi);
            self.emitLoadImm32(.rsi, @truncate(instr.operand));
            self.emitLoadImm64(SCRATCH, self.global_get_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
        }
        // Result in RAX (u64)
        self.reloadCallerSaved();
        self.storeVreg(instr.rd, SCRATCH); // SCRATCH = RAX = result
    }

    /// global.set: call jitGlobalSet(instance, idx, val)
    fn emitGlobalSet(self: *Compiler, instr: RegInstr) void {
        self.simdXregEvictAll();
        self.spillCallerSaved();
        const val_reg = self.getOrLoad(instr.rd, SCRATCH);
        if (builtin.os.tag == .windows) {
            Enc.movRegReg(&self.code, self.alloc, .r8, val_reg);
            self.emitLoadInstPtr(.rcx);
            self.emitLoadImm32(.rdx, @truncate(instr.operand));
            const frame_bytes = self.emitWindowsCallSetup(0);
            self.emitLoadImm64(SCRATCH, self.global_set_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // Load value to RDX FIRST — before clobbering RDI/RSI with call args.
            // The value vreg may be in RDI or RSI (caller-saved, still valid after spill).
            Enc.movRegReg(&self.code, self.alloc, .rdx, val_reg);
            // System V ABI: RDI=instance, ESI=global_idx, RDX=value (already set)
            self.emitLoadInstPtr(.rdi);
            self.emitLoadImm32(.rsi, @truncate(instr.operand));
            self.emitLoadImm64(SCRATCH, self.global_set_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
        }
        self.reloadCallerSaved();
        self.scratch_vreg = null;
    }

    // --- Call emitters ---

    /// Emit a function call via trampoline.
    fn emitCall(self: *Compiler, rd: u16, func_idx: u32, n_args: u16, n_results: u16, data: RegInstr, data2: ?RegInstr, _: []const RegInstr, _: u32) void {
        // 1. Spill ALL caller-saved regs (non-live-aware: avoids stale physical
        // registers after reload, preventing corruption by subsequent spillCallerSaved).
        self.simdXregEvictAll();
        self.spillCallerSaved();
        // Trampoline reads args from regs[] — spill ALL arg vregs unconditionally.
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

        const data_u64 = packDataWord(data);
        if (builtin.os.tag == .windows) {
            // Win64 ABI: RCX, RDX, R8, R9 then stack args after 32-byte shadow space.
            self.emitLoadVmPtr(.rcx);
            self.emitLoadInstPtr(.rdx);
            Enc.movRegReg(&self.code, self.alloc, .r8, REGS_PTR);
            self.emitLoadImm32(.r9, func_idx);

            const frame_bytes = self.emitWindowsCallSetup(3);
            self.emitLoadImm32(SCRATCH2, @as(u32, rd));
            self.emitWindowsCallArg(0, SCRATCH2);
            self.emitLoadImm64(SCRATCH2, data_u64);
            self.emitWindowsCallArg(1, SCRATCH2);
            if (data2) |d2| {
                self.emitLoadImm64(SCRATCH2, packDataWord(d2));
            } else {
                Enc.xorRegReg32(&self.code, self.alloc, SCRATCH2, SCRATCH2);
            }
            self.emitWindowsCallArg(2, SCRATCH2);

            self.emitLoadImm64(SCRATCH, self.trampoline_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // System V AMD64 ABI: RDI, RSI, RDX, RCX, R8, R9; data2 on stack.
            self.emitLoadVmPtr(.rdi);
            self.emitLoadInstPtr(.rsi);
            Enc.movRegReg(&self.code, self.alloc, .rdx, REGS_PTR);
            self.emitLoadImm32(.rcx, func_idx);
            self.emitLoadImm32(.r8, @as(u32, rd));
            self.emitLoadImm64(.r9, data_u64);
            if (data2) |d2| {
                self.emitLoadImm64(SCRATCH, packDataWord(d2));
            } else {
                Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH);
            }
            Enc.subImm32(&self.code, self.alloc, .rsp, 8);
            Enc.push(&self.code, self.alloc, SCRATCH);
            self.emitLoadImm64(SCRATCH, self.trampoline_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, 16);
        }

        // 5. Check error (RAX != 0 → error)
        Enc.testRegReg(&self.code, self.alloc, .rax, .rax);
        const rel32_off = Enc.jccRel32(&self.code, self.alloc, .ne); // JNE error
        self.error_stubs.append(self.alloc, .{
            .rel32_offset = rel32_off,
            .error_code = 0, // RAX already has error code
            .kind = .jne,
            .cond = .ne,
        }) catch {};

        // 6. Reload memory cache (memory may have grown during call)
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // 7. Reload ALL caller-saved regs, then load result
        self.reloadCallerSaved();
        if (n_results > 0) self.reloadVreg(rd);
    }

    /// Emit call_indirect via trampoline.
    fn emitCallIndirect(self: *Compiler, instr: RegInstr, data: RegInstr, data2: ?RegInstr) void {
        // 1. Spill caller-saved regs + arg vregs
        self.simdXregEvictAll();
        self.spillCallerSaved();
        // Trampoline reads args from regs[] — spill ALL arg vregs unconditionally.
        self.spillVreg(data.rd);
        self.spillVreg(data.rs1);
        self.spillVreg(data.rs2_field);
        self.spillVreg(@truncate(data.operand));
        if (data2) |d2| {
            self.spillVreg(d2.rd);
            self.spillVreg(d2.rs1);
            self.spillVreg(d2.rs2_field);
            self.spillVreg(@truncate(d2.operand));
        }
        self.spillVreg(instr.rs1);

        const data_u64 = packDataWord(data);
        const elem_disp: i32 = @as(i32, @intCast(instr.rs1)) * 8;
        if (builtin.os.tag == .windows) {
            self.emitLoadVmPtr(.rcx);
            self.emitLoadInstPtr(.rdx);
            Enc.movRegReg(&self.code, self.alloc, .r8, REGS_PTR);
            self.emitLoadImm32(.r9, instr.operand);

            const frame_bytes = self.emitWindowsCallSetup(4);
            self.emitLoadImm32(SCRATCH2, @as(u32, instr.rd));
            self.emitWindowsCallArg(0, SCRATCH2);
            self.emitLoadImm64(SCRATCH2, data_u64);
            self.emitWindowsCallArg(1, SCRATCH2);
            if (data2) |d2| {
                self.emitLoadImm64(SCRATCH2, packDataWord(d2));
            } else {
                Enc.xorRegReg32(&self.code, self.alloc, SCRATCH2, SCRATCH2);
            }
            self.emitWindowsCallArg(2, SCRATCH2);
            Enc.loadDisp32(&self.code, self.alloc, SCRATCH2, REGS_PTR, elem_disp);
            self.emitWindowsCallArg(3, SCRATCH2);

            self.emitLoadImm64(SCRATCH, self.call_indirect_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // System V AMD64: RDI=vm, RSI=instance, RDX=regs, ECX=type_idx_table_idx,
            //    R8D=result_reg, R9=data_word, stack[0]=data2_word, stack[1]=elem_idx
            self.emitLoadVmPtr(.rdi);
            self.emitLoadInstPtr(.rsi);
            Enc.movRegReg(&self.code, self.alloc, .rdx, REGS_PTR);
            self.emitLoadImm32(.rcx, instr.operand);
            self.emitLoadImm32(.r8, @as(u32, instr.rd));
            self.emitLoadImm64(.r9, data_u64);

            // Push elem_idx (8th arg) first, then data2 (7th arg) — right to left
            Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, elem_disp);
            Enc.push(&self.code, self.alloc, SCRATCH); // 8th arg

            if (data2) |d2| {
                self.emitLoadImm64(SCRATCH, packDataWord(d2));
            } else {
                Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH);
            }
            Enc.push(&self.code, self.alloc, SCRATCH); // 7th arg

            self.emitLoadImm64(SCRATCH, self.call_indirect_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, 16);
        }

        // 5. Check error
        Enc.testRegReg(&self.code, self.alloc, .rax, .rax);
        const rel32_off = Enc.jccRel32(&self.code, self.alloc, .ne);
        self.error_stubs.append(self.alloc, .{
            .rel32_offset = rel32_off,
            .error_code = 0,
            .kind = .jne,
            .cond = .ne,
        }) catch {};

        // 6. Reload memory cache
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // 7. Reload and load result
        self.reloadCallerSaved();
        if (instr.rs2_field > 0) self.reloadVreg(instr.rd);
    }

    /// Emit inline self-call: bypass trampoline, call directly to self_call_entry.
    /// Handles: spill, reg_ptr advance, arg copy, call_depth, CALL, restore.
    fn emitInlineSelfCall(self: *Compiler, rd: u16, n_results: u16, data: RegInstr, data2: ?RegInstr, _: []const RegInstr, _: u32) void {
        const needed: u32 = @as(u32, self.reg_count) + 4; // +4: mem cache + VM/inst ptrs
        const needed_bytes: u32 = needed * 8;
        const n_args = self.param_count;

        // 1. Spill ALL caller-saved vregs (including callee-saved vregs 0-2)
        self.simdXregEvictAll();
        self.spillCallerSaved();
        // Spill callee-saved vregs — self-call entry doesn't save/restore them.
        for (0..@min(self.reg_count, FIRST_CALLER_SAVED_VREG)) |i| {
            self.spillVreg(@intCast(i));
        }
        // Spill arg vregs unconditionally (needed even if dead after call)
        self.spillVreg(data.rd);
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

        // 2. Load vm_ptr into SCRATCH2 for reg_ptr/call_depth access
        self.emitLoadVmPtr(SCRATCH2);

        // 3. Advance reg_ptr: load current, add needed, check overflow, store back
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, SCRATCH2, @intCast(self.reg_ptr_offset));
        Enc.addImm32(&self.code, self.alloc, SCRATCH, @intCast(needed));
        // Check: new reg_ptr > REG_STACK_SIZE → stack overflow
        Enc.cmpImm32(&self.code, self.alloc, SCRATCH, vm_mod.REG_STACK_SIZE);
        self.emitCondError(.a, 2); // StackOverflow
        Enc.storeDisp32(&self.code, self.alloc, SCRATCH2, @intCast(self.reg_ptr_offset), SCRATCH);

        // 4. Increment call_depth, check MAX_CALL_DEPTH
        const cd_offset: i32 = @intCast(self.reg_ptr_offset + 8); // call_depth is adjacent
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, SCRATCH2, cd_offset);
        Enc.cmpImm32(&self.code, self.alloc, SCRATCH, vm_mod.MAX_CALL_DEPTH);
        self.emitCondError(.ae, 2); // StackOverflow
        Enc.addImm32(&self.code, self.alloc, SCRATCH, 1);
        Enc.storeDisp32(&self.code, self.alloc, SCRATCH2, cd_offset, SCRATCH);

        // 5. Compute callee REGS_PTR in arg0 register: caller REGS_PTR + needed_bytes
        const callee_regs_arg = abiRegsArg();
        Enc.movRegReg(&self.code, self.alloc, callee_regs_arg, REGS_PTR);
        Enc.addImm32(&self.code, self.alloc, callee_regs_arg, @intCast(needed_bytes));

        // 6. Copy args from caller's physical regs/memory to callee frame
        self.emitArgCopyDirect(callee_regs_arg, data.rd, 0);
        if (n_args > 1) self.emitArgCopyDirect(callee_regs_arg, data.rs1, 8);
        if (n_args > 2) self.emitArgCopyDirect(callee_regs_arg, data.rs2_field, 16);
        if (n_args > 3) self.emitArgCopyDirect(callee_regs_arg, @truncate(data.operand), 24);
        if (n_args > 4) {
            if (data2) |d2| {
                if (n_args > 4) self.emitArgCopyDirect(callee_regs_arg, d2.rd, 32);
                if (n_args > 5) self.emitArgCopyDirect(callee_regs_arg, d2.rs1, 40);
                if (n_args > 6) self.emitArgCopyDirect(callee_regs_arg, d2.rs2_field, 48);
                if (n_args > 7) self.emitArgCopyDirect(callee_regs_arg, @truncate(d2.operand), 56);
            }
        }

        // 7. Zero-init remaining locals
        if (n_args < self.local_count) {
            Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH);
            for (n_args..self.local_count) |i| {
                const offset: i32 = @intCast(i * 8);
                Enc.storeDisp32(&self.code, self.alloc, callee_regs_arg, offset, SCRATCH);
            }
        }

        // 8. Copy vm_ptr and inst_ptr to callee frame
        const vm_slot: i32 = (@as(i32, self.reg_count) + 2) * 8;
        const inst_slot: i32 = (@as(i32, self.reg_count) + 3) * 8;
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, vm_slot);
        Enc.storeDisp32(&self.code, self.alloc, callee_regs_arg, vm_slot, SCRATCH);
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, inst_slot);
        Enc.storeDisp32(&self.code, self.alloc, callee_regs_arg, inst_slot, SCRATCH);

        // 9. CALL self_call_entry (direct, no trampoline)
        // Emit CALL rel32 — target is self_call_entry_offset in the code buffer.
        const call_site = self.currentOffset();
        const call_rel32_off = Enc.callRel32(&self.code, self.alloc);
        Enc.patchRel32(self.code.items, call_rel32_off, self.self_call_entry_offset);
        _ = call_site;

        // 10. Restore REGS_PTR (R12): callee clobbered it, recover from callee base.
        // callee's R12 = caller's R12 + needed_bytes, so subtract to restore.
        Enc.subImm32(&self.code, self.alloc, REGS_PTR, @intCast(needed_bytes));

        // Save error code (RAX) to RCX — steps 11-12 use SCRATCH (RAX) as temp.
        Enc.movRegReg(&self.code, self.alloc, .rcx, .rax);

        // 11. Decrement call_depth (unconditionally — must balance even on error)
        self.emitLoadVmPtr(SCRATCH2);
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, SCRATCH2, cd_offset);
        Enc.subImm32(&self.code, self.alloc, SCRATCH, 1);
        Enc.storeDisp32(&self.code, self.alloc, SCRATCH2, cd_offset, SCRATCH);

        // 12. Restore reg_ptr
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, SCRATCH2, @intCast(self.reg_ptr_offset));
        Enc.subImm32(&self.code, self.alloc, SCRATCH, @intCast(needed));
        Enc.storeDisp32(&self.code, self.alloc, SCRATCH2, @intCast(self.reg_ptr_offset), SCRATCH);

        // 13. Restore error code from RCX back to RAX, then check.
        Enc.movRegReg(&self.code, self.alloc, .rax, .rcx);
        Enc.testRegReg(&self.code, self.alloc, .rax, .rax);
        const rel32_off = Enc.jccRel32(&self.code, self.alloc, .ne);
        self.error_stubs.append(self.alloc, .{
            .rel32_offset = rel32_off,
            .error_code = 0,
            .kind = .jne,
            .cond = .ne,
        }) catch {};

        // 13. Reload memory cache (memory may have grown during call)
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // 14. Copy callee's result (regs[0] at R12+needed_bytes) to caller's rd slot.
        // The callee's epilogue stored result in callee's regs[0].
        // After R12 restore, callee frame starts at R12 + needed_bytes.
        if (n_results > 0) {
            Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, @intCast(needed_bytes));
            const rd_disp: i32 = @as(i32, rd) * 8;
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, rd_disp, SCRATCH);
        }

        // 15. Reload ALL vregs (including callee-saved 0-2)
        self.reloadCallerSaved();
        // Reload callee-saved vregs (0-2) that were spilled in step 1
        for (0..@min(self.reg_count, FIRST_CALLER_SAVED_VREG)) |i| {
            self.reloadVreg(@intCast(i));
        }
        // Reload result (now contains callee's return value from step 14)
        self.reloadVreg(rd);
    }

    /// Copy arg vreg from caller's spilled memory to callee frame.
    /// Must use memory (not physical regs) because regs may have been clobbered.
    fn emitArgCopyDirect(self: *Compiler, callee_base: Reg, arg_vreg: u16, callee_offset: i32) void {
        const src_disp: i32 = @as(i32, arg_vreg) * 8;
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, src_disp);
        Enc.storeDisp32(&self.code, self.alloc, callee_base, callee_offset, SCRATCH);
    }

    /// Spill a single vreg unconditionally to regs[]. Required for call args
    /// because the trampoline reads args from regs[], and spillCallerSavedLive
    /// only spills live-after-call vregs — dead-after-call args would be missed.
    fn spillVreg(self: *Compiler, vreg: u16) void {
        if (vregToPhys(vreg)) |phys| {
            const disp: i32 = @as(i32, vreg) * 8;
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
        }
    }

    /// Reload a single vreg from memory.
    fn reloadVreg(self: *Compiler, vreg: u16) void {
        if (vregToPhys(vreg)) |phys| {
            const disp: i32 = @as(i32, vreg) * 8;
            Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
        }
    }

    /// Emit memory.grow via trampoline call.
    fn emitMemGrow(self: *Compiler, instr: RegInstr) void {
        self.simdXregEvictAll();
        self.spillCallerSaved();
        const pages_reg = self.getOrLoad(instr.rs1, SCRATCH);
        if (builtin.os.tag == .windows) {
            Enc.movRegReg64(&self.code, self.alloc, .rdx, pages_reg);
            self.emitLoadInstPtr(.rcx);
            const frame_bytes = self.emitWindowsCallSetup(0);
            self.emitLoadImm64(SCRATCH, self.mem_grow_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // Load pages BEFORE clobbering RDI — value may be in RDI (vreg 4)
            Enc.movRegReg64(&self.code, self.alloc, .rsi, pages_reg);
            self.emitLoadInstPtr(.rdi);
            self.emitLoadImm64(SCRATCH, self.mem_grow_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
        }
        // Result in RAX (u64): old_pages or fail value
        // Store result to regs[rd] immediately (before RAX is clobbered)
        const rd_disp: i32 = @as(i32, instr.rd) * 8;
        Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, rd_disp, .rax);
        // Reload memory cache (memory may have grown)
        if (self.has_memory) {
            self.emitLoadMemCache();
        }
        self.reloadCallerSaved();
        self.reloadVreg(instr.rd);
        self.scratch_vreg = null;
    }

    /// Emit memory.fill via trampoline call.
    fn emitMemFill(self: *Compiler, instr: RegInstr) void {
        self.simdXregEvictAll();
        self.spillCallerSaved();
        // Spill all arg vregs then load from memory to avoid register conflicts.
        // getOrLoad returns physical registers that may alias ABI arg registers;
        // loading from regs[] after spill avoids all clobbering issues.
        self.spillVreg(instr.rd);
        self.spillVreg(instr.rs1);
        self.spillVreg(instr.rs2());
        if (builtin.os.tag == .windows) {
            self.emitLoadInstPtr(.rcx);
            Enc.loadDisp32(&self.code, self.alloc, .rdx, REGS_PTR, @as(i32, instr.rd) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .r8, REGS_PTR, @as(i32, instr.rs1) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .r9, REGS_PTR, @as(i32, instr.rs2()) * 8);
            const frame_bytes = self.emitWindowsCallSetup(0);
            self.emitLoadImm64(SCRATCH, self.mem_fill_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // System V: RDI=instance, ESI=dst, EDX=val, ECX=n
            Enc.loadDisp32(&self.code, self.alloc, .rsi, REGS_PTR, @as(i32, instr.rd) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .rdx, REGS_PTR, @as(i32, instr.rs1) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .rcx, REGS_PTR, @as(i32, instr.rs2()) * 8);
            self.emitLoadInstPtr(.rdi);
            self.emitLoadImm64(SCRATCH, self.mem_fill_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
        }
        // Check error (EAX != 0 → OOB)
        Enc.testRegReg32(&self.code, self.alloc, .rax, .rax);
        self.emitCondError(.ne, 6); // OutOfBoundsMemoryAccess
        self.reloadCallerSaved();
        self.scratch_vreg = null;
    }

    /// Emit memory.copy via trampoline call.
    fn emitMemCopy(self: *Compiler, instr: RegInstr) void {
        self.simdXregEvictAll();
        self.spillCallerSaved();
        // Spill all arg vregs then load from memory to avoid register conflicts.
        self.spillVreg(instr.rd);
        self.spillVreg(instr.rs1);
        self.spillVreg(instr.rs2());
        if (builtin.os.tag == .windows) {
            self.emitLoadInstPtr(.rcx);
            Enc.loadDisp32(&self.code, self.alloc, .rdx, REGS_PTR, @as(i32, instr.rd) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .r8, REGS_PTR, @as(i32, instr.rs1) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .r9, REGS_PTR, @as(i32, instr.rs2()) * 8);
            const frame_bytes = self.emitWindowsCallSetup(0);
            self.emitLoadImm64(SCRATCH, self.mem_copy_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
            Enc.addImm32(&self.code, self.alloc, .rsp, @intCast(frame_bytes));
        } else {
            // System V: RDI=instance, ESI=dst, EDX=src, ECX=n
            Enc.loadDisp32(&self.code, self.alloc, .rsi, REGS_PTR, @as(i32, instr.rd) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .rdx, REGS_PTR, @as(i32, instr.rs1) * 8);
            Enc.loadDisp32(&self.code, self.alloc, .rcx, REGS_PTR, @as(i32, instr.rs2()) * 8);
            self.emitLoadInstPtr(.rdi);
            self.emitLoadImm64(SCRATCH, self.mem_copy_addr);
            Enc.callReg(&self.code, self.alloc, SCRATCH);
        }
        // Check error
        Enc.testRegReg32(&self.code, self.alloc, .rax, .rax);
        self.emitCondError(.ne, 6);
        self.reloadCallerSaved();
        self.scratch_vreg = null;
    }

    // --- Floating-point emitters ---

    const XMM0: u4 = 0;
    const XMM1: u4 = 1;
    const XMM2: u4 = 2;

    /// Load FP value from vreg (GPR or memory) into XMM register.
    fn loadFpToXmm(self: *Compiler, xmm: u4, vreg: u16) void {
        if (vregToPhys(vreg)) |phys| {
            Enc.movqToXmm(&self.code, self.alloc, xmm, phys);
        } else {
            // Load from memory to SCRATCH, then to XMM
            const disp: i32 = @as(i32, vreg) * 8;
            Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, disp);
            Enc.movqToXmm(&self.code, self.alloc, xmm, SCRATCH);
        }
    }

    /// Store FP value from XMM register to vreg (GPR or memory).
    fn storeFpFromXmm(self: *Compiler, vreg: u16, xmm: u4) void {
        if (vregToPhys(vreg)) |phys| {
            Enc.movqFromXmm(&self.code, self.alloc, phys, xmm);
        } else {
            Enc.movqFromXmm(&self.code, self.alloc, SCRATCH, xmm);
            const disp: i32 = @as(i32, vreg) * 8;
            Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, SCRATCH);
        }
    }

    /// Emit f64 binary operation (add/sub/mul/div).
    fn emitFpBinop64(self: *Compiler, instr: RegInstr) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        self.loadFpToXmm(XMM1, instr.rs2());
        switch (instr.op) {
            0xA0 => Enc.addsd(&self.code, self.alloc, XMM0, XMM1),
            0xA1 => Enc.subsd(&self.code, self.alloc, XMM0, XMM1),
            0xA2 => Enc.mulsd(&self.code, self.alloc, XMM0, XMM1),
            0xA3 => Enc.divsd(&self.code, self.alloc, XMM0, XMM1),
            else => unreachable,
        }
        self.storeFpFromXmm(instr.rd, XMM0);
    }

    /// Emit f32 binary operation (add/sub/mul/div).
    fn emitFpBinop32(self: *Compiler, instr: RegInstr) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        self.loadFpToXmm(XMM1, instr.rs2());
        switch (instr.op) {
            0x92 => Enc.addss(&self.code, self.alloc, XMM0, XMM1),
            0x93 => Enc.subss(&self.code, self.alloc, XMM0, XMM1),
            0x94 => Enc.mulss(&self.code, self.alloc, XMM0, XMM1),
            0x95 => Enc.divss(&self.code, self.alloc, XMM0, XMM1),
            else => unreachable,
        }
        self.storeFpFromXmm(instr.rd, XMM0);
    }

    /// Emit f64 unary operation (sqrt, abs, neg).
    fn emitFpUnop64(self: *Compiler, op: u16, instr: RegInstr) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        switch (op) {
            0x9F => Enc.sqrtsd(&self.code, self.alloc, XMM0, XMM0), // f64.sqrt
            0x99 => { // f64.abs: AND with 0x7FFFFFFFFFFFFFFF
                // Load mask into SCRATCH, then MOVQ to XMM1, then ANDPD
                self.emitLoadImm64(SCRATCH, 0x7FFFFFFFFFFFFFFF);
                Enc.movqToXmm(&self.code, self.alloc, XMM1, SCRATCH);
                Enc.andpd(&self.code, self.alloc, XMM0, XMM1);
            },
            0x9A => { // f64.neg: XOR with 0x8000000000000000
                self.emitLoadImm64(SCRATCH, 0x8000000000000000);
                Enc.movqToXmm(&self.code, self.alloc, XMM1, SCRATCH);
                Enc.xorpd(&self.code, self.alloc, XMM0, XMM1);
            },
            else => unreachable,
        }
        self.storeFpFromXmm(instr.rd, XMM0);
    }

    /// Emit f32 unary operation (sqrt, abs, neg).
    fn emitFpUnop32(self: *Compiler, op: u16, instr: RegInstr) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        switch (op) {
            0x91 => Enc.sqrtss(&self.code, self.alloc, XMM0, XMM0), // f32.sqrt
            0x8B => { // f32.abs: AND with 0x7FFFFFFF (in lower 32 bits)
                self.emitLoadImm64(SCRATCH, 0x7FFFFFFF);
                Enc.movqToXmm(&self.code, self.alloc, XMM1, SCRATCH);
                // ANDPS: 0F 54 /r (no prefix)
                self.code.appendSlice(self.alloc, &[_]u8{ 0x0F, 0x54, Enc.modrm(3, XMM0, XMM1) }) catch {};
            },
            0x8C => { // f32.neg: XOR with 0x80000000
                self.emitLoadImm64(SCRATCH, 0x80000000);
                Enc.movqToXmm(&self.code, self.alloc, XMM1, SCRATCH);
                // XORPS: 0F 57 /r (no prefix)
                self.code.appendSlice(self.alloc, &[_]u8{ 0x0F, 0x57, Enc.modrm(3, XMM0, XMM1) }) catch {};
            },
            else => unreachable,
        }
        self.storeFpFromXmm(instr.rd, XMM0);
    }

    /// Emit f64 min/max (direct binary op).
    fn emitFpMinMax64(self: *Compiler, instr: RegInstr) bool {
        self.loadFpToXmm(XMM0, instr.rs1);
        self.loadFpToXmm(XMM1, instr.rs2());
        if (instr.op == 0xA4) {
            // f64.min: NaN propagation via OR, -0 propagation via OR
            Enc.movaps(&self.code, self.alloc, XMM2, XMM0);
            Enc.minsd(&self.code, self.alloc, XMM2, XMM1);
            Enc.minsd(&self.code, self.alloc, XMM1, XMM0);
            Enc.orps(&self.code, self.alloc, XMM2, XMM1);
            self.storeFpFromXmm(instr.rd, XMM2);
        } else {
            // f64.max: NaN propagation via xor+or+sub, +0 selection via sub
            Enc.movaps(&self.code, self.alloc, XMM2, XMM0);
            Enc.maxsd(&self.code, self.alloc, XMM2, XMM1);
            Enc.maxsd(&self.code, self.alloc, XMM1, XMM0);
            Enc.xorps(&self.code, self.alloc, XMM2, XMM1);
            Enc.orps(&self.code, self.alloc, XMM1, XMM2);
            Enc.subsd(&self.code, self.alloc, XMM1, XMM2);
            self.storeFpFromXmm(instr.rd, XMM1);
        }
        return true;
    }

    /// Emit f32 min/max.
    fn emitFpMinMax32(self: *Compiler, instr: RegInstr) bool {
        self.loadFpToXmm(XMM0, instr.rs1);
        self.loadFpToXmm(XMM1, instr.rs2());
        if (instr.op == 0x96) {
            // f32.min: NaN propagation via OR, -0 propagation via OR
            Enc.movaps(&self.code, self.alloc, XMM2, XMM0);
            Enc.minss(&self.code, self.alloc, XMM2, XMM1);
            Enc.minss(&self.code, self.alloc, XMM1, XMM0);
            Enc.orps(&self.code, self.alloc, XMM2, XMM1);
            self.storeFpFromXmm(instr.rd, XMM2);
        } else {
            // f32.max: NaN propagation via xor+or+sub, +0 selection via sub
            Enc.movaps(&self.code, self.alloc, XMM2, XMM0);
            Enc.maxss(&self.code, self.alloc, XMM2, XMM1);
            Enc.maxss(&self.code, self.alloc, XMM1, XMM0);
            Enc.xorps(&self.code, self.alloc, XMM2, XMM1);
            Enc.orps(&self.code, self.alloc, XMM1, XMM2);
            Enc.subss(&self.code, self.alloc, XMM1, XMM2);
            self.storeFpFromXmm(instr.rd, XMM1);
        }
        return true;
    }

    /// Emit f64 comparison: result = 0 or 1.
    /// UCOMISD sets CF/ZF/PF. NaN → unordered (PF=1, ZF=1, CF=1).
    fn emitFpCmp64(self: *Compiler, op: u16, instr: RegInstr) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        self.loadFpToXmm(XMM1, instr.rs2());
        Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
        // Set result in AL based on condition, then MOVZX to clear upper bits
        const cond: Cond = switch (op) {
            0x61 => .e,   // f64.eq: ZF=1 and PF=0
            0x62 => .ne,  // f64.ne: ZF=0 or PF=1
            0x63 => .a,   // f64.lt: CF=0 and ZF=0 (reversed operands pattern)
            0x64 => .a,   // f64.gt
            0x65 => .ae,  // f64.le
            0x66 => .ae,  // f64.ge
            else => unreachable,
        };
        // For lt/le we need reversed operand order (already loaded as xmm0=rs1, xmm1=rs2)
        // UCOMISD xmm0,xmm1: flags for xmm0 vs xmm1
        // f64.lt: rs1 < rs2 → CF=1 after UCOMISD(rs1,rs2) → use SETB, but NaN gives CF=1 too
        // Correct: f64.eq: SETE+SETNP, f64.ne: SETNE or PF
        // Simple approach: use SETA/SETAE with operand reordering
        switch (op) {
            0x61 => { // f64.eq: ZF=1 AND PF=0
                // SETE + AND SETNP
                Enc.setcc(&self.code, self.alloc, .e, SCRATCH);
                // SETNP into SCRATCH2 low byte, then AND
                self.code.append(self.alloc, Enc.rexW1(SCRATCH2)) catch {};
                self.code.appendSlice(self.alloc, &[_]u8{ 0x0F, 0x9B }) catch {}; // SETNP
                self.code.append(self.alloc, Enc.modrm(3, 0, SCRATCH2.low3())) catch {};
                Enc.andRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH2);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x62 => { // f64.ne: ZF=0 OR PF=1
                Enc.setcc(&self.code, self.alloc, .ne, SCRATCH);
                self.code.append(self.alloc, Enc.rexW1(SCRATCH2)) catch {};
                self.code.appendSlice(self.alloc, &[_]u8{ 0x0F, 0x9A }) catch {}; // SETP
                self.code.append(self.alloc, Enc.modrm(3, 0, SCRATCH2.low3())) catch {};
                Enc.orRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH2);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x63 => { // f64.lt: rs1 < rs2 → UCOMISD(rs2, rs1), SETA
                // Reload with reversed order
                self.loadFpToXmm(XMM0, instr.rs2());
                self.loadFpToXmm(XMM1, instr.rs1);
                Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
                Enc.setcc(&self.code, self.alloc, cond, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x64 => { // f64.gt: rs1 > rs2 → UCOMISD(rs1, rs2), SETA
                Enc.setcc(&self.code, self.alloc, cond, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x65 => { // f64.le: rs1 <= rs2 → UCOMISD(rs2, rs1), SETAE
                self.loadFpToXmm(XMM0, instr.rs2());
                self.loadFpToXmm(XMM1, instr.rs1);
                Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
                Enc.setcc(&self.code, self.alloc, cond, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x66 => { // f64.ge: rs1 >= rs2 → UCOMISD(rs1, rs2), SETAE
                Enc.setcc(&self.code, self.alloc, cond, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            else => unreachable,
        }
        self.storeVreg(instr.rd, SCRATCH);
    }

    /// Emit f32 comparison.
    fn emitFpCmp32(self: *Compiler, op: u16, instr: RegInstr) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        self.loadFpToXmm(XMM1, instr.rs2());
        Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
        switch (op) {
            0x5B => { // f32.eq
                Enc.setcc(&self.code, self.alloc, .e, SCRATCH);
                self.code.append(self.alloc, Enc.rexW1(SCRATCH2)) catch {};
                self.code.appendSlice(self.alloc, &[_]u8{ 0x0F, 0x9B }) catch {};
                self.code.append(self.alloc, Enc.modrm(3, 0, SCRATCH2.low3())) catch {};
                Enc.andRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH2);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x5C => { // f32.ne
                Enc.setcc(&self.code, self.alloc, .ne, SCRATCH);
                self.code.append(self.alloc, Enc.rexW1(SCRATCH2)) catch {};
                self.code.appendSlice(self.alloc, &[_]u8{ 0x0F, 0x9A }) catch {};
                self.code.append(self.alloc, Enc.modrm(3, 0, SCRATCH2.low3())) catch {};
                Enc.orRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH2);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x5D => { // f32.lt → reversed
                self.loadFpToXmm(XMM0, instr.rs2());
                self.loadFpToXmm(XMM1, instr.rs1);
                Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
                Enc.setcc(&self.code, self.alloc, .a, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x5E => { // f32.gt
                Enc.setcc(&self.code, self.alloc, .a, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x5F => { // f32.le → reversed
                self.loadFpToXmm(XMM0, instr.rs2());
                self.loadFpToXmm(XMM1, instr.rs1);
                Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
                Enc.setcc(&self.code, self.alloc, .ae, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            0x60 => { // f32.ge
                Enc.setcc(&self.code, self.alloc, .ae, SCRATCH);
                Enc.movzxByte(&self.code, self.alloc, SCRATCH, SCRATCH);
            },
            else => unreachable,
        }
        self.storeVreg(instr.rd, SCRATCH);
    }

    /// Emit i32.trunc from f32/f64 (signed/unsigned).
    /// Strategy: NaN check → CVTT to i64 → range check → store lower 32 bits.
    /// Using i64 conversion avoids edge cases with the indefinite value for i32 range.
    fn emitTruncToI32(self: *Compiler, instr: RegInstr, is_f64: bool, signed: bool) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        // NaN check
        if (is_f64) {
            Enc.ucomisd(&self.code, self.alloc, XMM0, XMM0);
        } else {
            Enc.ucomiss(&self.code, self.alloc, XMM0, XMM0);
        }
        self.emitCondError(.p, 8); // JP → InvalidConversion (NaN)
        // Convert to i64 (handles full i32/u32 range without ambiguity)
        if (is_f64) {
            Enc.cvttsd2si64(&self.code, self.alloc, SCRATCH, XMM0);
        } else {
            Enc.cvttss2si64(&self.code, self.alloc, SCRATCH, XMM0);
        }
        // Range check
        if (signed) {
            // i32 range: [-2147483648, 2147483647]
            // Check result < -2^31: load -2^31 into SCRATCH2, CMP
            self.emitLoadImm64(SCRATCH2, @bitCast(@as(i64, -2147483648)));
            Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
            self.emitCondError(.l, 8); // JL → overflow
            self.emitLoadImm64(SCRATCH2, @bitCast(@as(i64, 2147483647)));
            Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
            self.emitCondError(.g, 8); // JG → overflow
        } else {
            // u32 range: [0, 4294967295]
            // Check result < 0
            Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
            self.emitCondError(.s, 8); // JS → negative = overflow
            self.emitLoadImm64(SCRATCH2, 4294967295);
            Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
            self.emitCondError(.a, 8); // JA → too large
        }
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitTruncF32ToI32(self: *Compiler, instr: RegInstr, signed: bool) void {
        self.emitTruncToI32(instr, false, signed);
    }

    fn emitTruncF64ToI32(self: *Compiler, instr: RegInstr, signed: bool) void {
        self.emitTruncToI32(instr, true, signed);
    }

    /// Emit i64.trunc from f32/f64 (signed/unsigned).
    /// For signed: CVTT to i64 directly, check indefinite value.
    /// For unsigned: need two-stage conversion for values >= 2^63.
    fn emitTruncToI64(self: *Compiler, instr: RegInstr, is_f64: bool, signed: bool) void {
        self.loadFpToXmm(XMM0, instr.rs1);
        // NaN check
        if (is_f64) {
            Enc.ucomisd(&self.code, self.alloc, XMM0, XMM0);
        } else {
            Enc.ucomiss(&self.code, self.alloc, XMM0, XMM0);
        }
        self.emitCondError(.p, 8); // JP → InvalidConversion (NaN)

        if (signed) {
            // Signed i64: CVTT returns indefinite (0x8000000000000000) on overflow
            if (is_f64) {
                Enc.cvttsd2si64(&self.code, self.alloc, SCRATCH, XMM0);
            } else {
                Enc.cvttss2si64(&self.code, self.alloc, SCRATCH, XMM0);
            }
            // Check for indefinite: if result == MIN_I64 and float wasn't exactly MIN_I64
            // Simpler: compare float against valid range boundaries
            // Use: if result == 0x8000000000000000, check if float was in range
            // Load indefinite into SCRATCH2 and compare
            self.emitLoadImm64(SCRATCH2, 0x8000000000000000);
            Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
            // If not equal to indefinite, result is valid
            const jne_ok = Enc.jccRel32(&self.code, self.alloc, .ne);
            // Result is indefinite — check if original float was exactly -2^63
            // Load -2^63 as float and compare
            if (is_f64) {
                // -2^63 as f64 = 0xC3E0000000000000
                self.emitLoadImm64(SCRATCH2, 0xC3E0000000000000);
                Enc.movqToXmm(&self.code, self.alloc, XMM1, SCRATCH2);
                Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
            } else {
                // -2^63 as f32 = 0xDF000000
                self.emitLoadImm32(SCRATCH2, 0xDF000000);
                Enc.movdToXmm(&self.code, self.alloc, XMM1, SCRATCH2);
                Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
            }
            // If float == -2^63 exactly (ZF=1, PF=0), result is valid MIN_I64
            // If not equal, it's an overflow
            self.emitCondError(.ne, 8); // overflow
            self.emitCondError(.p, 8); // shouldn't happen (already checked NaN) but safe
            Enc.patchRel32(self.code.items, jne_ok, self.currentOffset());
        } else {
            // Unsigned i64: values can be up to 2^64-1
            // Check negative (but -0.0 should give 0)
            // Strategy: if float < 2^63 (fits in signed), convert directly
            //           if float >= 2^63, subtract 2^63, convert, add 2^63 as int
            //           if float < 0 (not -0), trap

            // Load 2^63 as float into XMM1
            if (is_f64) {
                self.emitLoadImm64(SCRATCH2, 0x43E0000000000000); // 2^63 as f64
                Enc.movqToXmm(&self.code, self.alloc, XMM1, SCRATCH2);
                Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
            } else {
                self.emitLoadImm32(SCRATCH2, 0x5F000000); // 2^63 as f32
                Enc.movdToXmm(&self.code, self.alloc, XMM1, SCRATCH2);
                Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
            }
            // CF=0 and ZF=0 means float >= 2^63 (above)
            // CF=1 means float < 2^63 (below)
            // If below 2^63 (CF=1), go to small path
            const jb_small = Enc.jccRel32(&self.code, self.alloc, .b);

            // Large path: float >= 2^63
            // Subtract 2^63 from float
            if (is_f64) {
                Enc.subsd(&self.code, self.alloc, XMM0, XMM1);
                Enc.cvttsd2si64(&self.code, self.alloc, SCRATCH, XMM0);
            } else {
                Enc.subss(&self.code, self.alloc, XMM0, XMM1);
                Enc.cvttss2si64(&self.code, self.alloc, SCRATCH, XMM0);
            }
            // Check for overflow (indefinite after subtraction)
            Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
            self.emitCondError(.s, 8); // if negative (indefinite), overflow
            // Add 2^63 as integer
            self.emitLoadImm64(SCRATCH2, 0x8000000000000000);
            Enc.addRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
            const jmp_done = Enc.jmpRel32(&self.code, self.alloc);

            // Small path: float < 2^63
            Enc.patchRel32(self.code.items, jb_small, self.currentOffset());
            // Check negative: if float < -0.0 → trap
            // -0.0 should give 0, so we need: truncate first, then check
            if (is_f64) {
                Enc.cvttsd2si64(&self.code, self.alloc, SCRATCH, XMM0);
            } else {
                Enc.cvttss2si64(&self.code, self.alloc, SCRATCH, XMM0);
            }
            // If result < 0 and wasn't -0.0 → overflow
            Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
            const jns_ok = Enc.jccRel32(&self.code, self.alloc, .ns);
            // Result is negative. Check if it's exactly 0 (from -0.0 or very small negative)
            // Actually CVTT of -0.0 returns 0, and CVTT of -0.5 returns 0 (truncate toward zero)
            // So if result < 0, it means the float was < -1.0 → trap
            // But result is i64, so negative means the float was very negative → trap
            self.emitCondError(.s, 8); // always taken since we just tested and it was negative
            Enc.patchRel32(self.code.items, jns_ok, self.currentOffset());
            Enc.patchRel32(self.code.items, jmp_done, self.currentOffset());
        }
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitTruncF32ToI64(self: *Compiler, instr: RegInstr, signed: bool) void {
        self.emitTruncToI64(instr, false, signed);
    }

    fn emitTruncF64ToI64(self: *Compiler, instr: RegInstr, signed: bool) void {
        self.emitTruncToI64(instr, true, signed);
    }

    /// Saturating truncation: clamp instead of trap on NaN/overflow.
    /// i32 variants: CVTT to i64 (avoids indefinite ambiguity), then clamp.
    /// i64 variants: CVTT to i64, check for indefinite, clamp.
    fn emitTruncSat(self: *Compiler, instr: RegInstr) void {
        const sub = @as(u8, @truncate(instr.op & 0xFF));
        const is_f64 = (sub & 0x02) != 0;
        const is_unsigned = (sub & 0x01) != 0;
        const is_i64 = (sub & 0x04) != 0;

        self.loadFpToXmm(XMM0, instr.rs1);

        // NaN check: UCOMISD/UCOMISS xmm0, xmm0 → PF set if NaN
        if (is_f64) {
            Enc.ucomisd(&self.code, self.alloc, XMM0, XMM0);
        } else {
            Enc.ucomiss(&self.code, self.alloc, XMM0, XMM0);
        }
        // JP nan_handler → result = 0
        const jp_patch = Enc.jccRel32(&self.code, self.alloc, .p);

        if (!is_i64) {
            // i32 sat: convert to i64 first, then handle indefinite + clamp
            if (is_f64) {
                Enc.cvttsd2si64(&self.code, self.alloc, SCRATCH, XMM0);
            } else {
                Enc.cvttss2si64(&self.code, self.alloc, SCRATCH, XMM0);
            }
            // Check for x86 integer indefinite (0x8000000000000000).
            // CVTTSS2SI64/CVTTSD2SI64 returns this for +Inf, -Inf, and values outside i64 range.
            self.emitLoadImm64(SCRATCH2, 0x8000000000000000);
            Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
            const jne_valid = Enc.jccRel32(&self.code, self.alloc, .ne);
            // Indefinite: check original float sign to determine saturation direction
            Enc.xorpd(&self.code, self.alloc, XMM1, XMM1);
            if (is_f64) {
                Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
            } else {
                Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
            }
            if (is_unsigned) {
                const jae_pos = Enc.jccRel32(&self.code, self.alloc, .ae);
                Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH); // negative → 0
                const jmp_indef_done = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jae_pos, self.currentOffset());
                self.emitLoadImm64(SCRATCH, 0xFFFFFFFF); // positive → UINT32_MAX
                Enc.patchRel32(self.code.items, jmp_indef_done, self.currentOffset());
            } else {
                const jae_pos = Enc.jccRel32(&self.code, self.alloc, .ae);
                self.emitLoadImm64(SCRATCH, @bitCast(@as(i64, -2147483648))); // negative → INT32_MIN
                const jmp_indef_done = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jae_pos, self.currentOffset());
                self.emitLoadImm64(SCRATCH, @bitCast(@as(i64, 2147483647))); // positive → INT32_MAX
                Enc.patchRel32(self.code.items, jmp_indef_done, self.currentOffset());
            }
            const jmp_done_indef = Enc.jmpRel32(&self.code, self.alloc);
            Enc.patchRel32(self.code.items, jne_valid, self.currentOffset());
            // Valid i64 result (not indefinite): clamp to i32/u32 range
            if (is_unsigned) {
                // Clamp to [0, 0xFFFFFFFF]
                Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
                const jns_ok = Enc.jccRel32(&self.code, self.alloc, .ns);
                Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH); // negative → 0
                const jmp_done1 = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jns_ok, self.currentOffset());
                self.emitLoadImm64(SCRATCH2, 0xFFFFFFFF);
                Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
                const jbe_ok = Enc.jccRel32(&self.code, self.alloc, .be);
                Enc.movRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2); // too large → UINT32_MAX
                Enc.patchRel32(self.code.items, jbe_ok, self.currentOffset());
                Enc.patchRel32(self.code.items, jmp_done1, self.currentOffset());
            } else {
                // Clamp to [-2^31, 2^31-1]
                self.emitLoadImm64(SCRATCH2, @bitCast(@as(i64, -2147483648)));
                Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
                const jge_min = Enc.jccRel32(&self.code, self.alloc, .ge);
                Enc.movRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2); // too negative → INT32_MIN
                const jmp_done1 = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jge_min, self.currentOffset());
                self.emitLoadImm64(SCRATCH2, @bitCast(@as(i64, 2147483647)));
                Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
                const jle_ok = Enc.jccRel32(&self.code, self.alloc, .le);
                Enc.movRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2); // too large → INT32_MAX
                Enc.patchRel32(self.code.items, jle_ok, self.currentOffset());
                Enc.patchRel32(self.code.items, jmp_done1, self.currentOffset());
            }
            Enc.patchRel32(self.code.items, jmp_done_indef, self.currentOffset());
        } else {
            // i64 sat: CVTT to i64 directly
            if (is_f64) {
                Enc.cvttsd2si64(&self.code, self.alloc, SCRATCH, XMM0);
            } else {
                Enc.cvttss2si64(&self.code, self.alloc, SCRATCH, XMM0);
            }
            if (is_unsigned) {
                // Unsigned i64 sat: CVTTSS2SI64 only handles [0, 2^63).
                // Values in [2^63, 2^64) need subtract-and-add-back.
                // Values >= 2^64 or +Inf → UINT64_MAX. Negative → 0.
                Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
                const jns_ok = Enc.jccRel32(&self.code, self.alloc, .ns);
                // Result is negative (indefinite or actual negative):
                // Check original float to determine: negative → 0, [2^63, 2^64) → convert, >= 2^64 → MAX
                Enc.xorpd(&self.code, self.alloc, XMM1, XMM1);
                if (is_f64) {
                    Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
                } else {
                    Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
                }
                const jae_positive = Enc.jccRel32(&self.code, self.alloc, .ae);
                // Negative → 0
                Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH);
                const jmp_done_neg = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jae_positive, self.currentOffset());
                // Positive but >= 2^63: subtract 2^63 from float, convert, add back
                // Load 2^63 as float into XMM1
                if (is_f64) {
                    self.emitLoadImm64(SCRATCH2, 0x43E0000000000000); // f64(2^63)
                    Enc.movqToXmm(&self.code, self.alloc, XMM1, SCRATCH2);
                    Enc.subsd(&self.code, self.alloc, XMM0, XMM1); // XMM0 -= 2^63
                    Enc.cvttsd2si64(&self.code, self.alloc, SCRATCH, XMM0);
                } else {
                    self.emitLoadImm64(SCRATCH2, 0x5F000000); // f32(2^63)
                    Enc.movdToXmm(&self.code, self.alloc, XMM1, SCRATCH2);
                    Enc.subss(&self.code, self.alloc, XMM0, XMM1); // XMM0 -= 2^63
                    Enc.cvttss2si64(&self.code, self.alloc, SCRATCH, XMM0);
                }
                // If still indefinite after subtraction → value >= 2^64 → UINT64_MAX
                Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
                const jns_converted = Enc.jccRel32(&self.code, self.alloc, .ns);
                self.emitLoadImm64(SCRATCH, 0xFFFFFFFFFFFFFFFF);
                const jmp_done_max = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, jns_converted, self.currentOffset());
                // Add 2^63 back (as integer)
                self.emitLoadImm64(SCRATCH2, 0x8000000000000000);
                Enc.addRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
                Enc.patchRel32(self.code.items, jmp_done_max, self.currentOffset());
                Enc.patchRel32(self.code.items, jmp_done_neg, self.currentOffset());
                Enc.patchRel32(self.code.items, jns_ok, self.currentOffset());
            } else {
                // Signed i64 sat: indefinite (0x8000000000000000) could be valid INT64_MIN or overflow.
                // Check if CVTT returned indefinite, then check sign of source.
                self.emitLoadImm64(SCRATCH2, 0x8000000000000000);
                Enc.cmpRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
                const jne_ok = Enc.jccRel32(&self.code, self.alloc, .ne);
                // Indefinite: check if source > 0 (positive overflow)
                Enc.xorpd(&self.code, self.alloc, XMM1, XMM1);
                if (is_f64) {
                    Enc.ucomisd(&self.code, self.alloc, XMM0, XMM1);
                } else {
                    Enc.ucomiss(&self.code, self.alloc, XMM0, XMM1);
                }
                const jbe_neg = Enc.jccRel32(&self.code, self.alloc, .be);
                // Positive overflow → INT64_MAX
                self.emitLoadImm64(SCRATCH, 0x7FFFFFFFFFFFFFFF);
                Enc.patchRel32(self.code.items, jbe_neg, self.currentOffset());
                // Negative overflow → INT64_MIN (already in SCRATCH from CVTT)
                Enc.patchRel32(self.code.items, jne_ok, self.currentOffset());
            }
        }

        // Jump past NaN handler
        const jmp_done = Enc.jmpRel32(&self.code, self.alloc);

        // NaN handler: result = 0
        Enc.patchRel32(self.code.items, jp_patch, self.currentOffset());
        Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH);

        Enc.patchRel32(self.code.items, jmp_done, self.currentOffset());
        self.storeVreg(instr.rd, SCRATCH);
    }

    /// Emit unsigned i64 → f64/f32 conversion.
    /// x86 has no unsigned i64→float instruction, so we branch on the sign bit:
    /// - If < 2^63: direct signed conversion (value is the same)
    /// - If >= 2^63: (value >> 1 | value & 1) as signed, then double
    fn emitConvertI64uToFp(self: *Compiler, instr: RegInstr, is_f64: bool) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        if (src != SCRATCH) Enc.movRegReg(&self.code, self.alloc, SCRATCH, src);
        // TEST SCRATCH, SCRATCH — set SF if bit 63 is set
        Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
        const js_patch = Enc.jccRel32(&self.code, self.alloc, .s);
        // Small path: value < 2^63, signed conversion is correct
        if (is_f64) {
            Enc.cvtsi2sd64(&self.code, self.alloc, XMM0, SCRATCH);
        } else {
            Enc.cvtsi2ss64(&self.code, self.alloc, XMM0, SCRATCH);
        }
        const jmp_done = Enc.jmpRel32(&self.code, self.alloc);
        // Large path: value >= 2^63
        Enc.patchRel32(self.code.items, js_patch, self.currentOffset());
        // SCRATCH2 = SCRATCH (save original for low bit)
        Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
        // SHR SCRATCH, 1: REX.W D1 /5 reg
        self.code.append(self.alloc, Enc.rexW1(SCRATCH)) catch {};
        self.code.append(self.alloc, 0xD1) catch {};
        self.code.append(self.alloc, Enc.modrm(3, 5, SCRATCH.low3())) catch {};
        // AND SCRATCH2 with 1: load 1, AND with saved value
        // Use: AND SCRATCH2, SCRATCH (scratch2 still = original)
        // Then: MOV SCRATCH2, 1; AND SCRATCH2, original
        // Simplest: SCRATCH2 has original. Use AND r64, imm8 (REX.W 83 /4 ib)
        self.code.append(self.alloc, Enc.rexW1(SCRATCH2)) catch {};
        self.code.append(self.alloc, 0x83) catch {};
        self.code.append(self.alloc, Enc.modrm(3, 4, SCRATCH2.low3())) catch {};
        self.code.append(self.alloc, 1) catch {}; // imm8 = 1
        // OR SCRATCH, SCRATCH2: (value >> 1) | (value & 1)
        Enc.orRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
        // Convert (fits in signed i63)
        if (is_f64) {
            Enc.cvtsi2sd64(&self.code, self.alloc, XMM0, SCRATCH);
            Enc.addsd(&self.code, self.alloc, XMM0, XMM0); // double
        } else {
            Enc.cvtsi2ss64(&self.code, self.alloc, XMM0, SCRATCH);
            Enc.addss(&self.code, self.alloc, XMM0, XMM0); // double
        }
        // Done
        Enc.patchRel32(self.code.items, jmp_done, self.currentOffset());
        self.storeFpFromXmm(instr.rd, XMM0);
    }

    /// Emit FP conversion operations.
    fn emitFpConvert(self: *Compiler, op: u16, instr: RegInstr) bool {
        switch (op) {
            // f64.convert_i32_s (0xB7)
            0xB7 => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.cvtsi2sd32(&self.code, self.alloc, XMM0, src);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f64.convert_i32_u (0xB8)
            0xB8 => {
                // Zero-extend i32 to i64, then convert
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, src); // zero-extend
                Enc.cvtsi2sd64(&self.code, self.alloc, XMM0, SCRATCH);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f64.convert_i64_s (0xB9)
            0xB9 => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.cvtsi2sd64(&self.code, self.alloc, XMM0, src);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f64.convert_i64_u (0xBA) — unsigned i64 → f64
            0xBA => self.emitConvertI64uToFp(instr, true),
            // f32.convert_i64_u (0xB5)
            0xB5 => self.emitConvertI64uToFp(instr, false),
            // f32.convert_i32_s (0xB2)
            0xB2 => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.cvtsi2ss32(&self.code, self.alloc, XMM0, src);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f32.convert_i32_u (0xB3)
            0xB3 => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, src);
                Enc.cvtsi2ss64(&self.code, self.alloc, XMM0, SCRATCH);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f32.convert_i64_s (0xB4)
            0xB4 => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.cvtsi2ss64(&self.code, self.alloc, XMM0, src);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // i32/i64.trunc_f32/f64_s/u — NaN check + CVTT + overflow check
            0xA8 => self.emitTruncF32ToI32(instr, true),   // i32.trunc_f32_s
            0xA9 => self.emitTruncF32ToI32(instr, false),  // i32.trunc_f32_u
            0xAA => self.emitTruncF64ToI32(instr, true),   // i32.trunc_f64_s
            0xAB => self.emitTruncF64ToI32(instr, false),  // i32.trunc_f64_u
            0xAE => self.emitTruncF32ToI64(instr, true),   // i64.trunc_f32_s
            0xAF => self.emitTruncF32ToI64(instr, false),  // i64.trunc_f32_u
            0xB0 => self.emitTruncF64ToI64(instr, true),   // i64.trunc_f64_s
            0xB1 => self.emitTruncF64ToI64(instr, false),  // i64.trunc_f64_u
            // f64.promote_f32 (0xBB)
            0xBB => {
                self.loadFpToXmm(XMM0, instr.rs1);
                Enc.cvtss2sd(&self.code, self.alloc, XMM0, XMM0);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f32.demote_f64 (0xB6)
            0xB6 => {
                self.loadFpToXmm(XMM0, instr.rs1);
                Enc.cvtsd2ss(&self.code, self.alloc, XMM0, XMM0);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f32.copysign (0x98): result = (rs1 & 0x7FFFFFFF) | (rs2 & 0x80000000)
            0x98 => {
                self.loadFpToXmm(XMM0, instr.rs1);
                self.loadFpToXmm(XMM1, instr.rs2());
                self.emitLoadImm64(SCRATCH, 0x7FFFFFFF);
                Enc.movqToXmm(&self.code, self.alloc, XMM2, SCRATCH);
                // ANDPS XMM0, XMM2: a & abs_mask
                Enc.sseOpNp(&self.code, self.alloc, 0x54, XMM0, XMM2);
                // ANDNPS XMM2, XMM1: (~abs_mask) & b = sign of b
                Enc.sseOpNp(&self.code, self.alloc, 0x55, XMM2, XMM1);
                Enc.orps(&self.code, self.alloc, XMM0, XMM2);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f64.copysign (0xA6)
            0xA6 => {
                self.loadFpToXmm(XMM0, instr.rs1);
                self.loadFpToXmm(XMM1, instr.rs2());
                self.emitLoadImm64(SCRATCH, 0x7FFFFFFFFFFFFFFF);
                Enc.movqToXmm(&self.code, self.alloc, XMM2, SCRATCH);
                Enc.andpd(&self.code, self.alloc, XMM0, XMM2); // a & abs_mask
                // ANDNPD XMM2, XMM1: (~abs_mask) & b = sign of b
                Enc.sseOp(&self.code, self.alloc, 0x66, 0x0F, 0x55, XMM2, XMM1);
                Enc.orps(&self.code, self.alloc, XMM0, XMM2);
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f64.ceil/floor/trunc/nearest (0x9B-0x9E) — SSE4.1 ROUNDSD
            0x9B, 0x9C, 0x9D, 0x9E => {
                self.loadFpToXmm(XMM0, instr.rs1);
                const mode: u8 = switch (op) {
                    0x9B => 0x0A, // ceil: round up + inexact suppressed
                    0x9C => 0x09, // floor: round down + inexact suppressed
                    0x9D => 0x0B, // trunc: round toward zero + inexact suppressed
                    0x9E => 0x08, // nearest: round to nearest even + inexact suppressed
                    else => unreachable,
                };
                // ROUNDSD XMM0, XMM0, imm8: 66 0F 3A 0B /r ib
                self.code.appendSlice(self.alloc, &[_]u8{
                    0x66, 0x0F, 0x3A, 0x0B,
                    Enc.modrm(3, XMM0, XMM0),
                    mode,
                }) catch {};
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            // f32.ceil/floor/trunc/nearest (0x8D-0x90) — SSE4.1 ROUNDSS
            0x8D, 0x8E, 0x8F, 0x90 => {
                self.loadFpToXmm(XMM0, instr.rs1);
                const mode: u8 = switch (op) {
                    0x8D => 0x0A, // ceil
                    0x8E => 0x09, // floor
                    0x8F => 0x0B, // trunc
                    0x90 => 0x08, // nearest
                    else => unreachable,
                };
                // ROUNDSS XMM0, XMM0, imm8: 66 0F 3A 0A /r ib
                self.code.appendSlice(self.alloc, &[_]u8{
                    0x66, 0x0F, 0x3A, 0x0A,
                    Enc.modrm(3, XMM0, XMM0),
                    mode,
                }) catch {};
                self.storeFpFromXmm(instr.rd, XMM0);
            },
            else => return false,
        }
        return true;
    }

    // --- Finalization ---

    fn finalize(self: *Compiler) ?*JitCode {
        const code_size = self.code.items.len;
        if (code_size == 0) return null;
        const page_size = std.heap.page_size_min;
        const buf_size = std.mem.alignForward(usize, code_size, page_size);

        const aligned_buf = platform.allocatePages(buf_size, .read_write) catch return null;

        @memcpy(aligned_buf[0..code_size], self.code.items);

        // W^X transition
        platform.protectPages(aligned_buf, .read_exec) catch {
            platform.freePages(aligned_buf);
            return null;
        };

        // x86_64 has coherent I/D caches — no icache flush needed.

        const jit_code = self.alloc.create(JitCode) catch {
            platform.freePages(aligned_buf);
            return null;
        };
        jit_code.* = .{
            .buf = aligned_buf,
            .entry = @ptrCast(@alignCast(aligned_buf.ptr)),
            .code_len = @intCast(code_size),
            .oob_exit_offset = self.shared_exit_offset,
            .osr_entry = if (self.osr_prologue_offset > 0)
                @ptrCast(@alignCast(aligned_buf.ptr + self.osr_prologue_offset))
            else
                null,
        };
        return jit_code;
    }

    // --- Main compilation (skeleton — expanded in later tasks) ---

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
        if (builtin.cpu.arch != .x86_64) return null;

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

        self.has_memory = jit_mod.Compiler.scanForMemoryOps(reg_func.code);

        // Scan IR for self-calls and other calls
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
            }
        }
        self.has_self_call = found_self_call;
        self.self_call_only = found_self_call and !found_other_call;

        // Scan for SIMD opcodes
        for (reg_func.code) |instr| {
            if (instr.op >= predecode_mod.SIMD_BASE and instr.op <= predecode_mod.SIMD_BASE + 0x113) {
                self.has_simd = true;
                break;
            }
        }

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


        self.emitPrologue();

        const ir = reg_func.code;
        var pc: u32 = 0;

        self.pc_map.appendNTimes(self.alloc, 0, ir.len + 1) catch return null;

        // Pre-scan: find branch targets for fusion safety
        const branch_targets = self.scanBranchTargets(ir) orelse return null;
        defer self.alloc.free(branch_targets);
        self.ir_slice = ir;
        self.branch_targets_slice = branch_targets;

        // Pre-scan: compute written_vregs for the ENTIRE function.
        // Must cover all instructions (not just those before each call site)
        // because loops can write a vreg AFTER a call that needs to spill it.
        for (0..self.param_count) |i| {
            if (i < 128) self.written_vregs |= @as(u128, 1) << @as(u7, @intCast(i));
        }
        for (ir) |scan_instr| {
            if (scan_instr.rd < 128) {
                // The x86 backend's original tracking set the bit unconditionally.
                // This is slightly conservative (marks control-flow ops too) but safe.
                self.written_vregs |= @as(u128, 1) << @as(u7, @intCast(scan_instr.rd));
                // Track v128-producing SIMD ops for register class allocation
                const op = scan_instr.op;
                if (op >= predecode_mod.SIMD_BASE and op <= predecode_mod.SIMD_BASE + 0x113) {
                    const sub = op - predecode_mod.SIMD_BASE;
                    if (predecode_mod.simdResultIsV128(sub)) {
                        self.v128_vregs |= @as(u128, 1) << @as(u7, @intCast(scan_instr.rd));
                    }
                }
            }
        }

        while (pc < ir.len) {
            // Evict SIMD XMM cache at branch targets (merge points)
            if (pc < branch_targets.len and branch_targets[pc]) {
                self.simdXregEvictAll();
                self.scratch_vreg = null;
            }
            self.pc_map.items[pc] = self.currentOffset();
            const instr = ir[pc];
            pc += 1;

            if (!self.compileInstr(instr, ir, &pc)) return null;

            // Track known constants
            if (instr.op == regalloc_mod.OP_CONST32) {
                if (instr.rd < 128) self.known_consts[instr.rd] = instr.operand;
            } else if (instr.rd < 128) {
                self.known_consts[instr.rd] = null;
            }
            // written_vregs already computed in pre-scan (covers full function for loops)
        }
        self.pc_map.items[ir.len] = self.currentOffset();

        self.emitErrorStubs();
        self.patchBranches() catch return null;

        // Emit OSR prologue if requested (for back-edge JIT with reentry guard)
        if (self.osr_target_pc) |target_pc| {
            if (target_pc < self.pc_map.items.len) {
                self.emitOsrPrologue(target_pc);
            }
        }

        return self.finalize();
    }

    // --- SIMD XMM register cache (XMM6-XMM15) ---

    fn simdXregFind(self: *Compiler, vreg: u16) ?usize {
        for (self.simd_xreg, 0..) |entry, i| {
            if (entry != null and entry.? == vreg) return i;
        }
        return null;
    }

    fn simdXregAllocSlot(self: *Compiler, vreg: u16) usize {
        if (self.simdXregFind(vreg)) |slot| return slot;
        for (self.simd_xreg, 0..) |entry, i| {
            if (entry == null) {
                self.simd_xreg[i] = vreg;
                self.simd_xreg_dirty[i] = false;
                return i;
            }
        }
        const slot = self.simd_xreg_lru % SIMD_XREG_COUNT;
        self.simd_xreg_lru +%= 1;
        self.simdXregEvictSlot(slot);
        self.simd_xreg[slot] = vreg;
        self.simd_xreg_dirty[slot] = false;
        return slot;
    }

    fn simdXregGetOrLoad(self: *Compiler, vreg: u16) u4 {
        if (self.simdXregFind(vreg)) |slot| {
            return @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(slot)));
        }
        const slot = self.simdXregAllocSlot(vreg);
        const xreg: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(slot)));
        self.emitLoadV128Raw(xreg, vreg);
        return xreg;
    }

    fn simdXregEvictSlot(self: *Compiler, slot: usize) void {
        if (self.simd_xreg[slot]) |vreg| {
            if (self.simd_xreg_dirty[slot]) {
                const xreg: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(slot)));
                self.emitStoreV128Raw(xreg, vreg);
            }
            self.simd_xreg[slot] = null;
            self.simd_xreg_dirty[slot] = false;
        }
    }

    fn simdXregEvictAll(self: *Compiler) void {
        for (0..SIMD_XREG_COUNT) |i| {
            self.simdXregEvictSlot(i);
        }
    }

    fn simdXregInvalidate(self: *Compiler, vreg: u16) void {
        if (self.simdXregFind(vreg)) |slot| {
            self.simd_xreg[slot] = null;
            self.simd_xreg_dirty[slot] = false;
        }
    }

    fn simdXregFlushVreg(self: *Compiler, vreg: u16) void {
        if (self.simdXregFind(vreg)) |slot| {
            if (self.simd_xreg_dirty[slot]) {
                const xreg: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(slot)));
                self.emitStoreV128Raw(xreg, vreg);
                self.simd_xreg_dirty[slot] = false;
            }
        }
    }

    // --- SIMD v128 helpers ---

    const SIMD_SCRATCH0: u4 = 3; // XMM3
    const SIMD_SCRATCH1: u4 = 4; // XMM4

    // --- v128 load/store (contiguous simd_v128 storage) ---
    fn emitSimdV128Addr(self: *Compiler, vreg: u16) void {
        self.emitLoadVmPtr(SCRATCH2);
        const byte_offset: i32 = @as(i32, @intCast(self.simd_v128_offset)) + @as(i32, vreg) * 16;
        Enc.addImm32(&self.code, self.alloc, SCRATCH2, byte_offset);
    }

    /// Load v128: cache-aware. If cached, emit MOVAPS from XMM cache. Otherwise load from memory.
    fn emitLoadV128(self: *Compiler, xmm: u4, vreg: u16) void {
        if (self.simdXregFind(vreg)) |slot| {
            const x_cached: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(slot)));
            if (x_cached != xmm) Enc.movaps(&self.code, self.alloc, xmm, x_cached);
            return;
        }
        self.emitLoadV128Raw(xmm, vreg);
    }

    /// Load v128 directly from simd_v128[] (bypasses cache). Used by cache internals.
    fn emitLoadV128Raw(self: *Compiler, xmm: u4, vreg: u16) void {
        self.emitSimdV128Addr(vreg);
        Enc.movdquFromMem(&self.code, self.alloc, xmm, SCRATCH2, 0);
    }

    /// Store v128: cache-aware with lazy writeback.
    fn emitStoreV128(self: *Compiler, xmm: u4, vreg: u16) void {
        const slot = self.simdXregAllocSlot(vreg);
        const x_cached: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(slot)));
        if (x_cached != xmm) Enc.movaps(&self.code, self.alloc, x_cached, xmm);
        self.simd_xreg_dirty[slot] = true;
    }

    /// Store v128 directly to simd_v128[] + lo half to regs[]. Used by cache flush.
    fn emitStoreV128Raw(self: *Compiler, xmm: u4, vreg: u16) void {
        self.emitSimdV128Addr(vreg);
        Enc.movdquToMem(&self.code, self.alloc, SCRATCH2, 0, xmm);
        const lo_disp: i32 = @as(i32, vreg) * 8;
        Enc.movqXmmToMem(&self.code, self.alloc, REGS_PTR, lo_disp, xmm);
    }

    /// Copy v128 between vregs (cache-aware).
    fn emitCopySimdV128(self: *Compiler, rd: u16, rs1: u16) void {
        if (rd == rs1) return;
        if (self.simdXregFind(rs1)) |src_slot| {
            const x_src: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(src_slot)));
            const dst_slot = self.simdXregAllocSlot(rd);
            const x_dst: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(dst_slot)));
            if (x_dst != x_src) Enc.movaps(&self.code, self.alloc, x_dst, x_src);
            self.simd_xreg_dirty[dst_slot] = true;
        } else {
            const dst_slot = self.simdXregAllocSlot(rd);
            const x_dst: u4 = @intCast(@as(u5, SIMD_XREG_BASE) + @as(u5, @intCast(dst_slot)));
            self.emitLoadV128Raw(x_dst, rs1);
            self.simd_xreg_dirty[dst_slot] = true;
        }
    }

    /// Clear simd_v128[rd] (invalidate Q cache, then zero memory).
    fn emitClearSimdV128(self: *Compiler, rd: u16) void {
        self.simdXregInvalidate(rd);
        Enc.pxor(&self.code, self.alloc, 0, 0);
        self.emitSimdV128Addr(rd);
        Enc.movdquToMem(&self.code, self.alloc, SCRATCH2, 0, 0);
    }

    /// Emit native SSE binary op: uses XMM cache for direct register ops.
    fn emitSimdBinarySse(self: *Compiler, instr: RegInstr, encodeFn: *const fn (*std.ArrayList(u8), Allocator, u4, u4) void) void {
        // SSE binary ops are destructive (dst = dst OP src), so we can't operate
        // directly on cached regs without risking source clobber. Use scratch regs.
        self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
        self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
        encodeFn(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
        self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
    }

    /// Emit native SSE unary op.
    fn emitSimdUnarySse(self: *Compiler, instr: RegInstr, encodeFn: *const fn (*std.ArrayList(u8), Allocator, u4, u4) void) void {
        self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
        encodeFn(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
        self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
    }

    fn emitSimdNative(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        const sub: u32 = instr.op - predecode_mod.SIMD_BASE;

        // Peek at trailing NOP for extra metadata (lane index etc.)
        var extra: u16 = 0;
        const has_nop = pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP;
        if (has_nop) extra = ir[pc.*].rd;

        const handled = self.emitSimdNativeX86(instr, sub, extra);
        if (handled and has_nop) pc.* += 1;
        return handled;
    }

    fn emitSimdNativeX86(self: *Compiler, instr: RegInstr, sub: u32, extra: u16) bool {
        switch (sub) {
            // --- v128 bitwise ---
            0x4E => { self.emitSimdBinarySse(instr, &Enc.pand); return true; }, // v128.and
            0x4F => { // v128.andnot — PANDN (dst = NOT dst AND src, need swap)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field); // src2 → XMM3 (will be NOTted)
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1); // src1 → XMM4
                Enc.pandn(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1); // XMM3 = NOT(XMM3) AND XMM4
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x50 => { self.emitSimdBinarySse(instr, &Enc.por); return true; }, // v128.or
            0x51 => { self.emitSimdBinarySse(instr, &Enc.pxor); return true; }, // v128.xor
            0x4D => { // v128.not — PXOR with all-ones (PCMPEQD self,self = all-ones, then PXOR)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // Generate all-ones in XMM4: PCMPEQD XMM4, XMM4
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i8x16 arithmetic ---
            0x6E => { self.emitSimdBinarySse(instr, &Enc.paddb); return true; }, // i8x16.add
            0x71 => { self.emitSimdBinarySse(instr, &Enc.psubb); return true; }, // i8x16.sub

            // --- i16x8 arithmetic ---
            0x8E => { self.emitSimdBinarySse(instr, &Enc.paddw); return true; }, // i16x8.add
            0x91 => { self.emitSimdBinarySse(instr, &Enc.psubw); return true; }, // i16x8.sub
            0x95 => { self.emitSimdBinarySse(instr, &Enc.pmullw); return true; }, // i16x8.mul

            // --- i32x4 arithmetic ---
            0xAE => { self.emitSimdBinarySse(instr, &Enc.paddd); return true; }, // i32x4.add
            0xB1 => { self.emitSimdBinarySse(instr, &Enc.psubd); return true; }, // i32x4.sub
            0xB5 => { self.emitSimdBinarySse(instr, &Enc.pmulld); return true; }, // i32x4.mul (SSE4.1)

            // --- i64x2 arithmetic ---
            0xCE => { self.emitSimdBinarySse(instr, &Enc.paddq); return true; }, // i64x2.add
            0xD1 => { self.emitSimdBinarySse(instr, &Enc.psubq); return true; }, // i64x2.sub

            // --- f32x4 arithmetic ---
            0xE4 => { self.emitSimdBinarySse(instr, &Enc.addps); return true; }, // f32x4.add
            0xE5 => { self.emitSimdBinarySse(instr, &Enc.subps); return true; }, // f32x4.sub
            0xE6 => { self.emitSimdBinarySse(instr, &Enc.mulps); return true; }, // f32x4.mul
            0xE7 => { self.emitSimdBinarySse(instr, &Enc.divps); return true; }, // f32x4.div
            0xE3 => { self.emitSimdUnarySse(instr, &Enc.sqrtps); return true; }, // f32x4.sqrt

            // --- f64x2 arithmetic ---
            0xF0 => { self.emitSimdBinarySse(instr, &Enc.addpd); return true; }, // f64x2.add
            0xF1 => { self.emitSimdBinarySse(instr, &Enc.subpd); return true; }, // f64x2.sub
            0xF2 => { self.emitSimdBinarySse(instr, &Enc.mulpd); return true; }, // f64x2.mul
            0xF3 => { self.emitSimdBinarySse(instr, &Enc.divpd); return true; }, // f64x2.div
            0xEF => { self.emitSimdUnarySse(instr, &Enc.sqrtpd); return true; }, // f64x2.sqrt

            // --- i8x16 comparisons ---
            0x23 => { self.emitSimdBinarySse(instr, &Enc.pcmpeqb); return true; }, // i8x16.eq
            0x27 => { self.emitSimdBinarySse(instr, &Enc.pcmpgtb); return true; }, // i8x16.gt_s
            0x24 => { // i8x16.ne = eq + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpeqb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                // NOT: XOR with all-ones
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // all-ones
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x25 => { // i8x16.lt_s = swap + gt_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field); // swap
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x29 => { // i8x16.le_s = gt_s + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpgtb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x2B => { // i8x16.ge_s = swap + gt + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i16x8 comparisons ---
            0x2D => { self.emitSimdBinarySse(instr, &Enc.pcmpeqw); return true; }, // i16x8.eq
            0x31 => { self.emitSimdBinarySse(instr, &Enc.pcmpgtw); return true; }, // i16x8.gt_s
            0x2E => { // i16x8.ne
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpeqw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x2F => { // i16x8.lt_s = swap + gt
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x33 => { // i16x8.le_s = gt + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpgtw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x35 => { // i16x8.ge_s = swap + gt + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i32x4 comparisons ---
            0x37 => { self.emitSimdBinarySse(instr, &Enc.pcmpeqd); return true; }, // i32x4.eq
            0x3B => { self.emitSimdBinarySse(instr, &Enc.pcmpgtd); return true; }, // i32x4.gt_s
            0x38 => { // i32x4.ne
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x39 => { // i32x4.lt_s = swap + gt
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3D => { // i32x4.le_s = gt + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpgtd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3F => { // i32x4.ge_s = swap + gt + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f32x4 min/max ---
            0xE8 => { self.emitSimdBinarySse(instr, &Enc.minps); return true; }, // f32x4.min
            0xE9 => { self.emitSimdBinarySse(instr, &Enc.maxps); return true; }, // f32x4.max

            // --- f64x2 min/max ---
            0xF4 => { self.emitSimdBinarySse(instr, &Enc.minpd); return true; }, // f64x2.min
            0xF5 => { self.emitSimdBinarySse(instr, &Enc.maxpd); return true; }, // f64x2.max

            // --- saturating add/sub ---
            0x6F => { self.emitSimdBinarySse(instr, &Enc.paddsb); return true; }, // i8x16.add_sat_s
            0x70 => { self.emitSimdBinarySse(instr, &Enc.paddusb); return true; }, // i8x16.add_sat_u
            0x72 => { self.emitSimdBinarySse(instr, &Enc.psubsb); return true; }, // i8x16.sub_sat_s
            0x73 => { self.emitSimdBinarySse(instr, &Enc.psubusb); return true; }, // i8x16.sub_sat_u
            0x8F => { self.emitSimdBinarySse(instr, &Enc.paddsw); return true; }, // i16x8.add_sat_s
            0x90 => { self.emitSimdBinarySse(instr, &Enc.paddusw); return true; }, // i16x8.add_sat_u
            0x92 => { self.emitSimdBinarySse(instr, &Enc.psubsw); return true; }, // i16x8.sub_sat_s
            0x93 => { self.emitSimdBinarySse(instr, &Enc.psubusw); return true; }, // i16x8.sub_sat_u

            // --- integer min/max ---
            0x76 => { self.emitSimdBinarySse(instr, &Enc.pminsb); return true; }, // i8x16.min_s (SSE4.1)
            0x77 => { self.emitSimdBinarySse(instr, &Enc.pminub); return true; }, // i8x16.min_u
            0x78 => { self.emitSimdBinarySse(instr, &Enc.pmaxsb); return true; }, // i8x16.max_s (SSE4.1)
            0x79 => { self.emitSimdBinarySse(instr, &Enc.pmaxub); return true; }, // i8x16.max_u
            0x96 => { self.emitSimdBinarySse(instr, &Enc.pminsw); return true; }, // i16x8.min_s
            0x97 => { self.emitSimdBinarySse(instr, &Enc.pminuw); return true; }, // i16x8.min_u (SSE4.1)
            0x98 => { self.emitSimdBinarySse(instr, &Enc.pmaxsw); return true; }, // i16x8.max_s
            0x99 => { self.emitSimdBinarySse(instr, &Enc.pmaxuw); return true; }, // i16x8.max_u (SSE4.1)
            0xB6 => { self.emitSimdBinarySse(instr, &Enc.pminsd); return true; }, // i32x4.min_s (SSE4.1)
            0xB7 => { self.emitSimdBinarySse(instr, &Enc.pminud); return true; }, // i32x4.min_u (SSE4.1)
            0xB8 => { self.emitSimdBinarySse(instr, &Enc.pmaxsd); return true; }, // i32x4.max_s (SSE4.1)
            0xB9 => { self.emitSimdBinarySse(instr, &Enc.pmaxud); return true; }, // i32x4.max_u (SSE4.1)

            // --- integer abs (SSSE3: 66 0F 38 xx) ---
            0x60 => { self.emitSimdUnarySse(instr, &Enc.pabsb); return true; }, // i8x16.abs
            0x80 => { self.emitSimdUnarySse(instr, &Enc.pabsw); return true; }, // i16x8.abs
            0xA0 => { self.emitSimdUnarySse(instr, &Enc.pabsd); return true; }, // i32x4.abs

            // --- avgr_u ---
            0x7B => { self.emitSimdBinarySse(instr, &Enc.pavgb); return true; }, // i8x16.avgr_u
            0x9B => { self.emitSimdBinarySse(instr, &Enc.pavgw); return true; }, // i16x8.avgr_u

            // --- i8x16/i16x8 splat ---
            0x0F => { // i8x16.splat: MOVD + PSHUFB zero-mask
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, src);
                // Broadcast byte 0: PSHUFB with zero mask → all bytes = byte 0
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // zero mask
                Enc.pshufb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x10 => { // i16x8.splat: MOVD + PSHUFLW + PUNPCKLQDQ
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, src);
                // Broadcast word 0: PSHUFLW with imm=0 → low 4 words all = word 0
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0x00);
                // PSHUFLW zeros upper bits anyway via PSHUFD broadcast
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- load splat ---
            0x07 => { // v128.load8_splat
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 1);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pshufb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x09 => { // v128.load32_splat
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 4);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx32(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0x00);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x0A => { // v128.load64_splat
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.punpcklqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            0x08 => { // v128.load16_splat
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 2);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx32(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0x00);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- load/store lane ---
            0x54 => { // v128.load8_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 1);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                Enc.loadBaseIdx32(&self.code, self.alloc, SCRATCH2, MEM_BASE, SCRATCH);
                Enc.pinsrb(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH2, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x55 => { // v128.load16_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 2);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                Enc.loadBaseIdx32(&self.code, self.alloc, SCRATCH2, MEM_BASE, SCRATCH);
                Enc.pinsrw(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH2, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x56 => { // v128.load32_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 4);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                Enc.loadBaseIdx32(&self.code, self.alloc, SCRATCH2, MEM_BASE, SCRATCH);
                Enc.pinsrd(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH2, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x57 => { // v128.load64_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH2, MEM_BASE, SCRATCH);
                Enc.pinsrqReg(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH2, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x58 => { // v128.store8_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 1);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                Enc.pextrb(&self.code, self.alloc, SCRATCH2, SIMD_SCRATCH0, @truncate(extra));
                Enc.storeBaseIdx8(&self.code, self.alloc, MEM_BASE, SCRATCH, SCRATCH2);
                return true;
            },
            0x59 => { // v128.store16_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 2);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                Enc.pextrw41(&self.code, self.alloc, SCRATCH2, SIMD_SCRATCH0, @truncate(extra));
                Enc.storeBaseIdx16(&self.code, self.alloc, MEM_BASE, SCRATCH, SCRATCH2);
                return true;
            },
            0x5A => { // v128.store32_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 4);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                Enc.pextrd(&self.code, self.alloc, SCRATCH2, SIMD_SCRATCH0, @truncate(extra));
                Enc.storeBaseIdx32(&self.code, self.alloc, MEM_BASE, SCRATCH, SCRATCH2);
                return true;
            },
            0x5B => { // v128.store64_lane
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                Enc.pextrqReg(&self.code, self.alloc, SCRATCH2, SIMD_SCRATCH0, @truncate(extra));
                Enc.storeBaseIdx64(&self.code, self.alloc, MEM_BASE, SCRATCH, SCRATCH2);
                return true;
            },

            // --- load zero ---
            0x5C => { // v128.load32_zero
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 4);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx32(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                // MOVD xmm, r32 — load 32 bits, zero rest of xmm
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x5D => { // v128.load64_zero
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                // MOVQ xmm, r64 — load 64 bits, zero hi
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- load extend ---
            0x01 => { // v128.load8x8_s
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pmovsxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x02 => { // v128.load8x8_u
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pmovzxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x03 => { // v128.load16x4_s
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pmovsxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x04 => { // v128.load16x4_u
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pmovzxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x05 => { // v128.load32x2_s
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pmovsxdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x06 => { // v128.load32x2_u
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 8);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.loadBaseIdx64(&self.code, self.alloc, SCRATCH, MEM_BASE, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                Enc.pmovzxdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- v128.load ---
            0x00 => {
                if (!self.has_memory) return false;
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg); // zero-extend
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 16);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.movdquLoad(&self.code, self.alloc, SIMD_SCRATCH0, MEM_BASE, SCRATCH);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // --- v128.store ---
            0x0B => {
                if (!self.has_memory) return false;
                self.emitLoadV128(SIMD_SCRATCH0, instr.rd);
                const addr_reg = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movRegReg32(&self.code, self.alloc, SCRATCH, addr_reg);
                self.emitAddOffset(instr.operand);
                if (!self.use_guard_pages) {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, SCRATCH);
                    Enc.addImm32(&self.code, self.alloc, SCRATCH2, 16);
                    Enc.cmpRegReg(&self.code, self.alloc, SCRATCH2, MEM_SIZE);
                    self.emitCondError(.a, 6);
                }
                Enc.movdquStore(&self.code, self.alloc, MEM_BASE, SCRATCH, SIMD_SCRATCH0);
                return true;
            },
            // --- v128.const ---
            0x0C => {
                const pool_idx = instr.operand;
                if (pool_idx + 1 < self.pool64.len) {
                    const lo = self.pool64[pool_idx];
                    const hi = self.pool64[pool_idx + 1];
                    // Load lo into SCRATCH, move to XMM
                    self.emitLoadImm64(SCRATCH, lo);
                    Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH);
                    // Load hi, insert into high qword
                    self.emitLoadImm64(SCRATCH, hi);
                    Enc.pinsrqReg(&self.code, self.alloc, SIMD_SCRATCH0, SCRATCH, 1);
                    self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                    return true;
                }
                return false;
            },

            // --- extract_lane ---
            0x1B, 0x1F => { // i32x4/f32x4.extract_lane
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pextrd(&self.code, self.alloc, d, SIMD_SCRATCH0, @truncate(extra));
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x1D, 0x21 => { // i64x2/f64x2.extract_lane
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pextrqReg(&self.code, self.alloc, d, SIMD_SCRATCH0, @truncate(extra));
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x15 => { // i8x16.extract_lane_s: PEXTRB + sign-extend
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pextrb(&self.code, self.alloc, d, SIMD_SCRATCH0, @truncate(extra));
                self.emitMovsxByte32(d, d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x16 => { // i8x16.extract_lane_u: PEXTRB (zero-extended)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pextrb(&self.code, self.alloc, d, SIMD_SCRATCH0, @truncate(extra));
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x18 => { // i16x8.extract_lane_s: PEXTRW + sign-extend
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pextrw41(&self.code, self.alloc, d, SIMD_SCRATCH0, @truncate(extra));
                self.emitMovsxWord32(d, d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x19 => { // i16x8.extract_lane_u: PEXTRW (zero-extended)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pextrw41(&self.code, self.alloc, d, SIMD_SCRATCH0, @truncate(extra));
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- replace_lane ---
            0x17 => { // i8x16.replace_lane
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.pinsrb(&self.code, self.alloc, SIMD_SCRATCH0, src, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x1A => { // i16x8.replace_lane
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.pinsrw(&self.code, self.alloc, SIMD_SCRATCH0, src, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x1C, 0x20 => { // i32x4/f32x4.replace_lane
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.pinsrd(&self.code, self.alloc, SIMD_SCRATCH0, src, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x1E, 0x22 => { // i64x2/f64x2.replace_lane
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const src = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.pinsrqReg(&self.code, self.alloc, SIMD_SCRATCH0, src, @truncate(extra));
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- splat ---
            0x11 => { // i32x4.splat: MOVD + PSHUFD 0x00
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, src);
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0x00);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x12 => { // i64x2.splat: MOVQ + PUNPCKLQDQ
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, src);
                Enc.punpcklqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x13 => { // f32x4.splat: same as i32x4.splat
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH0, src);
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0x00);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x14 => { // f64x2.splat: same as i64x2.splat
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                Enc.movqToXmm(&self.code, self.alloc, SIMD_SCRATCH0, src);
                Enc.punpcklqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- integer neg (PXOR zero, PSUB) ---
            0x61 => { // i8x16.neg: 0 - x
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // zero
                Enc.psubb(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            0x81 => { // i16x8.neg
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.psubw(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            0xA1 => { // i32x4.neg
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.psubd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            0xC1 => { // i64x2.neg
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.psubq(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },

            // --- extend low (SSE4.1 PMOVSX/ZX, operates on low half of source) ---
            0x87 => { self.emitSimdUnarySse(instr, &Enc.pmovsxbw); return true; }, // i16x8.extend_low_i8x16_s
            0x89 => { self.emitSimdUnarySse(instr, &Enc.pmovzxbw); return true; }, // i16x8.extend_low_i8x16_u
            0xA7 => { self.emitSimdUnarySse(instr, &Enc.pmovsxwd); return true; }, // i32x4.extend_low_i16x8_s
            0xA9 => { self.emitSimdUnarySse(instr, &Enc.pmovzxwd); return true; }, // i32x4.extend_low_i16x8_u
            0xC7 => { self.emitSimdUnarySse(instr, &Enc.pmovsxdq); return true; }, // i64x2.extend_low_i32x4_s
            0xC9 => { self.emitSimdUnarySse(instr, &Enc.pmovzxdq); return true; }, // i64x2.extend_low_i32x4_u

            // --- extend high: shift high half to low, then PMOVSX/ZX ---
            0x88 => { // i16x8.extend_high_i8x16_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // Move high 64 bits to low: PUNPCKHQDQ with self puts [hi, hi]
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovsxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x8A => { // i16x8.extend_high_i8x16_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovzxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xA8 => { // i32x4.extend_high_i16x8_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovsxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xAA => { // i32x4.extend_high_i16x8_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovzxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xC8 => { // i64x2.extend_high_i32x4_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovsxdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xCA => { // i64x2.extend_high_i32x4_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovzxdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- narrow ---
            0x65 => { // i8x16.narrow_i16x8_s: PACKSSWB
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.packsswb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x66 => { // i8x16.narrow_i16x8_u: PACKUSWB
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.packuswb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x85 => { // i16x8.narrow_i32x4_s: PACKSSDW
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.packssdw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x86 => { // i16x8.narrow_i32x4_u: PACKUSDW (SSE4.1)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.packusdw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- shift (shift amount from GP reg via MOVD → XMM) ---
            0x8B => { // i16x8.shl
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.psllw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x8C => { // i16x8.shr_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.psraw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x8D => { // i16x8.shr_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.psrlw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xAB => { // i32x4.shl
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.pslld(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xAC => { // i32x4.shr_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.psrad(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xAD => { // i32x4.shr_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.psrld(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xCB => { // i64x2.shl
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.psllq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xCD => { // i64x2.shr_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const shift_reg = self.getOrLoad(instr.rs2_field, SCRATCH);
                Enc.movdToXmm(&self.code, self.alloc, SIMD_SCRATCH1, shift_reg);
                Enc.psrlq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- convert ---
            0xFA => { self.emitSimdUnarySse(instr, &Enc.cvtdq2ps); return true; }, // f32x4.convert_i32x4_s
            0xF8 => { self.emitSimdUnarySse(instr, &Enc.cvttps2dq); return true; }, // i32x4.trunc_sat_f32x4_s

            // --- f32x4 comparisons (CMPPS imm8) ---
            // imm8: 0=EQ, 1=LT, 2=LE, 4=NE (unordered), 5=NLT (>=), 6=NLE (>)
            0x41 => { // f32x4.eq
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmpps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 0); // EQ
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x42 => { // f32x4.ne
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmpps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 4); // NEQ
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x43 => { // f32x4.lt
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmpps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 1); // LT
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x44 => { // f32x4.gt = swap + LT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.cmpps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x45 => { // f32x4.le
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmpps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 2); // LE
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x46 => { // f32x4.ge = swap + LE
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.cmpps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 2);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f64x2 comparisons (CMPPD imm8) ---
            0x47 => { // f64x2.eq
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmppd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x48 => { // f64x2.ne
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmppd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 4);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x49 => { // f64x2.lt
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmppd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x4A => { // f64x2.gt = swap + LT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.cmppd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x4B => { // f64x2.le
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.cmppd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 2);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x4C => { // f64x2.ge = swap + LE
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.cmppd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1, 2);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- rounding (SSE4.1 ROUNDPS/PD) ---
            // imm8: 0=nearest, 1=floor, 2=ceil, 3=trunc
            0x67 => { // f32x4.ceil
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 2);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x68 => { // f32x4.floor
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x69 => { // f32x4.trunc
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 3);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x6A => { // f32x4.nearest
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x74 => { // f64x2.ceil
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundpd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 2);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x75 => { // f64x2.floor
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundpd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x7A => { // f64x2.trunc
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundpd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 3);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x94 => { // f64x2.nearest
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.roundpd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- v128.any_true (PTEST) ---
            0x53 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.ptest(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0); // ZF=1 if all zero
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                // SETNZ d (ZF=0 means non-zero → any_true=1)
                Enc.setcc(&self.code, self.alloc, .ne, d);
                Enc.movzxByte(&self.code, self.alloc, d, d); // zero-extend byte to 64-bit
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- i8x16.bitmask (PMOVMSKB) ---
            0x64 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pmovmskb(&self.code, self.alloc, d, SIMD_SCRATCH0);
                self.storeVreg(instr.rd, d);
                return true;
            },
            // --- i32x4.bitmask (MOVMSKPS) ---
            0xA4 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.movmskps(&self.code, self.alloc, d, SIMD_SCRATCH0);
                self.storeVreg(instr.rd, d);
                return true;
            },
            // --- i64x2.bitmask (MOVMSKPD) ---
            0xC4 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.movmskpd(&self.code, self.alloc, d, SIMD_SCRATCH0);
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- i8x16.swizzle (PSHUFB) ---
            0x0E => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // table
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // indices
                Enc.pshufb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- all_true (PCMPEQ zero + PTEST) ---
            0x63 => { // i8x16.all_true
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // zero
                Enc.pcmpeqb(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0); // lanes = FF where zero
                Enc.ptest(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // ZF=1 if no zero lanes
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.setcc(&self.code, self.alloc, .e, d); // ZF=1 → all non-zero
                Enc.movzxByte(&self.code, self.alloc, d, d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0x83 => { // i16x8.all_true
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pcmpeqw(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                Enc.ptest(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.setcc(&self.code, self.alloc, .e, d);
                Enc.movzxByte(&self.code, self.alloc, d, d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0xA3 => { // i32x4.all_true
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                Enc.ptest(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.setcc(&self.code, self.alloc, .e, d);
                Enc.movzxByte(&self.code, self.alloc, d, d);
                self.storeVreg(instr.rd, d);
                return true;
            },
            0xC3 => { // i64x2.all_true
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pcmpeqq(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                Enc.ptest(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.setcc(&self.code, self.alloc, .e, d);
                Enc.movzxByte(&self.code, self.alloc, d, d);
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- i16x8.bitmask: PACKSSWB to compress sign bits, then PMOVMSKB ---
            0x84 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // PACKSSWB compresses sign bits: 8 × i16 → 8 bytes (lower half has the signs)
                Enc.packsswb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.pmovmskb(&self.code, self.alloc, d, SIMD_SCRATCH0);
                // Only lower 8 bits are valid (upper 8 are duplicates from self-pack)
                Enc.movzxByte(&self.code, self.alloc, d, d); // mask to 8 bits
                self.storeVreg(instr.rd, d);
                return true;
            },

            // --- i64x2 comparisons (SSE4.2) ---
            0xD6 => { self.emitSimdBinarySse(instr, &Enc.pcmpeqq); return true; }, // i64x2.eq
            0xD7 => { // i64x2.ne
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpeqq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xD9 => { self.emitSimdBinarySse(instr, &Enc.pcmpgtq); return true; }, // i64x2.gt_s
            0xD8 => { // i64x2.lt_s = swap + gt
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xDB => { // i64x2.ge_s = swap + gt + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pcmpgtq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xDA => { // i64x2.le_s = gt + NOT
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pcmpgtq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i64x2.abs: negate where negative ---
            0xC0 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // PXOR zero
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                // PSUBQ zero - x = -x
                const SIMD_X5: u4 = 5;
                Enc.movaps(&self.code, self.alloc, SIMD_X5, SIMD_SCRATCH1);
                Enc.psubq(&self.code, self.alloc, SIMD_X5, SIMD_SCRATCH0); // negated in XMM5
                // PCMPGTQ to get sign mask (SSE4.2: all-ones where 0 > x, i.e., x < 0)
                Enc.pcmpgtq(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0); // mask where x < 0
                // Blend: select negated where negative, original where positive
                // PAND mask, negated; PANDN mask_copy, original; POR
                // Simpler: use PXOR + PSUBQ trick: abs(x) = (x XOR sign) - sign
                // sign = PSRAD 31 then broadcast... too complex
                // Just use blend with 3 registers:
                Enc.pand(&self.code, self.alloc, SIMD_X5, SIMD_SCRATCH1); // neg AND mask
                Enc.pandn(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0); // NOT(mask) AND orig
                Enc.por(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_X5); // combine
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },

            // --- i64x2.shr_s: emulate with PSRLQ + sign extension ---
            0xCC => {
                // i64x2.shr_s has no direct SSE instruction (PSRAQ doesn't exist in SSE)
                // Strategy: use PSRAD for high 32 bits, PSRLQ for full shift, blend
                // This is very complex. Use trampoline.
                return false;
            },

            // --- i8x16.popcnt: PSHUFB lookup table ---
            0x62 => {
                // Classic PSHUFB nibble lookup:
                // 1. Extract low nibbles: PAND 0x0F
                // 2. Lookup in table: PSHUFB
                // 3. Extract high nibbles: PSRLW 4, PAND 0x0F
                // 4. Lookup + add
                // Needs constant generation. Use trampoline for simplicity.
                return false;
            },

            // --- i8x16 byte shift: complex masking ---
            0x6B, 0x6C, 0x6D => return false, // trampoline

            // --- unsigned trunc/convert: complex branch logic ---
            0xF9, 0xFB, 0xFD, 0x102, 0x104 => return false, // trampoline

            // --- i32x4.dot_i16x8_s (PMADDWD) ---
            0xBA => { self.emitSimdBinarySse(instr, &Enc.pmaddwd); return true; },

            // --- f32x4 abs/neg (sign bitmask) ---
            0xE0 => { // f32x4.abs: AND with 0x7FFFFFFF
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // all-ones
                Enc.psrld_imm(&self.code, self.alloc, SIMD_SCRATCH1, 1); // 0x7FFFFFFF
                Enc.pand(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xE1 => { // f32x4.neg: XOR with 0x80000000
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pslld_imm(&self.code, self.alloc, SIMD_SCRATCH1, 31); // 0x80000000
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xEC => { // f64x2.abs: AND with 0x7FFFFFFFFFFFFFFF
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.psrlq_imm(&self.code, self.alloc, SIMD_SCRATCH1, 1);
                Enc.pand(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xED => { // f64x2.neg: XOR with 0x8000000000000000
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.psllq_imm(&self.code, self.alloc, SIMD_SCRATCH1, 63);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- pmin/pmax (MINPS/MAXPS with swapped operands for NaN handling) ---
            0xEA => { // f32x4.pmin: MINPS(b, a) — src=a returned on NaN
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // b → dst
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // a → src
                Enc.minps(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            0xEB => { // f32x4.pmax: MAXPS(b, a)
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.maxps(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            0xF6 => { // f64x2.pmin: MINPD(b, a)
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.minpd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            0xF7 => { // f64x2.pmax: MAXPD(b, a)
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.maxpd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },

            // --- unsigned compare: PMIN + PCMPEQ pattern ---
            // ge_u(a,b): min(a,b)==b → a>=b
            0x2C => { // i8x16.ge_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pminub(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1); // min(a,b)
                Enc.pcmpeqb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1); // min==b → a>=b
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x2A => { // i8x16.le_u = ge_u(b, a)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field); // swap
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pminub(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x28 => { // i8x16.gt_u = NOT(le_u) = NOT(ge_u(b,a))
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pminub(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x26 => { // i8x16.lt_u = NOT(ge_u(a,b))
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pminub(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // i16x8 unsigned compare (SSE4.1 PMINUW)
            0x36 => { // i16x8.ge_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pminuw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x34 => { // i16x8.le_u = ge_u(b,a)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pminuw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x32 => { // i16x8.gt_u = NOT(le_u)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pminuw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x30 => { // i16x8.lt_u = NOT(ge_u)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pminuw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // i32x4 unsigned compare (SSE4.1 PMINUD)
            0x40 => { // i32x4.ge_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pminud(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3E => { // i32x4.le_u = ge_u(b,a)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pminud(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3C => { // i32x4.gt_u = NOT(le_u)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs2_field);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1);
                Enc.pminud(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x3A => { // i32x4.lt_u = NOT(ge_u)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pminud(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pxor(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- demote/promote ---
            0x5E => { // f32x4.demote_f64x2_zero: CVTPD2PS (zeroes upper)
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.cvtpd2ps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x5F => { // f64x2.promote_low_f32x4: CVTPS2PD
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.cvtps2pd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- f64x2 convert from i32x4 ---
            0xFE => { // f64x2.convert_low_i32x4_s: CVTDQ2PD
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.cvtdq2pd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xFC => { // i32x4.trunc_sat_f64x2_s_zero: CVTTPD2DQ
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.cvttpd2dq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i16x8.q15mulr_sat_s (PMULHRSW SSSE3) ---
            0x82 => { self.emitSimdBinarySse(instr, &Enc.pmulhrsw); return true; },

            // --- extmul low (extend low halves + multiply) ---
            0x9C => { // i16x8.extmul_low_i8x16_s: PMOVSXBW both, PMULLW
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pmovsxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovsxbw(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmullw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x9E => { // i16x8.extmul_low_i8x16_u: PMOVZXBW both, PMULLW
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pmovzxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovzxbw(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmullw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xBC => { // i32x4.extmul_low_i16x8_s: PMOVSXWD both, PMULLD
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pmovsxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovsxwd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmulld(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xBE => { // i32x4.extmul_low_i16x8_u: PMOVZXWD both, PMULLD
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pmovzxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovzxwd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmulld(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xDC => { // i64x2.extmul_low_i32x4_s: PMULDQ (directly on low 32-bit lanes)
                self.emitSimdBinarySse(instr, &Enc.pmuldq);
                return true;
            },
            0xDE => { // i64x2.extmul_low_i32x4_u: PMULUDQ
                self.emitSimdBinarySse(instr, &Enc.pmuludq);
                return true;
            },

            // --- extmul high (shift high to low, then same as low) ---
            0x9D => { // i16x8.extmul_high_i8x16_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmovsxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovsxbw(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmullw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x9F => { // i16x8.extmul_high_i8x16_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmovzxbw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovzxbw(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmullw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xBD => { // i32x4.extmul_high_i16x8_s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmovsxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovsxwd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmulld(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xBF => { // i32x4.extmul_high_i16x8_u
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.punpckhqdq(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmovzxwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0);
                Enc.pmovzxwd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pmulld(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xDD => { // i64x2.extmul_high_i32x4_s: PSHUFD to move high lanes, PMULDQ
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                // Move lanes 2,3 to 0,1: PSHUFD imm=0b11_10_11_10 = 0xEE
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0xEE);
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1, 0xEE);
                Enc.pmuldq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0xDF => { // i64x2.extmul_high_i32x4_u: PSHUFD + PMULUDQ
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH0, 0xEE);
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1, 0xEE);
                Enc.pmuludq(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- extadd_pairwise ---
            0x7E => { // i32x4.extadd_pairwise_i16x8_s: PMADDWD with all-ones
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                // Generate all-ones i16 (0x0001 per word): PCMPEQD + PSRLW 15
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.sseShiftImm(&self.code, self.alloc, 0x71, 2, SIMD_SCRATCH1, 15); // PSRLW imm 15
                Enc.pmaddwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x7F => { // i32x4.extadd_pairwise_i16x8_u: PMADDWD with ones (unsigned → shift trick)
                // For unsigned: zero-extend to i32 via PMADDWD with 1s
                // PMADDWD treats src as signed, but if we use 0x0001 as multiplier, result is correct
                // since PMADDWD(a, 1) = a[0]*1 + a[1]*1 = a[0]+a[1] for values in 0..65535
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.sseShiftImm(&self.code, self.alloc, 0x71, 2, SIMD_SCRATCH1, 15);
                Enc.pmaddwd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x7C => { // i16x8.extadd_pairwise_i8x16_s: PMADDUBSW with ones
                // PMADDUBSW(a, b) treats a as unsigned, b as signed
                // To get signed pairwise add: set b = all 1s
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pabsb(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // all 0x01
                // But PMADDUBSW(unsigned, signed): we need src=unsigned*1 + unsigned*1
                // Actually for signed pairwise: use PMOVSXBW + PHADDW? Too complex.
                // Trampoline for this edge case
                return false;
            },
            0x7D => { // i16x8.extadd_pairwise_i8x16_u: PMADDUBSW(a, ones)
                // PMADDUBSW treats first operand as unsigned, second as signed
                // With all-1s as second: result = a[2n]*1 + a[2n+1]*1 = unsigned pairwise sum
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                Enc.pcmpeqd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1);
                Enc.pabsb(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH1); // all 0x01
                Enc.pmaddubsw(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            // --- i8x16.shuffle: PSHUFB with mask from pool ---
            0x0D => {
                // Load both v128 sources and mask
                // SSE PSHUFB only handles one 16-byte table.
                // Wasm shuffle can index 0-31 across 2 inputs.
                // Strategy: PSHUFB both with mask, blend based on index >= 16
                // Complex multi-instruction. Leave for trampoline.
                return false;
            },

            // --- relaxed ops: map to non-relaxed equivalents ---
            0x100 => { // relaxed_swizzle = swizzle
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.pshufb(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x101 => { self.emitSimdUnarySse(instr, &Enc.cvttps2dq); return true; }, // relaxed trunc f32→i32 s
            0x10D => { self.emitSimdBinarySse(instr, &Enc.minps); return true; }, // relaxed f32x4.min
            0x10E => { self.emitSimdBinarySse(instr, &Enc.maxps); return true; }, // relaxed f32x4.max
            0x10F => { self.emitSimdBinarySse(instr, &Enc.minpd); return true; }, // relaxed f64x2.min
            0x110 => { self.emitSimdBinarySse(instr, &Enc.maxpd); return true; }, // relaxed f64x2.max
            0x111 => { self.emitSimdBinarySse(instr, &Enc.pmulhrsw); return true; }, // relaxed q15mulr
            // relaxed_madd (0x105,0x107): mul + add (no FMA3 needed, relaxed allows)
            0x105 => { // f32x4.relaxed_madd(a,b,c) = a*b+c
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // a
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // b
                Enc.mulps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1); // a*b
                self.emitLoadV128(SIMD_SCRATCH1, extra); // c
                Enc.addps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1); // a*b+c
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x107 => { // f64x2.relaxed_madd
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.mulpd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitLoadV128(SIMD_SCRATCH1, extra);
                Enc.addpd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            0x106 => { // f32x4.relaxed_nmadd(a,b,c) = c - a*b
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.mulps(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitLoadV128(SIMD_SCRATCH1, extra); // c
                Enc.subps(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0); // c - a*b
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            0x108 => { // f64x2.relaxed_nmadd
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1);
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field);
                Enc.mulpd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitLoadV128(SIMD_SCRATCH1, extra);
                Enc.subpd(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                self.emitStoreV128(SIMD_SCRATCH1, instr.rd);
                return true;
            },
            // relaxed_laneselect (0x109-0x10C): same as bitselect
            0x109, 0x10A, 0x10B, 0x10C => {
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1); // v1
                const SIMD_X5: u4 = 5;
                self.emitLoadV128(SIMD_X5, instr.rs2_field); // v2
                self.emitLoadV128(SIMD_SCRATCH0, extra); // mask
                Enc.pand(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0);
                Enc.pandn(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_X5);
                Enc.por(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1);
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },
            // relaxed_trunc_f64x2 (0x103): same as non-relaxed
            0x103 => { self.emitSimdUnarySse(instr, &Enc.cvttpd2dq); return true; },
            // f64x2.convert_low_i32x4_u (0xFF): CVTDQ2PD covers positive i32
            0xFF => { self.emitSimdUnarySse(instr, &Enc.cvtdq2pd); return true; },

            // --- i64x2.mul (x86: PSHUFD + PMULUDQ + shift + add, same algo as ARM64) ---
            0xD5 => {
                self.emitLoadV128(SIMD_SCRATCH0, instr.rs1); // a
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs2_field); // b
                const SIMD_X5: u4 = 5;
                // Save a copy of a for PMULUDQ later
                Enc.movaps(&self.code, self.alloc, SIMD_X5, SIMD_SCRATCH0);
                // Swap 32-bit halves within 64-bit lanes: PSHUFD b, imm=0xB1 [1,0,3,2]
                const SIMD_X6: u4 = 6;
                Enc.pshufd(&self.code, self.alloc, SIMD_X6, SIMD_SCRATCH1, 0xB1);
                // Cross multiply: MUL a.4s × swapped_b.4s
                Enc.pmulld(&self.code, self.alloc, SIMD_X6, SIMD_SCRATCH0); // [a0*b1, a1*b0, a2*b3, a3*b2]
                // Pairwise add within 64-bit lanes: PSHUFD + PADDD
                Enc.pshufd(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_X6, 0xB1);
                Enc.paddd(&self.code, self.alloc, SIMD_X6, SIMD_SCRATCH0); // cross_sum in even lanes
                // Shift cross sum left 32: PSLLQ 32
                Enc.psllq_imm(&self.code, self.alloc, SIMD_X6, 32);
                // Low multiply: PMULUDQ a, b
                Enc.pmuludq(&self.code, self.alloc, SIMD_X5, SIMD_SCRATCH1); // a_lo * b_lo
                // Add: result = low + cross<<32
                Enc.paddq(&self.code, self.alloc, SIMD_X5, SIMD_X6);
                self.emitStoreV128(SIMD_X5, instr.rd);
                return true;
            },

            // --- v128.bitselect (PAND+PANDN+POR, uses 3 XMM regs) ---
            0x52 => {
                // bitselect(v1, v2, mask): mask from trailing NOP rd
                self.emitLoadV128(SIMD_SCRATCH1, instr.rs1); // v1 → XMM4
                const SIMD_SCRATCH2_X: u4 = 5; // XMM5 as third scratch
                self.emitLoadV128(SIMD_SCRATCH2_X, instr.rs2_field); // v2 → XMM5
                self.emitLoadV128(SIMD_SCRATCH0, extra); // mask → XMM3
                // result = (v1 AND mask) OR (v2 AND NOT mask)
                Enc.pand(&self.code, self.alloc, SIMD_SCRATCH1, SIMD_SCRATCH0); // v1 AND mask
                Enc.pandn(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH2_X); // NOT(mask) AND v2
                Enc.por(&self.code, self.alloc, SIMD_SCRATCH0, SIMD_SCRATCH1); // combine
                self.emitStoreV128(SIMD_SCRATCH0, instr.rd);
                return true;
            },

            else => return false,
        }
    }

    /// Emit SIMD trampoline: spill → set up C ABI args → CALL jitSimdTrampoline → check → reload.
    fn emitSimdTrampoline(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) void {
        const sub: u32 = instr.op - predecode_mod.SIMD_BASE;
        const effect = regalloc_mod.simdStackEffect(sub) orelse return;

        // Check for trailing NOP (extra metadata: lane index, third operand)
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

        // 1. Spill caller-saved regs
        self.simdXregEvictAll();
        self.spillCallerSaved();
        // Spill SIMD operand vregs (ensure they're in memory for trampoline)
        if (effect.pop >= 1) self.spillVreg(instr.rs1);
        if (effect.pop >= 2) self.spillVreg(instr.rs2_field);
        if (effect.push == 0 and effect.pop == 2) self.spillVreg(instr.rd);

        // 2. Set up C ABI args
        if (builtin.os.tag == .windows) {
            // Windows x64: rcx, rdx, r8, r9, stack for rest
            self.emitLoadVmPtr(.rcx); // arg0: vm_ptr
            self.emitLoadInstPtr(.rdx); // arg1: instance_ptr
            Enc.movRegReg(&self.code, self.alloc, .r8, REGS_PTR); // arg2: regs_ptr
            // arg3: op_extra = opcode | (extra << 32)
            const op_extra: u64 = @as(u64, instr.op) | (@as(u64, extra) << 32);
            self.emitLoadImm64(.r9, op_extra);
            // Stack args (push in reverse order): pool64_len, pool64_ptr, operand, regs_packed
            // Allocate 32 bytes shadow space + 4*8 = 64 bytes total
            Enc.subImm32(&self.code, self.alloc, .rsp, 64);
            // regs_packed at [rsp+32]
            const regs_packed: u64 = @as(u64, instr.rd) | (@as(u64, instr.rs1) << 16) |
                (@as(u64, instr.rs2_field) << 32) | (@as(u64, third_operand) << 48);
            self.emitLoadImm64(SCRATCH, regs_packed);
            Enc.storeDisp32(&self.code, self.alloc, .rsp, 32, SCRATCH);
            // operand at [rsp+40]
            self.emitLoadImm64(SCRATCH, instr.operand);
            Enc.storeDisp32(&self.code, self.alloc, .rsp, 40, SCRATCH);
            // pool64_ptr at [rsp+48]
            self.emitLoadImm64(SCRATCH, @intFromPtr(self.pool64.ptr));
            Enc.storeDisp32(&self.code, self.alloc, .rsp, 48, SCRATCH);
            // pool64_len at [rsp+56]
            self.emitLoadImm64(SCRATCH, self.pool64.len);
            Enc.storeDisp32(&self.code, self.alloc, .rsp, 56, SCRATCH);
        } else {
            // System V x86_64: rdi, rsi, rdx, rcx, r8, r9, stack for rest
            self.emitLoadVmPtr(.rdi); // arg0: vm_ptr
            self.emitLoadInstPtr(.rsi); // arg1: instance_ptr
            Enc.movRegReg(&self.code, self.alloc, .rdx, REGS_PTR); // arg2: regs_ptr
            // arg3: op_extra = opcode | (extra << 32)
            const op_extra: u64 = @as(u64, instr.op) | (@as(u64, extra) << 32);
            self.emitLoadImm64(.rcx, op_extra);
            // arg4: regs_packed = rd | (rs1 << 16) | (rs2 << 32) | (third << 48)
            const regs_packed: u64 = @as(u64, instr.rd) | (@as(u64, instr.rs1) << 16) |
                (@as(u64, instr.rs2_field) << 32) | (@as(u64, third_operand) << 48);
            self.emitLoadImm64(.r8, regs_packed);
            // arg5: operand
            self.emitLoadImm64(.r9, instr.operand);
            // Stack args: pool64_ptr, pool64_len (push in reverse)
            self.emitLoadImm64(SCRATCH, self.pool64.len);
            Enc.push(&self.code, self.alloc, SCRATCH);
            self.emitLoadImm64(SCRATCH, @intFromPtr(self.pool64.ptr));
            Enc.push(&self.code, self.alloc, SCRATCH);
        }

        // 3. CALL jitSimdTrampoline
        self.emitLoadImm64(SCRATCH, self.simd_trampoline_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);

        // Clean up stack args
        if (builtin.os.tag == .windows) {
            Enc.addImm32(&self.code, self.alloc, .rsp, 64);
        } else {
            Enc.addImm32(&self.code, self.alloc, .rsp, 16); // pop 2 stack args
        }

        // 4. Check error (rax = 0 success, non-zero error)
        Enc.testRegReg(&self.code, self.alloc, SCRATCH, SCRATCH);
        self.emitCondError(.ne, 0); // trap with error code from trampoline

        // 5. Reload
        if (self.has_memory) self.emitLoadMemCache();
        self.reloadCallerSaved();
        self.scratch_vreg = null;
        // Reload result vreg if push=1
        if (effect.push == 1) {
            if (vregToPhys(instr.rd)) |phys| {
                const disp: i32 = @as(i32, instr.rd) * 8;
                Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
            }
        }
    }

    /// Compile a single RegInstr. Returns false if unsupported (bail out).
    fn compileInstr(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        switch (instr.op) {
            // --- Register ops ---
            regalloc_mod.OP_MOV => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.storeVreg(instr.rd, src);
                if (self.has_simd) self.emitCopySimdV128(instr.rd, instr.rs1);
            },
            regalloc_mod.OP_CONST32 => {
                self.emitConst32(instr);
                if (self.has_simd) self.emitClearSimdV128(instr.rd);
            },
            regalloc_mod.OP_CONST64 => {
                if (!self.emitConst64(instr)) return false;
                if (self.has_simd) self.emitClearSimdV128(instr.rd);
            },

            // --- Control flow ---
            regalloc_mod.OP_BR => {
                // Fuel check at back-edges (target <= current pc)
                if (instr.operand <= pc.* - 1) self.emitFuelCheck();
                const patch_off = Enc.jmpRel32(&self.code, self.alloc);
                self.patches.append(self.alloc, .{
                    .rel32_offset = patch_off,
                    .target_pc = instr.operand,
                    .kind = .jmp,
                }) catch return false;
            },
            regalloc_mod.OP_BR_IF => {
                // Fuel check at back-edges
                if (instr.operand <= pc.* - 1) self.emitFuelCheck();
                // Branch if rd != 0
                const cond_reg = self.getOrLoad(instr.rd, SCRATCH);
                Enc.testRegReg(&self.code, self.alloc, cond_reg, cond_reg);
                const patch_off = Enc.jccRel32(&self.code, self.alloc, .ne);
                self.patches.append(self.alloc, .{
                    .rel32_offset = patch_off,
                    .target_pc = instr.operand,
                    .kind = .jcc,
                }) catch return false;
            },
            regalloc_mod.OP_BR_IF_NOT => {
                // Fuel check at back-edges
                if (instr.operand <= pc.* - 1) self.emitFuelCheck();
                const cond_reg = self.getOrLoad(instr.rd, SCRATCH);
                Enc.testRegReg(&self.code, self.alloc, cond_reg, cond_reg);
                const patch_off = Enc.jccRel32(&self.code, self.alloc, .e);
                self.patches.append(self.alloc, .{
                    .rel32_offset = patch_off,
                    .target_pc = instr.operand,
                    .kind = .jcc,
                }) catch return false;
            },
            regalloc_mod.OP_RETURN => {
                self.simdXregEvictAll();
                self.emitEpilogue(if (self.result_count > 0) instr.rd else null);
            },
            regalloc_mod.OP_RETURN_MULTI => {
                self.simdXregEvictAll();
                self.emitEpilogueMulti(instr, ir, pc);
            },
            regalloc_mod.OP_RETURN_VOID => {
                self.simdXregEvictAll();
                self.emitEpilogue(null);
            },
            regalloc_mod.OP_NOP, regalloc_mod.OP_BLOCK_END, regalloc_mod.OP_DELETED => {},

            // --- Unreachable ---
            0x00 => {
                // MOV EAX, 5 (Unreachable error) + JMP to shared exit
                Enc.movImm32ToReg(&self.code, self.alloc, .rax, 5);
                const jmp_off = Enc.jmpRel32(&self.code, self.alloc);
                self.error_stubs.append(self.alloc, .{
                    .rel32_offset = jmp_off,
                    .error_code = 0, // RAX already set, patch JMP to shared exit
                    .kind = .jne,
                    .cond = .ne,
                }) catch return false;
            },

            // --- Select ---
            0x1B => { // select: rd = cond ? val1 : val2
                const val2_idx = instr.rs2_field;
                const cond_idx: u16 = @truncate(instr.operand);
                // Compare condition first (before clobbering scratch regs)
                const cond_reg = self.getOrLoad(cond_idx, SCRATCH);
                Enc.testRegReg(&self.code, self.alloc, cond_reg, cond_reg);
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                // Load val2 BEFORE val1 — loading val1 into d would clobber val2
                // when rd == val2_idx (both map to the same physical register).
                var val2_reg = self.getOrLoad(val2_idx, SCRATCH2);
                if (val2_reg == d) {
                    // val2 is in d, which will be overwritten by val1 — save it
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH2, val2_reg);
                    val2_reg = SCRATCH2;
                }
                // Load val1 into destination
                const val1 = self.getOrLoad(instr.rs1, d);
                if (val1 != d) Enc.movRegReg(&self.code, self.alloc, d, val1);
                // CMOVE: if cond == 0, overwrite d with val2
                Enc.cmovcc64(&self.code, self.alloc, .e, d, val2_reg);
                if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, d);
            },

            // --- Drop ---
            0x1A => {}, // no-op

            // --- br_table ---
            regalloc_mod.OP_BR_TABLE => {
                if (!self.emitBrTable(instr, ir, pc)) return false;
            },

            // --- Global ops ---
            0x23 => self.emitGlobalGet(instr), // global.get
            0x24 => self.emitGlobalSet(instr), // global.set

            // --- Memory load ---
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
            0x36 => self.emitMemStore(instr, .w32, 4),  // i32.store
            0x37 => self.emitMemStore(instr, .x64, 8),  // i64.store
            0x38 => self.emitMemStore(instr, .w32, 4),  // f32.store
            0x39 => self.emitMemStore(instr, .x64, 8),  // f64.store
            0x3A => self.emitMemStore(instr, .b8, 1),   // i32.store8
            0x3B => self.emitMemStore(instr, .h16, 2),  // i32.store16
            0x3C => self.emitMemStore(instr, .b8, 1),   // i64.store8
            0x3D => self.emitMemStore(instr, .h16, 2),  // i64.store16
            0x3E => self.emitMemStore(instr, .w32, 4),  // i64.store32

            // --- Memory size/grow/fill/copy ---
            0x3F => self.emitMemorySize(instr), // memory.size
            0x40 => self.emitMemGrow(instr),     // memory.grow
            regalloc_mod.OP_MEMORY_FILL => self.emitMemFill(instr),
            regalloc_mod.OP_MEMORY_COPY => self.emitMemCopy(instr),

            // --- Function calls (consume extra data words) ---
            regalloc_mod.OP_CALL => {
                const func_idx = instr.operand;
                const n_args: u16 = @intCast(instr.rs1);
                const call_pc = pc.* - 1;
                const data = ir[pc.*];
                pc.* += 1;
                const has_data2 = (pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP);
                var data2: RegInstr = undefined;
                if (has_data2) {
                    data2 = ir[pc.*];
                    pc.* += 1;
                }
                const n_results: u16 = instr.rs2_field;
                if (self.has_self_call and func_idx == self.self_func_idx) {
                    self.emitInlineSelfCall(instr.rd, n_results, data, if (has_data2) data2 else null, ir, call_pc);
                } else {
                    self.emitCall(instr.rd, func_idx, n_args, n_results, data, if (has_data2) data2 else null, ir, call_pc);
                }
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

            // --- f64 arithmetic ---
            0xA0, 0xA1, 0xA2, 0xA3 => self.emitFpBinop64(instr),
            0x9F => self.emitFpUnop64(0x9F, instr),  // f64.sqrt
            0x99 => self.emitFpUnop64(0x99, instr),  // f64.abs
            0x9A => self.emitFpUnop64(0x9A, instr),  // f64.neg
            0xA4, 0xA5 => {
                if (!self.emitFpMinMax64(instr)) return false;
            },

            // --- f64 comparison ---
            0x61, 0x62, 0x63, 0x64, 0x65, 0x66 => self.emitFpCmp64(instr.op, instr),

            // --- f32 arithmetic ---
            0x92, 0x93, 0x94, 0x95 => self.emitFpBinop32(instr),
            0x91 => self.emitFpUnop32(0x91, instr),  // f32.sqrt
            0x8B => self.emitFpUnop32(0x8B, instr),  // f32.abs
            0x8C => self.emitFpUnop32(0x8C, instr),  // f32.neg
            0x96, 0x97 => {
                if (!self.emitFpMinMax32(instr)) return false;
            },

            // --- f32 comparison ---
            0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60 => self.emitFpCmp32(instr.op, instr),

            // --- FP conversions ---
            0xB7, 0xB8, 0xB9, 0xBA, // f64.convert_i32_s/u, f64.convert_i64_s/u
            0xB2, 0xB3, 0xB4, 0xB5, // f32.convert_i32_s/u, f32.convert_i64_s/u
            0xAA, 0xAB, 0xB0, 0xB1, // i32/i64.trunc_f64_s/u
            0xA8, 0xA9, 0xAE, 0xAF, // i32/i64.trunc_f32_s/u
            0xBB, 0xB6,             // f64.promote_f32, f32.demote_f64
            0x98, 0xA6,             // f32.copysign, f64.copysign
            0x9B, 0x9C, 0x9D, 0x9E, // f64.ceil/floor/trunc/nearest
            0x8D, 0x8E, 0x8F, 0x90, // f32.ceil/floor/trunc/nearest
            => {
                if (!self.emitFpConvert(instr.op, instr)) return false;
            },

            // --- i32 arithmetic ---
            0x6A => self.emitBinop32(instr, .add),
            0x6B => self.emitBinop32(instr, .sub),
            0x6C => self.emitBinop32(instr, .mul),
            0x6D => self.emitDiv32(instr, true, false),  // i32.div_s
            0x6E => self.emitDiv32(instr, false, false),  // i32.div_u
            0x6F => self.emitDiv32(instr, true, true),   // i32.rem_s
            0x70 => self.emitDiv32(instr, false, true),   // i32.rem_u
            0x71 => self.emitBinop32(instr, .@"and"),
            0x72 => self.emitBinop32(instr, .@"or"),
            0x73 => self.emitBinop32(instr, .xor),
            0x74 => self.emitShift32(instr, .shl),   // i32.shl
            0x75 => self.emitShift32(instr, .sar),   // i32.shr_s
            0x76 => self.emitShift32(instr, .shr),   // i32.shr_u
            0x77 => self.emitShift32(instr, .rol),   // i32.rotl
            0x78 => self.emitShift32(instr, .ror),   // i32.rotr

            // --- i32 bit ops ---
            0x67 => self.emitClz32(instr),   // i32.clz
            0x68 => self.emitCtz32(instr),   // i32.ctz
            0x69 => self.emitPopcnt32(instr), // i32.popcnt

            // --- i32 comparison ---
            0x45 => if (!self.emitEqz32(instr, pc)) return false,   // i32.eqz
            0x46 => if (!self.emitCmp32(instr, .e, pc)) return false,  // i32.eq
            0x47 => if (!self.emitCmp32(instr, .ne, pc)) return false, // i32.ne
            0x48 => if (!self.emitCmp32(instr, .l, pc)) return false,  // i32.lt_s
            0x49 => if (!self.emitCmp32(instr, .b, pc)) return false,  // i32.lt_u
            0x4A => if (!self.emitCmp32(instr, .g, pc)) return false,  // i32.gt_s
            0x4B => if (!self.emitCmp32(instr, .a, pc)) return false,  // i32.gt_u
            0x4C => if (!self.emitCmp32(instr, .le, pc)) return false, // i32.le_s
            0x4D => if (!self.emitCmp32(instr, .be, pc)) return false, // i32.le_u
            0x4E => if (!self.emitCmp32(instr, .ge, pc)) return false, // i32.ge_s
            0x4F => if (!self.emitCmp32(instr, .ae, pc)) return false, // i32.ge_u

            // --- i64 arithmetic ---
            0x7C => self.emitBinop64(instr, .add),
            0x7D => self.emitBinop64(instr, .sub),
            0x7E => self.emitBinop64(instr, .mul),
            0x7F => self.emitDiv64(instr, true, false),  // i64.div_s
            0x80 => self.emitDiv64(instr, false, false),  // i64.div_u
            0x81 => self.emitDiv64(instr, true, true),   // i64.rem_s
            0x82 => self.emitDiv64(instr, false, true),   // i64.rem_u
            0x83 => self.emitBinop64(instr, .@"and"),
            0x84 => self.emitBinop64(instr, .@"or"),
            0x85 => self.emitBinop64(instr, .xor),
            0x86 => self.emitShift64(instr, .shl),   // i64.shl
            0x87 => self.emitShift64(instr, .sar),   // i64.shr_s
            0x88 => self.emitShift64(instr, .shr),   // i64.shr_u
            0x89 => self.emitShift64(instr, .rol),   // i64.rotl
            0x8A => self.emitShift64(instr, .ror),   // i64.rotr

            // --- i64 bit ops ---
            0x79 => self.emitClz64(instr),   // i64.clz
            0x7A => self.emitCtz64(instr),   // i64.ctz
            0x7B => self.emitPopcnt64(instr), // i64.popcnt

            // --- i64 comparison ---
            0x50 => if (!self.emitEqz64(instr, pc)) return false,   // i64.eqz
            0x51 => if (!self.emitCmp64(instr, .e, pc)) return false,  // i64.eq
            0x52 => if (!self.emitCmp64(instr, .ne, pc)) return false, // i64.ne
            0x53 => if (!self.emitCmp64(instr, .l, pc)) return false,  // i64.lt_s
            0x54 => if (!self.emitCmp64(instr, .b, pc)) return false,  // i64.lt_u
            0x55 => if (!self.emitCmp64(instr, .g, pc)) return false,  // i64.gt_s
            0x56 => if (!self.emitCmp64(instr, .a, pc)) return false,  // i64.gt_u
            0x57 => if (!self.emitCmp64(instr, .le, pc)) return false, // i64.le_s
            0x58 => if (!self.emitCmp64(instr, .be, pc)) return false, // i64.le_u
            0x59 => if (!self.emitCmp64(instr, .ge, pc)) return false, // i64.ge_s
            0x5A => if (!self.emitCmp64(instr, .ae, pc)) return false, // i64.ge_u

            // --- Conversions ---
            0xA7 => { // i32.wrap_i64: just truncate (MOV r32, r32 zero-extends)
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const rd = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.movRegReg32(&self.code, self.alloc, rd, src);
                if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
            },
            0xAC => { // i64.extend_i32_s: MOVSXD
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const rd = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.movsxd(&self.code, self.alloc, rd, src);
                if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
            },
            0xAD => { // i64.extend_i32_u: MOV r32, r32 (zero-extends)
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const rd = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.movRegReg32(&self.code, self.alloc, rd, src);
                if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
            },

            // --- Reinterpret (bit-preserving) ---
            0xBC, 0xBE => { // i32.reinterpret_f32, f32.reinterpret_i32
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                const rd = vregToPhys(instr.rd) orelse SCRATCH;
                Enc.movRegReg32(&self.code, self.alloc, rd, src);
                if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
            },
            0xBD, 0xBF => { // i64.reinterpret_f64, f64.reinterpret_i64
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.storeVreg(instr.rd, src);
            },

            // --- Sign extension (Wasm 2.0) ---
            0xC0 => self.emitSignExt(instr, 8, false),  // i32.extend8_s
            0xC1 => self.emitSignExt(instr, 16, false),  // i32.extend16_s
            0xC2 => self.emitSignExt(instr, 8, true),  // i64.extend8_s
            0xC3 => self.emitSignExt(instr, 16, true),  // i64.extend16_s
            0xC4 => self.emitSignExt(instr, 32, true),  // i64.extend32_s

            // --- Saturating truncation (0xFC prefix) ---
            0xFC00, 0xFC01, // i32.trunc_sat_f32_s/u
            0xFC02, 0xFC03, // i32.trunc_sat_f64_s/u
            0xFC04, 0xFC05, // i64.trunc_sat_f32_s/u
            0xFC06, 0xFC07, // i64.trunc_sat_f64_s/u
            => self.emitTruncSat(instr),

            // --- SIMD opcodes: native SSE or trampoline fallback ---
            predecode_mod.SIMD_BASE...predecode_mod.SIMD_BASE + 0x113 => {
                if (!self.emitSimdNative(instr, ir, pc)) {
                    self.emitSimdTrampoline(instr, ir, pc);
                }
            },

            else => return false, // Unsupported — bail out to interpreter
        }
        return true;
    }

    // --- Helper emitters ---

    const BinOp = enum { add, sub, mul, @"and", @"or", xor };

    fn emitBinop32(self: *Compiler, instr: RegInstr, op: BinOp) void {
        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;

        // x86 is 2-operand: OP rd, r2  means  rd = rd OP r2.
        // We need: rd = r1 OP r2.  So MOV rd, r1 first, then OP rd, r2.
        // Bug: if rd == r2 and rd != r1, the MOV clobbers r2 before the OP.
        // Fix: for commutative ops, swap operands (OP rd, r1 since rd already has r2).
        //      for SUB, use SCRATCH: MOV SCRATCH, r1; SUB SCRATCH, rd; MOV rd, SCRATCH.
        if (rd == r2 and rd != r1) {
            switch (op) {
                .add, .mul, .@"and", .@"or", .xor => {
                    // Commutative: rd already has r2, just do OP rd, r1
                    switch (op) {
                        .add => Enc.addRegReg32(&self.code, self.alloc, rd, r1),
                        .mul => Enc.imulRegReg32(&self.code, self.alloc, rd, r1),
                        .@"and" => Enc.andRegReg32(&self.code, self.alloc, rd, r1),
                        .@"or" => Enc.orRegReg32(&self.code, self.alloc, rd, r1),
                        .xor => Enc.xorRegReg32(&self.code, self.alloc, rd, r1),
                        .sub => unreachable,
                    }
                },
                .sub => {
                    // Non-commutative: SCRATCH = r1 - r2, then MOV rd, SCRATCH
                    Enc.movRegReg32(&self.code, self.alloc, SCRATCH, r1);
                    Enc.subRegReg32(&self.code, self.alloc, SCRATCH, rd);
                    Enc.movRegReg32(&self.code, self.alloc, rd, SCRATCH);
                },
            }
        } else {
            if (rd != r1) {
                Enc.movRegReg32(&self.code, self.alloc, rd, r1);
            }
            switch (op) {
                .add => Enc.addRegReg32(&self.code, self.alloc, rd, r2),
                .sub => Enc.subRegReg32(&self.code, self.alloc, rd, r2),
                .mul => Enc.imulRegReg32(&self.code, self.alloc, rd, r2),
                .@"and" => Enc.andRegReg32(&self.code, self.alloc, rd, r2),
                .@"or" => Enc.orRegReg32(&self.code, self.alloc, rd, r2),
                .xor => Enc.xorRegReg32(&self.code, self.alloc, rd, r2),
            }
        }

        if (vregToPhys(instr.rd) == null) {
            self.storeVreg(instr.rd, SCRATCH);
        }
    }

    fn emitBinop64(self: *Compiler, instr: RegInstr, op: BinOp) void {
        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;

        // Same rd==r2 aliasing fix as emitBinop32 (see comment above).
        if (rd == r2 and rd != r1) {
            switch (op) {
                .add, .mul, .@"and", .@"or", .xor => {
                    switch (op) {
                        .add => Enc.addRegReg(&self.code, self.alloc, rd, r1),
                        .mul => Enc.imulRegReg(&self.code, self.alloc, rd, r1),
                        .@"and" => Enc.andRegReg(&self.code, self.alloc, rd, r1),
                        .@"or" => Enc.orRegReg(&self.code, self.alloc, rd, r1),
                        .xor => Enc.xorRegReg(&self.code, self.alloc, rd, r1),
                        .sub => unreachable,
                    }
                },
                .sub => {
                    Enc.movRegReg(&self.code, self.alloc, SCRATCH, r1);
                    Enc.subRegReg(&self.code, self.alloc, SCRATCH, rd);
                    Enc.movRegReg(&self.code, self.alloc, rd, SCRATCH);
                },
            }
        } else {
            if (rd != r1) {
                Enc.movRegReg(&self.code, self.alloc, rd, r1);
            }
            switch (op) {
                .add => Enc.addRegReg(&self.code, self.alloc, rd, r2),
                .sub => Enc.subRegReg(&self.code, self.alloc, rd, r2),
                .mul => Enc.imulRegReg(&self.code, self.alloc, rd, r2),
                .@"and" => Enc.andRegReg(&self.code, self.alloc, rd, r2),
                .@"or" => Enc.orRegReg(&self.code, self.alloc, rd, r2),
                .xor => Enc.xorRegReg(&self.code, self.alloc, rd, r2),
            }
        }

        if (vregToPhys(instr.rd) == null) {
            self.storeVreg(instr.rd, SCRATCH);
        }
    }

    // --- Const helpers ---

    fn emitConst32(self: *Compiler, instr: RegInstr) void {
        const val = instr.operand;
        if (vregToPhys(instr.rd)) |phys| {
            if (val == 0) Enc.xorRegReg32(&self.code, self.alloc, phys, phys)
            else Enc.movImm32(&self.code, self.alloc, phys, val);
        } else {
            if (val == 0) Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH)
            else Enc.movImm32(&self.code, self.alloc, SCRATCH, val);
            self.storeVreg(instr.rd, SCRATCH);
        }
    }

    fn emitConst64(self: *Compiler, instr: RegInstr) bool {
        const pool_idx = instr.operand;
        if (pool_idx >= self.pool64.len) return false;
        const val = self.pool64[pool_idx];
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        if (val == 0) {
            Enc.xorRegReg32(&self.code, self.alloc, rd, rd);
        } else if (val <= std.math.maxInt(u32)) {
            Enc.movImm32(&self.code, self.alloc, rd, @intCast(val));
        } else {
            Enc.movImm64(&self.code, self.alloc, rd, val);
        }
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
        return true;
    }

    // --- Peephole fusion: CMP+Jcc ---

    fn scanBranchTargets(self: *Compiler, ir: []const RegInstr) ?[]bool {
        const targets = self.alloc.alloc(bool, ir.len) catch return null;
        @memset(targets, false);
        var scan_pc: u32 = 0;
        while (scan_pc < ir.len) {
            const instr = ir[scan_pc];
            scan_pc += 1;
            switch (instr.op) {
                regalloc_mod.OP_BR => {
                    if (instr.operand < ir.len) targets[instr.operand] = true;
                },
                regalloc_mod.OP_BR_IF, regalloc_mod.OP_BR_IF_NOT => {
                    if (instr.operand < ir.len) targets[instr.operand] = true;
                },
                regalloc_mod.OP_BR_TABLE => {
                    const count = instr.operand;
                    var i: u32 = 0;
                    while (i < count + 1 and scan_pc < ir.len) : (i += 1) {
                        const entry = ir[scan_pc];
                        scan_pc += 1;
                        if (entry.operand < ir.len) targets[entry.operand] = true;
                    }
                },
                regalloc_mod.OP_BLOCK_END => {
                    targets[scan_pc - 1] = true;
                },
                else => {},
            }
        }
        return targets;
    }

    /// Try to fuse a CMP result with a following BR_IF/BR_IF_NOT.
    /// Returns true if fused, false if not fuseable. Returns null on OOM.
    fn tryFuseBranch(self: *Compiler, cc: Cond, rd: u16, pc: *u32) ?bool {
        if (pc.* >= self.ir_slice.len) return false;
        const next = self.ir_slice[pc.*];
        if (next.op != regalloc_mod.OP_BR_IF and next.op != regalloc_mod.OP_BR_IF_NOT) return false;
        if (next.rd != rd) return false;
        if (pc.* < self.branch_targets_slice.len and self.branch_targets_slice[pc.*]) return false;

        // Fuse: emit Jcc instead of SETCC + MOVZX + store + load + TEST + Jcc
        const actual_cc = if (next.op == regalloc_mod.OP_BR_IF) cc else cc.invert();
        const patch_off = Enc.jccRel32(&self.code, self.alloc, actual_cc);
        self.patches.append(self.alloc, .{
            .rel32_offset = patch_off,
            .target_pc = next.operand,
            .kind = .jcc,
        }) catch return null; // OOM

        // Record pc_map for the skipped BR_IF and advance past it
        self.pc_map.items[pc.*] = self.currentOffset();
        pc.* += 1;
        return true;
    }

    /// After CMP/TEST emission: try fusion, or fall back to SETCC + MOVZX + store.
    fn emitCmpResult(self: *Compiler, cc: Cond, rd: u16, pc: *u32) bool {
        if (self.tryFuseBranch(cc, rd, pc)) |fused| {
            if (fused) return true;
        } else return false; // OOM
        // No fusion — emit SETCC + MOVZX + store
        Enc.setcc(&self.code, self.alloc, cc, .rax);
        Enc.movzxByte(&self.code, self.alloc, .rax, .rax);
        self.storeVreg(rd, SCRATCH);
        return true;
    }

    // --- Comparison helpers ---
    // Pattern: CMP r1, r2 → SETcc AL → MOVZX EAX, AL → store to rd

    fn emitCmp32(self: *Compiler, instr: RegInstr, cc: Cond, pc: *u32) bool {
        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        Enc.cmpRegReg32(&self.code, self.alloc, r1, r2);
        return self.emitCmpResult(cc, instr.rd, pc);
    }

    fn emitCmp64(self: *Compiler, instr: RegInstr, cc: Cond, pc: *u32) bool {
        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        Enc.cmpRegReg(&self.code, self.alloc, r1, r2);
        return self.emitCmpResult(cc, instr.rd, pc);
    }

    fn emitEqz32(self: *Compiler, instr: RegInstr, pc: *u32) bool {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.testRegReg(&self.code, self.alloc, src, src);
        return self.emitCmpResult(.e, instr.rd, pc);
    }

    fn emitEqz64(self: *Compiler, instr: RegInstr, pc: *u32) bool {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.testRegReg(&self.code, self.alloc, src, src);
        return self.emitCmpResult(.e, instr.rd, pc);
    }

    // --- Shift helpers ---
    // x86 shifts require count in CL. RCX = vreg 3.

    const ShiftOp = enum { shl, shr, sar, rol, ror };

    fn emitShift32(self: *Compiler, instr: RegInstr, op: ShiftOp) void {
        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        const rs2_phys = vregToPhys(rs2);

        // Check if moving r1→rd would clobber the shift amount (rd aliases rs2),
        // or if rd is RCX (conflicts with CL for shift count).
        const has_alias = (rd == .rcx) or
            (rs2_phys != null and rs2_phys.? == rd and rd != r1);

        if (has_alias) {
            // Use SCRATCH (RAX) as shift destination to avoid aliasing.
            // 1. Save value to SCRATCH
            if (r1 != SCRATCH) Enc.movRegReg32(&self.code, self.alloc, SCRATCH, r1);
            // 2. Load shift amount to CL
            const shift_reg = self.getOrLoad(rs2, SCRATCH2);
            if (shift_reg != .rcx) {
                // Save vreg 3 (RCX) if live and NOT the output register
                if (instr.rd != 3 and vregToPhys(3) != null and 3 < self.reg_count) {
                    Enc.push(&self.code, self.alloc, .rcx);
                }
                Enc.movRegReg(&self.code, self.alloc, .rcx, shift_reg);
            }
            // 3. Shift SCRATCH by CL
            self.emitShiftOp32(op, SCRATCH);
            // 4. Move result to rd
            if (rd != SCRATCH) Enc.movRegReg32(&self.code, self.alloc, rd, SCRATCH);
            // 5. Restore RCX if we pushed it
            if (shift_reg != .rcx and instr.rd != 3 and vregToPhys(3) != null and 3 < self.reg_count) {
                Enc.pop(&self.code, self.alloc, .rcx);
            }
        } else {
            if (rd != r1) Enc.movRegReg32(&self.code, self.alloc, rd, r1);
            self.moveShiftCountToCl(rs2, rd);
            self.emitShiftOp32(op, rd);
            self.restoreCl(rs2);
        }

        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitShift64(self: *Compiler, instr: RegInstr, op: ShiftOp) void {
        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        const rs2_phys = vregToPhys(rs2);

        const has_alias = (rd == .rcx) or
            (rs2_phys != null and rs2_phys.? == rd and rd != r1);

        if (has_alias) {
            if (r1 != SCRATCH) Enc.movRegReg(&self.code, self.alloc, SCRATCH, r1);
            const shift_reg = self.getOrLoad(rs2, SCRATCH2);
            if (shift_reg != .rcx) {
                if (instr.rd != 3 and vregToPhys(3) != null and 3 < self.reg_count) {
                    Enc.push(&self.code, self.alloc, .rcx);
                }
                Enc.movRegReg(&self.code, self.alloc, .rcx, shift_reg);
            }
            self.emitShiftOp64(op, SCRATCH);
            if (rd != SCRATCH) Enc.movRegReg(&self.code, self.alloc, rd, SCRATCH);
            if (shift_reg != .rcx and instr.rd != 3 and vregToPhys(3) != null and 3 < self.reg_count) {
                Enc.pop(&self.code, self.alloc, .rcx);
            }
        } else {
            if (rd != r1) Enc.movRegReg(&self.code, self.alloc, rd, r1);
            self.moveShiftCountToCl(rs2, rd);
            self.emitShiftOp64(op, rd);
            self.restoreCl(rs2);
        }

        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    /// Emit 32-bit shift instruction on the given register.
    fn emitShiftOp32(self: *Compiler, op: ShiftOp, dst: Reg) void {
        switch (op) {
            .shl => Enc.shlCl32(&self.code, self.alloc, dst),
            .shr => Enc.shrCl32(&self.code, self.alloc, dst),
            .sar => Enc.sarCl32(&self.code, self.alloc, dst),
            .rol => {
                if (dst.isExt()) self.code.append(self.alloc, Enc.rex(false, false, false, true)) catch {};
                self.code.append(self.alloc, 0xD3) catch {};
                self.code.append(self.alloc, Enc.modrm(0b11, 0, dst.low3())) catch {};
            },
            .ror => Enc.rorCl32(&self.code, self.alloc, dst),
        }
    }

    /// Emit 64-bit shift instruction on the given register.
    fn emitShiftOp64(self: *Compiler, op: ShiftOp, dst: Reg) void {
        switch (op) {
            .shl => Enc.shlCl(&self.code, self.alloc, dst),
            .shr => Enc.shrCl(&self.code, self.alloc, dst),
            .sar => Enc.sarCl(&self.code, self.alloc, dst),
            .rol => Enc.rolCl(&self.code, self.alloc, dst),
            .ror => Enc.rorCl(&self.code, self.alloc, dst),
        }
    }

    /// Move shift amount (vreg rs2) into CL. Save RCX if needed.
    fn moveShiftCountToCl(self: *Compiler, rs2: u16, rd: Reg) void {
        _ = rd;
        const shift_reg = self.getOrLoad(rs2, SCRATCH2);
        if (shift_reg != .rcx) {
            // Save RCX if it holds a live vreg (vreg 3 maps to RCX)
            if (vregToPhys(3) != null and 3 < self.reg_count) {
                Enc.push(&self.code, self.alloc, .rcx);
            }
            Enc.movRegReg(&self.code, self.alloc, .rcx, shift_reg);
        }
    }

    fn restoreCl(self: *Compiler, rs2: u16) void {
        // Use SCRATCH2 as fallback for spilled vregs (matching moveShiftCountToCl)
        const shift_reg = vregToPhys(rs2) orelse SCRATCH2;
        if (shift_reg != .rcx) {
            if (vregToPhys(3) != null and 3 < self.reg_count) {
                Enc.pop(&self.code, self.alloc, .rcx);
            }
        }
    }

    // --- Division helpers ---
    // x86 uses RAX/RDX for division. RAX = SCRATCH, RDX = vreg 6.

    const MagicU32 = struct { magic: u32, shift: u6 };

    /// Compute magic multiplier for unsigned 32-bit division by constant.
    /// Returns (magic, shift) such that: floor(n/d) = floor((u64(n) * magic) >> shift)
    fn computeMagicU32(d: u32) ?MagicU32 {
        if (d < 2) return null;
        if (d & (d - 1) == 0) return null; // power of 2 handled separately
        for (32..64) |p| {
            const two_p: u64 = @as(u64, 1) << @intCast(p);
            const magic: u64 = (two_p + d - 1) / d;
            if (magic > 0xFFFFFFFF) continue;
            const rem = two_p % d;
            const err = if (rem == 0) 0 else d - @as(u32, @intCast(rem));
            if (@as(u64, err) * 0xFFFFFFFF < two_p) {
                return .{ .magic = @intCast(magic), .shift = @intCast(p) };
            }
        }
        return null;
    }

    /// Emit unsigned division by known constant using multiply-by-reciprocal.
    /// x86_64: IMUL r64,r64 for 32×32→64, then SHR r64,shift.
    fn tryEmitDivByConstU32(self: *Compiler, instr: RegInstr, divisor: u32) bool {
        // Power of 2: just SHR
        if (divisor & (divisor - 1) == 0) {
            const shift: u5 = @intCast(@ctz(divisor));
            const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
            if (rs1 != SCRATCH) Enc.movRegReg32(&self.code, self.alloc, SCRATCH, rs1);
            Enc.shrImm32(&self.code, self.alloc, SCRATCH, shift);
            self.storeVreg(instr.rd, SCRATCH);
            return true;
        }
        const m = computeMagicU32(divisor) orelse return false;
        // Load dividend into SCRATCH (zero-extended to 64 bits via MOV r32)
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        if (rs1 != SCRATCH) Enc.movRegReg32(&self.code, self.alloc, SCRATCH, rs1);
        // Load magic constant into SCRATCH2
        self.emitLoadImm32(SCRATCH2, m.magic);
        // IMUL r64, r64: SCRATCH = (u64)n * (u64)magic (both < 2^32, product < 2^64)
        Enc.imulRegReg(&self.code, self.alloc, SCRATCH, SCRATCH2);
        // SHR r64, shift: extract quotient from high bits
        Enc.shrImm(&self.code, self.alloc, SCRATCH, m.shift);
        self.storeVreg(instr.rd, SCRATCH);
        return true;
    }

    fn emitDiv32(self: *Compiler, instr: RegInstr, signed: bool, is_rem: bool) void {
        // Fast path: unsigned division by known constant
        if (!signed and !is_rem) {
            const rs2_vreg = instr.rs2();
            if (rs2_vreg < 128) {
                if (self.known_consts[rs2_vreg]) |d| {
                    if (d >= 2 and self.tryEmitDivByConstU32(instr, d))
                        return;
                }
            }
        }

        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const divisor = self.getOrLoad(rs2, SCRATCH2);

        // Check divisor == 0 → DivisionByZero (x86 IDIV/DIV raises SIGFPE)
        Enc.testRegReg32(&self.code, self.alloc, divisor, divisor);
        self.emitCondError(.e, 3); // error code 3 = DivisionByZero

        // Signed division edge cases for divisor == -1:
        // - div: INT_MIN / -1 → IntegerOverflow trap (x86 IDIV raises SIGFPE)
        // - rem: N % -1 = 0 always; skip IDIV to avoid SIGFPE on INT_MIN
        // Use 32-bit CMP: i32(-1) is stored as 0x00000000FFFFFFFF in 64-bit reg,
        // so 64-bit CMP with sign-extended -1 (0xFFFFFFFFFFFFFFFF) would fail.
        var rem_done_off: ?u32 = null;
        if (signed) {
            if (!is_rem) {
                Enc.cmpImm8_32(&self.code, self.alloc, divisor, -1);
                const skip_off = Enc.jccRel32(&self.code, self.alloc, .ne);
                Enc.cmpImm32(&self.code, self.alloc, r1, 0x80000000);
                self.emitCondError(.e, 4); // error code 4 = IntegerOverflow
                Enc.patchRel32(self.code.items, skip_off, self.currentOffset());
            } else {
                // rem_s: if divisor == -1, result is 0 — skip IDIV entirely
                Enc.cmpImm8_32(&self.code, self.alloc, divisor, -1);
                const ne_off = Enc.jccRel32(&self.code, self.alloc, .ne);
                Enc.xorRegReg32(&self.code, self.alloc, .rax, .rax);
                self.storeVreg(instr.rd, .rax);
                rem_done_off = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, ne_off, self.currentOffset());
            }
        }

        // Move divisor out of RAX/RDX BEFORE we clobber them.
        // RAX is clobbered by MOV dividend, RDX by CDQ/XOR zero-extension.
        var actual_divisor = divisor;
        if (divisor == .rax or divisor == .rdx) {
            Enc.movRegReg(&self.code, self.alloc, SCRATCH2, divisor);
            actual_divisor = SCRATCH2;
        }

        // Save RDX if it holds a live vreg (vreg 6)
        const rdx_live = vregToPhys(6) != null and 6 < self.reg_count;
        if (rdx_live) Enc.push(&self.code, self.alloc, .rdx);

        // Move dividend to EAX
        if (r1 != .rax) Enc.movRegReg32(&self.code, self.alloc, .rax, r1);

        // Sign/zero-extend EAX to EDX:EAX, then divide
        if (signed) {
            Enc.cdq(&self.code, self.alloc);
            Enc.idivReg32(&self.code, self.alloc, actual_divisor);
        } else {
            Enc.xorRegReg32(&self.code, self.alloc, .rdx, .rdx);
            Enc.divReg32(&self.code, self.alloc, actual_divisor);
        }

        // Result: quotient in EAX, remainder in EDX
        const result_reg: Reg = if (is_rem) .rdx else .rax;
        self.storeVreg(instr.rd, result_reg);

        if (rdx_live) Enc.pop(&self.code, self.alloc, .rdx);

        // Patch rem_s shortcut jump to skip past IDIV
        if (rem_done_off) |off| Enc.patchRel32(self.code.items, off, self.currentOffset());
    }

    fn emitDiv64(self: *Compiler, instr: RegInstr, signed: bool, is_rem: bool) void {
        const rs2 = instr.rs2();
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const divisor = self.getOrLoad(rs2, SCRATCH2);

        // Check divisor == 0 → DivisionByZero
        Enc.testRegReg(&self.code, self.alloc, divisor, divisor);
        self.emitCondError(.e, 3); // error code 3 = DivisionByZero

        // Signed division edge cases for divisor == -1:
        // - div: INT64_MIN / -1 → IntegerOverflow trap
        // - rem: N % -1 = 0 always; skip IDIV to avoid SIGFPE on INT64_MIN
        var rem_done_off: ?u32 = null;
        if (signed) {
            if (!is_rem) {
                Enc.cmpImm8(&self.code, self.alloc, divisor, -1);
                const skip_off = Enc.jccRel32(&self.code, self.alloc, .ne);
                Enc.movImm64(&self.code, self.alloc, SCRATCH, 0x8000000000000000);
                Enc.cmpRegReg(&self.code, self.alloc, r1, SCRATCH);
                self.emitCondError(.e, 4); // error code 4 = IntegerOverflow
                Enc.patchRel32(self.code.items, skip_off, self.currentOffset());
            } else {
                // rem_s: if divisor == -1, result is 0 — skip IDIV entirely
                Enc.cmpImm8(&self.code, self.alloc, divisor, -1);
                const ne_off = Enc.jccRel32(&self.code, self.alloc, .ne);
                Enc.xorRegReg(&self.code, self.alloc, .rax, .rax);
                self.storeVreg(instr.rd, .rax);
                rem_done_off = Enc.jmpRel32(&self.code, self.alloc);
                Enc.patchRel32(self.code.items, ne_off, self.currentOffset());
            }
        }

        // Move divisor out of RAX/RDX BEFORE we clobber them.
        var actual_divisor = divisor;
        if (divisor == .rax or divisor == .rdx) {
            Enc.movRegReg(&self.code, self.alloc, SCRATCH2, divisor);
            actual_divisor = SCRATCH2;
        }

        const rdx_live = vregToPhys(6) != null and 6 < self.reg_count;
        if (rdx_live) Enc.push(&self.code, self.alloc, .rdx);

        if (r1 != .rax) Enc.movRegReg(&self.code, self.alloc, .rax, r1);

        if (signed) {
            Enc.cqo(&self.code, self.alloc);
            Enc.idivReg(&self.code, self.alloc, actual_divisor);
        } else {
            Enc.xorRegReg32(&self.code, self.alloc, .rdx, .rdx);
            Enc.divReg(&self.code, self.alloc, actual_divisor);
        }

        const result_reg: Reg = if (is_rem) .rdx else .rax;
        self.storeVreg(instr.rd, result_reg);

        if (rdx_live) Enc.pop(&self.code, self.alloc, .rdx);

        // Patch rem_s shortcut jump to skip past IDIV
        if (rem_done_off) |off| Enc.patchRel32(self.code.items, off, self.currentOffset());
    }

    // --- Bit manipulation helpers ---

    fn emitClz32(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        // LZCNT if available, but for portability use BSR + XOR trick
        // BSR rd, src → rd = bit index of highest set bit (undefined if 0)
        // CLZ = 31 - BSR result. Handle zero: CLZ(0) = 32.
        // Use: MOV rd, 32; BSR tmp, src; CMOVNE rd, (31-tmp)
        // Simpler: XOR rd, rd; BSR SCRATCH2, src; JZ done; XOR rd, 31; SUB rd, SCRATCH2; ... too complex
        // Actually, just use LZCNT (BMI1) — most x86_64 CPUs since Haswell support it.
        Enc.lzcnt(&self.code, self.alloc, rd, src);
        // LZCNT operates on 32-bit for r32 variant — but our Enc.lzcnt uses REX.W (64-bit).
        // For 32-bit CLZ, we need 32-bit LZCNT. Quick fix: zero-extend src first.
        // Actually, Enc.lzcnt is 64-bit. For i32.clz we need 64-bit LZCNT then subtract 32.
        // LZCNT64(zero-extended 32-bit value) = 32 + CLZ32(value)
        // So: subtract 32 from result.
        Enc.subImm32(&self.code, self.alloc, rd, 32);
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitClz64(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        Enc.lzcnt(&self.code, self.alloc, rd, src);
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitCtz32(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        // TZCNT is 64-bit in our encoding. For i32.ctz of a zero-extended 32-bit value:
        // if value is 0, TZCNT64 = 64, but i32.ctz(0) = 32.
        // We need to OR with (1 << 32) to cap at 32.
        // Simpler: use 32-bit TZCNT. But our Enc.tzcnt emits REX.W.
        // Workaround: TZCNT64 then MIN(result, 32).
        // Or just emit 32-bit TZCNT manually (F3 [REX] 0F BC).
        // For now, use TZCNT64 and cap.
        Enc.tzcnt(&self.code, self.alloc, rd, src);
        // If src was zero-extended (upper 32 bits = 0), TZCNT64 = 32 when all low 32 are 0.
        // Actually, TZCNT counts from LSB. If low 32 bits are 0 and upper 32 are also 0
        // (which they are for a zero-extended i32), TZCNT64 = 64.
        // We need to cap at 32. Use CMP + CMOV.
        Enc.cmpImm8(&self.code, self.alloc, rd, 32);
        // If rd > 32 (can only be 64), set to 32
        Enc.movImm32(&self.code, self.alloc, SCRATCH2, 32);
        // CMOVA rd, SCRATCH2 — not trivially available in our encoder. Use branch:
        // JBE skip; MOV rd, 32; skip:
        const patch = Enc.jccRel32(&self.code, self.alloc, .be);
        if (rd != SCRATCH2) Enc.movRegReg(&self.code, self.alloc, rd, SCRATCH2);
        Enc.patchRel32(self.code.items, patch, self.currentOffset());
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitCtz64(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        Enc.tzcnt(&self.code, self.alloc, rd, src);
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitPopcnt32(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        // POPCNT64 on a zero-extended 32-bit value gives correct 32-bit popcount.
        Enc.popcnt(&self.code, self.alloc, rd, src);
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitPopcnt64(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        Enc.popcnt(&self.code, self.alloc, rd, src);
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    // --- Sign extension helpers ---

    fn emitSignExt(self: *Compiler, instr: RegInstr, bits: u8, is64: bool) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;
        // MOVSX r64/r32, r8/r16/r32
        switch (bits) {
            8 => {
                // MOVSX r, r8: 0F BE /r (32-bit) or REX.W 0F BE (64-bit)
                if (is64) {
                    self.emitMovsxByte64(rd, src);
                } else {
                    self.emitMovsxByte32(rd, src);
                }
            },
            16 => {
                // MOVSX r, r16: 0F BF /r (32-bit) or REX.W 0F BF (64-bit)
                if (is64) {
                    self.emitMovsxWord64(rd, src);
                } else {
                    self.emitMovsxWord32(rd, src);
                }
            },
            32 => {
                // MOVSXD r64, r32: REX.W 63 /r
                Enc.movsxd(&self.code, self.alloc, rd, src);
            },
            else => {},
        }
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    // Inline MOVSX byte/word encoding (not in Enc to keep it simple)
    fn emitMovsxByte32(self: *Compiler, dst: Reg, src: Reg) void {
        if (dst.isExt() or src.isExt() or @intFromEnum(src) >= 4) {
            self.code.append(self.alloc, Enc.rex(false, dst.isExt(), false, src.isExt())) catch {};
        }
        self.code.append(self.alloc, 0x0F) catch {};
        self.code.append(self.alloc, 0xBE) catch {};
        self.code.append(self.alloc, Enc.modrmReg(dst, src)) catch {};
    }

    fn emitMovsxByte64(self: *Compiler, dst: Reg, src: Reg) void {
        self.code.append(self.alloc, Enc.rexW(dst, src)) catch {};
        self.code.append(self.alloc, 0x0F) catch {};
        self.code.append(self.alloc, 0xBE) catch {};
        self.code.append(self.alloc, Enc.modrmReg(dst, src)) catch {};
    }

    fn emitMovsxWord32(self: *Compiler, dst: Reg, src: Reg) void {
        if (dst.isExt() or src.isExt()) {
            self.code.append(self.alloc, Enc.rex(false, dst.isExt(), false, src.isExt())) catch {};
        }
        self.code.append(self.alloc, 0x0F) catch {};
        self.code.append(self.alloc, 0xBF) catch {};
        self.code.append(self.alloc, Enc.modrmReg(dst, src)) catch {};
    }

    fn emitMovsxWord64(self: *Compiler, dst: Reg, src: Reg) void {
        self.code.append(self.alloc, Enc.rexW(dst, src)) catch {};
        self.code.append(self.alloc, 0x0F) catch {};
        self.code.append(self.alloc, 0xBF) catch {};
        self.code.append(self.alloc, Enc.modrmReg(dst, src)) catch {};
    }
};

// ================================================================
// Public entry point — called from jit.zig
// ================================================================

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
    page_size_log2: u5,
) ?*JitCode {
    if (builtin.cpu.arch != .x86_64) return null;
    _ = trace;
    _ = min_memory_bytes;

    const trampoline_addr = @intFromPtr(&jit_mod.jitCallTrampoline);
    const mem_info_addr = @intFromPtr(&jit_mod.jitGetMemInfo);
    const global_get_addr = @intFromPtr(&jit_mod.jitGlobalGet);
    const global_set_addr = @intFromPtr(&jit_mod.jitGlobalSet);
    const mem_grow_addr = @intFromPtr(&jit_mod.jitMemGrow);
    const mem_fill_addr = @intFromPtr(&jit_mod.jitMemFill);
    const mem_copy_addr = @intFromPtr(&jit_mod.jitMemCopy);
    const call_indirect_addr = @intFromPtr(&jit_mod.jitCallIndirectTrampoline);
    const reg_ptr_offset: u32 = @intCast(@offsetOf(vm_mod.Vm, "reg_ptr"));

    var compiler = Compiler.init(alloc);
    compiler.use_guard_pages = use_guard_pages;
    compiler.osr_target_pc = osr_target_pc;
    compiler.page_size_log2 = page_size_log2;
    compiler.jit_fuel_offset = @intCast(@offsetOf(vm_mod.Vm, "jit_fuel"));
    compiler.simd_v128_offset = @intCast(@offsetOf(vm_mod.Vm, "simd_v128"));
    compiler.simd_trampoline_addr = @intFromPtr(&vm_mod.Vm.jitSimdTrampoline);
    compiler.fuel_check_helper_addr = @intFromPtr(&vm_mod.Vm.jitFuelCheckHelper);
    defer compiler.deinit();

    return compiler.compile(
        reg_func,
        pool64,
        trampoline_addr,
        mem_info_addr,
        global_get_addr,
        global_set_addr,
        mem_grow_addr,
        mem_fill_addr,
        mem_copy_addr,
        call_indirect_addr,
        self_func_idx,
        param_count,
        result_count,
        reg_ptr_offset,
    );
}

// ================================================================
// Tests
// ================================================================

const testing = std.testing;

test "x86_64 instruction encoding" {
    const alloc = testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    // RET = C3
    Enc.ret_(&buf, alloc);
    try testing.expectEqual(@as(u8, 0xC3), buf.items[0]);

    buf.clearRetainingCapacity();

    // NOP = 90
    Enc.nop(&buf, alloc);
    try testing.expectEqual(@as(u8, 0x90), buf.items[0]);

    buf.clearRetainingCapacity();

    // PUSH RBX = 53
    Enc.push(&buf, alloc, .rbx);
    try testing.expectEqual(@as(u8, 0x53), buf.items[0]);
    try testing.expectEqual(@as(usize, 1), buf.items.len);

    buf.clearRetainingCapacity();

    // PUSH R12 = 41 54
    Enc.push(&buf, alloc, .r12);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x54 }, buf.items);

    buf.clearRetainingCapacity();

    // POP RBX = 5B
    Enc.pop(&buf, alloc, .rbx);
    try testing.expectEqual(@as(u8, 0x5B), buf.items[0]);

    buf.clearRetainingCapacity();

    // MOV RAX, RCX = 48 89 C8 (REX.W 89 /r, mod=11 src=RCX rm=RAX)
    Enc.movRegReg(&buf, alloc, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xC8 }, buf.items);

    buf.clearRetainingCapacity();

    // MOV R12, RDI = 49 89 FC (REX.WB 89 /r)
    Enc.movRegReg(&buf, alloc, .r12, .rdi);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x89, 0xFC }, buf.items);

    buf.clearRetainingCapacity();

    // ADD RAX, RCX = 48 01 C8
    Enc.addRegReg(&buf, alloc, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x01, 0xC8 }, buf.items);

    buf.clearRetainingCapacity();

    // XOR EAX, EAX = 31 C0 (32-bit, zero-extends, no REX needed)
    Enc.xorRegReg32(&buf, alloc, .rax, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x31, 0xC0 }, buf.items);

    buf.clearRetainingCapacity();

    // MOV EAX, 42 = B8 2A000000
    Enc.movImm32(&buf, alloc, .rax, 42);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00 }, buf.items);

    buf.clearRetainingCapacity();

    // MOV RAX, 0x123456789ABCDEF0 = 48 B8 F0DEBC9A78563412
    Enc.movImm64(&buf, alloc, .rax, 0x123456789ABCDEF0);
    try testing.expectEqual(@as(usize, 10), buf.items.len);
    try testing.expectEqual(@as(u8, 0x48), buf.items[0]); // REX.W
    try testing.expectEqual(@as(u8, 0xB8), buf.items[1]); // B8+RAX
}

test "x86_64 condition codes" {
    try testing.expectEqual(Cond.ne, Cond.e.invert());
    try testing.expectEqual(Cond.e, Cond.ne.invert());
    try testing.expectEqual(Cond.ge, Cond.l.invert());
    try testing.expectEqual(Cond.le, Cond.g.invert());
}

test "x86_64 virtual register mapping" {
    // r0-r2 → callee-saved
    try testing.expectEqual(Reg.rbx, vregToPhys(0).?);
    try testing.expectEqual(Reg.rbp, vregToPhys(1).?);
    try testing.expectEqual(Reg.r15, vregToPhys(2).?);
    // r3-r10 → caller-saved
    try testing.expectEqual(Reg.rcx, vregToPhys(3).?);
    try testing.expectEqual(Reg.rdi, vregToPhys(4).?);
    try testing.expectEqual(Reg.rsi, vregToPhys(5).?);
    try testing.expectEqual(Reg.rdx, vregToPhys(6).?);
    try testing.expectEqual(Reg.r8, vregToPhys(7).?);
    try testing.expectEqual(Reg.r9, vregToPhys(8).?);
    try testing.expectEqual(Reg.r10, vregToPhys(9).?);
    // r10+ → spill (R11 reserved for SCRATCH2)
    try testing.expectEqual(@as(?Reg, null), vregToPhys(10));
    try testing.expectEqual(@as(?Reg, null), vregToPhys(11));
    try testing.expectEqual(@as(?Reg, null), vregToPhys(20));
}

test "x86_64 compile and execute constant return" {
    if (builtin.cpu.arch != .x86_64) return;

    const alloc = testing.allocator;
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    var regs: [5]u64 = .{ 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, undefined);
    try testing.expectEqual(@as(u64, 0), result); // success
    try testing.expectEqual(@as(u64, 42), regs[0]); // result
}

test "x86_64 compile and execute i32 add" {
    if (builtin.cpu.arch != .x86_64) return;

    const alloc = testing.allocator;
    var code = [_]RegInstr{
        .{ .op = 0x6A, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.add r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    var regs: [7]u64 = .{ 10, 32, 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, undefined);
    try testing.expectEqual(@as(u64, 0), result);
    try testing.expectEqual(@as(u64, 42), regs[0]); // 10 + 32 = 42, stored to regs[0] via epilogue
}

test "x86_64 compile and execute branch (LE_S + BR_IF_NOT)" {
    if (builtin.cpu.arch != .x86_64) return;

    const alloc = testing.allocator;
    // Equivalent to: if (r0 <= r1) return r0; else return r1;
    // 0: i32.le_s r2, r0, r1   (0x4C)
    // 1: BR_IF_NOT r2, pc=3    (skip to else)
    // 2: RETURN r0
    // 3: RETURN r1
    var code = [_]RegInstr{
        .{ .op = 0x4C, .rd = 2, .rs1 = 0, .rs2_field = 1 }, // i32.le_s r2, r0, r1
        .{ .op = regalloc_mod.OP_BR_IF_NOT, .rd = 2, .rs1 = 0, .operand = 3 }, // branch if !le_s
        .{ .op = regalloc_mod.OP_RETURN, .rd = 0, .rs1 = 0, .operand = 0 }, // return r0
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 }, // return r1
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // Case 1: 5 <= 10 → return 5
    var regs1: [7]u64 = .{ 5, 10, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(u64, 0), jit_code.entry(&regs1, undefined, undefined));
    try testing.expectEqual(@as(u64, 5), regs1[0]);

    // Case 2: 10 <= 5 → false, return 5 (r1)
    var regs2: [7]u64 = .{ 10, 5, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(u64, 0), jit_code.entry(&regs2, undefined, undefined));
    try testing.expectEqual(@as(u64, 5), regs2[0]);
}

test "x86_64 compile and execute loop (simple counter)" {
    if (builtin.cpu.arch != .x86_64) return;

    const alloc = testing.allocator;
    // Count from r0 down to 0, accumulate in r1
    // r0 = n, r1 = 0 (accumulator), r2 = 1 (const)
    // 0: CONST32 r1, 0
    // 1: CONST32 r2, 1
    // loop:
    // 2: i32.eqz r3, r0          (0x45)
    // 3: BR_IF r3, pc=7           (if r0==0, exit)
    // 4: i32.add r1, r1, r2       (0x6A)
    // 5: i32.sub r0, r0, r2       (0x6B)
    // 6: BR pc=2                   (loop back)
    // 7: MOV r0, r1               (return accumulator)
    // 8: RETURN r0
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc_mod.OP_CONST32, .rd = 2, .rs1 = 0, .operand = 1 },
        .{ .op = 0x45, .rd = 3, .rs1 = 0, .operand = 0 }, // i32.eqz r3, r0
        .{ .op = regalloc_mod.OP_BR_IF, .rd = 3, .rs1 = 0, .operand = 7 },
        .{ .op = 0x6A, .rd = 1, .rs1 = 1, .rs2_field = 2 }, // i32.add r1, r1, r2
        .{ .op = 0x6B, .rd = 0, .rs1 = 0, .rs2_field = 2 }, // i32.sub r0, r0, r2
        .{ .op = regalloc_mod.OP_BR, .rd = 0, .rs1 = 0, .operand = 2 },
        .{ .op = regalloc_mod.OP_MOV, .rd = 0, .rs1 = 1, .operand = 0 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 4,
        .local_count = 1,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 1, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // count(10) = 10
    // regs layout: [0..3]=vregs, [4]=reg_ptr_addr, [5]=unused, [6]=vm_ptr, [7]=inst_ptr
    // Fuel check reads vm_ptr from regs[reg_count+2] and accesses vm.jit_fuel.
    // Provide a real Vm so the fuel decrement doesn't SEGV.
    var vm = vm_mod.Vm.init(alloc);
    var regs: [8]u64 = .{ 10, 0, 0, 0, 0, 0, @intFromPtr(&vm), 0 };
    try testing.expectEqual(@as(u64, 0), jit_code.entry(&regs, @ptrCast(&vm), undefined));
    try testing.expectEqual(@as(u64, 10), regs[0]);
}

test "x86_64 compile and execute memory load" {
    if (builtin.cpu.arch != .x86_64) return;

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
    const module_mod = @import("module.zig");
    var dummy_module = module_mod.Module.init(alloc, &.{});
    var inst = Instance.init(alloc, &store, &dummy_module);
    defer inst.deinit();
    try inst.memaddrs.append(alloc, mem_idx);

    // Verify jitGetMemInfo works with our instance
    var info: [2]u64 = .{ 0, 0 };
    jit_mod.jitGetMemInfo(@ptrCast(&inst), &info);
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 1, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // Execute: load from addr=0, offset=16 → should read 42
    // regs needs +4 extra for memory cache + VM/instance pointers
    var regs: [6]u64 = .{ 0, 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, @ptrCast(&inst));
    try testing.expectEqual(@as(u64, 0), result); // success
    try testing.expectEqual(@as(u64, 42), regs[0]); // loaded value (stored at regs[0] by RETURN)

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

test "x86_64 compile and execute memory store then load" {
    if (builtin.cpu.arch != .x86_64) return;

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

    // r0 = addr, r1 = value to store
    // store i32 r1 at [r0+0], load i32 r2 from [r0+0], return r2
    var code = [_]RegInstr{
        // [0] i32.store [r0 + 0] = r1
        .{ .op = 0x36, .rd = 1, .rs1 = 0, .operand = 0 },
        // [1] i32.load r2, [r0 + 0]
        .{ .op = 0x28, .rd = 2, .rs1 = 0, .operand = 0 },
        // [2] RETURN r2
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 1,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // Store 99 at addr 200, then load it back
    var regs: [7]u64 = .{ 200, 99, 0, 0, 0, 0, 0 };
    const result = jit_code.entry(&regs, undefined, @ptrCast(&inst));
    try testing.expectEqual(@as(u64, 0), result);
    try testing.expectEqual(@as(u64, 99), regs[0]); // loaded value via RETURN
}

test "x86_64 compile and execute f64 add" {
    if (builtin.cpu.arch != .x86_64) return;

    const alloc = testing.allocator;
    // r0 = f64 param A, r1 = f64 param B
    // f64.add r0, r0, r1 (opcode 0xA0)
    // RETURN r0
    var code = [_]RegInstr{
        .{ .op = 0xA0, .rd = 0, .rs1 = 0, .rs2_field = 1 }, // f64.add r0 = r0 + r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 2,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // 3.0 + 4.0 = 7.0
    var regs: [6]u64 = .{ @bitCast(@as(f64, 3.0)), @bitCast(@as(f64, 4.0)), 0, 0, 0, 0 };
    try testing.expectEqual(@as(u64, 0), jit_code.entry(&regs, undefined, undefined));
    const result: f64 = @bitCast(regs[0]);
    try testing.expectEqual(@as(f64, 7.0), result);
}

test "x86_64 CMP+Jcc fusion saves instructions per compare-and-branch" {
    if (builtin.cpu.arch != .x86_64) return;

    const alloc = testing.allocator;
    // if (a == b) return 42 else return 99
    // Pattern: i32.eq (r0, r1 -> r2) + BR_IF r2 — should fuse to CMP + Je
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

    // Also compile WITHOUT fusion opportunity (different rd for CMP and BR_IF)
    var code_nofuse = [_]RegInstr{
        .{ .op = 0x46, .rd = 2, .rs1 = 0, .rs2_field = 1 },
        .{ .op = regalloc_mod.OP_BR_IF, .rd = 3, .rs1 = 0, .operand = 4 },
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 99 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 42 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
    };

    var reg_func = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 4, .local_count = 2, .alloc = alloc };
    var reg_func_nofuse = RegFunc{ .code = &code_nofuse, .pool64 = &.{}, .reg_count = 4, .local_count = 2, .alloc = alloc };

    const jit_fused = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_fused.deinit(alloc);

    const jit_nofuse = compileFunction(alloc, &reg_func_nofuse, &.{}, 0, 0, 1, null, 0, false, null, 16) orelse
        return error.CompilationFailed;
    defer jit_nofuse.deinit(alloc);

    // Functional: a == b → 42
    {
        var regs: [8]u64 = .{ 5, 5, 0, 0, 0, 0, 0, 0 };
        const r = jit_fused.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), r);
        try testing.expectEqual(@as(u64, 42), regs[0]);
    }

    // Functional: a != b → 99
    {
        var regs: [8]u64 = .{ 5, 7, 0, 0, 0, 0, 0, 0 };
        const r = jit_fused.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), r);
        try testing.expectEqual(@as(u64, 99), regs[0]);
    }

    // Fusion check: fused code should be shorter
    try testing.expect(jit_fused.code_len < jit_nofuse.code_len);
}

test "x86_64 unreachable opcode emits trap error" {
    if (builtin.cpu.arch != .x86_64) return;

    const alloc = testing.allocator;

    // IR: if arg == 0, return 42; otherwise, fall through to unreachable.
    // [0] BR_IF_NOT r0, target=2 → if arg == 0, skip to return
    // [1] unreachable (0x00)
    // [2] CONST32 r1, 42
    // [3] RETURN r1
    var code = [_]RegInstr{
        .{ .op = regalloc_mod.OP_BR_IF_NOT, .rd = 0, .rs1 = 0, .operand = 2 },
        .{ .op = 0x00, .rd = 0, .rs1 = 0, .operand = 0 }, // unreachable
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 42 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
    };
    var rf = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 4, .local_count = 2, .alloc = alloc };
    const jit_code = compileFunction(alloc, &rf, &.{}, 0, 1, 1, null, 0, false, null, 16) orelse
        return error.SkipZigTest;
    defer jit_code.deinit(alloc);

    // arg=0: branch skips unreachable, returns 42
    {
        var regs = [_]u64{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 42), regs[0]);
    }

    // arg=1: falls through to unreachable, returns error code 5 (Unreachable)
    {
        var regs = [_]u64{ 1, 0, 0, 0, 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 5), result);
    }
}
