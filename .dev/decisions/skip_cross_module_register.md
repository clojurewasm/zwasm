# Skip — wast `(register "alias" $M)` directives

- **Status**: Superseded (2026-05-17 by Phase 9 §9.9-III chunk (c)-1c, per ADR-0065 Cat III absorption). The runner now parses `(register "M" $inst)` directives via the `DirectiveKind.register` arm in `test/spec/spec_assert_runner_base.zig::runCorpus`; populated entries land in `runCorpus.registered` (a session-local `StringHashMapUnmanaged([]u8)`) for the (c)-2 cross-module import linker to consume. The distiller's prior `skip-adr-skip_cross_module_register` emit was replaced by direct `register <alias>` emit at the same chunk. Kept in place as historical record; 0 manifest references remain.
- **Date**: 2026-05-16 (Superseded 2026-05-17)
- **Author**: zwasm v2 / continue loop (§9.9 / 9.9-l-1b-d093-d59, superseded at §9.9-III chunk (c)-1c)
- **Tags**: phase-9, skip-adr-superseded, spec-conformance, cross-module, register
- **Manifests covered**: 0 (was 21 across `elem`, `imports`, `linking`, `memory_grow`, `ref_func`, `table_copy`, `table_grow`, `table_init` — all flipped to `register <alias>` lines at chunk (c)-1c)

## Directive

The wast `(register "alias" $M)` directive binds the named (or
current) module under a host-import key. Subsequent modules in the
same `.wast` file can then `(invoke $alias "fn" ...)` or
`(import "alias" "fn" ...)` to call into the previously-registered
module's exports — i.e. it is the wast harness's mechanism for
constructing cross-module compositions.

## What v2 does today

The `spec_assert_runner_non_simd` harness:

1. Filters every `(invoke $module "fn" ...)` / `(assert_return
   (invoke $module ...))` / `(assert_trap (invoke $module ...))`
   directive at distillation time via
   `skip-adr-cross-module-action` (regen_spec_2_0_assert.sh's
   `assert_return` / `assert_trap` / `action` arms).
2. Filters every module with non-`spectest` imports at runtime via
   `hasUnbindableImports` (introduced by §9.9 / 9.9-l-1b-d093-d37,
   commit `23724d68`).

Together, no assertion downstream of a `(register ...)` directive
actually exercises the registered binding. The directive is
structurally a no-op in our scaffold.

## Why v2 declines

Cross-module composition (the union of mutable module instances,
the wast registry of "alias → instance", and the runtime's
import-resolution path for `(import "$alias" ...)` against a
peer module's export table) is the Track-D / Phase-10+ scope per
ADR-0029 + ADR-0050 + D-079. Implementing `register` honestly
requires:

1. An instance-aware spec harness — a `register` invocation must
   persist the produced module instance and re-bind it as an
   import provider for subsequent module instantiations in the
   same `.wast`.
2. Cross-module import resolution end-to-end — the running
   `hasUnbindableImports` filter currently rejects non-spectest
   function imports + all table / memory / global imports
   wholesale; that's the surface that would have to bend.
3. Per-module storage descriptors for typed memory / table /
   global imports that point at a peer module's storage rather
   than the harness's static-scratch globals.

That work is tracked as the broader Phase 10+ cross-module
imports + instance-aware refactor (D-079 + D-105 + D-126).

## What v2 needs to fix this honestly

The cross-module imports + instance-aware refactor row in Phase
10+. When that lands, the natural sequence is:

1. Replace `hasUnbindableImports` with a per-import resolver that
   consults a per-`.wast` instance registry.
2. Wire the distiller's `assert_return` / `assert_trap` / `action`
   arms to emit real cross-module dispatch directives instead of
   the current `skip-adr-cross-module-action` family.
3. Wire the distiller's `register` arm to emit a `register {as}
   {wasm_file}` directive (or attach to the most-recent module
   command) so the harness can populate its instance registry.
4. Retire this skip-ADR alongside `skip-adr-cross-module-action`
   and the associated debt rows (D-079 + D-082 + D-105 + D-126).

## Removal plan

When Phase 10+'s cross-module imports row lands and one of the 21
currently-skipped `register` directives in
`test/spec/wasm-2.0-assert/{elem,imports,linking,memory_grow,
ref_func,table_copy,table_grow,table_init}/manifest.txt` reaches
a state where the registered binding is needed by a downstream
assertion that is no longer SKIP'd via
`skip-adr-cross-module-action`, retire this skip-ADR and emit a
real `register` directive instead. The ADR itself stays as
historical record per ADR-0029 Path B conventions.

## Removal condition (machine-checkable)

> Every `skip-adr-skip_cross_module_register` line in
> `test/spec/wasm-2.0-assert/**/manifest.txt` is replaced by a
> real `register {as_name} {wasm_file}` directive, and the
> `spec_assert_runner_non_simd` harness implements an instance
> registry that the new directive populates.

## Implementation (per ADR-0029 Path B, since §9.9 / 9.9-l-1b-d093-d59)

The distiller `scripts/regen_spec_2_0_assert.sh` (the embedded
Python `elif t == 'register':` arm) emits
`skip-adr-skip_cross_module_register as={c["as"]}` for every
`{"type": "register", ...}` JSON command. The 21 entries are then
classified by the existing `classifySkipLine` prefix match on
`skip-adr-` as `skip_adr` rather than `skip_impl`, contributing
to the `2494 skipped (= 1817 skip-impl + 677 skip-adr)` tally on
`test-spec-wasm-2.0-assert` (Mac aarch64 + OrbStack x86_64,
post-d-59). The runner needs no per-directive code path —
matching the pre-existing `skip-adr-skip_text_format_parser` /
`skip-adr-skip_externref_segment` / `skip-adr-skip_embenchen_emcc_env_imports`
pattern.

## References

- ADR-0029 (Path B `skip-impl == 0` enforcement + prefix-vocab
  rule)
- ADR-0050 D-2 (skip-ADR effectiveness gate)
- ADR-0057 (`spec_assert_runner_non_simd` factoring)
- D-079 (cross-module imports umbrella)
- D-082 (Path B vocab migration; D-072 (c)-path follow-up)
- D-105 (memory_grow cross-module memory imports — sub-case)
- D-126 (`bulk.wast` post-mutation funcptr divergence — sub-case)
- Wasm spec §A.1 (wast syntax for `register` directive)
