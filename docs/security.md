# zwasm Threat Model

This document describes zwasm's security boundaries, what it protects against,
and what it does not. It serves as a reference for embedders evaluating whether
zwasm meets their security requirements.

## Trust Boundaries

zwasm enforces a clear boundary between **guest** (WebAssembly module) and
**host** (the embedding Zig application or CLI).

```
+-------------------+     WASI capabilities     +------------------+
|   Guest (Wasm)    | <-- deny-by-default --->  |   Host (Zig/CLI) |
|                   |                           |                  |
| Linear memory     |     Imports/exports       | Native memory    |
| Table entries     | <-- validated types --->  | Filesystem, env  |
| Global variables  |                           | Network, OS APIs |
+-------------------+                           +------------------+
        |                                               |
        |  Hardware isolation (guard pages, W^X)        |
        +-----------------------------------------------+
```

A valid Wasm module, no matter how adversarial, cannot:

- Read or write host memory outside its own linear memory
- Call host functions not explicitly imported
- Bypass WASI capability restrictions
- Execute code outside its validated instruction stream
- Overflow the call stack or value stack without trapping

## Attack Surfaces

### 1. Module Decoding (src/module.zig)

**Threat**: Malformed binary input causes memory corruption or excessive allocation.

**Mitigations**:
- Section count limits (types, functions, globals, etc.): 100-100,000 per section
- Per-function locals limit: 50,000 with saturating arithmetic for overflow detection
- Block nesting depth limit: 500
- All LEB128 reads are bounds-checked against the binary slice
- Fuzz-tested with 25,000+ modules including structure-aware generators

### 2. Validation (src/validate.zig)

**Threat**: Invalid module passes validation and causes undefined behavior at runtime.

**Mitigations**:
- Full Wasm 3.0 spec compliance: 62,158/62,158 spec tests pass
- Type checking for all instructions including GC, SIMD, exception handling
- Control flow integrity verified (block/loop/if nesting, branch targets)

### 3. Linear Memory (src/memory.zig)

**Threat**: Out-of-bounds memory access leaks host data or corrupts host state.

**Mitigations**:
- Every load/store uses u33 arithmetic (address + offset) to prevent 32-bit overflow
- Bounds check: `effective_address + access_size > memory.data.len` before any pointer dereference
- Guard pages (optional): 4 GiB + 64 KiB PROT_NONE region catches hardware faults
- Signal handler converts guard page faults to Wasm traps via RecoveryInfo

### 4. Tables and Indirect Calls (src/store.zig, src/vm.zig)

**Threat**: call_indirect with attacker-controlled index calls wrong function or crashes.

**Mitigations**:
- Table.lookup() bounds-checks index before access, returns error.UndefinedElement
- Null table entries (uninitialized slots) return error.UndefinedElement
- Type signature check on every call_indirect using canonical type IDs

### 5. JIT Code Generation (src/jit.zig)

**Threat**: JIT-generated code escapes sandbox or is modified after generation.

**Mitigations**:
- W^X enforcement: code buffer allocated RW during generation, transitions to RX before execution
- No simultaneous write+execute permission on JIT code pages
- Guard page mode: memory bounds rely on hardware fault (PROT_NONE pages)
- Non-guard mode: explicit CMP + conditional branch before every memory access
- JIT signal handler validates fault address is within known JIT code range

### 6. WASI Capabilities (src/wasi.zig)

**Threat**: Guest module reads files, environment variables, or accesses OS resources.

**Mitigations**:
- Deny-by-default capability model: all capabilities start disabled
- CLI defaults: only stdio, clock, random, and proc_exit enabled
- Filesystem: restricted to preopened directories only (no arbitrary path traversal)
- Path pointers validated against linear memory bounds before use
- Each WASI function checks its required capability at entry

### 7. Call Stack (src/vm.zig)

**Threat**: Deep recursion causes native stack overflow (host process crash).

**Mitigations**:
- Hard limit: MAX_CALL_DEPTH = 1024, checked before every function entry
- Applies to all call types: direct, indirect, and JIT-compiled calls
- JIT caches depth counter in register for zero-overhead checking

### 8. Value Stack (src/vm.zig)

**Threat**: Stack overflow/underflow corrupts VM state.

**Mitigations**:
- Operand stack: 4096 slots, overflow checked on every push
- Frame stack: 1024 slots, overflow checked on every push
- Label stack: 4096 slots, overflow checked on every push
- Pop underflow: prevented by validator (all type-checked instruction sequences
  guarantee balanced push/pop). Not runtime-checked for performance.

### 9. Host Function Interface

**Threat**: Host function exposes native pointers or allows guest to corrupt host state.

**Mitigations**:
- Host functions receive typed values (u32, u64, f32, f64), not raw pointers
- Memory access from host goes through the same bounds-checked Memory.read/write API
- No mechanism for guest to obtain or forge host pointers

## What zwasm Does NOT Protect Against

1. **Timing side channels**: No constant-time guarantees. Wasm execution time is
   observable and may leak information about branch patterns or memory access.

2. **Resource exhaustion beyond limits**: A module can allocate up to 4 GiB of
   linear memory and consume CPU until externally terminated. zwasm does not
   enforce CPU time limits or memory quotas beyond the Wasm spec.

3. **Host function bugs**: If a host-provided import function has vulnerabilities,
   zwasm cannot prevent exploitation through that function.

4. **Spectre-class attacks**: No mitigations for speculative execution side channels.
   Wasm's linear memory model provides some inherent isolation but is not
   designed to prevent microarchitectural attacks.

5. **Denial of service**: A malicious module can enter infinite loops, allocate
   maximum memory, or perform expensive computations. Embedders should apply
   external timeout/resource limits for untrusted modules.

6. **Non-determinism**: Thread-related operations, relaxed SIMD, and floating-point
   NaN bit patterns may produce different results across platforms. This does not
   affect safety but may affect reproducibility.

## Build Configuration

zwasm is distributed as ReleaseSafe, which preserves:
- Array bounds checks
- Integer overflow detection
- Null pointer checks
- Unreachable code assertions

ReleaseFast strips these safety checks and is NOT recommended for production use
with untrusted Wasm modules.

## Spec Compliance

Full Wasm 3.0 compliance (9 proposals):
- memory64, exception_handling, tail_call, extended_const
- branch_hinting, multi_memory, relaxed_simd
- function_references, gc

Spec test results: 62,158/62,158 (100.0%) on both macOS ARM64 and Ubuntu x86_64.
