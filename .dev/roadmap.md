# zwasm Roadmap

Independent Zig-native WebAssembly runtime — library and CLI tool.
Benchmark target: **wasmtime**. Optimization target: ARM64 Mac first.

**Strategic Position**: zwasm is an independent Zig Wasm runtime — library AND CLI.
NOT a ClojureWasm subproject. Design for the Zig ecosystem.
Two delivery modes: `@import("zwasm")` library + `zwasm` CLI (like wasmtime).

**Library Consumer Guarantee**: ClojureWasm depends on zwasm main via GitHub URL.
The main branch must always keep CW fully functional (tests, e2e, benchmarks).
All development happens on feature branches; merge to main requires CW verification.
See `.claude/CLAUDE.md` § Branch Policy and Merge Gate Checklist.

## Stage 0: Extraction & Independence (COMPLETE)

**Goal**: Standalone library + CLI, independent of ClojureWasm.

- [x] CW dependency audit and source extraction (10,398 LOC, 11 files)
- [x] Public API design: WasmModule / WasmFn / ImportEntry pattern
- [x] build.zig with library module, tests, benchmark
- [x] 115 tests passing
- [x] MIT license, CW references removed
- [x] CLI tool: `zwasm run`, `zwasm inspect`, `zwasm validate`
- [x] wasmtime comparison benchmark (544ms vs 58ms, 9.4x gap on fib(35))

## Stage 1: Library Quality + CLI Polish (COMPLETE)

**Goal**: Usable standalone Zig library + production CLI comparable to wasmtime basics.

- Ergonomic public API with doc comments
- Structured error types (replace opaque WasmError)
- build.zig.zon metadata (package name, version, description)
- CLI enhancements:
  - `zwasm run` WASI args/env/preopen support
  - `zwasm inspect --json` machine-readable output
  - Exit code propagation from WASI modules
- Example programs (standalone .zig files demonstrating library usage)
- API stability (v0.x semver)

**Exit criteria**: External Zig project can `@import("zwasm")` and run wasm modules.
`zwasm run hello.wasm` works like `wasmtime run hello.wasm` for basic WASI programs.

## Stage 2: Spec Conformance (COMPLETE)

**Goal**: WebAssembly spec test suite passing, publishable conformance numbers.

- Wast test runner (parse .wast, execute assertions)
- MVP spec test pass rate > 95%
- Post-MVP proposals: bulk-memory, reference-types, multi-value
- WASI Preview 1 completion (all syscalls)
- CI pipeline (GitHub Actions, test on push)
- Conformance dashboard / badge

**Exit criteria**: Published spec test pass rates, CI green, WASI P1 complete.

## Stage 3: JIT + Optimization (ARM64)

**Goal**: Close the performance gap with wasmtime via JIT compilation.
Approach: incremental JIT — profile first, register IR, then ARM64 codegen.

### Completed
- 3.1: Profiling infrastructure (opcode frequency + function call counters)
- 3.2: Benchmark suite expansion (3 layers: WAT, TinyGo, shootout)
- 3.3: Profile hot paths (documented in .dev/profile-analysis.md)
- 3.3b: TinyGo benchmark port
- 3.4: Register IR design (D104)
- 3.5: Register IR implementation (stack-to-register conversion)
- 3.6: Register IR validation + peephole optimization
- 3.7: ARM64 codegen design (D105)
- 3.8: ARM64 basic block codegen (i32/i64 arithmetic + control flow)

### Completed (cont.)
- 3.9: Function-level JIT (compile entire hot functions)
- 3.10: Tiered execution (back-edge counting + JitRestart)
- 3.11: JIT call optimization (fast JIT-to-JIT calls)
- 3.12: JIT code quality (direct dest reg, selective reload, shared error epilogue)

### Completed (cont. 2)
- 3.13: Inline self-call (direct BL, cached &vm.reg_ptr in x27)
- 3.14: Spill-only-needed (smart spill: caller-saved + arg vregs only)

