//! ARM64 emit pass — control-flow label + branch-fixup types.
//!
//! Per ADR-0023 §3 reference table + ADR-0021 sub-deliverable b
//! (§9.7 / 7.5d sub-b emit.zig 9-module split): extracted from
//! the previous monolithic `emit.zig` so the control-flow
//! patching machinery has a discoverable home and so emit.zig
//! itself can shrink toward the < 1000 LOC orchestrator goal.
//!
//! ADR-0014 §6.K.5 + `.claude/rules/single_slot_dual_meaning.md`:
//! the `merge_top_vreg` slot is load-bearing for the D-027 fix
//! (`(if (result T))` arm convergence); a future change that
//! merges it with another field is a §14 violation.
//!
//! Zone 2 (`src/engine/codegen/arm64/`).

const std = @import("std");

/// Why a Label was pushed on the control stack. Distinguishes
/// forward-resolving block / if branches from backward-resolving
/// loop branches.
pub const LabelKind = enum { block, loop, if_then, else_open };

/// Patching mechanism for an unresolved branch instruction.
/// `b_uncond` = unconditional `B` (br); `cbnz_w` = conditional
/// `CBNZ W` (br_if).
pub const FixupKind = enum { b_uncond, cbnz_w };

/// One pending branch awaiting target resolution. `byte_offset`
/// names the branch instruction's position in the emitted
/// buffer; the patcher recomputes its disp19 / disp26 when the
/// owning Label resolves.
pub const Fixup = struct {
    byte_offset: u32,
    kind: FixupKind,
};

/// One frame on the per-function control stack. The kind +
/// pending list combine to handle both block / loop / if /
/// else flow:
///
///   target_byte_offset — for `.loop`, the byte offset of the
///       loop entry (backward branches resolve immediately).
///       For `.block` / `.if_then` / `.else_open`, undefined
///       until `end` (or `else`) lands; pending fixups patch
///       at that point.
///   pending — branch fixups waiting on target resolution.
///   if_skip_byte — when `.if_then`, the byte offset of the
///       CBZ that skips the then-body. Patched at `else` (to
///       else-body start) or at `end` (to end of if). Cleared
///       when transitioning to `.else_open`.
///   merge_top_vreg — D-027 fix (sub-7.5c-vi): for `(if
///       (result T))` blocks, the then arm's result vreg is
///       captured at `else`; the else arm's result is MOVed
///       into this vreg's register at the if-frame's `end` so
///       both paths converge on the same physical reg. Null
///       for blocks without arity OR when no `else` was
///       emitted.
pub const Label = struct {
    kind: LabelKind,
    target_byte_offset: u32,
    pending: std.ArrayList(Fixup),
    if_skip_byte: ?u32 = null,
    merge_top_vreg: ?u32 = null,
};
