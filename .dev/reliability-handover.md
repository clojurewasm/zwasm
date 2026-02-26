# Reliability — Session Handover

> Plan: `@./.dev/reliability-plan.md`. Rules: `@./.claude/rules/reliability-work.md`.

## Branch
`strictly-check/reliability-003` (from main at d55a72b)

**Merge gate**: Do NOT merge to main until P1 (rw_c_string hang) + P2 (nbody regression) are fixed.
No regressions allowed on main. After P1+P2: Merge Gate check → merge → reliability-004 for P3-P5.

## Current: Plan A — Incremental regression fix + feature implementation

### Active Phase
**Phase 2: nbody FP cache fix** (Priority C)

### Phase Checklist
- [x] **P1**: rw_c_string hang fix — skip back-edge JIT for reentry guard functions (20.2ms, was timeout)
- [ ] **P2**: nbody FP cache fix — resolve be466a0 regression (43ms → ≤15ms)
- [ ] **P3**: rw_c_math re-measure — check P2 ripple effect, decide on further optimization
- [ ] **P4**: GC JIT basic implementation — JIT-compile struct/array ops
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

## Latest Benchmark Snapshot (a26a178, runs=5/warmup=3)

### >1.5x wasmtime (action required)
| bench | zwasm | wasmtime | ratio | Phase |
|-------|------:|--------:|------:|-------|
| nbody | 43.8 | 22.0 | 1.99x | P2 |
| rw_c_math | 16.4 | 8.8 | 1.86x | P3 |
| gc_alloc | 19.2 | 10.7 | 1.79x | P4 |
| gc_tree | 138.1 | 31.4 | 4.40x | P4 |
| st_matrix | 296.3 | 91.7 | 3.23x | P5 (exception) |
| rw_c_string | 20.2 | 9.3 | 2.17x | P1 done |

### ≤1.5x wasmtime (OK — 23 benchmarks)
fib 0.88x, tak 0.86x, sieve 0.51x, nqueens 0.65x, tgo_tak 0.62x,
tgo_arith 0.40x, tgo_sieve 0.61x, tgo_fib_loop 0.51x, tgo_gcd 0.38x,
tgo_list 0.53x, tgo_strops 0.95x, st_sieve 0.94x, st_nestedloop 0.56x,
st_ackermann 0.48x, rw_c_matrix 0.82x, rw_cpp_string 0.49x, rw_cpp_sort 0.53x,
tgo_rwork 1.03x, tgo_fib 1.18x, tgo_nqueens 1.19x, st_fib2 1.35x, tgo_mfr 1.42x,
rw_rust_fib 1.22x

## Completed (reliability-003)
- A-F: Environment, compilation, compat, E2E, benchmarks, analysis
- G: Ubuntu spec 62,158/62,158 (100%)
- I.0-I.7: E2E 792/792 (100%), FP precision fix
- J.1-J.3: x86_64 JIT bug fixes (division, ABI, SCRATCH2, liveness)
- K.old: select/br_table/trunc_sat JIT, self-call opt, div-const, FP-direct, OSR
- Bench infra: record.sh upgraded (29 benchmarks, runs=5/warmup=3, timeout)
- history.yaml: per-commit rerun data (28 commits b39b828..ee5f585)

## Uncommitted
None (jit.zig FP immediate-offset experiment reverted — revisit in P2 if needed).

## Known Bugs
- c_hello_wasi: EXIT=71 on Ubuntu (WASI issue, not JIT — same with --profile)
- Go WASI: 3 Go programs produce no output (WASI compatibility, not JIT-related)
