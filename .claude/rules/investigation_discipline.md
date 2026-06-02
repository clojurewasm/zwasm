---
description: "Multi-cycle bug investigation discipline — enumerated hypothesis list with rejecting-SHA tracking + heisenbug 5-silent-run discharge protocol with binary-layout diversity + cause-named close. Absorbs former hypothesis_enumeration.md + heisenbug_discharge.md per ADR-0118 D3."
paths:
  - ".dev/handover.md"
  - ".dev/debt.yaml"
  - ".dev/lessons/**"
  - "scripts/track_heisenbug.sh"
---

# Investigation discipline

> Lean stub (ADR-0118 D2). Full detail / templates / examples: [`../references/investigation_discipline.md`](../references/investigation_discipline.md).

## Invariant

- §1 — A bug open >1 cycle MUST carry an enumerated hypothesis list: numbered name + predicted observable signature + distinguishing probe (cheapest single experiment). Rejected ones kept ~~struck~~ with rejecting SHA (never re-walk). Step 0 BEFORE enumerating: dedup-grep `.dev/debt.yaml` + `.dev/lessons/INDEX.md` for source/function names + symptom keywords; if hit, update existing row / cite existing lesson, don't open fresh.
- §2 — Heisenbug discharge gate = ALL of: (1) ≥5 consecutive `silent` outcomes; (2) over ≥3 structurally-distinct SHAs in the suspected code area (same-artifact streak ≠ evidence); (3) instrumentation still in binary; (4) named root cause OR ADR-documented rate-reduction mitigation. Any non-`silent` (`fail`/`segv`) resets streak to 0.

## Enforcement

- §2: `bash scripts/track_heisenbug.sh <name> silent|fail|segv` (record); `--status` (inspect); prints `DISCHARGE CANDIDATE` when streak fires. Logs `private/heisenbug-<name>.log` (gitignored, per-machine).
- §1: prose discipline + `audit_scaffolding` (files finding if multi-cycle row lacks list).

## Key cases

- Open + investigating → list in debt row body; handover references (`see D-NNN`), no dup. Closed → promote list to lesson as audit trail.
- "Hasn't reproduced this session" = one silent run, NOT evidence (heisenbugs as low as 1/30).
- "DISCHARGED" in handover without commit-side evidence rejected (narrative ≠ landed state).
- Threshold 5 configurable via `--threshold N`; deviation needs ADR.

Templates, reviewer checklists, threshold rationale: [`../references/investigation_discipline.md`](../references/investigation_discipline.md).
