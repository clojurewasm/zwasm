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

## Stage 13: x86_64 JIT Backend (COMPLETE)

**Goal**: Port ARM64 JIT to x86_64 for Linux server deployment.

- x86_64 code emitter (x86.zig), arch dispatch from jit.zig
- System V AMD64 ABI calling convention
- CI validation on ubuntu x86_64

**Result**: All benchmarks run on x86_64. CI green on ARM64 + x86_64.

## Stage 14: Wasm 3.0 — Trivial Proposals (COMPLETE)

**Goal**: Three small Wasm 3.0 proposals: extended_const, branch_hinting, tail_call.

**Result**: ~330 LOC total. return_call + return_call_indirect with stack frame reuse.

## Stage 15: Wasm 3.0 — Multi-memory (COMPLETE)

**Goal**: Support multiple memories per module.

- All load/store/memory.size/grow/copy/fill/init get memidx immediate
- Binary format: memarg bit 6 for memidx encoding (memidx between alignment and offset)
- SIMD load/store also extended
- Regalloc bails to predecode IR for memidx != 0

**Result**: 41 multi-memory spec tests pass. 32,231/32,236 total.

## Stage 16: Wasm 3.0 — Relaxed SIMD

**Goal**: Non-deterministic SIMD operations for hardware-native performance.

### Scope
- 20 opcodes under 0xfd prefix (0x100-0x113)
- Categories: relaxed swizzle, relaxed trunc, FMA, laneselect, min/max,
  Q15 multiply, dot products
- Implementation-defined results (NaN handling, out-of-range, FMA rounding)
- ARM64 NEON maps directly for most ops
- ~600 LOC estimated

### Exit criteria
- relaxed-simd spec tests pass (7 test files)
- No regression
- CW: no regression

## Stage 17: Wasm 3.0 — Function References

**Goal**: Typed function references — prerequisite for GC.

### Scope
- 5 opcodes: call_ref (0x14), return_call_ref (0x15), ref.as_non_null (0xd4),
  br_on_null (0xd5), br_on_non_null (0xd6)
- Generalized reference types: `(ref null? heaptype)`
- Local initialization tracking for non-defaultable types
- Table initializer expressions for non-nullable ref tables
- return_call_ref requires tail_call (Stage 14)
- ~800 LOC estimated

### Dependencies
- Stage 14 (tail_call for return_call_ref)

### Exit criteria
- function-references spec tests pass (106 test files)
- No regression
- CW: no regression

## Stage 18: Wasm 3.0 — GC

**Goal**: Struct/array heap objects with garbage collection — the largest proposal.

### Scope
- ~32 opcodes: struct.new/get/set, array.new/get/set/len/fill/copy,
  ref.test/ref.cast, br_on_cast, i31ref, any/extern convert
- New types: struct, array, i31ref, anyref/eqref/structref/arrayref,
  packed i8/i16, recursive type groups (rec)
- Subtyping with depth+width rules
- Actual garbage collector implementation required
- ~3000 LOC estimated

### Dependencies
- Stage 17 (function_references)

### Exit criteria
- GC spec tests pass (109 test files)
- No regression
- CW: no regression

## Stage 19: Post-GC Improvements (PLANNED)

**Goal**: Quality improvements after Wasm 3.0 completion — GC spec tests, table.init fix,
GC collector, WASI P1 full support. ~1,490 LOC, 14 tasks.

### Group A: GC Spec Tests (W21)

Resolve wabt GC WAT format blocker using wasm-tools 1.244.0.

- A1: convert.sh wasm-tools support (~40 LOC)
- A2: run_spec.py GC ref type handling (~50 LOC)
- A3: GC spec execution + pass count recording (~20 LOC)

### Group B: table.init Fix (W2)

614/662 pass, 48 edge case failures (OOB boundaries, dropped segments).

- B1: Failure analysis + fix (~80 LOC)

### Group C: GC Collector (W20)

Mark-and-sweep without compaction. Addresses stay stable, no ref remapping.

- C1: GcSlot + free list (~80 LOC)
- C2: Mark phase — root scan + BFS (~120 LOC)
- C3: Sweep phase — free unmarked + free list (~80 LOC)
- C4: VM integration — threshold trigger (~70 LOC)

### Group D: WASI P1 Full Support (W4/W5)

~27/35 → 35/35. path_open is most critical.

- D1: FdTable + path_open (~250 LOC)
- D2: fd_readdir (~150 LOC)
- D3: fd_renumber + path_symlink + path_link (~120 LOC)
- D4: stub implementations (set_flags, set_times, filestat_get) (~200 LOC)
- D5: poll_oneoff (CLOCK only) (~150 LOC)
- D6: sock_* + remaining (NOSYS stubs) (~80 LOC)

### Execution Order

A1 → A2 → A3 → B1 → C1 → C2 → C3 → C4 → D1 → D2 → D3 → D4 → D5 → D6

### Exit criteria

- GC spec tests converted and running via wasm-tools
- table.init 662/662 pass
- GC collector operational (mark-and-sweep, threshold-triggered)
- WASI P1 35/35 functions implemented
- No regression on existing tests/benchmarks

## Stage 20: `zwasm features` CLI + Spec Compliance Metadata

