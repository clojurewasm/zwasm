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

## 36.5: JIT Bounds Audit (generated code cannot escape sandbox)

**Status**: PASS

JIT-generated code cannot escape the sandbox:

**Memory access bounds** (two modes):
- Non-guard: explicit CMP effective+size > mem_size + conditional branch to error
  (jit.zig:2793 load, jit.zig:2827 store)
- Guard pages: 4GiB+64KiB PROT_NONE region, hardware fault → signal handler → trap

**Branch target validation**:
- patchBranches() (jit.zig:3914): validates target_pc within pc_map range
- All branches resolved to concrete offsets within the code buffer at compile time
- Error stubs branch to shared exit (RET instruction)

**Signal handler safety** (guard.zig:132):
1. Checks `recovery.active` — only handles faults during JIT execution
2. Validates faulting PC within `[jit_code_start, jit_code_end)` range
3. Non-JIT faults re-raised with default handler (crash, not silent)
4. Redirects to OOB error return stub setting error code + RET

**JIT return interface**:
- JIT functions return u64 error code via x0/rax (0=success, non-zero=error)
- Caller checks return value and converts to WasmError
- No raw native pointers exposed to guest code

## 36.6: WASI Capability Audit

**Status**: PASS

46 WASI functions registered. Deny-by-default capability model with 8 flags.

**Capability-checked functions** (32 functions with hasCap()):

| Capability | Functions |
|-----------|-----------|
| allow_env | environ_get, environ_sizes_get |
| allow_clock | clock_time_get, clock_res_get |
| allow_stdio | fd_read (fd 0-2), fd_write (fd 0-2) |
| allow_read | fd_read (fd >2), fd_pread, fd_readdir, path_filestat_get, fd_filestat_get (via read) |
| allow_write | fd_write (fd >2), fd_pwrite, fd_datasync, fd_sync, fd_allocate, fd_fdstat_set_flags, fd_filestat_set_size, fd_filestat_set_times, fd_renumber |
| allow_path | path_open, path_create_directory, path_remove_directory, path_rename, path_symlink, path_unlink_file, path_readlink, path_link, path_filestat_set_times |
| allow_proc_exit | proc_exit |
| allow_random | random_get |

**No-cap functions** (by design, not a gap):
- args_get/args_sizes_get: args are host-provided, not privileged
- fd_close/fd_fdstat_get/fd_prestat_get/fd_prestat_dir_name: operate on already-open FDs
- fd_seek/fd_tell: position within already-open FDs
- sched_yield/poll_oneoff: harmless scheduling

**Stub functions** (return NOSYS, no capability needed):
- fd_fdstat_set_rights, proc_raise, sock_accept/recv/send/shutdown

**CLI defaults**: only stdio, clock, random, proc_exit enabled.
File read/write/path disabled by default — must be explicitly enabled.

## 36.7: Stack Depth Limit Verification

**Status**: PASS (with design note)

| Stack | Size | Overflow check | Underflow check |
|-------|------|---------------|-----------------|
| Operand | 4096 | vm.zig:5218 push() | No runtime check |
| Frame | 1024 | vm.zig:5269 pushFrame() | No runtime check |
| Label | 4096 | vm.zig:5284 pushLabel() | No runtime check |
| Call depth | 1024 | vm.zig:404,3200,4686 | N/A (counter) |

**Overflow**: All stacks checked before every push. StackOverflow on exceed.

**Underflow**: Not runtime-checked. Validator (validate.zig) ensures all
instruction sequences produce balanced push/pop. A module that passes
validation cannot underflow at runtime. If validation is bypassed (bug),
underflow causes usize wrap → array OOB → Zig safety check (ReleaseSafe)
or undefined behavior (ReleaseFast).

**Design note**: Pop underflow is a performance trade-off. Adding a runtime
check to pop() would add overhead to the hottest path in the interpreter.
The validator provides the safety guarantee. ReleaseSafe bounds checks
provide a second defense layer.
