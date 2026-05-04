---
name: if-result merge-point bug
description: emit pass naively pushes both then/else result vregs; only the post-branch top survives, but it's the wrong one for the cond=1 path
type: feedback
---

# `(if (result T))` exposes operand-stack merge-point bug at JIT emit

- **Date**: 2026-05-04
- **Phase**: Phase 7 / §9.7 / 7.5 sub-7.5c-v
- **Citing**: commit `<backfill>` body; debt entry D-NEW-merge-point;
  `test/edge_cases/p7/if_then_else/*.wat` (workaround pattern)

## What was tried

A fresh edge-case fixture exercised `if (result i32) (then ...)
(else ...)` end-to-end through the JIT:

```wat
(module (func (export "test") (result i32)
  (if (result i32) (i32.const 1)
    (then (i32.const 11))
    (else (i32.const 22)))))
```

Expected: cond=1 → returns 11. Actual: returns 0.

## What broke + why

The emit pass walks both arms during compilation. For each
`i32.const` it pushes a fresh vreg onto `pushed_vregs`. So the
shape post-walk is `pushed_vregs = [vreg_then, vreg_else]` —
two vregs from a single ZIR if/end frame.

At runtime:

- cond=1: then arm runs (writes vreg_then's reg = 11), else arm
  is skipped via the trailing `B`. The `end` handler reads
  `pushed_vregs[top]` → vreg_else. But vreg_else's register was
  never written — it contains junk (or 0 from prologue zeroing).
- cond=0: CBZ jumps to else arm (writes vreg_else's reg = 22),
  then arm skipped. End reads vreg_else → 22 (correctly).

So cond=0 happens to work; cond=1 silently returns the else
arm's register-uninitialised garbage.

## The structural fix

The if/else/end emit needs **merge-point coordination**: both
arms write to the SAME vreg/register. Concretely:

- At `if`: pop the condition. Reserve a "merge result" vreg per
  the if's result arity. Track it on the label stack.
- At `else`: pop the then arm's pushed result vreg(s). Their
  values are in the registers the regalloc assigned. Insert a
  MOV to the merge result reg. Then start the else arm.
- At `end` for if: pop the else arm's pushed result vreg(s).
  Insert MOV to the same merge result reg. Push the merge
  result onto pushed_vregs.

This requires a "merge result reg" per if/else/end frame on the
label stack. Non-trivial restructuring of the existing
`labels: ArrayList(Label)` shape.

## Lesson generalisation

The `pushed_vregs` model is a simulation of Wasm's operand
stack. It assumes **each emit-time push corresponds to one
runtime push**. That assumption breaks at CFG joins, where
multiple emit-time pushes from different arms collapse into
one runtime push. Any emit-pass model of Wasm's operand stack
needs a merge-aware abstraction at every joining op:

- if/else/end (block-result merge — this lesson)
- block/end with non-zero arity
- loop/end with non-zero arity
- br/br_if/br_table targets with non-zero label arity

The current sub-e2/e3 (if/else/end + br_table) emits do not
yet merge — they pass the spec testsuite's parser+validator
checks but break execution for non-zero-arity cases.

## Workaround used in `test/edge_cases/p7/if_then_else/*.wat`

Rewrote fixtures to use a local instead of a block-result:

```wat
(local i32)
(if (i32.const 1)            ; cond=0/1, no result type
  (then (i32.const 11) local.set 0)
  (else (i32.const 22) local.set 0))
local.get 0                  ; read after merge
```

Each arm's `local.set` writes the SAME local. At runtime only
the taken arm's set executes, but the local has the correct
value either way. The post-if `local.get` reads it. The emit
pass doesn't need merge-aware logic because the "merge" is in
the local frame, not the operand stack.

This pattern is sufficient for Wasm 1.0 fixtures we control,
but real spec testsuite assertions use `(if (result T))`
freely. **The structural fix is required before §9.7 / 7.5c-vii
can close the spec gate.**

## Citing

Tracked as debt entry (next debt sweep). The fix touches:

- `src/jit_arm64/emit.zig` — if/else/end + (later) br/br_if/
  br_table emit handlers, label-stack shape.
- Possibly `src/ir/liveness.zig` — to track merge-result vregs
  in addition to per-push vregs.
