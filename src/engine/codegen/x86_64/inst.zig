//! x86_64 instruction encoder (§9.7 / 7.6 chunk b).
//!
//! Mirrors the role of `arm64/inst.zig` but x86_64 instructions
//! are variable-width (1–15 bytes) so encoder fns return an
//! `EncodedInsn` value (max-sized stack buffer + length) instead
//! of a fixed `u32`. The caller writes `enc.slice()` to its
//! `*std.ArrayList(u8)` buffer — same "pure encoder + caller-
//! owned buffer" shape as arm64, just with a slice instead of a
//! u32 word.
//!
//! Phase 7.6 chunk-b scope: foundation primitives + a handful of
//! canonical ops to prove the encoding model end-to-end:
//!
//!   - REX / ModR/M / SIB byte builders (inline helpers).
//!   - `EncodedInsn` value type for variable-width emission.
//!   - reg-reg ALU (mov / add / sub) for 32-bit and 64-bit
//!     operand sizes.
//!   - control flow no-arg ops (ret, nop).
//!
//! Subsequent chunks layer on:
//!   - Memory ops (load / store with disp / SIB).
//!   - Immediate operands (mov-imm, add-imm, etc.).
//!   - Branch / call (rel8 / rel32 disps + label fixup model).
//!   - FP / SIMD via XMM (sub-h equivalents).
//!
//! Bit patterns from AMD64 Architecture Programmer's Manual
//! Vol. 3 (Pub. 24594) and Intel® 64 Vol. 2 (Order 325383).
//!
//! Zone 2 (`src/engine/codegen/x86_64/`) — must NOT import
//! `src/engine/codegen/arm64/` per ROADMAP §A3 (Zone-2 inter-arch
//! isolation).

const std = @import("std");

const reg_class = @import("reg_class.zig");

pub const Gpr = reg_class.Gpr;
pub const Xmm = reg_class.Xmm;
pub const Width = reg_class.Width;

/// Maximum encoded length of a single x86_64 instruction. Per
/// the AMD64 manual §1.2.5 a single instruction is bounded at
/// 15 bytes (legacy + REX + opcode + ModR/M + SIB + disp +
/// immediate). The foundation ops in this chunk top out at 4
/// bytes (REX + opcode + ModR/M); the bound is stated for the
/// later chunks that add immediates and SIB.
pub const max_insn_bytes: u8 = 15;

/// One encoded instruction. Caller appends `slice()` to its
/// output buffer:
///
///   const enc = inst.encMovRR(.q, .rax, .rcx);
///   try buf.appendSlice(allocator, enc.slice());
///
/// Stack-allocated; no allocation needed.
pub const EncodedInsn = struct {
    bytes: [max_insn_bytes]u8 = @splat(0),
    len: u8 = 0,

    pub fn slice(self: *const EncodedInsn) []const u8 {
        return self.bytes[0..self.len];
    }

    fn push(self: *EncodedInsn, b: u8) void {
        self.bytes[self.len] = b;
        self.len += 1;
    }
};

// ============================================================
// Prefix / ModR/M / SIB byte builders
// ============================================================

/// Encode the REX prefix byte. The four payload bits:
///   - W (bit 3): operand size — 1 = 64-bit, 0 = default.
///   - R (bit 2): high-bit extension of ModR/M.reg.
///   - X (bit 1): high-bit extension of SIB.index.
///   - B (bit 0): high-bit extension of ModR/M.rm OR SIB.base
///                OR opcode-embedded reg.
/// The fixed top half is `0100` per AMD64 Vol.3 §1.2.7.
inline fn encodeRex(w: bool, r: u1, x: u1, b: u1) u8 {
    return 0x40 |
        (@as(u8, @intFromBool(w)) << 3) |
        (@as(u8, r) << 2) |
        (@as(u8, x) << 1) |
        @as(u8, b);
}

/// Encode the ModR/M byte. `mod` selects addressing mode (3 =
/// register-direct, 0/1/2 = memory with 0/8/32-bit disp), `reg`
/// is the low 3 bits of the source/extension reg, `rm` is the
/// low 3 bits of the destination/base.
inline fn encodeModrm(mod: u2, reg: u3, rm: u3) u8 {
    return (@as(u8, mod) << 6) | (@as(u8, reg) << 3) | @as(u8, rm);
}

/// Encode the SIB byte. `scale` is 0/1/2/3 (1/2/4/8x), `index`
/// is the low 3 bits of the index reg, `base` is the low 3 bits
/// of the base reg. Only used when ModR/M.rm == 0b100 in memory
/// addressing modes.
inline fn encodeSib(scale: u2, index: u3, base: u3) u8 {
    return (@as(u8, scale) << 6) | (@as(u8, index) << 3) | @as(u8, base);
}

// ============================================================
// Foundation ops — reg-reg ALU (32-bit + 64-bit) + control flow
// ============================================================

/// Decide whether REX must be emitted for a 2-operand reg/reg
/// instruction, given the operand size. REX.W is set for 64-bit;
/// REX.R / REX.B are set when reg / rm are R8..R15.
///
/// For 32-bit ops we only emit REX when at least one extension
/// bit (R or B) is set — the 32-bit encoding is the default and
/// the prefix is otherwise redundant. For 64-bit ops REX is
/// always emitted (to set the W bit).
inline fn rexForRR(size: Width, reg: Gpr, rm: Gpr) ?u8 {
    const w = size == .q;
    const r = reg.extBit();
    const b = rm.extBit();
    if (!w and r == 0 and b == 0) return null;
    return encodeRex(w, r, 0, b);
}

/// `MOV r/m, r` (opcode 0x89) — copy `src` into `dst`. Width
/// `.d` = 32-bit (zero-extends to 64), `.q` = 64-bit.
///
/// Encoding (no SIB, mod=11 register-direct):
///   [REX?] 89 ModR/M
///   ModR/M.mod = 0b11, ModR/M.reg = src.low3, ModR/M.rm = dst.low3
pub fn encMovRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x89);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `ADD r/m, r` (opcode 0x01) — `dst += src`.
pub fn encAddRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x01);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `SUB r/m, r` (opcode 0x29) — `dst -= src`.
pub fn encSubRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x29);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `AND r/m, r` (opcode 0x21) — `dst &= src`.
pub fn encAndRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x21);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `OR r/m, r` (opcode 0x09) — `dst |= src`.
pub fn encOrRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x09);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `XOR r/m, r` (opcode 0x31) — `dst ^= src`.
pub fn encXorRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x31);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// EFLAGS condition code per AMD64 Vol.3 §3.1.4 (J<cc> /
/// SET<cc> / CMOV<cc> share the same 4-bit cc field). The
/// numeric value is the cc encoding (e.g. SETE = 0x0F 0x94 →
/// 0x90 + 4).
pub const Cond = enum(u4) {
    o = 0x0, no = 0x1, b = 0x2, ae = 0x3,
    e = 0x4, ne = 0x5, be = 0x6, a = 0x7,
    s = 0x8, ns = 0x9, p = 0xA, np = 0xB,
    l = 0xC, ge = 0xD, le = 0xE, g = 0xF,
};

/// `CMP r/m, r` (opcode 0x39) — sets EFLAGS based on `dst -
/// src` (no result stored). Same operand-role + REX layout as
/// ADD/SUB.
pub fn encCmpRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x39);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// Shift / rotate variants for the 0xD3 r/m, CL family. The
/// numeric value matches the ModR/M.reg field. AMD64 Vol.3
/// Table 4.5: `D3 /4` SHL, `/5` SHR, `/7` SAR, `/0` ROL, `/1`
/// ROR. Wasm doesn't use the carry-rotate (RCL/RCR = /2 //3) or
/// the SAL alias (= SHL = /6).
pub const ShiftKind = enum(u3) {
    rol = 0,
    ror = 1,
    shl = 4,
    shr = 5,
    sar = 7,
};

/// `<shift> r/m, CL` (opcode 0xD3 + ModR/M.reg = kind) —
/// shift / rotate the destination by the count in CL. Width
/// `.d` shifts the low 32 bits (zero-extends to 64); `.q`
/// shifts all 64 bits. Caller is responsible for moving the
/// shift count into ECX/RCX before this instruction.
///
/// **Caller invariant**: dst should not be RCX (the count
/// register). The emit-side handler checks this and surfaces
/// `UnsupportedOp` rather than emitting a self-clobbering
/// sequence.
pub fn encShiftRCl(size: Width, kind: ShiftKind, dst: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    // REX.R is unused (kind sits in ModR/M.reg, all kinds < 8).
    // Pass .rax as a no-op for the reg-position arg of rexForRR
    // so REX.R = 0 and only REX.W + REX.B contribute.
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0xD3);
    enc.push(encodeModrm(0b11, @intFromEnum(kind), dst.low3()));
    return enc;
}

/// `TEST r/m, r` (opcode 0x85) — sets EFLAGS based on bitwise
/// AND of `dst` and `src` (no result stored). Same operand-role
/// + REX layout as CMP. Used by Wasm `eqz` as `TEST x, x` →
/// ZF=1 iff x==0.
pub fn encTestRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, src, dst)) |rex| enc.push(rex);
    enc.push(0x85);
    enc.push(encodeModrm(0b11, src.low3(), dst.low3()));
    return enc;
}

