# 0022 — Post-session retrospective: 2026-05-04 design + refactor + rules cycle

- **Status**: Accepted (Retrospective)
- **Date**: 2026-05-04
- **Author**: Shota / design + refactor + rules cycle session
- **Tags**: retrospective, process, scaffolding, regret-triage

## Context

This ADR is a **retrospective record** of the 2026-05-04 design
+ refactor + rules cycle session — distinct from /continue
task-loop sessions in process and intent. The user invoked
"discussion-first, then sequenced implementation". Outputs
landed in 4 commits (`4a2da3c`, `2b35fd1`, `04c2453`, `50b691b`)
preceded by the planning commit (`96ddfdb`) which persisted the
agenda.

This ADR exists because the user explicitly requested a
"後追いのADR" (after-the-fact ADR) capturing the session as a
single load-bearing record, complementing ADR-0021 (the
operational sub-gate decision) with the broader process lens.

The session was triggered by 10 regret points the user surfaced
at the prior session's close:

1. emit.zig should have been split at the soft cap, not the hard cap
2. liveness handlers grew via if/elif/elif chains (deferred restructure)
3. ADR-0017 missed CFG join semantics; X19 amendment hid the gap
4. fixture-internal workarounds had no debt-entry discipline
5. `Allocation.max_reg_slots` default value churned 3 times
6. test byte-offsets hard-coded to fixed prologue size
7. ADR Revision history rows used as cover, not gap acknowledgement
8. autonomous-loop sub-row decomposition not reflected in ROADMAP
9. bug-fix-time discipline missing (twin-largest regret)
10. 4-ADR batch had implicit dependency order

## Decision

The session shipped these load-bearing artefacts:

1. **ADR-0021** — emit-split sub-gate (§9.7 / 7.5d hard gate
   before 7.6 x86_64 opens). Operationally amends ADR-0019.
2. **ROADMAP §9.7 row 7.5d** — captures the emit.zig split + test
   byte-offset abstraction work as a Phase 7 task.
3. **ROADMAP §15 bullet** — defers Phase 8/11/13 ordering re-evaluation
   to end-of-Phase-7 with realworld JIT data.
4. **`bug_fix_survey.md` rule** — addresses regret #9; complements
   `textbook_survey.md` along the task-start vs bug-fix-time axis.
5. **5 lessons** under `.dev/lessons/2026-05-04-*.md` — capture
   regrets #1, #2, #3, #7, #10 with re-derivable observations
   (each ≤ 51 lines per `lessons_vs_adr.md`).
6. **2 amendments to `edge_case_testing.md`** — codify
   regrets #4 (fixture-internal workarounds → debt entry) and
   #6 (test byte-offsets must be relative).
7. **`src/jit_arm64/prologue.zig`** — single source of truth for
   ARM64 prologue shape; `body_start_offset(has_frame)` +
   `wordAt` + `assertPrologueOpcodes` API.
8. **4 demonstration migrations in `emit.zig`** — pattern
   established; ~128-site bulk migration sequenced under 7.5d
   sub-b alongside the emit.zig split.

Regrets #5 (default-value churn) and #8 (sub-row ROADMAP
normalization) did NOT receive their own rule or lesson:

- **#5** is covered by the `liveness-stage-extension-debt`
  lesson + commit-message hygiene; the load-bearing piece is
  "default values count as decisions; treat changes like
  rule changes".
- **#8** is process improvement, addressed below.

## Process improvements (regret #8 + meta)

The autonomous /continue loop's sub-row decomposition (e.g.
7.5a..7.5c-vii) lived in handover.md only, never reflected in
ROADMAP. **Proposed amendment to `.claude/skills/continue/SKILL.md`**
(deferred to a follow-up commit, not this session): when a
/continue cycle decomposes a ROADMAP `[ ]` row into sub-cycles
spanning 3+ commits, promote the sub-row decomposition to ROADMAP
per §18.2 four-step. Until then, sub-row state lives in
handover.md as documented.

## What this session did NOT do (out of scope)

- **emit.zig split into 9 modules** — sequenced as ADR-0021's
  sub-deliverable b (next /continue cycle).
- **Bulk migration of 128 remaining byte-offset sites** — same
  cycle as the split, for review-coherence.
- **Liveness frame restructure** — no current bug; lower priority.
- **ADR-0019 partial revert / Phase 7-8 reordering** — explicitly
  rejected by ADR-0021 Alternatives §A.
- **Phase 11/13 reorder before Phase 8** — deferred to ROADMAP
  §15's end-of-Phase-7 decision point with data.
- **ADR-0017 honest re-framing of X19 row** — proposed in the
  `adr-0017-merge-blind-spot` lesson but deferred to a separate
  cycle.
- **`.dev/decisions/README.md` Dependencies / DAG convention
  amendment** — proposed in the `adr-batch-dependency-order`
  lesson but deferred.

