# 0081 — Extract top-level setup helpers from `emit.zig` into `emit_setup.zig` (Phase 1)

- **Status**: Closed (2026-05-21, impl landed)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (post-ADR-0080 Withdraw pivot)
- **Tags**: file-layout, refactor, zone-2, codegen-x86_64, file-size-cap

## Context

`src/engine/codegen/x86_64/emit.zig` is **1300 LOC** — over the
1000-LOC soft cap (ROADMAP §A2). ADR-0080's proposed int/float
split was Withdrawn 2026-05-21 same day after implementation-
prep verification revealed the per-op-file pattern from ADR-0074
had already absorbed nearly all domain-specific code into
`op_alu_int.zig`, `op_alu_float.zig`, `op_memory.zig`,
`op_convert.zig`, `op_simd*.zig`. See lesson
[`emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md)
for the survey-time discipline gap that motivated this pivot.

The honest measurement of emit.zig's structure (per the lesson's
"count 1-line routes vs inline-recipe LOC distribution"
prescription) is:

| Range | Element | LOC | Kind |
|---|---|---|---|
| 1-98 | imports, type aliases, re-exports | ~98 | scaffolding |
| 99-115 | `computeOutgoingMaxBytes` doc + start | (preamble) | doc |
| 117-195 | `fn computeOutgoingMaxBytes(...) u32` | ~79 | pure top-level helper |
| 196-1215 | `pub fn compile(...) Error!EmitOutput` | ~1020 | main driver |
| 1217-1237 | `pub fn localDisp(...) Error!i32` | ~20 | pure top-level helper |
| 1238-1252 | `const LocalLayout = struct { ... }` | ~14 | top-level struct |
| 1253-end | `fn computeLocalLayout(...) Error!LocalLayout` | ~50 | pure top-level helper |

The **~163 LOC of pure top-level helpers** (`computeOutgoingMaxBytes`,
`localDisp`, `LocalLayout`, `computeLocalLayout`) are extractable
**without touching compile()'s body** — they're called from inside
compile() but have no dependency on its internal scope. They can
move to a new `emit_setup.zig` and be imported back as namespaced
references.

The **~1020 LOC of `compile()`** is the real bloat axis, but
extracting its inner sections (prologue assembly, parameter
marshalling, local zero-init, state init) requires a refactor
that threads state through function arguments — an ADR-grade
design choice on state-passing boundaries. That work is **Phase 2,
deferred to ADR-0082+** when concrete pressure (another
~500-LOC bump pushing emit.zig over hard cap) warrants the
investment.

This ADR (0081) targets **Phase 1 only**: the mechanical
top-level extraction. Goal: emit.zig drops to ~1140 LOC,
still over soft cap, but the per-file-ADR discharge slot in
D-141 (which named emit.zig × 2 arches as one of the
pending-ADR files) closes for the x86_64 side.

## Decision

Extract **four declarations** from `src/engine/codegen/x86_64/emit.zig`
into a new sibling file `src/engine/codegen/x86_64/emit_setup.zig`:

1. `fn computeOutgoingMaxBytes(...)` (lines 117-195)
2. `pub fn localDisp(...)` (lines 1217-1237)
3. `const LocalLayout` (lines 1238-1252)
4. `fn computeLocalLayout(...)` (lines 1253-end)

Total: ~163 LOC of pure-function helpers + 1 struct.

`emit_setup.zig` becomes the home of x86_64 codegen's **frame-
shape + outgoing-region + local-layout** computation. The
helpers are pure (no side effects, no shared state) so the move
is mechanical.

After the move, `emit.zig` adds short package-private aliases
at the top of the file (just below the existing `const
rbpStoreR32 = rbp_disp.rbpStoreR32;` block) to keep call sites
inside `compile()` unchanged:

```zig
const setup = @import("emit_setup.zig");
const computeOutgoingMaxBytes = setup.computeOutgoingMaxBytes;
const computeLocalLayout = setup.computeLocalLayout;
const LocalLayout = setup.LocalLayout;
pub const localDisp = setup.localDisp; // re-export for tests
```

The `pub const localDisp = setup.localDisp;` re-export is
required because `emit_test_int.zig` and `emit_test_float.zig`
reference `emit.localDisp` directly (verified 2026-05-21):

```
src/engine/codegen/x86_64/emit_test_int.zig:19:const localDisp = emit.localDisp;
src/engine/codegen/x86_64/emit_test_float.zig:20:const localDisp = emit.localDisp;
```

External callers of `localDisp` outside the codegen directory:
none (verified by `grep -rn "emit\.localDisp\|emit\.computeLocalLayout\|emit\.computeOutgoingMaxBytes" src/ test/` — only the two test-file aliases above match).

The re-export pattern is the same as `pub const Error = types.Error;`
already used in emit.zig lines 88-91 (the D-030 chunk-a re-export
shape). No external caller change.

### Why "Phase 1 only" (and not the full compile() body extraction)

Phase 1 (this ADR) is **mechanical and observable**:
- Pure-function moves with `git mv`-shaped intent (Zig doesn't
  have file move semantics; the move is "delete from emit.zig,
  add to emit_setup.zig" in one commit).
- compile()'s body unchanged. Test gate (cohort) confirms
  byte-identical JIT output.
- Re-export discipline preserves the `pub fn` discovery surface.

Phase 2 (deferred to ADR-0082+) would extract compile()'s
internal sections (prologue assembly, parameter marshalling,
local zero-init, state init):
- Requires designing **state-passing boundaries**: which fields
  of EmitCtx + which loop-local variables (`p_idx`, `int_arg_idx`,
  `fp_arg_idx`, etc.) need to thread through function args.
- ADR-grade design choice: per-section function vs
  EmitCtx-method vs hybrid. Each has trade-offs (closure
  emulation cost, EmitCtx field bloat, scope coupling).
- Concrete pressure trigger: another ~200-LOC bump in emit.zig
  (Wasm 3.0 GC inline cases? new SIMD recipes?) pushing it
  over 1500 LOC.

Deferring Phase 2 is honest: there is **no concrete pressure
right now** demanding the compile() body refactor. emit.zig at
1140 LOC post-Phase-1 is uncomfortable but not blocking; the
per-file ADR discipline (D-141) is satisfied by ADR-0081's
Acceptance.

### Implementation order (single cycle — this is mechanical)

1. Create `src/engine/codegen/x86_64/emit_setup.zig` with the
   four declarations moved verbatim. Add module docstring
   pointing back to ADR-0081.
2. Update `src/engine/codegen/x86_64/emit.zig`:
   - Remove the four declarations.
   - Add the 5-line import + alias block.
   - Update `pub const localDisp` to re-export.
3. Cohort test gate (test-all on Mac aarch64); confirm green.
4. Single commit + push + ubuntu kick + re-arm.

No spike required — the move is mechanical. Tests already
exercise localDisp + computeLocalLayout indirectly through
compile(); no test changes needed beyond verifying alias.

## Alternatives considered

### Alternative A — Keep monolith + raise soft cap

- **Sketch**: leave emit.zig at 1300 LOC, raise §A2 soft cap
  from 1000 → 1500. Add `// ==== SETUP HELPERS ====` markers.
- **Why rejected**: ROADMAP §A2 caps exist to enforce semantic
  boundaries, not as suggestion. The four helpers are
  genuinely cohesive (frame + outgoing-region + local-layout),
  and emit_setup.zig is below the soft cap with room to grow.
  Cap-raise is a precedent collapse (already rejected in
  ADR-0079 Alt C + ADR-0080 Alt C).

### Alternative B — Extract everything (Phase 1 + Phase 2 together)

- **Sketch**: this ADR also extracts compile() prologue
  (lines 319-377), parameter marshalling (379-551), local
  zero-init (553-577), state init (587-679) into emit_setup.zig
  as named helpers taking ctx + relevant args.
- **Why rejected**: state-threading design is ADR-grade itself.
  Bundling Phase 1 + Phase 2 into one ADR makes the design
  surface area too large to verify in one cycle. ADR-0080 was
  Withdrawn precisely because the bundled scope hid an over-
  estimate. Phase 1 (mechanical) + Phase 2 (real design)
  staged delivery is the lesson's prescribed structure: each
  ADR has one verifiable Decision, not a stacked-design omnibus.

### Alternative C — Domain split (`emit_int.zig` / `emit_float.zig`)

- **Sketch**: ADR-0080's original proposal.
- **Why rejected**: Withdrawn 2026-05-21 same day after
  verification. See lesson + ADR-0080 Revision history. Not
  re-litigated here.

## Consequences

- **Positive**:
  - D-141 row's "emit.zig × 2 arches" slot closes for the
    x86_64 side (arm64 emit.zig is 1183 LOC, separate ADR
    candidate when concrete pressure surfaces).
  - emit.zig drops 1300 → ~1140 LOC (~12% reduction). Still
    over soft cap; honest about that.
  - emit_setup.zig becomes the natural landing slot for any
    future frame-shape helper additions (e.g., Win64-specific
    parameter classifier, MEMORY-class hidden-ptr setup) —
    consistent with the "name files by content" discipline
    from ADR-0079.
  - Test files (`emit_test_int.zig` / `emit_test_float.zig`)
    keep referencing `emit.localDisp` unchanged (re-export
    preserves API).
- **Negative**:
  - One additional file in the x86_64/ codegen directory.
    Mitigated by clear naming: `emit_setup.zig` for
    setup-phase helpers, `emit.zig` for compile-pass driver.
  - emit.zig still over soft cap (1140 > 1000). Phase 2
    refactor remains pending until concrete pressure surfaces.
- **Neutral / follow-ups**:
  - Phase 2 (compile() body extraction) becomes ADR-0082+ if
    pressure surfaces. No commitment yet.
  - D-055 sentinel wire-up + test-array migration are
    **independent** of this ADR; can proceed in parallel
    cycles. D-081 rename to `<source>_test.zig` strict suffix
    is **still blocked** (ADR-0054 amendment OR alternative
    naming path needed; emit_setup.zig doesn't pair with
    emit_test_int/float.zig either).
  - arm64/emit.zig (1183 LOC, also over soft cap) is **out
    of scope for this ADR** — when ADR-0083+ mirrors the
    pattern to arm64, this ADR's shape serves as precedent.

## References

- ADR-0079 — runner.zig 3-way split; shape precedent for
  this Phase 1 mechanical extraction.
- ADR-0080 — Withdrawn 2026-05-21; pivot lesson directly
  produced this ADR's Phase 1 / Phase 2 staging.
- ADR-0074 — per-op-file Zone split (the absorption
  pattern that made ADR-0080's domain split moot).
- ADR-0054 §"Naming convention" — `<source>_test.zig`
  strict suffix; relevant for D-081 (still blocked).
- D-141 — file-size soft cap proliferation; this ADR's
  Acceptance closes the x86_64 emit.zig slot.
- D-055 — sentinel wire-up + test-array migration;
  independent of this ADR.
- Lesson `2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md`
  — the survey-time discipline gap that produced this ADR's
  Phase 1 / Phase 2 staging.
- Source: `src/engine/codegen/x86_64/emit.zig` lines
  117-195 (`computeOutgoingMaxBytes`), 1217-1237 (`localDisp`),
  1238-1252 (`LocalLayout`), 1253-end (`computeLocalLayout`).
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `7945084f` | Initial Proposed version (Phase 1 — mechanical top-level helper extraction). |
| 2026-05-21 | `669b15ac5` | **Status: Accepted** — Phase 1 impl landed. emit.zig 1300 → 1144 LOC (-156); emit_setup.zig 204 LOC (incl. docstring + module header). Test gate cohort (test-all) + lint green. D-141 x86_64 emit.zig slot closes. |
