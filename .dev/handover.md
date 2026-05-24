# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: 9 IN-PROGRESS. §9.13-V `[x]`; Phase B.1 (D-167) CLOSED.
- **Last commit**: `4339eb02` D-167 wire-up + `7680cbd2` handover;
  this cycle = D-167 discharge + handover refresh.
- **Phase 9 close gate (mac-host)**: **18/18 PASS**.
- **Test state at `7680cbd2`**: Mac+ubuntu test-all GREEN;
  **windowsmini test-all GREEN — simd_assert 13351 PASS, 0 FAIL,
  0 directive fails** (all 9 pre-existing D-167 fails CLEARED).
- **D-028 heisenbug streak**: 1/5 silent (recorded
  `7680cbd2`); needs 4 more silent runs across distinct binary
  layouts to discharge.

## Active task — Phase B.3 (D-139 c_api Instance audit + coverage)

Per [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2.
B.2 (D-028) discharge progresses organically as future
windowsmini Phase-boundary runs accumulate silent outcomes (≥ 5
across ≥ 3 distinct SHAs per `.claude/rules/heisenbug_discharge.md`).

**B.3 — D-139 c_api Instance audit + coverage**:
- Audit `src/api/instance.zig` Instance lifecycle path: arena
  ownership, zombie-instance contract, deinit ordering vs
  cross-instance shared slices (cross-ref ADR-0014 §6.K).
- Add coverage tests (in-source `test "..."` blocks per project
  idiom; `zig build test` discovers via core runner) for:
  - Instance allocator strict-pass + double-deinit safety
  - Zombie list traversal (shared globals slice survival across
    one instance deinit while owner instance lives)
  - Arena ownership (cross-instance memory.copy bounds, table
    aliasing)

After Phase B closes (B.1 ✓, B.2 streak, B.3 D-139): §9.13-0 row
exit predicate per ADR-0104 D1.2-1.6 evaluation, then Phase C
(§9.12-I ADR canonical pass), Phase D (§9.12-F debt verify),
Phase E (§9.13 hard gate, user collab), Phase F (Phase 10 open).

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
- D-167 discharged 2026-05-24 at `4339eb02` (windowsmini-verified at `7680cbd2`)
- D-079 (ii) / D-170 — c_api wasm_instance_new v128 globals JIT
  wiring; blocked-by Phase 10+ alongside ADR-0109
- [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
  Phase B/C/D/E/F sequence
- §9.13-V closed-cohort cycles 38-56: `git log --grep="§9.13-V"`
