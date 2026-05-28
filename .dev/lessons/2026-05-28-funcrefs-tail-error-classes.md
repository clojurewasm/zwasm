# Function-references tail: 10 ParseFailed modules — error class inventory

**Date**: 2026-05-28
**Cycle**: 10.R-funcrefs-tail bundle Cycle 1 (95) — pure probe
**Citing**: `<backfill>` (cycle 95 handover commit)

## What was tried

After bundle 10.R-valtype-widen partial-closed at cycle 94
(`2f127b96`), 10 function-references modules still surfaced as
`compile FAIL: ParseFailed` in the spec runner. Cycle 95 wired
temporary diagnostic prints into `Engine.compile` +
`frontendValidate` + `readMemargCheckAlign` to surface the actual
underlying errors, which the runner's catch-all `ParseFailed`
label obscured.

## What was learned

### "ParseFailed" is c_api-side `wasm_module_new` returning null

Every failing module fired `[engine.compile.diag] wasm_module_new
returned null`, NOT a parser error. `wasm_module_new` (in
`src/api/instance.zig:448`) calls `instantiate.frontendValidate`
which runs per-function validate. The actual rejection is at the
validator level, not the parser.

### Per-function validate error classes (br_on_null + ref_is_null + br_on_non_null + ref_as_non_null modules)

```
[frontendValidate.diag] func N (typeidx K) failed: BadBlockType        (×3)
[frontendValidate.diag] func N (typeidx K) failed: BadValType          (×1)
[frontendValidate.diag] func N (typeidx K) failed: StackTypeMismatch   (×4)
[frontendValidate.diag] func N (typeidx K) failed: StackUnderflow      (×1)
[frontendValidate.diag] func N (typeidx K) failed: NotImplemented      (×3)
[frontendValidate.diag] func N (typeidx K) failed: UndeclaredFuncRef   (×?)
```

### Per error class → likely cause

| Error | Likely cause | Fix locus |
|---|---|---|
| `BadBlockType` ✅ CLOSED cycle 100 (`2fa216b9`) | Block instr reads result type byte; `0x63`/`0x64` typed-ref prefixes decode as SLEB -29/-28 and hit the BadBlockType else arm | `readBlockType` (validator) + `readBlockArity` (lower) now delegate the trailing heap-type to `init_expr.readTypedRef` (made pub). **Gotcha**: that helper is index-free (serves init-expr contexts), so the validator must bound-check a concrete heap-type index against `module_types.len` itself — else ref.9/ref.10 (`(ref 1)` with only type 0) get wrongly accepted (D-188 marker). function-references ParseFailed 10 → 7 |
| `BadValType` | Some valtype-reading path beyond `init_expr.readValType` (which was patched in cycle 92). Candidate: `readMemargReftypeByte` in `validator.zig::opTableSet` etc. | Find non-patched reftype-byte sites; reuse `init_expr.readValType` for consistency |
| `StackTypeMismatch` | Validator type-stack interaction: nullability narrowing (cycle 93) pushes non-null but downstream `popExpect` is strict-eql against nullable. Same root cause as the cycle-93 carve-out (subtype-aware popExpect) | Add `popSubtype` helper that accepts `(ref ht)` where `(ref null ht)` is expected (Wasm 3.0 §3.3.4 subtype rules) |
| `StackUnderflow` | Probably downstream of a `StackTypeMismatch` that left stack in wrong state | Same as above |
| `NotImplemented` | Some opcode in body returns `error.NotImplemented` — likely a dispatch-table entry that's still stubbed at the per-op handler level | Find which op via more targeted probe; either wire interp or update validator dispatch |
| `UndeclaredFuncRef` | `ref.func $N` used in a body without `$N` being in module's declared-funcrefs set (globals init / element segs / exports kind=func) | Likely correct — these fixtures may genuinely test the declared-funcref rule, OR the spec test uses `ref.func` in a non-init-expr context that should be allowed (10.R subset of the rule) |

## Why we tried

Bundle 10.R-funcrefs-tail Cycle 1 retarget per bundle close
discipline — partial-close at cycle 94 named the "10 ParseFailed
modules" gap; cycle 95 was the diagnostic probe before picking
which cycle to spend on which error class.

## How to apply

Cycle 96+ work plan:
1. **Subtype-aware popExpect helper** addresses 4× StackTypeMismatch
   + 1× StackUnderflow = 5/12 fails. Highest yield. Likely 1 cycle.
2. **Block result type extension** for `BadBlockType` = 3/12 fails.
   Likely 1 cycle.
3. **BadValType non-patched site** = 1/12 fail. Investigate via
   per-call grep + extension. Likely 1 cycle.
4. **NotImplemented opcode identification** = 3/12 fails. Need
   smaller probe to identify which op; then either wire or push
   to bundle 10.R-funcrefs-tail Cycle N+. Likely 1-2 cycles.
5. **UndeclaredFuncRef** = ? — needs case-by-case judgment per
   spec text.

Order recommendation: pick (1) first (highest yield + addresses
the cycle-93 known carve-out).

## Related

- Bundle `10.R-valtype-widen` (closed partial 2026-05-28 cycle 94)
- ADR-0123 D2 + Consequences §5 Cycle 5 — narrowing carve-out
- D-186 (return_call_ref) — still gated; full discharge at
  bundle close
- D-195 (function-references corpus return fails 0/39 → 30+/39)
  — bundle exit-condition
