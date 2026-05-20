# 0071 — Phase 9 substrate audit resolution + §9.12 scope amendment

- **Status**: Accepted
- **Date**: 2026-05-19
- **Author**: continue loop §9.9 close + 2026-05-19 substrate audit design session
- **Tags**: phase-9, substrate-audit, dispatch-architecture, build-option-dce, scope-amendment

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
| §2 P13 | Accept (maintain) — Day-1 ZIR sized for full target. **Re-evaluate at §9.12-B implementation if op-surface gaps emerge** (collab-gate user note: "実装段階で不足判明したら amend"). |
| **§2 P14** | **Amend (sharpen)** — "Only **runtime** if-branching on feature flags is forbidden. `if (comptime build_options.X)` in `comptime` contexts is permitted; recommended for build-option DCE purposes." See **Structural cohesion caveat** below. |
| §4.5 | Amend — DispatchTable interp axis = required (mvp complete); validator/lower/emit/jit axes = per-op file pattern (= consistent with ADR-0023 §4.5 amend; per `0023` Revision history) |
| §4.6 | Accept (consistent with Q3) — Leverage `-Dwasm=` / `-Dwasi=` build flags consistently across all layers for DCE |

#### Structural cohesion caveat (Q2 P14 sharpening)

The sharpening permits `if (comptime build_options.X)` and `inline for + continue`
DCE idioms; this is NOT a license for ad-hoc inline branching. The original
intent of P14 was **responsibility decomposition** — runtime feature branching
was always closer to "experimental escape hatch" than "required capability".

Therefore:

- **Prefer block-level or module-level cohesion** when a comptime branch can be
  hoisted to a single declaration / collector / dispatcher. The dispatch_collector
  pattern (per ADR-0073) is the canonical shape.
- **Inline `if (comptime ...)` is the fallback**, used only when no block/module-
  level rewrite is cleaner.
- Code review (and `audit_scaffolding §K.1`) flags scattered comptime branches
  that could be consolidated.
- If an inline branch persists, the reviewer must articulate why a block/module-
  level rewrite would be worse — the burden is on inline, not on consolidation.

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

### Q5 — Substrate hygiene + existing-artifact dedup sweep (note)

The Q5 deliverables (per ADR-0072 + §9.12-C) include the new `comment_as_invariant`
rule, `audit_scaffolding §G` extensions, D-133 register-numeral sweep, `runtime_
instance_layer.md` rule, and edge_case_testing "stress axes" section. In
addition, **§9.12-C MUST conduct a dedup sweep** of existing rules / lints
whose role becomes redundant or stale upon landing the new ones — concretely
`no_workaround.md`, `bug_fix_survey.md`, and any `audit_scaffolding §G` grep
that overlaps with the new comment-as-invariant lint. The goal is that a
reader hitting `.claude/rules/` after §9.12-C sees a coherent set, not a new-
plus-old hybrid in which the same advice is restated in two places. This is
recorded in §9.12-C's ROADMAP exit criterion (added at §9.12 Accept).

### Q6 — libc dependency boundary (note)

Adopt ADR-0070 (3-category policy + 16-site inventory + 5 deliverables) in
§9.12-D. User intent at §9.12 collab gate: this is **about putting the libc
surface under management for forward visibility into Phase 10+** (AOT / 組込
/ Windows native), not about eliminating libc immediately. The `necessary`
set keeps stable until upstream Zig stdlib closes the gap; the `replaceable`
set sweeps to `std.posix.*` in §9.12-D as proof the policy has teeth.

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

The three architectural hypotheses (A, B, C) plus the current half-state (D-1) and the original
narrow-scope reading of §9.12 were each measured against the user's design-quality axes
(structural cleanliness / resistance to latent bugs / ease of root-cause isolation;
explicitly **not** wall-clock cost or implementation effort, per the 2026-05-19 feedback
that those axes induce compromise).

### Alternative A — Complete §4.5 as originally written (function-pointer DispatchTable)

- **Sketch**: Implement all 9 features × `register(*DispatchTable)`; populate
  `DispatchTable.validate[op] / .lower[op] / .interp[op] / .arm64[op] / .x86_64[op]` at
  runtime startup. Validator / lower / emit dispatch sites become 5-axis table lookups
  (`return table.interp[@intFromEnum(op)](state)`). Per-op handler bodies live in
  `src/feature/<feature>/<op>.zig` and are registered by `register.zig` per feature.
- **Strengths**: source organisation by feature is clean; one table-cell-flip per
  feature toggle (runtime); zware-influenced; the existing `DispatchTable` scaffold
  in `src/ir/` already half-supports this shape.
