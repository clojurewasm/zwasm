# 0135 — GC-on-JIT precise rooting (§11.4 / D-211) re-sequenced to Phase 15 with reclamation

- **Status**: Accepted (2026-06-03; autonomous per ADR-0132)
- **Date**: 2026-06-03
- **Author**: claude (autonomous roadmap re-sequencing per ADR-0132; user directive 2026-06-03)
- **Tags**: Phase 11, Phase 15, GC, precise rooting, reclamation, D-211, deferred, forward-ref, ROADMAP §18
- **Amends**: ROADMAP §11 task table (row 11.4), ROADMAP Phase 15 scope; ADR-0128 §2 (the
  "rooting lands with Phase-11 reclamation" assumption); `.dev/debt.yaml` D-211
- **Authorised-by**: ADR-0132 (autonomous cross-phase re-sequencing for a phase task that
  references genuinely-later, unscheduled work)

## Context

§11.4 ("GC-on-JIT precise rooting — conservative native-stack scan + stack-map root walker;
lands with Phase-11 reclamation, zero codegen change") cannot be implemented or tested in
Phase 11, because the work it depends on is not present and not scheduled:

1. **Rooting is untestable without reclamation.** Precise rooting only becomes load-bearing
   once a collector actually frees objects — a *missed* root manifests as a use-after-free
   only if the missed object can be reclaimed. The Phase-10 collector is **β no-reclamation**:
   `src/feature/gc/collector_mark_sweep.zig:24-27` ("True reclamation … defers to Phase 11 …
   dead bytes leak until process exit") + `:214` ("Phase 11 amendment: free-list reuse or
   compaction"). The sweep counts `dead_bytes` but never reuses them. ADR-0128 §2 states the
   same: "rooting becomes load-bearing only when reclamation lands." With no reclamation, a
   rooting bug has **no observable failure** → no red test can be written (TDD-undeliverable).

2. **The stack-map + native-scan prerequisites are empty/absent.** `src/ir/zir.zig:640,645`
   declares `GcRootMap = struct {}` — a zero-size placeholder with no PC-indexed root slots.
   No native-stack conservative scanner exists in the tree; ADR-0128 §2 defers it without a
   routine. Filling `GcRootMap` requires the collector's free-list/compaction shape, which
   Phase 10 deliberately did not define.

3. **Rooting is NOT a Phase-11 exit criterion.** §11.P exit (ROADMAP §11 "Exit criterion")
   lists realworld Mac+Linux + Windows subset + 3-host bench auto-record + SIMD gap profile.
   GC rooting is absent. Deferring §11.4 therefore does not block Phase 11 close.

4. **Reclamation is currently unowned.** No phase's scope names GC free-list/compaction:
   Phase 12 = AOT, Phase 13 = C-API full, Phase 14 = CI matrix. The §11.4 phrase "lands with
   Phase-11 reclamation" is a forward reference to work that was never actually placed in a
   phase — a scoping gap inherited from ADR-0128's assumption that Phase 11 would add a
   reclaiming collector.

This is precisely the ADR-0132 carve-out condition (a phase task whose exit/scope references
genuinely-later-phase work), which authorises autonomous re-sequencing.

## Decision

**Re-sequence §11.4 (GC-on-JIT precise rooting, D-211 rooting part) to Phase 15, paired with
GC reclamation as a single unit.** Both land together when the optimisation/finalisation tier
is reached:

- **Why Phase 15, not earlier.** The non-moving + no-reclamation model is **correctness-safe**
  (a missed root cannot UAF when nothing is freed), so deferral costs no spec conformance. GC
  reclamation is a **memory-efficiency** concern, and P14 mandates "optimisation lands last"
  (Phase 15). Pairing rooting with reclamation keeps the mechanism with the thing it serves.
- **Why not v0.2.0+.** Keeping it in Phase 15 retains it within the v0.1.0 tail rather than
  making the larger "drop GC reclamation from v0.1.0" statement. If a v0.1.0 user surfaces a
  GC-heavy long-running program that OOMs under no-reclaim, reclamation can be re-prioritised
  by revising this ADR — the decision is reviewable, not irreversible.
- **GC op-emit is NOT affected.** D-211's *other* part — the absence of `struct*`/`array*`/
  `ref_cast`/`ref_test` JIT op-emit files (those ops run interp-only) — is a separate concern
  also tracked in D-211; it is independent of rooting and is likewise not a §11.P blocker (the
  gc spec corpus is green under the JIT spec-engine mode per the Phase-10 close). It stays in
  D-211 as a noted gap, not re-sequenced here.

### Changes (ROADMAP §18.2 four-step)

1. ROADMAP §11 task table row 11.4 → `[~] moved to Phase 15 (ADR-0135)`, content updated to
   state the reclamation pairing + the untestable-without-reclaim rationale.
2. ROADMAP Phase 15 scope gains a forward-ref bullet: "GC reclamation (free-list reuse /
   compaction per ADR-0115 §10) + precise rooting (stack-map root walker + conservative
   native-stack scan per ADR-0128 §2; ex-§11.4, D-211) land here as a paired unit."
3. This ADR + handover sync.
4. Commit references ADR-0135.

## Consequences

- Phase 11's remaining real work is §11.1 (WASI — Mac-side done; Windows subset = phase-close
  batch), §11.2 (bench — paths verified; committed 3-host rows = phase-close batch), and
  **§11.3 SIMD per-op gap analysis** (now the next substantive autonomous Phase-11 track).
- D-211 is updated: rooting deferred to Phase 15 (with reclamation); the GC-op-emit gap noted
  as the residual. The row stays `blocked-by` (Phase 15), no longer implying Phase-11 work.
- ADR-0128 §2's "lands with Phase-11 reclamation" wording is superseded by this ADR's
  "lands with Phase-15 reclamation."
