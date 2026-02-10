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

| Name       | Source                  | Wasm                          | Notes                     |
|------------|-------------------------|-------------------------------|---------------------------|
| tgo_fib    | bench/tinygo/fib.go     | bench/wasm/tgo_fib.wasm       | Recursive fib, same as L1 |
| tgo_tak    | bench/tinygo/tak.go     | bench/wasm/tgo_tak.wasm       | Takeuchi function          |
| tgo_arith  | bench/tinygo/arith.go   | bench/wasm/tgo_arith.wasm     | i64 sum loop              |
| tgo_sieve  | bench/tinygo/sieve.go   | bench/wasm/tgo_sieve.wasm     | Sieve with unsafe.Pointer |

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

### Future TinyGo additions

When adding new benchmarks, write TinyGo source first:
- nbody (f64 N-body simulation)
- matrix (matrix multiplication)
- binary-trees (allocation-heavy, recursive)

## Cross-Runtime Comparison

Compare zwasm against other Wasm runtimes. Run when benchmarks are added or after
major optimizations (JIT milestones).

```bash
bash bench/compare_runtimes.sh                              # zwasm vs wasmtime (default)
bash bench/compare_runtimes.sh --rt=zwasm,wasmtime,wasmer   # add wasmer
bash bench/compare_runtimes.sh --rt=zwasm,wasmtime,wasmer,bun,node  # all 5
bash bench/compare_runtimes.sh --bench=fib --quick          # quick single benchmark
```

### Supported runtimes

| Runtime  | Type            | WASI | Notes                          |
|----------|-----------------|:----:|--------------------------------|
| zwasm    | Interpreter+RegIR | Yes | Our runtime                    |
| wasmtime | JIT (Cranelift) | Yes  | Primary comparison target      |
| wasmer   | JIT (multiple)  | Yes  | Secondary comparison           |
| bun      | JIT (JSC)       | No   | Pure-wasm only via run_wasm.mjs |
| node     | JIT (V8)        | No   | Pure-wasm only via run_wasm.mjs |

bun/node use `bench/run_wasm.mjs` wrapper. WASI benchmarks (tgo_*) are skipped
for bun/node since they lack WASI support in this mode.

### Dependencies

Managed via `flake.nix` (`nix develop`): wasmtime, wasmer, bun, nodejs, hyperfine.

## Benchmark History

Track performance progression across optimization tasks.

```bash
bash bench/record.sh --id="3.8" --reason="ARM64 JIT basic"
bash bench/record.sh --id="3.8" --reason="re-measure" --overwrite
bash bench/record.sh --bench=fib --id="3.8" --reason="fib only"
bash bench/record.sh --delete="3.8"
```

Results: `bench/history.yaml` — zwasm-only, hyperfine mean ms.

## Layer 3: Standard Reference (External Comparison) — DEFERRED

For standardized cross-runtime benchmarks (sightglass, WasmScore).
Target: post-JIT (Stage 3.9+), when external comparison becomes meaningful.

### Candidate sources

| Suite                  | URL                                            | Notes                       |
|------------------------|------------------------------------------------|-----------------------------|
| sightglass/shootout    | github.com/bytecodealliance/sightglass         | wasmtime official, 21 algos |
| WasmScore              | github.com/bytecodealliance/wasm-score          | Built on sightglass         |
| libsodium              | 00f.net/2023/01/04/webassembly-benchmark-2023/ | 70 crypto tests, portable   |
| Programming Lang Bench | programming-language-benchmarks.vercel.app/wasm | 14+ Rust→wasm benchmarks    |
