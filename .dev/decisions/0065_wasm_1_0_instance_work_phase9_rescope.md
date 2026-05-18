# 0065 — Absorb Wasm 1.0 instance / store / linker work into Phase 9 scope

- **Status**: Accepted
- **Date**: 2026-05-17
- **Author**: zwasm v2 maintainer (Phase 9 close-readiness cycle)
- **Tags**: phase-9, scope, wasm-1.0, instance, store, linker, cross-module, host-imports

## Context

ROADMAP §9.9 row text (as amended by ADR-0056) commits Phase 9 to
**"Wasm 2.0 (incl. SIMD) 100% PASS on Mac+OrbStack"** with
`skip-impl == 0` as the structural exit predicate. Through the
2026-05-12..05-17 close-readiness cycle the literal `skip-impl`
counter sits at 1573 on Mac+OrbStack despite a bit-identical
spec_assert PASS count of 24001/0/2069 (non-SIMD) +
13301/0/440 (SIMD) since chunk d-85.

Decomposition of the residual `skip-impl == 1573` (per
[`.dev/phase9_close_plan.md`](../phase9_close_plan.md) §2) shows
the count is **not uniform**:

| Cat     | Description                                                                                            |                Today | Original ROADMAP placement             |
|---------|--------------------------------------------------------------------------------------------------------|---------------------:|----------------------------------------|
| **I**   | Validator / parser spec-rule enforcement                                                               |                **0** | Phase 9                                |
| **II**  | Spec-test harness (multi-result entry helpers)                                                         |                ~1400 | Phase 9 (driver scope)                 |
| **III** | Runtime instance binding — `(register "M" $inst)` + cross-module import / start-trap / link-typecheck |                  144 | **Phase 10+ "instance-aware runtime"** |
| **IV**  | Host-platform recovery bridge (Windows SEH for `assert_trap`)                                          | windowsmini-specific | Phase 9 (batch-end sweep)              |

ROADMAP §1 / §2 P/A + §11 layers + ADR-0056 placed Cat III into
"Phase 10+ instance-aware runtime" scope on the basis of
**implementation weight** (Store / Instance / linker is a
substantial runtime layer), not on the basis of where the
underlying feature lives in the Wasm spec.

**Cross-checking the Wasm 1.0 specification**:

- Wasm 1.0 core spec §4.5 (Instances, Stores, Imports, Linking)
  is base spec, not a proposal extension.
- The spec testsuite has used the `(register "M" $inst)`
  directive since Wasm 1.0; the directive being silently
  skipped in our corpus means we don't actually run those
  Wasm 1.0 assertions.
- Wasm 1.0 host imports (the `(import "spectest" "print_*"
  ...)` family) are likewise base spec; binding them is the
  pre-condition for the spec runner to exercise host-effect
  fixtures.

The 2026-05-17 user-confirmed correction:

> Cat III は Wasm 1.0 core 機能。`(register "M" $inst)` +
> cross-instance import は Wasm 1.0 仕様の一部。Phase 10 まで
> 遅延すべきでなかった。気付いたいま、Phase 9 のうちにやる
> べきだし、Wasm 2.0 完備項目にも含めるべき。ロードマップを
> 修正必要。

This makes the existing §9.9 row dishonest as a "Wasm
completeness" claim if it closes with Cat III still
silently skipped, even when the SIMD + non-SIMD PASS
counters are visually green.

## Decision

Absorb the Wasm 1.0 instance / store / linker / cross-module
dispatch / host-import binding / start-trap recovery work into
**Phase 9 scope** as part of the §9.9 exit predicate. Phase 10
scope purifies to the Wasm 3.0 proposal feature set (GC, EH,
tail-call, memory64, multi-memory, typed function references).

Concretely the §9.9 exit predicate becomes (per ADR-0056
2026-05-17 amend, this ADR cited):

> `skip-impl == 0` literally across all four categories on
> Mac + OrbStack + windowsmini:
>
> - **Cat I** (validator/parser): already 0.
> - **Cat II** (multi-result entry helpers): drain to 0 via
>   `entry.zig` `FuncRet_<types>` helpers + spec_assert runner
>   `dispatchMultiResult<shape>` arms.
> - **Cat III** (Wasm 1.0 instance / store / linker /
>   cross-module dispatch / host imports / start-trap /
>   link-typecheck): implement Store + Instance registry,
>   cross-module import linker, cross-module call dispatch,
>   host import binding (spectest family), start-trap
>   propagation, runner `(register ...)` directive handler.
> - **Cat IV** (Windows SEH bridge for `assert_trap`): batch
>   sweep at Phase 9 end (D-084 / D-136 / D-028 cohort).

The §9.9 row text in ROADMAP §9 is amended per ADR-0056
Revision history 2026-05-17 to reflect the 4-category
predicate. The §9.9 sub-task table gains rows for the Cat II /
Cat III / Cat IV discharge sub-chunks (chunk IDs assigned at
landing time per ADR-0014 no-renumber discipline).

