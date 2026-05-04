//! ARM64 instruction encoder (§9.7 / 7.2 chunk a).
//!
//! Produces fixed-width `u32` encodings for the AArch64 ops the
//! §9.7 / 7.3 emit pass uses: register-register and register-
//! immediate ALU, MOV-immediate (movz / movk), branches (B / BL
//! / BR / RET), and load / store immediate-offset (LDR / STR).
//!
//! Bit patterns from the Arm Architecture Reference Manual
//! (DDI 0487, A64 base instructions). Each `pub fn enc<X>`
//! returns the little-endian `u32` ready to write to the code
//! buffer; the §9.7 / 7.3 emit pass packs them into a `[]u8` via
//! `std.mem.writeInt(u32, ..., .little)`.
//!
//! Phase 7.2 chunk-a scope: enough opcodes to lower §9.7 / 7.4's
//! MVP arithmetic + control flow + memory ops via the §9.7 / 7.1
//! greedy-local regalloc. Float / SIMD / exception / atomic
//! encodings land alongside their phases (9 / 10).
//!
//! Zone 2 (`src/jit_arm64/`) — must NOT import `src/jit_x86/`
//! per ROADMAP §A3 (Zone-2 inter-arch isolation).

const std = @import("std");

/// X-register index 0..30 (XZR = 31 is the zero register;
/// SP also encodes as 31 with opcode-dependent semantics). The
/// encoder accepts the raw u5 to keep the surface honest about
/// ARM64's 5-bit register field; `abi.zig` maps regalloc slot
/// ids to specific Xn values.
pub const Xn = u5;

/// Zero register — reads as 0; writes are discarded.
pub const xzr: Xn = 31;
/// Stack pointer — encoded as 31; opcode disambiguates from XZR.
pub const sp_reg: Xn = 31;

/// `RET Xn` — return via Xn (X30/LR is the canonical default).
/// Encoding: `1101 0110 0101 1111 0000 00 [Rn:5] 00000`
/// = base `0xD65F0000` | (rn << 5).
pub fn encRet(rn: Xn) u32 {
    return 0xD65F0000 | (@as(u32, rn) << 5);
}

/// `MOVZ Xd, #imm16, lsl #0` — move zero-extended 16-bit imm.
/// Encoding (64-bit MOVZ, hw=0):
/// `1 10 100101 00 [imm16:16] [Rd:5]` = `0xD2800000` | (imm<<5) | rd.
pub fn encMovzImm16(rd: Xn, imm16: u16) u32 {
    return 0xD2800000 | (@as(u32, imm16) << 5) | @as(u32, rd);
}

/// `MOVK Xd, #imm16, lsl #(hw*16)` — keep-other-bits insert.
/// Encoding (64-bit MOVK):
/// `1 11 100101 [hw:2] [imm16:16] [Rd:5]` = `0xF2800000` | (hw<<21)
/// | (imm<<5) | rd.
pub fn encMovkImm16(rd: Xn, imm16: u16, hw: u2) u32 {
    return 0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | @as(u32, rd);
}

