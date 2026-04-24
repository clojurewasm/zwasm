# zwasm Roadmap

Zig-native WebAssembly runtime — library and CLI.

**Library Consumer Guarantee**: ClojureWasm depends on zwasm main via GitHub URL.
All development on feature branches; merge to main requires Merge Gate.

## Current State

All major features complete. 100% spec conformance. 4-platform JIT with SIMD.

| Metric        | Value                                                     |
|---------------|-----------------------------------------------------------|
| Spec tests    | 62,263/62,263 (100%, 0 skip)                              |
| E2E tests     | 792/792                                                   |
| Real-world    | 50/50                                                     |
| Binary        | 1.23 MB stripped                                          |
| Memory        | ~3.5 MB RSS                                               |
| Platforms     | macOS ARM64, Linux x86_64/ARM64, Windows x86_64           |
| JIT           | ARM64 + x86_64, SIMD (NEON 253/256, SSE 244/256)         |
| Proposals     | Wasm 3.0 all 9 + wide arithmetic + custom page sizes      |

Completed stages/phases: 0-47, 1, 3, 5, 8, 10, 11, 13, 15, 19.
Details: `roadmap-archive.md`.

## Upcoming Work

### Stability: Spec Tracking & Platform Maintenance

| Task                        | Priority | Description                                       |
|-----------------------------|----------|---------------------------------------------------|
| Zig version upgrade         | High     | Prepare for Zig 0.16 (breaking API changes)       |
| Spec test auto-bump         | Active   | Weekly CI (spec-bump.yml). Review failures.        |
| wasm-tools tracking         | Active   | Monthly CI (wasm-tools-bump.yml)                   |
| SpecTec monitoring          | Active   | Weekly CI (spectec-monitor.yml)                    |
| Debug/ReleaseSafe parity    | Medium   | i128 x86_64 Debug bug; audit other divergences     |

### Performance

| Task                           | Priority | Impact                                    |
|--------------------------------|----------|-------------------------------------------|
| ~~W37: Contiguous v128~~       | Done     | LDR Q / STR Q single-instruction v128     |
| ~~W38: Lazy AOT perf~~         | Done     | HOT_THRESHOLD 10→3, back_edge_bailed      |
| Multi-value return JIT         | Medium   | wide-arithmetic, multi-return fn JIT      |
| ~~SIMD register class (W44)~~  | Done     | Q16-Q31/XMM6-15 cache, lazy writeback     |
| ~~v128 addr cache (W43)~~      | Done     | SIMD_BASE_REG caches simd_v128 base addr  |
| **SIMD loop persistence (W45)**| **High** | **Keep Q regs across loop iters (78x→10x gap)** |
| SIMD bounds check elim         | Medium   | Guard pages for v128.load/store            |
| SIMD FMLA fusion               | Low      | mul+add → FMLA peephole                   |
| Lazy compilation (Phase 18.2)  | Low      | Defer JIT to first call, faster startup   |

### Ecosystem & Usability

| Task                       | Priority | Description                                     |
|----------------------------|----------|-------------------------------------------------|
| ~~PR #6: Timeout support~~ | Done     | Merged 2026-03-08. DeanoC.                       |
| ~~Epoch-based JIT check~~  | Done     | D131: fuel check helper replaces jitSuppressed   |
| CLI: `zwasm dump`          | Low      | Detailed module inspection                       |
| CLI: `zwasm bench`         | Low      | Built-in benchmark runner                        |
| Homebrew formula           | Low      | `brew install clojurewasm/tap/zwasm`             |
| WASI P2 native             | Future   | Currently via P1 adapter; direct P2 support      |

### Reliability

| Task                          | Priority | Description                                  |
|-------------------------------|----------|----------------------------------------------|
| SIMD JIT fuzz coverage        | Medium   | Extend fuzz harness for SIMD code paths      |
| ASan/Valgrind in CI           | Low      | Automated memory safety checks               |
| vm.zig decomposition          | Future   | 10.2K lines; consider splitting              |

### Spec Proposals (when they mature)

| Proposal           | Wasm Phase | Status                            |
|--------------------|------------|-----------------------------------|
| Stack Switching    | Phase 3    | Monitor; implement when Phase 4   |
| WASI P3 / Async   | Draft      | After wasmtime stabilizes         |
| Memory Control     | Phase 1    | Monitor                           |
| Branch Hinting v2  | Phase 2    | Monitor                           |

## Version History

| Version    | Key Changes                                                  |
|------------|--------------------------------------------------------------|
| **v1.6.1** | Windows port, JIT reliability, W35 fix                       |
| **v1.5.0** | Allocator injection, C API config, embedding docs            |
| **v1.3.0** | Guard pages, module cache, CI automation                     |
| **v1.0.0** | First stable release. Wasm 3.0, ARM64+x86 JIT, 100% spec    |

## Benchmark History

| Milestone          | fib(35) | vs wasmtime |
|--------------------|---------|-------------|
| Stage 0 (baseline) | 544ms   | 9.4x        |
| Stage 3 (JIT)      | 103ms   | 2.0x        |
| Stage 25 (self-call)| 52ms   | 1.0x        |
| Phase 13 (SIMD)    | 46ms    | 0.9x        |

## Merge Gate Checklist

All items must pass on **Mac AND Ubuntu x86_64** before merging to main.

- `zig build test` — all pass, 0 fail, 0 leak
- `python3 test/spec/run_spec.py --build --summary` — fail=0, skip=0
- `bash test/e2e/run_e2e.sh --convert --summary` — fail=0
- `bash test/realworld/run_compat.sh` — PASS=50, FAIL=0, CRASH=0
- `bash test/c_api/run_ffi_test.sh --build` — 0 failed
- `zig build test -Djit=false -Dcomponent=false -Dwat=false` — 0 fail
- Binary ≤ 1.80 MB (stripped; Linux ELF. Mac ~1.38 MB), memory ≤ 4.5 MB RSS
  - Raised from 1.50 MB in v1.10.0 for 0.16 `link_libc`; return to 1.50 MB targeted post-`std.Io` migration.
