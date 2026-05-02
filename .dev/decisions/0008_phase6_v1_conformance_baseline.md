---
name: 0008 — Insert Phase 6 (v1 conformance baseline) before any JIT phase
date: 2026-05-02
status: Accepted
tags: phase-6, v1, conformance, regression
---

# 0008 — Insert Phase 6 (v1 conformance baseline) before any JIT phase

- **Status**: Accepted
- **Date**: 2026-05-02
- **Author**: Claude (autonomous /continue loop, on user direction)
- **Tags**: phase-6, v1, conformance, regression

## Context

The Phase plan (ROADMAP §9) ramps from correctness substrate
(Phases 0–5) directly into JIT (old Phase 6 = JIT v1 ARM64
baseline). zwasm v1 ships a substantial test + bench + realworld
asset base (~50 realworld WASI samples, ClojureWasm guest set,
v1's own regression tests, bench history rows tied to
W43/W44/W45/W54-class optimisation work). The v0.1.0 commitment
(§1.2) is parity with v1's interp-observable behaviour, but
**no phase currently establishes "what fraction of v1-passing
artefacts pass under v2 interp"** before JIT machinery starts
adding W54-class lattice complexity.

Without that gate:

1. The first place a v1 ↔ v2 behavioural divergence shows up is
   inside JIT differential testing (Phase 7+ in the new
   numbering), where it must be triaged across three orthogonal
   suspects: missing v2 interp op, missing JIT op, regalloc bug.
   This is exactly the W54 post-mortem failure mode the v2
   redesign exists to prevent (P14, `no_workaround.md`).
2. The 30+ realworld diff target ADR-0006 deferred from Phase 4
   (now §9.4 / 4.10) has no natural Phase to land in — it
   currently lives at §9.5 / 5.7-5.9 inside the analysis-layer
   phase, which is thematically wrong (analysis layer ≠ broad
   conformance sweep).
3. Phase 14 → 15 (Performance parity with v1 + ClojureWasm
   migration) implicitly assumes "v1's correctness baseline
   already passes; we're only matching speed". That assumption
   is currently un-gated.

The v1-conformance-before-JIT discipline is also not the kind of
constraint an ADR alone surfaces. It is a *temporal invariant*
("done before X starts") that must be encoded in phase order to
be enforced — it cannot live solely in narrative.

## Decision

A new **Phase 6 — v1 conformance baseline** is inserted between
the existing Phase 5 (ZIR analysis layer) and the existing Phase
6 (JIT v1 ARM64 baseline). All downstream phases shift by +1:

| Old number  | Phase                                              | New number   |
|-------------|----------------------------------------------------|--------------|
| —           | **v1 conformance baseline** (NEW)                  | **Phase 6**  |
| Phase 6     | JIT v1 ARM64 baseline                              | Phase 7      |
| Phase 7     | JIT v1 x86_64 baseline                             | Phase 8      |
| Phase 8     | SIMD-128                                           | Phase 9      |
| Phase 9     | GC, EH, Tail call, memory64                        | Phase 10     |
| Phase 10    | WASI 0.1 full + bench infra                        | Phase 11     |
| Phase 11    | AOT compilation mode                               | Phase 12     |
| Phase 12    | C API full (wasm-c-api conformance) 🔒            | Phase 13     |
| Phase 13    | CI matrix infrastructure                           | Phase 14     |
| Phase 14    | Performance parity with v1 + ClojureWasm migration | Phase 15     |
| Phase 15    | Public release v0.1.0 🔒                          | Phase 16     |

The new Phase 6 carries:

- **Goal**: enumerate exactly which of v1's correctness-bearing
  artefacts (regression tests, realworld guest set, ClojureWasm
  guest set) fail under v2 interp, and bring them all to green
  *with no JIT or local-optimisation complexity in scope*.
- **Exit criterion** (sketch; expanded in the §9.6 task table at
  phase open):
  - `test/v1_carry_over/` — vendor v1's regression tests that
    aren't already covered by spec testsuite; fail=0.
  - All 50 realworld samples (Mac + Linux) run to completion;
    30+ match `wasmtime run` byte-for-byte stdout (absorbing the
    target ADR-0006 deferred from Phase 4).
  - ClojureWasm guest set runs end-to-end against zwasm v2 via
    `build.zig.zon` `path = ...`; no commits to ClojureWasm side.
  - `bench/baseline_v1_regression.yaml` records interp-only
    wall-clock numbers (absolute speed irrelevant — these are
    the comparison floor for Phases 7-15).
- **🔒 platform gate**: yes. Phase 7 (JIT) cannot open until
  Phase 6 is `DONE`.

