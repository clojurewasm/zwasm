# 0080 — Phase 9 exit redefinition: literal-zero OR named-successor-phase ADR escape

- **Status**: Rejected (2026-05-21; superseded by direct
  implementation — see Rejection note below)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (close-plan §6 (i))
- **Tags**: phase-9, exit-criterion, governance, skip-impl, escape-valve

## Rejection note (2026-05-21, post-Proposed)

User-collab spike under close-plan §6 (j) prep proved this ADR
**unnecessary**. The spectest cross-module imports gap (D-153,
the dominant runtime SKIP source at 100+ events) is solvable by
**direct implementation** rather than Phase 10 escape valve:

1. spectest is a finite 56-line OCaml host module
   (`WebAssembly/spec/interpreter/host/spectest.ml`).
2. Both zwasm v1 and wazero implement it as a regular `.wat`
   module that the spec runner auto-registers; cross-module
   resolver (β path) then binds testsuite imports normally.
3. Spike at `private/spikes/d153_spectest_wat/` (2026-05-21):
   compiled a 23-line spectest.wat + auto-registered it in
   runCorpus + flipped `hasUnbindableImports` to consult
   `registered.contains(imp.module)` for non-func imports.
   Result: 192 runtime-skip → 80 (−112), 43 new failures
   surfaced (= remaining cohort bugs in B146-B158 preparatory
   infra, fixable individually).

The 43 surfaced failures share a small number of root causes
(notably: per-exporter `scratch_globals` wiring reads importer-
side zero buffer instead of exporter side) — direct fix
discharges the cohort. No Phase 10 escape needed.

This ADR's `Status: Proposed` predicted "3-6 more months in
§9.12-E"; the spike empirically refuted that estimate.
Original Decision text below preserved for audit trail.

## Context

## Context

The current Phase 9 exit criterion, as amended in
[ADR-0056](0056_phase9_scope_extension_to_wasm2_full.md)
2026-05-17 and 2026-05-18 Revision-history rows:

> `skip-impl == 0 literally` across Categories I–IV, evaluated
> on Mac + ubuntunote (§9.9 close gate) + windowsmini reconcile
> (§9.13-0 gate).

This predicate is **structurally rigid**: a single residual
manifest `skip-impl` line — for any cause — blocks Phase 9
close. Three architectural debts now hold that lock:

| Debt   | Structural barrier                                                 | Realistic discharge phase |
|--------|--------------------------------------------------------------------|---------------------------|
| D-079  | v128 cross-module imports (Wasm 2.0 SIMD reftype Cat III tail)     | §9.12-E continuation OR Phase 10 substrate audit follow-up |
| D-136  | Windows SEH bridge for trap-in-cross-module-callee                 | §9.13-0 (Cat IV reconcile) OR Phase 10 windowsmini-specific work |
| D-153  | spectest cross-module imports (globals / tables / memories binding)| §9.12-E (spike-first per close-plan §6 (j)) OR Phase 10 |

Each is structurally non-trivial (400–800 LOC + design ADR per
debt-row hypotheses). Close-plan §6 (i) (resolving D1) names
the resulting failure mode: **§9.12-E lockin** — every cycle
since 2026-05-17 has measured the same 100-ish runtime SKIP
events without close progress, and the autonomous loop has no
graceful exit that doesn't either (a) close all three debts
inline (multi-cycle architectural work the close-plan §6 (j)
discipline correctly rejects as on-branch spike) or (b)
re-derive the exit criterion to recognise "this work is real
but belongs in a later phase".

Note: close-plan §6 (e) (commit `13562a5`) already revealed
that **manifest** `skip-impl` is in fact ALREADY zero — the
historical 192 "skip-impl" count was conflated with runtime
SKIP-* events. ADR-0029 Path B's release gate (the original
basis for `skip-impl == 0`) was always about manifest lines.
This ADR re-aligns the Phase 9 exit text with that semantic.

## Decision

Amend the Phase 9 exit criterion to a **two-clause disjunction**:

> Phase 9 closes when `manifest_skip_impl == 0` on Mac +
> ubuntunote (Cat I + II + III) **AND** every residual runtime
> SKIP-* event (counted by `tally.runtime_skip` per ADR-0029
> Path B + close-plan §6 (e)) is paired with **either**:
>
> - a `debt-trackable` row in `.dev/debt.md` whose
>   `Status: blocked-by:` names a **specific successor-phase
>   ADR** (e.g. ADR-Phase10-X) currently in Status: Proposed or
>   Accepted, OR
> - an `ADR-required` waiver in `.dev/decisions/skip_*.md`
>   (per ADR-0078 token taxonomy).

The Cat IV (windowsmini bit-identical reconcile) gate retains
its position at §9.13-0 per ADR-0056 2026-05-18 amendment —
this ADR does NOT move it.

### Concretely for D-079, D-136, D-153

If accepted, each of the three debts becomes a Phase 9 exit
escape candidate via the following procedure:

1. Author a successor-phase ADR (e.g. ADR-0081 for D-079
   "Phase 10 v128 cross-module imports", ADR-0082 for D-136
   "Phase 10 Windows SEH cross-module bridge", ADR-0083 for
   D-153 "Phase 10 spectest cross-module imports"). The ADR
   names the successor phase + carries the structural design.
   `Status: Proposed` is sufficient.
2. Update each debt row's `blocked-by:` to point at the
   corresponding successor ADR.
3. Verify `tally.runtime_skip` events for that fixture cohort
   route through an ADR-0078 `debt-trackable` row whose
   barrier now reads "ADR-008X Phase 10 work".
