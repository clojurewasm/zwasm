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
   GitHub API for latest release, updates `.github/tool-versions`, runs tests,
   creates PR if they pass.

3. **SpecTec monitor** (`spectec-monitor.yml`): Weekly (Monday 06:00 UTC). Checks
   for changes in `document/core/` or `spectec/` directories. Creates GitHub issue
   (with dedup) if changes found. Advisory only — no auto-merge.

**Centralized versions**: `.github/tool-versions` stores WASM_TOOLS_VERSION,
WASMTIME_VERSION, WASI_SDK_VERSION. All workflows `source` this file instead of
hardcoding versions. Single-file version bumps.

**Trade-off**: Auto-PRs require manual review before merge. Acceptable: version
bumps can introduce subtle behavior changes. Nightly workflow re-enabled as weekly
(Wednesday 03:00 UTC) to catch regressions without burning CI minutes daily.

Affected files: `.github/tool-versions`, `.github/workflows/ci.yml`,
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
