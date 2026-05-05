# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0023_src_directory_structure_normalization.md` —
   src/ 構造の最終形と命名規約。実装順は §7。
3. `.dev/decisions/0021_phase7_emit_split_gate.md` — emit.zig
   9-module split は item 16 full の後。
4. `.dev/decisions/0019_x86_64_in_phase7.md` / 0017 / 0018 / 0020 / 0022.
5. `.dev/debt.md` — discharge `Status: now` rows.
6. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.5e structural relocation DONE

ADR-0023 §7 の 18 項目のうち、**ディレクトリ構造の relocation
+ opcode-handler relocation は完了** (items 1-15, 17, 18-sweep, 8-full)。
残る大規模 refinement 2 つは別セッションで:

- **item 5 full**: `api/instance.zig` 内の `instantiateRuntime`
  (~720 LOC) + helpers を `runtime/instance/instance.zig` へ機能
  移動。binding-handle 型 (Module extern struct, Func, Val,
  Extern) は `api/wasm.zig` (or 残置)。`Extern` を pointer 受け
  渡す部分は `?*anyopaque` 化が必要。§A2 hard-cap discharge は
  この作業で完了。
- **item 16 full**: `engine/codegen/arm64/emit.zig` 内の ~118
  hardcoded byte-offset test sites を
  `prologue.body_start_offset(has_frame)` 経由に書き換え。helper
  + 4 demo sites + 新ルール `edge_case_testing.md` 配置済み。
  各 site は has_frame の判断が必要 (一括 sed ではなく Edit 単位)。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は `98f9e51` (item 8 full)。

## ADR-0023 §7 implementation progress

| #  | Item                                                              | Status                |
|----|-------------------------------------------------------------------|-----------------------|
| 1  | Land ADR + ROADMAP amendments                                     | DONE (6752a/ed06)     |
| 2  | runtime/{diagnostic, jit_abi} eviction                            | DONE (653ab43)        |
| 3  | runtime/runtime.zig (Runtime extract from interp/mod.zig)         | DONE (f7b739d)        |
| 4  | runtime/{value, trap, frame, module, engine, store}.zig sub-split | DONE (d5f275a/f6a4686/f16e5e7) |
| 5  | runtime/instance/instance.zig — Instance + ExportType skeleton    | **partial** (52209e5); full instantiateRuntime move pending |
| 6  | runtime/instance/{table, func, memory, global, element, data}.zig | DONE (6e9dc7b)        |
| 7  | parse/, validate/, ir/{lower, analysis/} from frontend/ + ir/     | DONE (15c51f4)        |
| 8  | instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/ + opcode relocate     | DONE (351475d/98f9e51); mvp.zig content split deferred |
| 9  | feature/ skeleton (6 active + 3 reserved)                         | DONE (b6043f4)        |
| 10 | engine/{runner, interp/, codegen/{shared, arm64, x86_64, aot}/}   | DONE (9a8cf6b)        |
| 11 | api/ from c_api/                                                  | DONE (e619d17)        |
| 12 | cli/ subcommand placeholders                                      | DONE (6d19bd0)        |
| 13 | wasi/preview1.zig rename                                          | DONE (01e253d)        |
| 14 | platform/ (signal, fs, time slots)                                | DONE (01e253d)        |
| 15 | util/ → support/ relocate                                         | DONE (5560a6a)        |
| 16 | engine/codegen/arm64/ from jit_arm64/                             | **partial** (9a8cf6b); ~118 byte-offset relativise pending |
| 17 | ADR-0017/0018/0019/0021 path citations                            | DONE (68d56f5)        |
| 18 | zone_check.sh / zone_deps.md / CLAUDE.md sweep                    | DONE (6f161b9/98f9e51) |

## Pending sub-tasks (within ADR-0023 §7)

これらは **構造的 normalization 完了後の content refinement**。
任意順で着手可能。各 commit ごとに 3-host gate 必須:

1. **item 16 full** (機械的、リスク中): emit.zig 内の ~118
   hardcoded `out.bytes[N..M]` test site を
   `prologue.body_start_offset(has_frame)` 経由に書き換え。site
   ごとに has_frame の判断が必要(一括 sed ではなく site 単位)。
2. **item 5 full** (大規模、リスク高): `api/instance.zig` の
   `instantiateRuntime` + helpers (~720 LOC) を
   `runtime/instance/instance.zig` へ移動。binding-side
   `?*const Extern` を `?*const anyopaque` に widen して
   Zone 1 を維持。c_api/instance.zig 2216 LOC §A2 violation
   discharge。
3. **interp/mvp.zig content split** (item 8 follow-up): mvp.zig
   の中身 (control + parametric + variable opcodes 混在) を
   `instruction/wasm_1_0/{control, parametric, variable}.zig`
   の skeleton に分配。dispatch wiring の調整必要。
4. **§9.7 / 7.5d sub-b** (ADR-0021): emit.zig 9-module split。
   item 16 full 完了後に。

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4008 LOC は item 16 full → 7.5d sub-b でもう一段 split。
- api/instance.zig 2216 LOC §A2 violation — item 5 full で discharge。

## Recently closed (per `git log --oneline -25`)

- ADR-0023 §7 items 1-15, 17, 18-sweep, 8-full DONE — 21 commits
  across this autonomous run.
- pre-existing zone violation in `platform/jit_mem.zig:99`
  discharged inline → 8b0caaf。
