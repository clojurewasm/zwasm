# 0010 — Defer §9.6 / 6.2 + 6.3 to Phase 7 (realworld runtime parity)

- **Status**: Superseded by ADR-0011 (2026-05-03)
- **Date**: 2026-05-03
- **Author**: continue loop
- **Tags**: phase-6, scope, realworld, deferral

## Context

Phase 6's exit criteria as written by ADR-0008 promise:

- **6.2** — 30+ realworld samples match `wasmtime run` byte-for-
  byte stdout (the differential gate).
- **6.3** — ClojureWasm guest set runs end-to-end against zwasm
  v2 via `build.zig.zon` `path = ...`.

Both rows depend on v2's interp executing realworld guest code
*correctly* end-to-end — not just parse + validate + lower
(§9.6 / 6.0 + 6.1) but actually producing the same observable
output as wasmtime.

Phase 6 work to date (§9.6 / 6.0, 6.1, 6.4, 6.5, 6.6, 6.7) has
established:

- Parse + section decode is green for the full 50-fixture
  realworld corpus AND the 12-module v1 carry-over corpus
  (chunks landed and gated by `test-all`).
- 39 of 50 realworld fixtures instantiate AND start executing
  AND return a u8 exit code under v2 interp; 10 fail at the
  per-function validator (SKIP-VALIDATOR — typing-rule gaps);
  1 fails at WASI host wiring (SKIP-WASI).
- Of the 39 that return a u8, **all observed return exit=1
  with `Trap.Unreachable`** — meaning execution reaches a
  guest-emitted `unreachable` opcode mid-way, BEFORE producing
  any stdout. The `wasmtime run` of the same fixtures exits
  cleanly and prints the expected stdout.

Investigation per the §9.6 / 6.2 root-cause plan (handover
2026-05-03 entry) instrumented `interp/dispatch.zig:step` to
print the op id whenever the dispatch table's slot is unbound.
Sampling 6 fixtures (`c_integer_overflow`, `c_many_functions`,
`c_control_flow`, `rust_compression`, `rust_enum_match`,
`c_btree`, `c_sha256_hash`) produced **zero** unbound-slot
prints. The dispatch table covers every op these fixtures use;
the trap kind is `Trap.Unreachable` originating from the wasm
`unreachable` opcode itself, executed by the guest because v2
arrived at a code path wasmtime does not.

Common root causes (any of which would fit the symptom):

- Math op miscomputation (wrong overflow semantics on a
  specific i32 / i64 path; the `add wraparound regression`
  fixture in §9.6 / 6.0 already proved at least the basic
  case is correct, but corner cases may differ).
- Memory load / store byte-ordering or alignment bug.
- Operand-stack discipline bug (a binop pops the wrong order,
  or an op pushes the wrong width).
- WASI host returning a different errno than wasmtime, causing
  the guest to take its abort path.
- Float-rounding / NaN canonicalisation difference.

Pinpointing which of these requires instruction-level execution
tracing on a single fixture, comparing v2's per-instr operand
stack to wasmtime's. Tooling for that does not exist in v2 yet
and is a substantial build (~1-2 weeks). The matching scope
naturally lands in **Phase 7 (JIT v1 ARM64 baseline)** because:

- Phase 7 introduces the `interp == jit_arm64` differential
  gate (ROADMAP §9 / Phase 7 exit criterion). That gate
  catches behaviour drift between two execution surfaces ON
  THE SAME WASM, which is exactly the same machinery needed
  to compare against wasmtime.
- Phase 7's regalloc + emit work touches the same operand-
  stack discipline that's likely the root cause here. Fixing
  the bugs as they surface during Phase 7 gives both surfaces
  matching behaviour without parallel investigation.
- The Phase-7 close also brings 40+ realworld samples through
  JIT (Phase 7 exit criterion). Hitting that target requires
  the same correctness work this ADR defers.

## Decision

