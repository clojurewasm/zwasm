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
   sub-gate。emit.zig 9-module split は item 16 full の後段。
4. `.dev/decisions/0019_x86_64_in_phase7.md` — Phase 7 covers ARM64
   + x86_64 baseline.
5. `.dev/decisions/0017_jit_runtime_abi.md` — JitRuntime ABI.
6. `.dev/decisions/0018_regalloc_reserved_set_and_spill.md`.
7. `.dev/decisions/0020_edge_case_test_culture.md`.
8. `.dev/decisions/0022_post_session_retrospective.md` — regret triage 記録。
9. `.dev/debt.md` — discharge `Status: now` rows before active task.
10. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.5e IN-PROGRESS (most relocation done)

- **Active task**: §9.7 / 7.5e の最終仕上げ — ADR-0023 §7 18 項目
  のうち、構造 relocation は items 1-17 完了。残るのは
  **item 18 sweep** + **item 5 full** (instantiateRuntime move) +
  **item 8 full** (interp/ → instruction/ relocation) +
  **item 16 full** (~128 byte-offset relativise)。
- **Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
- **Branch**: `zwasm-from-scratch`、最新は `15c51f4` (item 7 DONE)。

## ADR-0023 §7 implementation progress

| #  | Item                                                              | Status            |
|----|-------------------------------------------------------------------|-------------------|
| 1  | Land ADR + ROADMAP amendments                                     | DONE (6752a/ed06) |
| 2  | runtime/{diagnostic, jit_abi} eviction                            | DONE (653ab43)    |
| 3  | runtime/runtime.zig (Runtime extract from interp/mod.zig)         | DONE (f7b739d)    |
| 4a | runtime/{value, trap, frame}.zig sub-split                        | DONE (d5f275a)    |
| 4b | runtime/module.zig (extract from frontend/parser.zig)             | DONE (f6a4686)    |
| 4cd| runtime/{engine, store}.zig (Engine/Store/Zombie)                 | DONE (f16e5e7)    |
| 5  | runtime/instance/instance.zig (Instance + ExportType skeleton)    | **partial** (52209e5) — full instantiateRuntime move pending |
| 6  | runtime/instance/{table, func, memory, global, element, data}.zig | DONE (6e9dc7b)    |
| 7  | parse/, validate/, ir/{lower, analysis/} from frontend/ + ir/     | DONE (15c51f4)    |
| 8  | instruction/{wasm_1_0, wasm_2_0, wasm_3_0}/ skeleton              | **partial** (351475d) — full opcode-handler relocation pending |
| 9  | feature/ skeleton (6 active + 3 reserved)                         | DONE (b6043f4)    |
| 10 | engine/{runner, interp/, codegen/{shared, arm64, x86_64, aot}/}   | DONE (9a8cf6b)    |
| 11 | api/ from c_api/                                                  | DONE (e619d17)    |
| 12 | cli/ subcommand placeholders (compile/validate/inspect/...)       | DONE (6d19bd0)    |
| 13 | wasi/preview1.zig rename                                          | DONE (01e253d)    |
| 14 | platform/ (signal, fs, time slots)                                | DONE (01e253d)    |
| 15 | util/ → support/ relocate                                         | DONE (5560a6a)    |
| 16 | engine/codegen/arm64/ from jit_arm64/                             | **partial** (9a8cf6b) — ~128 byte-offset relativise pending |
| 17 | ADR-0017/0018/0019/0021 path citations                            | DONE (68d56f5)    |
| 18 | zone_check.sh / zone_deps.md final-shape sweep + dead-path cleanup| pending           |

## Pending sub-tasks (within ADR-0023 §7)

1. **item 18 sweep**: dead-path cleanup in zone_check.sh / zone_deps.md
   (remove `src/jit/`, `src/jit_arm64/`, `src/jit_x86/`, `src/util/`,
   `src/c_api/` etc from path classifications); final ROADMAP §A1 /
   §A3 path-string sync.
2. **item 5 full**: move `instantiateRuntime` (~720 LOC) + helpers
   (evalConstI32Expr, validateNoCode, checkImportTypeMatches, etc.)
   from `api/instance.zig` to `runtime/instance/instance.zig`. The
   binding-handle remains in `api/instance.zig`. This discharges the
   `c_api/instance.zig` 2216 LOC §A2 violation.
3. **item 8 full**: relocate `interp/{mvp, mvp_int, mvp_float,
   mvp_conversions, memory_ops}.zig` + `interp/ext_2_0/*` into the
   `instruction/wasm_X_Y/` skeleton.
4. **item 16 full**: relativise the remaining ~128 byte-offset test
   sites in `engine/codegen/arm64/emit.zig` via the
   `engine/codegen/arm64/prologue.zig` helper (per
   `.claude/rules/edge_case_testing.md`).

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4008 LOC は item 16 full → 7.5d sub-b でもう一段 split。
- api/instance.zig 2216 LOC §A2 violation — item 5 full で discharge。

## Recently closed (per `git log --oneline -25`)

- ADR-0023 §7 items 1-17 (構造 relocation の主体) DONE。
- pre-existing zone violation in `platform/jit_mem.zig:99`
  discharged inline → 8b0caaf。
