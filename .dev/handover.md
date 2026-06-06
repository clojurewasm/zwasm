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

## Current state

- **Phase 16 (完成形) — open-ended; the loop CONTINUES, no release (ADR-0156).** Phases 0–15 DONE;
  v0.1.0-scope complete + 3-host green. Tag/publish/cutover are manual, user-only — no release gate.
- Debt ledger: **66 entries, 0 `now`** (D-213 discharged this turn). All remaining = blocked-by future phases /
  notes (QoI/exotic/historical) / 3 partial. No actionable HIGH-value item open (verified §0.5 sweep 2026-06-06).

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
`[d-279-veh] STACK-OVERFLOW` WriteFile (diagnostic-only, ADR-0105 D4 stands). Windows run @`660bb771` was GREEN
(D-279 did NOT reproduce — intermittent; streak silent 1) so the H3 diag is build-validated + deployed but
UNFIRED. A FUTURE Win64 D-279 crash now self-identifies: prints `[d-279-veh] STACK-OVERFLOW` → H3 CONFIRMED
(extend the stack-limit guard to the overflowing path); exit-3 recurs WITHOUT it → H3 refuted (re-open
enumeration). This is the pending external signal.
**HIGH-VALUE AUTONOMOUS WORK IS COMPLETE.** Surface (C/Zig/CLI) audited+documented+exampled; memory-safety all
areas swept SOUND; D-279 maximally instrumented; debt swept; proposal_watch current (2026-04-30); audit-overstatement
lesson captured (`fd0a1914`). Remaining is genuinely user-gated (v0.2 features, dogfooding) or external-signal-gated
(D-279 next-crash). NOT padding low-ROI items (exotic D-209, 4th audit). The loop now mostly verifies gates + awaits
a Win64 crash signal or user direction on v0.2 priorities.

**Blocked / parked**: 31 blocked-by (call_ref §10.R / Phase-11 D-177 WASI-config / D-178 standalone Global-Memory /
future proposals). **D-290** = 3 proposal-laden distillers, direction-gated (wasm-tools↔wabt output divergence;
wabt stays). **D-264** ClojureWasm dogfooding gated. `.dev/proposal_watch.md` = v0.2.0 backlog.

## Step 0.7 (next resume) — verify remote logs

- **ubuntu**: re-kicked each turn (D6 always). Verify `[run_remote_ubuntu] OK` in `/tmp/ubuntu.log`. Last GREEN
  @`660bb771`. Red → auto-revert (D3).
- **windows**: BATCHED (D8). Last GREEN @`660bb771` (`--record`ed; H3 diag validated, D-279 did not reproduce).
  Red → NOT auto-revert; **first grep `[d-279-veh] STACK-OVERFLOW`** — if present = H3 CONFIRMED (extend stack
  guard); if a SIMD exit-3 crash WITHOUT it = D-279 (`track_heisenbug.sh win64-testall segv` + proceed, re-open
  H-enumeration). Don't poll-wait.
- **Gate note**: `[run_remote_windows] OK` = real green; `Build Summary: N failed` (no OK) = RED. EXPECTED
  non-failures: `zig-host-hello` exit-42 + `--__selftest-crash` exit-70 "failed command"; the sha256 `verify:
  FAIL` line is the known fixture-wrong-constant FALSE lead (zwasm hashes correctly).

## Key refs

- **ADR-0156** (no autonomous release) · **ADR-0153** (rework campaign) · **ADR-0076** (3-host cadence D6/D7/D8)
  · **ADR-0109** (native Zig API) · **ADR-0014 §2.1** (zombie-parking lifetime, D-297).
- **D-296** = surface-audit record (C/Zig-API) · **D-297** = cross-module memory-safety audit · **D-279** =
  Win64 SIMD heisenbug (instrumented) · `.dev/proposal_watch.md` = v0.2.0 feature backlog.
