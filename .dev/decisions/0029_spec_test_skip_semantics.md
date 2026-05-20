# 0029 — Sharpen `skip=0` semantics in §9.7 / 7.5 (and §9.7 / 7.8) exit criteria

- **Status**: Accepted
- **Date**: 2026-05-06
- **Author**: zwasm v2 maintainer (autonomous loop, `/continue` audit chunk)
- **Tags**: roadmap, exit-criteria, spec-tests, phase-7

## Context

ROADMAP §9.7 / 7.5 row text is:

> spec test pass=fail=skip=0 via ARM64 JIT on Mac aarch64 host
> (drives every Wasm 1.0 + 2.0 op the interp covers).

§9.7 / 7.8 mirrors this for x86_64. As written, `skip=0` is a
literal target.

The §9.7 / 7.5 spec-assertion-driver chain (chunks -a〜-u, see
`git log --grep='§9.7 / 7.5-spec-assertion-driver'`) has built a
pipeline that surfaces three categorically different reasons for
a spec assertion to be skipped:

1. **Implementation-gap skip** — handler / parser / validator /
   runner-dispatch piece for a Wasm 1.0 / 2.0 op exists in spec
   but doesn't yet exist in our codebase. Example: `local_tee.wast`
   runner failure on `as-convert-operand(i64:0) -> i32:41` is a
   missing `i64-arg → i32-result` runner dispatch, not a spec
   feature we deliberately deferred.
2. **Proposal-skip with ADR** — Wasm 2.0+ proposal (SIMD, GC, EH,
   threads, WASI preview2 etc.) we have explicitly carved out of
   Phase 7 scope via a `.dev/decisions/skip_*.md` ADR, with a
   removal condition documented. Example: `simd_*.wast` corpus
   skipped per a `skip_simd.md` ADR (= structural deferral).
3. **Test-shape skip** — fixture exists but the assert_return
   shape is outside the runner's typed-entry surface today
   (e.g. multi-result, ref types). Distinct from (1) because
   adding the dispatch is straightforward; the gating is
   prioritisation, not structural.

A literal `skip=0` interpretation requires landing every
proposal that the spec testsuite covers, including SIMD / GC
which §9.8+ explicitly defers. This is in tension with ROADMAP
§9.8 / Phase 8 scope and the proposal-watch
(`.dev/proposal_watch.md`) deferral of Wasm 2.0+ proposals to
their own phases.

Without explicit semantics, the autonomous `/continue` loop
faces an indeterminate `[x]` flip judgement at 7.5: either it
flips while skips remain (silently weakening the gate), or it
holds 7.5 `[ ]` indefinitely waiting for proposals that won't
land in Phase 7 (silently blocking all downstream rows). Both
modes are bad.

## Decision

`skip=0` in ROADMAP §9.7 / 7.5 (and §9.7 / 7.8) counts only
**implementation-gap skips** (category 1) and **test-shape
skips** (category 3). **Proposal-skip with ADR** (category 2)
is excluded from the count by construction — those are
deferred decisions, not implementation gaps.

Operationally:

- Each manifest-line `skip` directive consumed by
  `spec_assert_runner` / `wast_runner` carries one of two
  prefixes:
  - `skip-impl <field>` — implementation-gap or test-shape
    (categories 1, 3). **Counted toward the runner's `skipped`
    tally; non-zero blocks 7.5 / 7.8 `[x]` flip.**
  - `skip-adr-<ADR-id> <field>` — deferred per a specific
    `.dev/decisions/skip_*.md` ADR (category 2). **Not
    counted; reported in a separate `proposal_skipped` tally
    for visibility.**
- Runner output line evolves from
  ```
  spec_assert_runner: 138 passed, 0 failed, 94 skipped
  ```
  to
  ```
  spec_assert_runner: 138 passed, 0 failed, 94 skipped (impl), 0 skipped (proposal-adr)
  ```
- A bare `skip <reason>` (no prefix) is treated as
  `skip-impl` for forward compatibility and surfaced in a
  diagnostic warning by the runner so legacy entries are
  noisy rather than silent.

