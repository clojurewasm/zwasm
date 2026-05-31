---
paths:
  - "src/engine/codegen/arm64/abi.zig"
  - "src/engine/codegen/arm64/prologue.zig"
  - "src/engine/codegen/arm64/thunk.zig"
  - "src/engine/codegen/arm64/emit.zig"
  - "src/engine/codegen/arm64/op_call.zig"
  - "src/engine/codegen/arm64/op_control.zig"
  - "src/engine/codegen/x86_64/abi.zig"
  - "src/engine/codegen/x86_64/prologue.zig"
  - "src/engine/codegen/x86_64/thunk.zig"
  - "src/engine/codegen/x86_64/emit.zig"
  - "src/engine/codegen/x86_64/op_call.zig"
  - "src/engine/codegen/x86_64/op_control.zig"
  - "src/engine/codegen/shared/thunk.zig"
---

# ABI callee-saved pinning

> Lean stub (ADR-0118 D2). Full detail / case studies / matrix: [`../references/abi_callee_saved_pinning.md`](../references/abi_callee_saved_pinning.md).

## Invariant (PRESERVE — cost 6-cycle root-causes D-142 / D-206 / D-210)

- The **pinned runtime cohort** — arm64 **X19** + **X24–X28**; x86_64 **R15** —
  is installed by the prologue (ADR-0017 sub-2d-ii: MOV-install from the rt, not
  stack-save). Any path that **clobbers** a cohort reg across a call to a
  DIFFERENT runtime (cross-module bridge thunk, frame-consuming tail-jump
  `BR X16` / `JMP R11`) MUST restore the cohort first, else a same-module
  grand-caller's pinned values are corrupted and it traps on garbage.
- A frame-CONSUMING cross-module tail-call needs a **prologue cohort stack-save**
  on arm64 (Option B) before `frame_teardown` + `BR`. Until then cross-module
  `return_call` stays **call-and-return** via the bridge thunk, NOT proper-
  tail-call (D-210).
- Bridge thunk (`shared/thunk.zig:emitThunk`) is call-and-return: swap
  runtime_ptr → callee_rt, `BLR`/`CALL` callee_entry, `RET`. Cohort-safe by
  construction.

## Enforcement

Reviewer discipline (no mechanical gate) + the 3-host gate (cohort corruption
surfaces as a cross-module SEGV / wrong value, esp. x86_64 SysV). Cross-module +
tail-call fixtures are the regression net.

## Key cases

- New cross-runtime emit path (thunk variant, tail bridge) → audit cohort
  save/restore on BOTH arches (x86_64 per-frame R15 save ≠ arm64 MOV-install).
- D-210 (arm64 prologue cohort-save) gates frame-consuming cross-module TC.

Full register rationale, call-and-return vs frame-consuming matrix, D-142/D-206/D-210 case studies: [`../references/abi_callee_saved_pinning.md`](../references/abi_callee_saved_pinning.md).
