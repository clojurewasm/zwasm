# 0185 — x86_64 cross-instance EH frame-walk (thunk frame-link + global sniff resolution)

- **Status**: Accepted (2026-06-14; autonomous loop, D-238 implementation campaign)
- **Date**: 2026-06-14
- **Author**: claude (autonomous loop)
- **Tags**: x86_64, exception-handling, unwind, cross-instance, bridge-thunk, frame-chain, sniff, D-238, D-184, ADR-0134
- **Paired debt**: D-238 (x86_64 EH-JIT parity); implements the (a)+(b)+(c) design recorded there.
- **Amends**: ADR-0134 (cross-instance EH per-frame dispatch) — extends the frame-WALK side; ADR-0066 (bridge thunk) — widens the x86_64 thunk; builds on D-184 (x86_64 prologue-sniff).

## Context

arm64 cross-instance EH-on-JIT works (`4f73d9ee`): the bridge thunk
`MOV X29,SP` frame-links so the pure-pointer FP-walk traverses it, and
`eh_registry` does per-frame handler dispatch. The x86_64 side does NOT
work — a cross-instance JIT throw can't reach the importer's catch.

Two-cycle investigation (`eba26059` + `74fa9511`) found the x86_64 gap is
deeper than a missing thunk frame-link:

1. **The thunk frame isn't a chain link** — the 27-byte x86_64 thunk
   (`x86_64/thunk.zig`) does `PUSH R15; …; CALL; POP R15; RET` with no RBP
   frame, so the unwinder can't walk through it.

2. **The x86_64 sniff is single-CodeMap.** Unlike arm64's pure-pointer
   `loadFrame`, x86_64 `loadFrameSniffed` (`x86_64/frame_chain.zig:68`)
   must disambiguate two prologue layouts (standard `PUSH RBP; MOV RBP,RSP`
   vs uses_runtime_ptr `PUSH RBP; PUSH R15; MOV RBP,RSP`, saved-RIP at
   `[RBP,8]` vs `[RBP,16]`) by CodeMap-resolving the candidate slot to
   `.inside`. But `unwind.walk` feeds the loader ONE CodeMap —
   `normalize_ctx` = the THROWING instance's CodeMap, set once by
   `code_map.adapterContextFor` (`code_map.zig:145`); the per-frame
   `resolver` only dispatches handler tables (`unwind.zig:153`), NOT frame
   loading (`:184`). In `M1 imports f from M2; M2.f throws`, the bridge
   thunk lives in **M1's (importer's) thunk_arena** and the importer frames
   are in **M1's CodeMap** — neither is the throwing M2's CodeMap. So the
   callee (M2.f, R15-pushed) frame's saved-RIP = a thunk address resolves
   `.outside` M2's CodeMap → the sniff mis-identifies the layout and
   mis-walks (falls to the wrong default at `frame_chain.zig:92`).

A rejected earlier idea ("register the thunk arena as an empty sentinel
CodeMap") does NOT work: an empty map returns `.outside`, which is exactly
the wrong answer — the sniff needs the thunk-return slot to resolve as a
valid code address so it picks the R15-pushed layout `[RBP,16]`.

## Decision

Three coordinated changes:

**(a) RBP-framed x86_64 bridge thunk** (`x86_64/thunk.zig`, 27→40 bytes):

```text
PUSH RBP; MOV RBP,RSP; PUSH R15; SUB RSP,8;
MOV RDI,callee_rt; MOV RAX,callee_entry; CALL RAX;
ADD RSP,8; POP R15; POP RBP; RET
```

The standard `PUSH RBP; MOV RBP,RSP` makes the thunk frame a chain link
(`[RBP,0]`=saved importer RBP, `[RBP,8]`=importer return address). `PUSH
R15` keeps the D-142 cohort save/restore around the CALL. `SUB RSP,8` /
`ADD RSP,8` is the alignment pad: thunk entry RSP≡8 mod 16 (importer's
CALL pushed retaddr); after `PUSH RBP`(≡0) `PUSH R15`(≡8) the pad
restores ≡0 so `CALL RAX` is SysV-aligned. The thunk frame's standard
layout walks via the sniff's default branch (no special handling needed
for the thunk frame ITSELF).

