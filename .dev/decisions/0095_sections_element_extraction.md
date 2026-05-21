# 0095 — Extract element-section decoder into `sections_element.zig`

- **Status**: Superseded by ADR-0101 (see ADR-0100)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0094)
- **Tags**: file-layout, refactor, zone-1, parse, file-size-cap, superseded
- **Superseded-by**: ADR-0101 (see ADR-0100 for rationale — this extraction triggered N1+N2 per ADR-0099 §D2)

## Context

`src/parse/sections.zig` is **1556 LOC** (911 code + 645 tests), 55%
over the 1000-LOC soft cap (ROADMAP §A2). Listed in D-141 as a
remaining per-file ADR candidate with the framing
"per-section vs Wasm-version-cohort split vs FILE-SIZE-EXEMPT
marker".

The FILE-SIZE-EXEMPT marker mechanism (`scripts/file_size_check.sh`)
only raises the *hard* cap to 2500 lines and does not silence the
*soft* cap WARN; sections.zig at 1556 LOC is between caps, so the
marker does not actually clear the D-141 entry. A real extraction is
required.

Per-file ADR survey checklist (lesson
[`2026-05-21-pure-data-extraction-via-reexport`](../lessons/2026-05-21-pure-data-extraction-via-reexport.md)):

1. **Is there a single declaration block > 40% of file LOC?** No.
   The largest single function is `decodeElement` at 154 LOC (10%);
   the pure-data types collectively account for ~182 LOC (12%).
   → "Many independent things; ADR-grade design choice required."

2. **Closed coherent sub-language?** Yes, for the element section.
   `decodeElement` (Wasm 2.0 §5.5.12, 8 forms 0–7) is the most
   complex single decoder in the file (154 LOC of switch arms);
   its element-specific helpers (`readFuncrefInitExpr`,
   `ELEM_GLOBAL_GET_MARKER`, `elemEntryIsGlobalGet`,
   `elemEntryGlobalIdx`) plus pure-data types
   (`ElementKind`, `ElementSegment`, `Elements`) form a
   self-contained module. This mirrors the ADR-0083 (validator_simd,
   ~420 LOC) precedent.

3. **External callers reach via namespace or directly?** Via
   `sections.decodeElement` / `sections.ElementSegment` etc.
   Namespace access → re-export keeps callers stable.

Other candidates within sections.zig (data section: 60 LOC decoder
+ ~25 LOC types; codes section: 47 LOC decoder + ~17 LOC types;
imports section: 52 LOC decoder + ~28 LOC types) are smaller and
each adds its own follow-up ADR cost without dissolving the
soft-cap WARN single-handedly. Element is the largest sub-language
and the natural first extraction.

## Decision

Extract the element-section decoder (decodeElement + readFuncrefInitExpr
+ ELEM_GLOBAL_GET_MARKER + helpers + pure-data types + 8 tests) from
`src/parse/sections.zig` into a new sibling `src/parse/sections_element.zig`.

`sections.zig` re-exports all moved symbols via type/const aliases so
external callers (`instantiate.zig`, `compile.zig`, `runner.zig`, etc.)
continue to reach `sections.decodeElement` / `sections.ElementKind`
identically — zero caller migration.

| File | Contents | Approx LOC |
|---|---|---|
| `src/parse/sections.zig` (revised) | Section-decoder catalog for types / functions / imports / tables / globals / codes / memory / data / exports; shared helpers (scanInitExpr, skipLeb128, readValType, readName, readLimits); 51 tests for the non-element decoders; re-exports of element types/functions from the sibling. | ~1205 |
| `src/parse/sections_element.zig` (new) | ElementKind / ElementSegment / Elements pure-data types; decodeElement (Wasm 2.0 §5.5.12 forms 0–7); readFuncrefInitExpr (funcref init-expr decoder); ELEM_GLOBAL_GET_MARKER + elemEntryIsGlobalGet + elemEntryGlobalIdx (global.get marker helpers); 8 decodeElement tests. | ~360 |

### Implementation shape

`sections_element.zig` imports `scanInitExpr` from `sections.zig`
via `const sections = @import("sections.zig");` inside function
bodies (declarative, lazy resolution — same shape as ADR-0083's
validator_simd.zig referencing `validator.Validator`). This requires
pub-ifying `scanInitExpr` in sections.zig (free function — no
SIBLING-PUB marker per ADR-0094, which targets struct methods).

