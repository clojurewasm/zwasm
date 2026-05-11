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

## Active state — **PHASE 10 PREP MODE** 🛑

- **Mode**: preparation / decision-gathering phase, **not**
  normal chunk work. See `.dev/phase10_prep.md` (load-bearing —
  read it before any other step).
- **Phase**: Phase 9 (SIMD-128). §9.5/9.6/9.7/9.8 [x],
  **§9.9 still `[ ]`** (Mac + OrbStack at **11384 / 0** simd_
  assert post-§9.9-h-14; SKIP=2357 each; windowsmini not yet
  reconciled). §9.10/§9.11/§9.12 unopened.
- **Branch**: `zwasm-from-scratch`.
- **Why prep mode**: 4 design decisions block clean Phase 9
  close + Phase 10 entry. Each requires human judgment between
  named alternatives. Surfaces sized for review one at a time.
- **Loop contract per track** (per `.dev/phase10_prep.md`):
  1. Read the track scope.
  2. Survey + draft the **Markdown deliverable** (no `src/`
     code changes).
  3. Commit as `docs(p10-prep): track <X> — <one line>`.
  4. **Surface to user with one sentence**: deliverable path +
     "awaiting decision before proceeding".
  5. **Do NOT call `ScheduleWakeup`.** The user resumes
     manually with `/continue` after reviewing.

## Next sub-chunk candidates — **PREP TRACKS (run A → B → C → D in order)**

1. **Track A — §9.10 scope reality check** (does §9.10 stay,
   descope to baseline-only, or move to Phase 11). Blocks
   §9.9-after-skip / §9.10 entry. See `phase10_prep.md`
   §"Track A".
2. **Track B — D-057 / D-065 source-split partition**
   (`op_simd.zig` 4554 + `inst_neon.zig` 2249 +
   `op_simd_test.zig` 2624 vs §A2 cap 2000). Output: partition
   table + ADR-0054 draft skeleton. See §"Track B".
3. **Track C — ADR-0029 path A vs B** (skip-impl/skip-adr
   vocabulary OR runner-internal classification). Resolves
   D-072 + D-073 + the §9.9 skip-exit interpretation. See
   §"Track C".
4. **Track D — Phase 10 transition gate doc** (draft
   `.dev/phase10_transition_gate.md` so `/continue` hard-gate
   detector halts at Phase 10 entry). See §"Track D".

After all 4 tracks land + user reviews, normal autonomous
`/continue` resumes; this file's `Active state` flips back
out of prep mode.

## Open structural debt (pointers — see `.dev/debt.md`)

- `now`: **none** as of §9.9-h-14 close (D-063 / D-066 / D-070
  / D-071 / D-077 / D-078 (a)+(b)+(c) / D-079 (i) / D-080 all
  discharged; the row table's Active section is `blocked-by:`
  only).
- `blocked-by`: D-007 / D-010 / D-016 / D-018 / D-020 / D-021 /
  D-022 / D-026 / D-028 / D-052 / D-055 / **D-057** /
  D-058 / D-059 / D-062 / **D-065** / D-072 / D-073 /
  **D-074** / D-075 / **D-076** / **D-079 (ii)** —
  barrier dissolution re-evaluated every resume per SKILL.md
  Step 0.5. **Bold = directly addressed by a prep track**
  (D-057 / D-065 → Track B; D-072 / D-073 → Track C; D-074
  / D-076 → Track A; D-079 (ii) → unblocked by Phase 10
  schedule, naturally drops when Track D's gate doc lands).

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

## After Phase 10 prep completes

User holds 4 decisions (Track A scope, Track B partition,
Track C ADR-0029 path, Track D gate doc). Each unblocks
specific debt rows. After review:

- §9.9 close (the actual fail=skip=0 measurement against
  the resolved skip-counting rule from Track C).
- §9.10 (scope per Track A's decision).
- §9.11 audit + SHA backfill.
- §9.12 (open Phase 10 — guarded by Track D's hard gate).

Normal autonomous `/continue` resumes at that point.
