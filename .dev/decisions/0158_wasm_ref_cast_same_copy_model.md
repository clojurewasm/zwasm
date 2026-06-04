# 0158 — `wasm_ref_t` cast / same / copy model (C-API ref base)

- **Status**: Accepted
- **Date**: 2026-06-05
- **Author**: §16.2 C-API completion (D-269 chunk E3b), survey-grounded
- **Tags**: c-api, wasm-c-api, ref-model, D-253, D-269, ADR-0004
- **Relates**: D-253 (ref machinery remainder), D-269 (C-API completion), ADR-0156

## Context

The wasm-c-api `WASM_DECLARE_REF(name)` macro requires, for each of
func/global/table/memory/extern/instance/module/trap/foreign: `wasm_X_as_ref` /
`wasm_ref_as_X` (+`_const`), `wasm_X_same`, `wasm_X_copy` (host_info trio already
landed E1–E3a). ~44 fns remain unimplemented (link errors). zwasm's `wasm_ref_t`
(`Ref` in `handles.zig`) is a funcref/externref PAYLOAD holder (`ref: u64` +
`instance` + `func_view`), NOT a C++-style common base class — so the
upcast/downcast for non-reference objects is "degenerate" (D-253).

Survey findings (precedent + reference impls):
- **Existing zwasm precedent**: `wasm_func_as_ref` / `wasm_foreign_as_ref` use a
  **lazily-cached borrowed `ref_view: ?*Ref`** with payload `@intFromPtr(entity)`;
  `wasm_ref_as_func/_foreign` reverse via the payload (caller-guarantees-type, no
  runtime tag); `wasm_ref_copy` = fresh Ref duplicating the `u64` payload;
  `wasm_ref_same` = `u64` payload equality.
- **wasmtime** leaves `same` / `as_ref` / `ref_as` as `abort()` stubs (corner
  surface); `copy` = shallow clone of the wrapper struct (shares the inner engine
  ref). Confirms these are low-traffic, but zwasm must at least DEFINE them (no
  link error) and — per no_workaround — implement properly, not `@panic`-stub.
- **`wasm_instance_exports` returns FRESH handles each call** → two handles to the
  same export are distinct pointers. So `same` MUST compare entity identity
  `(instance, idx)`, not pointer identity.
- **Copy ownership trap**: standalone handles own sub-resources (Func.host,
  Global.cell, Table.tinst, Memory.minst) that a shallow clone would double-free
  on delete; instance-backed handles own only `(instance, idx)` (+ cached views).

## Decision

Extend the established foreign/func ref-view pattern uniformly:

1. **`wasm_X_as_ref` / `wasm_ref_as_X` (+const)**: a Ref produced by `as_ref` is an
   **object-identity ref** — `ref = @intFromPtr(handle)`, `instance = null`, cached
   as the handle's `ref_view` (borrowed; freed in the handle's `_delete`). Add a
   `ref_view: ?*Ref` field to the handle structs that lack it (global/table/memory/
   extern; instance/module/trap get one too or cache externally). `wasm_ref_as_X` =
   `@ptrFromInt(ref.ref)` → `*X` (caller-guarantees-type, exactly as
   `wasm_ref_as_foreign` already does). The `Ref` payload is **polymorphic** —
   funcref-encoding for `func`, object-pointer for the rest — interpreted by the
   `ref_as_X` the caller invokes. `_const` variants are `@constCast`-free typed
   aliases of the same body. This keeps `func`/`foreign` as-is (already shipped).
2. **`wasm_X_same`**: entity identity, not pointer identity. Instance-backed
   func/global/table/memory/extern → compare `(instance, idx)`; standalone (no
   instance) → pointer identity (the handle IS the entity); module/instance/trap →
   pointer identity; foreign → pointer; ref → existing `u64` payload eq. Two nulls
   are same; one null is not.
3. **`wasm_X_copy`**: instance-backed → a fresh handle alloc copying `(instance,
   idx)` + cached-view fields nulled (the copy gets its own lazy views; no shared
   ownership → no double-free). Standalone handles that own sub-resources
   (Func.host / Global.cell / Table.tinst / Memory.minst) → **return null +
   D-253-D note** (full ownership-transfer copy needs a per-store foreign-entity
   registry; deferred, not papered over — the limitation is explicit + tested).
   trap/foreign/ref copy = existing/payload-dup semantics.
4. **of.ref divergence (D-269)**: unchanged — `wasm_val_t.of.ref` stays a raw
   payload; the object-identity-ref model above is consistent with it (a Ref from
   `X_as_ref` is a handle wrapper, distinct from a Wasm-value ref).

## Anti-regression invariants

- `wasm_ref_as_X(wasm_X_as_ref(x))` round-trips to the same entity (test per type).
- A handle and its `as_ref` view never double-free (borrowed-view discipline).
- `copy` of an instance-backed handle is independently deletable (no double-free);
  `copy` of a standalone owner returns null (asserted) until D-253-D.

## Implementation plan (sub-chunks, TDD)

- **E3b-1** `wasm_X_same` (9) — entity-identity, self-contained, no new fields.
- **E3b-2** `wasm_X_as_ref` / `wasm_ref_as_X` (+const) — add `ref_view` fields +
  cast bodies; per-type round-trip tests.
- **E3b-3** `wasm_X_copy` (9) — instance-backed clone / standalone-null; tests.
- `wasm_foreign_copy/_same/_as_ref_const` fold into the above.

## Consequences

Closes the bulk of D-253 + the §16.2 ref-cast gap. Standalone-owner `copy`
remains a documented limitation (D-253-D registry). Revises the "degenerate in
zwasm's model" framing: the polymorphic-payload + caller-guarantees-type model IS
the chosen design, not a gap.
