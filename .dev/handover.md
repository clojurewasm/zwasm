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
- **Latest §9.9 landing**: §9.9 / 9.9-h-3 — D-079 (i) discharge.
  Three new entry helpers (`callVoid_v128`, `callVoid_v128v128`,
  `callVoid_v128v128v128v128`) in `engine/codegen/shared/
  entry.zig`; simd_assert_runner void-result dispatch extended
  to handle 1 / 2 / 4 v128 args; `regen_spec_simd_assert.sh`
  SUPPORTED set adds the three setter shapes; manifests
  regenerated. simd_const.388 Mac fails 4 → 0 cleared (the 4
  setter-cascade fails). Mac aarch64 simd_assert:
  **11263 PASS / 6 FAIL → 11268 PASS / 2 FAIL** (-4). Residual
  2 fails are D-063 (call_indirect v128 args Trap). OrbStack
  visible FAILs unchanged (D-078 a + c + D-077 panic — all
  pre-existing).
- **Active row**: §9.9 (still `[ ]`). Closes when fail = skip = 0
  on the 3-host gate per the row's exit criterion.

## Next sub-chunk candidates (names only)

- **D-063 simd_const call_indirect-param Trap** — Mac aarch64
  v128 args via call_indirect; lldb spike per debt.md. 2 of the
  current Mac fails (`as-call_indirect-param()` /
  `-param2()`).
- **D-078 (a) f64x2_extract_lane value mismatch** — JIT-disasm
  spike via debug_jit_auto skill (Mac PASSES, x86_64 only).
- **D-078 (c) simd_bitwise.17** — root cause: x86_64 v128 XMM
  spill not yet implemented. `resolveXmm` rejects spilled v128
  vregs. Needs `xmmLoadSpilledV128` + `xmmStoreSpilledV128`
  (16-byte MOVUPS) + ~100 handler updates. Substantial refactor;
  co-deliverable with D-057 source-split.
- Aggregate `test-spec-simd` into `test-all` (preventive — surfaces
  silent x86_64 simd regressions in autonomous loop gating).

Pick by: live evidence from Step 2's script + structural
impossibility check (debt.md `blocked-by:` barriers).

## Open structural debt (pointers — see `.dev/debt.md`)

- `now`: D-063 (call_indirect v128 Trap), D-071 (D-066 mirror
  cluster fully discharged at 9.9-g-16; row body retained for
  historical traceability), D-077 (OrbStack simd_assert_runner
  deinit panic — pre-existing), D-078 (residual cluster
  diagnosis: (a) f64x2_extract_lane spike, (b) v128 globals
  storage gap PARTIALLY DISCHARGED at 9.9-h-2 — cascading fails
  now belong to D-079, (c) simd_bitwise.17 XMM spill), D-079
  (v128 multi-arg setter invoke + v128 imports; new at 9.9-h-2).
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

**2026-05-11 gate-dormancy surprise**: `.githooks/pre_commit`
and `.githooks/pre_push` used underscore filenames since
bootstrap (`9bd21b2f`); git only recognises hyphenated names,
so every gate ran was a manual `bash scripts/gate_commit.sh`
invocation. `scripts/file_size_check.sh --gate` had been silently
failing for 1400+ commits. `zig fmt --check` drift across 43
src/*.zig files accumulated. Resolved by `chore(fmt): apply zig
fmt 0.16 across src/` + `chore(hooks): activate gate by renaming
pre_{commit,push} → pre-{commit,push}` (file_size_check switched
to warn-only mode pending D-057 source-split discharge). Bisect
trail: first-bad commit was `c2cd9b5e` (§9.1 / 1.2 ZirOp
catalogue) — the very first src-bearing commit on this branch.

**Pre-push hook scope**: `.githooks/pre-push` calls
`scripts/gate_commit.sh` (light: fmt + zone + file_size + zig
build test). The full 3-host `scripts/gate_merge.sh` (Mac +
OrbStack + windowsmini test-all) is **invoked manually** at
Phase boundary close + before any push to `main`, NOT
per-push to `zwasm-from-scratch`. Per-chunk autonomous loop
matches SKILL.md "Parallel test gate" (2-host Mac + OrbStack
subset; windowsmini phase-boundary only per ADR-0049).

## Sandbox quirks (Mac aarch64 host, 2026-05-11)

- `~/.cache/zig` is outside the write-allow list. Builds that
  need to populate global cache (`compiler_rt`, `ubsan_rt`,
  `builtin.zig`) fail with PermissionDenied unless
  `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache` is set. Workaround:
  prefix `zig build*` invocations with the env var; the cache
  inside `.zig-cache` (local) is unaffected.
- `bash scripts/p9_simd_status.sh` OrbStack branch fails because
  the inner `orb run` subprocess triggers a daemon log-rotation
  write into `~/.orbstack/log/` (sandbox-denied). Top-level
  `orb run -m my-ubuntu-amd64 bash -c '...'` works directly.

## After §9.9 closes

§9.10 (SIMD smoke benches + per-op gap profile), §9.11 (audit
+ SHA backfill), §9.12 (open Phase 10).
