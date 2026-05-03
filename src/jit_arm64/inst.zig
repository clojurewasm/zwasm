//! ARM64 instruction encoder (§9.7 / 7.2 chunk a).
//!
//! Produces fixed-width `u32` encodings for the AArch64 ops the
//! §9.7 / 7.3 emit pass uses: register-register and register-
//! immediate ALU, MOV-immediate (movz / movk), branches (B / BL
//! / BR / RET), and load / store immediate-offset (LDR / STR).
//!
//! Bit patterns are taken from the Arm Architecture Reference
//! Manual (DDI 0487, A64 base instructions). Each `pub fn enc<X>`
//! returns the little-endian `u32` ready to write to the code
//! buffer; the §9.7 / 7.3 emit pass packs them into a `[]u8` via
//! `std.mem.writeInt(u32, ..., .little)`.
//!
//! Phase-7 / 7.2 chunk-a scope: enough opcodes to lower the §9.7
//! / 7.4 spec testsuite's MVP arithmetic + control flow + memory
//! ops via the §9.7 / 7.1 greedy-local regalloc. Float / SIMD /
//! exception / atomic encodings land alongside their phases (9 /
//! 10).
//!
//! Zone 2 (`src/jit_arm64/`) — must not import `src/jit_x86/`
//! per ROADMAP §A3 (Zone-2 inter-arch isolation).

const std = @import("std");

/// X-register index 0..30 (XZR = 31 is special). The encoder
/// accepts the raw u5 to keep the surface honest about ARM64's
/// 5-bit register field; ABI helpers in `abi.zig` map regalloc
/// slot ids to specific Xn values.
pub const Xn = u5;

/// Special-purpose: zero register (read as 0, write discards).
pub const xzr: Xn = 31;
/// Special-purpose: stack pointer (per AAPCS64).
pub const sp_reg: Xn = 31; // SP and XZR share encoding 31; semantics depend on opcode.

/// `RET Xn` — return via Xn (default Xn = X30 / link register).
/// Encoding: `1101 0110 0101 1111 0000 00 [Rn:5] 00000`.
pub fn encRet(rn: Xn) u32 {
    return 0xD65F0000 | (@as(u32, rn) << 5);
}

/// `MOV Xd, #imm16` lsl 0 — i.e. `MOVZ Xd, #imm16`.
/// Encoding (64-bit MOVZ, hw=0): `1 10 100101 00 [imm16:16] [Rd:5]`.
/// Higher 16-bit lanes use `MOVK` with hw=1..3.
pub fn encMovzImm16(rd: Xn, imm16: u16) u32 {
    return 0xD2800000 | (@as(u32, imm16) << 5) | @as(u32, rd);
}

/// `MOVK Xd, #imm16, lsl #(hw*16)` — keep-other-bits insert.
/// Encoding (64-bit MOVK): `1 11 100101 [hw:2] [imm16:16] [Rd:5]`.
pub fn encMovkImm16(rd: Xn, imm16: u16, hw: u2) u32 {
    return 0xF2800000 | (@as(u32, hw) << 21) | (@as(u32, imm16) << 5) | @as(u32, rd);
}

