# 0097 — Extract regalloc verify family into `regalloc_verify.zig`

- **Status**: Rolled back (see ADR-0100)
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (D-141 per-file ADR series, post-ADR-0096)
- **Tags**: file-layout, refactor, zone-2, regalloc, file-size-cap, rolled-back
- **Rolled-back-by**: ADR-0100 (verify family re-incorporated into regalloc.zig at Cycle 4 — this extraction triggered N3 shallow-module per ADR-0099 §D2)

## Context

`src/engine/codegen/shared/regalloc.zig` is at **1401 LOC**, 40%
over the 1000-LOC soft cap (ROADMAP §A2). D-141 lists it among
remaining per-file ADR candidates ("compute/verify/vreg-class
axis split"). Prior extractions:

- ADR-0090: `populateShapeTags` → `regalloc_shape_tags.zig`.
- ADR-0092: `VregClass` + `vregClassByDef` → `regalloc_vreg_class.zig`.

Survey identified four semantic phases: init / compute / verify
/ class. compute (174 LOC algorithm + 50 LOC spill offsets +
forbidden-mask helpers) and verify (3 + 34 LOC) are the two
remaining extractable phases. This ADR covers **verify only**
as Step 1; compute extraction is a follow-up ADR (the algorithm
is larger and uses more internal state, so extracting it
separately keeps each cycle's risk profile small per
architectural-mode discipline).

## Decision

Extract `verify()` + `verifyWith()` + `VerifyError` from
`regalloc.zig` into a new sibling `src/engine/codegen/shared/regalloc_verify.zig`.
Move the 3 `verify:` tests + 2 `verifyWith:` tests alongside;
dup the small `testFenceTableFill` test helper (3 lines) since
both files need it.

| File | Contents |
|---|---|
| `regalloc.zig` (revised) | Allocation struct + methods, Slot/ShapeTag types, Error type, ScratchReservationFn type, forbiddenMaskForVreg + slotForbidden + validateRegallocOpScratchReservation (compute-time fence helpers), compute + computeWith + computeSpillOffsets, deinit, re-exports of populateShapeTags + VregClass + verify/verifyWith/VerifyError, all compute/Allocation/spill/fence tests. |
| `regalloc_verify.zig` (new) | `pub const VerifyError`, `pub fn verify`, `pub fn verifyWith` (the post-condition checker — overlap detection + ADR-0077 fence post-condition), 3 verify tests + 2 verifyWith tests. |

`ScratchReservationFn` type stays in `regalloc.zig` because
`computeWith` consumes it as a parameter; `regalloc_verify.zig`
imports it back declaratively (same lazy-import shape as
ADR-0095 / ADR-0096).

External API surface unchanged: callers reach `regalloc.verify` /
`regalloc.VerifyError` identically via re-exports.

## Alternatives

1. **Bundle compute + verify extraction in one ADR** — Rejected.
   computeWith is the LSRA algorithm (174 LOC) with allocator-
   internal state (free pool, active list, forbidden mask
   threading); higher extraction risk than verify (34 LOC
   post-condition function). Survey explicitly recommended
   verify-first to validate the re-export pattern before
   touching compute.

2. **Move ScratchReservationFn to verify** — Rejected. Survey
   suggested this for "post-condition ownership" cleanliness,
   but compute needs the same type as a parameter; moving forces
   compute to re-import it from verify, inverting the natural
   dependency (compute is the primary consumer of the fence).

3. **Move only verify code, leave tests in regalloc.zig** —
   Rejected. Tests belong with the function they exercise per
   the same edit-locality logic as ADR-0095/0096. The 5 tests
   moved + dup'd testFenceTableFill helper is mechanical.

## Consequences

**Positive**:

- regalloc.zig modestly reduced (~75-90 LOC removed in code+tests).
- `regalloc_verify.zig` is a coherent ~100 LOC module:
  post-condition predicate + its regression tests.
- Zero caller migration.
- Pattern established for follow-up `regalloc_compute.zig`
  extraction (next architectural cycle).

**Negative**:

- regalloc.zig stays WARN (~1310 LOC post-extraction; still over
  1000-LOC soft cap). Follow-up compute extraction needed to
  dissolve the WARN.
- One small test-helper duplication (`testFenceTableFill`, 3
  lines); acceptable per "small test helpers are cheaper to dup
  than share" project idiom.
- One additional file under `src/engine/codegen/shared/`.

**Neutral**:

- Cross-file circular import (regalloc.zig ↔ regalloc_verify.zig)
  resolved via Zig lazy import (same shape as ADR-0095/0096).
- Test gate (`zig build test`) asserts behaviour neutrality.

## References

- ADR-0090 — populateShapeTags extraction (predecessor in
  regalloc-axis series).
- ADR-0092 — VregClass extraction (predecessor).
- ADR-0095 / ADR-0096 — parse/sections extractions (same
  cross-file struct method shape).
- D-141 — file-size soft-cap proliferation.
- ROADMAP §A2 — file-size cap policy.
- ADR-0077 — op_scratch_reservation_table (the fence verified
  by verifyWith).

## Revision history

- 2026-05-21 — Initial draft (Proposed → Accepted same cycle;
  behaviour-neutral refactor; test gate asserts neutrality).
