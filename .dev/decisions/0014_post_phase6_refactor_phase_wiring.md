# 0014 — Wire a refactor & consolidation phase between Phase 6 and the JIT phase

- **Status**: Accepted
- **Date**: 2026-05-03
- **Author**: continue loop + interactive dialogue
- **Tags**: phase-6, phase-boundary, refactor, renumber, wiring,
  precondition-for-charter

## Context

During Phase 6 reopen iteration (ADR-0011 + ADR-0012), several
"あるべき論" gaps surfaced:

- defensive workarounds accumulated (W-1〜W-7 in commit
  `b10abef`).
- bug-discoverability gaps (e.g. `popOperand` debug.assert
  panicking instead of surfacing typed traps).
- magic numbers (`max_operand_stack=4096`, `max_frame_stack=256`,
  `128-slot result buffer`, `4 << 20` corpus byte limits, etc.)
  scattered across files without central audit.
- file-size soft-cap WARNs unaddressed (`src/c_api/instance.zig`
  1494 LOC, `src/frontend/sections.zig` 1073 LOC).
- code consolidation candidates (parse-validate-lower pipeline
  duplicated between `wast_runner.zig` and `wast_runtime_runner.zig`).
- code-split candidates (large files; per-feature validator splits
  carry-over from §9.5 / 5.4).
- root-cause vs symptom triage (39 trap-mid-execution + 78
  runtime-runner failures need substrate-level attention before
  Phase 7 JIT lands atop them).

User raised in 2026-05-03 dialogue: before Phase 7 (JIT v1 ARM64
baseline) starts, insert a refactor & consolidation phase.

This ADR documents only the **wiring decision** — where the phase
lives, what triggers its drafting, the renumber implications. The
phase's own charter (Goal / Exit criterion / work-item DAG /
relationship to existing ADRs / scaffolding rule revisits / out-
of-scope items) is the **next-session ADR-0015 draft**.

## Decision

### 1. Placement

Insert a new phase between the current Phase 6 (v1 conformance
baseline, reopened per ADR-0011 + ADR-0012) and the current Phase 7
(JIT v1 ARM64 baseline).

The new phase becomes **§9.7 (refactor & consolidation)**. The
existing §9.7 (JIT v1 ARM64 baseline) renumbers to **§9.8**. Every
subsequent phase shifts +1:

| Old           | New           |
|---------------|---------------|
| §9.7 (JIT v1 ARM64) | §9.8 |
| §9.8 (JIT v1 x86_64 🔒) | §9.9 |
| §9.9 (SIMD-128) | §9.10 |
| §9.10 (Wasm 3.0 🔒) | §9.11 |
| §9.11 (WASI 0.1 + bench infra) | §9.12 |
| §9.12 (AOT) | §9.13 |
| §9.13 (C API full 🔒) | §9.14 |
| §9.14 (CI matrix) | §9.15 |
| §9.15 (perf parity + ClojureWasm migration) | §9.16 |
| §9.16 (v0.1.0 🔒) | §9.17 |

ADR-0011's renumber-rejection rule (which protected the open
Phase 6) does NOT apply here because Phase 6 is closed at the
moment this renumber takes effect. The renumber is mechanical
text shifting — no semantic change to any non-§9.7 phase.

### 2. Trigger

The renumber + new §9.7 opening fires as part of the Phase 6
close gate (§9.6 / 6.J), replacing the standard "open §9.7
inline" step from the `continue` skill's Phase boundary handler:

- Standard: `Phase Status widget gets §9.7 = IN-PROGRESS;
  §9.7 task table opens inline mirroring §9.6's structure`.
- Per this ADR: `Phase Status widget gets §9.7 = IN-PROGRESS
  (refactor & consolidation; ADR-0015 draft pending). The
  renumbered §9.8〜§9.17 inherit their old §9.7〜§9.16 row
  text verbatim. New §9.7 opens with one row "7.0 Draft
  ADR-0015 (refactor phase charter)". Subsequent rows
  populate from ADR-0015's Decision §6 once Accepted.`

The handover.md "Active task" pointer at 6.J close points
directly at §9.7 / 7.0 (Draft ADR-0015), so the autonomous
loop's next wakeup naturally enters charter-drafting mode
without code-level changes to the skill.

### 3. ADR numbering for the charter

The full refactor phase charter (Goal / Exit criterion / work-
item DAG / relationship to existing ADRs / scaffolding rule
revisits / out-of-scope items) is **ADR-0015**. ADR-0014 (this
ADR) covers only the wiring; ADR-0015 covers the content.

