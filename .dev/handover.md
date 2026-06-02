# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — committed to 100% (ADR-0128)** (Phase 9 = DONE
  2026-05-24). §10 exit requires the official Wasm 3.0 testsuite at pass=fail=skip=0
  on **both backends** (interp + JIT).
- **HEAD** (`2b48dfdc`): **D-235 RESOLVED — JIT `call_indirect` subtype acceptance** (ADR-0131
  ported to the JIT backend). JIT corpus: **gc/type-subtyping assert_trap 4 → 0**; assert_return
  **762/2/531** (no regression — was 761/3/531); Mac test-all + lint green. +2 RED tests
  (`runner_gc_test`: over-accept TRAPS, exact-match returns 7).
- **D-235 SHIPPED MECHANISM (deviated from the prep — two latent prep gaps)**: (1) JIT `setup.zig`
  also had to materialise gti for FUNC-only-subtyping modules (D-232 fixed only the interp
  `instantiate.zig`; setup still gated on `needs_gc_heap` → `gc_type_infos_ptr=null` → over-reject).
  (2) The prep's "trampoline on CMP-mismatch" was register-unsafe: a call spliced mid-`call_indirect`
  clobbers caller-saved regs holding the op's arg/idx operands. SHIPPED: store RAW typeidx in
  `typeidx_base` for subtyping modules; a `jitCallIndirectResolve(rt,table_idx,idx,expected)→funcptr|0`
  trampoline (bounds + `concreteReachesGti` + funcptr lookup) called BEFORE marshalling; operands
  force-spilled via regalloc inclusive crossing for `call_indirect` (`ZirFunc.uses_type_subtyping`,
  mirroring struct.new); arm64 stashes funcptr in X17, x86_64 re-derives inline (all-callee-saved pool).
  Non-subtyping byte-identical (gated). Lesson `2026-06-03-jit-trampoline-mid-op-clobbers-operands`.
- **Prior context**: interp wasm-3.0 corpus FULLY GREEN (D-232/ADR-0131, `d041e425`); level-sep audit
  (ADR-0130, D-230); ADR-0127 PHASE C (unlinkable 4→0). Two paths: spec corpus = interp by default,
  JIT opt-in `ZWASM_SPEC_ENGINE=jit` (default test-all unchanged); JIT entry = `runner.zig` `JitInstance`.
- **PER-MODULE blocker-STACK reality** (lesson `2026-06-02-jit-corpus-late-phase-is-per-module-blocker-
  stacks`): each remaining JIT-corpus module has 3-6 DISTINCT blockers; rejects at the FIRST. Big levers
  spent. The 4 type-subtyping over-accept funcs are themselves void/reftype-result → JIT-eligibility-
  skipped at the assert level, but the per-module `trap_fail` counter still flipped 4→0.
- **Watch**: `runner_gc_test.zig` 1476 (WARN, under hard 2000). `jit_abi.zig` 1350 (WARN).

## Active task — Phase 10 → 100% (ADR-0128)  **NEXT**

D-235 closes the JIT call_indirect-subtype gap. Remaining workstreams (non-§10-table-first):

