# Benchmark Strategy

Three-tier benchmark approach for zwasm optimization development.

## Layer 1: Micro (Register IR Development)

Hand-written WAT — minimal overhead, isolates specific instruction patterns.

| Name    | WAT source       | Wasm                        | Workload category   |
|---------|------------------|-----------------------------|---------------------|
| fib     | (testdata)       | src/testdata/02_fibonacci.wasm | Recursive integer |
| tak     | bench/wat/tak.wat | bench/wasm/tak.wasm         | Deep recursion      |
| sieve   | bench/wat/sieve.wat | bench/wasm/sieve.wasm     | Loop + memory       |
| nbody   | bench/wat/nbody.wat | bench/wasm/nbody.wasm     | Float-heavy (f64)   |
| nqueens | (testdata)       | src/testdata/25_nqueens.wasm | Mixed int + memory  |

Purpose: Fast iteration during register IR and JIT development.
Profile analysis: `.dev/profile-analysis.md`

## Layer 2: Compiler Output (Real Compiler Evaluation)

TinyGo source compiled to wasm — tests realistic compiler output patterns
(function prologues, stack management, Go runtime overhead ~8KB).

Source: `bench/tinygo/` (Go source files)
Compiled: `bench/wasm/tgo_*.wasm`

| Name          | Source                      | Notes                     |
|---------------|-----------------------------|---------------------------|
| tgo_fib       | bench/tinygo/fib.go         | Recursive fib, same as L1 |
| tgo_tak       | bench/tinygo/tak.go         | Takeuchi function         |
| tgo_arith     | bench/tinygo/arith.go       | i64 sum loop              |
| tgo_sieve     | bench/tinygo/sieve.go       | Sieve with unsafe.Pointer |
| tgo_fib_loop  | bench/tinygo/fib_loop.go    | Iterative fibonacci       |
| tgo_gcd       | bench/tinygo/gcd.go         | Euclidean GCD             |

### Build instructions

```bash
# Requires: tinygo (brew install tinygo or nix)
bash bench/tinygo/build.sh
```

### Why TinyGo?

- Source is human-readable Go — explains what the benchmark does
- Compiler output includes real-world patterns: function prologues, stack frames, Go runtime
- Paired comparison with hand-written WAT shows compiler overhead
- Shareable with CW project for cross-runtime benchmarks

## Layer 3: Sightglass Shootout (Standard Reference)

19 C benchmarks from [bytecodealliance/sightglass](https://github.com/bytecodealliance/sightglass)
compiled to WASI .wasm with `zig cc -target wasm32-wasi`.

Source: `bench/shootout-src/` (C source + modified sightglass.h)
Compiled: `bench/wasm/shootout/*.wasm`

### Key modifications from upstream

- `sightglass.h`: bench_start()/bench_end() replaced with no-op inlines
  (original uses wasm imports for sightglass-recorder profiling)
- `ackermann.c`: hardcoded M=3,N=7 inputs (original reads from files)

### Representative benchmarks for comparison runs

| Name            | Algorithm              | Workload                  |
|-----------------|------------------------|---------------------------|
| st_fib2         | Recursive fibonacci    | Deep recursion (fib 42)   |
| st_sieve        | Sieve of Eratosthenes  | Loop + memory (17K iter)  |
| st_nestedloop   | 6 nested loops         | Pure integer arithmetic   |
| st_ackermann    | Ackermann function     | Deep recursion (3,7)      |
| st_ed25519      | Ed25519 crypto         | 128-bit math, 10K iter    |
| st_matrix       | Matrix multiply        | Array ops + arithmetic    |

### Build instructions

```bash
# Requires: zig (0.15.2+)
bash bench/shootout-src/build.sh
```

All 19 .wasm files run on ANY WASI runtime without stubs or special flags:
```bash
zwasm run shootout-fib2.wasm
wasmtime shootout-fib2.wasm
wasmer shootout-fib2.wasm
bun bench/run_wasm_wasi.mjs shootout-fib2.wasm
node bench/run_wasm_wasi.mjs shootout-fib2.wasm
```

## Cross-Runtime Comparison

Compare zwasm against other Wasm runtimes.

```bash
bash bench/compare_runtimes.sh                                         # zwasm vs wasmtime
bash bench/compare_runtimes.sh --rt=zwasm,wasmtime,wasmer,bun,node     # all 5
bash bench/compare_runtimes.sh --bench=st_fib2 --quick                 # quick single
bash bench/compare_runtimes.sh -h                                      # list all benchmarks
```

### Supported runtimes

| Runtime  | Type              | WASI | Notes                           |
|----------|-------------------|:----:|---------------------------------|
| zwasm    | Interpreter+RegIR | Yes  | Our runtime                     |
| wasmtime | JIT (Cranelift)   | Yes  | Primary comparison target       |
| wasmer   | JIT (multiple)    | Yes  | Secondary comparison            |
| bun      | JIT (JSC)         | Yes  | WASI via run_wasm_wasi.mjs      |
| node     | JIT (V8)          | Yes  | WASI via run_wasm_wasi.mjs      |

JS wrappers:
- `bench/run_wasm.mjs` — invoke-style (exported functions), with WASI stubs
- `bench/run_wasm_wasi.mjs` — WASI _start style (shootout benchmarks)

### Dependencies

Managed via `flake.nix` (`nix develop`): wasmtime, wasmer, bun, nodejs, hyperfine, tinygo.

## Benchmark History

Track performance progression across optimization tasks.

```bash
bash bench/record.sh --id="3.8" --reason="ARM64 JIT basic"
bash bench/record.sh --id="3.8" --reason="re-measure" --overwrite
bash bench/record.sh --bench=fib --id="3.8" --reason="fib only"
bash bench/record.sh --delete="3.8"
```

Results: `bench/history.yaml` — zwasm-only, hyperfine mean ms.

## Cross-Runtime Recording

Record speed, memory, and binary size across runtimes.

```bash
bash bench/record_comparison.sh                              # all runtimes
bash bench/record_comparison.sh --rt=zwasm,wasmtime          # specific
```

Results: `bench/runtime_comparison.yaml`

## Known Issues

- **fib_loop TinyGo**: zwasm returns 196608 instead of 75025 — execution bug
- **regalloc overflow**: Complex WASI programs (>255 virtual registers) overflow u8
