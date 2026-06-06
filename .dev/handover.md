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

## Active bundle (ADR-0118 D6) — Phase 17.1 Threads/Atomics (v0.2, ADR-0168)

- **Bundle-ID**: 17.1-atomics
- **Goal**: implement the WebAssembly threads/atomics `0xFE`-prefix op set (ZirOps already reserved
  `zir_ops.zig:596+`). Single-threaded substrate (ADR-0168): atomic load/store/rmw/cmpxchg = aligned seq-cst
  memory ops; `atomic.fence` = no-op; wait→trap-on-non-shared / notify→0.
- **Continuity-memo**: 0xFE prefix dispatch now LIVE in `lower.zig:emitPrefixFE` + `validator.zig
  :dispatchPrefixFE` (mirrors 0xFD). Remaining-absent: shared-mem flag still HARD-REJECTED
  (`parse/sections.zig:903` `is_shared→BadValType`) — only needed for wait/notify + spec shared fixture, NOT
  load/store/rmw (atomics need a memory but not a shared one). EXACT natural-align + runtime align-trap are the
  subtle correctness points (validator + per-arch JIT). ZirOp/per-op-file count consistency watch.
- **DONE**: `atomic.fence` (0x03) @9971b708 (no-op). **ALL atomic LOADS + STORES** (0x10-0x1d) — loads @e1a18357,
  stores @e6c22a57(non-JIT)+@85b8f150(JIT). Pattern: validate `opAtomicLoad`/`opAtomicStore` (EXACT natural align,
  `readMemargCheckAlignExact`; atomics need NO shared mem per wasm-tools `check_shared_memarg`) + lower emitMemarg
  + interp (`atomicLoadU`/`atomicStoreEa`, alignment-trap BEFORE bounds spec exec 8<14a, `Trap.UnalignedAtomic`/
  `TrapKind.unaligned_atomic`=14) + JIT-plain via emitMemOp arms+aliases + liveness. Both arches; edge+unit green.
- **D-299 (JIT misaligned-trap) = DEFERRED, ENV-CONSTRAINED**: B2's x86_64 runtime align-trap didn't fire (native
  ubuntu, reliable). My Mac/Rosetta investigation harness is UNRELIABLE (got-i32:0 vs NotImplemented for the same
  fixture across runs; load-only-atomic works fine on arm64 — so the iso NotImplemented was a harness artifact).
  Needs a reliable native-x86_64 + lldb env to crack (Mac/Rosetta can't). Error-path-only (well-formed programs
  never unalign atomics; threads spec-suite not yet wired → gate green). Interp traps correctly; the central
  `emitMemOp` JIT align-trap is the single D-299 fix that covers ALL atomic ops once cracked.
- **ALL atomics INTERP DONE** (0x10-0x4e): loads+stores+rmw(@96231c18)+cmpxchg(@78aa7dd2). **Shared-memory parse
  gate OPEN @b54059fc** (limits 0x02; shared needs max; MemoryEntry/MemoryInstance.shared threaded; edge
  shared_mem=42). loads+stores+**rmw** have JIT; cmpxchg does NOT yet.
- **load/store JIT x86_64 now CORRECT @fbdefda9** (Win64 gate caught 2 x86_64-only bugs; cracked via Rosetta
  hexdump-diff): (1) `emitMemOp` is_store/access_size/is_fp store-groups were missing the 7 atomic-store tags
  (store-JIT partial-apply gap) → `i32.atomic.store` hit `access_size else=>unreachable` compile-panic; (2)
  `usage.usesRuntimePtr` missed ALL atomic load/store → an atomics-only fn got the uses_runtime_ptr=false 4-byte
  prologue (no MOV R15) → load/store read garbage vm_base, returned 0 (D-180-class; arm64 immune, X19 always set).
  `i32_atomic_store.wasm` (atomic store+load, no plain memop) is the regression fixture. Add rmw/cmpxchg to
  usesRuntimePtr when their JIT lands. `check_uses_runtime_ptr.sh` did NOT catch the memop gap (only trap-stub
  drift) — detection-script gap noted, not blocking.
- **rmw JIT DONE @5b38c895** (callout, both arches): 42 `tNN.atomic.rmw*` → C-ABI callout through new TRAILING
  `JitRuntime.atomic_rmw_fn` slot (keeps @offsetOf stable). `defaultAtomicRmw` IS the prod impl (no host state).
  4-arg marshal (rt, ea, operand, opcode) mirrors table.grow; conflict-free (arg regs not allocatable, compile-
  asserted); offset folded into ea. Helper sets trap_flag on unaligned/oob → epilogue raises (no post-call check,
  like memory.grow); Zig-side align-check → **rmw sidesteps the inline D-299 gap** (jitTrapCode 14). usesRuntimePtr
  + regalloc_compute (force-spill) classify it; `rmwMapOf`/`isAtomicRmw` in jit_abi = single ABI source. 8 fixtures
  green 3-arch incl. **crossing-clobber (459008)** + i64 res64.
- **NEXT = cmpxchg JIT** (7 ops `tNN.atomic.rmw*.cmpxchg*`): mirror rmw, but 5 args (rt, ea, expected,
  replacement, opcode) → on Win64 the 5th is a STACK arg (only 4 GPR arg slots; SysV/arm64 fit in regs). Decide:
  pass opcode on the Win64 stack (use emitShadowAlloc + an outgoing slot) OR fold (e.g. width into a spare). Add a
  `atomic_cmpxchg_fn` slot (TRAILING) + `cmpxchgMapOf`/`isAtomicCmpxchg` in jit_abi + add cmpxchg ops to
  usesRuntimePtr+regalloc_compute (the isAtomic* predicates). THEN notify/wait (0x00-0x02 — wait→trap-on-non-
  shared, notify→0). 3-host RUN-verifies x86_64 (Rosetta proven reliable this session; revert-on-red like B2).
