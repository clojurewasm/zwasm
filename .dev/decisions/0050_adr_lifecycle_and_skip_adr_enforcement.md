# 0050 — ADR Status lifecycle terminals + skip-ADR runner enforcement policy

- **Status**: Accepted
- **Date**: 2026-05-11
- **Author**: 2026-05-11 ADR audit response
- **Tags**: governance, adr-conventions, skip-adr, lifecycle, audit

## Context

The 2026-05-11 ADR audit (private/20250511_adr_audit/) read all
49 ADRs + 3 skip-ADRs against the codebase and surfaced two
recurring gaps:

1. **Status-lifecycle terminal missing.** `decisions/README.md`
   §"Lifecycle" enumerates `Add / Supersede / Reject after debate
   / Amend in place / Demote`, but lacks a clean exit for
   one-shot ADRs whose decision has fully landed and the ADR is
   no longer steering anything (Phase complete; no remaining
   amendment surface). The audit found 4 ADRs in this state
   (0001 / 0006 / 0007 / 0011) that the original authors
   explicitly intended to flip but had no terminal label. They
   stayed `Accepted` indefinitely, which a fresh reader misreads
   as "active steering decision".

   A second sub-case: **scope-downgraded** ADRs (e.g. 0035 whose
   exit criterion was narrowed by 0036) sit between
   `Superseded` (entire decision replaced) and `Accepted` (still
   load-bearing as designed). The current Status enum has no
   notation for "design retained, scope reduced" — the
   superseded relationship lives only in the Revision history.

2. **skip-ADR runner enforcement is not load-bearing.** Three
   skip-ADRs exist (`skip_embenchen_emcc_env_imports`,
   `skip_externref_segment`, `skip_text_format_parser`). Only
   one (`skip_text_format_parser`) is honoured by its runner:
   `spec_assert_runner.zig` classifies the corresponding
   manifest entries as `skip-adr` per ADR-0029. The other two
   skip-ADRs document fixtures that are presently **active in
   `manifest_runtime.txt`** with no `# DEFER:` mark, and
   `wast_runtime_runner.zig` has no skip-token / DEFER
   awareness. The audit ran `zig build test-wasmtime-misc-runtime`
   and observed 5 honest FAILs that the skip-ADRs claim to
   have absolved.

   This is masked operationally because `test-wasmtime-misc-
   runtime` is **not aggregated into `test-all`** — the strict
   gate that fired ADR-0012 §6.J's "100% PASS" close. The
   moment the runner enters `test-all`, Phase 6's strict-close
   claim collapses.

   `scripts/check_skip_adrs.sh` exists but only verifies that
   the fixture file path exists; it does not check the
   ADR's "Removal condition" against runner behaviour, and it
   does not enforce DEFER-mark / runner-side skip wiring.

This ADR codifies the convention so future ADRs / skip-ADRs
don't re-incur the same drift.

## Decision

### D-1 — Add a `Closed (Phase X DONE)` lifecycle terminal

`decisions/README.md` §"Required structure / Status" gains
two terminals beyond the current set:

- **`Closed (Phase X DONE)`** — the ADR's decision was a
  one-shot scope-split / deferral / charter for a specific
  Phase, and that Phase is now `DONE` per ROADMAP §9 Phase
  Status widget. The ADR stays as historical record (must
  not be deleted; external citations may exist), but a fresh
  reader is told upfront that this is no longer steering
  active code.
- **`Accepted (scope downgraded by NNNN)`** — the design is
  retained as load-bearing scaffolding but the exit
  criterion has been narrowed by a subsequent ADR. Useful
  when a coalescer / optimisation / bench-target sequence
  walks down a per-Phase scope-trim path (e.g. ADR-0035 +
  ADR-0036 + ADR-0040). The successor ADR is named in the
  Status line so a reader hits the relationship before
  reaching Revision history.
- **`Accepted (partial — see D-NNN)`** — the decision
  landed for one arch / host / surface but a structural
  barrier blocks completion on another (current example:
  ADR-0034 ARM64-only sentinel; x86_64 prologue inject
  blocked on D-055). The named debt row carries the
  remaining structural barrier.

The full Status set is therefore:

| Status                                | When                                                          |
|---------------------------------------|---------------------------------------------------------------|
| `Proposed`                            | DRAFT or under debate                                         |
| `Accepted`                            | Steering active code; current load-bearing                    |
| `Accepted (partial — see D-NNN)`      | Implementation gap on one arch/host; debt row is the barrier  |
| `Accepted (scope downgraded by NNNN)` | Design retained; exit criterion narrowed by named ADR         |
| `Superseded by NNNN`                  | Entire decision replaced; new ADR carries the full lineage    |
| `Closed (Phase X DONE)`               | One-shot decision; phase complete; ADR is historical record   |
| `Demoted to .dev/lessons/<file>`      | Was observational; promoted to lesson per lessons-vs-ADR rule |
| `Rejected`                            | Proposal was debated and rejected                             |
| `Deprecated`                          | Decision is no longer recommended; no replacement ADR exists  |

