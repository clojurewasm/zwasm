# 0125 — WasmGC packed storage types via a `StorageType` union

- **Status**: Accepted
- **Date**: 2026-05-29
- **Author**: zwasm v2 / continue loop (autonomous, 10.G)
- **Tags**: phase-10, wasmgc, packed-types, struct, array, type-representation, ADR-0121-refinement, single-slot-dual-meaning

## Context

Wasm 3.0 GC §"Storage and field types" defines a field as
`fieldtype = (storagetype, mut)` where
`storagetype = valtype | packedtype` and `packedtype = i8 (0x78) | i16
(0x77)`. Packed types appear **only** in struct fields and array
elements — never on the operand stack. `struct.get` / `array.get` are
valid only on **non-packed** fields (push the valtype);
`struct.get_s` / `struct.get_u` (and `array.get_s` / `_u`) are valid
only on **packed** fields (sign- / zero-extend the i8/i16 to i32).
`struct.set` / `array.set` to a packed field store an i32 truncated to
i8/i16.

ADR-0121 D3 deferred packed types: "collapse `packed_type` (i8 / i16)
onto `ValType` extensions in a follow-up cycle (D-NNN to be filed when
sub-chunk 5 lands); for the first cut, fields are restricted to the
existing `ValType` set; packed-type encoding rejected." Today
`readFieldType` (`src/parse/sections.zig:107`) calls
`init_expr.readValType` → `BadValType` on 0x78/0x77.

The ADR-0016 M3 diagnostic (`d8daef9b`) made the cost concrete: a large
slice of the gc corpus — `ref_test.0`, `ref_cast.0`, `br_on_cast.0`,
`struct.0`, `struct.10`, `array.0`, `array.7`, `array.8`, `i31.3`,
`ref_eq.0`, `extern.0` — fails compile with
`type-section decode: BadValType`, i.e. blocked on this one gap. It sits
on the critical path of the gc `return ≥ 90` target.

## Decision

Introduce a **`StorageType` tagged union** and carry it on the field
type, instead of ADR-0121 D3's planned `ValType`-extension:

```zig
// src/parse/sections.zig
pub const PackedType = enum(u8) { i8 = 0x78, i16 = 0x77 };

pub const StorageType = union(enum) {
    val: ValType,        // numtype | vectype | reftype (operand-stack type)
    packed_: PackedType, // i8 / i16 — storage only, never on the stack
};

pub const StructFieldType = struct {
    storage: StorageType,   // was: valtype: ValType
    mutable: bool,
};
// ArrayDef.element keeps using StructFieldType.
```

Derived helpers on `StorageType`:
- `operandType()` → `ValType` — `.val => v`, `.packed_ => .i32` (the
  unpacked type seen by `struct.new` / `set` / `get_s` / `get_u`).
- `isPacked()` → `bool`.
- `specByte()` → the wire byte (`0x78`/`0x77` for packed, else the
  valtype byte) for `FieldInfo.valtype_byte` materialisation.
- `storageWidth()` → 1 (i8) / 2 (i16) / 8 (val) for the get_s/get_u
  sign-extension boundary (the **slot** stays 8 bytes uniform per
  ADR-0116 §3a; width drives extend-on-get / truncate-on-set, NOT the
  slot size).

Validator rules (Wasm 3.0 §3.3.5.6):
- `struct.get` / `array.get`: REJECT when the field is packed
  (`StackTypeMismatch` / a dedicated error); push `operandType()` when
  not.
- `struct.get_s` / `_u`, `array.get_s` / `_u` (ZirOps + lower.zig
  dispatch already exist; validator currently returns `NotImplemented`):
  REJECT when the field is NOT packed; push `.i32` when packed.
- `struct.set` / `array.set` / `array.fill`: pop `operandType()`
  (i32 for packed; truncation happens at exec time).
- Struct/array structural subtype comparison
  (`validator.zig:~2807`) compares `StorageType` (so an `i8` field and
  an `i16` field are NOT equal — the union makes this fall out
  naturally).

Runtime / exec:
- `materialiseGcTypes` sets `FieldInfo.valtype_byte = storage.specByte()`
  and records the storage width.
- `struct.get_s` / `_u` + `array.get_s` / `_u` exec handlers read the
  low `storageWidth()` bytes of the 8-byte slot and sign- / zero-extend
  to i32. `struct.set` / `array.set` truncate i32 → i8/i16 on store.

