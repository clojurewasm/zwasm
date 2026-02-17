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

---

## D117: Lightweight self-call — caller-saves-all for recursive calls

**Context**: Deep recursion benchmarks showed ~1.8x gap vs wasmtime. Root cause:
6 STP + 6 LDP (12 instructions) per recursive call.

**Approach**: Dual entry point for has_self_call functions. Normal entry does full
STP x19-x28 + sets x29=SP (flag). Self-call entry skips callee-saved saves, only
does STP x29,x30 + MOV x29,#0. Epilogue CBZ x29 conditionally skips LDP x19-x28.
Caller saves only live callee-saved vregs to regs[] via liveness analysis.

**Results**: fib 90.6→57.5ms (-37%), 1.03x faster than wasmtime.

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

---

## D119: wasmer benchmark invalidation — TinyGo invoke bug

**Context**: wasmer 7.0.1's `-i` flag does NOT work for WASI modules — enters
`execute_wasi_module` path ignoring `-i`. Functions never called, module just exits.

**Evidence**: Identical timing (~10ms) for nqueens(1)/nqueens(5000)/nqueens(10000).
WAT benchmarks (no WASI imports) and shootout (_start entry) work correctly.

**Decision**: Remove wasmer entirely from benchmark infrastructure (scripts,
YAML, flake.nix). Comparison targets: wasmtime, bun, node.

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
20 hot ops. See `.dev/simd-analysis.md` for full bottleneck data.

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
