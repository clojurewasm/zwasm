# 0030 — Split x86_64/emit.zig tests to emit_test.zig (D-051 close)

- **Status**: Accepted
- **Date**: 2026-05-08
- **Author**: Phase 8 / §9.8 / 8.2 autonomous /continue cycle
- **Tags**: roadmap, phase8, refactor, file-shape, jit, x86_64, mirror-adr-0021

## Context

D-051 names `src/engine/codegen/x86_64/emit.zig` (4305 LOC) as
exceeding ROADMAP §A2 / §14's 2000-LOC hard cap. The file's
8-chunk D-030 split (4925 → 2796 LOC, commits `cd3ced5`..`78bb577`)
discharged the previous violation, but subsequent §9.7 work
(7.5d/e + 7.7 + 7.9/7.10) re-grew the file by ~1500 LOC.

The §9.8 / 8.2 entry survey (private/notes/p8-8.2-survey.md;
re-derivable from the codebase) maps the regrowth to:

- **Test blocks (line 1249–4305, ~3053 LOC)** — inline tests
  accumulated across every Phase 7 chunk. ARM64's `arm64/emit.zig`
  (post-ADR-0021 sub-deliverable b) extracted tests to a sibling
  `emit_test.zig` and 6 family-split test modules; x86_64 never
  performed the equivalent extraction.
- **Orchestrator `compile()`** (lines 153–1022, ~870 LOC) — the
  param-marshaling Win64/SysV overflow paths + locals zero-init
  + frame setup live here.
- **Helper functions** (`localDisp`, RBP store/load wrappers,
  `rspSub`, `rspAdd`) — ~200 LOC of supporting infrastructure
  already trimmed by D-030 into supporting structure.

A naive mirror of ADR-0021's prologue.zig extraction (originally
proposed in D-051 description as "ADR `0030_x86_64_prologue_split.md`")
yields ~200–400 LOC reduction, leaving emit.zig at ~3900–4100 LOC
— still 2× the cap. Survey concludes: **prologue extraction is
not the load-bearing reduction path on x86_64**. Test extraction
is.

## Decision

**Primary path** — extract all inline test blocks (lines 1249–4305
of emit.zig) to a new sibling file `src/engine/codegen/x86_64/
emit_test.zig`, mirroring `arm64/emit_test.zig`'s shape. Add a
discovery hook to `src/zwasm.zig` so `zig build test` reaches the
new file via the existing root-imports chain. Make 1 private
helper (`localDisp`) `pub` to preserve test access; tests already
use the other consumed helpers via their existing public surfaces
(`emit.compile`, `emit.Error`, `emit.deinit`, `op_call.emit
ShadowAlloc`).

**Post-extraction target**: `emit.zig` ≤ 1300 LOC; `emit_test.zig`
~3050 LOC. The new test file lands above the §A2 soft cap (1000
LOC) but per ADR-0021's revision-history precedent (arm64's
`emit_test.zig` was 1986 LOC at the same close-up cycle), test-
file LOC overage is **acceptable when test discovery is
mechanically aggregated** — the file is a discovery surface, not
an authored module. A subsequent family-split into `emit_test_
alu_int.zig` / `emit_test_memory.zig` / etc. (mirroring arm64's
final shape) is **deferred** to opportunistic Phase 8 cleanup;
not load-bearing for D-051 closure.

**Tier-2 deferral** — `prologue.zig` extraction (D-051 description's
original proposed ADR) is **deferred**. Rationale:

- Test extraction alone closes D-051 (emit.zig drops below the
  hard cap). The hard-cap binding is the operative constraint.
- x86_64 prologue is multi-dimensional (`uses_runtime_ptr × cc ×
  has_frame × frame_bytes`) vs ARM64's `has_frame: bool`. A
  faithful mirror requires a richer helper surface
  (`body_start_offset(uses_runtime_ptr: bool, has_frame: bool,
  frame_bytes: u32) u32` + cc-pivot logic) AND ~50–80 test sites
  to migrate (most via offset computation, not pattern scanning).
  The migration is mechanical but high-volume — better timed with
  a Phase 8 optimisation commit that already touches the test
  byte assertions.
- Deferring per ROADMAP §P14 ("defer rather than work around")
  with a concrete trigger: re-evaluate when `emit.zig` next
  approaches the 1000-LOC soft cap, OR when a Phase 8 optimisation
  pass changes the prologue shape (regalloc upgrade, AOT skeleton).
  Deferred follow-up is tracked as a fresh debt row D-052 in the
  same commit that lands this ADR.

## Alternatives considered

### Alternative A — Faithful mirror of ADR-0021 (prologue + helper)

- **Sketch**: Extract prologue/epilogue + body_start_offset helper +
  opcode-constant module to `prologue.zig`. ~200–400 LOC moved.
- **Why rejected**: Insufficient. emit.zig stays ~3900–4100 LOC,
  still 2× the §A2 cap. The helper landing without test extraction
  would make `prologue.zig` immediately stale (new tests would
  reach for hardcoded offsets again, undoing the abstraction).