- **Exit-condition**: a `test/edge_cases/p17/atomics/*` (or spec atomics manifest) green 3-host with the full
  load/store/rmw/cmpxchg set + fence; wait/notify minimal-single-thread; shared-mem parse+validate.
- **Cycles-remaining**: ~many (large feature). No tag (ADR-0156).

## Current state

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168); 17.1-atomics ACTIVE: fence+loads+stores+**rmw** full JIT; ALL
  INTERP done @78aa7dd2; NEXT = **cmpxchg JIT** then notify/wait. rmw callout cracks its own align-trap (D-299
  remains only for inline load/store).
  Phase 16 (完成形) DONE. No release/tag ever (ADR-0156).
- Debt ledger: **65 entries, 0 `now`** (D-264 dogfooding discharged). Remaining = `.dev/remaining_sweep.md`
  (Bucket A prune / B actionable-low / C deferred / D externally-blocked) — sweep between features, never idle.
- **D-279** Win64 SIMD heisenbug: H3 stack-overflow diagnostic deployed; re-kick windows as work lands to keep
  hunting the reproduction (user: never leave it idle). Mac-side investigation walled (needs the Win64 signal).

## 完成形 v0.1 surface COMPLETE (history — 2026-06-06)

All three surface audits DONE: CLI→**D-295** (~85% + intentionally lean, declines per ADR-0159 ≠ gaps). C-API→
**ZERO gaps** (D-296; 293/293). Zig-API→**COMPLETE** (D-296; `Module.imports/exports` + `Memory.grow/sliceAt` +
`Engine.linker()` + `Linker.defineInstance`; `docs/zig_api_design.md` synced). Memory-safety ALL areas swept
**SOUND** (D-297 cross-module aliasing; WASI fd lifecycle; 3 audit "CRITICAL" labels dissolved under verification
→ discipline: always adversarially verify audit criticals; lesson `fd0a1914`). Forward track now = **v0.2
features** (atomics bundle ACTIVE) + remaining_sweep between features (NEVER-IDLE above).

**D-279 (Win64 SIMD-JIT heisenbug — one open RED-class)**: leading hypo **H3 = Win64 1 MB stack overflow** (vs
Mac/Linux 8 MB). H3 diagnostic LANDED+validated @`b86ac7fc` (`EXCEPTION_STACK_OVERFLOW` VEH → `[d-279-veh]
STACK-OVERFLOW` WriteFile, diagnostic-only) but UNFIRED. Future crash self-IDs: `[d-279-veh] STACK-OVERFLOW` → H3
CONFIRMED (extend stack-limit guard to that path); exit-3 WITHOUT it → H3 refuted (re-open). Loop re-kicks windows
per batch so a repro is always hunted.

**Blocked / parked**: 31 blocked-by (call_ref §10.R / D-177 WASI-config / D-178 Global-Memory / future proposals).
**D-290** = 3 distillers direction-gated (wasm-tools↔wabt divergence; wabt stays). **D-264** dogfooding gated.

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: re-kicked each turn (D6 always). Verify `[run_remote_ubuntu] OK` in `/tmp/ubuntu.log`. @`92c8fb3b`
  was RED — `wast_runtime_runner.zig:967 trapKindName` missed `unaligned_atomic` (test-all-only runner; Mac `zig
  build test` doesn't compile it). FORWARD-FIXED @`5202d0b0` (lesson `trapkind-variant-breaks-test-all-only-
  runner-switch` — should've run `zig build test-runtime-runner-smoke` pre-push; verified 5/0). Verify GREEN this
  resume @ new HEAD. Red → auto-revert (D3).
- **windows**: batch kicked @`6944105f` came back **RED** — but it was the **p17 atomic-store COMPILE crash**
  (exit-3, `op_memory.zig:144 else=>unreachable`), a real x86_64 bug NOT D-279 (per D7: investigated → real →
  FIXED @`fbdefda9`). **D-279 itself stayed silent** in that same run (simd_assert_runner 13351/0, no veh, no
  exit-3 from SIMD) → silent streak holds. **Re-kick windows this turn** to confirm the atomics fix is green on
  Win64 (the gate's value: it caught a bug Mac+ubuntu's `zig build test`-only path could miss until edge-RUN).
  Future SIMD crash self-IDs via `[d-279-veh] STACK-OVERFLOW` (H3) vs exit-3 w/o it (re-open). NOT auto-revert (D7).
- **Gate note**: `OK` = green; `Build Summary: N failed` (no OK) = RED. EXPECTED non-failures: `zig-host-hello`
  exit-42, `--__selftest-crash` exit-70, sha256 `verify: FAIL` (fixture-wrong-constant FALSE lead).

## Key refs

- **ADR-0156** (no autonomous release) · **ADR-0153** (rework campaign) · **ADR-0076** (3-host cadence D6/D7/D8)
  · **ADR-0109** (native Zig API) · **ADR-0014 §2.1** (zombie-parking lifetime, D-297).
- **D-296** = surface-audit record (C/Zig-API) · **D-297** = cross-module memory-safety audit · **D-279** =
  Win64 SIMD heisenbug (instrumented) · `.dev/proposal_watch.md` = v0.2.0 feature backlog.
