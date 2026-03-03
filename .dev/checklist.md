# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open items

- [x] W30: JIT out-of-bounds on complex real-world programs — **FIXED**
  Root cause: four JIT codegen bugs:
  1. Guard page recovery not saved/restored across nested JIT calls (SIGBUS crashes)
  2. instrDefinesRd wrong for global.set/memory.fill/memory.copy (rd is USE not DEF)
  3. computeCalleeSavedLiveSet missing rd-as-USE and select condition vreg
  4. x86 emitCall: liveness-aware spill/reload left garbage in physical registers
  Mac + Ubuntu: spec 62,263/62,263, E2E 792/792, compat 50/50 (Ubuntu).
- [ ] W31: Intermittent ARM64 JIT crash in Go wasm programs (go_regex, go_crypto_sha256)
  Pre-existing on main. Programs sometimes produce empty stdout. Low priority.

## Resolved items (summary, details in git history)

W2 (table.init), W4 (fd_readdir), W5 (sock_*), W7 (Component Model Stage 22),
W9 (transitive imports), W10 (cross-process table), W13/W27 (throw_ref Stage 32),
W14 (wide arithmetic), W15 (custom page sizes), W16 (wast2json NaN),
W17 (WAT parser), W18 (memory64 tables), W20 (GC collector), W21 (GC WAT),
W22 (multi-module linking Stage 32), W23 (GC subtyping Stage 32),
W24 (GC type canon Stage 32), W25 (endianness64 Stage 32),
W26 (externref Stage 32), W28 (call batch state Stage 32),
W29 (threads spec Stage 29), W30 (GC type annotation Stage 44),
W31 (WAT input validation Stage 44), W32 (SIMD performance Stage 45),
W34 (JIT back-edge reentry reliability-005).