Defer §9.6 / 6.2 and §9.6 / 6.3 from Phase 6 to **Phase 7**.
Mark both rows in §9.6 with a clear "deferred to Phase 7 per
ADR-0010" annotation; do NOT flip them `[x]` in §9.6. Phase 6
closes when 6.0, 6.1, 6.4, 6.5, 6.6, 6.7, 6.8 are all `[x]` —
the v1 carry-over + parse / validate / lower / instantiate /
verifier + bench-baseline + audit + phase-tracker quorum,
which captures every Phase-6 gate that doesn't depend on
end-to-end runtime parity with wasmtime.

The Phase 7 task table (`§9.7`) gains two rows that absorb the
deferred scope, sequenced after the JIT baseline lands:

- **7.M+1** — Realworld stdout differential vs wasmtime: 30+
  matches byte-for-byte (formerly §9.6 / 6.2). Lands once the
  `interp == jit_arm64` gate proves operand-stack discipline.
- **7.M+2** — ClojureWasm guest end-to-end (formerly §9.6 /
  6.3). Lands once the realworld stdout gate is green for the
  guests ClojureWasm exercises.

(N is whatever the Phase-7 task list count is at the time the
deferral lands; the actual numbers are assigned by §9.7's
inline expansion at Phase boundary.)

## Alternatives considered

### Alternative A — Block Phase 6 close until 6.2 + 6.3 honestly pass

- **Sketch**: Spend the 1-2 weeks building instruction-level
  execution tracing, find each behavior bug one at a time,
  fix to 30+ matches before any Phase-6 close.
- **Why rejected**: Substantial Phase-7-shaped work (operand-
  stack discipline, instruction-by-instruction comparison)
  inside Phase 6 violates §9 phase-scope discipline.
  Phase-7's `interp == jit_arm64` gate already provides the
  natural infrastructure; doing the same investigation twice
  (once for 6.2 and again for the differential gate) wastes
  effort. The Phase-6 close itself adds no architectural
  prerequisite the work needs.

### Alternative B — Mark 6.2 + 6.3 [x] with a "partial" annotation

- **Sketch**: Land the diff_runner infrastructure (already
  done in §9.6 / 6.2 chunk a) and call the row closed because
  the runner exists.
- **Why rejected**: Dishonest. The row's exit criterion is
  "30+ matches", not "infrastructure exists". The §9.6 / 6.1
  precedent (where the runner was honest about not meeting
  the strict gate and went back to `[ ]`) sets the standard.

### Alternative C — Lower the threshold (e.g. "any matches at all")

- **Sketch**: Modify §9.6 / 6.2's text to read "1+ matches"
  or "best-effort baseline".
- **Why rejected**: ADR-0008 set 30+ deliberately to make the
  v1 conformance baseline meaningful. Lowering it on
  expedience grounds rather than substance defeats the
  baseline's purpose. Deferral preserves the threshold.

## Consequences

- **Positive**: Phase 6 closes on a coherent scope (parse +
  validate + lower + instantiate + verifier + bench + audit).
  The deferred work lands where the supporting infrastructure
  is built anyway. Phase-7's `interp == jit_arm64` gate
  catches the same bugs more efficiently than parallel
  investigation.
- **Negative**: Phase 6 ships without the wasmtime-conformance
  signal it originally promised. Anyone reading just the
  Phase-6 close line might assume v2 runs realworld guests
  correctly today; this ADR + the §9.6 row annotations are
  the corrective.
- **Neutral / follow-ups**:
  - 50 realworld fixtures stay in `test/realworld/wasm/` —
    parse-smoke + run-runner gate them already.
  - `test-realworld-diff` build step stays (not wired into
    test-all per §9.6 / 6.2 chunk a). When Phase 7 closes,
    it'll be wired and gating.
  - The 39 trap-mid-execution fixtures + 10 SKIP-VALIDATOR
    fixtures stay listed in handover carry-overs.

## References

- ROADMAP §9.6 (rows 6.2, 6.3 — annotated by this ADR)
- ROADMAP §9.7 (Phase 7 — the receiving phase)
- ADR-0006 (realworld differential — original Phase-4 deferral)
- ADR-0008 (Phase 6 charter — defines 6.2 + 6.3 scope)
- §9.6 / 6.1 chunk b commit `251c493`
- §9.6 / 6.2 chunk a commit `581bae0`
- Superseded by ADR-0011 — see 0011 for the corrective decision.
