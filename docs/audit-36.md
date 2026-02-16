# Security Audit Findings (Stage 36)

Systematic audit of zwasm security boundaries. Each section corresponds to a
Phase 36 sub-task from the production roadmap.

## 36.2: Linear Memory Isolation

**Status**: PASS

All memory access paths are bounds-checked before pointer dereference:

| Path | Location | Mechanism |
|------|----------|-----------|
| Memory.read() | memory.zig:172 | u33(offset+address) + sizeof(T) > len |
| Memory.write() | memory.zig:187 | u33(offset+address) + sizeof(T) > len |
| Memory.copy() | memory.zig:142 | u64(address) + data.len > len |
| Memory.fill() | memory.zig:149 | u64(dst) + n > len |
| Memory.copyWithin() | memory.zig:156 | u64(dst/src) + n > len |
| VM memLoad* | vm.zig:5166+ | Delegates to Memory.read() |
| VM memStore* | vm.zig:5188+ | Delegates to Memory.write() |
| VM memLoadCached | vm.zig:5105 | Delegates to Memory.read() |
| VM memStoreCached | vm.zig:5127 | Delegates to Memory.write() |
| JIT (non-guard) | jit.zig:2793 | CMP effective+size > mem_size, branch to error |
| JIT (guard pages) | guard.zig:22 | 4GiB+64KiB PROT_NONE, signal handler converts to trap |

**Key defense**: u33 arithmetic prevents 32-bit address+offset overflow wrapping.
