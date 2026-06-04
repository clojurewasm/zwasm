# Cross-module tail-call: the pinned-cohort save discipline is per-arch asymmetric

**Date**: 2026-05-30
**Citing**: ADR-0112 Amendment 2026-05-30 (`7131d711`); D-206 step 2; D-210
**Keywords**: return_call, cross-module, tail-call, pinned cohort, X19, X24-X28,
R15, frame_teardown, bridge thunk, ADR-0066, ADR-0017, ADR-0026, grand-caller,
cohort corruption, call-and-return, frame-consuming, D-142

## Observation

The first cross-module `return_call` test (D-206 step 2) surfaced that the
"obvious" ADR-0112 D4 emit (load callee_rt → X0/RDI, `frame_teardown`, then a
frame-consuming `BR X16` / `JMP R11`) is **correct on x86_64 but corrupts the
caller's caller on arm64**. The split is rooted in the per-arch pinned-register
save discipline:

- **x86_64** (ADR-0026): the runtime-ptr R15 is the *only* pinned reg, and every
  frame that uses it PUSH-saves it in the prologue / POP-restores it in the
  epilogue (`frame_teardown`'s `uses_runtime_ptr`). A frame-consuming tail-jump
  preserves a same-module grand-caller's R15 *for free*: teardown restores it
  before the JMP, the callee re-saves-and-restores it, the callee's RET lands in
  the grand-caller with R15 intact.
- **arm64** (ADR-0017): the pinned cohort is X19 + X24-X28, and the prologue
  **MOV-installs X19 from X0 and LOADs X24-X28 from the rt** — it never
  stack-saves them. So a frame-consuming tail-jump to a different-rt callee
  leaves the callee's cohort in the registers when control returns to a
  same-module grand-caller → wrong mem/table base on its next op. This is the
  D-142 corruption class in tail-call form.

## Why it's invisible at the obvious test

A top-level `entry → A.test → return_call B.get` harness is **green on both
arches** even with the buggy arm64 BR-bridge: the entry trampoline reads the
result register and never touches the cohort. The corruption only manifests when
a *same-module* function calls A.test and then uses its cohort. The preventive
test (`runner.zig` "same-module grand-caller's cohort survives") closes exactly
that gap: `$mid` does the cross-module `return_call`, `test` calls `$mid` then
`i32.load`s A's own memory — a naive BR-bridge regression traps on B's empty
memory.

## Resolution (taken)

Cross-module `return_call` lowers to **call-and-return** through the existing
ADR-0066 bridge thunk (which save/restores the full cohort across its BLR/CALL)
+ the normal epilogue (= `call $import` then return). Cohort-correct on both
arches; the only cost is it's NOT frame-consuming (unbounded *cross-module*
mutual tail-recursion grows the native stack). Same-module `return_call` stays
proper-tail-call. Frame-consuming cross-module tail-call is deferred to the
arm64-prologue-cohort-save work (D-210).

## Takeaway

When a tail-call crosses an rt boundary, the callee must preserve the
grand-caller's pinned cohort. "Preserve" is free where the cohort is stack-saved
per-frame (x86_64 R15) and impossible where it's MOV-installed (arm64 cohort)
— the per-arch ABI decision (ADR-0017 vs ADR-0026) silently dictates whether a
frame-consuming cross-module tail-jump is even legal. Audit cross-arch ABI
symmetry assumptions before lowering a frame-consuming construct.
