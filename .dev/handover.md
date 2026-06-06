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

## Active bundle (ADR-0118 D6) — Phase 17.3 Custom-page-sizes (v0.2, ADR-0168)

- **Bundle-ID**: 17.3-custom-page-sizes
- **Goal**: implement the Wasm custom-page-sizes proposal — memtype limits flag bit `0x08` (has_page_size) + a
  trailing uleb128 `page_size_log2` (valid ∈ {0 = 1 byte, 16 = 64 KiB default}). With page_size=1, memory.size/
  grow + the min/max limits + bounds are all in BYTE units. W3C Phase-5 v1-parity item.
- **Continuity-memo**: (survey done) LARGE blast radius (~30 hardcoded-65536 sites). Parse currently REJECTS 0x08
  (`sections.zig:913` `flag & ~0x07 → BadValType`). MemoryEntry/MemoryInstance lack a page_size field. Hardcoded
  65536/`<<16`/`>>16`/`>>page_size_log2` sites: `runtime.zig:400/412/420` (growMemory), `setup.zig:172`
  (jitMemoryGrow) + `391-395` (alloc min*ps + 256MiB cap), `instruction/wasm_1_0/memory.zig:165/612`
  (memory.size/grow `wasm_page_size`), **JIT page-count shifts** `arm64/emit.zig:1373` (`encLsrImmW >>16`) +
  `x86_64/op_call.zig:1178` (`encShrRImm8 >>16`) → must become `>> page_size_log2`, `instantiate.zig:1380/1716`,
  `api/instance.zig`, `aot/*`. Validate page_size_log2 ∈ {0,16}; limits cap scales by idx_type (2^32 i32 / 2^48
  i64), NOT the 256MiB host cap.
- **Plan**: ~~chunk 1 parse @27b1b4d7~~ + ~~chunk 2 interp/setup @2af71186~~ + ~~chunk 3 JIT @9e80c94b~~ DONE.
  Engine feature COMPLETE. chunk 3 @9e80c94b: `rt.mem0_page_size_log2` field + variable-shift memory.size emit
  both arches + jitMemoryGrow + cap; 3 edge fixtures 3-arch. **chunk 4 @cd0de2dd: C-API** wasm_memory_size/grow
  in page units (instance via rt.memories[0].page_size_log2, standalone via mi.page_size_log2; default unchanged).
  **17.3-custom-page-sizes COMPLETE — all surfaces (parse+validate+interp+JIT+C-API).** NEXT = verify windows
  confirms the wide-arith+custom-page JIT batch @5a2cb51c (Step 0.7; Mac+ubuntu green) → close 17.3 bundle → open
  next v0.2 feature (proposal_watch: relaxed-SIMD / compact-import / stack-switching / component-model are the
  remaining; relaxed-SIMD is the next W3C-Rec item).
- **17.1-atomics DONE 3-host @9eb84833** (fence+load/store/rmw/cmpxchg+notify/wait, interp+JIT; D-028 win flake
  noted). **17.2-wide-arith DONE @231d4536** (add128/sub128/mul_wide_s/u, interp+JIT both arches; Mac+ubuntu green
  @aa95e204, windows batched 5/12). **D-299** (inline load/store JIT misaligned-trap) still DEFERRED.
- **Exit-condition**: a `(memory 1 1 (pagesize 0))`-style module (page_size=1) green 3-host: parse+validate,
  memory.size returns the byte count, memory.grow by N bytes, load/store at byte-granular addr.
- **Cycles-remaining**: ~3-4 (LARGE: ~30 sites parameterised across parse/validate/setup/interp/JIT). No tag.

## Current state

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168); **17.1-atomics DONE+3-host-confirmed @9eb84833** (full op set,
  interp+JIT both arches; win lone fail = D-028 known flake). **17.2-wide-arith DONE @231d4536** (4 ops,
  interp+JIT both arches; Mac+ubuntu green @aa95e204, windows batched). Now **17.3-custom-page-sizes ACTIVE**
  **COMPLETE @cd0de2dd** — all surfaces (parse+validate+interp+JIT+C-API); engine 3 edge fixtures 3-arch.
  NEXT = windows-confirm batch → close 17.3 bundle → open next v0.2 feature (relaxed-SIMD). D-299 deferred.
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