**Exit criteria**: fib(35) within 2x of wasmtime JIT. ARM64 JIT stable.
**Result**: fib(35) = 103ms, wasmtime = 52ms, ratio = 2.0x. EXIT CRITERIA MET.

**Performance target**: All benchmarks within 2x of wasmtime (ideal: 1x).
This is an ongoing commitment — keep optimizing until every benchmark meets this bar.
wasmtime source is available locally — study cranelift codegen to close gaps.

## Stage 4: Polish & Robustness (COMPLETE)

**Goal**: Fix known bugs and polish the runtime.

- 4.1: Fix fib_loop TinyGo bug (regalloc local.tee aliasing)
- 4.2: Fix regalloc u8 overflow (graceful fallback to stack IR)
- 4.3: Inline self-call for memory functions (recompute addr via SCRATCH)
- 4.4: Cross-runtime benchmark update (5 runtimes comparison)

## Stage 5: JIT Coverage Expansion (COMPLETE)

**Goal**: All benchmarks within 2x of wasmtime (ideal: 1x).

### Completed
- 5.1: Profile shootout benchmarks + fix doCallDirectIR JIT bypass
- 5.2: Close remaining gaps (regIR opcode coverage)
- 5.3: f64/f32 ARM64 JIT — nbody 133→60ms
- 5.4: Re-record cross-runtime benchmarks
- 5.5: JIT memory ops + call_indirect + popcnt + reload ordering fix
- 5.6: Profile and optimize remaining gaps (SCRATCH/FP caches, inline self-call, peephole)
- 5.7: Re-record benchmarks, verify exit criteria

**Result**: 20/21 benchmarks within 2x of wasmtime. 9 benchmarks faster than wasmtime.
Only st_matrix (3.1x) exceeds threshold — requires liveness-based regalloc (future).

**Exit criteria**: ALL benchmarks within 2x of wasmtime (ideal: 1x).
**Status**: 20/21 met. st_matrix deferred to future liveness regalloc work.

### Future (Stage 5)
- Superinstruction expansion (profile-guided)
- Liveness-based regalloc (st_matrix 3.1x gap)

## Stage 5F: E2E Compliance Completion (COMPLETE)

**Goal**: Resolve remaining E2E and spec test failures.

### Completed
- 5F.1: Fix memory_trap/names spec failures (JIT has_memory + hex batch protocol)
- 5F.2: Fix W9 transitive import chains (linked modules pass imports)

### Deferred
- W10: Store-independent funcref needed for shared table side effects (1 E2E)
- W18: Memory64 table operations — proposal-level feature (37 spec failures)

**Result**: Spec 30,663→30,666 (99.9%). E2E 178→180/181 (99.4%).
Remaining failures require architectural changes (W10) or new proposals (W18).

## Stage 6: Bug Fixes & Stability (COMPLETE)

**Goal**: Fix active JIT bugs discovered during benchmark porting.

