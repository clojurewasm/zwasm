---
ADR: 0124
Title: WasmGC structural subtype validation lattice
Status: Accepted
Date: 2026-05-29
Related: ADR-0115 (GC heap), ADR-0116 (GC roots + RTT + i31), ADR-0121 (struct/array typedef parse + RTT layout), ADR-0123 (typed-ref ValType)
---

## Context

The 10.G-wasmgc bundle's largest corpus family is `type-subtyping`
(44 of 88 gc modules). These declare `sub` / `sub final` typedefs
(binary `0x4F` / `0x50`, NOT `0x4E rec` — cycle-122 verified the actual
bytes) whose comptype must structurally conform to a declared supertype.

Cycle 122 proved a **parse-vs-validate coupling**: adding the `0x50`/
`0x4F` subtype parse ALONE regressed `gc invalid` pass 55→40. The
type-subtyping fixtures are largely `assert_invalid` (BAD subtyping
declarations) that previously "passed" by accidentally `ParseFailed`-ing
on the unknown `0x50` byte. Once parsed, with no subtype check, they
validate and are wrongly ACCEPTED. So the parse and the subtype-
conformance check MUST land together, and the conformance rules touch
the validator's type model (§4-adjacent) — hence this ADR.

The conformance rules are spec-defined (Wasm 3.0 GC §4.2.8 / §4.3.4),
so this ADR records HOW we implement them (and rejects the
under-validating alternatives), not a free design choice.

## Decision

Implement Wasm 3.0 GC structural subtyping in the validator, checked
at **two** sites:

1. **Type-section validation** (this bundle's coupled chunk): for every
   typedef that declares supertype(s) S via `0x4F`/`0x50`, verify its
   comptype is a structural subtype of each S's comptype; reject
   (`Error`) otherwise. Wired alongside the `0x50`/`0x4F` parse (the
   `Types.supertypes` side-table) so parse + validate land atomically.
2. **`ref.cast` / `ref.test` / `br_on_cast` narrowing** (later, GC
   Chunk 5): the same predicate gates the cast/test result type.

### The lattice + structural rules

**Abstract heap-type lattice** (top = `any`):
```
any  ←  eq  ←  { i31, struct, array }
any  ←  func ←  nofunc
any  ←  extern ← noextern
any  ←  exn  ←  noexn
none <: every internal (struct/array/i31/eq/any) type
```
(`func`/`extern`/`exn` are disjoint top-level hierarchies; a struct is
NOT a subtype of func, etc.)

**Comptype structural rules** — `comptype A <: comptype B` requires A
and B the SAME kind, and:
- **struct <: struct**: A has ≥ B's field count (width); for each of
  B's fields, A's field at that index conforms (depth) — a `var`
  (mutable) field is INVARIANT (types equal), a `const` (immutable)
  field is COVARIANT (A.fieldtype <: B.fieldtype).
- **array <: array**: element conforms — `var` invariant, `const`
  covariant (same rule as a struct field).
- **func <: func**: same param/result arity; params CONTRAVARIANT
  (B.param[i] <: A.param[i]), results COVARIANT (A.result[i] <:
  B.result[i]).

**ValType subtyping** (for field / element / param types) extends the
existing `valTypeIsSubtypeFree` with the lattice above; a concrete
`(ref $a)` <: `(ref $b)` recurses into the declared supertype chain
(`a == b` OR `b` reachable via `a`'s supertypes). Nullability:
`(ref null T)` is a supertype of `(ref T)`.

### Implementation shape

- `Types.supertypes: [][]const u32` (parse-side, cycle-122 diff).
- A `typeDefIsSubtype(sub_idx, super_idx, types)` helper in the
  validator (or a `feature/gc/` subtype module imported by it),
  consulted at type-section validation + later by ref.cast/test.
- The supertype CHAIN (transitive, for `(ref $a) <: (ref $b)` where b
  is a transitive supertype) reads `Types.supertypes`; the RTT display
  materialisation at instantiate (ADR-0116) is a separate later step.

## Alternatives

- **No subtype validation** (parse-only) — REJECTED: regresses `gc
  invalid` 55→40 (cycle 122); violates the spec + the A10 skip-0 gate.
- **Pointer/nominal identity only** — REJECTED: Wasm GC is STRUCTURAL
  (a structurally-conformant struct IS a subtype regardless of identity);
  nominal-only would reject valid `assert_return` fixtures.
- **Accept all newly-parsed subtypes** — REJECTED: same invalid
  regression; defeats `assert_invalid` fixtures.

## Consequences

- GC type-subtyping modules validate per spec: bad declarations reject
  (`gc invalid` returns to ≥55, target 60), good ones parse+validate.
- The `0x50`/`0x4F` parse + `typeDefIsSubtype` land as ONE coupled
  chunk (no parse-only intermediate — cycle 122's lesson).
- `ref.cast`/`ref.test`/`br_on_cast` RTT narrowing (GC Chunk 5) reuse
  `typeDefIsSubtype`, so the lattice is built once.
- Recursion depth is bounded by the supertype chain length (corpus
  chains are shallow); a visited-set guards against malformed cycles.

## References

- Wasm 3.0 GC §4.2.8 (subtyping) / §4.3.4 (defined-type subtyping).
- `.dev/lessons/2026-05-29-wasmgc-corpus-scope.md` (corpus survey +
  the cycle-122 parse-validate coupling finding).
- ADR-0121 (typedef parse + the deferred-RTT discipline this builds on).
- `src/validate/validator.zig` `valTypeIsSubtypeFree` (extended here);
  `src/parse/sections.zig` `Types.supertypes` (parse-side feed).
