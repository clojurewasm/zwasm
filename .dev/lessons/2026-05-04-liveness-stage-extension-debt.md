---
name: liveness-stage-extension-debt
description: Liveness handlers grew via if/elif/elif chains across phase boundaries; the staged extension created a future restructure cost that's now visible.
type: feedback
---

# Liveness staged extensions accumulated structural debt

`src/ir/liveness.zig` (and the equivalent in regalloc consumers)
grew via incremental if/elif/elif chains as Wasm 2.0 features
landed in Phase 5+ (sign_ext / sat_trunc / multivalue / bulk
memory / ref types). Each addition shipped as "one more elif"
without a frame-based restructure.

## Symptom

The chain reads top-to-bottom as a phase narrative, not as a
domain decomposition. New ops that fit existing categories must
be inserted at the right elif position; readers must mentally
trace the chain to understand category membership. The "twin
to single_slot_dual_meaning" risk: an op whose category is
ambiguous gets inserted at the wrong elif and silently misses a
liveness annotation.

## Why it didn't get caught

- Each individual elif addition was small and reviewed in
  isolation.
- The chain's growth crossed phase boundaries; no single audit
  pass saw the cumulative shape.
- Tests cover semantic correctness, not structural readability.
  A chain of 50 elifs passes the same tests as a frame-based
  switch with category dispatch.

## What we should have done

When the chain crossed ~10 elifs, restructure to:

```zig
const Frame = struct {
    category: OpCategory,
    handler: *const fn (...) Liveness,
};
const frames = [_]Frame{
    .{ .category = .numeric_unary, .handler = &liveness_unary },
    .{ .category = .numeric_binary, .handler = &liveness_binary },
    ...
};
fn analyse(op: ZirOp) Liveness {
    const f = frames[categoryOf(op)];
    return f.handler(...);
}
```

This is the dispatch-table pattern (ROADMAP §A12) but for the
analysis layer instead of the execution layer.

## Why I'm writing this as a lesson

It's not a load-bearing decision (no ADR needed); the
restructure is a refactor that someone will re-derive in
context. The lesson exists so the next person doesn't think
the chain is intentional design.

## How to apply

When liveness.zig is touched next (likely Phase 7 spill
analysis polish or Phase 8 optimisation foundation), do the
frame-based restructure as the first commit of that cycle, not
as a parallel "while I'm here" change.

## Citing

- ADR-0022 (post-session retrospective; lists this as regret #2)
- `.claude/rules/single_slot_dual_meaning.md` (§14 entry the
  pattern flirts with)
