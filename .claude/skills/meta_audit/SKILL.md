---
name: meta_audit
description: Periodic deliberate-skepticism audit against ROADMAP §1/§2/§9/§14/§15 and recent ADRs. Triggers on Phase boundary OR opportunistic drift signals from audit_scaffolding §J. Produces a report under .dev/meta_audits/, may seed ADRs / lessons / rule amendments. User-gated; this skill is NOT autonomous-fired by /continue.
---

# meta_audit

Where `audit_scaffolding` checks scaffolding **integrity** (dead
refs, bloat, lies, false positives), `meta_audit` checks
scaffolding **correctness** — is the plan still right? Are the
ADRs honest? Have we crossed a §14 forbidden line silently?

This skill exists because `/continue`'s per-task TDD loop is
**task-level**: it advances the next `[ ]` row, not the meta
question "is this row even the right thing?". Phase 7's emit.zig
reaching 3989 LOC (ROADMAP §A2 hard-cap = 2000) is the worked
example — autonomous loop never paused to ask "should this file
have been split 1500 LOC ago?". `meta_audit` is the deliberate
pause that asks.

## When to fire

### Default trigger — Phase boundary

Phase boundaries are the natural cadence. The `/continue` skill's
Phase boundary handler (after Phase Status flips DONE) **suggests**
firing `meta_audit`; the user gates the actual run.

### Opportunistic triggers — `audit_scaffolding §J`

`audit_scaffolding` (which DOES run autonomously per
`/continue`) detects drift signals and emits suggestions to fire
`meta_audit`. See `.claude/skills/audit_scaffolding/CHECKS.md §J`
for the exact predicates. Examples:

- A `src/` file passes 80% of §A2 soft cap (≥ 800 LOC).
- `.dev/debt.md` Active rows exceed 15.
- A debt row's `Last reviewed` is > 5 resume cycles old.
- A §14 forbidden-list near-miss (e.g. new `pub var`) detected.
- ADR count grew by > 5 since the last meta_audit without a
  cross-reference integrity check.

`audit_scaffolding` lists detected signals in its report; the
user sees them at the next `/continue` resume and decides whether
to fire `meta_audit`.

### Hard trigger — §14 violation in flight

If `audit_scaffolding` detects a **fresh §14 violation** (not a
near-miss — an actual cross of the forbidden-list line), the
`/continue` loop **stops** per its own stop conditions and
surfaces to the user with a `meta_audit` recommendation.

## User-gated, not autonomous

This skill **must not** be autonomous-fired by `/continue`.
Reasons:

- Meta audits trigger ROADMAP §18 amendments (Phase scope, exit
  criteria, §14 rewrites). §18 is explicitly user-collaborative
  ("if unsure, ask the user before proceeding").
- The skill's outcome may include "this whole Phase was wrong-
  shape" — the user is the judge of whether to accept that
  finding.
- Autonomous fire would conflict with `/continue`'s "advance the
  next row" intent; the loop would oscillate.

## Procedure

### Step 0 — Read the read-list

Re-read in order:

1. ROADMAP §1 (mission, v0.1.0 line)
2. ROADMAP §2 (P/A — inviolable principles)
3. ROADMAP §9 — current Phase scope + exit criteria
4. ROADMAP §14 (forbidden actions)
5. ROADMAP §15 (future go/no-go decision points)
6. The 5 most recent ADRs in `.dev/decisions/` (by NNNN)
7. `.dev/handover.md`
8. `.dev/debt.md` (full Active section)
9. `.dev/lessons/INDEX.md`

### Step 1 — Apply the 4 honest-lens questions

Answer each in 1-2 sentences. Brevity is the discipline; a
"nothing to report" answer is itself a finding.

1. **Phase scope drift**: does the current Phase's exit criterion
   (as written in ROADMAP §9) still match what the implementation
   has been doing? Surfacing point: when sub-rows accumulate in
   `handover.md` that don't map to ROADMAP rows.
