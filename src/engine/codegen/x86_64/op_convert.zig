// FILE-SIZE-EXEMPT: per-op handler catalog (Wasm FP↔int conversion sub-language); P1 spec-defined (per ADR-0099)
//! x86_64 emit pass — FP↔i / FP↔FP conversion handlers (D-030 chunk-d).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314 + the ARM64
//! ADR-0021 sub-b mirror shape (`arm64/op_convert.zig`). Behaviour
//! change zero — handler bodies are unchanged from their pre-split
//! shape; only their home file moves.
//!
//! Handlers in this module:
//!   - `emitFpConvertSimple`     — single-instruction conversions
//!     (promote/demote + reinterpret + signed i→f via CVTSI2SS/SD).
//!   - `emitFpConvertI64Unsigned` — branch-based unsigned i64→f
//!     (TEST+JS+SHR/AND high-bit dance; clang/gcc pattern).
//!   - `emitFpTruncSatSigned`    — Wasm 2.0 saturating signed
//!     trunc_sat (CVTTSS2SI + sentinel detection).
//!   - `emitFpTruncSatU32`       — Wasm 2.0 saturating unsigned
//!     trunc_sat to i32 (uses .q form on bounded range).
//!   - `emitFpTruncSatU64`       — Wasm 2.0 saturating unsigned
//!     trunc_sat to i64 (2^63 split path).
//!   - `emitFpTruncTrapSigned`   — Wasm 1.0 trapping signed trunc
//!     (UCOMI bounds + CVTTSS2SI).
//!   - `emitFpTruncTrapUnsigned` — Wasm 1.0 trapping unsigned trunc
//!     (UCOMI bounds + 2^63 split for i64_u).
//!
//! XMM7 is the SIMD scratch (reserved per `abi.zig`); XMM6 doubles
//! as a transient mid-op scratch in the i64_u split paths. RAX/RCX
//! are GPR scratches (not in regalloc pool). Trap branches share
//! the function-tail bounds_fixups list so the per-fixture trap
//! stub (set trap_flag=1, return 0) is emitted only once.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

