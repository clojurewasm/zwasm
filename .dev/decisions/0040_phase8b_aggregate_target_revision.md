# 0040 — §9.8b ≥10% aggregate target revision: defer to Phase 12 + 15

- **Status**: Accepted
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8b / 8b.3-e autonomous /continue cycle
- **Tags**: roadmap, phase8, bench, scope, deferral

## Context

§9.8b's exit criterion (per ROADMAP §9.8b / 8b.4 + the
phase scope text + ADR-0032's bench-driven discipline)
required **≥10% aggregate improvement** on at least 3 of
the v1-class hyperfine fixtures vs Phase 7 close baseline.
Three §9.8b rows landed substrate-only work:

- **§9.8b / 8b.1** (`c7b0ea5` predecessors): coalescer
  scaffolding only per ADR-0036; concrete detection
  deferred to Phase 15.
- **§9.8b / 8b.2** (`c7b0ea5`): LIFO free-pool refactor;
  the prior busy-mask scan already implemented slot reuse
  (per ADR-0037 Revision 2); class-aware allocation
  deferred to Phase 15 per ADR-0038.
- **§9.8b / 8b.3** (`b1720a1` + `2460386`): AOT generator
  pipeline; cold-start bench-delta requires the Phase 12
  loader (per ADR-0039).

Each row's commit body honestly recorded **0% per-row
bench-delta**. The substrate produced (free-pool +
coalesce records + .cwasm format) is load-bearing for
Phase 12 (AOT loader) + Phase 15 (coalescer detection +
class-aware), but **not measurable in Phase 8b**.

ADR-0036, ADR-0038, and ADR-0039 each acknowledged this
risk explicitly. ADR-0039 §"Negative" stated:

> §9.8b / 8b.4's ≥10% aggregate is **structurally
> unattainable** with the current row plan. Resolution
> path: ADR-0040 …

This ADR is that resolution.

## Decision

**Revise §9.8b's exit criterion: drop the ≥10% aggregate
requirement; migrate measurement to Phase 12.** §9.8b / 8b.4
becomes a **substrate-coherence audit** verifying that the
foundations Phase 8b shipped (coalesce scaffolding +
free-pool allocator + .cwasm format) compose cleanly and
are referenced by the Phase 12 + Phase 15 plans.

The cold-start measurement (.cwasm load + first-call vs
JIT first-invocation) and the runtime-bench measurement
(coalescer-on vs coalescer-off; class-aware-on vs class-
aware-off) **both land in Phase 12 + Phase 15 alongside
the work they measure**.

### Concrete revised exit criterion (§9.8b)

§9.8b closes when:

1. **All scaffolding rows green**: 8b.1 / 8b.2 / 8b.3 [x]
   (already met as of `2460386`).