/// `SETcc r/m8` (2-byte opcode 0x0F 0x90+cc) — write 0 or 1 to
/// the low byte of `dst` based on the EFLAGS condition. ModR/M:
/// mod=11, reg=0 (always for SETcc), rm = dst.low3.
///
/// **REX is always emitted.** For R8..R15 the REX.B bit is
/// needed; for RBX/RBP/RSI/RDI any REX (including 0x40) is
/// required to access the low-byte form (BL/BPL/SIL/DIL) rather
/// than the high-byte aliases (BH/CH/DH/AH) which clash in
/// 64-bit mode.
pub fn encSetccR(cc: Cond, dst: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(false, 0, 0, dst.extBit()));
    enc.push(0x0F);
    enc.push(0x90 | @as(u8, @intFromEnum(cc)));
    enc.push(encodeModrm(0b11, 0, dst.low3()));
    return enc;
}

/// `MOVZX r32, r/m8` (2-byte opcode 0x0F 0xB6 /r) — zero-extend
/// the low byte of `src` into the 32-bit form of `dst` (which
/// implicitly zero-extends to 64 bits). dst occupies ModR/M.reg,
/// src occupies r/m (same role inversion as IMUL).
///
/// **REX always emitted** for the same low-byte addressability
/// reason as SETcc.
pub fn encMovzxR32R8(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    enc.push(0x0F);
    enc.push(0xB6);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `CALL rel32` (opcode 0xE8) — direct call with 32-bit
/// signed displacement from the byte AFTER the disp32 (i.e.
/// the next instruction). Used by `emitCall` as a placeholder
/// (disp=0); the post-emit linker patches the disp via
/// `patchRel32` once function offsets are known.
pub fn encCallRel32(disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xE8);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `CALL r/m64` (opcode 0xFF /2) — indirect call through a
/// 64-bit register. CALL is implicitly 64-bit on x86_64; REX.W
/// is NOT required. REX.B is set if `target` is R8..R15. Used
/// by `emitCallIndirect` after the funcptr is loaded into a
/// scratch register.
pub fn encCallReg(target: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (target.extBit() != 0) {
        enc.push(encodeRex(false, 0, 0, target.extBit()));
    }
    enc.push(0xFF);
    enc.push(encodeModrm(0b11, 2, target.low3())); // /2 = CALL
    return enc;
}

/// `CMP r/m32, imm32` (opcode 0x81 /7) — sign-extended 32-bit
/// compare. Used by `emitCallIndirect`'s sig check vs the
/// call-site's expected typeidx (a u32 module-type index).
pub fn encCmpRImm32(dst: Gpr, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(.d, .rax, dst)) |rex| enc.push(rex);
    enc.push(0x81);
    enc.push(encodeModrm(0b11, 7, dst.low3())); // /7 = CMP
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}

/// `MOV r32, [base + idx*4]` (opcode 0x8B with SIB scale=2 →
/// ×4). 32-bit load with 4-scaled index; used by
/// `emitCallIndirect` to read `typeidx_base[idx]` (each entry
/// is a u32). mod=00 + rm=4 signals SIB-byte addressing
/// (no displacement).
pub fn encMovR32FromBaseIdxLsl2(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x8B);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b10, idx.low3(), base.low3())); // scale = ×4
    return enc;
}

/// `MOV r64, [base + idx*8]` (REX.W + opcode 0x8B with SIB
/// scale=3 → ×8). 64-bit load with 8-scaled index; used by
/// `emitCallIndirect` to read `funcptr_base[idx]` (each entry
/// is a u64 native funcptr).
pub fn encMovR64FromBaseIdxLsl3(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), idx.extBit(), base.extBit()));
    enc.push(0x8B);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b11, idx.low3(), base.low3())); // scale = ×8
    return enc;
}

/// `MOVSXD r64, r/m32` (REX.W + 0x63 /r) — sign-extend 32-bit
/// source into 64-bit destination. Used by `i64.extend_i32_s`.
/// dst occupies ModR/M.reg, src occupies r/m (IMUL-style
/// operand inversion). REX.W is mandatory.
pub fn encMovsxdR64R32(dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, src.extBit()));
    enc.push(0x63);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// Common shape for the `F3 0F <opcode> /r` family used by
/// LZCNT / TZCNT / POPCNT. dst occupies ModR/M.reg and src is
/// in r/m (IMUL-style operand inversion). The mandatory 0xF3
/// prefix precedes any REX byte per AMD64 Vol.3 §1.2.6. `size`
/// = `.d` → r/m32; `.q` → r/m64 (REX.W set).
inline fn encF3_0F_RR(size: Width, opcode: u8, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (rexForRR(size, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

inline fn encF3_0F_R32R(opcode: u8, dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.d, opcode, dst, src);
}

/// `CMP r/m32, imm8` (opcode 0x83 /7) — sign-extended 8-bit
/// compare. Used by br_table case-checks. imm8 covers Wasm
/// case indices 0..127; larger requires the 0x81 /7 imm32
/// form (currently surfaces as UnsupportedOp at the
/// emit-handler level rather than here).
pub fn encCmpRImm8(size: Width, dst: Gpr, imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 7, dst.low3())); // /7 = CMP
    enc.push(@bitCast(imm));
    return enc;
}

/// `Jcc rel8` (opcode 0x70+cc) — short conditional jump with
/// 8-bit signed displacement (-128..127). 2 bytes total.
/// Used by br_table to skip a single 5-byte JMP rel32 (disp = +5).
pub fn encJccRel8(cc: Cond, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x70 | @as(u8, @intFromEnum(cc)));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOV r64, [base + disp32]` (opcode 0x8B with REX.W, mod=10).
/// Used to reload JitRuntime invariants from `[R15 + offset]`
/// per ADR-0026.
pub fn encMovR64FromMemDisp32(dst: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, base.extBit()));
    enc.push(0x8B);
    enc.push(encodeModrm(0b10, dst.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV r32, [base + disp32]` (opcode 0x8B without REX.W, mod=10).
/// 32-bit load with disp32; zero-extends to 64-bit dst. Used by
/// `global.get` (i32) to read `[globals_base + idx*8]` for the
/// low 4 bytes of the 8-byte Value slot.
pub fn encMovR32FromMemDisp32(dst: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1 or base.extBit() == 1) {
        enc.push(encodeRex(false, dst.extBit(), 0, base.extBit()));
    }
    enc.push(0x8B);
    enc.push(encodeModrm(0b10, dst.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV [base + disp32], r32` (opcode 0x89 without REX.W, mod=10).
/// 32-bit store with disp32. Used by `global.set` (i32) to write
/// `[globals_base + idx*8]` for the low 4 bytes of the 8-byte
/// Value slot. The upper 4 bytes are left untouched (acceptable
/// for i32-typed globals because the slot is zero-initialised at
/// module load).
pub fn encStoreR32MemDisp32(src: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1 or base.extBit() == 1) {
        enc.push(encodeRex(false, src.extBit(), 0, base.extBit()));
    }
    enc.push(0x89);
    enc.push(encodeModrm(0b10, src.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `CMP r64, [base + disp32]` (opcode 0x3B with REX.W, mod=10).
/// Used by memory bounds check to compare eff_addr against
/// `[R15 + mem_limit_off]`.
pub fn encCmpR64MemDisp32(reg: Gpr, base: Gpr, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, reg.extBit(), 0, base.extBit()));
    enc.push(0x3B);
    enc.push(encodeModrm(0b10, reg.low3(), base.low3()));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV r32, [base + idx]` (opcode 0x8B with SIB, scale=1).
/// Used by memory loads to read the actual word from
/// `[vm_base + eff_addr]`. mod=00 + rm=4 signals SIB-byte
/// addressing (no disp).
pub fn encMovR32FromBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x8B);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOV [base + idx], r32` (opcode 0x89 with SIB, scale=1).
/// 32-bit store; ModR/M.reg = source register. Mirror of
/// `encMovR32FromBaseIdx` for the store direction (i32.store).
pub fn encStoreR32MemBaseIdx(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = src.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x89);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOV [base + idx], r16` (operand-size prefix 0x66 + opcode
/// 0x89 with SIB). 16-bit store; used by i32.store16.
pub fn encStoreR16MemBaseIdx(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66); // operand-size override
    const r = src.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x89);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOV [base + idx], r8` (opcode 0x88 with SIB). 8-bit store;
/// used by i32.store8. **Always emits REX** so r8-r15 + the
/// SPL/BPL/SIL/DIL low-byte forms encode correctly (without REX,
/// reg=4..7 means AH/CH/DH/BH).
///
/// TODO(perf, optimisation-phase): when src ∈ {RAX, RCX, RDX, RBX}
/// (low-byte AL/CL/DL/BL accessible without REX), the prefix can
/// be omitted for a 1-byte saving per insn. Deferred until the
/// benchmark loop surfaces store8-dominant fixtures; until then
/// the unconditional REX keeps the encoder simple and uniform.
pub fn encStoreR8MemBaseIdx(src: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(false, src.extBit(), idx.extBit(), base.extBit())); // force REX
    enc.push(0x88);
    enc.push(encodeModrm(0b00, src.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVZX r32, byte ptr [base + idx]` (opcode 0x0F 0xB6 with
/// SIB). 8→32 zero-extend load; used by i32.load8_u.
pub fn encMovzxR32_8MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xB6);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSX r32, byte ptr [base + idx]` (opcode 0x0F 0xBE with
/// SIB). 8→32 sign-extend load; used by i32.load8_s.
pub fn encMovsxR32_8MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xBE);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVZX r32, word ptr [base + idx]` (opcode 0x0F 0xB7 with
/// SIB). 16→32 zero-extend load; used by i32.load16_u.
pub fn encMovzxR32_16MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xB7);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `MOVSX r32, word ptr [base + idx]` (opcode 0x0F 0xBF with
/// SIB). 16→32 sign-extend load; used by i32.load16_s.
pub fn encMovsxR32_16MemBaseIdx(dst: Gpr, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    const r = dst.extBit();
    const x = idx.extBit();
    const b = base.extBit();
    if (r != 0 or x != 0 or b != 0) {
        enc.push(encodeRex(false, r, x, b));
    }
    enc.push(0x0F);
    enc.push(0xBF);
    enc.push(encodeModrm(0b00, dst.low3(), 0b100));
    enc.push(encodeSib(0b00, idx.low3(), base.low3()));
    return enc;
}

/// `LEA r64, [base + disp8]` (opcode 0x8D /r with REX.W,
/// ModR/M mod=01, disp8). Used by spec-strict bounds check to
/// compute `ea + access_size` into a separate scratch reg without
/// mutating `base`. disp8 covers access_size ∈ {1..8}.
///
/// **Caller constraint**: `base` must NOT be RSP (low3=0b100). With
/// mod=01 + rm=0b100 the AMD64 ISA mandates a SIB byte; this encoder
/// emits no SIB and would produce a malformed instruction. RBP is
/// safe (mod=01 always carries disp8). Current call sites pass
/// `.rdx` only.
pub fn encLeaR64BaseDisp8(dst: Gpr, base: Gpr, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, dst.extBit(), 0, base.extBit()));
    enc.push(0x8D);
    enc.push(encodeModrm(0b01, dst.low3(), base.low3()));
    enc.push(@bitCast(disp));
    return enc;
}

