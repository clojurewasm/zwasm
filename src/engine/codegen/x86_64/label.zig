//! x86_64 emit pass — control-flow label + fixup types (D-030
//! chunk-a).
//!
//! Extracted from `emit.zig` per ADR-0023 §269-314. The Label
//! shape mirrors arm64's `Label` (per ADR-0014 §6.K.5 +
//! `single_slot_dual_meaning.md` — start vs end semantics live
//! on `kind`, not on a polymorphic field). `merge_top_vreg` is
//! the D-027 if-result merge fix mirror; `if_skip_byte` is the
//! JE-skip patch site for `if_then` frames.
//!
//! Behaviour change zero — emit.zig re-exports `LabelKind`
//! and uses `Fixup` / `Label` via the new import.
//!
//! Zone 2 (`src/engine/codegen/x86_64/`).

const std = @import("std");

/// Why a Label was pushed on the control stack. block / loop /
/// if_then / else_open mirror arm64's LabelKind for parity at
/// the §9.7 / 7.11 three-way differential.
pub const LabelKind = enum { block, loop, if_then, else_open };

/// Forward-jump fixup awaiting target resolution. `byte_offset`
/// is the position of the JMP/Jcc instruction's first byte;
/// `insn_size` is 5 (JMP rel32) or 6 (Jcc rel32). `emitEndIntra`
/// patches the disp32 field via `inst.patchRel32`.
pub const Fixup = struct {
    byte_offset: u32,
    insn_size: u8,
};

/// One frame on the per-function control stack.
///   target_byte_offset — for `.loop`, the byte offset of the
///       loop entry. For `.block` / `.if_then` / `.else_open`,
///       undefined until `end`.
///   pending — branch fixups awaiting target resolution.
///   if_skip_byte — when `.if_then`, the byte offset of the
///       JE that skips the then-body. Patched at `else` (to
///       else-body start) or at `end` (to end of if). Cleared
///       when transitioning to `.else_open`.
///   merge_top_vreg — D-027 fix mirror (per ADR-0014 §6.K.5):
///       for `(if (result T))` blocks, the then arm's result
///       vreg is captured at `else`; the else arm's result is
///       MOVed into this vreg's register at the if-frame's
///       `end` so both paths converge on the same physical reg.
///       Null for blocks without arity OR when no `else` was
///       emitted.
pub const Label = struct {
    kind: LabelKind,
    target_byte_offset: u32,
    pending: std.ArrayList(Fixup),
    if_skip_byte: ?u32 = null,
    merge_top_vreg: ?u32 = null,
};