const zir = @import("../../../ir/zir.zig");
const regalloc = @import("../shared/regalloc.zig");
const ctx_mod = @import("ctx.zig");
const inst = @import("inst.zig");
const gpr = @import("gpr.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Error = types.Error;

/// Wasm spec §4.3 (f32/f64 conversions) — single-instruction
/// conversions:
/// - `f64.promote_f32` (CVTSS2SD), `f32.demote_f64` (CVTSD2SS).
/// - reinterpret (i↔f bit-cast via existing MOVD/MOVQ).
/// - signed i→f convert (CVTSI2SS/SD with REX.W for i64 source).
///
/// Unsigned i64→f convert + trapping/saturating f→i trunc handled
/// by sibling helpers in this file (need extra range-check / fixup).
pub fn emitFpConvertSimple(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;

    // Track which class the dst lives in so the post-branch spill
    // store picks the right helper. (op_convert flips between
    // GPR and FP destinations per op.)
    var dst_is_fp = true;

    switch (op) {
        .@"f64.promote_f32" => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 1);
            try buf.appendSlice(allocator, inst.encSseScalarBinary(.f32, 0x5A, dst_x, src_x).slice());
        },
        .@"f32.demote_f64" => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 1);
            try buf.appendSlice(allocator, inst.encSseScalarBinary(.f64, 0x5A, dst_x, src_x).slice());
        },
        .@"i32.reinterpret_f32" => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            const dst_g = try gpr.gprDefSpilled(alloc, result_v, 0);
            try buf.appendSlice(allocator, inst.encMovdR32FromXmm(dst_g, src_x).slice());
            dst_is_fp = false;
        },
        .@"i64.reinterpret_f64" => {
            const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            const dst_g = try gpr.gprDefSpilled(alloc, result_v, 0);
            try buf.appendSlice(allocator, inst.encMovqR64FromXmm(dst_g, src_x).slice());
            dst_is_fp = false;
        },
        .@"f32.reinterpret_i32" => {
            const src_g = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 0);
            try buf.appendSlice(allocator, inst.encMovdXmmFromR32(dst_x, src_g).slice());
        },
        .@"f64.reinterpret_i64" => {
            const src_g = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 0);
            try buf.appendSlice(allocator, inst.encMovqXmmFromR64(dst_x, src_g).slice());
        },
        .@"f32.convert_i32_s",
        .@"f32.convert_i64_s",
        .@"f64.convert_i32_s",
        .@"f64.convert_i64_s",
        .@"f32.convert_i32_u",
        .@"f64.convert_i32_u",
        => {
            const src_g = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
            const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 0);
            const scalar_kind: inst.SseScalarKind = switch (op) {
                .@"f32.convert_i32_s",
                .@"f32.convert_i64_s",
                .@"f32.convert_i32_u",
                => .f32,
                else => .f64,
            };
            // i32_u trick: use the .q (REX.W) form of CVTSI2SS/SD on the i32
            // source register. x86_64 i32 ops zero-extend their result to
            // 64 bits, so the value is non-negative when interpreted as i64
            // and CVTSI2SS converts it correctly without sign issues.
            // i64_s also uses .q. i32_s uses .d.
            const src_is_64 = switch (op) {
                .@"f32.convert_i32_s", .@"f64.convert_i32_s" => false,
                else => true,
            };
            try buf.appendSlice(allocator, inst.encCvtsi2Scalar(scalar_kind, src_is_64, dst_x, src_g).slice());
        },
        else => unreachable,
    }
    if (dst_is_fp) {
        // Stage 1 chosen for the promote/demote arms (where both
        // src and dst could be FP-spilled and use distinct stages).
        // For other FP-dst arms only stage 0 is live for dst, but
        // store-stage-1 vs store-stage-0 doesn't matter since the
        // dst reg was returned by gprDefSpilled with the matching
        // stage_idx — we pick stage 0/1 to match the def above.
        const stage_idx: u8 = switch (op) {
            .@"f64.promote_f32", .@"f32.demote_f64" => 1,
            else => 0,
        };
        try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, stage_idx);
    } else {
        try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    }
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.3 (f32/f64.convert_i64_u) — unsigned i64 → float.
/// Branch-based (the i64 may have the high bit set; CVTSI2SS
/// would interpret it as negative). Pattern (used by clang/gcc):
///
///   TEST src, src
///   JS   slow_path           ; high bit set ⇒ src ≥ 2^63
///   CVTSI2SS dst, src        ; positive case (REX.W form)
///   JMP end
///   slow_path:
///     MOV RAX, src ; SHR RAX, 1     ; halve, drop high bit
///     MOV RCX, src ; AND RCX, 1     ; preserve low bit (round)
///     OR  RAX, RCX
///     CVTSI2SS dst, RAX             ; convert as signed (now < 2^63)
///     ADDSS dst, dst                ; double the result
///   end:
///
/// Scratches RAX/RCX excluded from regalloc pool. Branches use
/// rel32 placeholders patched at end-of-emit.
pub fn emitFpConvertI64Unsigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_g = try gpr.gprLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst_x = try gpr.xmmDefSpilled(alloc, result_v, 0);

    const scalar_kind: inst.SseScalarKind = if (op == .@"f64.convert_i64_u") .f64 else .f32;

    // 1. TEST src, src
    try buf.appendSlice(allocator, inst.encTestRR(.q, src_g, src_g).slice());

    // 2. JS rel32 → slow_path (placeholder)
    const js_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.s, 0).slice());

    // 3. Positive path: CVTSI2SS dst, src (i64 form)
    try buf.appendSlice(allocator, inst.encCvtsi2Scalar(scalar_kind, true, dst_x, src_g).slice());

    // 4. JMP rel32 → end (placeholder)
    const jmp_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 5. Slow path; patch JS.
    const slow_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, js_byte, 6, @as(i32, @intCast(slow_byte)) - @as(i32, @intCast(js_byte)) - 6);

    try buf.appendSlice(allocator, inst.encMovRR(.q, .rax, src_g).slice());
    try buf.appendSlice(allocator, inst.encShrRImm8(.q, .rax, 1).slice());
    try buf.appendSlice(allocator, inst.encMovRR(.q, .rcx, src_g).slice());
    try buf.appendSlice(allocator, inst.encAndRImm8(.q, .rcx, 1).slice());
    try buf.appendSlice(allocator, inst.encOrRR(.q, .rax, .rcx).slice());
    try buf.appendSlice(allocator, inst.encCvtsi2Scalar(scalar_kind, true, dst_x, .rax).slice());
    try buf.appendSlice(allocator, inst.encSseScalarBinary(scalar_kind, 0x58, dst_x, dst_x).slice());

    // 6. end; patch JMP.
    const end_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jmp_byte, 5, @as(i32, @intCast(end_byte)) - @as(i32, @intCast(jmp_byte)) - 5);

    try gpr.xmmStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.3 (Wasm 2.0 i32/i64.trunc_sat_f32/f64_s) — signed
