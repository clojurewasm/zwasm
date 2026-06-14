# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active bundle

- **Bundle-ID**: d327-catch_ref
- **Cycles-remaining**: ~3
- **Continuity-memo**: INVESTIGATION COMPLETE 2026-06-14 — full de-risked impl
  contract in `private/notes/d327-catch_ref-plan.md` (read it; no re-derivation
  needed). D-327 = **ADR-0120 D6 Cycle-4+5** (decision already accepted, no new
  ADR). Findings: (1) JIT exnref = interp's shared `*Exception`; reify a heap
  Exception at the landing pad (copy tag_idx + `eh_payload_buf` slots). (2) gap is
  TWO-sided: catch_ref/catch_all_ref landing pad never pushes exnref AND
  `throw_ref` JIT is also a stub (needs symmetric read-back for the round-trip).
  (3) Reps settled: payload slot ↔ `Value{.bits64=u64}` (clean for v0.1 gpr
  types); caught tag_idx via new `rt.eh_thrown_tag_idx` stashed by trampolineCore;
  Exception lifetime via an `EhReifyCtx{allocator,exceptions}` on RuntimeOwned
  (setup.zig:118/996+), mirroring memory_grow_fn default-safe/override.
- **NEXT = Cycle-4a**: jit_abi trailing fields (`reify_exnref_fn`/`eh_reify_ctx`/
  `eh_thrown_tag_idx`) + `defaultReifyExnref` @panic + production `reifyExnref` +
  unit test (reify snapshots tag_idx+payload; clobber-safety). Then 4b trampoline
  stash → 4c landing-pad emit (×2 arch, e2e `drop`→88) → 4d throw_ref read-back
  (round-trip 88) → 5 re-vendor eh from wg-3.0 (UPDATE wasm_3_0_manifest counts).
- **Exit-condition**: JIT catch_ref pushes exnref + throw_ref round-trips, both
  arches green → eh wg-3.0-current, full `zig build test` + 3-host green. (Closes
  D-327; the alpha tag stays separate/user-only.)

## alpha.3 GATE (user-directed 2026-06-14) — close BOTH to "ideal form" before tag

User wants the 3.0 corpus genuinely complete (not "alpha-ready except gaps")
before `v2.0.0-alpha.3`. Two autonomous items gate the tag; close both → tag
surfaces ready (user-only, ADR-0156):
1. **tail-call un-revert** — re-vendor wg-3.0 tail-call (`return_call` +3 /
   `return_call_indirect` +4 asserts) **WITH** `wasm_3_0_manifest.zig` hardcoded
   updates (e2e `i32:306` value + "enumerate 31 asserts" count) in the SAME
   commit (lesson 2026-06-14). Low-risk; **do this FIRST**.
2. **D-327** — the Active bundle above (JIT EH catch_ref/throw_ref) → then eh
   wg-3.0 re-vendor. Bigger, multi-cycle.

## Campaign — spec re-vendor (full detail `private/spec_revendor_campaign.md`)

1.0/2.0/simd/threads CURRENT; gc re-vendored to wg-3.0 `b8e8b16c` (3-host green);
tail-call reverted `a981e5d8` (→ GATE item 1); rest no-drift. Sustainable
mechanism DONE (refdialect.py + runbook). 3.0 corpus = **wg-3.0-current except
tail-call (reverted) + catch_ref EH gap (D-327)**, 3-host green. Both are the
alpha.3 GATE above. D-327 root cause pinned `04e5fae2`.
**The alpha is tag-ready NOW** — `v2.0.0-alpha.3`, tag-only (no Release), user-only
(ADR-0156). Say "tag it" anytime; the catch_ref bundle proceeds independently.

## Current state

- **ROADMAP widget: Phase 17 = IN-PROGRESS (feature line)**. CM + WASI-P2
  wasmtime-equivalent campaign CLOSED 2026-06-13 (corpus 158/0/0).
