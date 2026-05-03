# 0011 — Reopen Phase 6 and semantically revert Phase 7 progress

- **Status**: Accepted
- **Date**: 2026-05-03
- **Author**: continue loop
- **Tags**: phase-6, phase-7, scope, deferral-reversal, baseline,
  supersedes-0010

## Context

ROADMAP §9.6 (Phase 6) was chartered by ADR-0008 with an
explicit 🔒 platform gate semantics:

> **Goal**: enumerate exactly which v1-passing artefacts ... fail
> under v2 interp, and **bring them all to green before any JIT
> or local-optimisation complexity is introduced**. ... This Phase
> exists to keep the v1-vs-v2 divergence triage **free of JIT /
> regalloc / W54-class lattice noise**. **🔒 platform gate**: yes.
> **Phase 7 (JIT v1 ARM64) cannot open until Phase 6 is `DONE`
> on all three hosts**.

ADR-0010 deferred two of Phase 6's exit criteria (§9.6 / 6.2
wasmtime stdout differential, §9.6 / 6.3 ClojureWasm guest
end-to-end) into Phase 7 on the operational rationale that
"Phase 7's `interp == jit_arm64` differential gate is the
natural infrastructure for catching the same bugs". Phase 6 was
then closed (`0f52be6`, §9.6 / 6.8) and Phase 7 progressed
through 7.0 / 7.1 / 7.2 over three feature commits (`b336e78` /
`a6bf0e7` / `3c89984`).

Two structural problems with that path were subsequently
surfaced:

1. **Phase 7's `interp == jit_arm64` gate cannot surface the
   deferred bugs.** ADR-0010's premise required the two
   execution surfaces to *diverge* on the buggy fixtures,
   exposing the underlying interp behaviour bug. But once the
   JIT lands and reproduces the same trap-mid-execution
   behaviour as the interp (the most likely outcome, since both
   surfaces consume the same ZIR with the same operand-stack
   discipline), the differential gate registers `0 mismatch` —
   *false green*. The bugs hide instead of being surfaced.

2. **The Phase 6 / §9.6 / 6.4 bench baseline is structurally
   invalid as a "Phase-7+ comparison floor".**
   `bench/baseline_v1_regression.yaml` (commit `4f73288`)
   admits in its own header comment that all 5 baseline
   fixtures are within the 39 trap-mid-execution subset, and
   that the wall-clock numbers are stable only because *the
   trap site is reproducible*. The §9.6 / 6.4 row text
   explicitly demands a "Phase-7+ comparison floor"; a baseline
   measuring trap-time instead of completion-time cannot serve
   that role. The `[x]` mark on §9.6 / 6.4 was the same
   meaning-stretching pattern ADR-0010 made for §9.6 / 6.2 +
   6.3, applied silently rather than via an ADR.

Together, these two facts mean Phase 6 was closed under a
charter (the §9.6 Goal "free of JIT noise" + 🔒 platform gate)
that the closure itself violated. Continuing Phase 7 from this
state risks landing the JIT baseline (the most expensive
component to build, debug, and revisit) on top of an interp
foundation whose behaviour parity with wasmtime is unverified.
That violates the W54-class lesson v2 was founded on: post-hoc
layered optimisation atop an unstable substrate produces a
fragile lattice.

The corrective action is to honour §9.6's original charter:
reopen Phase 6, do the v1 conformance work the charter
promised, and only then re-enter Phase 7 from scratch.

## Decision

Reopen Phase 6 and semantically revert Phase 7 code progress.
Specifically:

### 1. Code revert (single atomic commit)

Drop the following files and changes, restoring the working
tree to its `0f52be6` (Phase 6 close) state for the `src/`
tree:

- `src/jit/reg_class.zig` — delete (introduced by `b336e78`)
- `src/jit/regalloc.zig` — delete (introduced by `a6bf0e7`)
- `src/jit_arm64/inst.zig` — delete (introduced by `3c89984`)
- `src/jit_arm64/abi.zig` — delete (introduced by `3c89984`)
- `src/jit/` and `src/jit_arm64/` — `rmdir` if empty after the
  above