The 7.5 / 7.8 row text is amended (one short clause + this
ADR reference) to anchor the semantics in this ADR. The
amendment is the sole ROADMAP §9 change driven by this
decision.

## Alternatives considered

### Alternative A — Keep literal `skip=0`

- **Sketch**: don't change semantics. 7.5 stays open until SIMD
  / GC / EH ship. ROADMAP §9.8 stays blocked indefinitely.
- **Why rejected**: contradicts §9.8+ phase plan (Phase 8 = JIT
  optimisation foundation, not Wasm 2.0+ proposal landing).
  Also makes the autonomous loop's 7.13 transition gate
  unreachable. Not in good faith with the project's actual
  trajectory.

### Alternative B — Hard-code an exclusion list in row text

- **Sketch**: amend 7.5 to "spec test pass=fail=skip=0 *except
  SIMD / GC / EH / threads / WASI*".
- **Why rejected**: brittle. Every new Wasm proposal phase-
  advance requires a row-text amendment (= ROADMAP §9
  deviation = ADR). The skip_*.md ADR mechanism already exists
  and is the right place to enumerate exclusions.

### Alternative C — Rule-only (no ADR, no row amendment)

- **Sketch**: file `.claude/rules/spec_skip_classification.md`,
  leave 7.5 row text unchanged.
- **Why rejected**: 7.5 / 7.8 row text is the load-bearing
  exit-criterion source; a rule that contradicts the row text
  silently is worse than no rule. The skip semantics IS the
  exit criterion, so it belongs in the row text (anchored to
  this ADR).

### Alternative D — Move the gate to a separate row

- **Sketch**: split 7.5 into 7.5α (impl-skip = 0) and 7.5β
  (literal skip = 0, deferred to Phase 8+).
- **Why rejected**: row inflation. The operational target IS
  "no implementation gaps remain"; 7.5β is just a restatement
  of "Phase 8+ work" which §9.8 onwards already covers.

## Consequences

### Positive

- Autonomous loop has a deterministic `[x]`-flip rule for 7.5 /
  7.8: count `skip-impl` lines; if 0 (and pass=fail=0 hold),
  flip.
- skip_*.md ADRs become first-class artifacts visible from the
  runner output (proposal_skipped count).
- Phase 8 transition gate review (7.13
  `archive/phase_gates/phase8_transition_gate.md`) can
  sanity-check that **every** proposal-skip ADR has a
  removal condition consistent with §9.8+ phase plan.
- `bug_fix_survey.md` Step 3 (cite ROADMAP §14 forbidden-list
  nearby) extends naturally: when adding an `skip-impl`,
  surface "is this really impl-gap or proposal-deferred?" at
  authoring time.

### Negative

- Manifest format migration cost — every existing `skip <reason>`
  line in `test/spec/wasm-1.0-assert/*/manifest.txt` needs a
  prefix audit pass (the regen script can re-emit; manual
  fixtures need one-time touch).
- `spec_assert_runner` + `wast_runner` need to learn the
  prefix vocabulary. ~30 LOC each.
- Adds a small naming convention burden: every new `skip-adr-`
  line must reference an existing ADR id; missing ADR id = warn.

### Neutral / follow-ups

- After landing this ADR's runner-side code, fold the existing
  `skip non-int-result <field>` etc. lines from
  `scripts/regen_spec_1_0_assert.sh` into `skip-impl
  non-int-result <field>` (one-line change).
- The proposal-skip ADRs (`skip_simd.md`, `skip_gc.md` etc) for
  Wasm 2.0+ proposals land later; this ADR establishes the
  vocabulary they will use.
- Phase 7→8 transition gate (`archive/phase_gates/phase8_transition_gate.md` §3a)
  references this ADR as the canonical exit-criterion source —
  one new line in §3a.

## References

- ROADMAP §9.7 / 7.5 (amended; this ADR id appears inline in
  the row text)
