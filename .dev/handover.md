# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10` — last code commit: `d641dcd8`
   (dispatcher distinguishes UnsupportedOpForBuildLevel vs
   NotMigrated; §9.12-G Phase 10 comptime-reject infra).
2. **Live status** (when uncertain):
   `bash scripts/p9_completion_status.sh` —
   `bash scripts/check_skip_impl_ratchet.sh --report` —
   `bash scripts/check_skip_taxonomy_pairing.sh` —
   expected: gated_total stable; 0 block findings; 4 testsuites
   green Mac aarch64.
3. ROADMAP §9 Phase Status widget: Phase 9 IN-PROGRESS。
   §9.12-A〜E `[x]`、次 `[ ]` は **§9.12-F** (Phase-9-eligible
   debt cohort)。

## Active state

- **§9.12-E [x]** at `7b2e1b02` Mac aarch64 (`b11314ff` code +
  `ba203d91` ROADMAP flip).
- **ADR-0079 fully closed** (`166cb319` + `c3e391f9`):
  runner.zig 2051 → 397 LOC across 3 files.
- **ADR-0078 paired follow-ups fully closed**:
  - part 1 (per-class ratchet) at `51b231ed`.
  - part 2 (taxonomy audit gate) at `bae4b975`.
  - §G.1.2 paired-artifact resolution gate at `2e8f0f22`.
    Surfaces 6 drift findings (4 closed-D-NNN citations + 1
    placeholder + 1 debt-trackable without D-NNN) — addressed
    at next ADR-0078 amendment cycle alongside user Accept.
- **§9.12-G partial** (`39f1dc15` + `d641dcd8`): Wasm 3.0 ZirOp
  mapping doc, include/wasm.h byte-identical, zone_check --gate
  enforced, **dispatcher emits UnsupportedOpForBuildLevel for
  build-filtered ops** (Phase 10 comptime-reject infra; DCE-safe).
  Remaining: Phase 10 ZirOp tags in `src/ir/zir.zig` (GC / EH /
  tail-call / memory64 / multi-memory / typed func refs); per-op
  files in `src/instruction/wasm_3_0/<feature>_<op>.zig` with
  `wasm_level: .v3_0`; c_api Instance tests (D-139 blocked).
- **§9.12-F partial** (active debt 23; "< 15" target needs
  multi-cycle): Dissolved-barrier closures so far: D-149/153/
  154/156/102/103/105/155 (across `3ace7fb4` + `129c66c5` +
  `51b231ed`). Remaining 23 split into speculative-preventive
  (D-090/094/062), multi-cycle architectural (D-141/081/055),
  external blocker (D-010/021/028/148), Phase-future-row
  blocked (~12 rows).

## Next-cycle candidates (high-yield only)

- **batch-session work** (not single-autonomous-cycle):
  - §9.12-H bench baseline (Mac Wasm 2.0 + wasmtime × 26
    fixtures × hyperfine).
  - D-141 per-file ADRs (validator.zig 1790 / dispatch_
    collector 1887 / regalloc 1851 / inst.zig × 2 archs / …).
- **autonomous-cycle-eligible**:
  - §9.12-G CLI `--invoke` mode (prerequisite for Phase 11
    bench; per ROADMAP §9.12-G).
  - §9.12-G `src/api/instance.zig` (1424 LOC) health +
    helper extraction.
  - ADR-0078 amendment cycle (apply the 6 G.1.2 drift findings:
    cite discharge SHAs for D-008 / D-152 / D-153; resolve the
    "D-NNN follow-up" placeholder for SKIP-NO-LINK-TYPECHECK;
    add per-fixture D-NNN to SKIP-EXPORTS).

Loop has reached equilibrium for single-cycle-tractable work;
remaining items need batch-session or multi-cycle architectural
focus.

## Open questions / blockers

- なし。autonomous loop resumed.

## See

- [ROADMAP](./ROADMAP.md) §9.12 — next `[ ]` = §9.12-F.
- [`debt.md`](./debt.md) — 23 active rows.
- [`phase9_structural_debt_close_plan.md`](./phase9_structural_debt_close_plan.md)
  — CLOSED 2026-05-21.
- [`lessons/INDEX.md`](./lessons/INDEX.md).
