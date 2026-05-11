# Session handover

> ≤ 80 lines. No numeric predictions (per
> [`no_handover_predictions.md`](../.claude/rules/no_handover_predictions.md)).

## Cold-start procedure

1. `git log --oneline -5`.
2. `bash scripts/p9_simd_status.sh` — live SIMD FAIL/SKIP.
3. `cat .dev/debt.md | head -60` — `now` + `blocked-by:`.
4. ROADMAP §9 Phase Status widget + §9.9 row text (ADR-0056).

## Active state — **Phase 9 extended; SEQUENTIAL mode**

§9.11 [x]; §9.10 [~] Phase 11; §9.12 [ ] 🔒 (waits §9.9);
**§9.9 [ ]** scope = full Wasm 2.0 PASS on Mac+OrbStack per
ADR-0056. Mode change 2026-05-12: parallel-agent fanout for
implementation showed diminishing returns; main thread now
drives sub-chunks sequentially. Investigation agents X/Y/Z +
worktree Agent W (Win64 v128 marshal) all completed.

**Win64 v128 marshal DONE** (Agent W): windowsmini 41 FAIL →
0 first iteration; 13301/0/440 bit-identical with Mac+OrbStack.
Feature branch `feature/p9-win64-v128-marshal` (commits
`7b550038` impl + `00ca0e6c` ADR/debt/tests) merging into
main now. ADR-0055 Accepted; D-084 discharged.

## Implementation queue (sequential)

Stage A: [x] j-1 ADR-0056 (`6654435c`); [x] j-2 test-all 2/3
wirings + bench fixes (`a254ba50`).

Stage B — JIT op completion (小→大):
- **9.9-i-1 INTEGRATING** Win64 v128 marshal (cherry-pick)
- **9.9-m-4 NEXT** JIT select_typed type dispatch (non-i32)
- 9.9-j-2b D-085 rem_s + D-086 mac-only gate + test-edge-cases
- 9.9-m-1 ref.null / ref.func / ref.is_null
- 9.9-m-3 memory.init / data.drop / elem.drop
- 9.9-m-2 table.* full 7-op family (~3000 LOC, ADR-0058)

Stage C:
- 9.9-l-1 non-SIMD spec_assert_runner (ADR-0057)
- 9.9-k-1 Wasm 2.0 non-SIMD wast vendor (~30 files)
- 9.9-k-2 SIMD wast vendor (33 files)

Stage D:
- 9.9-n-1 fib2 perf root cause
- 9.9-j-3b SKIP gate real enforce (last)

## Sandbox quirks + hook scope

- `~/.cache/zig` not write-allowed → `ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache`.
- `p9_simd_status.sh` OrbStack daemon log-rotation panic;
  `pkill -9 -f OrbStack && open -a OrbStack`.
- `scripts/run_remote_windows.sh` `windowsmini.local` mDNS
  intermittently; workaround direct `ssh windowsmini ...`.
- Per-chunk 2-host (Mac+OrbStack) per ADR-0049; windowsmini at
  §9.9 close (already done via Agent W feature branch).

## Open debt pointers — see `.dev/debt.md`

- `now`: D-085 (i32.rem_s alias — j-2b), D-086 (edge-cases
  mac-only gate — j-2b).
- `blocked-by`: D-007/010/016/018/020/021/022/026/028/052(partial-discharged)/
  055/057/058/059/062(partial)/065/072/073/074/075/079(ii)/081/082.

## Investigation reports (gitignored)

- `private/d084-phase10-scope.md` — Win64 ABI agent
- `private/p9-x-wasm2-non-simd-coverage.md` — Agent X
- `private/p9-y-tests-bench-audit.md` — Agent Y
- `private/p9-z-realworld-v1-parity.md` — Agent Z
