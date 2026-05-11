# Skip — `embenchen_*1.wasm` (emscripten `env`-module imports)

- **Status**: Accepted (skip until follow-up — see "Removal plan"). Operationally effective via `skip-adr-skip_embenchen_emcc_env_imports` prefix per ADR-0029 Path B (since chunk 9.9-h-23, 2026-05-12); see §"Implementation" below.
- **Date**: 2026-05-04
- **Author**: zwasm v2 / continue loop
- **Tags**: phase-6, skip-adr, misc-runtime, embenchen, manifest-format
- **Fixtures covered**: 4

## Fixtures

- `test/wasmtime_misc/wast/embenchen/embenchen_fannkuch/embenchen_fannkuch.1.wasm`
- `test/wasmtime_misc/wast/embenchen/embenchen_fasta/embenchen_fasta.1.wasm`
- `test/wasmtime_misc/wast/embenchen/embenchen_ifs/embenchen_ifs.1.wasm`
- `test/wasmtime_misc/wast/embenchen/embenchen_primes/embenchen_primes.1.wasm`

All four are emscripten-compiled C benchmarks that import a host
`env` module (memory, table, globals, +helper functions like
`abort`, `enlargeMemory`, `getTotalMemory`).

## What v2 does today

`zig build test-wasmtime-misc-runtime` reports each `.1.wasm` as
`InstanceAllocFailed` with internal `error.UnknownImportModule`.
The companion `*.0.wasm` ("env stub") imports the runtime's
funcs / memory / globals; module 1 imports `env.*`.

The corresponding `manifest_runtime.txt`:

```
module embenchen_fannkuch.0.wasm as $env
module embenchen_fannkuch.1.wasm
```

— no `register` directive. Per the upstream `.wast` source
(`~/Documents/OSS/wasmtime/tests/misc_testsuite/embenchen_fannkuch.wast`)
the original script also lacks an explicit `(register "env" $env)`.

## Why v2 declines

Wasmtime's wast runner auto-registers `(module $X ...)` under
the bare name `X` (`crates/wast/src/wast.rs:fn module` →
`core_linker.instance(name, instance)`). zwasm's
`wast_runtime_runner.zig:handleModule` honours `as $X` only as a
script-local id and does **not** auto-register under the bare
name.

A naive auto-register fix (mirroring wasmtime) was attempted in
this 6.E close cycle and **immediately exposed a pre-existing
validator gap**: 9 of the 12 `linking-errors/linking-errors.*`
fixtures regressed from PASS to FAIL because c\_api's import-
resolution loop only checks `ext.kind != want_kind` — it does
**not** check that an imported global's type, an imported
table's element type, or an imported function's signature
matches the expected import descriptor. With auto-register
turned on, those fixtures successfully resolve "m" → module 0
but the type-mismatch checks that should reject the import
silently allow it through.

### Spike outcome (recorded so the same trial isn't retried)

