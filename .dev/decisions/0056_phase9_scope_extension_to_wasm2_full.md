# 0056 — Extend Phase 9 scope to "Wasm 2.0 (incl. SIMD) 100% PASS on Mac+OrbStack"

- **Status**: Accepted
- **Date**: 2026-05-12
- **Author**: zwasm v2 maintainer (autonomous `/continue` loop, Phase 9 close)
- **Tags**: phase-9, scope, wasm-2.0, spec-corpus, jit, bench, gate

## Context

ROADMAP §9.9 row text reads:

> `simd.wast` spec test wired in; fail=skip=0 across both backends
> (3-host gate). Sub-chunks 9.9-a..* recorded in
> [`.dev/phase_log/phase9.md`](../phase_log/phase9.md#row-99--simdwast-spec-test-wiring).

The literal reading is **SIMD-only** (`simd.wast`). The
autonomous loop and the §9.12 hard-gate wiring proceeded on that
literal reading. A user-driven audit (2026-05-12, three parallel
investigation agents X / Y / Z) surfaced **structural integrity
gaps** that make the literal reading insufficient as the Phase 9
exit gate:

### Discovery 1 — non-SIMD spec coverage is "fake green"

`test/spec/wast_runner.zig` (the `test-spec-wasm-2.0` driver,
covering the 1158-module Phase-2 curated corpus from ADR-0003)
performs **parse + validate only**. It does not execute any
`assert_return`, `assert_trap`, or `assert_invalid` directive at
runtime. The `1158 passed / 0 failed` headline is a typecheck
result, not a runtime conformance result.

In contrast, `test/spec/simd_assert_runner.zig` (the §9.9 SIMD
runner) does execute runtime assertions and reports
`13301 passed / 0 failed / 440 skipped` on Mac + OrbStack.

### Discovery 2 — JIT has ~14 hidden-skip Wasm 2.0 ops

Behind the fake-green non-SIMD coverage, both `arm64/emit.zig`
and `x86_64/emit.zig` dispatch tables fall through `else =>
UnsupportedOp` for: `ref.null`, `ref.func`, `ref.is_null`,
`table.get/set/size/grow/fill/copy/init`, `memory.init`,
`data.drop`, `elem.drop`, and `select_typed` (non-i32).

The interp implements all of these; the JIT does not. Spec
corpus does not currently exercise these ops at runtime (per
Discovery 1), so the gap is silent.

### Discovery 3 — spec corpus regression vs zwasm v1

v1 ran `run_spec.py --strict` over 265 corpora end-to-end with
runtime assertions. v2 vendors **30+ fewer non-SIMD wasts**
(missing: `bulk.wast`, `memory_copy.wast`, `memory_fill.wast`,
`memory_init.wast`, `data*.wast`, `elem*.wast`, `table_*.wast`,
`ref_*.wast`, typed `select.wast`) and **33 fewer SIMD wasts**
(missing: `simd_conversions`, `simd_f32x4` base,
`simd_load*_lane`, `simd_store*_lane`, `simd_i*_extadd_pairwise_*`,
`simd_i*_extmul_*`, `simd_i*_trunc_sat_*`, `simd_linking`,
`simd_memory-multi`, `simd_q15mulr_sat_s`, others). Total
**~7855 assert_return statements from v1 don't run on v2**.

ADR-0003 §"Consequences / Negative" anticipated this with:

> the §A10 release gate is partially deferred. Phase-5 ADRs
> widen the corpus as the analysis layer adds declaration-scope
> / init-expr / multi-param-block capabilities. **Phase 15 is
> the final corpus-completeness pass.**

But **ROADMAP §9.15 has no row** in the §9 task table tracking
this Phase-15 pass. The deferral lacks a tracking artifact —
the load-bearing claim "Phase 15 final corpus-completeness pass"
has no corresponding ROADMAP commitment.

### Discovery 4 — test-all wiring + bench script bugs

`build.zig:497-534`: `test-edge-cases`, `test-realworld-run-jit`,
`test-wasmtime-misc-runtime` are not wired into `test-all`. The
§9.7 / 7.9 "40+ realworld run-pass" exit criterion is
informally measured, never CI-gated.

`scripts/run_bench.sh:200-203`: scientific-notation parse bug
(`grep -oE '[0-9.]+'` fails on `8.31753e-06`, capturing
`8.31753` and producing `stddev_ms: 8317.53` — already in
committed `bench/results/history.yaml`). `record_merge_bench.sh`
is a TODO stub but advertised at ROADMAP §12.4. Schema drift
(README says `median_ms`, script writes `mean_ms`).

`test/realworld/run_runner_jit.zig:334`: catches
`error.UnsupportedImports` (plural) — **never raised anywhere**
in `src/` (actual code raises `UnsupportedImport` singular).
COMPILE-IMPORTS classification permanently 0.

ADR-0029 Path B `skip-impl == 0` gate documented as enforced
at chunk 9.9-h-23; actual runner code checks only `failed != 0`.

### Discovery 5 — user 2026-05-12 directive

> あるべき論として 100% を目指す原則、コストは問わない、今後の
> ためにきれいにしておく心掛けですべてを走らせてください。

The user explicitly raised the bar: "skip / workaround を
妥協しない、Wasm 2.0 + Wasm 2.0 SIMD を 100% にしたい
(まず Mac+OrbStack)". Discoveries 1-4 are mostly v1-floor
regressions or hidden gaps that a literal-narrow §9.9 close
would propagate into Phase 10+ as accumulating debt — exactly
the v1 W43/W44/W45 / W54 anti-pattern the v2 redesign exists
to avoid (ROADMAP §1, §2 P/A).

## Decision

Extend §9.9 scope from **"`simd.wast` runner green"** to
**"all Wasm 2.0 spec corpus (incl. SIMD) runtime-asserted PASS
+ JIT covers all Wasm 2.0 ops + test-all wiring complete + bench
infra clean, on Mac+OrbStack"**.

Specifically — the §9.9 row text is amended to:

> Wasm 2.0 (incl. SIMD) 100% PASS on Mac+OrbStack: all spec
> wasts runtime-asserted (vendored from upstream
> `WebAssembly/spec/test/core/` per ADR-0003 widen-trigger
> realised); JIT covers all Wasm 2.0 ops (no hidden-skip dispatch
> fallthroughs); test-all wires `test-edge-cases`,
> `test-realworld-run-jit`, `test-wasmtime-misc-runtime`; bench
> infra clean (no script bugs, no dead error paths, no schema
> drift); ADR-0029 Path B `skip-impl == 0` enforcement is real
> (gates the runner, not just narrative). windowsmini reconcile
> at phase boundary close (D-084 in flight per ADR-0055). Sub-
> chunks recorded in `phase_log/phase9.md`.

**ADR-0003 absorption clause**: the "Phase 15 final corpus-
completeness pass" referenced in ADR-0003 §"Consequences /
Negative" is **absorbed into Phase 9 close** (this ADR) for the
Wasm 2.0 corpus. Phase 15 retains responsibility for
post-Wasm-2.0 corpus widening (typed function references, GC,
EH, tail-call, threads, multi-memory) — which is consistent with
those features being Phase 10+ work scope. No new §9.15 row is
required; ADR-0003 § "Consequences / Negative" is amended in
place (Revision history) to point at this ADR.

### Implementation cohort (Phase 9 sub-chunks)

The expanded scope discharges via the following sub-chunks
(identifiers reserved; chunk numbering reflects landing order,
not dependency order):

- **9.9-i-1** — Win64 v128 marshal (D-084, in flight per
  ADR-0055, worktree agent W)
- **9.9-j-1** — this ADR + ROADMAP §9.9 row text update +
  ADR-0003 Revision history amendment
- **9.9-j-2** — test-all wiring + bench script fixes +
  dead-error fix
- **9.9-j-3a** — SKIP allowlist documentation (passive)
- **9.9-j-3b** — SKIP-gate real enforcement (last; gates blocked
  until upstream is clean)
- **9.9-k-1** — Wasm 2.0 non-SIMD spec wast vendor (~30 files
  from upstream)
- **9.9-k-2** — SIMD spec wast vendor (33 missing files)
- **9.9-l-1** — runner extension or new non-SIMD
  `spec_assert_runner` (new ADR `0057_non_simd_spec_runtime_runner.md`
  expected from the chunk's design step)
- **9.9-m-1** — JIT: ref.null / ref.func / ref.is_null (both
  arches)
- **9.9-m-2** — JIT: table.* full 7-op family (both arches;
  expected ~3000 LOC, may sub-split with own ADR `0058_*`)
- **9.9-m-3** — JIT: memory.init / data.drop / elem.drop (both
  arches)
- **9.9-m-4** — JIT: select_typed non-i32 (both arches)
- **9.9-n-1** — `shootout/fib2` perf root cause (41 s/run
  anomaly)

§9.9 row flips `[x]` only after all sub-chunks land AND 2-host
runtime-asserted spec coverage shows `failed = 0` AND
`skip-impl == 0` on Mac + OrbStack AND windowsmini reconcile
shows `failed = 0` on the Win64 path (per ADR-0055 D-084 close).

§9.12 (Phase 10 entry hard gate) waits for §9.9 [x]; its hard-
gate detector remains wired but does not fire while §9.9 is
[ ].

## Alternatives considered

### Alternative A — Close §9.9 literal-narrow (SIMD-only)

- **Sketch**: Flip §9.9 [x] now (Mac+OrbStack 13301/0/440 +
  windowsmini D-084 outstanding). Defer Discoveries 1-4 to
  Phase 10 / 11 / 15.
- **Why rejected**: v2 ROADMAP §1 / §2 P/A explicitly aim to
  avoid v1's W43/W44/W45 / W54 accumulating-deferral
  anti-pattern. "Fake-green" non-SIMD spec coverage propagated
  to Phase 10 entry would mean Phase 10's design ADRs (memory64
  / tail-call / EH / GC) are scoped on top of an
  unverified-runtime base layer. The cost of catching a Phase-2
  validator gap during Phase-10 implementation is structurally
  higher than catching it now. User directive 2026-05-12 also
  rejects this path explicitly.

### Alternative B — Defer to Phase 11 (WASI + bench infra cohort)

- **Sketch**: Bundle Discoveries 1-4 with D-074 Phase-11
  bench-infra cohort (since some items — `compare_runtimes.sh`,
  cross-runtime compare, toolchain pinning — already are Phase
  11 work).
- **Why rejected**: Discoveries 1-3 (spec coverage, JIT ops,
  spec corpus regression) are structurally Phase 9 concerns
  (Wasm 2.0 completion). Phase 11 (WASI 0.1 + bench infra) has
  no relationship to JIT op completion or spec runner shape.
  Bundling muddles review rationale and delays the Wasm 2.0
  "done" claim 2 phases.

### Alternative C — File a new §9.13 row in §9 task table

- **Sketch**: Leave §9.9 narrow; add §9.13 row "Wasm 2.0 full
  PASS extension" tracking the cohort separately.
- **Why rejected**: Two rows for the same conceptual phase
  scope (Wasm 2.0 = SIMD + non-SIMD) split the close gate
  artificially. The §9.9 row text already names the spec gate;
  amending it is cleaner than introducing parallel rows. Avoids
  §9 renumber concerns per ADR-0014.

## Consequences

- **Positive**:
  - Phase 9 close becomes a real Wasm 2.0 completion claim, not
    a SIMD-only claim with hidden non-SIMD regressions.
  - The ~14 JIT hidden-skip ops surface during Phase 9 close
    rather than during a Phase 10 EH/GC/tail-call/memory64
    design ADR where they'd derail scope.
  - ADR-0003's Phase-15 corpus deferral is honoured (the
    widening trigger fires now, with a tracking artifact).
  - Bench script bugs leave history.yaml within the same phase
    that introduced them; corruption is bounded.
  - Sets a precedent for Phase 10+ that "complete" means
    runtime-asserted + JIT-complete + test-all-wired, not
    parse+validate-only.
