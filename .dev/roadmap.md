# zwasm Roadmap

Zig-native embeddable WebAssembly runtime, extracted from ClojureWasm.

## Stage 0: API Design & Extraction

**Goal**: Clean separation from CW, standalone library that compiles and passes basic tests.

- CW dependency audit (identify all CW-specific imports)
- Public API design: Engine / Module / Instance pattern
- Source extraction from CW `src/wasm/` → zwasm `src/`
- Remove CW dependencies (Value, GC, Env, error.zig coupling)
- build.zig + build.zig.zon (Zig package manager)
- Basic test suite (module loading, function calls, memory, tables)
- First benchmark (wasm fib, compare with CW embedded interpreter)
- CW integration: consume zwasm as build.zig.zon dependency

**Exit criteria**: `zig build test` passes, CW uses zwasm as dependency without regression.

## Stage 1: Library Quality

**Goal**: Usable by external Zig projects, not just CW.

- Ergonomic public API with documentation
- Error handling refinement (structured errors, not CW EvalError)
- Example programs (load & run wasm, WASI hello world, host functions)
- build.zig.zon metadata (package name, version, description)
- CW builtins.zig uses only zwasm public API (no internal imports)
- API stability commitment (v0.x semver)

**Exit criteria**: External Zig project can `@import("zwasm")` and run wasm modules.

## Stage 2: Spec Conformance

**Goal**: WebAssembly spec test suite passing, publishable conformance numbers.

- Wast test runner (parse .wast, execute assertions)
- MVP spec test pass rate > 95%
- Post-MVP proposals: bulk-memory, reference-types, multi-value
- WASI Preview 1 completion (all syscalls)
- CI pipeline (GitHub Actions, test on push)
- Conformance dashboard / badge

**Exit criteria**: Published spec test pass rates, CI green, WASI P1 complete.

## Stage 3: Optimization & Advanced Features

**Goal**: Performance competitive with wasm3, advanced Wasm features.

- Register-based IR (reduce stack traffic)
- JIT compilation (ARM64 first, then x86_64)
- Superinstruction expansion (beyond current 11 fused ops)
- WASI Preview 2 (component model basics)
- Component Model support
- Profiling infrastructure (opcode frequency, hot path analysis)

**Exit criteria**: Benchmark parity with wasm3, Component Model MVP.

## Phase Notes

### Naming

- zwasm uses "Stage" (not "Phase") to avoid confusion with CW phases
- W## prefix for deferred items (CW uses F##)
- D## prefix shared with CW for architectural decisions

### Cross-project

- CW Phase 45 (Wasm Runtime Optimization) work benefits zwasm directly
- CW's predecoded IR, superinstructions, VM reuse are carried over
- JIT work (CW D87) informs Stage 3 design
