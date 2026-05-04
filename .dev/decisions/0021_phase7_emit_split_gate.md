# 0021 — Insert Phase 7 sub-gate for emit.zig split + test byte-offset abstraction before x86_64 emit work

- **Status**: Accepted
- **Date**: 2026-05-04
- **Author**: Shota / design + refactor cycle session
- **Tags**: roadmap, phase7, refactor, file-shape, jit, amend-0019

## Context

ROADMAP §A2 / §14 forbidden list cap a single source file at 2000
lines (hard cap). `src/jit_arm64/emit.zig` currently sits at 3989
lines — already double the cap, with no §A2 audit having flagged
it during Phase 7 implementation cycles. The cap was crossed
incrementally across sub-7.3 (op coverage), sub-7.4 (runtime
infra), and sub-7.5 (spec gate work) without a refactor cycle.

ADR-0019 (accepted 2026-05-04) pulled x86_64 backend work into
Phase 7 alongside ARM64 (rows 7.6 / 7.7 / 7.8 / 7.10), explicitly
documenting in its Negative Consequences §:

> Two emit.zig files to maintain. Each per-arch emit will add
> ~3000-4000 lines mirroring the other.

ADR-0019 made the right call on phase strategy (operationalising
P7 backend equality) but did not address the file-shape
implication. If 7.6 (x86_64 reg_class + abi) opens with the
current emit.zig structure as the ARM64 template, x86_64's emit.zig
will mirror the same monolithic shape — producing **two §A2
violations** instead of one, and locking in the v1-class W54
substrate (post-hoc layered changes onto an unmaintainable shape)
that v2 was redesigned to avoid.

