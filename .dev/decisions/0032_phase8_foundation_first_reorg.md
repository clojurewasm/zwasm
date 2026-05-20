# 0032 — Phase 8 reorg: foundation-first, bench-driven optimisation

- **Status**: Accepted
- **Date**: 2026-05-08
- **Author**: User (collaborative reframing) + autonomous /continue cycle
- **Tags**: roadmap, phase8, reorg, bench, observability, jit, meta-process

## Context

Phase 8's original §9.8 task list (per ADR-0019) was:

```
8.0–8.3  Phase 7 carry-overs (WASI for JIT, emit_test split, windowsmini bench)
8.4      Hoist pass
8.5      Coalescer pass
8.6      Regalloc upgrade
8.7      AOT skeleton
8.8      Bench delta ≥10% on 3+ fixtures
8.9      Phase 8 boundary audit
8.10     Open §9.9
```

8.0–8.3 closed cleanly across the early /continue cycles. 8.4
(Hoist) attempted twice and reverted both times:

- Cycle 1 (8.4-c, `dba7cbb`): naive instr-move broke ZIR vreg
  numbering at liveness time. Lesson
  `2026-05-08-hoist-vreg-semantic.md` recorded the gotcha;
  D-053 carried the redesign forward.
- Cycle 2 (8.4-d, `8180c66`): local-set/local-get rewrite
  redesign landed as code (helpers + slot + 4 unit tests +
  emit consumer migration), but pipeline integration regressed
  realworld_run_jit 52/55+15 → 42/55+8 — UnsupportedOp from a
  silent return path in arm64 emit op handlers. The redesign
  was partial-landed at `4d6fc0b` behind a per-function
  `max_hoists_per_func = 4` cap that insulates the integration
  from the regression source.

Two collaborative observations from the user (this cycle)
drove the reframe:

1. **JIT observability gap**: "I never know whether the JIT
   actually ran" surfaced repeatedly in v1 too. Per-pass DBG
   prints scattered across cycles is a symptom, not a fix —
   the project needs **centralised pass-trace + JIT-execution
   sentinel infrastructure** before optimisation work can be
   confidently measured.
2. **Bench-driven discipline absent**: the autonomous loop
   verified "baseline maintained" but never measured "did this
   optimisation actually speed anything up?" The §9.8 / 8.8
   row codifies the bench-delta ≥10% target at Phase exit,
   but per-task bench measurement is not in the /continue skill
   nor in CLAUDE.md's Mandatory checks. "Just adding
   optimisations without measuring them is meaningless."

The 8.4 cycle-1+2 work IS preserved — code + ADR-0031 +
lesson + commit history all remain — but moving forward without
infrastructure to measure each optimisation's effect risks
landing more "implemented but unmeasured" optimisations across
8.5 / 8.6 / 8.7.

## Decision

**Reorganise §9.8 into two consecutive sub-phases**:

- **§9.8a — Optimisation foundation (infrastructure-first)**.
  Land the observability + bench-discipline tooling that makes
  optimisation work measurable. NO new optimisation correctness
  work happens during 8a — the only Hoist-related row in 8a is
  `8a.5` which is the **D-053 root-cause investigation** using
  the new infra (cap=4 removal becomes a measured-improvement
  question, not an unrelated debug exercise).

- **§9.8b — Bench-driven optimisation**. Coalescer / Regalloc
  upgrade / AOT skeleton (the previous 8.5 / 8.6 / 8.7) move
  here, each requiring a per-task bench-delta entry per the
  new discipline added to the /continue skill.

The renumbered §9.8 task table:

