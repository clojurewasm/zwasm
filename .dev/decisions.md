# Design Decisions

Architectural decisions for zwasm. Reference by searching `## D##`.
Only architectural decisions — not bug fixes or one-time migrations.
Shares D## numbering with ClojureWasm (start from D100 to avoid conflicts).

D100-D115: See `decisions-archive.md` for early-stage decisions
(extraction, API design, register IR, ARM64 JIT, GC encoding, FP cache).

---

## D116: Address mode folding + adaptive prologue — abandoned (no effect)

**Context**: Stage 24 attempted two JIT optimizations to close remaining gaps
vs wasmtime on memory-bound (st_matrix 3.2x) and recursive (fib 1.8x) benchmarks.

1. **Address mode folding**: Fold static offset into LDR/STR immediate operand.
2. **Adaptive prologue**: Save only used callee-saved register pairs via bitmask.

**Result**: No measurable improvement. Wasm programs compute effective addresses
in wasm code (i32.add), not as static offsets. Recursive functions use all 6
callee-saved pairs. Abandoned.

Affected files: `src/jit.zig`

---

## D117: Lightweight self-call — caller-saves-all for recursive calls

**Context**: Deep recursion benchmarks showed ~1.8x gap vs wasmtime. Root cause:
6 STP + 6 LDP (12 instructions) per recursive call.

**Approach**: Dual entry point for has_self_call functions. Normal entry does full
STP x19-x28 + sets x29=SP (flag). Self-call entry skips callee-saved saves, only
does STP x29,x30 + MOV x29,#0. Epilogue CBZ x29 conditionally skips LDP x19-x28.
Caller saves only live callee-saved vregs to regs[] via liveness analysis.

**Results**: fib 90.6→57.5ms (-37%), 1.03x faster than wasmtime.

Affected files: `src/jit.zig`, `src/x86.zig`, `src/regalloc.zig`

---

## D118: JIT peephole optimizations — CMP+B.cond fusion

**Context**: nqueens inner loop: 18 ARM64 insns where cranelift emits ~12. Root
cause: `CMP + CSET + CBNZ` (3 insns) per comparison+branch instead of `CMP + B.cond` (2).

**Approach**: RegIR look-ahead during JIT emission. When emitCmp32/64 detects next
RegIR is BR_IF/BR_IF_NOT consuming its result vreg, emit `CMP + B.cond` directly.
Phase 2: MOV elimination via copy propagation. Phase 3: constant materialization.

**Expected impact**: Inner loops 20-33% fewer instructions.

**Rejected**: Multi-pass regalloc (LIRA) — would fix st_matrix but conflicts with
small/fast philosophy. Post-emission peephole — adds second pass over emitted code.

Affected files: `src/jit.zig`, `src/x86.zig`

---

## D119: wasmer benchmark invalidation — TinyGo invoke bug

**Context**: wasmer 7.0.1's `-i` flag does NOT work for WASI modules — enters
`execute_wasi_module` path ignoring `-i`. Functions never called, module just exits.

**Evidence**: Identical timing (~10ms) for nqueens(1)/nqueens(5000)/nqueens(10000).
WAT benchmarks (no WASI imports) and shootout (_start entry) work correctly.

**Decision**: Remove wasmer entirely from benchmark infrastructure (scripts,
YAML, flake.nix). Comparison targets: wasmtime, bun, node.

Affected files: `bench/run_bench.sh`, `bench/compare_runtimes.sh`

---

## D120: RegInstr u16 register widening — 8→12 bytes

**Context**: st_matrix func#42 has 42 locals + hundreds of temporaries, exceeding
the u8 (255) register limit. Falls back to stack interpreter (2.96x gap vs wasmtime).

**Decision**: Widen RegInstr register fields from u8 to u16. Add explicit `rs2_field`
instead of packing rs2 in operand low byte. Struct: op:u16, rd:u16, rs1:u16,
rs2_field:u16, operand:u32 = 12 bytes (was 8).

**Trade-off**: 50% larger IR increases cache pressure (~6% regression on some benchmarks).
Acceptable: unlocks JIT for all functions regardless of register count.
JIT trampoline pack/unpack via explicit helpers (no @bitCast with 12-byte struct).

**Rejected**: Smarter register reuse alone — 42 locals consume 42 base regs, leaving
213 for temps in a 4766-instruction function. Would require full liveness analysis.

Affected files: `src/regalloc.zig`, `src/jit.zig`, `src/x86.zig`, `src/vm.zig`

---

## D122: SIMD JIT strategy — hybrid predecoded IR + deferred NEON

**Context**: SIMD benchmarks show 43x geometric mean gap vs wasmtime. Root cause:
v128 functions forced to raw stack interpreter (~2.4μs/instr) because RegIR only
supports u64 registers. 88% of instructions in SIMD functions are non-SIMD overhead
(loops, address calc, locals) that RegIR handles at ~0.15μs/instr.

Task 45.4 extended the predecoded IR interpreter to handle SIMD prefix (0xFD),
achieving ~2x speedup by eliminating LEB128 decode and double-switch dispatch.
Still uses stack-based value manipulation for SIMD ops.

**Feasibility assessment** for full JIT NEON:
- ARM64 has 32 V registers (V0-V31), NEON instruction encoding is distinct from GP
- V0-V7 share physical space with D0-D7 (scalar FP) — requires careful tracking
- ~20 hot ops cover 80% of benchmark use: v128 load/store, f32x4 add/mul/splat,
  i32x4 add/mul, extract_lane, v128_const, i8x16_shuffle
- Register allocation: parallel V-register file alongside existing GP allocation
- Spill/reload: 16-byte slots (vs current 8-byte)
- Calling convention: v128 is local-only in Wasm (no params/returns), simplifies ABI

**Decision**: Defer RegIR v128 extension and JIT NEON to a future stage. Rationale:
1. Task 45.4's predecoded IR path already delivers 2x SIMD speedup
2. Full RegIR v128 extension requires type tagging in RegInstr (3-4 weeks)
3. JIT NEON requires parallel register file + 20 instruction encoders (6-8 weeks)
4. Combined effort ~10-14 weeks is a major undertaking for diminishing returns
5. Current SIMD performance is adequate for zwasm's use case (embedded runtime)