A second motivation: 146 hard-coded byte offsets in emit.zig's
test suite assume a fixed 32-byte ARM64 prologue size. The
prologue grew during sub-2 (ADR-0017's 5 LDRs) and the 124+
sites needed manual updates. Phase 7's x86_64 work + Phase 15's
optimisation hoist work will trigger the same cascade. A
`prologue_size()` helper isolates the prologue-shape knowledge to
one place.

This ADR partially amends ADR-0019 by inserting a hard sub-gate.
ADR-0019's phase staging stays intact; this ADR adds the
file-shape precondition the earlier ADR failed to surface.

## Decision

**Insert ROADMAP §9.7 row 7.5d "emit.zig responsibility split +
test byte-offset abstraction" as a hard gate before row 7.6
(x86_64 reg_class) opens.**

The 7.5d row contains two sub-deliverables:

1. **emit.zig split** into ~9 modules under `src/jit_arm64/`
   (proposed shapes documented in
   `.dev/lessons/2026-05-04-emit-monolith-cost.md`):
   - `emit.zig` — orchestrator, ≤ 1000 LOC
   - `ops_const.zig`, `ops_alu.zig`, `ops_memory.zig`,
     `ops_control.zig`, `ops_call.zig`
   - `bounds_check.zig`, `register.zig`, `emit_helpers.zig`,
     `label.zig` (Label struct + D-027 `merge_top_vreg` field)
   The split target: every module ≤ 400 LOC; orchestrator ≤ 1000
   LOC; both within §A2 soft cap.

2. **Test byte-offset abstraction** via a new
   `src/jit_arm64/prologue.zig` module exposing `prologue_size(has_frame)`,
   `body_start_offset(has_frame)`, opcode constants
   (`FpLrSave.stp_word`, `FpLrSave.mov_fp_word`), and an
   `assert_prologue_opcodes(bytes)` helper. Migrate 142
   relativisable test sites (4 stay fixed-opcode per AAPCS64
   ABI pinning, Arm IHI 0055 §6.4).

The split itself ships in a future session per its own /continue
cycle; this ADR commits the byte-offset abstraction in this
session as the lighter half. Sub-deliverable 2 closes the
immediate prologue-cascade risk; sub-deliverable 1 closes the
§A2 violation before x86_64 emit lands.

**Row 7.6 (x86_64 reg_class + abi) does not open until 7.5d
closes.** This sequencing is the load-bearing change — without
it, ADR-0019's file-shape implication compounds.

## Alternatives considered

### Alternative A — Full ADR-0019 revert (Phase 7 ARM64-only)

- **Sketch**: Revert ADR-0019. Phase 7 = ARM64 baseline only;
  Phase 8 = x86_64 baseline (back to original).
- **Why rejected**: ADR-0019's three primary justifications
  (P7 operationalisation; 3-host JIT asymmetry; W54-class
  regression risk from staggered backends) all still hold. Full
  revert re-introduces the asymmetry. The fix for emit.zig's
  shape is orthogonal to phase staging.

### Alternative B — Defer the split to Phase 8

- **Sketch**: Allow Phase 7 to ship with the current emit.zig.
  Split during Phase 8 once x86_64 emit also exists.
- **Why rejected**: §A2 hard cap is `forbidden` per §14 — the
  state already violates. `no_workaround.md`'s "fix root causes,
  never work around" applies. Allowing the violation to
  compound through Phase 7 is paper-over.

### Alternative C — Split emit.zig but allow x86_64 emit.zig to grow monolithically

- **Sketch**: Refactor ARM64 only; let x86_64 ship as a 3000+
  LOC file and split later.
- **Why rejected**: Defeats the split's purpose. The new shape
  exists precisely so x86_64 can mirror it from day 1, not as
  retrofit. Mirror-then-split is W54-class.

### Alternative D — Only do byte-offset abstraction; defer split

- **Sketch**: This session does sub-deliverable 2 only; the
  split is a separate ADR for next session.
- **Why partially adopted**: This is exactly what this session
  ships (split deferred to its own /continue cycle, byte-offset
  helper lands now). The ADR records both halves as one
  decision so the sequencing constraint (7.6 blocked by 7.5d
  closure) is unambiguous.

## Consequences

### Positive

- **§A2 violation discharged before compounding.** x86_64 emit
  starts on a structured template, not a monolith.
- **Prologue-cascade isolation.** Future prologue changes
  (Phase 8 optimisation, Phase 15 v1 ports) update one helper,
  not 142 test sites.
- **Cited regret #1** (`.dev/lessons/2026-05-04-emit-monolith-cost.md`)
  becomes load-bearing instead of observational. The next
  /continue cycle reads 7.5d as the active row.

### Negative

- **+1 row in §9.7** (12 → 13 rows). Phase 7 task count grows
  to accommodate the structural fix.
- **Split work itself is large** (estimated 800-1200 net lines
  redistributed across 9 modules) — sequenced as its own
  /continue cycle, not bundled with this session.

### Neutral / follow-ups

- The §15 future decision points list gains an entry: "End of
  Phase 7 — re-evaluate whether interpreter v1-surface
  readiness (WASI 0.1 full = Phase 11, C API full = Phase 13)
  should pull forward before Phase 8 JIT optimisation."
  Documented as user-surfaced ordering question; defers
  decision to post-Phase-7 with realworld JIT data, not
  speculation.
- ADR-0017 / ADR-0018 lineage stays intact; the sub-gate
  doesn't change those ADRs' decisions.

## References

- ROADMAP §9.7 (task table — amended here)
- ROADMAP §A2 / §14 (file-size cap)
- ROADMAP §15 (future decision points — added bullet)
- ADR-0019 (which this ADR operationally amends; ADR-0019's
  phase staging stays accepted)
- Lesson: `.dev/lessons/2026-05-04-emit-monolith-cost.md`
  (proposed split target)
- emit.zig responsibility survey (this session, in-context)
- Byte-offset survey (this session, in-context; 146 sites
  catalogued, 142 relativisable, 4 fixed-opcode)

## Revision history

| Date       | Commit       | Summary                            |
|------------|--------------|------------------------------------|
| 2026-05-04 | `<backfill>` | Initial Decision; sub-gate inserted. |
| 2026-05-04 | `<backfill>` | Sub-deliverable a scope reduced. **Why (gap, per the `adr-revision-history-misuse` lesson written this session)**: the original Decision text said "Migrate 142 relativisable test sites" in the same commit as the helper module. In practice that's a 132-site mechanical rewrite that benefits from running alongside the emit.zig split (sub-b), not as a standalone commit racing the rest of this session's design work. **What changed**: helper module `src/jit_arm64/prologue.zig` lands per the original plan; pattern demonstrated at 4 representative test sites + new rule (`edge_case_testing.md` §"Test-side byte offsets must be relative") gates new sites. Bulk migration of the remaining ~128 sites runs under sub-b. The hard gate "row 7.6 does not open until 7.5d closes" is unchanged — both sub-a and sub-b must close before x86_64 work begins. |
