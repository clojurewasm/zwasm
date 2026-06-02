# JIT spec-corpus "fails" are repeatedly harness artifacts, not codegen bugs

2026-06-02 (D-233, D-234). Under `ZWASM_SPEC_ENGINE=jit` the wasm-3.0 spec runner
reported assert failures that, on investigation, were the test HARNESS
mis-evaluating CORRECT JIT behaviour — twice in one session, costing ~8 cycles of
codegen debugging on bugs that don't exist:

- **D-233** (`ref_cast_null` ×4 + others): jit-mode `assert_trap` was evaluated on
  the stale INTERP instance (the setup `(invoke)` action only populates `cur_jit`),
  so the trap funcs read empty state → no trap → "fail". The JIT was fine.
- **D-234** (memory64 OOB ×51): exposed when D-233's fix routed assert_trap through
  `cur_jit`. mem64 OOB `i32.load` was PROVEN to trap correctly via FIVE isolated
  paths (const `runI32Export`; i64-param `runScalar1Export`; the exact
  `JitInstance.init`→`initLinked`→`setupRuntimeLinked` constructor the corpus uses,
  single / 3× / in-bounds-then-OOB). Not reproducible outside the full corpus run →
  a persistent-`cur_jit` / full-module evaluation artifact, not codegen.

Both follow the same shape as the level-separation findings
(`detection-without-enforcement-dead-gate`, `gti-tied-to-heap-need`,
`jit-mode-assert-trap-evaluates-on-interp-instance`): **the mechanism (codegen)
was correct; the wiring/evaluation (harness) was the gap.** The interp wasm-3.0
corpus is fully green and the JIT is in much better shape than the raw
`ZWASM_SPEC_ENGINE=jit` fail count implies.

**Rules:**

1. **Before debugging codegen for a `ZWASM_SPEC_ENGINE=jit` assert fail, reproduce
   it via a MINIMAL isolated `JitInstance.init(bytes)` + `invoke`** (a hand-rolled
   2-section module + a `runI32Export`/`runScalar1Export`/JitInstance unit test). If
   it passes/traps in isolation, the corpus number is a harness artifact — go audit
   the runner's per-assert evaluation (which engine/instance, setup-state target,
   cur_jit reuse), NOT `op_*.zig`.
2. The runner's JIT corpus evaluation is **systematically incomplete** (assert_trap
   was a no-op until D-233; cur_jit reuse mis-reports state-independent traps). A
   raw jit-mode fail/skip count is NOT the true JIT gap count until the harness eval
   is audited. Weight a corpus-runner audit over per-op codegen chasing.
3. An in-runner "re-invoke on a fresh JitInstance" probe SEGVs on import-bearing
   modules (a naive `JitInstance.init` can't resolve imports → crash). Guard such a
   probe to no-import modules, or isolate the single fixture, before running it
   corpus-wide.
4. The "5 isolated paths all pass" pattern is decisive evidence: stop adding paths
   and conclude harness-artifact; the marginal probe has near-zero yield once the
   shared codegen is exercised through the production constructor.

**CORRECTION (same day, D-235):** the rule cuts BOTH ways — don't over-generalize
"harness artifact" either. The 4 gc/type-subtyping assert_trap fails were initially
lumped in as harness, but they are REAL: the JIT `call_indirect` "canonical" is D-111
`canonicalTypeidx` (`funcTypeEql`, params/results only — FINALITY-BLIND), so
`(sub (func))` and `(sub final (func))` collapse to one canonical → CMP matches →
wrongly accepts a should-trap call. The error was assuming "canonical-exact compare"
preserves type identity without READING `canonicalTypeidx`. **Rule 5: when reasoning
about a "canonical"/"exact"/"equal" check, read the actual canonicalization/equality
function and confirm it preserves the distinction you care about (finality, subtyping,
identity) — a "canonical" id is only as fine-grained as its equality relation.**
