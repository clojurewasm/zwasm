# Phase 10 JIT coverage is PARTIAL — the spec corpus runs via interp, the JIT does not cover GC

**Date**: 2026-05-30 (cyc243 audit, user-requested)
**Citing**: `1f35d08d`; ROADMAP §10 (10.G/10.E/10.P `[ ]`); invariant I16
**Keywords**: Phase 10, JIT, interp, wasm-3.0, GC, op_gc, spec corpus, instance.invoke,
_dispatch.run, runI32Export, check_phase10_close_invariants, SKIP-vs-FAIL, close-eligible,
10.P, over-optimism, scope verification

## Observation

A user asked for evidence that "Phase 10 covers Wasm 3.0 INCLUDING the JIT, with no
residuals, in a should-be design." Verifying the CODE (not the ROADMAP/handover prose)
showed all three are NOT yet true:

- **The spec corpus runs via the INTERPRETER, not the JIT.** `invokeInstance` (the
  wasm-3.0-assert runner's execution path) → `instance.invoke` → `_dispatch.run(rt,
  dispatchTable, zfunc.instrs)` (`src/zwasm/instance.zig:169`) — it walks the ZIR
  instruction list on the operand stack (interp). So the green corpus (assert_return
  1232, gc 349/96/60, etc.) is **interp** coverage. The JIT is exercised separately by
  `runI32Export` tests (tail-call / EH / cross-module — the cyc232-239 work) +
  `test-realworld-run-jit` (clang fixtures), NOT the spec corpus.
- **GC is the SOLE Wasm-3.0 proposal with NO JIT emit.** `codegen/{arm64,x86_64}/ops/
  wasm_3_0/` has emit files for tail-call (`return_call{,_indirect,_ref}.zig`),
  function-references (`br_on_null.zig` / `br_on_non_null.zig` / `ref_as_non_null.zig` /
  `call_ref.zig`), and **EH** (`throw.zig` / `throw_ref.zig` / `try_table.zig`) — all
  JIT-emitted and `runI32Export`-verified (cyc232-233). There is **NO** `struct*` /
  `array*` / `ref_cast` / `ref_test` / `i31*` / `gc*` file anywhere in `codegen/` — GC
  ops are **interp-only** (legacy `_dispatch.run` switch). So the "JIT" gap for Wasm 3.0
  is **GC specifically, not EH**. `check_phase10_close_invariants.sh` I16 ("regalloc
  3-axis JIT-side work; deferred to 10.E/G JIT") is now substantially the GC-side
  remainder (refs across GC-alloc safepoints); `test-realworld-run-jit` skips
  `needs_gc_heap` modules (`build.zig:69-71`). See debt D-211.
- **"10.P close-eligible" counts 8 SKIPs as not-FAIL, not as done.** The script reports
  `16 PASS / 8 SKIP / 0 FAIL`; the SKIPs are DEFERRED criteria (GC/EH JIT codegen I16,
  c_api tag accessors I14, realworld emscripten/dart/ocaml/hoot I21 [fixtures are 0
  `.wasm` = placeholders], gc_stress/eh_frequency runner deep-content I19/I20, bench
  I11, widget I23). "Close-eligible" ≠ "Phase 10 complete / nothing remaining."

## Takeaway (how to apply)

When assessing "Phase N done": the JIT and the interp are SEPARATE coverage paths in
zwasm v2. A green `test-spec` / `test-spec-wasm-3.0-assert` proves **interp** coverage;
JIT coverage is the `runI32Export` / `test-realworld-run-jit` / per-arch emit-test
surface. Do NOT read a green spec corpus as "JIT-complete." And read a close-invariants
"close-eligible" as "no FAILs," NOT "no residuals" — count the SKIPs (each is a deferred
deliverable). The ROADMAP §10 `[ ]` rows (10.M/10.R/10.TC/10.E/10.G/10.P) are the
ground-truth remaining list; the handover prose ("substantially complete") was
interp-only optimism. Verify against the code + the `[ ]` rows + the SKIP list, not the
summary prose — same discipline as `stale-debt-rows-misroute-the-loop`.
