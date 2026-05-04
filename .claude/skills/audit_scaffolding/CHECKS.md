# audit_scaffolding — checks

> Run the checks in order. Classify each finding as `block` / `soon`
> / `watch` (see SKILL.md). Output `private/audit-YYYY-MM-DD.md`.

## A. Staleness checks

### A.1 Dead file references

For each markdown file under `.dev/`, `.claude/`, `CLAUDE.md`,
`README.md`:

- Extract every `(./path)` and `path/to/file` reference.
- For each, check `test -e <path>`.
- Flag missing as `block` (CLAUDE.md / handover.md / ROADMAP.md) or
  `soon` (others).

### A.2 Dead SHA references

In `.dev/handover.md` and `.dev/decisions/*.md`:

- Extract `[a-f0-9]{7,40}` patterns that look like SHAs.
- For each, run `git cat-file -t <sha>` and flag if not present.

### A.3 Phase tracker drift

`.dev/handover.md` claims a phase / task. Cross-check against
`.dev/ROADMAP.md` §9.<N>:

- Is the phase number consistent?
- Is the task `[ ]` / `[x]` state consistent?
- Does the "last commit" SHA match `git log -1`?

Discrepancy → `block`.

### A.4 ROADMAP-amendment ↔ ADR coverage

For each ROADMAP edit landing in the last 10 commits:

- Per ROADMAP §18, an ADR is required for amendments to §1, §2, §4,
  §5, §9 phase rows, §11 layers, §14 forbidden list.
- Check the commit message references an ADR.
- Flag commits that touch those sections without an ADR reference
  (`block`).

### A.5 Proposal-watch freshness

`.dev/proposal_watch.md` has a "Last reviewed" date. If it's more
than 90 days old, flag `soon`.

## B. Bloat checks

### B.1 File-size hard cap

`bash scripts/file_size_check.sh`. Hard cap (>2000 lines) is `block`.
Soft cap (>1000 lines, no ADR for split plan) is `soon`.

### B.2 Markdown bloat

For `.dev/*.md`, `.claude/**/*.md`:

- Files > 800 lines: `soon` (consider splitting into multiple files
  or moving content to ADRs).
- Files > 1500 lines: `block` (must split). ROADMAP.md is the
  intentional exception — it is large by design.

### B.3 Duplicated facts

Pairwise diff of "principles" / "rules" / "phase plan" between:

- `CLAUDE.md` vs `.dev/ROADMAP.md`
- `.claude/rules/zone_deps.md` vs `.dev/ROADMAP.md` §A1
- `.dev/handover.md` vs `.dev/ROADMAP.md` §9.<N>

Drifted duplication → `soon`.

### B.4 Skill instruction bloat

`.claude/skills/*/SKILL.md` > 500 lines: `soon`. Skills should be
short procedures, not narratives.

## C. Lies / absolute claims

### C.1 "Always X" / "Never Y" statements

```
grep -E '^\s*(- \*\*)?(Always|Never|All)' \
    .dev/ROADMAP.md .claude/rules/*.md CLAUDE.md
```

For each absolute claim, verify it holds:

- "Tests must pass on three hosts" — does the pre-push hook
  enforce it?
- "All public functions have `///`" — sample check.
- "ZirOp is u16" — does `src/ir/zir.zig` confirm?

Failed claim → `block`.

### C.2 "Phase N delivers X"

For each "Phase N delivers ..." in ROADMAP §9, check:

- Does the §9.<N> task list still produce that?
- Has the ADR table for that phase changed?

Drift → `soon`.

## D. False positives

### D.1 Rule path matchers

`.claude/rules/*.md` front-matter has `paths:`. For each rule:

- Run `find <pattern>` to confirm matched files exist.
- Flag rules whose patterns match no files (`watch`).

### D.2 Pre-commit / pre-push hooks

`.githooks/pre_commit` / `pre_push` should fail only on real issues.
If a developer reports a false positive, capture in `private/audit-*`
as `block` until fixed.

### D.3 zone_check.sh false positives

`bash scripts/zone_check.sh` (info mode) reports any zone violations.
For each, verify it's a real violation; if the rule itself is wrong
(e.g. test code crossing zones), flag as `block`.

## E. Cross-section consistency

### E.1 ROADMAP self-consistency

- §3.1 "in scope" ↔ §9 Phase outputs: every in-scope item should
  trace to a phase exit criterion.
- §6 tier system ↔ §4.2 ZirOp catalogue ↔ §9 phase plan: the three
  views of "what we implement when" should agree.

### E.2 Forbidden actions ↔ permission allowlist

ROADMAP §14 lists forbidden actions. `.claude/settings.json`
`permissions.deny` should mirror them. Mismatch → `block`.

### E.3 Test-strategy ↔ build steps

ROADMAP §11.1 lists `zig build test-*` steps. `build.zig` should
declare each one when its phase opens. Missing step at a phase
where it's promised → `block`.

## F. Debt + lessons coherence (added 2026-05-04)

### F.1 Debt-ledger Refs validity

