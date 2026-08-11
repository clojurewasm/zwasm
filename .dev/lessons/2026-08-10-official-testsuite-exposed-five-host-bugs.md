# The official wasi-testsuite binaries exposed five real host bugs the local corpus certified as green

**Date**: 2026-08-10 · **Context**: ADR-0205 phase A (wasi03-full campaign)

Running the upstream-BUILT `prod/testsuite-base` wasm32-wasip3 binaries (real
rust + wit-bindgen 0.58 output) against a host whose own fixture corpus was
100% green surfaced, in one afternoon:

1. **future.{read,write} core ABI arity** — bound as 3-arg (stream shape);
   the spec says (handle, ptr). Our hand-written `.wat` fixtures had baked the
   same wrong arity, so they "confirmed" the bug.
2. **future completion packing** — host result futures returned
   `COMPLETED(1)`; `future_event` packs no count ("always zero"). Again the
   local fixture asserted the wrong constant (`0x10`).
3. **imported-func `raw_typeidx` = 0** — a host-bound import wired into a
   funcref table + `call_indirect` in a GTI-bearing module false-trapped
   `IndirectCallTypeMismatch` (checked against type 0).
4. **stale side-table roles on handle reuse** — `host_result_futures` (handle
   -keyed) and `host_sinks`/`host_sources` (shared-keyed) survived drops; a
   reused handle inherited "result future" and short-circuited a fresh
   stream's writes to `COMPLETED(0)` → guest write-retry livelock.
5. **`run → err` exit code** — both runners ignored the `result` discriminant
   (exit 0 instead of 1).

Phase B (filesystem) added two more of the same class:

6. **`waitable.join` arg order** — bound as (set, waitable); the spec's core
   ABI is `(waitable, set)` with set 0 = leave-set and move semantics. EIGHT
   hand-written fixtures baked the reversed order and certified it green.
7. **end-pointer invalidation** — `StreamFutureTable.get`'s pointer was held
   across a `newFuturePair` (table growth realloc) — a latent UAF the borrow
   discipline of the hand-rolled fixtures never triggered.

Why the local corpus missed all five: hand-written fixtures encode the
AUTHOR'S understanding of the ABI — they co-evolve with the host and cannot
catch a shared misreading. Real-toolchain binaries encode wit-bindgen's
(adversarially precise) understanding. **Corollary**: when a spec claim and a
passing local fixture disagree with real-toolchain output, suspect the fixture
first; and prefer vendoring upstream-built conformance artifacts over
regenerating equivalents locally (D-523's borrowed-libc trap is the same
lesson from the build side).
