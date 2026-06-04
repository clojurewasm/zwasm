# 0156 — Endgame redirection: no autonomous release, completion-gated, breaking-allowed industry-standard surfaces

- **Status**: Accepted (2026-06-04; **user-directed** redirection — explicit
  user message in the `/continue` session that mis-marched toward a release).
- **Date**: 2026-06-04
- **Author**: claude (recording a user directive)
- **Tags**: mission, release, scaffolding, completion (完成形), C-API, Zig-API,
  CLI, dogfooding, debt, ADR-0153, ROADMAP §1.1/§1.2, Phase 16
- **Amends**: ROADMAP §1.1, §1.2, Phase 16 (scope + exit); `.claude/skills/continue/`
  (release is never autonomous); CLAUDE.md (frozen invariants + Identity).
  **Extends ADR-0153** (design-priority 完成形 over v0.1.0 speed) to the consumer
  surfaces + the no-autonomous-release rule.

## Context

This `/continue` session opened by closing the D-265 rework campaign (ADR-0153
Phase V), then — following the handover + ROADMAP — flipped Phase 15 → DONE and
opened **Phase 16 "Public release v0.1.0 🔒"**, and began writing release docs
(the §16.1 migration guide). The user intervened with three observations that
the loop's own scaffolding had obscured:

1. **The loop was marching toward a "release" with a large backlog** — D-261
   (GC-on-JIT conservative rooting has NO adversarial test → latent UAF, blocked
   on D-258), the CLI far below v1 (v2 ships only `run`/`compile`; v1 has
   `validate`/`inspect`/`features`/`wat`/`wasm` + capability flags), D-262/D-267,
   and more.
2. **Cutting a `v0.1.0` tag on this branch is structurally undefined.**
   `zwasm-from-scratch` is a long-lived branch and **main is frozen for v1**
   (ROADMAP §13.3). Phase 16 said "zwasm v2 replaces v1 / cut release tag
   v0.1.0" but never specified the merge/cutover mechanics, and `v0.1.0` for a
   rewrite that replaces v1 (1.10.0) is itself an odd number.
3. **The scaffolding actively MIS-FRAMED the loop** into a release-march. That
   the autonomous loop confidently walked into "write CHANGELOG/README, head to
   a release tag" is the bug — the steering (handover / ROADMAP / continue
   skill) pointed there.

## Decision

1. **No autonomous release — ever.** The release (git tag / binary publish /
   any main cutover) is a **MANUAL, user-only act**. The loop MUST have **no
   autonomous path that reaches "cut a release."** There is **no release gate as
   a loop construct**: equivalently, a release gate is *defined out of
   existence* until (a) every completion problem is resolved AND (b) the user
   explicitly acts. The loop never schedules, prepares-then-tags, or surfaces "I
   am ready to release"; it just keeps improving toward 完成形.

2. **The endgame goal is 完成形, not a version.** "Clean final design / good
   design / lightweight-yet-fast / full-featured / 100% spec" across the runtime
   **AND all consumer surfaces — C API, Zig API, CLI.** Measured against
   **あるべき論 + industry standards** (wasm-c-api, wasmtime/wasmer/wazero, the
   Wasm/WASI specs), not against v1 feature-by-feature.

3. **Breaking changes are allowed; v1 full-parity is NOT the goal.** Especially
   the **CLI**: v1's full subcommand/flag set is explicitly **not required**.
   Pick the truly-necessary, simple, industry-standard surface and drop the
   rest. (This supersedes ROADMAP §1.2's "v0.1.0 = match what v1 ships" framing
   for the *surfaces*; the runtime/spec parity items in §1.2 — Wasm 3.0, WASI
   0.1, JIT platforms, 100% spec — remain the floor because they ARE the
   industry-standard correctness bar, not v1-specific.)

4. **Forward work model (all autonomous, debt repaid aggressively):**
   - **Surface-design audits** — C API audited against wasm-c-api (the standard
     wasmtime/wasmer follow); any divergence fixed, and the **tests fixed too**
     if they encoded a wrong shape. Zig API + CLI reviewed for the あるべき論
     minimal surface (breaking-allowed).
   - **Minimal-wrapper dogfooding** — consume zwasm v2 as a Zig library locally
     (a `build.zig.zon` path-dep consumer) to verify it stands up cleanly as a
     library, surface ergonomic gaps, and catch "usable from the CLI but not
     reachable from the API" mismatches. Reuse the existing test corpus where a
     little adaptation makes it serve double duty. (cw-v1 dogfooding stays
     deferred — D-264, no consumer yet.)
   - **Debt repayment** — work the ledger down autonomously, weighting the
     memory-safety items (D-258 JIT GC trigger → D-261 adversarial rooting test)
     and the surface-correctness items (D-267 API naming, D-262 emit
     verification). Research industry norms (web search, reference runtimes)
     as part of the work.

5. **Scaffolding rework mandate.** The wiring / reference-chains / guardrails /
   automation must be reworked so the loop is aimed at 完成形 and **cannot
   re-enter a release-march misframe.** This ADR + the ROADMAP / continue-skill /
   handover / CLAUDE.md edits in the same commit are the first installment;
   further drift found later is fixed under this mandate.

6. **Version / tag / cutover are deferred to an explicit future user decision.**
   Not `v0.1.0` by default; not on this branch by default; not by the loop.

## Consequences

- **ROADMAP Phase 16** is reframed from "Public release v0.1.0 🔒 (march)" to a
  **completion-finalization phase** (surface audits + dogfooding + debt + spec
  100%) whose "exit" is the 完成形 bar — with the actual release explicitly
  outside the loop. The 🔒 auto-release-gate framing is removed.
- **ROADMAP §1.1/§1.2** amended: the migration guide *exists* (it does not "ship
  at a release" the loop controls); the surface line is industry-standard-minimal
  + breaking-allowed, not v1-parity.
- **continue skill**: a frozen invariant — *the loop never performs or prepares a
  release; release is user-only.* No §16 hard-gate that auto-marches.
- **CLAUDE.md**: frozen-invariant + Identity updated (no autonomous release;
  completion-gated; version/cutover deferred).
- **Handover** rewritten to the new model.
- **No code is reverted** — the §16.1 migration guide is useful regardless and
  stays (it documents the breaking v1→v2 surface change, which is exactly what
  this ADR endorses). It will be revised as the surface-design audits land.

## Why this is the right shape

The project's inviolable design priority (ADR-0153, memory
`feedback_design_priority_completeness_over_v010`) already says 完成形 gates, not
the calendar. The failure this session was not the priority — it was the
scaffolding translating "Phase 15 done" into "march to a release tag." Removing
the release as an autonomous construct, and re-pointing the loop at the 完成形
bar across all surfaces, makes the steering match the philosophy. A rewrite that
is not yet a well-known library has the freedom to choose the *right* surface
(breaking v1) rather than carry v1's CLI sprawl; taking that freedom is the
あるべき論 judgment.