For every row in `.dev/debt.md`, check the Refs column points to
something that still exists:

- File path → `test -e <path>`. Missing file → `block`.
- ADR § anchor → grep the ADR for the section. Missing → `soon`.
- Lesson slug → grep `.dev/lessons/INDEX.md` for the row. Missing
  → `block`.
- Skill / rule path → `test -e <path>`. Missing → `block`.

A debt row whose Refs are invalid is itself debt; either the
debt has been discharged (delete the row) or the reference is
stale (fix it).

### F.2 Debt-row Status integrity

Every row in `.dev/debt.md` MUST have `Status: now` OR
`Status: blocked-by: <specific structural barrier>`. Vague
"later" / "low priority" / "small effort" / "TODO" entries are
forbidden by the file's own discipline header.

- Row missing `Status:` field → `block`.
- Row with `Status: blocked-by` followed by an empty / vague
  string ("blocked-by: later", "blocked-by: someone") →
  `block`.
- Row whose `blocked-by` barrier has demonstrably been removed
  (e.g. cited Phase has closed; cited ADR has landed) →
  `soon` ("flip to `now` and discharge").

### F.3 Lessons INDEX coverage

Every file in `.dev/lessons/` (excluding INDEX.md and the
`archive/` subtree) MUST have a corresponding row in
`.dev/lessons/INDEX.md`:

- Lesson file without an INDEX row → `block`.
- INDEX row pointing at a missing file → `block`.
- INDEX row's keyword column empty → `soon` (keyword is the
  search anchor; without it, lesson is undiscoverable).

### F.4 Lessons promotion candidates

For each lesson, count citations across the codebase + commit
log:

- 3+ citations (in commit messages, code comments, ADR
  Alternatives sections) → `soon` ("promote to ADR per
  `lessons_vs_adr.md`").
- Same lesson title appearing in multiple lesson files →
  `block` (de-dup).

### F.5 Skip-ADR Removal-condition currency

Run `bash scripts/check_skip_adrs.sh` and parse output:

- Any "MISSING ON DISK" → `block`.
- Skip-ADR Removal condition obviously satisfied (e.g. cited
  follow-up ADR has been Accepted, cited Phase has closed) →
  `soon` ("remove skip-ADR; restore fixtures to runner").

### F.6 ADR Revision-history SHA validity

Run `bash scripts/check_adr_history.sh` and parse output:

- Any "UNKNOWN" SHA → `block`.
- `<backfill>` placeholder older than the current phase →
  `soon` ("backfill SHA at phase boundary").

## G. Extended-challenge consistency

### G.1 Workaround pairings

For each "SKIP-X-MISSING" / "SKIP-X-UNUSABLE" / similar fallback
in source / test runners, verify it's paired with **either** an
ADR documenting the choice **or** a debt row naming the
structural barrier:

- Workaround without paired investigation → `block`
  (violates `.claude/rules/extended_challenge.md`).
- Workaround whose paired debt row was discharged but the
  workaround code still exists → `soon`.

### G.2 Anchor-command currency

Re-run the diagnostic anchor commands the loop has been silently
trusting; flag drift between "what we assume" and "what is".
The audit fires these inline (one Bash call per command, parallel-
batched), captures the output verbatim into the day's audit
report, and grades:

- `ssh windowsmini "command -v zig"` — Windows host reachable +
  zig present.
- `ssh windowsmini "command -v wasmtime"` — windowsmini wasmtime
  resolution (the D-008 case). Expected today: resolves to a
  stub.
- `ssh windowsmini "wasmtime --version"` — does the resolved
  binary actually run? Expected today: no. **If this starts
  succeeding**, the SKIP-WASMTIME-UNUSABLE fallback is now a
  pure workaround (no longer paired with a real barrier) and
  the audit MUST flag `soon` — D-008 just discharged.
- `orb run -m my-ubuntu-amd64 bash -c 'command -v zig'` — Linux
  reachable + zig present.
- `orb run -m my-ubuntu-amd64 bash -c 'zig version'` — version
  parity vs Mac (mismatch = the OrbStack VM drifted).

Each command's outcome:

- Expected (per current debt rows) → record verbatim, no
  finding.
- Different from expected → `soon` finding ("D-NNN's barrier
  may have changed; flip Status to `now` and re-evaluate").
- Command itself fails to even run (host unreachable) → `block`
  finding ("the audit's anchor is broken; fix host setup
  per `.dev/{orbstack,windows_ssh}_setup.md`").

This is the "mandatory walking" of `extended_challenge.md`
Step 1 that was missing in Phase 6 — the audit now fires it
on every audit run rather than waiting for the human to
notice.

## H. Output

Write to `private/audit-YYYY-MM-DD.md`:

```
# Scaffolding audit — YYYY-MM-DD

## block (N)
- <file:line> — <one-line description>
  fix: <suggestion>

## soon (N)
- ...

## watch (N)
- ...

## summary
<2-3 sentences>
```

Then summarise to the user with severity counts and top-3 findings.
Do not modify any tracked files; the user decides the fix timing.
