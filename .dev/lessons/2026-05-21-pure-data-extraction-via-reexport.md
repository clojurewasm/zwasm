# Pure-data extraction via re-export: zero-caller-migration shape

**Date**: 2026-05-21
**Keywords**: ADR-0082, ADR-0086, ADR-0087, ADR-0088, per-file ADR, D-141, re-export, pure data, dispatch_collector, zir_ops, stack_effect, refactor, file-size cap, zero migration
**Citing**: `7bec6946` (ADR-0082), `f0d91a82` (ADR-0086), `50834b6f` (ADR-0087), `0f3f863f` (ADR-0088)

## The pattern

When a file's mass is dominated by a **single declaration block**
(tuple literal, enum body, comptime-resolved switch, struct
catalog) that has:

- no methods on the type itself,
- no mutable state,
- no internal helpers that the rest of the file needs,

the cheapest possible file split is **extract to sibling +
re-export**:

```zig
// In the original file (orig.zig), where the block used to live:
const data_sibling = @import("orig_data.zig");
pub const Big = data_sibling.Big;          // type alias re-export
pub const big_thing = data_sibling.big_thing;  // const / fn alias
```

External callers continue to reach `orig.Big` and `orig.big_thing`
identically — **zero caller migration**.

## When this pattern applies (the 4 validated cases)

Across 4 ADRs in a single session, the pattern proved to be
mechanical + safe whenever the criteria hold:

| ADR | Source file (before → after) | Extracted block | Sibling LOC | Caller migration |
|---|---|---|---|---|
| 0082 | `src/ir/dispatch_collector.zig` (1397 → 500) | per-op `@import` lines + `collected_ops` tuple | 923 | 0 |
| 0086 | `src/engine/codegen/dispatch_collector.zig` (1887 → 264) | per-arch `@import` lines + 3 `collected_*_ops` tuples | 1642 | 0 |
| 0087 | `src/ir/zir.zig` (1244 → 566) | `pub const ZirOp = enum(u16) { ... };` (684 LOC) | 693 | 0 |
| 0088 | `src/ir/analysis/liveness.zig` (1192 → 679) | `pub const StackEffect = struct { ... };` + `pub fn stackEffect(op) { switch { ... } }` (509-LOC switch) | 533 | 0 |

Total mass moved: **3791 LOC of pure data** across 4 sibling
files; **0 caller sites updated**.

## Why this is cheap to verify

The re-export form is a single line per re-exported symbol; Zig's
type system catches any naming mistake at build time. The cohort
test gate (`zig build test-all`) + lint gate confirms the
extraction is behaviour-preserving. No semantic surprises possible
— `data_sibling.X` is structurally identical to the original
`X` declaration; the re-export is a comptime-resolved alias with
zero runtime overhead.

## Contrast with the non-re-export pattern (ADR-0084)

ADR-0084 (arm64/inst.zig FP machinery) extracted **35 encoder
functions**. Each function was directly imported from external
files via `inst.encFXxx` syntax. Re-export was insufficient
because:

- Each encoder is a separate symbol (vs ADR-0082's single
  `collected_ops` re-exportable handle).
- Re-exporting 35 individual `pub const encFAddS = inst_fp.encFAddS;`
  lines is ugly + verbose.
- Direct sed-rewrite of caller imports (`inst.encF*` →
  `inst_fp.encF*`) was cleaner — 127 substitutions across 11 files.

The lesson: re-export shines when **one or two symbols** carry
the dominant LOC (a single tuple, a single enum, a struct +
its associated function). For **many independent symbols**
(an encoder catalog), per-caller migration is the right shape.

## Survey checklist for future per-file ADR candidates

Before drafting a per-file ADR for an over-cap file, ask:

1. **Is there a single declaration block > 40% of file LOC?**
   - If yes → re-export pattern likely applies. Single-cycle
     mechanical extraction. Draft + impl same cycle.
   - If no → the file's mass is spread across many independent
     things. ADR-grade design choice required (per-family split?
     caller-side migration? state-threading refactor?).

