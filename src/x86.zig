// Copyright (c) 2026 zwasm contributors. Licensed under the MIT License.
// See LICENSE at the root of this distribution.

//! x86_64 JIT compiler — compiles register IR to native machine code.
//! Parallel to ARM64 backend in jit.zig. See D105 in .dev/decisions.md.
//!
//! Register mapping (System V AMD64 ABI):
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
//!   Entry: RDI=regs, RSI=vm, RDX=instance. Returns: RAX=0 success.

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
const jit_mod = @import("jit.zig");
const JitCode = jit_mod.JitCode;
const JitFn = jit_mod.JitFn;
const vm_mod = @import("vm.zig");

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
const SCRATCH2 = Reg.r11; // secondary scratch (caller-saved, not a vreg)

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
    // p = 0xA, // parity (not needed)
    // np = 0xB,
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

/// Map virtual register index to x86_64 physical register.
/// r0-r2 → RBX, RBP, R15 (callee-saved)
/// r3-r10 → RCX, RDI, RSI, RDX, R8, R9, R10, R11 (caller-saved)
/// r11+ → memory (via regs_ptr at R12)
fn vregToPhys(vreg: u8) ?Reg {
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
        10 => .r11,
        else => null, // spill to memory
    };
}

/// Maximum virtual registers mappable to physical registers.
const MAX_PHYS_REGS: u8 = 11;

