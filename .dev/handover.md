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
- **Latest §9.9 landing**: `67aa0025` (§9.9 / 9.9-g-13 —
  preventive `emitV128IntCmpUnsigned` `dst==lhs` alias fix).
  See commit body for measured deltas.
- **Note**: HEAD is past `67aa0025` by 4 meta-work commits
  (`ddc9e54c..030ce80a`) — scaffolding split per §18.3
  amendment + 2026-05-11 ADR audit response. Not §9.9 chunk
  work; `git log --grep="§9.9"` for actual chunk anchor.
- **Active row**: §9.9 (still `[ ]`). Closes when fail = skip = 0
  on the 3-host gate per the row's exit criterion.

## Next sub-chunk candidates (names only)

- **D-071 (b)** — `i8x16.popcnt` x86_64 PSHUFB recipe debug.
- **D-071 (c-actual)** — `i*x*.ne` family PCMPEQ+PXOR recipe.
- **D-071 (a)** — `i64x2.mul` x86_64 PMULUDQ recipe debug.
- **D-067** — bitmask validator-shape (lower + ARM64 emit).
- Aggregate `test-spec-simd` into `test-all` (preventive — surfaces
  silent x86_64 simd regressions in autonomous loop gating).

Pick by: live evidence from Step 2's script + structural
impossibility check (debt.md `blocked-by:` barriers).

## Open structural debt (pointers — see `.dev/debt.md`)

- `now`: D-063 (call_indirect v128 Trap), D-071 (x86_64 SIMD
  residuals — categorised in debt body, NOT here).
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
