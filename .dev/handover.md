# Session handover

> ≤ 100 lines. Canonical fresh-session entry point per ADR-0104
> + `.dev/phase9_close_master.md` §8.
> Framing: [`handover_framing.md`](../.claude/rules/handover_framing.md).

## Current state

- **Phase**: 9 IN-PROGRESS. §9.13-V `[x]` (`9204847a`, this cycle).
- **Last commit**: `<this cycle>` — post-merge bookkeeping
  (ADR-0110 → Closed, §9.13-V [x], handover refresh).
- **Phase 9 close gate (mac-host)**: **18/18 PASS** (verified
  resume Step 0.8).
- **Test state**: Mac+ubuntu test-all GREEN at `9204847a`
  (ubuntu code-equivalent verified via `73ba4e38..9204847a` diff =
  scripts/+docs only); windowsmini: D-167 pre-existing **9 fails**
  (was 10 pre-cohort; value16 incidentally improved by 1).

## Active task — Phase B (windowsmini D-167 reconcile)

Per [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
Phase B sequence:

- **B.1 (next)** — **D-167 Win64 1+ arg multi-result entry helpers**
  (`now` debt). Single-cycle wire-up per debt row:
  - add `invokeBufWin64Args` helper to
    `src/engine/codegen/shared/entry_buffer_write.zig` (mirror
    of existing `invokeBufWin64NoArgs` lines 95-110)
  - add Win64 if-arms in `src/engine/codegen/shared/entry.zig`
    for `callI32i32_i32` / `callI32i64_i32` /
    `callI64i32_i64i64i32` (4-line forwarding each) +
    `callI32i32i64_i32`
  - windowsmini integration verify (simd_assert orchestration
    via `bash scripts/run_remote_windows.sh test-all`)
  - 11 Win64 directive fails clear on success
- **B.2** — D-028 IPC flake CONFIRMED #5 final verify (N=4 more
  silent runs post-Windows-Defender fix; per
  `.claude/rules/heisenbug_discharge.md`)
- **B.3** — D-139 c_api Instance audit + coverage

After Phase B → Phase C (ADR canonical pass) → Phase D
(§9.12-F debt verify) → Phase E (§9.13 hard gate, user collab) →
Phase F (Phase 10 open).

## Cold-start procedure

Per `/continue` SKILL.md Resume Steps 0.5 / 0.7 / 0.8.
Authoritative remaining-work source:
[`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2.

**Mandatory before any §9.x [x] flip**:
`bash scripts/check_phase9_close_invariants.sh --gate`
(currently 18/18 PASS at `9204847a`).

## See

- ADR-0104 (Phase 9 真スコープ)
- ADR-0110 — Value widen 8→16, **Closed (implemented) at `9204847a`**
- [`phase9_remaining_flow.md`](./phase9_remaining_flow.md) §2
  Phase B/C/D/E/F sequence
- [`phase9_value_widen_plan.md`](./phase9_value_widen_plan.md)
  — §9.13-V Phase A.1-A.6 closed; transitions to ARCHIVED at
  Phase 10 open
- Debt: D-167 (`now`, Phase B.1), D-028 (`blocked-by`, Phase B.2),
  D-170 (`blocked-by` Phase 10+ alongside ADR-0109)
- §9.13-V closed-cohort cycles 38-56: `git log --grep="§9.13-V"`
  (28 commits on the linear chain to `9204847a`).
