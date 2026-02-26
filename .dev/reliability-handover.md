# Reliability — Session Handover

> Plan: `@./.dev/reliability-plan.md`. Rules: `@./.claude/rules/reliability-work.md`.

## Branch
`strictly-check/reliability-004` (from main at 74153ff, after P1+P2 merge)

P1+P2 merged to main. Remaining: P3-P5.

## Current: Plan A — Incremental regression fix + feature implementation

### Active Phase
**Phase 4: GC JIT basic implementation** (Priority B)

### Phase Checklist
- [x] **P1**: rw_c_string hang fix — skip back-edge JIT for reentry guard functions (20.2ms, was timeout)
- [x] **P2**: nbody FP cache fix — expand D-reg cache D2-D15 + FP-aware MOV (23.1ms, 0.97x wasmtime)
- [x] **P3**: rw_c_math — accepted as regalloc limit (58ms, 4.92x, 136 regs / 1381 IR instrs)
- [x] **P4**: GC JIT basic implementation — predecode+regalloc+JIT for struct ops (gc_alloc 0.50x, gc_tree 0.73x wasmtime)
- [ ] **P5**: st_matrix accept — ≤3.5x exception (single-pass limit)

### Per-Phase Workflow (important)
```
1. Investigate: identify root cause, check wasmtime reference
2. Implement: TDD (Red → Green → Refactor)
3. Verify: zig build test + spec tests (when applicable)
4. Bench: bash bench/run_bench.sh --quick (regression check)
5. Record: bash bench/record.sh --id=P{N} --reason="..."  ← MANDATORY
6. Commit
7. Proceed to next phase
```

## Latest Benchmark Snapshot (P4, runs=5/warmup=3)

### >1.5x wasmtime (action required)
| bench | zwasm | wasmtime | ratio | Phase |
|-------|------:|--------:|------:|-------|
| rw_c_math | 59.7 | 11.8 | 5.06x | P3 exception (regalloc limit) |
| st_matrix | 296.4 | 91.7 | 3.23x | P5 exception (regalloc limit) |

### ≤1.5x wasmtime (OK — 27 benchmarks)
fib 0.88x, tak 0.86x, sieve 0.51x, nbody 0.97x, nqueens 0.65x, tgo_tak 0.62x,
tgo_arith 0.40x, tgo_sieve 0.61x, tgo_fib_loop 0.51x, tgo_gcd 0.38x,
tgo_list 0.53x, tgo_strops 0.95x, st_sieve 0.94x, st_nestedloop 0.56x,
st_ackermann 0.48x, rw_c_matrix 0.82x, rw_c_string 1.06x, rw_cpp_string 0.49x,
rw_cpp_sort 0.53x, tgo_rwork 1.03x, tgo_fib 1.18x, tgo_nqueens 1.19x,
st_fib2 1.35x, tgo_mfr 1.42x, rw_rust_fib 1.22x,
gc_alloc 0.50x, gc_tree 0.73x

## Completed (reliability-003)
- A-F: Environment, compilation, compat, E2E, benchmarks, analysis
- G: Ubuntu spec 62,158/62,158 (100%)
- I.0-I.7: E2E 792/792 (100%), FP precision fix
- J.1-J.3: x86_64 JIT bug fixes (division, ABI, SCRATCH2, liveness)
- K.old: select/br_table/trunc_sat JIT, self-call opt, div-const, FP-direct, OSR
- Bench infra: record.sh upgraded (29 benchmarks, runs=5/warmup=3, timeout)
- history.yaml: per-commit rerun data (28 commits b39b828..ee5f585)

## Uncommitted
None.

## Known Bugs
- c_hello_wasi: EXIT=71 on Ubuntu (WASI issue, not JIT — same with --profile)
- Go WASI: 3 Go programs produce no output (WASI compatibility, not JIT-related)
