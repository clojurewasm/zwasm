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

/// `LDR Wt, [Xn, #imm]` — load 32-bit at unsigned imm12 offset
/// scaled by 4. byte_offset MUST be 4-byte aligned and < 16384.
/// Encoding (32-bit LDR unsigned offset):
///   `1011 1001 01 [imm12:12] [Rn:5] [Rt:5]` = `0xB9400000`.
pub fn encLdrImmW(rt: Xn, rn: Xn, byte_offset: u14) u32 {
    const imm12: u12 = @intCast(byte_offset >> 2);
    return 0xB9400000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Wt, [Xn, #imm]` — store 32-bit at unsigned imm12 offset
/// scaled by 4. Encoding:
///   `1011 1001 00 [imm12:12] [Rn:5] [Rt:5]` = `0xB9000000`.
pub fn encStrImmW(rt: Xn, rn: Xn, byte_offset: u14) u32 {
    const imm12: u12 = @intCast(byte_offset >> 2);
    return 0xB9000000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
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

/// `ROR Wd, Wn, Wm` — variable right rotate; ARM `RORV`.
/// Encoding: `... 0010 11 ...` = `0x1AC02C00`.
pub fn encRorvRegW(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x1AC02C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `CMP Wn, Wm` — alias for `SUBS WZR, Wn, Wm`. Sets NZCV; the
/// result is discarded into WZR. Encoding (32-bit SUBS shifted-
/// reg, shift=0): `0 11 01011 00 0 [Rm:5] 000000 [Rn:5] 11111`
/// = `0x6B00001F` | (Rm<<16) | (Rn<<5).
pub fn encCmpRegW(rn: Xn, rm: Xn) u32 {
    return 0x6B00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
}

/// `CMP Wn, #imm12` — alias for `SUBS WZR, Wn, #imm12, lsl #0`.
/// Encoding (32-bit SUBS imm, sh=0): `0 11 10001 0 0 [imm12:12]
/// [Rn:5] 11111` = `0x7100001F` | (imm12<<10) | (Rn<<5).
pub fn encCmpImmW(rn: Xn, imm12: u12) u32 {
    return 0x7100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
}

/// `CMP Xn, Xm` — alias for `SUBS XZR, Xn, Xm`. 64-bit form.
/// Encoding: `1 11 01011 00 0 [Rm:5] 000000 [Rn:5] 11111`
/// = `0xEB00001F` | (Rm<<16) | (Rn<<5).
pub fn encCmpRegX(rn: Xn, rm: Xn) u32 {
    return 0xEB00001F | (@as(u32, rm) << 16) | (@as(u32, rn) << 5);
}

/// `CMP Xn, #imm12` — alias for `SUBS XZR, Xn, #imm12, lsl #0`.
/// 64-bit form. Encoding:
///   `1 11 10001 0 0 [imm12:12] [Rn:5] 11111` = `0xF100001F`
///   | (imm12<<10) | (Rn<<5).
pub fn encCmpImmX(rn: Xn, imm12: u12) u32 {
    return 0xF100001F | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5);
}

/// ARM condition codes (4-bit). The cond fed to `encCsetW` is
/// the encoded condition under which the result becomes 0 (the
/// CSINC alias inverts the user's "set if X" condition by XOR-1
/// with the lowest bit; this enum uses the encoded form so
/// callers do the XOR explicitly when needed).
pub const Cond = enum(u4) {
    eq = 0x0,
    ne = 0x1,
    hs = 0x2,  // unsigned >=
    lo = 0x3,  // unsigned <
    mi = 0x4,
    pl = 0x5,
    vs = 0x6,
    vc = 0x7,
    hi = 0x8,  // unsigned >
    ls = 0x9,  // unsigned <=
    ge = 0xA,  // signed >=
    lt = 0xB,  // signed <
    gt = 0xC,  // signed >
    le = 0xD,  // signed <=
};

/// Invert the lowest bit of a `Cond` — the relationship between
/// "set if X" and the encoded form for `CSET`/`CSINC` aliases.
/// `EQ <-> NE`, `LT <-> GE`, `LO <-> HS`, etc.
pub fn invertCond(c: Cond) Cond {
    return @enumFromInt(@intFromEnum(c) ^ 1);
}

/// `CSET Wd, cond` — set Wd to 1 if cond holds, else 0. Encoded
/// as `CSINC Wd, WZR, WZR, invert(cond)`. The 32-bit CSINC:
/// `0 00 11010100 [Rm:5] [cond:4] 01 [Rn:5] [Rd:5]` with Rm = Rn
/// = WZR (31). Base = `0x1A9F07E0` | (encoded_cond<<12) | Rd.
pub fn encCsetW(rd: Xn, set_if: Cond) u32 {
    const enc = invertCond(set_if);
    return 0x1A9F07E0 | (@as(u32, @intFromEnum(enc)) << 12) | @as(u32, rd);
}

/// `CLZ Wd, Wn` — count leading zeros (32-bit). The §9.7 / 7.3
/// sub-b4 i32.clz handler emits this directly.
/// Encoding (Data Processing 1-source, sf=0):
///   `0 1 0 11010110 00000 000100 [Rn:5] [Rd:5]` = `0x5AC01000`.
pub fn encClzW(rd: Xn, rn: Xn) u32 {
    return 0x5AC01000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `RBIT Wd, Wn` — reverse bits (32-bit). i32.ctz lowers to
/// `RBIT scratch, val ; CLZ result, scratch` (the canonical
/// ARM idiom). Encoding (Data Processing 1-source, sf=0):
///   `0 1 0 11010110 00000 000000 [Rn:5] [Rd:5]` = `0x5AC00000`.
pub fn encRbitW(rd: Xn, rn: Xn) u32 {
    return 0x5AC00000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ============================================================
// 64-bit X-variants of the i32 sub-b ops (sf=1 form).
// ============================================================

/// `LSL Xd, Xn, Xm` — 64-bit variable left shift (LSLV X form).
/// Same as LSLV W with sf=1. Encoding base: `0x9AC02000`.
pub fn encLslvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `LSR Xd, Xn, Xm` — 64-bit variable logical right shift.
pub fn encLsrvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ASR Xd, Xn, Xm` — 64-bit variable arithmetic right shift.
pub fn encAsrvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ROR Xd, Xn, Xm` — 64-bit variable right rotate.
pub fn encRorvRegX(rd: Xn, rn: Xn, rm: Xn) u32 {
    return 0x9AC02C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `CLZ Xd, Xn` — 64-bit count leading zeros. sf=1 vs encClzW.
/// Encoding: `1 1 0 11010110 00000 000100 [Rn:5] [Rd:5]` = `0xDAC01000`.
pub fn encClzX(rd: Xn, rn: Xn) u32 {
    return 0xDAC01000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `RBIT Xd, Xn` — 64-bit reverse bits.
/// Encoding: `1 1 0 11010110 00000 000000 [Rn:5] [Rd:5]` = `0xDAC00000`.
pub fn encRbitX(rd: Xn, rn: Xn) u32 {
    return 0xDAC00000 | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FMOV Dd, Xn` — move 64-bit GPR to lower 64 of V-register
/// (D-form). Used by i64.popcnt to stage the value into the
/// SIMD unit. Encoding (FMOV general, sf=1, type=01 double,
/// opcode=111):
///   `1 0 0 11110 01 1 00 111 000000 [Rn:5] [Rd:5]` = `0x9E670000`.
/// Verified via `clang -target arm64-apple-darwin` assembler.
pub fn encFmovDtoFromX(vd: Vn, xn: Xn) u32 {
    return 0x9E670000 | (@as(u32, xn) << 5) | @as(u32, vd);
}

/// V-register index 0..31 — ARM SIMD/FP register file. Same u5
/// width as `Xn` but a separate type for documentation; the
/// integer regalloc never allocates these (the §9.7 / 7.3
/// sub-b5 popcnt handler uses V31 as fixed scratch — it's
/// caller-saved per AAPCS64 so emit can clobber it freely).
pub const Vn = u5;

/// `FMOV S<d>, W<n>` — move 32-bit GPR to lower 32 of V<d>.
/// Encoding (FMOV general, type=00 single, opcode=111, sf=0):
///   `0 0 0 11110 00 1 00 111 000000 [Rn:5] [Rd:5]` = `0x1E270000`.
/// Verified via `clang -target arm64-apple-darwin` assembler.
pub fn encFmovStoFromW(vd: Vn, wn: Xn) u32 {
    return 0x1E270000 | (@as(u32, wn) << 5) | @as(u32, vd);
}

/// `CNT V<d>.8B, V<n>.8B` — Advanced SIMD count bits per byte
/// (8-byte form, lower 64 bits). Encoding:
///   `0 0 0 01110 00 1 00000 00101 1 0 [Rn:5] [Rd:5]` = `0x0E205800`.
pub fn encCntV8B(vd: Vn, vn: Vn) u32 {
    return 0x0E205800 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `ADDV B<d>, V<n>.8B` — Advanced SIMD across-vector add of
/// bytes (sums 8 bytes into byte 0 of Vd; upper bytes zero).
/// Encoding:
///   `0 0 0 01110 00 1 1000 1 1011 10 [Rn:5] [Rd:5]` = `0x0E31B800`.
pub fn encAddvB8B(vd: Vn, vn: Vn) u32 {
    return 0x0E31B800 | (@as(u32, vn) << 5) | @as(u32, vd);
}

/// `UMOV W<d>, V<n>.B[0]` — Advanced SIMD extract byte 0 to
/// 32-bit GPR (zero-extends). Encoding:
///   `0 0 0 01110 000 00001 0 0111 1 [Rn:5] [Rd:5]` = `0x0E013C00`.
/// (imm5=00001 selects B-element, index 0.)
pub fn encUmovWFromVB0(wd: Xn, vn: Vn) u32 {
    return 0x0E013C00 | (@as(u32, vn) << 5) | @as(u32, wd);
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

test "encStrImmW w9, [sp, #0] — `str w9, [sp]` → 0xB90003E9" {
    try testing.expectEqual(@as(u32, 0xB90003E9), encStrImmW(9, 31, 0));
}

test "encLdrImmW w10, [sp, #8] — `ldr w10, [sp, #8]` → 0xB9400BEA" {
    // imm12 = 8>>2 = 2; <<10 = 0x800.
    try testing.expectEqual(@as(u32, 0xB9400BEA), encLdrImmW(10, 31, 8));
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

test "encRorvRegW w0, w1, w2 — `ror w0, w1, w2` → 0x1AC22C20" {
    try testing.expectEqual(@as(u32, 0x1AC22C20), encRorvRegW(0, 1, 2));
}

test "encCmpRegW w1, w2 — `cmp w1, w2` → 0x6B02003F" {
    // base 0x6B00001F; rm=2 (<<16)=0x20000; rn=1 (<<5)=0x20.
    try testing.expectEqual(@as(u32, 0x6B02003F), encCmpRegW(1, 2));
}

test "encCmpImmW w1, #0 — `cmp w1, #0` → 0x7100003F" {
    try testing.expectEqual(@as(u32, 0x7100003F), encCmpImmW(1, 0));
}

test "encCmpImmW w1, #5 — `cmp w1, #5` → 0x7100143F" {
    // imm12=5 (<<10)=0x1400; rn=1 (<<5)=0x20.
    try testing.expectEqual(@as(u32, 0x7100143F), encCmpImmW(1, 5));
}

test "encCmpRegX x1, x2 — `cmp x1, x2` → 0xEB02003F" {
    try testing.expectEqual(@as(u32, 0xEB02003F), encCmpRegX(1, 2));
}

test "encCmpImmX x1, #0 — `cmp x1, #0` → 0xF100003F" {
    try testing.expectEqual(@as(u32, 0xF100003F), encCmpImmX(1, 0));
}

test "invertCond: eq <-> ne, lt <-> ge, lo <-> hs" {
    try testing.expectEqual(Cond.ne, invertCond(.eq));
    try testing.expectEqual(Cond.eq, invertCond(.ne));
    try testing.expectEqual(Cond.ge, invertCond(.lt));
    try testing.expectEqual(Cond.lt, invertCond(.ge));
    try testing.expectEqual(Cond.hs, invertCond(.lo));
    try testing.expectEqual(Cond.lo, invertCond(.hs));
}

test "encCsetW w0, eq — `cset w0, eq` → 0x1A9F17E0" {
    // CSET Wd, EQ → CSINC Wd, WZR, WZR, NE.
    // base 0x1A9F07E0; cond=NE (0x1 << 12) = 0x1000; Rd=0.
    try testing.expectEqual(@as(u32, 0x1A9F17E0), encCsetW(0, .eq));
}

test "encCsetW w3, lt — `cset w3, lt` → 0x1A9FA7E3" {
    // invert(LT=0xB) = 0xA = GE; (0xA << 12) = 0xA000; Rd=3.
    try testing.expectEqual(@as(u32, 0x1A9FA7E3), encCsetW(3, .lt));
}

test "encClzW w0, w1 — `clz w0, w1` → 0x5AC01020" {
    // base 0x5AC01000; rn=1 (<<5)=0x20; rd=0.
    try testing.expectEqual(@as(u32, 0x5AC01020), encClzW(0, 1));
}

test "encRbitW w0, w1 — `rbit w0, w1` → 0x5AC00020" {
    try testing.expectEqual(@as(u32, 0x5AC00020), encRbitW(0, 1));
}

test "encLslvRegX x0, x1, x2 — `lsl x0, x1, x2` → 0x9AC22020" {
    try testing.expectEqual(@as(u32, 0x9AC22020), encLslvRegX(0, 1, 2));
}

test "encLsrvRegX x0, x1, x2 — `lsr x0, x1, x2` → 0x9AC22420" {
    try testing.expectEqual(@as(u32, 0x9AC22420), encLsrvRegX(0, 1, 2));
}

test "encAsrvRegX x0, x1, x2 — `asr x0, x1, x2` → 0x9AC22820" {
    try testing.expectEqual(@as(u32, 0x9AC22820), encAsrvRegX(0, 1, 2));
}

test "encRorvRegX x0, x1, x2 — `ror x0, x1, x2` → 0x9AC22C20" {
    try testing.expectEqual(@as(u32, 0x9AC22C20), encRorvRegX(0, 1, 2));
}

test "encClzX x0, x1 — `clz x0, x1` → 0xDAC01020" {
    try testing.expectEqual(@as(u32, 0xDAC01020), encClzX(0, 1));
}

test "encRbitX x0, x1 — `rbit x0, x1` → 0xDAC00020" {
    try testing.expectEqual(@as(u32, 0xDAC00020), encRbitX(0, 1));
}

test "encFmovDtoFromX d31, x9 — `fmov d31, x9` → 0x9E67013F" {
    try testing.expectEqual(@as(u32, 0x9E67013F), encFmovDtoFromX(31, 9));
}

// V-register encodings cross-checked via `clang -target
// arm64-apple-darwin` assembler. See verifier session in
// commit history (popcnt sub-b5 prep).

test "encFmovStoFromW s0, w0 — `fmov s0, w0` → 0x1E270000" {
    try testing.expectEqual(@as(u32, 0x1E270000), encFmovStoFromW(0, 0));
}

test "encFmovStoFromW s31, w9 — `fmov s31, w9` → 0x1E27013F" {
    // Rn=9 (<<5)=0x120; Rd=31; base=0x1E270000.
    try testing.expectEqual(@as(u32, 0x1E27013F), encFmovStoFromW(31, 9));
}

test "encCntV8B v0.8b ← v0.8b — `cnt v0.8b, v0.8b` → 0x0E205800" {
    try testing.expectEqual(@as(u32, 0x0E205800), encCntV8B(0, 0));
}

test "encCntV8B v31.8b ← v31.8b — `cnt v31.8b, v31.8b` → 0x0E205BFF" {
    try testing.expectEqual(@as(u32, 0x0E205BFF), encCntV8B(31, 31));
}

test "encAddvB8B b0 ← v0.8b — `addv b0, v0.8b` → 0x0E31B800" {
    try testing.expectEqual(@as(u32, 0x0E31B800), encAddvB8B(0, 0));
}

test "encAddvB8B b31 ← v31.8b — `addv b31, v31.8b` → 0x0E31BBFF" {
    try testing.expectEqual(@as(u32, 0x0E31BBFF), encAddvB8B(31, 31));
}

test "encUmovWFromVB0 w0 ← v0.B[0] — `umov w0, v0.b[0]` → 0x0E013C00" {
    try testing.expectEqual(@as(u32, 0x0E013C00), encUmovWFromVB0(0, 0));
}

test "encUmovWFromVB0 w10 ← v31.B[0] — `umov w10, v31.b[0]` → 0x0E013FEA" {
    try testing.expectEqual(@as(u32, 0x0E013FEA), encUmovWFromVB0(10, 31));
}
