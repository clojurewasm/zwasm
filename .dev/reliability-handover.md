# Reliability Check — Session Handover

> Progress tracker for `.dev/reliability-plan.md`.
> Read plan for full context. Update after each phase.

## Branch
`strictly-check/reliability` (from main at 7b81746)

## Progress Tracker

- [x] A.1: Create feature branch
- [x] A.2: Expand flake.nix (Go, wasi-sdk 30)
- [ ] A.3: Verify flake.nix on Ubuntu
- [ ] B.1: Rust programs → wasm32-wasip1
- [ ] B.2: Go programs → wasip1/wasm
- [ ] B.3: C programs → wasm32-wasi
- [ ] B.4: C++ programs → wasm32-wasi
- [ ] B.5: Build automation script
- [ ] C.1: Compatibility test runner
- [ ] C.2: Fix compatibility failures
- [ ] C.3: Document unsupported cases
- [ ] D.1: Fix existing E2E failures (15 failures)
- [ ] D.2: Feature-specific E2E tests
- [ ] D.3: Update E2E runner
- [ ] E.1: Real-world benchmarks
- [ ] E.2: Benchmark harness update
- [ ] E.3: Fair benchmark audit
- [ ] E.4: Record baseline
- [ ] F.1: Analyze weak spots
- [ ] F.2: Profile and optimize
- [ ] F.3: JIT nested loop fix (W34)
- [ ] G.1: Push and pull on Ubuntu
- [ ] G.2: Build and test on Ubuntu
- [ ] G.3: Real-world wasm on Ubuntu
- [ ] G.4: Benchmarks on Ubuntu
- [ ] G.5: Fix Ubuntu-only failures
- [ ] H.1: Audit README claims
- [ ] H.2: Fix discrepancies
- [ ] H.3: Update benchmark table

## Current Phase
B complete. C.1 done (first run). Proceeding to C.2 (fix failures).

## Compatibility Test Results (Mac, first run)
12 real-world wasm binaries. 3 PASS, 9 DIFF, 0 CRASH.

Categories of failures:
1. **Test script `--` handling** (3): hello_wasi (C/Go/Rust) — wasmtime receives `--` as argv, zwasm strips it. Fix the test runner.
2. **JIT back-edge bug (W34)** (4): c_matrix_multiply, c_string_processing, cpp_vector_sort, cpp_string_ops — nested loops exceed BACK_EDGE_THRESHOLD (1000), JIT compiles buggy native code, hits unreachable trap. **CRITICAL**: This affects ALL real-world programs with nested loops.
3. **FP precision difference** (1): c_math_compute — 21304744.877962 vs 21304744.878669. Small difference, likely expected.
4. **WASI file I/O** (1): rust_file_io — needs investigation (may also be JIT-related).

**W34 is the #1 priority.** It silently breaks real-world wasm programs from C/C++ when loops iterate enough to trigger back-edge JIT.

## Notes
- Rust: system rustup with wasm32-wasip1 target (not in nix)
- Go: nix provides Go 1.25.5 with wasip1/wasm support
- wasi-sdk: v30, fetched as binary in flake.nix
- Sensitive info (SSH IPs) must NOT be in committed files
