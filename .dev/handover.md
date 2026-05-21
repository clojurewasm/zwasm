# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -10` — last code commit: `1a008ee5`
   (ADR-0089 — lower_simd.zig extraction; lower.zig 1109 → 775
   LOC; ADR-0083 cross-file struct-method pattern applied;
   Accepted same cycle). Total D-141 closures: 10.
2. **User directive (2026-05-21)**: batch-session architectural
   mode.
3. **Live status**: `bash scripts/p9_completion_status.sh` —
   D-055 `Status: now`; D-081 blocked.

## Authorized next-session pickup (priority order — updated 2026-05-21)

1. **PRIMARY: remaining D-141 candidates need ADR-grade survey
   (not single-cycle mechanical)**:
   - **parse/sections.zig** (1556 LOC) — 16 structs + decode
     functions; per-section axis split — bigger refactor with
     7+ new files. Survey-first; ADR-grade design choice.
   - **api/instance.zig** (1431 LOC) — c_api Instance lifecycle;
     §9.12-G item.
   - **engine/compile.zig** (1225 LOC) — huge `pub fn compileWasm`
     spanning lines 29-903 (~875 LOC); needs ADR-grade
     extraction axis. Survey-first.
   - **regalloc.zig** (1851 LOC) — has methods + state; likely
     ADR-0083 pattern again.
2. **Subsequent D-141 candidates** (after #1 lands):
   - **arm64/emit.zig** (1630 LOC) — mirror of x86_64/emit.zig
     after ADR-0081; same shape likely applies.
   - **x86_64/inst.zig** (1328 LOC) — parallel of arm64; FP
     extraction may apply similarly.
   - **lower.zig** (1109 LOC) — `Lowerer = struct {...}`
     struct-method-heavy. Apply ADR-0083 pattern.
2. **D-055 discharge (independent)**. ~95 hardcoded byte-offset
   sites migrate; sentinel wire-up. Multi-cycle mechanical.
3. **§9.12-F debt-cohort walk** continues per Step 0.5.
4. **§9.12-G `src/api/instance.zig` split** (1424 LOC).
5. **§9.12-H bench baseline** (Mac Wasm 2.0 + wasmtime).
6. **§9.12-I ADR/lesson curation closure**.

## Active state (snapshot)

- **§9.12-A enforcement**: 9 items OK; `gate_commit` strict
  --gate for libc + fallback; `pre-push` 4 audit gates;
  §7.9 `feature_level_check.zig` (`2d6bd6ca`).
- **§9.12-E [x]** at `7b2e1b02`.
- **ADR-0078 fully load-bearing**: G.1.1 + G.1.2 + amendment;
  pre-push wired.
- **§9.12-G partial**: 41 Wasm 3.0 stubs across 6 cohorts;
  dispatcher comptime-reject; CLI --invoke. Discrete-opcode
  stub coverage structurally complete.
- **§9.12-F**: 24 debt rows; closed: D-149/153/154/156/102/103/
  105/155. 2026-05-21: ADR-0079/0081/0082/0083 all Accepted
  (runner.zig + emit_setup.zig + dispatch_collector_ops.zig +
  validator_simd.zig); D-141 slots closed for runner / x86_64
  emit / dispatch_collector / validator. D-055 `Status: now`;
  D-081 still blocked (ADR-0054 amendment path).
- **Lessons shaping per-file ADRs**: `emit-zig-survey-per-op-
  pattern-already-absorbed.md` (measurement-focused Step 0
  briefs) + `cross-file-struct-method-syntax-zig-0-16.md`
  (struct-method-heavy file pre-extraction checklist).

## Operational note for the batch-session loop

`/continue` resume Steps 0-7 still apply per cycle. Granularity
is `architectural` (per LOOP.md), not `emit`. Spike-first allowed
for design questions. Up to 3 cycles without measurable progress
before re-evaluating chunk shape. Cite ADR-0079/0081/0082/0083
shape precedents in commit bodies.

## Open questions / blockers

- なし。autonomous batch-session resumed at user direction.

## See

- [ROADMAP](./ROADMAP.md) §9.12 — F / G / H / I open.
- [`debt.md`](./debt.md) — 24 active rows.
- [`decisions/0083_validator_simd_extraction.md`](./decisions/0083_validator_simd_extraction.md)
  — struct-method-heavy extraction precedent.
- [`lessons/INDEX.md`](./lessons/INDEX.md).
