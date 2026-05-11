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
- **Latest §9.9 landing**: §9.9 / 9.9-h-12 — ADR-0053 Part 3b/3c
  (D-078 (c) FULLY DISCHARGED). Bitselect reclaims XMM7 as a
  3rd staging slot for `a` + spilled dst; Load / Store / Const
  also migrated. **OrbStack simd_assert: 11257 / 1 → 11270 / 0
  FAIL** — simd_bitwise.17 cleared. Mac unchanged 11270 / 0.
  **Both hosts at zero failing fixtures.** §9.9 exit criterion
  now blocked only on: windowsmini reconciliation (deferred to
  phase boundary per ADR-0049) + SKIP-cluster review.
- **Active row**: §9.9 (still `[ ]`). Mac is at FAIL=0 / SKIP>0;
  the exit criterion is fail=skip=0 across the 3-host gate, so
  skips remain (assert_invalid SKIP-VALIDATOR-GAP cluster +
  cascading-skipped under bad modules). OrbStack still has 2
  visible FAILs (D-078 a + c) blocked on x86_64-specific work.

## Next sub-chunk candidates (names only)

- **SKIP-cluster review** — Mac 2471 SKIPs, OrbStack 2471
  SKIPs. Most are `SKIP-VALIDATOR-GAP` (assert_invalid that
  the validator currently accepts) + `skip
  v128-param-pending` for un-supported invoke shapes +
  cascading-skipped-under-bad-module entries. §9.9 exit
  criterion needs these classified and either fixed or
  ADR-justified.
- **windowsmini phase-boundary reconciliation** — when the
  §9.9 SKIPs are at zero, run `scripts/run_remote_windows.sh
  test-all` once, fix any windowsmini-only deltas, then
  `should_gate_windows.sh --record`.
- **Aggregate `test-spec-simd` into `test-all`** — both
  hosts are at 0 FAIL now, so adding the dependency in
  `build.zig` no longer breaks the gate. Preventive
  regression detection.
- **Remaining v128-class `resolveXmm` audit** — many other
  v128 handlers (lane extract/replace, splat, shifts,
  shuffle, compares, convert) still use `resolveXmm`. No
  current fixture triggers spilled-v128 on them, but a grep
  audit + preventive migration prevents future surprises.
- **D-057 / D-065 source-split** — `op_simd.zig` (4554 LOC)
  + `inst_neon.zig` (2249 LOC) + `op_simd_test.zig` (2624
  LOC) breach the §A2 hard cap. ADR-0053 mentioned this as
  co-deliverable but it's still pending.
- Aggregate `test-spec-simd` into `test-all` (preventive — surfaces
  silent x86_64 simd regressions in autonomous loop gating).
- **D-066 alias-stash pattern audit** — `bug_fix_survey.md` grep
  surfaced ~20 sites in x86_64/op_simd.zig with the
  `encMovapsXmmXmm(dst, …)` shape. Several may have latent
  `dst == src2` alias bugs that no current fixture exercises;
  systematic audit + preventive stash-or-prove safe.
- §9.9 exit-criterion narrowing: with Mac at 0 FAIL, the
  remaining gate work is OrbStack-only (1 visible FAIL +
  D-077) plus the SKIP-cluster review.

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