## Alternatives considered

### Alternative A — Keep Cat III in Phase 10; amend ADR-0056 to exclude it from §9.9 exit

- **Sketch**: leave Cat III's 144 directives as legitimate
  `skip-impl` in §9.9 close; document the carve-out in
  ADR-0056 Revision history; let Phase 10 absorb the instance
  work alongside the Wasm 3.0 proposals.
- **Why rejected**: dishonest about Wasm 1.0 completeness.
  ROADMAP §1 / §2 P/A explicitly aim to avoid v1's W43/W44/W45
  / W54 deferred-debt anti-pattern. A "Phase 9 done" claim
  that silently skips Wasm 1.0 base-spec directives propagates
  the same failure mode the v2 redesign exists to prevent.
  The same reasoning that drove ADR-0056 ("non-SIMD
  fake-green is structural debt") applies in the same shape
  to Cat III.

### Alternative B — Open a new §9.9.5 / §9.5b row dedicated to instance work

- **Sketch**: leave §9.9 as the SIMD + multi-result close;
  add a parallel row §9.9.5 (or §9.10b if §9.10 is taken)
  for instance work. Both must close before §9.12 substrate
  audit fires.
- **Why rejected**: distorts the Phase Status widget semantics
  (one phase, one IN-PROGRESS row at a time) and creates two
  rows that are conceptually the same exit (Wasm 1.0 + 2.0
  base-spec completeness). ADR-0014's no-renumber discipline
  prefers row-text amendment over row addition when the
  semantic scope of the existing row is the natural carrier.

### Alternative C — Defer the entire §9.9 close decision until substrate audit lands

- **Sketch**: pause §9.9 work until §9.12 substrate audit
  clears, on the theory that any instance-layer code shape
  may need re-derivation if substrate audit picks
  dispatch-table completion (Hypothesis A) or per-op-file
  hybrid (Hypothesis C).
- **Why rejected**: substrate audit's scope (per ADR-0062) is
  the **opcode dispatch architecture** for the per-op
  semantics layer (validator / lower / emit arms). The
  runtime/Store/Instance/linker layer is structurally
  independent — Store holds instances, instances hold
  exported funcaddrs, linker resolves imports at
  instantiation. None of that touches opcode dispatch.
  Even if substrate audit picks (B) or (C), the instance
  layer code likely doesn't need re-shaping. Pausing §9.9
  on a non-dependency is unforced delay.

### Alternative D — Promote the close-plan §3 narrative into a lesson rather than a new ADR

- **Sketch**: rely on `.dev/phase9_close_plan.md` + a
  `.dev/lessons/2026-05-17-cat-iii-roadmap-misclassification.md`
  to carry the correction; amend ADR-0056 only.
- **Why rejected**: per
  [`.claude/rules/lessons_vs_adr.md`](../.claude/rules/lessons_vs_adr.md),
  a Phase-scope absorption is **load-bearing** — downstream
  code (instance/Store/linker), Phase 10 scope text, debt-row
  re-evaluations, and the substrate audit doc all change as
  a consequence of this decision. An ADR is the correct
  artifact; the close-plan stays as the execution playbook;
  no lesson file is required.

## Consequences

- **Positive**:
  - Phase 9 close becomes an honest Wasm 1.0 + 2.0
    completeness claim (the structural-debt-free baseline
    that ADR-0056 and ROADMAP §2 P/A aimed for).
  - Phase 10 scope purifies to Wasm 3.0 proposals (GC, EH,
    tail-call, memory64, multi-memory, typed function refs).
    The Phase 10 entry gate (§9.13) opens against a clean
    Wasm 2.0 base, not on top of a hidden Cat III gap.
  - The 144 Cat III directives surface during Phase 9
    close-readiness rather than emerging mid-Phase-10 as
    "we can't run this Wasm 3.0 fixture because the
    cross-module linker isn't there yet". The cost of
    discovering instance-layer gaps during a Wasm 3.0 design
    ADR is structurally higher than discovering them now.
  - Several `now`-debt rows whose barrier was named "Phase
    10+ instance-aware runtime" (D-079 v128 cross-module
    imports, D-126 bulk.wast call_indirect post-mutation,
    D-082 sub-rows on cross-module fixtures, D-026 embenchen
    emcc env imports) become dischargeable in the same
    Phase 9 close, reducing the deferred-debt overhang.
  - Substrate audit (§9.12) Q5 hygiene rules
    (invariant-comment lint, single-slot-dual-meaning,
    no-copy-from-v1, debug discipline) apply uniformly to
    the new instance-layer code; the layer doesn't accumulate
    pre-audit hygiene debt.
