# Session handover

> Read at session start. **Replace** (not append) the `Active
> state` block at session end. Keep ≤ 80 lines.
>
> Per [`.claude/rules/no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md):
> **no numeric predictions** in this file. Live measurements live
> in `scripts/p<N>_*_status.sh`. Past chunk facts live in commit
> messages and ROADMAP chunk records.

## Cold-start procedure (do not skip)

1. `git log --oneline -5` — latest commits.
2. `bash scripts/p9_simd_status.sh` — **live** SIMD spec FAIL
   breakdown across Mac + OrbStack + active `now` debt rows.
   Authoritative. If anything below disagrees with this output,
   trust the script and update this file.
3. `cat .dev/debt.md | head -60` — `now` rows + recent
   `blocked-by:` barriers (per resume Step 0.5).
4. Open `.dev/ROADMAP.md` §9 Phase Status widget + §9.9 row.

## Active state

- **Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline).
  §9.5 [x], §9.6 [x], §9.7 [x], §9.8 [x] (absorbed per
  ADR-0044), **§9.9 in-flight**.
- **Branch**: `zwasm-from-scratch`.
- **Latest §9.9 landing**: `324e5fc3` (§9.9 / 9.9-g-18 —
  x86_64 explicit-`return` v128 marshal closes simd_lane.140
  compile gap; D-078 partial). OrbStack FAIL: 4 → 3.
- **Active row**: §9.9 (still `[ ]`). Closes when fail = skip = 0
  on the 3-host gate per the row's exit criterion.

## Next sub-chunk candidates (names only)

- **D-067 bitmask 9.9-g-19 implementation ready** — Step 0
  survey landed at `private/notes/p9-9.9-g-19-bitmask-neon-
  survey.md` (full recipe by shape, encoder list, const-pool
  values). Existing emit pattern reference:
  `arm64/op_simd.zig:1305 emitV128AnyTrue` uses
  `emitV128ReduceWithEncoder` shared helper —
  bitmask follows the same shape with a longer recipe (SSHR +
  AND const + ADDV + UMOV). Encoder precedent:
  `inst_neon.zig:422 encUmaxv16B` (Q=1, U=1, opcode=01010).
  Estimated diff 400-600 source LOC + 200-300 test LOC; at
  upper LOOP.md chunk-granularity bound. Closes simd_boolean.0
  on both arches.
- **D-078 (c) simd_bitwise.17 — root cause: x86_64 v128
  XMM spill not yet implemented**. `resolveXmm` rejects
  spilled v128 vregs (handler not XMM-spill-aware). Discharge
  needs `xmmLoadSpilledV128` / `xmmStoreSpilledV128` using
  16-byte MOVUPS + handler updates (~100 sites). Substantial
  refactor; Step 0 survey + co-deliverable with D-057
  source-split. (D-078 (b) v128 globals retired as
  misdiagnosis; actual gap was return-v128 closed at 9.9-g-18.)
- **D-078 (a) f64x2_extract_lane value mismatch** — JIT-disasm
  spike via debug_jit_auto skill (Mac PASSES, x86_64 only).
- Aggregate `test-spec-simd` into `test-all` (preventive — surfaces
  silent x86_64 simd regressions in autonomous loop gating).

Pick by: live evidence from Step 2's script + structural
impossibility check (debt.md `blocked-by:` barriers).

## Open structural debt (pointers — see `.dev/debt.md`)

- `now`: D-063 (call_indirect v128 Trap), D-067 (i*x*.bitmask
  validator-shape + ARM64 emit), D-071 (D-066 mirror cluster
  fully discharged at 9.9-g-16; row body retained for
  historical traceability), D-077 (OrbStack simd_assert_runner
  deinit panic — pre-existing), D-078 (4-fail residual cluster
  diagnosis: f64x2_extract_lane spike + v128 globals gap +
  simd_bitwise.17 dispatch).
- `blocked-by`: D-007 / D-010 / D-016 / D-018 / D-020 / D-021 /
  D-022 / D-026 / D-028 / D-052 / D-055 / D-057 / D-058 / D-059 /
  D-065 / D-070 / D-072 / D-073 / D-074 / D-075 / D-076 — barrier
  dissolution re-evaluated every resume per SKILL.md Step 0.5.
  D-072..D-076 added 2026-05-11 by ADR audit response (out of
  /continue chunk-work scope; named structural barriers).

## Recent surprise (drift signal)

§9.9-g-13 surfaced that the prior handover's "Targets ~16
fails" prediction (alias case) didn't match live evidence
(actual 16 = `i*x*.ne` family). Rule
[`.claude/rules/no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)
+ live-measurement script
[`scripts/p9_simd_status.sh`](../scripts/p9_simd_status.sh) +
`/continue` Resume **Step 0.5b** landed 2026-05-11 to prevent
recurrence. Lesson:
[`2026-05-11-handover-prediction-vs-evidence.md`](lessons/2026-05-11-handover-prediction-vs-evidence.md).

## After §9.9 closes

§9.10 (SIMD smoke benches + per-op gap profile), §9.11 (audit
+ SHA backfill), §9.12 (open Phase 10).
