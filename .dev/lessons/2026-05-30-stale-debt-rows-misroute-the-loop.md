# Stale "blocked-by ADR-flip" debt rows mis-route the autonomous loop

**Date**: 2026-05-30
**Citing**: cyc234-235 session (D-195 / D-198 / D-202 navigation); `05266c03`
**Keywords**: debt sweep, stale debt, barrier-dissolution, ADR Status, blocked-by,
Proposed vs Accepted, narrative-claim-vs-landed-state, D-195, D-198, ADR-0123,
ADR-0126, function-references corpus, bucket-3 false alarm, Step 0.5

## Observation

A `/continue` session spent ~3 turns mis-navigating Phase 10 because **debt rows
described barriers that had already dissolved**, and the loop trusted the prose
instead of verifying ground truth:

- D-195 `blocked-by: ADR-0123 Accept flip` — but ADR-0123 was **Accepted**
  2026-05-28 ("user-delegated autonomous flip") and the function-references corpus
  was already GREEN (`return 39/0, trap 4/0, invalid 18/0`). The typed-funcref
  `0x63/0x64` parser had landed (`zir.zig:191`). The row was stale; the loop
  briefly treated D-195 as the next chunk, then as a user-gated blocker.
- The loop nearly called a **bucket-3 stop** ("high-value work is user-gated on GC
  ADR flips") — FALSE: ADR-0115/0116/0123/0126 are all Accepted. There was no
  pending user flip. The genuine open work (D-202 cross-module finality) is
  autonomous impl, not ADR-gated.
- A GC-survey subagent compounded it by reading per-op `NotMigrated` stubs as
  "unimplemented ops" — but those fall back to the legacy switch
  (`dispatch_collector.zig:280`) and the corpus is green through it.

## Root cause

Debt rows carry a snapshot `Status: blocked-by: <ADR> Proposed → Accepted`. When
the ADR flips Accepted, the impl becomes autonomous, but the row's `blocked-by`
prose is not auto-updated — so a later Step 0.5 debt-sweep that trusts the prose
treats settled work as still-gated, and can mistake "ADRs accepted + impl pending"
for "user-gated, bucket-3."

## Takeaway (how to apply)

In `/continue` **Step 0.5 debt sweep**, before trusting any debt row whose Status
says `blocked-by: ADR-NNNN <flip>` or `gated on ADR-NNNN`:

1. `grep -m1 Status .dev/decisions/NNNN_*.md` — if **Accepted**, the gate is gone;
   the row is impl-pending (autonomous), not user-gated. Treat it as a candidate
   chunk, not a barrier.
2. Cross-check the **live corpus** (the ubuntu test-all summary line / `pNN_*_status.sh`),
   NOT the row's narrative counts — fixture states drift green underneath stale rows.
3. Only conclude **bucket-3** when a CURRENT artifact (an ADR still `Proposed`, a
   provably-absent host, a toolchain genuinely unprovisioned) gates the work — never
   from a debt row's prose alone.

This is the `narrative-claim-vs-landed-state` discipline applied to the debt ledger:
the ledger is a hint, the ADR Status + live corpus are ground truth.
