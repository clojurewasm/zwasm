# Memory64

Status: Wasm 3.0 | Repo: memory64 | Complexity: high
zwasm: todo | Est. LOC: ~600 | Opcodes: 0 new (extends existing with i64 addresses)

## What It Adds

Extends memory and table types with an address type qualifier (i32 or i64).
When a memory has `addrtype = i64`, all memory instructions use i64 addresses,
memory.size/grow return/take i64, and limits are u64. Also extends tables
similarly (table64). This is a pervasive change affecting all memory access paths.

## New Opcodes

None. Existing instructions change their type signatures based on addrtype:

| Instruction | i32 memory | i64 memory |
|-------------|-----------|-----------|
| t.load memarg | [i32] -> [t] | [i64] -> [t] |
| t.store memarg | [i32 t] -> [] | [i64 t] -> [] |
| memory.size | [] -> [i32] | [] -> [i64] |
| memory.grow | [i32] -> [i32] | [i64] -> [i64] |
| memory.fill | [i32 i32 i32] -> [] | [i64 i32 i64] -> [] |
| memory.copy | [i32 i32 i32] -> [] | [i64 i64 i64] -> [] |
| memory.init | [i32 i32 i32] -> [] | [i64 i32 i32] -> [] |
| call_indirect | [t1* i32] -> [t2*] | [t1* i64] -> [t2*] (table64) |

SIMD and atomic load/store also extended similarly.

## New Types

| Type | Description |
|------|-------------|
| addrtype | `i32` or `i64` — address type qualifier for memory/table |
| memtype | `addrtype limits` (limits become u64 for i64) |
| tabletype | `addrtype limits reftype` |

## Binary Format Changes

Limits encoding extended with new flag bytes:

| Flags | Format | Description |
|-------|--------|-------------|
| 0x00 | n:u32 | i32 addr, min only, unshared |
| 0x01 | n:u32 m:u32 | i32 addr, min+max, unshared |
| 0x04 | n:u64 | i64 addr, min only, unshared |
| 0x05 | n:u64 m:u64 | i64 addr, min+max, unshared |
| 0x06 | n:u64 | i64 addr, min only, shared (with threads) |
| 0x07 | n:u64 m:u64 | i64 addr, min+max, shared (with threads) |

memarg.offset becomes u64. Validation: offset < 2^|addrtype|.

## Key Semantic Changes

- Address type is per-memory (module can mix i32 and i64 memories)
- i64 memory max: 2^48 pages (validation limit, not 2^64)
- memarg.offset: u64 (was u32) — affects binary decoding
- Data segment offset expr must produce addrtype-matching value
- memory.grow on i64: returns 2^64-1 on failure (not -1 as i32)
- Table64: call_indirect and table.* ops use i64 indices

## Dependencies

None (standalone proposal, but interacts with multi-memory and threads).

## Implementation Strategy

1. Extend memory type in `types.zig` to include addrtype field
2. Update limits decoding in `module.zig` to handle flag bytes 0x04-0x07
3. Change memarg decoding to read u64 offset
4. Parameterize all memory access paths by addrtype:
   - vm.zig: pop i32 or i64 address based on memory's addrtype
   - Bounds checking: extend to 64-bit arithmetic
5. Update memory.size/grow to return/take i64
6. Table64: extend table indices to i64 where addrtype = i64
7. JIT: 64-bit address calculation (already native on ARM64)

## Files to Modify

| File | Changes |
|------|---------|
| types.zig | Add addrtype to MemoryType, TableType |
| module.zig | Decode limits flags 0x04-0x07, u64 memarg.offset |
| predecode.zig | Parameterize memory IR by addrtype |
| vm.zig | i64 address pop/push, 64-bit bounds check |
| jit.zig | 64-bit address calculation |
| instance.zig | Memory instantiation with u64 limits |
| store.zig | Memory with u64 size tracking |
| memory.zig | Extend to support >4GB memories |
| spec-support.md | Update |

## Tests

- Spec: memory64/test/core/memory64.wast (~206 lines),
  float_memory64.wast (~158 lines)
- Assertions: ~100+ (i64 loads/stores, size/grow, validation)

## wasmtime Reference

- `cranelift/wasm/src/environ/mod.rs` — `memory_style`, heap type selection
- `cranelift/codegen/src/isa/aarch64/lower.rs` — 64-bit heap addr
- Cranelift: memory64 uses `heap_addr` with 64-bit offsets natively
