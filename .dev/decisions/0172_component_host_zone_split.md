# ADR-0172 — Component host orchestration lives in Zone 3, not feature/

**Status**: Accepted (2026-06-07)
**Scope**: CM campaign chunk B6 (`.dev/component_model_plan.md` Phase B). A §4
Zone-boundary decision within ADR-0170's mandate. No §1/§2 (P/A) change.

## Context

The campaign survey called `src/feature/component/` a "Zone-2 new layer", but
`feature/` is **Zone 1** in the layering contract (`zone_deps`: Zone 1 =
ir/runtime/parse/validate/instruction/feature/diagnostic; Zone 2 =
interp/engine/wasi; Zone 3 = cli/api). The pure component logic shipped so far
— `decode` / `types` / `canon` / `wit` (A1–B5) — IS legitimately Zone 1: it
imports only Zone 0 (`support/leb128`) and Zone 1 (`runtime/value` for the
flattened core value type). Zero engine/interp dependency.

B6 (instantiate embedded core modules + invoke exports + canon trampolines)
breaks that: it must call `Instance.invoke` (interp = Zone 2) and the public
`Engine`/`Module`/`Instance` facade (`src/zwasm/*` = Zone 3). A Zone-1 module
importing Zone 2/3 is an **upward import** — a `zone_check` violation.

WASI is NOT a precedent for putting it in Zone 2: the interp calls *into* wasi
(Zone 2 ← Zone 2), so wasi is a *callee*. The component host is the opposite —
a *consumer* of `invoke`, so it must sit **above** Zone 2.

## Decision

Split the component model across two zones by responsibility:

- **Pure component logic → Zone 1** (`src/feature/component/`, unchanged):
  `decode`, `types`, `canon` (lift/lower/store/load over a caller-supplied
  `[]u8` + injected `cabi_realloc` callback), `wit/*`, and (later)
  `resource_table`. No `invoke`, no engine. Testable with a mock realloc.
- **Host orchestration → Zone 3** (`src/api/component.zig`): decode a component,
  instantiate its embedded core modules via the public `Engine` facade, wire
  canon trampolines, and install the `cabi_realloc` callback as
  `inst.invoke("cabi_realloc", …)`. Zone 3 may import Zone 1 (the pure logic)
  AND the Zone-3 facade — both downward. The CanonContext's injected callback
  (ADR-0171) is exactly the seam that lets the Zone-1 canon code stay free of
  the Zone-2 invoke it ultimately drives.

This keeps the canon/decode/wit core reusable + unit-testable in isolation,
and confines the engine coupling to one Zone-3 orchestration file.

## Alternatives rejected

- **Reclassify `feature/component/` as Zone 2/3**: pollutes the zone contract
  (feature/ is the per-proposal registration home, Zone 1 by construction) and
  would let any feature reach the engine. Rejected.
- **Put orchestration in `src/engine/` (Zone 2)**: engine/ is codegen; a
  component host there inverts its role (engine would import the component
  decoder). Rejected.

## Consequences

- `-Dcomponent` gates `api/component.zig` too (default build emits zero
  component code).
- `zone_check` baseline stays 0 — the Zone-1 canon code never imports upward.
- The public `zwasm.Value` (facade) ≠ internal `runtime.Value`; the Zone-3
  orchestration converts at the invoke boundary. Flat-scalar invokes need no
  canon; canon lift/lower engages once component-level aggregate values cross
  the boundary (IT-3+).
