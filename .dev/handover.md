# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -5`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
   Authoritative; trust the script if anything disagrees.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row.

## Active state — **PHASE 10 PREP CLOSED ✅**

Prep mode complete 2026-05-11..2026-05-12; 4 tracks decided.
Deliverables: `.dev/phase10_prep/track_{a,b,c}_*.md` +
`.dev/phase10_transition_gate.md`. Normal `/continue` resumes.

Phase: 9 (SIMD-128). §9.5/6/7/8 [x]; §9.9 [ ] (Mac+OrbStack
**13295/0/446** = 56 skip-impl + 390 skip-adr post-h-30 with
SUPPORTED for select still deferred; windowsmini reconcile
pending).

Latest landed: `33218eef` — 9.9-h-30 D-083 part 1 (arm64
emitV128Select alias-stash). arm64 fix preserved; SUPPORTED
deferral kept until D-083 part 2 (x86_64 v128 select) lands.

## Implementation queue (matches ROADMAP first `[ ]`)

§9.9 sub-chunks h-15..-N until skip-impl=0; then §9.11 (bundling
Track A's §9.10 reshape); then §9.12 + Track D wiring; then hard
gate. Specs: `phase10_prep/track_*.md` §6/§7.

1. **Track B** (9.9-h-15..-20, 6 chunks) — **COMPLETE** (all
   `[x]`). file_size_check hard-cap list = 0; warn→gate flipped;
   ADR-0054 lands; D-057 + D-065 closed; D-081 filed.
2. **Track C** (9.9-h-21..-24, 4 chunks) — **COMPLETE** (all
   `[x]`). ADR-0029 Path B prefix vocab end-to-end; 3 skip-ADRs
   operationally effective; D-072 + D-073 closed; D-082 carries
   the (c)-path actual fixture fixes. `check_skip_adrs --gate`
   wired into `gate_commit.sh`.
3. **§9.9 close residual** (h-25..-N): live skip-impl breakdown
   per-resume; loop picks largest category. Current post-h-26:
   - **9.9-h-25** `[x]` `01db6434` — NaN-pattern lane (1222→0).
   - **9.9-h-26** `[x]` `4de24200` — 6 v128-mixed-arg helpers
     (674 → 175).
   - **9.9-h-27** `[x]` `2c5cb3e9` — 3 more shapes (175 → 39);
     D-083 deferred select_v128_i32 bug.
   - **9.9-h-28** `[x]` `b85c07da` — 11 more shapes (39 → 6;
     residual = D-083-deferred select).
   - **9.9-h-29** `[x]` `2f1e75f1` — assert_trap + quoted-name.
   - **9.9-h-30** `[x]` `33218eef` — D-083 part 1 (arm64
     emitV128Select alias-stash). x86_64 part 2 still
     outstanding.
   - **9.9-h-31** **NEXT** — D-083 part 2: x86_64 v128 select
     handler. (a) add v128 dispatch in `x86_64/emit.zig`
     select arm (mirror of arm64's at lines 1093-1108); (b)
     new `emitV128Select` in `x86_64/op_simd.zig` using
     mask-based PAND/PANDN/POR (TEST cond → CMOV r_mask,
     -1 → MOVQ xmm_mask → PSHUFD broadcast → PAND val1 →
     PANDN val2 → POR). Watch for same alias-on-mask-XMM-reg
     pattern as arm64. Restoring SUPPORTED flips +6 PASS on
     both hosts → manifest-line skip-impl = 0 → §9.9 close
     gate met.
   - Then: §9.11 (audit + SHA backfill) + §9.12 (Track D
     wiring for Phase 10 hard gate).
   Chunks until `failed = skip-impl = 0` on 2-host; windowsmini
   reconcile at Phase boundary close. §9.9 row flips `[x]`.
4. **§9.11 + Track A bundled** (1 chunk): audit_scaffolding
   Phase-9 pass + SHA backfill §9.9 `[x]` rows + §9.10
   `[~] moved to Phase 11` + Phase 11 row prose + ADR-0043
   amend + D-074 update + D-076 close.
5. **§9.12 + Track D wiring** (1 chunk): §9.12 row text →
   `🔒 Phase 10 entry gate review
   (.dev/phase10_transition_gate.md)`; add Phase 9→10 entry
   to SKILL.md "Currently registered hard gates" list.
6. **Phase 10 entry HARD GATE STOP** — next resume after §9.12
   wiring lands hits the row, detector fires, loop surfaces
   `phase10_transition_gate.md` for collaborative review. No
   `ScheduleWakeup`.

## Phase 10 design ADR slots (Track D §9 Q3)

ADR-0054 = Track B; A amends ADR-0043; C amends ADR-0029.
Phase 10 per-subsystem (Q2 order): ADR-0055 memory64 →
0056 Tail Call → 0057 EH → 0058 WasmGC.

## Open structural debt (pointers — see `.dev/debt.md`)

- `now`: none post-§9.9-h-14.
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052/055/
  D-057/058/059/062/D-065/D-072/D-073/D-074/075/D-076/D-079(ii).
  Prep impl discharges **D-057 / D-065 / D-072 (a/b) / D-073 /
  D-076**; D-074 updated; **D-081 / D-082** newly filed.

## Sandbox quirks + hook scope

- `~/.cache/zig` not write-allowed → prefix `zig build*` with
  `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- `p9_simd_status.sh` OrbStack branch fails on daemon log-rotation;
  use top-level `orb run -m my-ubuntu-amd64 bash -c '...'` directly.
- `.githooks/pre-push` → `gate_commit.sh` (light); full 3-host
  `gate_merge.sh` manual at Phase boundary + before push to main.
  Per-chunk loop is 2-host (Mac+OrbStack) per ADR-0049;
  windowsmini phase-boundary only.