/// `ADD r/m64, imm32` (opcode 0x81 /0 with REX.W). 4-byte
/// little-endian immediate. Used to fold the Wasm static offset
/// into the effective address before bounds check.
pub fn encAddR64Imm32(dst: Gpr, imm: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, dst.extBit()));
    enc.push(0x81);
    enc.push(encodeModrm(0b11, 0, dst.low3())); // /0 = ADD
    const u: u32 = @bitCast(imm);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `MOV DWORD PTR [base + disp32], imm32` (opcode 0xC7 /0).
/// Used by trap stub to set `JitRuntime.trap_flag = 1` per
/// ADR-0017 sub-7.5b-ii equivalent.
pub fn encStoreImm32MemDisp32(base: Gpr, disp: i32, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (base.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0xC7);
    enc.push(encodeModrm(0b10, 0, base.low3())); // /0 in reg field
    const ud: u32 = @bitCast(disp);
    enc.push(@truncate(ud));
    enc.push(@truncate(ud >> 8));
    enc.push(@truncate(ud >> 16));
    enc.push(@truncate(ud >> 24));
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}

/// `JMP rel32` (opcode 0xE9) — unconditional near jump with
/// 32-bit signed displacement. Disp is relative to the byte
/// AFTER the 5-byte instruction. Use `encJmpRel32(0)` as a
/// placeholder for forward jumps that patch later via
/// `patchRel32` once the target is known.
pub fn encJmpRel32(disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xE9);
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// `Jcc rel32` — conditional near jump (2-byte opcode 0x0F
/// 0x80+cc + 32-bit disp). 6 bytes total. Disp is relative to
/// the byte AFTER the instruction.
pub fn encJccRel32(cc: Cond, disp: i32) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x0F);
    enc.push(0x80 | @as(u8, @intFromEnum(cc)));
    const u: u32 = @bitCast(disp);
    enc.push(@truncate(u));
    enc.push(@truncate(u >> 8));
    enc.push(@truncate(u >> 16));
    enc.push(@truncate(u >> 24));
    return enc;
}

/// In-place patch the disp32 field of a JMP/Jcc rel32 placeholder.
/// `at` is the byte offset of the instruction's first byte
/// (0xE9 for JMP or 0x0F for Jcc). `disp` is computed by the
/// caller as `target - (at + insn_size)` where insn_size is 5
/// (JMP) or 6 (Jcc). Writes 4 bytes little-endian.
pub fn patchRel32(buf: []u8, at: usize, insn_size: u8, disp: i32) void {
    const off = at + insn_size - 4;
    const u: u32 = @bitCast(disp);
    buf[off + 0] = @truncate(u);
    buf[off + 1] = @truncate(u >> 8);
    buf[off + 2] = @truncate(u >> 16);
    buf[off + 3] = @truncate(u >> 24);
}

/// `LZCNT r32, r/m32` (F3 0F BD /r, BMI1) — count leading
/// zeros. Returns 32 if the input is 0; matches Wasm i32.clz
/// semantics exactly. Distinct from BSR (older op with
/// undefined behaviour at 0).
pub fn encLzcntR32(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_R32R(0xBD, dst, src);
}

/// `TZCNT r32, r/m32` (F3 0F BC /r, BMI1) — count trailing
/// zeros. Returns 32 if the input is 0; matches Wasm i32.ctz.
/// Distinct from BSF (older op with undefined behaviour at 0).
pub fn encTzcntR32(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_R32R(0xBC, dst, src);
}

/// `POPCNT r32, r/m32` (F3 0F B8 /r, POPCNT extension) —
/// population count (number of 1 bits). Matches Wasm i32.popcnt
/// directly.
pub fn encPopcntR32(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_R32R(0xB8, dst, src);
}

/// `LZCNT r64, r/m64` (F3 REX.W 0F BD /r) — 64-bit form for
/// Wasm i64.clz. Returns 64 for input 0.
pub fn encLzcntR64(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.q, 0xBD, dst, src);
}

/// `TZCNT r64, r/m64` (F3 REX.W 0F BC /r) — 64-bit form for
/// Wasm i64.ctz. Returns 64 for input 0.
pub fn encTzcntR64(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.q, 0xBC, dst, src);
}

/// `POPCNT r64, r/m64` (F3 REX.W 0F B8 /r) — 64-bit form for
/// Wasm i64.popcnt.
pub fn encPopcntR64(dst: Gpr, src: Gpr) EncodedInsn {
    return encF3_0F_RR(.q, 0xB8, dst, src);
}

/// `IMUL r, r/m` (2-byte opcode 0x0F 0xAF /r) — `dst *= src`,
/// signed/unsigned identical for the low N bits (Wasm i32.mul
/// doesn't distinguish signedness).
///
/// **Operand-role inversion vs ADD/SUB/AND/OR/XOR**: IMUL's
/// 2-operand form puts `dst` in the ModR/M.reg field and `src`
/// in r/m, opposite to ADD/SUB/etc. So REX.R extends `dst`
/// (not `src`) and REX.B extends `src` (not `dst`).
pub fn encImulRR(size: Width, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(0xAF);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `RET` near (opcode 0xC3) — pop return address from stack and
/// jump. Single byte; no operands.
pub fn encRet() EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xC3);
    return enc;
}

/// `NOP` (opcode 0x90) — single-byte no-op. Useful for
/// instruction-stream alignment (multi-byte NOPs land in a
/// later chunk).
pub fn encNop() EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x90);
    return enc;
}

/// `SUB RSP, imm8` (sign-extended) — opcode 0x83 /5 with REX.W.
/// 4-byte encoding. Caller responsibility to pass `imm` in
/// i8 range; larger frame extensions need the 6-byte imm32 form
/// (out of scope for the §9.7 / 7.7 skeleton — capped at 15
/// locals = 120-byte frame).
pub fn encSubRSpImm8(imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, 0));
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 5, 4)); // /5 = SUB, rm=4 (RSP)
    enc.push(@bitCast(imm));
    return enc;
}

/// `ADD RSP, imm8` (sign-extended) — opcode 0x83 /0 with REX.W.
pub fn encAddRSpImm8(imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, 0));
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 0, 4)); // /0 = ADD
    enc.push(@bitCast(imm));
    return enc;
}

