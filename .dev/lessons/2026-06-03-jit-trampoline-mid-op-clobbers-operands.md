# JIT: a trampoline call inserted mid-op clobbers that op's operands

**Date**: 2026-06-03 · **Context**: D-235 (JIT `call_indirect` subtype acceptance)

## Observation

The D-235 prep proposed "on the sig CMP mismatch, CALL a subtype trampoline
before trapping" — inserting a C-ABI call into the *middle* of the
`call_indirect` emit. That design is broken: the regalloc does NOT model the
inserted call, so it freely places the op's own operands (the call args + the
table index) in caller-saved registers — they die at the op, and only the
*actual* `BLR`/`CALL` is modeled as a clobber point. A trampoline `BLR` emitted
before that point destroys the marshalled args (or the operand vregs marshal is
about to read).

## What works

1. **Run the trampoline BEFORE any marshalling** — then its caller-saved clobber
   has nothing to corrupt (args not yet in arg regs). Only the pinned
   callee-saved cohort (X19/X24-X28, R15) must survive, and the C ABI preserves
   callee-saved by construction.
2. **Force-spill the op's operands** so they survive the trampoline. The
   ADR-0060 force-spill already does this for any vreg *strictly crossing* a
   call; an op that reads operands *after* an internal call needs the
   **inclusive** crossing (like `struct.new`). Gated per-module via
   `ZirFunc.uses_type_subtyping` so non-subtyping `call_indirect` stays
   byte-identical (strict crossing).
3. Have the trampoline **return the funcptr** (resolve, not just check) so no
   per-arch reload dance is needed: arm64 stashes it in reserved X17 (survives
   marshal — marshal never touches X16/X17); x86_64's regalloc pool is
   *all-callee-saved* so the operand idx survives → re-derive funcptr inline.

The general rule: you cannot splice a call into an op's body unless the op's
live operands are in callee-saved/spill. Either reorder before marshalling +
force-spill, or model the helper as a real IR op (regalloc-modeled clobber).

## Measurement gotcha (cost me a false-regression scare)

`zig build test-spec-wasm-3.0-assert -Dno-run` is NOT a real flag — the build
**fails** and reuses a STALE exe (half-applied changes), which reported a bogus
`538/22/735` "regression". Always do a real `zig build test-spec-wasm-3.0-assert`
(it builds + runs), grab the freshest exe (`find … | ls -t | head -1`), and
diff JIT corpus metrics against a truly-rebuilt baseline before believing them.

**Second mechanism (2026-06-03, 10.E Cause A):** even when the build SUCCEEDS, a
bare `find .zig-cache/o -name zwasm-spec-wasm-3-0-assert | head -1` returns the
FIRST match by find/dir order — NOT the newest. `.zig-cache/o` accumulates dozens
of old spec-runner binaries across sessions, so `head -1` silently ran a stale exe
and the EH-dir delta read as `0` (pass=0 fail=1 skip=33) until a stash-baseline
showed byte-identical exe hashes. Fix: ALWAYS sort by mtime —
`find … -type f -exec ls -t {} + | head -1`. The "byte-identical exe hash across a
real source change" is the tell that you're holding a stale binary.

Related: [[2026-06-02-gti-tied-to-heap-need-misses-func-subtyping]] (the interp
half; D-235 fixed the same gti gap in the JIT `setup.zig`).