- **cljw CM-API finished-form campaign CLOSED 2026-06-13** (all 6 cw requests +
  REQ-7 `33e0100c` opened-component-owns-bytes; 3-host green; cljw handovers
  COMPLETED). **D-325 / D-324 CLOSED** (cross-instance ctx fix; memory64×multi-mem
  bulk-op). Detail in git log / ADRs.
- **D-290 CLOSED 2026-06-13 — wabt→wasm-tools migration COMPLETE.** All
  distillers swapped (2_0 / wasmtime_misc / **simd** `fa06c202` 13420/0
  skip-impl 32→0 / **threads** `db72560a` exact-parity 294/0 / 3_0 stale-
  check fix); **`pkgs.wabt` dropped from flake** (`dd1a96e5`). Zero wabt
  invocations remain (spec runners read pre-baked corpora; build.zig
  spectest = `wasm-tools parse`). ONE modern wasm CLI.
- **ADR-0184 COMPLETE** (engine-owned io for C-API WASI; D-255+D-007 closed).
- Mac test/lint green per commit; ubuntu test-all green; windows batch
  green 2026-06-13 (`beb2g2d5a`); local `zig build test-all` green post-REQ-5.

## NEXT (autonomous)

No `now` debt. Recent closes: D-326 (cw REQ-7) `33e0100c`; D-293 slice-4e
`b5af6e2b`. Next actionable (demand-driven long-tail — pick by signal):
- **D-293 remainder** = the GC array.* trampolines only (`array_init_data/copy/
  fill/init_elem/new_data/new_elem`). Each single 0-return from `jitGcArray*`
  mixes ≥6 failure modes (null/OOM/segidx-OOB/dropped-seg/dst+src-OOB) → NOT a
  fixup re-route; proper fix = helper RETURNS A KIND the stub maps. LOW priority,
  conformance-neutral, interp already precise — "else leave" until a GC-on-JIT
  program needs precise array-trap codes. (slice-4e corrected the stale
  `array_oob`-TrapKind recipe: contradicted slice-4c's array-OOB=oob_memory.)
- D-245 → note (RESOLVED, re-audit 2026-06-13; see row).
- Else: §1.3 backlog demand-driven · blocked-by long-tail · D-323.

## Closed-work pointers (detail in git log / ADRs)

- **d314-jit-sandbox CLOSED 2026-06-12** (sandboxing triad; ADR-0179).
  GATE NOTE (D-311): raw-entry-call seed-flaky in `zig build test`; 3-host
  test-all is authority (`releasesafe_jit_failures.md`).
- JIT-correctness 2026-06-12: wasm-3.0 assert_return 880/0 both arches.
  D-318 (note): Rosetta x86_64-macos corpus-JIT SEGVs, local-only.
- **Open user-decision follow-ons**: Tier-2 #5 ILP32/watchOS.

## State at pause (stable baseline)

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. v0.2 features +
  official corpora complete. WASI 0.1 complete. Sandboxing triad everywhere.
- **CM + WASI-P2**: default-ON (ADR-0182); real Rust/Go wasip2 components run
  e2e; typed API (ADR-0183) + cljw CM-API finished-form (open/WitType/labels/
  budget/dropResource/diagnostics); validator rules 1–12; corpus 158/0/0.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env per ADR-0184) ·
  Zig-API complete (docs §3.9) · lean CLI · memory-safety sound ·
  dogfooded into cw v1. Runners ReleaseSafe (ADR-0177).
- Debt ledger: zero `now` rows; rest `blocked-by`/`note` long-tail.

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) · `docs/zig_api_design.md`
  §3.9 (component surface, incl. open/Opened/WitType/dropResource).
- **ADR-0184** (engine-owned io) · **ADR-0183** (typed component API) ·
  **ADR-0179** (sandboxing) · **ADR-0156** (no release) · **ADR-0153**
  (rework) · **ADR-0170/0176/0177** (CM / validation / runners).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311).