**If revisited**: Start with RegIR v128 type tagging (extend RegInstr with
reg_class bits, add v128_regs parallel to u64 regs), then selective NEON for the
20 hot ops. See `roadmap.md` Phase 13 (SIMD JIT) for the plan.

Affected files: `src/predecode.zig`, `src/vm.zig`

## D121: GC heap — arena allocator + adaptive threshold

**Context**: GC benchmarks show 6.7-46x gap vs wasmtime (gc_alloc 62ms vs 8ms,
gc_tree 1668ms vs 36ms). Two root causes identified:

1. **Per-object heap allocation**: Each `struct.new` calls `alloc.alloc(u64, n)` for
   the fields slice. General-purpose allocator overhead per object (gpa/page_allocator).
   wasmtime uses bump allocation from pre-allocated pages.

2. **O(n²) collection**: Fixed threshold of 1024 allocations triggers GC. For 100K
   objects: ~97 collections, each scanning ALL live objects (clearMarks + markRoots +
   sweep over entire slots array). Total work: O(n²/threshold). gc_tree with 524K
   nodes does ~512 collections with increasingly expensive scans.

**Decision**: Two-part fix:

**(a) Arena allocator for field storage**: Replace per-object `alloc.alloc()` with a
page-based arena. Pre-allocate 4KB pages, bump-allocate field slices from them.
No per-object free — entire arena freed on GcHeap.deinit() or after sweep reclaims
a full page. Eliminates allocator overhead: O(1) bump vs O(alloc) per struct.

**(b) Adaptive GC threshold**: Instead of fixed 1024, double threshold after each
collection that reclaims less than 50% of objects. Caps at heap_size/2.
Reduces collection count from O(n/1024) to O(log n) for growing workloads
(like benchmark build phases where nothing can be freed).

**Trade-off**: Arena wastes memory on freed objects until page is fully reclaimable.
Acceptable: GC benchmarks are allocation-heavy, and the arena approach matches how
production runtimes (V8, wasmtime) handle short-lived GC objects.

**Rejected**: Generational GC — too complex for the current heap model. Nursery/tenured
split requires write barriers and remembered sets. The adaptive threshold gives most of
the benefit (avoiding useless collections) without the complexity.

Affected files: `src/gc.zig`, `src/store.zig`

---

## D124: Module cache — predecoded IR serialization

**Context**: Phase 1.2. Repeated execution of the same wasm module re-parses and
re-predecodes all functions. For large modules (1000+ functions), predecode is the
dominant startup cost after validation.

**Decision**: Serialize predecoded IR (`PreInstr` + `pool64`) to disk at
`~/.cache/zwasm/<sha256>.zwcache`. Cache key is SHA-256 of the wasm binary.
Cache includes a version field (invalidated on zwasm version change).

**Format** (little-endian):
- Magic: `ZWCACHE\0` (8 bytes)
- Version: u32
- Wasm hash: [32]u8 (SHA-256)
- Num functions: u32
- Per function: code_len u32, pool_len u32, code bytes, pool bytes

`PreInstr` is `extern struct` (8 bytes, deterministic layout), so code is stored as
raw bytes — no per-field serialization needed. Zero-copy on read via `@memcpy`.

**CLI**: `zwasm run --cache file.wasm` (load/save automatically),
`zwasm compile file.wasm` (AOT predecode all functions, save cache).

**Trade-off**: Cache is per-binary (SHA-256), not per-function. A single-byte change
in the wasm file invalidates the entire cache. Acceptable: wasm modules are typically
immutable artifacts. Version field allows future format changes without silent corruption.

**Not cached**: RegIR and JIT native code. RegIR depends on runtime state (function
indices, memory layout). JIT code contains absolute addresses. Both regenerated at
runtime from predecoded IR (fast: <1ms per function).

Affected files: `src/cache.zig`, `src/cli.zig`, `src/types.zig`

---

## D125: CI automation — cron-based dependency freshness

**Context**: Phase 3. zwasm depends on external artifacts (WebAssembly spec testsuite,
wasm-tools, WASI SDK, wasmtime) that update independently. Manual version bumps are
easy to forget, causing silent drift from upstream.

**Decision**: Three automated workflows:

1. **Spec bump** (`spec-bump.yml`): Weekly (Monday 04:00 UTC). Clones latest spec,
   runs convert + spec tests, creates PR if tests pass. Tracks spec SHA in
   `.github/spec-sha` marker file.

2. **wasm-tools bump** (`wasm-tools-bump.yml`): Monthly (1st, 05:00 UTC). Queries
   GitHub API for latest release, updates `.github/versions.lock`, runs tests,
   creates PR if they pass.

3. **SpecTec monitor** (`spectec-monitor.yml`): Weekly (Monday 06:00 UTC). Checks
   for changes in `document/core/` or `spectec/` directories. Creates GitHub issue
   (with dedup) if changes found. Advisory only — no auto-merge.

**Centralized versions**: `.github/versions.lock` stores WASM_TOOLS_VERSION,
WASMTIME_VERSION, WASI_SDK_VERSION. All workflows `source` this file instead of
hardcoding versions. Single-file version bumps. (Renamed from `tool-versions`
in D136 when it became the cross-environment mirror of flake.nix pins.)

**Trade-off**: Auto-PRs require manual review before merge. Acceptable: version
bumps can introduce subtle behavior changes. Nightly workflow re-enabled as weekly
(Wednesday 03:00 UTC) to catch regressions without burning CI minutes daily.

Affected files: `.github/versions.lock`, `.github/workflows/ci.yml`,
`.github/workflows/nightly.yml`, `.github/workflows/spec-bump.yml`,
`.github/workflows/wasm-tools-bump.yml`, `.github/workflows/spectec-monitor.yml`

---

## D126: C API — hybrid design with `zwasm_` prefix

**Context**: Phase 5. Make zwasm usable from C and any FFI-capable language
(Python/ctypes, Rust/FFI, Go/cgo, etc.). Two approaches considered:

1. **wasm-c-api standard** (`wasm_engine_new`, `wasm_module_new`, etc.):
   Maximum interop but heavyweight API surface (~60 functions), complex
   ownership model (engine → store → module → instance hierarchy).