## Alternatives

1. **Extend `ValType` with i8/i16 (ADR-0121 D3's original plan).**
   REJECTED. `ValType` is the operand-stack / signature / local type,
   used pervasively. i8/i16 can never appear on the operand stack, so
   adding them to `ValType` forces every `switch (valtype)` site (emit,
   interp, regalloc class, sig checks) to handle variants that are
   structurally impossible there — and risks a silent miscompile if one
   forgets. This is the "single field serving two semantic axes"
   §14-forbidden pattern (`single_slot_dual_meaning.md`): `ValType`
   would carry both "stack type" and "storage-only type."

2. **Keep `valtype: ValType` (= i32 for packed) + add a defaulted
   `packed: ?PackedType = null`.** REJECTED despite the lower blast
   radius (defaulted field → existing constructors compile unchanged).
   It re-creates the dual-axis hazard on `valtype`: readers can't tell
   from `valtype` alone whether a field is "really i32" or "packed i8
   unpacked to i32," and the structural-subtype comparison would treat
   `i8` and `i16` fields as equal (both `valtype = i32`) unless every
   such site also remembers to consult `packed`. The union makes the
   declared storage type a single unambiguous value; per the global
   "take the あるべき論 option, don't optimise for impl cost" directive,
   the union's mechanical churn (atomic field rename + ~34 test
   constructors) is the right price.

## Consequences

- **Atomic refactor.** Renaming `StructFieldType.valtype` →
  `storage: StorageType` breaks every reader until updated, so the
  switch lands in **one commit** (cannot be partially staged). Blast
  radius (per the cyc146 mapping subagent):
  - parse: `readFieldType`, `StructFieldType`, `StorageType`/`PackedType`
    (`sections.zig`).
  - runtime: `fieldSlotSize`, `materialiseGcTypes`, `FieldInfo`
    materialisation (`type_info.zig`).
  - validator: `opStructGet` / `opStructSet` / `opArrayGet` /
    `opArraySet` / `opArrayFill` + the get_s/_u dispatch arms (drop the
    `NotImplemented`) + structural subtype cmp (`validator.zig`).
  - exec: `structGet` / `structSet` / `arrayGet` / `arraySet` /
    `arrayFill` + NEW `structGetS` / `structGetU` / `arrayGetS` /
    `arrayGetU` handlers (`struct_ops.zig`, `array_ops.zig`).
  - tests: ~34 `StructFieldType` / `ArrayDef` constructors in
    `validator_tests.zig` + the `type_info.zig` / `struct_ops.zig` /
    `array_ops.zig` test blocks (mechanical `.valtype = X` →
    `.storage = .{ .val = X }`).
- **8-byte slots retained** (ADR-0116 §3a). Packed only affects the
  *encoding* (`valtype_byte`) + the extend-on-get / truncate-on-set
  boundary, not slot size. No heap-layout change.
- **ZirOps already exist.** `struct.get_s/_u`, `array.get_s/_u` are in
  `zir_ops.zig` and lower.zig already routes 0xFB sub-ops 3/4 + 12/13;
  the validator just drops its `NotImplemented` rejections.
- **Unblocks** the packed gc corpus families at compile; combined with
  ref.test exec (separate RTT work, ADR-0116) it reaches the
  ref_test / ref_cast / struct.10 / array.{0,7,8} return assertions.
- The implementation lands as a fresh `/continue` bundle (the atomic
  refactor wants full context); the ADR-0016 M3 diagnostic attributes
  each remaining failure as it proceeds.

## References

- ADR-0121 D3 (the deferral this refines) + D2 (StructDef/ArrayDef).
- ADR-0116 §3a (8-byte uniform slots, natural-width deferral).
- `.claude/rules/single_slot_dual_meaning.md` (§14 — the dual-axis
  rejection of alternatives 1 + 2).
- ADR-0016 M3 (`d8daef9b`) — the diagnostic that surfaced the blocker.
- Wasm 3.0 GC §3.3.5.6 (struct/array get/get_s/get_u/set validation),
  §5.3 (storagetype binary encoding).

## Revision history

| Date | SHA | Note |
|---|---|---|
| 2026-05-29 | `31bca2ad` | Accepted. Refines ADR-0121 D3 (packed via `StorageType` union, not `ValType` extension). Impl queued as a `/continue` bundle. |