- **Why rejected**: **build-option DCE is structurally impossible** — the table is a
  *runtime data structure* populated at program startup, so the LLVM linker cannot
  prove which entries are unreached. A `-Dwasm=v1_0` build would still link the
  v2.0/v3.0 `register_*` functions and all their referenced handler bodies. The
  `.text` section would not shrink. This violates user requirement (iii) — "in a
  `-Dwasm=v1_0` build, Wasm 2.0+ code / CLI arguments / c_api / WASI must be
  literally absent". Falls short on "small" + "literal absence" + "1 op = 1 file
  (handlers across 5 axes are scattered across `src/feature/<f>/<op>.zig` × 5
  feature subdirs, not co-located)".

### Alternative B — Comptime-gated exhaustive switch (wrap existing arms)

- **Sketch**: Abolish `DispatchTable` and `src/instruction/wasm_X_Y/` placeholders.
  Each of the 5 dispatcher files (`validator.zig`, `lower.zig`, `arm64/emit.zig`,
  `x86_64/emit.zig`, `interp/dispatch.zig`) keeps its single exhaustive `switch
  (ZirOp)`; each Wasm-2.0+ arm is wrapped in
  `if (comptime build_options.wasm_level >= .v2_0) { ... } else
   return Error.UnsupportedOpForBuildLevel;`. LLVM DCE deletes unreachable
  arms.
- **Strengths**: build-option DCE works (the arm bodies are statically unreachable
  and get stripped); validator and emit each remain a single self-contained file
  (good for grep + readability); minimal disruption to the existing §9.9 code path;
  the current §2 P14 wording can be sharpened to permit this idiom rather than
  rewritten.
- **Why rejected**: each dispatcher remains a **monolith**. `validator.zig` already
  sits at 1699 LOC with the switch at line 515; the same op's validate-arm,
  lower-arm, arm64-emit-arm, x86_64-emit-arm, and interp-arm live in 5 distinct
  files, so understanding the full lifecycle of one op requires 5 file reads + 5
  grep operations. This violates user requirement (4) "modular preparation" and the
  master plan's design-axis priority "1 op = 1 file / consistent across all layers".
  Bug localisation (D-126 / D-132 / D-148 class) gets harder, not easier, as ZirOp
  grows toward Phase 10's 581 tags.

### Alternative D-1 — Hybrid (maintain current half-A + half-C state)

- **Sketch**: Fill in the 4 placeholder feature `register.zig` files so
  `DispatchTable` is fully populated (Hypothesis A's surface), but keep the
  exhaustive switches in the 5 dispatcher files as the actual binding (current
  reality). Add build-option consultation at 2-3 high-level entry points (e.g.
  `cli/main.zig` rejecting `--enable-gc` on a v1_0 build).
- **Strengths**: smallest delta from current state; §9.9 momentum preserved; no
  spike risk on `inline switch` compile-time.
- **Why rejected**: this is the existing latent-debt state. It violates user
  requirement (iii) "literal absence" (build-option DCE doesn't reach the
  dispatchers; v2.0+ code stays in the binary). It violates requirement (4)
  ("modular preparation so Phase 10 proceeds without friction") because Phase 10's
  GC / EH / tail-call additions would extend the same monolithic switches by
  another 100+ arms each. The 2026-05-19 feedback explicitly names "any change in
  the direction of compromise" as physically blocked — D-1 IS the compromise.

### Alternative E — Keep §9.12 scope narrow (decisions only, no implementation)

- **Sketch**: §9.12 closes with ADRs + spike measurements; the per-op file
  migration / DCE substrate work moves entirely into Phase 10's first sub-rows.
- **Why rejected**: user requirement (3) "incorporate insights sparing no effort"
  + (4) "Phase 10 starts with ground fully prepared" + (6) "drastic reorganization"
  are stated as Phase 9 deliverables, not Phase 10's. Splitting the substrate work
  across the phase boundary means Phase 10 cannot start adding Wasm 3.0 features
  until the substrate lands — so it's substrate-first regardless of which Phase
  owns the work. Owning it in Phase 9 makes the "Phase 10 entry gate clean" claim
  literal.

### Alternative F — Hypothesis C with central-collector ONLY (no per-layer DCE)

- **Sketch**: Adopt the per-op file pattern + `dispatch_collector.zig` for
  ZirOp / validator / lower / emit / interp, but keep CLI / c_api / WASI as
  current (no declarative form, no build-option DCE on those layers).
- **Why rejected**: the master plan's Chapter 4 cross-layer consistency goal
  treats the substrate as 4 parallel applications of the same pattern. Adopting
  it only at the IR/codegen layer leaves 3 layers in the legacy shape, and the
  user's "consistent pattern across every layer" requirement (additional
  feedback iii) is not satisfied. ADR-0073 codifies the full 4-layer
  application; this ADR-0071 entry adopts it by reference.

## Consequences

### Positive