/// `ADD Xd, Xn, #imm12` — add immediate (no shift).
/// Encoding (64-bit ADD imm, sh=0): `1 00 10001 0 0 [imm12:12] [Rn:5] [Rd:5]`.
pub fn encAddImm12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0x91000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Xd, Xn, #imm12` — subtract immediate (no shift).
/// Encoding (64-bit SUB imm, sh=0): `1 10 10001 0 0 [imm12:12] [Rn:5] [Rd:5]`.
pub fn encSubImm12(rd: Xn, rn: Xn, imm12: u12) u32 {
    return 0xD1000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD Xd, Xn, Xm` — add register, no shift.
/// Encoding (64-bit ADD shifted reg, shift=0, imm6=0):
/// `1 00 01011 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]`.
pub fn encAddReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x8B000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB Xd, Xn, Xm` — subtract register, no shift.
/// Encoding (64-bit SUB shifted reg, shift=0, imm6=0):
/// `1 10 01011 00 0 [Rm:5] 000000 [Rn:5] [Rd:5]`.
pub fn encSubReg(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0xCB000000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LDR Xt, [Xn, #imm]` — load 64-bit immediate offset (unsigned
/// imm12 scaled by 8 → byte offset 0..32760, 8-byte aligned).
/// Encoding (LDR 64-bit unsigned offset):
/// `1111 1001 01 [imm12:12] [Rn:5] [Rt:5]`.
/// `byte_offset` must be 8-byte aligned; the encoder shifts >> 3
/// to produce the imm12 field (caller responsible for alignment).
pub fn encLdrImm(rt: Xn, rn: Xn, byte_offset: u15) u32 {
    const imm12: u12 = @intCast(byte_offset >> 3);
    return 0xF9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Xt, [Xn, #imm]` — store 64-bit immediate offset.
/// Encoding (STR 64-bit unsigned offset):
/// `1111 1001 00 [imm12:12] [Rn:5] [Rt:5]`.
pub fn encStrImm(rt: Xn, rn: Xn, byte_offset: u15) u32 {
    const imm12: u12 = @intCast(byte_offset >> 3);
    return 0xF9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `BR Xn` — branch to register.
/// Encoding: `1101 0110 0001 1111 0000 00 [Rn:5] 00000`.
pub fn encBr(rn: Xn) u32 {
    return 0xD61F0000 | (@as(u32, rn) << 5);
}

const testing = std.testing;

// Bit patterns cross-checked against the Arm ARM (DDI 0487 K.a)
// and `llvm-mc -triple=aarch64 -show-encoding` on Mac aarch64.
// Each test name records the asm form so future readers can
// re-verify by pasting the form into `llvm-mc`.

test "encRet x30 produces 0xD65F03C0 (RET)" {
    // `ret`  →  `0xD65F03C0` (default: ret x30)
    try testing.expectEqual(@as(u32, 0xD65F03C0), encRet(30));
}

test "encRet x0 produces 0xD65F0000 (ret x0)" {
    try testing.expectEqual(@as(u32, 0xD65F0000), encRet(0));
}

test "encMovzImm16 x0, #0 → 0xD2800000" {
    // `movz x0, #0`  →  `0xD2800000`
    try testing.expectEqual(@as(u32, 0xD2800000), encMovzImm16(0, 0));
}

test "encMovzImm16 x0, #42 → 0xD2800540" {
    // `movz x0, #42` → bits: 1101 0010 1000 0000 0000 0101 0100 0000
    // = 0xD2800540 (42 << 5 = 0x540, plus base 0xD2800000)
    try testing.expectEqual(@as(u32, 0xD2800540), encMovzImm16(0, 42));
}

test "encMovkImm16 x0, #1, lsl #16 → 0xF2A00020" {
    // `movk x0, #1, lsl #16` → 0xF2A00020
    // (hw=1 sets bit 21; imm=1 shifted left 5)
    try testing.expectEqual(@as(u32, 0xF2A00020), encMovkImm16(0, 1, 1));
}

test "encAddImm12 x0, x1, #1 → 0x91000420" {
    // `add x0, x1, #1` → 0x91000420
    // base 0x91000000; imm12=1 (<<10)=0x400; rn=1 (<<5)=0x20; rd=0
    try testing.expectEqual(@as(u32, 0x91000420), encAddImm12(0, 1, 1));
}

test "encSubImm12 x0, x1, #4 → 0xD1001020" {
    // `sub x0, x1, #4` → 0xD1001020
    try testing.expectEqual(@as(u32, 0xD1001020), encSubImm12(0, 1, 4));
}

test "encAddReg x0, x1, x2 → 0x8B020020" {
    // `add x0, x1, x2` → 0x8B020020
    // rm=2 (<<16)=0x20000; rn=1 (<<5)=0x20; rd=0
    try testing.expectEqual(@as(u32, 0x8B020020), encAddReg(0, 1, 2));
}

test "encSubReg x3, x4, x5 → 0xCB050083" {
    // `sub x3, x4, x5` → 0xCB050083
    // rm=5 (<<16)=0x50000; rn=4 (<<5)=0x80; rd=3
    try testing.expectEqual(@as(u32, 0xCB050083), encSubReg(3, 4, 5));
}

test "encLdrImm x0, [x1, #0] → 0xF9400020" {
    // `ldr x0, [x1]` → 0xF9400020
    try testing.expectEqual(@as(u32, 0xF9400020), encLdrImm(0, 1, 0));
}

test "encLdrImm x0, [x1, #8] → 0xF9400420" {
    // `ldr x0, [x1, #8]` → 0xF9400420
    // imm12 = 8>>3 = 1; <<10 = 0x400
    try testing.expectEqual(@as(u32, 0xF9400420), encLdrImm(0, 1, 8));
}

test "encStrImm x0, [x1, #16] → 0xF9000820" {
    // `str x0, [x1, #16]` → 0xF9000820
    // imm12 = 16>>3 = 2; <<10 = 0x800
    try testing.expectEqual(@as(u32, 0xF9000820), encStrImm(0, 1, 16));
}

test "encBr x16 → 0xD61F0200" {
    // `br x16` → 0xD61F0200
    try testing.expectEqual(@as(u32, 0xD61F0200), encBr(16));
}
