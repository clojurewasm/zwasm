# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: 9 IN-PROGRESS. **§9.12-I `[x]`** at `526bbe30` —
  Phase C closed.
- **Last commit**: `526bbe30` — 12 more ADRs Accepted→Closed
  (0041, 0053, 0054, 0055, 0057, 0058, 0059, 0060, 0066, 0074,
  0075, 0077). ADR Accepted **52 → 25** (target <30).
- **Phase 9 close gate (mac-host)**: **18/18 PASS**.
- **Test state at `526bbe30`**: docs-only chunk; Mac+ubuntu
  GREEN at prior `e670446b` per Step 0.7.
- **D-028 heisenbug streak**: 1/5 silent.

## Active task — Phase D (§9.12-F debt cohort verify)

Per [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
Phase D (1 cycle, autonomous):

- **D.1 — §9.12-F debt cohort dissolution verify**: walk per
  ADR-0102 per-row predicate (a)(b)(c)(d) for D-094, D-062,
  D-141, D-081, D-055.
- ADR-0102 says most have dissolved via ADR-0106 / Q3 C
  adoption / per-op file pattern. Verify each row state.

Exit: §9.12-F row flip `[x]`.

After §9.12-F closes → Phase E (§9.13 hard gate, **user
collab**) → Phase F (Phase 10 open).

## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
Authoritative remaining-work source:
[`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2.

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`
(currently 18/18 PASS at `526bbe30`).

## See

- ADR-0104 (Phase 9 真スコープ)
- ADR-0110 — Value widen 8→16, Closed (implemented) at `9204847a`
- ADR-0105 / ADR-0106 — Closed (implemented); I6 invariant
  widened to accept Closed alongside Accepted per Phase C
- D-167 discharged at `4339eb02`/`fe666b0f` (Phase B.1)
- D-174 cascade fix at `57039f10` (Phase B.3 sub)
- D-139 audit + 7 tests at `64c2378c`…`f81234b0` (Phase B.3)
- D-171 / D-172 / D-173 — c_api accessor blockers (v0.1.0 RC)
- [`c_api_instance_audit_2026-05-24.md`](./c_api_instance_audit_2026-05-24.md)
  — D-139 audit (closed; §6 revision history)
- [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
  Phase D/E/F sequence reference
