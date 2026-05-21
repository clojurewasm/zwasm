# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure — FILE-SIZE REFORM Cycle 2 next

**Pickup is Cycle 2 of the file-size discipline reform.**

1. **Read `private/file-size-reform/07-execution-plan.md`** §"Cycle 2"
   (workspace gitignored, present locally; archived at 6c).
2. Execute Cycle 2: wire `scripts/check_split_smell.sh` into
   `scripts/gate_commit.sh` as informational (non-failing) check
   between `file_size_check` and `check_skip_adrs`. Add
   `.claude/skills/audit_scaffolding/CHECKS.md` §J.3 referencing
   check_split_smell.
3. Continue Cycles 3-6 in order (Cycles 7-8 optional).
4. **DO NOT** start any new D-141 file-size extraction work
   until the reform lands.
5. **Path B vs Path A for sections (Cycle 5)**: plan recommends
   Path B (extract init_expr.zig as deep utility; sub-steps
   5a/5b/5c). Path A acceptable interim. Decision at Cycle 5
   entry.

## Cycle 1 landed (this session)

- ADR-0099 (file-size reframe; 4+4 conditions; EXEMPT default)
- `.claude/rules/file_size_smell.md`
- `scripts/check_split_smell.sh` (not yet gate-wired)
- Lesson `2026-05-21-pure-data-extraction-via-reexport.md` amended
- ROADMAP §5 A2 narrative updated to cite ADR-0099

Script returns **10 findings** baseline (Cycles 4-5 reduce to 4
expected: api/wasm.zig hub, testFenceTableFill N4 dup, inst_neon
N3 informational, regalloc_compute N1 test-context carve-out).

## Background (short)

Post-D-141 retrospective: 3 of 15 sweep extractions (ADR-0095/0096/0097)
don't satisfy proper architectural standards. Root cause: soft cap
WARN treated as forcing function rather than smell detector
(ADR-0063 intent drifted). Reform plan: ADR-0099 (✅ Cycle 1) →
gate wire (Cycle 2) → ADR-0100 rollback notice (Cycle 3) → execute
0097 rollback (Cycle 4) → ADR-0101 init_expr redesign (Cycle 5) →
verify + lesson + archive (Cycle 6).

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

- §9.12-A enforcement: 11 items OK after Cycle 2 wires script.
- §9.12-F (D-141 sweep): 15 ADRs Accepted; net after reform =
  12 valid + 1 redesigned (init_expr) + 3 retired.
- §9.12-G/H/I: open.

## Open questions / blockers

- なし。Cycle 2 is mechanical (gate_commit edit + CHECKS.md edit).

## See

- [`.dev/decisions/0099_file_size_discipline_reframe.md`](./decisions/0099_file_size_discipline_reframe.md)
- [`.claude/rules/file_size_smell.md`](../.claude/rules/file_size_smell.md)
- [`scripts/check_split_smell.sh`](../scripts/check_split_smell.sh)
- [`private/file-size-reform/07-execution-plan.md`](../private/file-size-reform/07-execution-plan.md)
- [ROADMAP](./ROADMAP.md) §9.12 F/G/H/I; §5 A2 reframed
- [`debt.md`](./debt.md) — D-055 only `now`
- [`lessons/INDEX.md`](./lessons/INDEX.md)
