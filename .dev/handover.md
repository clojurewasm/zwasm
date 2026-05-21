# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-F discharge plateau

§9.12-F (debt active rows < 15) and §9.12-I (ADR canonical) open.
The autonomous discharge work has reached a productive plateau —
remaining barriers are genuine future-phase deferrals or external
upstream issues. Next step is user-judgment territory (§9.12-F
exit re-framing OR pivot to §9.13-0 multi-cycle work).

| Exit criterion                  | Latest fact                                                   |
|---------------------------------|---------------------------------------------------------------|
| §9.12-F: debt active rows < 15  | 19 (D-081 closed `f79104bb`; 4/6 phase-9-eligible cohort done)|
| §9.12-I: ADR `Accepted` < 30    | strict 33 / loose 53 (ADR-0034 flipped `9457a4b6`)            |

**Latest cycles since plateau** (cleanup + heartbeat):

- `9641f794` debt-stale-framing-pattern lesson.
- `b2f88711` trigger-watch heartbeat (D-094 / D-062 / D-079).
- `d8e02f32` arm64 m-4c comment cleanup post-D-090.
- `e2e3c1f2` runVoidExport docstring refresh post-D-055.

These touched comments only (no behaviour change).

**Trigger-watch candidates**: D-094 (real workload demanding
>2 same-class results), D-062 (≥ 9 v128 args), D-079 (c_api
v128). No fixture changes; triggers un-fired.

**§9.12-F remaining state**:

- 13 deferred to Phase 10/11/14/v0.1.0 RC/external (D-007,
  D-010, D-020, D-021, D-026, D-058, D-059, D-074, D-075,
  D-079, D-082, D-148, D-157).
- 4 §9.13-0 / Cat IV cohort (D-022, D-028, D-136 + sibling).
- 2 trigger-not-fired Phase-9-eligible (D-062, D-094).

**Next pickup** (user-judgment territory):

(a) §9.13-0 windowsmini reconcile (D-136 SEH bridge, D-028 IPC)
    — substantial multi-cycle Win64-side work.
(b) §18 amendment of §9.12-F exit criterion — re-frame to
    "phase-9-eligible cohort substantially addressed".
(c) Wait for natural trigger events (D-094 / D-062 fixtures).

windowsmini reachable per `ssh windowsmini`. SEH bridge needs
Win64 PowerShell + small C/asm shim.

## Recent context

- §9.12-G closed (`4bd62842`); §9.12-H closed (`600bd7cf`).
- §9.12-I batches 1+2 + ADR-0034 flip.
- §9.12-F discharges: D-018 / D-055 / D-090 / D-141 / D-081.
- D-055 migration batches 1+2 + close (`871c78e1`).
- Plateau cleanups + lesson.

## Active `now` debts

- なし.

## Other queued work

1. **§9.13-0 windowsmini reconcile** (D-136 SEH, D-028 IPC).
2. **§9.12-F exit re-framing decision** (user-judgment).
3. **D-094 / D-062 trigger-watch** per stale-framing lesson.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK.
- §9.12-F: 19 active rows; 4/6 phase-9-eligible debts closed.
- §9.12-G / §9.12-H / D-055 / D-090 / D-141 / D-081: closed.
- §9.12-I: 30 ADRs flipped; blocked on Phase 9 close.

## Open questions / blockers

- §9.12-F exit re-framing decision (user-judgment per §18).
- §9.13-0 needs commitment to deep Win64 SEH work or wait.

## See

- [ROADMAP](./ROADMAP.md) §9.12-F + §9.12-I + §9.13-0
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
- New lesson: `2026-05-21-debt-stale-framing-pattern.md`
