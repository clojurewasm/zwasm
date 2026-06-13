# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **ROADMAP widget: Phase 17 = IN-PROGRESS (feature line)**. CM + WASI-P2
  wasmtime-equivalent campaign CLOSED 2026-06-13 (corpus 158/0/0).
- **D-324 CLOSED 2026-06-13 (bundle d324-mem64-bulk, B1–B4 + B-JIT)** —
  memory64 × multi-memory bulk-op correctness. (B1) validator per-memory
  `idx_types` slice + `memIdxTypeAt`/`memEntryIdxType`; memory.copy types
  `[it_dst it_src it_min]` (it_min = i32 if either side i32); load/store/
  atomics/size/grow/fill/init all per-memidx. (B2) interp bulk pops at
  validated width (`popAddr`/`memIs64`/`outOfRange`, overflow-safe). (B3)
  distilled memory64 memory_copy/fill/init + float_memory64 corpora (the
  suffix-`64` curation hole that hid the gap; wasm-3.0 11937 directives
  0 fail). (B-JIT) arm64+x86_64 bulk emitters capture X-form/64-bit + the
  overflow-safe subtraction bounds scheme (`encCbnz` added); 2
  memory64_bulk edge fixtures. (B4) wast_runner per-memory validation +
  **regen_wasmtime_misc.sh wasm-tools swap COMMITTED** (basic 74/0,
  runtime 359/0/5; externref-segment skip-ADR Closed — fixture PASSes).
- **D-290 progressed**: regen_spec_2_0_assert.sh + regen_wasmtime_misc.sh
  both swapped to wasm-tools. REMAINING blocked = only
  regen_spec_simd_assert.sh (v128) + flake wabt-pin drop.
- **ADR-0184 COMPLETE** (engine-owned io for C-API WASI preopen/env;
  D-255 + D-007 discharged). **CWFS exportedFuncs** enumerates
  interface-nested funcs path-qualified (`af112e9a`).
- Mac test/lint green per commit; ubuntu test-all green 2026-06-13;
  **windows batch green 2026-06-13** (`beb2g2d5a`, 55/55 realworld + all).

## Active bundle

- **Bundle-ID**: cljw-cm-api-finished-form
- **Cycles-remaining**: ~2
- **Progress**: REQ-4 DONE (`8a647a2b` + `336c9db4` test-all caller fix —
  InstantiateOpts budget). REQ-3 DONE (`ef1bdbb0` — `WitType` +
  resolveType/resolveFuncSig in feature/component/wit_type.zig). REQ-2
  DONE (`115f6be9` — enum/variant/flags labels borrow in value tree;
  output self-describing, input by ordinal). REQ-6 DONE (`0af412ce` —
  typed-invoke diagnostics + EXTRACTED component.zig tests to
  component_tests.zig 2007→529 lines). REMAINING: REQ-1 (unified
  `comp.open` + `Opened` union handle, delegating methods + predicate)
  → REQ-5 (`Opened.dropResource` host-facing, reaches guest_resources +
  destructor). NOTE: component.zig is lean (529) again — room for both.
  cw handover (COMPLETED) written at the very end.