/// `MOV [RBP + disp8], r32` — store the low 32 bits of `src`
/// to a stack slot at `RBP + disp`. Opcode 0x89 with mod=01
/// (disp8) + rm=5 (RBP base). REX.R for src extension only
/// (no W since 32-bit; no B since base is RBP, low reg).
pub fn encStoreR32MemRBP(disp: i8, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (src.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x89);
    enc.push(encodeModrm(0b01, src.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `MOV r32, [RBP + disp8]` — load the 32-bit value at
/// `RBP + disp` into `dst` (zero-extends to 64 bits per the
/// W-form). Opcode 0x8B with mod=01 + rm=5.
pub fn encLoadR32MemRBP(dst: Gpr, disp: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 1, 0, 0));
    enc.push(0x8B);
    enc.push(encodeModrm(0b01, dst.low3(), 0b101));
    enc.push(@bitCast(disp));
    return enc;
}

/// `PUSH r64` (opcode 0x50+rd) — push a 64-bit GPR onto the
/// stack. REX.B (0x41) is needed for R8..R15. Width is implicit
/// 64-bit; no operand-size override exists for PUSH r64.
pub fn encPushR(reg: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (reg.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0x50 | @as(u8, reg.low3()));
    return enc;
}

/// `POP r64` (opcode 0x58+rd) — pop a 64-bit GPR from the stack.
/// Same REX.B treatment as PUSH r64.
pub fn encPopR(reg: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (reg.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0x58 | @as(u8, reg.low3()));
    return enc;
}

/// `MOV r64, imm64` (REX.W + 0xB8+rd iq) — `MOVABS`-form
/// 64-bit immediate load. 10 bytes total. Used by FP const
/// handlers to materialise a 64-bit bit pattern in a GPR for
/// MOVQ → XMM transfer.
pub fn encMovImm64Q(dst: Gpr, imm: u64) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(encodeRex(true, 0, 0, dst.extBit()));
    enc.push(0xB8 | @as(u8, dst.low3()));
    var i: u6 = 0;
    while (i < 8) : (i += 1) {
        enc.push(@truncate(imm >> (i * 8)));
    }
    return enc;
}

/// `MOVD xmm, r/m32` (0x66 prefix + 0x0F 0x6E /r) — copy a
/// 32-bit GPR's low half into an XMM (zero-extends the high
/// 96 bits). xmm in ModR/M.reg, gpr in r/m. Used by f32.const
/// to plant the IEEE-754 bit pattern in an XMM slot.
pub fn encMovdXmmFromR32(xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(false, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x6E);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVQ xmm, r/m64` (0x66 prefix + REX.W + 0x0F 0x6E /r) —
/// 64-bit MOVD-equivalent. REX.W is mandatory. Used by
/// f64.const after the bit pattern is materialised in a GPR
/// via MOVABS.
pub fn encMovqXmmFromR64(xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_dst.extBit(), 0, gpr_src.extBit()));
    enc.push(0x0F);
    enc.push(0x6E);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVAPS xmm, xmm` (0x0F 0x28 /r) — 128-bit aligned move
/// between XMM registers. Used as the FP equivalent of
/// `MOV r32, r32` (lhs → dst before the SSE binary op).
/// dst occupies ModR/M.reg, src occupies r/m.
pub fn encMovapsXmmXmm(dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x28);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `SHR r/m, imm8` (opcode 0xC1 /5 ib) — logical shift right
/// by an 8-bit immediate. Width selects 32/64-bit form via REX.W.
/// Used by f.convert_i64_u (slow-path divide-by-2 + round bit).
pub fn encShrRImm8(size: Width, dst: Gpr, imm: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0xC1);
    enc.push(encodeModrm(0b11, 5, dst.low3())); // /5 = SHR
    enc.push(imm);
    return enc;
}

/// `AND r/m, imm8` (opcode 0x83 /4 ib) — sign-extended 8-bit
/// AND. Used by f.convert_i64_u to extract the low bit (round
/// bit) before re-doubling.
pub fn encAndRImm8(size: Width, dst: Gpr, imm: i8) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (rexForRR(size, .rax, dst)) |rex| enc.push(rex);
    enc.push(0x83);
    enc.push(encodeModrm(0b11, 4, dst.low3())); // /4 = AND
    enc.push(@bitCast(imm));
    return enc;
}

/// `MOVSS / MOVSD xmm,[base+idx]` and the store direction —
/// scalar single/double FP load/store with SIB scale=1 (no
/// displacement). `is_store` toggles opcode 0x10 (load) / 0x11
/// (store). `scalar_kind` selects the F3 (f32) / F2 (f64) prefix.
/// xmm goes into ModR/M.reg, base into SIB.base, idx into
/// SIB.index.
pub fn encMovssMovsdMemBaseIdx(scalar_kind: SseScalarKind, is_store: bool, xmm: Xmm, base: Gpr, idx: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(scalar_kind));
    if (xmm.extBit() != 0 or base.extBit() != 0 or idx.extBit() != 0) {
        enc.push(encodeRex(false, xmm.extBit(), idx.extBit(), base.extBit()));
    }
    enc.push(0x0F);
    enc.push(if (is_store) @as(u8, 0x11) else 0x10);
    enc.push(encodeModrm(0b00, xmm.low3(), 0b100)); // mod=00, rm=4 → SIB
    enc.push(encodeSib(0b00, idx.low3(), base.low3())); // scale=1
    return enc;
}

