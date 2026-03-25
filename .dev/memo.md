# zwasm Development Memo

Session handover document. Read at session start.

## Current State

- Stages 0-46 + Phase 1, 3, 5, 8, 10, 11, 13, 15, 19, **20** complete.
- Spec: 62,263/62,263 Mac+Ubuntu (100.0%, 0 skip).
- E2E: 797/797 (Mac+Ubuntu). Fixed JIT memory64 bounds + custom-page-sizes 2026-03-25.
- Real-world: Mac 50/50, Ubuntu 50/50. go_math_big fixed 2026-03-25.
- JIT: Register IR + ARM64/x86_64 + SIMD (NEON 253/256, SSE 244/256).
- HOT_THRESHOLD=3 (lowered from 10 in W38).
- Binary: 1.29MB stripped. Memory: ~3.5MB RSS.
- Platforms: macOS ARM64, Linux x86_64/ARM64, Windows x86_64.
- **main = stable**. ClojureWasm updated to v1.5.0.

## Current Task

**W44: SIMD Register Class (D132 Phase B) — ARM64 + x86 DONE (Mac verified)**

Added SIMD register cache: Q16-Q31 (ARM64, 16 regs) and XMM6-XMM15 (x86, 10 regs).
Eliminates per-op simd_v128[] memory traffic via lazy writeback with LRU eviction.

### Design (from D132 Phase B)

**Goal**: v128 values stay in SIMD registers across consecutive operations.
Current: every SIMD op does `load simd_v128[vreg] → NEON/SSE → store simd_v128[vreg]`.
Target: `v128.const → Q16`, `i32x4.add Q16,Q17 → Q18`, no memory traffic.

**Register allocation**:
- ARM64: Q16-Q31 for v128 (16 regs, no FP D-cache conflict since D-cache uses D2-D15)
- x86: XMM5-XMM15 for v128 (~11 regs), XMM0-XMM2 scratch, XMM3-XMM4 existing SIMD scratch

**Implementation plan (ordered by dependency)**:

1. **regalloc.zig: v128 type tracking**
   - Add `is_v128` bit to vreg metadata (or separate v128_vregs bitset)
   - SIMD opcodes mark their rd as v128, rs1/rs2 as v128 consumers
   - Scalar ops consuming v128 (e.g., `i32x4.extract_lane`) need cross-class handling

2. **regalloc.zig: SIMD register class allocation**
   - New `simd_reg_count` field — number of v128 vregs mapped to physical SIMD regs
   - v128 vregs get separate numbering from scalar vregs
   - Spill target: `simd_v128[]` array (existing, already used by interpreter)

3. **jit.zig (ARM64): Q register mapping**
   - `v128VregToPhys(vreg) → Q16..Q31` mapping function
   - `emitSimdBinaryOp`: operate directly on Q regs instead of load/op/store
   - `emitLoadV128`/`emitStoreV128`: only for spill/reload, not every op
   - Prologue: load v128 vregs from `simd_v128[]` into Q regs
   - Epilogue: store dirty Q regs back to `simd_v128[]`

4. **x86.zig: XMM register mapping**
   - Same pattern as ARM64 but with XMM5-XMM15
   - Existing `SIMD_SCRATCH0`/`SIMD_SCRATCH1` (XMM3/XMM4) unchanged

5. **Spill/reload across calls**
   - Q16-Q31 are caller-saved on ARM64 → spill to `simd_v128[]` before BLR
   - XMM are caller-saved on x86 → same pattern
   - `spillCallerSaved`/`reloadCallerSaved` must handle SIMD reg class

6. **Cross-tier compatibility (trampoline)**
   - Before JIT→interpreter transition: flush dirty Q/XMM to `simd_v128[]`
   - After interpreter→JIT return: reload Q/XMM from `simd_v128[]`
   - `emitStoreV128` already writes lo-half to `regs[]` — keep for compatibility

