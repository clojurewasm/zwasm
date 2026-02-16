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

## 36.3: Table Bounds + Type Check

**Status**: PASS

All table access paths are bounds-checked and type-verified:

| Path | Location | Mechanism |
|------|----------|-----------|
| Table.lookup() | store.zig:113 | index >= len returns UndefinedElement |
| Table.get() | store.zig:118 | index >= len returns OutOfBounds |
| Table.set() | store.zig:123 | index >= len returns OutOfBounds |
| call_indirect (bytecode) | vm.zig:891 | lookup + matchesCallIndirectType |
| call_indirect (IR) | vm.zig:4254 | lookup + matchesCallIndirectType |
| return_call_indirect | vm.zig:925,4277 | lookup + matchesCallIndirectType |
| table.get (IR) | vm.zig:4332 | Table.get() bounds check |
| table.set (IR) | vm.zig:4338 | Table.set() bounds check |

**Type safety**: call_indirect checks canonical type IDs first, falls back to
structural comparison. MismatchedSignatures error on type mismatch.

**Null element defense**: Uninitialized table slots contain `null`, which
Table.lookup() rejects as UndefinedElement before any dereference.

## 36.4: JIT W^X Verification

**Status**: PASS

Both ARM64 (jit.zig) and x86_64 (x86.zig) follow strict W^X:

1. `mmap(PROT_READ | PROT_WRITE)` — writable, not executable
2. `@memcpy` instructions into buffer
3. `mprotect(PROT_READ | PROT_EXEC)` — executable, not writable
4. ARM64: `icacheInvalidate()` after mprotect
5. x86_64: coherent I/D caches, no flush needed

No code path creates `PROT_READ | PROT_WRITE | PROT_EXEC` pages.
JIT code is never modified after mprotect transition.

| Arch | mmap | mprotect | Location |
|------|------|----------|----------|
| ARM64 | jit.zig:3955 (RW) | jit.zig:3970 (RX) | finalize() |
| x86_64 | x86.zig:2472 (RW) | x86.zig:2485 (RX) | finalize() |
