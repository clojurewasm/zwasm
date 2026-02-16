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
| Binary size (ReleaseSafe) | 1.28 MB |
| Runtime memory (fib benchmark) | 3.57 MB RSS |
| wasmtime binary for comparison | 56.3 MB |

zwasm is ~44x smaller than wasmtime.

## Benchmark results

Representative benchmarks comparing zwasm against wasmtime, Bun, and Node.js on Apple M4 Pro:

| Benchmark | zwasm | wasmtime | Bun | Node |
|-----------|-------|----------|-----|------|
| fib(35) | 54 ms | 51 ms | 33 ms | 44 ms |
| tak(24,16,8) | 7 ms | 11 ms | 17 ms | 26 ms |
| sieve(1M) | 4 ms | 6 ms | 16 ms | 27 ms |
| nbody(1M) | 10 ms | 21 ms | 33 ms | 34 ms |
| nqueens(8) | 2 ms | 5 ms | 14 ms | 22 ms |

zwasm is competitive with wasmtime on most benchmarks and faster on several, while using a fraction of the memory.

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
- **Memory**: Wasm modules with linear memory allocate guard pages. Initial RSS is ~3.5 MB regardless of module size.
