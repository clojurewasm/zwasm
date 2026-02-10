# JIT Check Rules

Auto-load paths: `src/jit.zig`

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
