# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — §9.12-I in progress

§9.12-I (ADR + lesson + private/ closure). Exit criteria:

| Exit criterion                  | Latest fact                                                                |
|---------------------------------|----------------------------------------------------------------------------|
| `check_adr_history.sh --gate` 0 | 1 pending (template only) — gate exits 0 ✓                                 |
| `check_lesson_citing.sh` 0      | 0 unfilled ✓                                                               |
| ADR `Accepted` count < 30       | strict 33 (loose incl. annotated: 52) — structurally blocked (see below)   |

**This commit (ADR canonical pass batch 2)**: 2 more ADRs
flipped `Accepted` → `Closed (Phase 7 DONE)` — 0027 (JitRuntime
globals extension, §9.7 / 7.7) + 0028 (Diagnostic M3 trace, ADR-
0016 M3 in Phase 7). Both verified by `## Context` reading.

**Skip-ADR cleanup investigation**:

- `skip_cross_module_register`: already `Superseded (2026-05-17
  by Phase 9 §9.9-III chunk (c)-1c)`. 0 manifest references.
  No action — canonical wording already in place.
- `skip_cross_module_action`: Status remains `Accepted`. 286
  manifest entries across elem / exports / linking /
  memory_grow / table_grow still reference
  `skip-adr-skip_cross_module_action`. The annotation
  "while cross-module imports are out of scope" is stale
  (imports landed via ADR-0065) but the action-directive
  dispatch problem is separate and still active. Keep
  `Accepted`; cleanup wording amendment deferred until
  action-directive dispatch lands.

**Lesson promotion scan (3+ citations, deferred per-lesson)**:

- `2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`
  (10 cites) — cited by ADR-0080-Withdrawn historical record.
- `2026-05-21-pure-data-extraction-via-reexport` (9 cites) —
  cited by file-layout ADRs.
- `2026-05-17-d134-rosetta-2-signal-translation-limit` (7) —
  already promoted by ADR-0067.
- `2026-05-21-cross-file-struct-method-syntax-zig-0-16` (6) —
  already promoted by ADR-0094.
- Others: 2026-05-17-gamma3d-dispatch-write-segv-bisect (6);
  2026-05-16-regalloc-pool-scratch-overlap (6);
  2026-05-16-narrative-claim-vs-landed-state (5);
  2026-05-04-emit-monolith-cost (5).

Most citations are FROM the associated ADR (promotion already
happened structurally). Per-lesson actual demotion / cleanup
deferred — each needs individual judgment per
`lessons_vs_adr.md` "Promotion / Demotion" procedures.

**Why exit criterion is structurally blocked**: the remaining
strict-Accepted cohort splits into (a) 17 Phase-9 ADRs (Phase
9 still IN-PROGRESS — `Accepted` is correct), (b) ~13 §9.12
file-layout reform ADRs (§9.12 still IN-PROGRESS), (c)
cross-cutting infrastructure ADRs without a closing phase
(0009 lint, 0020 testing process, 0049 multi-host-policy,
0050 ADR governance, 0062 governance/dispatch, 0067 infra,
0074 architecture, 0076 process). The < 30 target requires
Phase 9 + §9.12 to close first.

**Next pickup**: §9.12-I row's `[x]` should NOT be flipped
yet — exit criterion is unmet. Continue with §9.12-F row text
sub-items (D-094 / D-090 / D-062 / D-081 / D-055 dissolution
verify), then revisit §9.12-I after Phase 9 work + §9.12-F
land.

## Recent context

- §9.12-G closed (`4bd62842`); §9.12-H closed (`600bd7cf`).
- §9.12-I batch 1 (`1095d225`): 27 ADRs flipped (P1/2/3/4/6/7/8).
- §9.12-I batch 2 (this commit): 2 ADRs flipped (P7 meta).

## Active `now` debts

- **D-055** (mechanical, multi-cycle): emit_test_int has 27 sites
  pending.

## Other queued work

1. **§9.12-F sub-item discharge** — D-094 / D-090 / D-062 / D-081 /
   D-055; exit `debt active rows < 15`.
2. **D-055 continuation** (mechanical, multi-cycle).
3. **§9.12-I revisit after Phase 9 + §9.12-F close**.

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK.
- §9.12-F: `[ ]` in ROADMAP — D-094 / D-090 / D-062 / D-081 /
  D-055 sub-items pending.
- §9.12-G: closed (`4bd62842`).
- §9.12-H: closed (`600bd7cf`).
- §9.12-I: open (2 batches landed; exit blocked on P9 + §9.12-F).

## Open questions / blockers

- なし for §9.12-F sub-item pivot.

## See

- [ROADMAP](./ROADMAP.md) §9.12-F + §9.12-I scope + exit
- [`scripts/check_adr_history.sh`](../scripts/check_adr_history.sh)
- [`scripts/check_lesson_citing.sh`](../scripts/check_lesson_citing.sh)
- [`debt.md`](./debt.md), [`lessons/INDEX.md`](./lessons/INDEX.md)