| New | Old | Description |
|-----|-----|---|
| 8.0  | 8.0 | Open §9.8 (already [x]). |
| 8.1  | 8.1 | WASI for JIT (already [x]). |
| 8.2  | 8.2 | emit_test split (already [x]). |
| 8.3  | 8.3 | windowsmini bench subset (already [x]). |
| 8.4  | 8.4 (partial) | **Hoist MVP behind cap=4** (`4d6fc0b`); marked `[x]` as historical record of the partial land. The cap-removal investigation moves to 8a.5. |
| **8a.1** | (new) | **Per-pass diagnostic ringbuffer extension** — ADR-0028's Diagnostic ring buffer extended with `passEvent(pass_name, summary)` entries; each pipeline stage (lower / hoist / liveness / regalloc / emit) emits enter + exit events with structured summaries. |
| **8a.2** | (new) | **JIT-execution sentinel** — JIT block prologue gets a small inject (counter increment / sentinel store) so post-execution checks can prove the JIT-emitted body actually ran (vs. compile-passed but never invoked). Resolves the v1-era "is the JIT actually running" confusion. |
| **8a.3** | (new) | **Bench-delta-per-commit infra** — `scripts/run_bench.sh --diff <ref>` produces a before/after table; `scripts/record_bench_delta.sh` formats it for commit-message inclusion. Used by the new /continue skill bench discipline. |
| **8a.4** | (new) | **`ZWASM_DIAG=passes,jit_exec,bench` env var** — opt-in surfacing of the 8a.1/8a.2/8a.3 outputs without recompile. Same release-mode binary as production. |
| **8a.5** | (D-053 promotion) | **Hoist cap-removal root-cause investigation** — using 8a.1 + 8a.2, identify the silent-UnsupportedOp source for high-hoist functions; either fix the affected emit path or refine the cap with a precise filter. Discharges D-053. |
| **8a.6** | 8.9 (renumbered) | Phase-8a boundary `audit_scaffolding` pass. |
| **8b.1** | 8.5 | **Coalescer pass** — now bench-delta-required. |
| **8b.2** | 8.6 | **Regalloc upgrade** — now bench-delta-required. |
| **8b.3** | 8.7 | **AOT skeleton** — bench-delta-required where it overlaps JIT pipeline (loadable .cwasm runs vs. JIT cold-start). |
| **8b.4** | 8.8 | **Bench delta ≥10%** — Phase 8 exit; aggregates 8b.1-8b.3 effects. |
| **8b.5** | (renumbered) | Phase-8b boundary `audit_scaffolding` pass. |
| **8b.6** | 8.10 | Open §9.9 inline + flip phase tracker. |

**The 8.4 row stays `[x]` in the new layout** — it records
the partial-landed Hoist MVP behind cap=4 as a historical
artifact. The full Hoist (cap-removed + bench-measured) is
**not** a separate ROADMAP row — it's the discharge condition
for 8a.5.

## /continue skill amendment (separate but companion)

The Step 5 (Test gate) of the per-task TDD loop gains a
**bench-delta sub-step** that fires when ALL hold:

- Active task is in Phase 8 §9.8b (or any future Phase
  explicitly tagged "bench-driven").
- The diff modifies `src/ir/`, `src/engine/codegen/`, or any
  file the optimisation passes touch.
- The 8a infrastructure rows (8a.1 + 8a.2 + 8a.3) are all
  `[x]`.

In that path, the loop runs `scripts/run_bench.sh --quick
--diff HEAD~1` after the test gate, and the commit message
MUST include the bench-delta table (positive AND negative
movements both surface; the loop neither cherry-picks
positives nor hides regressions). A regression on any
recorded fixture without a paired explanation in the commit
body is a Step-7 forbid.

Outside Phase 8b (and during 8a foundation work), bench-delta
is **not** required — those tasks are not optimisations and
forcing per-commit bench delta would be noise.

## Alternatives considered

### Alternative A — Continue with current §9.8 ordering

- **Sketch**: Push through 8.4 (uncap hoist + root-cause
  investigation) without infra, then 8.5 / 8.6 / 8.7 each
  measured ad-hoc.
- **Why rejected**: The 8.4 cycle's debugging time was already
  large because of missing infra (per-pass instrumentation
  rebuilt from scratch each round). 8.5 / 8.6 / 8.7 would
  each pay the same infra-bootstrap cost. Foundation-first
  amortises.

### Alternative B — Inline bench discipline without reordering

- **Sketch**: Add bench-delta to the /continue skill and apply
  it to the existing 8.5 / 8.6 / 8.7 rows in their current
  order.
- **Why rejected**: Without 8a.1 / 8a.2 / 8a.3 infra, the
  bench discipline is mostly procedural ceremony — the loop
  has nothing to compare against beyond aggregate runtime
  numbers, which don't isolate per-pass contribution. The
  reorg makes the discipline actionable.

