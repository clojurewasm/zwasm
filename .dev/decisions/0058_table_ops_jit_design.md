# 0058 — JIT table.* family design: generalized TableSlice ABI

- **Status**: Accepted
- **Date**: 2026-05-12
- **Author**: zwasm v2 maintainer (autonomous `/continue` loop, Phase 9 close, §9.9 / 9.9-m-2 cluster)
- **Tags**: phase-9, jit, abi, tables

## Context

§9.9 (Wasm 2.0 100% PASS on Mac+OrbStack per ADR-0056) requires
the full `table.*` family on the JIT path:

| Op            | Wasm spec | Shape                                              |
|---------------|-----------|----------------------------------------------------|
| `table.get x` | §4.4.10   | pop i32 idx → push reftype                         |
| `table.set x` | §4.4.11   | pop reftype val, pop i32 idx                       |
| `table.size x`| §4.4.12   | push i32 (current length)                          |
| `table.grow x`| §4.4.13   | pop i32 n + reftype init → push i32 prev_size / -1 |
| `table.fill x`| §4.4.14   | pop i32 dst + reftype val + i32 n                  |
| `table.copy x y`| §4.4.15 | pop i32 dst + i32 src + i32 n (dst-tbl x, src-tbl y) |
| `table.init x y`| §4.4.16 | pop i32 dst + i32 src + i32 n (elemidx x, tbl y)   |

The validator + interp paths were complete pre-Phase 9 (Wasm 2.0
groundwork). The JIT had only call_indirect's table-0-specialised
`funcptr_base` + `table_size` invariants (per ADR-0017). Generic
`table.*` ops surfaced as `UnsupportedOp` at compile time.

This ADR codifies the JIT-side runtime shape (a parallel
`tables_ptr: [*]const TableSlice` array) and the m-2a/b/c chunk
split that lands the family.

## Decision

### 1. JitRuntime ABI extension — `TableSlice`

Extend `src/engine/codegen/shared/jit_abi.zig` with a new tail
field pair (mirroring m-3a's `data_dropped` and m-3b's
`data_segments`):

```zig
pub const TableSlice = extern struct {
    refs: [*]u64,   // pointer to the table's u64[] storage
    len: u32,       // current entry count (post-grow visible)
    max: u32,       // max-cap (table_no_max = u32_MAX = "no max")
};
pub const table_slice_size: u32 = @sizeOf(TableSlice); // = 16

pub const JitRuntime = extern struct {
    ...
    tables_ptr: [*]const TableSlice = undefined,
    tables_count: u32 = 0,
    _pad9: u32 = 0,
};
```

The 16-byte stride matches `SegmentSlice` (m-3b) for ABI
consistency across the JIT body's tail-extension reads.

**Storage encoding for `refs`**: each `u64` entry is a
`Value.ref`-encoded value identical to the interpreter's
`TableInstance.refs: []Value` representation:

- Funcref tables: `@intFromPtr(&rt.func_entities[funcidx])` (the
  m-1b funcref encoding) or `Value.null_ref` (= 0).
- Externref tables: opaque host-supplied u64 handle or
  `Value.null_ref`.

The JIT loads/stores raw u64 without tag inspection; type
correctness is the validator's responsibility (Wasm spec §4.5.7
elem-type check).

### 2. `tables_ptr` array generalises beyond table 0

Pre-m-2a, JitRuntime carried `funcptr_base` + `table_size` as a
table-0-only specialisation for `call_indirect`'s fast path:
each entry is a **native code pointer** (executable address)
plus a parallel `typeidx_base[u32]` for the sig check. That
representation is **not the spec's table representation** — it's
a precomputed dispatch cache.

For `table.get`/`set`/etc., the spec table representation is
required: each entry is a 64-bit `Value.ref` (FuncEntity ptr for
funcref). The new `tables_ptr` is a **parallel** array; the
existing `funcptr_base` stays for call_indirect.

Trade-off: 16 extra bytes per declared table (TableSlice is
denormalised against the funcref/externref union, but the
interp's `TableInstance` is also denormalised in the same
direction). Storage cost is bounded by the module's static table
count — well under 100 declared tables in any realworld module.

**Coherency follow-up**: `table.set` updates `tables_ptr[0].refs[i]`
(Value.ref encoding) but NOT `funcptrs_buf[i]` (native code
pointer cache). If a Wasm program runs `call_indirect` after
`table.set` writes a fresh funcref into table 0, the
`call_indirect` would read a stale native-code-ptr. This is a
known limitation in m-2a; tracked as a Phase-10 follow-up debt
(D-090 once filed). Realworld modules in the current corpus
don't exercise this pattern (most use static element-segment
init for call_indirect tables); v1's same idiom carried the
same gap.