/// `CVTTSS2SI r/m32 or r/m64, xmm/m32-or-64` family — scalar
/// truncating float→signed-int conversion.
///   F3 [REX?] 0F 2C /r (CVTTSS2SI; src f32 via prefix)
///   F2 [REX?] 0F 2C /r (CVTTSD2SI; src f64 via prefix)
/// `dst_is_64` toggles REX.W for the i64 destination variant.
/// dst is in ModR/M.reg (gpr), src is in r/m (xmm).
///
/// **Saturation behaviour**: returns INT_MIN of the destination
/// width (0x80000000 for r32, 0x8000000000000000 for r64) when
/// the source is NaN OR out of range. Used as the sentinel by
/// emitFpTruncSatSigned to drive the spec-correct saturation.
pub fn encCvttScalar2Int(scalar_kind: SseScalarKind, dst_is_64: bool, gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(scalar_kind));
    if (dst_is_64 or gpr_dst.extBit() != 0 or xmm_src.extBit() != 0) {
        enc.push(encodeRex(dst_is_64, gpr_dst.extBit(), 0, xmm_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2C);
    enc.push(encodeModrm(0b11, gpr_dst.low3(), xmm_src.low3()));
    return enc;
}

/// `CVTSI2SS xmm, r/m32` / `CVTSI2SD xmm, r/m64` family —
/// signed integer to scalar float conversion.
///   F3 [REX?] 0F 2A /r (CVTSI2SS, src f32-aware via prefix)
///   F2 [REX?] 0F 2A /r (CVTSI2SD)
/// `src_is_64` toggles REX.W for the i64 source variant.
/// xmm in ModR/M.reg, gpr in r/m.
pub fn encCvtsi2Scalar(scalar_kind: SseScalarKind, src_is_64: bool, xmm_dst: Xmm, gpr_src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(scalar_kind));
    if (src_is_64 or xmm_dst.extBit() != 0 or gpr_src.extBit() != 0) {
        enc.push(encodeRex(src_is_64, xmm_dst.extBit(), 0, gpr_src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2A);
    enc.push(encodeModrm(0b11, xmm_dst.low3(), gpr_src.low3()));
    return enc;
}

/// `MOVD r/m32, xmm` (0x66 + 0x0F 0x7E /r) — extract the low
/// 32 bits of an XMM into a GPR. Mirror of `encMovdXmmFromR32`.
/// xmm in ModR/M.reg, gpr in r/m.
pub fn encMovdR32FromXmm(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (xmm_src.extBit() != 0 or gpr_dst.extBit() != 0) {
        enc.push(encodeRex(false, xmm_src.extBit(), 0, gpr_dst.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x7E);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    return enc;
}

/// `MOVQ r/m64, xmm` (0x66 + REX.W + 0x0F 0x7E /r) — extract
/// the low 64 bits of an XMM into a GPR. REX.W mandatory.
pub fn encMovqR64FromXmm(gpr_dst: Gpr, xmm_src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    enc.push(encodeRex(true, xmm_src.extBit(), 0, gpr_dst.extBit()));
    enc.push(0x0F);
    enc.push(0x7E);
    enc.push(encodeModrm(0b11, xmm_src.low3(), gpr_dst.low3()));
    return enc;
}

/// SSE packed bitwise op kind. f32 = no prefix (operates on
/// single-precision-aligned packed lanes); f64 = 0x66 prefix
/// (double-precision lanes). For abs/neg in scalar contexts
/// the choice only affects the prefix byte; all 128 bits are
/// AND/XOR'd identically.
pub const SsePackedKind = enum(u8) {
    f32 = 0,
    f64 = 0x66,
};

/// SSE2 packed bitwise binary (ANDPS/ANDPD/ORPS/ORPD/XORPS/XORPD).
/// Encoding: `[<prefix>] [REX?] 0x0F <opcode> ModR/M`. Used by
/// abs (ANDPS/ANDPD with 0x7F.. mask) and neg (XORPS/XORPD with
/// 0x80.. sign bit). Opcode: 0x54=AND, 0x56=OR, 0x57=XOR.
pub fn encSsePackedBinary(kind: SsePackedKind, opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (kind != .f32) enc.push(@intFromEnum(kind));
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `ROUNDSS xmm, xmm/m32, imm8` (66 0F 3A 0A /r ib) — SSE4.1
/// scalar single-precision round with mode imm8: 0=nearest
/// (ties to even), 1=floor (toward -inf), 2=ceil (toward +inf),
/// 3=trunc (toward zero), 4=current MXCSR rounding mode.
pub fn encRoundss(dst: Xmm, src: Xmm, mode: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x0A);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(mode);
    return enc;
}

/// `ROUNDSD xmm, xmm/m64, imm8` (66 0F 3A 0B /r ib) — SSE4.1
/// scalar double-precision round; same mode encoding as ROUNDSS.
pub fn encRoundsd(dst: Xmm, src: Xmm, mode: u8) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x3A);
    enc.push(0x0B);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    enc.push(mode);
    return enc;
}

/// `UCOMISS xmm, xmm/m32` (0x0F 0x2E /r) — Unordered Compare
/// Scalar Single. Sets ZF / CF / PF on the comparison result:
/// equal → ZF=1, CF=0, PF=0; less → ZF=0, CF=1, PF=0; greater →
/// ZF=0, CF=0, PF=0; unordered (NaN) → ZF=1, CF=1, PF=1. Used
/// by emitFpCompare to drive SETcc.
pub fn encUcomiss(a: Xmm, b: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (a.extBit() != 0 or b.extBit() != 0) {
        enc.push(encodeRex(false, a.extBit(), 0, b.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2E);
    enc.push(encodeModrm(0b11, a.low3(), b.low3()));
    return enc;
}

/// `UCOMISD xmm, xmm/m64` (0x66 prefix + 0x0F 0x2E /r) —
/// double-precision counterpart of UCOMISS. Same flag
/// semantics.
pub fn encUcomisd(a: Xmm, b: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0x66);
    if (a.extBit() != 0 or b.extBit() != 0) {
        enc.push(encodeRex(false, a.extBit(), 0, b.extBit()));
    }
    enc.push(0x0F);
    enc.push(0x2E);
    enc.push(encodeModrm(0b11, a.low3(), b.low3()));
    return enc;
}

/// Mandatory prefix for SSE scalar ops. F3 = single-precision
/// (operates on the low 32 bits of XMM = f32). F2 = double-
/// precision (operates on the low 64 bits = f64).
pub const SseScalarKind = enum(u8) {
    f32 = 0xF3,
    f64 = 0xF2,
};

/// SSE2 scalar binary op (ADDSS / ADDSD / SUBSS / SUBSD /
/// MULSS / MULSD / DIVSS / DIVSD). Encoding:
///   <prefix> [REX?] 0x0F <opcode> ModR/M
/// where `<prefix>` is F3 (f32) or F2 (f64); `<opcode>` is
/// 0x58 (add), 0x5C (sub), 0x59 (mul), 0x5E (div).
/// dst occupies ModR/M.reg, src occupies r/m.
pub fn encSseScalarBinary(kind: SseScalarKind, opcode: u8, dst: Xmm, src: Xmm) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(@intFromEnum(kind));
    if (dst.extBit() != 0 or src.extBit() != 0) {
        enc.push(encodeRex(false, dst.extBit(), 0, src.extBit()));
    }
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
}

/// `MOV r32, imm32` (opcode 0xB8+rd ib32) — load a 32-bit
/// immediate into a GPR. The 32-bit form zero-extends to 64
/// bits (Wasm i32 semantics map to this). REX.B for R8..R15.
///
/// `imm` is emitted little-endian per AMD64 Vol.3 §1.2.2.
pub fn encMovImm32W(dst: Gpr, imm: u32) EncodedInsn {
    var enc: EncodedInsn = .{};
    if (dst.extBit() == 1) enc.push(encodeRex(false, 0, 0, 1));
    enc.push(0xB8 | @as(u8, dst.low3()));
    enc.push(@truncate(imm));
    enc.push(@truncate(imm >> 8));
    enc.push(@truncate(imm >> 16));
    enc.push(@truncate(imm >> 24));
    return enc;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "encodeRex: bit positions" {
    // W=1, R=0, X=0, B=0 → 0x48 (canonical 64-bit operand prefix)
    try testing.expectEqual(@as(u8, 0x48), encodeRex(true, 0, 0, 0));
    // W=0 default → 0x40
    try testing.expectEqual(@as(u8, 0x40), encodeRex(false, 0, 0, 0));
    // W=1, R=1, B=1 → 0x4D (used for mov r9, r8 etc.)
    try testing.expectEqual(@as(u8, 0x4D), encodeRex(true, 1, 0, 1));
    // W=0, B=1 → 0x41 (32-bit access into R8..R15)
    try testing.expectEqual(@as(u8, 0x41), encodeRex(false, 0, 0, 1));
}

test "encodeModrm: register-direct mode" {
    // mod=11, reg=001 (rcx), rm=000 (rax) → 0xc8 (the canonical
    // mov rax, rcx ModR/M byte).
    try testing.expectEqual(@as(u8, 0xC8), encodeModrm(0b11, 1, 0));
    // mod=00, reg=000, rm=000 → 0x00 ([rax])
    try testing.expectEqual(@as(u8, 0x00), encodeModrm(0b00, 0, 0));
}

test "encodeSib: scale + index + base" {
    // scale=2 (×4), index=001 (rcx), base=000 (rax) → 0x88
    try testing.expectEqual(@as(u8, 0x88), encodeSib(0b10, 1, 0));
}

test "encMovRR: mov rax, rcx (q) → 48 89 c8" {
    const enc = encMovRR(.q, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov eax, ecx (d) → 89 c8 (no REX)" {
    const enc = encMovRR(.d, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov r8, rcx (q) → 49 89 c8 (REX.W + REX.B)" {
    const enc = encMovRR(.q, .r8, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov rax, r9 (q) → 4c 89 c8 (REX.W + REX.R)" {
    const enc = encMovRR(.q, .rax, .r9);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x89, 0xC8 }, enc.slice());
}

test "encMovRR: mov r9d, r8d (d) → 45 89 c1 (REX.R + REX.B, no W)" {
    const enc = encMovRR(.d, .r9, .r8);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x89, 0xC1 }, enc.slice());
}

test "encAddRR: add rax, rcx (q) → 48 01 c8" {
    const enc = encAddRR(.q, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x01, 0xC8 }, enc.slice());
}

test "encSubRR: sub rax, rcx (q) → 48 29 c8" {
    const enc = encSubRR(.q, .rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x29, 0xC8 }, enc.slice());
}

test "encRet: single 0xC3" {
    const enc = encRet();
    try testing.expectEqualSlices(u8, &.{0xC3}, enc.slice());
}

test "encNop: single 0x90" {
    const enc = encNop();
    try testing.expectEqualSlices(u8, &.{0x90}, enc.slice());
}

test "EncodedInsn: max len bound" {
    try testing.expectEqual(@as(u8, 15), max_insn_bytes);
}

test "encPushR: push rbp → 55" {
    const enc = encPushR(.rbp);
    try testing.expectEqualSlices(u8, &.{0x55}, enc.slice());
}

test "encPushR: push r12 → 41 54 (REX.B)" {
    const enc = encPushR(.r12);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x54 }, enc.slice());
}

test "encPopR: pop rbp → 5d" {
    const enc = encPopR(.rbp);
    try testing.expectEqualSlices(u8, &.{0x5D}, enc.slice());
}

test "encPopR: pop r12 → 41 5c (REX.B)" {
    const enc = encPopR(.r12);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x5C }, enc.slice());
}

test "encMovImm32W: mov eax, #42 → b8 2a 00 00 00" {
    const enc = encMovImm32W(.rax, 42);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x2A, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encMovImm32W: mov r10d, #42 → 41 ba 2a 00 00 00 (REX.B)" {
    const enc = encMovImm32W(.r10, 42);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xBA, 0x2A, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encMovImm32W: little-endian imm32 (0xDEADBEEF)" {
    const enc = encMovImm32W(.rax, 0xDEADBEEF);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0xEF, 0xBE, 0xAD, 0xDE }, enc.slice());
}

test "encSubRSpImm8: sub rsp, 16 → 48 83 ec 10" {
    const enc = encSubRSpImm8(16);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xEC, 0x10 }, enc.slice());
}

test "encAddRSpImm8: add rsp, 16 → 48 83 c4 10" {
    const enc = encAddRSpImm8(16);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xC4, 0x10 }, enc.slice());
}

test "encStoreR32MemRBP: mov [rbp-8], r10d → 44 89 55 f8 (REX.R)" {
    const enc = encStoreR32MemRBP(-8, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x55, 0xF8 }, enc.slice());
}

test "encStoreR32MemRBP: mov [rbp-8], ebx → 89 5d f8 (no REX)" {
    const enc = encStoreR32MemRBP(-8, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x5D, 0xF8 }, enc.slice());
}

test "encLoadR32MemRBP: mov r10d, [rbp-8] → 44 8b 55 f8" {
    const enc = encLoadR32MemRBP(.r10, -8);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x8B, 0x55, 0xF8 }, enc.slice());
}

test "encLoadR32MemRBP: mov ebx, [rbp-16] → 8b 5d f0" {
    const enc = encLoadR32MemRBP(.rbx, -16);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x5D, 0xF0 }, enc.slice());
}

