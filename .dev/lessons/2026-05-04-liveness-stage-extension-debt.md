---
name: liveness-stage-extension-debt
description: Liveness handlers grew via if/elif/elif chains across phase boundaries; the staged extension created a future restructure cost that's now visible.
type: feedback
---

# Liveness staged extensions accumulated structural debt

`src/ir/liveness.zig` grew via incremental if/elif/elif chains as
Wasm 2.0 features landed in Phase 5+ (sign_ext / sat_trunc /
multivalue / bulk memory / ref types). Each addition shipped as
"one more elif" without a frame-based restructure.

## Symptom

The chain reads top-to-bottom as a phase narrative, not as a
domain decomposition. New ops that fit existing categories must
be inserted at the right elif position. Tests cover semantic
correctness, not structural readability — a chain of 50 elifs
passes the same tests as a frame-based switch with category
dispatch.

## Why it didn't get caught

Each addition was small and reviewed in isolation; growth crossed
phase boundaries; no single audit pass saw the cumulative shape.

## What we should have done

When the chain crossed ~10 elifs, restructure to dispatch-table
shape (the §A12 pattern but for the analysis layer):

```zig
const Frame = struct { category: OpCategory, handler: *const fn (...) Liveness };
const frames = [_]Frame{
    .{ .category = .numeric_unary, .handler = &liveness_unary },
    .{ .category = .numeric_binary, .handler = &liveness_binary },
    // ...
};
fn analyse(op: ZirOp) Liveness {
    return frames[categoryOf(op)].handler(...);
}
```

## How to apply

When liveness.zig is touched next (likely Phase 7 spill polish or
Phase 8 optimisation foundation), do the frame-based restructure
as the first commit of that cycle.

**Citing**: ADR-0022 (regret #2) + `.claude/rules/single_slot_dual_meaning.md`.
