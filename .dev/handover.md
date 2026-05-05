# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0025_zig_library_surface.md` — Zig host
   API design (3-line happy path, 9 stable symbols).
3. `.dev/decisions/0024_module_graph_and_lib_root.md` — module
   graph (Ghostty + Bun pattern, single `core` module).
4. `.dev/decisions/0023_src_directory_structure_normalization.md`
   — directory shape (amended by ADR-0024 in Revision history).
5. `.dev/decisions/0021_phase7_emit_split_gate.md` — emit.zig
   9-module split (sub-deliverable b in progress).
6. `.dev/decisions/0019_x86_64_in_phase7.md` — x86_64 baseline
   (gated on 7.5d sub-b close).
7. `.dev/decisions/0017_jit_runtime_abi.md` / 0018 / 0020 / 0014.
8. `.dev/debt.md` — discharge `Status: now` rows.
9. `.dev/lessons/INDEX.md` — keyword-grep for active task domain.

## Current state — Phase 7 / §9.7 / 7.7 IN-PROGRESS

直近 commit:
- `12cd04c` §9.7 / 7.7-wrap — x86_64 i32.wrap_i64 + i64.extend_i32_s/u
  (encMovsxdR64R32 + emitConvertWidth, 7 new tests, 3-host green)
- `f55ddb9` #5 ADR-0027 implementation (i32 globals 両 backend)
- `5013ce5` #7 ADR-0028 M3-a-1 (trace ringbuffer infra)

**Active task**: 残り 7.7 chunks — 7.7-call (call/call_indirect)
が **NEXT**。完了後 7.7-fp (f32/f64 surface) → §9.7 / 7.8 spec
gate。M3-a-2 (trap stub からの ringbuffer write) と globals
i64/FP は post-7.7 chunk として queue。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は `12cd04c`。

## ADR-0025 implementation chain (Phase A done; B-D pending)