2. **Recent-ADR honesty**: do the last 5 ADRs' Alternatives
   sections genuinely reject paths, or did some Alternatives
   appear later via Revision history (suggesting the original
   design was incomplete)? Surfacing point: any Revision history
   row whose summary reads as "refinement" but is actually a
   gap-fix.
3. **§14 near-misses**: any forbidden-list entry that the
   project is approaching but not yet crossing? `audit_scaffolding
   §J` lists the auto-detected candidates; meta_audit reads them.
4. **§15 decision-point readiness**: has any future go/no-go
   decision point's data become available (e.g. realworld JIT
   numbers ready for Phase 7's end-of-Phase decision)?

### Step 2 — Plan artefact production

For each finding:

- **Observational** → lesson under `.dev/lessons/<YYYY-MM-DD>-<slug>.md`
- **Rule-able** → amend an existing rule in `.claude/rules/`
- **Load-bearing** (Phase scope, ADR amend, §14 line move) → ADR
  per `.dev/decisions/README.md`
- **Process-only** → amend the relevant skill SKILL.md

Do **not** produce ADRs for the meta_audit *itself*; the
retrospective report is sufficient.

### Step 3 — Self-review the plan (2 passes)

Internal Pass 1 (completeness + ordering) + Pass 2 (risk + commit
granularity). Same shape as the 2026-05-04 design session's
self-review pattern.

### Step 4 — Execute

Commit per the artefact-production plan. Granularity: one commit
per artefact-class (e.g. one commit for "ADR + ROADMAP edit + handover sync"
per ROADMAP §18.2; one commit for "all lesson amendments";
one commit for rule changes).

### Step 5 — Self-review the diff (2 passes via subagents)

Round 1: code-reviewer + code-simplifier in parallel on the diff
range from before-meta-audit HEAD → after-meta-audit HEAD.

Round 2: code-reviewer single pass on the round-1 fix-up commit.

### Step 6 — Retrospective report

Write `.dev/meta_audits/<YYYY-MM-DD>-<slug>.md` (≤ 80 lines):

```markdown
# Meta-audit YYYY-MM-DD — <one-line summary>

## Trigger
Phase boundary | audit_scaffolding §J.<N> | user-explicit.

## Findings
1. <finding>
2. <finding>
...

## Artefacts produced
- ADR-NNNN (`<slug>`)
- Rule: `<file>.md` (amend)
- Lesson: `<file>.md`
- Process: `<skill>/SKILL.md` (amend)

## Out of scope (deferred)
- <item> — <next trigger>

## Trigger conditions to refine
- <signal> too loose / too tight; propose <new-threshold>
```

The report is **not** an ADR — it is observational. ADR cadence
stays "load-bearing decisions only" (per `.dev/decisions/README.md`
"When NOT to write an ADR").

## What this skill does NOT do

- Edit code (that's `/continue` per-task TDD loop's job).
- Modify ROADMAP without an accompanying ADR (per §18).
- Run tests as a gate (Step 5 reviews use subagents on the diff;
  the existing 3-host gate runs as part of the artefact commits).
- Fire on every /continue resume — that's `audit_scaffolding`.

## Anti-patterns

- **"Meta-audit becomes a journaling cadence"**: if every Phase
  boundary's report says "no findings", the skill is overhead.
  Mitigation: the trigger conditions (§J) should fire only when
  there's likely something to find. Tune §J thresholds upward if
  meta_audit consistently finds nothing.
- **"Meta-audit produces ADRs for everything"**: load-bearing vs
  observational discipline matters. Per `lessons_vs_adr.md`, most
  findings are lessons, not ADRs.
- **"Meta-audit autonomous-fires during /continue"**: forbidden.
  See "User-gated, not autonomous" above.

## Citations

- ADR-0022 (post-session retrospective; the 2026-05-04 dialogue
  that motivated this skill)
- `.claude/skills/audit_scaffolding/CHECKS.md §J` (auto-trigger
  predicates)
- ROADMAP §18 (amendment policy this skill operates under)
- ROADMAP §15 (future go/no-go decision points this skill
  re-evaluates)
