# 0167 — Interp deep-recursion: native-stack-limit check, not a flat interp

- **Status**: Accepted (design) 2026-06-06
- **Date**: 2026-06-06
- **Author**: `/continue` loop (D-288 REWORK Phase I + III)
- **Tags**: phase-16, interp, stack-overflow, robustness, win64, posix
- **Companion**: ADR-0105 (JIT-prologue stack-probe — the precedent this
  mirrors for the interpreter). Debt: D-288.

## Context

The interpreter recurses on the **host native stack** for every wasm
call: `src/interp/mvp.zig:654 invoke()` is re-entered (≈8 KB/frame) from
5 call sites (`callOp`, `call_indirect`, `call_ref`, `return_call`,
`return_call_indirect`). A fixed `frame_buf[256]` in `runtime.zig:354`
traps `CallStackExhausted` at 256 frames — a SAFETY GUARD that fires
*before* the host stack SEGVs (~1021-deep on a Mac 8 MB stack).

Two problems:

1. **Latent Windows SEGV**: Windows default thread stack is 1 MB → the
   real native ceiling is ~128 frames, *below* the 256-frame guard. A
   128–256-deep wasm recursion on Win64 SEGVs (crash) instead of
   trapping cleanly. Pre-existing; current Win test programs don't reach
   it, but it is a correctness hole.
2. **Arbitrary shallow ceiling**: 256 is lower than a normal runtime
   (wasmtime runs ackermann(3,7) = 1021-deep). Raising the cap is WRONG
   — it removes the guard (tested `cap=4096` → ackermann SEGV at the
   real ~1021 native limit instead of a clean trap; reverted).

## Decision

Adopt **option (b): add a native-stack-limit check to the interpreter's
`invoke()`**, mirroring the JIT prologue stack-probe (ADR-0105). On each
`invoke()`, compare the current native SP against
`platform.stack_limit.computeStackLimit(headroom)` (the per-OS low
bound) and trap `CallStackExhausted` *before* recursing if the next
frame would cross it. The `frame_buf[256]` guard stays as a cheap
upper bound; the SP check makes the **real** per-OS native limit the
binding one, so deep recursion traps cleanly on EVERY platform (no
SEGV), at a depth close to the host's true capacity.

**The native-recursion ceiling is an intentional, documented property
of both engines**, not a bug.

## Options considered

- **(a) Flat / trampolined interpreter** — process frames via a heap
  frame-stack with no native recursion per call; runs arbitrary depth
  (ackermann). REJECTED for now: (1) it is a substantial interp-core
  rewrite; (2) it creates an **engine asymmetry** — the JIT *also*
  recurses on the native stack (real `call` instructions) and cannot run
  unbounded depth, so a flat interp would let the slow reference engine
  out-recurse the fast JIT. The wasm spec mandates **no** minimum call
  depth (`call stack exhausted` is a valid trap at any
  implementation-defined limit), so deeper-than-JIT recursion is a
  non-spec-mandated capability, not a completeness gap. Consistent
  clean-trap-at-native-limit across both engines is the cleaner 完成形
  design. (a) remains a possible future interp-architecture enhancement
  if a concrete need for unbounded interp recursion appears.
- **(c) Run interp on a large stack (thread/fiber) or shrink the ~8 KB
  invoke frame** — orthogonal mitigations that raise the ceiling but do
  not remove the SEGV-vs-trap hole; (b) is required regardless.

## Consequences

- **Correctness**: deep recursion traps `CallStackExhausted` cleanly on
  Mac/Linux/Windows — the latent Win64 SEGV is closed.
- **Consistency**: interp and JIT both trap at their real native ceiling
  via the same `stack_limit` infrastructure.
- **Cost**: one SP read + compare per `invoke()` (negligible; the JIT
  pays the same per-call). `computeStackLimit` returns `0` (disabled)
  gracefully on unsupported platforms → the `frame_buf[256]` guard
  remains the fallback there.
- **No `Error`-set widening**: the trap is the existing
  `CallStackExhausted`, surfaced through the normal trap path (cf.
  `platform_panic_vs_error.md` — no new shared-`Error` variant).

## Implementation (D-288 Phase IV)

1. **Phase II first (correctness gate)**: characterization test pinning
   current clean-trap behaviour on a deep-but-bounded recursion fixture
   (Mac), + a fixture that would exceed Windows' ~128 ceiling to prove
   the new check traps instead of SEGV-ing (verified on the win gate).
2. Add a `headroom` const for the interp (a few native frames of
   margin) and a `checkNativeStackLimit()` helper reading the current SP
   (`@frameAddress()`), called at the top of `invoke()`; trap
   `CallStackExhausted` when `sp <= limit`.
3. Keep `frame_buf[256]`; the SP check is the binding limit when
   `computeStackLimit != 0`.
4. Discharge D-288: deep-recursion fixture traps cleanly 3-host (esp.
   the Win64 no-SEGV guarantee), ADR documents the ceiling.
