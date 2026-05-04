---
name: audit_scaffolding
description: Detect staleness, bloat, dead references, duplicated facts, and false-positive triggers across the project's scaffolding (CLAUDE.md, .dev/, .claude/, scripts/). Trigger when scaffolding feels off, after large refactors, after many ROADMAP edits, before release tags, or when the user explicitly asks for a scaffolding audit. Produces a report; does not modify files.
---

# audit_scaffolding

Audit the *scaffolding* (everything that supports the code, but
isn't the code itself) for the four common rot patterns:

1. **Staleness** — references to files / SHAs / phases / sections
   that no longer exist or no longer match reality.
2. **Bloat** — files past their soft limit, or duplicated facts that
   have started to drift between copies.
3. **Lies** — absolute statements ("we always X", "never Y") that
   reality has overtaken.
4. **False positives** — gate triggers / `.claude/rules/*.md` path
   matchers that fire on commits or files where they shouldn't.

The full check list, grouped by category, lives in
[`CHECKS.md`](./CHECKS.md) next to this file. Read it when running
the audit.

## When to invoke

Two firing modes:

### Mandatory (the loop fires this skill automatically)

- **Phase boundary** — when the `/continue` skill's per-task TDD
  loop detects the last `[ ]` of `§9.<N>` flipping to `[x]`, it
  fires `audit_scaffolding` inline as part of the boundary
  handler before opening `§9.<N+1>`. This guarantees `blocked-by:
  <Phase-N>` debt rows + `flake.lock` churn + ROADMAP drift
  inherent to the closing phase get walked at the moment of
  closure, not "next time someone notices".
- **Stale debt review** — when the `/continue` Step 0.5 debt
  sweep detects a `blocked-by` row whose `Last reviewed` field
  is more than 3 resume cycles stale, fires this skill in
  "narrow mode" (only §F debt-coherence checks) so the row's
  barrier is re-evaluated before silently being trusted again.

### Adaptive (user / agent judgment)

- The scaffolding feels off — handover.md disagrees with ROADMAP, an
  ADR cites a section that has moved, etc.
- A large refactor or architectural shift has just landed.
- ROADMAP has been amended (per §18) several times in a row.
- A release tag is about to be cut.
- The user explicitly says "audit scaffolding" / "check for drift" /
  similar.

The mandatory triggers are recent (added 2026-05-04 to close the
gap that Phase 6 surfaced: a `blocked-by:` debt row whose barrier
quietly disappeared was never re-evaluated until human
intervention). Local-optimisation drift (audit-fix-audit-fix at
the expense of phase progress) is still a failure mode this skill
can flag — keep an eye on whether the audit is helping or
hindering.

## Procedure

### Run inline by default; delegate only when scope is large

CHECKS.md is mostly grep / `test -e` / `git cat-file` — each check
finishes in milliseconds. **Default to inline** (batched parallel
`Bash` calls in the main agent). Subagent fork pays a context-handover
overhead (~30-60 s spin-up plus completion) that exceeds the savings
unless the audit is genuinely large.

**Delegate to a subagent only when** any of:

- ROADMAP has had >5 amendments since the last audit (A.4 walk
  becomes proportional to commit count).
- The audit is expected to surface >500 lines of finding text
  (so the parent context shouldn't absorb it).
- A specific deep-dive across `.dev/decisions/` is in scope.

For Phase 0–6 routine boundary audits, inline is the right choice.
The §9.0 / 0.6 boundary measured ~3 minutes via subagent vs.
~1 minute estimated inline.

### Steps

1. Read [`CHECKS.md`](./CHECKS.md). It groups checks by category and
   gives the exact command for each.
2. Run the checks in order. For each finding, classify severity:
   - **block** — must fix before next commit (false positive in
     gate, dead link in CLAUDE.md, broken handover).
   - **soon** — fix in the next iteration (bloat over soft limit,
     drifted duplication).
   - **watch** — note for later (approaching limit, weak signal).
3. Produce a report at `private/audit-YYYY-MM-DD.md` with three
   sections (block / soon / watch), each finding cited with
   file:line.
4. Summarise to the user in 5–10 lines:
   - Total findings (block / soon / watch counts)
   - Top 3 most important findings (one line each)
   - Whether to fix now or queue for later
5. The audit itself does not modify files; the user (or a follow-up
   commit) does the fixes. Where a fix is local and obvious, the
   `continue` skill may apply it inline before resuming the loop.

## Output format

```
# Scaffolding audit — YYYY-MM-DD

## block (N)
- <file:line> — <one-line description>
  fix: <one-line suggestion>

## soon (N)
- <file:line> — <description> (fix: ...)

## watch (N)
- <file:line> — <description>

## summary
<2-3 sentence read of overall health>
```

## Why this exists

Scaffolding rot is the failure mode that LLM-driven development is
most prone to: docs and rules accumulate, become contradictory, and
the agent stops trusting any of them. By making the audit an
explicit-when-needed step (rather than hoping to notice in passing),
drift is caught when it actually matters and fixed before it
confuses the next session.

The complementary failure mode is **over-auditing** — running the
audit so often that the project never advances. The adaptive
cadence (above) is the corrective.
