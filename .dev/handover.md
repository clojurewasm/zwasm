# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-I in progress

§9.12-I (ADR + lesson + private/ closure). 2 of 3 exit
criteria now met this commit:

| Exit criterion | Pre-commit | Post-commit |
|---|---|---|
| `check_adr_history.sh --gate` 0 | 5 pending (3 real + 2 templates) | 1 pending (template only) — gate exits 0 ✓ |
| `check_lesson_citing.sh` 0 | 2 unfilled | 0 ✓ |
| ADR `Accepted` count < 30 | 85 | 85 (open — canonical pass deferred) |

**This commit (mechanical backfills)**:
- ADR-0075 row: `<backfill>` → `799b9b10` (D-160 amend).
- ADR-0080 row: `<backfill>` → `2b8e2447` (Withdrawn commit).
- ADR-0094 rows (2): `<backfill>` → `ac89b0a6` (Proposed) +
  `5653180c` (Accepted at f777edaa).
- Lesson `d141-sweep-structural-debts.md`: Citing `<pending>` →
  `ce43d124`.
- Lesson `emit-zig-survey-per-op-pattern-already-absorbed.md`:
  Citing `<backfill>` → `2b8e2447`.

**Next pickup**: ADR Status canonical pass — flip ~55 ADRs
from `Accepted` to `Closed (Phase X DONE)` where the ADR's
authoring phase has been marked DONE per the §9 Phase Status
widget. The §9.12-I row text says "~22-25 entries" specifically
for the Phase-9-cohort; older phases also need pruning to reach
the `< 30` exit target. This is a substantial multi-cycle pass
(85 → < 30 = ~55+ flips); approach in batches by phase.

Approach:
1. Group ADRs by authoring phase via `git log --follow`.
2. For each phase Status: DONE (per Phase Status widget),
   batch-flip `Accepted` → `Closed (Phase N DONE)` on its
   ADRs.
3. skip-ADR Status wording cleanup (skip_cross_module_register
   / skip_cross_module_action — separate scan).
4. Lesson promotion scan (3+ citations).

## Recent context

- §9.12-G closed (`4bd62842`); §9.12-H closed (`600bd7cf`).
- File-size reform (cycles C1..C6): ADR-0099/0100/0101 etc.

## Active `now` debts

- **D-055** (mechanical, multi-cycle): emit_test_int has 27 sites
  pending.

## Other queued work

1. **§9.12-I ADR canonical pass** — next cycle (multi-cycle).
2. **D-055 continuation**.
3. **Phase 10 ZirOp slot policy ADR** — gates memory64 /
   relaxed-simd file-level placeholders.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK.
- §9.12-F (D-141 + reform): closed.
- §9.12-G: closed.
- §9.12-H: closed.
- §9.12-I: in progress (this commit + canonical pass to come).

## Open questions / blockers

- なし for §9.12-I canonical pass.

## See

- [ROADMAP](./ROADMAP.md) §9.12-I scope + exit
- [`scripts/check_adr_history.sh`](../scripts/check_adr_history.sh)
- [`scripts/check_lesson_citing.sh`](../scripts/check_lesson_citing.sh)
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
