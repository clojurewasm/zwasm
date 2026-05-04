# Auto-register spike regressed `linking-errors/*.wasm` (5 → 14 fails) — exposed import-type validation gap

- **Date**: 2026-05-04
- **Phase**: Phase 6 / §9.6 / 6.E (close cycle)
- **Citing**: `skip_embenchen_emcc_env_imports.md` "Why v2 declines" §;
  commit `b569b8f` body; debt entry D-006

## What was tried

To close the 4 remaining `embenchen_*1.wasm` `manifest_runtime.txt`
failures (`InstanceAllocFailed` / `error.UnknownImportModule`), the
`wast_runtime_runner.zig:handleModule` was modified to mirror
wasmtime's behaviour: when a script declares `(module $X ...)`,
auto-register that instance under the **bare** name `X` (in addition
to the `$X` script-id), so subsequent `m.X` imports can resolve.

Wasmtime does this in `crates/wast/src/wast.rs:fn module` →
`core_linker.instance(name, instance)`. Mirroring it required ~10
lines.

## What broke

The misc-runtime fail count went **from 5 to 14**. The 4 embenchen
fixtures recovered as expected (PASS). The new 9 failures were all
`linking-errors/linking-errors.{1-9}.wasm`, which `assert_unlinkable`
on type mismatches.

Root-cause inspection (via `wasm-tools print`):

- `linking-errors.0.wasm` exports `(global g i32 ...)`.
- `linking-errors.1.wasm` imports `(global g i64)`.
- spec mandates `assert_unlinkable` (i32 ≠ i64).
- v2's `c_api/instance.zig` `instantiateRuntime` import-resolution
  loop only checks `ext.kind != want_kind` (.global vs .global) —
  the underlying `valtype` mismatch is **not** validated.

Pre-spike, those fixtures "passed" by accident: `m` was unresolvable
under the bare name (only `$m` registered), so they failed at the
manifest-discovery layer **before** reaching the type-check
shortfall. Auto-register exposed the genuine gap.

## What was done

The auto-register edit was reverted; the 4 embenchen fixtures
were skip-ADR'd (`skip_embenchen_emcc_env_imports.md`). Misc-runtime
returned to 266 PASS / 5 deferred. The validator gap was filed
as debt entry **D-006** with `blocked-by: import-type-validation
work scope`.

## Lesson

Two takeaways:

1. **A "stuck fixture" symptom may be hiding a deeper validator
   gap.** Mirror-ing wasmtime's harness behaviour is correct in
   isolation but only safe when the underlying validator already
   matches wasmtime's strictness. Verify the validator first;
   harness parity second.
2. **Auto-register is not "safe" without import-type checking.**
   Future attempts to land the auto-register feature must
   sequence import-type validation **before** the harness change
   — re-introducing the same regression is not a learning
   opportunity, it's a violation of this lesson.

## Re-derivable from

- `skip_embenchen_emcc_env_imports.md` "What v2 needs to fix
  this honestly" §
- Commit `b569b8f` body
- Debt entry D-006 in `.dev/debt.md`
