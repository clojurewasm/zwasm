# zwasm Roadmap

Independent Zig-native WebAssembly runtime — library and CLI tool.
Benchmark target: **wasmtime**. Optimization target: ARM64 Mac first.

**Strategic Position**: zwasm is an independent Zig Wasm runtime — library AND CLI.
NOT a ClojureWasm subproject. Design for the Zig ecosystem.
Two delivery modes: `@import("zwasm")` library + `zwasm` CLI (like wasmtime).

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

## Stage 4: Polish & Robustness (COMPLETE)

**Goal**: Fix known bugs and polish the runtime.

- 4.1: Fix fib_loop TinyGo bug (regalloc local.tee aliasing)
- 4.2: Fix regalloc u8 overflow (graceful fallback to stack IR)
- 4.3: Inline self-call for memory functions (recompute addr via SCRATCH)
- 4.4: Cross-runtime benchmark update (5 runtimes comparison)

## Stage 5: JIT Coverage Expansion

**Goal**: Close the remaining performance gaps with wasmtime.
Key gaps: shootout 23-33x slower (not JIT'd), nbody 6.2x (no f64 JIT).

### Tasks
- 5.1: Profile shootout benchmarks — identify JIT coverage gaps
- 5.2: Close identified gaps (JIT threshold, opcode coverage)
- 5.3: f64 ARM64 JIT — codegen for f64 operations
- 5.4: Re-record cross-runtime benchmarks

**Exit criteria**: Shootout benchmarks within 5x of wasmtime. nbody within 3x.

### Future
- Superinstruction expansion (profile-guided)
- x86_64 JIT backend
- Component Model / WASI P2

## Benchmark Targets

| Milestone          | fib(35) actual | vs wasmtime |
|--------------------|----------------|-------------|
| Stage 0 (baseline) | 544ms          | 9.4x slower |
| Stage 2 + reg IR   | ~200ms         | ~3.5x       |
| Stage 3 (3.12)     | 224ms          | 4.3x        |
| Stage 3 (3.13)     | 119ms          | 2.3x        |
| Stage 3 (3.14)     | 103ms          | 2.0x        |

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
