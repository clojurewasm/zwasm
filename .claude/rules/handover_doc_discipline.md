---
description: ".dev/handover.md is FROZEN (2026-08-20, discussion #207 plank 4; ADR-0212 D1) — do not update it or cite it as current state. Current state = open PRs and issues; the SessionStart brief prints them."
paths:
  - ".dev/handover.md"
---

# Handover doc — FROZEN

`.dev/handover.md` was the campaign-era session-state doc. It froze on
2026-08-20 (discussion #207 plank 4; ADR-0212 D1): the body is the final
campaign snapshot, kept as-is. Do NOT update, trim, re-flow, or "fix" it,
and do not cite it as current state.

Current state lives in **open PRs and issues** — the SessionStart brief
(`scripts/print_handover_brief.sh`) prints them — plus `git log`. The
durable invariants worth keeping moved to `docs/development.md`; the rest
of the body is historical equipment.

The maintenance disciplines this rule carried (state-doc framing, no
future-tense numeric predictions, length caps) retired with the file (the
no-predictions principle is restated in
[`../references/investigation_discipline.md`](../references/investigation_discipline.md) §Related).
