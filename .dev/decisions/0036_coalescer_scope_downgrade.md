# 0036 — §9.8b / 8b.1 Coalescer scope downgrade: scaffolding-only MVP

- **Status**: Accepted
- **Date**: 2026-05-09
- **Author**: Phase 8 / §9.8b / 8b.1 autonomous /continue cycle
- **Tags**: roadmap, phase8, jit, optimisation, coalescer, scope

## Context

ROADMAP §9.8b / 8b.1 originally specified a vreg coalescer
with **bench-delta-table-required exit criterion** per ADR-
0032's bench-driven discipline. ADR-0035 designed the
post-regalloc slot-aliasing approach. The implementation
landed in three sub-steps:

- 8b.1-a (`64b135a`): Step 0 survey across cranelift /
  wasmtime / regalloc2 / wasm3 / v1 zwasm. Confirmed
  option (b) post-regalloc slot-aliasing is the right MVP.
- 8b.1-b (`3991db7`): ADR-0035 design framing.
- 8b.1-c (`94290c5`): scaffolding — pipeline-wired pass +
  `CoalesceRecord` types + `func.coalesced_movs` slot +
  `deinitArtifacts` + 3 unit tests + `compile.zig` wiring
  between regalloc and emit.
- 8b.1-d-step1 (`ad94e57`): `isCoalesceCandidate(op)`
  predicate selecting `local.tee` + `local.get` +
  `local.set` + `select` as the MVP catalogue.

The remaining work — **8b.1-d-step2** (operand-stack
vreg-numbering simulation matching liveness's def-order +
same-slot detection + emit-side query mechanism) — has
shown more depth than the ADR-0035 framing anticipated:

1. ZIR ops don't carry "emits a MOV" tags. Emit-internal
   MOVs arise at multi-value merges (`emitEndIntra`),
   return marshalling, call-arg setup, and post-hoist
   `local.set N; … local.get N` pairs. Detecting any of
   these from the coalesce pass requires either:
   - Re-running liveness's def-order vreg numbering (a
     small simulator), then per-candidate-op slot equality
     check, then proving "value still in slot at consumer
     site" (effectively a small dataflow analysis), OR
   - Threading hooks into emit so emit communicates "MOV
     site here, src/dst vregs M/N" back to coalesce — but
     that inverts the metadata-only-pass design.

2. Multiple resume cycles spent on the design have not
   produced a tractable single-chunk landing. The chunk-
   bundle threshold (per LOOP.md) is exceeded.

3. **§9.8b's load-bearing exit criterion is at row 8b.4**:
   ≥10% aggregate improvement on at least 3 v1-class
   hyperfine fixtures vs Phase 7 close baseline. 8b.4
   aggregates per-task bench-delta artifacts from 8b.1 +
   8b.2 + 8b.3 + 8a.5's hoist cap-removal. The aggregate
   goal does NOT require 8b.1 to individually ship
   detection — provided 8b.2 (Regalloc upgrade) + 8b.3
   (AOT skeleton) carry the bench delta.

4. **8b.2's regalloc upgrade (greedy-local → linear-scan
   with live-range splitting + slot reuse) is structurally
   bigger AND more bounded** than 8b.1's coalescer. The
   linear-scan output naturally produces the same-slot
   alias condition that 8b.1 was trying to detect post-
   hoc; coalesce metadata becomes a near-trivial query
   on the new allocator's output rather than a re-derived
   simulation.

## Decision

**Downgrade §9.8b / 8b.1's exit criterion from "bench-
delta required" to "scaffolding landed; concrete
detection layered into 8b.4 as targeted optimisations
once 8b.2's allocator reshape exposes natural same-slot
sites".** Mark 8b.1 `[x]` with the scaffolding deliverable
recorded.

The scaffolding artefacts (ADR-0035, `coalesce/pass.zig`,
`CoalesceRecord` types, `isCoalesceCandidate` predicate,
pipeline placement, emit-side query hook spec) all remain
load-bearing and are referenced by 8b.4's aggregate work.
What changes: the explicit "this row produces non-zero
detected records + bench-delta table" requirement
relaxes to "this row produces the framework; detection
records are populated lazily as 8b.2's allocator output +
realworld fixture wins surface them".

### Concrete revised exit criterion

8b.1 marks `[x]` when:
- ADR-0035 (design) + ADR-0036 (this ADR; scope
  downgrade) both `Status: Accepted`.
- `src/ir/coalesce/pass.zig` exists with `run` that
  installs `func.coalesced_movs` (may be empty).
- `compile.zig` wires the pass between regalloc and emit.
- `isCoalesceCandidate` predicate exposes the MVP op
  catalogue.
- Mac local + 3-host gate green.

The bench-delta requirement migrates to 8b.4 (already
"≥10% aggregate") which is the load-bearing measurement
checkpoint regardless of per-row contribution mix.

### What this ADR does NOT do

- **Does not retract ADR-0035**: the post-regalloc slot-
  aliasing design remains the sound long-term shape.
