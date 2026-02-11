---
paths:
  - "bench/**/*"
  - "src/jit.zig"
  - "src/vm.zig"
  - "src/regalloc.zig"
---

# Benchmark Check Rules

## Core Principle

**Always use ReleaseSafe for benchmarks.** All scripts auto-build ReleaseSafe.
All measurement uses hyperfine (warmup + multiple runs). Never trust single-run.

## When to Record

| Scenario                         | What to record                    | Command                              |
|----------------------------------|-----------------------------------|--------------------------------------|
| **Optimization task**            | `history.yaml` only               | `bash bench/record.sh --id=ID --reason=REASON` |
| (interpreter/JIT improvement)    | (compare against own past)        | Use `--overwrite` to re-measure same ID |
| **Benchmark item added/removed** | Both `history.yaml` AND           | `bash bench/record.sh --id=ID --reason=REASON` |
| (new .wasm, new layer, etc.)     | `runtime_comparison.yaml`         | `bash bench/record_comparison.sh`    |

## Commands

```bash
# Quick check (no recording)
bash bench/run_bench.sh --quick
# Cross-runtime quick check
bash bench/compare_runtimes.sh --quick
# Specific benchmark only
bash bench/run_bench.sh --bench=fib
# Record to history (hyperfine 5 runs + 2 warmup)
bash bench/record.sh --id="3.9" --reason="JIT function-level"
```

## Before Committing Optimization/JIT Changes

1. **Quick check**: `bash bench/run_bench.sh --quick` — verify no regression
2. **Record**: `bash bench/record.sh --id=TASK_ID --reason=REASON`
3. If benchmark items changed: also `bash bench/record_comparison.sh`

## Files

- History: `bench/history.yaml` — zwasm performance progression
- Comparison: `bench/runtime_comparison.yaml` — 5 runtimes (zwasm/wasmtime/wasmer/bun/node)
- Strategy: `.dev/bench-strategy.md` — benchmark layers and design
