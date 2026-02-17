# SIMD Performance Bottleneck Analysis

Stage 45.3 — 2026-02-17

## Problem Statement

zwasm SIMD operations are 6-17x slower than scalar equivalents within zwasm,
and ~43x slower than wasmtime SIMD (geometric mean across 4 benchmarks).
See `bench/simd_comparison.yaml` for baseline data.

## Root Cause: Execution Tier Disparity

zwasm has three execution tiers:

| Tier | Dispatch cost | Used for |
|------|--------------|----------|
| Stack interpreter | ~2.4 μs/instr | v128 functions (SIMD) |
| RegIR interpreter | ~0.15 μs/instr | Scalar functions (pre-JIT) |
| ARM64 JIT | ~0.01 μs/instr | Hot scalar functions |

**v128 functions are forced to the slowest tier** because:
1. RegIR uses `u64` register file — cannot hold `v128` values (line 432-434 in vm.zig)
2. JIT requires RegIR as input, so also unavailable
3. Result: **16x dispatch overhead** per instruction vs RegIR

## Dispatch Overhead Breakdown

### Stack interpreter (vm.zig:720, `execute`)
Per instruction:
- Read byte from bytecode array → `@enumFromInt` → switch dispatch
- SIMD: extra LEB128 decode for `simd_prefix` sub-opcode → second switch
- Stack push/pop for every operand (memory writes to op_stack)
- `block`/`loop` need `skipToEnd` or branch table lookup

Total per SIMD instruction: ~2.4 μs (measured: 354K instrs in 860ms)

### RegIR interpreter (vm.zig:3473, `executeRegIR`)
Per instruction:
- Read from pre-decoded instruction array (struct with op, rd, rs1, operand)
- Single switch dispatch on compact opcode
- Register operands are direct array indexes (no stack manipulation)
- No LEB128 decoding at runtime

Total per scalar instruction: ~0.15 μs (measured: 827K instrs in 126ms)

### JIT (native ARM64)
- No dispatch at all — native machine code
- wasmtime: ~11ms for same dot_product benchmark

## Profiling Data

### dot_product (10K iterations, N=4096)
```
Scalar (RegIR): 827,524 instructions, 126.3ms → 0.153 μs/instr
SIMD (stack):   354,524 instructions, 862.7ms → 2.434 μs/instr
Ratio: 15.9x dispatch overhead per instruction
```

Fewer SIMD instructions (f32x4 processes 4 elements at once) but each takes
16x longer to dispatch. Net result: SIMD 6.8x slower than scalar.

### SIMD opcode distribution (dot_product, 10 iterations)
```
simd_prefix:    40,974 (11.6%) — each triggers LEB128 + second switch
i32.const:      79,905 (22.5%) — address computation
local.get:      75,823 (21.4%) — stack push overhead
i32.add/mul:    65,546 (18.5%) — address computation
local.set:      24,608 (6.9%)  — stack write overhead
br_if/br:       28,704 (8.0%)  — loop control
```

Key insight: Only 11.6% of instructions are actual SIMD operations.
The remaining 88.4% is loop overhead, address computation, and local access —
all of which RegIR handles with zero stack manipulation.

## What Wasmtime Does (Cranelift JIT)

Cranelift compiles v128 ops directly to ARM64 NEON instructions:

| Wasm SIMD op | NEON instruction | Notes |
|-------------|------------------|-------|
| f32x4.add | `fadd vD.4s, vN.4s, vM.4s` | Single cycle |
| f32x4.mul | `fmul vD.4s, vN.4s, vM.4s` | Single cycle |
| f32x4.splat | `dup vD.4s, vN.s[0]` | From scalar FP reg |
| v128.load | `ldr qD, [Xn, Xm, LSL #4]` | 128-bit load |
| splat(load) | `ld1r { vD.4s }, [Xn]` | Load + splat fused |
| f32x4.fma | `fmla vD.4s, vN.4s, vM.s[n]` | Element-indexed FMA |

Key optimizations:
- **Splat-from-load fusion**: `ld1r` replaces separate load + dup
- **FMA element-indexing**: Detects splat × vector patterns, uses indexed FMLA
- **Constant splat folding**: `movi`/`fmov` for immediates instead of load+dup
- **V0-V31 unified register file**: FP and SIMD share same registers, no spill overhead
- **No dispatch**: All loop overhead compiled to native branch instructions

