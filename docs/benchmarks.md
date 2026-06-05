# Benchmarks

How zwasm performs against other WebAssembly runtimes, and across its own
three execution engines. **Read the [methodology](#methodology) and
[how to read these numbers](#how-to-read-these-numbers) before the tables** —
the honest story has nuance, and the headline ranking depends entirely on
whether your workload is startup-bound or compute-bound.

> These are point-in-time, single-host figures (Mac aarch64). Benchmarks are
> machine- and toolchain-specific; reproduce them on your own hardware with the
> [command below](#reproducing). The raw full matrix lives in
> [`bench/results/all_engine_matrix.md`](../bench/results/all_engine_matrix.md).

## TL;DR — what zwasm optimizes for

zwasm is a **single-pass, no-optimizing-tier** runtime built for a **small
footprint, fast startup, and a simple embeddable core**. The numbers reflect
that deliberate trade:

- **Memory footprint — zwasm wins decisively.** On small WASI guests zwasm holds
  **~2–5 MB** resident where wasmtime sits at ~13 MB, wazero ~8–9 MB, wasmer
  ~27 MB, WasmEdge ~24 MB — a **4–12× advantage**. AOT (`.cwasm`) is leanest.
- **Startup latency — zwasm is fast.** For short-lived / cold-start workloads
  (CLI tools, serverless, scripting) zwasm's low instantiate cost (~2 ms) beats
  the optimizing JITs (~5–14 ms), which pay compile cost up front.
- **Sustained compute throughput — the optimizing JITs lead, by design.** Once a
  workload runs long enough to amortize startup, wasmtime/wasmer (Cranelift) and
  wazero pull ahead of zwasm's JIT/AOT by ~1.5–3.9× on typical compute. zwasm
  trades peak throughput for a backend with no multi-pass optimizer — a smaller,
  simpler, faster-to-start engine.

**Pick zwasm when** you want minimal memory, fast cold start, or a small
embeddable runtime. **Pick an optimizing JIT when** maximum sustained throughput
on long-running compute is the priority.

## Methodology

- **Host**: Mac, `Darwin aarch64` (Apple M4 Pro). One machine — these are not
  cross-host-averaged.
- **Harness**: [`hyperfine`](https://github.com/sharkdp/hyperfine), wall-clock of
  `<runtime> run <module>` (full process: spawn + instantiate + execute WASI
  `_start`). Peak RSS via `/usr/bin/time -l`.
- **zwasm engines**: `interp` (default, tree-walking), `jit` (single-pass
  arm64/x86_64 codegen), `aot` (`zwasm compile` → `.cwasm`, then run the
  artifact). AOT timings exclude the one-off compile; AOT compile latency is a
  separate [cold-start metric](../bench/results/aot_coldstart.md).
- **Comparators** (pinned in `flake.nix` `devShells.bench`): **wasmtime** 43.0.1
  (Cranelift JIT), **wazero** 1.11.0 (Go compiler), **wasmer** 5.0.4 (Cranelift),
  **WasmEdge** 0.16.1 (interpreter by default — compare it to zwasm-interp, not
  the JITs).
- **Fixtures**: the sightglass shootout (compute-heavy: fib2, sieve, matrix,
  heapsort, base64, keccak, …) and TinyGo / ClojureWasm WASI guests (short
  workloads).

### How to read these numbers

1. **Startup confound.** Sub-10 ms fixtures are dominated by *startup*, not
   execution — so "fastest on tinygo/fib" is a startup-latency result, not a
   throughput claim. The shootout fixtures (100 ms – 60 s) amortize startup and
   reflect execution speed. We label which is which.
2. **WasmEdge runs its interpreter** here (its AOT needs a separate compile
   step); it belongs next to zwasm-interp.
3. The snapshot below was taken with `--quick` (3 runs + 1 warmup) — comparative,
   not tight-CI. Re-run without `--quick` for publication-grade stability.

## Sustained compute (startup amortized) — mean ms, lower is faster

| fixture             | zwasm-jit | zwasm-aot | wasmtime | wazero | wasmer | zwasm-interp | WasmEdge |
|---------------------|----------:|----------:|---------:|-------:|-------:|-------------:|---------:|
| shootout/fib2       |      1062 |      1053 |  **704** |    776 |    717 |        64727 |    42793 |
| shootout/sieve      |       336 |       336 |  **204** |    493 |    205 |        14192 |    20560 |
| shootout/matrix     |       342 |       341 |   **88** |    198 |     91 |         5999 |    11011 |
| shootout/heapsort   |      1576 |      1574 |  **636** |    919 |    640 |        17149 |    23785 |
| shootout/keccak     |        32 |        32 |        9 |  **8** |     15 |          266 |      379 |
| shootout/gimli      |         9 |         9 |        9 |  **5** |     12 |          105 |      157 |
| shootout/base64 †  |       770 |       768 |   **58** |     78 |     61 |         7349 |    10989 |
| shootout/memmove † |       254 |       253 |   **17** |     14 |     21 |          138 |       41 |

The optimizing JITs (wasmtime/wasmer/wazero) lead zwasm-jit/aot by ~1.5–3.9× on
fib2/sieve/matrix/heapsort/keccak — the expected single-pass-vs-optimizer gap.
zwasm-jit ≈ zwasm-aot everywhere (shared codegen; AOT's payoff is cold-start).

> † `base64` (~13×) and `memmove` (~15×, and slower than zwasm's own interpreter)
> are **outliers past the normal trade** — a known zwasm-JIT codegen gap on
> byte-manipulation / bulk-memory loops, tracked as a fix candidate (debt D-285).
> They are not representative of the typical 1.5–3.9× compute gap.

## Startup-bound short workloads — mean ms (measures cold start, not throughput)

| fixture        | zwasm-aot | zwasm-interp | zwasm-jit | wazero | wasmtime | wasmer | WasmEdge |
|----------------|----------:|-------------:|----------:|-------:|---------:|-------:|---------:|
| tinygo/fib     |   **1.7** |          2.1 |       2.3 |    5.3 |      6.5 |   11.4 |     13.5 |
| tinygo/sieve   |   **2.0** |          2.6 |       2.6 |    6.1 |      6.1 |   11.7 |     14.3 |
| tinygo/nqueens |       2.4 |      **2.3** |       2.4 |    6.7 |      5.7 |    9.9 |     13.4 |
| cljw/tak       |       2.1 |          2.1 |       2.4 |    5.7 |      5.2 |   10.9 |     14.0 |

zwasm's low instantiate cost makes it fastest end-to-end on these — useful for
CLI / serverless / scripting where each invocation is short.

## Memory footprint — peak RSS (MB), lower is better

| fixture      | zwasm-aot | zwasm-jit | zwasm-interp | wazero | wasmtime | WasmEdge | wasmer |
|--------------|----------:|----------:|-------------:|-------:|---------:|---------:|-------:|
| tinygo/fib   |   **2.2** |       3.3 |          3.5 |    8.4 |     13.2 |     23.7 |   27.6 |
| tinygo/sieve |   **4.0** |       5.2 |          5.4 |    9.0 |     13.2 |     23.8 |   27.5 |
| cljw/tak     |   **2.1** |       3.2 |          3.4 |    8.5 |     13.2 |     23.6 |   27.4 |

The footprint advantage is uniform across the WASI guests: zwasm uses **4–12×
less** resident memory than the comparators, with AOT the leanest (no JIT code
buffers).

## Engine selection (zwasm)

| engine             | how                                                         | best for                                                            |
|--------------------|-------------------------------------------------------------|---------------------------------------------------------------------|
| `interp` (default) | `zwasm run <m>`                                             | smallest footprint, instant start, full WASI; slow on heavy compute |
| `jit`              | `zwasm run --engine jit <m>`                                | 10–90× faster than interp on compute; adds SIMD execution         |
| `aot`              | `zwasm compile <m> -o <m>.cwasm` then `zwasm run <m>.cwasm` | same steady-state as jit, but lowest cold-start + leanest RSS       |

## Reproducing

```sh
nix develop .#bench --command \
  bash scripts/run_bench.sh --engines=interp,jit,aot --compare=all --capture-rss
# add --quick for the fast 3-run snapshot; omit for 5+3 publication runs
# --bench=<name> for a single fixture; --compare=wasmtime,wazero to subset
```

The `.#bench` dev shell pins every comparator runtime, so the comparison is
hermetic and reproducible. See [`bench/README.md`](../bench/README.md) for the
harness internals and [`bench/results/`](../bench/results/) for raw result docs.