## Alternatives considered

### Alternative A — Skip ADR-0022; let ADRs 0021 + 5 lessons stand alone

- **Sketch**: The 5 lessons + ADR-0021 already capture the
  individual decisions. No single retrospective needed.
- **Why rejected**: The user explicitly requested
  "後追いのADR" as the closing artefact. Multiple
  cross-references between artefacts (lessons cite "ADR-0022"
  forwards) need a target file to point to. Without ADR-0022,
  forward references in 6 places resolve to nothing — which is
  exactly the citation-rot pattern `lessons_vs_adr.md` warns
  against.

### Alternative B — Promote some of the 5 lessons to ADR-0022 (consolidation)

- **Sketch**: Merge `adr-revision-history-misuse` +
  `adr-batch-dependency-order` into ADR-0022 since both propose
  load-bearing changes to `.dev/decisions/README.md`.
- **Why rejected**: The lessons survey the problem; the proposed
  README amendments are the load-bearing decisions, which deserve
  their own ADR(s) when authored. ADR-0022 is the retrospective;
  splitting it across multiple ADRs the same day re-creates regret
  #10's batch-without-DAG anti-pattern.

### Alternative C — Make ADR-0022 a "process ADR" with normative content

- **Sketch**: Codify rules like "every retrospective session ends
  with an ADR" + "every regret point traces to a rule or lesson".
- **Why rejected**: A normative process ADR is itself the kind of
  load-bearing claim that `audit_scaffolding` would need to verify
  forever after. The user's "好転後にADRで記録" intent reads as
  observational, not prescriptive. A future cycle may revisit and
  promote a real process ADR (e.g. "ADR-NNNN: retrospective ADR
  cadence"), but ADR-0022 stays observational.

## Consequences

### Positive

- **Single closing artefact** for the session; cross-references
  resolve.
- **Regret triage made explicit** — future sessions can reference
  this ADR to see what was triaged where (rule / lesson /
  forthcoming ADR / commit-message hygiene).
- **Deferred items are named, not forgotten** — the "Out of scope"
  list above is the explicit punch-list for follow-up cycles.

### Negative

- **Retrospective ADRs risk pulling weight they shouldn't carry**
  — if every session ends with one, ADR cadence drifts from
  "load-bearing decisions" to "session diaries". Mitigated by
  scoping this ADR to **one specific session** that genuinely
  reshaped scaffolding (10 regrets + cross-cutting refactor).
- **Two-pass review still surfaced 4 BLOCKING + 5 SIMPLIFY
  findings**, including factual drift in handover.md. Round-1
  fixes landed in commit `50b691b`. The pattern teaches: even
  with self-review at plan-time + 1 round of reviewer subagents,
  drift between prose and reality slips through.

### Neutral / follow-ups

- Round 2 of agent-coordinated self-review (per the user's "2 回
  くらいやると練度が上がります") runs after this ADR lands, on
  the diff range `8778349..HEAD`. Fixes go into a final
  follow-up commit if any blockers surface.
- Push to `origin/zwasm-from-scratch` requires explicit user
  approval per CLAUDE.md (this session is not /continue).

## References

- ADR-0019 (Phase 7 covers ARM64 + x86_64 — operationally amended by 0021)
- ADR-0021 (emit-split sub-gate — the load-bearing companion ADR)
- ROADMAP §9.7 / 7.5d (the row this session inserted)
- ROADMAP §15 (the deferred Phase 8/11/13 ordering decision)
- `.dev/lessons/2026-05-04-emit-monolith-cost.md` (regret #1)
- `.dev/lessons/2026-05-04-liveness-stage-extension-debt.md` (regret #2)
- `.dev/lessons/2026-05-04-adr-0017-merge-blind-spot.md` (regret #3)
- `.dev/lessons/2026-05-04-adr-revision-history-misuse.md` (regret #7)
- `.dev/lessons/2026-05-04-adr-batch-dependency-order.md` (regret #10)
- `.claude/rules/bug_fix_survey.md` (regret #9)
- `.claude/rules/edge_case_testing.md` (regrets #4, #6 — amendments)
- `.dev/handover.md` (current-state pointer to this ADR)
- `.dev/next-session-agenda.md` (the session plan; was the
  per-session source of truth during this work cycle)
- Session commits: `96ddfdb` (plan), `4a2da3c` (ADR-0021 +
  ROADMAP + handover), `2b35fd1` (rules + lessons), `04c2453`
  (prologue.zig + demo sites), `50b691b` (review-fixes round 1),
  this commit (ADR-0022 retrospective).

## Revision history

| Date       | Commit       | Why-class    | Summary                                     |
|------------|--------------|--------------|---------------------------------------------|
| 2026-05-04 | `<backfill>` | initial      | Retrospective ADR for the 2026-05-04 cycle. |
