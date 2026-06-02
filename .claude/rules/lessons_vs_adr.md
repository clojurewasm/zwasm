---
paths:
  - ".dev/decisions/**"
  - ".dev/lessons/**"
  - ".dev/handover.md"
  - ".dev/debt.yaml"
---

# Lessons vs ADRs — when to use which

> Lean stub (ADR-0118 D2). Full detail / tables / examples: [`../references/lessons_vs_adr.md`](../references/lessons_vs_adr.md).

## Invariant

Load-bearing decision → **ADR** (`.dev/decisions/NNNN_<slug>.md`). Observational / re-derivable → **lesson** (`.dev/lessons/<YYYY-MM-DD>-<slug>.md`, ≤50 lines, INDEX row). Never both: promotion deletes the lesson same-commit; demotion marks the ADR `Status: Demoted to <file>`.

Decision table (YES → ADR / NO → lesson):

| Question | YES→ADR | NO→lesson |
|---|:-:|:-:|
| Does another file's behaviour change because of this? | ✓ | |
| Deviates from ROADMAP §1 / §2 (P/A) / §4 (arch/Zone/ZirOp) / §5 (layout) / §9 (scope/exit) / §11 / §14? | ✓ | |
| Does removing it require a code/test change? | ✓ | |
| Picks one path + explicitly rejects named alternatives? | ✓ | |
| "We tried something and learned X" / re-derivable intuition / spike with no path adopted? | | ✓ |

## Enforcement

`lessons/INDEX.md` row is the single point of truth for what lessons exist (file lacks row → fix INDEX). `audit_scaffolding` skill cite-verifies each INDEX row's path + citing refs resolve.

## Key cases

- Lesson + ADR-amend coexist (NOT a promotion): lesson keeps observational framing; ADR amend expands load-bearing section + cites lesson.
- Promotion fires when: cited 3+ places / a ROADMAP-Phase-scope decision rests on it / it requires changing public behaviour.
- Don't write either for: "fixed X by Y" (commit body), rename (subject), "TODO later" (debt).
- No "leave it ambiguous" path — promotion is cleanup, demotion is rescue.

Decision tree, promotion/demotion procedures, citation forms: [`../references/lessons_vs_adr.md`](../references/lessons_vs_adr.md).
