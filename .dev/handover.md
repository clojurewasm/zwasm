# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Active campaign — spec re-vendor → alpha.3 tag (USER-AUTHORIZED; option A chosen 2026-06-14)

Full plan: **`private/spec_revendor_campaign.md`**. Verified (web+local):
1.0/2.0/simd/threads CURRENT; only **3.0 corpus** trailed the wg-3.0 Recommendation.
Re-vendor: gc `b8e8b16c` incorporated (runtime-PASS, 3-host green incl windows).
tail-call `6ce31520` REVERTED `a981e5d8` — it broke HARDCODED `wasm_3_0_manifest.zig`
tests (D-187 "enumerate 31 assert_returns" marker + return_call.0.wasm→i32:306
e2e) that pin corpus structure; `test-spec-X` missed it, `test-all` caught it on
ubuntu (lesson `2026-06-14-corpus-revendor-breaks-hardcoded-manifest-tests`).
memory64/multi-memory/func-refs no-drift; eh + tail-call drift remain (deferred).
So 3.0 corpus = current-for-wg-3.0 EXCEPT multi-value asserts (D-327) + the
reverted tail-call/eh deltas. Mechanism DONE (refdialect.py + runbook).
D-327 PINNED 2026-06-14c: `test-spec-wasm-3.0-assert` is driven by
`spec_assert_runner_wasm_3_0.zig` (build.zig:558), which ALREADY does multi-value
via `inst.invokeMulti` for ALL-SCALAR results (@963-1002); non-scalar (v128/ref)
multi defers. So the eh try_table +5 failures are NOT "runner can't check" — they
are VALUE MISMATCHES (`jitScalarResultMatches` false @989) ⇒ a likely REAL
JIT/runtime multi-value bug in try_table/exception contexts (or arg/result
encoding), NOT a pure test-harness gap. So option A = a genuine RUNTIME
investigation (bigger than the ~250-400 LOC harness estimate). For an ALPHA this
strengthens B.
DECISION (user's call — alpha effort/release tradeoff): **A** = close D-327 →
re-vendor deferred asserts (w/ manifest-test updates) → full wg-3.0 → tag. **B** =
tag `v2.0.0-alpha.3` NOW (corpus wg-3.0-current-except-multi-value, 3-host green;
D-327+deferred → beta/rc debt). Recommend B. NEXT: honour pick; if silent,
continue D-327 investigation (pin the exact runner gap).

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
  - **REQ-7 FIXED (`33e0100c`)** — opened component now OWNS its bytes so it
    outlives the caller's load buffer (cw instance-cache pattern). `decode`
    stayed zero-copy; ComponentInstance/BuiltComponent/ComponentGraph dupe +
    own `owned_bytes`, decode against it, free in deinit. Root cause was
    input-buffer lifetime (not relocatability): TypeInfo names borrowed the
    section bodies = caller's bytes → dangled on free → resolveFuncSig null.
    Adversarial test (free+clobber input, then resolve+invoke).
  - cljw handovers written `COMPLETED` →
    `$MY/ClojureWasmFromScratch/private/20260613_handover_from_zwasm/`
    (handover.md pin `65a760e2`; handover_v2.md REQ-7 pin `33e0100c`).
    docs §3.9 synced.
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