| Phase | Status | Notes |
|---|---|---|
| A — design + ROADMAP §10 sync | DONE (this commit) | self-reviewed, 8 issues addressed in Revision history row 2 |
| B-1 thin facade (Runtime/Module/Instance/invoke) | pending | post-7.5d sub-b |
| B-2 TypedFunc + getTyped | pending | depends on B-1 |
| B-3 WasiConfig + wasi/host.zig WasiStdio union | pending | requires WASI subsystem surface change |
| B-4 ImportEntry + cross-module wiring | pending | depends on `runtime/instance/import.zig` ImportBinding (already landed via ADR-0023 §7 item 5 Step A2) |
| B-5 examples/zig_host/* | pending | depends on B-1..B-4 |
| D docs/migration_v1_to_v2.md (Zig section) | pending | **before** Phase C per Issue 7 fix |
| C ClojureWasm v1 改修 | external repo | post Phase D ship |

ADR-0025 self-review captured 8 issues, all addressed in the
ADR's Revision history (cross-module `*Module` → `*Instance`,
zone placement of facade, "zero overhead" → "constant
overhead", error sets added to stable list, WASI host
prerequisite acknowledged, allocator back-ref pattern
documented, ImportBinding prereq stated, Phase C/D ordering
fixed).

## §9.7 / 7.6 + 7.7 chunk progress

| # | Chunk | Status |
|---|---|---|
| 7.6-a | reg_class.zig (Gpr + Xmm + Width) | DONE `739de07` |
| 7.6-b | inst.zig foundation (REX/ModR/M/SIB + 5 ops) | DONE `3c78b63` |
| 7.6-c | abi.zig SysV (arg/return/callee-saved + slotToReg) | DONE `344d393` |
| 7.7-skel | emit.zig skeleton (prologue + i32.const + end) + inst PUSH/POP/MOVImm32W | DONE `4956b9e` |
| 7.7-alu | i32 ALU op handlers (add/sub/mul/and/or/xor) | DONE `741a9b4` |
| 7.7-cmp | i32 compare 10 ops (eq..ge_u) via CMP+SETcc+MOVZX | DONE `126ce7e` |
| 7.7-eqz | i32.eqz (TEST+SETE+MOVZX, unary) | DONE `2c5d681` |
| 7.7-shift | i32 shifts 5 ops (CL constraint) | DONE `211a51f` |
| 7.7-bitcount | i32 clz/ctz/popcnt (LZCNT/TZCNT/POPCNT) | DONE `c62a3d7` |
| 7.7-locals | frame SUB/ADD RSP + local.get/.set/.tee (15 cap) | DONE `59ed705` |
| 7.7-control-skel | block/loop/br + emitEndIntra + JMP/Jcc rel32 + patchRel32 | DONE `75f88e6` |
| 7.7-control-if | if/else (+if_skip_byte +merge_top_vreg D-027) + br_if | DONE `c0ba23d` |
| 7.7-control-table | br_table (linear CMP+JNE-skip+JMP chain + tail) | DONE `46a6d9f` |
| 7.7-mem-load | i32.load + ADR-0026 prologue + bounds-check trap stub | DONE `c0711fb` |
| 7.7-mem-store | i32.store + 狭幅 load/store + emitMemOp 統合 refactor | DONE `7d37a5b` |
| 7.7-globals | global.get/.set (i32 only; i64/FP は別 chunk) | DONE `f55ddb9` |
| 7.7-wrap | i32.wrap_i64 / i64.extend_i32_s/u | DONE `12cd04c` |
| 7.7-call | call/call_indirect | **NEXT** |
| 7.7-fp | f32/f64 surface | pending |
| deferred-Win64 | Win64 ABI table + Cc enum | pending |

ADR-0019 phase plan post-7.6: 7.7 emit.zig, 7.8 spec gate (Linux
+ Windows hosts), 7.9/7.10 realworld, 7.11 3-way differential 🔒.
ADR-0021 Revision history row (sub-split + emit_test extraction)
deferred to phase boundary batch update.

各 sub-step は 3-host gate green で commit + push。

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 580 LOC: 7.5d sub-b 完全クローズ。inst.zig 1193 LOC
  soft-cap、emit_test.zig 1986 LOC soft-cap (test bulk; hard-cap内)。
- api/instance.zig soft-cap (>1000 LOC) — binding code はそのまま、
  hard-cap (2000) は Step A2 で discharge 済み。

## Recently closed (per `git log --oneline -45`)

- §9.7 / 7.7-wrap: x86_64 i32.wrap_i64 + i64.extend_i32_s/u
  (encMovsxdR64R32 + emitConvertWidth, mirrors arm64
  op_convert.zig); 3 inst byte tests + 4 emit compile tests;
  edge-case fixture deferred (private/notes/p7-edge-case-
  rationale.md, gated on D-031 i64-runner gap) (12cd04c)。
- 7-issue cleanup batch (2026-05-05, 4 commits):
  - `618ac14` ADR-0027 (#5 globals 設計) + ADR-0028 (#7 M3 trace 前倒し)
  - `fe42735` #1 spec-strict bounds (両 backend ea+size>limit + 2 trap fixtures
    + liveness.zig memory ops + D-031 runner制約 debt)
  - `afa3808` D-028 windowsmini ロギング (10 連 0 fail + WebSearch 確認)
  - `c58af89` #6 TODO marker + #2 D-029 ARM64 grep + #3 D-030 ADR-0023 mirror gap
- §9.7 / 7.7-mem-store: x86_64 i32.store + 狭幅 load/store + emitMemOp
  refactor (7d37a5b)。
- §9.7 / 7.7-mem-load: x86_64 i32.load + ADR-0026 prologue + bounds-check
  trap stub (c0711fb)。
- §9.7 / 7.7-control-{skel,if,table}: block/loop/br/if/else/br_if/br_table
  on x86_64 (75f88e6 / c0ba23d / 46a6d9f)。
- §9.7 / 7.7-locals/bitcount/shift/eqz/cmp/alu/skeleton: x86_64 i32 op
  surface 完備 (4956b9e..59ed705)。
- §9.7 / 7.6 a/b/c: x86_64 reg_class + inst foundation + abi
  (739de07 / 3c78b63 / 344d393)。
- §9.7 / 7.5d 完全クローズ (sub-b chunks 1-10) (48b9745)。
- ADR-0023 §7 18 items + ADR-0024 + ADR-0025 (Phase A) DONE。
- 詳細は `git log --grep='§9.<N> / N.M'` で取得可能。
