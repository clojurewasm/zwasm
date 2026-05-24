# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: 9 IN-PROGRESS. **Phase B.3 (D-139) CLOSED** at
  `f81234b0` — audit + 7 in-source tests landed.
- **Last commit**: `f81234b0` — D-139 gap A3 (OOB elem trap zombie)
  close; audit doc revision history updated.
- **Phase 9 close gate (mac-host)**: **18/18 PASS**.
- **Test state at `f81234b0`**: Mac `zig build test` GREEN; lint
  GREEN. ubuntu verified GREEN at `61997baa` (one cycle back per
  Step 0.7).
- **D-028 heisenbug streak**: 1/5 silent (accumulates organically
  through Phase C/D/E windowsmini boundary runs).

## Active task — Phase C cont. (ADR canonical pass to <30)

Per [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2 Phase C.

**Chunk 1 closed at `ba852dd9`**:
- 15 ADRs flipped Accepted → Closed (0105 + 0106 + 0081-0093
  extraction cohort).
- 3 lesson Citing backfills (check_lesson_citing.sh: OK).
- 2 ADR Revision history `<backfill>` resolved (783517cb).

Current Accepted count: **37** (target **<30** per §9.12-I exit).

**NEXT — continue ADR canonical pass** (~7 more flips needed):
candidates include 0054 (track-b source split), 0057 (spec_assert
runner factoring), 0074 (per-op file zone split), 0075 (x86_64
emitctx unification), 0077 (regalloc op scratch reservation) —
all with implementation landed in §9.12 era. Verify per-ADR
implementation evidence before flip.

After §9.12-I exits → Phase D (§9.12-F debt verify, 1 cycle) →
Phase E (§9.13 hard gate, **user collab**) → Phase F.

## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
Authoritative remaining-work source:
[`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2.

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`
(currently 18/18 PASS).

## See

- ADR-0104 (Phase 9 真スコープ)
- ADR-0110 — Value widen 8→16, Closed (implemented) at `9204847a`
- D-167 discharged at `4339eb02`/`fe666b0f` (Phase B.1)
- D-174 cascade fix discharged at `57039f10` (Phase B.3 sub)
- D-139 audit + 7 tests discharged at cycles producing
  `64c2378c` → `f81234b0` (Phase B.3)
- D-171 / D-172 / D-173 — c_api accessor blockers (filed
  during D-139 audit; v0.1.0 RC scope per ADR-0025)
- [`c_api_instance_audit_2026-05-24.md`](./c_api_instance_audit_2026-05-24.md)
  — D-139 audit (now closed; §6 revision history)
- [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
  Phase C/D/E/F sequence reference
