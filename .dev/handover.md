# Session handover

> Read at session start. **Replace** (not append) the `Active
> state` block at session end. Keep ≤ 80 lines.
>
> Per [`.claude/rules/no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md):
> **no numeric predictions** in this file.

## Cold-start procedure

1. `git log --oneline -5`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP
   breakdown. Authoritative; if anything below disagrees, trust
   the script.
3. `cat .dev/debt.md | head -60` — `now` rows + `blocked-by:`.
4. Open ROADMAP §9 Phase Status widget + §9.9 row.

## Active state — **PHASE 10 PREP CLOSED ✅ → §9.9 close work**

Phase 10 prep mode complete (2026-05-11 .. 2026-05-12). All
4 tracks decided; deliverables at
`.dev/phase10_prep/track_{a,b,c}_*.md` +
`.dev/phase10_transition_gate.md`. **Normal autonomous
`/continue` resumes**.

Phase: 9 (SIMD-128). §9.5/9.6/9.7/9.8 [x]; §9.9 still `[ ]`
(Mac + OrbStack 11384/0 simd_assert post-§9.9-h-14; SKIP=2357
each; windowsmini phase-boundary reconciliation pending).

## Implementation queue (sequenced; pick top-down)

1. **Track A impl** (1 chunk): §9.10 `[~] moved to Phase 11` +
   Phase 11 row prose expansion + ADR-0043 amend + D-074
   barrier update + D-076 close. Spec:
   `phase10_prep/track_a_9.10_scope.md` §7.
2. **Track C impl** (9.9-h-21..-24): Path B prefix-vocab
   migration (runner → regen → wast_runtime_runner + D-082
   file → ADR-0029 amend + check_skip_adrs.sh pre-commit gate
   + D-073 close). Spec: `track_c_adr_0029_path.md` §6.
3. **Track B impl** (9.9-h-15..-20): 4-way source split +
   4-way test mirror (`<source>_test.zig` suffix) + 3-way
   encoder split + ADR-0054 + tiered pub + file_size_check
   warn→gate flip + D-081 file + D-057/D-065 close. Spec:
   `track_b_source_split.md` §6.
4. **Phase 9 close cluster**: §9.11 audit_scaffolding +
   §9.9 SHA backfill; §9.12 row text update + Track D gate
   finalization + SKILL.md hard-gate list extension.
5. **Phase 10 entry hard gate STOP**: autonomous loop
   surfaces with `phase10_transition_gate.md` checklist for
   collaborative review. No `ScheduleWakeup`.

## Phase 10 design ADR slots (Track D §9 Q3)

ADR-0054 = Track B. A amends ADR-0043; C amends ADR-0029.
Phase 10 per-subsystem reserved (Q2 ordering):
ADR-0055 memory64 → 0056 Tail Call → 0057 EH → 0058 WasmGC.

## Open structural debt (pointers — see `.dev/debt.md`)

- `now`: none post-§9.9-h-14.
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052/055/
  D-057/058/059/062/D-065/D-072/D-073/D-074/075/D-076/D-079(ii).
  Prep impl discharges **D-057 / D-065 / D-072 (a/b) / D-073 /
  D-076**; D-074 updated; **D-081 / D-082** newly filed.

## Sandbox quirks (Mac aarch64, 2026-05-12)

- `~/.cache/zig` not write-allowed → prefix `zig build*` with
  `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- `bash scripts/p9_simd_status.sh` OrbStack branch fails on
  daemon log-rotation; use top-level
  `orb run -m my-ubuntu-amd64 bash -c '...'` directly.

## Pre-push hook scope

`.githooks/pre-push` → `scripts/gate_commit.sh` (light gate).
Full 3-host `scripts/gate_merge.sh` invoked **manually** at
Phase boundary + before push to `main`. Per-chunk loop is
2-host (Mac + OrbStack) per ADR-0049; windowsmini
phase-boundary only.
