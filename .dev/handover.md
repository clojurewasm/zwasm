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

## Active bundle (ADR-0118 D6) — Phase 17.4 Relaxed-SIMD (Phase-5/W3C-Rec, v0.1.0-completeness)

- **Bundle-ID**: 17.4-relaxed-simd
- **Goal**: implement the 18 relaxed-SIMD ops (0xFD prefix, sub-opcodes **0x100–0x113**) across all surfaces
  (validate+lower+liveness+interp+JIT-both-arches). Already declared in ZirOp enum (`zir_ops.zig:563-582`); zero
  impl today (only an emit_test probe uses `f32x4.relaxed_madd` as the reserved-unimpl marker → must re-point).
  This is a **Phase-5 (W3C Rec / Wasm 3.0) v0.1.0-completeness gap**, not a strict v0.2 item (proposal_watch L29).
- **Determinism choices (uniform interp↔JIT↔both-arches — the v2 DIVERGENCE vs v1's interp/x86 split)**:
  madd/nmadd = **always FMA** (`@mulAdd` / arm64 FMLA / x86 VFMADD or `@mulAdd` lowering — NEVER unfused
  fallback); swizzle OOB idx→**0**; trunc NaN/OOB→**saturating clamp**; laneselect=**full bitselect**
  `(a&m)|(b&~m)`; min/max=**hardware FMIN/FMAX** (non-NaN operand, -0<+0); q15mulr overflow→**INT16_MAX**;
  dot treats b as **signed i8**. v1 oracle (read-only): `~/Documents/MyProducts/zwasm/src/vm.zig:3855-3989`.
- **Continuity-memo**: wiring map (survey @this cycle) — validator `validator_simd.zig:dispatchPrefixFD` (else→NotImpl @306) +
  lower `lower_simd.zig:emitPrefixFD` (else→NotImpl @385) + `liveness_stack_effect.zig` (need 3-pop entries for
  madd×4/laneselect×4/dot_add, 2-pop rest — mirror `v128.bitselect` @686) + interp (SIMD currently JIT-only;
  per-op instruction stubs `error.NotMigrated`) + JIT both arches (dispatch_collector preferred per ADR-0086, or
  legacy switch `emit.zig:1909ff`). Stack pop order 3-op = c,b,a.
- **Plan** (NOTE: 20 relaxed ops total, not 18 — earlier miscount): chunks 1-6 + 7a DONE.
  ~~front-end @f27eee15~~ ~~swizzle @6e044e92~~ ~~trunc @3dab4e24~~ ~~min/max+ADR-0169 @1fd3a614~~
  ~~madd/nmadd @cb781fd3~~ ~~laneselect @4ab9f77a~~ ~~q15mulr @dc7eec0a~~. **18/20 JIT both arches.**
  **NEXT chunk7b = the 2 dot products (LAST)** then close bundle:
  - `i16x8.relaxed_dot_i8x16_i7x16_s` (0x112, 2-pop) → i16x8[i]=a[2i]·b[2i]+a[2i+1]·b[2i+1]. **x86**: single
    PMADDUBSW(a,b) (a unsigned, b signed — the relaxed latitude; need encPmaddubsw, SSSE3 `66 0F 38 04`).
    **arm64**: SMULL Vt.8H,a.8B,b.8B + SMULL2 (high) → 16 i16 products; ADDP Vd.8H,lo,hi → adjacent pairs summed
    (need encSmull8H/encSmull2_8H/encAddp8H). No sat for i7-range b (fixtures stay small → cross-arch identical).
  - `i32x4.relaxed_dot_i8x16_i7x16_add_s` (0x113, **3-pop** a,b,c) → (dot i16x8 then pairwise-widen-add to i32x4)
    +c. **x86**: PMADDUBSW(a,b)→i16x8; PMADDWD(·, ones_i16)→i32x4 (need encPmaddwd + ones const-pool); PADDD(+c).
    **arm64**: SMULL+SMULL2+ADDP→i16x8; SADDLP Vd.4S,·.8H→i32x4 (need encSaddlp4S); ADD.4S +c. 3-operand staging
    (mirror emitV128FpFma / bitselect). After 7b: bundle exit-condition (all 20 run, relaxed_madd FMA observable)
    + re-point check + `check_bundle_active --close`.
  **JIT routes**: chunk2 = dispatch_collector per-op files (+count bump dispatch_collector.zig); chunks 3-7a =
  **legacy switch** in `{arm64,x86_64}/emit.zig` (lighter; no per-op file/count bump). New encoders go in
  inst_neon_arith (arm64) / inst_sse_packed+inst.zig re-export (x86). **ADR-0169**: per-arch hardware, fixtures
  finite/exact → one `.expect` 3-host. Fixtures: wat2wasm `--enable-relaxed-simd`, `zig build test-edge-cases`.
  emit_test UnsupportedOp probe uses `memory.discard` (stable).
- **Tests**: 7 upstream wast at `~/Documents/OSS/WebAssembly/testsuite/{relaxed_madd_nmadd,relaxed_laneselect,
  relaxed_min_max,i8x16_relaxed_swizzle,i32x4_relaxed_trunc,i16x8_relaxed_q15mulr_s,relaxed_dot_product}.wast`
  — use `(either ...)` 2-outcome asserts (impl-defined latitude); runner `test/spec/simd_assert_runner.zig`,
  regen `scripts/regen_spec_simd_assert.sh`. New corpus dir under `test/spec/`. Plus `test/edge_cases/p17/relaxed_simd/`.
- **Exit-condition**: all 18 ops validate+lower+run; relaxed_madd FMA-path observable (FLT_MAX×2−FLT_MAX→FLT_MAX
  not inf) green 3-host; the emit_test reserved-unimpl probe re-pointed to a still-unimpl op (v0.3 candidate).
- **Cycles-remaining**: ~5 (18 ops, 5 families, JIT×2 arch each). No tag.

## Current state

- **Phase 17 (v0.2) IN-PROGRESS** (ADR-0168). DONE+3-host: **17.1-atomics @9eb84833** · **17.2-wide-arith
  @231d4536** · **17.3-custom-page-sizes @cd0de2dd** (all surfaces parse+validate+interp+JIT+C-API). The
  wide-arith+custom-page JIT batch is **windows-confirmed green @b9102acb** (size_1byte=1, grow_bytes=11,
  load_store=1611516670, wide mul/sub all PASS; simd 13351/0, D-279 silent streak=1). Now **17.4-relaxed-SIMD
  ACTIVE** (front-end @f27eee15; JIT swizzle/trunc/min-max/madd-nmadd/laneselect/q15mulr done @dc7eec0a,
  +ADR-0169; **18/20 ops** run both arches, edge fixtures green Mac+ubuntu(+Win64 for chunks 1-4). NEXT =
  chunk7b 2 dot products = LAST → close 17.4 bundle). **D-299** (inline load/store
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
