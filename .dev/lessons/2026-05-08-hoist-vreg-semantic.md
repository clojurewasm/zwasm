---
name: hoist-vreg-semantic
description: ZIR vreg IDs are renumbered at liveness time by operand-stack push order; naive instr-move is NOT semantic-preserving. Hoist requires local-set/local-get rewrite.
type: feedback
---

# Hoist pass — naive instr-move is not semantic-preserving

## Observation

§9.8 / 8.4-c attempted to wire `src/ir/hoist/pass.zig` (the
constant-hoist MVP from 8.4-b) into `compileWasm` between
`lowerFunctionBody` and `liveness.compute`. Result on
`ZWASM_JIT_RUN=1 test-realworld-run-jit`: **regression from
52/55 compile-pass + 15/55 RUN-PASS to 38/55 compile-pass +
2/55 RUN-PASS**, with 14 fixtures hitting `UnsupportedOp` post-
hoist that compiled cleanly pre-hoist.

Root cause (`src/ir/analysis/liveness.zig:1-9`):

> Walks a lowered `ZirFunc`'s instr stream simulating the
> operand stack as a stack of vreg ids. Each push assigns a
> fresh vreg id (sequential, 0-based) and opens a live range...

ZIR vreg IDs are **not stored on `ZirInstr`** — they are
renumbered by liveness based on operand-stack push order. ADR-0031
(and the 8.4-b implementation) assumed the opposite (vreg
identity preserved across instr moves). When hoist moves an
`i32.const` from inside a loop to before it, the new push order
causes ALL downstream vregs to renumber, breaking every
operation that references them.

Additionally — even setting aside vreg renumbering — Wasm's
operand-stack model **frame-scopes** values: a `loop` opcode
splits the stack at the frame boundary; values pushed BEFORE
the loop are NOT visible to instructions INSIDE the loop body.
Hoisting a const out of the loop while leaving its consumer
inside makes the consumer pop from an empty in-loop stack
(underflow).

## Why

**Why:** ZIR's day-1 design (ADR-0014) chose operand-stack-
push-order vreg numbering rather than explicit vreg-id payload
on `ZirInstr`. The choice is correct for Wasm's stack-VM
semantics (vreg identity per-push matches Wasm's "every push
is a fresh stack slot" semantic), but it makes "move an instr
backward in the stream" a **non-trivial transformation**. The
transformation must either preserve push order (e.g. hoist the
ENTIRE consumer subtree out of the loop) OR rewrite the IR to
decouple the value from the stack (introduce a local: `*.const
K; local.set N` outside the loop; `local.get N` inside).

**How to apply:**

1. **Don't ship a hoist pass that just moves instrs**. Update
   ADR-0031 / re-design with the local-set/local-get rewrite
   semantic. The locals slot is the load-bearing decoupling
   between operand-stack scope and the value's lifetime.
2. **Naive moves of *.const opcodes break the IR even at the
   single-loop case** — verify on the realworld_run_jit baseline
   before believing unit tests. The 8.4-b unit tests passed
   because they don't exercise liveness or downstream pipeline
   stages.
3. **Document this in ADR-0031's revision history** so the next
   /continue cycle picking up 8.4 doesn't re-pay the same
   debugging cost.

## Discharge

8.4-c integration reverted in this commit. ADR-0031 amended
with the failure record. New debt entry D-053 tracks the
correct hoist approach (local-rewrite semantic). 8.4-b's
`src/ir/hoist/pass.zig` MVP stays as code (passes its own unit
tests) but is **not wired into the compile pipeline** — it's
preserved as a starting point for D-053's local-rewrite
implementation, since the pc_shift / blocks / branch_targets
update logic IS reusable; what changes is the semantic of what
gets emitted at the hoist position.

Citing: this commit's SHA (backfilled at next phase boundary).
