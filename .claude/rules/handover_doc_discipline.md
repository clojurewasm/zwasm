---
description: "Handover.md discipline — drive next chunk, don't deliberate; no numeric predictions; forbidden surrender phrases grep-enforced. Absorbs former handover_framing.md + no_handover_predictions.md per ADR-0118 D3."
paths:
  - ".dev/handover.md"
  - ".dev/debt.yaml"
  - ".dev/ROADMAP.md"
---

# Handover doc discipline

> Lean stub (ADR-0118 D2). Full detail / tables / examples: [`../references/handover_doc_discipline.md`](../references/handover_doc_discipline.md).

`.dev/handover.md` is a DRIVING doc, not a deliberation doc. Every entry names a concrete autonomous next chunk OR a specific code/test/spec dependency provably waiting on external input.

## Invariant

- §1 — No forbidden surrender phrase. `/continue` Step 1 grep (VERBATIM):
  ```sh
  grep -nE "user-judgment territory|wait for natural trigger|wait for .* fixtures|needs commitment to|substantial multi-cycle|deep .* work or wait|pivot to .* OR" .dev/handover.md
  ```
  If non-empty → the first chunk of the resume IS the handover rewrite. (Single allowed `user-judgment` use: §18 ADR amendment requiring user-flip; draft still autonomous.)
- §2 — No future-tense numeric predictions in mutable docs. Past-tense observations (chunk records, commit bodies, bench) are facts, not predictions. Numbers in debt narrative MUST be prefixed `Hypothesis (verified at <SHA-or-date>): ...`.
- §6 — Length soft 100 / hard 120 lines. Relocate stable content at 120; do NOT micro-trim 103→100.

## Enforcement

The §1 grep (run at `/continue` Step 1) + `wc -l .dev/handover.md` at handover-commit step. No mechanical gate for §6 (system-defenses-over-scripts); reviewer discipline + the wc check.

## Key cases

- Don't list multiple "options" — the loop already picks by reading handover.
- 3-option pickup anti-pattern (incl. "(c) wait") → pick autonomous tracks, drop wait.
- Legitimate bucket-3 stop (all levers pulled, work needs user) ≠ surrender framing — see reference §4.
- Live `p<N>_*_status.sh` wins over handover narrative on disagreement.

Full §1 table, fact-kind source-of-truth table, bucket-3 template, reviewer checklist: [`../references/handover_doc_discipline.md`](../references/handover_doc_discipline.md).
