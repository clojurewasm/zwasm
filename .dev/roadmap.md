# zwasm Roadmap

Independent Zig-native WebAssembly runtime — library and CLI tool.
Benchmark target: **wasmtime**. Optimization target: ARM64 Mac first.

**Library Consumer Guarantee**: ClojureWasm depends on zwasm main via GitHub URL.
All development on feature branches; merge to main requires Merge Gate.

## Completed (v1.2.0)

Stages 0-46 complete. Details: `roadmap-archive.md`.

- Wasm 3.0: all 9 proposals (581+ opcodes). WASI P1 46/46. WAT parser.
- JIT: Register IR + ARM64/x86_64. Spec: 62,263/62,263 (100%, 0 skip).
- E2E: 792/792 (0 leak). Real-world: 50/50. Fuzz: 10K+ iterations, 0 crashes.
- Size: 1.20MB stripped / 4.48MB RSS. Mac + Ubuntu x86_64.

## Future Phases (zwasm only)

Integrated roadmap (zwasm + CW): `private/future/03_zwasm_clojurewasm_roadmap_ja.md`
CW-specific phases (2, 4, 6, 7, 9, 14, 16, 17) are in that document only.

### Phase 1: Guard Pages + Module Cache — COMPLETE

Performance impact: highest of remaining items. Improvements propagate to CW.

**1.1 Virtual Memory Guard Pages — COMPLETE**

Already implemented: guard.zig (mmap/mprotect/signal handler), memory.zig (initGuarded),
store.zig (auto-use when JIT supported), jit.zig/x86.zig (bounds check elimination),
cli.zig (signal handler install).

**1.2 Module Cache / AOT Serialize — COMPLETE (D124)**

- `cache.zig`: serialize predecoded IR to `~/.cache/zwasm/<hash>.zwcache`
- `zwasm run --cache` option + `zwasm compile` command
- Cache invalidation: SHA-256 hash + version field
- All tests pass (spec 62,263/62,263, E2E 792/792, real-world 50/50)

**Gate**: PASSED. zwasm v1.3.0 candidate.

### Phase 3: CI Automation + Documentation — COMPLETE

**3.1 CI Automation**

- `.github/tool-versions`: centralized WASM_TOOLS, WASMTIME, WASI_SDK versions
- `spec-bump.yml`: weekly spec testsuite auto-bump (Monday 04:00 UTC)
- `wasm-tools-bump.yml`: monthly wasm-tools version update (1st, 05:00 UTC)
- `spectec-monitor.yml`: weekly SpecTec change detection (Monday 06:00 UTC)
- `nightly.yml`: re-enabled as weekly (Wednesday 03:00 UTC)
- D125 decision record, `.dev/proposal-watch.md`

**3.2 Documentation**

- `ARCHITECTURE.md`: pipeline diagram + 28-file map + test suites
- `docs/data-structures.md`: key types by pipeline stage
- `//!` doc comments on fuzz harness files
- `Affected files:` references on all D100-D125 decisions

**Gate**: PASSED.

### Phase 5: C API + Conditional Compilation — COMPLETE

**5.1 C API (D126)**

- `src/c_api.zig`: 25 exported `zwasm_*` functions via C ABI
  - Module lifecycle: `new`, `new_wasi`, `new_wasi_configured`, `new_with_imports`, `delete`, `validate`
  - Invocation: `invoke`, `invoke_start`
  - Memory: `memory_data`, `memory_size`, `memory_read`, `memory_write`
  - Exports: `export_count`, `export_name`, `export_param_count`, `export_result_count`
  - WASI config: `wasi_config_new/delete/set_argv/set_env/preopen_dir`
  - Host imports: `import_new/delete/add_fn`
  - Error: `last_error_message`
- `include/zwasm.h`: single C header
- `libzwasm.so` / `.dylib` / `.a` build targets (`zig build lib`)
- C tests (`test/c_api/test_basic.c`), C example, Python ctypes example

**5.2 Conditional Compilation (D127)**

