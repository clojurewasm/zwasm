# 0093 — Extract merge-MOV helpers to `op_control_merge_mov.zig`

- **Status**: Accepted (2026-05-21, draft + impl landed same cycle)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0092)
- **Tags**: file-layout, refactor, zone-2, codegen-arm64, file-size-cap

## Context

`src/engine/codegen/arm64/op_control.zig` was 1127 LOC — 13%
over soft cap. The file is the arm64 control-flow emit handlers
(emitBlock / emitLoop / emitBr / emitBrIf / emitBrTable / emitIf /
emitElse / emitEndIntra) plus a 249-LOC block of private
merge-MOV helpers at the top (lines 59-307).

The merge-MOV block:

- `ParallelMove` struct (~25 LOC) — represents a single src→dst
  register move in a batch with dependency tracking.
- `resolveAndEmitMergeMovsRegBatch` (~75 LOC) — D-147 cycle-aware
  parallel-move resolver. Walks the batch breaking cycles via X16
  scratch.
- `emitMergeMov` (~60 LOC) — emit a single ARM64 MOV (handling
  V128/GPR/spill src vs dst combinations).
- `captureOrEmitBlockMergeMov` (~90 LOC) — branch-target merge
  capture logic (capture-vs-emit decision based on `tgt_idx`).
- `unpackBlockArity` (~7 LOC) — extract param/result counts from
  ZirInstr.extra payload.
- `merge_top_vregs_cap` constant.

All 4 fns + struct are private (no `pub`) — only called from
within op_control.zig's public emit handlers. Zero external
callers. The block sits in the file's header section, separating
the rich helpers (with their D-147 cycle-aware algorithm) from
the per-op emit handlers below.

## Decision

Move the block to a new sibling
`src/engine/codegen/arm64/op_control_merge_mov.zig`. Pub-ify the
4 helpers + struct for cross-file access; add `gpr` import (the
moved emitMergeMov body uses it). In op_control.zig, add:

```zig
const merge_mov = @import("op_control_merge_mov.zig");
const ParallelMove = merge_mov.ParallelMove;
```

Rewrite intra-file call sites (15+ across the 8 public emit
handlers): `helperFn(args)` → `merge_mov.helperFn(args)`.

| File | Contents | Approx LOC |
|---|---|---|
| `src/engine/codegen/arm64/op_control.zig` (revised) | 8 public emit handlers (block / loop / br / br_if / br_table / if / else / end) + 1 private branch-resolver helper (emitBranchToDepth) + imports + merge_mov import. | ~877 |
| `src/engine/codegen/arm64/op_control_merge_mov.zig` (new) | 28-line header + imports (incl. gpr, abi, regalloc references that moved) + merge_top_vregs_cap constant + 4 pub fns + 1 pub struct. | ~278 |

### Difference from re-export pattern (ADR-0090/0091/0092)

The moved helpers are NOT re-exported from op_control.zig — they
have no external callers. The pattern here is "private helper
relocation": pub-ified only for cross-file access from
op_control.zig itself; callers via `merge_mov.X` syntax. This
preserves the API surface (no new external entry points exposed).

### Implementation details

- Pub-ified: `ParallelMove`, `resolveAndEmitMergeMovsRegBatch`,
  `emitMergeMov`, `captureOrEmitBlockMergeMov`, `unpackBlockArity`.
- Added `gpr` import to sibling (needed by emitMergeMov body).
- Added `merge_top_vregs_cap: u8 = 8` constant (referenced by
  resolveAndEmitMergeMovsRegBatch's O(N²) loop bound).
- Removed 3 newly-unused imports from op_control.zig: `inst_fp` /
  `abi` / `regalloc` (only used inside the moved block).
- Removed 1 newly-unused import from op_control_merge_mov.zig:
  `std` (the moved body doesn't reference std directly).

Sed-rewrite of 4 helper names across 15+ call sites in
op_control.zig public emit fns.

## Alternatives considered

### Alternative A — Re-export from op_control.zig

- **Sketch**: pub-ify the 4 helpers + `pub const X = merge_mov.X;`
  re-exports in op_control.zig.
- **Why rejected**: no external caller reaches these helpers
  through op_control.X. Adding re-exports would expose private
  implementation as public API for no reason.

### Alternative B — Keep monolith + FILE-SIZE-EXEMPT

- **Sketch**: op_control.zig stays at 1127.
- **Why rejected**: the 249-LOC helper block is structurally
  distinct from the per-op emit handlers (different abstraction
  level — the merge-MOV is the "machinery", emit handlers are
  the "consumers"). Extraction improves the file's intent.

## Consequences

- **Positive**:
  - op_control.zig drops 1127 → 877 LOC (UNDER soft cap, -250).
  - Merge-MOV machinery findable by file name (someone tracking
    D-147 parallel-move cycle logic reaches
    `op_control_merge_mov.zig` immediately).
  - No new public API surface.
  - Removed 4 newly-unused imports (cleanup side-effect).
- **Negative**: none material. Sibling at 278 LOC is well under
  soft cap.
- **Neutral / follow-ups**:
  - Pattern variant: private-helper-relocation (vs ADR-0090's
    re-export pattern). Both apply depending on whether the
    moved block has external callers.

## References

- ADR-0090/0091/0092 — pure-data-via-re-export pattern (sister
  variants).
- D-147 — parallel-move cycle resolution (the helper block's
  origin).
- Lesson
  [`2026-05-18-parallel-move-cycle-in-if-merge`](../lessons/2026-05-18-parallel-move-cycle-in-if-merge.md)
  — design background for the cycle-aware resolver.
- Lesson
  [`2026-05-21-pure-data-extraction-via-reexport`](../lessons/2026-05-21-pure-data-extraction-via-reexport.md)
  — survey checklist that identified this block.
- D-141 — file-size soft-cap proliferation.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `41dcc43d`   | Initial draft + impl landed same cycle. op_control.zig 1127 → 877 LOC (UNDER soft cap, -250); op_control_merge_mov.zig 278 LOC new. Pub-ify 4 helpers + struct for cross-file access; intra-call sites rewritten via sed. 4 newly-unused imports removed post-extraction. Test gate cohort + lint green. |
