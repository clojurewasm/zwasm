# ClojureWasm guest end-to-end — setup procedure

> Discovered 2026-05-04 during §9.6 / 6.G investigation: the
> ROADMAP's original wording "via `build.zig.zon` `path = ...`"
> presumed CW v2 would expose pre-built `.wasm` artefacts as a
> Zig package. CW v2
> (`~/Documents/MyProducts/ClojureWasmFromScratch/`) is at Phase
> 3 (tree-walk evaluator) and won't emit wasm until its own
> Phase 14+. CW v1 (`~/Documents/MyProducts/ClojureWasm/`) does
> emit wasm32-wasi guests today and is the substitute substrate
> for §9.6 / 6.G's "guest end-to-end" verification.
>
> This file is the operational procedure for that substitution.
> ADR-grade discussion was deemed unnecessary — the substitution
> is mechanical, the timeline is documented, and removal is
> procedural (when CW v2 lands wasm, switch the corpus source).

## What 6.G actually requires

The §9.6 / 6.G exit is "ClojureWasm guest end-to-end" — a CW-
emitted .wasm runs under zwasm v2's interpreter and produces the
same output as wasmtime. The mechanism (path-dep vs vendoring)
is implementation detail; the load-bearing claim is
"interoperability proven against a real CW guest".

## Substrate selection (CW v1 substitution)

**Choice**: vendor a small subset of CW v1's `bench/wasm/*.wasm`
into `test/realworld/wasm/` with a `cljw_` prefix. This:

- Keeps the existing realworld 3-runner pipeline (parse / run /
  diff vs wasmtime) doing the verification work.
- Avoids `build.zig.zon` `path = "../ClojureWasm"` (which
  requires every host that runs `zig build` to have CW v1
  cloned at the relative path; windowsmini doesn't).
- Defers the `path = ...` mechanism until CW v2's wasm backend
  ships; at that point the corpus switches source from "vendored
  from CW v1 commit X" to "built by CW v2 path-dep at Y".

**Selected fixtures** (small, compute-only, WASI-pure):

- `cljw_fib.wasm`        — recursive fib via i32 ops.
- `cljw_gcd.wasm`        — euclid loop.
- `cljw_arith.wasm`      — mixed integer arithmetic.
- `cljw_sieve.wasm`      — sieve of eratosthenes (memory + loop).
- `cljw_tak.wasm`        — Takeuchi function (deeply recursive).

(The `*_bench.wasm` siblings include CW's bench harness loop and
print noise — vendor only the plain forms unless we want to
stress the diff runner with longer outputs.)

## Vendoring procedure

```bash
CW_V1_ROOT=~/Documents/MyProducts/ClojureWasm
CW_COMMIT=$(git -C "$CW_V1_ROOT" rev-parse HEAD)

for f in fib gcd arith sieve tak; do
  cp "$CW_V1_ROOT/bench/wasm/$f.wasm" test/realworld/wasm/cljw_$f.wasm
done

# Record provenance for future re-syncs:
echo "Source: $CW_V1_ROOT @ $CW_COMMIT" > test/realworld/wasm/CLJW_PROVENANCE.txt
echo "Vendored: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> test/realworld/wasm/CLJW_PROVENANCE.txt
```

The 5 vendored fixtures flow through:

- `zig build test-realworld` (parse + validate + lower).
- `zig build test-realworld-run` (execute via cli_run.runWasm).
- `zig build test-realworld-diff` (byte compare vs wasmtime).

No additional runner / build wiring is required — the existing
runners walk `test/realworld/wasm/` recursively for `.wasm`.

## Acceptance criterion (§9.6 / 6.G)

- All 5 `cljw_*.wasm` fixtures PASS in
  `test/realworld/runner.zig` (parse).
- All 5 PASS in `test/realworld/run_runner.zig` (execute, exit 0).
- All 5 in `test/realworld/diff_runner.zig` produce **either**
  `MATCH` (both runtimes byte-equal non-empty stdout) **or**
  `SKIP-EMPTY` (both runtimes produced empty stdout — trivially
  equal). CW v1's `bench/` fixtures are compute-only: their
  `_start` runs silently and the computed result is exposed via
  named exports (e.g. `fib`) intended for a host harness, so
  SKIP-EMPTY is the expected outcome under direct CLI invocation.
  `MISMATCH` or `SKIP-V2-*` is a real fail and triggers the
  spec-gap escape clause (debt or skip-ADR per §9.6 / 6.J).

If a future fixture exercises a printing path (e.g. a CW v2
`(println ...)` form once that lands), it should appear as
MATCH; the gate remains "both runtimes agreed on stdout
bytes", whatever that byte count is.

## Removal / migration path

When CW v2 lands its wasm32-wasi backend (CW Phase 14+):

1. Update CW v2's `build.zig.zon` `paths` field to include the
   wasm output directory (currently `bench/wasm/` is *not* in
   `paths`, so even path-dep can't see it).
2. Add `clojure_wasm_v2 = .{ .path = "../ClojureWasmFromScratch" }`
   to zwasm v2's `build.zig.zon`.
3. Add a build step that triggers CW v2's `zig build wasm`
   target and consumes the artifacts.
4. Delete the vendored `cljw_*.wasm` files; replace with the
   build-product path.
5. Delete `CLJW_PROVENANCE.txt`.
6. Delete this setup file (or rewrite for v2 mechanism).

## Why no ADR

Per `.claude/rules/lessons_vs_adr.md`:

- The choice (CW v1 vendor) is mechanical — it doesn't reject
  named alternatives with load-bearing rationale; it picks the
  only working substrate.
- No removal-condition rationale needs preservation — when CW v2
  ships wasm, the migration is obvious.
- No subsequent ROADMAP / phase / scope decision rests on this
  choice.

The ROADMAP §9.6 / 6.G row text is amended to refer to this file
rather than the "via `build.zig.zon` `path = ...`" mechanism;
that amendment is documented in §7 of `.dev/ROADMAP.md`'s
Revision history conventions, not as a separate ADR.

## See also

- `test/realworld/README.md` — three-runner pipeline.
- `~/Documents/MyProducts/ClojureWasm/build.zig:122` — CW v1's
  `wasm` build step (wasm32-wasi target).
- `~/Documents/MyProducts/ClojureWasmFromScratch/.dev/ROADMAP.md`
  §9 — CW v2's phase plan; wasm backend at Phase 14.
