# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0014_post_phase6_refactor_phase_wiring.md` —
   the wiring contract for the post-Phase-6 → refactor-phase
   transition (renumber + ADR-0015 drafting flow). Active from
   the moment §9.6 / 6.J fires.
3. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   Phase 6 reopen scope (work items 6.A〜6.J, DAG, deferred items).

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (6.A〜6.D done, 6.E iter 4,
  6.F〜6.J pending).
- **Last commit**: `2a972be` — fix(p6) §9.6 / 6.E iter 4 assert_trap
  arity + trap-text mapping. Three-host green.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — drive Phase 6 to strict close (6.E → 6.F → … → 6.J; 100% PASS per ROADMAP §9.6 / 6.J)

`/continue` autonomous loop continues iterating 6.E, then 6.F /
6.G / 6.H once 6.E unlocks them, with 6.I in parallel, terminating
at 6.J Phase 6 close gate.

### 6.E iter 5+ targets (current)

The `test-wasmtime-misc-runtime` standalone gate has 65
remaining failures (down from 78: iter 3 fixed loop+br_if
re-entry, iter 4 fixed assert_trap arity sizing + trap-text
tag_map). Outstanding clusters:
- ~43 trapped unexpectedly (call_indirect, table_copy,
  table_grow_with_funcref, partial-init-table-segment,
  issue4840, etc.) — mixed bag of interp behaviour bugs and
  operand discipline.
- ~10 InstanceAllocFailed (cross-module imports) — runner's
  `register` directive needs named-module store sharing wired.
- ~7 BadValueSyntax 'is hello?' — manifest field with embedded
  space; regen needs to quote field, runner needs quoted-token
  tokenizer.
- ~7 partial-init-memory-segment "result mismatch" — bare
  `(invoke …)` action lines aren't emitted by regen, so
  memory.copy never runs between asserts. Plus partial-init data
  semantics may need spec re-check.

Sequence: pick one cluster per iteration, fix root cause, re-run,
move fixtures from FAIL to PASS, commit. When `test-wasmtime-misc-
runtime` reaches 0 failures, add it to `test-all` aggregate and
proceed to 6.F. Per ROADMAP §9.6 / 6.J the close is **strict 100%
PASS**; the only permitted defer is a v1-era design-dependent
fixture documented in `.dev/decisions/skip_<fixture>.md` AND
physically removed / `# DEFER:`-marked from the active manifest so
the runner's tally is genuinely zero.

## Phase 6 close → automatic refactor-phase ADR drafting

**This is a hard wiring of the post-6.J transition.** When 6.J
fires (Phase 6 strict-close — 100% PASS per ROADMAP §9.6 / 6.J),
the standard "open §9.7 inline" step is **replaced** by:

1. Phase Status widget gets `7 = IN-PROGRESS (refactor &
   consolidation; ADR-0015 draft pending)`. The current `7 =
   PENDING (JIT v1 ARM64 baseline)` text moves down to slot `8`,
   and every later phase's number increments by 1. This renumber
   is acceptable here because Phase 6 is closed and ADR-0011's
   renumber-rejection rule (which protected the open Phase 6)
   no longer applies.
2. `.dev/decisions/0014_refactor_phase_charter.md` is drafted as
   the FIRST work item under the new §9.7 task table. Until
   ADR-0015 is Accepted, §9.7 contains a single row "7.0 Draft
   ADR-0015 (refactor phase charter)"; after ADR-0015 lands, its
   Decision §6 (work-item DAG) populates §9.7 / 7.A〜7.X mirroring
   the ADR-0012 pattern.
3. `/continue` autonomous loop, on the wakeup after 6.J commit,
   reads this handover, sees §9.7 / 7.0 as the active task,
   and runs Step 0 Survey (subagent) on the refactor concept —
   delivering survey input to the ADR-0015 draft author (the
   user, in the next session) instead of advancing implementation.

The autonomous loop's standard §9.<N> → §9.<N+1> phase boundary
handler does NOT need a code-level change for this — the
handover-driven retargeting (above) gives the loop the right
next pointer. The loop keeps running; the next active task
just happens to be ADR-drafting rather than coding.

