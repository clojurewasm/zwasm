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

## Current state — Phase 7 / §9.7 / 7.5d sub-b IN-PROGRESS

emit.zig 9-module split が進行中。直近 commit `b663bf4`
(ctx.zig + gpr.zig + op_const.zig extract)。emit.zig 4009 →
3862 LOC。3-host gate green (Mac test/test-all/lint/zone +
OrbStack Ubuntu test-all + windowsmini test-all)。

**Active task**: §9.7 / 7.5d sub-b 続行。EmitCtx の最初の
consumer が op_const.zig として landed。次は op_alu.zig
(~1500 LOC、最大塊) — int / float に分けるか単一かは extract
時に判断。

**Phase**: Phase 7 (ARM64 + x86_64 baseline、ADR-0019)。
**Branch**: `zwasm-from-scratch`、最新は b663bf4。

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

## §9.7 / 7.5d sub-b implementation plan (chunk progress)

| # | Chunk | LOC | Status |
|---|---|---|---|
| 1 | label.zig | ~65 | DONE `beafdb8` |
| 2 | ctx.zig (EmitCtx + Error + CallFixup) | ~95 | DONE `b663bf4` |
| 2 | gpr.zig (writeU32 + resolveGpr/Fp + spill helpers) | ~115 | DONE `b663bf4` |
| 2 | op_const.zig (i32.const + i64.const + emitConst*) | ~95 | DONE `b663bf4` |
| 3 | op_alu.zig (or op_alu_int / op_alu_float split) | ~1500 | **NEXT** |
| 4 | op_memory.zig | ~600 | pending |
| 5 | op_control.zig (incl. D-027 merge) | ~700 | pending |
| 6 | op_call.zig | ~400 | pending |
| 7 | bounds_check.zig | ~150 | pending |

各 sub-step は 3-host gate green で commit + push。

## Open structural debt

- **D-022** Diagnostic M3 / trace ringbuffer — Phase 7 close 後に再評価。
- **D-026** env-stub host-func wiring — cross-module dispatch。
- emit.zig 3862 LOC は 7.5d sub-b で discharge 中 (chunks 3-7
  remaining)。
- api/instance.zig soft-cap (>1000 LOC) — binding code はそのまま、
  hard-cap (2000) は Step A2 で discharge 済み。

## Recently closed (per `git log --oneline -45`)

- 7.5d sub-b chunk 2: ctx.zig + gpr.zig + op_const.zig extracted
  (b663bf4)。
- 7.5d sub-b chunk 1: label.zig extracted (beafdb8)。
- ADR-0023 §7 18 items + ADR-0024 + ADR-0025 (Phase A) DONE。
- §9.7 / 7.5e [x] flipped。
- ROADMAP §10 expanded with consumer-surface section per ADR-0025.