Date: 2026-05-04. Branch state: `b569b8f` (the 6.E close commit).
Spike: edit `test/runners/wast_runtime_runner.zig:handleModule`
to mirror wasmtime's `crates/wast/src/wast.rs:fn module` —
register `(module $X ...)` under the bare name `X` (in addition
to the script-id `$X`) so subsequent `m.X` imports resolve.
Result: misc-runtime fail count went **5 → 14** (4 embenchen
recovered as expected; 9 `linking-errors/linking-errors.{1-9}.wasm`
regressed from PASS to FAIL because their assert\_unlinkable
clauses depend on import-type validation that v2 doesn't yet do).
Spike reverted in the same edit window. The full investigation
also lives in `.dev/lessons/2026-05-04-autoregister-spike-regression.md`.

## What v2 needs to fix this honestly

1. Implement proper Wasm 2.0 §3.4.10 import-matching rules in
   `src/c_api/instance.zig`:
   - Function: imported `funcType` must equal expected `funcType`.
   - Global: imported `valType` + mutability must equal expected.
   - Table: imported `elem_type` + min/max bounds must satisfy
     spec sub-typing rules.
   - Memory: imported min/max bounds must satisfy sub-typing.
2. Land auto-register in
   `wast_runtime_runner.zig:handleModule` once (1) is in place.
3. Re-run misc-runtime; expect both these 4 embenchen fixtures
   AND the 9 `linking-errors/*.wasm` (assert\_unlinkable) to
   pass.

This is a Phase-6.J follow-up `linking-errors-and-import-type-
matching` row, not in 6.K's scope per ADR-0014's funcref/
ownership/cross-module narrative.

## Removal plan

When the validator-hardening work above lands (likely a new
ROADMAP §9.6 row, or as part of the post-Phase-6 spec-
conformance pass), this skip ADR's 4 fixtures **must** be
removed from the runner's deferred-skip list and re-run end-to-
end. The ADR itself stays as historical record.

## Removal condition (machine-checkable)

`scripts/check_skip_adrs.sh` (proposed) walks
`.dev/decisions/skip_*.md`, parses each "Removal condition"
line, and verifies the condition is still true. For this ADR
the condition is:

> The `linking-errors/linking-errors.{1-9}.wasm` fixtures all
> report PASS in `zig build test-wasmtime-misc-runtime` AND
> the runner's `handleModule` calls a non-trivial auto-register
> path.

When both halves of that AND become true, this ADR's skip
status expires; promote the 4 embenchen fixtures back into
the runner.

## Current effectiveness gap (2026-05-11)

Per the 2026-05-11 ADR audit
(`private/20250511_adr_audit/SUMMARY.md` §2.1 +
`batch_A_findings.md`), this skip-ADR is **not effective** per
ADR-0050 D-2's three-path test:

- **Path 1 (runner-side classification)**: ❌
  `wast_runtime_runner.zig` does NOT classify any of the 4
  fixtures as `skip-adr` — `grep` returns 0 hits for
  `skip_embenchen` or `embenchen_fannkuch.1` skip handling.
- **Path 2 (DEFER mark + runner skip-token)**: ❌ the 4
  fixtures appear in `manifest_runtime.txt` as plain `module
  embenchen_*.1.wasm` lines without `# DEFER:` marks. The
  runner has no skip-token machinery.
- **Path 3 (manifest exclusion)**: ❌ fixtures are active in
  `manifest_runtime.txt`.

Operational effect: `zig build test-wasmtime-misc-runtime`
reports **4 honest FAILs** for these fixtures (joined by 1
from `skip_externref_segment.md` for 5 total). This is masked
because `test-wasmtime-misc-runtime` is **not aggregated into
`test-all`** — Phase 6's strict-close gate (ADR-0012 §6.J)
fired against `test-all` only. The moment the runner enters
`test-all`, Phase 6's strict-PASS claim collapses.

Discharge path tracked as **D-072** in `.dev/debt.md`. Three
options the discharge can pick from (per ADR-0050 D-2):

1. Add `skip-adr-<slug>` token recognition to
   `wast_runtime_runner.zig` (matches Path 1).
2. Add `# DEFER: skip_embenchen_emcc_env_imports` lines to
   `manifest_runtime.txt` and runner-side skip handling
   (matches Path 2).
3. Land the actual fix from "What v2 needs to fix this
   honestly" (proper Wasm 2.0 §3.4.10 import-type validation
   in `src/c_api/instance.zig`); the skip-ADR retires.

The skip-ADR's design intent and Removal condition are
unchanged; only the runner-side wiring is missing.

## Implementation (per ADR-0029 Path B, since chunk 9.9-h-23)

The 4 fixtures' `manifest_runtime.txt` carry the line
`skip-adr-skip_embenchen_emcc_env_imports embenchen_<topic>.1.wasm`
in place of `module embenchen_<topic>.1.wasm`. Parsed by
`test/runners/wast_runtime_runner.zig` (since chunk 9.9-h-23);
the runner emits the line in the `skip-adr` tally rather than
`skip-impl`, so `zig build test-wasmtime-misc-runtime` reports
`266 passed, 0 failed, 5 skipped (= 0 skip-impl + 5 skip-adr)`
— operationally effective per ADR-0050 D-2. The companion
`module embenchen_<topic>.0.wasm as $env` line still loads
(the `.0.wasm` "env stub" instantiates correctly; the gap is
in `.1.wasm`'s emscripten `env` imports). The "Current
effectiveness gap (2026-05-11)" §below predates the migration
and is retained for historical context; do not interpret it
as current state.

## References

- ADR-0014 §2.1 / 6.K.3 (cross-module imports — implements the
  *kind*-level routing this skip-ADR depends on)
- ADR-0014 §2.1 / 6.J (strict-100%-PASS close criterion +
  per-fixture skip-ADR escape clause)
- ADR-0050 (skip-ADR effectiveness gate that flagged this
  ADR's not-effective status)
- D-072 (skip-ADR runner-gate enforcement debt)
- `crates/wast/src/wast.rs:fn module` (wasmtime's auto-
  register reference implementation)
- Wasm 2.0 §3.4.10 (import-matching sub-typing rules)