§A (axioms) gains **A13**: "v1 regression suite stays green from
Phase 6 onward". The differential gate (A5, P12) operates on top
of this baseline through the JIT phases, so any
v1-passing-but-v2-interp-failing case is caught at its origin
(missing op or wrong op semantics) rather than as a JIT mismatch.

§9.5's task rows 5.7-5.9 (realworld conformance) move to the new
§9.6 (renumbered as 6.1-6.3); §9.5 / 5.10 and 5.11 (audit, open
next) renumber to 5.7 and 5.8. ADR-0006's "Phase 5" forward-
references retarget to Phase 6.

All ROADMAP narrative, scripts, source comments, rules, skills,
handover, and ADRs that reference old Phase numbers 6–15 shift
by +1.

## Alternatives considered

### Alternative A — Add as final tasks of Phase 5

- **Sketch**: append the v1-conformance work to §9.5 as
  5.7-5.12, keep "Phase 5" name.
- **Why rejected**: thematically wrong (analysis layer ≠
  conformance sweep); Phase 5 grows unbounded; the
  "before JIT" invariant becomes one task row among many — easy
  to skip into Phase 6 (JIT) before it lands.

### Alternative B — Add as first tasks of (old) Phase 6 / JIT

- **Sketch**: §9.6 / 6.0-6.4 = v1 conformance, then JIT body
  starts at 6.5+.
- **Why rejected**: same phase boundary at exit, but the
  JIT-substrate work (regalloc, vcode, prologue/epilogue) bleeds
  into the conformance window because they share the §9.6 cadence.
  W54-class lessons specifically warn against mixing correctness
  baseline establishment with optimisation substrate work.

### Alternative C — Do nothing; rely on Phase 14 → 15 (parity)
to catch v1-vs-v2 divergences

- **Sketch**: when Phase 15 (parity + ClojureWasm migration)
  opens, exhaustive v1 comparison happens then.
- **Why rejected**: by Phase 15, JIT, AOT, SIMD, and Wasm 3.0
  features have all landed. A v1-vs-v2 divergence at that point
  has 5+ orthogonal suspects. Diagnosing it requires bisecting
  through optimisation lattice — exactly the W54 trap.

### Alternative D — Let it be a §A axiom only, no dedicated phase

- **Sketch**: codify "v1 regression suite stays green from Phase
  6 onward" as A13; trust each phase to maintain it.
- **Why rejected**: an axiom is an invariant; you still need a
  phase that *establishes* the green baseline in the first place.
  Without it the axiom has no anchor.

## Consequences

- 11 phases (current 6–15, plus new 16) shift by +1. The
  renumber is mechanical but spans `~/.dev/ROADMAP.md`,
  `.dev/proposal_watch.md`, `.dev/windows_ssh_setup.md`,
  `.dev/orbstack_setup.md`, `.dev/decisions/0002_*.md`,
  `.dev/decisions/0003_*.md`, `.claude/rules/*.md`,
  `.claude/skills/continue/SKILL.md`, `scripts/*.sh`,
  `src/ir/*.zig`, `src/interp/dispatch.zig`, and `handover.md`.
  Single commit lands the renumber + the new Phase 6 + the new
  axiom A13 + the §9.5 task-list reshuffle, referencing this ADR.
- §9.5 / 5.7-5.9 move to §9.6 / 6.1-6.3 and are removed from
  §9.5. §9.5 / 5.10-5.11 renumber to 5.7-5.8.
- Handover updates the "next [ ]" pointer to keep matching the
  renumbered §9.5 task table. The current in-flight task
  (§9.5 / 5.0 chunk c) is unaffected (5.0 stays at 5.0).
- The c_api_lib.zig / scripts/ that mention `p10`, `p11`, etc as
  commit-scope hints shift accordingly. Existing commits keep
  their `p2` / `p3` / `p4` / `p5` scope tags as historical
  record (no rewriting).
- The Phase Status widget gains a new Phase 6 PENDING row. The
  widget retains its "exactly one IN-PROGRESS at a time" rule,
  so Phase 5 closure now opens Phase 6 (v1 conformance), not the
  old Phase 6 (JIT).

## References

- ROADMAP §1.2 — v0.1.0 = parity with zwasm v1.
- ROADMAP §P10 — v1 stays untouched, but is not copied.
- ROADMAP §P12 — differential testing is the oracle.
- ROADMAP §P14 — optimisation lands last; W54-class lessons.
- ROADMAP §A5 — differential test gates every wasm-execution
  test (Phase 7+ in the new numbering).
- ADR-0006 — defers the "30+ realworld" target from §9.4 / 4.10
  to "Phase 5" (retargeted to Phase 6 by this ADR).
- `.claude/rules/no_workaround.md` — anti-pattern catalog from
  the v1 W54 post-mortem.
