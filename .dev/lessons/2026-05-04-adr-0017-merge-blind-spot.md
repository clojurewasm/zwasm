---
name: adr-0017-merge-blind-spot
description: ADR-0017 design did not anticipate `(if (result T))` join semantics; X19 amendment hid the original incompleteness rather than acknowledging it.
type: feedback
---

# ADR-0017 had a merge-point blind spot at design time

ADR-0017 (JitRuntime ABI; X0 = `*const JitRuntime`; prologue
LDRs invariants) was drafted, self-reviewed, and accepted on
2026-05-04 as a single-unit design. **It did not consider how
`(if (result T))` joins arm-result registers at the merge
point.** Sub-7.5c-vi surfaced the gap as the D-027 bug: `if`
returned junk for the cond=1 path because emit pushed both
arms' result vregs but only the post-branch top survived.

## The hidden mechanism

The ADR-0017 design assumed each ZIR op's result is a single
vreg whose physical register is determined by the regalloc.
This is true at op-emission time, but at **CFG join points**
(`else` arm-end, `end` block-end), two vregs from different
control-flow paths converge to one logical result. Without a
merge-aware label stack, the `else` arm's result-vreg's
physical register is independent of the `then` arm's
result-vreg's physical register; whichever is "top" after
the join is what propagates.

## What was wrong with the X19 amendment

When the bug surfaced, ADR-0017 was amended in place to add a
`Revision history` row about "X19 amendment" — but the prose
treated the amendment as a refinement, not a correction of an
incomplete original design. The Alternatives section was not
updated to record the "we considered single-arm IR" alternative.
The result: a future reader of ADR-0017 sees "X19 was always
considered" rather than "X19 was a gap discovered in
sub-7.5c-vi".

The correct amend (per `.dev/decisions/README.md` rules):

> Amend in place is allowed for the same decision evolving
> with newer evidence. Add a Revision history row and **keep
> the original Alternatives section's rationale intact — don't
> rewrite history into 'we always meant this'.**

A new Alternatives entry should have been added: "Alternative E
— ignore CFG join points (REJECTED 2026-05-04 sub-7.5c-vi
after D-027 surfaced; merge-aware label stack required)".

## How to apply

Future ADR amendments must include:

1. Revision history row with the amend rationale.
2. New Alternatives subsection if the amend rejects an
   alternative that wasn't previously listed.
3. Honest framing: "we discovered" / "we found" not "we
   refined" when the change is corrective.

This rule is also added to `adr-revision-history-misuse.md`
lesson (regret #7).

## Citing

- ADR-0022 (post-session retrospective; lists this as regret #3)
- ADR-0017 (the artefact this lesson critiques; should be
  amended in a follow-up to reflect the honest framing)
- D-027 (debt entry, discharged via merge-aware label stack)
