# A cheap sanity-check that duplicates a real gate's limit must SHARE the constant

**Date**: 2026-06-03 · **Context**: D-241 (standard-Go modules rejected at instantiate)

## Observation

The IR verifier (`verifier.zig`) capped branch-target depth at a literal
`max_block_depth: u32 = 256`, with a comment saying it "matches the validator's
`max_control_stack` so anything that survives the validator passes this check too."
But the validator's `max_control_stack` had since grown to **1024** (validator.zig).
The two drifted. A validator-ACCEPTED standard-Go function with control depth in
[256, 1024) — common in Go's compiler output — was then wrongly rejected by the
verifier (`BranchTargetOutOfRange` → `InvalidModule` → instantiate null-collapse),
which is why all 9 `go_*` realworld fixtures failed to instantiate.

The verifier is a *cheap structural sanity net*; the validator is the *real gate*.
A sanity net must never be STRICTER than the gate it backstops — if it is, it
rejects inputs the gate accepts, which is a false-negative bug, not extra safety.

## Rule

When a secondary check duplicates a primary gate's limit, **source both from ONE
named constant** — never two literals "kept in sync" by a comment. The comment is
not enforcement; it rots the moment one side changes. Fix: put the limit in the
lowest common module (here `zir.max_control_stack`, imported by both validator and
verifier) so they CANNOT drift, and add a test asserting the two are equal (the
exact invariant that broke).

Same family as [[2026-06-03-reprobe-blocked-by-barriers-before-scoping]] (D-240):
a check that is inconsistent with the real gate (there, the elem-vs-table `eql`;
here, the branch-depth ceiling) — the inconsistency itself is the bug. Whenever
you see "must match X" in a comment over a literal, that's a drift waiting to
happen; replace it with a shared constant.

Related: D-241 (this bug, resolved); D-242 (the deeper gap the fix then exposed —
the 256-frame interp call stack is too shallow for Go's runtime, CallStackExhausted);
validator.zig `max_control_stack`; verifier.zig `max_block_depth`; zir.zig.
