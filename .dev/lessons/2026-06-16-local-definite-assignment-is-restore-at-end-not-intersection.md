# Wasm local definite-assignment is "sets don't escape blocks", NOT dataflow intersection

**Date**: 2026-06-16
**Context**: D-459 (Wasm 3.0 §3.3.1 local-init validation), surfaced by the D-458 local_init corpus add

## Observation

A non-defaultable local (non-null `(ref $t)` / `(ref extern)` — no default value) is
readable only if definitely-assigned on every path reaching the read. The *intuitive*
model — "a local set on ALL branches of an if is initialized after the if" (dataflow
intersection at control-flow joins) — is **WRONG** for the Wasm spec. The actual rule
is the conservative **restore-at-end**: a `local.set`/`local.tee` inside a structured
block/loop/if does **not escape** it; at the matching `end` (and at `else`, back to the
if-entry state) the init-set is restored to the block's entry snapshot.

Decisive evidence (the official `local_init.wast`, cross-checked with `wasm-tools`):
`$uninit-from-if` sets `$x` in **both** the `then` and `else` branches, then reads it
after the `if` — and it is `assert_invalid`. Under an intersection model it would be
valid; under restore-at-end it is correctly rejected. So inits flow only INTO nested
blocks (a set at function-body level is visible inside a child block), never back OUT.

An Explore subagent surveying the implementation *recommended* the intersection model
(allocator-duped per-frame snapshots, merge at joins) — plausible but spec-wrong. The
testsuite is the authoritative oracle; verifying the proposed rule against the actual
`assert_invalid` cases (and a reference validator) BEFORE implementing caught it.

## Rule

For a spec validation rule whose shape you're inferring, derive it from the official
testsuite's valid/invalid case matrix + a reference tool (`wasm-tools validate`), not
from intuition or a subagent's "standard dataflow" framing. For local-init specifically:
implement restore-at-end (per-frame entry snapshot of the non-defaultable locals' init
bits, restored at `end`/`else`), NOT a join intersection. The implementation is far
simpler than intersection (a u64 mask per frame, no merge logic) — and it's the only
one that matches the conformance suite.

## See also

- [[hardcoded-corpus-subset-hides-whole-op-families]] — the local_init corpus that
  surfaced this gap (D-458 core-2.0 completeness).
- D-459 (impl `33658bdb`); validator.zig pushFrame/opEnd/opElse + `init_mask_at_entry`.
