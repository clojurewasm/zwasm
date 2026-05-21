# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — FILE-SIZE REFORM Cycle 6 next

**Pickup is Cycle 6 (verification + condensed lesson + archive)
of the file-size discipline reform.**

1. Read `private/file-size-reform/07-execution-plan.md` §"Cycle 6"
   (workspace gitignored; archived at 6c).
2. Execute Cycle 6 sub-steps in order:
   - **6a (verification)**: run `bash scripts/check_split_smell.sh`
     (expect 6 findings: api/wasm.zig hub, testFenceTableFill N4 dup,
     inst_neon N3, regalloc_compute N1 test-context, sections_codes
     N3, sections_data N3 — last 2 are P1 spec-axis acceptable
     carve-outs not anticipated in the original 4-expected plan).
     Run `zig build test` (green). Run `bash scripts/file_size_check.sh`
     (sections.zig now 825 LOC < 1000 soft cap).
   - **6b (condensed lesson)**: create
     `.dev/lessons/2026-05-21-file-size-cap-as-smell-detector-not-metric.md`
     (~50-80 LOC; drift pattern + 4+4 framework summary + ADR
     pointers). Update lessons/INDEX.md.
   - **6c (archive)**: `mv private/file-size-reform/ →
     private/archive/2026-05-21-file-size-reform/`. Refresh
     handover.md back to normal cold-start procedure pointing at
     §9.12-G / §9.12-H / §9.12-I etc.

## Cycles landed (this session; see `git log` for detail)

- C1..C5c: ADR-0099 (✅) + gate wire (✅) + ADR-0100 (✅) +
  ADR-0097 rollback (✅) + ADR-0101 init_expr extraction
  (✅ 5a/5b/5c). sections.zig 1190 → 825 LOC; verify family
  back in regalloc.zig (694 LOC). check_split_smell: 6 findings
  (4 expected + 2 sections N3 spec-axis carve-out; ADR-0099 §D2
  tie-breaker acceptable).

## Background (short)

Post-D-141 retrospective: 3 of 15 sweep extractions don't satisfy
proper architectural standards. Reform plan: ADR-0099 (✅C1) →
gate wire (✅C2) → ADR-0100 (✅C3) → 0097 rollback (✅C4) →
ADR-0101 init_expr (✅C5a, ✅C5b, ✅C5c) → verify + lesson +
archive (C6).

## Active `now` debts

- **D-055** (mechanical, multi-cycle): emit_test_int has 27 sites
  pending. **Defer until reform lands (Cycle 6c).**

## Other queued work (post-reform)

1. §9.12-G `api/instance.zig` redesign (P3 evaluation per §D2).
2. §9.12-H bench baseline (Mac Wasm 2.0 + wasmtime comparison).
3. §9.12-I ADR/lesson curation closure (Phase 9 close).
4. D-055 continuation.
5. Remaining D-141 WARN files (most → EXEMPT marker per §D2).

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK.
- §9.12-F (D-141 sweep): 15 ADRs Accepted; net after reform =
  12 valid + 1 redesigned (init_expr) + 3 retired.
- §9.12-G/H/I: open.

## Open questions / blockers

- なし。Cycle 6 mostly docs (lesson + archive); 6a verification
  is read-only.

## See

- [`.dev/decisions/0099_file_size_discipline_reframe.md`](./decisions/0099_file_size_discipline_reframe.md)
- [`.dev/decisions/0100_rollback_invalid_d141_extractions.md`](./decisions/0100_rollback_invalid_d141_extractions.md)
- [`.dev/decisions/0101_init_expr_extraction.md`](./decisions/0101_init_expr_extraction.md)
- [`src/parse/init_expr.zig`](../src/parse/init_expr.zig)
- [`private/file-size-reform/07-execution-plan.md`](../private/file-size-reform/07-execution-plan.md)
- [ROADMAP](./ROADMAP.md) §9.12 F/G/H/I; §5 A2 reframed
- [`debt.md`](./debt.md) — D-055 only `now`
- [`lessons/INDEX.md`](./lessons/INDEX.md)