1. **§10-scope question** → `.dev/phase10_scope_reassessment.md` — §10 exit vs Phase-14 deferral
   (multi-memory's 407 JIT skips ⇒ JIT skip=0 unreachable in Phase 10 as written). **USER-GATED**
   (ADR-0128-amendment = user-flip case). The bundle's last gated item — surface to user, don't self-decide.
2. **Non-gated JIT forward work**: **eh/try_table on JIT** (the 2nd of the original 2 return-fails;
   deeper — `codegen/{arm64,x86_64}/ops/wasm_3_0/throw*.zig` + `shared/exception_table.zig` +
   `shared/zwasm_throw.zig`); **D-234** (51 memory64 assert_trap = corpus-runner HARNESS artifact, codegen
   proven correct — runner-side fix); **D-198** (rec-group subtype), **D-209** (stale u32 offset check),
   **D-210** (cross-module proper-tail-call — arm64 prologue cohort-save).
3. **Realworld GC/EH/TC producers** (§5; flake.nix `#gen`): `wasm_of_ocaml` / `emcc -fwasm-exceptions` /
   `guile-hoot`.

## Active bundle

- **Bundle-ID**: `10.G-typesubtyping-RTT`. **D-235 CLOSED this turn** (`2b48dfdc`) — exit-condition met:
  JIT gc/type-subtyping assert_trap 4→0, no regression, Mac test-all green. Earlier in this bundle-chain:
  PHASE C (unlinkable 4→0, `add983e8`); .12/.14 global-init (`8d5d67ed`); .17 "run" interp (`80aeee1d`);
  interp D-232/ADR-0131 (`d041e425`); §1 multi-value +18.
- **Cycles-remaining**: ~1. **REMAINING = the §10-scope question ONLY (user-gated)**; the bundle CLOSES
  once §10-scope resolved. All JIT/interp type-subtyping correctness is now DONE (both backends).
- **Continuity-memo**: interp wasm-3.0 = 0 fails; JIT assert_return 762/2/531, gc/type-subtyping
  assert_trap 0. D-235 resolved. Non-gated forward = eh-on-JIT / D-234 runner fix / D-198 / D-210.
- **Exit-condition**: type-subtyping correct on both backends ✓ DONE. Only §10-scope (user-flip) remains.

## §10 remaining — the six `[ ]` rows

- **10.M** memory64 — corpus green; D-209 stale (payload u64; lift leftover u32 check); D-234 (51 OOB
  assert_trap = harness artifact, codegen proven correct).
- **10.R** function-references — JIT emit present, corpus green; residual = D-198.
- **10.TC** tail-call — JIT matrix complete; residuals = D-210 + `wasm_of_ocaml`.
- **10.E** EH — JIT emit present; residuals = **eh/try_table on JIT (return-fail)** + eh_frequency runner
  (I20), c_api tag accessors (I14 → Phase 13), emscripten_eh realworld (I21).
- **10.G** GC — JIT emit COMPLETE both arches; §1 JIT-corpus + PHASE C + **D-235 (call_indirect subtype)** DONE;
  remaining = D-198 + gc_stress (I19) + dart/hoot (I21).
- **10.P** close — flips only at 100% both-backends (ADR-0128).

## Step 0.7 (next resume)

THIS turn = D-235 EXECUTED (per the 2026-06-02 user directive — one focused pass, fresh clear session).
JIT call_indirect now does the gti subtype check; gc/type-subtyping assert_trap 4→0, no regression, Mac
test-all + lint green, +2 unit tests. ubuntu kick fired for `2b48dfdc` (verifies the **x86_64** emit path —
the resolve-trampoline + inline funcptr re-derive). Next resume Step 0.7: `tail -3 /tmp/ubuntu.log` —
expect `OK (HEAD=2b48dfdc)`; on FAIL the regression is x86_64-specific (likely the SysV arg-reg marshal in
`emitCallIndirect`'s subtyping block or the all-callee-saved-pool assumption) → investigate, don't blind-revert.
Mac aarch64; ubuntu = x86_64.

**Gate hygiene**: use `bash scripts/mac_gate.sh` for the Step-5 Mac gate (writes `/tmp/mac_gate.log`); never
`zig build test-all > log; grep -c …` (trailing `grep -c` exits 1 on zero matches → false failure). For the
JIT corpus, `zig build test-spec-wasm-3.0-assert` (NO bogus `-Dno-run` — it fails the build + reuses a STALE
exe, the `538/22/735` false-regression trap), then `ZWASM_SPEC_ENGINE=jit <freshest-exe> test/spec/wasm-3.0-assert --fail-detail`.

## Key refs

- **ADR-0131** (interp gti subtype; D-235 ports it to JIT); ADR-0128 (Phase 10 100% master plan);
  ADR-0116 (RTT 8-deep Cohen + subtype); ADR-0126 (canonical type ids); ADR-0060 (force-spill — D-235
  extends inclusive crossing to subtyping `call_indirect`). ROADMAP §10.
- Debt: **D-234** (51 memory64 assert_trap harness artifact — runner-side), D-198 / D-209 / D-210 / D-211 / D-212.
  Lessons: `2026-06-03-jit-trampoline-mid-op-clobbers-operands` (D-235),
  `2026-06-02-gti-tied-to-heap-need-misses-func-subtyping`,
  `2026-06-02-jit-corpus-fails-are-often-harness-artifacts`,
  `2026-05-31-spec-jit-corpus-fails-are-gaps-not-stale-state`.
