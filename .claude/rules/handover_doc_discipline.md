---
description: "Handover.md discipline — a maintenance-mode STATE doc: name current state + concrete next work (or a specific external dependency), don't deliberate; no future-tense numeric predictions; length-capped. Absorbs former handover_framing.md + no_handover_predictions.md per ADR-0118 D3."
paths:
  - ".dev/handover.md"
  - ".dev/debt.yaml"
  - ".dev/ROADMAP.md"
---

# Handover doc discipline

> Lean stub (ADR-0118 D2). Full detail / tables / examples: [`../references/handover_doc_discipline.md`](../references/handover_doc_discipline.md).

`.dev/handover.md` is the canonical fresh-session entry point: a STATE doc that
names the current state + the concrete next work OR a specific dependency provably
waiting on external input (a user decision, a CI run, an upstream fix). Not a
deliberation doc.

## Invariant

- §1 — Name concrete state + next work, not vague deferrals. Don't list multiple
  "options" for a reader to pick from; state where things are and the specific
  next step (or the specific thing being waited on, and why). (Campaign-era note:
  the `/continue` Step-1 "forbidden surrender phrase" grep is RETIRED with the
  autonomous loop — there is no loop to keep from surrendering; §1 is now reviewer
  discipline, not a mechanical gate.)
- §2 — No future-tense numeric predictions in mutable docs. Past-tense observations
  (chunk records, commit bodies, bench) are facts, not predictions. Numbers in debt
  narrative MUST be prefixed `Hypothesis (verified at <SHA-or-date>): ...`.
- §6 — Length soft 100 / hard 120 lines. Relocate stable content at 120; do NOT
  micro-trim 103→100.

## Enforcement

`wc -l .dev/handover.md` at the handover-commit step (soft/hard length). §1/§2 =
reviewer discipline (system-defenses-over-scripts); no mechanical gate.

## Key cases

- Don't list multiple "options" — name the state + the next step.
- "Waiting on <specific user decision / CI run / upstream fix>" is a concrete
  dependency (name it specifically), not vague deferral.

Full fact-kind source-of-truth table + reviewer checklist: [`../references/handover_doc_discipline.md`](../references/handover_doc_discipline.md).
