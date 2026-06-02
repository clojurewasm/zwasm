# Blocked-by ledger sweep — 2026-05-21

> **Doc-state**: ACTIVE — load-bearing reference (Phase 9+ scope).

> Initial sweep per close-plan §6 (h) acceptance. Establishes
> the age-threshold ladder defined in
> [`audit_scaffolding §F.2a`](../.claude/skills/audit_scaffolding/CHECKS.md)
> and classifies the 28 active `blocked-by` rows in
> [`.dev/debt.yaml`](debt.yaml) at sweep time.

## Threshold ladder (re-state)

| Age (today − Last reviewed)              | Finding | Action                                                                              |
|------------------------------------------|---------|-------------------------------------------------------------------------------------|
| ≤ 14 calendar days (≈ ≤ 3 resume cycles) | clean   | No action.                                                                          |
| 15–30 days (> 3 cycles)                  | `soon`  | Re-walk the barrier; update `Last reviewed` if still blocked.                       |
| > 30 days (> 5 cycles)                   | `block` | File an ADR or lesson capturing the structural cause, OR promote the row to `now`.  |

## Classification at 2026-05-21

### Clean (≤ 14 days; no action) — 20 rows

| Row   | Last reviewed | Age   |
|-------|---------------|-------|
| D-141 | 2026-05-21    |  0 d  |
| D-148 | 2026-05-18    |  3 d  |
| D-149 | 2026-05-18    |  3 d  |
| D-026 | 2026-05-17    |  4 d  |
| D-074 | 2026-05-17    |  4 d  |
| D-079 | 2026-05-17    |  4 d  |
| D-082 | 2026-05-17    |  4 d  |
| D-102 | 2026-05-17    |  4 d  |
| D-103 | 2026-05-17    |  4 d  |
| D-105 | 2026-05-17    |  4 d  |
| D-136 | 2026-05-17    |  4 d  |
| D-139 | 2026-05-17    |  4 d  |
| D-094 | 2026-05-14    |  7 d  |
| D-062 | 2026-05-12    |  9 d  |
| D-081 | 2026-05-12    |  9 d  |
| D-090 | 2026-05-12    |  9 d  |
| D-075 | 2026-05-11    | 10 d  |
| D-058 | 2026-05-10    | 11 d  |
| D-059 | 2026-05-10    | 11 d  |
| D-055 | 2026-05-09    | 12 d  |

### `soon` (15–30 days; re-walk barrier) — 7 rows

| Row   | Last reviewed | Age   | Re-walk priority                                                       |
|-------|---------------|-------|------------------------------------------------------------------------|
| D-018 | 2026-05-04    | 17 d  | Verify barrier holds; otherwise flip to `now`.                         |
| D-020 | 2026-05-04    | 17 d  | "                                                                      |
| D-021 | 2026-05-04    | 17 d  | "                                                                      |
| D-022 | 2026-05-05    | 16 d  | "                                                                      |
| D-028 | 2026-05-05    | 16 d  | "                                                                      |
| D-007 | 2026-05-06    | 15 d  | "                                                                      |
| D-010 | 2026-05-06    | 15 d  | "                                                                      |

### `block` (> 30 days; needs ADR/lesson OR promote) — 0 rows

None. The oldest entry is 17 days; no row has fossilised past
the 30-day threshold.

## Action plan

This sweep document is the static snapshot. The 7 `soon` rows
each need a barrier re-walk; that work is captured as **D-156**
in `.dev/debt.yaml` (added in the same commit as this sweep). The
re-walk happens in subsequent `/continue` cycles, one row at a
time, per the Step 0.5 unconditional check.

Once D-156 closes, the next periodic sweep can re-run this
file's classification logic via the planned
`scripts/audit_blocked_by_age.sh` (filed under D-155 follow-up
to ADR-0078 + audit §F.2a; same script can serve both
audit-skill checks).

## Notes

- D-070 was incorrectly returned by an early `awk` pass; it is
  in the "Recently discharged" section, not active. Excluded.
- "≈ 3 resume cycles = 14 days" calibrates the conversion based
  on the 2026-05-04 → 2026-05-21 timeframe seeing roughly 4
  active `/continue` loops; the calendar threshold remains
  authoritative when the cycle count is ambiguous.