### Alternative B — Multi-vector extraction (prologue + params + locals + tests)

- **Sketch**: Run all four extractions (prologue + compile_args +
  frame_ops + emit_test) in one chunk. Total ~1100–1400 LOC moved.
- **Why rejected**: Scope creep. Each extraction has its own
  refactor risk surface (param marshaling has cc-pivot logic;
  local-frame ops have alloc/spill interactions). Bundling
  multiplies the regression surface for a single commit gate.
  Tier-1 (test extract) is a pure mechanical move; Tier-2
  (structural extracts) can be scheduled when their individual
  cost/benefit makes sense.

### Alternative C — Wait until Phase 9+ (SIMD lands; emit.zig grows again)

- **Sketch**: Defer all extraction; accept §A2 violation through
  Phase 8 optimisation work.
- **Why rejected**: §14's "forbidden" semantics — the cap is a
  hard rule, not a guideline. The 2026-05-08 lesson
  `file-size-blindspot` documents the prior failure mode
  (interpret "acknowledged" as "fine"). Discharging now prevents
  recurrence.

### Alternative D — Mechanical full-flush mirror of ARM64 (test family split)

- **Sketch**: Extract tests AND immediately split into
  `emit_test_alu_int.zig` / `emit_test_alu_float.zig` / `emit_test_
  control.zig` / `emit_test_memory.zig` / `emit_test_call.zig` /
  `emit_test_local.zig` mirroring arm64's 6-file final shape.
- **Why partially adopted**: The discovery aggregator pattern
  (this ADR's emit_test.zig) IS the entry point for that family
  split. Whether to do the immediate family-split on top of
  monolithic extraction is a separate-cost decision; arm64 itself
  iterated through the monolithic emit_test.zig phase before the
  family split. Following the same iteration pattern lets each
  step's correctness be verified independently. Family split
  deferred to opportunistic Phase 8 cleanup.

## Consequences

### Positive

- **D-051 closes.** emit.zig drops below §A2 hard cap.
- **Mirror of ARM64 close-up.** Per ADR-0021's amendment pattern
  (`emit_test.zig` extraction sub-b chunk 10), x86_64 reaches
  the same baseline shape arm64 uses.
- **Test file LOC overage is structural, not authored.** New tests
  added to the discovery aggregator won't trigger fresh §A2
  violations until the soft cap re-binds (~6× current size for
  the hard cap to bind).

### Negative

- **One private helper goes pub** (`localDisp`). Acceptable: the
  helper is a 12-line offset computation; making it pub doesn't
  enlarge the API surface meaningfully and exposing it for
  external test verification is in line with arm64's analogous
  `emit_test_local.zig` / `gpr.zig` exposure pattern.
- **Prologue extraction deferred.** Tracked as D-052 with concrete
  trigger condition (per ROADMAP §P14).

### Neutral / follow-ups

- Family-split of `emit_test.zig` into per-op-class siblings
  (mirror of arm64) is opportunistic Phase 8 cleanup; not a debt
  row.
- The helper-based byte-offset migration described in the survey
  (~30–40 hardcoded sites) lands alongside D-052's prologue
  extraction, not in this commit. Until then, tests retain their
  current literal-offset shape — acceptable because the prologue
  shape itself is unchanged by this refactor.

## References

- ROADMAP §9.8 / 8.2 (this ADR's source row)
- ROADMAP §A2 / §14 (file-size cap)
- ADR-0021 (prior-art template — arm64 emit.zig split + ADR-0021
  sub-deliverable a's `prologue.zig`)
- ADR-0026 (x86_64 emit split — D-030 discharge; this ADR is the
  follow-up for the same file)
- D-051 (debt row — closed by this ADR's primary path)
- D-052 (new — prologue extraction deferred; lands in same commit)
- Lesson: `.dev/lessons/2026-05-08-file-size-blindspot.md` (the
  CHECKS / LOOP gap that allowed the regrowth)
- Survey: `private/notes/p8-8.2-survey.md` (gitignored;
  re-derivable from the codebase per `lessons_vs_adr.md`)

## Revision history

| Date       | Commit       | Summary                            |
|------------|--------------|------------------------------------|
| 2026-05-08 | `89dee4d2` | Initial Decision; emit_test.zig extraction primary; prologue extraction deferred to D-052. |
| 2026-05-11 | `030ce80a` | **Honest re-bloat record** (per 2026-05-11 ADR audit, SUMMARY §4.2 / batch_C). Post-discharge `emit.zig` was 1247 LOC; current 1983 LOC (under the 2000 hard cap but well past the 1300 target this ADR named). Same drift pattern that motivated this ADR initially. Phase 9 SIMD work re-bloated the file by ~700 LOC; the §A2 gate remains opt-in. ADR-0030 itself is not the right discharge vehicle for the new bloat — D-052 (prologue extract trigger) is `now`-eligible per its "approach to 1000-LOC soft cap" criterion (clearly exceeded), and D-057 / D-065 cover the SIMD-side hard-cap breaches in adjacent files. The structural fix (gate-as-pre-commit-hook) is recorded in D-057's discharge sequencing. No design change. |
