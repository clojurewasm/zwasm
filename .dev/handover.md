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

## Current state — Phase 9 / §9.9 in-flight; **9.9-e-2 NEXT — x86_64 mirror of 9.9-e-1 (v128 frame layout + param marshal + local.get/set/tee handlers; new MOVUPS RBP-disp encoders required)**

9.9-e-1 (`95c065c5`): ARM64 v128 frame layout + param marshal +
local.get/set/tee handlers landed. New `LocalLayout` helper
(group-by-type strategy C: scalars 8-byte stride low region,
v128 16-byte stride high region; `local_base_off` rounded to 16
when v128 locals present). v128 param marshal per AAPCS64 §6.4 +
overflow per §6.4.2 stage C.4. v128 local.get/set/tee via
`qDefSpilled` / `qLoadSpilled` + `encLdrQImm` / `encStrQImm`.
Zero-init via two `STR XZR` per v128 declared local.

**Mac aarch64 simd_assert_runner totals after 9.9-e-1**:
226 → **227 PASS** / 36 → 36 FAIL / 296 → 292 SKIP. The 3
compile UnsupportedOps from 9.9-d-5/-6 (`simd_select.0`,
`simd_const.387`, `simd_align.90`) all flipped to PASS or
moved to runner-stage failures (3 simd_align ExportNotFound —
runner-side gap, not codegen).

Residual 36 fails:
- 21 value-mismatch (`got v128`) — defer to 9.9-d-7 audit.
- 3 simd_align ExportNotFound (runner-side gap; new exposure
  post-9.9-e-1 — fixtures now compile but runner doesn't map
  the export name correctly).
- 3 simd_const compile (BadBlockType + BadValType +
  NotImplemented — separate validator/lower gaps).
- The remaining 9 cluster around assert_invalid / assert_trap
  shapes the runner partially supports.

**Next — 9.9-e-2**: x86_64 mirror per
`private/notes/p9-9.9-e-survey.md`:
1. Add `LocalLayout` helper to `x86_64/emit.zig` (mirror of
   ARM64 shape, but RBP-negative offsets).
2. Add new MOVUPS RBP-disp encoders to `inst_sse.zig`
   (`encMovupsXmmMemRBP[Disp32]` — opcode 0x0F 0x10 / 0x11,
   no prefix, REX.R when xmm ≥ 8). Choose MOVUPS over MOVAPS
   for the local-slot form (alignment not guaranteed).
3. v128 param marshal SystemV-only (Win64 v128 by-hidden-
   pointer punted to debt row).
4. v128 local.get/set/tee handlers in
   `emitLocalGet/Set/Tee`.

Subsequent §9.9 chunks per ADR-0045:
- 9.9-d-7: investigate residual 21 value-mismatches +
  simd_align ExportNotFound runner gap.
- 9.9-f: scale to FP arith + compares (heavy 9k+ files).
- 9.9-g: aggregate `test-spec-simd` into `test-all`; flip §9.9 [x].

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
§9.9 in-flight (9.9-a..c + 9.9-d-1..6 + 9.9-e-1 landed; 9.9-e-2
NEXT — x86_64 v128 frame layout / param / local handlers).
**Branch**: `zwasm-from-scratch`。
