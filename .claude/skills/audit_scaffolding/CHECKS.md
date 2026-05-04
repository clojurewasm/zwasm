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

- `ssh windowsmini 'bash -c "command -v zig"'` — Windows host
  reachable + zig present (note: must wrap in `bash -c` because
  the default SSH shell on windowsmini is PowerShell, where
  `command -v` resolves through different rules and zig isn't
  visible by default; the project's bash-side install IS visible).
- `ssh windowsmini 'bash -c "command -v wasmtime"'` —
  windowsmini wasmtime resolution. Expected (post-D-008
  discharge): resolves to `/c/Users/.../wasmtime`.
- `ssh windowsmini "wasmtime --version"` — does the binary run
  via the SSH default shell? Expected (post-D-008 discharge):
  yes (`wasmtime 42.0.1 (...)`). **If this starts failing**, a
  windowsmini-side regression occurred — flag `block`.
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

## I. Edge-case fixture coverage (added 2026-05-04 per ADR-0020)

Verifies the `test/edge_cases/p<N>/` fixture corpus stays in
sync with semantic-boundary code touched in recent commits.
The discipline lives in
[`.claude/rules/edge_case_testing.md`](../../rules/edge_case_testing.md):
boundary-touching commits land their fixture in the same diff.

### I.1 Fixture triple integrity

For each `test/edge_cases/**/<case>.wat`:

```bash
test -f "${case%.wat}.wasm"   || warn "missing .wasm artifact"
test -f "${case%.wat}.expect" || warn "missing .expect file"
```

Findings:

- Missing `.wasm` for an existing `.wat` → `warn` ("re-compile
  via `wat2wasm`; check fixture-build target wires it").
- Missing `.expect` → `warn` ("each fixture's expected output
  must be declared; trap-only fixtures still need `trap:
  <reason>`").

### I.2 Fixture artifact freshness

For each `<case>.wasm` paired with `<case>.wat`, verify the
artifact's mtime ≥ the source's mtime. Stale artifact → `warn`
finding ("re-compile + commit the updated `.wasm`").

### I.3 Boundary-touch / fixture-add correspondence

Walks recent commits (last 20 by default, or since last phase
boundary) and cross-references "boundary-touching" file
changes with fixture additions:

- **Boundary-touching** = commits that modify Zig source under
  `src/jit_arm64/emit.zig`, `src/interp/`, `src/feature/` (op
  handler surfaces) OR `.dev/decisions/` (ADRs that change
  semantics).
- **Fixture additions** = new files under `test/edge_cases/**`.

For each boundary-touching commit lacking a paired fixture
addition: `soon` finding ("touches semantic boundary without
fixture addition; verify rationale per
`.claude/rules/edge_case_testing.md`'s 'When NOT to add a
fixture' section").

Intentionally noisy at first; calibration happens via the
rule's exclusion list and per-commit rationale.

### I.4 Convention checks

All fixture paths must match
`test/edge_cases/p<N>/<concept>/<case>.{wat,wasm,expect}`.
Any deviation → `warn` finding.

### I.5 Stale-ness

If the rule file (`.claude/rules/edge_case_testing.md`) is
missing or its `paths:` frontmatter no longer covers `src/**`
+ `test/**`, §I's premise is broken — `block` finding ("rule
file missing; restore from ADR-0020 or supersede").

## J. Meta-audit triggers (added 2026-05-04)

Detect drift signals that suggest the user should fire the
`meta_audit` skill. These checks **do not** fail the audit; they
emit `suggest meta_audit` findings. The `meta_audit` skill is
user-gated (per its SKILL.md "User-gated, not autonomous" §); this
section's job is to surface the candidates for that decision.

### J.1 §A2 soft-cap approach

Any `src/**/*.zig` whose line count is ≥ 800 (= 80% of the
ROADMAP §A2 soft cap of 1000). Surface as `suggest meta_audit`
finding listing each match (`watch` severity). The 2026-05-04
retrospective worked example: emit.zig at 3989 LOC was a §A2
hard-cap violation that should have triggered meta_audit at
the 800-LOC mark (sub-7.3), not be discovered at the
retrospective.

### J.2 §A2 hard-cap violation

Any `src/**/*.zig` whose line count is ≥ 2000 (the §A2 hard cap).
This is a **§14 forbidden-list cross**, not a near-miss; emit
`block` severity finding with explicit
`fire meta_audit BEFORE next /continue resume`. Existing
violations (e.g. emit.zig pre-discharge of ADR-0021 row 7.5d-b)
are tracked but not re-fired each cycle while their discharging
ADR is active.

### J.3 Debt accumulation

`.dev/debt.md` Active rows count > 15. The threshold is
intentionally low — debt rows are supposed to discharge or
escalate, not accumulate. Emit `suggest meta_audit` listing the
oldest 5 rows by First-raised date (`soon` severity).

### J.4 Stale debt review

Any debt row whose `Last reviewed` date is older than 5 resume
cycles (where 1 cycle ≈ 1 day; tracked via the `audit_scaffolding`
runs themselves). Dovetails with §F.2; promotes to `suggest
meta_audit` (`watch` severity) when ≥ 3 rows are stale (§F.2
alone surfaces the single-row case).

### J.5 §14 forbidden-list near-miss

**"New" definition**: appears in a commit later than the
previous `audit_scaffolding` invocation's `private/audit-*.md`
report — or, on first run, any current occurrence. Snapshot the
match list per run so a delta is computable next time.

Detection patterns (heuristic; false-positives acceptable):

- Any new `pub var` in `src/` (§14: "pub var as a vtable").
- Any new `if (build_options\.` (or compile-time equivalent)
  outside the **build-options registration sites** — exclude
  `src/main.zig`, `src/c_api/*.zig`, `src/cli/*.zig`, and any
  module wired into `addOptions` per `build.zig`. The §14 ban is
  on **pervasive** build-time flags in main code paths; entry
  modules legitimately read `build_options.wasm_level` etc.
  False-positive on entry modules is what motivated this
  exception.
- Any new `std.Thread.Mutex` / `std.io.AnyWriter` /
  `std.io.fixedBufferStream` (§14 + §P4 + zig_tips.md
  removed-API list).
- Any new file path containing `-` (§14: hyphens in file names).

Emit `suggest meta_audit` finding per match (`watch` severity).

### J.6 ADR cross-reference integrity

ADR count grew by ≥ 5 since the last `meta_audit` retrospective
report under `.dev/meta_audits/`. Without periodic cross-reference
verification (Revision history SHAs, Dependencies sections — see
the 2026-05-04 batch-dependency-order lesson), a 5-ADR batch
risks the implicit-DAG anti-pattern. Emit `suggest meta_audit`
when threshold reached (`watch` severity).

### J.7 Phase boundary

When the Phase Status widget flips to `DONE` (§A.3 watches this).
Emit `suggest meta_audit` as a routine cadence finding (`watch`
severity — lightest of the three CHECKS categories). The user
usually accepts this trigger; it is the default cadence for
`meta_audit` per its SKILL.md.

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
