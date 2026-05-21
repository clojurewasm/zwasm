# 0096 — Extract data + codes section decoders into siblings

- **Status**: Accepted
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, ADR-0095 follow-up)
- **Tags**: file-layout, refactor, zone-1, parse, file-size-cap

## Context

`src/parse/sections.zig` is at **1190 LOC** post-ADR-0095 (element
extraction). Still above the 1000-LOC soft cap (ROADMAP §A2);
D-141 entry persists. The remaining decoder/test mass that can
be split out cleanly along the same "coherent sub-language"
axis is the **data** section (Wasm 2.0 §5.5.13) and the **codes**
section (Wasm §5.5.11) — both small, both self-contained, both
following the ADR-0095 mechanical template exactly.

Combined extraction brings sections.zig under the soft cap in
one cycle, dissolving the WARN.

| Decoder | LOC (code) | LOC (tests) | Total |
|---|---:|---:|---:|
| decodeCodes + CodeEntry + Codes | 64 | 86 | 150 |
| decodeData + DataKind + DataSegment + Datas | 82 | 63 | 145 |
| **Net removed from sections.zig** | **146** | **149** | **~295** |

After: sections.zig ≈ 1190 − 295 ≈ 895 LOC (under 1000).

## Decision

Extract two new sibling files under `src/parse/`:

| File | Contents |
|---|---|
| `sections_codes.zig` (new) | `CodeEntry`, `Codes`, `decodeCodes` (function-bodies decoder, Wasm §5.5.11), 8 decodeCodes tests. |
| `sections_data.zig` (new) | `DataKind`, `DataSegment`, `Datas`, `decodeData` (Wasm 2.0 §5.5.13 with 3 forms 0/1/2), 5 decodeData tests. |

Both files re-import `sections.zig` for `Error` and for the
shared `readValType` (codes) and `scanInitExpr` (data) helpers.
`readValType` flips to `pub` in this commit (same shape as
`scanInitExpr` did at ADR-0095; free function, no SIBLING-PUB
marker required per ADR-0094 scope).

`sections.zig` re-exports all moved symbols so callers continue to
reach `sections.decodeCodes` / `sections.DataSegment` etc.
identically — zero caller migration.

### Implementation shape

Mirrors ADR-0095 exactly. Declarative cross-file references
(`sections.scanInitExpr`, `sections.readValType`) live inside
function bodies — Zig lazy-import resolution handles the cycle
between sections.zig and the new siblings.

## Alternatives

1. **One file at a time (ADR-0096 = codes only; ADR-0097 = data
   later)** — Rejected. Both follow ADR-0095 mechanical template
   without new design choices; bundling them under one ADR is
   honest about the lack of distinct decisions and dissolves the
   WARN in one cycle.

2. **Bundle codes + data into a single `sections_segments.zig`** —
   Rejected. The two sections are semantically distinct
   (function bodies vs initialization data); the only thing they
   share is the extraction pattern. Two files preserves locality
   of edit.

3. **Wait until all D-141 candidates have own ADRs before any
   extraction** — Rejected. ADR-0095 already established the
   per-file ADR cadence; ADR-0096 continues at the same
   granularity.

## Consequences

**Positive**:

- sections.zig: 1190 → ~895 LOC (under 1000-LOC soft cap; D-141
  entry's `parse/sections.zig` slot clears).
- Two new coherent ~150-LOC modules (sections_codes,
  sections_data), each self-tested.
- Zero caller migration.
- Future Wasm 3.0 data/code section extensions (e.g. memory64
  data, tail-call code bodies) land in the dedicated siblings
  naturally.

**Negative**:

- One additional leaked module-private helper: `readValType`
  flips to `pub`. Same shape and rationale as ADR-0095's
  `scanInitExpr` pub-ification; accepted per ADR-0094 scope.
- Two new files added to `src/parse/`.

**Neutral**:

- Cross-file circular imports (sections.zig ↔ sections_codes,
  sections.zig ↔ sections_data) resolved via Zig lazy import.
- Test gate (`zig build test`) asserts behaviour neutrality.

## References

- ADR-0095 — sections_element extraction (the immediate
  precedent; this ADR mirrors its shape).
- ADR-0083 — validator_simd extraction (Cross-file struct
  method precedent).
- ADR-0094 — SIBLING-PUB marker scope (applies to struct
  methods, not free functions).
- D-141 — file-size soft-cap proliferation.
- ROADMAP §A2 — file-size cap policy.

## Revision history

- 2026-05-21 — Initial draft (Proposed → Accepted same cycle:
  mechanical extraction following ADR-0095 template; test gate
  asserts behaviour neutrality).
