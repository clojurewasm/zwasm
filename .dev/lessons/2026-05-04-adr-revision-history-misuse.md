---
name: adr-revision-history-misuse
description: ADR Revision history rows have been used as cover ("ADR was always complete") rather than as honest gap-acknowledgement; the amend pattern needs sharper framing rules.
type: feedback
---

# ADR Revision history must record gaps, not cover them

`.dev/decisions/README.md` documents amendment as:

> **Amend in place** is allowed for the same decision evolving
> with newer evidence. Add a Revision history row and keep the
> original Alternatives section's rationale intact — don't
> rewrite history into "we always meant this".

In practice, recent ADR amendments (ADR-0017's X19 row,
ADR-0014's §6.K.5 split) have been written as if the original
ADR was always complete, with the Revision history row reading
like "minor refinement" rather than "we missed this at design
time".

## Why this matters

Three failure modes:

1. **Future readers underestimate ADR risk**: a future ADR that
   "looks like ADR-0017's shape" gets approved on the assumption
   that ADR-0017 was thoroughly considered. The blind-spot
   isn't surfaced.
2. **Lessons get lost**: the gap-discovery moment teaches
   future ADR authors what to look for. If the Revision history
   reads like routine maintenance, the teaching doesn't propagate.
3. **Trust erodes silently**: external readers (or the user)
   may eventually re-read older ADRs and notice the gap; the
   "always complete" framing then reads as cover-up.

## Sharper Revision history rules (proposed)

Each Revision history row should answer:

- **What changed**: one phrase (e.g. "X19 amendment")
- **Why** (one of):
  - **gap**: the original ADR didn't consider this case
    (acknowledge openly)
  - **refinement**: the original ADR considered it; new
    evidence sharpens the choice
  - **expansion**: the original ADR's scope grew (e.g. an
    Alternative now needs to be revisited)
- **How surfaced**: ticket / debt entry / sub-row that exposed
  the need

Example for ADR-0017's X19 row:

> | 2026-05-04 | `<sha>` | X19 invariant added | gap: original
> ADR-0017 didn't model CFG join points; sub-7.5c-vi's D-027
> surfaced the need; Alternatives § E added to record the
> rejected single-arm-IR option |

## How to apply

`.dev/decisions/README.md` should be amended in a follow-up to
include this convention. ADR-0017 itself should be amended to
re-frame its X19 row honestly (separate cycle).

## Citing

- ADR-0022 (post-session retrospective; lists this as regret #7)
- ADR-0017 (instance of the misuse pattern)
- `.dev/decisions/README.md` (the amend-in-place rules; needs
  a sharpening update in a future session)
- `.dev/lessons/2026-05-04-adr-0017-merge-blind-spot.md` (the
  specific instance this lesson generalises from)
