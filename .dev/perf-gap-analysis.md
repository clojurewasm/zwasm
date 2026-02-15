# Performance Gap Analysis: st_matrix and tgo_mfr

## Summary

| Benchmark  | zwasm (ms) | wasmtime (ms) | Gap  | Root Cause |
|-----------|-----------|--------------|------|------------|
| st_matrix | 262.7     | 88.7         | 2.96x | func#42 (42 locals) exceeds u8 reg limit, runs in stack interpreter |
| tgo_mfr   | 50.0      | 32.3         | 1.55x | JIT codegen quality (spills, no LICM/unrolling) |

## st_matrix (2.96x gap)

### Hot Function: func#42

- **42 locals** (5 params + 37 locals), **4766 WAT lines**
- RegIR conversion **fails** at `max_reg > 255` check (regalloc.zig:1153)
- Falls back to **stack-based interpreter** (predecoded IR only)
- No JIT possible without RegIR

### Other Functions: JIT-compiled successfully

- func#7 (28 regs, 392 IR) — JIT compiled
- func#8 (13 regs, 131 IR) — JIT compiled
- func#46 (35 regs, 255 IR) — back-edge JIT compiled
- func#9, #10, #32 — JIT compiled

### Why func#42 exceeds 255 regs

The function has 42 locals and deeply nested expressions. With single-pass
regalloc that allocates a new virtual register for each intermediate result,
42 base locals + hundreds of temporaries easily exceeds u8 range.

### Fix Options

1. **Widen reg fields to u16** (RegInstr struct change)
   - Effort: Medium. Every RegInstr field (rd, rs1, rs2) becomes u16.
   - Impact: Doubles RegInstr size (currently 8 bytes → ~12 bytes).
   - RegIR execution loop touches every field — cache pressure increases.
   - JIT: MAX_PHYS_REGS=20 already handles spilling; more regs just means
     more stack slots. ARM64 has 30 GPRs, x86 has 16 — either way, the JIT
     already spills beyond MAX_PHYS_REGS.
   - Risk: Low. Mechanical change, good test coverage.

2. **Improve temp register reuse** (smarter regalloc)
   - Effort: Medium-High. Current allocator reuses freed temps, but
     deeply nested expressions create long live ranges that prevent reuse.
   - Could implement basic liveness analysis to find reuse opportunities.
   - May not be enough: 42 locals alone consume 42 regs, leaving only
     213 for temps — still tight for a 4766-instruction function.

3. **Hybrid: u16 regs + better reuse**
   - Best approach. u16 removes the hard limit, better reuse keeps
     the reg count reasonable for JIT performance.

### Recommendation

**Option 1 (u16 regs)** as immediate fix. The 3x gap is entirely due to
func#42 falling back to the stack interpreter. Even mediocre JIT code
would be 2-3x faster than the interpreter. Expected improvement: 2.96x → ~1.5x.

## tgo_mfr (1.55x gap)

### Hot Function: func#24 (mfr)

- **7 locals** (1 param + 6 locals), **91 RegIR instructions**, **23 virtual regs**
- Back-edge JIT compiles successfully (724 bytes native code)
- 23 regs > MAX_PHYS_REGS=20, so regs 20-22 spill to stack

### Three Inner Loops

1. **Init loop** (pc 7-31): fill array with sequential i64 values, 5 stores per iteration
2. **Square loop** (pc 33-57): load, square, store each i64, 4 elements per iteration
3. **Sum loop** (pc 61-82): conditionally sum even elements, select + add pattern

### Gap Analysis

The 1.55x gap comes from:

1. **Register spills**: regs 20-22 spill/reload on every access. These are used
   in the sum loop inner body (r20, r21 for select/add), causing extra
   memory traffic on every iteration.

2. **No loop strength reduction**: address computation `addi32 r18 = r1 op 1032`
   recalculates offsets each iteration instead of maintaining a running pointer.

3. **No loop unrolling**: cranelift may unroll the tight square/sum loops.

4. **Extra mov instructions**: regalloc generates mov chains (e.g., pc 25-28:
   `mov r1=r12; const r12; add r12; mov r4=r12`) that cranelift eliminates
   via copy propagation.

### Fix Options

1. **Increase MAX_PHYS_REGS** (20 → 24-26)
   - ARM64 has x0-x28 (29 GPRs). Currently using 20 (5 callee + 7 caller +
     2 callee + 6 caller). Could reclaim x16-x18 (currently reserved) for
     4 more physical registers.
   - Would eliminate spills for this function (23 regs, need 23 physical).
   - Effort: Low. Just extend the register mapping tables.
   - Risk: x16-x18 have special roles on some platforms (IP0/IP1/PR).
     Need careful platform-specific handling.

2. **Peephole: eliminate redundant movs**
   - The regalloc produces `const r12=X; op r12=r4,r12; mov r4=r12` patterns.
   - A peephole pass could detect when rd is immediately moved to another reg
     and combine them.
   - Effort: Medium. Already have some peephole in Stage 26.
   - Impact: ~10% improvement (reduces instruction count by ~15%).

3. **Copy propagation in JIT**
   - Instead of emitting mov instructions, track register aliases.
   - When JIT sees `mov r4 = r12`, record that r4's value is in the physical
     register holding r12, skip the move.
   - Effort: Medium. Requires alias tracking in JIT emitter.
   - Impact: Significant for mov-heavy code.

### Recommendation

**Option 1 (increase MAX_PHYS_REGS)** for immediate gains. The 3 spilled
registers are in the hot sum loop; eliminating spills could reduce the gap
from 1.55x to ~1.3x. Then Option 2/3 for further improvement.

## Implementation Priority

1. **u16 reg fields** (st_matrix: 2.96x → ~1.5x estimated)
2. **Increase MAX_PHYS_REGS to 24** (tgo_mfr: 1.55x → ~1.3x estimated)
3. **Peephole mov elimination** (both: ~10% further improvement)

Total effort: ~2-3 tasks. Expected outcome: both benchmarks within 1.5x of wasmtime.
