# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -5`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
   Authoritative; trust the script if anything disagrees.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9 task table.

## Active state — **HARD GATE PENDING — Phase 10 entry review**

§9.9 [x] (Mac+OrbStack green; windowsmini Win64 v128 ABI gap =
D-084); §9.10 [~] moved to Phase 11 (Track A); §9.11 [x]
(audit + SHA backfill + ADR-0043 amend); §9.12 [ ] 🔒
**Phase 10 entry gate** ([`phase10_transition_gate.md`](phase10_transition_gate.md)).

**Next /continue HITS the hard gate**: SKILL.md §"Currently
registered hard gates" registers §9.9 → Phase 10 anchored at
9.12 (this chunk landed the registration). Resume Step 2
detector fires; loop surfaces gate doc for collaborative
review; no autonomous TDD chunks fire until 9.12 is
collaboratively flipped `[x]`.

## What surfaces at the gate

`phase10_transition_gate.md` §"Checklist" enumerates Phase 9
functional completion + debt reconciliation + design
cleanliness extrapolation + per-subsystem ADR slots
(0055..0058: memory64 / Tail Call / EH / WasmGC). The §"Phase
9 functional completion" section explicitly enumerates 3-host
green — the windowsmini Win64 v128 ABI gap (D-084) surfaces
there for collaborative decision (file own Phase 10 row vs
absorb into Phase 10 EH/GC ABI work).

## Cohort of debt rows the gate will reference

- **D-084** (new, this chunk) — windowsmini Win64 v128 ABI
  marshal gap; 41 FAIL + 12466 skip-impl on windowsmini
  while Mac+OrbStack are bit-identical green.
- **D-079(ii)** — v128 cross-module imports
  (`Runtime.globals` shape extension).
- **D-074(updated)** — ADR-0012 §1–§3 bench infra cohort +
  SIMD per-op gap analysis (Track A migrated 2026-05-12).
- Plus the 17-row blocked-by cohort listed at handover bottom.

## Sandbox quirks + hook scope

- `~/.cache/zig` not write-allowed → prefix `zig build*` with
  `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- `p9_simd_status.sh` OrbStack branch fails on daemon log-
  rotation; restart via `pkill -9 -f OrbStack && open -a
  OrbStack`, then top-level `orb run -m my-ubuntu-amd64
  bash -c '...'` directly.
- `scripts/run_remote_windows.sh` fails on
  `windowsmini.local` mDNS resolution intermittently;
  workaround: direct `ssh windowsmini "cd
  Documents/MyProducts/zwasm_from_scratch && zig build
  test-spec-simd"`. Filed as new debt candidate (script SSH
  path uses bash login shell which lacks mDNS in some
  states).
- `.githooks/pre-push` → `gate_commit.sh` (light); full
  3-host `gate_merge.sh` manual at Phase boundary + before
  push to main. Per-chunk loop is 2-host (Mac+OrbStack) per
  ADR-0049; windowsmini phase-boundary fired at this chunk.

## Open structural debt pointers — see `.dev/debt.md`

- `now`: none.
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052/
  055/057/058/059/062/065/072/073/074/075/079(ii)/081/082/
  **D-084 (new)**.
