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
   sub-gate (emit.zig 9-module split は item 16 full 後段)。
4. `.dev/decisions/0019_x86_64_in_phase7.md`.
5. `.dev/decisions/0017_jit_runtime_abi.md`.
6. `.dev/decisions/0018_regalloc_reserved_set_and_spill.md`.
7. `.dev/decisions/0020_edge_case_test_culture.md`.
8. `.dev/decisions/0022_post_session_retrospective.md`.
9. `.dev/debt.md` — discharge `Status: now` rows before active task.
10. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.5e structural relocation DONE; refinement pending

ADR-0023 §7 の 18 項目のうち、**ディレクトリ構造の relocation は
完了** (items 1-15, 17, 18-sweep)。残る 3 つは "後段 refinement" で、
ADR-0023 が要求する **構造的 normalization** は満たされている:

- **item 5 full**: `api/instance.zig` 2216 LOC 内の
  `instantiateRuntime` (~720 LOC) と関連 helper を
  `runtime/instance/instance.zig` へ機能移動。今は Instance struct
  + ExportType のみ移動済み (skeleton)。§A2 hard-cap discharge は
  この commit で完了する。
- **item 8 full**: `interp/{mvp, mvp_int, mvp_float,
  mvp_conversions, memory_ops}.zig` + `interp/ext_2_0/*` を
  `instruction/wasm_X_Y/` へ relocate。今は skeleton のみ作成済み。
- **item 16 full**: `engine/codegen/arm64/emit.zig` 内の ~118
  hardcoded byte-offset test sites を `prologue.body_start_offset()`
  経由に書き換え。helper は配置済み + 4 demo sites + 新ルール
  `edge_case_testing.md "Test-side byte offsets must be relative"`
  により新サイトは強制済み。残るのは bulk migration。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は `6f161b9` (item 18 sweep)。

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
| 8  | instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/ skeleton              | **partial** (351475d); opcode-handler relocation pending |
| 9  | feature/ skeleton (6 active + 3 reserved)                         | DONE (b6043f4)        |
| 10 | engine/{runner, interp/, codegen/{shared, arm64, x86_64, aot}/}   | DONE (9a8cf6b)        |
| 11 | api/ from c_api/                                                  | DONE (e619d17)        |
| 12 | cli/ subcommand placeholders                                      | DONE (6d19bd0)        |
| 13 | wasi/preview1.zig rename                                          | DONE (01e253d)        |
| 14 | platform/ (signal, fs, time slots)                                | DONE (01e253d)        |
| 15 | util/ → support/ relocate                                         | DONE (5560a6a)        |
| 16 | engine/codegen/arm64/ from jit_arm64/                             | **partial** (9a8cf6b); ~118 byte-offset relativise pending |
| 17 | ADR-0017/0018/0019/0021 path citations                            | DONE (68d56f5)        |
| 18 | zone_check.sh / zone_deps.md / CLAUDE.md sweep                    | DONE (6f161b9)        |

## Pending sub-tasks (within ADR-0023 §7)

これらは **構造的 normalization 完了後の content refinement**。
任意順で着手可能。各 commit ごとに 3-host gate (Mac + OrbStack +
windowsmini) を通すこと:

1. **item 16 full** (機械的、最低リスク): emit.zig 内の ~118
   hardcoded `out.bytes[N..M]` test site を
   `prologue.body_start_offset(has_frame)` 経由に書き換え。
   `.claude/rules/edge_case_testing.md` "Test-side byte offsets
   must be relative" 参照。site ごとに has_frame の判断が必要。
2. **item 5 full** (大規模): `api/instance.zig` の
   `instantiateRuntime` + helpers を `runtime/instance/instance.zig`
   へ移動。binding-handle (Module extern struct, Func struct, Val,
   Extern, etc.) は `api/wasm.zig` (or `api/instance.zig` 残置)。
   c_api/instance.zig 2216 LOC §A2 violation discharge。
3. **item 8 full** (中規模): `interp/{mvp*, memory_ops}.zig` +
   `interp/ext_2_0/*` を `instruction/wasm_X_Y/` 配下へ relocate。
   importer (mvp, dispatch, ext_2_0 sibling 等) の path 更新。
   Wasm 1.0 ops の category 分割 (mvp.zig → control + parametric +
   variable) は分割後の改めての design 判断必要。
4. **§9.7 / 7.5d sub-b** (ADR-0021): emit.zig 9-module split。
   item 16 full 完了後、新パス `engine/codegen/arm64/` 上で実施。

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4008 LOC は item 16 full → 7.5d sub-b でもう一段 split。
- api/instance.zig 2216 LOC §A2 violation — item 5 full で discharge。

## Recently closed (per `git log --oneline -25`)

- ADR-0023 §7 items 1-15, 17, 18-sweep DONE — 19 commits across
  this autonomous run。
- pre-existing zone violation in `platform/jit_mem.zig:99`
  discharged inline → 8b0caaf。