`sections.zig` re-exports:

```zig
const elem = @import("sections_element.zig");
pub const ElementKind = elem.ElementKind;
pub const ElementSegment = elem.ElementSegment;
pub const Elements = elem.Elements;
pub const decodeElement = elem.decodeElement;
pub const ELEM_GLOBAL_GET_MARKER = elem.ELEM_GLOBAL_GET_MARKER;
pub const elemEntryIsGlobalGet = elem.elemEntryIsGlobalGet;
pub const elemEntryGlobalIdx = elem.elemEntryGlobalIdx;
```

External API surface unchanged: callers reach the same symbols
through `sections.X` identically.

## Alternatives

1. **FILE-SIZE-EXEMPT marker only** — Rejected. The marker only
   raises the hard cap (2000 → 2500); sections.zig at 1556 is in
   the WARN range regardless. D-141 entry persists.

2. **Per-section bulk split** (10 sibling files: sections_type.zig,
   sections_import.zig, ..., sections_export.zig) — Rejected.
   Mass fragmentation; high re-export boilerplate cost for small
   decoders (function/memory/exports each ~25–40 LOC); semantic
   coherence of "sections.zig = Wasm spec §5 catalog" lost.

3. **Pure-data types only** (~182 LOC to sections_types.zig) —
   Rejected. The 11.7% block does not satisfy the >40% threshold
   from the survey checklist; the resulting sections.zig at ~1375
   LOC remains WARN and the pure-data block is not the dominant
   mass; extraction value is low.

4. **decodeElement-only (without tests / helpers)** — Rejected.
   The 8 element tests + readFuncrefInitExpr + marker helpers form
   a coherent unit; splitting tests away from their decoder hurts
   discoverability and edit locality.

## Consequences

**Positive**:

- sections.zig: 1556 → ~1205 LOC (−351 LOC, −23%). Still WARN but
  measurable progress (D-141 list count unchanged but the cap
  margin narrows).
- sections_element.zig is a coherent ~360-LOC module: one sub-
  language (Wasm 2.0 element section), self-tested, single concern.
- Zero caller migration; existing imports of `sections.X` keep
  working.
- Future Wasm 3.0 element-segment extensions (e.g. table.atomic_*)
  land in sections_element.zig naturally.

**Negative**:

- One leaked module-private helper: `scanInitExpr` flips to `pub`.
  Acceptable — it's a free function (no SIBLING-PUB marker
  required per ADR-0094's scope); the leak is the canonical price
  of cross-file factoring.
- sections.zig remains over the 1000-LOC soft cap at ~1205. A
  follow-up extraction (likely data + codes families bundled to
  `sections_segments.zig` or `sections_data.zig`) will be needed
  to fully dissolve the WARN. Tracked under D-141.
- One new file added to src/parse/ (now: ctx.zig, parser.zig,
  sections.zig, sections_element.zig).

**Neutral**:

- `decodeElement` references `sections.scanInitExpr` declaratively
  (Zig's lazy import resolution handles the circular dependency
  cleanly; same precedent as ADR-0083 validator_simd ↔ validator).
- Test gate (`zig build test`) covers the moved 8 tests + the
  retained 51 tests, asserting behaviour neutrality.

## References

- D-141 — file-size soft-cap proliferation (entry that this ADR
  partially discharges).
- ROADMAP §A2 — file-size cap policy.
- ADR-0083 — validator_simd extraction (the precedent for
  cross-file coherent sub-language extraction).
- ADR-0086 / ADR-0087 / ADR-0088 / ADR-0090 — pure-data
  re-export precedents (different shape; not adopted here).
- ADR-0094 — SIBLING-PUB marker (applies to struct methods, not
  free functions; the `scanInitExpr` pub-ification is exempt).
- Lesson
  [`2026-05-21-pure-data-extraction-via-reexport`](../lessons/2026-05-21-pure-data-extraction-via-reexport.md)
  — survey checklist used in Context §.
- `scripts/file_size_check.sh` — the soft/hard/exempt-cap gate.

## Revision history

- 2026-05-21 — Initial draft (Proposed → Accepted same cycle:
  refactor lands in the same commit, test gate asserts behaviour
  neutrality).
