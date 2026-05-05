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

/// Common shape for the `F3 0F <opcode> /r` family used by
/// LZCNT / TZCNT / POPCNT. dst occupies ModR/M.reg and src is
/// in r/m (IMUL-style operand inversion). The mandatory 0xF3
/// prefix precedes any REX byte per AMD64 Vol.3 §1.2.6.
inline fn encF3_0F_R32R(opcode: u8, dst: Gpr, src: Gpr) EncodedInsn {
    var enc: EncodedInsn = .{};
    enc.push(0xF3);
    if (rexForRR(.d, dst, src)) |rex| enc.push(rex);
    enc.push(0x0F);
    enc.push(opcode);
    enc.push(encodeModrm(0b11, dst.low3(), src.low3()));
    return enc;
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
