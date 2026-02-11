# Garbage Collection

Status: Wasm 3.0 | Repo: gc | Complexity: very_high
zwasm: todo | Est. LOC: ~3000 | Opcodes: ~32 new

## What It Adds

Managed heap-allocated aggregate types (struct, array) with garbage collection.
Introduces a rich type hierarchy with subtyping, recursive types, casts, and
an unboxed i31 integer type. This is the largest Wasm 3.0 proposal.

## New Opcodes

### Struct Operations (6)

| Opcode | Instruction | Signature |
|--------|-------------|-----------|
| 0xfb00 | struct.new | [field_vals...] -> [(ref $t)] |
| 0xfb01 | struct.new_default | [] -> [(ref $t)] |
| 0xfb02 | struct.get | [(ref null $t)] -> [field_type] |
| 0xfb03 | struct.get_s | [(ref null $t)] -> [i32] (sign-extend packed) |
| 0xfb04 | struct.get_u | [(ref null $t)] -> [i32] (zero-extend packed) |
| 0xfb05 | struct.set | [(ref null $t) val] -> [] |

### Array Operations (14)

| Opcode | Instruction | Signature |
|--------|-------------|-----------|
| 0xfb06 | array.new | [val i32] -> [(ref $t)] |
| 0xfb07 | array.new_default | [i32] -> [(ref $t)] |
| 0xfb08 | array.new_fixed | [val^N] -> [(ref $t)] |
| 0xfb09 | array.new_data | [i32_offset i32_len] -> [(ref $t)] |
| 0xfb0a | array.new_elem | [i32_offset i32_len] -> [(ref $t)] |
| 0xfb0b | array.get | [(ref null $t) i32] -> [elem_type] |
| 0xfb0c | array.get_s | [(ref null $t) i32] -> [i32] |
| 0xfb0d | array.get_u | [(ref null $t) i32] -> [i32] |
| 0xfb0e | array.set | [(ref null $t) i32 val] -> [] |
| 0xfb0f | array.len | [(ref null array)] -> [i32] |
| 0xfb10 | array.fill | [(ref null $t) i32 val i32] -> [] |
| 0xfb11 | array.copy | [(ref null $t1) i32 (ref null $t2) i32 i32] -> [] |
| 0xfb12 | array.init_data | [(ref null $t) i32 i32 i32] -> [] |
| 0xfb13 | array.init_elem | [(ref null $t) i32 i32 i32] -> [] |

### Cast Operations (6)

| Opcode | Instruction | Signature |
|--------|-------------|-----------|
| 0xfb14 | ref.test | [ref] -> [i32] |
| 0xfb15 | ref.test (null) | [ref] -> [i32] |
| 0xfb16 | ref.cast | [ref] -> [ref] (trap on fail) |
| 0xfb17 | ref.cast (null) | [ref] -> [ref] (trap on fail) |
| 0xfb18 | br_on_cast | [t* ref] -> [t* ref] (branch on success) |
| 0xfb19 | br_on_cast_fail | [t* ref] -> [t* ref] (branch on failure) |

### Conversion & Scalar (6)

| Opcode | Instruction | Signature |
|--------|-------------|-----------|
| 0xfb1a | any.convert_extern | [(ref extern)] -> [(ref any)] |
| 0xfb1b | extern.convert_any | [(ref any)] -> [(ref extern)] |
| 0xfb1c | ref.i31 | [i32] -> [(ref i31)] |
| 0xfb1d | i31.get_s | [(ref null i31)] -> [i32] |
| 0xfb1e | i31.get_u | [(ref null i31)] -> [i32] |
| (0xd3) | ref.eq | [eqref eqref] -> [i32] (extends existing) |

## New Types

### Abstract Heap Types

| Type | Description | Supertype |
|------|-------------|-----------|
| any | Top type for all internal references | - |
| eq | Comparable references | any |
| struct | All struct types | eq |
| array | All array types | eq |
| i31 | Tagged 31-bit integer (unboxed) | eq |
| none | Bottom type (all internal) | everything |
| func | All function types | - |
| nofunc | Bottom function type | func |
| extern | External references | - |
| noextern | Bottom external type | extern |

### Composite Types

- **struct**: Heterogeneous fields, static indexing
  `(type $point (struct (field $x f64) (field $y f64)))`
- **array**: Homogeneous elements, dynamic indexing
  `(type $vec (array (mut f64)))`

### Storage Types

- `i8` and `i16`: Packed storage types for struct fields and array elements
- Only accessible via `get_s`/`get_u` (sign/zero extension)

### Recursive Type Groups

`(rec (type $a (struct (field (ref $b)))) (type $b (struct (field (ref $a)))))`
Types in a rec group are mutually recursive and form an equivalence unit.

### Subtyping

- Explicit: `(type $sub (sub $super (struct ...)))`
- Width subtyping: struct subtypes can add fields (prefix rule)
- Depth subtyping: field types covary (immutable) or are invariant (mutable)
- `(sub final ...)`: sealed types (default for non-sub declarations)

## Key Semantic Changes

1. **Type section**: Recursive type groups, sub declarations, composite types
2. **Structural type equivalence**: Types compared by structure, not name
3. **Subtype checking**: Runtime for casts, compile-time for validation
4. **Null traps**: struct.get/set on null ref traps (not validation error)
5. **i31ref**: Unboxed tagged integer (avoids heap allocation for small ints)
6. **Defaultability**: `(ref null _)` is defaultable, `(ref _)` is not
7. **Garbage collection**: Runtime must collect unreachable struct/array objects

## Dependencies

- function_references (required — generalized reference types)
- reference_types (required — base ref type support)

## Implementation Strategy

1. **Type system** (~1000 LOC): Recursive types, subtyping, type canonicalization
2. **Object model** (~500 LOC): Struct/array heap allocation, field access
3. **GC implementation** (~500 LOC): Reference counting or mark-sweep
4. **Instructions** (~500 LOC): 32 new opcodes in vm.zig
5. **Validation** (~300 LOC): Subtype checking, cast validation
6. **JIT** (~200 LOC): Struct/array access codegen, GC barriers

## Files to Modify

| File | Changes |
|------|---------|
| types.zig | Recursive types, struct/array/i31, subtyping, heap types |
| module.zig | Type section with rec groups, decode 32 opcodes |
| predecode.zig | IR for struct/array/cast ops |
| vm.zig | Execute all GC instructions |
| jit.zig | Struct/array field access, GC write barriers |
| instance.zig | GC object allocation |
| store.zig | GC heap management |
| gc.zig (new) | Garbage collector implementation |
| spec-support.md | Update |

## Tests

- Spec: gc/test/core/ — 109 test files
- Key: struct.wast, array.wast, ref_cast.wast, br_on_cast.wast,
  i31.wast, type-subtyping.wast, type-rec.wast
- Assertions: 1000+ (type hierarchy, casts, null traps, packed fields)

## wasmtime Reference

- `cranelift/wasm/src/gc/` — GC type layout, barriers
- `crates/runtime/src/gc/` — DRC (deferred reference counting) collector
- `cranelift/codegen/src/isa/aarch64/` — struct/array access lowering
- wasmtime uses DRC by default, optionally switching to null collector
