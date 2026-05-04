# Meta-audit reports

This directory holds retrospective reports from `meta_audit` skill
runs (`.claude/skills/meta_audit/SKILL.md`). One file per run:

```
<YYYY-MM-DD>-<slug>.md
```

`<slug>` reflects the audit's focus (e.g. `phase7-boundary`,
`debt-15plus`, `a2-near-miss`).

## Why these are not ADRs

Meta-audit runs **observe** drift; the artefacts they seed (ADRs,
lessons, rule amendments) are the load-bearing records. The
retrospective report is observational. Per
`.claude/rules/lessons_vs_adr.md`, ADR cadence stays "load-bearing
decisions only".

## Why these are not lessons

Lessons are re-derivable observations indexed by keyword in
`.dev/lessons/INDEX.md`. Meta-audit reports are structural records
of an audit run (trigger / findings / artefacts produced /
deferred items / threshold-tuning suggestions) — they exist to
make the audit cadence itself browsable, not to teach future
sessions a re-derivable lesson. (If a meta-audit finding is itself
a lesson, that lesson lands under `.dev/lessons/` separately, and
the retrospective report cites it.)

## Cadence

Each report is bounded:

- Length: ≤ 80 lines (per `meta_audit/SKILL.md` Step 6).
- Trigger source: Phase boundary | `audit_scaffolding §J.<N>` |
  user-explicit.
- Lifecycle: append-only. Do not edit historical reports — they
  capture a point-in-time state. Errata land in a new report.

## Threshold tuning

Each report's "Trigger conditions to refine" section feeds back
into `audit_scaffolding/CHECKS.md §J`. The cadence is:

1. Meta-audit run finds the trigger fired but the audit found
   nothing → propose loosening the threshold.
2. Meta-audit run finds significant drift the trigger missed →
   propose tightening the threshold.
3. Refinements land in a new commit amending §J's predicates.

## See also

- `.claude/skills/meta_audit/SKILL.md` — the skill itself
- `.claude/skills/audit_scaffolding/CHECKS.md §J` — auto-trigger
  predicates that suggest firing meta_audit
- ADR-0022 (post-session retrospective; the dialogue that
  motivated this skill)
