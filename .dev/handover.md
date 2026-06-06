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

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168). DONE+3-host: **17.1-atomics @9eb84833** · **17.2-wide-arith
  @231d4536** · **17.3-custom-page-sizes @cd0de2dd** · **17.4-relaxed-SIMD @08342ec5** (delta 0→**20 ops** JIT
  both arches: swizzle/trunc×4/madd-nmadd×4/laneselect×4/min-max×4/q15mulr/dot/dot_add; +ADR-0169 per-arch
  hardware semantics; emit_test probe → `memory.discard`). 20/20 edge fixtures green Mac; **dots 7b/7c (new x86
  PMADDUBSW/PMADDWD codegen) await ubuntu+windows confirm** at next Step 0.7 (D3/D7). **NEXT = verify dots
  3-host, then open next v0.2 feature** (proposal_watch: compact-import / stack-switching / component-model →
  v0.3) OR sweep `.dev/remaining_sweep.md`. No tag (ADR-0156). **D-299** (inline load/store
  JIT misaligned-trap) still DEFERRED. Phase 16 (完成形) DONE. No release/tag ever (ADR-0156).
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
features** (17.4 relaxed-SIMD ACTIVE) + remaining_sweep between features (NEVER-IDLE above).

**D-279 (Win64 SIMD-JIT heisenbug — one open RED-class)**: leading hypo **H3 = Win64 1 MB stack overflow** (vs
Mac/Linux 8 MB). H3 diagnostic LANDED+validated @`b86ac7fc` (`EXCEPTION_STACK_OVERFLOW` VEH → `[d-279-veh]
STACK-OVERFLOW` WriteFile, diagnostic-only) but UNFIRED. Future crash self-IDs: `[d-279-veh] STACK-OVERFLOW` → H3
CONFIRMED (extend stack-limit guard to that path); exit-3 WITHOUT it → H3 refuted (re-open). Loop re-kicks windows
per batch so a repro is always hunted.

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
