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
//!   x22-x28: virtual r0-r6 (callee-saved)
//!   x9-x15:  virtual r7-r13 (caller-saved)
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

/// JIT-compiled function pointer type.
/// Args: regs_ptr, vm_ptr, instance_ptr.
/// Returns: 0 on success, non-zero WasmError ordinal on failure.
pub const JitFn = *const fn ([*]u64, *anyopaque, *anyopaque) callconv(.c) u64;

/// Compiled native code for a single function.
pub const JitCode = struct {
    buf: []align(std.heap.page_size_min) u8,
    entry: JitFn,

    pub fn deinit(self: *JitCode, alloc: Allocator) void {
        std.posix.munmap(self.buf);
        alloc.destroy(self);
    }
};

/// Hot function call threshold — JIT after this many calls.
pub const HOT_THRESHOLD: u32 = 100;

/// Maximum virtual registers mappable to physical registers.
const MAX_PHYS_REGS: u8 = 14; // 7 callee-saved + 7 caller-saved

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
        hs = 0b0010, // unsigned >=
        lo = 0b0011, // unsigned <
        hi = 0b1000, // unsigned >
        ls = 0b1001, // unsigned <=
        ge = 0b1010, // signed >=
        lt = 0b1011, // signed <
        gt = 0b1100, // signed >
        le = 0b1101, // signed <=

        fn invert(self: Cond) Cond {
            return @enumFromInt(@intFromEnum(self) ^ 1);
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
};

// ================================================================
// Virtual register → ARM64 physical register mapping
// ================================================================

/// Map virtual register index to ARM64 physical register.
/// r0-r6 → x22-x28 (callee-saved)
/// r7-r13 → x9-x15 (caller-saved)
/// r14+ → memory (via regs_ptr at x19)
fn vregToPhys(vreg: u8) ?u5 {
    if (vreg <= 6) return @intCast(vreg + 22); // x22-x28
    if (vreg <= 13) return @intCast(vreg - 7 + 9); // x9-x15
    return null; // spill to memory
}

/// Scratch register for temporaries.
const SCRATCH: u5 = 8; // x8
/// Second scratch for two-operand memory ops.
const SCRATCH2: u5 = 16; // x16 (IP0)
/// Registers saved in prologue.
const REGS_PTR: u5 = 19; // x19
const VM_PTR: u5 = 20; // x20
const INST_PTR: u5 = 21; // x21

// ================================================================
// JIT Compiler
// ================================================================

