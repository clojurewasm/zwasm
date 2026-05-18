# 0071 — Phase 9 substrate audit resolution + §9.12 scope amendment

- **Status**: Proposed
- **Date**: 2026-05-19
- **Author**: continue loop §9.9 close + 2026-05-19 substrate audit design session
- **Tags**: phase-9, substrate-audit, dispatch-architecture, build-option-dce, scope-amendment

> **Status**: skeleton. This ADR will be expanded to a full draft in §9.12-pre.
> This file is a placeholder that satisfies the §18.2 prior-ADR requirement for
> the §9.12 sub-row expansion (ROADMAP §9 amend). The skeleton of Context /
> Decision is already in place; Alternatives / Consequences / implementation
> details will be populated in §9.12-pre.

## Context

The Phase 9 completion substrate audit (ROADMAP §9.12; per ADR-0062) was originally
scoped as "Q2-Q4 design decisions only". However, during the 2026-05-18 to 19
sessions:

1. **The "skip-impl == 0" claim was found to be inaccurate** — measurements show
   243 directives remain (193 non-simd + 50 SIMD). `SKIP-CROSS-MODULE-IMPORTS`
   (100) + `SKIP-NO-LINK-TYPECHECK` (26) + `SKIP-VALIDATOR-GAP` SIMD (50) +
   manifest skip-impl (1).

2. **The user finalized the 7 requirements for Phase 9 completion**
   ([`.dev/phase9_completion_master_plan.md`](../phase9_completion_master_plan.md) Chapter 1):
   - Full resolution of debt / ADRs, Wasm 2.0 completion 100%, fixation of
     learnings, Phase 10 ground preparation, bench baseline, scaffolding
     iteration speed, windowsmini cross-platform sweep.

3. **Additional feedback** (2026-05-19): The direction was finalized to
   establish the two-stage control of true DCE via build-option + runtime option
   as a consistent pattern across all layers.

4. **Fact-check of the current substrate state**:
   - ZirOp 581 tags (Wasm 3.0 slots aligned); `src/instruction/wasm_X_Y/<op>.zig`
     3514 LOC existing; only `src/feature/mvp/mod.zig` has a register()
     implementation, the other 9 features are placeholders;
     `build_options.wasm_level` is consulted at only 2 CLI diagnostic sites.
   - Task #2 survey confirmed the system is running on a half-completed
     Hypothesis D-1 (details: `private/notes/p9-close-q3-arch-survey.md`).

## Decision

**Expand the scope of §9.12 (Phase 9 substrate audit) as follows** and unfold
it into the implementation stage in the sub-rows §9.12-pre / §9.12-A..I.

### Q2 — Re-examination scope resolution

| Clause | Adoption |
|---|---|
| §2 P13 | Accept (maintain) — Day-1 ZIR sized for full target |
| **§2 P14** | **Amend (sharpen)** — "Only **runtime** if-branching on feature flags is forbidden. `if (comptime build_options.X)` in `comptime` contexts is permitted; recommended for build-option DCE purposes." |
| §4.5 | Amend — DispatchTable interp axis = required (mvp complete); validator/lower/emit/jit axes = per-op file pattern (= consistent with ADR-0023 §4.5 amend; per `0023` Revision history) |
| §4.6 | Accept (consistent with Q3) — Leverage `-Dwasm=` / `-Dwasi=` build flags consistently across all layers for DCE |

### Q3 — Architecture adoption = **Hypothesis C** (per-op file + comptime collector + build-option DCE)

Selection rationale (design quality axes):

| Aspect | A | B | **C** | D-1 |
|---|---|---|---|---|
| True DCE via build-option | Not possible (table runtime populate) | Possible | **Possible** | Not possible |
| 1 op = 1 file | × | × (monolith) | **◎** | △ |
| Consistent pattern across all layers | × | △ | **◎** | × |

By adopting C: (a) understanding one op only requires reading one file to see
all 5-axis handlers (b) a `-Dwasm=v1_0` build has the Wasm 2.0+ handlers
**literally absent** (c) extending the same pattern to CLI / c_api / WASI
makes the feature flag substrate consistent across all layers. The detailed
implementation form is fully covered in ADR-0073 (build-option DCE substrate).

### Q4 — Boundary between audit and implementation

Audit deliverables = ADR + decisions + 3 spike measurements + minimal
implementation sample (implement the representative op `i32.add` in the C
pattern and confirm test pass across 6 build option combinations). The C
migration of the remaining ops + DCE extension across all layers is handled in
§9.12-B. Q5 / Q6 are in §9.12-C / §9.12-D. The Wasm 2.0 100% drainage
(skip-impl 243 → 0) is in §9.12-E, which is the **main exit criterion for
Phase 9 completion**.

### §9.12 ROADMAP scope amendment

§9.12 expands into the following sub-rows:

```
§9.12-pre   ADR drafts (4 new including this ADR + 2 amends) + 3 spike (autonomous)
§9.12-A     Scaffolding compression + enforcement layer construction (details: master plan §7)
§9.12-B     Q3 C adoption completion + build-option DCE extension across all layers (ADR-0073 implementation)
§9.12-C     Q5 hygiene landings (ADR-0072 + rule + lint + code)
§9.12-D     Q6 libc boundary (ADR-0070 + rule + sweep)
§9.12-E     ★ Wasm 2.0 completion 100% (skip-impl 243 → 0 + 4 exhaustive test families)
§9.12-F     Phase-9-eligible debt cohort
§9.12-G     Phase 10 prep substrate
§9.12-H     Bench baseline (Mac-only Wasm 2.0 + wasmtime)
§9.12-I     ADR + lesson + private/ closure
```

§9.13-0 (Cat IV windowsmini) and §9.13 (Phase 10 entry gate) remain as-is.

## Alternatives considered

> Skeleton stage. Detailed expansion to be done in §9.12-pre.

### Alternative A — Hypothesis A complete (all DispatchTable axes populated)

- Sketch: Implement 9 features × register() + convert validator/lower/emit to table consumption
- Rejected: **True DCE via build-option is not possible** (the table is populated at runtime). Falls below the other proposals in the Q3 adoption evaluation.

### Alternative B — comptime-gated switch (wrap the existing switch with `if (comptime ...)`)

- Sketch: Abolish DispatchTable + revert from `src/instruction/` to validator/lower/emit
- Rejected: `validator.zig` etc. remain as monoliths; the "1 op = 1 file" organization cannot be achieved. Inferior to C on the design quality axes.

### Alternative D-1 — Hybrid (maintain the current half-A + half-C state)

- Sketch: Minimal finishing in §9.12-B (fill in 4 placeholders) + add build-option consultation
- Rejected: True DCE via build-option not addressed; the design continues in a half-finished state.

### Keep §9.12 scope narrow as design decisions only (= as originally per ADR-0062)

- Sketch: §9.12 = decisions; implementation moves to Phase 10
- Rejected: The user's requirements (7 items for Phase 9 completion) explicitly state they cannot be carried over to Phase 10; "starting Phase 10 with the ground prepared" is a requirement.

## Consequences

- **Positive**:
  - All 5 axes are localized in 1 op = 1 file (= the root cause of a bug is immediately identifiable)
  - `-Dwasm=v1_0` build literally does not include Wasm 2.0+ code in the binary (size + attack surface reduction)
  - CLI / c_api / WASI are feature-gated with a consistent pattern across all layers
  - Phase 9 completion exit can be literally verified by "skip-impl == 0 + 4 exhaustive test families green"

- **Negative**:
  - §9.12-B has a large implementation scope (rewriting all 5 dispatchers into the inline switch + collector form)
  - The compile-time wall of the 581-tag `inline switch` in Zig 0.16 awaits spike measurement
  - §9.12 sub-rows balloon to 11 rows → ROADMAP §9 table becomes vertically long (price of visibility)

- **Neutral / follow-ups**:
  - File ADR-0073 (build-option DCE substrate) separately as a new ADR
  - Amend ADR-0023 §4.5 separately (formal adoption of per-op file pattern)
  - Amend ADR-0050 separately (skip-impl one-way ratchet)
  - Phase Status widget wording update will be done in a commit after this ADR is Accepted

## References

- ROADMAP §1, §2 (P/A), §4.5, §4.6, §9.12, §9.12-pre to §9.12-I
- Related ADRs:
  - ADR-0023 (src directory structure; §4.5 amend pair)
  - ADR-0050 (ADR lifecycle; skip-impl ratchet amend pair)
  - ADR-0056 (Phase 9 scope extension)
  - ADR-0062 (substrate audit gate anchor)
  - ADR-0065 (Wasm 1.0 instance work Phase 9 rescope)
  - ADR-0070 (libc dependency policy; Q6)
  - ADR-0072 (comment-as-invariant rule; Q5)
  - ADR-0073 (build-option DCE substrate; details of Q3 C adoption)
- Master plan: [`.dev/phase9_completion_master_plan.md`](../phase9_completion_master_plan.md)
- Design discussion: [`.dev/phase9_completion_substrate_audit.md`](../phase9_completion_substrate_audit.md)
- Survey outputs (gitignored): `private/notes/p9-close-q3-arch-survey.md`, `private/notes/p9-close-skip-impl-inventory.md`

## Revision history

| Date       | SHA          | Note                                                                              |
|------------|--------------|-----------------------------------------------------------------------------------|
| 2026-05-19 | `<backfill>` | Initial skeleton — §9.12 scope amendment justification; full draft in §9.12-pre.  |
