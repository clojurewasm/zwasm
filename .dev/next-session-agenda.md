# Session plan — 2026-05-04 design + refactor + rules cycle

> **Purpose**: this session is **not** a /continue task-loop session.
> It is a deliberate design + scaffolding cycle. The user invoked
> "議論ファースト" then approved a sequenced implementation plan.
> This file is the per-session source of truth; ROADMAP / ADRs /
> rules are the durable artefacts. Overwrites the prior brain-dump.

## Context (one paragraph)

Prior session closed Phase 7 sub-7.5c-vi (D-027 merge fix). At its
end the user surfaced 10 regret points and asked for: (a) Phase
ordering re-evaluation, (b) AI rule updates from regrets, (c)
refactor work (emit.zig split / liveness frame / byte-offset
abstraction). This session executes a triaged version of all
three after a discussion that converged on:

- **Phase 7 internal sub-gate** (not full ADR-0019 revert).
  Reason: ADR-0019's P7-operationalisation case is strong; the
  weak point is emit.zig's already-3989-LOC state (which is a
  §A2 / §14 forbidden-list violation already, *before* x86_64
  emit work begins).
- **One new rule** (`bug_fix_survey.md` = regret #9), plus
  amendments to two existing rules; the rest of the regrets
  become lessons or commit-message hygiene.
- **Refactor sequence**: byte-offset abstraction → ADR-0021 +
  ROADMAP edits → emit.zig split (deferred to next session — too
  large for a single commit alongside the other work). Liveness
  frame restructure: deferred (no concrete bug, lower priority).

## Sequenced plan (this session)

Each numbered step ends with one or more commits. The whole
sequence runs sequentially in this session.

### Step 1 — ADR-0021 + ROADMAP §9 edits + handover sync

**ADR-0021** (`.dev/decisions/0021_phase7_emit_split_gate.md`):

- **Status**: Accepted.
- **Decision**: Add §9.7 / 7.5d row "emit.zig responsibility
  split + test byte-offset abstraction" as a hard gate before
  7.6 (x86_64 reg_class) opens. ADR-0019 stays in effect.
- **Alternatives**:
  - **A.** Full ADR-0019 revert (Phase 7 ARM64-only). **Rejected**:
    P7 operationalisation argument from ADR-0019 still holds.
    3-host JIT asymmetry would re-emerge.
  - **B.** Defer the split to Phase 8. **Rejected**: emit.zig is
    *already* at 3989 LOC (§A2 hard cap = 2000). x86_64 emit will
    add a parallel 3000+ LOC file. The §14 forbidden-list violation
    exists today; allowing it to compound through Phase 7 violates
    no_workaround.md.
  - **C.** Split emit.zig but allow x86_64 emit.zig to grow
    monolithically. **Rejected**: defeats the split's purpose. New
    file should follow the new structure from day 1.
- **Consequences**:
  - +1 §9.7 row (7.5d). Phase 7 task count grows by 1, which is
    accepted given the §A2 root cause.
  - x86_64 emit work (7.7) becomes structured-from-day-1 instead of
    needing a Phase 8 retro-split.
  - Lesson lineage: cites
    `2026-05-04-emit-monolith-cost.md` (Step 2 of this plan).
- **References**: ADR-0019 (which this ADR amends operationally),
  emit.zig survey at this session, ROADMAP §A2 / §14.

**ROADMAP edits** (per §18.2 four-step):

- §9.7 task table: insert row 7.5d "emit.zig responsibility split
  + test byte-offset abstraction" between 7.5 and 7.6, with note
  "split target documented in `.dev/lessons/2026-05-04-emit-monolith-cost.md`".
- §15 (future decision points): add bullet "End of Phase 7 — does
  the interpreter v1-surface readiness (WASI 0.1 full = Phase 11,
  C API full = Phase 13) merit pulling forward before Phase 8 JIT
  optimisation? Re-evaluate with realworld JIT data from 7.9, not
  speculation now." This documents the user's ordering question
  without committing to it speculatively.

**handover sync**: replace `Active task` table; cite ADR-0021.

**Commit**: `chore(p7): ADR-0021 — emit-split sub-gate + ROADMAP §9.7 + §15 + handover sync`.

### Step 2 — bug_fix_survey rule + lessons batch

**New rule** `.claude/rules/bug_fix_survey.md` (regret #9):

> Before applying a bug fix, survey same-class cases (grep for
> identical symbol / shape) so the fix lands at the population,
> not the symptom. The rule complements `textbook_survey.md`
> (task-start) by addressing **bug-fix-time** survey discipline.

Body sections: rule statement; "why" with D-027 case study (if-result
fix landed in if-then but missed if-else for one cycle because no
sibling-grep happened); 3-step procedure (grep symbol; grep shape;
grep ROADMAP §14 forbidden patterns nearby); reviewer checklist;
when to skip.

**Lessons** (`.dev/lessons/2026-05-04-*.md`):

- `emit-monolith-cost.md` (regret #1) — emit.zig at 3989 LOC was
  predictable; should have split when crossing soft cap (1000 LOC).
- `liveness-stage-extension-debt.md` (regret #2) — staging
  liveness as if/elif/elif chains made a future restructure cost
  visible.
- `adr-0017-merge-blind-spot.md` (regret #3) — ADR-0017 design
  did not anticipate `(if (result T))` join semantics; X19
  amendment hid the original incompleteness.
- `adr-revision-history-misuse.md` (regret #7) — Revision history
  rows doubled as "ADR was always complete" cover; ADRs should
  document gaps openly.
- `adr-batch-dependency-order.md` (regret #10) — ADRs 0017-0020
  filed as a batch; dependency order between them was implicit.

**Amendments** (existing rules; touch with one paragraph each):

- `edge_case_testing.md`: append §"fixture-internal workarounds
  trigger debt entry" (regret #4) — `// FIXME` / constant
  substitution / hardcoded shortcut inside a fixture must yield a
  D-NNN row in `.dev/debt.md`.
- `edge_case_testing.md`: append §"test byte-offset must be
  relative" (regret #6) — magic byte literals in JIT tests must
  use `prologue_size()` + N.

**Index**: 5 rows added to `.dev/lessons/INDEX.md`.

**Commit**: `chore(rules): bug_fix_survey rule + 5 lessons + edge_case_testing amendments (regrets #1-10 triage)`.

### Step 3 — byte-offset abstraction (refactor; behaviour-preserving)

Create `src/jit_arm64/prologue.zig` with:

- `pub const FpLrSave.stp_word: u32 = 0xA9BF7BFD`
- `pub const FpLrSave.mov_fp_word: u32 = 0x910003FD`
- `pub fn prologue_size(has_frame: bool) u32` returning 32 or 36
- `pub fn body_start_offset(has_frame: bool) u32` (alias of above)
- `pub fn assert_prologue_opcodes(bytes: []const u8) !void`

Migrate test sites in `src/jit_arm64/emit.zig` (146 sites; 142
relativisable, 4 fixed-opcode):

- Replace `out.bytes[32..36]` with `out.bytes[body_start..body_start+4]`
  where `const body_start = prologue.body_start_offset(false);`
- Replace magic opcode constants `0xA9BF7BFD` and `0x910003FD`
  with `prologue.FpLrSave.stp_word` / `mov_fp_word`.
- Sites that hard-code the 4 fixed opcodes stay at byte `[0..4]` /
  `[4..8]` (ABI-pinned per AAPCS64 Arm IHI 0055 §6.4); only the
  numeric opcode constants change.

**Out of scope**: do NOT split emit.zig in this session. The
split is sequenced for next session per ADR-0021 (Step 1's
note). Splitting AND migrating offsets simultaneously is a
big-bang change.

**Test gate**: `zig build test` green on Mac native (Step 0 of
the agreed mandatory pre-commit checklist). OrbStack + windowsmini
verifications run before push.

**Commit**: `refactor(p7): introduce src/jit_arm64/prologue.zig; relativize 142 test byte-offsets`.

### Step 4 — three-host gate (no push without user approval)

`zig build test` on Mac → OrbStack (`orb run -m my-ubuntu-amd64`)
→ windowsmini (`bash scripts/run_remote_windows.sh test`). All
three must be green.

**Push policy**: this session is **not** /continue. Per CLAUDE.md
"Pushing outside the autonomous /continue loop requires explicit
user approval", commits stay local until the user signs off at
session end. Reviews (Step 5) and the retrospective ADR (Step 6)
run on local commits.

### Step 5 — implementation diff self-review (subagent x2)

Range: from `8778349` (HEAD at session start) to final commit.

- **Pass 1** (`pr-review-toolkit:code-reviewer` subagent): full
  review focused on (a) project rules adherence (zone_deps,
  no_workaround, edge_case_testing, single_slot_dual_meaning, the
  *new* bug_fix_survey), (b) §A2 / §14 forbidden-list compliance,
  (c) ADR-0021 citation correctness, (d) handover.md sync.
- **Pass 2** (`pr-review-toolkit:code-simplifier` subagent): does
  the byte-offset helper introduce unnecessary indirection? Are
  the 5 new lesson files within the 50-line cap? Does
  `bug_fix_survey.md` overlap with `textbook_survey.md`?

If either review surfaces blocking findings, file as TODO commits
in this session (don't defer to next).

### Step 6 — follow-up retrospective ADR

After all reviews settle, file `.dev/decisions/0022_post_session_retrospective.md`:

- Records the session's redesign work as a single load-bearing
  decision (rather than 5 disparate rule + lesson files).
- Cites ADR-0021 as the operational decision; this ADR is the
  retrospective lens.
- Documents what the regret triage taught about scaffolding
  ordering, why bug_fix_survey is its own rule (not an amendment
  to textbook_survey), and the cost-benefit of keeping
  ADR-0019 intact rather than reverting.
- **Status: Accepted (Retrospective)**.
- **Revision history**: 2026-05-04 — Proposed and accepted in the
  same commit (this is the session-end record commit).

**Commit**: `docs(adr): ADR-0022 — post-session retrospective on regret triage + emit-split sub-gate`.

## Self-review of this plan (mandatory; 2 passes)

### Pass 1 — completeness + ordering

✓ Step 1 (ADR-0021 + ROADMAP) lands BEFORE Step 3 (refactor) so
the refactor cites a load-bearing ADR row, not an undocumented
sub-task.
✓ Step 2 (rules + lessons) is independent of Step 3 — could in
principle parallelize. Sequenced first to keep commit context
clean (rule + ADR commit, then refactor commit, then
retrospective). Order respects regret #10 (ADR dependency
ordering).
✓ Step 3 is behaviour-preserving (only test sites change; no JIT
emit logic touched). Three-host gate verifies.
✓ Step 4 explicitly gates push behind 3-host green.
✓ Step 5 reviews the actual diff range (HEAD → final), not just
the last commit.
✓ Step 6 retrospective ADR closes the loop without papering over
the ADR-0019 acceptance.

**Found**: §9.7 / 7.5d row insertion may renumber existing rows
or trigger §18.3 "Quiet renumbering forbidden" check. Mitigation:
insert as `7.5d` (not "7.5.5") so 7.6+ stay numerically intact.
Already factored into Step 1 plan.

**Found**: Step 3 says "do not split emit.zig in this session" but
adds a new file `src/jit_arm64/prologue.zig`. New file is fine
(emit.zig itself stays unchanged in body; only test imports
change). Confirmed.

**Found**: Step 5 mentions "bug_fix_survey overlap with textbook_
survey" review. The Pass 2 reviewer must explicitly confirm both
rules carry distinct triggers (task-start vs bug-fix-time). If
overlap is real, merge them.

### Pass 2 — risk + commit granularity

**Risk: byte-offset migration is mechanical but error-prone.**
146 sites; hand-migration risks one-byte-off mistakes that hide
behind passing tests (since the test asserts a fixed value at a
fixed offset; if both move in sync, regression invisible).
Mitigation: after migration, **inspect a sample of 5 sites
manually** to confirm the literal value still matches; rely on
3-host gate for the rest.

**Risk: ADR-0021 contradicts ADR-0019 implicitly.** ADR-0019
accepted "Two emit.zig files to maintain. Each per-arch emit will
add ~3000-4000 lines mirroring the other." ADR-0021 reads that
acceptance as inadvertent §A2 violation. The retrospective ADR
(0022) must clarify the lineage: ADR-0019 was *correct on phase
strategy* but *did not address file shape*; ADR-0021 fills the
gap. This is amendment, not contradiction.

**Risk: 3 commits in one session is many.** Granularity check:

| Step | Commit | Estimated diff size |
|------|--------|---------------------|
| 1    | ADR-0021 + ROADMAP + handover | ~150 lines |
| 2    | rule + lessons + 2 rule amendments | ~250 lines |
| 3    | prologue.zig + test migration | ~200 net lines (mostly rewrites) |
| 6    | ADR-0022 (retrospective) | ~80 lines |

4 commits, all under 300 lines, each with a coherent theme. Not
big-bang. Not too granular (1 per commit boundary, not 1 per
artefact).

**Risk: "deferred next session" emit.zig split could rot.**
ADR-0021 makes 7.5d a §9.7 task row, so the next /continue resume
sees it as the next concrete `[ ]` row in the Phase Status widget.
The deferral is durable.

**Risk: 5 lessons in one batch dilutes attention.** Each lesson
has a specific regret index; they're not redundant. But INDEX.md
will jump from 3 rows to 8 rows — verify INDEX scanning stays
tractable. The keyword column is the search axis; spot-check that
all 5 new keywords are distinct.

**Found nothing new.** Plan stands.

## Pre-execution checklist

- [ ] `git status` clean (currently `(clean)` per session boot).
- [ ] HEAD is `8778349` (D-027 fix commit).
- [ ] Step 1 file paths exist or are creatable: `.dev/decisions/0021_*.md`,
  `.dev/handover.md`, `.dev/ROADMAP.md`.
- [ ] Step 2 file paths: `.claude/rules/bug_fix_survey.md`,
  `.dev/lessons/2026-05-04-*.md` (5 new), `.dev/lessons/INDEX.md`,
  `.claude/rules/edge_case_testing.md`.
- [ ] Step 3 file paths: `src/jit_arm64/prologue.zig` (new),
  `src/jit_arm64/emit.zig` (test sites only).
- [ ] Step 6: `.dev/decisions/0022_*.md`.

## Out of scope (for next session or later)

- emit.zig split into 9 modules (per the survey at this session;
  documented in `2026-05-04-emit-monolith-cost.md`). Sequenced as
  §9.7 / 7.5d row.
- liveness.zig restructure — no current bug; lower priority.
- ROADMAP §15 ordering re-evaluation (whether Phase 11/13 should
  move forward) — gated on Phase 7 close + realworld JIT data.
- ADR-0019 partial revert — explicitly rejected by ADR-0021's
  Alternatives §A.

## Decision log (this session, summarised)

- ADR-0019 stays. Phase 7 covers ARM64 + x86_64.
- ADR-0021 inserts 7.5d (emit-split + byte-offset abstraction)
  as a hard gate before 7.6 (x86_64 reg_class) opens.
- bug_fix_survey is a new rule (regret #9 = "twin-largest").
- 5 lessons batch (regrets #1, 2, 3, 7, 10).
- 2 amendments to edge_case_testing.md (regrets #4, 6).
- regret #5 (default value re-changes) → no rule, lives in commit
  message hygiene + the new lesson `liveness-stage-extension-debt.md`.
- regret #8 (sub-row ROADMAP normalization) → addressed in
  ADR-0022's "process improvement" § (handover-to-ROADMAP
  discipline added to /continue skill in a future session). Not
  a §9.7 row by itself — the load-bearing fix is the rule, not a
  one-time bookkeeping task.