2. **Custom `zwasm_` API**: Simple module-centric API wrapping `WasmModule`.
   Fewer functions, flatter hierarchy, zwasm-specific features exposed directly.

**Decision**: Hybrid — custom `zwasm_` API designed so a wasm-c-api compatibility
layer can be added on top later. Rationale:

- **Simplicity**: `WasmModule` already encapsulates store+module+instance+vm.
  Exposing the full wasm-c-api hierarchy would force users into unnecessary
  boilerplate for common use cases.
- **Zero-overhead FFI**: Functions use `callconv(.c)` + `export` for direct
  symbol export. No runtime dispatch or vtables.
- **Opaque pointers**: C sees `zwasm_module_t*`, `zwasm_wasi_config_t*`,
  `zwasm_imports_t*` — all opaque. Internal layout can change freely.
- **Error handling**: Functions return null/false on error.
  `zwasm_last_error_message()` returns thread-local error string
  (similar to SQLite `sqlite3_errmsg` / OpenGL `glGetError` pattern).
- **Allocator strategy**: Each module owns a `GeneralPurposeAllocator`.
  Created in `_new`, freed in `_delete`. No allocator parameter in C API —
  simpler for FFI callers. GPA detects leaks in debug builds.
- **u64 value interface**: Args/results passed as `uint64_t` arrays matching
  the Zig API. C callers pack/unpack typed values themselves — no `wasm_val_t`
  union overhead.

**Future**: wasm-c-api shim can be built atop these primitives if needed
for ecosystem compatibility (e.g., wasm-c-api test suite).

Affected files: `src/c_api.zig`, `include/zwasm.h`, `build.zig`

## D127: Conditional Compilation Design

**Context**: zwasm compiles all features by default (~1.23MB stripped). Embedded
use cases may only need MVP+WASI without JIT or component model.

**Decision**: Feature flags via `build.zig` options, checked at comptime.

**Flags implemented**:
- `-Djit=false` — excludes jit.zig/x86.zig/arm64.zig (interpreter only)
- `-Dcomponent=false` — excludes component.zig/canon_abi.zig/wit_parser.zig/wit.zig
- `-Dwat=false` — excludes WAT text format parser (existing)
- `-Dsimd=false`, `-Dgc=false`, `-Dthreads=false` — build options defined but
  not yet guarded in source (low binary savings, high complexity)

**Guarding pattern**: Conditional import with comptime stub struct:
```zig
const jit_mod = if (build_options.enable_jit) @import("jit.zig") else struct {
    pub fn jitSupported() bool { return false; }
    // ... stub types matching real API surface
};
```
Zig's comptime dead code elimination removes unreachable branches automatically.

**Why only JIT and component?** JIT (~200KB savings) and component model (~80KB)
are the largest optional modules. SIMD/GC/threads opcodes are interleaved
throughout vm.zig dispatch and would require extensive per-opcode guards for
minimal savings. Pragmatic choice: guard the big modules, leave fine-grained
opcodes always compiled.

**Size results** (stripped, ReleaseSafe, Ubuntu x86_64):
- full: ~1230 KB
- no-jit: ~1050 KB
- no-component: ~1140 KB
- no-wat: ~1140 KB
- minimal (no-jit + no-component + no-wat): ~940 KB

Affected files: `build.zig`, `src/vm.zig`, `src/store.zig`, `src/types.zig`,
`.github/workflows/ci.yml`

## D128: Allocator Injection — Host-Driven Memory Management

**Date**: 2026-03-08
**Status**: Future (target: next major version)
**Decision**: zwasm will accept `std.mem.Allocator` from the caller instead of
owning its own GC/Arena internally. This is the Zig-idiomatic approach and
eliminates dual-GC problems when zwasm is embedded in a host with its own GC
(e.g., ClojureWasm, cw-new).

**Problem**: When a GC-managed host (CW) embeds zwasm, two independent GC systems
coexist. The host GC collects wasm Value objects, but zwasm's internal Arena
retains the underlying memory. This creates a lifecycle mismatch — CW GC cannot
reclaim zwasm-allocated memory.

**Design**:

```zig
// Zig API: caller provides allocator directly
pub fn Engine.init(allocator: std.mem.Allocator) Engine { ... }

// C API: optional malloc/free callback injection (default: page_allocator)
export fn zwasm_engine_new(config: ?*const ZwasmConfig) *Engine {
    const allocator = if (config) |c|
        wrapCAllocator(c.alloc_fn, c.free_fn, c.user_data)
    else
        std.heap.page_allocator;
    return Engine.init(allocator);
}
```

**Scope**: Allocator injection covers zwasm's internal bookkeeping only:
- Module metadata, function tables, import/export tables
- Instance state, global variables
- Internal data structures

Wasm **linear memory** (memory.grow) remains separately managed per Wasm spec —
this is unaffected by host allocator choice.

**Usage matrix**:

| Caller              | Allocator source                                |
|---------------------|-------------------------------------------------|
| Zig host (CW/cw-new) | Host's `std.mem.Allocator` (GC-managed)          |
| C host (via C API)  | `malloc/free` function pointers or default        |
| Standalone CLI      | Internal `page_allocator` or `GeneralPurposeAllocator` |

**Migration**: Internal Arena usage → accept Allocator parameter. Existing C API
(`zwasm_engine_new`) gains optional config struct with alloc/free callbacks.
Backward compatible — NULL config uses default allocator.

**Precedents**: SQLite (`SQLITE_CONFIG_MALLOC`), Lua (`lua_newstate(alloc_fn, ud)`),
jemalloc, mimalloc — all accept custom allocators from the host.

---

## D129: Windows First-Class Support — Platform Abstraction

