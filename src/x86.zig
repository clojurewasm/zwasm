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
    /// Live vreg bitmap at current call site.
    call_live_set: u32,
    scratch_vreg: ?u8,
    /// True when the memory has guard pages — skip explicit bounds checks.
    use_guard_pages: bool,
    /// Byte offset of the shared error epilogue (for signal handler recovery).
    shared_exit_offset: u32,
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
            .self_func_idx = 0,
            .param_count = 0,
            .result_count = 0,
            .reg_ptr_offset = 0,
            .min_memory_bytes = 0,
            .known_consts = .{null} ** 128,
            .written_vregs = 0,
            .call_live_set = 0,
            .scratch_vreg = null,
            .use_guard_pages = false,
            .shared_exit_offset = 0,
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
            if (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg))) != 0) {
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

    /// Spill only caller-saved vregs that are live after the call.
    fn spillCallerSavedLive(self: *Compiler, ir: []const RegInstr, call_pc: u32) void {
        const max = @min(self.reg_count, MAX_PHYS_REGS);
        if (max <= FIRST_CALLER_SAVED_VREG) return;
        // Reuse ARM64's computeCallLiveSet — same RegInstr format
        const jit_arm64 = @import("jit.zig");
        const live_set = jit_arm64.Compiler.computeCallLiveSet(ir, call_pc);
        self.call_live_set = live_set;
        for (FIRST_CALLER_SAVED_VREG..max) |i| {
            const vreg: u8 = @intCast(i);
            if (self.written_vregs & (@as(u128, 1) << @as(u7, @intCast(vreg))) == 0) continue;
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
            if (vregToPhys(vreg)) |phys| {
                const disp: i32 = @as(i32, vreg) * 8;
                Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
            }
        }
    }

    /// Reload only caller-saved vregs that were spilled as live.
    fn reloadCallerSavedLive(self: *Compiler) void {
        const max = @min(self.reg_count, MAX_PHYS_REGS);
        if (max <= FIRST_CALLER_SAVED_VREG) return;
        const live_set = self.call_live_set;
        for (FIRST_CALLER_SAVED_VREG..max) |i| {
            const vreg: u8 = @intCast(i);
            if ((live_set & (@as(u32, 1) << @as(u5, @intCast(vreg)))) == 0) continue;
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
        // Align RSP to 16 bytes. Entry CALL pushed 8 bytes (return addr) +
        // 6 callee-saved pushes = 56 bytes total, leaving RSP misaligned by 8.
        // Sub 8 to restore 16-byte alignment required by System V ABI for CALLs.
        Enc.subImm32(&self.code, self.alloc, .rsp, 8);

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

        // Load memory cache BEFORE loading virtual registers.
        // emitLoadMemCache() calls jitGetMemInfo via CALL, which trashes all
        // caller-saved registers. Loading vregs after ensures their values
        // in RCX, RDI, RSI, RDX, R8-R11 are not corrupted by the call.
        if (self.has_memory) {
            self.emitLoadMemCache();
        }

        // Load virtual registers from regs array into physical registers.
        // Must be AFTER emitLoadMemCache() which calls CALL (trashes caller-saved).
        const max_vreg = @min(self.reg_count, MAX_PHYS_REGS);
        for (0..max_vreg) |i| {
            const vreg: u8 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                const disp: i32 = @as(i32, vreg) * 8;
                Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
            }
        }
    }

    fn emitEpilogue(self: *Compiler, result_vreg: ?u8) void {
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

        // Undo alignment padding + restore callee-saved registers
        Enc.addImm32(&self.code, self.alloc, .rsp, 8);
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

    // --- Error handling ---

    /// Emit conditional error: if condition is true, branch forward to error stub.
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
        if (self.error_stubs.items.len == 0 and !self.use_guard_pages) return;

        // Shared error epilogue: restore callee-saved, return with RAX=error_code
        const shared_exit = self.currentOffset();
        self.shared_exit_offset = shared_exit;
        // At this point, RAX has the error code. Restore callee-saved and return.
        // Undo alignment padding from prologue
        Enc.addImm32(&self.code, self.alloc, .rsp, 8);
        Enc.pop(&self.code, self.alloc, .r15);
        Enc.pop(&self.code, self.alloc, .r14);
        Enc.pop(&self.code, self.alloc, .r13);
        Enc.pop(&self.code, self.alloc, .r12);
        Enc.pop(&self.code, self.alloc, .rbp);
        Enc.pop(&self.code, self.alloc, .rbx);
        Enc.ret_(&self.code, self.alloc);

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

    /// Load memory cache: call jitGetMemInfo(instance, &regs[reg_count]) then
    /// load MEM_BASE and MEM_SIZE from the output slots.
    fn emitLoadMemCache(self: *Compiler) void {
        // System V ABI: RDI=arg0 (instance), RSI=arg1 (&regs[reg_count])
        self.emitLoadInstPtr(.rdi);
        // RSI = address of regs[reg_count] = REGS_PTR + reg_count*8
        const out_disp: i32 = @as(i32, self.reg_count) * 8;
        Enc.movRegReg(&self.code, self.alloc, .rsi, REGS_PTR);
        if (out_disp > 0) {
            Enc.addImm32(&self.code, self.alloc, .rsi, out_disp);
        }
        // CALL jitGetMemInfo
        self.emitLoadImm64(SCRATCH, self.mem_info_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);
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

    /// Emit memory.size: rd = memory pages (MEM_SIZE / 65536)
    fn emitMemorySize(self: *Compiler, instr: RegInstr) void {
        // SHR R14_copy, 16 → pages
        Enc.movRegReg(&self.code, self.alloc, SCRATCH, MEM_SIZE);
        // SHR RAX, 16 — need shift by immediate
        // SHR r64, imm8: REX.W C1 /5 ib
        self.code.append(self.alloc, Enc.rexW1(SCRATCH)) catch {};
        self.code.append(self.alloc, 0xC1) catch {};
        self.code.append(self.alloc, Enc.modrm(3, 5, SCRATCH.low3())) catch {};
        self.code.append(self.alloc, 16) catch {};
        self.storeVreg(instr.rd, SCRATCH);
    }

    // --- Global ops emitters ---

    /// global.get: call jitGlobalGet(instance, idx) → u64
    fn emitGlobalGet(self: *Compiler, instr: RegInstr) void {
        self.spillCallerSaved();
        // System V ABI: RDI=instance, ESI=global_idx
        self.emitLoadInstPtr(.rdi);
        self.emitLoadImm32(.rsi, @truncate(instr.operand));
        // CALL jitGlobalGet
        self.emitLoadImm64(SCRATCH, self.global_get_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);
        // Result in RAX (u64)
        self.reloadCallerSaved();
        self.storeVreg(instr.rd, SCRATCH); // SCRATCH = RAX = result
    }

    /// global.set: call jitGlobalSet(instance, idx, val)
    fn emitGlobalSet(self: *Compiler, instr: RegInstr) void {
        self.spillCallerSaved();
        // System V ABI: RDI=instance, ESI=global_idx, RDX=value
        self.emitLoadInstPtr(.rdi);
        self.emitLoadImm32(.rsi, @truncate(instr.operand));
        const val_reg = self.getOrLoad(instr.rd, SCRATCH);
        Enc.movRegReg(&self.code, self.alloc, .rdx, val_reg);
        // CALL jitGlobalSet
        self.emitLoadImm64(SCRATCH, self.global_set_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);
        self.reloadCallerSaved();
        self.scratch_vreg = null;
    }

    // --- Call emitters ---

    /// Emit a function call via trampoline.
    fn emitCall(self: *Compiler, rd: u8, func_idx: u32, n_args: u16, data: RegInstr, data2: ?RegInstr, ir: []const RegInstr, call_pc: u32) void {
        // 1. Spill caller-saved regs + arg vregs
        self.spillCallerSavedLive(ir, call_pc);
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

        // 2. Set up trampoline args (System V AMD64 ABI: RDI, RSI, RDX, RCX, R8, R9):
        //    RDI=vm, RSI=instance, RDX=regs, ECX=func_idx, R8D=rd, R9=data_word
        //    data2 goes on the stack (7th argument)
        self.emitLoadVmPtr(.rdi);
        self.emitLoadInstPtr(.rsi);
        Enc.movRegReg(&self.code, self.alloc, .rdx, REGS_PTR);
        self.emitLoadImm32(.rcx, func_idx);
        self.emitLoadImm32(.r8, @as(u32, rd));
        // Pack data word as u64 into R9
        const data_u64: u64 = @bitCast(data);
        self.emitLoadImm64(.r9, data_u64);
        // data2 as 7th argument: push onto stack
        if (data2) |d2| {
            const d2_u64: u64 = @bitCast(d2);
            self.emitLoadImm64(SCRATCH, d2_u64);
        } else {
            Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH);
        }
        // Alignment padding: RSP is 16-aligned after prologue; one push would
        // leave RSP at 8 mod 16, violating the ABI before CALL.
        // Sub 8 first so that push + sub = 16 bytes, keeping RSP 16-aligned.
        Enc.subImm32(&self.code, self.alloc, .rsp, 8);
        Enc.push(&self.code, self.alloc, SCRATCH); // 7th arg on stack

        // 3. CALL trampoline
        self.emitLoadImm64(SCRATCH, self.trampoline_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);

        // 4. Clean up stack (remove 7th arg + alignment padding = 16 bytes)
        Enc.addImm32(&self.code, self.alloc, .rsp, 16);

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

        // 7. Reload caller-saved regs, then load result
        self.reloadCallerSavedLive();
        self.reloadVreg(rd);
    }

    /// Emit call_indirect via trampoline.
    fn emitCallIndirect(self: *Compiler, instr: RegInstr, data: RegInstr, data2: ?RegInstr) void {
        // 1. Spill caller-saved regs + arg vregs
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
        self.spillVregIfCalleeSaved(instr.rs1);

        // 2. System V AMD64: RDI=vm, RSI=instance, RDX=regs, ECX=type_idx_table_idx,
        //    R8D=result_reg, R9=data_word, stack[0]=data2_word, stack[1]=elem_idx
        self.emitLoadVmPtr(.rdi);
        self.emitLoadInstPtr(.rsi);
        Enc.movRegReg(&self.code, self.alloc, .rdx, REGS_PTR);
        self.emitLoadImm32(.rcx, instr.operand);
        self.emitLoadImm32(.r8, @as(u32, instr.rd));
        const data_u64: u64 = @bitCast(data);
        self.emitLoadImm64(.r9, data_u64);

        // Push elem_idx (8th arg) first, then data2 (7th arg) — right to left
        // Load elem_idx from regs[instr.rs1]
        const elem_disp: i32 = @as(i32, instr.rs1) * 8;
        Enc.loadDisp32(&self.code, self.alloc, SCRATCH, REGS_PTR, elem_disp);
        Enc.push(&self.code, self.alloc, SCRATCH); // 8th arg

        if (data2) |d2| {
            const d2_u64: u64 = @bitCast(d2);
            self.emitLoadImm64(SCRATCH, d2_u64);
        } else {
            Enc.xorRegReg32(&self.code, self.alloc, SCRATCH, SCRATCH);
        }
        Enc.push(&self.code, self.alloc, SCRATCH); // 7th arg

        // 3. CALL trampoline
        self.emitLoadImm64(SCRATCH, self.call_indirect_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);

        // 4. Clean up stack (2 pushed args = 16 bytes)
        Enc.addImm32(&self.code, self.alloc, .rsp, 16);

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
        self.reloadVreg(instr.rd);
    }

    /// Spill a single vreg if it's callee-saved (r0-r2). No-op for caller-saved.
    fn spillVregIfCalleeSaved(self: *Compiler, vreg: u8) void {
        if (vregToPhys(vreg)) |phys| {
            // Caller-saved: RCX, RDI, RSI, RDX, R8-R11 → already spilled
            // Callee-saved: RBX(r0), RBP(r1), R15(r2) → need explicit spill
            switch (phys) {
                .rbx, .rbp, .r15 => {
                    const disp: i32 = @as(i32, vreg) * 8;
                    Enc.storeDisp32(&self.code, self.alloc, REGS_PTR, disp, phys);
                },
                else => {},
            }
        }
    }

    /// Reload a single vreg from memory.
    fn reloadVreg(self: *Compiler, vreg: u8) void {
        if (vregToPhys(vreg)) |phys| {
            const disp: i32 = @as(i32, vreg) * 8;
            Enc.loadDisp32(&self.code, self.alloc, phys, REGS_PTR, disp);
        }
    }

    /// Emit memory.grow via trampoline call.
    fn emitMemGrow(self: *Compiler, instr: RegInstr) void {
        self.spillCallerSaved();
        // System V: RDI=instance, RSI=pages
        self.emitLoadInstPtr(.rdi);
        const pages_reg = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, .rsi, pages_reg);
        // CALL jitMemGrow
        self.emitLoadImm64(SCRATCH, self.mem_grow_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);
        // Result in EAX (u32): old_pages or 0xFFFFFFFF
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
        self.spillCallerSaved();
        // System V: RDI=instance, ESI=dst, EDX=val, ECX=n
        self.emitLoadInstPtr(.rdi);
        const dst_reg = self.getOrLoad(instr.rd, SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, .rsi, dst_reg);
        const val_reg = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, .rdx, val_reg);
        const n_reg = self.getOrLoad(instr.rs2(), SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, .rcx, n_reg);
        // CALL jitMemFill
        self.emitLoadImm64(SCRATCH, self.mem_fill_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);
        // Check error (EAX != 0 → OOB)
        Enc.testRegReg32(&self.code, self.alloc, .rax, .rax);
        self.emitCondError(.ne, 6); // OutOfBoundsMemoryAccess
        self.reloadCallerSaved();
        self.scratch_vreg = null;
    }

    /// Emit memory.copy via trampoline call.
    fn emitMemCopy(self: *Compiler, instr: RegInstr) void {
        self.spillCallerSaved();
        // System V: RDI=instance, ESI=dst, EDX=src, ECX=n
        self.emitLoadInstPtr(.rdi);
        const dst_reg = self.getOrLoad(instr.rd, SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, .rsi, dst_reg);
        const src_reg = self.getOrLoad(instr.rs1, SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, .rdx, src_reg);
        const n_reg = self.getOrLoad(instr.rs2(), SCRATCH);
        Enc.movRegReg32(&self.code, self.alloc, .rcx, n_reg);
        // CALL jitMemCopy
        self.emitLoadImm64(SCRATCH, self.mem_copy_addr);
        Enc.callReg(&self.code, self.alloc, SCRATCH);
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
    fn loadFpToXmm(self: *Compiler, xmm: u4, vreg: u8) void {
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
    fn storeFpFromXmm(self: *Compiler, vreg: u8, xmm: u4) void {
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
            .oob_exit_offset = self.shared_exit_offset,
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

        // Pre-scan: find branch targets for fusion safety
        const branch_targets = self.scanBranchTargets(ir) orelse return null;
        defer self.alloc.free(branch_targets);
        self.ir_slice = ir;
        self.branch_targets_slice = branch_targets;

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

        self.emitErrorStubs();
        self.patchBranches() catch return null;

        return self.finalize();
    }

    /// Compile a single RegInstr. Returns false if unsupported (bail out).
    fn compileInstr(self: *Compiler, instr: RegInstr, ir: []const RegInstr, pc: *u32) bool {
        switch (instr.op) {
            // --- Register ops ---
            regalloc_mod.OP_MOV => {
                // Load directly into destination register to avoid SCRATCH → phys MOV
                const d = vregToPhys(instr.rd) orelse SCRATCH;
                const src = self.getOrLoad(instr.rs1, d);
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
                self.emitEpilogue(if (self.result_count > 0) instr.rd else null);
            },
            regalloc_mod.OP_RETURN_VOID => self.emitEpilogue(null),
            regalloc_mod.OP_NOP, regalloc_mod.OP_BLOCK_END, regalloc_mod.OP_DELETED => {},

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
        const rs2: u8 = @truncate(instr.operand);
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
    fn tryFuseBranch(self: *Compiler, cc: Cond, rd: u8, pc: *u32) ?bool {
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
    fn emitCmpResult(self: *Compiler, cc: Cond, rd: u8, pc: *u32) bool {
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
        const rs2: u8 = @truncate(instr.operand);
        const r1 = self.getOrLoad(instr.rs1, SCRATCH);
        const r2 = self.getOrLoad(rs2, SCRATCH2);
        Enc.cmpRegReg32(&self.code, self.alloc, r1, r2);
        return self.emitCmpResult(cc, instr.rd, pc);
    }

    fn emitCmp64(self: *Compiler, instr: RegInstr, cc: Cond, pc: *u32) bool {
        const rs2: u8 = @truncate(instr.operand);
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
        const rs2: u8 = @truncate(instr.operand);
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
        const rs2: u8 = @truncate(instr.operand);
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
    use_guard_pages: bool,
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false) orelse
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false) orelse
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 1, 1, null, 0, false) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // count(10) = 10
    var regs: [8]u64 = .{ 10, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(u64, 0), jit_code.entry(&regs, undefined, undefined));
    try testing.expectEqual(@as(u64, 10), regs[0]);
}

test "x86_64 compile and execute memory load" {
    if (builtin.cpu.arch != .x86_64) return;

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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 1, 1, null, 0, false) orelse
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
    const mem_idx = try store.addMemory(1, null, 65536, false);
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false) orelse
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
        .{ .op = 0xA0, .rd = 0, .rs1 = 0, .operand = 1 }, // f64.add r0 = r0 + r1
        .{ .op = regalloc_mod.OP_RETURN, .rd = 0, .rs1 = 0, .operand = 0 },
    };
    var reg_func = RegFunc{
        .code = &code,
        .pool64 = &.{},
        .reg_count = 2,
        .local_count = 2,
        .alloc = alloc,
    };

    const jit_code = compileFunction(alloc, &reg_func, &.{}, 0, 2, 1, null, 0, false) orelse
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
        // [0] i32.eq r2, r0, r1  (rs2 = operand low byte)
        .{ .op = 0x46, .rd = 2, .rs1 = 0, .operand = 1 },
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
        .{ .op = 0x46, .rd = 2, .rs1 = 0, .operand = 1 },
        .{ .op = regalloc_mod.OP_BR_IF, .rd = 3, .rs1 = 0, .operand = 4 },
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 99 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
        .{ .op = regalloc_mod.OP_CONST32, .rd = 1, .rs1 = 0, .operand = 42 },
        .{ .op = regalloc_mod.OP_RETURN, .rd = 1, .rs1 = 0, .operand = 0 },
    };

    var reg_func = RegFunc{ .code = &code, .pool64 = &.{}, .reg_count = 4, .local_count = 2, .alloc = alloc };
    var reg_func_nofuse = RegFunc{ .code = &code_nofuse, .pool64 = &.{}, .reg_count = 4, .local_count = 2, .alloc = alloc };

    const jit_fused = compileFunction(alloc, &reg_func, &.{}, 0, 0, 1, null, 0, false) orelse
        return error.CompilationFailed;
    defer jit_fused.deinit(alloc);

    const jit_nofuse = compileFunction(alloc, &reg_func_nofuse, &.{}, 0, 0, 1, null, 0, false) orelse
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