test "encJmpRel32: jmp +0 → e9 00 00 00 00 (placeholder shape)" {
    const enc = encJmpRel32(0);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encJmpRel32: jmp +5 → e9 05 00 00 00" {
    const enc = encJmpRel32(5);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0x05, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encJmpRel32: jmp -7 → e9 f9 ff ff ff (sign-extended disp)" {
    const enc = encJmpRel32(-7);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0xF9, 0xFF, 0xFF, 0xFF }, enc.slice());
}

test "encJccRel32: jne +0 → 0f 85 00 00 00 00 (cc=ne=5)" {
    const enc = encJccRel32(.ne, 0);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x85, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encJccRel32: je +10 → 0f 84 0a 00 00 00 (cc=e=4)" {
    const enc = encJccRel32(.e, 10);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x84, 0x0A, 0x00, 0x00, 0x00 }, enc.slice());
}

test "patchRel32: rewrite JMP placeholder disp" {
    var buf = [_]u8{ 0xE9, 0, 0, 0, 0 };
    patchRel32(&buf, 0, 5, 42);
    try testing.expectEqualSlices(u8, &.{ 0xE9, 0x2A, 0x00, 0x00, 0x00 }, &buf);
}

test "patchRel32: rewrite Jcc placeholder disp" {
    var buf = [_]u8{ 0x0F, 0x84, 0, 0, 0, 0 };
    patchRel32(&buf, 0, 6, -100);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x84, 0x9C, 0xFF, 0xFF, 0xFF }, &buf);
}

test "encCmpRImm8: cmp ebx, 5 → 83 fb 05" {
    const enc = encCmpRImm8(.d, .rbx, 5);
    try testing.expectEqualSlices(u8, &.{ 0x83, 0xFB, 0x05 }, enc.slice());
}

test "encCmpRImm8: cmp r10d, 0 → 41 83 fa 00 (REX.B)" {
    const enc = encCmpRImm8(.d, .r10, 0);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x83, 0xFA, 0x00 }, enc.slice());
}

test "encJccRel8: jne +5 → 75 05 (cc=ne=5; the canonical br_table skip)" {
    const enc = encJccRel8(.ne, 5);
    try testing.expectEqualSlices(u8, &.{ 0x75, 0x05 }, enc.slice());
}

test "encJccRel8: je -10 → 74 f6" {
    const enc = encJccRel8(.e, -10);
    try testing.expectEqualSlices(u8, &.{ 0x74, 0xF6 }, enc.slice());
}

test "encMovR64FromMemDisp32: mov rax, [r15+0] → 49 8b 87 00 00 00 00" {
    const enc = encMovR64FromMemDisp32(.rax, .r15, 0);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x8B, 0x87, 0, 0, 0, 0 }, enc.slice());
}

test "encMovR64FromMemDisp32: mov rdx, [r15+8] → 49 8b 97 08 00 00 00" {
    const enc = encMovR64FromMemDisp32(.rdx, .r15, 8);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x8B, 0x97, 0x08, 0, 0, 0 }, enc.slice());
}

test "encMovR32FromMemDisp32: mov ebx, [rax+8] → 8b 98 08 00 00 00 (no REX)" {
    const enc = encMovR32FromMemDisp32(.rbx, .rax, 8);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x98, 0x08, 0, 0, 0 }, enc.slice());
}

test "encMovR32FromMemDisp32: mov r10d, [rax+16] → 44 8b 90 10 00 00 00 (REX.R)" {
    const enc = encMovR32FromMemDisp32(.r10, .rax, 16);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x8B, 0x90, 0x10, 0, 0, 0 }, enc.slice());
}

test "encStoreR32MemDisp32: mov [rax+8], ebx → 89 98 08 00 00 00 (no REX)" {
    const enc = encStoreR32MemDisp32(.rbx, .rax, 8);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x98, 0x08, 0, 0, 0 }, enc.slice());
}

test "encStoreR32MemDisp32: mov [rax+16], r10d → 44 89 90 10 00 00 00 (REX.R)" {
    const enc = encStoreR32MemDisp32(.r10, .rax, 16);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x89, 0x90, 0x10, 0, 0, 0 }, enc.slice());
}

test "encCmpR64MemDisp32: cmp rdx, [r15+8] → 49 3b 97 08 00 00 00" {
    const enc = encCmpR64MemDisp32(.rdx, .r15, 8);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x3B, 0x97, 0x08, 0, 0, 0 }, enc.slice());
}

test "encMovR32FromBaseIdx: mov ebx, [rax + rdx] → 8b 1c 10" {
    const enc = encMovR32FromBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x1C, 0x10 }, enc.slice());
}

test "encMovR32FromBaseIdx: mov r10d, [r15 + rax] → 45 8b 14 07 (REX.R+REX.B)" {
    const enc = encMovR32FromBaseIdx(.r10, .r15, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x8B, 0x14, 0x07 }, enc.slice());
}

test "encStoreR32MemBaseIdx: mov [rax+rdx], ebx → 89 1c 10" {
    const enc = encStoreR32MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x89, 0x1C, 0x10 }, enc.slice());
}

test "encStoreR32MemBaseIdx: mov [r15+rax], r10d → 45 89 14 07 (REX.R+REX.B)" {
    const enc = encStoreR32MemBaseIdx(.r10, .r15, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x89, 0x14, 0x07 }, enc.slice());
}

test "encStoreR16MemBaseIdx: mov [rax+rdx], bx → 66 89 1c 10" {
    const enc = encStoreR16MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x89, 0x1C, 0x10 }, enc.slice());
}

test "encStoreR8MemBaseIdx: mov [rax+rdx], bl → 40 88 1c 10 (forced REX)" {
    const enc = encStoreR8MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x88, 0x1C, 0x10 }, enc.slice());
}

test "encStoreR8MemBaseIdx: mov [rax+rdx], r10b → 44 88 14 10 (REX.R)" {
    const enc = encStoreR8MemBaseIdx(.r10, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x88, 0x14, 0x10 }, enc.slice());
}

test "encMovzxR32_8MemBaseIdx: movzx ebx, byte [rax+rdx] → 0f b6 1c 10" {
    const enc = encMovzxR32_8MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xB6, 0x1C, 0x10 }, enc.slice());
}

test "encMovsxR32_8MemBaseIdx: movsx r10d, byte [rax+rdx] → 44 0f be 14 10 (REX.R)" {
    const enc = encMovsxR32_8MemBaseIdx(.r10, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0xBE, 0x14, 0x10 }, enc.slice());
}

test "encMovzxR32_16MemBaseIdx: movzx ebx, word [rax+rdx] → 0f b7 1c 10" {
    const enc = encMovzxR32_16MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xB7, 0x1C, 0x10 }, enc.slice());
}

test "encMovsxR32_16MemBaseIdx: movsx ebx, word [rax+rdx] → 0f bf 1c 10" {
    const enc = encMovsxR32_16MemBaseIdx(.rbx, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xBF, 0x1C, 0x10 }, enc.slice());
}

test "encLeaR64BaseDisp8: lea rcx, [rdx+4] → 48 8d 4a 04" {
    const enc = encLeaR64BaseDisp8(.rcx, .rdx, 4);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x8D, 0x4A, 0x04 }, enc.slice());
}

test "encLeaR64BaseDisp8: lea rcx, [r15+8] → 49 8d 4f 08 (REX.B)" {
    const enc = encLeaR64BaseDisp8(.rcx, .r15, 8);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0x8D, 0x4F, 0x08 }, enc.slice());
}

test "encAddR64Imm32: add rdx, 4 → 48 81 c2 04 00 00 00" {
    const enc = encAddR64Imm32(.rdx, 4);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x81, 0xC2, 0x04, 0, 0, 0 }, enc.slice());
}

test "encStoreImm32MemDisp32: mov [r15+40], 1 → 41 c7 87 28 00 00 00 01 00 00 00" {
    const enc = encStoreImm32MemDisp32(.r15, 40, 1);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xC7, 0x87, 0x28, 0, 0, 0, 0x01, 0, 0, 0 }, enc.slice());
}

test "encAndRR: and ebx, ecx (d) → 21 cb" {
    const enc = encAndRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x21, 0xCB }, enc.slice());
}

test "encOrRR: or ebx, ecx (d) → 09 cb" {
    const enc = encOrRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x09, 0xCB }, enc.slice());
}

test "encXorRR: xor ebx, ecx (d) → 31 cb" {
    const enc = encXorRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x31, 0xCB }, enc.slice());
}

test "encXorRR: xor rax, rax (q) → 48 31 c0 (canonical zero idiom)" {
    const enc = encXorRR(.q, .rax, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x31, 0xC0 }, enc.slice());
}

test "encImulRR: imul ebx, ecx (d) → 0f af d9" {
    const enc = encImulRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0xAF, 0xD9 }, enc.slice());
}

test "encImulRR: imul rbx, rcx (q) → 48 0f af d9" {
    const enc = encImulRR(.q, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x0F, 0xAF, 0xD9 }, enc.slice());
}

