# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## NEVER-IDLE PROTOCOL (read first — user-directed 2026-06-06)

The loop **NEVER idles in "minimal turns."** The 完成形 v0.1 surface is done, but the user **UNBLOCKED v0.2 AND
v0.3 feature work** (2026-06-06) — "AIが思いのほか早いのでどんどんやろう." **Work priority each resume:**
1. **v0.2 / v0.3 features** — the primary forward track now (ROADMAP §17 / `.dev/proposal_watch.md`: threads,
   wide-arith, relaxed-SIMD, custom-page-sizes, component-model, …). Survey → sequence → TDD-implement. **No
   release/tag ever** (ADR-0156 stands — user reconfirmed "タグは切らない").
2. When between features OR a feature is gated → **sweep `.dev/remaining_sweep.md`** (Bucket A ledger-prune → B
   actionable-low-value → C deferred) — never idle, sweep the leftover systematically.
3. **D-279 + similar are NEVER "left alone"** (user: "放置せず常にシステムは動作するように") — keep it actively
   progressing: the H3 diagnostic is deployed; re-kick windows when work lands so a reproduction is always being
   hunted; verify the signal at every Step 0.7.
Idle/minimal turn is now a BUG, not a steady-state. Dogfooding (D-264) is **DONE** (cw v1 side succeeded).

## Active bundle (ADR-0118 D6) — atomics official spec corpus (conformance for 17.1)

- **Bundle-ID**: atomics-spec-corpus
- **Goal**: run the official `proposals/threads/atomic.wast` through a spec runner — official conformance for
  17.1 atomics (complements the p17/atomics edge fixtures). The relaxed-SIMD corpus caught 2 real x86 bugs;
  atomics (complex rmw/cmpxchg/wait) is the next-most-likely to surface latent bugs. Same value pattern.
- **Continuity-memo**: SCOUTED this cycle — `wast2json --enable-threads proposals/threads/atomic.wast` → 142
  assert_return + 45 assert_trap + 48 assert_invalid + 59 standalone `action` (3 modules). All shapes **scalar**
  (i32.atomic.load: [i32]→[i32]); NO `(either)`. **Runner choice is the open Q**: simd_assert_runner = v128-
  focused; wasm_3_0 runner EXECUTES but has narrow JIT-eligibility (SKIPS arg-taking asserts — atomic.load takes
  an i32 arg → would skip); `spec_assert_runner_non_simd` has broad arg-taking scalar exec (25437 assertions) →
  likely the right host BUT must verify it (a) handles a **shared-memory** module + (b) the 59 `action` commands
  (store-side; distiller currently `skip-impl directive-action` → loads may read uninit — check if atomic tests
  are self-contained or need action-execution).
