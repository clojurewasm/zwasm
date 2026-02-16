# Deferred Work Checklist

Open items only. Resolved items removed (see git history).
Check at session start for items that become actionable.
Prefix: W## (to distinguish from CW's F## items).

## Invariants (always enforce)

- [ ] D100: No CW-specific types in public API (Value, GC, Env)
- [ ] D102: All types take allocator parameter, no global allocator

## Open items

None currently. All W2-W29 resolved as of Stage 34 (62,158/62,158 spec, 356/356 E2E).

## Resolved items (summary, details in git history)

W2 (table.init), W4 (fd_readdir), W5 (sock_*), W7 (Component Model Stage 22),
W9 (transitive imports), W10 (cross-process table), W13/W27 (throw_ref Stage 32),
W14 (wide arithmetic), W15 (custom page sizes), W16 (wast2json NaN),
W17 (WAT parser), W18 (memory64 tables), W20 (GC collector), W21 (GC WAT),
W22 (multi-module linking Stage 32), W23 (GC subtyping Stage 32),
W24 (GC type canon Stage 32), W25 (endianness64 Stage 32),
W26 (externref Stage 32), W28 (call batch state Stage 32),
W29 (threads spec Stage 29).