/// saturating trunc. CVTTSS2SI / CVTTSD2SI returns INT_MIN of dst
/// width on NaN OR out-of-range — that sentinel is the trigger
/// for spec-correct saturation:
///
///   CVTTSS2SI dst, src
///   CMP dst, INT_MIN_sentinel
///   JNE done                          ; in-range — dst is correct
///   ; sentinel: NaN OR overflow
///   UCOMI src, src ; JP nan_path      ; PF=1 ⇒ NaN
///   XORPS xmm7, xmm7                  ; scratch = 0.0
///   UCOMI src, xmm7
///   JBE done                          ; src ≤ 0 ⇒ INT_MIN already in dst
///   MOV dst, INT_MAX                  ; positive overflow
///   JMP done
///   nan_path: XOR dst, dst (zero)
///   done:
///
/// XMM7 reserved as SIMD scratch (per abi.zig). RCX scratch for
/// i64 sentinel materialisation (not in pool).
pub fn emitFpTruncSatSigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst = try gpr.gprDefSpilled(alloc, result_v, 0);

    const is_f64_src = switch (op) {
        .@"i32.trunc_sat_f64_s", .@"i64.trunc_sat_f64_s" => true,
        else => false,
    };
    const is_i64_dst = switch (op) {
        .@"i64.trunc_sat_f32_s", .@"i64.trunc_sat_f64_s" => true,
        else => false,
    };
    const scalar_kind: inst.SseScalarKind = if (is_f64_src) .f64 else .f32;
    const packed_kind: inst.SsePackedKind = if (is_f64_src) .f64 else .f32;

    // 1. CVTTSS/SD2SI dst, src.
    try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, is_i64_dst, dst, src_x).slice());

    // 2. Compare dst with INT_MIN sentinel.
    if (is_i64_dst) {
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, 0x8000000000000000).slice());
        try buf.appendSlice(allocator, inst.encCmpRR(.q, dst, .rcx).slice());
    } else {
        try buf.appendSlice(allocator, inst.encCmpRImm32(dst, 0x80000000).slice());
    }

    // 3. JNE done (placeholder).
    const jne_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.ne, 0).slice());

    // 4. NaN check: UCOMI src, src.
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, src_x).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, src_x).slice());
    }

    // 5. JP nan_path (placeholder).
    const jp_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.p, 0).slice());

    // 6. Zero scratch XMM7 (XORPS/PD), then UCOMI src vs scratch.
    try buf.appendSlice(allocator, inst.encSsePackedBinary(packed_kind, 0x57, .xmm7, .xmm7).slice());
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }

    // 7. JBE done (placeholder; src ≤ 0 ⇒ INT_MIN already in dst).
    const jbe_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());

    // 8. MOV dst, INT_MAX (positive overflow).
    if (is_i64_dst) {
        try buf.appendSlice(allocator, inst.encMovImm64Q(dst, 0x7FFFFFFFFFFFFFFF).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovImm32W(dst, 0x7FFFFFFF).slice());
    }

    // 9. JMP done (placeholder).
    const jmp_done_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 10. nan_path; patch JP.
    const nan_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jp_byte, 6, @as(i32, @intCast(nan_byte)) - @as(i32, @intCast(jp_byte)) - 6);
    try buf.appendSlice(allocator, inst.encXorRR(if (is_i64_dst) .q else .d, dst, dst).slice());

    // 11. done; patch JNE / JBE / JMP-done.
    const done_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jne_byte, 6, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jne_byte)) - 6);
    inst.patchRel32(buf.items, jbe_byte, 6, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jbe_byte)) - 6);
    inst.patchRel32(buf.items, jmp_done_byte, 5, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jmp_done_byte)) - 5);

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.3 (Wasm 2.0 i32.trunc_sat_f32/f64_u) — saturating
/// unsigned trunc to i32. Uses the .q form CVTTSS2SI on the bounded
/// range [0, 2^32), which fits comfortably inside positive i64 — no
/// signed-overflow ambiguity. Branches handle NaN/negative→0 and
/// ≥ 2^32 → UINT32_MAX:
///
///   UCOMI src, src ; JP zero_path     ; NaN
///   XORPS xmm7, xmm7
///   UCOMI src, xmm7 ; JBE zero_path   ; src ≤ 0 (or NaN)
///   ; Materialise threshold 2^32 in xmm7 (overwriting zero).
///   MOV/MOVABS rax, threshold ; MOVD/Q xmm7, rax
///   UCOMI src, xmm7 ; JAE max_path    ; src ≥ 2^32
///   CVTTSS2SI .q gpr_dst, src         ; in-range
///   JMP done
///   zero_path: XOR gpr_dst, gpr_dst (.d) ; JMP done
///   max_path:  MOV gpr_dst, 0xFFFFFFFF
///   done:
///
/// Threshold is 2^32 (0x4F800000 as f32, 0x41F0000000000000 as f64),
/// both exactly representable.
///
/// XMM7 is the SIMD scratch (per abi.zig). RAX is GPR scratch
/// for threshold materialisation. Neither in regalloc pool.
pub fn emitFpTruncSatU32(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst = try gpr.gprDefSpilled(alloc, result_v, 0);

    const is_f64_src = op == .@"i32.trunc_sat_f64_u";
    const scalar_kind: inst.SseScalarKind = if (is_f64_src) .f64 else .f32;
    const packed_kind: inst.SsePackedKind = if (is_f64_src) .f64 else .f32;

    // 1. NaN check: UCOMI src, src ; JP zero_path.
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, src_x).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, src_x).slice());
    }
    const jp_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.p, 0).slice());

    // 2. XORPS xmm7, xmm7 ; UCOMI src, xmm7 ; JBE zero_path.
    try buf.appendSlice(allocator, inst.encSsePackedBinary(packed_kind, 0x57, .xmm7, .xmm7).slice());
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    const jbe_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());

    // 3. Load threshold 2^32 into xmm7 (overwriting the zero).
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rax, 0x41F0000000000000).slice());
        try buf.appendSlice(allocator, inst.encMovqXmmFromR64(.xmm7, .rax).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovImm32W(.rax, 0x4F800000).slice());
        try buf.appendSlice(allocator, inst.encMovdXmmFromR32(.xmm7, .rax).slice());
    }

    // 4. UCOMI src, xmm7 ; JAE max_path.
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    const jae_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());

    // 5. In-range: CVTTSS/SD2SI .q gpr_dst, src. Lower 32 bits
    //    hold the i32 result (upper bits are 0 since src < 2^32).
    try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, true, dst, src_x).slice());

    // 6. JMP done.
    const jmp_done_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 7. zero_path; patch JP, JBE.
    const zero_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jp_byte, 6, @as(i32, @intCast(zero_byte)) - @as(i32, @intCast(jp_byte)) - 6);
    inst.patchRel32(buf.items, jbe_byte, 6, @as(i32, @intCast(zero_byte)) - @as(i32, @intCast(jbe_byte)) - 6);
    try buf.appendSlice(allocator, inst.encXorRR(.d, dst, dst).slice());

    // 8. JMP done.
    const jmp_zero_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 9. max_path; patch JAE.
    const max_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jae_byte, 6, @as(i32, @intCast(max_byte)) - @as(i32, @intCast(jae_byte)) - 6);
    try buf.appendSlice(allocator, inst.encMovImm32W(dst, 0xFFFFFFFF).slice());

    // 10. done; patch JMPs.
    const done_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jmp_done_byte, 5, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jmp_done_byte)) - 5);
    inst.patchRel32(buf.items, jmp_zero_byte, 5, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jmp_zero_byte)) - 5);

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.3 (Wasm 2.0 i64.trunc_sat_f32/f64_u) — saturating
/// unsigned trunc to i64. i64 doesn't fit in positive signed i64
/// above 2^63, so a 2^63 split path is needed:
///
///   UCOMI src, src ; JP zero_path           ; NaN
///   XORPS xmm7, xmm7
///   UCOMI src, xmm7 ; JBE zero_path         ; src ≤ 0
///   ; ≥ 2^64 → UINT64_MAX
///   MOVABS rax, threshold_max ; MOVQ xmm7, rax
///   UCOMI src, xmm7 ; JAE max_path
///   ; Decide < 2^63 or ≥ 2^63
///   MOVABS rax, threshold_split ; MOVQ xmm7, rax  (xmm7 = 2^63)
///   UCOMI src, xmm7 ; JAE high_path
///   ; src < 2^63: direct convert
///   CVTTSS2SI .q dst, src ; JMP done
///   high_path:
///     MOVAPS xmm6, src
///     SUBSS xmm6, xmm7              ; xmm6 = src - 2^63
///     CVTTSS2SI .q dst, xmm6        ; converts (now in [0, 2^63))
///     MOVABS rcx, 0x8000000000000000
///     OR dst, rcx                    ; restore high bit
///   JMP done
///   zero_path: XOR dst, dst (.q) ; JMP done
///   max_path:  MOVABS dst, UINT64_MAX
///   done:
///
/// Thresholds: 2^63 = 0x5F000000 (f32) / 0x43E0000000000000 (f64);
/// 2^64 = 0x5F800000 (f32) / 0x43F0000000000000 (f64). Both
/// exactly representable.
///
/// XMM6 + XMM7 used as FP scratches (XMM7 reserved per abi.zig;
/// XMM6 is an arg slot but not in regalloc pool — safe mid-op
/// since this op makes no calls). RAX/RCX are GPR scratches.
pub fn emitFpTruncSatU64(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst = try gpr.gprDefSpilled(alloc, result_v, 0);

    const is_f64_src = op == .@"i64.trunc_sat_f64_u";
    const scalar_kind: inst.SseScalarKind = if (is_f64_src) .f64 else .f32;
    const packed_kind: inst.SsePackedKind = if (is_f64_src) .f64 else .f32;

    // Helpers to materialise an FP threshold in xmm7.
    const Materialiser = struct {
        fn write(allo: Allocator, b: *std.ArrayList(u8), is_f64: bool, bits: u64) Error!void {
            if (is_f64) {
                try b.appendSlice(allo, inst.encMovImm64Q(.rax, bits).slice());
                try b.appendSlice(allo, inst.encMovqXmmFromR64(.xmm7, .rax).slice());
            } else {
                try b.appendSlice(allo, inst.encMovImm32W(.rax, @truncate(bits)).slice());
                try b.appendSlice(allo, inst.encMovdXmmFromR32(.xmm7, .rax).slice());
            }
        }
    };
    const threshold_max: u64 = if (is_f64_src) 0x43F0000000000000 else 0x5F800000;
    const threshold_split: u64 = if (is_f64_src) 0x43E0000000000000 else 0x5F000000;

    // 1. NaN check.
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, src_x).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, src_x).slice());
    }
    const jp_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.p, 0).slice());

    // 2. ≤ 0 → zero path.
    try buf.appendSlice(allocator, inst.encSsePackedBinary(packed_kind, 0x57, .xmm7, .xmm7).slice());
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    const jbe_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());

    // 3. ≥ 2^64 → max path.
    try Materialiser.write(allocator, buf, is_f64_src, threshold_max);
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    const jae_max_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());

    // 4. ≥ 2^63 → high path; xmm7 ends up holding 2^63.
    try Materialiser.write(allocator, buf, is_f64_src, threshold_split);
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    const jae_high_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());

    // 5. src < 2^63: direct CVTTSS2SI .q.
    try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, true, dst, src_x).slice());
    const jmp_direct_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 6. high path: subtract 2^63 (in xmm7) from src, convert, restore high bit.
    const high_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jae_high_byte, 6, @as(i32, @intCast(high_byte)) - @as(i32, @intCast(jae_high_byte)) - 6);
    try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm6, src_x).slice());
    try buf.appendSlice(allocator, inst.encSseScalarBinary(scalar_kind, 0x5C, .xmm6, .xmm7).slice()); // SUBSS/SD
    try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, true, dst, .xmm6).slice());
    try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, 0x8000000000000000).slice());
    try buf.appendSlice(allocator, inst.encOrRR(.q, dst, .rcx).slice());
    const jmp_high_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 7. zero path; patch JP, JBE.
    const zero_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jp_byte, 6, @as(i32, @intCast(zero_byte)) - @as(i32, @intCast(jp_byte)) - 6);
    inst.patchRel32(buf.items, jbe_byte, 6, @as(i32, @intCast(zero_byte)) - @as(i32, @intCast(jbe_byte)) - 6);
    try buf.appendSlice(allocator, inst.encXorRR(.q, dst, dst).slice());
    const jmp_zero_byte: u32 = @intCast(buf.items.len);
    try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

    // 8. max path; patch JAE-max.
    const max_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jae_max_byte, 6, @as(i32, @intCast(max_byte)) - @as(i32, @intCast(jae_max_byte)) - 6);
    try buf.appendSlice(allocator, inst.encMovImm64Q(dst, 0xFFFFFFFFFFFFFFFF).slice());

    // 9. done; patch the 3 JMPs.
    const done_byte: u32 = @intCast(buf.items.len);
    inst.patchRel32(buf.items, jmp_direct_byte, 5, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jmp_direct_byte)) - 5);
    inst.patchRel32(buf.items, jmp_high_byte, 5, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jmp_high_byte)) - 5);
    inst.patchRel32(buf.items, jmp_zero_byte, 5, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jmp_zero_byte)) - 5);

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.3 (Wasm 1.0 i32/i64.trunc_f32/f64_s) — trapping
/// signed truncate. Spec: trap on NaN, src ≥ INT_MAX+1, or
/// src < INT_MIN. Otherwise truncate.
///
///   UCOMI src, src ; JP trap                ; NaN
///   Materialise (INT_MAX+1) as float in xmm7
///   UCOMI src, xmm7 ; JAE trap              ; src ≥ INT_MAX+1
///   Materialise INT_MIN as float in xmm7
///   UCOMI src, xmm7 ; JB trap               ; src < INT_MIN
///   CVTTSS2SI dst, src                       ; in-range
///
/// Trap branches are appended to bounds_fixups (function-tail
/// stub sets trap_flag=1 and returns 0; same shared mechanism
/// as memory bounds traps; see ADR-0028 for per-reason split).
///
/// Thresholds (all exactly representable):
///   2^31  = 0x4F000000 (f32) / 0x41E0000000000000 (f64)
///   -2^31 = 0xCF000000 (f32) / 0xC1E0000000000000 (f64)
///   2^63  = 0x5F000000 (f32) / 0x43E0000000000000 (f64)
///   -2^63 = 0xDF000000 (f32) / 0xC3E0000000000000 (f64)
pub fn emitFpTruncTrapSigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    invalid_conv_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst = try gpr.gprDefSpilled(alloc, result_v, 0);

    const is_f64_src = switch (op) {
        .@"i32.trunc_f64_s", .@"i64.trunc_f64_s" => true,
        else => false,
    };
    const is_i64_dst = switch (op) {
        .@"i64.trunc_f32_s", .@"i64.trunc_f64_s" => true,
        else => false,
    };
    const scalar_kind: inst.SseScalarKind = if (is_f64_src) .f64 else .f32;

    const upper_bits: u64 = if (is_i64_dst)
        (if (is_f64_src) @as(u64, 0x43E0000000000000) else 0x5F000000)
    else
        (if (is_f64_src) @as(u64, 0x41E0000000000000) else 0x4F000000);
    // D-091 close — lower-bound threshold for `i32.trunc_f64_s`
    // (f64 → i32 signed). f64 represents the boundary half-step
    // values (e.g. -2147483648.9) which `trunc` rounds to INT_MIN
    // (in range). The naive threshold `-2^31` with strict `JB`
    // wrongly traps these. Use `-(2^31 + 1) = -2147483649.0` and
    // `JBE` so:
    //   x = -2^31           → JBE off, no trap; CVTTSD2SI → INT_MIN. ✓
    //   x = -2^31 - 0.5     → JBE off (> -2147483649), no trap;
    //                          CVTTSD2SI → INT_MIN. ✓
    //   x = -2147483649.0   → JBE on (= -2147483649), trap. ✓
    //   x = -2^31 - 2.0     → JBE on (< -2147483649), trap. ✓
    // Other variants (i32_s f32, i64_s f32, i64_s f64) have FP
    // precision coarser than the boundary gap (f32 step at 2^31
    // is 256; f64 step at 2^63 is 2048), so no half-step values
    // exist between INT_MIN and the next-representable below, and
    // the original `-2^N` / `JB` shape stays correct.
    const i32_s_f64 = !is_i64_dst and is_f64_src;
    const lower_bits: u64 = if (i32_s_f64)
        @as(u64, 0xC1E0000000200000) // -2147483649.0 (f64)
    else if (is_i64_dst)
        (if (is_f64_src) @as(u64, 0xC3E0000000000000) else 0xDF000000)
    else
        @as(u64, 0xCF000000); // i32_s f32: -2^31 unchanged

    // 1. UCOMI src, src ; JP trap.
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, src_x).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, src_x).slice());
    }
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.p, 0).slice());
        try invalid_conv_fixups.append(allocator, fixup_at); // D-293 slice-3 NaN → invalid_conversion (code 9)
    }

    // 2. Upper bound: load (INT_MAX+1) into xmm7, UCOMI, JAE trap.
    try materialiseFpThreshold(allocator, buf, is_f64_src, upper_bits);
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
        try overflow_fixups.append(allocator, fixup_at); // D-293 slice-3 trunc range → int_overflow (code 8)
    }

    // 3. Lower bound: load INT_MIN (or -(INT_MIN+1) for i32_s f64,
    // see lower_bits comment) into xmm7, UCOMI, conditional trap.
    // i32_s f64 uses `JBE` (≤) against -2147483649; all other
    // variants use `JB` (<) against -2^N. See lower_bits derivation.
    try materialiseFpThreshold(allocator, buf, is_f64_src, lower_bits);
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        const lower_cc: inst.Cond = if (i32_s_f64) .be else .b;
        try buf.appendSlice(allocator, inst.encJccRel32(lower_cc, 0).slice());
        try overflow_fixups.append(allocator, fixup_at); // D-293 slice-3 trunc range → int_overflow (code 8)
    }

    // 4. In-range: CVTTSS2SI/SD dst, src.
    try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, is_i64_dst, dst, src_x).slice());

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// Wasm spec §4.3 (Wasm 1.0 i32/i64.trunc_f32/f64_u) — trapping
/// unsigned truncate. Spec: trap on NaN, src ≤ -1, src ≥ 2^N.
/// Otherwise truncate.
///
/// For i32_u: in-range CVTTSS2SI .q form handles (-1, 2^32)
/// directly (range fits in positive i64, and (-1, 0) trunc to 0).
///
/// For i64_u: same range checks, then 2^63 split path (mirrors
/// trunc_sat_u64): src < 2^63 → direct convert; src ≥ 2^63 →
/// SUBSS by 2^63, convert, OR with sign bit.
///
/// Trap branches share the bounds_fixups list (function-tail trap
/// stub). Internal high-path branch for i64_u uses local rel32
/// patches.
pub fn emitFpTruncTrapUnsigned(
    allocator: Allocator,
    buf: *std.ArrayList(u8),
    alloc: regalloc.Allocation,
    pushed_vregs: *std.ArrayList(u32),
    next_vreg: *u32,
    invalid_conv_fixups: *std.ArrayList(u32),
    overflow_fixups: *std.ArrayList(u32),
    spill_base_off: u32,
    op: zir.ZirOp,
) Error!void {
    if (pushed_vregs.items.len < 1) return Error.AllocationMissing;
    const src_v = pushed_vregs.pop().?;
    const result_v = next_vreg.*;
    next_vreg.* += 1;
    if (result_v >= alloc.slots.len) return Error.SlotOverflow;
    const src_x = try gpr.xmmLoadSpilled(allocator, buf, alloc, spill_base_off, src_v, 0);
    const dst = try gpr.gprDefSpilled(alloc, result_v, 0);

    const is_f64_src = switch (op) {
        .@"i32.trunc_f64_u", .@"i64.trunc_f64_u" => true,
        else => false,
    };
    const is_i64_dst = switch (op) {
        .@"i64.trunc_f32_u", .@"i64.trunc_f64_u" => true,
        else => false,
    };
    const scalar_kind: inst.SseScalarKind = if (is_f64_src) .f64 else .f32;

    const neg_one_bits: u64 = if (is_f64_src) 0xBFF0000000000000 else 0xBF800000;
    const upper_bits: u64 = if (is_i64_dst)
        (if (is_f64_src) @as(u64, 0x43F0000000000000) else 0x5F800000)
    else
        (if (is_f64_src) @as(u64, 0x41F0000000000000) else 0x4F800000);

    // 1. UCOMI src, src ; JP trap.
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, src_x).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, src_x).slice());
    }
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.p, 0).slice());
        try invalid_conv_fixups.append(allocator, fixup_at); // D-293 slice-3 NaN → invalid_conversion (code 9)
    }

    // 2. Lower bound: trap if src ≤ -1. Materialise -1.0, JBE trap.
    try materialiseFpThreshold(allocator, buf, is_f64_src, neg_one_bits);
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.be, 0).slice());
        try overflow_fixups.append(allocator, fixup_at); // D-293 slice-3 trunc range → int_overflow (code 8)
    }

    // 3. Upper bound: trap if src ≥ 2^N.
    try materialiseFpThreshold(allocator, buf, is_f64_src, upper_bits);
    if (is_f64_src) {
        try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
    } else {
        try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
    }
    {
        const fixup_at: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());
        try overflow_fixups.append(allocator, fixup_at); // D-293 slice-3 trunc range → int_overflow (code 8)
    }

    // 4. In-range convert.
    if (is_i64_dst) {
        // 2^63 split: src ≥ 2^63 → high_path (subtract 2^63 + OR sign bit).
        const split_bits: u64 = if (is_f64_src) 0x43E0000000000000 else 0x5F000000;
        try materialiseFpThreshold(allocator, buf, is_f64_src, split_bits);
        if (is_f64_src) {
            try buf.appendSlice(allocator, inst.encUcomisd(src_x, .xmm7).slice());
        } else {
            try buf.appendSlice(allocator, inst.encUcomiss(src_x, .xmm7).slice());
        }
        const jae_high_byte: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJccRel32(.ae, 0).slice());

        // src < 2^63: direct convert.
        try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, true, dst, src_x).slice());
        const jmp_done_byte: u32 = @intCast(buf.items.len);
        try buf.appendSlice(allocator, inst.encJmpRel32(0).slice());

        // high_path: SUBSS xmm6, xmm7 (xmm7 still holds 2^63), CVTTSS2SI, OR sign bit.
        const high_byte: u32 = @intCast(buf.items.len);
        inst.patchRel32(buf.items, jae_high_byte, 6, @as(i32, @intCast(high_byte)) - @as(i32, @intCast(jae_high_byte)) - 6);
        try buf.appendSlice(allocator, inst.encMovapsXmmXmm(.xmm6, src_x).slice());
        try buf.appendSlice(allocator, inst.encSseScalarBinary(scalar_kind, 0x5C, .xmm6, .xmm7).slice());
        try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, true, dst, .xmm6).slice());
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rcx, 0x8000000000000000).slice());
        try buf.appendSlice(allocator, inst.encOrRR(.q, dst, .rcx).slice());

        // done: patch jmp.
        const done_byte: u32 = @intCast(buf.items.len);
        inst.patchRel32(buf.items, jmp_done_byte, 5, @as(i32, @intCast(done_byte)) - @as(i32, @intCast(jmp_done_byte)) - 5);
    } else {
        // i32_u: CVTTSS2SI .q form on (-1, 2^32) range fits in i64
        // positive; lower 32 bits give correct u32 (and (-1,0)→0).
        try buf.appendSlice(allocator, inst.encCvttScalar2Int(scalar_kind, true, dst, src_x).slice());
    }

    try gpr.gprStoreSpilled(allocator, buf, alloc, spill_base_off, result_v, 0);
    try pushed_vregs.append(allocator, result_v);
}

