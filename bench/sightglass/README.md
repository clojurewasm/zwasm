# bench/sightglass/

Vendored Bytecode Alliance sightglass benchmarks per ADR-0012 §3 +
ROADMAP §9.6 / 6.I. Each subdirectory carries (a) the original C
or C++ source from upstream, (b) the pre-built `benchmark.wasm`
suitable for direct invocation, (c) the golden stdout / stderr,
and (d) any input fixture (`default.input`).

## Provenance

See [`PROVENANCE.txt`](PROVENANCE.txt) for the upstream commit
SHA and vendor date. Re-sync via:

```bash
SG=~/Documents/OSS/sightglass/benchmarks
DEST=$(git rev-parse --show-toplevel)/bench/sightglass

for name in noop quicksort richards bz2 gcc-loops; do
    rm -rf "$DEST/$name"
    mkdir -p "$DEST/$name"
    cp -r "$SG/$name"/. "$DEST/$name/"
    rm -f "$DEST/$name/Dockerfile" "$DEST/$name/Dockerfile.native"
done
```

Update `PROVENANCE.txt` with the new commit SHA + date.

## Why these five

| Benchmark   | Lines | Domain                 | Notes                                     |
|-------------|-------|------------------------|-------------------------------------------|
| `noop`      | 11    | sanity baseline        | smallest possible loop; tests harness     |
| `quicksort` | 178   | compute                | classic recursive sort                    |
| `richards`  | 387   | OO scheduler           | the SunSpider-era OO classic              |
| `bz2`       | 5779  | compression + I/O      | needs `default.input` (216 KB)            |
| `gcc-loops` | 405   | vectorizer-friendly    | C++; tests SIMD / branch-heavy code paths |

Coverage rationale: all five are in-repo C/C++ source so the
"reject TinyGo binary-only and gc_* source-less artifacts"
clause from ADR-0012 §3 holds. Larger Rust-crate benchmarks
(`blake3-*`, `regex`, `rust-html-rewriter`, …) are deferred to
a subsequent vendor cycle once the bench infrastructure can
build them from source — they're not source-less, but vendoring
the full Cargo crate inflates the repo more than 6.I needs.

## Rebuilding the wasm artefacts

The `benchmark.wasm` files are vendored verbatim from the
sightglass upstream Docker-based build. Rebuilding requires
`wasi-sdk` + (for `gcc-loops`) `clang++ -target wasm32-wasi`,
neither of which are in the project's dev shell yet. That's
deliberate: 6.I is structural vendor only, and the wasm
artefacts are deterministic outputs of upstream's reproducible
build.

When Phase 11 wires hyperfine into `scripts/run_bench.sh`, it
will use these `.wasm` files as-is. If a bench needs a fresh
rebuild (e.g. pinned upstream version drift), follow the
sightglass upstream's `build.sh` per benchmark — the original
Dockerfiles were stripped from the vendored copy on purpose
(Docker isn't part of the project's portable build path).

## Why direct CLI invocation fails (this is by design)

Each `benchmark.wasm` imports `bench::start` and `bench::end`
from a harness namespace. The harness must provide those two
host functions; the bench's body calls them around the work-
under-measurement region so the harness can record wall-clock.

Without a harness, `wasmtime run benchmark.wasm` fails at
instantiate with `unknown import: bench::start has not been
defined`. Same outcome on zwasm via `cli_run.runWasm` (the bench
host isn't part of the WASI host yet). **This is expected** —
these wasms aren't standalone WASI guests like
`test/realworld/wasm/cljw_*.wasm`; they're harness-coupled.

Phase 11+ wires a small Zig host (likely
`bench/runners/sightglass_host.zig`) that:

1. Loads each `benchmark.wasm`.
2. Provides `bench::start` and `bench::end` that no-op (the
   harness measures from outside via hyperfine; inside the
   guest these are just timing markers).
3. Calls the guest's `_start` and reports wall-clock.

For 6.I the deliverable is the **vendor + layout** so the Phase
11 host has a stable in-repo corpus to read. No runtime
exercise is required.

## Schema reminder

The shared `sightglass.h` (vendored once per benchmark, since
upstream colocates it) declares:

```c
extern void bench_start(void);
extern void bench_end(void);
```

These resolve to the imported `bench::start` / `bench::end`
mentioned above.

## See also

- [`PROVENANCE.txt`](PROVENANCE.txt)
- [`../../bench/README.md`](../README.md) — top-level bench
  layout (results/, runners/, fixtures/, sightglass/, custom/).
- ADR-0012 §3 (directory layout) + §6.I (this row's scope).
- `~/Documents/OSS/sightglass/` — upstream clone.