- **Continuity-memo**: 6 cw CM-API requests (below). USER GO GIVEN
  2026-06-13 ("finished-form priority over impl difficulty; you decide
  the shape / provide both"). Design decisions made (finished-form):
  REQ-1 = `comp.open(engine,alloc,bytes,host)` + unified `Opened` union
  handle (delegating exportedFuncs/invokeTyped/dropResource/deinit) +
  `componentNeedsWasi(bytes)` predicate. REQ-2 = enum/variant/flags
  labels **borrow** from TypeInfo (consistent w/ record field names) in
  the value tree, BOTH directions (output carries label; input accepts
  label→ordinal resolve). REQ-3 = NEW public `WitType` type-tree
  (specialization-preserving — option/result/tuple distinct — + labels)
  via `resolveType`/`resolveFuncSig` (parallels ComponentValue; NOT the
  despecialized CanonType). REQ-4 = thread `InstantiateLimits` into
  component instantiate/open/buildWasiP2Component (2 hardcoded `.{}` at
  component.zig:435/468). REQ-5 = `Opened.dropResource(handle)` host-
  facing, reaches guest_resources + runs destructor. REQ-6 = setDiag at
  component_typed.zig invoke error sites (arg/field blame).
  ORDER: 4 → 3(WitType) → 2(labels) → 6(diag) → 1(open spine) →
  5(drop). Each TDD red→green, commit pair, chain in-turn.
  Key files: src/api/component.zig (instantiate:455, BuiltComponent
  re-export:487), src/api/component_wasi_p2.zig (buildWasiP2Component:
  1642, BuiltComponent:1590, WasiP2Ctx.guest_resources:61), src/api/
  component_typed.zig (fromCanonDefType:260 — labels available in dt;
  InvokeTypedError:30), src/feature/component/value.zig (ComponentValue),
  src/feature/component/canon.zig (CanonType:68, resolveTypeIndex:1295,
  canonTypeFromLocalDefType:1386), src/feature/component/types.zig
  (EnumType.labels:81, FlagsType.labels:86, VariantType.cases:114),
  src/api/instance.zig (InstantiateLimits:698).
- **Exit-condition**: all 6 implemented + tested; cljw handover written
  to `$MY/ClojureWasmFromScratch/private/20260613_handover_from_zwasm/
  handover.md` with `COMPLETED` marker; 3-host green.

## The 6 cw CM-API requests (USER-SURFACED 2026-06-13)

cw dogfooding (D-404 / ADR-0135) surfaced 6 component-model API requests.
When done, write the response handover to
`$MY/ClojureWasmFromScratch/private/20260613_handover_from_zwasm/handover.md`
with a `COMPLETED` marker so cw resumes. The 6 (priority order):
1. **Unified open API** — `comp.open(engine,alloc,bytes,host)` auto-selecting
   single-module vs WASI-P2 graph (or a cheap "needs-wasi-imports?" predicate);
   unify the `ComponentInstance` / `BuiltComponent` return types. (kills cw's
   try-catch fallback + Opened union dispatch.)
2. **enum/variant/flags labels in the value tree** — `ComponentValue` carries
   only ordinals/bits, no label names → cw can't map enum→keyword etc. Add
   labels (TypeInfo-borrow ok) or return the result ValType alongside invoke.
3. **type-resolution 2-space rule API** — public recursive `ValType`→concrete
   resolver (despecialized type tree) so consumers don't re-implement TypeCtx.
4. **budget threading to component path** — `instantiate`/`buildWasiP2Component`
   take `InstantiateOpts` (fuel/max-memory); currently `.{}` hardcoded
   (component-side of D-347).
5. **host resource-drop API** — api-layer "drop own handle w/ destructor"
   entry (ResourceTable.drop is internal only).
6. **component-path diagnostics** — instantiate/invoke failures are bare Zig
   errors; no `diagnostic.setDiag` equivalent for user-facing messages.

## Closed-work pointers (detail in git log / ADRs)

- **d314-jit-sandbox CLOSED 2026-06-12** (sandboxing triad; ADR-0179).
  GATE NOTE (D-311): raw-entry-call seed-flaky in `zig build test`; 3-host
  test-all is authority (`releasesafe_jit_failures.md`).
- JIT-correctness 2026-06-12: wasm-3.0 assert_return 880/0 both arches.
  D-318 (note): Rosetta x86_64-macos corpus-JIT SEGVs, local-only.
- **Open user-decision follow-ons**: Tier-2 #5 ILP32/watchOS.
- Other open debt: D-323 (stdlib NTSTATUS, blocked-by) · D-318 (note).

## State at pause (stable baseline)

- **Core Wasm 1.0/2.0/3.0**: 100% spec, 0 skip, 3-host green. v0.2 features +
  official corpora complete. WASI 0.1 complete. Sandboxing triad everywhere.
- **CM + WASI-P2**: default-ON (ADR-0182); real Rust/Go wasip2 components run
  e2e; typed API (ADR-0183); validator rules 1–12; corpus 158/0/0.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env per ADR-0184) ·
  Zig-API complete (docs §3.9) · lean CLI · memory-safety sound ·
  dogfooded into cw v1. Runners ReleaseSafe (ADR-0177).
- Debt ledger: zero `now` rows; rest `blocked-by`/`note` long-tail.

## Key refs

- [`docs/handoff_cw_v1.md`](../docs/handoff_cw_v1.md) — consumer-side handoff.
- **ADR-0184** (engine-owned io) · **ADR-0183** (typed component API) ·
  **ADR-0179** (sandboxing) · **ADR-0156** (no release) · **ADR-0153**
  (rework) · **ADR-0170/0176/0177** (CM / validation / runners).
- [`component_model_plan.md`](component_model_plan.md) ·
  [`releasesafe_jit_failures.md`](releasesafe_jit_failures.md) (D-311).
