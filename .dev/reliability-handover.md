# Reliability — Session Handover

> Plan: `@./.dev/reliability-plan.md`. Rules: `@./.claude/rules/reliability-work.md`.

## Branch
`strictly-check/reliability-005` (from main at f654cc9, after reliability-004 merge)

## Current: reliability-005 — Real-world DIFF fix + test expansion + Phase H

### Goal
1. Fix all real-world DIFF (0 failures on Mac + Ubuntu)
2. Expand real-world tests from 12 → 30 (minimal feature overlap)
3. E2E segfault fix (Mac aarch64)
4. Phase H Gate pass → merge to main → CI green → Phase H (41-file doc audit)

### Active Phase
**R7: Merge to main, push, CI green**

### Phase Checklist

#### Infrastructure
- [x] **R0**: CI + gate update — add E2E/compat to gates, memory check, WASI SDK/wasmtime in CI

#### E2E + DIFF fixes
- [x] **R1**: E2E segfault fix — JIT self-call stack overflow use-after-free (d289d44)
- [x] **R2**: Go WASI fix — back-edge JIT restart corrupts Go state machine (skip for side-effect functions)
- [x] **R3**: cpp_string_ops Ubuntu fix — same root cause as R2 (back-edge JIT restart)
- [x] **R4**: c_hello_wasi Ubuntu fix — same root cause as R2 (back-edge JIT restart)

#### Test expansion (12 → 30)
- [x] **R5**: Add 18 new real-world test programs (30/30 Mac + Ubuntu)
  - 5 C, 4 C++, 4 Go, 5 Rust — covers integer/FP math, strings, data structures,
    sorting, recursion, control flow, error handling, function pointers
  - JIT IR instruction limit (MAX_JIT_IR_INSTRS=1500) prevents miscompilation of large functions
  - x86_64 select aliasing fix — val2 clobbered when rd == val2_idx (a87495b)

#### Merge + Phase H
- [x] **R6**: Phase H Gate — all conditions pass (Mac + Ubuntu)
  - OSR for back-edge JIT: enter at loop body, skip prologue side effects
  - ARM64 OSR prologue fix: push FP callee-saved d8-d15 (stack corruption fix)
  - x86_64 OSR prologue fix: load physically-mapped vregs (was missing)
  - hasBrTableInPrologue: inclusive of target instruction (Go back-edge → br_table)
  - st_sieve: 0.97x wasmtime (restored from 30.82x regression)
  - Mac + Ubuntu: 30/30 compat, 62158/62158 spec, unit tests PASS
- [ ] **R7**: Merge to main, push, CI green
- [ ] **R8**: Phase H — 41-file comprehensive documentation audit

### Existing Real-World Tests (12)
| # | Program | Language | WASI Features |
|---|---------|----------|---------------|
| 1 | c_hello_wasi | C | stdout, argv |
| 2 | c_math_compute | C | stdout, math (sin/cos/sqrt) |
| 3 | c_matrix_multiply | C | stdout, loops, arrays |
| 4 | c_string_processing | C | stdout, string ops |
| 5 | cpp_string_ops | C++ | stdout, std::string |
| 6 | cpp_vector_sort | C++ | stdout, std::vector, std::sort |
| 7 | go_hello_wasi | Go | stdout, argv (DIFF) |
| 8 | go_json_marshal | Go | stdout, encoding/json (DIFF) |
| 9 | go_sort_benchmark | Go | stdout, sort (DIFF) |
| 10 | rust_fib_compute | Rust | stdout, recursion |
| 11 | rust_file_io | Rust | stdout, file I/O (/tmp) |
| 12 | rust_hello_wasi | Rust | stdout, env vars |

### Per-Phase Workflow
```
1. Investigate: identify root cause, check wasmtime reference
2. Implement: TDD (Red → Green → Refactor)
3. Verify: zig build test + spec tests (when applicable)
4. Compat: bash test/realworld/run_compat.sh (all PASS)
5. Commit
6. Proceed to next phase
```

## Latest Benchmark Snapshot (P4, runs=5/warmup=3)

### Accepted exceptions (regalloc limit — single-pass architecture)
| bench | zwasm | wasmtime | ratio | Phase |
|-------|------:|--------:|------:|-------|
| rw_c_math | 59.7 | 11.8 | 5.06x | P3 (136 vregs / 1381 IR instrs) |
| st_matrix | 296.4 | 91.7 | 3.23x | P5 (35 vregs, matrix multiply) |

### ≤1.5x wasmtime (OK — 27 benchmarks)
fib 0.88x, tak 0.86x, sieve 0.51x, nbody 0.97x, nqueens 0.65x, tgo_tak 0.62x,
tgo_arith 0.40x, tgo_sieve 0.61x, tgo_fib_loop 0.51x, tgo_gcd 0.38x,
tgo_list 0.53x, tgo_strops 0.95x, st_sieve 0.94x, st_nestedloop 0.56x,
st_ackermann 0.48x, rw_c_matrix 0.82x, rw_c_string 1.06x, rw_cpp_string 0.49x,
rw_cpp_sort 0.53x, tgo_rwork 1.03x, tgo_fib 1.18x, tgo_nqueens 1.19x,
st_fib2 1.35x, tgo_mfr 1.42x, rw_rust_fib 1.22x,
gc_alloc 0.50x, gc_tree 0.73x

## Completed

### reliability-004 (P1-P5)
- [x] P1: rw_c_string hang fix — skip back-edge JIT for reentry guard (20.2ms)
- [x] P2: nbody FP cache fix — expand D-reg cache D2-D15, FP-aware MOV (0.97x wasmtime)
- [x] P3: rw_c_math — accepted as regalloc limit (4.92x)
- [x] P4: GC JIT — struct ops (gc_alloc 0.50x, gc_tree 0.73x wasmtime)
- [x] P5: st_matrix — accepted as regalloc limit (3.23x)

### reliability-003 (A-K)
- A-F: Environment, compilation, compat, E2E, benchmarks, analysis
- G: Ubuntu spec 62,158/62,158 (100%)
- I.0-I.7: E2E 792/792 (100%), FP precision fix
- J.1-J.3: x86_64 JIT bug fixes (division, ABI, SCRATCH2, liveness)
- K.old: select/br_table/trunc_sat JIT, self-call opt, div-const, FP-direct, OSR

## Uncommitted
None.

## Known Bugs
None — all previously known bugs fixed (R1-R4).
