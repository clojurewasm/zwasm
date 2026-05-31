---
paths:
  - "src/**/*.zig"
  - "build.zig"
---

# Textbook survey before implementation

> Lean stub (ADR-0118 D2). Full textbook table / 5 anti-pull guards / skip rules: [`../references/textbook_survey.md`](../references/textbook_survey.md) (→ `textbook_survey_skip_rules.md`).

## Invariant

- Step 0 of the TDD loop dispatches an **Explore subagent** to survey how the
  concept is built in v1 + 1–2 industry references; deliverable = 200–400 lines
  naming files / line-ranges / data shapes / **≥1 DIVERGENCE** point vs ROADMAP §2.
- The 5 anti-pull guards (cite ROADMAP before adopting a v1 idiom; always note
  one DIVERGENCE; §14-forbidden patterns stay forbidden; W54-lessons mandatory
  for regalloc/per-arch; **no copy-paste**, see [`no_copy_from_v1.md`](no_copy_from_v1.md)).
- **Skip Step 0 only when ALL hold**: refactor/rename/doc-only OR scaffolding-
  verify, AND no new public API, AND no observable-behaviour change. **A new
  `encXxx` / helper / scratch-reg reservation / multi-instr synthesis / const-
  pool entry forfeits skip.**

## Enforcement

`audit_scaffolding §G` walks recent commits to verify Step 0 ran when required.
Mid-implementation realisation of a wrong skip → dispatch the Explore subagent now.

## Key cases

- Survey summary may land in `private/notes/<phase>-<task>-survey.md` (gitignored, optional).
- The subagent should return a CONCISE digest — the report returns into main context too.

Full textbook table + worked skip examples + v1-monolith trap: [`../references/textbook_survey.md`](../references/textbook_survey.md).
