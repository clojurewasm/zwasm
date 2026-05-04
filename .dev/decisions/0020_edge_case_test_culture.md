# 0020 — Adopt edge-case test culture: "気付いたら即追加"

- **Status**: Accepted
- **Date**: 2026-05-04
- **Author**: Shota / autonomous loop
- **Tags**: testing, process, ruleset, optimization

## Context

§9.7 / 7.3 sub-h3 (trapping trunc) hand-derived 8 sets of
floating-point bound constants from the Wasm spec. Those bounds
were verified by clang-assemble + otool inspection of the
*encodings*, but the **boundary semantics** (NaN/+Inf/-Inf, exact
2^31 boundary, next-representable-below-INT_MIN, etc.) have not
been exercised against fixture wasm. The §9.7 / 7.5 spec gate
will surface any errors, but only if the spec testsuite happens
to include those boundaries.

This problem generalises:

1. As Phase 7 closes and Phase 8+ optimisation work begins, every
   refactor risks regressing on edge cases that were "obvious"
   when written but become invisible later.
2. The project does not have a culture for adding minimal
   targeted boundary fixtures. The existing fixture ecosystem
   (spec testsuite, wasmtime-misc, realworld) is comprehensive
   but coarse — boundary regressions hide inside passing test
   counts.
3. The `/continue` Step 4 (Refactor) and `audit_scaffolding`
   skill have no checkpoint for "did you add a boundary test for
   the case you just thought about?"

The user surfaced this concern explicitly during the
2026-05-04 redesign discussion: "境界値テストは、すでに準備のあ
るものから必要と思ったときに気軽に追加していく指示体系が必要"
(an instruction system that lets us casually add boundary tests
from existing fixtures whenever we feel one is needed).

## Decision

Establish a **lightweight edge-case test culture** with three
mechanisms:

### 1. New rule file: `.claude/rules/edge_case_testing.md`

Auto-loaded when editing test fixtures or when the active task
modifies semantic boundaries. Codifies:

- **The "気付いたら即追加" trigger**: whenever code touches a
  numeric boundary, special FP value (NaN, ±Inf, ±0, denormal),
  off-by-one in a comparison, or an enum switch with semantic
  edges, **add a fixture in the same commit** unless one already
  exists.
- **Fixture placement convention**:
  - `test/edge_cases/<phase>/<concept>/<case>.wat` source
  - `test/edge_cases/<phase>/<concept>/<case>.wasm` compiled
    artifact
  - `test/edge_cases/<phase>/<concept>/<case>.expect` expected
    outputs (for runner comparison)
- **Fixture extraction patterns** from existing corpora:
  - From spec testsuite: cite the original `.wast` + assertion
    line range; trim to the minimal Wasm module exhibiting the
    boundary.
  - From wasmtime-misc / realworld: same pattern with provenance
    in the fixture's leading WAT comment.
- **Anti-pattern**: "We'll add it later when the test runner
  exists" — that "later" never comes; add the WAT fixture today,
  the runner harness wires up when ready.

### 2. `/continue` Step 4 (Refactor) checklist addition

Existing Step 4 already has a "did you observe debt?" item.
Adding:

- **"Did you cross any semantic boundary in this cycle?"** —
  if yes, was a fixture added? If not, add one or document why
  none is needed. Document = `private/notes/<phase>-<task>-edge-
  case-rationale.md` listing why each candidate boundary was
  declined to test (e.g. "covered by spec assertion line N").

### 3. `audit_scaffolding` skill §I — edge-case coverage

New audit section (CHECKS.md currently uses §A–§G for content
checks + §H for "Output"; this proposal inserts §I before §H or
renumbers §H → §J — implementation cycle picks the cleaner of
the two). Periodic adaptive-cadence check:

- Walks `test/edge_cases/` and verifies each fixture has the
  expected file triple (`.wat` + `.wasm` + `.expect`).
- Cross-references the most recent N commits' touched semantic
  surfaces (numeric op handlers, comparison logic, FP boundary
  code) against fixture additions in the same commit window.
  Surfaces "boundary touched without fixture added" as a `block`
  finding.
- Verifies fixtures' compilation artifact (`.wasm`) is up to
  date with the source (`.wat`); stale artifacts get a `warn`.

### Bootstrapping fixtures (Phase 7 close)

Seed `test/edge_cases/p7/` with the boundaries that ADR-0017 +
sub-h3 + sub-h5 work surfaced and that `/continue` would have
flagged retroactively:

