# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   Phase 6 reopen scope (work items 6.A〜6.J, DAG, deferred items).
3. `.dev/ROADMAP.md` §9.6 task table — see "§9.6 reopened scope"
   sub-table for the active row.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (6.A〜6.D done, 6.E iter 2,
  6.F〜6.J pending).
- **Last commit**: `b10abef` — fix(p6) §9.6 / 6.E iter 2 workaround
  cleanup (W-1〜W-7). Three-host green.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — TWO threads, user choice on next session

### Thread A (default): continue 6.E iter 3+ via /continue

If `/continue` is invoked, drive 6.E forward: target the
remaining 78 failures in `test-wasmtime-misc-runtime`.
Categorised in `git show b10abef` commit message:
- ~50 trapped unexpectedly (fib / call_indirect / partial-init-
  table-segment). Each cluster needs interp-side root-cause
  investigation (operand-stack discipline / call mechanics).
- ~10 InstanceAllocFailed (cross-module imports). Need to wire
  `register` directive's named-module store sharing in the
  runner.
- ~7 BadValueSyntax 'hello?' (memory-copy-style string-literal
  args). Runner parser extension.
- ~11 individual.

When ≥5 wasmtime_misc fixtures fully pass + realworld traps
shrink toward 30+ completion-bucket fixtures, advance to 6.F /
6.G / 6.H. 6.I (bench restructure) is parallel-eligible
throughout.

### Thread B (user-elevated, **next session takes precedence**):
draft "refactor & consolidation" ADR before resuming 6.E

User raised in 2026-05-03 dialogue: before Phase 7 (JIT) starts,
we should pause for a refactor phase that addresses the
"あるべき論" gaps surfaced during Phase 6:

- root-design re-examination
- code consolidation (where is logic duplicated across files?)
- code separation (where is one file doing too much? e.g.
  `src/c_api/instance.zig` 1494 LOC, `src/frontend/sections.zig`
  1073 LOC — both flagged by `file_size_check.sh --gate`)
- bug-discoverability (where do panics happen instead of
  surfacing typed traps? — popOperand assert pattern is one
  example; W-1 partially addressed)
- magic numbers (operand_stack=4096, frame_stack=256, etc. —
  audit for hardcoded vs spec-derived)
- performance (interp dispatch cost, allocator threading)
- maintainability (naming consistency, comment debt)
- testability (per-feature test isolation, fixture organization)
- benchmarkability (bench fixture coverage, history.yaml
  hygiene)
- "should-be" design (vs "currently-is" — where did we
  compromise for time and where would a fresh re-derivation
  produce a better design?)
- workaround / temporary-fix audit (the W-1〜W-7 from
  `b10abef` exposed the pattern; expect more)
- root-cause vs symptom inventory

User's preferred placement (per dialogue): **insert as a new
Phase between Phase 6 close and Phase 7 (JIT)**. Renumbering
old Phase 7 → 8, old Phase 8 → 9, etc., is acceptable in this
context (different from ADR-0011's renumber-rejection because
this is post-Phase-6-close, not mid-Phase-6).

**Next-session instruction (user request: keep generic, not
prescriptive)**:

> Open a fresh session. Read this handover. Then propose an
> ADR for the refactor phase. Aim for a discussion ADR
> (Proposed status, dialogue-driven), not a unilateral
> Accepted ADR. Cover at minimum:
>
> 1. Where in the ROADMAP this phase lives — defaulting to
>    "between Phase 6 close and current Phase 7", with the
>    renumber implications enumerated.
> 2. The phase's Goal + Exit criterion (what "refactor done"
>    means, in measurable terms).
> 3. The work-item taxonomy (mirror ADR-0012's §6 DAG style):
>    discovery / design / consolidation / split / bug-class
>    elimination / magic-number audit / etc. as separate work
>    items, not one giant blob.
> 4. The relationship to ADR-0008 (Phase 6 charter), ADR-0011
>    (Phase 6 reopen), ADR-0012 (test/bench redesign). Does
>    this refactor phase carry forward any deferred items from
>    Phase 6?
> 5. The relationship to the existing scaffolding rules
>    (ROADMAP §1-§5 / §11 / §14 / §18, .claude/rules/*) — is
>    any rule itself due for refactor?
> 6. Out-of-scope items deferred to later phases.
>
> Resist over-specifying work items at draft time — the user
> wants the phase's *shape* discussed first. Implementation
> detail (which files to split, which numbers to centralise)
> emerges from discussion, not from the ADR draft. Lean
> toward "open questions for the user" over "prescribed
> answers" in the first draft.
>
> ADR-0014 is the next available number. (ADR-0014 in
> ADR-0012's "forthcoming" list was conditional on 6.I
> surfacing load-bearing decisions; if 6.I lands in
> conventional shape, ADR-0014 can be reclaimed for this
> refactor phase, and the bench-infra forthcoming becomes
> ADR-0015.)

When the refactor ADR drafting is done (or on session-pause),
fall back to Thread A. The two threads do NOT block each
other: 6.E iter N can land in parallel with refactor ADR
discussion. The phase boundary discipline ensures the
refactor phase does not start before Phase 6 honest-closes.

## Phase 6 reopen DAG (ADR-0012 §6)

```
6.A ✅  6.B ✅  6.C ✅  6.D ✅
 │
 ├─→ 6.E ⏳ (iter 2 done; iter 3+ continues in Thread A)
 │    └─→ {6.F, 6.G, 6.H} → 6.J
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
- 78 wasmtime_misc runtime-runner failures (categorised in
  Thread A)

## Open questions / blockers

- **Thread B placement decision**: user prefers a new phase
  between Phase 6 and Phase 7. Confirm during ADR-0014 draft.
- **Scope of refactor**: how aggressive? Single-pass surface
  cleanup (zone audit, magic-number centralisation) vs deep
  redesign (e.g. revisit Runtime struct fields, dispatch table
  layout). User's wording covers both ends; ADR draft is the
  forum to scope.
