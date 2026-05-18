# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. **HARD GATE — read first**:
   [`phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md).
   §9.9 closed at this session; next `[ ]` row is §9.12 (🔒
   substrate re-examination per ADR-0062). The `/continue`
   loop's hard-gate detector pauses autonomous mode here for
   collaborative review. Do NOT auto-pick the next ROADMAP row.
2. `git log --oneline -10`. Latest pre-resume:
   `<this-session-commit> chore(p9): §9.9 [x] flip — Cat I+II+III drained, hard gate at §9.12`.
3. `bash scripts/p9_simd_status.sh` — live status (SIMD 13301/0/440
   bit-identical Mac + ubuntunote; non-simd 25325/0/688 bit-identical).
4. `cat .dev/debt.md` — `now` rows: D-079, D-102, D-103, D-105,
   D-133, D-149 (audit cohort SHA backfill).

## Active state — §9.9 closed; Phase 9 IN-PROGRESS pending §9.12

- §9.9 `[x]` (umbrella row; this session).
- §9.9-II `[x] fb063b09` (Cat II multi-result drained).
- §9.9-III `[x] 2dbd3f15` (Cat III instance / cross-module).
- §9.9-IV `[~] moved to §9.13-0` (windowsmini reconcile post-§9.12).
- §9.10 `[~] moved to Phase 11` (SIMD per-op gap analysis).
- §9.11 `[x] f06a3c9b` (prior phase-9 boundary cohort).
- §9.12 `[ ]` 🔒 — **substrate audit hard gate**, NEXT.
- §9.13-0 `[ ]` — windowsmini Cat IV reconcile (post-§9.12).
- §9.13 `[ ]` 🔒 — Phase 10 entry gate (post-§9.13-0).

Phase Status widget: Phase 9 stays `IN-PROGRESS` until §9.13 [x].

## Hard gate procedure — §9.12 substrate re-examination

Per ADR-0062 + `/continue` skill §"Exception — hard human-in-loop
transition gates": surface the gate document to the user,
collaborative review walks Q2 / Q3 / Q4 decisions (DispatchTable
completion vs comptime-switch vs per-op-file hybrid), then user
flips §9.12 `[x]`. Phase 10 feature work waits behind this.

## Outstanding upstream blocker

D-148 (Zig 0.16 self-hosted x86_64 Debug backend miscompile for
`callconv(.c)` 9-FP-scalar + MEMORY-class return) is filed at
[Codeberg ziglang/zig#35343](https://codeberg.org/ziglang/zig/issues/35343).
Workaround in `build.zig` (`.use_llvm = true` on the non-simd
spec_assert runner exe; commit `a8474d1a`); minimal Zig-only
repro at `private/spikes/d148-zig-sysv-fp-args/`. Removal
condition: upstream fix lands → drop the override.

### Discipline reminders

No `--no-verify`. 2-host per chunk (Mac + ubuntunote);
windowsmini reconcile stays at §9.13-0 (post-§9.12).

### Outstanding `now` debts (after §9.9 close)

- D-079: v128 cross-module imports (barrier dissolved per
  ADR-0065; needs discharge attempt next resume).
- D-102 / D-103 / D-105: cross-module data/elem/memory imports
  (barrier dissolved at §9.9-III; discharge via Cat III code).
- D-133: arm64 op_table / op_memory hardcoded X10/X11/X12
  scratch sweep.
- D-149: ADR Phase-9 cohort SHA backfill (75 `<backfill>`
  placeholders across decisions/0003..0069; per audit §F.7).
- D-148: blocked-by upstream Zig fix; workaround in place.
- §9.13-0 cohort: D-084 / D-028 / D-136 (windowsmini SEH).

## Sandbox + References

`~/.cache/zig` → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
Per-chunk 2-host; windowsmini at §9.13-0.

PRIMARY: [`phase9_completion_substrate_audit.md`](phase9_completion_substrate_audit.md)
(§9.12 hard gate). Close plan:
[`phase9_close_plan.md`](phase9_close_plan.md) §6 Step (f) /
(g) (post-§9.12 sequencing).
ADRs: [`0062`](decisions/0062_phase9_completion_substrate_audit.md)
(gate doc anchor), [`0026`](decisions/0026_x86_64_runtime_invariant_strategy.md)
(Convention Swap), [`0069`](decisions/0069_multi_result_return_abi.md)
(multi-result ABI), [`0065`](decisions/0065_wasm_1_0_instance_work_phase9_rescope.md)
(Cat III absorption).
Audit: `private/audit-2026-05-18.md` (Phase-9 boundary findings).