test "encImulRR: imul ebx, r10d (d) → 41 0f af da (REX.B for src)" {
    const enc = encImulRR(.d, .rbx, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x0F, 0xAF, 0xDA }, enc.slice());
}

test "encImulRR: imul r9d, ecx (d) → 44 0f af c9 (REX.R for dst)" {
    const enc = encImulRR(.d, .r9, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x44, 0x0F, 0xAF, 0xC9 }, enc.slice());
}

test "encCmpRR: cmp ebx, ecx (d) → 39 cb" {
    const enc = encCmpRR(.d, .rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x39, 0xCB }, enc.slice());
}

test "encCmpRR: cmp r10d, r11d (d) → 45 39 da (REX.R + REX.B)" {
    const enc = encCmpRR(.d, .r10, .r11);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x39, 0xDA }, enc.slice());
}

test "encTestRR: test ebx, ebx (d) → 85 db" {
    const enc = encTestRR(.d, .rbx, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x85, 0xDB }, enc.slice());
}

test "encTestRR: test r10d, r10d (d) → 45 85 d2 (REX.R + REX.B)" {
    const enc = encTestRR(.d, .r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x85, 0xD2 }, enc.slice());
}

test "encTestRR: test rax, rax (q) → 48 85 c0 (canonical zero check)" {
    const enc = encTestRR(.q, .rax, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x85, 0xC0 }, enc.slice());
}

test "encShiftRCl: shl ebx, cl (.d, .shl) → d3 e3" {
    const enc = encShiftRCl(.d, .shl, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xE3 }, enc.slice());
}

test "encShiftRCl: shr r10d, cl (.d, .shr) → 41 d3 ea (REX.B)" {
    const enc = encShiftRCl(.d, .shr, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xD3, 0xEA }, enc.slice());
}

test "encShiftRCl: sar ebx, cl (.d, .sar) → d3 fb (kind=7)" {
    const enc = encShiftRCl(.d, .sar, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xFB }, enc.slice());
}

test "encShiftRCl: rol ebx, cl (.d, .rol) → d3 c3 (kind=0)" {
    const enc = encShiftRCl(.d, .rol, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xC3 }, enc.slice());
}

test "encShiftRCl: ror ebx, cl (.d, .ror) → d3 cb (kind=1)" {
    const enc = encShiftRCl(.d, .ror, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0xD3, 0xCB }, enc.slice());
}

test "encShiftRCl: shl rbx, cl (.q) → 48 d3 e3 (REX.W)" {
    const enc = encShiftRCl(.q, .shl, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xD3, 0xE3 }, enc.slice());
}

test "encLzcntR32: lzcnt ebx, ecx → f3 0f bd d9" {
    const enc = encLzcntR32(.rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xBD, 0xD9 }, enc.slice());
}

test "encLzcntR32: lzcnt r10d, r11d → f3 45 0f bd d3 (REX after F3)" {
    const enc = encLzcntR32(.r10, .r11);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x45, 0x0F, 0xBD, 0xD3 }, enc.slice());
}

test "encTzcntR32: tzcnt ebx, ecx → f3 0f bc d9" {
    const enc = encTzcntR32(.rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xBC, 0xD9 }, enc.slice());
}

test "encPopcntR32: popcnt ebx, ecx → f3 0f b8 d9" {
    const enc = encPopcntR32(.rbx, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0xB8, 0xD9 }, enc.slice());
}

test "encPopcntR32: popcnt r10d, r10d → f3 45 0f b8 d2" {
    const enc = encPopcntR32(.r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x45, 0x0F, 0xB8, 0xD2 }, enc.slice());
}

test "encSetccR: sete bl → 40 0f 94 c3 (bare REX for low-byte access)" {
    const enc = encSetccR(.e, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0x94, 0xC3 }, enc.slice());
}

test "encSetccR: setl r10b → 41 0f 9c c2 (REX.B)" {
    const enc = encSetccR(.l, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x0F, 0x9C, 0xC2 }, enc.slice());
}

test "encSetccR: setb cl (unsigned-less) → 40 0f 92 c1" {
    const enc = encSetccR(.b, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0x92, 0xC1 }, enc.slice());
}

test "encMovzxR32R8: movzx ebx, bl → 40 0f b6 db" {
    const enc = encMovzxR32R8(.rbx, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x40, 0x0F, 0xB6, 0xDB }, enc.slice());
}

test "encMovzxR32R8: movzx r10d, r10b → 45 0f b6 d2 (REX.R + REX.B)" {
    const enc = encMovzxR32R8(.r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0xB6, 0xD2 }, enc.slice());
}

test "encMovsxdR64R32: movsxd rax, ecx → 48 63 c1" {
    const enc = encMovsxdR64R32(.rax, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x63, 0xC1 }, enc.slice());
}

test "encMovsxdR64R32: movsxd r10, r10d → 4d 63 d2 (REX.W + REX.R + REX.B)" {
    const enc = encMovsxdR64R32(.r10, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x4D, 0x63, 0xD2 }, enc.slice());
}

test "encMovsxdR64R32: movsxd r11, ecx → 4c 63 d9 (REX.W + REX.R)" {
    const enc = encMovsxdR64R32(.r11, .rcx);
    try testing.expectEqualSlices(u8, &.{ 0x4C, 0x63, 0xD9 }, enc.slice());
}

test "encCallRel32: call rel32 disp=0 → e8 00 00 00 00 (placeholder)" {
    const enc = encCallRel32(0);
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encCallRel32: call rel32 disp=0x12345678 little-endian" {
    const enc = encCallRel32(0x12345678);
    try testing.expectEqualSlices(u8, &.{ 0xE8, 0x78, 0x56, 0x34, 0x12 }, enc.slice());
}

test "encCallReg: call rax → ff d0 (no REX)" {
    const enc = encCallReg(.rax);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xD0 }, enc.slice());
}

test "encCallReg: call r10 → 41 ff d2 (REX.B)" {
    const enc = encCallReg(.r10);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0xFF, 0xD2 }, enc.slice());
}

test "encCmpRImm32: cmp eax, 0 → 81 f8 00 00 00 00 (no REX)" {
    const enc = encCmpRImm32(.rax, 0);
    try testing.expectEqualSlices(u8, &.{ 0x81, 0xF8, 0x00, 0x00, 0x00, 0x00 }, enc.slice());
}

test "encCmpRImm32: cmp r10d, 0xCAFE → 41 81 fa fe ca 00 00 (REX.B + LE imm32)" {
    const enc = encCmpRImm32(.r10, 0xCAFE);
    try testing.expectEqualSlices(u8, &.{ 0x41, 0x81, 0xFA, 0xFE, 0xCA, 0x00, 0x00 }, enc.slice());
}

test "encMovR32FromBaseIdxLsl2: mov eax, [rax + r10*4] → 42 8b 04 90 (REX.X)" {
    const enc = encMovR32FromBaseIdxLsl2(.rax, .rax, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x42, 0x8B, 0x04, 0x90 }, enc.slice());
}

test "encMovR32FromBaseIdxLsl2: mov ebx, [rcx + rdx*4] → 8b 1c 91 (no REX)" {
    const enc = encMovR32FromBaseIdxLsl2(.rbx, .rcx, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0x8B, 0x1C, 0x91 }, enc.slice());
}

test "encMovR64FromBaseIdxLsl3: mov rax, [rax + r10*8] → 4a 8b 04 d0 (REX.W + REX.X)" {
    const enc = encMovR64FromBaseIdxLsl3(.rax, .rax, .r10);
    try testing.expectEqualSlices(u8, &.{ 0x4A, 0x8B, 0x04, 0xD0 }, enc.slice());
}

test "encMovR64FromBaseIdxLsl3: mov rcx, [rdx + rbx*8] → 48 8b 0c da (REX.W only)" {
    const enc = encMovR64FromBaseIdxLsl3(.rcx, .rdx, .rbx);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x8B, 0x0C, 0xDA }, enc.slice());
}

test "encMovImm64Q: movabs rax, 0xDEADBEEFCAFEBABE → 48 b8 + LE 8-byte imm" {
    const enc = encMovImm64Q(.rax, 0xDEADBEEFCAFEBABE);
    try testing.expectEqualSlices(u8, &.{
        0x48, 0xB8, 0xBE, 0xBA, 0xFE, 0xCA, 0xEF, 0xBE, 0xAD, 0xDE,
    }, enc.slice());
}

test "encMovImm64Q: movabs r10, 0 → 49 ba + 8 zeros (REX.W + REX.B)" {
    const enc = encMovImm64Q(.r10, 0);
    try testing.expectEqualSlices(u8, &.{
        0x49, 0xBA, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    }, enc.slice());
}

test "encMovdXmmFromR32: movd xmm0, eax → 66 0f 6e c0 (no REX)" {
    const enc = encMovdXmmFromR32(.xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovdXmmFromR32: movd xmm8, eax → 66 44 0f 6e c0 (REX.R)" {
    const enc = encMovdXmmFromR32(.xmm8, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x44, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovqXmmFromR64: movq xmm0, rax → 66 48 0f 6e c0 (REX.W only)" {
    const enc = encMovqXmmFromR64(.xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovqXmmFromR64: movq xmm8, rax → 66 4c 0f 6e c0 (REX.W + REX.R)" {
    const enc = encMovqXmmFromR64(.xmm8, .rax);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4C, 0x0F, 0x6E, 0xC0 }, enc.slice());
}

test "encMovapsXmmXmm: movaps xmm0, xmm1 → 0f 28 c1 (no REX)" {
    const enc = encMovapsXmmXmm(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x28, 0xC1 }, enc.slice());
}

