# 0038 — §9.8b / 8b.2-d class-aware allocation deferral to Phase 15

- **Status**: Accepted
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8b / 8b.2-d autonomous /continue cycle
- **Tags**: roadmap, phase8, jit, regalloc, class-aware, scope, deferral

## Context

ADR-0037 Revision 2 (filed earlier this same resume cycle)
identified that `regalloc.compute`'s busy-mask scan already
implements slot reuse on dead vregs. The runtime-bench wins
that ADR-0037 originally anticipated for §9.8b / 8b.2 migrate
to **class-aware allocation per D-036 §option-b**: tighter
spill-frame accounting when GPR + FP vregs share slot id
space, mentioned in the current `regalloc.zig:131-133` as
"Tighter accounting lands when the allocator becomes
class-aware".

ADR-0037's amendment committed to filing this ADR before
8b.2-d implementation. This ADR is that filing.

The structural prerequisite for class-aware allocation is
**liveness type-tagging**: the `LiveRange` shape currently
carries only `def_pc` + `last_use_pc`, with class
interpretation deferred to emit time via `Allocation.slot
(vreg, class)`. To allocate **separately** per class, the
allocator needs per-vreg class input from liveness (which in
turn needs per-vreg type info from the validator's type
stack — multi-file change spanning `validate/` → `ir/zir.
zig` → `ir/analysis/liveness.zig` → `engine/codegen/shared/
regalloc.zig`).

## Decision

**Defer §9.8b / 8b.2-d (class-aware allocation) to Phase 15
alongside the coalescer detection lift.** Close §9.8b / 8b.2
at 8b.2-c (LIFO free-pool refactor, landed `c7b0ea5`). The
8b.2-d + 8b.2-e rows dissolve into 8b.2's closure.

