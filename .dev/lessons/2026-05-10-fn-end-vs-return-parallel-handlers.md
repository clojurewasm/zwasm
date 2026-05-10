# Function-level `end` vs `return` op are parallel emit paths

> Lesson surfaced 2026-05-10 in §9.9 / 9.9-d-4 spike.
> Citing: commit `3aaed99f`.

## Observation

When 9.9-b (ADR-0046, ARM64 v128 return marshal) extended the
emit pass with a `.v128` arm, only the `.return` op handler at
`src/engine/codegen/arm64/emit.zig:962` got the new arm. The
function-level `.end` handler at line 1086 — which marshals
the same set of result kinds via a parallel code path —
silently kept `.v128` in the `is_fp = false` GPR-route bucket.

Symptom: `(result v128)` functions returned via `MOV X0, Xn`
(GPR convention) instead of `MOV V0.16B, Vn.16B` (AAPCS64 +
ADR-0046 vector convention). V0 was never written by the JIT
body, so the caller read whatever was there before the call —
in our test environment, often slice-header bytes from
`compiled.module.func_offsets`.

The 60-PASS bias on simd_const (`() → v128` fixtures) made the
bug invisible: pre-call V0 happened to coincide with the spec's
expected constant often enough to look like correctness. Only
the `(i32) → v128` shape (simd_address) gave a controlled
post-call V0 read that exposed the gap.

## Why this is re-derivable but worth remembering

Both `.return` and the function-level `end` perform exactly
the same logical step (move the operand stack's top vreg to
the AAPCS64 return register per result_kind). They differ
only in whether they emit a B-fixup (`.return` exits early
through a fixup that joins the single epilogue) or fall
through to the epilogue (`.end`). The marshal logic itself is
duplicated.

A `bug_fix_survey.md` grep at 9.9-b time for "result_kind"
would have surfaced both call sites. The cycle that landed
9.9-b touched only one.

## Forbidden phrasings the rule rejects

- "`.return` and `.end` differ enough that one fix doesn't
  apply to the other" — false; the marshal is identical, only
  the post-marshal control flow differs.
- "the v128 case can wait until the function-level path is
  exercised" — exactly the failure mode; an unexercised path
  silently corrupts return values.

## Future-self checklist

When extending `arm64/emit.zig` (or its x86_64 sibling) with a
new result-type arm, grep for **every** site that switches on
`func.sig.results[0]` / `result_kind`. As of 2026-05-10 the
arm64 pass has at least two such sites:

1. `.return` op handler — sub-7.5b-ii epoch.
2. Function-level `.end` handler (when `labels.items.len == 0`).

Both must be updated together. The same shape exists in
`x86_64/emit.zig` (chunks 7.7-fp / 9.9-b cousin).