**Date**: 2026-03-15
**Status**: Complete (PR #8, commit 48f68a7)
**Decision**: Add Windows x86_64 as a first-class target via platform abstraction
layer, without compromising Mac/Linux code quality.

**Problem**: zwasm used POSIX APIs directly (mmap, mprotect, signals, fd_t).
Windows requires VirtualAlloc, VEH, HANDLE-based I/O.

**Design**:

1. **`platform.zig`** — Unified OS abstraction for page-level memory:
   - `reservePages`/`commitPages`/`protectPages`/`freePages` (mmap ↔ VirtualAlloc)
   - `flushInstructionCache` (sys_icache_invalidate / __clear_cache / FlushInstructionCache)
   - `appCacheDir`/`tempDirPath` (cross-platform paths)

2. **`guard.zig`** — OOB trap via VEH on Windows:
   - POSIX: SIGSEGV signal handler modifies ucontext PC
   - Windows: VEH handler modifies CONTEXT.Rip/Pc on EXCEPTION_ACCESS_VIOLATION
   - Same recovery logic (JIT code range check → redirect to OOB exit stub)

3. **`wasi.zig`** — HostHandle abstraction:
   - `posix.fd_t` → `HostHandle { raw: Handle, kind: .file|.dir }`
   - POSIX file ops (read/write/lseek) → `std.fs.File` methods
   - `path_open`: Windows uses `Dir.openDir`/`createFile`; POSIX keeps `openat`
   - `FdEntry.append` field for Windows O_APPEND emulation

4. **`x86.zig`** — Win64 ABI support:
   - SysV: RDI/RSI/RDX args, RDI/RSI caller-saved
   - Win64: RCX/RDX/R8 args, RDI/RSI callee-saved, 32-byte shadow space
   - Compile-time dispatch via `abiRegsArg()`/`abiVmArg()`/`abiInstArg()`

5. **Test infrastructure** — bash → Python migration:
   - All test runners rewritten in Python for cross-platform support
   - bash wrappers retained for Mac/Linux backward compatibility
   - `select.select()` → `queue.Queue` + threading (Windows stdio)

**Scope**: x86_64 Windows only. ARM64 Windows deferred (no test hardware).

**Trade-offs**:
- `writeFilestat`: nlink always 1 on portable path (std.fs.File.Stat lacks nlink)
- `path_filestat_get`: POSIX retains fstatat for SYMLINK_NOFOLLOW; Windows always follows
- Binary size/memory checks skipped on Windows CI (no strip/time -v equivalents)

Related: D126 (C API), D127 (conditional compilation), CW D110, cw-new D13.

---

## D130: SIMD JIT Architecture

**Context**: Phase 13 — JIT compilation of wasm SIMD (v128) opcodes.
252 SIMD opcodes already implemented in interpreter. JIT has zero SIMD support;
any function with SIMD falls back to interpreter. SIMD benchmark shows
interpreter-only execution 2.6-7.7x slower than scalar JIT.

**Research**: `.dev/references/simd-jit-research.md` (runtime survey, usage patterns).

**Design Decisions**:

1. **Float register class (A1)**: Add `RegClass.Float` alongside existing GP class.
   All runtimes (Cranelift, V8, SpiderMonkey, Wasmer) use this model.
   Float and v128 share the same physical registers (XMM on x86, V on ARM64).

2. **x86 minimum ISA (D1)**: SSE4.1. Industry standard (Cranelift, V8, SpiderMonkey).
   Provides `pblendvb` (bitselect), `ptest` (any_true), `roundps/pd` (ceil/floor),
   `pmovsx/zx` (extending loads). SSE4.1-incapable x86_64 CPUs are pre-2008.

3. **Spill slots (D2)**: Class-separate. GP = 8 bytes, Float = 16 bytes.
   Avoids 2x stack bloat for non-SIMD functions.

4. **Fallback strategy (D3)**: Full opcode coverage before real-world benefit.
   Real-world SIMD is scattered in large mixed functions (70-80%, LLVM inlines
   before vectorizing). Partial JIT helps only hand-written WAT (~5-10%).
   Mechanism: regalloc returns null for unimplemented opcodes → function fallback.

5. **Shuffle strategy (D4)**: Generic fallback first (ARM64: `tbl`, x86: `pshufb`).
   Cranelift's 14+ priority rules accumulated over years. Start correct, optimize later.

6. **Build flag (D5)**: `-Dsimd=false` excludes SIMD codegen via `comptime if`.
   New files (`simd_arm64.zig`, `simd_x86.zig`) not imported. Minimal build unaffected.

7. **ISA parity (D6)**: Implement each opcode group on ARM64 + x86 simultaneously.
   Prevents "big bang porting" bugs (lesson from W35 ARM64-specific clobber bug).

**Affected files**: regalloc.zig, jit.zig, x86.zig, predecode.zig, vm.zig, build.zig,
simd_arm64.zig (new), simd_x86.zig (new).

Related: D127 (conditional compilation), `.dev/references/simd-jit-research.md`.

---

## D131: Epoch-Based JIT Timeout — Fuel Check Helper

**Context**: W40 — deadline (wall-clock timeout) suppressed JIT entirely because JIT
code couldn't check wall-clock time at back-edges. This forced interpreter fallback
when timeout was active, losing 5-10x performance.

**Decision**: Reuse the existing `jit_fuel` back-edge counter as a periodic interval
timer. When deadline is active, arm `jit_fuel` to `DEADLINE_JIT_INTERVAL` (10,000
back-edge ticks). When fuel goes negative, JIT calls `jitFuelCheckHelper` via
BL (ARM64) / CALL (x86) from a shared out-of-line stub. The helper checks both
fuel exhaustion and wall-clock deadline, then either re-arms (returns 0 → RET to
continue JIT) or returns an error code (→ JIT exits to shared epilogue).

**Alternatives considered**:
1. Signal-based (SIGALRM): lightweight check, but requires platform-specific timer
   infrastructure and conflicts with existing SIGSEGV guard pages.
2. Atomic epoch counter (wasmtime-style): clean but requires external timer thread
   or event loop, unnecessary complexity for single-threaded runtime.
3. Exit-and-re-enter JIT: impossible without state checkpoint — JIT code has side
   effects (memory writes, globals) that can't be replayed.

**Error codes**: 9 = FuelExhausted (unchanged), 10 = TimeoutExceeded (new).

**Key design points**:
- `jit_fuel_initial` field tracks the armed value for fuel sync calculation.
- `armJitFuel()` sets `jit_fuel = min(fuel, DEADLINE_JIT_INTERVAL)`.
- `syncJitFuelBack()` decrements `fuel` by consumed ticks after JIT exit.
- Shared stub spills/reloads caller-saved vregs to reg_stack memory.
- Stack alignment maintained: ARM64 uses STP/LDP x29,x30; x86 leverages
  the push rax + CALL = 16 bytes alignment property.
- No changes to interpreter `consumeInstructionBudget` — both paths coexist.

**Affected files**: vm.zig (helper, fuel arming), jit.zig (ARM64 stub),
x86.zig (x86_64 stub).

---

## D132: SIMD Performance — Two-Phase Optimization Plan

**Context**: Phase 13 (SIMD JIT) achieved functional correctness (NEON 253/256,
SSE 244/256) but SIMD-heavy benchmarks still show large gaps vs wasmtime. Root cause:
every v128 operation does load-from-memory → NEON/SSE op → store-to-memory, because
v128 values live in `Vm.simd_v128[512][2]u64` (global array), not in registers.

**Current v128 access cost (ARM64)**:
Each v128 load/store requires 3-4 instructions for address computation:
1. Load vm_ptr from `regs[reg_count+2]` (1 insn)
2. Add `@offsetOf(Vm, simd_v128) + vreg*16` — exceeds imm12 (4095), so 2-3 insns
3. LDR Q / STR Q (1 insn)

A binary SIMD op (e.g. `i32x4.add`) costs ~11-17 instructions total
(load×2 + op + store), where 8-14 are pure address computation overhead.

### Phase A: v128 Base Address Cache (W43)

**Decision**: Cache `vm_ptr + @offsetOf(Vm, simd_v128)` in a dedicated register
during JIT function prologue, so v128 address computation becomes 1-2 instructions
(ADD scratch, cached_base, vreg*16) instead of 3-4.

**Register allocation**:
- ARM64: Use x17 (currently vreg 22, last-resort caller-saved). Sacrifice only
  when `has_simd = true`. Functions with 23 vregs AND SIMD are extremely rare.
  Define `SIMD_BASE: u5 = 17`. MAX_PHYS_REGS stays 23 but vreg 22 unavailable
  for SIMD functions.
- x86: Similar — sacrifice r10 (vreg 9) when `has_simd = true`, or compute
  from vm_ptr (1 extra load, x86 handles 32-bit immediates natively so less
  benefit than ARM64).

**Implementation plan**:
1. Add `simd_base_cached: bool` field to Compiler (both backends)
2. In `emitPrologue`, when `has_simd`: compute and store base in SIMD_BASE reg
3. Rewrite `emitSimdV128Addr` to use cached register when available
4. Ensure OSR prologue also sets up SIMD_BASE (must match normal prologue)
5. Self-call entry: SIMD_BASE is callee-saved (x17 is caller-saved on ARM64
   but we don't have self-calls with SIMD in practice; guard if needed)
6. No spillCallerSaved impact — SIMD_BASE is computed from vm_ptr, not a vreg

**Expected improvement**: ~20-35% code size reduction for SIMD ops on ARM64.
10-20% wall-clock improvement on SIMD-heavy benchmarks.

**Bug risk**: Low. Pattern identical to MEM_BASE/MEM_SIZE caching.
Key risk: OSR prologue mismatch (documented pitfall).

**Estimated effort**: 2-3 days.

### Phase B: SIMD Register Class (W44, future)

**Decision**: Add a second register class for v128 values, mapping them to
Q0-Q31 (ARM64) or XMM0-XMM15 (x86) physical registers. v128 values stay in
SIMD registers across multiple operations, eliminating load/store traffic.

**Why deferred**: Requires structural changes to regalloc.zig (type tracking,
new register class), ARM64 FP D-register cache conflicts with Q register
allocation (D8 is the lower half of Q8), both backends need independent
implementation, and spill/reload for 128-bit values through calls is error-prone.

**Prerequisites**: Phase A completed, profiling data showing remaining bottleneck
is load/store traffic (not address computation).

**Key design challenges**:
1. regalloc.zig: Track scalar vs v128 type per vreg
2. ARM64: Partition Q regs — Q16-Q31 for v128 (no FP cache conflict),
   Q2-Q15 for scalar FP cache (existing)
3. x86: XMM5-XMM15 for v128 (~11 regs), XMM0-XMM2 for scratch
4. spillCallerSaved: must spill Q/XMM regs to simd_v128[] on calls
5. Cross-tier compat: interpreter still uses simd_v128[], trampoline must sync
6. Lane extract/insert: transition between v128 reg class and scalar reg class

**Expected improvement**: 30-50% on SIMD-heavy code. Would close most of the
gap vs wasmtime for SIMD workloads.

**Bug risk**: High. Touches regalloc, both JIT backends, spill/reload, FP cache.

**Estimated effort**: 3-6 weeks.

**Affected files**: jit.zig, x86.zig (v128 addr, prologue), vm.zig (simd_v128
offset), regalloc.zig (Phase B only).

## D133: FD-Based WASI Stdio and Preopen Configuration

**Context**: Issue #17. Embedders that already manage host file descriptors need
to pass them directly to WASI instances, rather than using path-based configuration.

**Decision**: Add per-instance FD override for stdio (0/1/2) and FD-based preopen
registration. Each FD has an explicit ownership mode: `borrow` (caller retains fd)
or `own` (runtime closes on teardown).

**API surface**:
- `WasiContext.setStdioFd(fd, host_fd, ownership)` — override stdin/stdout/stderr
- `WasiContext.stdioFile(fd)` — resolve stdio with override fallback
- `WasiContext.addPreopenFd(wasi_fd, guest_path, host_fd, kind, ownership)` — register fd-based preopen
- C API: `zwasm_wasi_config_set_stdio_fd()`, `zwasm_wasi_config_preopen_fd()`
- `WasiOptions`: `stdio_fds`, `stdio_ownership`, `preopen_fds` fields

**Design choices**:
- `stdioFile` moved from free function to WasiContext method; `defaultStdioFile`
  remains for non-WASI fallback paths.
- Ownership tracked per-fd (not per-config) to allow mixed borrow/own in one instance.
- `applyWasiOptions` helper extracts duplicated WASI setup logic from `loadWasiWithOptions`
  and `loadWasiWithImports`.
- C API uses integers for kind (0=file, 1=dir) and ownership (0=borrow, 1=own)
  to keep the header cross-language friendly.

**Affected files**: wasi.zig, types.zig, c_api.zig, include/zwasm.h, test_ffi.c.

## D134: Async Execution Cancellation

**Context**: Issue #27 / PR #28. Embedders need to abort a running Wasm invocation
from another thread — for instance to enforce user-initiated cancel buttons on top
of Wasm plugins, or to unwind infinite loops that escape fuel/deadline budgets.
Pre-set fuel limits and deadline timeouts were the only existing escape hatches;
both are decided before execution starts.

**Decision**: Expose a thread-safe `cancel()` request on `Vm` / `WasmModule` /
`zwasm_module_t`. The interpreter and JIT both poll the flag at their existing
periodic budget checkpoints, so the new path reuses proven machinery rather than
adding a second interrupt mechanism.

**Mechanism**:
- `Vm.cancelled: std.atomic.Value(bool)` — `release` store on cancel, `acquire`
  load on check.
- Interpreter path: `consumeInstructionBudget()` already fired every
  `DEADLINE_CHECK_INTERVAL` (1024) instructions for deadline polling; cancel
  checks piggyback on the same checkpoint with no extra branch on the hot path.
- JIT path: `armJitFuel` caps `jit_fuel` to `DEADLINE_JIT_INTERVAL` when
  cancellation is armed, so `jitFuelCheckHelper` fires periodically even when
  no fuel/deadline is set. The helper returns error code `11` (`Canceled`) back
  into the trampoline.
- `reset()` clears the flag — each `invoke()` starts from a clean state, and
  cancel requests issued against an idle module are dropped. This is documented
  on both the Zig and C APIs; the FFI test races cancels across invoke start
  to cover the corresponding window.

**Opt-out**: `Vm.cancellable: bool = true` (Zig default) / `cancellable: ?bool`
in `WasmModule.Config` / `zwasm_config_set_cancellable(config, false)`. Disabling
restores `jit_fuel = maxInt(i64)` for fuel/deadline-free runs, recovering pre-PR
throughput for hosts that never need cancel.

**API surface**:
- Zig: `Vm.cancel()`, `WasmModule.cancel()`, `error.Canceled`,
  `WasmModule.Config.cancellable: ?bool`.
- C: `void zwasm_module_cancel(zwasm_module_t *)`,
  `void zwasm_config_set_cancellable(zwasm_config_t *, bool)`.
- CLI: `error.Canceled` prints "execution canceled".

**Affected files**: vm.zig, types.zig, cli.zig, c_api.zig, include/zwasm.h,
test/c_api/test_ffi.c, docs/{embedding,errors,usage,api-boundary}.md,
book/{en,ja}/src/{c-api,embedding-guide}.md.

## D135: Io Threading Strategy for Zig 0.16.0 Migration

**Context**: Zig 0.16.0's "I/O as an Interface" shift routes every filesystem,
network, and synchronization primitive through a `std.Io` vtable. `std.fs.*` is
deprecated in favour of `std.Io.Dir`; `std.Thread.Mutex` moved to `std.Io.Mutex`;
`File.openFile`, `File.stat`, `File.close`, and friends all take `io: Io` as
their second positional argument. We cannot migrate to 0.16 without deciding
where `io` comes from at every call site — it cannot be recovered from thin
air, and constructing a fresh `std.Io.Threaded` per call is both wasteful and
semantically wrong (independent Io instances do not share resources).

**Decision**: Use a two-tier strategy, matching the two distinct lifecycle
regimes in the codebase.

1. **Library code owns an `io: std.Io` field on the Vm struct.**

   `Vm` is the long-lived object that outlasts any individual invocation and is
   already the owner of other execution-global state (fuel, deadline, cancel
   flag). It becomes the natural owner of `io`. `Memory` and `WasiContext`
   reach `io` via the `Vm` they belong to rather than holding their own copy —
   keeps a single source of truth per module.

   `WasmModule.Config` gains `io: ?std.Io = null`. When null, `loadCore`
   constructs a `std.Io.Threaded` backed by the module's allocator, owns it,
   and tears it down in `WasmModule.deinit`. Embedders who need a specific
   Io implementation (`Uring` on Linux, `Kqueue` on macOS, or a mock for
   tests) pass their own.

2. **CLI code uses a module-level `cli_io: std.Io` var.**

   A CLI invocation is one process, one event loop, one Io. The `init.io`
   handed to `cli.main` by `start.zig` lives for the whole run. Threading it
   through the five `cmd*` functions plus all their helpers adds noise with
   no correctness benefit — a CLI is single-threaded with respect to its
   own I/O.

   `start.zig` itself sets up its debug_allocator this way (module-level
   `var`), so the pattern matches upstream idiom for single-process globals.

**Alternatives considered**:

- **Option A (thread `io` through all public API)**: Forces breaking changes on
  every embedder (ClojureWasm + future consumers). Rejected — the benefit
  (fine-grained per-call Io override) is not a use case we have.
- **Option B (mandatory `Config.io`)**: Forces embedders to construct an Io
  before they can call `WasmModule.load`. Rejected — the common case is
  "I just want the default behaviour" and we shouldn't make that verbose.
- **Option C (WASI-local io, construct inline in wasi.zig)**: Wastes resources
  by constructing a fresh `Threaded` per WASI syscall and doesn't help
  `Memory.Mutex` or `guard.zig`'s signal handler paths. Rejected once we
  realised how many non-WASI sites also need `io`.

**C API implications**: `zwasm_config_t` does not expose `io` — C callers get
the default `Threaded` constructed internally. This is honest to the ABI (Zig
interface vtables do not cross FFI cleanly) and matches how `zwasm_config_t`
already handles Zig-only fields like `imports`.

**Affected files (migration-time)**: `src/vm.zig` (io field, init signature),
`src/types.zig` (`Config.io`, lifecycle), `src/memory.zig` (Mutex routes
through Vm.io), `src/wasi.zig` (33 `std.fs.*` sites), `src/cli.zig` (cli_io
module var — already in develop/zig-0.16.0), `src/module.zig`,
`src/instance.zig`, tests.

**Lifetime invariant**: `io` on Vm outlives every operation that captures it.
Since Vm owns any auto-constructed `Threaded` and tears it down last in
`deinit`, and since no invoke path holds `io` past the invoke's return,
there is no use-after-free path introduced by the threading.

**Result (2026-04-24)**: Migration shipped as v1.10.0. Strategy validated:

- Library: `Vm.io: std.Io = undefined`; `WasmModule.Config.io: ?std.Io = null`;
  `loadCore` / `loadLinked` stand up an owned `std.Io.Threaded` (kept in
  `WasmModule.owned_io`) when `io` is null, deinit'd last.
- CLI: `cli.cli_io: std.Io = undefined` set from `main(init: std.process.Init).io`
  before any sub-command runs.
- Tests: each test that hits an `io`-using Vm path constructs its own local
  `std.Io.Threaded` and assigns `vm.io = th.io()`.

**Pragmatic split from the original plan**: for POSIX ops that `std.posix`
dropped in 0.16 (fsync, mkdirat, unlinkat, renameat, pread/pwrite, dup,
futimens, readlinkat, symlinkat, linkat, fstatat, close, pipe, getenv,
mprotect), WASI handlers call `std.c.*` directly with `file.handle` rather
than threading `io` through. `file.handle` is trivially available from the
`HostHandle` / `FdEntry` structures and errno is mapped with a single local
helper (`cErrnoToWasi`). This keeps `io` as the currency for the std-Io-based
operations that genuinely need it (`file.stat`, `file.setTimestamps`,
`Dir.openDir`, `Io.Timestamp.now`, `io.random`, `io.sleep`,
`process.spawn`) while leaving the bulk of WASI's POSIX surface un-io-y.

**Pitfall noted**: in long-running executable `main()` functions (the e2e
runner in particular), constructing a fresh `std.Io.Threaded` locally and
using its `.io()` caused sporadic segfaults in `Io.Timestamp.now` after many
iterations — symptoms consistent with the Threaded scheduler being torn down
too early even though the variable was still in scope. Using `init.io`
(supplied by `start.zig`) avoids this entirely. Use init.io for top-level
binaries; use a freshly constructed Threaded only when the scope is bounded.

---

## D136: Nix flake as toolchain SSoT, with `versions.lock` as the cross-environment mirror

**Context**: Three separate places independently described "the toolchain
zwasm builds against": (1) `flake.nix` for `nix develop` + direnv on
Linux/macOS, (2) the old `.github/tool-versions` for a handful of CI
pins, (3) ad-hoc CI YAML literals for everything else (Zig action input,
hyperfine DEB URL, etc.). Drift was already present — the local nix
devshell delivered `wasi-sdk-30`, while CI consumed `WASI_SDK_VERSION=25`
through `tool-versions`, so realworld C/C++ builds in PRs were never
validated against the SDK developers ran locally. With Windows joining
the supported matrix as a first-class environment (W## tracking item)
and Nix unable to run natively on Windows, the model needed an explicit
SSoT plus a sanctioned mirror, not three drifting copies.

**Decision**:

1. **`flake.nix` is the single source of truth for Linux and macOS**, both
   for local development (via `.envrc` → `use flake .`) and for CI once
   Plan B lands. Pinned tools that Nix manages directly (Zig, WASI SDK)
   carry their version + URL + sha256 inside `flake.nix`.

2. **`.github/versions.lock`** (renamed from `tool-versions`) is the mirror
   for environments that cannot consume Nix:

   - Windows native installer scripts (Plan B)
   - CI workflow steps that need a string before Nix is available
     (`actions/setup-zig` input, `cargo install --version`, release ZIP URLs)

   The file is bash-sourceable (`source .github/versions.lock`) and also
   read by Python via `splitlines()`. It carries every pin a non-Nix
   consumer might need, even ones currently only fetched by Nix on
   Linux/Mac, so the Windows installer can stay symmetric.

3. **Update discipline**: bumping a pin requires editing both
   `flake.nix` (when applicable) and `versions.lock`. A future
   `scripts/sync-versions.sh` (Plan B) plus a Merge Gate consistency
   check will mechanise this — until then it is a code-review concern.

4. **No WSL fallback for Windows.** The whole point of the Windows
   matrix entry is to validate native PE/COFF + MSVC behaviour. Routing
   Windows through WSL2 + Nix would re-test Linux, not Windows. Windows
   uses native tooling installed via winget / direct release ZIPs whose
   versions are dictated by `versions.lock`.

5. **Future shape (Plan B + C, separate PRs)**:

   - `scripts/gate-commit.sh`, `scripts/gate-merge.sh`,
     `scripts/run-bench.sh` become the unified entry points. They run
     identically locally and in CI; each is invoked under
     `nix develop --command` on Linux/Mac and natively under Git Bash
     on Windows.
   - CI Linux/Mac jobs adopt
     `DeterminateSystems/nix-installer-action` +
     `DeterminateSystems/magic-nix-cache-action` and call those scripts.
   - CI Windows job runs `scripts/windows/install-tools.ps1` (reads
     `versions.lock`) then the same gate scripts under bash.
   - `ci.yml`'s eleven `if: runner.os != 'Windows'` skips become
     individual no-skip targets (Plan C: shared-lib DLL, FFI tests,
     static link, binary size via `zig objcopy --strip-all`, memory
     check via PowerShell, size-matrix OS-fanout, benchmark Windows
     record-only).

**Alternatives considered**:

- **Single `flake.nix` only, no mirror file.** Rejected — Windows cannot
  consume `flake.nix`, and having CI YAML hardcode versions independently
  reproduces the drift problem we just fixed.
- **Replace `tool-versions` with `flake.lock` direct queries** (e.g.
  `nix eval`). Rejected for now — needs Nix on the consumer, which
  defeats the Windows use case. May revisit when Plan B's
  `scripts/sync-versions.sh` is in place; a non-Nix pre-rendered lock
  is friendlier to humans reading PRs.
- **Drop the Windows native matrix entry, use WSL only.** Rejected per
  point 4.

**Bumping WASI SDK 25 → 30 in this PR**: not a separate decision — it is
the immediate consequence of declaring `flake.nix` (already at 30) the
SSoT. Verified locally with `python test/realworld/build_all.py --force`
and `run_compat.py` (50 PASS / 0 FAIL / 0 CRASH, 2026-04-29).

**Affected files (this PR / Plan A)**: `.github/versions.lock` (renamed
from `tool-versions`, expanded with `ZIG_VERSION` and `[planned]`
informational pins), `.github/workflows/ci.yml`,
`.github/workflows/nightly.yml`, `.github/workflows/spec-bump.yml`,
`.github/workflows/wasm-tools-bump.yml`, `ARCHITECTURE.md`,
`.dev/environment.md` (new), `CLAUDE.md` (Merge Gate addendum).

**Affected files (Plan B, separate PR)**: `scripts/lib/versions.sh`,
`scripts/sync-versions.sh`, `scripts/gate-commit.sh`,
`scripts/gate-merge.sh`, `scripts/run-bench.sh`,
`scripts/windows/install-tools.ps1`, `flake.nix` (pin wasm-tools /
wasmtime / hyperfine explicitly), `ci.yml` refactor.

**Affected files (Plan C, separate PR)**: `test/c_api/run_ffi_test.sh`
(Windows DLL + LoadLibraryA), `test/c_api/test_ffi.c` (Win32 path),
`examples/rust/build.rs` (Windows), CI binary-size step
(`zig objcopy --strip-all`), CI memory check (PowerShell), `size-matrix`
+ `benchmark` jobs (OS fanout).

## D137: Cross-platform binary stripping (`-Dstrip=true`) and per-OS size ceilings

**Context**: Until Plan C-e/C-f the CI binary-size guard depended on the
GNU `strip` shell tool and was wrapped in `if: runner.os != 'Windows'`
because the Windows runner ships no GNU strip and `zig objcopy
--strip-all` is ELF-only (it refuses Mach-O with `InvalidElfMagic` and
PE/COFF outright). Two independent problems sat behind the guard:

1. **How** to strip portably. The host-tool path is unfixable on
   Windows, and `zig objcopy` is too narrow.

2. **Where** the size ceiling should sit on each platform. The historic
   1.60 MB cap was Linux-targeted; macOS Mach-O coincidentally fit
   below it, but Windows PE consistently overshoots due to higher
   relocation/import-table overhead even when zwasm itself is identical
   bytecode-wise. Forcing a single global cap would either gate Linux
   on a too-loose number (defeating the regression-guard purpose) or
   gate Windows on a too-tight number (gating CI on a property of the
   PE format, not of zwasm).

The two problems must be solved together because the original
1.60 MB number was specifically the *post-strip* size; without an
agreed-on stripping mechanism, the ceiling has no meaning.

**Decision**:

1. **Strip via LLD at link time, not via a host tool.** `build.zig`
   exposes `-Dstrip=true` (default `false`) which sets
   `Module.strip = true` on the CLI executable. LLD strips the binary
   during the link step on every target Zig supports — ELF, Mach-O,
   PE/COFF. The CI size step does an *isolated* build into
   `.strip-cache/` so the unstripped `zig-out/bin/zwasm` used by the
   memory check and the realworld tests later in the same job stays
   untouched.

2. **Per-OS ceilings, not a single global cap.** Each ceiling tracks
   the observed stripped size with ~80–100 KB of headroom. The
   ceiling is a *regression guard*, not a parity target: cross-OS
   binary-size comparison is meaningless given the format differences,
   and forcing parity would either hobble Linux or grant Windows
   excess slack.

   | OS               | Stripped binary | Ceiling   | Headroom |
   |------------------|-----------------|-----------|----------|
   | macOS aarch64    | ~1.20 MB        | 1.30 MB   | ~80 KB   |
   | Linux x86_64     | ~1.56 MB        | 1.60 MB   | ~40 KB   |
   | Windows x86_64   | ~1.70 MB        | 1.80 MB   | ~100 KB  |

   The Linux 1.60 MB number is the original W48 Phase-1 target and is
   unchanged; the macOS 1.30 MB number tightens on the prior implicit
   1.60 MB so a Mac regression trips the gate before consuming the
   Linux-sized budget; the Windows 1.80 MB number is the first
   measurement-grounded ceiling for that runner — historic 1.80 MB on
   the Zig 0.16 transition was a pragmatic global compromise during
   `link_libc=true`, this 1.80 is a per-OS budget reflecting PE's
   structural overhead with `link_libc=false`.

3. **`size-matrix` becomes a 3-OS matrix.** The job was Ubuntu-only on
   the same `if: runner.os != 'Windows'` reasoning and reduces to the
   same fix once `-Dstrip=true` works on every target. Each variant
   (full / no-jit / no-component / no-wat / minimal) builds with
   `-Dstrip=true` into its own `.strip-cache-<NAME>/` prefix; the loop
   measures the binary directly.

**Alternatives considered**:

- **Keep `strip` and ship a Windows-only re-implementation.** Rejected
  — Windows GNU `strip` is not in any standard runner image, and
  shipping our own would duplicate work the Zig toolchain already does
  via LLD.
- **Use `zig objcopy --strip-all` with per-OS adapters.** Rejected —
  it is ELF-only by design (`InvalidElfMagic` on Mach-O, no PE handler
  at all), and a per-OS pipeline that converged on different binary
  formats would be more code than the LLD path it would replace.
- **Single global ceiling sized for the largest OS (Windows 1.80 MB).**
  Rejected — Linux and macOS would silently regress up to 200 KB
  before tripping the gate, defeating the regression guard.
- **Strip everywhere always (default `-Dstrip=true`).** Rejected — the
  unstripped binary is useful for local debugging (panic backtraces,
  symbol resolution under lldb) and for the existing memory check
  which relies on the same `zig-out/bin/zwasm` artefact built earlier
  in the same CI job. Default `false`, opt in for size measurement.

**Affected files (PR #70)**: `build.zig` (`-Dstrip` option +
`Module.strip` wiring on the CLI module), `.github/workflows/ci.yml`
(`Binary size check` rewritten with isolated `.strip-cache/` build and
per-OS LIMIT_BYTES; `size-matrix` job converted from `runs-on:
ubuntu-latest` to `strategy.matrix.os: [ubuntu-latest, macos-latest,
windows-latest]`), CHANGELOG `[Unreleased]`.

**Future bumps**: tightening any per-OS ceiling is explicitly
encouraged when sustained reductions land (e.g. W48 Phase-2 trims the
Mac binary another 60 KB → cap drops 1.30 → 1.25 MB). Loosening a
ceiling requires a CHANGELOG entry naming the regression source so
the slack is intentional and visible.