- Feature flags: `-Djit=false`, `-Dcomponent=false`, `-Dwat=false`
  (SIMD/GC/threads flags defined but not yet guarded — low savings)
- Minimal build: ~940KB stripped (24% reduction from full)
- CI `size-matrix` job: 5 build variants

**Gate**: PASSED.

### Phase 8: Real-World Coverage + WAT Parity — COMPLETE

**8.1 Real-World Coverage: 50 programs**

- TinyGo (4), C (9), C++ (1), Go (2), Rust (4) + existing (30) = 50
- Stress tests: deep recursion, large memory, many functions
- W30 JIT bug: five codegen fixes (guard recovery, instrDefinesRd,
  callee-saved liveness, x86 emitCall, emitInlineSelfCall ordering)
- Deferred: SQLite + Lua (complex wasm, future work)

**8.2 WAT Spec Parity: 100%**

- WAT roundtrip: 62,259/62,259 (100%)
- 708 conv-fail = wasm-tools can't convert malformed .wasm (expected)

**Gate**: PASSED. Mac + Ubuntu compat 50/50, spec 62,263/62,263, E2E 792/792.

### Phase 10: Quality / Stabilization (zwasm portion, 1 day)

- Full test suite re-verification (Mac + Ubuntu)
- Benchmark regression check
- Size guard confirmation (≤ 1.5MB)
- Merge Gate pass

**Gate**: All test suites pass. No regressions.

### Phase 13: SIMD JIT (5 days)

Largest technical challenge.

- SIMD microbenchmark suite
- RegIR v128 register class extension
- ARM64 NEON + x86 SSE codegen (top 20 instructions)
- Target: st_matrix gap 22.3x → ≤ 5x
- Size guard ≤ 1.5MB

**Gate**: SIMD bench faster than scalar. zwasm v2.0.0 candidate.

### Phase 15: Windows Port (3 days)

- D## decision record (SEH, VirtualAlloc, CI strategy)
- Memory management OS abstraction (mmap → VirtualAlloc)
- Signal handler port (SIGSEGV → SEH)
- JIT W^X port (VirtualProtect + FlushInstructionCache)
- WASI filesystem Windows branch
- CI Windows job + release binaries

**Gate**: Windows x86_64 all tests pass. 3-OS support complete.

### Phase 18: Book i18n + Lazy Compilation + CLI Extensions (3 days)

**18.1 Book i18n (1 day)**

- `book/en/` + `book/ja/` structure
- Japanese translation + language switcher

**18.2 Lazy Compilation (1 day)**

JIT deferred to first call. Trampoline → direct jump patch.

**18.3 CLI Extensions (1 day)**

- `zwasm dump` (detailed module dump)
- `zwasm bench` (built-in benchmark runner)
- `zwasm diff` (module comparison)
- Fuel API docs + Memory growth callback

## Future (timeline TBD)

| Item | Condition |
|------|-----------|
| Stack Switching | Proposal reaches Phase 4 |
| WASI P3 / Async | After wasmtime stabilizes |
| Copy-and-Patch JIT | When technique matures |
| GC collector upgrade (generational/Immix) | D121 arena approach sufficient for now |
| Liveness-based regalloc / LIRA | Rejected (D116/D120), single-pass sufficient |

## Version Milestones

| Version | Phases | Key Results |
|---------|--------|-------------|
| **v1.3.0** | 1, 3 | Guard pages, cache, CI automation, ARCHITECTURE.md |
| **v1.4.0** | 5, 8 | C API, conditional compilation, 50+ real-world, WAT parity |
| **v2.0.0** | 13, 15 | SIMD JIT, Windows, 3-OS support |

## Benchmark History

| Milestone          | fib(35) | vs wasmtime |
|--------------------|---------|-------------|
| Stage 0 (baseline) | 544ms   | 9.4x        |
| Stage 3 (3.14)     | 103ms   | 2.0x        |
| Stage 5 (5.7)      | 97ms    | 1.72x       |
| Stage 23           | 91ms    | 1.8x        |
| Stage 25           | 52ms    | 1.0x        |