**(b) Global thunk-arena range registry** (`eh_registry`):
`registerThunkArena(start,len)` / `unregisterThunkArena(start)` /
`isThunkAddr(addr)`. Each instance registers its `thunk_arena` range at
JIT finalize (`setup.zig`). The thunk belongs to the IMPORTER, so a global
(cross-instance) set — not the throwing instance's view — is required.

**(c) Global sniff resolution** — the x86_64 layout-disambiguation must
ask "is this a valid code address ANYWHERE (any instance's CodeMap OR any
thunk range)", not "is it in the single throwing-instance CodeMap".
`eh_registry.isCodeAddr(abs_pc)` = `isThunkAddr OR (∃ registered instance
whose CodeMap contains it)`. `loadFrameSniffed` takes an `isCodeAddr`
predicate (threaded via the adapter `Context`); the production path wires
it to `eh_registry.isCodeAddr`, unit tests supply a synthetic predicate.
This fixes BOTH the callee→thunk transition (thunk addr now resolves) AND
any importer-instance intermediate frame (resolves via its own CodeMap
through the global set).

The handler dispatch (which instance's ExceptionTable) is unchanged —
still the per-frame `resolver`. Only the frame-WALK layout-disambiguation
moves from single-CodeMap to the global predicate.

## Alternatives considered

- **A. Thunk RBP frame-link only** (the original D-238 design note).
  Rejected: necessary but not sufficient — the callee frame still
  mis-walks because the thunk-return RIP resolves `.outside` the single
  throwing-instance CodeMap.
- **B. Empty sentinel CodeMap for thunk PCs.** Rejected: returns
  `.outside`, the wrong answer for layout disambiguation.
- **C. Add thunk ranges as synthetic CodeMap function entries.** Rejected:
  thunks aren't functions; pollutes the per-function CodeMap + forces
  per-instance rebuilds. A separate `isThunkAddr` set is cleaner.
- **D. Make arm64 do the same.** Unnecessary: arm64's pure-pointer
  `loadFrame` doesn't sniff, so it already walks thunk frames by pointer
  (the `4f73d9ee` `MOV X29,SP` suffices). (c) is x86_64-specific.

## Consequences

**Positive**: x86_64 cross-instance EH-on-JIT reaches the importer's catch
(both-backend parity per the ADR-0128 "100%" directive). The sniff becomes
correct for ALL cross-instance frames, not just thunks.

**Negative / risk**: changes the EH-unwind frame-walk hot path + the
bridge thunk (every x86_64 cross-module call). The non-EH cross-module
regression net is the default 3-host (D-225 fixtures on ubuntu); the EH
functional path is x86_64-JIT-only (`ZWASM_SPEC_ENGINE=jit`, EH dir) — NOT
Mac-testable. Mitigation: the WALK LOGIC is unit-tested on Mac via
synthetic cross-instance frame chains (callee→thunk→importer), mirroring
`unwind.zig:390` `TwoInstanceResolver`; green-at-every-commit; ubuntu
`ZWASM_SPEC_ENGINE=jit` is the final functional gate before close.

## Removal condition

Retires when D-238 closes: x86_64 `ZWASM_SPEC_ENGINE=jit` runs the EH
cross-module dir green (importer catches an exporter throw), the non-EH
D-225 set + arm64 EH stay green on the 3-host gate, and ADR-0114's
`cross_module_throw_propagation.wat` fixture is shipped covering both
arches. Status → `Closed (Implemented)` with the SHA.

## References

- D-238 (x86_64 EH-JIT parity — the (a)+(b)+(c) design record).
- ADR-0134 (cross-instance per-frame handler dispatch — the WALK side this extends).
- ADR-0066 (bridge thunk — the x86_64 thunk this widens).
- D-184 (`2026-05-16` x86_64 prologue-sniff — the layout-disambiguation this generalizes).
- `src/engine/codegen/x86_64/thunk.zig` (a) · `x86_64/frame_chain.zig:68` (c) ·
  `shared/eh_registry.zig` (b)+(c) · `shared/frame_chain_adapter.zig:53` (predicate threading) ·
  `shared/throw_trampoline.zig:132` (production wiring) · `engine/setup.zig:395` (registration).

## Revision history

- 2026-06-14 — Initial. Accepted as the implementation design for the
  D-238 campaign (investigation `eba26059`+`74fa9511` established (a)+(b)+(c)).
