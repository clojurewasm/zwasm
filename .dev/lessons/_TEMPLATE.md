# <one-line title in imperative or descriptive form>

**Date**: YYYY-MM-DD
**Keywords**: <comma-separated keywords for INDEX grep — domain + symptom + remediation>
**Citing**: <commit SHA or §9.<N> / N.M chunk id; use `<backfill>` until commit lands>

## What happened

<2-5 sentences: the surprise / observation / spike outcome. What did the
loop expect, what did it actually find?>

## Root cause

<3-8 sentences: the mechanism. Why did the surprise happen? Cite specific
files + line numbers when applicable. If the lesson is observational (no
single root cause), state that explicitly.>

## Fix (or path forward)

<Observational: "No fix — record for awareness." Derivable: 2-5 sentences
naming what changed; cite the production commit SHA in **Citing** above.>

## Why this didn't surface earlier

<Optional but recommended for surprise-class lessons. Names the conditions
that masked the issue — prevents "why didn't we catch this in CI?"
re-investigation.>

## Re-derivability

<One sentence: can a future session re-discover this by reading the code +
ADRs + git log? If yes, the lesson is a shortcut. If no, it's load-bearing
observational knowledge worth keeping.>

## Related

<Optional. ADRs this lesson seeded or amends (per
`.claude/rules/lessons_vs_adr.md` "Lesson alongside ADR amend" — both
coexist); sibling lessons (same domain, same shape); debt rows citing it.>

<!--
Template hygiene:
- Keep ≤ 50 lines total per `.claude/rules/lessons_vs_adr.md`.
- Add one row to `.dev/lessons/INDEX.md` in the SAME commit.
- If `Citing` is `<backfill>`, fix it at next phase boundary alongside
  the SHA-pointer backfill pass.
- Promotion to ADR: see `lessons_vs_adr.md` "Promotion: lesson → ADR" —
  delete the lesson + INDEX row in the same commit as the new ADR.
-->
