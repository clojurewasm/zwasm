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
| 26    | JIT Peephole Optimizations    | CMP+B.cond fusion, MOVN constants       |

## v0.3.0 Roadmap

Target: spec compliance, thread support, close remaining perf gaps.

### Stage 27: Platform Verification + Spec Runner Hardening

- Ubuntu x86_64 verification of Stage 26 (CMP+Jcc fusion)
- Switch spec runner default build to ReleaseSafe (eliminates 11 tail-call timeouts)
- Migrate all tooling from wabt to wasm-tools (check latest version)
- Remove wabt references from docs and rules

### Stage 28: Spec Test Improvements

- Regenerate GC spec tests with wasm-tools (currently 74 failures, mostly wabt limitation)
- Investigate multi-module 33 failures — check history for regressions, may be spec runner config
- threads 4 failures — deferred until Stage 29

### Stage 29: Thread Execution

- Set up build toolchain (Emscripten/Rust wasm32-wasip1-threads)
- Create thread test suite (pthread-based wasm samples)
- Implement thread spawning mechanism in zwasm if missing
- Fix remaining 4 threads spec failures

### Stage 30: Performance Gap Analysis + Improvements

Single-pass constraint maintained. Codegen analysis of cranelift output.

- **st_matrix (3.3x)**: Investigate MAX_PHYS_REGS expansion (ARM64 has 30 GPRs),
  liveness hints, loop-local register pressure reduction. D116 rejected LIRA but
  other single-pass approaches may help.
- **tgo_mfr (1.6x)**: Analyze cranelift codegen for loop optimizations
  (LICM, strength reduction, base+offset precomputation).
- Deliverable: analysis doc with feasibility estimates before implementation.

### Stage 31: GC Benchmarks + Collector Assessment

- Create GC stress test suite (WAT: mass alloc, reference graph, partial free, realloc loop)
- Benchmark zwasm vs wasmtime vs node on GC workloads
- Identify bottleneck (allocation, collection, pause time)
- Decide on collector improvement scope based on data

### Exit criteria for v0.3.0

- Spec pass rate improved (target: GC + multi-module resolved)
- Thread execution working with test suite
- st_matrix / tgo_mfr gaps analyzed, improved where feasible
- GC performance baselined

## Future (post v0.3.0)

- WASI P2 full interface coverage
- WASI P3 / async
- GC collector upgrade (generational/Immix) — pending Stage 31 analysis
- Liveness-based regalloc / LIRA — if Stage 30 shows single-pass limit

## Benchmark History

| Milestone          | fib(35) | vs wasmtime |
|--------------------|---------|-------------|
| Stage 0 (baseline) | 544ms   | 9.4x        |
| Stage 3 (3.14)     | 103ms   | 2.0x        |
| Stage 5 (5.7)      | 97ms    | 1.72x       |
| Stage 23           | 91ms    | 1.8x        |
| Stage 25           | 52ms    | 1.0x        |
