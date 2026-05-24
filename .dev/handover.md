# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: 9 IN-PROGRESS. §9.12-F `[x]`, §9.12-I `[x]`.
  Remaining `[ ]` in §9: §9.13-0 + §9.13 (hard gate).
- **Phase 9 close gate (mac-host)**: **18/18 PASS**.
- **Last code commit**: `00cb63de` (D-170 / D-079 (ii) close —
  in-source c_api regression test for cross-module v128 global
  threading; master plan §5.3a Phase A.3 discharge).

## §9.13-0 close path

Per `.dev/phase9_close_master.md` §5.3a:

- Phase A — per-debt discharge with in-source tests
  - A.1 D-157 (SKIP-NO-LINK-TYPECHECK) — **[x]**
  - A.2 D-139 (c_api Instance lifecycle audit) — **[x]**
  - A.3 D-079 (ii) / D-170 (v128 cross-module) — **[x]
    (`00cb63de`)**
- Phase B — windowsmini reconcile (single shot after Phase A
  complete)
  - B.1 `bash scripts/run_remote_windows.sh test-all` once
  - B.2 §9.13-0 `[x]` flip + §9.12-F / §9.12-I re-confirm +
    SHA backfill

## Active task — Phase B.1 windowsmini reconcile

Phase A is complete. Next chunk type: `infrastructure`
(phase-boundary windowsmini reconcile per ADR-0049 + ADR-0067
single-shot discipline).

1. Run `bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1`
   (long-running SSH; use `run_in_background: true`; Bash timeout
   ≥ 600000 ms). The wrapper does `git fetch + reset --hard
   origin/zwasm-from-scratch` on windowsmini before run, so it
   tests `00cb63de` HEAD.
2. Read `/tmp/win.log` tail: required = zero
   `SKIP-WIN64-EXHAUSTION` / `SKIP-WIN64-CALL-INDIRECT-TRAP` /
   `SKIP-WIN64-MULTI-RESULT` / `SKIP-NO-LINK-TYPECHECK`
   emission; PASS counts ≥ prior windowsmini green
   (`7680cbd2` = simd_assert_runner 13351 pass).
3. If a Win64-specific issue surfaces, in scope to fix within
   the same Phase B reconcile (single re-iterate per master
   plan §5.3a B.1).
4. On green: Phase B.2 — flip §9.13-0 `[x]` in ROADMAP §9
   citing the windowsmini-green commit; backfill SHA columns
   for the §9 rows whose Status column is bare.

After §9.13-0 `[x]`, next ROADMAP row is §9.13 (🔒 Phase 10
entry gate `.dev/phase10_transition_gate.md`); per `/continue`
LOOP.md "Exception — hard human-in-loop transition gates", the
autonomous loop STOPS at that detection and surfaces to user
for collaborative review.

## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
Authoritative remaining-work source:
[`phase9_close_master.md`](./phase9_close_master.md) §5.3a + §6.

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`
(currently 18/18 PASS).

## See

- [`phase9_close_master.md`](./phase9_close_master.md) §5.3a / §6
  — current authoritative close-plan (Doc-state: ACTIVE)
- [`lessons/2026-05-24-c_api-v128-spec-boundary.md`](./lessons/2026-05-24-c_api-v128-spec-boundary.md)
  — industry audit; load-bearing for D-079 / D-170 / D-171 /
  D-172 / D-173
- ADR-0104 (Phase 9 真スコープ); ADR-0110 Closed (Value=16
  widen); ADR-0109 Proposed (native Zig API, v128 access path)
- `.dev/debt.md` Active rows + Discharged-this-cycle (D-170 +
  D-079 retired)
