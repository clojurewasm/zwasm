# `src/api/instance.zig` structural audit — §9.12-G (c)

> **Doc-state**: ACTIVE

**Date**: 2026-05-21
**Subject**: `src/api/instance.zig` (1431 LOC; soft-cap WARN)
**Scope**: ADR-0099 §D2 P3 evaluation per §9.12-G deliverable (c)
**Verdict**: **FILE-SIZE-EXEMPT** — no clean extraction candidate;
no P-condition fires cleanly; multiple N-conditions would fire on
proposed extractions.

## Top-level structure

| Category | Count | Source range |
|---|---|---|
| Public extern structs / type aliases | 11 | lines 70-176 |
| Public C ABI exports (`pub export fn`) | 18 | lines 207-939 |
| Public inline helpers | 1 (`storeAllocator`) | line 328-331 |
| Private helpers | 9 | lines 186-757 |
| Inline tests | 19 blocks (488 LOC; ~34% of file) | lines 945-1431 |

## Functional groupings (cohesive subsystems)

| Group | Symbols | LOC (code only) | Shared private helpers |
|---|---|---|---|
| A: Engine lifecycle | `wasm_engine_{new,delete}` | ~30 | `engineAllocator` |
| B: Store lifecycle + WASI | `wasm_store_{new,delete}`, `zwasm_store_set_wasi`, `storeAllocator` | ~85 | `engineAllocator`, `parkAsZombie` |
| C: Module parse/validate/lifecycle | `wasm_module_{new,validate,delete}` | ~55 | `storeAllocator` |
| D: Instance lifecycle + binding | `wasm_instance_{new,delete}` | ~140 (incl. private `buildBindings` 113 LOC + `lookupSourceExportType` 12 LOC) | `parkAsZombie`, `storeAllocator`, `dispatchTable` |
| E: Func dispatch + val marshaling | `zwasm_instance_get_func`, `wasm_func_{delete,call}` | ~240 (incl. `marshalValIn`, `marshalValOut`, `dispatchTable`) | `storeAllocator`, `dispatchTable` |
| F: Extern + export discovery | `wasm_extern_{kind,delete,as_func,vec_delete}`, `wasm_instance_exports` | ~115 (incl. `exportDescToExternKind`) | `storeAllocator` |

## ADR-0099 §D2 conditions check

### Positive conditions (need ≥ 1 to justify extraction)

| Condition | Fires? | Evidence |
|---|---|---|
| P1 (spec-defined closed sub-language ≥ 300 LOC) | **NO** | C ABI is not a spec; wasm.h has no "sub-language" boundaries; no group ≥ 300 LOC of substantive code |
| P2 (pure-data dominance ≥ 40% LOC) | **NO** | Largest non-data block is `buildBindings` (113 LOC, ~8%) which is logic, not data |
| P3 (independent change cadence + deep interface) | **NO** | Groups share `parkAsZombie`/`storeAllocator`/`dispatchTable`/`engineAllocator`; change cadence is unified (Val encoding, ZirOp dispatch, exception handling surface across all groups); no group has ≥ 10 use sites in prod code (CLI + tests = ~45-60 total) |
| P4 (test surface isolation) | **NO** | Inline tests intermix groups (e.g. instance/func/extern lifecycle tests share fixture setup) |

### Negative conditions (any one → REJECT)

| Condition | Fires on proposed extraction? | Evidence |
|---|---|---|
| N1 (helper-circular import) | YES, on any group extraction | Extracted sibling would need `storeAllocator` / `parkAsZombie` from parent OR parent would need extracted struct types — cyclic |
| N2 (forced pub-leak of helper) | YES | `parkAsZombie`, `dispatchTable`, `engineAllocator` are currently private; extraction forces pub on at least one |
| N3 (shallow module < 100 LOC substantive) | YES for Groups A/C/F (30/55/115 LOC) | Groups individually below the deep-module threshold |
| N4 (test dup) | YES | Inline tests share setup boilerplate; extracting per-group tests would duplicate fixtures |

**Decision (tie-breaker)**: 0 positives + 4 negatives → **REJECT extraction**.

## Reasoning summary

1. The file is a **uniform-pattern C ABI catalog**, not a monolith with separable concerns. Every function follows null-check → extract handle → operation → return result — load-bearing per upstream wasm.h C-host compatibility discipline.
2. Groups share lightweight private helpers (`parkAsZombie`, `storeAllocator`, `dispatchTable`) whose duplication would defeat the modularization benefit.
3. Change cadence is unified across groups (Val encoding, ZirOp dispatch, exception handling).
4. External caller distribution is dilute (no group ≥ 10 prod-code sites), characteristic of a Zone-3 boundary layer.
5. Inline tests (488 LOC, 34%) are load-bearing for C-boundary null-tolerance, ownership, and marshaling fidelity; cannot be moved without losing context.
6. The 1431 LOC reflects the **breadth of the C ABI surface** compressed into the **minimum code** required to map wasm.h onto zwasm Zone-1/2 types.

## Outcome

- `// FILE-SIZE-EXEMPT: <rationale> (per ADR-0099)` marker added on
  line 1 of `src/api/instance.zig`.
- `file_size_check.sh` continues to emit WARN at 1431 LOC (soft cap
  is informational per ADR-0099 §D1 anyway); the marker documents
  the design choice for reviewers.
- D-139 (c_api Instance-path test coverage) discharge plan remains
  bundled with v0.1.0 RC + ADR-0025 Zig facade work, not addressed
  in §9.12-G. The 19 inline test blocks already cover null-arg
  discipline, lifecycle round-trips, dispatch+marshaling, import
  binding (WASI + unknown-module), and export discovery — sufficient
  c_api Instance-path coverage for §9.12-G entry criteria.

## References

- ADR-0099 §D1 (soft cap = smell detector, EXEMPT as default outcome)
- ADR-0099 §D2 (4+4 conditions framework)
- ADR-0007 (original carve-out of `wasm.zig` → `api/instance.zig` + siblings)
- D-139 (c_api spec-runner coverage gap; v0.1.0 RC discharge)
- D-079 (v128 cross-module imports; ADR-0052 §3 follow-up)
