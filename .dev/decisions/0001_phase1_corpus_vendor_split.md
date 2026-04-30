---
name: 0001 — Split Phase-1 spec corpus vendoring across §9.1 / 1.8 + 1.9
date: 2026-05-01
status: Accepted
tags: phase-1, spec-corpus, scope
---

# 0001 — Split Phase-1 spec corpus vendoring across §9.1 / 1.8 + 1.9

- **Status**: Accepted
- **Date**: 2026-05-01
- **Author**: Claude (autonomous /continue loop)
- **Tags**: phase-1, spec-corpus, scope

## Context

ROADMAP §9.1 / 1.8 reads:

> Vendor the Wasm Core 1.0 spec corpus (read-only); add the
> `zig build test-spec` runner.

A literal reading bundles two separable deliverables into one
task: (a) vendor the upstream Wasm 1.0 corpus (~40 `.wast`
files plus an `wast2json` regen path), and (b) add the
`zig build test-spec` infrastructure. ROADMAP §9.1 / 1.9 then
mandates the **fail=0 / skip=0 gate** across all three hosts —
which presupposes the corpus is in place AND the frontend's
section-body decoders for type / function / code exist (the
runner needs them to drive validate + lower per function).

Section-body decoders for type / function / code do not yet
exist; §9.1 / 1.5 (validator) and 1.6 (lowerer) deliberately
deferred them. To run the upstream corpus through validate +
lower, those decoders must land first.

Doing all of (a) + (b) + section-body decoders + the gate run
in one task violates TDD scope discipline (§13) and produces an
opaque, hard-to-review commit.

## Decision

Split the corpus vendoring across 1.8 and 1.9:

- **§9.1 / 1.8** delivers (b) — the `zig build test-spec`
  runner infrastructure — together with a small hand-baked
  *smoke corpus* (`test/spec/smoke/{empty,single_func,
  block}.wasm`, generated via wat2wasm). The runner exercises
  the parser only; validate + lower drive is deferred to 1.9.
- **§9.1 / 1.9** absorbs the upstream corpus vendor: copy
  Wasm 1.0 `.wast` files from
  `~/Documents/OSS/WebAssembly/spec/test/core/` into
  `test/spec/wat/`, add `scripts/regen_test_data.sh`
  (wast2json wrapper) producing `test/spec/json/`
  (gitignored), implement the type / function / code
  section-body decoders, and upgrade `test/spec/runner.zig`
  to drive parser → validator → lowerer per function. The
  fail=0 / skip=0 gate is the corpus passing on Mac aarch64 +
  OrbStack Ubuntu x86_64 + windowsmini SSH.

The §9.1 / 1.8 ROADMAP row text is unchanged; this ADR
narrows the operational interpretation of "vendor the Wasm
Core 1.0 spec corpus" to "have a representative Wasm 1.0
smoke corpus committed". The §9.1 / 1.9 ROADMAP row text is
unchanged; this ADR widens its operational interpretation
to include the upstream-vendoring work formerly read into 1.8.

## Alternatives considered

### Alternative A — Land everything in 1.8 (literal reading)

- **Sketch**: vendor the full upstream corpus, build
  section-body decoders for type / function / code, add the
  runner, drive validate + lower, and fail=0/skip=0 gate the
  whole thing — all in one task before flipping 1.8 to `[x]`.
- **Why rejected**: the resulting commit would touch ≥6 new
  files across three subsystems (frontend, build, test
  infrastructure) plus a vendored corpus blob. Reviewing it
  is impractical and the TDD red→green→refactor rhythm
  collapses. ROADMAP §13 explicitly favours commit-at-natural-
  granularity over megacommits.

### Alternative B — Defer 1.8 entirely to 1.9

- **Sketch**: skip 1.8; collapse all work into 1.9.
- **Why rejected**: produces zero observable Phase-1 progress
  for the duration of the (already large) 1.9 task. The
  runner infrastructure is a useful in-flight artefact even
  before the upstream corpus is in place.

### Alternative C — Add a 1.8.1 / 1.8.2 sub-row instead of an ADR

- **Sketch**: subdivide 1.8 in the ROADMAP itself.
- **Why rejected**: §9 task tables across other phases use
  flat numbering; introducing decimal sub-rows here only is a
  drift. ADR-narrating a split keeps the table shape uniform.

## Consequences

- **Positive**: 1.8 lands in one tight commit (smoke corpus +
  runner + build wiring), reviewable inline. 1.9 has a
  bounded, well-defined scope that includes section decoders.
- **Negative**: 1.9's commit will be larger than a typical
  task because section decoders + corpus vendor + runner
  upgrade all land together. If 1.9 grows further, it should
  be split via a follow-up ADR rather than absorbed silently.
- **Neutral / follow-ups**: when 1.9 lands, this ADR's
  Status flips to `Superseded by N/A` (acknowledged, no longer
  load-bearing). The handover should reflect that.

## References

- ROADMAP §9.1 / 1.8 (row text unchanged)
- ROADMAP §9.1 / 1.9 (row text unchanged)
- ROADMAP §11.5 — three-OS gate
- ROADMAP §13 — commit at natural granularity
- ROADMAP §A10 — spec test fail=0 / skip=0 is a release gate