pub const Compiler = struct {
    code: std.ArrayList(u32),
    /// Map from RegInstr PC → ARM64 instruction index.
    pc_map: std.ArrayList(u32),
    /// Forward branch patches: (arm64_idx, target_reg_pc).
    patches: std.ArrayList(Patch),
    alloc: Allocator,
    reg_count: u16,
    local_count: u16,
    trampoline_addr: u64,
    pool64: []const u64,

    const Patch = struct {
        arm64_idx: u32, // index in code array
        target_pc: u32, // target RegInstr PC
        kind: PatchKind,
    };

    const PatchKind = enum { b, b_cond, cbz32, cbnz32 };

    pub fn init(alloc: Allocator) Compiler {
        return .{
            .code = .empty,
            .pc_map = .empty,
            .patches = .empty,
            .alloc = alloc,
            .reg_count = 0,
            .local_count = 0,
            .trampoline_addr = 0,
            .pool64 = &.{},
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.code.deinit(self.alloc);
        self.pc_map.deinit(self.alloc);
        self.patches.deinit(self.alloc);
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
        } else {
            self.emit(a64.str64(src, REGS_PTR, @as(u16, vreg) * 8));
        }
    }

    /// Get the physical register for a vreg, or load to scratch.
    fn getOrLoad(self: *Compiler, vreg: u8, scratch: u5) u5 {
        if (vregToPhys(vreg)) |phys| return phys;
        self.emit(a64.ldr64(scratch, REGS_PTR, @as(u16, vreg) * 8));
        return scratch;
    }

    /// Store all live virtual regs to memory (before function calls).
    fn spillAll(self: *Compiler) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        for (0..max) |i| {
            const vreg: u8 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.str64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
    }

    /// Reload all virtual regs from memory (after function calls).
    fn reloadAll(self: *Compiler) void {
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        for (0..max) |i| {
            const vreg: u8 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
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

        // Save args to callee-saved regs
        // x0 = regs, x1 = vm, x2 = instance
        self.emit(a64.mov64(REGS_PTR, 0)); // x19 = regs
        self.emit(a64.mov64(VM_PTR, 1)); // x20 = vm
        self.emit(a64.mov64(INST_PTR, 2)); // x21 = instance

        // Load virtual registers from regs[] into physical registers
        const max: u8 = @intCast(@min(self.reg_count, MAX_PHYS_REGS));
        for (0..max) |i| {
            const vreg: u8 = @intCast(i);
            if (vregToPhys(vreg)) |phys| {
                self.emit(a64.ldr64(phys, REGS_PTR, @as(u16, vreg) * 8));
            }
        }
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

    // --- Main compilation ---

    pub fn compile(
        self: *Compiler,
        reg_func: *RegFunc,
        pool64: []const u64,
        trampoline_addr: u64,
    ) ?*JitCode {
        if (builtin.cpu.arch != .aarch64) return null;

        self.reg_count = reg_func.reg_count;
        self.local_count = reg_func.local_count;
        self.trampoline_addr = trampoline_addr;
        self.pool64 = pool64;

        self.emitPrologue();

        const ir = reg_func.code;
        var pc: u32 = 0;

        // Pre-allocate pc_map indexed by RegInstr PC (not loop iteration)
        self.pc_map.appendNTimes(self.alloc, 0, ir.len + 1) catch return null;

        while (pc < ir.len) {
            // Record ARM64 code offset at actual RegInstr PC
            self.pc_map.items[pc] = self.currentIdx();
            const instr = ir[pc];
            pc += 1;

            if (!self.compileInstr(instr, ir, &pc)) return null;
        }
        // Trailing entry for end-of-function
        self.pc_map.items[ir.len] = self.currentIdx();

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
                const val = instr.operand;
                if (val <= 0xFFFF) {
                    self.emit(a64.movz64(SCRATCH, @truncate(val), 0));
                } else {
                    self.emit(a64.movz64(SCRATCH, @truncate(val), 0));
                    self.emit(a64.movk64(SCRATCH, @truncate(val >> 16), 1));
                }
                self.storeVreg(instr.rd, SCRATCH);
            },
            regalloc_mod.OP_CONST64 => {
                const val = self.pool64[instr.operand];
                const instrs = a64.loadImm64(SCRATCH, val);
                for (instrs) |inst| self.emit(inst);
                self.storeVreg(instr.rd, SCRATCH);
            },

            // --- Control flow ---
            regalloc_mod.OP_BR => {
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
                self.emitEpilogue(instr.rd);
            },
            regalloc_mod.OP_RETURN_VOID => {
                self.emitEpilogue(null);
            },

            // --- Function call ---
            regalloc_mod.OP_CALL => {
                const func_idx = instr.operand;
                const data = ir[pc.*];
                pc.* += 1;
                // Skip second data word if present
                const has_data2 = (pc.* < ir.len and ir[pc.*].op == regalloc_mod.OP_NOP);
                var data2: RegInstr = undefined;
                if (has_data2) {
                    data2 = ir[pc.*];
                    pc.* += 1;
                }
                self.emitCall(instr.rd, func_idx, data, if (has_data2) data2 else null);
            },
            regalloc_mod.OP_NOP => {}, // data word, already consumed
            regalloc_mod.OP_BLOCK_END => {}, // no-op in JIT
            regalloc_mod.OP_DELETED => {}, // no-op

            // --- i32 arithmetic ---
            0x6A => self.emitBinop32(.add, instr),
            0x6B => self.emitBinop32(.sub, instr),
            0x6C => self.emitBinop32(.mul, instr),
            0x71 => self.emitBinop32(.@"and", instr),
            0x72 => self.emitBinop32(.@"or", instr),
            0x73 => self.emitBinop32(.xor, instr),
            0x74 => self.emitBinop32(.shl, instr),
            0x75 => self.emitBinop32(.shr_s, instr),
            0x76 => self.emitBinop32(.shr_u, instr),

            // --- i32 comparison ---
            0x45 => { // i32.eqz
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.cmp32(src, 31)); // CMP Wn, WZR
                self.emit(a64.cset32(SCRATCH, .eq));
                self.storeVreg(instr.rd, SCRATCH);
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
            0x83 => self.emitBinop64(.@"and", instr),
            0x84 => self.emitBinop64(.@"or", instr),
            0x85 => self.emitBinop64(.xor, instr),
            0x86 => self.emitBinop64(.shl, instr),
            0x87 => self.emitBinop64(.shr_s, instr),
            0x88 => self.emitBinop64(.shr_u, instr),

            // --- i64 comparison ---
            0x50 => { // i64.eqz
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.cmpImm64(src, 0));
                self.emit(a64.cset64(SCRATCH, .eq));
                self.storeVreg(instr.rd, SCRATCH);
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
                self.emit(a64.uxtw(SCRATCH, src));
                self.storeVreg(instr.rd, SCRATCH);
            },
            0xAC => { // i64.extend_i32_s
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.sxtw(SCRATCH, src));
                self.storeVreg(instr.rd, SCRATCH);
            },
            0xAD => { // i64.extend_i32_u
                const src = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.uxtw(SCRATCH, src));
                self.storeVreg(instr.rd, SCRATCH);
            },

            // --- Fused immediate ops ---
            regalloc_mod.OP_ADDI32 => self.emitImmOp32(.add, instr),
            regalloc_mod.OP_SUBI32 => self.emitImmOp32(.sub, instr),
            regalloc_mod.OP_MULI32 => {
                // MUL doesn't have immediate form; load imm to scratch
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.movz32(SCRATCH2, @truncate(instr.operand), 0));
                if (instr.operand > 0xFFFF) {
                    self.emit(a64.movk64(SCRATCH2, @truncate(instr.operand >> 16), 1));
                }
                self.emit(a64.mul32(SCRATCH, rs1, SCRATCH2));
                self.storeVreg(instr.rd, SCRATCH);
            },
            regalloc_mod.OP_ANDI32, regalloc_mod.OP_ORI32, regalloc_mod.OP_XORI32 => {
                // No immediate form for AND/OR/XOR in our encoding; use scratch
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.movz32(SCRATCH2, @truncate(instr.operand), 0));
                if (instr.operand > 0xFFFF) {
                    self.emit(a64.movk64(SCRATCH2, @truncate(instr.operand >> 16), 1));
                }
                const enc: u32 = switch (instr.op) {
                    regalloc_mod.OP_ANDI32 => a64.and32(SCRATCH, rs1, SCRATCH2),
                    regalloc_mod.OP_ORI32 => a64.orr32(SCRATCH, rs1, SCRATCH2),
                    regalloc_mod.OP_XORI32 => a64.eor32(SCRATCH, rs1, SCRATCH2),
                    else => unreachable,
                };
                self.emit(enc);
                self.storeVreg(instr.rd, SCRATCH);
            },
            regalloc_mod.OP_SHLI32 => {
                const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
                self.emit(a64.movz32(SCRATCH2, @truncate(instr.operand), 0));
                self.emit(a64.lslv32(SCRATCH, rs1, SCRATCH2));
                self.storeVreg(instr.rd, SCRATCH);
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
                const cond_reg = self.getOrLoad(cond_idx, SCRATCH2);
                const val1 = self.getOrLoad(instr.rs1, SCRATCH);
                // Compare condition
                self.emit(a64.cmpImm32(cond_reg, 0));
                // CSEL rd, val1, val2, ne
                const val2_reg = self.getOrLoad(val2_idx, SCRATCH2);
                _ = val2_reg;
                _ = val1;
                // For simplicity, use branch-based select
                // TODO: use CSEL instruction
                self.emit(a64.nop()); // placeholder
            },

            // --- Drop ---
            0x1A => {}, // no-op

            // --- Unreachable ---
            0x00 => {
                self.emitErrorReturn(1); // Trap
            },

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
        const enc: u32 = switch (op) {
            .add => a64.add32(SCRATCH, rs1, rs2),
            .sub => a64.sub32(SCRATCH, rs1, rs2),
            .mul => a64.mul32(SCRATCH, rs1, rs2),
            .@"and" => a64.and32(SCRATCH, rs1, rs2),
            .@"or" => a64.orr32(SCRATCH, rs1, rs2),
            .xor => a64.eor32(SCRATCH, rs1, rs2),
            .shl => a64.lslv32(SCRATCH, rs1, rs2),
            .shr_s => a64.asrv32(SCRATCH, rs1, rs2),
            .shr_u => a64.lsrv32(SCRATCH, rs1, rs2),
        };
        self.emit(enc);
        self.storeVreg(instr.rd, SCRATCH);
    }

    const BinOp64 = enum { add, sub, mul, @"and", @"or", xor, shl, shr_s, shr_u };

    fn emitBinop64(self: *Compiler, op: BinOp64, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        const enc: u32 = switch (op) {
            .add => a64.add64(SCRATCH, rs1, rs2),
            .sub => a64.sub64(SCRATCH, rs1, rs2),
            .mul => a64.mul64(SCRATCH, rs1, rs2),
            .@"and" => a64.and64(SCRATCH, rs1, rs2),
            .@"or" => a64.orr64(SCRATCH, rs1, rs2),
            .xor => a64.eor64(SCRATCH, rs1, rs2),
            .shl => a64.lslv64(SCRATCH, rs1, rs2),
            .shr_s => a64.asrv64(SCRATCH, rs1, rs2),
            .shr_u => a64.lsrv64(SCRATCH, rs1, rs2),
        };
        self.emit(enc);
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitCmp32(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        self.emit(a64.cmp32(rs1, rs2));
        self.emit(a64.cset32(SCRATCH, cond));
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitCmp64(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const rs2 = self.getOrLoad(instr.rs2(), SCRATCH2);
        self.emit(a64.cmp64(rs1, rs2));
        self.emit(a64.cset64(SCRATCH, cond));
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitCmpImm32(self: *Compiler, cond: a64.Cond, instr: RegInstr) void {
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
        self.emit(a64.cset32(SCRATCH, cond));
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitImmOp32(self: *Compiler, op: enum { add, sub }, instr: RegInstr) void {
        const rs1 = self.getOrLoad(instr.rs1, SCRATCH);
        const imm = instr.operand;
        if (imm <= 0xFFF) {
            const enc: u32 = switch (op) {
                .add => a64.addImm32(SCRATCH, rs1, @intCast(imm)),
                .sub => a64.subImm32(SCRATCH, rs1, @intCast(imm)),
            };
            self.emit(enc);
        } else {
            self.emit(a64.movz32(SCRATCH2, @truncate(imm), 0));
            if (imm > 0xFFFF)
                self.emit(a64.movk64(SCRATCH2, @truncate(imm >> 16), 1));
            const enc: u32 = switch (op) {
                .add => a64.add32(SCRATCH, rs1, SCRATCH2),
                .sub => a64.sub32(SCRATCH, rs1, SCRATCH2),
            };
            self.emit(enc);
        }
        self.storeVreg(instr.rd, SCRATCH);
    }

    fn emitCall(self: *Compiler, rd: u8, func_idx: u32, data: RegInstr, data2: ?RegInstr) void {
        // 1. Spill all virtual regs to memory
        self.spillAll();

        // 2. Set up trampoline args (C calling convention):
        //    x0 = vm, x1 = instance, x2 = regs, w3 = func_idx,
        //    w4 = rd (result reg), x5 = data_word, x6 = data2_word
        self.emit(a64.mov64(0, VM_PTR));
        self.emit(a64.mov64(1, INST_PTR));
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

        // 4. Check error (x0 != 0 → error)
        // Store result to regs[rd] is done by the trampoline
        // On error, propagate: restore callee-saved and return error code
        const error_branch = self.currentIdx();
        self.emit(a64.cbnz64(0, 0)); // placeholder — branch to error handler

        // 5. Reload all virtual regs from memory
        self.reloadAll();

        // Emit error handler (out-of-line, after normal flow)
        // We'll use a simple approach: the error handler is right here,
        // and normal flow jumps over it.
        const skip_idx = self.currentIdx();
        self.emit(a64.b(0)); // placeholder — skip error handler

        // Error handler: restore and return error code from x0
        const error_target = self.currentIdx();
        // Patch the cbnz to jump here
        const error_offset: i19 = @intCast(@as(i32, @intCast(error_target)) - @as(i32, @intCast(error_branch)));
        self.code.items[error_branch] = a64.cbnz64(0, error_offset);
        // Restore callee-saved regs and return with error in x0
        self.emit(a64.ldpPost(27, 28, 31, 2));
        self.emit(a64.ldpPost(25, 26, 31, 2));
        self.emit(a64.ldpPost(23, 24, 31, 2));
        self.emit(a64.ldpPost(21, 22, 31, 2));
        self.emit(a64.ldpPost(19, 20, 31, 2));
        self.emit(a64.ldpPost(29, 30, 31, 2));
        // x0 already has error code from trampoline
        self.emit(a64.ret_());

        // Patch skip branch
        const skip_target = self.currentIdx();
        const skip_offset: i26 = @intCast(@as(i32, @intCast(skip_target)) - @as(i32, @intCast(skip_idx)));
        self.code.items[skip_idx] = a64.b(skip_offset);
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

    var call_results: [1]u64 = .{0};
    vm.callFunction(instance, func_ptr, call_args[0..n_args], call_results[0..@min(n_results, 1)]) catch |e| {
        return wasmErrorToCode(e);
    };

    if (n_results > 0) {
        regs[result_reg] = call_results[0];
    }
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
        else => 1, // generic trap
    };
}

// ================================================================
// Public API
// ================================================================

/// Attempt to JIT-compile a register IR function.
/// Returns null if compilation fails (unsupported opcodes, etc.).
pub fn compileFunction(
    alloc: Allocator,
    reg_func: *RegFunc,
    pool64: []const u64,
) ?*JitCode {
    if (builtin.cpu.arch != .aarch64) return null;

    const trampoline_addr = @intFromPtr(&jitCallTrampoline);

    var compiler = Compiler.init(alloc);
    defer compiler.deinit();

    return compiler.compile(reg_func, pool64, trampoline_addr);
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

    // r0-r6 → x22-x28
    try testing.expectEqual(@as(u5, 22), vregToPhys(0).?);
    try testing.expectEqual(@as(u5, 28), vregToPhys(6).?);
    // r7-r13 → x9-x15
    try testing.expectEqual(@as(u5, 9), vregToPhys(7).?);
    try testing.expectEqual(@as(u5, 15), vregToPhys(13).?);
    // r14+ → null (spill)
    try testing.expectEqual(@as(?u5, null), vregToPhys(14));
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // Execute: regs[0] should become 42
    var regs: [4]u64 = .{ 0, 0, 0, 0 };
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    var regs: [4]u64 = .{ 10, 32, 0, 0 };
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

    const jit_code = compileFunction(alloc, &reg_func, &.{}) orelse
        return error.CompilationFailed;
    defer jit_code.deinit(alloc);

    // n=0: 0 <= 1 is true → return 100
    {
        var regs: [4]u64 = .{ 0, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 100), regs[0]);
    }

    // n=1: 1 <= 1 is true → return 100
    {
        var regs: [4]u64 = .{ 1, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 100), regs[0]);
    }

    // n=10: 10 <= 1 is false → return 200
    {
        var regs: [4]u64 = .{ 10, 0, 0, 0 };
        const result = jit_code.entry(&regs, undefined, undefined);
        try testing.expectEqual(@as(u64, 0), result);
        try testing.expectEqual(@as(u64, 200), regs[0]);
    }
}