- `p7/trunc_f32_s/at_int_min.wat` — src = -2147483648.0f, expect i32.MIN
- `p7/trunc_f32_s/just_below_int_min.wat` — src = next-f32-below, expect trap
- `p7/trunc_f32_s/at_int_max_plus_1.wat` — src = 2147483648.0f, expect trap
- `p7/trunc_f32_u/negative_one.wat` — src = -1.0f, expect trap
- `p7/trunc_sat_f32_s/nan.wat` — src = NaN, expect 0
- `p7/trunc_sat_f32_s/pos_inf.wat` — src = +Inf, expect i32.MAX
- ... (one per hand-derived boundary)

Each fixture takes ~5 minutes to author (WAT + expect file). The
bootstrap effort is bounded; the regression-prevention value
compounds.

## Alternatives considered

### Alternative A — Rely on spec testsuite alone

- **Sketch**: Trust that wasm-1.0 + wasm-2.0 spec testsuites
  cover the boundaries; don't add internal fixtures.
- **Why rejected**: spec testsuites are generic; they don't
  exercise zwasm-specific implementation choices (e.g. our
  particular FP-bound representation in sub-h3a). When a
  zwasm-internal refactor regresses a boundary, generic spec
  tests may pass with the regression hidden behind aggregate
  counts.

### Alternative B — Add fixtures only when bugs are reported

- **Sketch**: Defer fixture authoring until a real bug surfaces.
- **Why rejected**: P14 (optimisation lands last) implies that
  the bug-surfacing fixtures are needed *before* optimisation
  begins, not during. Reactive authoring is too late.

### Alternative C — Property-based / fuzz testing instead of fixtures

- **Sketch**: Use random fuzzing to hit boundaries; skip hand-
  authored fixtures.
- **Why rejected**: fuzz catches bugs but doesn't document
  intent. Boundary fixtures act as **specifications** of which
  cases the implementation explicitly intends to handle. Fuzz
  is complementary (Phase 14 has a fuzz infrastructure row), not
  a replacement.

## Consequences

### Positive

- **Boundary regressions surface via dedicated fixtures**, not
  buried in aggregate spec-test counts.
- **Optimisation phase (Phase 8 / 15) has a safety net**. Each
  refactor either keeps the boundary fixture green or fails it
  loudly.
- **Knowledge compression**: each fixture is a 1-line
  specification of "this case must work this way". Reading
  `test/edge_cases/p7/` recalls a slice of the implementation
  history that ADRs would over-formalise.
- **The "気軽に追加" trigger lowers cost** — fixtures don't have
  to wait for phase boundaries.

### Negative

- **Test corpus grows**. Estimated 30-50 fixtures per Phase. At
  ~20 KB each (WAT + WASM + EXPECT), 50 fixtures × 5 phases ≈
  5 MB. Negligible.
- **Bootstrapping cost**: seeding `test/edge_cases/p7/` is a
  dedicated cycle (~30 fixtures × 5 min each ≈ 2-3 hours).
- **Stale fixtures**: if implementation changes legitimately
  alter a boundary's expected output, the fixture must be
  updated (or retired with a comment). `audit_scaffolding`'s
  staleness check catches the "stale" case.

### Neutral / follow-ups

- **Runner harness for `test/edge_cases/`**: today, the existing
  `wast_runtime_runner.zig` can drive WAT fixtures with
  expected-output assertions; `test/edge_cases/` slots in
  alongside `test/spec/` etc. Bootstrap cycle wires the
  Zig-build target.
- **Per-phase vs. global**: `test/edge_cases/p<N>/` separation
  acknowledges that some boundaries are phase-specific (e.g.
  sub-h3 trapping bounds become uninteresting once verified).
  `audit_scaffolding` may at later phases collapse stable
  per-phase fixtures into a single shared directory.

## References

- ROADMAP §2 P14 (optimisation lands last) — this rule is the
  safety net that lets P14 land safely.
- W54 post-mortem (`~/Documents/MyProducts/zwasm/.dev/archive/w54-redesign-postmortem.md`) — boundary regressions caused by post-hoc layered optimisation
- Related ADRs: 0017 (JitRuntime ABI — first place this rule
  would have flagged sub-h3 boundaries), 0018, 0019
- `.claude/rules/textbook_survey.md` (rule format precedent)
- `.claude/rules/single_slot_dual_meaning.md` (rule format precedent)
- `/continue` skill, `audit_scaffolding` skill (modified by this ADR)

## Revision history

- 2026-05-04 — Proposed. SHA: `<backfill at acceptance>`
