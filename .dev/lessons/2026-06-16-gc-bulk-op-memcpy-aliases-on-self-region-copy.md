# GC bulk-copy `@memcpy` aliases on a self-region copy

**Date**: 2026-06-16
**Context**: ADR-0192 wasmtime misc_testsuite differential campaign, gc bucket.

## Observation

`array.copy` (Wasm 3.0 GC §3.3.5.6.14) has memmove semantics — it must
tolerate the source and destination being the **same array with overlapping
ranges**, including the degenerate `dst_off == src_off` (copy a region onto
itself). zwasm's interp handler (`array_ops.zig` `arrayCopy`) and the JIT
trampoline helper (`jit_abi.zig` `jitGcArrayCopy`) both did the per-element
copy with `@memcpy`. Zig's `@memcpy` requires the dest and source slices to
**not alias**; for a self-region copy the per-element slices are *identical*,
so it panics `@memcpy arguments alias` (abort, not a trap).

Fix: `std.mem.copyForwards(u8, dst, src)` per element — alias-safe (the
outer `overlap_backward` iteration already orders cross-element overlap; per
element the ranges are disjoint or identical, both fine for copyForwards).

## Why the synthetic suite missed it

The Wasm spec GC testsuite (`array_copy.wast`) is 362/0 green but never
exercises a self-region copy with equal offsets. wasmtime's
`tests/misc_testsuite/gc/array-copy-inline.wast` does. **Real / reference
corpora hit aliasing + overlap edges the synthetic suite skips** — the same
forcing-function pattern as the validator-subtyping lessons this campaign.

## Rule

Any heap↔heap bulk copy of guest-controlled ranges (array.copy, future
GC bulk ops) MUST use a memmove-safe copy (`copyForwards`/`copyBackwards`),
never `@memcpy`. `@memcpy` is only safe when one side is a distinct
stack/local buffer (struct.get header reads etc. — those stay `@memcpy`).
Audit: `grep -n '@memcpy' src/instruction/wasm_3_0/ src/engine/codegen/shared/jit_abi.zig`
and check both operands can never be the same heap region.
