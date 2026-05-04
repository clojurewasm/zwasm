# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0023_src_directory_structure_normalization.md` —
   src/ 構造の最終形と命名規約。**次セッションの最初の active task**
   (§9.7 / 7.5e) はここから読む。実装順は §7 を参照。
3. `.dev/decisions/0021_phase7_emit_split_gate.md` — §9.7 / 7.5d
   sub-gate。emit.zig 分割は ADR-0023 完了後に新パス
   `engine/codegen/arm64/` 上で実施。
4. `.dev/decisions/0019_x86_64_in_phase7.md` — Phase 7 covers ARM64
   + x86_64 baseline; Phase 8 redefined as optimisation foundation.
5. `.dev/decisions/0017_jit_runtime_abi.md` — JitRuntime ABI.
6. `.dev/decisions/0018_regalloc_reserved_set_and_spill.md`.
7. `.dev/decisions/0020_edge_case_test_culture.md`.
8. `.dev/decisions/0022_post_session_retrospective.md` — regret triage 記録。
9. `.claude/skills/meta_audit/SKILL.md` — 周期的メタ監査 skill。
10. `.dev/debt.md` — discharge `Status: now` rows before active task.
11. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 IN-PROGRESS

- **Active task**: **§9.7 / 7.5e** — `src/` directory structure
  normalization per ADR-0023. **Hard gate before 7.5d sub-b
  (emit.zig 9-module split)**, which will land on the new path
  `engine/codegen/arm64/` produced by 7.5e.
- **Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
- **Branch**: `zwasm-from-scratch`、最新は ADR-0023 ランディング後の
  state (next session で確認)。

## Active plan — implementation cycles

| # | Step | ADR | Status |
|---|------|-----|--------|
| 1 | regalloc pool + first-class spill | 0018 | **DONE** |
| 2 | JitRuntime struct + ABI | 0017 | **DONE** |
| 3 | Edge-case test culture | 0020 | **DONE** |
| 4 | §9.7 / 7.5 spec testsuite via ARM64 JIT | — | 7.5a..7.5c-vi DONE; 7.5d sub-a PARTIAL (`prologue.zig` helper + 4 demo sites). Bulk migration deferred to 7.5e (per ADR-0023 §7) |
| 5 | **§9.7 / 7.5e — src/ structural normalization (ADR-0023)** | **0023** | **NEXT — active task**。実装順は ADR-0023 §7 の 18 項目。各 commit ごとに 3-host gate |
| 6 | §9.7 / 7.5d sub-b — emit.zig 9-module split | 0021 | After 7.5e。新パス `engine/codegen/arm64/` 上で実施 |
| 7 | §9.7 / 7.6 + 7.7 + 7.8: x86_64 reg_class/abi + emit + spec gate | 0019 | After 7.5d sub-b (HARD GATE per ADR-0021) |
| 8 | §9.7 / 7.9–7.12: realworld + three-way differential + audit | — | After Step 7 |

## Implementation notes for the next cycle (Step 5 = ADR-0023)

実装順は ADR-0023 §7 の 18 項目に従う。要点:

- 1 項目 = 1 commit ではない、依存順は固定だが粒度は実施判断
- 各 commit ごとに 3-host gate (Mac + OrbStack + windowsmini SSH)
  通過。big-bang 厳禁
- 重い項目: c_api/instance.zig 2216 LOC 分割 (item 5)、`runtime/`
  全面再構成 (items 2-6)、`engine/` 新設 (item 10)、`api/` rename
  (item 11)
- 最後に emit.zig を新パスへ単純 mv (item 16 の前段)
- ROADMAP §4.1 / §4.3 / §4.4 / §4.5 / §4.7 / §4.10 / §5 / §A2 は
  ADR-0023 ランディング commit で同期済 (再編集不要)
- 関連 ADR (0017 / 0018 / 0019 / 0021) の path citation 更新は item 17

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4008 LOC 状態は 7.5e 中も継続、7.5d sub-b で discharge。
- c_api/instance.zig 2216 LOC §A2 違反 — 7.5e で discharge (ADR-0023 §7 item 5)。
- 3-host JIT asymmetry — Step 7 dissolves via ADR-0019。

## Recently closed (per `git log`)

- §9.7 / 7.3 op coverage (111 ops)、7.4a/b/c JIT runtime infra。
- ADRs 0017 / 0018 / 0019 / 0020 drafted + accepted。
- ADR-0021 sub-gate inserted; `prologue.zig` helper + 4 demo sites。
- ADR-0022 retrospective recorded。
- **ADR-0023 src/ structural normalization** accepted; ROADMAP §4.1/§4.3/§4.4/§4.5/§4.7/§4.10/§5/§A2 amended in same commit。