### 3. Chunk split — m-2a / m-2b / m-2c

Per the pre-m-2 survey
([`private/notes/p9-99-m-2-table-survey.md`](../../private/notes/p9-99-m-2-table-survey.md)):

| Sub-chunk | Ops                                  | Notes                                              |
|-----------|--------------------------------------|----------------------------------------------------|
| m-2a      | table.get / table.set / table.size   | Bounds-checked load/store; this chunk lands ADR.   |
| m-2b      | table.grow / table.fill              | Runtime helper for grow; inline loop for fill.     |
| m-2c      | table.copy / table.init              | memmove semantics; init reads elem_dropped (m-3a). |

Each sub-chunk independently meets the §9.9 close gate; m-2 as a
whole closes when m-2c lands.

### 4. `table.grow` returns -1, never traps

Per Wasm spec §4.4.13: growth failure (max-cap exceeded, u32
overflow, or host allocation failure) returns `-1: i32` and
leaves the table unchanged. The JIT MUST NOT raise a trap on
this path. Implementation in m-2b will route through a runtime
helper (C-ABI call from JIT body) to handle the realloc; the
return value is pushed via the standard sig-result marshal.

### 5. table.fill / table.copy inline loops (not memcpy helper)

Mirror the memory.fill / memory.copy / memory.init pattern
already landed: emit a forward (or backward, for copy with
overlap) byte loop using `LDR/STR` (arm64) or `MOV` (x86_64) on
the 8-byte ref slot. memmove semantics for `table.copy` use the
same `same_table && dst > src && dst < src+n` backward arm as
the interp.

## Alternatives considered

1. **Reuse `funcptr_base` for `table.get`**: rejected. The
   pre-existing array stores **native code pointers** (used by
   `call_indirect` fast-path dispatch), not the spec's funcref
   encoding (`@intFromPtr(&FuncEntity)`). Reusing it would force
   `table.get` to re-derive the funcref encoding at every read
   (reverse-lookup native ptr → FuncEntity), which is both
   expensive and ambiguous for null entries.

2. **Single `tables_ptr` covering both table 0 and table 1+**
   (no separate funcptrs_buf): rejected for m-2a scope.
   Migrating `call_indirect`'s fast-path to the generalised
   table representation requires extra ABI work (load native
   code ptr from FuncEntity at each call, not from a precomputed
   cache); deferred to Phase 10+ when the call_indirect / table
   coherency story is unified.

3. **Tagged-union TableSlice for funcref vs externref**:
   rejected. Wasm spec §3.2.1 (table type) requires elem_type
   uniformity per table; the validator enforces this. The JIT
   doesn't need to inspect elem_type at runtime — the read/write
   shape is the same 64-bit slot regardless.

