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

**Performance target**: All benchmarks within 2x of wasmtime (ideal: 1x).
This is an ongoing commitment — keep optimizing until every benchmark meets this bar.
wasmtime source is available locally — study cranelift codegen to close gaps.

## Stage 4: Polish & Robustness (COMPLETE)

**Goal**: Fix known bugs and polish the runtime.

- 4.1: Fix fib_loop TinyGo bug (regalloc local.tee aliasing)
- 4.2: Fix regalloc u8 overflow (graceful fallback to stack IR)
- 4.3: Inline self-call for memory functions (recompute addr via SCRATCH)
- 4.4: Cross-runtime benchmark update (5 runtimes comparison)

## Stage 5: JIT Coverage Expansion (IN PROGRESS)

**Goal**: All benchmarks within 2x of wasmtime (ideal: 1x).
This is the primary optimization stage — keep adding JIT features until the target is met.

### Completed
- 5.1: Profile shootout benchmarks + fix doCallDirectIR JIT bypass
- 5.2: Close remaining gaps (regIR opcode coverage)
- 5.3: f64/f32 ARM64 JIT — nbody 133→60ms
- 5.4: Re-record cross-runtime benchmarks
- 5.5: JIT memory ops + call_indirect + popcnt + reload ordering fix

### Current gaps (vs wasmtime, from bench YAML at 5.5)
- st_matrix: ~3.8x — biggest remaining gap, needs profiling
- st_fib2: ~2.3x — close but above 2x target
- nbody: ~2.4x — needs improvement
- fib: ~2.0x — at compromise target, not at ideal
- st_sieve: ~2.1x — close to compromise target
- st_nestedloop, st_ackermann: ≤1.1x — at parity

### Remaining tasks
- 5.6: Profile and optimize remaining gaps
- 5.7: Re-record benchmarks, verify exit criteria

**Exit criteria**: ALL benchmarks within 2x of wasmtime (ideal: 1x).

### Future
- Superinstruction expansion (profile-guided)
- x86_64 JIT backend
- Component Model / WASI P2
- Capability-based security hardening (see below)

## Stage 5F: E2E Compliance Completion

**Goal**: Resolve ALL remaining E2E test failures and skipped files.
Currently 169/179 pass (94.4%) with 10 failures and 6 skipped files.
Target: 179/179 pass (100%), all skipped files either passing or permanently
excluded with rationale.

### Actionable now (no new proposal support needed)

- 5F.1: W8 — Cross-module type canonicalization (5 e2e failures)
  Fix call_indirect across modules. Remap imported function type indices
  to match the calling module's type table using structural comparison.
  Key file: `src/types.zig` registerImports().
  Reference: wasmtime `wasmtime-environ/src/module.rs`.

- 5F.2: W9 — Cross-module table func ref remap edge cases (4 e2e failures)
  Fix null refs, type index mismatches, and multi-hop import chains in
  table sharing. Key file: `src/types.zig` registerImports() table branch.

- 5F.3: W1 + W2 — table.copy cross-table + table.init (310 spec failures)
  Implement the stubbed table operations. These also block the 262
  table_copy spec test failures. Key file: `src/vm.zig`.

- 5F.4: W10 — Test runner assert_uninstantiable side effects (1 e2e failure)
  Extend run_spec.py to track instantiation side effects across modules
  within a single test file.

- 5F.5: W17 — .wat file support in test runner (2 skipped files)
  Add wat2wasm compilation path to run_spec.py for .wat test files.

- 5F.6: W16 — wast2json NaN literal upgrade (1 skipped file)
  Upgrade wabt or add pre-processor for NaN literal syntax.

### Requires new proposal support (future)

- W13: Exception handling — issue11561.wast (large effort, Wasm 3.0)
- W14: Wide arithmetic — wide-arithmetic.wast (medium effort, newer proposal)
- W15: Custom page sizes — memory-combos.wast (small effort, newer proposal)

### Exit criteria

- All e2e tests that don't require unimplemented proposals: 100% pass
- table_copy/table_init spec tests: 0 failures (W1, W2 resolved)
- Skipped files reduced to only those requiring unimplemented Wasm 3.0 proposals

## Future: Sandbox & Security Hardening

Wasm's core value proposition is **sandboxed execution** — untrusted code runs in
an isolated environment with no ambient authority. The runtime must uphold this
guarantee. Currently zwasm provides basic isolation (linear memory bounds, no raw
host pointers) but lacks explicit capability control for WASI.

### Current state
- Linear memory is bounds-checked (interpreter and JIT)
- Filesystem access requires explicit `--dir` preopen (no ambient FS access)
- stdin/stdout/stderr are always available (common convention, matches wasmtime)
- No network, no process spawn, no signal handling
- WASI syscalls are all-or-nothing: if WASI is linked, all implemented syscalls
  are available to the module

### What needs to change
- **Deny-by-default WASI**: Modules should get zero WASI capabilities unless the
  embedder (CLI or library caller) explicitly grants them. Even stdio should be
  opt-in for library usage (CLI can default to granting stdio for usability).
- **Fine-grained capability flags**: `--allow-read`, `--allow-write`,
  `--allow-env`, `--allow-clock`, etc. A module requesting `fd_write` on a
  path it wasn't granted should get `EACCES`, not a host panic.
- **Import validation**: Reject unknown or denied imports at instantiation time
  rather than trapping at call time. Fail fast, fail loud.
- **Resource limits**: Memory ceiling, execution timeout (fuel/gas metering),
  stack depth limits — all configurable by the embedder.
- **JIT W^X enforcement**: JIT code pages should be mapped W^X (write XOR
  execute). Currently mmap'd as RWX for simplicity; production use requires
  toggling between writable-not-executable and executable-not-writable.
- **Audit trail**: Optional logging of all WASI syscalls for security review.

### Priority
This is not urgent while zwasm is pre-release and used only by trusted code
(ClojureWasm dog fooding). It becomes critical before any public release where
users might run untrusted Wasm modules. Plan as a dedicated stage after
performance work stabilizes.

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