- **Plan**: ~~chunk1 host-runner identified~~ = **`spec_assert_runner_non_simd`** (broad arg-taking scalar exec,
  25437 assertions; takes a `corpus_root` arg @non_simd:84-103 + auto-iterates subdirs; linear mem via
  `base.growable_memory`). wasm_3_0 runner REJECTED (skips arg-taking). **NEXT chunk2** = regen atomic.wast →
  a new `test/spec/threads-assert/atomic/` corpus + add a build.zig step reusing the non_simd runner binary
  pointed at it (mirror build.zig:464 test-spec-wasm-2.0-assert). Distiller source = TESTSUITE
  `proposals/threads/atomic.wast` (NOT spec/test/core). **Action-handling RESOLVED (scout)**: non_simd runner
  PERSISTS memory across directives (@non_simd:147) + already runs `init`-action invokes (@622) → distiller emits
  the 59 `action` (store/init) commands as **void-result invokes** (`assert_return <fn> <args> -> ()`), NOT skip.
  Module = `(memory 1 1 shared)`. **chunk2-3 DONE (spiked @this cycle)**: regen `scripts/regen_spec_threads_assert.sh`
  written; `spec_assert_runner_non_simd` runs the corpus — **226 asserts PASS, ZERO atomics bugs**. **NOW BLOCKED
  @D-301 (chunk4 = runner extension, REQUIRED)**: (a) 3-arg-scalar dispatch (cmpxchg/wait take 3 args; runner
  maxes at 2 AND they're sequence-setup ops → skipping breaks dependent loads) — add entry helpers
  callI32_i32i32i32 / callI64_i32i64i64 / callI32_i32i32i64 / callI32_i32i64i64 (entry.zig) + non_simd dispatch;
  (b) assert_trap arg-parse (nonSimdRunAssertTrap can't parse i64/multi-arg the assert_return path handles).
  Then regen → wire build.zig test-spec-threads-assert step → corpus green 3-host. Regen script committed
  (untracked corpus NOT committed until green). Atomic JIT edge-covered (p17/atomics) meanwhile.
- **Exit-condition**: atomic.wast assert_returns execute (not skip) + pass in a runner, 0 fail, 3-host; any
  surfaced bug fixed.
- **Cycles-remaining**: ~3-4. No tag (ADR-0156).

## Current state

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168). DONE+**3-host-confirmed**: **17.1-atomics @9eb84833** ·
  **17.2-wide-arith @231d4536** · **17.3-custom-page-sizes @cd0de2dd** · **17.4-relaxed-SIMD @08342ec5**
  (delta 0→**20 ops** JIT both arches; +ADR-0169 per-arch hardware semantics; emit_test probe → `memory.discard`).
  17.4 verified Mac + ubuntu @758ff210 + **Win64 @758ff210** (dot_add_s=110/dot_s=3/q15mulr=8192,32767; gate
  recorded; D-279 silent streak=3; 1-failed=D-028 IPC flake, 0 assertions). **Wasm-3.0 100%-spec is COMPLETE —
  no lurking reserved-but-unimpl Phase-5 ops** (audited zir_ops enum 2026-06-07; only stack-switching/
  memory-control stubs remain = Phase-3).
- **relaxed-SIMD official spec corpus DONE @8ef2e752 + x86 dot fix @b8c1c31d** — 7 upstream `.wast` in
  simd_assert_runner with `(either)` support (ADR-0169); **13420 passed, 0 fail** on arm64 AND x86_64 (Rosetta-
  verified). The corpus caught a REAL x86 bug (relaxed_dot passed `a` as PMADDUBSW's unsigned operand → wrong for
  a<0; fixed by swapping → b=unsigned/a=signed). ubuntu was RED@5d098216 (3 fail) → forward-fixed (impl bug, not
  revert). dot_s_neg edge fixture guards the sign boundary. ubuntu re-confirm pending @b8c1c31d.
- **D-231 leak FIXED @96fcdf9f** — running check_build_dce's nm-grep on a cross-compiled x86_64 v1_0 binary
  found 3 dead `wasm_3_0` codegen symbols surviving DCE (x86 legacy-switch br_on_null cohort lacked the
  `if (comptime wasm_v3_plus)` guard arm64 had). Fixed; v1_0 x86 wasm_3_0 3→0. REMAINING D-231 = wire the gate
  (cross-nm x86 in check_build_dce; mechanism validated). D-209 memory64 >4GiB = correctly measure-first-deferred
  (hot-path branch cost, no consumer). D-259 spillBytes = measure-first.
- **Sweep state (2026-06-07 barrier-review)**: safe-actionable items exhausted this cycle. D-231 leak FIXED; its
  gate-wiring is LOW-urgency (check_build_dce only runs at manual main-merge, never in-branch). D-209 (hot-path,
  exotic, no consumer) + D-259 (W54-ABI-risk, zero perf benefit) both correctly stay deferred. **NEXT = either
  re-survey proposal_watch for any newly-Phase-4 proposal, wire another official spec corpus (relaxed-SIMD
  pattern — high-value conformance, may surface more bugs), or D-231 gate-wiring (env-fragile cross-nm, fresh
  context).** **NOT new-proposal features** — stack-switching **DEFERRED
  @D-300** (survey 2026-06-07: Phase-3 unstable format + 3 architecture ADRs + ~25-35cyc — re-survey Phase 4). compact-import/
  memory-control also pre-Phase-4. So pick from `.dev/remaining_sweep.md` Bucket B/C (D-231 build-DCE gate,
  D-209 memory64 >4GiB memarg completeness, D-259 spillBytes measure-first, …) + re-check proposal_watch
  quarterly. **D-299** (inline atomic misaligned-trap, x86_64 W^X stale-page) still open. No tag (ADR-0156).
- Debt ledger: **52 entries** (Bucket A 15 pruned @758ff210; +D-300 stack-switching defer). 0 `now` except
  D-299. Sweep between features, never idle.
- **D-279** Win64 SIMD heisenbug: H3 stack-overflow diagnostic deployed; re-kick windows as work lands to keep
  hunting the reproduction (user: never leave it idle). Mac-side investigation walled (needs the Win64 signal).

## 完成形 v0.1 surface COMPLETE (history — 2026-06-06)

All three surface audits DONE: CLI→**D-295** (~85% + intentionally lean, declines per ADR-0159 ≠ gaps). C-API→
**ZERO gaps** (D-296; 293/293). Zig-API→**COMPLETE** (D-296; `Module.imports/exports` + `Memory.grow/sliceAt` +
`Engine.linker()` + `Linker.defineInstance`; `docs/zig_api_design.md` synced). Memory-safety ALL areas swept
**SOUND** (D-297 cross-module aliasing; WASI fd lifecycle; 3 audit "CRITICAL" labels dissolved under verification
→ discipline: always adversarially verify audit criticals; lesson `fd0a1914`). v0.2 tractable features all DONE
(atomics/wide-arith/custom-page/relaxed-SIMD); forward track = remaining_sweep + completeness (NEVER-IDLE above).

**D-279 (Win64 SIMD-JIT heisenbug)**: hypo H3=Win64 1MB stack overflow; VEH diagnostic landed @`b86ac7fc`
(`[d-279-veh] STACK-OVERFLOW` self-ID → H3 confirmed; exit-3 w/o it → refuted). UNFIRED; silent streak=4. Loop
re-kicks windows per batch to keep hunting. Full detail in the D-279 debt row.

**Blocked / parked**: 31 blocked-by (call_ref §10.R / D-177 WASI-config / D-178 Global-Memory / future proposals).
**D-290** = 3 distillers direction-gated (wasm-tools↔wabt divergence; wabt stays). **D-264** dogfooding gated.

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: re-kicked each turn (D6 always). Verify `[run_remote_ubuntu] OK` in `/tmp/ubuntu.log`. Red →
  auto-revert (D3; first-resume + non-code-gap exceptions apply).
- **windows**: BATCHED (D8). Last batch **OK @b9102acb** (recorded). Re-kick when the next batch threshold fires
  (`should_gate_windows.sh`; ≥6 ABI-risk / ≥12 else). D-279 SIMD crash self-IDs via `[d-279-veh] STACK-OVERFLOW`
  (H3) vs exit-3 w/o it (re-open). NOT auto-revert (D7): reproduces=real bug+fix; flake=`track_heisenbug.sh`+proceed.
- **Gate note**: `OK` = green; `Build Summary: N failed` (no OK) = RED. EXPECTED non-failures: `zig-host-hello`
  exit-42, `--__selftest-crash` exit-70, sha256 `verify: FAIL` (fixture-wrong-constant FALSE lead).

## Key refs

- **ADR-0156** (no autonomous release) · **ADR-0153** (rework campaign) · **ADR-0076** (3-host cadence D6/D7/D8)
  · **ADR-0168** (Phase 17 v0.2 line) · **ADR-0109** (native Zig API) · **ADR-0086** (dispatch_collector migration).
- **D-296** = surface-audit record (C/Zig-API) · **D-297** = cross-module memory-safety audit · **D-279** =
  Win64 SIMD heisenbug (instrumented) · `.dev/proposal_watch.md` = v0.2.0 feature backlog.
