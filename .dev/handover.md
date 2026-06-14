# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## ACTIVE AGENDA (user-directed 2026-06-14) — drive these in order via `/continue`

Project is feature-complete + 3-host green + tag-ready; **tag is user-only, NEVER
autonomous (ADR-0156)**. This agenda is completion-refinement under Phase 17.
Work the tasks top-to-bottom; each names a concrete first action.

**A1 — flaky `zig build test` (D-311), focused chunk.** Local `zig build test`
seed-flakily SEGVs (3-host `test-all` is authority + green; this only improves
LOCAL determinism). Investigation DONE + recipe in
[`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) §"Re-narrowed
2026-06-14". Steps: (1) route the contract-violating test direct-calls through
the existing safe helpers — `entry.zig:2694-95` (f32 test) → `invokeAndCheck`;
`linker.zig:598,829` → `entry.callI32NoArgs`; (2) DECIDE whether x86_64 production
multi-result `entry.zig:1365/1424` (`f(rt)`, no asm-clobber vs arm64's
`aarch64_blr_clobbers` sibling) needs the `asm volatile("":::entry.jit_cohort_clobbers)`
barrier; (3) verify `zig build test` ×~20 (seed-varying) shows ZERO SEGV + 3-host.
If step 2 opens deeper ABI work, ship step 1 + document; don't rabbit-hole.

**A2 — ClojureWasm (cljw/CWFS) handoff doc — CURRENT STATE of the Zig API.** Not a
changelog — a standalone "here is the Zig embedding API as it stands now" for the
cljw consumer. Cover: Engine/Module/Instance lifecycle, `Linker` (defineFunc/
defineInstance/defineGlobal/defineMemory/defineWasi + `WasiConfig{args, envs}`,
preopens NOT yet wired = D-177), component surface (open/Opened/WitType/labels/
budget/dropResource/diagnostics), lifetime contracts (Linker outlives importers;
cross-instance source outlives importer). Base on `docs/zig_api_design.md` +
`docs/handoff_cw_v1.md`; land as a new `docs/handoff_cw_v2_zig_api.md` (name TBD).

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
