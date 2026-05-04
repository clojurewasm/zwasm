---
name: adr-0017-merge-blind-spot
description: ADR-0017 design did not anticipate `(if (result T))` join semantics; X19 amendment hid the original incompleteness.
type: feedback
---

# ADR-0017 had a merge-point blind spot at design time

ADR-0017 (JitRuntime ABI; X0 = `*const JitRuntime`; prologue LDRs
invariants) was drafted, self-reviewed, and accepted on
2026-05-04. **It did not consider how `(if (result T))` joins
arm-result registers at the merge point.** Sub-7.5c-vi surfaced
the gap as D-027: `if` returned junk for the cond=1 path because
emit pushed both arms' result vregs but only the post-branch top
survived.

## The hidden mechanism

ADR-0017 assumed each ZIR op's result is a single vreg whose
physical register comes from regalloc. True at op-emission time;
**at CFG join points** (`else` arm-end, `end` block-end) two vregs
from different control-flow paths converge to one logical result.
Without merge-aware label stack, each arm's result-vreg's physical
register is independent; whichever is "top" after the join wins.

## What was wrong with the X19 amendment

When the bug surfaced, ADR-0017 was amended in place with a
`Revision history` row about "X19 amendment" — but the prose
treated the amendment as a refinement, not a correction of an
incomplete design. The Alternatives section was not updated. A
future reader sees "X19 was always considered" rather than "X19
was a gap discovered in sub-7.5c-vi".

The correct framing per `.dev/decisions/README.md`:

> Amend in place is allowed for the same decision evolving with
> newer evidence... **keep the original Alternatives section's
> rationale intact — don't rewrite history into "we always meant
> this"**.

A new Alternatives entry should have been added recording the
rejected single-arm-IR path.

**Citing**: ADR-0022 (regret #3) + ADR-0017 + D-027 +
`.dev/lessons/2026-05-04-adr-revision-history-misuse.md`.
