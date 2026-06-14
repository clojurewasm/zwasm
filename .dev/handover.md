# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## D-327 REFRAMED 2026-06-14 (investigation; premise was a MISDIAGNOSIS)

Direct probing corrected the bundle's premise. KEY FACTS (high-confidence):
- **EH try_table corpus is ALREADY wg-3.0-current**: committed raw = upstream
  `exception-handling/test/core/try_table.wast` (BOTH 34 assert_returns, identical
  exports). NO new asserts to add. The debt-row D-327 claim "EH +5 multi-value" is
  STALE.
- **EH spec runner is 100% GREEN now**: `[exception-handling] return 34/34, trap
  2/2, invalid 7/7, exception 4/4`. catch_ref asserts pass because the wast
  `(drop)`s the exnref + checks only the param (wast line 158). NO assert validates
  exnref VALUE at runtime; exnref-using cases (wast 354-5) are `assert_invalid`.
- So **the JIT exnref garbage + throw_ref stub is CONFORMANCE-NEUTRAL** — a genuine
  JIT *completeness* gap (interp-correct, JIT-wrong) that NO spec assert exercises.
  It does NOT block the alpha's "100% latest spec" for EH, and does NOT block
  EH-wg-3.0-currency. The bundle's "catch_ref FAILsetup" premise was wrong.
- **Cycle-4a infra is still correct + kept** (`8478d853`: reify fields/helper/test).
  It's the substrate for the genuine completeness work IF pursued — but that work
  is now decoupled from the alpha gate.

## Active bundle — JIT exnref completeness (user chose "do it now" 2026-06-14)

- **Bundle-ID**: d327-exnref-jit  **Cycles-remaining**: ~3
- **Continuity-memo**: conformance-neutral but user chose "do it now" (ideal form).
  RED CONFIRMED: `zwasm run --engine jit --invoke roundtrip` → **trap**; interp →
  **88**. Strong test = throw_ref ROUND-TRIP (not the weak drop test). NEXT = 4b+4c+4d
  in one chunk — full execution contract + fixture bytes + emit mechanics (Explore
  survey) in `private/notes/d327-catch_ref-plan.md` → "EXECUTION CONTRACT": 4b
  trampoline tag stash · 4c landing-pad reify+push both arches (extend `any_payload`
  for `_ref`; exnref vreg = slot the param prelude does NOT fill) · 4d throw_ref
  read-back · setup.zig install reifyExnref+ctx. Win64 arg0=RCX = ABI-risk. Cycle-4a
  infra `8478d853` is the substrate.
- **Exit-condition**: JIT round-trip returns 88 both arches; full `zig build test` +
  lint + 3-host green.

## Parallel track — wg-3.0 currency re-verification (the conformance gate)

Debt-row D-327's EH claim was stale → RE-VERIFY each proposal's wg-3.0 currency via
the runbook (checkout wg-3.0/proposal HEAD → re-bake → diff manifest). Confirmed
current: EH try_table (34=34), tail-call (`21959b5f`). TO CHECK: gc (debt claims
extern+13 — suspect), function-references, memory64, multi-memory, simd, threads.

## alpha.3 GATE (user-directed 2026-06-14) — "ideal form" before tag

Two autonomous tracks gate the tag (user-only, ADR-0156): (1) the Active bundle
above (JIT exnref completeness — user's ideal-form call) + (2) the Parallel track
(wg-3.0 currency re-verification). Sustainable mechanism DONE (refdialect.py +
runbook). 1.0/2.0/simd/threads current; gc `b8e8b16c`; tail-call DONE `21959b5f`;
EH wg-3.0-current. **Conformance-wise the alpha is essentially ready** (`v2.0.0-
alpha.3`, tag-only, no Release); the two tracks pursue genuine completeness +
per-proposal re-verification before surfacing "tag it".

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