- 6.1: Fix JIT prologue caller-saved register corruption (mfr i64 bug)
- 6.2: Investigate remaining active bugs (#3, #4 — closed, unreproducible)
- 6.3: Update checklist (W9 resolved, active bugs cleaned up)

**Result**: All active bugs resolved or closed. JIT stable.

## Stage 7: Memory64 Table Operations (W18)

**Goal**: Complete memory64 proposal table support. Fix 37 spec failures.

Extends existing memory64 support (i64 addresses for load/store/memory.size/grow
already work) to tables. Checklist W18.

### Scope
- 64-bit table limit decoding (limits flag bytes 0x04-0x07)
- `table.size` returns i64 when table has i64 addrtype
- `table.grow` takes i64 delta when table has i64 addrtype
- Update validation for i64 table indices in table.get/set/fill/copy/init
- Binary format: addrtype field in table type

### Key files
- `src/module.zig`: Table type decoding (addrtype), limit decoding
- `src/vm.zig`: table.size/grow/get/set/fill/copy/init instruction handlers
- `src/opcode.zig`: May need new memarg variants
- `src/predecode.zig`: Table instruction validation

### References
- Spec: `~/Documents/OSS/WebAssembly/memory64/proposals/memory64/Overview.md`
- Tests: `test/spec/json/table_size64.json` (36 failures), `memory_grow64.json` (1)
- proposals.yaml: `wasm_3.0.memory64`
- wasmtime impl: `~/Documents/OSS/wasmtime/`

### Exit criteria
- Spec: 30,666 → ≥30,703 (37 new passes)
- E2E: no regression
- CW: no regression

## Stage 8: Exception Handling (W13)

**Goal**: Implement Wasm 3.0 exception handling (exnref).

The largest remaining Wasm 3.0 proposal not yet implemented.
New section (tag), new types (exnref), and structured control flow (try_table).

### Scope
- **Tag section** (section 13): Declare exception tags with type signatures
- **Instructions**: `throw` (0x08), `throw_ref` (0x0a), `try_table` (0x1f)
- **Catch clauses**: catch, catch_ref, catch_all, catch_all_ref
- **Type**: exnref (ref null exn) — exception reference
- **Propagation**: Exceptions unwind the call stack until caught by try_table
- **Traps are NOT caught**: Only thrown exceptions, not runtime traps
- **JIT**: Exception-aware codegen (landing pads, or fallback to interpreter)

### Key files
- `src/module.zig`: Tag section parsing, exnref type
- `src/vm.zig`: throw/throw_ref/try_table instruction handlers
- `src/opcode.zig`: New opcodes (0x08, 0x0a, 0x1f)
- `src/predecode.zig`: Validation for new control flow
- `src/jit.zig`: Exception handling in JIT (may initially fall back to interpreter)

### References
- Spec: `~/Documents/OSS/WebAssembly/exception-handling/proposals/exception-handling/`
- Summary: `.dev/references/proposals/exception-handling.md`
- proposals.yaml: `wasm_3.0.exception_handling`
- E2E blocked: `issue11561.wast`

### Exit criteria
- All exception handling spec tests pass
- E2E: issue11561.wast passes
- No regression on existing tests/benchmarks
- CW: no regression

## Stage 9: Wide Arithmetic (W14)

**Goal**: Implement i128 wide arithmetic operations (4 opcodes).

Small, self-contained proposal. Phase 3.

### Scope
- `i64.add128`: (i64, i64, i64, i64) → (i64, i64) — 128-bit addition
- `i64.sub128`: (i64, i64, i64, i64) → (i64, i64) — 128-bit subtraction
- `i64.mul_wide_s`: (i64, i64) → (i64, i64) — signed widening multiply
- `i64.mul_wide_u`: (i64, i64) → (i64, i64) — unsigned widening multiply

### Key files
- `src/vm.zig`: Instruction handlers (multi-value return via stack)
- `src/opcode.zig`: New opcodes
- `src/predecode.zig`: Validation

### References
- proposals.yaml: `in_progress.wide_arithmetic`
- E2E blocked: `wide-arithmetic.wast`

### Exit criteria
- wide-arithmetic.wast spec tests pass
- No regression
- CW: no regression

## Stage 10: Custom Page Sizes (W15)

**Goal**: Support non-64KB memory page sizes.

Small proposal. Phase 3. Allows memories with 1-byte page granularity.

### Scope
- Memory type gains optional `page_size` field (default 65536)
- `memory.size` / `memory.grow` scale by page_size
- Validation: page_size must be power of 2, max 65536
- Binary format: encoded in limits

### Key files
- `src/module.zig`: Memory type decoding (page_size field)
- `src/vm.zig`: memory.size/grow adjusted for page_size

### References
- proposals.yaml: `in_progress.custom_page_sizes`
- E2E blocked: `memory-combos.wast`

### Exit criteria
- memory-combos.wast passes
- No regression
- CW: no regression

## Stage 11: Security Hardening

**Goal**: Production-ready sandboxing for untrusted Wasm modules.

### Scope
- **Deny-by-default WASI**: Zero capabilities unless explicitly granted.
  CLI defaults: stdio granted. Library: nothing granted.
- **Fine-grained capability flags**: `--allow-read`, `--allow-write`,
  `--allow-env`, `--allow-clock`, etc. Denied → EACCES, not panic.
- **Import validation**: Reject unknown/denied imports at instantiation.
- **Resource limits**: Memory ceiling, fuel/gas metering, stack depth.
- **JIT W^X enforcement**: Separate write and execute phases for JIT pages.
- **Audit trail**: Optional WASI syscall logging.

### Key files
- `src/wasi.zig`: Capability checking per syscall
- `src/vm.zig`: Resource limit enforcement (fuel counter)
- `src/jit.zig`: W^X mmap toggle
- `src/cli.zig`: --allow-* flags
- `src/module.zig`: Import validation at instantiation

### Exit criteria
- All existing tests pass (capabilities granted in test harness)
- New tests for deny scenarios
- CW: no regression (CW grants all needed capabilities)
- Benchmark: no significant regression with capabilities granted

## Stage 12: WAT Parser & Build-time Feature Flags (W17) (COMPLETE)

**Goal**: Native .wat (WebAssembly Text Format) support with optional inclusion.

### Completed
- 12.1: Build-time feature flag system (`-Dwat=false` in build.zig, D106)
- 12.2: WAT S-expression tokenizer (lexer for WAT syntax)
- 12.3: WAT parser — module structure (module, func, memory, table, global, import, export)
- 12.4: WAT parser — instructions (all opcodes, folded S-expr form)
- 12.5: Wasm binary encoder (emit valid .wasm from parsed AST)
- 12.6: WAT abbreviations (named locals/globals/labels, inline exports)
- 12.7: API + CLI integration (loadFromWat, auto-detect .wat)
- 12.8: E2E verification (v128/SIMD support, issue12170.wat validates OK)

**Result**: ~3K LOC wat.zig. `zwasm run file.wat` works. `WasmModule.loadFromWat()` API works.
W17 resolved. issue11563.wat out of scope (multi-module format + GC proposal).

## Stage 13: x86_64 JIT Backend

**Goal**: Port ARM64 JIT to x86_64 for Linux server deployment.

### Scope
- x86_64 code emitter (parallel to existing ARM64 a64.zig)
- Register mapping for x86_64 calling convention (System V AMD64 ABI)
- Same register IR — only codegen differs
- CI validation on ubuntu x86_64
- Reference: `.dev/ubuntu-x86_64.md`

### Exit criteria
- All benchmarks run on x86_64 with JIT
- Performance within 2x of wasmtime on x86_64
- CI green on both ARM64 and x86_64
- CW: no regression

## Future

- Superinstruction expansion (profile-guided)
- Liveness-based regalloc (st_matrix 3.1x gap)
- Component Model / WASI P2 (W7)
- GC proposal (very_high complexity, ~3000 LOC)
- Relaxed SIMD, Multi-memory, Function references
- Threads (shared memory, atomics)

## Benchmark Targets

| Milestone          | fib(35) actual | vs wasmtime |
|--------------------|----------------|-------------|
| Stage 0 (baseline) | 544ms          | 9.4x slower |
| Stage 2 + reg IR   | ~200ms         | ~3.5x       |
| Stage 3 (3.12)     | 224ms          | 4.3x        |
| Stage 3 (3.13)     | 119ms          | 2.3x        |
| Stage 3 (3.14)     | 103ms          | 2.0x        |
| Stage 5 (5.7)      | 97ms           | 1.72x       |

## Phase Notes

### Naming

- zwasm uses "Stage" (not "Phase") to avoid confusion with CW phases
- W## prefix for deferred items (CW uses F##)
- D## prefix shared with CW for architectural decisions (D100+)

### Design Principles

- **Independent Zig library**: API designed for the Zig ecosystem
- **wasmtime as benchmark target**: measure every optimization against wasmtime
- **ARM64 Mac first**: optimize for the primary dev platform, x86_64 later
- **Incremental JIT**: hot function detection → baseline JIT → optimizing JIT
- **Library + CLI**: both modes are first-class, like wasmtime
