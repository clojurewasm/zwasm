# 0085 — Extract arm64 emit setup helpers into `emit_setup.zig`

- **Status**: Closed (2026-05-21, draft + impl landed same cycle)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0084)
- **Tags**: file-layout, refactor, zone-2, codegen-arm64, file-size-cap

## Context

`src/engine/codegen/arm64/emit.zig` is **1632 LOC** — 63% over
the 1000-LOC soft cap (ROADMAP §A2). D-141 lists it among per-file
ADR candidates. Direct mirror of x86_64/emit.zig before ADR-0081
split (which dropped x86_64/emit.zig from 1300 → 1144 LOC).

Quick measurement (no full Step 0 survey needed — pattern already
established by ADR-0081):

- 3 top-level helpers usable for extraction:
  - `fn computeOutgoingMaxBytes(...)` (lines 111–...; ~70 LOC)
  - `const LocalLayout = struct {...}` (lines 206–214; ~10 LOC)
  - `fn computeLocalLayout(...)` (lines 223–...; ~80 LOC)
- 0 external callers (`grep -rn "emit\.localDisp\|emit\.computeLocalLayout\|emit\.computeOutgoingMaxBytes" src/ test/` returns nothing for arm64).
- All helpers internal to `compile()`'s body; pub-ification needed
  only for cross-file access from sibling.

## Decision

Mirror ADR-0081's x86_64 extraction to arm64. Move the 3 helpers
to `src/engine/codegen/arm64/emit_setup.zig`. emit.zig adds an
import + alias block (7 lines) to keep compile() call sites
unchanged.

| File | Contents | Approx LOC |
|---|---|---|
| `src/engine/codegen/arm64/emit.zig` (revised) | compile() driver, dispatch loop, prologue/epilogue emission, state init, all GPR encoders' callers | ~1479 |
| `src/engine/codegen/arm64/emit_setup.zig` (new) | computeOutgoingMaxBytes + LocalLayout + computeLocalLayout + 22-line header + std/builtin/zir/ctx_mod imports | ~186 |

Difference from ADR-0081 (x86_64 case):

- arm64 does NOT have a `localDisp` function (x86_64-specific
  RBP-relative disp formula). Extraction is just 3 declarations
  vs x86_64's 4.
- arm64 imports `ctx_mod.Error` instead of `types.Error` (x86_64
  uses types.zig; arm64 uses ctx.zig — different module
  organisation per the codegen subtree's history).

### Implementation order

Drafted + impl landed in same cycle since the design is a direct
mirror of ADR-0081 (no novel design surface, mechanical
extraction):

1. Python extraction script (mirrors ADR-0081 / -0082 / -0084
   pattern): identify target functions/structs by name, walk
   braces for body boundaries, write extracted to sibling file
   + reduce original.
2. Add 7-line `const setup = @import(...)` + aliases to emit.zig
   (parallel of ADR-0081's pattern).
3. Pub-ify the 3 extracted decls + their `deinit` method.
4. Build + cohort gate (test-all) + lint. All green.

## Alternatives considered

### Alternative A — Defer until concrete pressure surfaces

- **Sketch**: keep arm64/emit.zig at 1632; wait for next bloat
  to push it past hard cap.
- **Why rejected**: D-141's per-file ADR series is the structural
  fix for soft-cap proliferation. ADR-0081 set the precedent for
  x86_64; not mirroring leaves arm64 inconsistent. The cycle
  cost is small (no struct-method handling per lesson
  `cross-file-struct-method-syntax-zig-0-16.md`; pure top-level
  helpers per `emit-zig-survey-per-op-pattern-already-absorbed.md`).

### Alternative B — More aggressive extraction (split prologue/epilogue, dispatch sub-tables)

- **Sketch**: extract prologue assembly + epilogue + dispatch
  loop separately into multiple sibling files.
- **Why rejected**: same anti-pattern as ADR-0080 (fragmentation
  without semantic gain). compile() function body is one cohesive
  walk over ZirFunc.instrs; splitting its inner sections requires
  state-threading design (ADR-grade on its own, deferred until
  needed).

## Consequences

- **Positive**:
  - emit.zig drops 1632 → 1479 LOC. Still over soft cap but
    -153 LOC reduction.
  - Pattern composes: future emit.zig setup helpers (e.g.,
    new frame-shape variants for Wasm-FX, multi-memory) land
    in emit_setup.zig automatically.
  - D-141 arm64/emit.zig slot closes.
- **Negative**:
  - emit.zig still over soft cap (1479 > 1000). Honest about
    that — compile() body extraction requires state-threading
    refactor (Phase 14+ candidate; ADR-grade on its own).
- **Neutral / follow-ups**:
  - x86_64/inst.zig is **already** per-family split (inst_alu /
    inst_mem / inst_branch / inst_sse per the orchestrator's
    docstring) — not a refactor target. Discovery this cycle.
  - lower.zig (1109 LOC) `Lowerer = struct {...}` is the
    next candidate; needs ADR-0083-pattern (struct-method
    extraction) per cross-file-method-syntax lesson.

## References

- ADR-0081 — x86_64 emit_setup.zig (direct precedent).
- ADR-0084 — arm64 inst_fp.zig (immediate-prior arm64-side
  extraction).
- D-141 — file-size soft-cap proliferation.
- Lesson
  [`2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed`](../lessons/2026-05-21-emit-zig-survey-per-op-pattern-already-absorbed.md)
  — measurement-focused survey discipline.
- ROADMAP §A2 — file size soft (1000) / hard (2000) caps.

## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `41095fc8e` / `6d71eb60` | Initial draft + impl landed same cycle. arm64/emit.zig 1632 → 1479 LOC; emit_setup.zig 186 LOC new. Test gate cohort + lint green. |
