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

**Decision**: Remove wasmer from public docs. Mark TinyGo results invalid in
runtime_comparison.yaml. Keep wasmer in benchmark script for WAT/shootout.
