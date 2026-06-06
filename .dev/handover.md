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
- **DONE @9971b708**: `atomic.fence` (0xFE 0x03) END-TO-END — the 0xFE prefix pipeline is now live in BOTH
  validator (`dispatchPrefixFE`) + lower (`emitPrefixFE`); interp shares `nopOp`; arm64+x86_64 emit transparent
  0→0 no-op; liveness stackEffect 0→0; `test/edge_cases/p17/atomics/fence` green (=42); build.zig wires p17 edge
  dir; emit_test_local unsupported-probe retargeted fence→rmw.cmpxchg.
- **i32.atomic.load Chunk A DONE @219e7d58** (validate/lower/interp + `Trap.UnalignedAtomic` + `TrapKind
  .unaligned_atomic`=14): 裏取り'd atomics need NO shared memory (wasm-tools `check_shared_memarg` — only EXACT
  static align + a memory). validator `opAtomicLoad`/`readMemargCheckAlignExact` (==natural, not ≤); interp
  alignment-trap BEFORE bounds (spec exec 8<14a); stackEffect 1→1.
- **NEXT (current chunk)**: `i32.atomic.load` **Chunk B = JIT emit** — mirror `i32.load`, which uses the
  dispatch_collector (NOT a switch arm): (1) meta `src/instruction/<level>/i32_atomic_load.zig` (op_tag +
  `wasm_level` — pick/confirm the threads WasmLevel; cf. `instruction/wasm_1_0/i32_load.zig`); (2) arm64+x86_64
  per-op files `ops/<level>/i32_atomic_load.zig` → call `op_memory.emitMemOp`; (3) APPEND to `collected_ops`
  registry; (4) add `.@"i32.atomic.load"` arm (access_size=4, LDR/MOV) to BOTH `op_memory.zig:emitMemOp`
  (arm64@77, x86_64@69). **Chunk B2** = RUNTIME align-trap: AND ea,#3 + cond-branch to a NEW trap stub
  (`jitTrapCode`=14 `unaligned_atomic`, mirror oob_fixups/bounds_check both arches). Heed
  `dispatch_consistency_audit` (ZirOp=per-op-file=handler count). edge fixtures: aligned (=val) + misaligned
  `expect trap`. THEN store → rmw set → cmpxchg → i64 → shared-mem gate → notify/wait.
- **Exit-condition**: a `test/edge_cases/p17/atomics/*` (or spec atomics manifest) green 3-host with the full
  load/store/rmw/cmpxchg set + fence; wait/notify minimal-single-thread; shared-mem parse+validate.
- **Cycles-remaining**: ~many (large feature). No tag (ADR-0156).

## Current state

- **Phase 17 (v0.2 feature line) IN-PROGRESS** (ADR-0168, user-unblocked); 17.1-atomics bundle ACTIVE, fence
  milestone DONE @9971b708. Phase 16 (完成形) DONE; v0.1 surface audited+documented+exampled, memory-safety swept
  SOUND, dogfooding DONE (cw v1). No release/tag ever (ADR-0156).
- Debt ledger: **65 entries, 0 `now`** (D-264 dogfooding discharged). Remaining = `.dev/remaining_sweep.md`
  (Bucket A prune / B actionable-low / C deferred / D externally-blocked) — sweep between features, never idle.
- **D-279** Win64 SIMD heisenbug: H3 stack-overflow diagnostic deployed; re-kick windows as work lands to keep
  hunting the reproduction (user: never leave it idle). Mac-side investigation walled (needs the Win64 signal).

## ← LEAD: 完成形 surface work COMPLETE; entering maintenance/depth (2026-06-06 session)

**All three surface audits DONE** (user-steered direction): CLI→**D-295** (~85% + intentionally lean; declines
per ADR-0159 ≠ gaps; `--env` shipped). C-API→**ZERO gaps** (D-296; `capi_surface_gap.sh` 293/293; Phase-13
conformance verified+exceeded). Zig-API→**COMPLETE** (D-296): closed gap#1 (`Module.imports/exports`) + ALL
implementable residuals this session — `Memory.grow` (`f163e882`, shared `Runtime.growMemory`, test-spec 9/0),
`Memory.sliceAt` (`e5f34ff8`), `Engine.linker()` (`994a5aef`), `Linker.defineInstance` (`dba99bb8`, all 4 export
kinds). Surface reviewed CLEAN (subagent, no HIGH/MED), `docs/zig_api_design.md` synced (`e120cc15`), example
introspection demo (`40553679`).