2. **Does that block have methods on its type?**
   - If yes (struct with `pub fn` methods, enum with methods) →
     cross-file method-syntax issue (per lesson
     [`2026-05-21-cross-file-struct-method-syntax-zig-0-16`](./2026-05-21-cross-file-struct-method-syntax-zig-0-16.md));
     re-export still works but pub-ifying methods is needed.
   - If no → re-export is pure mechanical. The pattern at the
     top of this lesson applies directly.

3. **Are external callers reaching the block via its file's
   namespace (`orig.Symbol`) or via the symbol directly
   (`encFooBar`)?**
   - Via namespace → re-export. Zero caller migration.
   - Via direct symbol (e.g., individual function imports) →
     per-caller sed migration (ADR-0084 pattern).

## Related ADRs / lessons

- ADR-0082 — first validated case (ir/dispatch_collector).
- ADR-0086 — Zone-2 codegen mirror.
- ADR-0087 — ZirOp catalog (enum, not tuple).
- ADR-0088 — stackEffect switch (function, not type — the
  `pub const fn-alias = mod.fn` form).
- Lesson
  [`2026-05-21-cross-file-struct-method-syntax-zig-0-16`](./2026-05-21-cross-file-struct-method-syntax-zig-0-16.md)
  — sibling rule for when methods are involved.
- Lesson
  [`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](./2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md)
  — measurement-focused Step 0 survey discipline that lets you
  detect "single declaration block > 40%" cleanly.
- D-141 — file-size soft-cap proliferation; the survey
  checklist above is the standing screening procedure when
  picking the next D-141 candidate.

## When the rule dissolves

After D-141 closes (file_size_check WARN list emptied or all
remaining over-cap files have FILE-SIZE-EXEMPT markers), this
pattern's per-file ADR series concludes. Re-export remains
generally available as a refactor tool but ceases to be the
*default* extraction shape — future file growth would surface
new design questions (per-family, per-version, etc.) rather
than re-applying the same mechanical pattern.

## When this lesson does NOT apply (added 2026-05-21 post-retrospective)

This lesson covers the **Pure-data re-export pattern only**. Per
ADR-0099, file-size-driven extractions fall into multiple
patterns:

| Pattern | Lesson / discipline | Examples |
|---|---|---|
| Pure-data re-export | THIS lesson | ADR-0082, 0086, 0087, 0088, 0090 |
| Spec-defined closed sub-language (P1) | ADR-0099 §D2 P1 | ADR-0083, 0089 |
| Independent change cadence + deep interface (P3) | ADR-0099 §D2 P3 | ADR-0091, 0092, 0093, 0098 |
| Per-caller migration (sed-rewrite) | ADR-0084 narrative | ADR-0084 |
| **FILE-SIZE-EXEMPT (no valid extraction)** | ADR-0063 + ADR-0099 §D1 | entry.zig, op_simd_int_cmp_lane.zig |

**Do NOT use this lesson as justification when:**
- The dominant block is < 40% of file LOC (the lesson's threshold)
- The extracted "data" actually has methods or carries state
- The extraction requires pub-ifying a private helper (N2)
- The extracted module would be < 100 LOC substantive (N3)

When the conditions don't fit, the ADR-0099 §D2 4+4 conditions
govern.

### Retrospective: ADR-0091 was a border case

ADR-0091's Context section wrote:
> "Does ONE block exceed 40% of file LOC? The 326-LOC tail is 27%
> — below the 40% threshold, but cohesive."

That phrasing weakened the threshold without explicit justification.
Under ADR-0099, the correct evaluation is:

- The extraction's positive condition is P3 (independent change
  cadence + deep interface), not P2
- P2's 40% threshold is irrelevant when the justification is P3

ADR-0091 is retroactively recategorised under P3 (the
post-instantiate helpers are conceptually distinct from
compileWasm orchestration; consumed by Instance lifecycle + spec
runner). The extraction stands.

### Self-review note

The lesson at the time was implicitly suggesting that "below 40%"
→ "ADR-grade design choice required" → "but still might be
extractable." That ambiguity is the drift signal. The amendment
clarifies: below 40% → use a *different* positive condition
(P1/P3/P4) OR don't extract.