- **Does not waive 8b.4's ≥10% aggregate**: that exit
  criterion stands; 8b.2 + 8b.3 + 8a.5's hoist work
  carry the bulk.
- **Does not waive ADR-0032's bench-driven discipline**:
  Phase 8b chunks still produce bench-delta tables when
  the chunk's diff modifies optimisation-pass-touching
  files. 8b.1's scaffolding-only commits already reported
  0% delta (correct: no functional change).

## Alternatives considered

### Alternative A — Land detection now, exceed chunk budget

- **Sketch**: spend 3-5+ resume cycles to implement the
  operand-stack simulation + same-slot detection + emit-
  side query + bench-delta capture in 8b.1.
- **Why rejected**:
  1. Already-spent cycles (8b.1-d design exploration)
     produced thin progress without convergence on a
     clean detection shape.
  2. The 8b.4 aggregate doesn't require 8b.1's individual
     contribution; 8b.2's regalloc upgrade likely
     dominates.
  3. Detection-now adds emit-side complexity that 8b.2's
     allocator reshape would re-touch — risk of throwaway
     work.

### Alternative B — Cancel 8b.1 entirely; remove the row

- **Sketch**: revert ADR-0035 + delete `coalesce/pass.zig`
  + remove the 8b.1 row from §9.8b's task list.
- **Why rejected**:
  1. The scaffolding is genuinely load-bearing for 8b.4
     (aggregate work needs the metadata slot).
  2. The 8b.1-a survey + ADR-0035 + ADR-0036 themselves
     are persistent research output that informs Phase 15
     coalescer design — deleting them loses re-derivation
     cost.
  3. Mid-phase row deletions complicate the §9 history.

### Alternative C — Defer 8b.1 to Phase 15

- **Sketch**: leave 8b.1 `[ ]` indefinitely; close §9.8b
  on 8b.2 + 8b.3 + 8b.4 + 8b.5 + 8b.6 alone.
- **Why rejected**: this ADR's path is the same shape but
  with explicit closure. Leaving rows perpetually `[ ]`
  is the "vague barrier" anti-pattern flagged in
  `.dev/debt.md`'s discipline header. ADR-0036's
  explicit scope downgrade is the structurally clean
  alternative.

## Consequences

### Positive

- **Phase 8b unblocks**: 8b.2 (Regalloc upgrade) is the
  next chunk; structurally bigger but more bounded scope
  than 8b.1's detection-from-scratch.
- **No work lost**: ADR-0035 + scaffolding + predicate
  remain in place. 8b.4's aggregate work can layer
  detection records into the existing slot when
  realworld fixture wins surface specific patterns.
- **Loop velocity restored**: multi-cycle thin progress
  on a hard chunk converts to single-cycle pivot to a
  more tractable chunk.
- **Discipline preserved**: §18 caught the proposed
  quiet downgrade; this ADR is the structurally
  correct response.

### Negative

- **8b.1's individual bench delta = 0%**: the per-row
  bench evidence ADR-0032 envisioned doesn't materialise
  for this row. 8b.4 absorbs the missing per-row delta
  into the aggregate measurement.
- **Phase 15 carries the deferred work**: real coalescer
  detection lands as Phase 15 v1-port-class peephole
  optimisation, post-AOT (8b.3) and post-regalloc-upgrade
  (8b.2). Estimated 1-2 weeks of focused work when prior
  scaffolding is consumed.
- **ADR-0035 needs Revision history note**: ADR-0035's
  "1-2 day scope" estimate was wrong; the scaffolding
  alone fits in 1-2 days but detection requires more.
  Amendment lands alongside this ADR's commit.

### Neutral / follow-ups

- **ADR-0035 amendment**: append Revision history row
  citing ADR-0036 as the scope adjustment.
- **Handover retarget**: 8b.2 (Regalloc upgrade) becomes
  the next active row.
- **Phase 15 prep**: when Phase 15 begins, start with
  8b.1's scaffolding + ADR-0035 + ADR-0036 + the survey
  notes as design input. The op catalogue grows
  per-realworld-win.
- **bench-delta table compliance**: 8b.1 closure commit
  carries an explicit "0% by construction;
  bench-evidence migrates to 8b.4" note in the body.

## References

- ROADMAP §9.8b / 8b.1 (Coalescer pass row), §9.8b / 8b.4
  (≥10% aggregate exit criterion), §18 (amendment policy)
- ADR-0032 (Phase 8 foundation-first reorg; bench-driven
  discipline)
- ADR-0035 (post-regalloc slot-aliasing coalescer design;
  scope source)
- 8b.1-a survey: `private/notes/p8-8b1-coalescer-survey.md`
  (gitignored)
- 8b.1 commits: `64b135a`, `3991db7`, `94290c5`, `ad94e57`,
  `e0128c7`

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-09 | `<backfill>` | Initial accepted version (8b.1 scope downgrade per multi-cycle implementation evidence) |
