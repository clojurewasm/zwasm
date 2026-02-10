# zwasm Roadmap

Independent Zig-native WebAssembly runtime — library and CLI tool.
Benchmark target: **wasmtime**. Optimization target: ARM64 Mac first.

## Stage 0: Extraction & Independence (COMPLETE)

**Goal**: Standalone library + CLI, independent of ClojureWasm.

- [x] CW dependency audit and source extraction (10,398 LOC, 11 files)
- [x] Public API design: WasmModule / WasmFn / ImportEntry pattern
- [x] build.zig with library module, tests, benchmark
- [x] 115 tests passing
- [x] MIT license, CW references removed
- [x] CLI tool: `zwasm run`, `zwasm inspect`, `zwasm validate`
- [x] wasmtime comparison benchmark (544ms vs 58ms, 9.4x gap on fib(35))

## Stage 1: Library Quality + CLI Polish

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

## Stage 2: Spec Conformance

**Goal**: WebAssembly spec test suite passing, publishable conformance numbers.

- Wast test runner (parse .wast, execute assertions)
- MVP spec test pass rate > 95%
- Post-MVP proposals: bulk-memory, reference-types, multi-value
- WASI Preview 1 completion (all syscalls)
- CI pipeline (GitHub Actions, test on push)
- Conformance dashboard / badge

**Exit criteria**: Published spec test pass rates, CI green, WASI P1 complete.

## Stage 3: JIT + Optimization (ARM64)

**Goal**: Close the 9.4x performance gap with wasmtime via JIT compilation.

Approach: incremental JIT — start with hot functions, fall back to interpreter.

### 3.1 Profiling Infrastructure
- Opcode frequency counters (identify hot paths)
- Function call counters (identify hot functions)
- Benchmark suite expansion (fib, tak, sieve, nbody, binary-trees)

### 3.2 Register IR
- Convert stack-based Wasm to register-based IR
- Reduce stack traffic (biggest interpreter overhead)
- Validate: fib(35) should be 2-3x faster with register IR alone

### 3.3 ARM64 JIT (Mac)
- ARM64 code generation for basic blocks
- Function-level JIT (compile entire functions)
- Tiered: interpreter → baseline JIT → optimizing JIT
- Target: close to wasmtime single-pass tier (2-3x gap acceptable)

### 3.4 Superinstruction Expansion
- Profile-guided superinstruction generation
- Beyond current 11 fused ops
- Combine with register IR for maximum interpreter speedup

### 3.5 Advanced Optimization
- WASI Preview 2 (component model basics)
- Component Model support
- x86_64 JIT backend
- Parallel compilation (compile modules on background threads)

**Exit criteria**: fib(35) within 2x of wasmtime JIT. ARM64 JIT stable.

## Benchmark Targets

| Milestone          | fib(35) target | vs wasmtime |
|--------------------|----------------|-------------|
| Stage 0 (current)  | 544ms          | 9.4x slower |
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