**Goal**: Machine-readable feature listing. Users and tools can query what's supported.

- 20.1: Add `zwasm features` subcommand — prints table of supported proposals with status
- 20.2: Spec level tags per feature (W3C Recommendation / Finalized / Preview / Not yet)
- 20.3: `--json` output for machine consumption

~200 LOC. No runtime changes.

## Stage 21: Threads (Shared Memory + Atomics)

**Goal**: Core Wasm threads proposal. Shared memory, atomic ops, wait/notify.

Reference: wasmtime cranelift atomics, spec repo `~/Documents/OSS/WebAssembly/threads`.

- 21.1: Shared memory flag in memory section, SharedArrayBuffer-style backing
- 21.2: Atomic load/store/rmw opcodes (i32/i64) — 57 opcodes
- 21.3: memory.atomic.wait32/wait64/notify
- 21.4: atomic.fence
- 21.5: Spec tests + validation

~1,500 LOC. Core spec (Phase 4, browser-shipped).

## Stage 22: Component Model (W7)

**Goal**: Full Component Model support. WIT parsing, Canonical ABI, component linking.
wasmtime is reference impl. Staged approach — each group is independently useful.

### Design Principles

- **Default ON** for W3C Recommendation and finalized proposals
- **Implement all** that wasmtime supports — zwasm tracks spec frontier
- **Minimal flags** — no rights/caps complexity. WASI access is binary (on/off)
- **`zwasm features`** lists what's confirmed spec vs preview

### Group A: WIT Parser (~800 LOC)

WIT (WebAssembly Interface Types) IDL parser. Standalone, no runtime dependency.

- A1: WIT lexer + token types
- A2: WIT parser — interfaces, worlds, types, functions
- A3: WIT resolution — use declarations, package references
- A4: Unit tests + wasmtime WIT corpus validation

### Group B: Component Binary Format (~1,200 LOC)

Decode component-model binary sections (layered on top of core module decoder).

- B1: Component section types (component, core:module, instance, alias, etc.)
- B2: Component type section — func types, component types, instance types
- B3: Canon section — lift/lower/resource ops
- B4: Start, import, export sections
- B5: Nested component/module instantiation

### Group C: Canonical ABI (~1,500 LOC)

Value lifting/lowering between component-level types and core Wasm linear memory.

- C1: Scalar types (bool, integers, float, char)
- C2: String encoding (utf-8/utf-16/latin1+utf-16)
- C3: List, record, tuple, variant, enum, option, result
- C4: Flags, own/borrow handles
- C5: Memory realloc protocol + post-return

### Group D: Component Linker + WASI P2 (~2,000 LOC)

Wire components together. Implement WASI Preview 2 interfaces.

- D1: Component instantiation — resolve imports, create instances
- D2: Virtual adapter pattern — P1 compat shim
- D3: WASI P2 interfaces — wasi:io, wasi:clocks, wasi:filesystem, wasi:sockets
- D4: `zwasm run` component support (detect component vs module automatically)
- D5: Spec tests + integration

### Execution Order

20 → 21 → 22A → 22B → 22C → 22D

Each stage is independently mergeable. Stage 22 groups can be paused/resumed
at group boundaries if spec changes require waiting.

### Exit Criteria

- `zwasm features` shows all proposals with correct status
- Threads spec tests pass
- Component Model: can instantiate and run wasmtime component test suite

## Stage 23: JIT Optimization — Smart Spill + Direct Call (COMPLETE)

**Goal**: Close performance gap with wasmtime through JIT micro-optimizations.

Systematic optimization pass: liveness-based spill/reload, direct call emission,
FP register cache (D2-D7), inline self-call with caller-saved analysis,
vm_ptr/inst_ptr/reg_ptr caching in callee-saved registers.

### Key Results
- 13/21 benchmarks match or beat wasmtime (was 9/21)
- fib: 331ms → 91ms (Stage 3.10 → 23.5)
- nbody: 42ms → 9ms (now 0.4x wasmtime)

### Exit Criteria
- All spec tests pass
- No performance regression on any benchmark
- Benchmark recording at stage completion

## Stage 25: Lightweight Self-Call (COMPLETE)

**Goal**: Reduce per-call overhead for self-recursive functions.

Root cause analysis: 6 STP + 6 LDP (12 instructions) per recursive call was the
bottleneck. wasmtime uses tail calling convention (no callee-saved overhead).

Dual entry point: normal entry saves all callee-saved regs, self-call entry saves
only x29,x30. x29 flag (SP vs 0) controls conditional epilogue (CBZ x29).
Caller saves/restores only live callee-saved vregs via liveness analysis.

### Key Results
- fib: 91ms → 52ms (-43%), now matches wasmtime (1.0x)
- st_fib2: 1310ms → 1073ms (-18%)
- No regressions on non-recursive benchmarks
- See D117

### Exit Criteria
- All spec tests pass (61,640+)
- fib benchmark improved
- Binary ≤ 1.5MB (actual: 1.1MB)
- WASI P2: basic filesystem/clock/random via component interfaces

## Future

- Superinstruction expansion (profile-guided)
- Liveness-based regalloc (st_matrix 3.1x gap)
- WASI P3 / async (depends on CM Stage 22)
- GC collector upgrade (generational/Immix)

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
