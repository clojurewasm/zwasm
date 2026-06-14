# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## ACTIVE AGENDA (user-directed 2026-06-14) — drive these in order via `/continue`

Project is feature-complete + 3-host green + tag-ready; **tag is user-only, NEVER
autonomous (ADR-0156)**. This agenda is completion-refinement under Phase 17.
Work the tasks top-to-bottom; each names a concrete first action.

**A1 — flaky `zig build test` (D-311) — DONE `120e9fc1` (de-escalated + fixed).**
Pinned it: `zig build test` EXITS 0 + the test binary passes 2754/0 STANDALONE
across 4 seeds → the "failed command --listen=-" is a Zig build-runner IPC artifact,
**NOT a real failure** (earlier "seed-flaky SEGV" framing was overstated). Shipped the
correctness fix anyway: new pub `entry.callEntrySafe` (wraps the D-245 trampoline) +
routed the 8 contract-violating test direct-calls (entry.zig f32 / linker.zig×2 /
runner_test.zig×4). Full finding: [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md)
§RESOLVED-as-NOT-A-FAILURE. (Residual --listen line = build-runner quirk, deferred.)

**A2 — cljw Zig-API current-state handoff doc — DONE `4aeaea75`.** Authored
`docs/handoff_cw_v2_zig_api.md` (signatures verified accurate-to-HEAD via source
survey): mental model + outlives contracts, lifecycle, host imports (defineFunc/
defineFuncCtx + Caller), cross-module linking, WASI P1 (WasiConfig{args,envs};
preopens=D-177), invoke (untyped+typedFunc), state access, sandboxing, Component
Model (comp.open→Opened: invokeTyped/resolveFuncSig/dropResource/diagnostics +
WitType + ComponentValue), trap set, known-gaps table. Linked from README; tables
aligned. cljw can now read the current Zig embedding surface in one place.

**A3 — external-facing doc精査 + update (non-dev).** Re-examine every PUBLIC doc
against current reality and fix drift: `README.md`, `docs/tutorial.md`,
`docs/reference/{cli,c_api,zig_api}.md`, `docs/benchmarks.md`,
`docs/migration_v1_to_v2.md`. (cli.md/c_api.md were verified accurate 2026-06-14;
README got a wabt/WASI-P2 fix `b34183a7` — re-walk the rest end-to-end, esp.
tutorial command accuracy + reference/zig_api vs the A2 current-state.) NOT `.dev/`
(internal) — only outward-facing docs.

**Wiring note**: this handover IS the `/continue` driving doc; `releasesafe_jit_failures.md`
holds the A1 recipe; A2/A3 source docs all exist (verified). No auto-tag, no
release. Mark each task done here as it completes; retarget the NEXT marker.

## State (tag-ready baseline, all 3-host green)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON (ADR-0182/0183; corpus 158/0/0). Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env, ADR-0184) · Zig-API
  complete (+`WasiConfig.envs` `04cb3497`) · lean CLI · memory-safety sound ·
  dogfooded into cw v1. Runners ReleaseSafe (ADR-0177).
- **Debt**: 53 entries, **zero `now`**; rest blocked-by(external)/note long-tail.
  Recent: D-301/D-177/D-179 closed; D-297 discharged (2026-06-14 sweep, in git).
- **Alpha conformance MET** (`d151538a`): 3.0 corpus fully wg-3.0-current. Tag
  `v2.0.0-alpha.3` is tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`docs/zig_api_design.md`](../docs/zig_api_design.md) (Zig API, §3.8 WASI/§3.9
  component) · [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) (prior cljw handoff).
- **ADR-0184** (engine-owned io) · **0183** (typed component API) · **0182** (CM
  default-ON) · **0179** (sandboxing) · **0177** (ReleaseSafe runners) · **0156**
  (NO autonomous release) · **0153** (rework) · **0109** (Linker/facade API).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311 / A1 recipe).