- **Negative**:
  - Phase 9 expands by ~10-15 chunks / ~5000-10000 LOC of new
    JIT op implementations + runner extension + vendor work +
    bench script fixes. Phase 9 close timeline extends
    proportionally.
  - The §9.12 Phase 10 entry hard gate cannot fire until the
    extended §9.9 closes; Phase 10 entry is delayed.
- **Neutral / follow-ups**:
  - `0057_non_simd_spec_runtime_runner.md` expected — runner
    architecture choice between extending `wast_runner.zig` vs
    factoring out a shared `spec_assert_runner_base.zig` with
    SIMD / non-SIMD specialisations.
  - `0058_jit_table_ops.md` likely — table.* implementation
    spans both backends and ~3000 LOC; deserves its own
    architectural ADR for funcref `Value` extension, indirect
    call typecheck interaction, etc.
  - bench `history.yaml` historical contamination — option (a)
    delete affected entries vs (b) annotate as "tool-bug-
    affected"; decided in 9.9-j-2 chunk body.
  - v1-exceed work (c_simd realworld vendored + wired as real
    realworld-SIMD-gate) is **out of scope of this ADR**;
    remains Phase 11 D-074 cohort per Track A.

## References

- ROADMAP §1, §2 (P / A), §9.9 — phase scope this ADR amends
- ROADMAP §11 — test data policy (vendored verbatim, upstream
  commit pinned)
