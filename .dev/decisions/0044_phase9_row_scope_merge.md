---
name: Merge §9.8 scope into §9.7 row (Phase 9 task close-out)
description: Close §9.8 [x] without separate sub-chunks because its scope was absorbed by §9.7's progressive expansion
status: Accepted
date: 2026-05-10
---

# ADR-0044: Merge §9.8 scope into §9.7 row

## Status

Accepted (2026-05-10)

## Context

Phase 9's task table at the time of opening (§9.0 commit `c50296c`) split
the x86_64 SIMD emit work into two rows:

| Row | Original scope                                                          |
|-----|-------------------------------------------------------------------------|
| 9.7 | x86_64 emit (SSE4.1+SSE4.2 baseline): SIMD load/store + lane access + integer arithmetic |
| 9.8 | x86_64 emit (SSE4.1): SIMD comparison + shuffle + float arithmetic + conversion |

The split anticipated a foundation chunk (9.7) followed by a comparison /
FP / shuffle / conversion chunk (9.8). In practice the implementation
progressed as a single linear sequence under the §9.7 row's prose
(sub-chunks 9.7-a through 9.7-bb across ~60 commits), and naturally
covered both nominal scopes:

- 9.7-k..n — int compares (eq/ne/lt/gt/le/ge × {s,u})
- 9.7-o — FP compares
- 9.7-p..q — FP arith (add/sub/mul/div/sqrt + min/max NaN-correction)
- 9.7-r..s — bitwise + reductions
- 9.7-t..w — shifts
- 9.7-x..y — extends + narrowing
- 9.7-z..ad — abs/neg/swizzle/FP unops
- 9.7-ae..ap — trunc-sat / pairwise extadd / FP convert
- 9.7-ar — i8x16.shuffle (the "shuffle" originally in 9.8's scope)
- 9.7-aj..aq — extadd_pairwise
- 9.7-ax..bb — v128 memory ops (load/store/splat/zero/lane/extend)

By 9.7-bb close (commit `401f2e1f`), all 237 SIMD ops in zir.zig:184-288
have x86_64 emit handlers — verified by:

```
sed -n '184,288p' src/ir/zir.zig | grep -oE '@"[^"]+"' | sort -u
  | while read op; do
      grep -qE "^[[:space:]]+\.@\"${op:2:-1}\"" src/engine/codegen/x86_64/emit.zig
        || echo "$op"
    done
# (zero output)
```

§9.8's nominal scope is therefore substantively done, with no remaining
emit work to enumerate as additional sub-chunks.

## Decision

Close §9.8 as `[x]` in the same chore commit that closes §9.7, with a
prose annotation in the §9.8 row pointing to the §9.7 sub-chunks that
delivered each piece of its nominal scope. Do NOT carve fictional 9.8-a
sub-chunks for work that never landed under that row ID; the git log
under `§9.7 / 9.7-*` is the authoritative trail.

## Alternatives considered

### A. Carve 9.8-a..z sub-chunks for already-landed work

Re-attribute prior commits to 9.8 sub-IDs in retrospect. Rejected:

- Commit messages reference `§9.7 / 9.7-X` not `§9.8 / 9.8-X`; renaming
  retrospectively breaks the `git log --grep="§9.<N> / N.M"` lookup
  pattern that ROADMAP §18 + the per-task TDD loop both rely on.
- Adds zero information — the reader's question "which commits cover
  9.8's nominal scope?" is already answered by the §9.8 row prose
  pointing at the §9.7 sub-chunks.

### B. Keep §9.8 [ ] and create empty close-out sub-chunks

Add a 9.8-a "scope verification" sub-chunk that just runs the grep above
and flips [x]. Rejected:

- Pure ceremony — no source code change, no behaviour change. The work
  IS done; marking it [x] is the routine status update §18 explicitly
  whitelists. The ADR (this document) handles the scope-merge
  bookkeeping.

### C. Renumber §9.9 → §9.8 and shift all later rows down

Drop the empty §9.8 entirely and renumber §9.9 (simd.wast spec test) →
§9.8, §9.10 → §9.9, etc. Rejected:

- Renumbering rows mid-Phase invalidates handover, debt, and external
  references that already cite §9.9..§9.12 by number.
- Phase row numbering is treated as a stable identifier; absorption
  with annotation preserves traceability.

## Consequences

- §9.7 + §9.8 both flip [x] in the close commit. Phase 9 row count is
  unchanged; only the bookkeeping shape of §9.8 changes.
- The §9.8 row prose gets a one-sentence annotation pointing at the
  §9.7 sub-chunks (9.7-k..n, 9.7-o, 9.7-p..q, 9.7-ab..ae, 9.7-ar, etc.)
  that delivered each piece of its nominal scope.
- Future Phase plans should consider this pattern: when a row's scope
  is naturally absorbed by an adjacent row's progressive expansion, an
  ADR-documented merge is preferable to forcing artificial sub-chunks.
- Phase 9 progress widget moves from `IN-PROGRESS at §9.7` directly to
  `IN-PROGRESS at §9.9` (skipping the empty-by-merge §9.8).

## References

- ROADMAP §9 task table (Phase 9 row): the §9.7 row prose + this ADR
  reference document the absorption.
- Commits §9.7 / 9.7-a (`...`) through §9.7 / 9.7-bb (`401f2e1f`) for
  the actual implementation trail. SHA backfill happens at Phase 9
  close per the standard procedure.
- ADR-0041 §5 amend at 9.7-m (commit subject "ADR-0041 §5 amended to
  raise x86_64 baseline SSE4.1 → SSE4.2") — the scope-expansion event
  that enabled 9.7 to consume 9.8's nominal SSE4.1 scope.

## Revision history

| Date       | Reason                                                    |
|------------|-----------------------------------------------------------|
| 2026-05-10 | Initial — filed at §9.7 row close to authorise §9.8 [x] without separate sub-chunks. |