- `src/ir/zir.zig` — restore the `RegClass` enum to its
  pre-7.0 3-variant form (`enum(u8) { gpr, fpr, simd, _ }`),
  reverting `b336e78`'s extension. Phase 7's re-entry will
  re-derive the 3 `*_special` variants when needed.
- `src/main.zig` — remove the test-discovery imports for the
  4 deleted files

`bench/baseline_v1_regression.yaml` is **NOT** included in
this commit. It stays in tree under the staged plan in §3
below.

### 2. ROADMAP / handover state restore (same commit as §1)

- **Phase Status widget**: `6 → IN-PROGRESS`, `7 → PENDING`
  (reverts `0f52be6`'s flip)
- **§9.6 / 6.4** (bench baseline): `[x] 4f73288` → `[ ]` with
  an inline annotation `(reopened by ADR-0011 — was [x] on a
  trap-time baseline)`.
- **§9.6 / 6.8** (Phase 6 close): `[x]` → `[ ]`. Phase 6 is
  no longer closed.
- **§9.6 / 6.2 + 6.3**: replace `DEFERRED → §9.7 per
  ADR-0010` with `REOPENED in Phase 6 per ADR-0011`. The
  actual restoration of these two rows to their original
  ADR-0008 charter scope is the heart of this ADR.
- **§9.7 / 7.0 + 7.1 + 7.2**: `[x]` → `[ ]`. The `§9.7 task
  list (expanded)` table itself is preserved (it's the plan
  Phase 7 returns to after Phase 6 strict-closes), but the
  individual rows reset to unstarted state. Add a 1-line
  inline note above the table: `Phase 7 is paused until
  Phase 6 strict-closes per ADR-0011; rows below describe
  the plan to re-enter from 7.0.`
- **§9.7 / 7.7 + 7.8**: removed from the §9.7 table. These
  were the ADR-0010 deferred-in rows; their scope returns to
  §9.6 / 6.2 + 6.3.
- **§9.6 / 6.0/6.1/6.5/6.6/6.7 SHA backfills**: preserved
  (these rows landed honestly and are not affected by this
  ADR).
- **`.dev/handover.md`**: `Active task` and `Current state`
  blocks rewritten to "Phase 6 reopen — ADR-0011 landed;
  revert commit landed; next step is the v1-asset triage
  decision that will define Phase 6's reopened scope".

### 3. Bench baseline staged handling

`bench/baseline_v1_regression.yaml` is preserved through the
revert commit. Its honest disposition lands in three steps:

1. **Immediately after revert**: re-run `bash
   scripts/record_baseline_v1_regression.sh` and confirm the
   current interp produces the same trap-time numbers (sanity
   check that the revert did not perturb interp behaviour).
2. **During Phase 6 reopen**: as interp behaviour bugs are
   fixed and the 39 trap-mid-execution fixtures move into
   the completion bucket, the 5 baseline fixtures will
   transition from trap-time to completion-time numbers.
3. **At Phase 6 strict-close**: regenerate the baseline
   against completion-bucket fixtures, delete or overwrite
   the trap-time yaml, and only then mark §9.6 / 6.4 `[x]`
   again.

### 4. ADR-0010 supersession

ADR-0010's frontmatter changes from `Status: Accepted` to
`Status: Superseded by ADR-0011 (2026-05-03)`. Body content,
Decision, Alternatives, and Consequences are preserved
verbatim as historical record. `References` gains one
trailing line: `Superseded by ADR-0011 — see 0011 for the
corrective decision.`

### 5. Revert commit hygiene

The revert commit message references this ADR by number,
enumerates all reverted commit SHAs (`b336e78` `efe599b`
`a6bf0e7` `096843b` `3c89984` `978e1ab` plus partial revert
of `0f52be6` for ROADMAP/handover), and explains in 2-3
sentences why this is a *semantic revert* rather than `git
revert -m` on each commit (atomic restoration of
meaning-state, not mechanical diff inversion of code-state).

### 6. Phase 6 reopened scope

Phase 6 reopens with its original ADR-0008 charter intact:
the §9.6 Goal "bring all v1-passing artefacts to green
before any JIT or local-optimisation complexity is
introduced" stands as written. The specific work breakdown
(which v1 assets to ingest, in what order, with what runner
shape) is established by a separate decision after this ADR
lands and the working tree is in its reopened state.

## Alternatives considered

### Alternative A — Honour ADR-0010 and continue Phase 7

- **Sketch**: Land §9.7 / 7.3 〜 7.6, trust the differential
  gate to surface interp bugs as ADR-0010 promised.
- **Why rejected**: The differential gate's surfacing power
  depends on the two surfaces *diverging* on buggy inputs.
  When both consume the same ZIR with the same operand-stack
  discipline bug, they trap at the same instruction and the
  gate registers `0 mismatch` — exactly the false-green
  pattern this ADR exists to prevent.

### Alternative B — Insert a new Phase between 6 and 7, renumber downstream

- **Sketch**: Open a new "Phase 6.5" for interp-parity work,
  renumber Phase 7+ → 8+, leave Phase 6 closed.
- **Why rejected**: Renumbering touches §A1-§A14 cross-
  references, every downstream Phase exit criterion that
  names a Phase number, handover, and several existing ADRs.
  High blast radius for documentation, with no semantic gain
  over reopening Phase 6 honestly. Reopening is also more
  truthful — the work to be done IS what ADR-0008 chartered
  §9.6 to be.

## Consequences

### Positive

- Phase 7 re-enters from a substrate where the interp's
  observable behaviour matches wasmtime on the realworld
  corpus and the bench baseline measures completion-time, not
  trap-time. The JIT baseline (Phases 7-8) lands on a
  verified foundation.
- ADR-0010's flawed premise is surfaced explicitly and
  corrected via standard ADR supersession, preserving the
  historical record of why the deferral was originally chosen
  and why it was reversed.
- §9.6 / 6.4's silent meaning-stretch (trap-time as
  comparison floor) is normalised retroactively. The pattern
  of "close a row by stretching the row text's meaning" is
  named and rejected here, providing precedent for future
  audits.

