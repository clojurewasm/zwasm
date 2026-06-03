# Win64 JIT trampoline-call sites hardcoded SysV arg regs → garbage on Windows

**Date**: 2026-06-03 · **Context**: §11.P windowsmini reconcile — first Win64 run of Phase-10 JIT EH/GC

## Observation

The §11.P phase-boundary windowsmini `test-all` (first since Phase-10's EH-on-JIT +
GC-on-JIT landed) surfaced two Win64-only failures that Mac-arm64 + Linux-x86_64-SysV
had been green on the whole time: `throw_trampoline` test SEGV, and `struct.new_default
+ ref.is_null → 0` returning 1 (null). **Unifying root cause**: x86_64 emit code that
CALLs a `callconv(.c)` helper (jitGcAlloc, the throw trampoline) **hardcoded the SysV
argument registers** (`.rdi`/`.rsi`/`.rdx`/`.rcx`) instead of the Cc-aware
`abi.current.arg_gprs[N]` that the prologue already uses. On Win64 the helper reads args
from RCX/RDX/R8/R9, so it got garbage → `jitGcAlloc` returned the null sentinel (0) →
`ref.is_null` saw 0 → returned 1.

This was invisible on the per-chunk 2-host gate (Mac + ubuntunote) because **SysV is the
only ABI both of those hosts use**, and Win64 JIT only runs at the phase-boundary
windowsmini reconcile — so an entire phase of GC/EH JIT op-emit shipped without one Win64
exercise (the same structural blind spot as the OS-only compile drift in
[[2026-06-03-windowsmini-reconciliation-catches-os-only-compile-drift]]).

## Rule

- **Never hardcode `.rdi`/`.rsi`/`.rdx`/`.rcx` for a `callconv(.c)` call site in x86_64
  emit — route through `abi.current.arg_gprs[N]`.** It compiles to the same bytes on
  SysV (`arg_gprs[0..3] == {rdi,rsi,rdx,rcx}`, abi.zig:60 + test) so the change is a
  **provable no-op on Mac+Linux** (existing byte-level tests prove it) and only corrects
  Win64. The regalloc pool is comptime-disjoint from `arg_gprs` on both ABIs, so a
  per-arg index swap has no register-shuffle collision hazard.
- **Win64 has only 4 GPR arg slots (RCX/RDX/R8/R9).** A helper with **≥5 integer args**
  (array_copy/fill/init_* etc.) cannot be fixed by an index swap — `arg_gprs[4]` is
  out-of-bounds on Win64; args 5/6 must spill to the stack above the 32-byte shadow
  space. That is a holistic per-op rework, not a literal swap (tracked: D-248).
- **A test wrapper that hand-marshals into a naked trampoline is ALSO an ABI surface.**
  `invokeTrampolineWith` was SysV-only (tag→RDI); the *production* `.windows` trampoline
  reads the incoming tag from RCX, so the wrapper needed its own `.windows` arm. Mirror
  the working SysV arm's push structure exactly so RSP parity at the trampoline entry
  matches production (entry RSP ≡ 8 mod 16).

Related: [[2026-06-03-host-to-jit-must-preserve-callee-saved]] (D-245 — the *other* Win64
host↔JIT ABI family: caller-saved preservation, distinct from arg-reg routing).
