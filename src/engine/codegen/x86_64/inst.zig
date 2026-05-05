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