### Alternative C — Drop the 8.4 partial land, restart the Hoist work

- **Sketch**: Revert `4d6fc0b`, treat 8.4 as deferred until
  8a infra is ready.
- **Why rejected**: The partial land IS productive (small
  functions get hoisted; baseline maintained; many APPLY events
  observed). Reverting throws away verified-correct work for
  no benefit. The cap=4 marker is honest about its scope; the
  D-053 row tracks the cap-removal as 8a.5.

### Alternative D — Pure-additive: leave §9.8 as-is, add a 8a sub-section

- **Sketch**: Don't renumber; just insert 8a/8b rows alongside.
- **Why rejected**: The existing 8.4-8.10 rows need to be
  re-targeted (8.5/8.6/8.7/8.8 become bench-driven; 8.9 is the
  8b boundary audit, not 8 boundary). Renumbering forces the
  reader to see the new shape immediately; pure-additive
  layering invites drift.

## Consequences

### Positive

- **Optimisation work becomes measurable**. 8a.3's bench-delta-
  per-commit infra makes "did this pass help?" a check-in
  question, not a Phase-8.8 retrospective.
- **JIT observability infra lands once**. v1's recurring
  "did the JIT actually run?" confusion is structurally
  resolved by 8a.2's sentinel + 8a.1's pass trace.
- **D-053 root-cause work has structural support**. 8a.5's
  cap-removal investigation reads pass-trace events + sentinel
  counters from 8a.1 + 8a.2, not ad-hoc DBG prints.
- **Phase 8 retains its scope** — the original optimisation
  goals (Hoist / Coalescer / Regalloc / AOT) all still happen,
  just sequenced after the foundation lands.

### Negative

- **+5 ROADMAP rows** (8a.1 through 8a.5) before any new
  optimisation work touches the JIT codegen. Phase 8 task
  count grows from 11 to 16.
- **8.4-d's hoist module sits behind cap=4 longer** than
  originally planned. Acceptable: the cap is an honest marker;
  the loss is bounded to small-function micro-improvements
  not yet bench-measured.
- **Per-Phase-N tagging in the /continue skill** introduces a
  Phase-aware code path (the bench-discipline trigger). Slight
  complexity; offset by the discipline's value when it fires.

### Neutral / follow-ups

- ADR-0019 (which introduced Phase 8's optimisation scope)
  remains accepted. This ADR refines the **sequencing** within
  Phase 8, not the scope.
- D-053 promotion: the debt row is replaced by ROADMAP row
  8a.5. The debt-ledger entry stays as `Recently discharged`
  (with discharge note pointing at 8a.5) to preserve the
  resolution lineage per `lessons_vs_adr.md` discipline.
- ADR-0028 (Diagnostic ring buffer) becomes the structural
  parent of 8a.1's pass-trace work. 8a.1's ADR
  (`0033_pass_trace_extension.md` — to be filed at chunk
  start) will cite it.

## References

- ROADMAP §9.8 (re-shaped by this ADR)
- ROADMAP §P14 ("Optimisation lands last in commit order" —
  reaffirmed; the foundation-first sequencing operationalises
  this principle within Phase 8)
- ADR-0019 (Phase 8 scope shift to optimisation foundation;
  parent of this ADR)
- ADR-0028 (Diagnostic ring buffer; structural parent for
  8a.1)
- ADR-0031 + lesson `2026-05-08-hoist-vreg-semantic.md` (the
  8.4 cycle history; preserved)
- D-053 (debt ledger; promoted to ROADMAP row 8a.5)
- Commit history `4f0be65` (8.4-b MVP) → `dba7cbb` (8.4-c
  revert) → `8180c66` (8.4-d redesign land) → `4d6fc0b`
  (8.4-d cap=4 integration) — the partial Hoist work
  preserved verbatim.

## Revision history

| Date       | Commit       | Summary |
|------------|--------------|---------|
| 2026-05-08 | `c50296c6` | Initial Decision; Phase 8 reorg into 8a (foundation) + 8b (bench-driven optimisation); D-053 promoted to ROADMAP row 8a.5; /continue skill amended with bench-delta discipline trigger. |