/// `(ctx, ins)` adapters for the Wasm
/// 1.0 trapping trunc cohort. Unpack `ctx.*` fields into the
/// existing 8-arg `emitFpTruncTrapSigned` / `emitFpTruncTrapUnsigned`
/// positional impls, which dispatch on `ins.op` internally. All
/// four variants per family share the same body — per-op aliases
/// preserve the per-op-file shape required by the dispatch-collector
/// contract (each per-op file's `emit` fn names a distinct symbol).
pub fn emitI32TruncF32S(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpTruncTrapSigned(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.invalid_conv_fixups,
        ctx.overflow_fixups,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI32TruncF64S = emitI32TruncF32S;
pub const emitI64TruncF32S = emitI32TruncF32S;
pub const emitI64TruncF64S = emitI32TruncF32S;

pub fn emitI32TruncF32U(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpTruncTrapUnsigned(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.invalid_conv_fixups,
        ctx.overflow_fixups,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI32TruncF64U = emitI32TruncF32U;
pub const emitI64TruncF32U = emitI32TruncF32U;
pub const emitI64TruncF64U = emitI32TruncF32U;

/// `(ctx, ins)` adapters for the Wasm
/// 2.0 saturating trunc cohort. No `bounds_fixups` (saturating,
/// not trapping). Three legacy consumers — signed family
/// (`emitFpTruncSatSigned`), unsigned-to-i32 (`emitFpTruncSatU32`),
/// unsigned-to-i64 (`emitFpTruncSatU64`) — each gets a primary
/// `(ctx, ins)` adapter and per-op aliases (legacy impls dispatch
/// on `ins.op` internally).
pub fn emitI32TruncSatF32S(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpTruncSatSigned(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI32TruncSatF64S = emitI32TruncSatF32S;
pub const emitI64TruncSatF32S = emitI32TruncSatF32S;
pub const emitI64TruncSatF64S = emitI32TruncSatF32S;

pub fn emitI32TruncSatF32U(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpTruncSatU32(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI32TruncSatF64U = emitI32TruncSatF32U;

pub fn emitI64TruncSatF32U(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpTruncSatU64(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI64TruncSatF64U = emitI64TruncSatF32U;

/// `(ctx, ins)` adapters for the
/// int→float convert cohort. Two legacy consumers — simple-path
/// (`emitFpConvertSimple`, also serves f64.promote_f32 /
/// f32.demote_f64 / reinterpret family, but only the 6 signed
/// convert + i32_u convert variants route here) and the
/// branched i64_u path (`emitFpConvertI64Unsigned`). Each gets
/// one primary `(ctx, ins)` adapter; per-op aliases preserve
/// the per-op-file shape.
pub fn emitF32ConvertI32S(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpConvertSimple(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitF32ConvertI64S = emitF32ConvertI32S;
pub const emitF64ConvertI32S = emitF32ConvertI32S;
pub const emitF64ConvertI64S = emitF32ConvertI32S;
pub const emitF32ConvertI32U = emitF32ConvertI32S;
pub const emitF64ConvertI32U = emitF32ConvertI32S;

pub fn emitF32ConvertI64U(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpConvertI64Unsigned(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitF64ConvertI64U = emitF32ConvertI64U;

/// `(ctx, ins)` adapters for the
/// reinterpret + promote/demote cohort. Single legacy consumer
/// (`emitFpConvertSimple`). Primary adapter + 5 aliases.
pub fn emitI32ReinterpretF32(ctx: *ctx_mod.EmitCtx, ins: *const zir.ZirInstr) Error!void {
    return emitFpConvertSimple(
        ctx.allocator,
        ctx.buf,
        ctx.alloc,
        ctx.pushed_vregs,
        ctx.next_vreg,
        ctx.spill_base_off,
        ins.op,
    );
}
pub const emitI64ReinterpretF64 = emitI32ReinterpretF32;
pub const emitF32ReinterpretI32 = emitI32ReinterpretF32;
pub const emitF64ReinterpretI64 = emitI32ReinterpretF32;
pub const emitF64PromoteF32 = emitI32ReinterpretF32;
pub const emitF32DemoteF64 = emitI32ReinterpretF32;

/// Materialise an FP bit pattern into XMM7 via RAX scratch.
/// Used by the FP trunc-trap helpers above. Module-private —
/// `emitFpTruncSatU64` inlines its own copy because it also needs
/// to materialise into XMM7 with slightly different constants;
/// keeping these distinct (rather than collapsing) preserves the
/// pre-split byte-stream shape.
fn materialiseFpThreshold(allocator: Allocator, buf: *std.ArrayList(u8), is_f64: bool, bits: u64) Error!void {
    if (is_f64) {
        try buf.appendSlice(allocator, inst.encMovImm64Q(.rax, bits).slice());
        try buf.appendSlice(allocator, inst.encMovqXmmFromR64(.xmm7, .rax).slice());
    } else {
        try buf.appendSlice(allocator, inst.encMovImm32W(.rax, @truncate(bits)).slice());
        try buf.appendSlice(allocator, inst.encMovdXmmFromR32(.xmm7, .rax).slice());
    }
}
