# ADR-0142 — Phase-13 §13.2 C-API surface scoping + §13.3/§13.4 sequencing

> **Status**: Accepted (2026-06-04). Autonomous per ADR-0132 carve-out
> (re-scoping because a phase's exit references genuinely-later/blocked work).

## Context

ROADMAP §13.2 = "Implement the missing `wasm.h` surface (valtype / functype /
… / ref / … / foreign), grouped by category." The **load-bearing surface is
complete**:

- Type constructors + queries + vecs (`7ac09d80`); externtype + import/export
  types (`6f721b6b`); module imports/exports (`80131306`/`befd8acd`); frames +
  trap origin/trace (`d3819d32`).
- Extern conversions: `extern_as_*_const` + `extern_type` (`63dab69d`);
  `*_as_extern[_const]` (`0fc0aac5`, `api/extern_new.zig`).
- Host-entity construction (all importable): `wasm_global_new` (`5faef5d9`),
  `wasm_memory_new` (`a1c9fbfe`), `wasm_table_new` (`08d5fd23`),
  `wasm_func_new[_with_env]` (`c712eac1`, closed D-252).
- Ref machinery: `wasm_ref_copy`/`_same` (`9e634743`); funcref cross-cast
  `wasm_func_as_ref`/`wasm_ref_as_func` (`8775e30f`); `wasm_foreign` +
  host_info + `as_ref`/`ref_as_foreign` (`9c15ca50`).

What remains is tracked in **D-253**: (C) per-entity `host_info` on
func/global/table/memory; (E) the degenerate `wasm_{instance,extern,global,
table,memory}_as_ref` casts.

## Decision

1. **Mark §13.2 `[x]`.** C/E stay in D-253, deferred §13.4-driven. Rationale:
   - **(C) host_info bulk** is low-value (host attaching data to a wasm entity
     is rarely exercised by the conformance examples) AND cap-constrained
     (`instance.zig` is at 3299/3300; adding `host_info` fields to four structs
     exceeds the exempt cap → needs a Store-level side-table keyed by handle
     ptr, or another cap raise). Defer that design until a consumer needs it.
   - **(E) degenerate casts** are genuinely not-modeled: instances/externs are
     not spec reference *values* (no `runtime.Value` encoding for "a reference
     to an instance/extern"). Whether to expose them at all is a model decision
     that §13.4 (does any ported example use them?) informs. NOT silent stubs —
     documented as not-modeled in D-253.

2. **Sequence §13.4 before the §13.3 remainder.** §13.3's `inherit_argv`/
   `inherit_env` + `preopen_dir` are blocked on the ADR-0070 (libc boundary)
   C-API io/process-provenance decision (Zig 0.16's capability-based I/O gives
   a C-library context no `Init` token — see the §13.3-partial handover note).
   §13.4 (conformance) is unblocked, validates the §13.2 surface end-to-end via
   the existing `zig build test-c-api` harness, and reveals which of D-253 C/E
   actually matter. So: §13.4 next; §13.3 remainder interleaves once ADR-0070
   lands.

## Consequences

- §13.2 closes without C/E; D-253 (blocked-by §13.4 prioritization) carries
  them with full encoding/ownership notes + discharge order.
- §13.P (phase close 🔒) gates on conformance fail=0 + examples — by then D-253
  C/E are either implemented (if §13.4 needs them) or confirmed not-modeled.
- No ROADMAP §1/§2/§4/§5/§11/§14 change; §9-scope re-scope only (ADR-0132).
