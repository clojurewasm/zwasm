# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0021_phase7_emit_split_gate.md` — emit.zig
   9-module split is now mid-flight.
3. `.dev/lessons/2026-05-04-emit-monolith-cost.md` — proposed
   split structure.
4. `.dev/decisions/0017_jit_runtime_abi.md` / 0018 / 0019 / 0023.
5. `.dev/debt.md` — discharge `Status: now` rows.
6. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.5d sub-b IN-PROGRESS

ADR-0023 §7 全 18 項目 完全達成、§9.7 / 7.5e DONE。Active task は
**§9.7 / 7.5d sub-b** — `engine/codegen/arm64/emit.zig` (4009 LOC)
を ≤ 9 modules に split。

1 サブステップ完了 (label.zig extraction、commit `beafdb8`)。
残る 7-8 サブステップは op handler の context-struct 設計が必要。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は `beafdb8`。

## §9.7 / 7.5d sub-b implementation plan

### 完了
- label.zig: `Label` / `LabelKind` / `Fixup` / `FixupKind` extract
  (commit beafdb8、emit.zig -14 LOC)。

### 次の階段(順序固定 — 依存方向に沿って積み上げ):

1. **EmitCtx struct** を emit.zig の compile() 内 local state を
   束ねる context として定義。fields:
   - `allocator: Allocator`
   - `buf: *std.ArrayList(u8)`
   - `f: *const ZirFunc`
   - `alloc: regalloc.Allocation`
   - `labels: *std.ArrayList(Label)`
   - `pushed_vregs: *std.ArrayList(u32)`
   - `func_sigs: []const FuncType`
   - `module_types: []const FuncType`
   - その他 (call_fixups, trap_fixups, etc.)

   compile() の inner-fn を method 化して `fn (ctx: *EmitCtx,
   instr: ZirInstr) Error!void` 形に整形。

2. **op_const.zig**: `i32.const`, `i64.const`, `f32.const`,
   `f64.const`, `ref.null` 系 handlers (~200 LOC)。

3. **op_alu.zig**: `i32/i64.{add, sub, mul, div_*, rem_*, and,
   or, xor, shl, shr_*, rotr, rotl}` + `i32/i64.{eq, ne, lt_*,
   gt_*, le_*, ge_*, eqz, clz, ctz, popcnt}` + `f32/f64.{add,
   sub, mul, div, abs, neg, sqrt, ceil, floor, trunc, nearest,
   min, max, copysign, eq, ne, lt, gt, le, ge}` (~1500 LOC).
   分割案: `op_alu_int.zig` + `op_alu_float.zig`。

4. **op_memory.zig**: `i32/i64/f32/f64.load*`, `i32/i64.store*`,
   `memory.size`, `memory.grow` (~600 LOC)。

5. **op_control.zig**: `block`, `loop`, `if`, `else`, `end`,
   `br`, `br_if`, `br_table`, `return`, `unreachable`, `nop`,
   `select` (D-027 merge logic 含む) (~700 LOC)。

6. **op_call.zig**: `call`, `call_indirect`, `local.{get,set,tee}`,
   `global.{get,set}`, `drop` (~400 LOC)。

7. **bounds_check.zig**: `emitTrunc32BoundsCheck`,
   `emitTrunc64BoundsCheck`, memory bounds (~150 LOC)。

8. **conversion**: `i32.wrap_i64`, `i64.extend_i32_*`,
   `*.{convert, demote, promote, trunc, trunc_sat,
   reinterpret}_*` — op_alu に同居 or 別 file。

各 sub-step は **3-host gate green** で commit + push。big-bang 厳禁。

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 4009 LOC は 7.5d sub-b で discharge 中。
- api/instance.zig soft-cap (>1000 LOC) — binding code はそのまま、
  §A2 soft-cap warn は受容(item 5 完了で hard-cap は通過)。

## Recently closed (per `git log --oneline -35`)

- ADR-0023 §7 18 items DONE (29 commits in this autonomous run)。
- §9.7 / 7.5e flipped `[x]`。
- 7.5d sub-b started: label.zig extracted。
