# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — FILE-SIZE REFORM Cycle 5 next

**Pickup is Cycle 5 of the file-size discipline reform.**

1. **Read `private/file-size-reform/07-execution-plan.md`** §"Cycle 5"
   (workspace gitignored, present locally; archived at 6c).
2. Execute Cycle 5 (Path B recommended): create `src/parse/init_expr.zig`
   as a deep utility (scanInitExpr, readValType, skipLeb128). Sub-steps:
   - 5a: create init_expr.zig (helpers copied; sections.zig keeps its
     versions; ADR-0101 lands).
   - 5b: re-point sections_element/codes/data at init_expr.
   - 5c: remove duplicates from sections.zig; sections.zig delegates
     internal callers to init_expr too.
3. Continue Cycle 6 (verification + lesson + archive).
4. **DO NOT** start any new D-141 file-size extraction work
   until the reform lands.

## Cycles landed (this session)

- **Cycle 1** (`a33e3dea`): ADR-0099 + rule + script + lesson +
  ROADMAP §A2 reframe.
- **Cycle 2** (`ce67bb45`): check_split_smell.sh wired into
  gate_commit.sh (informational) + audit §J.1 amend + §J.8 add.
- **Cycle 3** (`a061d709`): ADR-0100 (rollback notice for 0097;
  supersede 0095/0096). ADR-0095/0096/0097 Status fields updated.
- **Cycle 4** (this commit): ADR-0097 rollback executed. Verify
  family (VerifyError, verify, verifyWith, 5 tests, testFenceTableFill
  helper) re-incorporated into regalloc.zig. regalloc_verify.zig
  deleted. regalloc.zig now 694 LOC (under 1000 soft cap).

check_split_smell.sh now returns **9 findings** (was 10; regalloc_verify
N3 removed). After Cycle 5 sections rollback, expect 4 (api/wasm.zig
hub, testFenceTableFill N4 dup, inst_neon N3 informational,
regalloc_compute N1 test-context carve-out).

## Background (short)

Post-D-141 retrospective: 3 of 15 sweep extractions (ADR-0095/0096/0097)
don't satisfy proper architectural standards. Reform plan:
ADR-0099 (✅ C1) → gate wire (✅ C2) → ADR-0100 rollback notice
(✅ C3) → execute 0097 rollback (✅ C4) → ADR-0101 init_expr redesign
(C5) → verify + lesson + archive (C6).

## Active `now` debts

- **D-055** (mechanical, multi-cycle): emit_test_int has 27 sites
  pending. **Defer until reform lands.**

## Other queued work (post-reform)

1. §9.12-G `api/instance.zig` redesign (P3 evaluation per §D2).
2. §9.12-H bench baseline (Mac Wasm 2.0 + wasmtime comparison).
3. §9.12-I ADR/lesson curation closure (Phase 9 close).
4. D-055 continuation.
5. Remaining D-141 WARN files (most → EXEMPT marker per §D2).

## Active state (snapshot)

- §9.12-A enforcement: 11 items OK (check_split_smell wired).
- §9.12-F (D-141 sweep): 15 ADRs Accepted; net after reform =
  12 valid + 1 redesigned (init_expr) + 3 retired.
- §9.12-G/H/I: open.

## Open questions / blockers

- なし。Cycle 5 is the largest cycle: 3 sub-steps (5a/5b/5c),
  each independently green. Substrate scope.

## See

- [`.dev/decisions/0099_file_size_discipline_reframe.md`](./decisions/0099_file_size_discipline_reframe.md)
- [`.dev/decisions/0100_rollback_invalid_d141_extractions.md`](./decisions/0100_rollback_invalid_d141_extractions.md)
- [`.claude/rules/file_size_smell.md`](../.claude/rules/file_size_smell.md)
- [`scripts/check_split_smell.sh`](../scripts/check_split_smell.sh)
- [`private/file-size-reform/07-execution-plan.md`](../private/file-size-reform/07-execution-plan.md)
- [ROADMAP](./ROADMAP.md) §9.12 F/G/H/I; §5 A2 reframed
- [`debt.md`](./debt.md) — D-055 only `now`
- [`lessons/INDEX.md`](./lessons/INDEX.md)