4. Phase 9 close proceeds — the residual SKIP events are
   acknowledged as Phase 10 scope, not Phase 9 gaps.

This is **NOT a relaxation** of release rigor. The release
gate that ADR-0050 D-5 enforces (one-way ratchet on
`manifest_skip_impl`) is **strengthened** by ADR-0078 + close-
plan §6 (e): the counter no longer hides runtime gaps as
manifest gaps, and every runtime gap is now traceable to a
named structural barrier with a successor-phase plan.

### What this ADR does NOT change

- ADR-0029 Path B (manifest skip-impl as the release gate).
  Preserved verbatim; only its interpretation is sharpened.
- ADR-0050 D-5 (one-way ratchet). Preserved; now ratchets only
  `manifest_skip_impl`, which is currently zero on both Mac and
  ubuntunote — the strongest position possible.
- ADR-0056 4-category scope (Cat I/II/III/IV). Preserved; the
  exit predicate's clause shape is amended without removing a
  category.
- Cat IV windowsmini reconcile at §9.13-0. Preserved per
  ADR-0056 2026-05-18 amendment.

## Alternatives considered

### Alternative A — Hold the literal predicate; finish D-079 / D-136 / D-153 inline

- **Sketch**: Stay with `skip-impl == 0 literally`. Close-plan
  §6 (j) D-153 resume + parallel D-079 / D-136 work continues
  in §9.12-E until all three structural debts dissolve.
- **Why rejected**: Each debt is architectural (400–800 LOC,
  ADR-grade design). Three in series under §9.12-E means
  3–6 more months of "Phase 9 closes after this big piece".
  Close-plan B3 ("1 more chunk" pattern) explicitly forbids
  this shape. The architectural-cycle-cap rule (LOOP.md +
  close-plan §6 (c)) already caps D-153 at 3 cycles — extending
  to D-079 + D-136 in series is direct evidence the exit
  predicate is the load-bearing constraint, not the work
  itself.

### Alternative B — Drop the manifest gate; gate purely on Phase 10 design ADRs

- **Sketch**: Remove the literal-zero predicate entirely.
  Phase 9 closes when every category has a successor-phase
  ADR in Proposed or Accepted.
- **Why rejected**: This DOES loosen rigor. ADR-0050 D-5 ratchet
  exists precisely to prevent skip-impl count from drifting
  upward across phases. Manifest skip-impl is observable; ADR
  presence is governance theatre if the underlying behaviour
  doesn't measurably hold. The disjunction in this ADR keeps
  the measurable side.

### Alternative C — Time-box: 3 more cycles, then escape

- **Sketch**: Continue §9.12-E for exactly 3 more `/continue`
  cycles; if the three debts don't close, auto-escape with
  successor-phase ADRs as proposed here.
- **Why rejected**: Time-boxing is a heuristic; the structural
  question is "does the work belong in Phase 9 or Phase 10".
  ADR-0072 §"Invariants in code, not prose" prefers a structural
  predicate over a time-based one. The disjunction in this ADR
  is structural — successor-phase ADR existence is the gate,
  not elapsed cycles.

## Consequences

- **Positive**:
  - §9.12-E lockin (close-plan D1) breaks. Phase 9 can close
    once the successor-phase ADR triplet (D-079 / D-136 /
    D-153) lands as Proposed.
  - Phase 10 inherits a **clearer scope statement** —
    cross-module imports / Windows SEH / SIMD reftypes Cat III
    tail are NAMED Phase 10 work (vs the current Phase 9 spill-
    over ambiguity).
  - ADR-0078 + close-plan §6 (e) gain a downstream consumer:
    `runtime_skip` events now carry a per-token Phase 10 path,
    closing the audit story.
- **Negative**:
  - Three more successor-phase ADRs must be authored before
    Phase 9 closes. Mitigated: each is small (Proposed only,
    no impl) and the design space is already documented in the
    respective debt-row hypotheses.
  - Phase 9 closing under this predicate ships v0.1.0 with
    documented gaps. Mitigated: the gaps were always there;
    this ADR makes them visible instead of pretending §9.12-E
    extension will close them imminently.
- **Neutral / follow-ups**:
  - Successor-phase ADR triplet (ADR-0081 / ADR-0082 / ADR-0083
    suggested numbers) — to be authored post-Acceptance.
  - ADR-0056 needs a Revision-history entry citing this ADR
    once Accepted.
  - `scripts/check_skip_impl_ratchet.sh` already operates on
    `manifest_skip_impl` only (close-plan §6 (e)) — no script
    change needed.

## References

- Close-plan §6 (i) — `.dev/phase9_structural_debt_close_plan.md`
- ADR-0029 Path B — skip-impl release gate (preserved).
- ADR-0050 D-5 — one-way ratchet (preserved; now manifest-only).
- ADR-0056 — Phase 9 scope extension (this ADR amends its
  exit-criterion interpretation).
- ADR-0062 — substrate-audit gate (preserved; gates §9.12-E
  → §9.12 substrate audit).
- ADR-0072 — comment-as-invariant rule (structural predicate
  preferred over time-based).
- ADR-0078 — SKIP-* token taxonomy (this ADR's
  `debt-trackable` + `ADR-required` categories are the
  pairing-target).
- Close-plan §6 (e) commit `13562a5` — AssertTally split that
  revealed manifest skip-impl ≡ 0 already.
- D-079 / D-136 / D-153 — the three debts this ADR plans to
  escape to Phase 10 via successor ADRs.

<!--
## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `52a93fbc` | Initial Proposed version.               |
-->
