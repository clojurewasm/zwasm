# Typed Function References

Status: Wasm 3.0 | Repo: function-references | Complexity: high
zwasm: todo | Est. LOC: ~800 | Opcodes: 5 new

## What It Adds

Generalizes reference types to support typed function references `(ref $t)`.
Enables statically-typed indirect calls via `call_ref` (no table lookup
needed). Introduces non-nullable references, local initialization tracking,
and table initializer expressions.

## New Opcodes

| Opcode | Binary | Signature | Description |
|--------|--------|-----------|-------------|
| call_ref | 0x14 | [t1* (ref null $t)] -> [t2*] | Call typed function reference |
| return_call_ref | 0x15 | [t1* (ref null $t)] -> [t2*] | Tail call via typed ref |
| ref.as_non_null | 0xd4 | [(ref null ht)] -> [(ref ht)] | Assert non-null (trap if null) |
| br_on_null | 0xd5 | [t* (ref null ht)] -> [t* (ref ht)] | Branch if null, pass non-null |
| br_on_non_null | 0xd6 | [t* (ref null ht)] -> [t*] | Branch if non-null |

## New Types

| Type | Description |
|------|-------------|
| (ref ht) | Non-nullable reference to heap type |
| (ref null ht) | Nullable reference (existing funcref/externref become shorthands) |
| heaptype index | Type index as heap type: `(ref $functype)` |

Shorthands preserved:
- `funcref` = `(ref null func)`
- `externref` = `(ref null extern)`

## Key Semantic Changes

1. **Typed references**: `(ref $t)` carries the function's type statically.
   `call_ref` uses this type for direct dispatch — no table, no runtime
   type check (faster than call_indirect).

2. **Nullability**: `(ref ht)` is non-nullable (not defaultable).
   - Cannot be used as local type without initialization
   - Cannot be default value for table elements

3. **Local initialization tracking**: Validation tracks which locals have
   been set. `local.get` on a non-defaultable local before `local.set/tee`
   is a validation error. This affects control flow merges (both branches
   must initialize before a get after the merge).

4. **Table initializers**: Tables with non-nullable element types require
   an explicit initializer expression:
   `(table 10 (ref $f) (ref.func $myfunc))`

5. **ref.func precision**: Returns `(ref $t)` where $t is the function's
   declared type (not generic funcref).

## Dependencies

- reference_types (required)
- tail_call (for return_call_ref — can be implemented later)

## Implementation Strategy

1. Extend type system in `types.zig`:
   - Generalize RefType to (nullable?, heaptype)
   - HeapType: func | extern | type_index
2. Update validation in `module.zig`:
   - Track local initialization state per block
   - Validate call_ref/return_call_ref type matching
   - Table initializer expressions
3. Decode new opcodes (0x14, 0x15, 0xd4, 0xd5, 0xd6)
4. Implement in `vm.zig`:
   - call_ref: pop funcref, null-check, invoke
   - ref.as_non_null: pop ref, trap if null
   - br_on_null/br_on_non_null: conditional branch on null
5. JIT: call_ref as direct call when type is known at compile time

## Files to Modify

| File | Changes |
|------|---------|
| types.zig | Generalized RefType, HeapType, nullability |
| module.zig | Decode + validate new opcodes, init tracking, table init |
| predecode.zig | IR opcodes for call_ref, br_on_null |
| vm.zig | Execute 5 new instructions |
| jit.zig | call_ref codegen, null checks |
| instance.zig | Table initialization with expressions |
| spec-support.md | Update |

## Tests

- Spec: function-references/test/core/ — 106 test files
  (full suite with typed ref extensions)
- Key test files: call_ref.wast, ref_as_non_null.wast, br_on_null.wast,
  local_init.wast, table.wast (initializer tests)

## wasmtime Reference

- `cranelift/wasm/src/code_translator.rs` — `translate_call_ref`
- `cranelift/wasm/src/func_translator.rs` — local init tracking
- `cranelift/codegen/src/isa/aarch64/lower.rs` — call_ref lowering
- Cranelift emits `call_indirect` IR with known signature
