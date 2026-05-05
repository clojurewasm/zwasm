# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0023_src_directory_structure_normalization.md` —
   src/ 構造の最終形と命名規約。実装順は §7。
3. `.dev/decisions/0021_phase7_emit_split_gate.md`.
4. `.dev/decisions/0019_x86_64_in_phase7.md` / 0017 / 0018 / 0020 / 0022.
5. `.dev/debt.md` — discharge `Status: now` rows.
6. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.5e: §A2 hard-cap discharged

ADR-0023 §7 18 項目のうち、**16 完全達成 + 2 partial-but-major**。
Step A1 で `api/instance.zig` 2127 → 1797 LOC、§A2 hard-cap (2000)
violation を discharge 済み。残るのは設計確定済みの 2 sub-task:

- **Step A2** (instantiateRuntime + checkImportTypeMatches を
  runtime/instance/instantiate.zig に move): 設計 `ImportBinding`
  union を `runtime/instance/import.zig` に landing 済み。実装
  詳細は下記。
- **item 16 full** (~118 byte-offset relativise): 機械的だが
  各 site で has_frame 判断が必要。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は Step A1 + import.zig。

## ADR-0023 §7 implementation progress

| #  | Item                                                              | Status                |
|----|-------------------------------------------------------------------|-----------------------|
| 1  | Land ADR + ROADMAP amendments                                     | DONE (6752a/ed06)     |
| 2  | runtime/{diagnostic, jit_abi} eviction                            | DONE (653ab43)        |
| 3  | runtime/runtime.zig (Runtime extract from interp/mod.zig)         | DONE (f7b739d)        |
| 4  | runtime/{value, trap, frame, module, engine, store}.zig sub-split | DONE (d5f275a/f6a4686/f16e5e7) |
| 5  | runtime/instance/instance.zig + instantiate.zig (Step A1)         | **partial** (52209e5/b8c7e9d); Step A2 (instantiateRuntime move) pending |
| 6  | runtime/instance/{table, func, memory, global, element, data}.zig | DONE (6e9dc7b)        |
| 7  | parse/, validate/, ir/{lower, analysis/} from frontend/ + ir/     | DONE (15c51f4)        |
| 8  | instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/ + opcode relocate     | DONE (351475d/98f9e51) |
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

## Step A2 implementation plan (next session)

`ImportBinding` 設計は `src/runtime/instance/import.zig` に
landing 済み — 4 variants:
- `func: FuncImport` (HostCall + source_runtime + source_funcidx
  + signature pair)
- `table: TableImport` (TableInstance value-copy + descriptor pair)
- `memory: MemoryImport` (memory slice header + descriptor pair)
- `global: GlobalImport` (slot *Value + descriptor pair)

実装順:
1. `import.zig` を上記 4-variant 形に拡張(現在は単一 struct で
   placeholder)。すべての import variants が「runtime-side の
   wiring に必要な最小情報 + binding-side で行った type-check
   結果」を carry。
2. `api/instance.zig` に `externToBinding(*const Extern, ...)`
   helper を追加。WASI imports は store.wasi_host から thunk を
   pre-resolve、cross-module imports は CallCtx を arena に
   pre-allocate して FuncImport.host_call に詰める。
3. `runtime/instance/instantiate.zig` に `instantiateRuntime`
   + `checkImportTypeMatches` を追加。引数は `imports:
   ?[]const ImportBinding`。Extern / wasi.lookupWasiThunk /
   cross_module.CallCtx / dispatchTable() への参照を全削除。
4. `api/instance.zig` から両関数を削除、`wasm_instance_new`
   から `instantiate.instantiateRuntime(...)` を呼ぶ。
5. `api/instance.zig` 1797 LOC → ~1100 LOC が見込み(§A2 soft
   cap も解消)。

## item 16 full plan (autonomous safe)

`engine/codegen/arm64/emit.zig:2050+` の test sites を順番に:
- `slots.len == 0 && n_spill_bytes == 0` → has_frame = false
  (body_start = 32)、それ以外 has_frame = true (body_start = 36)
- `out.bytes[N..N+4]` の `N` を `body0 + (N - 32)` (or `N - 36`) で
  計算 → `out.bytes[body0+offset..body0+offset+4]` に書き換え
- 各 commit で 3-host gate

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4008 LOC は item 16 full → 7.5d sub-b でもう一段 split。
- api/instance.zig soft-cap (>1000 LOC) は Step A2 で discharge。

## Recently closed (per `git log --oneline -25`)

- ADR-0023 §7 items 1-15, 17, 18-sweep, 8-full, 5-Step-A1 DONE。
- Step A2 設計 `ImportBinding` を import.zig に landing。
