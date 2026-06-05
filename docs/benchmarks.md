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
  the optimizing JITs (~6–16 ms), which pay compile cost up front.
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
   throughput claim. The shootout fixtures (100 ms – 40 s) amortize startup and
   reflect execution speed. We label which is which.
2. **WasmEdge runs its interpreter** here (its AOT needs a separate compile
   step); it belongs next to zwasm-interp.
3. Numbers below are 5 runs + 3 warmup with zwasm built **ReleaseFast** (the fair
   basis vs the release-optimized comparators). Single host (Mac aarch64).

## Sustained compute (startup amortized) — mean ms, lower is faster

| fixture            | zwasm-jit | zwasm-aot | wasmtime | wazero | wasmer | zwasm-interp | WasmEdge |
|--------------------|----------:|----------:|---------:|-------:|-------:|-------------:|---------:|
| shootout/fib2      |      1077 |      1083 |  **700** |    781 |    713 |        39747 |    42865 |
| shootout/sieve     |       320 |       318 |  **203** |    490 |    206 |        13601 |    20637 |
| shootout/matrix    |       343 |       342 |   **88** |    198 |     93 |         5399 |    11038 |
| shootout/heapsort  |      1574 |      1573 |  **642** |    926 |    647 |        15666 |    24078 |
| shootout/keccak    |        34 |        34 |        9 |  **9** |     16 |          289 |      382 |
| shootout/gimli     |        10 |        10 |        8 |  **6** |     14 |          103 |      160 |
| shootout/memmove   |        39 |        38 |       19 | **15** |     22 |          141 |       40 |
| shootout/base64 † |       781 |       780 |   **57** |     79 |     62 |         7028 |    11155 |

The optimizing JITs (wasmtime/wasmer/wazero) lead zwasm-jit/aot by ~1.5–3.9× on
fib2/sieve/matrix/heapsort/keccak — the expected single-pass-vs-optimizer gap.
zwasm-jit ≈ zwasm-aot everywhere (shared codegen; AOT's payoff is cold-start).

> † `base64` (~13.7×) is the hardest case for a single-pass backend: its hot loop
> is 6-bit-group + table-lookup byte processing, which optimizing compilers
> vectorise and zwasm's non-optimizing JIT does not — the §1.3 trade amplified for
> byte shuffling, not a bug. (`memmove` was formerly an outlier where the JIT was
> *slower than the interpreter* — a real `memory.copy` byte-loop defect, now
> **fixed**: zwasm-jit 254→39 ms via word-wise lowering on both backends.)

## Startup-bound short workloads — mean ms (measures cold start, not throughput)

| fixture        | zwasm-aot | zwasm-interp | zwasm-jit | wasmtime | wazero | wasmer | WasmEdge |
|----------------|----------:|-------------:|----------:|---------:|-------:|-------:|---------:|
| tinygo/fib     |   **2.0** |          2.3 |       2.8 |      7.2 |    7.1 |   12.0 |     16.5 |
| tinygo/sieve   |   **2.3** |          2.6 |       2.9 |      6.3 |    7.0 |   11.9 |     16.2 |
| tinygo/nqueens |   **2.1** |          2.4 |       2.8 |      6.4 |    6.7 |   12.5 |     16.5 |
| cljw/tak       |   **2.2** |          2.5 |       2.6 |      6.4 |    6.6 |   12.1 |     16.1 |

zwasm's low instantiate cost makes it fastest end-to-end on these — useful for
CLI / serverless / scripting where each invocation is short.

## Memory footprint — peak RSS (MB), lower is better

| fixture      | zwasm-aot | zwasm-jit | zwasm-interp | wazero | wasmtime | WasmEdge | wasmer |
|--------------|----------:|----------:|-------------:|-------:|---------:|---------:|-------:|
| tinygo/fib   |   **2.1** |       3.2 |          2.7 |    8.7 |     13.3 |     23.7 |   27.5 |
| tinygo/sieve |   **4.0** |       5.1 |          4.6 |    9.5 |     13.2 |     23.6 |   27.5 |
| cljw/tak     |   **2.1** |       3.1 |          2.6 |    8.6 |     13.2 |     23.6 |   27.5 |

The footprint advantage is uniform across the WASI guests: zwasm uses **4–12×
less** resident memory than the comparators, with AOT the leanest (no JIT code
buffers).

## Engine selection (zwasm)

| engine             | how                                                         | best for                                                            |
|--------------------|-------------------------------------------------------------|---------------------------------------------------------------------|
| `interp` (default) | `zwasm run <m>`                                             | smallest footprint, instant start, full WASI; slow on heavy compute |
| `jit`              | `zwasm run --engine jit <m>`                                | ~10–40× faster than interp on compute; adds SIMD execution        |
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
