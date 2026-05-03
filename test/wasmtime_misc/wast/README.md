# test/wasmtime_misc/wast/

Vendored from `bytecodealliance/wasmtime/tests/misc_testsuite/`
per ADR-0012 §1 (information sources) + §6.C (Phase 6 reopen
work item). Mirrors v1's `convert.py` BATCH1-3 origin
classification, expressed as physical directory hierarchy per
ADR-0012 §3 (D3) + §4 (D4 — directory hierarchy replaces
prefix).

## Categories

| Dir          | Origin                                 | Fixture count (vendored) |
|--------------|----------------------------------------|--------------------------|
| `basic/`     | wasmtime BATCH1 (basic ops)            | 21                       |
| `reftypes/`  | wasmtime BATCH2 (reference types)      | 8                        |
| `embenchen/` | wasmtime BATCH3 (embenchen + fib + rust_fannkuch) | 6                        |
| `issues/`    | wasmtime BATCH3 (GitHub issue regression) | 7                        |

Each subdir contains per-fixture sub-subdirs (e.g.
`basic/add/{add.0.wasm, manifest.txt}`); the `wast_runner`
recurses one level when a category dir lacks `manifest.txt`
itself.

Total: 42 fixtures, 72 .wasm files exercised by
`zig build test-wasmtime-misc-basic` (parse + validate gate).

## Queued for §9.6 / 6.E (v2 validator/interp gaps)

The following BATCH1-3 .wast files surfaced v2 validator gaps
when converted; they are NOT vendored under this directory yet
and are tracked as Phase-6 / 6.E investigation targets:

- BATCH1 basic: `wide-arithmetic`, `br-table-fuzzbug`,
  `no-panic`, `no-panic-on-invalid`, `elem_drop`
- BATCH2 reftypes: `int-to-float-splat`, `externref-id-function`,
  `mutable_externref_globals`, `simple_ref_is_null`,
  `externref-table-dropped-segment-issue-8281`,
  `many_table_gets_lead_to_gc`, `no-mixup-stack-maps`
- BATCH3 issues: `issue6562`

Re-add by removing the comment line in
`scripts/regen_wasmtime_misc.sh`'s BATCH list and re-running
the script after the validator/interp gap is fixed in §9.6 /
6.E.

## Out of Phase 6 scope (per ADR-0012 §6.2)

- BATCH4 SIMD (14 fixtures) → Phase 9
- BATCH5 proposals (function-references / tail-call /
  multi-memory / threads / memory64 / GC, 52 fixtures) →
  Phase 10

## Regeneration

```sh
bash scripts/regen_wasmtime_misc.sh
```

Reads from `$WASMTIME_REPO` (defaults to
`$HOME/Documents/OSS/wasmtime`); converts each `.wast` via
`wast2json`; distils JSON commands into per-fixture
`manifest.txt` (parse + validate directives only;
runtime-asserting directives wire when §9.6 / 6.D activates
the runtime runner against this corpus).

Generated `.wasm` files are committed; `.json` intermediates
are not.
