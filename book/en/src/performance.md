# Performance

## Execution tiers

zwasm uses tiered execution:

1. **Interpreter**: All functions start as register IR, executed by a dispatch loop. Fast startup, no compilation overhead.
2. **JIT (ARM64/x86_64)**: Hot functions are compiled to native code when call count or back-edge count exceeds a threshold.

### When JIT kicks in

- **Call threshold**: After ~8 calls to the same function
- **Back-edge counting**: Hot loops trigger JIT faster (loop iterations count toward the threshold)
- **Adaptive**: The threshold adjusts based on function characteristics

Once JIT-compiled, all subsequent calls to that function execute native machine code directly, bypassing the interpreter.

## Binary size and memory

| Metric | Value |
|--------|-------|
| Binary size (ReleaseSafe) | ~1.2 MB |
| Runtime memory (fib benchmark) | ~4.5 MB RSS |
| wasmtime binary for comparison | 56.3 MB |

zwasm is ~40x smaller than wasmtime.

## Benchmark results

Representative benchmarks comparing zwasm against wasmtime 41.0.1, Bun 1.3.8, and Node v24.13.0 on Apple M4 Pro.
16 of 29 benchmarks match or beat wasmtime. 25/29 within 1.5x.

| Benchmark | zwasm | wasmtime | Bun | Node |
|-----------|------:|---------:|----:|-----:|
| nqueens(8) | 2 ms | 5 ms | 14 ms | 23 ms |
| nbody(1M) | 22 ms | 22 ms | 32 ms | 36 ms |
| gcd(12K,67K) | 2 ms | 5 ms | 14 ms | 23 ms |
| tak(24,16,8) | 5 ms | 9 ms | 17 ms | 29 ms |
| sieve(1M) | 5 ms | 7 ms | 17 ms | 29 ms |
| fib(35) | 46 ms | 51 ms | 36 ms | 52 ms |
| st_fib2 | 900 ms | 674 ms | 353 ms | 389 ms |

zwasm uses 3-4x less memory than wasmtime and 8-10x less than Bun/Node.

Full results (29 benchmarks): `bench/runtime_comparison.yaml`

### SIMD performance

SIMD operations are functionally complete (256 opcodes, 100% spec) but run on the stack
interpreter, not the register IR or JIT. This results in ~22x slower SIMD execution vs
wasmtime. Planned improvement: extend register IR for v128, then selective JIT NEON/SSE.

## Benchmark methodology

All measurements use [hyperfine](https://github.com/sharkdp/hyperfine) with ReleaseSafe builds:

```bash
# Quick check (1 run, no warmup)
bash bench/run_bench.sh --quick

# Full measurement (3 runs, 1 warmup)
bash bench/run_bench.sh

# Record to history
bash bench/record.sh --id="X" --reason="description"
```

### Benchmark layers

| Layer | Count | Description |
|-------|-------|-------------|
| WAT micro | 5 | Hand-written: fib, tak, sieve, nbody, nqueens |
| TinyGo | 11 | TinyGo compiler output: same algorithms + string ops |
| Shootout | 5 | Sightglass shootout suite (WASI) |
| Real-world | 6 | Rust, C, C++ compiled to Wasm (matrix, math, string, sort) |
| GC | 2 | GC proposal: struct allocation, tree traversal |

### CI regression detection

PRs are automatically checked for performance regressions:
- 6 representative benchmarks run on both base and PR branch
- Fails if any benchmark regresses by more than 20%
- Same runner ensures fair comparison

## Performance tips

- **ReleaseSafe**: Always use for production. Debug is 5-10x slower.
- **Hot functions**: Functions called frequently will be JIT-compiled automatically.
- **Fuel limit**: `--fuel` adds overhead per instruction. Only use for untrusted code.
- **Memory**: Wasm modules with linear memory allocate guard pages. Initial RSS is ~4.5 MB regardless of module size.