**Memory-safety (完成形 dimension) — ALL major manual-memory areas now swept SOUND**: facade additions reviewed
clean; **cross-module aliasing** (**D-297**) SOUND (zombie-parking; disproved a table-UAF; documented the
Linker-outlives-Instances contract `477a9004`); **WASI fd lifecycle** swept this turn → SOUND (no double-close /
UAF / realloc-bug; stdio correct; Host correctly BORROWS preopen handles; `path_open` unimplemented so no owned
fds; the CLI preopen fds are an intentional documented process-lifetime choice run.zig:62, not a leak). The
audit's "fd-leak REAL BUG" was the **3rd overstated finding this session** to dissolve under verification.
**Discipline: always adversarially verify audit "CRITICAL" labels** (table-UAF, fd-leak, Linker-#6 all overstated).

**D-279 (Win64 SIMD-JIT heisenbug — the one open RED-class issue)**: RESURFACED @d0c5b737 (3 SIMD crashes:
test.exe + spec-simd + wasm-2-0-assert, all exit-3; segv recorded streak→0). MAJOR NARROWING: the `[d-279-veh]`
diagnostic did NOT fire + NO panic message + NO 0xC0000005 in the log → **NOT a VEH hardware fault, NOT a
standard panic**. New **leading hypothesis H3 = Win64 1 MB stack overflow** (vs Mac/Linux 8 MB): a deep SIMD test
path fitting 8 MB but overflowing 1 MB → Win64-only + intermittent-by-depth + no-message + not-VEH-caught (filter
excludes EXCEPTION_STACK_OVERFLOW per ADR-0105 D4). Fits ALL evidence + the deep-stack lineage. Full analysis +
next-diagnostic (re-add EXCEPTION_STACK_OVERFLOW to the VEH filter with a `[d-279-veh] stack-overflow` log) in
D-279. NOT auto-reverted (D7; ubuntu 8 MB green every time, facade exonerated).

**D-279 H3 diagnostic LANDED + Win64-VALIDATED** (`b86ac7fc`): `EXCEPTION_STACK_OVERFLOW` VEH arm → minimal
`[d-279-veh] STACK-OVERFLOW` WriteFile (diagnostic-only, ADR-0105 D4 stands), build-validated + deployed but
UNFIRED (streak silent 2). A FUTURE Win64 D-279 crash self-identifies: `[d-279-veh] STACK-OVERFLOW` → H3
CONFIRMED (extend the stack-limit guard to the overflowing path); exit-3 WITHOUT it → H3 refuted (re-open
enumeration). Pending external signal — the loop keeps re-kicking windows per batch so a repro is always hunted.

完成形 v0.1 surface (C/Zig/CLI) audited+documented+exampled; memory-safety all areas SOUND; debt swept;
proposal_watch current (2026-04-30); audit-overstatement lesson `fd0a1914`. Forward track now = **v0.2 features**
(atomics bundle ACTIVE) + remaining_sweep between features (NEVER-IDLE above).

**Blocked / parked**: 31 blocked-by (call_ref §10.R / Phase-11 D-177 WASI-config / D-178 standalone Global-Memory /
future proposals). **D-290** = 3 proposal-laden distillers, direction-gated (wasm-tools↔wabt output divergence;
wabt stays). **D-264** ClojureWasm dogfooding gated. `.dev/proposal_watch.md` = v0.2.0 backlog.

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: re-kicked each turn (D6 always). Verify `[run_remote_ubuntu] OK` in `/tmp/ubuntu.log`. Last GREEN
  @`660bb771`. Red → auto-revert (D3).
- **windows**: @`487e4bbd` run finished **clean GREEN** (`OK.` present, simd 13351/0, no veh, no exit-3) →
  D-279 silent **streak 3** (toward discharge-5); batch recorded @`92c8fb3b`. No kick pending — re-kicks when the
  next batch fires (≥6 ABI-touch / ≥12 else since 92c8fb3b). Future crash self-IDs via `[d-279-veh]
  STACK-OVERFLOW` (H3 CONFIRMED) vs SIMD exit-3 w/o it (segv, re-open). NOT auto-revert (D7). Don't poll-wait.
- **Gate note**: `OK` = green; `Build Summary: N failed` (no OK) = RED. EXPECTED non-failures: `zig-host-hello`
  exit-42, `--__selftest-crash` exit-70, sha256 `verify: FAIL` (fixture-wrong-constant FALSE lead).

## Key refs

- **ADR-0156** (no autonomous release) · **ADR-0153** (rework campaign) · **ADR-0076** (3-host cadence D6/D7/D8)
  · **ADR-0109** (native Zig API) · **ADR-0014 §2.1** (zombie-parking lifetime, D-297).
- **D-296** = surface-audit record (C/Zig-API) · **D-297** = cross-module memory-safety audit · **D-279** =
  Win64 SIMD heisenbug (instrumented) · `.dev/proposal_watch.md` = v0.2.0 feature backlog.
