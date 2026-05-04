---
name: adr-revision-history-misuse
description: ADR Revision history rows have been used as cover ("ADR was always complete") rather than as honest gap-acknowledgement.
type: feedback
---

# ADR Revision history must record gaps, not cover them

`.dev/decisions/README.md` says:

> **Amend in place** is allowed for the same decision evolving
> with newer evidence... keep the original Alternatives section's
> rationale intact — don't rewrite history into "we always meant
> this".

In practice, recent ADR amendments (ADR-0017's X19 row,
ADR-0014's §6.K.5 split) read as "minor refinement" rather than
"we missed this at design time".

## Why this matters

- **Future ADR risk underestimated**: an ADR "looking like ADR-0017"
  gets approved on the assumption that ADR-0017 was thoroughly
  considered. The blind-spot doesn't surface.
- **Lessons get lost**: gap-discovery moments teach future ADR
  authors what to look for; "routine maintenance" framing kills
  the propagation.
- **Trust erodes**: a re-reader noticing the gap reads the
  framing as cover-up.

## Sharper Revision history rules (proposed)

Each row should answer: **what changed** (one phrase) +
**why-class** (one of: gap / refinement / expansion) +
**how surfaced** (ticket / debt / sub-row).

Example for ADR-0017's X19 row:

> X19 invariant added | gap: original ADR-0017 didn't model CFG
> join points; sub-7.5c-vi's D-027 surfaced the need; Alternatives
> § E added recording the rejected single-arm-IR option.

## How to apply

Amend `.dev/decisions/README.md` in a follow-up to make this
convention load-bearing. ADR-0017 itself should be amended to
re-frame its X19 row honestly.

**Citing**: ADR-0022 (regret #7) + ADR-0017 +
`.dev/decisions/README.md` + sibling lesson on the specific
ADR-0017 instance.
