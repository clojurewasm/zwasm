//! ARM64 NEON instruction encoders (§9.9 / 9.5 per ADR-0041).
//!
//! Foundational SIMD-128 encoders covering the MVP subset
//! needed by §9.9/9.5-a:
//!
//! - `LDR Q<rt>, [Xn, #imm]` — load 128-bit (16-byte stride).
//! - `STR Q<rt>, [Xn, #imm]` — store 128-bit.
//! - `ORR Vd.16B, Vn.16B, Vn.16B` — vector reg-to-reg move
//!   (ARM convention; `MOV V<d>.16B, V<n>.16B` is an alias).
//! - `DUP Vd.4S, Wn` — broadcast i32 → 4× i32 lanes (i32x4.
//!   splat).
//! - `ADD Vd.4S, Vn.4S, Vm.4S` — vector i32x4 add
//!   (representative SIMD binop for §9.5 anchoring).
//!
//! Bit patterns from the Arm Architecture Reference Manual
//! (DDI 0487, A64 SIMD&FP instructions). Each `pub fn enc<X>`
//! returns the little-endian `u32` ready to write to the code
//! buffer; the §9.9/9.5+ emit pass packs them into `[]u8` via
//! `std.mem.writeInt(u32, ..., .little)`.
//!
//! Per ADR-0041 §"Decision" / 2: Q registers map to the
//! existing FP-class register pool (V0-V31; allocatable
//! V16-V28 per ADR-0027 + D-037). The 128-bit Q view shares
//! the underlying register file with scalar D/S forms — the
//! `ShapeTag` axis on `Allocation` (§9.4) disambiguates which
//! view emit should use.
//!
//! Zone 2 (`src/engine/codegen/arm64/`) — must NOT import
//! `src/engine/codegen/x86_64/` per ROADMAP §A3.

const std = @import("std");

/// V-register index 0..31. NEON's 128-bit view is `Q<n>`;
/// the same index also names the 64-bit `D<n>`, 32-bit `S<n>`,
/// 16-bit `H<n>`, and 8-bit `B<n>` views — opcode determines
/// which width is in use.
pub const Vn = u5;

/// X-register index alias (re-exported from `inst.zig`'s shape
/// for callers that import only `inst_neon.zig`). The encoders
/// here treat GPR sources as `Vn`-shaped u5 since the 5-bit
/// register field is identical across X and V register banks.
pub const Xn = u5;

// =====================================================================
// Memory ops (128-bit)
// =====================================================================