The deferral mirrors ADR-0036's pattern (8b.1 coalescer
scope downgrade) and is justified by the **same structural
overlap**: Phase 15's coalescer detection lift will already
touch the slot-id-to-class mapping (per ADR-0036 §"Phase 15
prep"). Liveness type-tagging is a Phase 15 prerequisite for
the coalescer detection logic; running it twice — once for
8b.2-d's allocator-side use, then again for Phase 15's
coalescer-side use — produces duplicate ABI changes that
the ADR-0035 + ADR-0036 stability discipline expressly
seeks to avoid.

### Concrete revised exit criterion (8b.2)

§9.8b / 8b.2 marks `[x]` when:

- ADR-0037 (design) + ADR-0037 Revision 2 (discovery
  reframe) + ADR-0038 (this ADR; class-aware deferral)
  all `Status: Accepted`.
- 8b.2-a (survey) + 8b.2-b (ADR-0037) + 8b.2-c (LIFO
  refactor) all `[x]`.
- Mac local + 3-host gate green at the 8b.2-c commit.

The bench-delta requirement migrates to 8b.4's ≥10%
aggregate exit, absorbed alongside ADR-0036's 8b.1 scope
downgrade. 8b.4's burden therefore concentrates on:

- **8b.3 (AOT skeleton)**: cold-start time delta — the
  load-bearing source of bench wins for §9.8b.
- **8a.5 hoist cap-removal**: already landed at `2e0022c`;
  any incidental fixture wins flow into 8b.4's aggregate
  measurement.

If 8b.4 measurement shows < 10% aggregate after 8b.3 lands,
revisit class-aware allocation as a Phase-8b extension via
amendment to this ADR (rather than re-opening 8b.2-d).

### What this ADR does NOT do

- **Does not retract ADR-0037**: ADR-0037's design framing
  + 8b.2-c LIFO refactor remain load-bearing.
- **Does not change ROADMAP §9.8b's exit gate**: 8b.4
  ≥10% aggregate stands; only the per-row contribution
  mix changes.
- **Does not waive class-aware allocation as future work**:
  Phase 15 lifts both the coalescer detection layer + the
  liveness type-tagging + dual-pool allocator together, in
  one structural change. Estimated 1-2 weeks of focused
  work when prior scaffolding (8b.1 coalescer +
  8b.2-c free-pool) is consumed.

## Alternatives considered

### Alternative A — Implement class-aware allocation in 8b.2-d now

- **Sketch**: extend `LiveRange` with `class: RegClass`,
  thread type info from validator → liveness, dual-pool
  allocator, per-class `n_slots_gpr` / `n_slots_fp` in
  `Allocation`, corrected `spillBytes()`.
- **Why deferred**:
  1. Multi-file structural change (validator → zir.zig →
     liveness.zig → regalloc.zig → emit consumers) at
     ~150-300 LOC across 4-5 files. Exceeds the chunk-
     bundle threshold.
  2. The Phase 15 coalescer detection lift (per ADR-0036)
     will re-touch `LiveRange` for the operand-stack vreg-
     numbering simulation — running the type-tagging change
     in 8b.2-d means Phase 15 either inherits the 8b.2-d
     ABI (good) or revises it (bad, defeats stability).
  3. Bench wins are ~3-5% on FP-heavy fixtures only;
     8b.4's ≥10% aggregate is more reliably carried by 8b.3
     (AOT cold-start delta).
  4. ADR-0036's same-structural-overlap argument applies
     symmetrically: defer the related work together.

### Alternative B — Implement only the spill-bytes accounting (no full dual-pool)

- **Sketch**: track `n_slots_gpr` / `n_slots_fp` separately
  in the allocator's running counters; correct
  `spillBytes()` formula. Skip the dual-pool slot-id
  bifurcation.
- **Why deferred**: even this slimmer version requires
  per-vreg class input (the allocator needs to know which
  counter to increment). The structural prerequisite
  (liveness type-tagging) is the same; the implementation
  surface is only marginally smaller.

### Alternative C — Cancel 8b.2-d entirely; remove from §9.8b

- **Sketch**: no follow-on row; class-aware lifts straight
  to Phase 15 alongside coalescer detection.
- **Why rejected**: the same 引数 as ADR-0036 §B
  ("Cancel 8b.1 entirely; remove the row") — ADR-0037
  + ADR-0038 are the persistent research artefacts that
  inform Phase 15's design, deleting them loses the
  re-derivation cost. Mid-phase row deletions complicate
  §9 history.

## Consequences

### Positive

- **§9.8b velocity restored**: 8b.2 closes; loop pivots to
  8b.3 (AOT skeleton) — structurally bigger work area
  with concrete cold-start delta to measure.
- **No work lost**: ADR-0037 + 8b.2-c LIFO refactor remain
  in place. Phase 15 picks up where 8b.2-c left off.
- **Phase 15 design coherence**: liveness type-tagging
  + coalescer detection + dual-pool allocator all land
  together as one structural change rather than three
  separate ABI churns.

### Negative

- **8b.2's individual bench delta = 0%**: same
  acknowledgement as ADR-0036 §"Negative". 8b.4 absorbs.
- **8b.4's ≥10% aggregate concentrates on 8b.3**: AOT
  cold-start delta becomes the load-bearing measurement
  for §9.8b's exit criterion. If 8b.3 underperforms, 8b.4
  needs an amendment OR a follow-on Phase-8b row.
- **Phase 15 carries another deferral**: alongside the 8b.1
  coalescer detection deferral (ADR-0036), Phase 15 now
  also carries class-aware allocation. Phase 15's planning
  needs to surface both as load-bearing prerequisites in
  one ADR.

### Neutral / follow-ups

- **Phase 15 prep**: when Phase 15 begins, the design input
  is: ADR-0035 (post-regalloc slot-aliasing coalescer) +
  ADR-0036 (8b.1 scope downgrade) + ADR-0037 (8b.2 free-
  pool refactor) + ADR-0038 (this ADR; class-aware
  deferral) + 8b.1 scaffolding (`src/ir/coalesce/pass.zig`)
  + 8b.2-c LIFO substrate. The op catalogue grows
  per-realworld-win.
- **bench-delta table compliance**: 8b.2-c commit body
  carried "0% by construction" rationale per ADR-0032
  precedent. This ADR's commit reframes 8b.2-d as
  "deferred; no commit-body bench table".
- **8b.4 risk mitigation**: if 8b.3 alone can't carry the
  ≥10% aggregate, the next step is an ADR-0039 amendment
  to either (a) re-open class-aware in Phase 8b, or (b)
  revise §9.8b's ≥10% target downward (load-bearing
  ROADMAP edit per §18.2).

## References

- ROADMAP §9.8b / 8b.2 (regalloc upgrade row), §9.8b / 8b.4
  (≥10% aggregate exit), §18 (amendment policy)
- ADR-0027 (callee-saved pool reduction; original busy-mask
  context)
- ADR-0035 (post-regalloc slot-aliasing coalescer; ABI
  consumer)
- ADR-0036 (8b.1 scope downgrade; this ADR's structural
  precedent)
- ADR-0037 (regalloc upgrade design + Revision 2 discovery)
- D-036 §option-b (class-aware allocation source — current
  `regalloc.zig:131-133` quote)
- 8b.2-a survey: `private/notes/p8-8b2-regalloc-survey.md`
  (gitignored)
- 8b.2-c LIFO refactor: `c7b0ea5`
- Lesson `2026-05-09-greedy-local-already-does-reuse.md`

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `e85d60a9` | Initial accepted version (§9.8b / 8b.2-d class-aware deferral to Phase 15; mirrors ADR-0036 pattern) |