7. **Lane extract/insert (cross-class)**
   - `i32x4.extract_lane`: Q reg → scalar GPR (UMOV on ARM64, PEXTRD on x86)
   - `i32x4.replace_lane`: scalar GPR → Q reg (INS on ARM64, PINSRD on x86)

**Key risks**:
- FP D-cache (D2-D15) shares the lower halves with Q2-Q15. Using Q16-Q31
  avoids this conflict entirely.
- `spillCallerSaved` loop needs to iterate both scalar and SIMD reg classes.
- v128.const pool values (128-bit) need careful loading into Q regs.

**Expected improvement**: 30-50% on SIMD-heavy code.

### Approach

Start with ARM64 (cleaner register model, Q16-Q31 are dedicated).
Work incrementally: first handle binary ops (i32x4.add etc.), then unary,
then const/load/store, then spill/reload, then x86.

### Key code locations

- `src/regalloc.zig`: vreg allocation, `RegInstr` struct, `OP_SIMD_*` handling
- `src/jit.zig`: `emitSimdBinaryOp`, `emitLoadV128`, `emitStoreV128`, prologue/epilogue
- `src/x86.zig`: same pattern, XMM regs
- `src/predecode.zig`: `SIMD_BASE` opcode range (0xFD00+)
- `src/vm.zig`: interpreter SIMD execution (reference for semantics)

### Open Work Items

| Item       | Description                                       | Status         |
|------------|---------------------------------------------------|----------------|
| **W44**    | **SIMD register class (D132 Phase B)**            | **Mac DONE, needs Ubuntu verify** |
| Phase 18   | Lazy Compilation + CLI Extensions                 | Future         |
| Zig 0.16   | API breaking changes                              | When released  |

## Completed Phases (summary)

| Phase    | Name                                  | Date       |
|----------|---------------------------------------|------------|
| 1        | Guard Pages + Module Cache            | 2026-03    |
| 3        | CI Automation + Documentation         | 2026-03    |
| 5        | C API + Conditional Compilation       | 2026-03    |
| 8        | Real-World Coverage + WAT Parity      | 2026-03    |
| 10       | Quality / Stabilization               | 2026-03    |
| 11       | Allocator Injection + Embedding       | 2026-03    |
| 13       | SIMD JIT (NEON + SSE)                 | 2026-03-23 |
| 15       | Windows Port                          | 2026-03    |
| 19       | JIT Reliability                       | 2026-03    |
| 20       | JIT Correctness Sweep                 | 2026-03-25 |

## Next Session Reference Chain

1. **Orient**: `git log --oneline -5 && git status && git branch`
2. **This memo**: current task (W44 design + implementation plan)
3. **D132 Phase B**: `@./.dev/decisions.md` → search `## D132` → "Phase B"
4. **regalloc.zig**: `RegInstr` struct, SIMD opcode handling (search `SIMD_BASE`)
5. **jit.zig**: `emitSimdBinaryOp`, `emitLoadV128`, `emitStoreV128`, `SIMD_SCRATCH0/1`
6. **x86.zig**: same patterns as jit.zig
7. **Reference impl**: wasmtime cranelift (`~/Documents/OSS/wasmtime/`) — SIMD register allocation
8. **SIMD benchmarks**: `bench/run_simd_bench.sh` — A/B comparison
9. **Ubuntu testing**: `@./.dev/references/ubuntu-testing-guide.md`
10. **Merge gate**: CLAUDE.md → "Merge Gate Checklist" section

## References

- `@./.dev/roadmap.md` — Phase roadmap
- `@./.dev/checklist.md` — resolved work items
- `@./.dev/decisions.md` — D130 (SIMD arch), D132 (SIMD perf plan)
- `@./.dev/jit-debugging.md` — JIT debug techniques
- `@./.dev/references/w38-osr-research.md` — OSR research
- `bench/simd_comparison.yaml` — SIMD performance data
- `bench/history.yaml` — benchmark history (latest: phase20-rem-fix)
- External: wasmtime (`~/Documents/OSS/wasmtime/`), zware (`~/Documents/OSS/zware/`)
