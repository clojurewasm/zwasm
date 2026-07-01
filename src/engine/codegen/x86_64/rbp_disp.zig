//! RBP-relative disp8 / disp32 auto-form helpers.
//!
//! The helpers pick disp8 vs disp32 encoder form based on the
//! signed displacement so call sites don't replicate the
//! form-selection logic. Frame layout grows DOWN from RBP, so
//! negative `disp` values are typical; the helpers are
//! disp-sign-agnostic at the encoder layer.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`). Imported by `emit.zig`
//! and `param_marshal.zig`; nothing above Zone 2 depends on this
//! module directly.
//!
//! Mirror in arm64: `arm64/prologue.zig` carries the equivalent
//! ldr/str-imm-disp form-selectors. x86_64 keeps them in a
//! standalone module rather than `prologue.zig` because they're
//! consumed by body-emission paths (local.get / local.set /
//! op_simd_*.zig) just as much as by the prologue/marshal.

const inst = @import("inst.zig");

/// `MOV [RBP + disp], r32` — picks disp8 / disp32 form per `disp`
/// range.
pub fn rbpStoreR32(disp: i32, src: inst.Gpr) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreR32MemRBP(@intCast(disp), src);
    return inst.encStoreR32MemRBPDisp32(disp, src);
}

/// `MOV r32, [RBP + disp]` — load form auto-helper.
pub fn rbpLoadR32(dst: inst.Gpr, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadR32MemRBP(dst, @intCast(disp));
    return inst.encLoadR32MemRBPDisp32(dst, disp);
}

/// `MOV [RBP + disp], r64` — store form auto-helper (REX.W).
pub fn rbpStoreR64(disp: i32, src: inst.Gpr) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreR64MemRBP(@intCast(disp), src);
    return inst.encStoreR64MemRBPDisp32(disp, src);
}

/// `MOV r64, [RBP + disp]` — load form auto-helper (REX.W).
pub fn rbpLoadR64(dst: inst.Gpr, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadR64MemRBP(dst, @intCast(disp));
    return inst.encLoadR64MemRBPDisp32(dst, disp);
}

/// `MOVSS [RBP + disp], xmm` — store form auto-helper (f32).
pub fn rbpStoreXmmF32(disp: i32, src: inst.Xmm) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreXmmF32MemRBP(@intCast(disp), src);
    return inst.encStoreXmmF32MemRBPDisp32(disp, src);
}

/// `MOVSS xmm, [RBP + disp]` — load form auto-helper (f32).
pub fn rbpLoadXmmF32(dst: inst.Xmm, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadXmmF32MemRBP(dst, @intCast(disp));
    return inst.encLoadXmmF32MemRBPDisp32(dst, disp);
}

/// `MOVSD [RBP + disp], xmm` — store form auto-helper (f64).
pub fn rbpStoreXmmF64(disp: i32, src: inst.Xmm) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreXmmF64MemRBP(@intCast(disp), src);
    return inst.encStoreXmmF64MemRBPDisp32(disp, src);
}

/// `MOVSD xmm, [RBP + disp]` — load form auto-helper (f64).
pub fn rbpLoadXmmF64(dst: inst.Xmm, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadXmmF64MemRBP(dst, @intCast(disp));
    return inst.encLoadXmmF64MemRBPDisp32(dst, disp);
}

/// `MOVUPS [RBP + disp], xmm` — store form auto-helper (v128).
/// V128 local-store path. MOVUPS chosen over
/// MOVAPS because v128 local-slot disps depend on the per-
/// function layout and aren't guaranteed 16-byte aligned.
pub fn rbpStoreXmmV128(disp: i32, src: inst.Xmm) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encStoreXmmV128MemRBP(@intCast(disp), src);
    return inst.encStoreXmmV128MemRBPDisp32(disp, src);
}

/// `MOVUPS xmm, [RBP + disp]` — load form auto-helper (v128).
pub fn rbpLoadXmmV128(dst: inst.Xmm, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLoadXmmV128MemRBP(dst, @intCast(disp));
    return inst.encLoadXmmV128MemRBPDisp32(dst, disp);
}

/// `LEA r64, [RBP + disp]` — picks disp8 / disp32 form per range.
/// Win64 v128 marshal caller-side path: compute
/// `[RBP + scratch_disp]` (typically deep in the local frame,
/// past i8 range) into the int-arg-reg slot per Microsoft x64
/// ABI §"Parameter passing" hidden-pointer recipe.
pub fn rbpLeaR64(dst: inst.Gpr, disp: i32) inst.EncodedInsn {
    if (disp >= -128 and disp <= 127) return inst.encLeaR64BaseDisp8(dst, .rbp, @intCast(disp));
    return inst.encLeaR64BaseDisp32(dst, .rbp, disp);
}

/// `SUB RSP, imm` — picks imm8 / imm32 form per `imm` range.
pub fn rspSub(imm: u32) inst.EncodedInsn {
    if (imm <= 127) return inst.encSubRSpImm8(@intCast(imm));
    return inst.encSubRSpImm32(@intCast(imm));
}

/// `ADD RSP, imm` — pair of `rspSub`.
pub fn rspAdd(imm: u32) inst.EncodedInsn {
    if (imm <= 127) return inst.encAddRSpImm8(@intCast(imm));
    return inst.encAddRSpImm32(@intCast(imm));
}