## Optimization Paths

### Path A: RegIR v128 Extension (Moderate effort, large impact)

Extend RegIR to handle v128 values:
- Add `v128_regs: [MAX]u128` alongside existing `u64` register file
- New RegIR opcodes for common SIMD patterns (v128_load, v128_store, f32x4_add, etc.)
- Predecode v128 functions into RegIR format
- Eliminates stack push/pop overhead, LEB128 decode, double-switch

Expected improvement: ~10-15x faster (from stack → RegIR tier)

Pros: Reuses existing RegIR infrastructure, no platform-specific code
Cons: Still interpreted, won't match JIT performance

### Path B: JIT NEON Extension (High effort, maximum impact)

Extend JIT backend to emit ARM64 NEON instructions:
- Map v128 to Q registers (Q0-Q31, same physical as V0-V31)
- Emit NEON instructions for f32x4, i8x16, i16x8, i32x4, i64x2 ops
- Register allocation for 32 Q registers (separate from GP registers)
- Handle v128 spill/reload (128-bit stack slots)

Expected improvement: ~40-80x faster (matching wasmtime)

Pros: Native performance, parity with wasmtime
Cons: ~256 SIMD opcodes to implement, complex register allocation,
      x86 SSE/AVX would need separate implementation

### Path C: Interpreter Fast-Path (Low effort, modest impact)

Detect hot SIMD patterns (consecutive v128 load→arithmetic→store),
batch-dispatch without per-instruction overhead.

Expected improvement: ~2-4x faster (reduces dispatch, doesn't eliminate it)

Pros: Simple, platform-independent
Cons: Limited improvement, fragile pattern matching

### Path D: Hybrid RegIR + Selective NEON (Recommended)

1. First: Extend RegIR for v128 (Path A) — eliminates dispatch overhead
2. Then: JIT the most common NEON ops (Path B subset) — f32x4 arithmetic,
   v128 load/store, splat, shuffle. ~20 opcodes cover 80% of use cases.

Expected improvement: 10-15x from RegIR, additional 3-5x from selective JIT

## Recommendation

**Path D (Hybrid)** is the pragmatic choice:
- Phase 1 (45.4): RegIR v128 extension — biggest bang for effort
- Phase 2 (45.5-45.6): Selective JIT NEON for hot ops

The 88.4% non-SIMD overhead in current SIMD functions means RegIR alone
(which handles all scalar ops already) would give a massive improvement
even before JIT enters the picture.

## SIMD Parity Plan (wasmtime 1x target)

Current state after Stage 45.4: predecoded IR fast-path gives 2x improvement.
Gap remains at 22.3x vs wasmtime. Full parity requires three phases:

### Phase 1: RegIR v128 Extension (3-4 weeks)

- Add `v128_regs: [MAX]u128` parallel register file in vm.zig
- Type-tag RegInstr to distinguish u64 vs v128 register class
- Predecode v128 functions into RegIR (currently falls back to stack interp)
- New RegIR opcodes: v128_load, v128_store, f32x4_add/sub/mul/div,
  i32x4_add/sub/mul, f32x4_splat, extract_lane, v128_const, i8x16_shuffle
- Expected: 22.3x → ~2-3x gap (eliminates stack manipulation + LEB128 decode)

### Phase 2: Selective JIT NEON — 20 hot opcodes (6-8 weeks)

- Map v128 to ARM64 Q-registers (Q0-Q31, share physical with V0-V31)
- Parallel V-register allocation alongside GP registers
- 16-byte spill slots for v128 values
- Target 20 opcodes covering 80% of benchmark use:
  - f32x4: add, sub, mul, div, sqrt, splat
  - i32x4/i64x2: add, sub, mul
  - v128: load, store, const, bitselect
  - Lane: extract_lane, replace_lane, shuffle
- Expected: ~2-3x → ~1.2-1.5x gap

### Phase 3: Pattern Fusion (2-3 weeks)

- splat+load → `ld1r` (load-and-replicate)
- indexed FMA → `fmla vD.4s, vN.4s, vM.s[idx]`
- constant splat → `movi`/`fmov` immediate
- Expected: ~1.2x → ~1.0x (parity)

### Total: ~10-14 weeks for full parity

Phase 1 alone delivers the largest single improvement (10-15x).
Deferred per D122 — revisit when SIMD parity becomes a priority.