- ROADMAP §9.7 / 7.8 (mirrors 7.5; same amendment)
- `.dev/decisions/skip_*.md` (existing per-fixture skip ADRs)
- `.dev/proposal_watch.md` (Wasm proposal phase tracking)
- `.dev/archive/phase_gates/phase8_transition_gate.md` §3a (Phase 7→8 deferred-work DAG)
- Lessons:
  - `2026-05-06-spec-citation-gap.md` (related: per-handler
    spec citation rule)
- §9.7 / 7.5-spec-assertion-driver-{a..u} chain (commits
  `503b5ee`〜`bde1223`) — the chain that surfaced this gap.

## Revision history

| Date | SHA | Change |
|---|---|---|
| 2026-05-06 | `4a742914` | Initial. Sharpens 7.5 / 7.8 `skip=0` semantics. Driven by audit chunk that asked: "will the autonomous loop reach Phase 8 readiness?" — the indeterminate `[x]`-flip rule was identified as a blocker. |
| 2026-05-11 | `3d0e8a7c` | **Honest record of design-vs-implementation divergence** (per 2026-05-11 ADR audit, SUMMARY §2.4 / batch_C). The §"Decision" specifies `skip-impl <field>` / `skip-adr-<ADR-id> <field>` manifest-line prefixes. The actual implementation took a different path: `spec_assert_runner.zig` produces the ADR's promised twin-tally output (`N skipped (impl) + M skipped (proposal-adr)`) but **classifies via runner-internal hardcoded reason strings**, not manifest-line prefixes. `grep -rn "skip-impl\|skip-adr" test/spec/` returns 0 matches; manifests still carry bare `skip <reason>` lines. The runner has a single hardcoded mapping (`directive-assert_malformed-text` → `skip-adr` for ADR `skip_text_format_parser.md`). The §7.5 / 7.8 deterministic `[x]`-flip behaviour the ADR aims for is delivered, but new proposal-skip ADRs require runner-code edits to register their reason strings rather than manifest-line additions. The structural barrier (manifest-prefix vocabulary not adopted) is filed as **D-073**; choice between (a) amending this ADR to match the implementation path or (b) implementing the manifest-prefix migration is left to D-073 discharge. ADR Status remains `Accepted` because the operational outcome (deterministic close-flip on §9.7 / 7.5 / 7.8) was achieved; the divergence is structural rather than operational. |
| 2026-05-12 | `c49e856c` | **Path B closure** (D-073 discharge; Track C of Phase 10 prep mode; chunks 9.9-h-21..-24). The 2026-05-11 divergence is resolved by implementing the prefix vocab end-to-end rather than amending the §"Decision". 9.9-h-21 added prefix-aware classification to `spec_assert_runner.zig` + `simd_assert_runner.zig` (+ bare-`skip` back-compat with WARN). 9.9-h-22 updated `scripts/regen_spec_simd_assert.sh` + `scripts/regen_spec_1_0_assert.sh` to emit `skip-impl <reason>` / `skip-adr-skip_text_format_parser <reason>`; 31 manifests rebaked; bare-`skip` count in `test/spec/` went 2357 → 0. 9.9-h-23 added the same to `test/runners/wast_runtime_runner.zig` + hand-migrated 5 `wasmtime_misc/wast/{embenchen,reftypes}/manifest_runtime.txt` files; `test-wasmtime-misc-runtime` flipped from `266/5/0` to `266 passed, 0 failed, 5 skipped (= 0 skip-impl + 5 skip-adr)` — operationally effective per ADR-0050 D-2. D-072 (a/b)-path discharged; D-082 filed for (c)-path actual fixture fixes. This chunk (9.9-h-24) landed (a) this revision row + 3 skip-ADRs' §"Implementation" subsection naming the prefix vocab + drop NOT-EFFECTIVE Status on the 2 affected skip-ADRs, (b) `scripts/check_skip_adrs.sh` prefix-coherence extension wired into `gate_commit.sh`, (c) **D-072 + D-073 deletion**. New skip-ADR workflow: author `.dev/decisions/skip_<topic>.md` + update regen script to emit `skip-adr-skip_<topic>` prefix — **no runner-code edits required**. |