test "encMovapsXmmXmm: movaps xmm10, xmm8 → 45 0f 28 d0 (REX.R + REX.B)" {
    const enc = encMovapsXmmXmm(.xmm10, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x28, 0xD0 }, enc.slice());
}

test "encSseScalarBinary: addss xmm0, xmm1 → f3 0f 58 c1 (no REX)" {
    const enc = encSseScalarBinary(.f32, 0x58, .xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x58, 0xC1 }, enc.slice());
}

test "encSseScalarBinary: addss xmm10, xmm9 → f3 45 0f 58 d1 (REX.R + REX.B)" {
    const enc = encSseScalarBinary(.f32, 0x58, .xmm10, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x45, 0x0F, 0x58, 0xD1 }, enc.slice());
}

test "encSseScalarBinary: mulsd xmm8, xmm9 → f2 45 0f 59 c1 (REX, F2 prefix, opcode 59)" {
    const enc = encSseScalarBinary(.f64, 0x59, .xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x59, 0xC1 }, enc.slice());
}

test "encSseScalarBinary: divsd xmm0, xmm1 → f2 0f 5e c1 (no REX, opcode 5E)" {
    const enc = encSseScalarBinary(.f64, 0x5E, .xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x0F, 0x5E, 0xC1 }, enc.slice());
}

test "encUcomiss: ucomiss xmm0, xmm1 → 0f 2e c1 (no REX, no prefix)" {
    const enc = encUcomiss(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encUcomiss: ucomiss xmm8, xmm9 → 45 0f 2e c1 (REX.R + REX.B)" {
    const enc = encUcomiss(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0x45, 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encUcomisd: ucomisd xmm0, xmm1 → 66 0f 2e c1 (66 prefix, no REX)" {
    const enc = encUcomisd(.xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encUcomisd: ucomisd xmm8, xmm9 → 66 45 0f 2e c1 (66 prefix + REX)" {
    const enc = encUcomisd(.xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x2E, 0xC1 }, enc.slice());
}

test "encSsePackedBinary: andps xmm0, xmm1 → 0f 54 c1 (no prefix)" {
    const enc = encSsePackedBinary(.f32, 0x54, .xmm0, .xmm1);
    try testing.expectEqualSlices(u8, &.{ 0x0F, 0x54, 0xC1 }, enc.slice());
}

test "encSsePackedBinary: xorpd xmm8, xmm9 → 66 45 0f 57 c1 (66 prefix + REX)" {
    const enc = encSsePackedBinary(.f64, 0x57, .xmm8, .xmm9);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x57, 0xC1 }, enc.slice());
}

test "encRoundss: roundss xmm0, xmm1, 2 → 66 0f 3a 0a c1 02 (ceil mode)" {
    const enc = encRoundss(.xmm0, .xmm1, 2);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x0A, 0xC1, 0x02 }, enc.slice());
}

test "encRoundss: roundss xmm8, xmm9, 1 → 66 45 0f 3a 0a c1 01 (REX + floor mode)" {
    const enc = encRoundss(.xmm8, .xmm9, 1);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x3A, 0x0A, 0xC1, 0x01 }, enc.slice());
}

test "encRoundsd: roundsd xmm0, xmm1, 3 → 66 0f 3a 0b c1 03 (trunc mode, opcode 0B)" {
    const enc = encRoundsd(.xmm0, .xmm1, 3);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x3A, 0x0B, 0xC1, 0x03 }, enc.slice());
}

test "encMovdR32FromXmm: movd eax, xmm0 → 66 0f 7e c0 (no REX)" {
    const enc = encMovdR32FromXmm(.rax, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x0F, 0x7E, 0xC0 }, enc.slice());
}

test "encMovdR32FromXmm: movd r10d, xmm8 → 66 45 0f 7e c2 (REX.R + REX.B)" {
    const enc = encMovdR32FromXmm(.r10, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0F, 0x7E, 0xC2 }, enc.slice());
}

test "encMovqR64FromXmm: movq rax, xmm8 → 66 4c 0f 7e c0 (REX.W + REX.R)" {
    const enc = encMovqR64FromXmm(.rax, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x4C, 0x0F, 0x7E, 0xC0 }, enc.slice());
}

test "encMovqR64FromXmm: movq rcx, xmm0 → 66 48 0f 7e c1 (REX.W only)" {
    const enc = encMovqR64FromXmm(.rcx, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0x66, 0x48, 0x0F, 0x7E, 0xC1 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2ss xmm0, eax → f3 0f 2a c0 (no REX)" {
    const enc = encCvtsi2Scalar(.f32, false, .xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x2A, 0xC0 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2ss xmm8, rax → f3 4c 0f 2a c0 (REX.W + REX.R)" {
    const enc = encCvtsi2Scalar(.f32, true, .xmm8, .rax);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x4C, 0x0F, 0x2A, 0xC0 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2sd xmm8, r10d → f2 45 0f 2a c2 (REX.R + REX.B)" {
    const enc = encCvtsi2Scalar(.f64, false, .xmm8, .r10);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x45, 0x0F, 0x2A, 0xC2 }, enc.slice());
}

test "encCvtsi2Scalar: cvtsi2sd xmm0, rax → f2 48 0f 2a c0 (REX.W only)" {
    const enc = encCvtsi2Scalar(.f64, true, .xmm0, .rax);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x48, 0x0F, 0x2A, 0xC0 }, enc.slice());
}

test "encShrRImm8: shr rax, 1 → 48 c1 e8 01" {
    const enc = encShrRImm8(.q, .rax, 1);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0xC1, 0xE8, 0x01 }, enc.slice());
}

test "encShrRImm8: shr r10, 1 → 49 c1 ea 01 (REX.W + REX.B)" {
    const enc = encShrRImm8(.q, .r10, 1);
    try testing.expectEqualSlices(u8, &.{ 0x49, 0xC1, 0xEA, 0x01 }, enc.slice());
}

test "encAndRImm8: and rax, 1 → 48 83 e0 01" {
    const enc = encAndRImm8(.q, .rax, 1);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xE0, 0x01 }, enc.slice());
}

test "encAndRImm8: and rcx, 1 → 48 83 e1 01" {
    const enc = encAndRImm8(.q, .rcx, 1);
    try testing.expectEqualSlices(u8, &.{ 0x48, 0x83, 0xE1, 0x01 }, enc.slice());
}

test "encCvttScalar2Int: cvttss2si eax, xmm0 → f3 0f 2c c0 (no REX)" {
    const enc = encCvttScalar2Int(.f32, false, .rax, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x2C, 0xC0 }, enc.slice());
}

test "encCvttScalar2Int: cvttss2si r10, xmm8 → f3 4d 0f 2c d0 (REX.W+R+B; ModRM.reg=r10)" {
    const enc = encCvttScalar2Int(.f32, true, .r10, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x4D, 0x0F, 0x2C, 0xD0 }, enc.slice());
}

test "encCvttScalar2Int: cvttsd2si rax, xmm0 → f2 48 0f 2c c0 (REX.W only)" {
    const enc = encCvttScalar2Int(.f64, true, .rax, .xmm0);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x48, 0x0F, 0x2C, 0xC0 }, enc.slice());
}

test "encCvttScalar2Int: cvttsd2si eax, xmm8 → f2 41 0f 2c c0 (REX.B only)" {
    const enc = encCvttScalar2Int(.f64, false, .rax, .xmm8);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x41, 0x0F, 0x2C, 0xC0 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movss xmm0, [rax+rdx] → f3 0f 10 04 10 (no REX)" {
    const enc = encMovssMovsdMemBaseIdx(.f32, false, .xmm0, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x0F, 0x10, 0x04, 0x10 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movsd xmm8, [rax+rdx] → f2 44 0f 10 04 10 (REX.R)" {
    const enc = encMovssMovsdMemBaseIdx(.f64, false, .xmm8, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x44, 0x0F, 0x10, 0x04, 0x10 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movss [rax+rdx], xmm8 → f3 44 0f 11 04 10 (store, REX.R)" {
    const enc = encMovssMovsdMemBaseIdx(.f32, true, .xmm8, .rax, .rdx);
    try testing.expectEqualSlices(u8, &.{ 0xF3, 0x44, 0x0F, 0x11, 0x04, 0x10 }, enc.slice());
}

test "encMovssMovsdMemBaseIdx: movsd [r10+r11], xmm0 → f2 43 0f 11 04 1a (store, REX.B+X)" {
    const enc = encMovssMovsdMemBaseIdx(.f64, true, .xmm0, .r10, .r11);
    try testing.expectEqualSlices(u8, &.{ 0xF2, 0x43, 0x0F, 0x11, 0x04, 0x1A }, enc.slice());
}