### Negative

- Phase 7 work (commits `b336e78` 〜 `978e1ab`, six commits,
  ~600 LOC including tests) is reverted. The work itself is
  not lost (`git log` retains it) and most of it will be
  re-derived when Phase 7 re-enters.
- The Phase 6 → Phase 7 transition that handover and audit
  scaffolding documents already record as `[x]` will appear
  twice in `git log` (once at `0f52be6`, once at the
  eventual strict close). The commit message and ADR-0011
  reference make the cause clear.

### Neutral / follow-ups

- The `audit_scaffolding` skill should be re-run after this
  ADR + the revert commit + ROADMAP edits land, to verify
  the scaffolding state is internally consistent (Phase
  widget matches §9.6 / 6.x marks matches handover Active
  task).
- The `continue` skill's autonomous push policy remains
  as-is; this ADR does not change the operating discipline.
  The current explicit halt of `/continue` remains in effect
  until Phase 6 reopen has a clear next-task pointer in
  handover.
- Phase 6's reopened scope (the work that defines what
  "strict close" means in concrete rows) is established by
  a subsequent decision, not by this ADR.

## References

- ROADMAP §9.6 (Phase 6 — to be reopened)
- ROADMAP §9.7 (Phase 7 — task table preserved, individual
  rows reset)
- ROADMAP §A13 (v1 regression suite stays green merge gate)
- ADR-0008 (Phase 6 charter — the original §9.6 scope this
  ADR restores)
- ADR-0010 (Phase 6 / 6.2 + 6.3 deferral — superseded by
  this ADR)
- Reverted commits: `b336e78` `efe599b` `a6bf0e7` `096843b`
  `3c89984` `978e1ab` (full code reverts) + `0f52be6`
  (partial revert: ROADMAP Phase Status widget + §9.6 / 6.8
  mark only; §9.7 inline expansion preserved)
- `bench/baseline_v1_regression.yaml` header comment (the
  self-admitted trap-time baseline)
