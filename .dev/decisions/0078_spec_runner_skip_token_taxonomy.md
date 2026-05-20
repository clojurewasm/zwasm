# 0078 — Spec runner SKIP-* token taxonomy

- **Status**: Proposed
- **Date**: 2026-05-21
- **Author**: autonomous /continue loop (close-plan §6 (f))
- **Tags**: testing, spec-runner, taxonomy, skip-discipline

## Context

The `spec_assert_runner_base.zig` runner emits `SKIP-<TAG>` stderr
lines at runtime whenever it encounters a structural barrier that
would otherwise produce a FAIL. Over 19 distinct token shapes have
accumulated across Phases 6–9 with no canonical classification —
some pair with an Accepted ADR (e.g. `skip_cross_module_*.md`),
some with a debt-ledger entry (D-008 / D-152 / D-153), and some
are pure runner bookkeeping. The discipline-gap surfaces in three
ways:

1. **Ratchet ambiguity** — `bench/results/skip_impl_history.yaml`'s
   ratchet (per ADR-0050 D-5) previously conflated manifest
   `skip-impl` lines with runtime `SKIP-*` events; close-plan
   §6 (e) (commit `13562a5`) split the counter, but the per-token
   class is still implicit. Some tokens are "release-gate
   concerns" (must be discharged before v0.1.0 RC); others are
   "runner bookkeeping" (legitimate runtime guard, not a gate).
2. **ADR-vs-debt confusion** — close-plan C3 (`SKIP-NON-INVOKE-
   ACTION` B137 land) flagged that the criterion for "this token
   needs an ADR" vs "this token is debt-trackable" vs "this token
   is runner-internal" had never been written down. New tokens
   land as ad-hoc additions to the runner.
3. **Discoverability** — when a fixture trips `SKIP-X` and a future
   investigator asks "is this expected?", the answer is buried in
   commit history. A taxonomy lets `grep` answer it.

Close-plan §6 (f) ordered an ADR-Proposed-only step at this point
of the sequence; the corresponding ratchet-script extension
(`check_skip_impl_ratchet` token-class awareness) is a paired
follow-up debt entry, not in scope for this ADR's acceptance.

## Decision

Adopt three **token classes**. Every `SKIP-<TAG>` the runner emits
MUST belong to exactly one:

| Class              | Meaning                                                                                                          | Release-gate concern? | Paired artifact                                              |
|--------------------|------------------------------------------------------------------------------------------------------------------|-----------------------|--------------------------------------------------------------|
| `debt-trackable`   | A real implementation gap that the project owes; growth indicates regression / new discovery.                    | Yes                   | `.dev/debt.md::D-NNN` row, `Status: now` or `blocked-by:`    |
| `ADR-required`     | A waived gap whose discharge condition is documented in an Accepted ADR (typically `.dev/decisions/skip_*.md`).  | Yes (until ADR's `Removal condition` fires) | `.dev/decisions/<slug>.md` Accepted ADR |
| `runner-internal`  | Legitimate runtime guard for an out-of-scope action (start function trap, missing-callback specialisation, etc.). | No                    | Runner source code comment + this ADR's classification entry |

Each token has its class fixed at the time the runner emits it;
re-classification requires an ADR amendment per ROADMAP §18.

### Initial classification (canonical table)

This table is the source of truth for existing tokens. Add a row
when a new token is introduced; never remove a row (delete the
runner emission first, then mark the row "retired" in a follow-up
ADR amendment).

| Token                          | Class             | Paired artifact                                                |
|--------------------------------|-------------------|----------------------------------------------------------------|
| `SKIP-CROSS-MODULE-IMPORTS`    | `debt-trackable`  | D-153 (paused; spike-first redesign per close-plan §6 (j))     |
| `SKIP-CROSS-MODULE-CALLEE-STATE` | `ADR-required`  | `.dev/decisions/skip_cross_module_register.md`                 |
| `SKIP-EMPTY`                   | `runner-internal` | empty fixture guard                                            |
| `SKIP-EXPORTS`                 | `debt-trackable`  | `exports/manifest.txt` gap (1 fixture; close-plan §7 follow-up) |
| `SKIP-HOST-IMPORT`             | `ADR-required`    | `.dev/decisions/skip_embenchen_emcc_env_imports.md`            |
| `SKIP-NO-INSTANTIATE-CB`       | `runner-internal` | specialisation lacks `handle_assert_uninstantiable` callback   |
| `SKIP-NO-LINK-TYPECHECK`       | `debt-trackable`  | linking typecheck gap (26 fixtures; D-NNN follow-up)           |
| `SKIP-NOENTRY`                 | `runner-internal` | fixture has no entry function (out-of-scope by design)         |
| `SKIP-NON-INVOKE-ACTION`       | `debt-trackable`  | D-152 (compileWasm empty-fn-path globals_offsets fix)          |
| `SKIP-PARSER-GAP`              | `debt-trackable`  | parser-recognition gap; per-fixture D-NNN as discovered        |
| `SKIP-START-TRAP`              | `runner-internal` | start function legitimately traps; runner doesn't re-raise     |
| `SKIP-V2-InstanceAllocFailed`  | `debt-trackable`  | v0.2 instance alloc gap; D-NNN per-fixture                     |
| `SKIP-V2-READ`                 | `debt-trackable`  | v0.2 reader gap; per-corpus D-NNN                              |
| `SKIP-VALIDATOR-GAP`           | `debt-trackable`  | validator strictness gap; per-fixture D-NNN as discovered      |
| `SKIP-WASI`                    | `debt-trackable`  | WASI surface gap; per-call D-NNN                               |
| `SKIP-WASMTIME-FAIL`           | `runner-internal` | wasmtime-side failure on differential fixture (their bug)      |
| `SKIP-WASMTIME-MISSING`        | `debt-trackable`  | D-008 (windowsmini wasmtime install gap)                       |
| `SKIP-WASMTIME-UNUSABLE`       | `debt-trackable`  | D-008 (windowsmini wasmtime stub binary)                       |
| `SKIP-HOST-STATE-DIVERGED`     | `ADR-required`    | `.dev/decisions/skip_host_state_diverged.md`                   |

### When a new token is introduced

Reviewer checklist for any commit that adds a `try
stdout.print("SKIP-<NEW> ...")` site:

- [ ] Does the diff add a row to the table above in the same commit
      (or an ADR amendment to this ADR)?
- [ ] Does the chosen class match the token's nature? Reference
      the distinguishing question: "would shipping v0.1.0 with
      this skip non-zero be acceptable?" → if YES, `runner-
      internal`; if NO and there's an ADR carrying the removal
      condition, `ADR-required`; if NO and there's no ADR yet,
      `debt-trackable`.
- [ ] Is the paired artifact (D-NNN row OR ADR file) created /
      referenced in the same commit?

A `SKIP-*` token landing without a class entry is a
`audit_scaffolding §G` finding (`block` — re-derives the close-
plan C3 failure mode).

## Alternatives considered

### Alternative A — Single-class flat list

- **Sketch**: All `SKIP-*` tokens are equal; the ratchet tracks
  the total runtime_skip count.
- **Why rejected**: Conflates "real gap" with "expected runner
  guard". `SKIP-START-TRAP` (legitimate) and `SKIP-CROSS-MODULE-
  IMPORTS` (real gap) would ratchet identically — masking the
  signal close-plan §6 (e) was specifically engineered to expose.

### Alternative B — Per-token Accepted ADR

- **Sketch**: Every `SKIP-*` token requires a paired Accepted ADR
  (mirror `.dev/decisions/skip_*.md` style for all 19 tokens).
- **Why rejected**: ADR overhead is wrong for runner-internal
  cases (e.g. `SKIP-EMPTY` would need an ADR explaining "empty
  fixture is empty" — pure ceremony). The debt-trackable class
  exists precisely so `D-NNN` rows can carry the same information
  at lower cost.

### Alternative C — Class derived from token prefix

- **Sketch**: `SKIP-V2-*` is automatically `debt-trackable`;
  `SKIP-WASMTIME-*` is `runner-internal`; etc.
- **Why rejected**: The semantic class is orthogonal to the
  prefix. `SKIP-WASMTIME-FAIL` is runner-internal but `SKIP-
  WASMTIME-MISSING` is debt-trackable — same prefix, different
  classes. The explicit per-token table avoids the false
  generalisation.

## Consequences

- **Positive**:
  - Ratchet semantics become precise: only `debt-trackable` +
    `ADR-required` counts gate release; `runner-internal` is
    informational.
  - New `SKIP-*` token reviewer-checklist closes the close-plan
    C3 anti-pattern (tokens landing without an ADR/debt pairing).
  - `audit_scaffolding §G.1` (workaround pairings) gains a
    direct table to grep against — every entry without a paired
    artifact is a `block` finding.
- **Negative**:
  - One more table to maintain. Mitigated by the audit grep
    making drift detectable.
  - The initial classification table risks being wrong; the
    `Proposed` Status acknowledges that the user-collaborative
    Accept may re-classify a few entries.
- **Neutral / follow-ups**:
  - ~~`scripts/check_skip_impl_ratchet.sh` extension to ingest the
    token-class mapping (per close-plan §6 (f) bullet 4).~~
    LANDED at D-155 part 1: script now greps `SKIP-<TOKEN>` lines
    from cached spec-runner logs, classifies each via this ADR's
    canonical table, and gates on `manifest_total +
    runtime_debt_trackable + runtime_adr_required`
    (`runner_internal` informational). YAML schema extended with
    three per-class fields; pre-extension rows default missing
    fields to 0 (backward compat).
  - ~~`audit_scaffolding §G.1` grep-against-table extension (per
    the workaround-pairings check).~~ LANDED at 0abe32d8 as
    `scripts/check_skip_taxonomy_pairing.sh` + audit
    `§G.1.2` (paired-artifact resolution): debt-trackable rows
    are resolved against `.dev/debt.md` + `git log` discharge
    history; ADR-required rows are resolved against
    `.dev/decisions/*.md` file existence. Current Proposed table
    surfaces 6 drift findings (4 discharged-D-NNN citations + 1
    placeholder + 1 debt-trackable lacking any D-NNN) — to be
    addressed at the next ADR-0078 amendment cycle alongside
    user Accept.

## References

- Close-plan §6 (f) — `.dev/phase9_structural_debt_close_plan.md`
- Sibling ADRs: ADR-0050 (skip-impl ratchet); ADR-0029 (Path B
  skip classification); `.dev/decisions/skip_*.md` (per-fixture
  paired ADRs).
- Close-plan §6 (e) commit `13562a5` (AssertTally split, paired
  semantic shift).
- `.claude/rules/no_workaround.md` + `.claude/rules/
  no_fallback_on_failure.md` (sibling discipline; tokens are the
  controlled exit for cases neither rule accepts inline).
- Runner source: `test/spec/spec_assert_runner_base.zig`
  (lines that emit `SKIP-*`).

<!--
## Revision history

| Date       | SHA          | Note                                    |
|------------|--------------|-----------------------------------------|
| 2026-05-21 | `a8e8d524` | Initial Proposed version.               |
-->