/// First caller-saved vreg index (for spill/reload).
const FIRST_CALLER_SAVED_VREG: u8 = 3;

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
    self_func_idx: u32,
    param_count: u16,
    result_count: u16,
    reg_ptr_offset: u32,
    min_memory_bytes: u32,
    known_consts: [128]?u32,
    written_vregs: u128,
    scratch_vreg: ?u8,

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
            .self_func_idx = 0,
            .param_count = 0,
            .result_count = 0,
            .reg_ptr_offset = 0,
            .min_memory_bytes = 0,
            .known_consts = .{null} ** 128,
            .written_vregs = 0,
            .scratch_vreg = null,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.code.deinit(self.alloc);
        self.pc_map.deinit(self.alloc);
        self.patches.deinit(self.alloc);
        self.error_stubs.deinit(self.alloc);
    }

    fn currentOffset(self: *Compiler) u32 {
        return @intCast(self.code.items.len);
    }

    // --- Virtual register load/store ---

    /// Load vreg value into a physical register.
    /// If vreg is already in a physical register, returns that register.
    /// Otherwise, loads from memory (regs_ptr + vreg*8) into `scratch`.
    fn getOrLoad(self: *Compiler, vreg: u8, scratch: Reg) Reg {
        if (vregToPhys(vreg)) |phys| return phys;
        // Load from memory: MOV scratch, [R12 + vreg*8]
        self.loadVreg(vreg, scratch);
        return scratch;
    }

    /// Load vreg from memory into dst register.
    fn loadVreg(self: *Compiler, vreg: u8, dst: Reg) void {
        const disp: i32 = @as(i32, vreg) * 8;
        Enc.loadDisp32(&self.code, self.alloc, dst, REGS_PTR, disp);
    }

    /// Store a physical register value to vreg.
    /// If vreg maps to a physical register, emit MOV if needed.
    /// Otherwise, store to memory.
    fn storeVreg(self: *Compiler, vreg: u8, src: Reg) void {
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
            const vreg: u8 = @intCast(i);
            if (self.written_vregs & (@as(u128, 1) << @as(u7, vreg)) != 0) {
                if (vregToPhys(vreg)) |phys| {
                    const disp: i32 = @as(i32, vreg) * 8;
                    Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
                }
            }
        }
    }

    /// Reload caller-saved vregs from memory after a function call.
    fn reloadCallerSaved(self: *Compiler) void {
        const max = @min(self.reg_count, MAX_PHYS_REGS);
        if (max <= FIRST_CALLER_SAVED_VREG) return;
        for (FIRST_CALLER_SAVED_VREG..max) |i| {
            const vreg: u8 = @intCast(i);
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
        Enc.push(&self.code, self.alloc, .r12);
        Enc.push(&self.code, self.alloc, .r13);
        Enc.push(&self.code, self.alloc, .r14);
        Enc.push(&self.code, self.alloc, .r15);

        // Move arguments to callee-saved registers
        // RDI=regs_ptr → R12, RSI=vm_ptr (save to stack), RDX=instance_ptr (save to stack)
        Enc.movRegReg(&self.code, self.alloc, REGS_PTR, .rdi); // R12 = regs_ptr

        // Save vm_ptr and instance_ptr to regs array (after virtual regs)
        // regs[reg_count+2] = vm_ptr, regs[reg_count+3] = instance_ptr
        // (Same convention as ARM64 backend)
        const vm_offset: i32 = (@as(i32, self.reg_count) + 2) * 8;
        const inst_offset: i32 = (@as(i32, self.reg_count) + 3) * 8;
        Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, vm_offset, .rsi);
        Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, inst_offset, .rdx);

        // Load virtual registers from regs array into physical registers
        const max_vreg = @min(self.reg_count, MAX_PHYS_REGS);
        for (0..max_vreg) |i| {
            const vreg: u8 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                const disp: i32 = @as(i32, vreg) * 8;
                Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
            }
        }
    }

    fn emitEpilogue(self: *Compiler) void {
        // Store virtual registers back to regs array
        const max_vreg = @min(self.reg_count, MAX_PHYS_REGS);
        for (0..max_vreg) |i| {
            const vreg: u8 = @intCast(i);
            if (self.written_vregs & (@as(u128, 1) << @as(u7, vreg)) != 0) {
                if (vregToPhys(vreg)) |phys| {
                    const disp: i32 = @as(i32, vreg) * 8;
                    Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
                }
            }
        }

        // Return success (RAX = 0)
        Enc.xorRegReg32(&self.code, self.alloc, .rax, .rax);

        // Restore callee-saved registers
        Enc.pop(&self.code, self.alloc, .r15);
        Enc.pop(&self.code, self.alloc, .r14);
        Enc.pop(&self.code, self.alloc, .r13);
        Enc.pop(&self.code, self.alloc, .r12);
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

    // --- Finalization ---

    fn finalize(self: *Compiler) ?*JitCode {
        const code_size = self.code.items.len;
        if (code_size == 0) return null;
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

        @memcpy(aligned_buf[0..code_size], self.code.items);

        // W^X transition
        std.posix.mprotect(aligned_buf, PROT.READ | PROT.EXEC) catch {
            std.posix.munmap(aligned_buf);
            return null;
        };

        // x86_64 has coherent I/D caches — no icache flush needed.

        const jit_code = self.alloc.create(JitCode) catch {
            std.posix.munmap(aligned_buf);
            return null;
        };
        jit_code.* = .{
            .buf = aligned_buf,
            .entry = @ptrCast(@alignCast(aligned_buf.ptr)),
            .code_len = @intCast(code_size),
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

        self.emitPrologue();

        const ir = reg_func.code;
        var pc: u32 = 0;

        self.pc_map.appendNTimes(self.alloc, 0, ir.len + 1) catch return null;

        // Mark params as written
        for (0..self.param_count) |i| {
            if (i < 128) self.written_vregs |= @as(u128, 1) << @as(u7, @intCast(i));
        }

        while (pc < ir.len) {
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
            // Track written vregs
            if (instr.rd < 128) {
                self.written_vregs |= @as(u128, 1) << @as(u7, @intCast(instr.rd));
            }
        }
        self.pc_map.items[ir.len] = self.currentOffset();

        self.patchBranches() catch return null;

        return self.finalize();
    }

    /// Compile a single RegInstr. Returns false if unsupported (bail out).
    fn compileInstr(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        switch (instr.op) {
            // --- Register ops ---
            regalloc_mod.OP_MOV => {
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.storeVreg(instr.rd, src);
            },
            regalloc_mod.OP_CONST32 => self.emitConst32(instr),
            regalloc_mod.OP_CONST64 => {
                if (!self.emitConst64(instr)) return false;
            },

            // --- Control flow ---
            regalloc_mod.OP_BR => {
                const patch_off = Enc.jmpRel32(&self.code, self.alloc);
                self.patches.append(self.alloc, .{
                    .rel32_offset = patch_off,
                    .target_pc = instr.operand,
                    .kind = .jmp,
                }) catch return false;
            },
            regalloc_mod.OP_BR_IF => {
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
                if (self.result_count > 0) {
                    const src = self.getOrLoad(instr.rd, SCRATCH);
                    if (instr.rd != 0) {
                        Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, 0, src);
                    }
                }
                self.emitEpilogue();
            },
            regalloc_mod.OP_RETURN_VOID => self.emitEpilogue(),
            regalloc_mod.OP_NOP, regalloc_mod.OP_BLOCK_END, regalloc_mod.OP_DELETED => {},

            // --- Function calls (consume extra data words) ---
            regalloc_mod.OP_CALL => {
                _ = ir;
                _ = pc;
                return false; // TODO: task 13.4
            },
            regalloc_mod.OP_CALL_INDIRECT => {
                _ = ir;
                _ = pc;
                return false; // TODO: task 13.4
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
            0x45 => self.emitEqz32(instr),           // i32.eqz
            0x46 => self.emitCmp32(instr, .e),        // i32.eq
            0x47 => self.emitCmp32(instr, .ne),       // i32.ne
            0x48 => self.emitCmp32(instr, .l),        // i32.lt_s
            0x49 => self.emitCmp32(instr, .b),        // i32.lt_u
            0x4A => self.emitCmp32(instr, .g),        // i32.gt_s
            0x4B => self.emitCmp32(instr, .a),        // i32.gt_u
            0x4C => self.emitCmp32(instr, .le),       // i32.le_s
            0x4D => self.emitCmp32(instr, .be),       // i32.le_u
            0x4E => self.emitCmp32(instr, .ge),       // i32.ge_s
            0x4F => self.emitCmp32(instr, .ae),       // i32.ge_u

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
            0x50 => self.emitEqz64(instr),           // i64.eqz
            0x51 => self.emitCmp64(instr, .e),        // i64.eq
            0x52 => self.emitCmp64(instr, .ne),       // i64.ne
            0x53 => self.emitCmp64(instr, .l),        // i64.lt_s
            0x54 => self.emitCmp64(instr, .b),        // i64.lt_u
            0x55 => self.emitCmp64(instr, .g),        // i64.gt_s
            0x56 => self.emitCmp64(instr, .a),        // i64.gt_u
            0x57 => self.emitCmp64(instr, .le),       // i64.le_s
            0x58 => self.emitCmp64(instr, .be),       // i64.le_u
            0x59 => self.emitCmp64(instr, .ge),       // i64.ge_s
            0x5A => self.emitCmp64(instr, .ae),       // i64.ge_u

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

            else => return false, // Unsupported — bail out to interpreter
        }
        return true;
    }

    // --- Helper emitters ---

    const BinOp = enum { add, sub, mul, @"and", @"or", xor };

    fn emitBinop32(self: *Compiler, instr: RegInstr, op: BinOp) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;

        // If rd != r1, move r1 to rd first (x86 is destructive 2-operand)
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

        if (vregToPhys(instr.rd) == null) {
            self.storeVreg(instr.rd, SCRATCH);
        }
    }

    fn emitBinop64(self: *Compiler, instr: RegInstr, op: BinOp) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;

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

    // --- Comparison helpers ---
    // Pattern: CMP r1, r2 → SETcc AL → MOVZX EAX, AL → store to rd

    fn emitCmp32(self: *Compiler, instr: RegInstr, cc: Cond) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        Enc.cmpRegReg32(&self.code, self.alloc, r1, r2);
        Enc.setcc(&self.code, self.alloc, cc, .rax);
        Enc.movzxByte(&self.code, self.alloc, .rax, .rax);
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitCmp64(self: *Compiler, instr: RegInstr, cc: Cond) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        Enc.cmpRegReg(&self.code, self.alloc, r1, r2);
        Enc.setcc(&self.code, self.alloc, cc, .rax);
        Enc.movzxByte(&self.code, self.alloc, .rax, .rax);
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitEqz32(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.testRegReg(&self.code, self.alloc, src, src);
        Enc.setcc(&self.code, self.alloc, .e, .rax);
        Enc.movzxByte(&self.code, self.alloc, .rax, .rax);
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitEqz64(self: *Compiler, instr: RegInstr) void {
        const src = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.testRegReg(&self.code, self.alloc, src, src);
        Enc.setcc(&self.code, self.alloc, .e, .rax);
        Enc.movzxByte(&self.code, self.alloc, .rax, .rax);
        self.storeVreg(instr.rd, SCRATCH);
    }

    // --- Shift helpers ---
    // x86 shifts require count in CL. RCX = vreg 3.

    const ShiftOp = enum { shl, shr, sar, rol, ror };

    fn emitShift32(self: *Compiler, instr: RegInstr, op: ShiftOp) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;

        // Move r1 to rd (destructive)
        if (rd != r1) Enc.movRegReg32(&self.code, self.alloc, rd, r1);

        // Get shift amount into CL
        self.moveShiftCountToCl(rs2, rd);

        switch (op) {
            .shl => Enc.shlCl32(&self.code, self.alloc, rd),
            .shr => Enc.shrCl32(&self.code, self.alloc, rd),
            .sar => Enc.sarCl32(&self.code, self.alloc, rd),
            .rol => {
                // ROL r/m32, CL: D3 /0 (no REX.W = 32-bit)
                if (rd.isExt()) self.code.append(self.alloc, Enc.rex(false, false, false, true)) catch {};
                self.code.append(self.alloc, 0xD3) catch {};
                self.code.append(self.alloc, Enc.modrm(0b11, 0, rd.low3())) catch {};
            },
            .ror => Enc.rorCl32(&self.code, self.alloc, rd),
        }

        self.restoreCl(rs2);
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitShift64(self: *Compiler, instr: RegInstr, op: ShiftOp) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rd = vregToPhys(instr.rd) orelse SCRATCH;

        if (rd != r1) Enc.movRegReg(&self.code, self.alloc, rd, r1);

        self.moveShiftCountToCl(rs2, rd);

        switch (op) {
            .shl => Enc.shlCl(&self.code, self.alloc, rd),
            .shr => Enc.shrCl(&self.code, self.alloc, rd),
            .sar => Enc.sarCl(&self.code, self.alloc, rd),
            .rol => Enc.rolCl(&self.code, self.alloc, rd),
            .ror => Enc.rorCl(&self.code, self.alloc, rd),
        }

        self.restoreCl(rs2);
        if (vregToPhys(instr.rd) == null) self.storeVreg(instr.rd, SCRATCH);
    }

    /// Move shift amount (vreg rs2) into CL. Save RCX if needed.
    fn moveShiftCountToCl(self: *Compiler, rs2: u8, rd: Reg) void {
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

    fn restoreCl(self: *Compiler, rs2: u8) void {
        const shift_reg = vregToPhys(rs2) orelse return;
        if (shift_reg != .rcx) {
            if (vregToPhys(3) != null and 3 < self.reg_count) {
                Enc.pop(&self.code, self.alloc, .rcx);
            }
        }
    }

    // --- Division helpers ---
    // x86 uses RAX/RDX for division. RAX = SCRATCH, RDX = vreg 6.

    fn emitDiv32(self: *Compiler, instr: RegInstr, signed: bool, is_rem: bool) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const divisor = self.getOrLoad(rs2, SCRATCH2);

        // Save RDX if it holds a live vreg (vreg 6)
        const rdx_live = vregToPhys(6) != null and 6 < self.reg_count;
        if (rdx_live) Enc.push(&self.code, self.alloc, .rdx);

        // Move dividend to EAX
        if (r1 != .rax) Enc.movRegReg32(&self.code, self.alloc, .rax, r1);

        // Sign/zero-extend EAX to EDX:EAX
        if (signed) {
            Enc.cdq(&self.code, self.alloc);
            // Ensure divisor is not in RAX or RDX
            if (divisor == .rax or divisor == .rdx) {
                Enc.movRegReg(&self.code, self.alloc, SCRATCH2, divisor);
                Enc.idivReg32(&self.code, self.alloc, SCRATCH2);
            } else {
                Enc.idivReg32(&self.code, self.alloc, divisor);
            }
        } else {
            Enc.xorRegReg32(&self.code, self.alloc, .rdx, .rdx);
            if (divisor == .rax or divisor == .rdx) {
                Enc.movRegReg(&self.code, self.alloc, SCRATCH2, divisor);
                Enc.divReg32(&self.code, self.alloc, SCRATCH2);
            } else {
                Enc.divReg32(&self.code, self.alloc, divisor);
            }
        }

        // Result: quotient in EAX, remainder in EDX
        const result_reg: Reg = if (is_rem) .rdx else .rax;
        self.storeVreg(instr.rd, result_reg);

        if (rdx_live) Enc.pop(&self.code, self.alloc, .rdx);
    }

    fn emitDiv64(self: *Compiler, instr: RegInstr, signed: bool, is_rem: bool) void {
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const divisor = self.getOrLoad(rs2, SCRATCH2);

        const rdx_live = vregToPhys(6) != null and 6 < self.reg_count;
        if (rdx_live) Enc.push(&self.code, self.alloc, .rdx);

        if (r1 != .rax) Enc.movRegReg(&self.code, self.alloc, .rax, r1);

        if (signed) {
            Enc.cqo(&self.code, self.alloc);
            if (divisor == .rax or divisor == .rdx) {
                Enc.movRegReg(&self.code, self.alloc, SCRATCH2, divisor);
                Enc.idivReg(&self.code, self.alloc, SCRATCH2);
            } else {
                Enc.idivReg(&self.code, self.alloc, divisor);
            }
        } else {
            Enc.xorRegReg32(&self.code, self.alloc, .rdx, .rdx);
            if (divisor == .rax or divisor == .rdx) {
                Enc.movRegReg(&self.code, self.alloc, SCRATCH2, divisor);
                Enc.divReg(&self.code, self.alloc, SCRATCH2);
            } else {
                Enc.divReg(&self.code, self.alloc, divisor);
            }
        }

        const result_reg: Reg = if (is_rem) .rdx else .rax;
        self.storeVreg(instr.rd, result_reg);

        if (rdx_live) Enc.pop(&self.code, self.alloc, .rdx);
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
    try testing.expectEqual(Reg.r11, vregToPhys(10).?);
    // r11+ → spill
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0) orelse
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
        .{ .op = 0x6A, .rd = 2, .rs1 = 0, .operand = 1 }, // i32.add r2, r0, r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 2, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 3,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0) orelse
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
        .{ .op = 0x4C, .rd = 2, .rs1 = 0, .operand = 1 }, // i32.le_s r2, r0, r1
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0) orelse
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
        .{ .op = 0x6A, .rd = 1, .rs1 = 1, .operand = 2 }, // i32.add r1, r1, r2
        .{ .op = 0x6B, .rd = 0, .rs1 = 0, .operand = 2 }, // i32.sub r0, r0, r2
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 1, 1, null, 0) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // count(10) = 10
    var regs: [8]u64 = .{ 10, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(u64, 0), jit_code.entry(&regs, undefined, undefined));
    try testing.expectEqual(@as(u64, 10), regs[0]);
}
