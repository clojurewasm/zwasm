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

- **Phase**: **Phase 6 IN-PROGRESS** (6.A〜6.D done, 6.E paused
  on 29 fails awaiting ADR-0015 inputs; 6.F〜6.J pending).
- **Last source commit**: `7b26760` — fix(p6) §9.6 / 6.E iter 11
  split Label arity (br vs end), wire defined globals. Three-host
  green. The underflow's true cause was `loopOp` hardcoding
  `arity=0` for both end and br paths (`tinygo_fib`'s
  `loop (result i32)`).
- **Iter 12 reverted**: cascade-quiet `register from $X` was
  workaround-class; reverted so the root failure stays visible.
- **Next**: ADR-0015 drafting session (with user) to plan the
  cross-module / ownership / Value-semantics cleanup before the
  remaining 27 fails close. See "Workaround / debt inventory"
  below for the input list.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — drive Phase 6 to strict close (6.E → 6.F → … → 6.J; 100% PASS per ROADMAP §9.6 / 6.J)

`/continue` autonomous loop continues iterating 6.E, then 6.F /
6.G / 6.H once 6.E unlocks them, with 6.I in parallel, terminating
at 6.J Phase 6 close gate.

### 6.E status: clearing inputs for ADR-0015 (clean-up before close)

`test-wasmtime-misc-runtime` standalone gate: **242 passed / 29
failed** (78 → 65 → 45 → 41 → 39 → 30 → 29). Iterations 5–11
landed real fixes; iter 12 attempted a `register`-cascade
PASS-skip that was reverted as workaround-class. The remaining
clusters all share one root: **funcref / cross-module dispatch
needs (instance, funcidx) instead of bare funcidx**, and the
allocator/ownership model around it is currently ad-hoc. That
is ADR-0015 territory, not iter-by-iter.

Current cluster shape:
- 18 `invoke ExportNotFound` — tcot.1/2 hit
  `UnsupportedCrossModuleTableImport`; current stays at module 0
  which lacks `call_t`/`call_u`/`call_t_2`/`call_u_2`.
- 9 `instantiate InstanceAllocFailed` — embenchen_*.1 ×4
  (memory + table + globals + funcs); call_indirect.1 + tcot.{1,2}
  (table); externref-segment.0 + elem-ref-null.0 (decodeElement
  forms 5/7 still deferred).
- 1 `partial-init-table-segment/indirect-call result[0] mismatch`
  — likely resolves with proper funcref dispatch.
- 1 `register source module '$n' not registered` — cascade from
  tcot.1 instantiate failure (the would-be iter 12 fix was
  reverted to keep root failure visible until ADR lands).

### Workaround / debt inventory (input to ADR-0015)

These are the items that warrant first-class redesign rather than
piecemeal patches. Each is documented inline; ADR-0015 will decide
the resolution sequence.

1. **Cross-module imports beyond memory** — `c_api/instance.zig`
   returns `error.UnsupportedCrossModuleTableImport` /
   `…GlobalImport` / `…FuncImport`. Direct cause of 27 of the 29
   misc-runtime failures. Resolution requires (a) a `FuncEntity`
   (or equivalent) so a `funcref` carries the source instance,
   (b) cross-instance dispatch for `call_indirect` and `call`,
   (c) shared globals.
2. **`Value` (`src/interp/mod.zig`) lacks instance identity** —
   `funcref` is the low-32 of `ref`. Single-instance assumption
   leaks throughout `call_indirect` / `table.*` / `ref.func` /
   elem-segment population. Pre-Phase-6 design judgment that
   doesn't survive cross-module.
3. **Runtime ↔ Instance ↔ allocator ownership** — `rt.alloc` is
   parent_alloc; `inst.arena` is a separate per-instance arena.
   Table `refs` are split between the two (parent_alloc for grow-
   compatibility, arena for per-segment slices). `rt.memory` got
   a `memory_borrowed` flag in iter 7 because it can be aliased
   from another instance and `Runtime.deinit` would otherwise
   double-free. Tables / elems leak (no free path). Pattern
   doesn't scale to globals / funcs.
4. **Runtime has no Instance back-pointer** — Cross-instance
   dispatch needs to know "which instance owns this Runtime" for
   funcref resolution. Currently invented ad-hoc per call site.
5. **`decodeElement` forms 5 / 7** — `src/frontend/sections.zig`
   returns `Error.InvalidFunctype` for non-form-{0,1,3,4} element
   segments. Comment marks `// 2/5-7 deferred`; affects 2
   reftypes fixtures (externref-segment.0, elem-ref-null.0).
   Phase 2 chunk 5d-3 carry-over — relocate or close in
   ADR-0015.
6. **`Label.branch_arity = 0` for loop** — iter 11 hardcoded for
   Wasm 1.0; multivalue loop-with-params (Phase 2 chunk 3b
   carry-over) re-opens this. ADR-0015c (formalise the
   `arity` / `branch_arity` split as the canonical shape) +
   §14 anti-pattern entry against single-slot dual-meaning.
7. **`buildImports` (`test/runners/wast_runtime_runner.zig`)
   silently sets a slot to null when the source isn't
   registered or doesn't expose a matching name** — the import
   then surfaces as `UnknownImportModule` two layers deeper.
   Acceptable while imports are still being built out, but the
   diagnostic chain is fragile.
8. **`partial-init-table-segment/indirect-call` mismatch
   uninvestigated** — root-cause not confirmed; almost
   certainly downstream of (1)/(2). Re-measure after ADR-0015
   item lands; do not patch in isolation.

### ADR-0015 directionality (sketch — not yet a decision)

The original ADR-0014 wiring assumed Phase 6 closes first, then
ADR-0015 drafts the *next* refactor phase. The user has flagged
that closing Phase 6 with workaround debt in place is wrong:
the items above warrant resolution **before** §6.J close,
because:

- (1)/(2) block strict 100% PASS regardless.
- (3)/(4) shape the API surface that (1)/(2)'s fix touches —
  doing them after means rewriting freshly-landed code.
- The "refactor phase as Phase 7" framing was meant to clean up
  Phase 6 *afterthoughts*; if the cleanup is also the unblocker,
  doing it inside Phase 6 is the cheaper path.

ADR-0015 (next drafting session) decides:
- Whether §9.6 gains a `6.K` work item (or similar) that
  consolidates the above before `6.J` close, OR
- Whether `6.J` close acceptance criterion is relaxed to
  document-as-deferred for the cross-module subset.
- The relationship to the planned post-Phase-6 refactor charter
  (formerly ADR-0014's §9.7 task table).
- Test-bench discipline: how to keep these debt items visible
  in the gate so they don't accumulate silently again.

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
 ├─→ 6.E ⏳ (iter 11 last source fix; ADR-0015 drafting next)
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
- 29 wasmtime_misc runtime-runner failures (categorised above)

## Open questions / blockers

(none — autonomous loop continues 6.E → 6.J → ADR-0015 drafting.)
