# Lessons vs ADRs — when to use which

Auto-loaded when editing `.dev/decisions/`, `.dev/lessons/`, ADRs,
or related docs. Codifies the boundary between **load-bearing**
design records (ADR) and **observational** notes (lesson).

## TL;DR

| Question                                                                 | If YES → ADR | If NO → lesson |
|--------------------------------------------------------------------------|:-:|:-:|
| Does another file's behaviour change because of this decision?           | ✓ | |
| Is the decision a **deviation** from ROADMAP §1, §2 (P/A), §4 (architecture / Zone / ZirOp), §5 (file layout), §9 phase rows (scope / exit), §11 layers, or §14 forbidden list? | ✓ | |
| Does removing this decision require a corresponding code / test change?  | ✓ | |
| Does the decision pick one path and explicitly reject named alternatives? | ✓ | |
| Is this a description of "we tried something and learned X"?              | | ✓ |
| Is this a re-derivable design intuition that future sessions might forget? | | ✓ |
| Is this a record of a spike outcome where no path was adopted yet?         | | ✓ |
| Could the same observation be **re-derived** by reading the codebase + ADRs? | | ✓ |

## Decision tree

```
Is the artifact load-bearing for downstream code/test/build?
├─ YES → ADR (.dev/decisions/NNNN_<slug>.md)
│        Sections: Context / Decision / Alternatives / Consequences /
│        References. SHA-tracked Revision history footer.
│
└─ NO  → Is it a learning that a future session might forget,
         or that someone re-attempting the same spike would re-pay?
         ├─ YES → Lesson (.dev/lessons/<YYYY-MM-DD>-<slug>.md)
         │        ≤ 50 lines. Index row in .dev/lessons/INDEX.md.
         │        No Decision / Alternatives sections needed.
         │
         └─ NO  → Don't write either. Trust git log + the codebase.
```

## What ADRs are for

ADRs codify decisions that:

- Change the rules of the project (rules-of-the-game level).
- Have alternatives that were rejected with reasons we need to
  remember.
- Carry a **removal condition** (when does this decision expire?).
- Are referenced from ROADMAP / handover / other ADRs / commits.

Examples in this codebase:

- `0014_redesign_and_refactoring_before_phase7.md` — defines the
  6.K block scope.
- `0015_canonical_debug_toolkit.md` — picks `-Dsanitize=address` +
  `run-repro` step.
- `0016_error_diagnostic_system.md` — Diagnostic threadlocal +
  M1/M2/M3/M4/M5 phasing.
- `skip_*.md` — per-fixture skip-ADRs at §9.6 / 6.J's exception
  clause.

## What lessons are for

Lessons codify learnings that:

- Future sessions / future developers might re-pay if not warned.
- Don't justify a load-bearing document.
- Don't change project rules.
- Are observational rather than prescriptive.

Examples (seeded today):

- `2026-05-04-beta-funcref-encoding-rejected.md` — "Beauty-driven
  design loses to 10 years of production experience".
- `2026-05-04-autoregister-spike-regression.md` — "Mirroring
  wasmtime harness behaviour requires the underlying validator
  to already match wasmtime strictness".

## Lesson alongside ADR amend (both stay)

A common case: a lesson exists, and the same evidence triggers an
**amendment** to an existing ADR (not creation of a new ADR).
Both artefacts coexist:

- The lesson stays where it is — it preserves the observational,
  re-derivable framing.
- The ADR amendment expands the load-bearing section (typically
  `Alternatives` or `Consequences`) and adds a `Revision history`
  row per `.dev/decisions/README.md`.
- The ADR amendment SHOULD cite the lesson by path in its
  `References` section so the lineage is traceable.
- The lesson's `Citing:` header SHOULD list the amend commit's
  SHA (or `<backfill>` until the commit lands; backfill at the
  next phase boundary is acceptable).

This case is **not** a promotion — promotion is for creating a
**new** ADR seeded by a lesson. Distinguishing the two prevents
the "I converted my lesson to an ADR but the lesson is still
there" duplicate-content failure mode.

## Promotion: lesson → ADR

A lesson **promotes** to an ADR (creating a new ADR, deleting the
lesson) when ANY of the below fire:

1. The same lesson is cited from 3+ places (commits, code comments,
   ADR Alternatives sections).
2. A subsequent ROADMAP / Phase / scope decision rests on the
   lesson.
3. Following the lesson requires changing public behaviour (e.g.,
   the lesson implies a code-level rule that needs enforcement).

Promotion procedure:

1. Open `.dev/decisions/NNNN_<slug>.md`. Use the lesson's content
   as the new ADR's `Context`.
2. Add `Decision` / `Alternatives` / `Consequences` / `References`
   sections. The `References` MUST cite the originating lesson by
   path so the promotion lineage is traceable.
3. **Delete** the original lesson file. Update `.dev/lessons/INDEX.md`
   to remove the row. The ADR supersedes the lesson; do not keep
   both (avoids stale-ness).
4. The deletion + ADR creation MUST be in the same commit so the
   git history shows the promotion atomically.

## Demotion: ADR → lesson

Rare but allowed. If an ADR turns out to be observational rather
than load-bearing (e.g., the "decision" never gated downstream
behaviour), demote to a lesson AND mark the ADR `Status: Demoted
to .dev/lessons/<file>` so external citations don't break. Don't
delete an ADR that has external citations.

## What NOT to write either as

These belong in **commit messages** + **ADR / lesson refs**, not
as their own artifacts:

- "I fixed bug X by Y." → commit message body.
- "We renamed `foo` to `bar`." → commit message subject.
- "TODO: address Z later." → `.dev/debt.md` entry.
- "I spent 2h on Z and concluded W." → if W is re-derivable, commit
  message; if W teaches something future-you would forget, lesson.

## How to cite

- From ADR → lesson: `References: see [`<slug>`](../lessons/<file>)`.
- From commit → lesson: `Cf. .dev/lessons/<YYYY-MM-DD>-<slug>.md`.
- From debt → lesson: in the Refs column of `.dev/debt.md`.
- From lesson → ADR: in the lesson's `Citing:` header.

## Stale-ness — how this rule prevents drift

- The lessons/INDEX.md table is the **single point of truth** for
  what lessons exist. If a lesson file lacks an INDEX row, fix the
  INDEX (the file is the artifact; the index is the directory).
- `audit_scaffolding` skill verifies each INDEX row's file path
  and citing references still resolve.
- Promotion to ADR is the cleanup path; demotion is the rescue
  path. There is no "leave it ambiguous" path.

## Why this rule exists (motivation)

Phase 6 surfaced a recurring failure mode: surprising-but-
re-derivable observations either ended up as ADR amendments
(over-formalised, polluting the ADR Alternatives section) or as
gitignored `private/notes/` (lost across sessions). Lessons fill
the gap — git-tracked but cheap to write.

The discipline is: **write the lesson the same hour the surprise
hits**, not a week later "when there's time". The lessons/INDEX
row is what makes the discipline cheap (one keyword grep before
each task).