/// `ADD Xd, Xn, #imm12` (no shift). 64-bit ADD imm with sh=0:
/// `1 00 10001 0 0 [imm12:12] [Rn:5] [Rd:5]` = `0x91000000` | …
pub fn encAddImm12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Xd, Xn, #imm12` (no shift). 64-bit SUB imm with sh=0:
/// `1 10 10001 0 0 [imm12:12] [Rn:5] [Rd:5]` = `0xD1000000` | …
pub fn encSubImm12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD Xd, Xn, Xm` (no shift). 64-bit ADD shifted-reg, shift=0:
/// `1 00 01011 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0x8B000000` | …
pub fn encAddReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Xd, Xn, Xm` (no shift). 64-bit SUB shifted-reg, shift=0:
/// `1 10 01011 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0xCB000000` | …
pub fn encSubReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LDR Xt, [Xn, #imm]` — load 64-bit at unsigned imm12 offset.
/// `byte_offset` MUST be 8-byte aligned; encoder shifts >>3 to
/// produce the imm12 field. Encoding (LDR 64-bit unsigned offs):
/// `1111 1001 01 [imm12:12] [Rn:5] [Rt:5]` = `0xF9400000` | …
pub fn encLdrImm(rt: Xn, rn: Xn, byte_offset: u15) u32 {
    const imm12: u12 = @intCast(byte_offset >> 3);
    return 0xF9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Xt, [Xn, #imm]` — store 64-bit at unsigned imm12 offset.
/// Same alignment constraint as `encLdrImm`. Encoding:
/// `1111 1001 00 [imm12:12] [Rn:5] [Rt:5]` = `0xF9000000` | …
pub fn encStrImm(rt: Xn, rn: Xn, byte_offset: u15) u32 {
    const imm12: u12 = @intCast(byte_offset >> 3);
    return 0xF9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `BR Xn` — unconditional branch to register.
/// Encoding: `1101 0110 0001 1111 0000 00 [Rn:5] 00000`
/// = `0xD61F0000` | (rn << 5).
pub fn encBr(rn: Xn) u32 {
    return 0xD61F0000 | (@as(u32, rn) << 5);
}

/// `MUL Xd, Xn, Xm` — alias for `MADD Xd, Xn, Xm, XZR`.
/// Encoding (64-bit MADD): `1 00 11011 000 [Rm:5] 0 [Ra:5] [Rn:5] [Rd:5]`
/// with Ra=31 (XZR). Base = `0x9B007C00` | (Rm<<16) | (Rn<<5) | Rd.
pub fn encMulReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `AND Xd, Xn, Xm` (no shift). 64-bit AND shifted-reg, shift=0:
/// `1 00 01010 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0x8A000000` | …
pub fn encAndReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x8A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ORR Xd, Xn, Xm` (no shift). 64-bit ORR shifted-reg, shift=0:
/// `1 01 01010 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0xAA000000` | …
pub fn encOrrReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xAA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `EOR Xd, Xn, Xm` (no shift). 64-bit EOR shifted-reg, shift=0:
/// `1 10 01010 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]` = `0xCA000000` | …
pub fn encEorReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xCA000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ============================================================
// W-register (32-bit) variants
//
// Wasm i32 ops are 32-bit modulo 2^32. The W-variants implicitly
// zero-extend the 32-bit result into the upper 32 bits of the
// 64-bit X-register, which is what the spec demands. Bit 31 of
// the encoding (sf) is the only structural difference vs the
// X-variants — when sf=0 the op is W; when sf=1 it's X.
// ============================================================

/// `ADD Wd, Wn, Wm` — 32-bit register add, no shift.
/// Encoding: same as ADD X but sf=0. Base = `0x0B000000`.
pub fn encAddRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x0B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Wd, Wn, Wm` — 32-bit register subtract, no shift. Base = `0x4B000000`.
pub fn encSubRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x4B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL Wd, Wn, Wm` — alias for `MADD Wd, Wn, Wm, WZR` (sf=0).
/// Base = `0x1B007C00`.
pub fn encMulRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1B007C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `AND Wd, Wn, Wm` (no shift). Base = `0x0A000000`.
pub fn encAndRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x0A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ORR Wd, Wn, Wm` (no shift). Base = `0x2A000000`.
pub fn encOrrRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x2A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `EOR Wd, Wn, Wm` (no shift). Base = `0x4A000000`.
pub fn encEorRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x4A000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LSL Wd, Wn, Wm` — variable left shift; ARM `LSLV`.
/// Encoding (32-bit LSLV):
///   `0 00 11010110 [Rm:5] 0010 00 [Rn:5] [Rd:5]` = `0x1AC02000`.
pub fn encLslvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LSR Wd, Wn, Wm` — variable logical right shift; ARM `LSRV`.
/// Encoding: `... 0010 01 ...` = `0x1AC02400`.
pub fn encLsrvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ASR Wd, Wn, Wm` — variable arithmetic right shift; ARM `ASRV`.
/// Encoding: `... 0010 10 ...` = `0x1AC02800`.
pub fn encAsrvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ============================================================
// Tests
//
// Bit patterns cross-checked against the Arm Architecture
// Reference Manual (DDI 0487 K.a) and `llvm-mc -triple=aarch64
// -show-encoding`. Each test cites the asm form so future readers
// can re-verify by pasting into `llvm-mc`.
// ============================================================

const testing = std.testing;

test "encRet x30 — `ret` (the canonical bare RET) → 0xD65F03C0" {
    try testing.expectEqual(@as(u32, 0xD65F03C0), encRet(30));
}

test "encRet x0 — `ret x0` → 0xD65F0000" {
    try testing.expectEqual(@as(u32, 0xD65F0000), encRet(0));
}

test "encMovzImm16 x0, #0 — `movz x0, #0` → 0xD2800000" {
    try testing.expectEqual(@as(u32, 0xD2800000), encMovzImm16(0, 0));
}

test "encMovzImm16 x0, #42 — `movz x0, #42` → 0xD2800540" {
    // imm16=42 (<<5)=0x540; rd=0; base=0xD2800000.
    try testing.expectEqual(@as(u32, 0xD2800540), encMovzImm16(0, 42));
}

test "encMovkImm16 x0, #1, lsl #16 — `movk x0, #1, lsl #16` → 0xF2A00020" {
    // hw=1 sets bit 21 (0x200000); imm16=1 (<<5)=0x20; base=0xF2800000.
    try testing.expectEqual(@as(u32, 0xF2A00020), encMovkImm16(0, 1, 1));
}

test "encAddImm12 x0, x1, #1 — `add x0, x1, #1` → 0x91000420" {
    // base 0x91000000; imm=1 (<<10)=0x400; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x91000420), encAddImm12(0, 1, 1));
}

test "encSubImm12 x0, x1, #4 — `sub x0, x1, #4` → 0xD1001020" {
    try testing.expectEqual(@as(u32, 0xD1001020), encSubImm12(0, 1, 4));
}

test "encAddReg x0, x1, x2 — `add x0, x1, x2` → 0x8B020020" {
    // rm=2 (<<16)=0x20000; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x8B020020), encAddReg(0, 1, 2));
}

test "encSubReg x3, x4, x5 — `sub x3, x4, x5` → 0xCB050083" {
    try testing.expectEqual(@as(u32, 0xCB050083), encSubReg(3, 4, 5));
}

test "encLdrImm x0, [x1, #0] — `ldr x0, [x1]` → 0xF9400020" {
    try testing.expectEqual(@as(u32, 0xF9400020), encLdrImm(0, 1, 0));
}

test "encLdrImm x0, [x1, #8] — `ldr x0, [x1, #8]` → 0xF9400420" {
    try testing.expectEqual(@as(u32, 0xF9400420), encLdrImm(0, 1, 8));
}

test "encStrImm x0, [x1, #16] — `str x0, [x1, #16]` → 0xF9000820" {
    try testing.expectEqual(@as(u32, 0xF9000820), encStrImm(0, 1, 16));
}

test "encBr x16 — `br x16` → 0xD61F0200" {
    try testing.expectEqual(@as(u32, 0xD61F0200), encBr(16));
}

test "encMulReg x0, x1, x2 — `mul x0, x1, x2` → 0x9B027C20" {
    // base 0x9B007C00; rm=2 (<<16)=0x20000; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x9B027C20), encMulReg(0, 1, 2));
}

test "encAndReg x0, x1, x2 — `and x0, x1, x2` → 0x8A020020" {
    try testing.expectEqual(@as(u32, 0x8A020020), encAndReg(0, 1, 2));
}

test "encOrrReg x0, x1, x2 — `orr x0, x1, x2` → 0xAA020020" {
    try testing.expectEqual(@as(u32, 0xAA020020), encOrrReg(0, 1, 2));
}

test "encEorReg x0, x1, x2 — `eor x0, x1, x2` → 0xCA020020" {
    try testing.expectEqual(@as(u32, 0xCA020020), encEorReg(0, 1, 2));
}

test "encAddRegW w0, w1, w2 — `add w0, w1, w2` → 0x0B020020" {
    try testing.expectEqual(@as(u32, 0x0B020020), encAddRegW(0, 1, 2));
}

test "encSubRegW w0, w1, w2 — `sub w0, w1, w2` → 0x4B020020" {
    try testing.expectEqual(@as(u32, 0x4B020020), encSubRegW(0, 1, 2));
}

test "encMulRegW w0, w1, w2 — `mul w0, w1, w2` → 0x1B027C20" {
    try testing.expectEqual(@as(u32, 0x1B027C20), encMulRegW(0, 1, 2));
}

test "encAndRegW w0, w1, w2 — `and w0, w1, w2` → 0x0A020020" {
    try testing.expectEqual(@as(u32, 0x0A020020), encAndRegW(0, 1, 2));
}

test "encOrrRegW w0, w1, w2 — `orr w0, w1, w2` → 0x2A020020" {
    try testing.expectEqual(@as(u32, 0x2A020020), encOrrRegW(0, 1, 2));
}

test "encEorRegW w0, w1, w2 — `eor w0, w1, w2` → 0x4A020020" {
    try testing.expectEqual(@as(u32, 0x4A020020), encEorRegW(0, 1, 2));
}

test "encLslvRegW w0, w1, w2 — `lsl w0, w1, w2` → 0x1AC22020" {
    try testing.expectEqual(@as(u32, 0x1AC22020), encLslvRegW(0, 1, 2));
}

test "encLsrvRegW w0, w1, w2 — `lsr w0, w1, w2` → 0x1AC22420" {
    try testing.expectEqual(@as(u32, 0x1AC22420), encLsrvRegW(0, 1, 2));
}

test "encAsrvRegW w0, w1, w2 — `asr w0, w1, w2` → 0x1AC22820" {
    try testing.expectEqual(@as(u32, 0x1AC22820), encAsrvRegW(0, 1, 2));
}