## ADR-0015 draft brief (referenced by §9.7 / 7.0)

Generic by design — the draft phase is a discussion, not a
prescribed plan. The drafter (user + Claude in dialogue) covers:

1. **Placement**: confirm "between Phase 6 close and the JIT
   phase". Document the renumber: old §9.7 (JIT v1 ARM64) →
   §9.8, old §9.8 (JIT x86_64) → §9.9, etc.
2. **Goal + Exit criterion** in measurable terms (what does
   "refactor done" mean — code metrics? bug-class elimination?
   test-coverage thresholds? all of the above?).
3. **Work-item taxonomy** mirroring ADR-0012's §6 DAG style:
   discovery / design re-examination / consolidation / split /
   bug-class elimination / magic-number centralisation /
   workaround inventory + root-cause replacement / test- and
   bench-fixture organisation revisit / etc., as separate work
   items with dependencies.
4. **Relationship to existing ADRs** (0008 / 0011 / 0012 /
   0013) — are any of those superseded or extended? Does this
   phase carry forward any deferred items from Phase 6?
5. **Relationship to scaffolding rules** (ROADMAP §1-§5 / §11
   / §14 / §18, `.claude/rules/*`) — is any rule itself due
   for refactor as part of this phase?
6. **Out-of-scope items** deferred to later phases.

Resist over-specifying work items at draft time — the phase's
*shape* is the discussion target. Implementation detail (which
files to split, which numbers to centralise, which rules to
revisit) emerges from discussion. Prefer "open questions for
user" over "prescribed answers" in the first draft.

### Carry-over reminders for ADR-0015 drafting (do not lose)

- **ADR-0010 lessons**: premise-unverified `defer` (the 6.2 / 6.3
  push-out via differential-gate-will-catch-it) was reversed by
  ADR-0011. Refactor phase should include a "discovery" work item
  that surfaces premise-checks for any future deferral / scope
  reduction proposal — not just trusting the gate.
- **ADR-0011 lessons**: "silent meaning-stretch" pattern (closing
  a row by stretching its text's meaning, e.g. trap-time numbers
  as bench baseline) was named and rejected. Refactor phase
  should review scaffolding rules (§18 amendment policy,
  audit_scaffolding heuristics) for whether they catch this
  pattern; if not, add an explicit check.
- **ADR-0012 §7 boundary**: bench history accretion suppression
  (`bench/results/{recent,history}.yaml` split, phase-boundary-
  only history append) is implemented in 6.H. Refactor phase
  must NOT touch §7's contract — or must explicitly supersede
  §7 in ADR-0015 if it does. Default: leave alone.

ADR numbering: ADR-0014 (wiring, this commit, Accepted) and
ADR-0015 (charter, next session, Proposed→Accepted) are
reclaimed from ADR-0012's "forthcoming ADR-0014 (bench
infra)" conditional slot; the bench-infra ADR slips to
ADR-0016 if it ever surfaces load-bearing decisions.

## Phase 6 reopen DAG (ADR-0012 §6)

```
6.A ✅  6.B ✅  6.C ✅  6.D ✅
 │
 ├─→ 6.E ⏳ (iter 4 done; iter 5+ → /continue continues)
 │    └─→ {6.F, 6.G, 6.H} → 6.J → §9.7 ADR-0015 drafting
 │
 └─→ 6.I (parallel)  ─→ 6.J
```

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over
- element-section forms 2 / 4-7 — Phase 2 chunk 5d-3
- ref.func declaration-scope — Phase 2 chunk 5e
- 13 wasmtime_misc BATCH1-3 fixtures queued (validator gaps)
- 39 trap-mid-execution realworld fixtures — 6.E target
- 10 SKIP-VALIDATOR realworld fixtures
- 65 wasmtime_misc runtime-runner failures (categorised above)

## Open questions / blockers

(none — autonomous loop continues 6.E → 6.J → ADR-0015 drafting.)
