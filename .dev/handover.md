# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -5`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
   Authoritative; trust the script if anything disagrees.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9 task table.

## Active state — **Phase 9 RE-OPENED: §9.9 in-Phase-9 Win64 marshal**

§9.11 [x] (audit + SHA backfill); §9.10 [~] moved to Phase 11;
§9.12 [ ] 🔒 Phase 10 entry gate (wired but cannot fire until
§9.9 closes); **§9.9 [ ]** — was prematurely flipped at last
chunk; reverted 2026-05-12 after user-correction. Discharge =
implementing Win64 v128 marshal per ADR-0055 (D-084 = `now`).

Mac+OrbStack bit-identical 13301/0/440; windowsmini 885/41/12856
(41 FAIL all = `compile: UnsupportedOp = Win64 v128 param
unsupported`, single root cause per agent report at
`private/d084-phase10-scope.md`).

## Implementation queue

1. **§9.9-i-1 NEXT** — Win64 v128 param marshal in
   `src/engine/codegen/x86_64/emit.zig` per ADR-0055
   (cranelift `ABIArg::ImplicitPtrArg` recipe; caller-allocated
   16-byte scratch + pointer-in-integer-arg-reg + callee MOVUPS
   load). Co-discharge SysV stack-arg overflow (`fp_arg_idx ≥
   8`) deferral from 9.9-e-2 if budget allows. Verify 41 FAIL →
   0 on windowsmini. Closes D-084.
2. Pending user paste — additional Phase 9 close items (test /
   bench / realworld coverage gaps vs zwasm v1's Wasm 2.0 +
   SIMD reach).
3. **§9.9** flips `[x]` only when 3-host green AND user-pasted
   coverage cohort discharged.
4. **§9.12 🔒 hard gate** then fires per existing detection.

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
  test-spec-simd"`.
- `.githooks/pre-push` → `gate_commit.sh` (light); full
  3-host `gate_merge.sh` manual at Phase boundary + before
  push to main. Per-chunk loop is 2-host (Mac+OrbStack) per
  ADR-0049; **windowsmini fired at §9.12 reconcile 2026-05-12
  and surfaced 41 FAIL = Phase 9 incompletion**.

## Worktree subagent pattern for §9.9-i-1

- `git worktree add ../zwasm-win64-v128 -b feature/win64-v128-marshal
  zwasm-from-scratch` (separate worktree on feature branch).
- Subagent iterates implementation in worktree; pushes feature
  branch to origin; `ssh windowsmini` fetches feature branch +
  runs `zig build test-spec-simd` for verification iterations.
- On 41 FAIL → 0, parent agent merges feature branch into
  `zwasm-from-scratch` + cleans up worktree.

## Open structural debt pointers — see `.dev/debt.md`

- `now`: **D-084 (Win64 v128 marshal; this Phase's next chunk
  discharges)**.
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052/
  055/057/058/059/062/065/072/073/074/075/079(ii)/081/082.
