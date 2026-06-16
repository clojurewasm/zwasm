# A `src/` signature change can miss `test/` runner callers that Mac gates never compile

**Date**: 2026-06-16
**Context**: The canonical-equality commit (`9ec68a75`) added a `canonical_types`
param to `validateFunctionWithMemIdxAndTags`. I updated the 6 `validator_tests.zig`
callers + `instantiate.zig` + `compile.zig` — but MISSED `test/spec/wast_runner.zig:352`.
The Mac pre-push gates (`zig build test` / `test-spec` / `lint` / `test-edge-cases`)
do NOT compile `wast_runner.zig`; only the remote `zig build test-all` does. So
the `expected 21 argument(s), found 20` compile error reached the ubuntu gate
(red build, exit 1) even though every test SUITE that DID build passed
(GC 362/0, realworld 56/0). A full remote round-trip was spent to surface a
one-line caller fix.

**Finding**: `src/` files have callers in `test/` runner executables
(`wast_runner.zig`, the spec-assert runners) that are **only compiled by
`test-all`** (remote-only). `zig build test` compiles `src/` + its unit-test
blocks + `validator_tests.zig`, NOT the standalone runner exes. So a widely-called
`src/` signature change (esp. the `validateFunction*` family — many positional
params, no defaults in Zig) passes all Mac gates while a missed runner caller
silently waits to break the remote build.

**How to apply**: when changing a public `src/` signature with many positional
args (the `validateFunction*` family especially), BEFORE push:
1. `grep -rn "<fn name>" --include="*.zig" src/ test/` — enumerate ALL callers,
   incl. `test/spec/*runner*.zig`, and update each (Zig has no default args, so
   every caller must change).
2. Compile the test-all-only runners locally: `zig build test-spec-wasm-2.0`
   builds + runs `wast_runner.zig` on Mac (fast, ~catches the arity error). For
   the GC/3.0 path, `zig build test-spec-wasm-3.0-assert`.
This is the same Mac-gate-gap class as
[[2026-06-15-spill-stage-reg-clobber-and-spec-gate-gap]] (codegen change green
on Mac `test`/`test-spec` but red on the remote `wasm-2.0-assert` runner) — both
say: a change that touches a broadly-consumed surface must compile-check the
remote-only runner targets before push, not rely on `zig build test`.
