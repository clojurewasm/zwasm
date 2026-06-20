# spec-assert harness wires cross-module func+global, NOT table/memory

**Date**: 2026-06-20 · **Refs**: D-475, `test/spec/spec_assert_runner_base.zig`,
`src/zwasm/linker.zig`

## Observation

The Wasm-3.0-assert harness resolves `(register "M" $inst)` + a later module's
import ONLY for two import kinds:

- **func** — `resolveCrossModuleImports` (line ~1486) explicitly
  `if (imp.kind != .func) continue;` (JIT thunk path).
- **global** — `applyImportedGlobalsFromRegistered` (line ~1797) byte-copies the
  exporter's global slot into the importer's.

There is **no `applyImportedTablesFromRegistered` / …Memory…** equivalent. So a
module that imports a `register`ed TABLE (or memory) fails instantiation with
`LinkError.UnknownImport`. This surfaced when distilling the memory64 table64
corpus: `table.12/34` + `table_grow.6/7` (modules importing a registered table)
were the ONLY table64 spec fails left after the validator/runtime/u64-limits
fixes — and they are NOT table64-specific (an i32 cross-module register-table
import fails identically).

## Why it is NOT a zwasm conformance miss

zwasm's **runtime + linker DO support** cross-module table imports:
`Linker.defineTable` (linker.zig:395) installs a `TableAlias` payload
(linker.zig:157, D-201b) that aliases the exporter's `TableInstance.refs`. The
gap is purely the **test harness not calling `defineTable` for registered
tables**. Self-contained table64 modules are fully interp-conformant (11/13
spec dirs green). So this is a harness-COVERAGE gap, not a spec-conformance
miss — don't chase it as a zwasm bug.

## Caveat for the eventual harness wiring

`TableAlias` snapshots the exporter `TableInstance` by value (its `refs` slice
header aliases the shared backing). A cross-module `table.grow` (refs realloc)
would STALE the importer's snapshot — `table_grow.6` ($Tgit1 grows an imported
table) needs `*TableInstance` sharing (the D-199 memory precedent), not just
the value-alias. So wiring the harness closes the read-only cross-module table
imports; grow-across-modules needs the pointer-sharing follow-up first.
