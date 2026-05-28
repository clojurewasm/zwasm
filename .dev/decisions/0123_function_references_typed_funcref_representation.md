# ADR-0123 — function-references (10.R): typed-funcref representation + call_ref sig-dispatch

- **Status**: Proposed (loop-drafted; awaiting user flip → Accepted)
- **Date**: 2026-05-28
- **Tags**: wasm-3.0, function-references, valtype, call_ref, zir, phase10
- **Deciders**: autonomous /continue loop (drafts); user (Accept flip)

## Context

ROADMAP §10 row 10.R implements the Wasm 3.0 function-references
proposal: `ref.as_non_null` / `br_on_null` / `br_on_non_null` /
`call_ref` / `return_call_ref` + `(ref $sig)` / `(ref null $sig)`
typed function references.

Current state (Step-0 survey, 10.R cycle 48):

- All 5 ops have `ZirOp` tags (`src/ir/zir_ops.zig:514-520`).
- `ref.as_non_null` / `br_on_null` / `br_on_non_null` are **parsed +
  validated + interpreted** with the *generic* `funcref` reftype
  (`src/validate/validator.zig:1675-1756`); JIT-stubbed.
- `call_ref` / `return_call_ref` are **parsed only**; validate / lower
  / interp return `error.NotMigrated`
  (`src/instruction/wasm_3_0/call_ref.zig`). `return_call_ref` has
  arm64+x86_64 emit skeletons returning `UnsupportedOp`.
- `ValType` (`src/ir/zir.zig:21-54`) is `enum(u8)` — no `(ref $sig)`
  variant, and a bare enum tag cannot carry the sig **index**.
- `validator.zig:1672-1674` already records the intent: "nullability
  narrowing lands at 10.G (WasmGC) where `(ref $sig)` typed refs need
  their own typed-ref module."

No existing ADR decides the typed-funcref **representation**.
ADR-0116 §95-97 names `(ref $func_type)` in the conceptual type
hierarchy but **explicitly scopes typed-funcref impl out** (§229:
"by typed-funcref work; cycle 20+ outside scope"). ADR-0112 leaves
`return_call_ref` green-field. Implementing 10.R therefore needs a
load-bearing §4 decision recorded **first** (ROADMAP §18.2 /
deviation-watch).

## Decision

**D1 — No new `ValType` variant for `(ref $sig)` in Phase 10.R.**
The static type stack keeps the generic `funcref` reftype. The sig
**type-index** for `call_ref` / `return_call_ref` rides in
`ZirInstr.payload` (`u64`), exactly as `call_indirect` already carries
its expected type-index (`src/interp/trap_audit.zig:73-103`). This
avoids a disruptive `enum(u8)` → tagged-union `ValType` rewrite
mid-Phase-10 and reuses the proven indirect-call substrate.

**D2 — Static nullability narrowing defers to 10.G.** In 10.R,
`ref.as_non_null` / `br_on_null` / `br_on_non_null` operate at
**runtime** on the generic ref representation (`Value.ref: u64`,
null = 0). The validator stays non-narrowing (as today): it pops/pushes
the generic reftype without expressing `(ref null T)` → `(ref T)`. The
full static typed-ref module (with nullability in the type lattice)
lands in 10.G alongside the GC type hierarchy, per ADR-0116's existing
scoping. This is sound because the spec's *dynamic* semantics (trap on
null) are fully captured at runtime; the static narrowing is an
additional validation-strictness layer, not a runtime-behavior gate.

**D3 — `call_ref` runtime sig-dispatch mirrors `call_indirect`.**
`call_ref` pops a funcref; traps `NullReference` on null; then checks
the callee's actual signature against the static type-index
(`ZirInstr.payload`), trapping `IndirectCallTypeMismatch` on mismatch
(reusing the existing indirect-call sig-check). No table indirection —
the funcref is called directly.

**D4 — `return_call_ref` = `call_ref` + frame teardown.** Reuses the
ADR-0112 tail-call frame_teardown path (already landed for
`return_call` / `return_call_indirect`, HEAD `ae2abab7`) plus D3's
null+sig checks. This discharges debt D-186's representation blocker
(D-186 stays blocked on 10.R-3/4 landing, which this ADR unblocks).

## Alternatives

- **A1 — Extend `ValType` to a tagged union carrying a heap-type
  index** (`(ref null? $idx)`). Rejected for 10.R: `ValType` is a
  pervasive `enum(u8)` consumed across parse/validate/lower/interp/emit
  + the GC variants; widening it to carry an index is a Phase-wide
  structural change that ADR-0116 already deferred to the GC typed-ref
  module. Doing it now would couple 10.R to a 10.G-scope refactor.
- **A2 — Full static nullability narrowing in 10.R** (express
  `(ref T)` vs `(ref null T)` in the validator type lattice). Rejected:
  same coupling as A1; the runtime trap semantics (D2/D3) already give
  spec-correct *behavior*; the extra static strictness is a 10.G
  concern. Spec assert_invalid cases needing narrowing stay as
  validator-strictness debt (parallels D-188's EH validator strictness).
- **A3 — call_ref via a synthetic single-entry table** (reuse
  call_indirect machinery literally). Rejected: adds a fake table +
  bounds check the spec doesn't mandate; D3's direct funcref call is
  simpler and matches wasmtime/wasm-tools.

## Consequences

- 10.R becomes implementable without a §4 `ValType` overhaul: the
  remaining work is emit handlers (null-check ops) + `call_ref`
  validate/interp/emit reusing indirect-call sig-dispatch.
- `ref.as_non_null` / `br_on_null` / `br_on_non_null` JIT emit is
  **representation-independent** (generic-ref null-check) → can proceed
  immediately, even before this ADR's Accept flip.
- A known, bounded gap: assert_invalid spec cases that require static
  nullability narrowing will not pass until 10.G. Tracked as
  validator-strictness debt (file a D-row when the gc/function-ref
  corpus surfaces them), NOT as a runtime-correctness gap.
- When 10.G lands the typed-ref module, the `ZirInstr.payload` sig-index
  carried here remains valid; 10.G adds the static lattice on top
  without reworking the runtime path.

## References

- ROADMAP §10 row 10.R; §18.2 (deviation → ADR-first).
- ADR-0112 (tail-call; return_call_ref frame teardown, green-field note).
- ADR-0116 §95-97 (type hierarchy naming `(ref $func_type)`), §229
  (typed-funcref impl explicitly out of GC-cycle scope).
- `src/ir/zir.zig:21-54` (ValType enum), `:104-107` (ZirInstr
  payload/extra).
- `src/instruction/wasm_3_0/call_ref.zig` (current stub),
  `src/validate/validator.zig:1672-1756` (non-narrowing ref ops).
- `src/interp/trap_audit.zig:73-103` (call_indirect sig-dispatch
  pattern reused by D3).
- Debt D-186 (return_call_ref blocked-by 10.R; unblocked by D4).

## Revision history

- 2026-05-28 — Proposed (10.R cycle 48, Step-0 survey outcome).