- **1 op = 1 file across 5 axes**: validate / lower / arm64 / x86_64 / interp handlers
  for a single op live in `src/instruction/wasm_X_Y/<op>.zig`. Root-cause of a bug
  (e.g. D-126 / D-132 / D-148 class) localises to one file rather than requiring 5
  parallel grep operations across `validator.zig` / `lower.zig` / `arm64/emit.zig` /
  `x86_64/emit.zig` / `interp/dispatch.zig`.
- **Literal absence under `-Dwasm=v1_0`**: Wasm 2.0+ handler bodies, CLI args
  (`--enable-gc`), c_api exports (`wasm_v128_extract` ELF symbol), and WASI p2
  syscalls are not in the binary — confirmed by `nm` + `size` in spike
  `q3-build-option-dce-poc/`. Attack-surface and binary-size both shrink.
- **Cross-layer consistency**: the same declarative-metadata + comptime-filter
  pattern applies to 4 layers (IR, CLI, c_api, WASI). Adding a new layer in the
  future (e.g. proposed `-Dtarget=embedded` minimal build) reuses the same
  boilerplate.
- **Phase 9 completion exit is literal**: `skip-impl == 0` across spec /
  edge_cases / realworld / differential corpora + 4 test tracks green is a
  measurable PASS criterion, not a narrative one.
- **§2 P14 sharpening clarifies intent**: the pre-amendment wording was being
  read by both authors as forbidding `if (comptime build_options.X)` —
  blocking the build-option DCE substrate. The amendment names the
  failure-mode it actually targets (runtime if-branching on feature flags,
  per Wasmer/Cranelift's runtime-toggle style) and explicitly permits the
  comptime form.

### Negative

- **§9.12-B implementation scope is large**: all 5 dispatchers must be
  rewritten into the `inline switch + collector` form, and all 581 ZirOp
  tags need a corresponding `src/instruction/wasm_X_Y/<op>.zig` file.
  Per-op file completeness is enforced by a comptime check in
  `dispatch_collector.zig` (cannot be silently skipped).
- **Zig 0.16 `inline switch` compile-time wall**: 581 tags is on the upper
  edge of what Zig 0.16's sema has been exercised against. Spike
  `q3-zig-inline-switch/` measures the wall position and the
  `@setEvalBranchQuota` knob; if the wall is hit, the master plan
  Chapter 8 §8.3 specifies a tag-range split (Cranelift `isle-split-match`
  equivalent) as the workaround. Wall position is not a reason to
  compromise on the design.
- **§9.12 ROADMAP table grows to 11 sub-rows**: vertical real estate is a
  price paid for visibility. Each sub-row is a real deliverable; the
  table is not padded.
- **CLI / c_api / WASI reshape touches user-facing surfaces**: the
  declarative-form rewrite affects API stability, though all 3 are
  pre-1.0 (zwasm v2 has not shipped) so no compatibility break is paid.
  The `include/wasm.h` upstream is preprocessor-gated by build-option;
  consumers building against zwasm c_api now control feature surface
  via the same `ZWASM_WASM_LEVEL` macro.

### Neutral / follow-ups

- **ADR-0073** carries the build-option DCE substrate detail (all 4 layers,
  declarative-metadata shape, central collector form, spike results).
- **ADR-0023 §4.5 amend** formalises the per-op file pattern in the directory-
  structure ADR.
- **ADR-0050 amend** adds the skip-impl one-way ratchet (D-5 + D-6 sub-decisions).
- **Phase Status widget wording** flips in a commit landing after the §9.12
  collab gate Accepts this ADR (master plan Chapter 6.2).
- **ROADMAP §14** gains forbidden-list entries (`Unconscious libc fanout` via
  ADR-0070; `Skip-impl count regressions` via ADR-0050 amend).
- **The 9-item enforcement layer** (master plan Chapter 7) lands in §9.12-A
  before any §9.12-B implementation begins; this prevents the substrate from
  silently sliding back to D-1 during the migration cycle.

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
| 2026-05-19 | `bdd433d5` | Initial skeleton — §9.12 scope amendment justification; full draft in §9.12-pre.  |
| 2026-05-19 | `<backfill>` | Full draft populated in §9.12-pre — Alternatives A/B/D-1/E/F + Consequences + Structural cohesion caveat (Q2 P14). |
| 2026-05-19 | `<backfill>` | **Accepted** at §9.12 collab gate. Q2 P13 = Accept (re-evaluate at §9.12-B if op gaps) / Q2 P14 = Amend with structural cohesion caveat / Q2 §4.5 = Amend (interp required; 4 axes per-op file) / Q2 §4.6 = Accept (4-layer DCE) / Q3 = Hypothesis C / Q4 = Decision + minimal PoC / Q5 = 5 deliverables + dedup sweep / Q6 = under-management forward-looking policy. ROADMAP §9.12 → [x]; §14 forbidden list amended; Phase Status widget wording updated. |
