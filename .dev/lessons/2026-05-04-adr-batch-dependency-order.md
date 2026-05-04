---
name: adr-batch-dependency-order
description: ADRs 0017-0020 were filed as a 4-ADR batch; the dependency order between them was implicit, making it unclear which ADR's implementation cycle should fire first.
type: feedback
---

# ADR batch authoring leaves dependency order implicit

ADRs 0017 / 0018 / 0019 / 0020 were drafted, self-reviewed, and
accepted as a 4-ADR batch on 2026-05-04. Each ADR's "Consequences"
section referenced the others in passing, but the **dependency
DAG between them was not explicit**. handover.md picked an order
(1: ADR-0018, 2: ADR-0017, 3: ADR-0020, then ADR-0019 carries
through) but the rationale lived only in conversation context.

## What broke

When sub-2 (ADR-0017 implementation) started, "can we land this
without ADR-0018 closed?" had no clear answer in the ADRs
themselves. ADR-0018 modifies regalloc reserved set (X24..X28).
ADR-0017 modifies prologue to LDR from `*X0` into X24..X28. If
ADR-0017 ships before ADR-0018, the LDRs target a pool of
registers still considered allocatable. Race risk. The 1→2
handover order was right, but the "right" was buried.

## What we should have done

For batched ADRs, add a `Dependencies` section to each:

```markdown
## Dependencies
- **Blocks**: NNNN
- **Blocked by**: NNNN
- **Sibling**: NNNN
```

Or, file a single **DAG ADR** when batching 3+ ADRs that listing
the order. The 4-ADR batch effectively reshapes Phase 7; a
meta-ADR would have made the lineage explicit.

## How to apply

Next batch (likely Phase 8 optimisation foundation, touching
hoist + coalesce + linear-scan in parallel) should file the DAG /
Dependencies section up front. Don't let the order live only in
handover.md.

**Citing**: ADR-0022 (regret #10) + ADRs 0017/0018/0019/0020 +
`.dev/decisions/README.md` (which should be amended to add the
Dependencies / DAG convention).
