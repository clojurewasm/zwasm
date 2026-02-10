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

### Remaining
- 3.13: Inline self-call (eliminate trampoline for self-recursive calls)
- 3.14: Spill-only-needed (only spill arg + caller-saved registers)

### Future
- Superinstruction expansion (profile-guided)
- x86_64 JIT backend
- Component Model / WASI P2

**Exit criteria**: fib(35) within 2x of wasmtime JIT. ARM64 JIT stable.

## Benchmark Targets

| Milestone          | fib(35) target | vs wasmtime |
|--------------------|----------------|-------------|
| Stage 0 (baseline) | 544ms          | 9.4x slower |
| Stage 2 + reg IR   | ~200ms         | ~3.5x       |
| Stage 3 baseline   | ~120ms         | ~2x         |
| Stage 3 optimized  | ~80ms          | ~1.4x       |

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
