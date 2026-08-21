---
description: "Every .dev/*.md file (except always-active ROADMAP/debt/proposal_watch/lessons-INDEX) declares a Doc-state header (ACTIVE / ARCHIVED-IN-PLACE / ARCHIVED / SUPERSEDED-BY)."
paths:
  - ".dev/*.md"
  - ".dev/archive/**/*.md"
---

# Doc-state marker (stub per ADR-0118 D2)

`.dev/*.md` files (except always-active rulebook docs — ROADMAP /
debt / proposal_watch / lessons/INDEX) MUST declare in the
top-of-file blockquote:

```markdown
> **Doc-state**: ACTIVE | ARCHIVED-IN-PLACE | ARCHIVED | SUPERSEDED-BY
```

Optional `> **Superseded-by**: <path>` for transitions.

**Mechanization**: `bash scripts/check_doc_state.sh` (audit_scaffolding §G
grep variant; surfaces missing markers as block findings).

**Why**: 2026-05-22 audit (Agent 3) found 4 close-plan docs accumulating
without lifecycle markers → claim drift between docs. Reviewers can't
tell which is authoritative. ADRs (`.dev/decisions/`) have their own
`Status:` lifecycle that subsumes this marker.
