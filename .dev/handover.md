# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0024_module_graph_and_lib_root.md` — module
   graph design (Ghostty + Bun pattern); single `core` module
   shared across artifacts.
3. `.dev/decisions/0023_src_directory_structure_normalization.md`
   — directory shape (amended by ADR-0024 in Revision history).
4. `.dev/decisions/0021_phase7_emit_split_gate.md` — emit.zig
   9-module split (sub-deliverable b in progress).
5. `.dev/decisions/0019_x86_64_in_phase7.md` — Phase 7 x86_64
   baseline (gated on 7.5d sub-b close).
6. `.dev/decisions/0017_jit_runtime_abi.md` / 0018 / 0020.
7. `.dev/debt.md` — discharge `Status: now` rows.
8. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.5d sub-b IN-PROGRESS

ADR-0023 §7 全 18 項目 完全達成 + ADR-0024 (module graph) 完全達成。
全 gate green:
- Mac aarch64: `zig build test` / `test-all` / `test-c-api` /
  `lint --max-warnings 0` / `zone_check.sh --gate` /
  `run_bench.sh --quick` 全 pass
- OrbStack Ubuntu x86_64: `zig build test-all` green
- windowsmini SSH: `zig build test-all` green
- 747/747 unit tests + 39/55 realworld diff matched + spec /
  wasi / c-api 全 pass

**Active task**: §9.7 / 7.5d sub-b — `engine/codegen/arm64/
emit.zig` (4009 LOC) を ≤ 9 modules に split (orchestrator
≤ 1000 LOC、各 module ≤ 400 LOC)。1 サブステップ完了
(label.zig extraction、commit `beafdb8`)。残る 7-8 サブ
ステップは op handler の context-struct 設計が必要。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は ADR-0024 ランディング後。

## ADR-0024 implementation summary

- `src/zwasm.zig` 新規 = library root + zone re-export hub +
  test loader + comptime force-include for `pub export fn`
  symbols (subsumes the former `api/lib_export.zig`).
- `src/main.zig` → `src/cli/main.zig` (CLI exe entry lives in
  the cli zone, eliminates `_main` collision).
- `src/api/lib_export.zig` deleted.
- build.zig: single `core` Module rooted at `src/zwasm.zig`,
  `core.addImport("zwasm", core)` for self-import (Bun
  pattern), `lib_static.root_module = core`, exe's thin module
  imports `"zwasm"` by name (Ghostty pattern).
- `scripts/zone_check.sh`: `src/zwasm.zig` classified as `lib`
  (exempt from upward-import checks; library surface re-
  exports every zone by design).
- Test-runner callsites migrated to the new hierarchy
  (`zwasm.parse.parser` etc.) per ADR-0024 D-3.

## §9.7 / 7.5d sub-b implementation plan (next session)

実装順 (依存方向に積み上げ):

1. **EmitCtx struct** を emit.zig の compile() 内 local state を
   束ねる context として定義。fields: allocator / buf / f /
   alloc / labels / pushed_vregs / func_sigs / module_types /
   call_fixups / trap_fixups。compile() の inner-fn を method
   化して `fn (ctx: *EmitCtx, instr: ZirInstr) Error!void` 形に。
2. **op_const.zig**: `i32.const`, `i64.const`, `f32.const`,
   `f64.const`, `ref.null` (~200 LOC)。
3. **op_alu.zig** (or op_alu_int / op_alu_float に分割): i32/i64/
   f32/f64 ALU + cmps + clz/ctz/popcnt + min/max + copysign
   (~1500 LOC)。
4. **op_memory.zig**: load/store + memory.size/grow (~600 LOC)。
5. **op_control.zig**: block/loop/if/else/end/br/br_if/br_table/
   return/unreachable/nop/select + D-027 merge (~700 LOC)。
6. **op_call.zig**: call/call_indirect/local.*/global.*/drop
   (~400 LOC)。
7. **bounds_check.zig**: emitTrunc32/64BoundsCheck (~150 LOC)。

各 sub-step は **3-host gate green** で commit + push。big-bang
厳禁。

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4009 LOC は 7.5d sub-b で discharge 中。
- api/instance.zig soft-cap (>1000 LOC) — binding code はそのまま、
  hard-cap (2000) は Step A2 で discharge 済み。

## Recently closed (per `git log --oneline -40`)

- ADR-0023 §7 18 items + ADR-0024 module graph DONE。
- §9.7 / 7.5e [x] flipped。
- 7.5d sub-b: label.zig extracted (commit beafdb8)。
- §A2 hard-cap discharged: api/instance.zig 2127 → 1403。
- emit.zig 119 byte-offset sites relativised via prologue helper。
- All gates green (Mac test/test-all/lint/zone/bench + Linux + Windows)。
