# instantiate-FAIL / FAILsetup ≠ host-import — re-triage each individually

**Date**: 2026-06-16
**Context**: ADR-0192 wasmtime misc_testsuite differential campaign.

A prior cycle's native differential sweep (`wasmtime_misc_native_sweep.sh`)
reported a per-bucket tally with many `FAILsetup` / `instantiate FAIL` rows and
concluded **"native sweep CLEAN (0 value/ref mismatches); remaining fails are
FAILsetup/UnknownImport host-import fixtures"** — folding ALL setup failures into
one "host-import, parked (D-456)" bucket. A re-sweep + per-module triage
(`zwasm run <baked.wasm> --invoke <name>`) found that was wrong: **3 of the
setup-FAIL categories were real DEFERRED engine gaps, not host imports**:

- **A. v128 in a GC aggregate field** — `(struct (field v128))` →
  `type_info.zig fieldSlotSize` returns `Error.UnsupportedFieldSize` (the
  uniform-8-byte slot model can't hold a 16-byte field). Real Wasm 3.0 GC×SIMD
  gap. Fixtures: alloc-v128-struct, const-expr-gc-simd, v128-with-gc-ref,
  array-copy-inline.
- **B. `any.convert_extern`/`extern.convert_any` in const-expr** —
  `evalGlobalInitGc` `else => UnsupportedConstExpr`. FIXED this cycle (identity
  pass-through, `2daaf643`); fixture `gc/const-expr-gc` now returns 55.
- **C. memory64 memarg offset > 4 GiB** — `lower.zig readMemargOffset` rejects
  `> maxInt(u32)` with `BadMemarg`. This is D-209, whose note claimed such
  offsets appear "ONLY in assert_malformed/assert_invalid, never executed" — but
  wasmtime's `memory64/offsets.wast` uses `offset=0xffff_ffff_ffff_fff0` in an
  **`assert_trap`** (executed, expects OOB trap). Premise falsified; fix scope
  (multi-arch 64-bit offset codegen) unchanged.

## Rule

"instantiate-FAIL" / "FAILsetup" is NOT synonymous with "host-import". A
bucket-level "0 value mismatches" tally only counts modules that *executed*; it
is structurally blind to reject-before-execute gaps. When a differential sweep
reports setup failures, run **each** failing module through the engine
individually and read the actual error:

- `UnknownImport` → genuine host-import fixture (runner-extension, D-456 parked).
- `InstantiateFailed` / `BadMemarg` / `UnsupportedFieldSize` → a real engine
  reject; root-cause it before classifying as "parked".

Never let an aggregate green-ish tally ("0 value mismatches") stand in for
per-fixture triage on a conformance corpus — the same masking class as
`hardcoded-corpus-subset-hides-whole-op-families` (omission isn't auditable) and
`windows-crlf-manifest-badpathname-hidden-by-nongating-skeleton` (a non-gating
runner hides a broken bucket).
