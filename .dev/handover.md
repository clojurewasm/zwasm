# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.7 row — Phase 9 active.
3. `.dev/debt.md` — D-055 / D-057 + 10 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, x86_64 SSE/SSE4.1/SSE4.2, ADR-0041 §5).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline post-9.7-m
   amendment).

## Current state — Phase 9 / §9.9 in-flight; **9.9-d-7 NEXT — investigate residual 21 simd_address value-mismatches + 3 simd_align ExportNotFound runner gap**

9.9-e-2 (`11a32364`): x86_64 v128 frame layout + param marshal +
local.get/set/tee handlers + 4 new MOVUPS RBP-disp encoders.
Mirrors 9.9-e-1 ARM64 shape: `LocalLayout` group-by-type
strategy C; SysV v128 in XMM0..XMM7 → `MOVUPS [RBP+disp_v128]`;
Win64 v128 stays UnsupportedOp (passed by hidden pointer per
Microsoft x64 ABI). v128 stack-arg overflow (fp_arg_idx ≥ 8)
surfaces UnsupportedOp pending follow-up.

**Mac aarch64 simd_assert_runner totals after 9.9-e-2**:
227 / 36 / 292 — same as 9.9-e-1 (Mac aarch64 doesn't directly
exercise x86_64 emit). OrbStack Linux x86_64 has access to v128
emit but no x86_64-specific spec runner is wired into test-all
yet (§9.9-g target).

Residual 36 fails on Mac aarch64 (same shape as 9.9-e-1):
- 21 value-mismatch (`got v128`) — defer to 9.9-d-7 audit.
- 3 simd_align ExportNotFound (runner-side gap; fixtures now
  compile but runner doesn't map the export name correctly).
- 3 simd_const compile (BadBlockType + BadValType +
  NotImplemented — separate validator/lower gaps).
- The remaining 9 cluster around assert_invalid / assert_trap
  shapes the runner partially supports.

**Next — 9.9-d-7**: investigate the 21 simd_address value-
mismatch FAILs. They all show `got v128:000...0` (zero vector)
when expected is `16171819...` (data-segment bytes). Either the
data-segment init isn't running for the runner-injected modules
OR the JIT prologue routes args through the wrong cell when
shape is `(i32) → v128`. Spike via `debug_jit_auto` skill
recipes; outcome could be a runner-side fix (data-segment
wiring) OR a JIT-side fix (param/result interaction). Also
investigate the 3 simd_align ExportNotFound — likely runner
export-name mapping for `align=N` suffixes.

Subsequent §9.9 chunks per ADR-0045:
- 9.9-f: scale to FP arith + compares (heavy 9k+ files).
- 9.9-g: aggregate `test-spec-simd` into `test-all`; flip §9.9 [x].
- v128 stack-arg overflow (SysV fp_arg_idx ≥ 8 + Win64 v128
  by-hidden-pointer) — track as a debt row at chunk close.

After §9.9: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- **D-057** (op_simd.zig hard-cap, now ~4442 LOC) — blocked-by
  ADR for source-split landing. Discharge requires ADR mirror
  of ADR-0030; deferred until §9.7 row close.
- 10 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/
  D-022/D-026/D-028/D-052 — barriers all hold this resume.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15)
live in git: ADRs 0035-0040, lessons in `.dev/lessons/INDEX.md`,
code in `src/ir/coalesce/`, regalloc.zig LIFO free-pool,
`src/engine/codegen/aot/`. `git log` is authoritative.

**Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline).
§9.5 [x] (ARM64 NEON pt 1), §9.6 [x] (ARM64 NEON pt 2),
§9.7 [x] (x86_64 SSE4.1+SSE4.2; 9.7-a..bb landed),
§9.8 [x] (scope absorbed per ADR-0044),
§9.9 in-flight (9.9-a..c + 9.9-d-1..6 + 9.9-e-1 + 9.9-e-2
landed; 9.9-d-7 NEXT — residual value-mismatch + ExportNotFound
investigation).
**Branch**: `zwasm-from-scratch`。
