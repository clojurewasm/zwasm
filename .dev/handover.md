# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## D-327 REFRAMED 2026-06-14 (premise was a MISDIAGNOSIS)

Probing corrected it: **EH try_table corpus is ALREADY wg-3.0-current** (committed
raw = upstream, 34=34 asserts) + **spec runner 100% GREEN** (`[exception-handling]
return 34/34, trap 2/2, invalid 7/7, exception 4/4`). catch_ref asserts pass
because the wast `(drop)`s the exnref + checks only the param; NO assert validates
exnref VALUE (exnref-using cases are `assert_invalid`). So the JIT exnref garbage +
throw_ref stub is **CONFORMANCE-NEUTRAL** completeness (interp-correct, JIT-wrong),
NOT an alpha blocker. Cycle-4a infra kept (`8478d853`).

## Active bundle — JIT exnref completeness (user chose "do it now" 2026-06-14)

- **Bundle-ID**: d327-exnref-jit  **Cycles-remaining**: ~3
- **Continuity-memo**: 4b/4c/4d IMPLEMENTED + VALIDATED then REVERTED (clean tree)
  2026-06-14 — the exnref machinery is CORRECT (the throw_ref round-trip fixture
  goes green: reify + rethrowFromExnref work). BUT it's BLOCKED by **D-328** (new):
  a multi-value catch landing-pad block (`block $h (result i32 exnref)`) gets
  COLLIDING result vregs — instrumented `pushed_vregs={0,0}` (both results =
  placeholder vreg 0). Harmless today (spec drops the exnref; JIT 34/34) but reify
  writing the *Exception into the shared slot CORRUPTS the i32 result (catch_ref
  simple-drop returns the pointer, not 88). So **fix D-328 FIRST** (distinct result
  vregs for multi-value catch in op_control.emitEndIntra/regalloc — investigate why
  both are vreg 0), THEN re-apply 4b/4c/4d (code re-derivable from
  `private/notes/d327-catch_ref-plan.md` → EXECUTION CONTRACT; the round-trip
  fixture bytes + emit mechanics are there). Cycle-4a infra `8478d853` is the
  substrate.
- **Exit-condition**: D-328 fixed (distinct vregs) → JIT round-trip + catch_ref_88
  + catch_all_ref_77 all return their values both arches; full `zig build test` +
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
