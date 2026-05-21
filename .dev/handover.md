# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-F + §9.12-I in progress (structurally blocked)

Two open §9.12 sub-rows both gated on Phase 9 deep code work:

| Exit criterion                  | Latest fact                                                                |
|---------------------------------|----------------------------------------------------------------------------|
| §9.12-F: debt active rows < 15  | 23 (24 - 1 D-018 discharge last cycle); 8 over target                      |
| §9.12-I: ADR `Accepted` < 30    | strict 33 / loose 52; blocked on P9 cohort (17) + §9.12 file-layout (~13)  |

**This commit (debt sweep — Last reviewed bumps)**:

Per Step 0.5 escalation rule (rows reviewed > 3 cycles ago):
8 rows bumped to 2026-05-21 after re-walking barriers. All barriers
hold:

- D-026 (blocked-by emcc env-stub host-func wiring) — Phase 11 scope.
- D-058 / D-059 (blocked-by Phase 10 boundary audit_scaffolding) —
  Phase 10 not yet open.
- D-074 (blocked-by no Phase row for tier-provisioning) — Phase 11.
- D-075 (blocked-by no Phase row for Zig library facade) — v0.1.0 RC.
- D-082 (blocked-by Phase 11 embenchen full-perf-suite) — Phase 11.
- D-136 (blocked-by Win64 SEH bridge) — §9.13-0 Cat IV.
- D-139 (blocked-by no Phase row for c_api Instance path test) —
  v0.1.0 RC.

**Why §9.12-F is structurally blocked**: 23 active rows split into:
- 1 `now` (D-055; mechanical multi-cycle migration; ~95 expectEqual
  Slices test sites + 5-line wire — too large for a single cycle).
- 22 `blocked-by`, of which:
  - 9 deferred to Phase 10 / 11 / 14 / v0.1.0 RC (won't resolve in
    Phase 9).
  - 5 §9.12 sub-items (D-055 / D-081 / D-090 / D-094 / D-141) —
    deep code work, each 1+ cycle.
  - 3 external (D-010 Zig stdlib semantics; D-028 windowsmini IPC
    flake; D-148 upstream Zig fix).
  - 5 §9.13-0 / SEH / Track-D / future (D-026 / D-136 / D-157 /
    D-082 / D-022).

Reaching `< 15` requires either (a) several cycles of mechanical
D-055 site migration + D-141 per-file ADRs landing, or (b) §18
amendment of the exit criterion to exclude provably-deferred-to-
future-phase rows. Neither is a one-cycle action.

**Next pickup**: D-055 migration batch 1 (~10 test sites in
emit_test_int.zig / emit_test_float.zig moved from hardcoded
prologue offsets to `prologue.body_start_offset()`-relative). The
migration is behavior-preserving (tests stay green); the eventual
5-line `inst.encMovMemDisp32Imm32` wire-up in `x86_64/emit.zig`
prologue happens after all ~95 sites land. Each migration cycle
makes ≤ 10% progress toward unblocking the JIT-execution sentinel
on x86_64.

## Recent context

- §9.12-G closed (`4bd62842`); §9.12-H closed (`600bd7cf`).
- §9.12-I batch 1 (`1095d225`) + batch 2 (`5e2b1a6e`).
- §9.12-F D-018 discharge (`02397144` + SHA backfill `3df2f7ff`).

## Active `now` debts

- **D-055** (mechanical, multi-cycle): ~95 expectEqualSlices sites +
  5-line wire; barrier dissolved per row.

## Other queued work

1. **D-055 migration batches** — per-cycle ~10 sites.
2. **D-141 per-file file-size ADRs** — 18 WARN files; many qualify
   for P1/P2 conditions per ADR-0099 D2.
3. **§9.12-I revisit after Phase 9 close**.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK.
- §9.12-F: 23 active rows; exit `< 15` blocked on multi-cycle work.
- §9.12-G / §9.12-H: closed.
- §9.12-I: 29 ADRs flipped to Closed (P1-P7-P8 cohort); blocked on
  Phase 9 close.

## Open questions / blockers

- なし for D-055 migration batches.

## See

- [ROADMAP](./ROADMAP.md) §9.12-F + §9.12-I scope + exit
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
