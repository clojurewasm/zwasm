---
name: lint-debt-at-phase-close
description: Phase 7 close commit (`9da3c99`) landed with 8 pre-existing lint warnings (5 no_unused + 3 require_exhaustive_enum_switch) — same shape as the file-size-blindspot lesson; mandatory pre-commit checks list is informational, not enforced
type: feedback
---

# Lint debt landed at Phase 7 close — pre-commit list is advisory, not enforced

## Observation

Resuming Phase 8 / §9.8 / 8.1, `zig build lint -- --max-warnings 0`
exits 1 at HEAD `9da3c99` (Phase 7 close commit) with 8 warnings
all in `src/engine/codegen/x86_64/`:

- `no_unused`: 5 dangling `const std = @import("std")` / `const abi`
  imports across `inst_sse.zig`, `inst_alu.zig`, `inst_branch.zig`,
  `inst_mem.zig`, `op_convert.zig` (left over from D-030's 8-chunk
  responsibility split — extractions removed std usage but left the
  import declaration).
- `require_exhaustive_enum_switch`: 3 sites in `emit.zig` using
  `else => {}` / `else => unreachable` over the exhaustive `ValType`
  enum.

## Why this matters

CLAUDE.md "Mandatory pre-commit checks" lists `zig build lint` as
gate (4). But there is **no `.git/hooks/pre-commit` file** in the
repo — the checks are advisory documentation, not enforced. The
autonomous /continue loop's per-task Step 4 includes a Mac-host
lint gate, but Phase 7 close (chained close-up commits — 7.13 +
debt sweep + handover) executed under enough chunk-batching that
the lint gate apparently slipped through one of the iterations.

Same shape as `2026-05-08-file-size-blindspot.md` (Phase 7 closed
with 3 active §14 file-size hard-cap violations interpreted as
"acknowledged + tracked = fine to continue").

**Why:** when a category of debt is **observable** (`zig build lint`
exits 1) but the autonomous loop doesn't fail-fast on it, the loop
will accumulate the debt across phase boundaries silently — the
"commit summary said success" signal masks the underlying gate
failure.

**How to apply:**

1. Per-task Step 4 lint gate must be **fail-fast** — if
   `zig build lint` exits 1, STOP the per-task TDD loop and
   discharge the lint debt before proceeding (current §9.8 / 8.1-a
   precedent: surface 8 warnings at chunk start; fix them as
   chunk's first sub-step; only then resume the chunk's own
   feature).
2. Phase-boundary `audit_scaffolding` should explicitly check
   `zig build lint` exit code as part of the routine §A
   (functional health) section, not just §F (debt coherence).
3. The CHECKS / LOOP gap that lets these slip is the same one
   the file-size lesson identified — escalate from `watch` to
   `block` at phase boundaries for any hard-gate (lint, file-size,
   zone_check, spill_aware) that is currently exit-1 at HEAD.

## Discharge

8 warnings cleared in §9.8 / 8.1-a commit (5 unused imports
deleted + 3 switch sites widened to explicit `.v128, .funcref,
.externref => unreachable` enumeration per zig_tips.md
"Exhaustive enum switch"). Citing: this commit's SHA backfilled
at next phase boundary.
