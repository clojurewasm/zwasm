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

/// `ADD V<d>.<T>, V<n>.<T>, V<m>.<T>` — element-wise integer
/// add across a SIMD-128 register. The size field at bits
/// [23:22] selects the lane shape:
///   00 → 16B (i8x16)
///   01 → 8H  (i16x8)
///   10 → 4S  (i32x4)
///   11 → 2D  (i64x2)
///
/// Encoding (SIMD ADD vector, U=0, Q=1):
///   `0 1 0 01110 [size:2] 1 [Rm:5] 100001 [Rn:5] [Rd:5]`
///   = `0x4E208400 | (size << 22) | (Rm << 16) | (Rn << 5) | Rd`
///
/// Per Arm IHI 0055 §C7.2.5. SUB shares the same encoding shape
/// with U=1 (bit[29] set; base += 0x20000000).

/// `ADD V<d>.16B, V<n>.16B, V<m>.16B` — i8x16 lanewise add.
pub fn encAdd16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E208400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD V<d>.8H, V<n>.8H, V<m>.8H` — i16x8 lanewise add.
pub fn encAdd8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E608400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD V<d>.4S, V<n>.4S, V<m>.4S` — i32x4 lanewise add.
pub fn encAdd4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `ADD V<d>.2D, V<n>.2D, V<m>.2D` — i64x2 lanewise add.
pub fn encAdd2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.16B, V<n>.16B, V<m>.16B` — i8x16 lanewise sub.
/// SUB encoding mirrors ADD with U=1 (bit[29]). Per §C7.2.339.
pub fn encSub16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E208400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.8H, V<n>.8H, V<m>.8H` — i16x8 lanewise sub.
pub fn encSub8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E608400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.4S, V<n>.4S, V<m>.4S` — i32x4 lanewise sub.
pub fn encSub4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EA08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SUB V<d>.2D, V<n>.2D, V<m>.2D` — i64x2 lanewise sub.
pub fn encSub2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6EE08400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL V<d>.<T>, V<n>.<T>, V<m>.<T>` — element-wise integer
/// multiply. Same encoding shape as ADD but bits[15:11] = 10011
/// (vs ADD's 10000); delta from ADD base = 0x1800.
///
/// Encoding (SIMD MUL vector, U=0, Q=1):
///   `0 1 0 01110 [size:2] 1 [Rm:5] 100111 [Rn:5] [Rd:5]`
///
/// Per Arm IHI 0055 §C7.2.222.
///
/// **Note**: NEON has no `MUL Vd.2D` form — i64x2.mul requires
/// a multi-instr synthesis (extract / scalar mul / insert) and
/// defers to §9.9 / 9.5-c-vi alongside the other 64-bit-lane ops
/// that need synthesis.

/// `MUL V<d>.16B, V<n>.16B, V<m>.16B` — i8x16 lanewise mul.
pub fn encMul16B(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E209C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL V<d>.8H, V<n>.8H, V<m>.8H` — i16x8 lanewise mul.
pub fn encMul8H(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E609C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MUL V<d>.4S, V<n>.4S, V<m>.4S` — i32x4 lanewise mul.
/// SSE4.1's PMULLD per ADR-0041 §"5. SSE4.1 minimum baseline".
pub fn encMul4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA09C00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
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

// ---------------------------------------------------------------------
// §9.9 / 9.5-c-vi — B / H / D element forms
// ---------------------------------------------------------------------
// Wasm spec (SIMD) §extract_lane / replace_lane — i8x16, i16x8, i64x2.
// The B and H forms come in U(zero-extend) and S(sign-extend) flavours
// because Wasm distinguishes `i8x16.extract_lane_s` /
// `_u`. The D form is single-flavour (UMOV X) since i64x2 has no
// sub-i64 extraction width to disambiguate.

/// `UMOV W<rd>, V<n>.B[lane]` — copy 8-bit lane from V<n>.16B
/// into W<rd> (zero-extended). Used by `i8x16.extract_lane_u`.
/// `lane` ∈ 0..15. imm5 = (lane << 1) | 0b00001 (B-element discriminator).
/// Per Arm IHI 0055 §C7.2.371.
pub fn encUmovWFromB(rd: Xn, rn: Vn, lane: u4) u32 {
    const imm5: u32 = (@as(u32, lane) << 1) | 0b00001;
    return 0x0E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SMOV W<rd>, V<n>.B[lane]` — copy 8-bit lane sign-extended into
/// W<rd>. Used by `i8x16.extract_lane_s`. Same imm5 as UMOV B.
/// Encoding base = `0x0E002C00` (bits[14:11] = 0101 vs UMOV's 0111).
/// Per Arm IHI 0055 §C7.2.328.
pub fn encSmovWFromB(rd: Xn, rn: Vn, lane: u4) u32 {
    const imm5: u32 = (@as(u32, lane) << 1) | 0b00001;
    return 0x0E002C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.B[lane], W<n>` — insert low 8 bits of W<n> into the
/// B lane. Used by `i8x16.replace_lane`. imm5 = B form. Same INS
/// base as S form (0x4E001C00). Per Arm IHI 0055 §C7.2.155.
pub fn encInsBFromW(rd: Vn, rn: Xn, lane: u4) u32 {
    const imm5: u32 = (@as(u32, lane) << 1) | 0b00001;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UMOV W<rd>, V<n>.H[lane]` — copy 16-bit lane zero-extended into
/// W<rd>. Used by `i16x8.extract_lane_u`. `lane` ∈ 0..7.
/// imm5 = (lane << 2) | 0b00010 (H-element discriminator).
pub fn encUmovWFromH(rd: Xn, rn: Vn, lane: u3) u32 {
    const imm5: u32 = (@as(u32, lane) << 2) | 0b00010;
    return 0x0E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `SMOV W<rd>, V<n>.H[lane]` — copy 16-bit lane sign-extended into
/// W<rd>. Used by `i16x8.extract_lane_s`. Same imm5 as UMOV H.
pub fn encSmovWFromH(rd: Xn, rn: Vn, lane: u3) u32 {
    const imm5: u32 = (@as(u32, lane) << 2) | 0b00010;
    return 0x0E002C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.H[lane], W<n>` — insert low 16 bits of W<n> into the
/// H lane. Used by `i16x8.replace_lane`.
pub fn encInsHFromW(rd: Vn, rn: Xn, lane: u3) u32 {
    const imm5: u32 = (@as(u32, lane) << 2) | 0b00010;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `UMOV X<rd>, V<n>.D[lane]` — copy 64-bit lane into X<rd>. Used
/// by `i64x2.extract_lane`. `lane` ∈ 0..1. Q=1 (X-form result),
/// imm5 = (lane << 4) | 0b01000 (D-element discriminator).
/// Encoding base = `0x4E003C00` (Q bit set vs S/B/H W-form).
pub fn encUmovXFromD(rd: Xn, rn: Vn, lane: u1) u32 {
    const imm5: u32 = (@as(u32, lane) << 4) | 0b01000;
    return 0x4E003C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `INS V<d>.D[lane], X<n>` — insert X<n> into the D lane. Used by
/// `i64x2.replace_lane`. INS reuses the standard general-from-GPR
/// base; the GPR width is determined by imm5's element selector
/// (D-form expects an X register).
pub fn encInsDFromX(rd: Vn, rn: Xn, lane: u1) u32 {
    const imm5: u32 = (@as(u32, lane) << 4) | 0b01000;
    return 0x4E001C00 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// §9.9 / 9.5-c-vii — FP element forms (S = f32x4, D = f64x2 lane access)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `f32x4.extract_lane` produces an f32 scalar held
// in an FP register (S-form, low 32 bits of V<rd>); `replace_lane`
// consumes an f32 scalar at S[0] of an FP register and writes lane k.
// f64x2 same with D-form.
//
// Encoders use DUP-scalar (extract: zeros upper V bits naturally) and
// INS-element (replace: copies V<rn>.S[0] / V<rn>.D[0] into a V<rd>
// lane). No GPR transit, so no SPILL-EXEMPT marker needed downstream.

/// `MOV S<rd>, V<n>.S[lane]` (alias of `DUP S<d>, V<n>.S[lane]`)
/// — extract a 32-bit FP lane into a scalar S register (zeros
/// upper V bits). Used by `f32x4.extract_lane`. `lane` ∈ 0..3.
///
/// Encoding (DUP advanced SIMD scalar, S element form):
///   `0 1 0 11110 000 [imm5:5] 0 0000 1 [Rn:5] [Rd:5]`
///   imm5 = (lane << 3) | 0b00100 (S-element discriminator).
///   Base = `0x5E000400`. Per Arm IHI 0055 §C7.2.85.
pub fn encMovScalarSFromVlane(rd: Vn, rn: Vn, lane: u2) u32 {
    const imm5: u32 = (@as(u32, lane) << 3) | 0b00100;
    return 0x5E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV D<rd>, V<n>.D[lane]` (alias of `DUP D<d>, V<n>.D[lane]`)
/// — extract a 64-bit FP lane into a scalar D register. Used by
/// `f64x2.extract_lane`. `lane` ∈ 0..1. imm5 = (lane << 4) | 0b01000.
pub fn encMovScalarDFromVlane(rd: Vn, rn: Vn, lane: u1) u32 {
    const imm5: u32 = (@as(u32, lane) << 4) | 0b01000;
    return 0x5E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV V<d>.S[dst_lane], V<n>.S[0]` (alias of `INS (element)` with
/// src lane 0) — copy the low S of V<n> into the S lane of V<d>.
/// Used by `f32x4.replace_lane`.
///
/// Encoding (INS element, S form, src lane 0):
///   `0 1 1 01110 000 [imm5:5] 0 [imm4:4] 1 [Rn:5] [Rd:5]`
///   imm5 = (dst_lane << 3) | 0b00100 (S-element discriminator).
///   imm4 = src_lane × 4-bytes = 0 when src_lane = 0.
///   Base = `0x6E000400`. Per Arm IHI 0055 §C7.2.155.
pub fn encMovVSlaneFromVS0(rd: Vn, dst_lane: u2, rn: Vn) u32 {
    const imm5: u32 = (@as(u32, dst_lane) << 3) | 0b00100;
    return 0x6E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `MOV V<d>.D[dst_lane], V<n>.D[0]` — copy the low D of V<n> into
/// the D lane of V<d>. Used by `f64x2.replace_lane`. imm5 D form;
/// imm4 = src_lane × 8-bytes = 0 when src_lane = 0.
pub fn encMovVDlaneFromVD0(rd: Vn, dst_lane: u1, rn: Vn) u32 {
    const imm5: u32 = (@as(u32, dst_lane) << 4) | 0b01000;
    return 0x6E000400 | (imm5 << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

// ---------------------------------------------------------------------
// §9.6 / 9.6-a — FP three-same arithmetic (FADD / FSUB / FMUL / FDIV)
// ---------------------------------------------------------------------
// Wasm spec (SIMD) — `f32x4.add/sub/mul/div` and `f64x2.add/sub/mul/div`.
// Encoding family: "Floating-point three same"
//   `0 Q U 01110 op 1 sz 1 Rm opcode 1 Rn Rd`
// where Q=1 for the 128-bit form, U distinguishes (FMUL/FDIV use U=1),
// op bit 23 distinguishes FADD (0) vs FSUB (1) within the U=0 family,
// sz (bit 22) selects S (0) vs D (1) lanes, and opcode bits[15:11]
// further disambiguate (FADD/FSUB = 11010, FMUL = 11011, FDIV = 11111).
// Per Arm IHI 0055 §C7.2.97 / §C7.2.146 / §C7.2.131 / §C7.2.115.

/// `FADD V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise add (IEEE-754
/// round-to-nearest-even, NaN-propagating per Wasm spec).
pub fn encFAdd4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E20D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FADD V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise add.
pub fn encFAdd2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4E60D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FSUB V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise sub. Bit 23 = 1
/// (vs FADD's 0); same opcode bits[15:11] = 11010.
pub fn encFSub4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EA0D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FSUB V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise sub.
pub fn encFSub2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x4EE0D400 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FMUL V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise mul. U=1,
/// opcode bits[15:11] = 11011.
pub fn encFMul4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E20DC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FMUL V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise mul.
pub fn encFMul2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E60DC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FDIV V<d>.4S, V<n>.4S, V<m>.4S` — f32x4 lanewise div. U=1,
/// opcode bits[15:11] = 11111.
pub fn encFDiv4S(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E20FC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
}

/// `FDIV V<d>.2D, V<n>.2D, V<m>.2D` — f64x2 lanewise div.
pub fn encFDiv2D(rd: Vn, rn: Vn, rm: Vn) u32 {
    return 0x6E60FC00 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | @as(u32, rd);
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

// ============================================================
// §9.9 / 9.5-c-iv — ADD/SUB across i8x16/i16x8/i64x2 (i32x4
// already in foundation tests). Tests verify size-field bit
// patterns + cross-shape distinctness sanity.
// ============================================================

test "encAdd16B: V0, V1, V2 (i8x16, size=00)" {
    // 0x4E208400 | (2 << 16) | (1 << 5) | 0 = 0x4E228420
    try testing.expectEqual(@as(u32, 0x4E228420), encAdd16B(0, 1, 2));
}

test "encAdd8H: V0, V1, V2 (i16x8, size=01)" {
    // 0x4E608400 | (2 << 16) | (1 << 5) | 0 = 0x4E628420
    try testing.expectEqual(@as(u32, 0x4E628420), encAdd8H(0, 1, 2));
}

test "encAdd2D: V0, V1, V2 (i64x2, size=11)" {
    // 0x4EE08400 | (2 << 16) | (1 << 5) | 0 = 0x4EE28420
    try testing.expectEqual(@as(u32, 0x4EE28420), encAdd2D(0, 1, 2));
}

test "encSub16B: V0, V1, V2 (i8x16, size=00, U=1)" {
    // 0x6E208400 | (2 << 16) | (1 << 5) | 0 = 0x6E228420
    try testing.expectEqual(@as(u32, 0x6E228420), encSub16B(0, 1, 2));
}

test "encSub8H: V0, V1, V2 (i16x8, size=01, U=1)" {
    // 0x6E608400 | ... = 0x6E628420
    try testing.expectEqual(@as(u32, 0x6E628420), encSub8H(0, 1, 2));
}

test "encSub4S: V0, V1, V2 (i32x4, size=10, U=1)" {
    // 0x6EA08400 | ... = 0x6EA28420
    try testing.expectEqual(@as(u32, 0x6EA28420), encSub4S(0, 1, 2));
}

test "encSub2D: V0, V1, V2 (i64x2, size=11, U=1)" {
    // 0x6EE08400 | ... = 0x6EE28420
    try testing.expectEqual(@as(u32, 0x6EE28420), encSub2D(0, 1, 2));
}

test "encSub vs encAdd: U bit set distinguishes; same shape size field" {
    // ADD/SUB at same shape (4S) differ only in bit[29] (U bit).
    const add_word = encAdd4S(0, 1, 2);
    const sub_word = encSub4S(0, 1, 2);
    try testing.expectEqual(@as(u32, 0x20000000), sub_word ^ add_word);
}

test "encAdd shapes pairwise distinct (size field separates)" {
    // 16B vs 8H vs 4S vs 2D — same operands, different bits[23:22].
    try testing.expect(encAdd16B(0, 1, 2) != encAdd8H(0, 1, 2));
    try testing.expect(encAdd8H(0, 1, 2) != encAdd4S(0, 1, 2));
    try testing.expect(encAdd4S(0, 1, 2) != encAdd2D(0, 1, 2));
}

// ============================================================
// §9.9 / 9.5-c-v — MUL family (16B/8H/4S; 2D needs synthesis)
// ============================================================

test "encMul16B: V0, V1, V2 (i8x16.mul shape)" {
    // 0x4E209C00 | (2 << 16) | (1 << 5) | 0 = 0x4E229C20
    try testing.expectEqual(@as(u32, 0x4E229C20), encMul16B(0, 1, 2));
}

test "encMul8H: V0, V1, V2 (i16x8.mul)" {
    // 0x4E609C00 | ... = 0x4E629C20
    try testing.expectEqual(@as(u32, 0x4E629C20), encMul8H(0, 1, 2));
}

test "encMul4S: V0, V1, V2 (i32x4.mul)" {
    // 0x4EA09C00 | ... = 0x4EA29C20
    try testing.expectEqual(@as(u32, 0x4EA29C20), encMul4S(0, 1, 2));
}

test "encMul vs encAdd: bits[15:11] differ by 0b00011 << 11 = 0x1800" {
    // MUL bits[15:11] = 10011, ADD = 10000 → delta 0x1800.
    const add_word = encAdd4S(0, 1, 2);
    const mul_word = encMul4S(0, 1, 2);
    try testing.expectEqual(@as(u32, 0x1800), mul_word ^ add_word);
}

// ============================================================
// §9.9 / 9.5-c-vi — Lane access for B/H/D element forms
// ============================================================

test "encUmovWFromB: lane 0 (W0 ← V0.B[0])" {
    // imm5 = (0 << 1) | 1 = 1 → 0x10000.
    // 0x0E003C00 | 0x10000 = 0x0E013C00
    try testing.expectEqual(@as(u32, 0x0E013C00), encUmovWFromB(0, 0, 0));
}

test "encUmovWFromB: lane 15 (W3 ← V2.B[15])" {
    // imm5 = (15 << 1) | 1 = 31 = 0x1F → 0x1F0000.
    // 0x0E003C00 | 0x1F0000 | (2 << 5) | 3 = 0x0E1F3C43
    try testing.expectEqual(@as(u32, 0x0E1F3C43), encUmovWFromB(3, 2, 15));
}

test "encSmovWFromB: lane 0 vs encUmovWFromB lane 0 — bit[12] differs" {
    // SMOV bits[14:11]=0101, UMOV=0111 → delta = 0b10 << 11 = 0x1000
    const u_word = encUmovWFromB(0, 0, 0);
    const s_word = encSmovWFromB(0, 0, 0);
    try testing.expectEqual(@as(u32, 0x1000), u_word ^ s_word);
}

test "encInsBFromW: lane 0 (V0.B[0] ← W0)" {
    // imm5 = 1 → 0x10000. Base 0x4E001C00 | 0x10000 = 0x4E011C00.
    try testing.expectEqual(@as(u32, 0x4E011C00), encInsBFromW(0, 0, 0));
}

test "encInsBFromW: lane 15 (V31.B[15] ← W30)" {
    // imm5 = 31 → 0x1F0000. 0x4E001C00 | 0x1F0000 | (30 << 5) | 31
    //   = 0x4E1F1FDF
    try testing.expectEqual(@as(u32, 0x4E1F1FDF), encInsBFromW(31, 30, 15));
}

test "encUmovWFromH: lane 0 (W0 ← V0.H[0])" {
    // imm5 = (0 << 2) | 2 = 2 → 0x20000.
    try testing.expectEqual(@as(u32, 0x0E023C00), encUmovWFromH(0, 0, 0));
}

test "encUmovWFromH: lane 7 (W0 ← V0.H[7])" {
    // imm5 = (7 << 2) | 2 = 30 = 0x1E → 0x1E0000.
    try testing.expectEqual(@as(u32, 0x0E1E3C00), encUmovWFromH(0, 0, 7));
}

test "encSmovWFromH vs encUmovWFromH: bit[12] differs" {
    const u_word = encUmovWFromH(0, 0, 3);
    const s_word = encSmovWFromH(0, 0, 3);
    try testing.expectEqual(@as(u32, 0x1000), u_word ^ s_word);
}

test "encInsHFromW: lane 7 (V0.H[7] ← W1)" {
    // imm5 = 30 → 0x1E0000. 0x4E001C00 | 0x1E0000 | (1 << 5) | 0
    //   = 0x4E1E1C20
    try testing.expectEqual(@as(u32, 0x4E1E1C20), encInsHFromW(0, 1, 7));
}

test "encUmovXFromD: lane 0 (X0 ← V0.D[0])" {
    // Q=1, imm5 = (0 << 4) | 8 = 8 → 0x80000.
    // 0x4E003C00 | 0x80000 = 0x4E083C00
    try testing.expectEqual(@as(u32, 0x4E083C00), encUmovXFromD(0, 0, 0));
}

test "encUmovXFromD: lane 1 (X3 ← V2.D[1])" {
    // imm5 = (1 << 4) | 8 = 24 = 0x18 → 0x180000.
    // 0x4E003C00 | 0x180000 | (2 << 5) | 3 = 0x4E183C43
    try testing.expectEqual(@as(u32, 0x4E183C43), encUmovXFromD(3, 2, 1));
}

test "encInsDFromX: lane 0 (V0.D[0] ← X0)" {
    // imm5 = 8 → 0x80000. 0x4E001C00 | 0x80000 = 0x4E081C00.
    try testing.expectEqual(@as(u32, 0x4E081C00), encInsDFromX(0, 0, 0));
}

test "encInsDFromX: lane 1 (V31.D[1] ← X30)" {
    // imm5 = 24 → 0x180000. 0x4E001C00 | 0x180000 | (30 << 5) | 31
    //   = 0x4E181FDF
    try testing.expectEqual(@as(u32, 0x4E181FDF), encInsDFromX(31, 30, 1));
}

test "lane access encoders: B/H/S/D element discriminators distinct" {
    // imm5 low bits: B=00001, H=00010, S=00100, D=01000. UMOV at lane 0.
    try testing.expect(encUmovWFromB(0, 0, 0) != encUmovWFromH(0, 0, 0));
    try testing.expect(encUmovWFromH(0, 0, 0) != encUmovWFromS(0, 0, 0));
    try testing.expect(encUmovWFromS(0, 0, 0) != encUmovXFromD(0, 0, 0));
}

// ============================================================
// §9.9 / 9.5-c-vii — FP lane access (DUP scalar + INS element)
// ============================================================

test "encMovScalarSFromVlane: lane 0 (MOV S0, V0.S[0])" {
    // imm5 = 4 → 0x40000. Base 0x5E000400 | 0x40000 = 0x5E040400.
    try testing.expectEqual(@as(u32, 0x5E040400), encMovScalarSFromVlane(0, 0, 0));
}

test "encMovScalarSFromVlane: lane 3 (MOV S0, V1.S[3])" {
    // imm5 = (3 << 3) | 4 = 28 = 0x1C → 0x1C0000.
    // 0x5E000400 | 0x1C0000 | (1 << 5) | 0 = 0x5E1C0420
    try testing.expectEqual(@as(u32, 0x5E1C0420), encMovScalarSFromVlane(0, 1, 3));
}

test "encMovScalarDFromVlane: lane 0 (MOV D0, V0.D[0])" {
    // imm5 = 8 → 0x80000.
    try testing.expectEqual(@as(u32, 0x5E080400), encMovScalarDFromVlane(0, 0, 0));
}

test "encMovScalarDFromVlane: lane 1 (MOV D31, V30.D[1])" {
    // imm5 = (1 << 4) | 8 = 24 = 0x18 → 0x180000.
    // 0x5E000400 | 0x180000 | (30 << 5) | 31 = 0x5E1807DF
    try testing.expectEqual(@as(u32, 0x5E1807DF), encMovScalarDFromVlane(31, 30, 1));
}

test "encMovVSlaneFromVS0: dst lane 0 (MOV V0.S[0], V0.S[0])" {
    // imm5 = 4 → 0x40000. Base 0x6E000400 | 0x40000 = 0x6E040400.
    try testing.expectEqual(@as(u32, 0x6E040400), encMovVSlaneFromVS0(0, 0, 0));
}

test "encMovVSlaneFromVS0: dst lane 2 (MOV V0.S[2], V1.S[0])" {
    // imm5 = (2 << 3) | 4 = 20 = 0x14 → 0x140000. imm4 = 0.
    // 0x6E000400 | 0x140000 | (1 << 5) | 0 = 0x6E140420
    try testing.expectEqual(@as(u32, 0x6E140420), encMovVSlaneFromVS0(0, 2, 1));
}

test "encMovVDlaneFromVD0: dst lane 1 (MOV V0.D[1], V1.D[0])" {
    // imm5 = (1 << 4) | 8 = 24 = 0x18 → 0x180000. imm4 = 0.
    try testing.expectEqual(@as(u32, 0x6E180420), encMovVDlaneFromVD0(0, 1, 1));
}

test "DUP-scalar vs INS-element: distinct opcode prefixes" {
    // DUP-scalar: `0_1_0_11110...` (bits 31:24 = 0x5E)
    // INS-element: `0_1_1_01110...` (bits 31:24 = 0x6E)
    // Bits 29 (op) AND 28 (asimd-class disambiguator) both differ →
    // XOR delta = 0x30000000 at identical imm5/Rn/Rd.
    const dup_word = encMovScalarSFromVlane(0, 0, 0);
    const ins_word = encMovVSlaneFromVS0(0, 0, 0);
    try testing.expectEqual(@as(u32, 0x30000000), dup_word ^ ins_word);
}

// ============================================================
// §9.6 / 9.6-a — FP three-same arithmetic (FADD/FSUB/FMUL/FDIV)
// ============================================================

test "encFAdd4S: V0, V1, V2 (f32x4.add base)" {
    // 0x4E20D400 | (2 << 16) | (1 << 5) | 0 = 0x4E22D420
    try testing.expectEqual(@as(u32, 0x4E22D420), encFAdd4S(0, 1, 2));
}

test "encFAdd2D: V0, V1, V2 (f64x2.add)" {
    // 0x4E60D400 | (2 << 16) | (1 << 5) | 0 = 0x4E62D420
    try testing.expectEqual(@as(u32, 0x4E62D420), encFAdd2D(0, 1, 2));
}

test "encFSub4S vs encFAdd4S: bit 23 differs (op = add vs sub)" {
    // 0x4EA0D400 vs 0x4E20D400 → XOR = 0x00800000
    try testing.expectEqual(@as(u32, 0x00800000), encFSub4S(0, 1, 2) ^ encFAdd4S(0, 1, 2));
}

test "encFSub2D: V31, V31, V31 (max indices, f64x2.sub)" {
    // 0x4EE0D400 | (31 << 16) | (31 << 5) | 31 = 0x4EFFD7FF
    try testing.expectEqual(@as(u32, 0x4EFFD7FF), encFSub2D(31, 31, 31));
}

test "encFMul4S: V0, V1, V2 (f32x4.mul, U=1, opcode bit 11 set vs FADD/FSUB)" {
    // 0x6E20DC00 | ... = 0x6E22DC20
    try testing.expectEqual(@as(u32, 0x6E22DC20), encFMul4S(0, 1, 2));
}

test "encFMul2D: V0, V1, V2 (f64x2.mul)" {
    // 0x6E60DC00 | ... = 0x6E62DC20
    try testing.expectEqual(@as(u32, 0x6E62DC20), encFMul2D(0, 1, 2));
}

test "encFDiv4S: V0, V1, V2 (f32x4.div, opcode 11111)" {
    // 0x6E20FC00 | ... = 0x6E22FC20
    try testing.expectEqual(@as(u32, 0x6E22FC20), encFDiv4S(0, 1, 2));
}

test "encFDiv2D vs encFMul2D: opcode bit 13 differs" {
    // FDIV opcode 11111, FMUL 11011 → bit 13 differs → +0x2000.
    try testing.expectEqual(@as(u32, 0x2000), encFDiv2D(0, 1, 2) ^ encFMul2D(0, 1, 2));
}

test "FP arith: sz field selects 4S vs 2D (bit 22)" {
    // .4S has sz=0, .2D has sz=1 → bit 22 differs → +0x00400000.
    try testing.expectEqual(@as(u32, 0x00400000), encFAdd2D(0, 1, 2) ^ encFAdd4S(0, 1, 2));
    try testing.expectEqual(@as(u32, 0x00400000), encFMul2D(0, 1, 2) ^ encFMul4S(0, 1, 2));
}
