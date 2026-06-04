# Function-references tail: 10 ParseFailed modules — error class inventory

**Date**: 2026-05-28
**Cycle**: 10.R-funcrefs-tail bundle Cycle 1 (95) — pure probe
**Citing**: `7fbb833c` (cycle 95 handover commit)

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

## Cycle 101 re-probe (post-Gate-4) — error map refresh

Re-ran the per-func `frontendValidate` error probe after Gate 4
cleared 3 modules (ParseFailed 10→7). The cycle-99 "Gate 3 =
opRefFunc non-null" framing was WRONG; actual classes for the 7:

- `ref_as_non_null.0/2` → **NotImplemented** — root cause: dispatch
  typo `0xD3 => opRefAsNonNull` in BOTH `validator.zig` + `lower.zig`.
  `ref.as_non_null` is **0xD4** (`0xD3` = GC ref.eq). Fixed cycle 101
  (`7db8aed0`); `ref_as_non_null.2` parses (7→6). `ref_as_non_null.0`
  still fails (separate later-function gate; uses `ref.func N`+`call`
  with typed refs).
- `br_on_null.0/2`, `br_on_non_null.0/2` → **StackTypeMismatch**
  (func type_idx=0) — concrete typed-ref `(ref 0)` flowing through
  `block`/`br_on_null`/`call_ref`. cycle-102 target. Error class
  known; failing OP needs a position-level probe.

  **Cycle 102 result**: the `br_on_*` MECHANICS were fine — the
  StackTypeMismatch was at the type-0 ENTRY funcs (`func 4/5`:
  `ref.func N; call M`), not the br_on funcs (type 1/2). Root cause:
  `opRefFunc` pushed abstract `funcref`, but `call M` expected the
  typed `(ref $sig)` param. Fix: opRefFunc pushes `(ref
  func_type_indices[N])` (ADR-0123 D4) + `valTypeIsSubtypeFree` gains
  `(ref $sig) <: func` so typed refs still satisfy funcref contexts
  (else `ref_func.1`'s funcref `global.set`/`table.set` regress).
  Threading: `func_type_indices` added to the Validator +
  `validateFunctionWithMemIdxAndTags` + `frontendValidate`. Result:
  ParseFailed 6→3, **return pass 0→7** (`7b9218c2`). Lesson: an error
  CLASS at "func type_idx=N" names the function's TYPE index, not its
  position — trace which funcs carry that type before blaming the
  proposal-op the module is named after.
- `ref_is_null.0` → fails BEFORE the per-func loop (no fv.diag) —
  earlier frontendValidate stage; uses `(table (ref null 0))` +
  `(elem (table 2) (ref 0) (ref.func 0))`.

**Probe technique** (reusable): the c_api `wasm_module_new` →
`frontendValidate` returns bool, masking the real error as
`ParseFailed`. Temporarily wrap the per-func validate call
(`instantiate.zig` ~line 322) with a `catch |e| print(@errorName(e))`
to surface the class; revert before commit. "No fv.diag before the
runner's compile-FAIL line" = failure is in an earlier stage
(parse / preDecodeSectionBodies / section decode), not a func body.

**Interleaving trap (cycle 105, cost ~2 cycles of wrong attribution)**:
`grep -B1 "<module> compile FAIL"` for the preceding fv.diag is
UNRELIABLE in the spec runner — many modules fail and their stderr
diags interleave, so the adjacent fv.diag may be a DIFFERENT module's
(cycle-104's "ref_is_null.0 func#0 BadValType" was actually a single-
func GC module's `select (result (ref 1))` diag). **Isolate**: add a
temp test that compiles the ONE module in the core/manifest test
binary (it `@embedFile`s fixtures; runs sequentially, no cross-module
interleave) with `[MARKER-START]`/`[MARKER-END]` around the compile —
grep between markers. Then stage-tag `frontendValidate`'s return-false
points (parse / preDecode.<section> / per-func) to localize. ref_is_
null.0 actually failed at **preDecode.element decode** —
`readFuncrefInitExpr` rejected `ref.func` for a concrete `(ref 0)`
segment (`isFuncref()` only matches abstract nullable funcref).
`@embedFile` can't reach outside the src/ package, so the isolation
test goes in `test/spec/`, not `src/`.

## Cycle 106 — return-phase breakdown (engine vs harness)

After ParseFailed→0 (cycle 105), function-references is 24/39 return
pass. Categorizing the 15 return fails (gated runner probe at the
assert_return fail paths) showed the remaining gap is **predominantly
test-harness, not engine**:

- **8 fails = ref_func.1** — `(import "M" "f")` → UnknownImport because
  the manifest carries `skip-impl directive-register`: the corpus baker
  drops the `register` directive, so ref_func.0 is never registered as
  "M". This is **D-192 (cross-module register substrate)** — the SAME
  gap EH try_table.1 hits (imports try_table.0's tag/func). Implement
  the `register` directive (bake it + wire runner `register <name>` →
  `Linker.define*`) to unblock both corpora.
- **~7 scattered** — externref-value arg/result handling in the runner
  (e.g. `init (param externref)` invoke is skipped when the runner
  can't parse an externref arg, leaving a table uninitialized →
  downstream `externref-elem` MISMATCH) + others.

Lesson: when a spec corpus's *parse* is complete but *return* lags,
categorize before assuming engine bugs — the gap was harness substrate
(register directive + ref-value marshalling), and the highest-leverage
fix (D-192 register) is SHARED across proposals. Re-scoped bundle
10.R-funcrefs-exec → 10.X-D192-register accordingly.

## Related

- Bundle `10.R-valtype-widen` (closed partial 2026-05-28 cycle 94)
- ADR-0123 D2 + Consequences §5 Cycle 5 — narrowing carve-out
- D-186 (return_call_ref) — still gated; full discharge at
  bundle close
- D-195 (function-references corpus return fails 0/39 → 30+/39)
  — bundle exit-condition