- ROADMAP §A10 — spec test fail=0 / skip=0 release gate
- ADR-0003 — Phase-2 corpus curation (this ADR amends ADR-0003
  Revision history to mark the deferred Phase-15 pass as
  absorbed into Phase 9 close)
- ADR-0014 — no §9 renumber discipline (preserved: §9.9 row
  text is amended in place)
- ADR-0029 — Path B skip vocab (this ADR's `9.9-j-3b` realises
  the skip-impl == 0 gate as code, not just narrative)
- ADR-0041 / ADR-0046 / ADR-0049 / ADR-0054 / ADR-0055 —
  upstream Phase 9 design ADRs preserved
- `.dev/debt.md` D-084 (Win64 v128 marshal, in flight)
- Investigation reports (gitignored, kept for traceability):
  - `private/p9-x-wasm2-non-simd-coverage.md` (Agent X, 758
    lines)
  - `private/p9-y-tests-bench-audit.md` (Agent Y, 30-item
    punch list)
  - `private/p9-z-realworld-v1-parity.md` (Agent Z, 628 lines)

## Revision history

| Date       | SHA          | Note                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
|------------|--------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-12 | `171bbd36` | Initial. Extends §9.9 scope to full Wasm 2.0 100% PASS on Mac+OrbStack; absorbs ADR-0003's deferred Phase-15 corpus-completeness pass for Wasm 2.0; enumerates 9.9-i/j/k/l/m/n sub-chunk discharge plan.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| 2026-05-17 | `2e27cfeb` | Re-interprets `skip-impl == 0` exit predicate as **literal 0 across 4 categories** on Mac+OrbStack+windowsmini per [`ADR-0065`](0065_wasm_1_0_instance_work_phase9_rescope.md): Cat I validator/parser (already 0), Cat II multi-result entry helpers (~1400 → 0), Cat III Wasm 1.0 instance / store / linker / cross-module / host-imports / start-trap (144 → 0; absorbed from Phase 10 per ADR-0065), Cat IV Windows SEH bridge (windowsmini batch-end sweep at Phase 9 close per ADR-0049). Driver: 2026-05-17 user-confirmed correction that Cat III is Wasm 1.0 base-spec scope, mis-classified as "Phase 10+ instance-aware runtime" in the original §9.9 row. Cohort §9.9-o (Cat II multi-result), §9.9-p (Cat III instance work), §9.9-q (Cat IV windowsmini reconcile sweep) added; chunk IDs assigned at landing time per ADR-0014 no-renumber discipline. windowsmini per-chunk gate remains deferred per ADR-0049; Phase-boundary reconcile is the Cat IV batch step. See [`.dev/phase9_close_plan.md`](../phase9_close_plan.md) for the executable playbook.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| 2026-05-18 | `86fad986` | **Cat IV position-shift (NOT predicate-loosening)** per user 2026-05-18 confirmation. The 4-category `skip-impl == 0 literally` predicate is **preserved**, but Cat IV (windowsmini reconcile sweep) moves OUT of §9.9 close gate INTO a dedicated row §9.13-0 (between §9.12 substrate audit hard-gate and §9.13 Phase 10 entry hard-gate). §9.9 close exit predicate = Cat I + Cat II + Cat III on **Mac + ubuntunote** at literal 0; windowsmini bit-identical verification is gated at §9.13-0 (still required for Phase 10 entry). Rationale: §9.12 substrate audit may amend Phase 9 scope retroactively (e.g., D-094/D-140 indirect-result-ptr cohort scope decisions); running Cat IV reconcile BEFORE the cleanup risks duplicate work + wasted windowsmini cycles. The 3-host invariant is preserved across §9.9 → §9.12 → §9.13-0 → §9.13 — split across rows, NOT loosened. ADR-0049 Revision-history 2026-05-18 row pairs this. |
