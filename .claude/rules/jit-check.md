---
paths:
  - "src/jit.zig"
---

# JIT Check Rules

## Before committing JIT changes

1. **Dump & disassemble**: Write mmap buffer to /tmp, ELF wrap, `objdump -d`
   to verify generated ARM64 instructions. See `.dev/jit-debugging.md`.

2. **CSET encoding pitfall**: Rn field must be WZR (register 31), not R0.
   Base encoding = `0x1A9F07E0`. Wrong Rn causes silent wrong results.

3. **pc_map indexing**: Must use actual RegInstr PC, not loop iteration count.
   Off-by-one here causes wrong deopt/branch targets.

4. **Cross-module safety**: Reset `jit_code`, `jit_failed`, `call_count`
   when copying functions across modules (function imports).

5. **Run benchmarks**: `bash bench/run_bench.sh --quick` to verify no regression.

6. **Scratch register cache**: `getOrLoad(vreg, hint)` only checks the scratch cache
   when `hint == SCRATCH`. Passing a different register (e.g. `destReg(rd)`) bypasses
   the cache, turning free MOVs into memory loads. Always use SCRATCH as the hint
   unless you have verified the cache impact with A/B benchmarks.

7. **Peephole A/B verification**: Instruction count reduction does not guarantee
   speedup. Always A/B benchmark peephole changes — micro-architectural effects
   (branch prediction, CPU instruction fusion) can cause regressions.