4. **`max: ?u32` (optional) in TableSlice**: rejected. extern
   struct can't carry `?u32`; the sentinel `table_no_max =
   std.math.maxInt(u32)` represents "no max" (matches interp's
   `?u32` `null` semantics with one less indirection at the
   read site).

## Consequences

**Positive**:

- All seven `table.*` ops become first-class JIT citizens; no
  fallback to interp for spec-test fixtures.
- The `TableSlice` ABI surface is small (16 bytes per table) and
  matches `SegmentSlice` stride for cross-handler consistency.
- ADR-grade decision recorded once per family; m-2b and m-2c
  cite this ADR for the shared design substrate.

**Negative**:

- 16 bytes additional JitRuntime tail per module (negligible).
- `table.set` / `table.fill` / `table.copy` / `table.init` write
  the `Value.ref` storage but do NOT update `funcptrs_buf` /
  `typeidxs_buf` for table 0. A mixed program (static element
  segments + runtime table mutation + `call_indirect`) sees stale
  cache reads. Documented as known limitation; tracked as debt
  for Phase 10 unification.

**Neutral / follow-ups**:

- m-2b: filed at next chunk. Will introduce a runtime helper
  call from JIT body (mirroring the host_dispatch path) for
  `table.grow`'s realloc.
- m-2c: filed at next chunk. Depends on m-3a's
  `elem_dropped_ptr` (already in JitRuntime).
- Phase 10+: unify `funcptrs_buf` / `typeidxs_buf` into
  `tables_ptr` (single source of truth); `call_indirect` then
  loads the FuncEntity ptr from the table and indirects through
  `FuncEntity.func_idx` to the linker's compiled body table.

## Operand-capture discipline (Step 4 lesson)

The first arm64 m-2a iteration suffered a silent-miscompile
class bug: the JIT body loaded `tables_ptr → X10`, then `refs →
X11`, then `len → W12` BEFORE staging the popped operand vregs.
The arm64 regalloc allocates from {X9..X13, X19..X22}, so the
operand vregs' home registers may be X10/X11/X12 — clobbered by
the prologue LDR sequence. The `set_get_roundtrip` fixture
exposed this: `idx=1, len=4` traps incorrectly because the
captured idx value gets overwritten before the CMP.

**Discipline**: operand snapshot via `encOrrRegW(17, 31, w_src)`
(or `encOrrReg(16, 31, x_src)` for 64-bit operands) into the
intra-procedure scratch X16/X17 MUST precede any LDR into
X10/X11/X12. Mirrors `arm64/op_memory.emitMemoryInit`'s Step A
pattern. The x86_64 path is unaffected because that
architecture's allocatable pool {RBX, R12, R13, R14} is
disjoint from the {RAX, RCX, RDX, R10, R11} scratch used by the
table.* prologue.

This isn't a new design decision — it's the existing
op_memory.emitMemoryInit pattern documented as a same-class
trap for future m-2 chunks (m-2b + m-2c each have ≥ 2 operands
to capture).

## References

- [`private/notes/p9-99-m-2-table-survey.md`](../../private/notes/p9-99-m-2-table-survey.md)
  — pre-m-2 textbook survey (v1, wasmtime/winch, zware, wasm3).
- [`src/engine/codegen/shared/jit_abi.zig`](../../src/engine/codegen/shared/jit_abi.zig)
  — TableSlice extern struct + tables_ptr field.
- [`src/engine/codegen/arm64/op_table.zig`](../../src/engine/codegen/arm64/op_table.zig)
  — arm64 emit (this chunk).
- [`src/engine/codegen/x86_64/op_table.zig`](../../src/engine/codegen/x86_64/op_table.zig)
  — x86_64 emit (this chunk).
- [`src/instruction/wasm_2_0/table_ops.zig`](../../src/instruction/wasm_2_0/table_ops.zig)
  — interp parity reference.
- ADR-0017 (JitRuntime layout, prologue invariants).
- ADR-0056 (Phase 9 scope extension to Wasm 2.0 100% PASS).
- Wasm spec §4.4.10–§4.4.16 (table instructions).
- `~/Documents/OSS/wasmtime/winch/codegen/src/visitor.rs`
  (table.* single-pass visitor reference).

## Amendment — 2026-05-12 (m-2c-init): ElemSlice ABI extension

§9.9 / 9.9-m-2c-init introduces `ElemSlice` to JitRuntime —
parallel to TableSlice + SegmentSlice, 16-byte stride. Each
declared element segment gets a `[]u64` of pre-computed
funcref-encoded values (FuncEntity pointers; `Value.null_ref`
for null entries). Layout:

```zig
pub const ElemSlice = extern struct {
    refs: [*]const u64,
    len: u32,
    _pad: u32 = 0,
};
```

New JitRuntime tail fields (lined up after `tables_count`'s
padding):

```zig
elem_segments_ptr: [*]const ElemSlice = undefined,
elem_segments_count: u32 = 0,
_pad10: u32 = 0,
```

head_size: 168 → 184 bytes (16 + padding for the new pair).

`setupRuntime` populates the array by walking the element
section once and allocating two slices (descriptors + refs
arena). Funcidxs in the segment are converted to
FuncEntity-ptr encoding via `@intFromPtr(&func_entities[fidx])`,
identical to m-1b's ref.func emit shape and m-2a's
table_refs element-segment population.

`table.init` reads `elem_segments_ptr[elemidx]` then
overrides `seg.len → 0` via the existing `elem_dropped_ptr`
flag (m-3a). The dropped-flag override is implemented with
CSEL X15, X15, XZR, EQ on arm64 and CMOVNE on x86_64 —
mirror of m-3b's memory.init Step C pattern.

## Revision history

- 2026-05-12: Initial accept at §9.9 / 9.9-m-2a landing commit.
- 2026-05-12 (m-2b): table.fill landed without scope change to
  this ADR; documented in commit body.
- 2026-05-12 (m-2c): table.copy landed without scope change to
  this ADR; documented in commit body.
- 2026-05-12 (m-2c-init): ElemSlice ABI extension amendment
  above. New tail fields + 16-byte stride per-segment funcref
  arena. table.init handler both arches.
