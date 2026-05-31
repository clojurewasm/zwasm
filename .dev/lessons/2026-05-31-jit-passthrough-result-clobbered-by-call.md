# JIT passthrough-result must be captured AFTER the CALL, not before

**Date**: 2026-05-31
**Citing**: 10.G R-3 `ref.cast_null` (this commit)
**Tags**: jit, gc-on-jit, regalloc, spill, ref.cast, calling-convention

## The surprise

`ref.cast_null`'s result is the **operand unchanged** (null passes; a
non-null match returns the same ref). The first emit set the result reg
to the operand BEFORE the trap-check CALL, then `gprStoreSpilled`d it:

```zig
const rd = gprDefSpilled(result);
if (rd != xsrc) MOV rd, xsrc;   // result = operand
gprStoreSpilled(result);        // <-- intended to persist before the CALL
... CALL jitGcRefTest ...        // trap decision
```

It passed the mismatch-trap test but FAILED the match/null tests
(wrong result value). Cause: `gprDefSpilled` returns the result vreg's
**home register** when it is register-allocated, and `gprStoreSpilled`
is then a **no-op** (the result "lives" in `rd`, not a spill slot). The
CALL clobbers `rd` (caller-saved) → the result is garbage. The
force-spill (ADR-0060) spills vregs *crossing* the call, but the result
is defined by THIS op, so it can land in a caller-saved reg.

## The rule

For a JIT op whose result is a **passthrough of an operand** (or any
value computed BEFORE a CALL the op also emits), do NOT materialise the
result before the CALL. Either:

1. **Capture it from the return reg AFTER the CALL** (W0/EAX) — the
   straight-line pattern `ref.test`/`ref.cast` use; the trampoline
   returns the value, OR
2. **Put the pre-CALL value on a no-CALL path** behind an inline branch
   (what `ref.cast_null` does: `CBZ`/`JZ` skips the CALL for null, so
   `rd = operand` set before the branch survives; the non-null path
   re-captures `rd` from the return reg post-CALL).

Storing "before the CALL to survive the clobber" only works if the
result is GUARANTEED spilled — and a this-op-defined result is not.

## Applies next to

`br_on_cast` / `br_on_cast_fail` (cast + passthrough + branch),
`ref.as_non_null`, `extern.convert_any` / `any.convert_extern` — any
op that returns an operand-derived value alongside a trampoline CALL.

## Related

- `src/engine/codegen/arm64/gpr.zig` `gprDefSpilled` / `gprStoreSpilled`
  (the reg-vs-spill home semantics).
- ADR-0060 (force-spill across is_call).
- `.claude/rules/abi_callee_saved_pinning.md` (the broader
  caller/callee-saved discipline).
