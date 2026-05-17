---
name: mac-aarch64-thread-rx-mode-survives-alloc
description: On Mac aarch64, jit_mem.alloc() does NOT flip the thread's W^X state back to RW — subsequent JIT-page writes silently SEGV. Any new JIT-page allocator wrapper must pair alloc with setWritable, matching linker.zig.
metadata:
  type: feedback
---

**Rule**: any wrapper that allocates JIT pages via
`platform.jit_mem.alloc` MUST follow with `jit_mem.setWritable`
before the caller writes into the returned block.

**Why**: on Mac aarch64, `pthread_jit_write_protect_np` is a
**per-thread** flag, not per-block. `jit_mem.alloc` mmaps with
MAP_JIT but never toggles the flag — so if the prior JIT compile
left the thread in RX mode (via `setExecutable` at the end of
`linker.linkBlock`), the freshly-mapped MAP_JIT page is
unwritable for the current thread. A subsequent emit hits a
SIGSEGV that the spec runner's handler catches as "SEGV outside
armed JIT call" → `_exit(142)` (D-134-style exit). It looks like
a hang because stdout is buffered up to the exit — the failure is
two screens away from the actual point.

**How to apply**:

- New `allocXxxArena` / `allocXxxBlock` helpers in
  `src/engine/codegen/shared/*` must follow `alloc + setWritable`,
  mirroring `linker.linkBlock`'s pattern (line ~186).
- The docstring SHOULD claim "returned block is writable"; the
  implementation MUST honour it.
- Resolver / patch / re-link code paths that re-enter the block
  after `finalizeArena` (= `setExecutable`) must call
  `unfinalizeArena` (= `setWritable`) before writing.

**Where**: §9.9-III chunk (c)-2.3-β-2b discovered this when
`shared/thunk.zig::allocArena` followed `compileWasm`'s trailing
`setExecutable` and tried to `emitThunk` directly. The thunk
write SEGV'd; the SIGSEGV handler hit the `_exit(142)` path; the
test runner exited with the D-134 disambiguation code, masquerading
as a corpus hang. Fixed by adding `setWritable` inside
`allocArena` — same shape as `linker.linkBlock`.

**Linux / Windows**: not affected — those platforms map RWX
directly, and `setWritable` / `setExecutable` are no-ops there.
The lesson is Mac-aarch64-specific by construction, but the
"alloc + setWritable pair" idiom is cheap to apply unconditionally
(no-op cost on the other two hosts).

**Related**: [[d134-rosetta-2-signal-translation-limit]] —
shares the `_exit(142)` exit code by design (per the
disambiguation probe in `sigsegvHandler`); the two failures look
identical from `zig build`'s vantage point. Distinguish by
inspecting which compile path was active: Rosetta race surfaces
under translated execution, this gap surfaces on native Mac
aarch64 after any JIT-page allocator that omits the
`setWritable` pair.