- **Negative**:
  - Phase 9 close timeline extends by the Cat II + Cat III +
    Cat IV cohort. The Phase Status widget stays Phase 9 =
    IN-PROGRESS for the duration; the §9.12 substrate audit
    hard-gate fires later than it would have under
    Alternative A.
  - The instance/Store/linker layer is being implemented
    **before** the substrate audit's architecture decision
    is locked. If audit picks (B) comptime-gated switch or
    (C) per-op-file hybrid, the per-op layer reshapes —
    but the instance layer doesn't (per Alternative C
    rejection rationale). Discipline note: avoid coupling
    instance-layer code to opcode-dispatch internals beyond
    the existing `ZirOp` enum surface.
- **Neutral / follow-ups**:
  - `D-079`, `D-082` sub-rows, `D-126`, `D-026` debt rows
    need barrier re-evaluation at close-plan step (a)-4;
    rows whose `blocked-by:` cited "Phase 10+
    cross-module …" flip to `now`.
  - The Cat III work likely surfaces 1–2 sub-ADRs for the
    Store / Instance lifetime model (ownership of imported
    funcaddrs across instances; lifetime of host-bound
    closures) at the chunk's design step — those land as
    `0066_*` / `0067_*` per close-plan step (c)
    sub-chunk-1.
  - `D-074` (Phase 11 bench-infra cohort) sub-items that
    cited "cross-module instance binding" as a barrier may
    move forward; re-evaluated at step (a)-4 alongside the
    others.
  - Phase 10 ROADMAP description text needs no change yet
    (the Phase 10 entry exit criterion already references
    Wasm 3.0 proposals only); the §1 / §2 P/A entries do
    need amendment to push Phase 9's lower bound to "Wasm
    1.0 + 2.0 base-spec complete on 3 hosts".

## References

- ROADMAP §1, §2 (P / A), §9.9 — phase scope this ADR amends
  (load-bearing per §18.2; ROADMAP edit chunk = close-plan
  step (a)-3)
- ROADMAP §11 — runtime layer (Store / Instance / linker is
  the layer being populated; no §11 text change required —
  the layer was always declared, only its population
  timeline shifts)
- ROADMAP §14 — forbidden list unchanged
- ADR-0003 — Phase-2 corpus curation (no further amendment;
  ADR-0056's Phase-15 absorption clause covers the Wasm 2.0
  corpus; the Cat III work uses the same vendored corpus
  unchanged)
- ADR-0014 — no §9 renumber discipline (preserved; §9.9 row
  text is amended in place; no new row added)
- ADR-0029 — Path B skip vocab (this ADR's Cat III absorption
  realises the `skip-impl == 0` predicate's intent
  honestly across the 4-category breakdown)
- ADR-0049 — per-chunk Mac+OrbStack gate; windowsmini Phase
  boundary reconcile (Cat IV is the Phase-boundary
  reconcile sweep)
- ADR-0055 — Win64 v128 marshal discipline (Cat IV cohort
  pre-existing item)
- ADR-0056 — Phase 9 scope extension to "Wasm 2.0 100% PASS"
  (this ADR amends ADR-0056 Revision history at step (a)-2
  to add the 4-category predicate and Cat III absorption)
- ADR-0062 — Phase 9 完備 substrate audit gate at §9.12
  (this ADR clarifies that Cat III work is structurally
  independent of substrate audit's Q3 architecture decision
  and proceeds in parallel)
- ADR-0063, ADR-0064 — pre-commit gate reactivation
  foundation (the gate runs on every Cat II / III / IV
  commit)
- [`.dev/phase9_close_plan.md`](../phase9_close_plan.md) —
  authoritative execution playbook (this ADR is the
  load-bearing decision; close-plan is the runnable
  sequence)
- `.dev/debt.md` rows affected: D-079, D-082 sub-rows,
  D-126, D-026, D-074, D-084, D-135, D-136

## Revision history

| Date       | SHA          | Note                                                                                                                                               |
|------------|--------------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-17 | `<backfill>` | Initial. Absorbs Wasm 1.0 instance / store / linker / cross-module / host-imports / start-trap work into Phase 9 scope; pairs with ADR-0056 amend.                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| 2026-05-18 | `<backfill>` | **Cat IV scope clarification** — the original 4-category absorption included Cat IV (windowsmini reconcile) inside §9.9 close. Per user 2026-05-18 confirmation + ADR-0049 + ADR-0056 paired amendments, Cat IV moves to a dedicated row §9.13-0 (post-§9.12-substrate-audit, pre-§9.13-Phase-10-entry-gate). Cat I + Cat II + Cat III remain in §9.9 close gate. The Phase 9 scope absorption (this ADR's load-bearing decision) is **not** loosened; only the position of the windowsmini reconcile step within the Phase 9 close sequence shifts. See ADR-0049 + ADR-0056 Revision-history 2026-05-18 rows for the position-shift rationale. |
