---
name: adr-batch-dependency-order
description: ADRs 0017-0020 were filed as a 4-ADR batch; the dependency order between them was implicit, making it unclear which ADR's implementation cycle should fire first.
type: feedback
---

# ADR batch authoring leaves dependency order implicit

ADRs 0017 / 0018 / 0019 / 0020 were drafted, self-reviewed, and
accepted as a 4-ADR batch on 2026-05-04. Each ADR's
"Consequences" section referenced the others in passing, but
the **dependency DAG between them was not explicit**. The
handover.md plan picked an order (1: ADR-0018, 2: ADR-0017,
3: ADR-0020, then later ADR-0019 carries through) but the
ordering rationale wasn't load-bearing in any single ADR.

## What broke

When sub-2 (ADR-0017 implementation) started, the question
"can we land this without ADR-0018 closed?" had no clear
answer in the ADRs themselves. The handover stated the order
but the **why** lived only in conversation context.
Specifically:

- ADR-0018 modifies regalloc reserved set (X24..X28).
- ADR-0017 modifies prologue to LDR from `*X0` into X24..X28.
- If ADR-0017 ships before ADR-0018, the LDRs target a pool of
  registers that's still considered allocatable. Race risk.

The 1→2 handover order was right, but the "right" was buried.

## What we should have done

For batched ADRs, add a `Dependencies` section to each:

```markdown
## Dependencies

- **Blocks**: NNNN (which ADRs cannot ship before this one)
- **Blocked by**: NNNN (which ADRs must ship first)
- **Sibling**: NNNN (independent; can run in parallel)
```

Or, file a single **DAG ADR** when batching 3+ ADRs:

```
.dev/decisions/0017_jit_runtime_abi.md       (sub)
.dev/decisions/0018_regalloc_reserved.md     (sub)
.dev/decisions/0019_x86_64_in_phase7.md      (sub)
.dev/decisions/0020_edge_case_test_culture.md (sub)
.dev/decisions/0021_phase7_redesign_dag.md   (DAG; lists order)
```

The 4-ADR batch effectively reshapes Phase 7; a meta-ADR would
have made the reshape's lineage explicit.

## How to apply

When the next batch fires (likely Phase 8 optimisation
foundation, which will touch hoist + coalesce + linear-scan in
parallel), file the DAG / dependency section up front. Don't
let the order live only in handover.md.

## Citing

- ADR-0022 (post-session retrospective; lists this as regret #10)
- ADRs 0017 / 0018 / 0019 / 0020 (the batch this lesson
  generalises from)
- `.dev/decisions/README.md` (which should be amended in a
  follow-up to add the Dependencies / DAG convention)
