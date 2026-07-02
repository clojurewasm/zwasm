# 0082 — Extract op registry from `dispatch_collector.zig` into `dispatch_collector_ops.zig`

- **Status**: Closed (2026-05-21, impl landed)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0081)
- **Tags**: file-layout, refactor, zone-1, dispatch-collector, file-size-cap

## Context

`src/ir/dispatch_collector.zig` is **1397 LOC** — 40% over the
1000-LOC soft cap (ROADMAP §A2). Measurement-focused Step 0
survey (per lesson
[`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md))
shows a sharply bimodal distribution:

| Category | LOC | % | Comptime-coupled to dispatcher? |
|---|---|---|---|
| Op module imports (lines 151–622) | 472 | 34% | No — pure `const X = @import(...)` |
| `collected_ops` tuple (lines 625–1055) | 431 | 31% | No — pure data |
| Test blocks (lines 1220–1397) | 177 | 13% | Yes — exercise framework |
| Module overhead (imports, enums) | 84 | 6% | Yes |
| Comptime helpers (validateOpModule, enabledByBuild) | 40 | 3% | Yes — used by dispatcherOver |
| Utility functions (migratedOpCount, opModuleFor, etc.) | 43 | 3% | Mixed |
| Dispatcher framework (dispatcherOver, factory) | 35 | 2% | **Core logic** |
| Top-level comptime validation | 6 | <1% | Yes |
| Doc / contract | 19 | 1% | Doc |

**65% of dispatch_collector.zig is pure registry data** (op
imports + collected_ops tuple) with **zero shared scope** with
the dispatcher framework. The dispatcher logic (35 LOC) is
buried under 903 LOC of pure declarations — readers must scroll
past the entire op-by-op registry to find `dispatcherOver`.

D-141's row body lists `dispatch_collector.zig` among the
per-file-ADR candidates. ADR-0081 (emit_setup.zig extraction)
established the precedent: when a file's bloat is pure-data /
pure-function and not coupled to inner-scope logic, extracting
it into a sibling file is mechanical and observable. This ADR
applies the same pattern at much larger scale (~900 LOC vs
ADR-0081's 163 LOC) because the registry's pure-data
characteristic makes it defensible.

## Decision

Extract the **op registry** (imports + `collected_ops` tuple +
the comptime validation loop that walks the tuple) from
`src/ir/dispatch_collector.zig` into a new sibling
`src/ir/dispatch_collector_ops.zig`. Dispatcher framework
(`validateOpModule`, `enabledByBuild`, `dispatcherOver`,
`dispatcher` factory, `populateDispatchTable`, `opModuleFor`,
utility functions, tests) stays in `dispatch_collector.zig`.

| File | Contents | Approx LOC |
|---|---|---|
| `src/ir/dispatch_collector.zig` (revised driver) | Type defs (IRAxis, Feature, DispatchError, WasmLevel/WasiLevel re-exports), comptime helpers (validateOpModule, enabledByBuild), dispatcher framework (dispatcherOver, dispatcher factory), utility functions (migratedOpCount, zirOpTagCount, migrationComplete, opModuleFor, populateDispatchTable), top-level comptime validation, all 13 test blocks. | ~500 |
| `src/ir/dispatch_collector_ops.zig` (new registry) | 419 op-module imports (`const op_<name> = @import("../instruction/wasm_X_Y/<name>.zig");`), `pub const collected_ops` tuple referencing those imports. | ~900 |

`dispatch_collector.zig` imports the registry and aliases the
tuple at the top:

```zig
const ops_registry = @import("dispatch_collector_ops.zig");
pub const collected_ops = ops_registry.collected_ops;
```

`feature_level_check.zig` already uses `collector.collected_ops`;
the re-export keeps that reference unchanged.

### Why the registry can extract cleanly

Per the survey's "Comptime-heavy detection" §, the constraints
are:

- `validateOpModule` + `enabledByBuild` use `@hasDecl` /
  `@typeInfo` / `@compileError` — they inspect op-module
  structure but don't depend on the tuple's location. They
  stay in dispatch_collector.zig and are called inside
  `dispatcherOver`'s `inline for (collected_ops)` body via the
  re-export.
- `dispatcherOver` closure + `inline for` over the tuple work
  identically whether the tuple is defined in this file or
  imported from a sibling — Zig's comptime evaluation walks
  the tuple value regardless of declaration site.
- `opModuleFor` uses `comptime for (collected_ops)` + lookup;
  same logic.
- `@setEvalBranchQuota(10_000)` at top-level scope inherits
  to all comptime evaluations in this file. The new
  dispatch_collector_ops.zig needs its own
  `@setEvalBranchQuota` only if its top-level body has loops
  (it doesn't — pure declarations + tuple literal).

The registry's role is **provide a value**, not provide logic.
Extracting it into a sibling file is the same shape as the
emit_setup.zig extraction (ADR-0081).

### Implementation order (single architectural cycle, ~3 commits)

1. **Survey verification** (this ADR): completed.
2. **Carve cycle** (next):
   - Create `src/ir/dispatch_collector_ops.zig` with the 419
     op imports + `collected_ops` tuple + necessary type
     imports (zir, build_options, std).
   - Update `dispatch_collector.zig`: remove the imports +
     tuple (lines 151–1055), add `const ops_registry =
     @import("dispatch_collector_ops.zig"); pub const
     collected_ops = ops_registry.collected_ops;`.
   - Mac cohort gate (test-all) confirms green.
3. **Status flip + handover** (post-impl): ADR-0082 Status
   Proposed → Accepted with Revision history entry citing
   impl SHA.

### Sizes after split

| File | Before | After | Δ |
|---|---|---|---|
| dispatch_collector.zig | 1397 | ~500 | -897 |
| dispatch_collector_ops.zig | (n/a) | ~900 | +900 |

dispatch_collector.zig drops well under soft cap (500 ≪ 1000).
dispatch_collector_ops.zig is over soft cap (900 < 1000 but
close) — but its 900 LOC is **structurally homogeneous** (pure
imports + pure data tuple) with no logic to obscure. A file
over soft cap when the over-cap content is one
semantically-uniform block (= the registry) is qualitatively
different from one where logic and data interleave.

If `dispatch_collector_ops.zig` later grows past hard cap
(2000 LOC, would need ~1100 more ops registered), the natural
next split is by Wasm version family: `dispatch_collector_ops_v1.zig`
/ `dispatch_collector_ops_v2.zig` / `dispatch_collector_ops_v3.zig`.
That's out of scope for this ADR.

## Alternatives considered

### Alternative A — 3-way split (imports / tuple / driver)

- **Sketch**: `dispatch_collector_imports.zig` (419 op
  imports, ~472 LOC) + `dispatch_collector_ops.zig` (tuple
  only, ~431 LOC) + `dispatch_collector.zig` (driver, ~500 LOC).
- **Why rejected**: the imports and the tuple are
  semantically one unit — the tuple **is** the registry of
  imported modules. Splitting them across two files creates
  cross-file coupling with zero readability benefit. Readers
  expect "import → reference" in the same file. Per ADR-0081's
  rejected Alt A pattern.

### Alternative B — Keep monolith + raise soft cap to 1500 LOC

- **Sketch**: leave dispatch_collector.zig at 1397; raise
  §A2 soft cap from 1000 → 1500. Add section markers like
  `// =========== REGISTRY ===========`.
- **Why rejected**: precedent collapse (already rejected in
  ADR-0079, ADR-0080, ADR-0081). Cap-raise normalises drift.
  The 35-LOC dispatcher logic stays buried under 903 LOC of
  declarations — readability cost is real even if compile
  passes.

## Consequences

- **Positive**:
  - `dispatch_collector.zig` drops to ~500 LOC; the 35-LOC
    dispatcher framework becomes readable without scrolling
    past 900 LOC of imports.
  - D-141 row's `dispatch_collector.zig` slot closes.
  - Registry expansion (future Wasm 3.0 GC ops, custom
    proposals) lands in `dispatch_collector_ops.zig` without
    cluttering dispatcher logic.
  - Pattern composes: the same shape (imports + tuple → sibling
    file) applies to any future registry of N modules feeding a
    central comptime dispatcher.
- **Negative**:
  - One new file in `src/ir/` (now 2 files for dispatch_collector
    concept). Mitigated by clear naming: `_ops` suffix denotes
    the data registry.
  - `dispatch_collector_ops.zig` is 900 LOC — over soft cap.
    Documented above as semantically-homogeneous and not
    drift-prone; flagged via FILE-SIZE-EXEMPT marker per
    ADR-0063 mechanism if the file_size_check WARN proliferation
    becomes a concern (currently it doesn't — WARN list already
    shows 26 files).
- **Neutral / follow-ups**:
  - Future SIMD-cohort registry expansion lands in `_ops.zig`.
  - If hard-cap pressure surfaces, version-family split
    (`_ops_v1` / `_ops_v2` / `_ops_v3`) is the natural next
    step — separate ADR when triggered.

## References

- ADR-0079 — `runner.zig` 3-way split (per-file ADR
  shape precedent).
- ADR-0081 — `emit_setup.zig` extraction (immediate-prior
  per-file ADR; same pattern at smaller scale).
- ADR-0074 — per-op-file Zone split (defines the
  per-op-module shape this registry references).
- D-141 — file-size soft-cap proliferation (this ADR closes
  the `dispatch_collector.zig` slot).
- ADR-0063 — FILE-SIZE-EXEMPT marker mechanism (potentially
  applied to `_ops.zig` if reviewer eye-glaze surfaces).
- Lesson
  [`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md)
  — Step 0 measurement discipline that produced this ADR's
  defensible LOC estimates.
- Source: `src/ir/dispatch_collector.zig` (1397 LOC; lines
  151–1055 are the imports + tuple slated for extraction).
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `dc2b74c5d` | Initial Proposed version.               |
| 2026-05-21 | `7bec6946` | **Status: Accepted** — carve impl landed. dispatch_collector.zig 1397 → 500 LOC (-897); dispatch_collector_ops.zig 923 LOC new. Test gate cohort (test-all) + lint green. D-141 dispatch_collector.zig slot closes. |
