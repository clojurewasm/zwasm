# WasmGC spec-corpus scope + implementation plan (10.G-wasmgc)

**Date**: 2026-05-29
**Cycle**: 10.G-wasmgc cycle 121 (survey)
**Citing**: `664acf7e` (cycle 121 chore commit)

## Corpus state (direct-binary run)

`gc`: return 407 (pass=0 fail=384), trap 100 (fail), invalid 60
(pass=55 fail=5), malformed 1 (pass). **87/88 modules `compile FAIL:
ParseFailed`** — almost entirely a PARSE-level block.

## ParseFailed breakdown by family (leverage ranking)

- **type-subtyping ×44** (50%) — all need recursive type forms.
- array ×7, struct ×6, i31 ×6, array_new_elem ×4, array_new_data ×4,
  br_on_cast(_fail) ×6, ref_test ×2, ref_cast ×2, ref_eq/extern/
  array_{init_elem,init_data,fill,copy} ×1 each.

## The shared parse gap (highest leverage)

`src/parse/sections.zig` `decodeTypes` (~line 135-166) switches
`0x60` func / `0x5F` struct / `0x5E` array, then `else =>
Error.InvalidFunctype`. The **recursive type forms are unhandled**:
- `0x4E rec` — group of N mutually-recursive typedefs.
- `0x4F sub` — subtype with explicit supertype idx vec.
- `0x50 sub final` — final subtype (supertype idx vec, then the
  struct/array/func body).
Every type-subtyping module (+ most struct/array variants) hits
`0x4E`/`0x50` in the type section → rejects before the validator/
lowerer sees a GC opcode. Unblocking this one form opens ~44 modules.

## What's already landed (don't rebuild)

`feature/gc/` substrate: `heap.zig` (ObjectHeader), `type_info.zig`
(StructInfo/ArrayInfo/TypeInfo + `materialiseGcTypes`,
`GcTypeInfos`), `collector_mark_sweep.zig`, `i31.zig`,
`needs_heap_detector.zig`, `root_scope.zig`. `validator.zig`
`dispatchPrefixFB` (~1315) already dispatches the `0xFB` GC opcodes
(struct.new/get/set, array.*, i31.*, ref.test/cast, br_on_cast,
any↔extern, ref.eq) for the no-RTT cut. ADR-0115 (heap), ADR-0116
(roots+RTT+i31), ADR-0121 (struct/array typedef parse; RTT
materialisation explicitly DEFERRED).

## CORRECTION (cycle 122) — Chunk 1 and Chunk 2 are COUPLED

Two corrections from cyc122's attempt:
1. The actual bytes use `0x50 sub-final` (and `0x4F sub`), NOT `0x4E
   rec` — type-subtyping.{0,1,2} have 4E=0, 50=6-7. So each subtype is
   its OWN type index (no flattening refactor); the gap is the
   `0x50`/`0x4F` subtype PREFIX (`vec(typeidx)` supertypes + comptype)
   in `decodeTypes`, recorded in a parallel `supertypes` side-table.
2. **Parsing 0x50/0x4F ALONE regresses the invalid axis** (gc invalid
   pass 55→40). The type-subtyping fixtures are largely `assert_invalid`
   (BAD subtyping). They previously "passed" by accidentally ParseFailing
   on the unknown 0x50 byte; once parsed, they validate (no subtype
   check) → wrongly ACCEPTED → invalid regression. **Chunk 1 (parse) and
   Chunk 2 (subtype-conformance validation) MUST land together** — a
   D-188-class parse-vs-validate coupling. Reverted cyc122's parse-only.

The subtype-conformance check (a declared subtype's comptype must
structurally conform to each declared supertype: struct width+depth,
array element variance, func param/result variance, + the abstract
heap-type lattice struct/array <: eq <: any, i31 <: any, etc.) is
**ADR-grade** → file ADR-0124 FIRST, then implement parse + validate as
one coupled chunk (gc ParseFailed ↓ AND invalid stays ≥55, ideally →60).

## Plan (smallest-first; verify each by DIRECT binary run)

1. **Chunk 1 — recursive type parse** (NEXT, cyc122). `0x4E`/`0x4F`/
   `0x50` arms in `decodeTypes`; record supertype-idx in a parse-side
   side-table (do NOT materialise the RTT chain yet — ADR-0121 D6).
   Observable: gc ParseFailed 87 → ~43. NOT ADR-grade (parse-structure).
2. **Chunk 2 — subtype lattice + field-access kind-checks**. The 5
   invalid-accepted (struct.3/4, array.1/3/4) = validator missing
   "popped is structref/arrayref" check on struct/array field access
   (routine). Full ref.cast/ref.test RTT narrowing + the GC subtype
   lattice (struct/array <: eq <: any; i31 <: any; etc.) = ADR-grade →
   file ADR-0124. Observable: gc invalid 55→60.
3. **Chunk 3-4 — struct/array execution** (heap alloc + get/set/len via
   lower.zig + interp + instantiate StructInfo/ArrayInfo materialise).
4. **Chunk 5 — RTT supertype-chain materialise at instantiate** (from
   Chunk 1's side-table) → ref.cast/ref.test narrowing live.
5. **Chunk 6-7 — array copy/fill/init_elem/init_data + i31 exec**.

## Related

- ADR-0115 / ADR-0116 / ADR-0121 (GC substrate).
- `.dev/lessons/2026-05-29-eh-cross-module-tag-substrate-scope.md`
  (the EH survey→implement pattern this mirrors).
- D-197 (surface validate errors) — discharge candidate here (the gc
  384-fail debugging needs the specific decode/validate error, not
  generic ParseFailed).
