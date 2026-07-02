# 0083 — Extract SIMD validator into `validator_simd.zig`

- **Status**: Closed (2026-05-21, impl landed)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0082)
- **Tags**: file-layout, refactor, zone-1, validator, simd, file-size-cap

## Context

`src/validate/validator.zig` is **1790 LOC** (handover's
previous 1699 estimate was stale — actual count at this resume).
79% over the 1000-LOC soft cap (ROADMAP §A2). D-141 lists it
among per-file ADR candidates. Measurement-focused Step 0 survey
(per lesson
[`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md))
identified the per-op dispatch shape as **hybrid in transition**:

- Lines 540–547 in `dispatch()` route to `dispatch_collector.dispatcher(.validate)`
  (ADR-0074 per-op-file pattern). Successful dispatch returns early.
- Lines 531–667 is a 137-LOC fallback switch for not-yet-migrated MVP + Wasm 2.0 ops.
- Lines 900–1171 is a **272-LOC SIMD 0xFD prefix dispatcher** with ~150 sub-opcodes inline.
- Lines 1174–1320 is **147 LOC of SIMD-specific helpers** (lane validation, memarg
  validation, load/store shape decoders).

The SIMD block (~420 LOC combined) is explicitly **Phase 14+ deferral**
per ADR-0041 Revision 2 ("central DispatchTable's validator slot is
not consumed today; that's a Phase 14+ refactor"). It is the largest
semantically-coherent block in the file with **zero coupling** to other
dispatch paths — SIMD opcodes form a closed sub-language.

Other extractable candidates surfaced by the survey:

- Memory + table + ref bulk ops (lines 1323–1496, ~174 LOC): semantically
  coherent (Wasm 2.0 bulk memory + table operations) but **not yet
  migrated to per-op files**; tighter coupling to Validator state
  helpers. Larger refactor.
- Stack-manipulation helpers (lines 395–525, ~70 LOC): small, mostly
  utility; not enough mass to justify file extraction on its own.
- Entry-point overloads (lines 190–302, ~80 LOC): API consolidation
  candidate, not extraction; out of scope for this ADR.

The SIMD extraction is the **clearest pure-helper-extraction**
opportunity (same shape as ADR-0081's emit_setup.zig). Other
candidates are deferred to follow-up ADRs when per-op-file migration
(Phase 14+) provides the natural extraction axis.

## Decision

Extract the SIMD validator (0xFD prefix dispatcher + SIMD-specific
helpers) from `src/validate/validator.zig` into a new sibling
`src/validate/validator_simd.zig`. The main dispatch switch in
`validator.zig` calls `validator_simd.dispatchPrefixFD(self, ...)`
via a thin wrapper; SIMD opcode logic + lane/memarg helpers move
entirely.

| File | Contents | Approx LOC |
|---|---|---|
| `src/validate/validator.zig` (revised) | Module overhead, type defs (BlockType/Error/GlobalEntry), public entry points, Validator struct + state, main dispatch switch (MVP + Wasm 2.0 + 0xFC), control-flow ops, parametric/variable/numeric ops, memory+table+ref bulk ops, call+select+brTable, frame-end validation, helpers. | ~1370 |
| `src/validate/validator_simd.zig` (new) | SIMD 0xFD prefix dispatcher (~272 LOC, lines 900–1171), SIMD op helpers (~147 LOC, lines 1174–1320): opSimdLoad / opSimdShuffle / opSimdExtractLane / opSimdReplaceLane / opSimdBitselect / opSimdShift / lane-index validators / memarg validators. | ~420 |

### Implementation shape

`validator.zig`'s `dispatch()` switch arm for the 0xFD prefix becomes:

```zig
0xFD => return @import("validator_simd.zig").dispatchPrefixFD(self, sub_op),
```

`validator_simd.zig` takes `*Validator` as receiver (the state lives
in validator.zig); imports the Error union and helper functions
needed via `const validator = @import("validator.zig");` re-import
(circular-import-safe because `validator_simd.zig` references
`validator.Validator` and `validator.Error` declaratively at function
signatures, not at top level).

External API surface unchanged: callers (`runtime/instance/instantiate.zig`,
`engine/compile.zig`, `engine/runner.zig`, spec runners) reach
`validator.validateFunction()` and its variants identically.
`validator_simd.zig` is package-private; no external caller references it.

### Why "SIMD only" (Phase 1) and not "SIMD + memory/table bulk"

Per the survey's "Extractable Mass Estimate" §:

- **SIMD (~420 LOC)**: pure SIMD opcode logic + helpers. No coupling
  to other dispatch paths. Phase-14-deferred per ADR-0041. Extraction
  is the same shape as ADR-0081's emit_setup.zig (pure helper
  extraction).
- **Memory/table/ref bulk (~174 LOC)**: semantically coherent but
  reads Validator state extensively (popExpect, pushType, frame
  manipulation) — tighter coupling. **Not yet migrated to per-op
  files**, so extraction doesn't align with ADR-0074's per-op-file
  trajectory. Larger refactor warrants its own ADR.
- **Combined (594 LOC)** would bring validator.zig to ~1180 LOC
  (still over soft cap). The 174-LOC bulk-ops extraction is real
  work; bundling it with SIMD doubles the design surface area
  (review burden, test gate scope) without proportional benefit.

Staging: ADR-0083 handles SIMD now (Phase 14 alignment); future
ADR-0084+ handles bulk memory/table when concrete pressure surfaces.

### Implementation order (single architectural cycle)

1. **This ADR**: Proposed land.
2. **Carve cycle** (next): create `src/validate/validator_simd.zig`
   with the extracted block (~420 LOC). Update `validator.zig`:
   delete lines 900–1320, add the `0xFD => @import(...).dispatchPrefixFD(...)`
   dispatch arm. Run cohort gate (test-all on Mac aarch64).
3. **Status flip** (post-impl): ADR-0083 Status Proposed → Accepted
   with Revision history SHA backfill.

## Alternatives considered

### Alternative A — Minimal extraction (SIMD dispatch only, ~272 LOC)

- **Sketch**: extract the 0xFD switch (lines 900–1171) but keep
  the SIMD helpers (lines 1174–1320) in validator.zig.
- **Why rejected**: the SIMD helpers (opSimdLoad, opSimdShuffle,
  opSimdBitselect, etc.) are called **only** from the SIMD
  dispatch arm. Splitting them keeps the call-site routing across
  two files for no benefit. validator.zig drops only to 1518 LOC
  instead of 1370. Pair the helpers with the dispatch.

### Alternative B — Larger extraction (SIMD + memory/table/ref bulk, ~610 LOC)

- **Sketch**: ADR-0083b in the survey — extract SIMD + bulk memory
  + table + ref ops into 2 sibling files.
- **Why rejected**: bulk memory/table/ref ops have **higher coupling
  to Validator state** than SIMD does (they read 4–6 Validator
  fields per op vs SIMD which reads 2). Extracting them safely
  requires either (a) passing Validator pointer + many helper
  closures, or (b) splitting Validator state itself — both are
  ADR-grade design choices on their own. Defer to ADR-0084+ when
  triggered.

### Alternative C — Keep monolith + raise soft cap to 1800 LOC

- **Sketch**: leave validator.zig at 1790; raise §A2 soft cap
  from 1000 → 1800. Add `// ==== SIMD ====` section markers.
- **Why rejected**: precedent collapse (rejected in ADR-0079,
  -0080, -0081, -0082). 1790 LOC validator with SIMD inlined is
  exactly the kind of bloat ROADMAP §A2 exists to prevent. SIMD's
  Phase-14-deferred status makes it the **cleanest extraction
  target** in the file; not extracting now defeats the per-file
  ADR discipline (D-141 row's purpose).

## Consequences

- **Positive**:
  - validator.zig drops 1790 → ~1370 LOC (-420). Still over soft
    cap but no longer at hard-cap risk; SIMD bloat isolated.
  - SIMD per-op migration (Phase 14+) starts from a clean
    extracted file rather than carving from a monolith.
  - D-141 row's `validator.zig` slot closes.
  - Future readers find the 137-LOC main dispatch switch without
    scrolling past 420 LOC of SIMD inline.
- **Negative**:
  - validator.zig still over soft cap (1370 > 1000). Honest about
    that — main dispatch + control-flow + monolithic core ops are
    the residual; further extraction requires per-op-file migration
    (Phase 14+) or memory/table bulk ADR (ADR-0084+).
  - Two-file validator surface: callers don't see it (only
    validator.zig is imported), but reviewers must read both.
    Mitigated by clear naming + the `_simd` suffix convention
    matching `_test`, `_setup`, `_ops` precedents.
- **Neutral / follow-ups**:
  - Phase 14 SIMD per-op migration target shifts to per-op files
    under `src/instruction/wasm_2_0/simd_*/`; this ADR's
    extracted `validator_simd.zig` is the natural source-of-truth
    until that migration.
  - ADR-0084 candidate: extract bulk memory/table/ref ops
    (~174 LOC) when pressure surfaces.

## References

- ADR-0074 — per-op-file Zone split (defines the per-op shape
  this ADR's extracted file would mirror at Phase 14).
- ADR-0041 Revision 2 — SIMD validator Phase 14 deferral.
- ADR-0081 — `emit_setup.zig` extraction (pure-helper extraction
  shape; this ADR's primary precedent).
- ADR-0082 — `dispatch_collector_ops.zig` extraction (pure-data
  extraction; sibling precedent at larger scale).
- Lesson
  [`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md)
  — Step 0 measurement discipline that produced this ADR's
  defensible LOC estimates.
- D-141 — file-size soft-cap proliferation (this ADR's
  Acceptance closes the `validator.zig` slot).
- Source: `src/validate/validator.zig` (1790 LOC; lines
  900–1320 are the SIMD block slated for extraction).
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `79da7f75a` | Initial Proposed version.               |
| 2026-05-21 | `860281bb` | **Status: Accepted** — carve impl landed. validator.zig 1790 → 1363 LOC (-427); validator_simd.zig 457 LOC new. Structural change: SIMD methods → free fns (Zig 0.16 no usingnamespace). pub-ified Validator struct + popExpect/pushType for cross-file method syntax. Test gate cohort + lint green. |