`Closed` is **terminal** — the same ADR cannot move from
`Closed` back to `Accepted`. If the underlying problem
re-opens, write a new ADR (e.g. ADR-0010 → ADR-0011 reopen
pattern, which predates this terminal but illustrates the
shape).

### D-2 — Skip-ADR runner-gate enforcement is mandatory

A skip-ADR (`skip_<fixture>.md`) is only **effective** if at
least one of the following holds:

1. **Runner-side classification.** The runner that consumes
   the fixture's manifest classifies the skip line as
   `skip-adr-<ADR-id>` per ADR-0029's vocabulary, and the
   runner's tally separates `skip-impl` from `skip-adr`. The
   `skip-adr` count is **not** counted toward the gate's
   `skip=0` requirement, but it is reported.
2. **DEFER mark + runner skip-token.** The manifest carries
   `# DEFER: skip_<slug>` (or `skip-adr-<slug>`) on the
   fixture's line; the runner recognises the token and emits
   `SKIP-ADR <slug>` instead of running the fixture.
3. **Manifest exclusion.** The fixture is removed from the
   active `manifest_runtime.txt` entirely. ADR-0012 §6.J
   already permits this; its strict-close claim relies on
   it.

If none of the three is true, the skip-ADR is **not
effective** and a debt row must be filed naming the
structural barrier (typically: "runner X has no skip-token
machinery" or "validator gap blocks the Removal condition's
machine check").

### D-3 — `scripts/check_skip_adrs.sh` evolves from path-only to enforcement

Current behaviour: walks `.dev/decisions/skip_*.md`, verifies
each fixture's file path exists. That's sufficient as a
sanity check but does not enforce D-2.

The script's gate-mode (`--gate`) gains three new exit
conditions:

1. For each `skip_*.md`, if the corresponding fixture is
   **active in any manifest** (no `# DEFER:` / `skip-adr-`
   prefix) AND the runner has no skip-token machinery for
   the manifest's filename, **fail** with the message
   `skip-ADR not effective: <ADR>; runner has no
   enforcement; file debt`.
2. Verify that `Removal condition` parses to a known shape
   (one of: "fixture passes in <runner-step>", "runner's
   <field> reaches 0", "<file>:<symbol> exists"). Unknown
   shapes warn.
3. When the Removal condition is "fixture passes in
   <runner-step>", attempt to run that step (best-effort;
   skipped if step is not yet present in `build.zig`) and
   report whether the condition is now met. Met conditions
   trigger an INFO line "skip-ADR <ADR> may be retired"
   without failing the gate.

The wiring of (3) into the autonomous loop is deferred per
the same `gate_commit.sh` opt-in pattern that D-057 / D-065
record — the script exists; pre-commit hook installation is
the user-driven step.

### D-4 — ADR template gets an optional Revision history footer

Currently `0000_template.md` does not include a Revision
history footer; recent ADRs (0041–0049) all add one
manually. The template gains a commented-out footer
`<!-- ## Revision history (add when amending) | Date | SHA |
Note | --->` so authors don't drop the convention.

This is a documentation nudge, not a load-bearing rule —
trivial single-commit ADRs are fine without a Revision
history.

### D-5 — Skip-impl one-way ratchet substrate

Amend per 2026-05-19 Phase 9 completion substrate audit (per
ADR-0071) to integrate the **skip-impl count ratchet** into
the ADR lifecycle. Background: the 2026-05-19 measurement
exposed that the prior handover claim "skip-impl == 0" was
inaccurate — 243 directives remained (193 non-simd + 50
SIMD). The drift was undetected because no commit-gate
checked skip-impl monotonicity. D-5 codifies the structural
fix.

**Substrate**:

- **`bench/results/skip_impl_history.yaml`** is the ratchet
  substrate. It is git-tracked and gets one new row per
  PR that touches skip-impl counts. Schema:

  ```yaml
  - sha: <commit-sha>
    date: <YYYY-MM-DD>
    non_simd: <count>
    simd: <count>
    total: <sum>
    runner_versions:
      spec_assert_runner_non_simd: <stamp>
      simd_assert_runner: <stamp>
    exempt: <ADR-NNNN or null>   # only when delta > 0
    notes: <one-line summary>
  ```

  Seed row at 2026-05-19 records 193 / 50 / 243 as the baseline.

- **Ratchet invariant**: for any non-`exempt` PR, the new
  row's `total` MUST be `<=` the previous row's `total`. PRs
  whose `total` rises require an explicit `exempt: <ADR-NNNN>`
  citation; otherwise the gate fails (D-6 enforces).

- **Exemption mechanism**: when a legitimate skip-impl increase
  is needed (e.g. a new spec corpus arrives with previously-
  unseen unsupported constructs), the PR carries a new ADR
  amendment or a skip-ADR file justifying the increase, and the
  yaml row sets `exempt: <ADR-NNNN>`. Without an explicit ADR
  reference, the increase is rejected.

- **Reading order**: a fresh reader can `tail bench/results/
  skip_impl_history.yaml` to see the historical trajectory and
  the `exempt:` field to understand each upward bump.

### D-6 — Pre-push gate: `scripts/check_skip_impl_ratchet.sh`

Amend to register the pre-push gate that enforces D-5.

**Behaviour**:

1. Read the last row of `bench/results/skip_impl_history.yaml`
   as the previous baseline (`prev_total`).
2. Run `zig build test-spec-wasm-2.0-assert` and the SIMD
   counterpart to measure current `cur_total` (or read the
   most-recent measurement artifact if a fresh run is too
   slow for pre-push — script chooses the cheapest valid
   signal).
3. If `cur_total > prev_total` and the current commit does
   not contain a new yaml row with `exempt: <ADR-NNNN>`, fail
   with message:
   ```
   skip-impl ratchet violation: prev=<N> cur=<M>; delta=<+K>
   No exempt ADR cited in this PR. Either fix the regression
   or add a skip-ADR + yaml exempt row.
   ```
4. If the commit's diff modifies `bench/results/skip_impl_
   history.yaml`, verify the new row's `total` matches a
   fresh measurement (catches manually-fudged rows).

**Installation**: the gate is registered in `scripts/gate_merge.sh`
(the strict A13 merge gate) and as an optional pre-push hook
in `scripts/gate_commit.sh`'s extended config. The autonomous
`/continue` loop's per-chunk Mac + ubuntunote gate does NOT
fire D-6 (pre-chunk is too aggressive); D-6 fires at push time
and at A13 merge time.

**Landing**: D-6 lands in §9.12-A (alongside the rest of the
master-plan Chapter 7 enforcement layer). Until then, the
ratchet is an honour-system invariant — the yaml exists but
the script's `--gate` exit code is a no-op.

### D-5 / D-6 interaction with skip-ADR effectiveness (D-2)

D-5 / D-6 are **additive** to D-2's skip-ADR effectiveness
discipline. A skip-ADR that classifies a fixture as `skip-adr`
(per ADR-0029) removes that fixture from `skip-impl` count;
those fixtures DO NOT contribute to the ratchet total. The
ratchet tracks only true `skip-impl` (unimplemented spec /
runner / validator capabilities), which is the user-
requirement-i exit criterion ("skip-impl 100% is the primary
exit").

## Alternatives considered

### Alternative A — Add `Closed` only; leave skip-ADR enforcement as-is

- **Sketch**: only do D-1; defer D-2 / D-3 to a future ADR
  pairing with the runner-side implementation.
- **Why rejected**: skip-ADR ineffectiveness is the audit's
  Top-1 finding (most dangerous; collapses Phase 6's
  strict-close claim if `test-wasmtime-misc-runtime` enters
  `test-all`). Splitting the rule from the policy
  postpones the structural fix. The runner-code work itself
  IS deferred (out of scope for this ADR; D-072 / D-073
  carry it), but the policy that the work must exist before
  a skip-ADR is "effective" is what this ADR codifies.

### Alternative B — Encode `Closed` as `Superseded by N/A`

- **Sketch**: reuse the existing `Superseded by NNNN`
  notation with a special marker `N/A` for one-shot ADRs
  whose decision landed without a successor.
- **Why rejected**: the audit found ADR-0001's own
  Consequences § promises `Status: Superseded by N/A`, and
  no one flipped it. The notation was confusing precisely
  because there is no successor to point to. `Closed
  (Phase X DONE)` is direct: it names the ROADMAP fact
  (Phase X widget = DONE) that made the ADR historical, and
  invites no successor lookup.

### Alternative C — Auto-flip via `audit_scaffolding`

- **Sketch**: `audit_scaffolding §F` infers a `Closed`
  state when (a) all referenced ROADMAP rows are `[x]`,
  (b) the Phase is `DONE`, and (c) no recent commit touches
  the ADR. Auto-emit a Status flip suggestion.
- **Why deferred** (not rejected): plausible, but
  inference is brittle (an ADR whose "follow-up" lives in
  another phase shouldn't auto-flip). Manual flip on
  Phase-close + audit-time review is the tighter loop. The
  auto-suggestion can be a future enhancement once D-1's
  notation is established.

### Alternative D — Skip-ADR runner enforcement via per-runner per-fixture comment

- **Sketch**: each skip-ADR's "Why v2 declines" lists the
  runner's exact `skip-token` line; runners search for
  the comment. No DEFER-mark or manifest mutation.
- **Why rejected**: couples the ADR text to runner
  internals (file path, line numbers, comment shape).
  Runner refactors silently break the linkage. The
  manifest-level DEFER mark + runner-token convention is
  the cheapest stable surface.

## Consequences

### Positive

- **Status terminals reduce reader confusion.** A fresh
  reader of ADR-0001 sees `Closed (Phase 1 DONE)` and
  knows the file is historical; previously they saw
  `Accepted` and assumed it was still steering Phase-1
  decisions.
- **Scope-downgrade has a notation.** ADR-0035 →
  `Accepted (scope downgraded by ADR-0036)` directly
  records the relationship in the Status line.
  Reviewers no longer dig into Revision history to
  recover "is this still load-bearing or vestigial?".
- **Skip-ADR effectiveness is auditable.** The three
  effectiveness paths (D-2.1 / D-2.2 / D-2.3) give
  `check_skip_adrs.sh` enough structure to flag
  ineffective skip-ADRs at gate time. Drift from
  ADR claim → runner reality surfaces immediately.
- **Audit cadence formalised.** The pattern lives
  alongside the existing ROADMAP §18 amendment
  policy + `lessons_vs_adr.md` boundary; it doesn't
  create a fourth governance surface.

### Negative

- **Existing 4 ADRs need Status flips** (0001, 0006,
  0007, 0011) and 1 needs scope-downgrade notation
  (0035) and 1 needs partial notation (0034). Mechanical
  cohort edit covered by the 2026-05-11 follow-up
  commits.
- **`check_skip_adrs.sh` D-3 work is deferred.** The
  policy is in place; the script enhancement lands when
  the autonomous loop has bandwidth. Until then,
  enforcement relies on manual audit (the 2026-05-11
  audit being one such instance). Tracked as D-072.

### Neutral / follow-ups

- Cohort flip of ADR-0001 / 0006 / 0007 / 0011 to
  `Closed (Phase X DONE)` lands in the same commit batch
  that this ADR ships in (or the immediately-following
  cohort commit — see RESOLUTION_LOG.md).
- ADR-0035 flips to `Accepted (scope downgraded by
  ADR-0036)` in the same cohort.
- ADR-0034 flips to `Accepted (partial — see D-055)` in
  the same cohort.
- D-072 (skip-ADR runner enforcement) is filed alongside
  this ADR.
- D-073 (ADR-0029 manifest prefix-syntax adoption) is
  filed alongside this ADR.
- The autonomous `/continue` loop's session-start
  handover may grow a "Recent Status flips" line if the
  cohort pattern repeats; not in this ADR's scope.

## References

- ROADMAP §18 — Amendment policy (this ADR adds Status
  vocabulary that §18.3 forbidden-list interacts with).
- `decisions/README.md` §"Required structure" / §"Lifecycle"
  / §"Skip ADRs" — directly amended by this ADR.
- ADR-0008 → 0010 → 0011 → 0012 — the supersession chain
  that motivated `Closed` as a clean terminal (per the
  audit's "exemplar" note).
- ADR-0029 — skip-impl / skip-adr vocabulary that D-2
  builds on.
- `skip_embenchen_emcc_env_imports.md` /
  `skip_externref_segment.md` /
  `skip_text_format_parser.md` — the three skip-ADRs
  that exemplify the effective / not-effective split.
- 2026-05-11 audit:
  `private/20250511_adr_audit/SUMMARY.md` §2.1, §2.5,
  §3.4, §4.3, §4.4.

## Revision history

| Date       | SHA          | Note                                                                                |
|------------|--------------|-------------------------------------------------------------------------------------|
| 2026-05-11 | `6376e707` | Initial accepted version. Codifies Closed terminal + skip-ADR enforcement triad. |
| 2026-05-19 | `<backfill>` | **Amend (add D-5 + D-6 — Phase 9 completion substrate audit per ADR-0071)**. Integrate skip-impl one-way ratchet into the ADR lifecycle: (D-5) treat `bench/results/skip_impl_history.yaml` as the ratchet substrate; any PR that changes skip-impl counts in the increasing direction must be justified by an ADR and registered with `exempt: <ADR-NNNN>`. (D-6) add `scripts/check_skip_impl_ratchet.sh` to the pre-push gate (lands in §9.12-A). Skeleton; full body (new `### D-5` / `### D-6` sub-sections) to be expanded in §9.12-pre. The existing D-3 (check_skip_adrs evolution) and D-4 (ADR template Revision history footer) keep their original meanings. |
