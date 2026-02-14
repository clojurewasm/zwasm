# zwasm Roadmap

Independent Zig-native WebAssembly runtime — library and CLI tool.
Benchmark target: **wasmtime**. Optimization target: ARM64 Mac first.

**Library Consumer Guarantee**: ClojureWasm depends on zwasm main via GitHub URL.
All development on feature branches; merge to main requires CW verification.

## Completed Stages (details: roadmap-archive.md)

| Stage | Name                          | Key Result                              |
|-------|-------------------------------|-----------------------------------------|
| 0     | Extraction & Independence     | Standalone lib+CLI from CW              |
| 1     | Library Quality + CLI Polish  | Public API, build.zig.zon               |
| 2     | Spec Conformance              | Wast runner, CI pipeline                |
| 3     | JIT + Optimization (ARM64)    | fib 544→103ms (2.0x wasmtime)           |
| 4     | Polish & Robustness           | Regalloc fixes, cross-runtime bench     |
| 5     | JIT Coverage Expansion        | 20/21 within 2x, f64/f32 JIT           |
| 5F    | E2E Compliance                | 30,666 spec (99.9%)                     |
| 6     | Bug Fixes & Stability         | All active bugs resolved                |
| 7     | Memory64 Table Ops            | +37 spec passes                         |
| 8     | Exception Handling            | throw/try_table/exnref                  |
| 9     | Wide Arithmetic               | 4 i128 opcodes                          |
| 10    | Custom Page Sizes             | Non-64KB pages                          |
| 11    | Security Hardening            | Deny-by-default WASI, fuel, W^X         |
| 12    | WAT Parser                    | `zwasm run file.wat`, `-Dwat=false`     |
| 13    | x86_64 JIT Backend            | x86.zig, System V ABI, CI              |
| 14    | Trivial Proposals             | extended_const, branch_hinting, tail_call |
| 15    | Multi-memory                  | memidx for all load/store               |
| 16    | Relaxed SIMD                  | 20 opcodes, NEON mapping                |
| 17    | Function References           | call_ref, generalized ref types         |
| 18    | GC                            | 32 opcodes, struct/array, mark-sweep    |
| 19    | Post-GC Improvements          | GC spec, WASI P1 46/46, collector       |
| 20    | `zwasm features` CLI          | --json, spec level tags                 |
| 21    | Threads                       | 79 atomics, wait/notify                 |
| 22    | Component Model               | WIT, Canon ABI, WASI P2                 |
| 23    | Smart Spill + Direct Call     | 13/21 beat wasmtime, fib 331→91ms       |
| 25    | Lightweight Self-Call         | fib 91→52ms, matches wasmtime (D117)    |

## Stage 26: JIT Peephole Optimizations (PLANNED)

**Goal**: Improve JIT code quality with peephole patterns. No architectural changes.
Binary target: stay under 1.5MB. See D118.

### Analysis (2026-02-14)

zwasm emits `CMP + CSET + CBNZ` (3 insns) per conditional branch where
cranelift emits `CMP + B.cond` (2 insns). nqueens inner loop: 18→~12 (-33%).
Also: redundant MOV chains, suboptimal constant materialization (-1 = 4 insns → 1).

### Current gaps (wasmtime comparison)

| Benchmark    | zwasm   | wasmtime | ratio | category       |
|--------------|---------|----------|-------|----------------|
| st_matrix    | 284.8ms | 86.9ms   | 3.28x | regalloc-bound |
| tgo_mfr      | 59.3ms  | 32.1ms   | 1.85x | memory+loop    |
| st_fib2      | 1086ms  | 686ms    | 1.58x | recursion      |
| tgo_fib      | 43.3ms  | 28.9ms   | 1.50x | recursion      |

st_matrix needs multi-pass regalloc (LIRA) — rejected per D116. Known limitation.
13/21 beat wasmtime, 17/21 within 1.5x, only st_matrix exceeds 2x.

### Task breakdown

- 26.0: Remove wasmer from benchmark infrastructure
- 26.1: CMP+B.cond fusion (ARM64) — RegIR look-ahead in emitCmp32/emitCmp64
- 26.2: CMP+Jcc fusion (x86_64) — same pattern for x86 backend
- 26.3: Redundant MOV elimination — copy propagation tracking
- 26.4: Constant materialization — MVN for -1, MOVN for negatives
- 26.5: Benchmark + evaluate + record

### Exit criteria

- All spec tests pass, no regression, binary ≤ 1.5MB

## Future

- Liveness-based regalloc / LIRA (st_matrix 3.3x — deferred)
- Superinstruction expansion (profile-guided)
- WASI P3 / async
- GC collector upgrade (generational/Immix)

## Benchmark History

| Milestone          | fib(35) | vs wasmtime |
|--------------------|---------|-------------|
| Stage 0 (baseline) | 544ms   | 9.4x        |
| Stage 3 (3.14)     | 103ms   | 2.0x        |
| Stage 5 (5.7)      | 97ms    | 1.72x       |
| Stage 23           | 91ms    | 1.8x        |
| Stage 25           | 52ms    | 1.0x        |