/// `LDR Q<rt>, [X<n>, #imm]` — load 128-bit at unsigned imm12
/// offset scaled by 16. `byte_offset` MUST be 16-byte aligned
/// and < 65536. Encoder shifts >>4 to produce the imm12 field.
///
/// Encoding (SIMD&FP load unsigned offset, size=00, opc=11):
///   `00 111 1 01 11 [imm12:12] [Rn:5] [Rt:5]`
///   = `0x3DC00000` | (imm12 << 10) | (Rn << 5) | Rt
///
/// Per Arm IHI 0055 §C7.2.184. The Q form (size=00, opc=11)
/// is distinct from D (size=11, opc=01) and S (size=10,
/// opc=01) — opcode bits select the 128-bit view.
pub fn encLdrQImm(rt: Vn, rn: Xn, byte_offset: u16) u32 {
    const imm12: u12 = @intCast(byte_offset >> 4);
    return 0x3DC00000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

/// `STR Q<rt>, [X<n>, #imm]` — store 128-bit at unsigned imm12
/// offset scaled by 16. Same alignment constraint as
/// `encLdrQImm`.
///
/// Encoding (SIMD&FP store unsigned offset, size=00, opc=10):
///   `00 111 1 01 10 [imm12:12] [Rn:5] [Rt:5]`
///   = `0x3D800000` | (imm12 << 10) | (Rn << 5) | Rt
///
/// Per Arm IHI 0055 §C7.2.337.
pub fn encStrQImm(rt: Vn, rn: Xn, byte_offset: u16) u32 {
    const imm12: u12 = @intCast(byte_offset >> 4);
    return 0x3D800000 | (@as(u32, imm12) << 10) | (@as(u32, rn) << 5) | @as(u32, rt);
}

// =====================================================================
// Register-to-register moves
// =====================================================================

/// `ORR V<d>.16B, V<n>.16B, V<m>.16B` — bitwise OR vector.
/// Used as the canonical 128-bit register-to-register move
/// (`MOV V<d>.16B, V<n>.16B` is an alias for `ORR V<d>.16B,
/// V<n>.16B, V<n>.16B`).
///
/// Encoding (SIMD ORR vector, Q=1):
///   `0 1 0 01110 1 0 1 [Rm:5] 0 00111 [Rn:5] [Rd:5]`
///   = `0x4EA01C00` | (Rm << 16) | (Rn << 5) | Rd
///
/// Per Arm IHI 0055 §C7.2.246.
pub fn encOrrV16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA01C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV V<d>.16B, V<n>.16B` — alias for `ORR V<d>.16B, V<n>.
/// 16B, V<n>.16B`. Convenience helper for SIMD reg-to-reg
/// move; emit pass uses this when copying v128 vregs in
/// merges or function-result marshalling.
pub fn encMovV16B(rd: Vn, rn: Vn) u32 {
    return encOrrV16B(rd, rn, rn);
}

// =====================================================================
// Splat (broadcast scalar to all lanes)
// =====================================================================

/// `DUP V<d>.4S, W<n>` — broadcast 32-bit GPR value to all
/// four 32-bit lanes of V<d> (i32x4.splat).
///
/// Encoding (SIMD DUP element from GPR, Q=1, imm5=00100 for
/// 4S):
///   `0 1 0 01110 000 [imm5:5] 0 0001 1 [Rn:5] [Rd:5]`
///   imm5 = 0b00100 (4S shape) → bits[20:16] = 00100
///   = `0x4E040C00` | (Rn << 5) | Rd
///
/// Per Arm IHI 0055 §C7.2.106. 4S form: imm5=xx100 with
/// xx=00 (no element index since SIMD-from-GPR uses only
/// the size-encoding bits).
pub fn encDup4S(rd: Vn, rn: Xn) u32 {
    return 0x4E040C00 | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Integer arithmetic (i32x4)
// =====================================================================

/// `ADD V<d>.4S, V<n>.4S, V<m>.4S` — element-wise i32x4 add.
///
/// Encoding (SIMD ADD vector, size=10, Q=1):
///   `0 1 0 01110 [size:2] 1 [Rm:5] 100001 [Rn:5] [Rd:5]`
///   size = 10 (32-bit lanes / 4S) → bits[23:22] = 10
///   = `0x4EA08400` | (Rm << 16) | (Rn << 5) | Rd
///
/// Per Arm IHI 0055 §C7.2.5.
pub fn encAdd4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Lane access (extract / replace)
// =====================================================================

/// `UMOV W<rd>, V<n>.S[lane]` — copy 32-bit lane from V<n>.4S
/// into W<rd> (zero-extended). Used by `i32x4.extract_lane`.
/// `lane` ∈ 0..3.
///
/// Encoding (SIMD UMOV, S element form, Q=0):
///   `0 0 0 01110 000 [imm5:5] 0 0111 1 [Rn:5] [Rd:5]`
///   imm5 = (lane << 3) | 0b00100 (S-element discriminator).
///   Base = `0x0E003C00`.
///
/// Per Arm IHI 0055 §C7.2.371. The S form is the 32-bit lane
/// view; UMOV (B/H) and SMOV (B/H/S signed-extending) variants
/// land in 9.6 alongside i8x16 / i16x8 lane handlers.
pub fn encUmovWFromS(rd: Xn, rn: Vn, lane: u2) u32 {
    const imm5: u32 = (@as(u32, lane) << 3) | 0b00100;
    return 0x0E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.S[lane], W<n>` — insert 32-bit GPR W<n> into V<d>.
/// 4S lane. Used by `i32x4.replace_lane`. `lane` ∈ 0..3.
///
/// Encoding (SIMD INS general from GPR, S element form):
///   `0 1 0 01110 000 [imm5:5] 0 0011 1 [Rn:5] [Rd:5]`
///   imm5 same as UMOV S form. Base = `0x4E001C00`.
///
/// Per Arm IHI 0055 §C7.2.155.
pub fn encInsSFromW(rd: Vn, rn: Xn, lane: u2) u32 {
    const imm5: u32 = (@as(u32, lane) << 3) | 0b00100;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "encLdrQImm: V0, [X1, #0]" {
    // LDR Q0, [X1] = LDR Q0, [X1, #0]
    // 0x3DC00000 | (0 << 10) | (1 << 5) | 0 = 0x3DC00020
    try testing.expectEqual(@as(u32, 0x3DC00020), encLdrQImm(0, 1, 0));
}

test "encLdrQImm: V0, [X1, #16] (imm12=1)" {
    // imm12 = 16/16 = 1
    // 0x3DC00000 | (1 << 10) | (1 << 5) | 0 = 0x3DC00420
    try testing.expectEqual(@as(u32, 0x3DC00420), encLdrQImm(0, 1, 16));
}

test "encLdrQImm: V31, [X29, #16] (max V index, FP base)" {
    // imm12 = 1
    // 0x3DC00000 | (1 << 10) | (29 << 5) | 31
    //   = 0x3DC00000 | 0x400 | 0x3A0 | 0x1F = 0x3DC007BF
    try testing.expectEqual(@as(u32, 0x3DC007BF), encLdrQImm(31, 29, 16));
}

test "encStrQImm: V0, [X1, #0]" {
    // 0x3D800000 | (0 << 10) | (1 << 5) | 0 = 0x3D800020
    try testing.expectEqual(@as(u32, 0x3D800020), encStrQImm(0, 1, 0));
}

test "encStrQImm: V31, [X1, #(4095*16)]" {
    // imm12 = 4095 (max u12); byte_offset = 65520 (just under u16 max).
    const imm: u32 = 4095;
    const expected: u32 = 0x3D800000 | (imm << 10) | (1 << 5) | 31;
    try testing.expectEqual(expected, encStrQImm(31, 1, 65520));
}

test "encOrrV16B: V0, V1, V2" {
    // 0x4EA01C00 | (2 << 16) | (1 << 5) | 0 = 0x4EA21C20
    try testing.expectEqual(@as(u32, 0x4EA21C20), encOrrV16B(0, 1, 2));
}

test "encOrrV16B: V31, V31, V31 (max indices)" {
    // 0x4EA01C00 | (31 << 16) | (31 << 5) | 31 = 0x4EBF1FFF
    try testing.expectEqual(@as(u32, 0x4EBF1FFF), encOrrV16B(31, 31, 31));
}

test "encMovV16B: V0, V1 — alias of ORR Vd, Vn, Vn" {
    // Mov V0, V1 = ORR V0, V1, V1 = 0x4EA01C00 | (1<<16) | (1<<5) | 0 = 0x4EA11C20
    try testing.expectEqual(@as(u32, 0x4EA11C20), encMovV16B(0, 1));
    // Equivalent to encOrrV16B(0, 1, 1).
    try testing.expectEqual(encOrrV16B(0, 1, 1), encMovV16B(0, 1));
}

test "encDup4S: V0, W1 (i32x4.splat)" {
    // 0x4E040C00 | (1 << 5) | 0 = 0x4E040C20
    try testing.expectEqual(@as(u32, 0x4E040C20), encDup4S(0, 1));
}

test "encDup4S: V31, W30 (max indices)" {
    // 0x4E040C00 | (30 << 5) | 31 = 0x4E040FDF
    try testing.expectEqual(@as(u32, 0x4E040FDF), encDup4S(31, 30));
}

test "encAdd4S: V0, V1, V2" {
    // 0x4EA08400 | (2 << 16) | (1 << 5) | 0 = 0x4EA28420
    try testing.expectEqual(@as(u32, 0x4EA28420), encAdd4S(0, 1, 2));
}

test "encAdd4S: V31, V31, V31" {
    // 0x4EA08400 | (31 << 16) | (31 << 5) | 31 = 0x4EBF87FF
    try testing.expectEqual(@as(u32, 0x4EBF87FF), encAdd4S(31, 31, 31));
}

test "encAdd4S vs encOrrV16B: distinct opcodes (4S add ≠ 16B or)" {
    // Sanity: same operands produce different bytes.
    try testing.expect(encAdd4S(0, 1, 2) != encOrrV16B(0, 1, 2));
}

test "encLdrQImm vs encStrQImm: distinct opcode bits" {
    // Sanity: load and store at same operands differ.
    try testing.expect(encLdrQImm(0, 1, 0) != encStrQImm(0, 1, 0));
}

// ============================================================
// §9.9 / 9.5-c-iii — Lane access encoder tests (UMOV / INS)
// ============================================================

test "encUmovWFromS: lane 0 (W0 ← V0.S[0])" {
    // imm5 = (0 << 3) | 0b00100 = 4 → 0x040000.
    // 0x0E003C00 | 0x40000 | 0 = 0x0E043C00
    try testing.expectEqual(@as(u32, 0x0E043C00), encUmovWFromS(0, 0, 0));
}

test "encUmovWFromS: lane 3 (W0 ← V0.S[3])" {
    // imm5 = (3 << 3) | 4 = 0b11100 = 0x1C → 0x1C0000.
    // 0x0E003C00 | 0x1C0000 = 0x0E1C3C00
    try testing.expectEqual(@as(u32, 0x0E1C3C00), encUmovWFromS(0, 0, 3));
}

test "encUmovWFromS: max regs + max lane (W31 ← V31.S[3])" {
    // 0x0E1C3C00 | (31 << 5) | 31 = 0x0E1C3FFF
    try testing.expectEqual(@as(u32, 0x0E1C3FFF), encUmovWFromS(31, 31, 3));
}

test "encInsSFromW: lane 0 (V0.S[0] ← W0)" {
    // imm5 = 4 → 0x40000. Base 0x4E001C00 | 0x40000 = 0x4E041C00.
    try testing.expectEqual(@as(u32, 0x4E041C00), encInsSFromW(0, 0, 0));
}

test "encInsSFromW: lane 2 (V0.S[2] ← W1)" {
    // imm5 = (2 << 3) | 4 = 0b10100 = 0x14 → 0x140000.
    // 0x4E001C00 | 0x140000 | (1 << 5) | 0 = 0x4E141C20
    try testing.expectEqual(@as(u32, 0x4E141C20), encInsSFromW(0, 1, 2));
}

test "encInsSFromW: max regs + max lane (V31.S[3] ← W31)" {
    // 0x4E1C1C00 | (31 << 5) | 31 = 0x4E1C1FFF
    try testing.expectEqual(@as(u32, 0x4E1C1FFF), encInsSFromW(31, 31, 3));
}
