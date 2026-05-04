# Skip — `externref-segment.0.wasm` (externref element segment)

- **Status**: Accepted (skip until externref reftype lands)
- **Date**: 2026-05-04
- **Author**: zwasm v2 / continue loop
- **Tags**: phase-6, skip-adr, misc-runtime, externref, reftypes
- **Fixtures covered**: 1

## Fixture

- `test/wasmtime_misc/wast/reftypes/externref-segment/externref-segment.0.wasm`

The fixture declares an `externref` table + an `(elem ... externref)`
segment with `ref.null extern` initializers, then exports a getter
that observes `is_null(ref)` for both segment-initialised slots
and post-`table.fill` slots.

## What v2 does today

`zig build test-wasmtime-misc-runtime` reports the fixture as
`InstanceAllocFailed` because the validator/lowerer pipeline does
not yet accept `externref` as a `RefType`. zwasm's element-segment
work landed in 6.K.4 was scoped to `funcref` only.

## Why v2 declines

Per **ADR-0014 §2.1 / 6.K.4 (Element-section forms 5 / 6 / 7)**
the funcref-only scope was an explicit decision: each non-funcref
reftype (`externref` and forthcoming GC-proposal reftypes) lands
as its own ROADMAP row, not as part of a single "wasm 2.0 reftypes"
sweep. Stretching 6.K.4 to externref would have leaked into
`Value.ref`'s storage layout (host-pointer slot + tag bit) and
into the global / table import paths the same row touches — an
unnecessary scope expansion for a row that already covered three
distinct element forms.

## What v2 needs to fix this honestly

A new ROADMAP row (likely `§9.<N> / E.X — externref reftype + host
ref API`) implementing:

1. `Value.ref_extern` storage encoding (host *anyopaque* pointer
   slot, distinct from `*FuncEntity`, with one tag bit).
2. Validator: accept `externref` as a `RefType`; type-check
   `ref.null extern`, `ref.is_null`, `ref.func` -> externref
   coercion is not allowed.
3. Lowerer: ZIR ops for `externref` table init / fill / get / set.
4. Runtime: `TableInstance` accepts mixed reftype; `table.fill`
   on externref tables.
5. C-ABI: extend `wasm_ref_t` host opaque ref handle alongside
   `wasm_funcref_t`.

This is on the Phase 6/7 spec-conformance backlog, not 6.K's
ownership-model scope.

## Removal plan

When the externref reftype row lands and externref-segment.0.wasm
passes end-to-end, remove this skip-ADR's fixture from the
deferred-skip list. The ADR itself stays as historical record.

## Removal condition (machine-checkable)

> `externref-segment.0.wasm` reports PASS in
> `zig build test-wasmtime-misc-runtime`.

## References

- ADR-0014 §2.1 / 6.K.4 (funcref-only scope for element forms
  5 / 6 / 7)
- ADR-0014 §2.1 / 6.J (strict-100%-PASS close criterion +
  per-fixture skip-ADR escape clause)
- Wasm 2.0 §3.2.6 (reftype + valtype matching rules)
- `~/Documents/OSS/wasmtime/tests/misc_testsuite/externref-segment.wast`
  — original .wast source
