# 0090 — Extract populateShapeTags to `regalloc_shape_tags.zig`

- **Status**: Accepted (2026-05-21, draft + impl landed same cycle)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0089)
- **Tags**: file-layout, refactor, zone-2, codegen, regalloc, file-size-cap

## Context

`src/engine/codegen/shared/regalloc.zig` is **1851 LOC** — 85%
over soft cap (the largest remaining D-141 candidate after the
10 closures earlier in this session). Per the lesson
[`2026-05-21-pure-data-extraction-via-reexport`](../lessons/2026-05-21-pure-data-extraction-via-reexport.md)
survey checklist:

1. **Does ONE block exceed 40% of file LOC?** Almost. `populateShapeTags`
   (lines 716–1043) is **328 LOC = 17.7% of the file**; not quite
   the 40% threshold but the largest single declaration.
2. **Does it have methods?** No — it's a top-level pub fn (not
   a struct method). Re-export pattern applies.
3. **Callers reach via namespace or direct import?** Via namespace:
   1 external caller (`engine/codegen/x86_64/op_simd.zig:6` —
   docstring reference + use of `regalloc.populateShapeTags`).

The function is a complete unit: 303-LOC body walking
`ZirFunc.instrs` and signature to produce per-vreg `[]ShapeTag`
array for v128-aware emit dispatch. Dependencies are all
cross-module imports (zir, liveness) + regalloc-internal
`ShapeTag` / `Error` types — no internal private helpers that
need to move alongside.

## Decision

Move `populateShapeTags` + its doc comment (lines 716–1043) to a
new sibling `src/engine/codegen/shared/regalloc_shape_tags.zig`.
Re-export from `regalloc.zig` so the external caller continues to
reach `regalloc.populateShapeTags` identically.

| File | Contents | Approx LOC |
|---|---|---|
| `src/engine/codegen/shared/regalloc.zig` (revised) | docstring + imports + forbidden-mask helpers + validateRegallocOpScratchReservation + ShapeTag enum + Allocation struct + compute/computeWith/verify/verifyWith/deinit + VregClass enum + vregClassByDef/vregClassOfOp. Re-exports populateShapeTags from sibling. | ~1529 |
| `src/engine/codegen/shared/regalloc_shape_tags.zig` (new) | 22-line header + imports + populateShapeTags doc + body. | ~350 |

Re-export pattern (same as ADR-0088):

```zig
const shape_tags_mod = @import("regalloc_shape_tags.zig");
pub const populateShapeTags = shape_tags_mod.populateShapeTags;
```

**Zero caller migration** — `regalloc.populateShapeTags(...)` at
`op_simd.zig` reaches the function through the re-export
identically.

## Lint side-effect: unused liveness import

`regalloc.zig` had `const liveness = @import("../../../ir/analysis/liveness.zig");`
that was used ONLY inside `populateShapeTags`'s body (calls to
`liveness.compute` / `liveness.stackEffect`). After extraction,
the import became unused — `no_unused` lint flagged it. Removed
in the same commit. Other `liveness` mentions in `regalloc.zig`
are comments (`// Reads ZirFunc.liveness.?.ranges`) or field
accesses on `ZirFunc.liveness` (a struct field, not the imported
module).

## Alternatives considered

### Alternative A — Aggressive multi-axis split (verify / compute / shape_tags / vreg_class)

- **Sketch**: 4 sibling files (one per "phase" of regalloc).
- **Why rejected**: same anti-pattern as ADR-0084 Alternative A
  / ADR-0080. The 4 phases share `Allocation` / `Error` / `ShapeTag`
  types + `forbiddenMaskForVreg` helper. Splitting forces
  re-exports of 4+ types + 1 helper per sibling. Net cost
  exceeds the gain.

### Alternative B — Keep monolith + FILE-SIZE-EXEMPT

- **Sketch**: regalloc.zig stays at 1851; add exempt marker.
- **Why rejected**: regalloc.zig is not a uniform-adapter catalog
  (the ADR-0075 exempt rationale). It has 4 distinct semantic
  phases worth of logic. The shape_tags extraction is the
  largest single-axis cut available without fragmentation; doing
  it improves regalloc.zig's discoverability.

## Consequences

- **Positive**:
  - regalloc.zig drops 1851 → 1529 LOC. Still over soft cap but
    -322 reduction; no longer at hard-cap risk (471 LOC of
    headroom).
  - populateShapeTags becomes findable by file name (someone
    looking for "where are vreg shape tags computed" reaches
    `regalloc_shape_tags.zig` immediately).
  - Zero caller migration cost.
  - D-141 regalloc.zig slot closes.
- **Negative**:
  - regalloc.zig still over soft cap (1529 > 1000). Further
    extraction (compute/verify/vreg_class) requires ADR-grade
    design choice for axis selection — deferred until concrete
    pressure surfaces (no immediate need).
- **Neutral / follow-ups**:
  - Pattern composes cleanly with ADR-0082/0086/0087/0088 (5th
    instance of pure-data re-export this session).

## References

- ADR-0088 — ir/analysis/liveness_stack_effect.zig (direct
  precedent; same re-export pattern for a large top-level
  function).
- Lesson
  [`2026-05-21-pure-data-extraction-via-reexport`](../lessons/2026-05-21-pure-data-extraction-via-reexport.md)
  — the validated survey checklist that flagged populateShapeTags
  as a re-export candidate.
- D-141 — file-size soft-cap proliferation.
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `30ae661f`   | Initial draft + impl landed same cycle. regalloc.zig 1851 → 1529 LOC (-322); regalloc_shape_tags.zig 350 LOC new. Zero caller migration. Unused liveness module import removed post-extraction. Test gate cohort + lint green. D-141 regalloc.zig slot closes. |
