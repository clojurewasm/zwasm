# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS** (Phase 9 = DONE 2026-05-24). Real remaining work is
  enumerated below — Phase 10 is **NOT close-ready**. (The prior "substantially
  complete" framing was interp-only optimism; corrected by the 2026-05-30 user audit.)
- **HEAD**: `<this-commit>` (cyc243 wiring audit). cyc232-242 landed + ubuntu-verified:
  cross-module `return_call`, EH×TC, D-202 PHASE A + B-finality, ADR-0127 draft.
- **Two execution paths (CODE-verified, not doc prose)**: the spec corpus runs via the
  **INTERPRETER** (`instance.invoke` → `_dispatch.run`, `src/zwasm/instance.zig:169`).
  The **JIT** is a separate surface (`runI32Export` / `test-realworld-run-jit`).
  - JIT **emits**: Wasm 1.0/2.0 + tail-call + function-references + **EH**
    (`codegen/{arm64,x86_64}/ops/wasm_3_0/`: `return_call*`, `br_on_null*`,
    `ref_as_non_null`, `call_ref`, `throw`, `throw_ref`, `try_table`).
  - JIT does **NOT** emit **GC** (no `struct*`/`array*`/`ref_cast`/`ref_test`/`i31*`
    file) → GC is interp-only. The headline gap: **D-211**.
- **Corpus**: multi-mem 407/244/2 green; the gc corpus carries D-198/D-202 residuals
  (invariant I2 excludes gc/func-refs by design).
- **10.P**: 16 PASS / **8 SKIP** / 0 FAIL. The 8 SKIPs are DEFERRED deliverables, each
  mapping to a residual below. "Close-eligible" = no FAIL; it is NOT "no work left".

## §10 remaining — the six `[ ]` rows (精査)

- **10.M** memory64 — corpus green; residual = **D-209** (>4 GiB static offset; `payload`
  u32; deferred — ZirInstr layout change).
- **10.R** function-references — JIT emit present, corpus green; residual = **D-198**
  (iso-recursive rec-group structural subtype validation).
- **10.TC** tail-call — JIT matrix complete (direct/indirect/ref, both arches);
  residuals = **D-210** (cross-module PROPER tail-call — arm64 prologue cohort-save; the
  current cross-module `return_call` is call-and-return, so deep cross-module mutual
  recursion grows the native stack) + `wasm_of_ocaml` capstone (toolchain).
- **10.E** EH — JIT emit present (`throw`/`try_table`); residuals = eh_frequency runner
  deep content (I20) + c_api tag accessors (I14 → Phase 13 type-reflection) +
  emscripten_eh realworld (I21 → toolchain).
- **10.G** GC — **JIT emit ABSENT (D-211, headline)** + **D-202 PHASE C** (ADR-0127; 4
  `gc/type-subtyping` assert_unlinkable wrongly link) + D-198 + `.17` (deferred) +
  gc_stress runner content (I19) + dart/hoot realworld (I21 → toolchain).
- **10.P** close — the 8 SKIP invariants above; flips when their criteria land or are
  explicitly re-scoped.

## Active task — GC-on-JIT bundle (D-211)  **NEXT**

The single biggest remaining Wasm-3.0 JIT deliverable, and **required by the §10 exit
criterion** ("all proposals' spec tests pass on BOTH backends"). First chunk: Step-0
survey of the regalloc safepoint requirement (heap-ref / i31 live values must survive a
GC-alloc call that clobbers caller-saved and may move refs → spill/reload across
safepoints + ref stack-maps — invariant I16), then the simplest emit (arm64 `struct.new`
/ `struct.get`) with a `runI32Export` struct-round-trip red test. Multi-cycle → bundle.

The six §10 `[ ]` rows are **parallel proposal tracks, not a sequence** — the Active task
is value/exit-criterion-prioritized (10.G), NOT the table-first `[ ]` 10.M (whose only
residual D-209 is deferred). Do not let Resume Step-1's "trust ROADMAP first `[ ]`" route
the loop to 10.M; the handover Active task is authoritative for the next chunk here.

**Queue (names only)**: D-202 PHASE C (after ADR-0127 Accept) · D-210 (cross-module
proper-tail-call) · D-198 (rec-group subtype) · eh_frequency / gc_stress runner content.

## User touchpoints (parallel — the loop works the Active task, does NOT stop on these)

- **ADR-0127** `Proposed → Accept` gates the **D-202 PHASE C** impl only (cross-module
  func import type-identity; needs a cross-`Types` `canonicalEqual`). Not a phase blocker.
- **Phase-10 exit-criterion consistency** (design finding): §10 exit says "all
  proposals' spec tests pass on BOTH backends", but GC has no JIT emit (D-211) AND the
  spec corpus runs interp-only (`instance.invoke`), so "both backends" is unmet +
  unverified for GC — while close-invariant I16 SKIPs it ("close-eligible" papers over
  the gap). Resolve by implementing GC-on-JIT (the Active task), or by an ADR amending
  the §10 exit criterion to accept GC-interp-only (a §9-scope deviation, needs the ADR
  first). Default per the user audit: implement.

## Step 0.7 (next resume)

cyc239 PHASE B-finality (`a4bd9bbb`) ubuntu-verified `OK (HEAD=64b27118)`. cyc240-243 are
docs/wiring-only → no ubuntu pending, no revert.

## Key refs

- ROADMAP §10 (10.M/R/TC/E/G/P `[ ]`). Debt: D-198 / D-202 / D-209 / D-210 / **D-211**.
- ADR-0066 (bridge thunk); ADR-0112 + Amendment 2026-05-30 (cross-module TC =
  call-and-return); ADR-0127 (Proposed; D-202 PHASE C); `abi_callee_saved_pinning.md`.
- Lessons `2026-05-30-{phase10-jit-coverage-partial-spec-corpus-interp,
  cross-module-tail-call-cohort-asymmetry, stale-debt-rows-misroute-the-loop,
  clang-wasm-realworld-toolchain-recipe}`; `.dev/phase_log/phase10.md`.
