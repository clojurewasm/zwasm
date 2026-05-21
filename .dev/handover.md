# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10` — D-141 sweep cont.: ADR-0097
   extracts regalloc verify family to `regalloc_verify.zig`
   (regalloc.zig 1401→1274 LOC; still WARN, follow-up
   compute extraction needed). Prior: ADR-0095/0096 closed
   parse/sections.zig. D-055 unchanged (27 emit_test_int sites).
2. **User directive (2026-05-21)**: batch-session architectural
   mode — Phase 9 closure quality. D-141 per-file ADR cycle
   continues; remaining candidates need own ADR-grade survey.
3. **Live status**: `bash scripts/p9_completion_status.sh`.

## Active `now` debts

- **D-055** (mechanical, multi-cycle, partial): cumulative 30
  tests migrated. emit_test_float ~99% done (1 unreachable
  test with prescan-induced runtime_ptr remaining).
  emit_test_int starts next cycle (27 sites). After full
  migration, sentinel wire-up is a 5-line patch in
  x86_64/emit.zig.

## Authorized next-session pickup (priority order)

1. **Remaining D-141 candidates** (architectural, each needs
   own ADR-grade survey — NOT single-cycle mechanical):
   - `api/instance.zig` (1431 LOC) — c_api lifecycle redesign.
   - `shared/regalloc.zig` follow-up (1274 LOC post-ADR-0097) —
     Step 2 = extract computeWith + computeSpillOffsets + fence
     helpers to `regalloc_compute.zig` (dissolves WARN).
   - `validate/validator.zig` (1365 LOC) — Wasm 2.0 bulk
     memory/table ops + dispatch helpers (post-ADR-0083 SIMD
     extraction); blocked by per-op-file migration.
   - codegen *_test.zig pairs (emit_test_int 1607, emit_test_float
     1571, op_simd_int_cmp_lane_test 1190) — test-file splits
     await D-055/D-081 closure.
2. **D-055 continuation** (multi-cycle mechanical, partial at
   `783e6c11`; continue from emit_test_int line ~159).
3. **§9.12-G `src/api/instance.zig` split** (per c_api lifecycle).
4. **§9.12-H bench baseline** (Mac Wasm 2.0 + wasmtime).
5. **§9.12-I ADR/lesson curation closure**.

## Active state (snapshot)

- **§9.12-A enforcement**: 10 items OK (now includes
  check_sibling_pub --gate per ADR-0094); gate_commit + pre-push
  audit gates active. §9.12-E [x] at `7b2e1b02`.
- **ADR-0078 fully load-bearing**: G.1.1 + G.1.2 + amendment.
- **§9.12-G partial**: 41 Wasm 3.0 stubs landed; dispatcher
  comptime-reject; CLI --invoke.
- **§9.12-F**: 14 D-141 slots closed (2026-05-21 session).
  ADRs 0079+0081-0090+0095-0097 Accepted. ADR-0094 Accepted
  (D-158). 3 lessons captured. `engine/compile.zig` +
  `parse/sections.zig` both dropped from WARN list; 19 files
  remain (regalloc.zig reduced but still WARN pending Step 2).

## Pattern menu (next-session reference)

| Pattern | When applicable | Examples |
|---|---|---|
| Pure-data re-export | One block > 40% LOC, no methods, no state | ADR-0082, 0086, 0087, 0088, 0090 |
| Pure top-level helper | 3+ standalone helpers, no callers, simple imports | ADR-0079, 0081, 0085 |
| Cross-file struct method | Struct-method-heavy file with SIMD or other clean axis | ADR-0083, 0089, 0095 (paired with ADR-0094 SIBLING-PUB discipline) |
| Per-caller migration | N independent symbols, 100+ caller sites | ADR-0084 |

See lesson `2026-05-21-pure-data-extraction-via-reexport.md`
survey checklist before drafting the next per-file ADR. For
struct-method extractions, also follow lesson `2026-05-21-cross-
file-struct-method-syntax-zig-0-16.md` 4-step checklist (SIBLING-
PUB marker is step 4).

## Operational note for the batch-session loop

`/continue` resume Steps 0-7 apply per cycle. Granularity
`architectural`. Soft cap is a smell not a constraint per
user direction (意味があるならハードキャップ無視可). Remaining
work needs survey-first discipline.

## Open questions / blockers

- なし。Remaining D-141 candidates each need own ADR-grade
  survey before extraction (no mechanical pattern fits).

## See

- [ROADMAP](./ROADMAP.md) §9.12 — F (D-141 sweep partial) / G / H / I open.
- [`debt.md`](./debt.md) — 25 active rows.
- [`decisions/0095_sections_element_extraction.md`](./decisions/0095_sections_element_extraction.md) — Accepted.
- [`decisions/0096_sections_data_and_codes_extraction.md`](./decisions/0096_sections_data_and_codes_extraction.md) — Accepted.
- [`decisions/0097_regalloc_verify_extraction.md`](./decisions/0097_regalloc_verify_extraction.md) — Accepted.
- [`lessons/INDEX.md`](./lessons/INDEX.md).
