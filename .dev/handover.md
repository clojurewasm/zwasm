# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0021_phase7_emit_split_gate.md` — emit.zig
   9-module split (sub-deliverable b) is now the active task.
3. `.dev/decisions/0019_x86_64_in_phase7.md` — x86_64 lands after
   7.5d sub-b closes (HARD GATE per ADR-0021).
4. `.dev/decisions/0017_jit_runtime_abi.md` / 0018 / 0020 / 0023.
5. `.dev/debt.md` — discharge `Status: now` rows.
6. `.dev/lessons/INDEX.md` — keyword-grep for active task domain
   (`emit-monolith-cost` lesson is directly relevant).

## Current state — Phase 7 / §9.7 / 7.5d sub-b NEXT

ADR-0023 §7 全 18 項目 **完全達成** (commit `3111fb0`)。§9.7 / 7.5e
は `[x]` flip 済み。`api/instance.zig` 1797 → 1403 LOC で §A2
hard-cap discharge、emit.zig 119 byte-offset sites 全て
`prologue.body_start_offset()` 経由化。

**Active task**: §9.7 / 7.5d sub-b — `engine/codegen/arm64/emit.zig`
(4008 LOC) を ≤ 9 modules に split (orchestrator ≤ 1000 LOC、
各 module ≤ 400 LOC)。lesson `2026-05-04-emit-monolith-cost.md`
の提案 split: op_const / op_alu / op_memory / op_control /
op_call / bounds_check / inst (existing) / abi (existing) /
prologue (existing) / label (新規)。`src/engine/codegen/arm64/`
直下に各 op_*.zig ファイルを作成、emit.zig を orchestrator に
shrink。

**Hard gate**: 7.5d sub-b 完了まで 7.6 (x86_64) は開かない
(ADR-0021)。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は `3111fb0`。

## Recently closed (per `git log --oneline -30`)

- ADR-0023 §7 items 1-18 完全達成 (28 commits in this autonomous run)。
- §9.7 / 7.5e DONE — directory structure normalisation 完成。
- §A2 hard-cap discharged (api/instance.zig 2127 → 1403)。
- §A2 violation on emit.zig 4008 LOC は 7.5d sub-b で discharge 予定。

## §9.7 / 7.5d sub-b implementation plan

ADR-0021 + lesson `emit-monolith-cost` per:

1. **新規ファイル**: `engine/codegen/arm64/{op_const, op_alu,
   op_memory, op_control, op_call, bounds_check, label}.zig`。
2. **emit.zig** を orchestrator (ZirOp → handler dispatch) に
   shrink。各 op_*.zig は同 zone (Zone 2) の sibling。
3. 新 module 間の path 関係:
   - `emit.zig` → 各 `op_*.zig` を sibling import
   - `op_*.zig` → `inst.zig` / `abi.zig` / `regalloc.zig`
     (`../shared/regalloc.zig`) / `prologue.zig` / `label.zig`
     を sibling もしくは `../shared/X.zig`
4. 各 commit ごとに 3-host gate。big-bang 厳禁。op category
   ごと(e.g. op_const のみ抽出)で commit + verify。
5. 完了後、7.5d sub-b `[x]` flip → 7.6 (x86_64 reg_class +
   inst + abi) 解禁。

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4008 LOC は 7.5d sub-b で discharge。
- api/instance.zig soft-cap (>1000 LOC) — wasm_*_new/delete などの
  binding code はそのまま、§A2 soft-cap warning は受容(item 5
  完了で hard-cap は通過)。