Rationale: keeping the wiring decision separate from the charter
content lets ADR-0015 be a discussion ADR drafted in dialogue
without blocking the wiring. If ADR-0015 ends up superseded by
ADR-0016 etc. as the discussion converges, ADR-0014 (this
wiring) stays stable.

### 4. ADR-0015 draft brief (carried in handover, generic by design)

The drafter (user + Claude in dialogue) covers at minimum:

1. Goal + Exit criterion in measurable terms.
2. Work-item taxonomy mirroring ADR-0012's §6 DAG (discovery /
   design re-examination / consolidation / split / bug-class
   elimination / magic-number centralisation / workaround
   inventory + root-cause replacement / test- and bench-
   fixture organisation revisit / etc.).
3. Relationship to ADRs 0008 / 0011 / 0012 / 0013 — supersede,
   extend, or independent.
4. Relationship to scaffolding rules (ROADMAP §1-§5 / §11 /
   §14 / §18, `.claude/rules/*`) — is any rule itself due for
   refactor as part of this phase?
5. Out-of-scope items deferred to later phases.

Resist over-specifying work items at draft time — the phase's
*shape* is the discussion target. Implementation detail emerges
from discussion, not from the ADR draft.

### 5. Handover wiring

`.dev/handover.md` carries the actionable next-session pointers:

- "Phase 6 close → automatic refactor-phase ADR drafting"
  section explains the post-6.J flow.
- "ADR-0015 draft brief" section reproduces §4 above for
  next-session readers.
- The Active task pointer at 6.J close becomes "§9.7 / 7.0
  Draft ADR-0015".

## Alternatives considered

- **(α) New §9.6 / 6.K** (refactor as last work item of Phase 6).
  Rejected: scope creep, mixes correctness (Phase 6 charter
  per ADR-0008) with designedness. Phase 6 risks not closing.
- **(γ) Phase 6.5 half-step** notation. Rejected: not in
  ROADMAP §9 numbering convention; equivalent to (β) below
  with non-standard label.
- **(δ) Inline-edit Phase 6 to insert refactor** without renumber.
  Rejected: Phase 6's charter (ADR-0008) is correctness-only;
  refactor is a separate concern.

The chosen approach (insert + renumber, β in the dialogue
shorthand) was preferred per user direction.

## Consequences

### Positive
- Phase 6 honest-close happens naturally (no scope-creep into
  refactor).
- Phase 7 JIT lands atop a refactored substrate, not atop
  workaround-laden Phase 6 code.
- Renumber is mechanical text shifting; no semantic ripple to
  existing ADRs because they reference Phase 6 by number which
  is unchanged.
- Autonomous loop transitions naturally; no skill change needed.

### Negative
- Renumber edits §9.8〜§9.17 row positions; readers comparing
  ADR-0008 / 0011 / 0012 / 0013 to current ROADMAP must
  remember "Phase 7 = refactor now, JIT moved to Phase 8".
- ADR-0008's Phase 6 schedule references "Phase 7 (JIT v1
  ARM64) cannot open until Phase 6 is DONE on all three
  hosts" — the wording stays correct because §9.7 is now
  refactor (which the renumber moves JIT to §9.8); the
  semantic intent ("JIT does not start until Phase 6 closes")
  is preserved + strengthened by the new §9.7 being a
  prerequisite for §9.8.

### Neutral / follow-ups
- ADR-0015 must be drafted in the next user-attended session
  before §9.7 work items beyond 7.0 (Draft) can populate.
- §9.6 / 6.J row text gets a small annotation pointing at this
  ADR's wiring; the row's scope (test-all green + bench-quick
  green + audit + widget flip) is unchanged.
- ROADMAP §9.7 (JIT v1 ARM64) row text moves verbatim to §9.8.
  No content change; just relocation.

## References

- ROADMAP §9.6 (Phase 6 — closes per this wiring's trigger),
  §9.7-§9.16 (renumber +1 per §1 above)
- ROADMAP §A5 (differential test gates Phase 7+ — semantic
  reference to "Phase 7" updated to "Phase 8" by this renumber)
- ADR-0008 (Phase 6 charter — semantic intent preserved)
- ADR-0011 (Phase 6 reopen — its renumber-rejection rule does
  not apply here; explicit non-conflict)
- ADR-0012 (Phase 6 reopen scope — work items 6.A〜6.J unchanged)
- ADR-0013 (runtime-asserting WAST runner design — independent)
- ADR-0015 (forthcoming — refactor phase charter content)
- `.dev/handover.md` "Phase 6 close → automatic refactor-phase
  ADR drafting" section (operational wiring)