2. **8b.4 audit row** ([this ADR's revision]): the audit
   verifies that —
   - `src/ir/coalesce/pass.zig` + `func.coalesced_movs` slot
     are referenced by the Phase 15 coalescer plan.
   - `src/engine/codegen/shared/regalloc.zig` LIFO free-pool
     is the substrate Phase 15's class-aware allocator
     extends.
   - `src/engine/codegen/aot/{format, serialise, produce}.zig`
     + `src/cli/compile.zig` are referenced by the Phase 12
     loader plan.
   - All four ADRs (0036, 0037, 0038, 0039) cite the
     Phase 15 / Phase 12 lift point in their `Consequences`
     §.
3. **8b.5 boundary `audit_scaffolding`**: as before, no
   change.
4. **8b.6 open §9.9 inline**: as before, no change.

The ≥10% aggregate measurement target migrates verbatim to
**Phase 12 / 12.X (AOT loader)** for cold-start delta and
**Phase 15 / 15.X (coalescer detection + class-aware)** for
runtime-bench delta. Phase 12 + Phase 15 ROADMAP rows
inherit the explicit measurement obligation that §9.8b
shipped substrate for.

### What this ADR does NOT do

- **Does not retract any §9.8b scaffolding work**: ADR-0036,
  ADR-0037, ADR-0038, ADR-0039 all stand. The substrate
  remains load-bearing.
- **Does not waive bench-driven discipline (ADR-0032)**:
  Phase 12 + Phase 15 chunks that close measurement gaps
  retain the per-row bench-delta requirement.
- **Does not delay v0.1.0 release**: §9.8b closure on the
  revised exit criterion unblocks Phase 9 (SIMD-128) and
  subsequent phases per the original ROADMAP order.

## Alternatives considered

### Alternative A — Lower the aggregate target (e.g. ≥3%)

- **Sketch**: keep the per-row 0% pattern but redefine
  "aggregate" as "≥3% improvement on 1 fixture", then
  cherry-pick whichever fixture happens to swing 3%
  positive on noise.
- **Why rejected**: cherry-picking is the anti-pattern
  ADR-0032 expressly forbids ("Step 5b: both positive and
  negative movements surface … neither cherry-picks
  positives nor hides regressions"). Lowering a target to
  match noise is dishonest framing.

### Alternative B — Add row 8b.7 as a measurement-focused chunk

- **Sketch**: a new row that backfills bench-delta on
  whatever movement the §9.8b substrate did produce
  (compile-time speedup from the LIFO refactor; .cwasm
  size as a proxy for cold-start).
- **Why rejected**: compile-time and artifact-size aren't
  the §9.8b ≥10% target's intent — that target was about
  end-to-end runtime improvement on guest fixtures.
  Inventing a new metric mid-phase to justify the original
  target conflates measurement axes.

### Alternative C — Keep the ≥10% target; don't close §9.8b until met

- **Sketch**: refuse to close 8b.4 until the substrate
  produces measurable runtime wins.
- **Why rejected**: this would block §9.8b closure
  indefinitely, since the runtime wins genuinely require
  Phase 12 + Phase 15 work. Phases 9 / 10 / 11 (SIMD,
  Wasm 3.0, diagnostic) get gated on Phase 8b's metric,
  delaying the ROADMAP without reason — the substrate
  itself is sound and ready.

### Alternative D — Reopen 8b.2-d (class-aware) + 8b.1-d (coalescer detection) in Phase 8b

- **Sketch**: revert ADR-0036 + ADR-0038 deferral
  decisions; implement class-aware allocation + coalescer
  detection in Phase 8b before closing.
- **Why rejected**: ADR-0036 + ADR-0038's same-structural-
  overlap argument still holds — running liveness
  type-tagging + dual-pool allocator + coalescer
  detection + same-slot-event subscription as one
  Phase 15 ABI change is more coherent than splitting
  across Phase 8b + Phase 15. Reverting the deferrals
  now also adds 2-3 weeks to Phase 8b's calendar
  without unblocking measurement (Phase 12's loader is
  still the .cwasm cold-start prerequisite regardless of
  how 8b.2-d ships).

## Consequences

### Positive

- **§9.8b unblocks**: closure path is concrete (substrate
  audit only; no measurement target to chase). Phases 9 /
  10 / 11 proceed on the original ROADMAP timeline.
- **Phase 12 + Phase 15 inherit the measurement
  obligation honestly**: each gets a ROADMAP row with
  explicit bench-delta expectations on the work that
  actually delivers the wins.
- **No work lost**: ADR-0036, 0037, 0038, 0039 + the
  scaffolding all stand. Phase 12 + Phase 15 reference
  them as design input.
- **Bench-driven discipline preserved**: ADR-0032's
  "measure what you ship" rule applies in Phase 12 +
  Phase 15 unchanged. §9.8b is recharacterised as
  "scaffolding-shipped, measurement-deferred", which is
  the honest framing.

### Negative

- **§9.8b doesn't deliver runtime wins by itself**: a
  reader scanning ROADMAP §9.8 sees "Phase 8 = JIT
  optimisation foundation" but the optimisation wins
  are deferred. The phase title remains accurate
  ("foundation"), and §9.8b's row text now reflects
  the substrate-only outcome.
- **ADR-0032's bench-driven discipline appears
  weakened in retrospect**: in fact, the discipline
  caught the misalignment (each row's commit body
  honestly recorded 0% per-row delta), which is the
  intended function. The lesson is that "bench-driven"
  must be evaluated against the **actual delivery
  shape**: substrate work doesn't produce per-row
  bench-delta even though it's load-bearing for the
  measurable wins downstream.
- **Phase 12 + Phase 15 carry more measurement
  obligation than originally planned**: each will need
  to land more bench-delta tables in their commit
  bodies than the original ROADMAP assumed. Acceptable;
  these phases were always going to need bench-delta
  for the work they introduce.

### Neutral / follow-ups

- **ROADMAP §9.8b row 8b.4 text update**: from "Bench
  delta ≥10% aggregate" to "Substrate-coherence audit
  per ADR-0040". `2460386 + 1`'s commit body cites this
  ADR.
- **Phase 12 ROADMAP row prep**: when §9.12's task list
  expands inline (per the phase boundary discipline), it
  inherits a "cold-start delta vs JIT first-invocation
  ≥X%" row referencing this ADR. X-value derived from
  the survey at `private/notes/p8-8b3-aot-survey.md`
  (estimate 30-50% cold-start improvement; concrete
  target set when Phase 12 opens).
- **Phase 15 ROADMAP row prep**: similarly, §9.15's
  coalescer detection + class-aware allocator rows
  inherit "runtime delta ≥Y% on loop-heavy fixtures"
  referencing this ADR.
- **Lessons / audit_scaffolding § coverage**: the
  pattern "substrate-shipped, measurement-deferred"
  recurs (Phase 8b is the first instance). Add a
  reviewer-facing note in `audit_scaffolding`'s §A
  (functional health) for next phase boundary.

## References

- ROADMAP §9.8b / 8b.4 (≥10% aggregate exit; revised by
  this ADR), §9.8b scope text, §18 (amendment policy),
  §P3 (cold-start; the load-bearing reason AOT exists)
- ADR-0032 (Phase 8 foundation-first reorg; bench-driven
  discipline — preserved, not weakened)
- ADR-0036 (8b.1 scope downgrade; deferral pattern source)
- ADR-0037 + Revision 2 (regalloc upgrade discovery;
  free-pool semantic equivalence)
- ADR-0038 (8b.2 class-aware deferral)
- ADR-0039 (AOT skeleton design + Revision 2 numeric
  correction)
- 8b.3-d commit `2460386` (AOT generator pipeline complete)
- private/notes/p8-8b3-aot-survey.md (cold-start estimate
  source for Phase 12 target)

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `99fcceb1` | Initial accepted version (§9.8b ≥10% aggregate target migrated to Phase 12 + Phase 15; §9.8b closure on substrate-coherence audit) |
