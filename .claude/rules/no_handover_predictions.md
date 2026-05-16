---
paths:
  - ".dev/handover.md"
  - ".dev/debt.md"
  - ".dev/ROADMAP.md"
---

# No numeric predictions in handover / debt

Auto-loaded when editing `.dev/handover.md`, `.dev/debt.md`, or
`.dev/ROADMAP.md`. Codifies the discipline that surfaced when
§9.9-g-13's predicted target ("16 cmp fails are `dst==lhs`
alias case, expect to clear them") proved wrong — the actual
16 fails were `i*x*.ne` family, an entirely separate recipe
bug. The chunk's preventive value was real; the framing was
not.

## The rule

Do **not** write numeric predictions in mutable docs.

- ❌ "Targets ~16 fails."
- ❌ "Expected to flip ~25 PASS."
- ❌ "Should reduce OrbStack from 79 to ~54."
- ❌ "After this chunk, simd_i*x*_cmp will be ~0."
- ✅ "Candidate: D-071 part (b) — `i8x16.popcnt` PSHUFB."
- ✅ "Latest landed: 67aa0025 (see commit body for delta)."

## Where each kind of fact lives

| Fact kind                                  | Source of truth                                                               | MUST NOT be duplicated in                       |
|--------------------------------------------|-------------------------------------------------------------------------------|-------------------------------------------------|
| Past chunk outcome (3-host gate, deltas)   | commit message body (`git show <sha>`)                                        | handover Current/Active state, debt narrative   |
| Current FAIL counts / breakdown            | `bash scripts/p<N>_*_status.sh` (live)                                        | handover, debt                                  |
| `now` debt rows                            | `.dev/debt.md` Status column                                                  | handover (point at, do not copy)                |
| ROADMAP §9.<N> chunk records (immutable)   | the row at chunk-close time (snapshot)                                        | handover (already a snapshot; not a prediction) |
| Hypothesis with TTL                        | `.dev/debt.md` row body, prefixed `Hypothesis (verified at <SHA-or-date>):`   | handover                                        |

## How to write `Next candidates` correctly

Names + Refs only. No numbers. No "should clear". No
"expects":

```markdown
## Next sub-chunk candidates (names only, NO predictions)

- D-071 (b) — i8x16.popcnt PSHUFB recipe
- D-071 (a) — i64x2.mul PMULUDQ recipe
- D-067 — bitmask validator-shape (lower + ARM64 emit)
```

If the urge to write a number is strong, the right place is:

- `.dev/debt.md` row body, with `Hypothesis (verified at
  <SHA-or-date>): ...`. The TTL marker tells future readers
  the number may be stale.
- The commit message of the chunk that **actually landed**
  the fix — now the number is a fact (3-host gate result),
  not a prediction.

## Session-start verification step

Per `/continue` skill Resume Step 0.5b: run
`bash scripts/p<N>_*_status.sh` before believing handover
narrative. If the script's live output disagrees with
handover, the script wins; update handover before
continuing.

## Reviewer checklist

- [ ] Does this handover edit contain a numeric prediction
      ("Targets ~N", "should clear M", "expects ~K PASS",
      "should reduce X to Y")? If yes, remove or move to
      commit body.
- [ ] Does the "Next candidates" section list anything
      beyond names + Refs?
- [ ] Does a debt row's narrative carry numbers without a
      `Hypothesis (verified at <SHA-or-date>):` prefix? If
      yes, prefix it OR remove the numbers.
- [ ] Does the chunk record include numbers that were
      measured at chunk-close-time? — OK, those are past
      facts and stay (immutable historical snapshot).

## What this rule does NOT cover

- ROADMAP `§9.<N>` chunk records like
  "9.9-g-12 (...): Mac 11263/4, OrbStack 79 fails" are
  **immutable historical snapshots** — they record what was
  true at the chunk's commit. Those numbers are facts and
  stay. They are not predictions about future chunks.
- commit message bodies same.
- bench/ directory historical results same (always
  measured-at-commit-time).

The trigger is **future-tense numeric claims about as-yet-
unwritten code**, not past-tense observations.

## Why this rule exists (case study)

§9.9-g-12 closed with a hypothesis: "the residual 16 cmp
fails after the IntCmpSigned alias fix are likely IntCmp
`dst == lhs` alias cases". This was reasonable speculation
based on the prior chunk's pattern. The handover wrote it
as "Targets ~16 fails" alongside the chunk's actual
measured deltas, with no marker distinguishing prediction
from fact.

§9.9-g-13's session (the autonomous /continue loop) read the
handover, organised the chunk around the prediction,
implemented an alias-safety fix, and discovered **only after
running test-spec-simd** that the 16 fails were `i*x*.ne`
family (PCMPEQ + PXOR-ones recipe) with no alias case
involved. The 9.9-g-13 fix was structurally correct
(prevents a real bug class) but did not move FAIL count.

The drift came from three reinforcing failure modes:

1. handover's Next-candidate list mixed predictions and
   facts in the same prose;
2. session-start procedure had no live-evidence check before
   the per-task TDD loop;
3. the same numeric breakdown was duplicated across
   handover + debt + commit body — only commit body is
   immutable, so the others drift.

This rule + `scripts/p<N>_*_status.sh` + the `/continue`
Step 0.5b live-status check are the structural fix.

## Stale-ness

If a future Phase produces a similarly observable failing-
fixture set (e.g. Phase 10 SIMD bench gap, Phase 14 thread
fixtures), drop a `scripts/p<N>_<topic>_status.sh` for that
phase before letting handover accumulate predictions about
it. The script existing is what makes the rule cheap to
follow.
