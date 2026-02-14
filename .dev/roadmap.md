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
