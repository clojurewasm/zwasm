# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0023_src_directory_structure_normalization.md` —
   src/ 構造の最終形と命名規約。実装順は §7 を参照。
3. `.dev/decisions/0021_phase7_emit_split_gate.md` — §9.7 / 7.5d
   sub-gate。emit.zig 分割は ADR-0023 完了後に新パス
   `engine/codegen/arm64/` 上で実施。
4. `.dev/decisions/0019_x86_64_in_phase7.md` — Phase 7 covers ARM64
   + x86_64 baseline; Phase 8 redefined as optimisation foundation.
5. `.dev/decisions/0017_jit_runtime_abi.md` — JitRuntime ABI.
6. `.dev/decisions/0018_regalloc_reserved_set_and_spill.md`.
7. `.dev/decisions/0020_edge_case_test_culture.md`.
8. `.dev/decisions/0022_post_session_retrospective.md` — regret triage 記録。
9. `.dev/debt.md` — discharge `Status: now` rows before active task.
10. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.5e IN-PROGRESS

- **Active task**: **§9.7 / 7.5e** — `src/` directory structure
  normalization per ADR-0023 (§7 の 18 項目を順次実行中)。
- **Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
- **Branch**: `zwasm-from-scratch`、最新は `653ab43` (item 2 DONE)。

## ADR-0023 §7 implementation progress

| # | Item                                                                               | Commit              | Status     |
|---|------------------------------------------------------------------------------------|---------------------|------------|
| 1 | Land ADR + ROADMAP amendments                                                      | 6752ab0 + ed06937   | DONE       |
| 2 | Evict legacy runtime/* (diagnostic + jit_abi)                                      | 653ab43             | DONE       |
| 3 | Create runtime/runtime.zig (extract Runtime from interp/mod.zig)                   | —                   | **NEXT**   |
| 4 | Create runtime/{module, value, trap, frame, engine, store}.zig                     | —                   | pending    |
| 5 | Split c_api/instance.zig 2216 LOC → runtime/instance/instance.zig                  | —                   | pending    |
| 6 | Create runtime/instance/{memory, table, global, func, element, data}.zig          | —                   | pending    |
| 7 | Create parse/, validate/, ir/analysis/ from frontend/                              | —                   | pending    |
| 8 | Create instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/                                 | —                   | pending    |
| 9 | Create feature/ skeleton (6 active + 3 reserved)                                  | —                   | pending    |
| 10| Create engine/{runner, interp, codegen/{shared, arm64, x86_64, aot}}/             | —                   | pending    |
| 11| Create api/ from c_api/                                                            | —                   | pending    |
| 12| Reorganise cli/ + add placeholder slots (Phase 11/12)                             | —                   | pending    |
| 13| Rename wasi/p1.zig → wasi/preview1.zig                                             | —                   | pending    |
| 14| Extend platform/ (signal, fs, time slots)                                          | —                   | pending    |
| 15| Establish diagnostic/ + support/ (util/* relocate)                                 | —                   | pending    |
| 16| mv jit_arm64/* → engine/codegen/arm64/ + relativise ~128 byte-offset test sites    | —                   | pending    |
| 17| Sync handover.md + path citations in ADR-0017/0018/0019/0021                       | —                   | pending    |
| 18| Sweep stale references + zone_check.sh / zone_deps.md final shape update           | —                   | pending    |

各 commit ごとに 3-host gate (Mac + OrbStack + windowsmini SSH) を通過。
big-bang 厳禁。zone_check.sh / file_size_check.sh / zone_deps.md は
進捗に応じて段階的に追従(item 18 で最終整合)。

## Active plan — implementation cycles

| # | Step | ADR | Status |
|---|------|-----|--------|
| 1 | regalloc pool + first-class spill | 0018 | DONE |
| 2 | JitRuntime struct + ABI | 0017 | DONE |
| 3 | Edge-case test culture | 0020 | DONE |
| 4 | §9.7 / 7.5 spec testsuite via ARM64 JIT | — | 7.5a..7.5c-vi DONE; 7.5d sub-a PARTIAL |
| 5 | **§9.7 / 7.5e — src/ structural normalization (ADR-0023)** | **0023** | **IN-PROGRESS — item 2/18 DONE** |
| 6 | §9.7 / 7.5d sub-b — emit.zig 9-module split | 0021 | After 7.5e |
| 7 | §9.7 / 7.6 + 7.7 + 7.8: x86_64 reg_class/abi + emit + spec gate | 0019 | After 7.5d sub-b |
| 8 | §9.7 / 7.9–7.12: realworld + three-way differential + audit | — | After Step 7 |

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4008 LOC 状態は item 16 の mv まで継続、7.5d sub-b で content-split discharge。
- c_api/instance.zig 2216 LOC §A2 違反 — item 5 で discharge。
- 3-host JIT asymmetry — Step 7 dissolves via ADR-0019。

## Recently closed (per `git log`)

- ADR-0023 item 1 (land + ROADMAP amends) → 6752ab0 + ed06937。
- ADR-0023 item 2 (runtime/diagnostic + jit_abi mv) → 653ab43。
- pre-existing zone violation in `platform/jit_mem.zig:99`
  discharged inline (test-only import moved into test body) → 8b0caaf。
- ADR-0021 sub-gate; `prologue.zig` helper + 4 demo sites; ADR-0022 retrospective。
