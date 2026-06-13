# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **ROADMAP widget: Phase 17 = IN-PROGRESS (feature line)**. CM + WASI-P2
  wasmtime-equivalent campaign CLOSED 2026-06-13 (corpus 158/0/0).
- **cljw CM-API finished-form campaign CLOSED 2026-06-13** (bundle
  cljw-cm-api-finished-form; user-directed, finished-form-first). All 6
  cw component-model API requests done + tested + 3-host green:
  - **REQ-4** (`8a647a2b`+`336c9db4`) — `InstantiateOpts` budget threaded
    into all component instantiate entries + Linker.instantiate.
  - **REQ-3** (`ef1bdbb0`) — public `WitType` type-tree +
    resolveType/resolveFuncSig (specialization-preserving + labels;
    new feature/component/wit_type.zig).
  - **REQ-2** (`115f6be9`) — enum/variant/flags labels borrow into the
    value tree (output self-describing; input by ordinal).
  - **REQ-6** (`0af412ce`) — typed-invoke diagnostics; ALSO extracted
    component.zig tests → component_tests.zig (2007→529 lines).
  - **REQ-1** (`53334187`) — unified `comp.open` + `Opened` union handle
    (delegating methods) + `componentNeedsWasi` predicate.
  - **REQ-5** (`5795c3d0`) — host-facing `Opened.dropResource` /
    `BuiltComponent.dropResource` (removes handle + runs destructor).
  - cljw handover written `COMPLETED` →
    `$MY/ClojureWasmFromScratch/private/20260613_handover_from_zwasm/handover.md`
    (pin commit **`65a760e2`**). docs §3.9 synced.
- **D-325 FIXED + closed (`65a760e2`)** — cross-instance
  `call_indirect`/`call_ref` ran the callee in the CALLER's runtime context;
  a guest func reached through a wit-bindgen shim's `$imports` table executed
  against the shim's empty globals → `globalGet` OOB (the REQ-5 dtor trap).
  Fix: a foreign-runtime funcref runs in ITS context via new
  `invokeCrossRuntime` (shared by call_indirect/call_ref + cross_module.thunk,
  single source). REQ-5 dtor now runs cleanly; 3-host + test-all green.
- **D-324 CLOSED** (memory64 × multi-memory bulk-op; B1–B4+JIT).
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

No `now` debt. Debt sweep 2026-06-13:
- **D-245 → note (RESOLVED, re-audit)** — the "remainder (a) win64 / (b)
  arg'd still @call" was STALE (pre-§15.5). entry.zig routes ALL non-
  manual-asm paths (arg'd/i32/v128 RESULT + arg'd + win64 VOID) through
  the non-inline clobber-barrier `jitTrampoline`/`jitTrampolineVoid`
  (arg- + os-agnostic cohort save/restore; no bare @call). Mac ReleaseSafe
  gate + probe green 2026-06-13; 3-host test-all green (ReleaseSafe runners).
- **D-293 — remaining demux = `array_oob` ONLY** (re-surveyed 2026-06-13;
  cast_failure DONE slice-4d `cast_fail_fixups`, struct/array null-deref DONE
  slice-4b `null_ref_fixups` — the row's slice list is behind). Precise scope:
  these JIT ops still append to the GENERIC `bounds_fixups` (→ code 2 oob_table,
  a mislabel for array OOB): `array_init_data/copy/fill/init_elem/new_elem/
  new_data` + `i31_get_s/u` + `struct_get_s` (both arches, ~12 sites). Recipe
  = mirror slice-1/4d: add an `array_oob` TrapKind surface variant (next C-ABI
  code + spec msg "out of bounds array access" + mapInterpTrap arm, like
  slice-4a) → new `array_oob_fixups` channel in ctx.zig (both arches, +emit.zig
  wire) → route the array appends → per-kind stub → TDD (array.get OOB →
  array_oob, JIT+interp parity). DELIBERATE architectural chunk (open fresh,
  3-cycle cap); conformance-NEUTRAL (suite matches by kind today), lower-freq.
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
