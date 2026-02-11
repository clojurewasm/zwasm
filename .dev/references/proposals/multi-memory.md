# Multiple Memories

Status: Wasm 3.0 | Repo: multi-memory | Complexity: medium
zwasm: todo | Est. LOC: ~400 | Opcodes: 0 new (extends existing with memidx)

## What It Adds

Removes the restriction that a module can define/import at most one memory.
All memory-related instructions gain an optional memory index immediate
(default 0 for backward compatibility). Symmetric with multi-table from
the reference-types proposal.

## New Opcodes

None. All existing memory instructions are extended with a memidx immediate:

| Category | Instructions Extended |
|----------|---------------------|
| Load | i32.load, i64.load, f32.load, f64.load + all load8/16/32 variants |
| Store | i32.store, i64.store, f32.store, f64.store + all store8/16/32 variants |
| Memory mgmt | memory.size, memory.grow |
| Bulk | memory.copy (dst + src memidx), memory.fill, memory.init |
| SIMD | v128.load, v128.store + all lane/splat/zero variants |

## New Types

None.

## Key Semantic Changes

- Multiple memory definitions and imports allowed per module
- Binary format: memarg bit 6 (in first LEB byte) signals presence of memidx
  after alignment+offset. When bit 6 is clear, memidx defaults to 0.
- memory.copy takes TWO memidx: destination and source (cross-memory copy)
- Data segments specify which memory they belong to
- Text format: optional memidx appears before offset/align keywords
- Each memory instance is fully independent (separate linear address space)

## Dependencies

- bulk_memory (for memory.copy/fill/init extensions)

## Implementation Strategy

1. Remove single-memory validation check in `module.zig`
2. Extend `memarg` decoding to check bit 6 and read memidx
3. Change `Instance` to hold `memories: []Memory` (already a slice? check)
4. All memory access paths in `vm.zig` must index into memories array
5. Update `memory.copy` to take dst/src memidx pair
6. Data segment linking: associate each segment with its memory index
7. Update JIT memory access to load base pointer from correct memory slot

## Files to Modify

| File | Changes |
|------|---------|
| module.zig | Remove single-memory limit, decode memidx, data segment memory |
| predecode.zig | Encode memidx in IR memory instructions |
| vm.zig | Index into memories array for all memory ops |
| jit.zig | Load memory base from indexed slot |
| instance.zig | Multiple memory instantiation |
| store.zig | Multiple memory management |
| spec-support.md | Update |

## Tests

- Spec: multi-memory/test/core/multi-memory/ — 37 dedicated test files
  (load, store, memory_size, memory_copy, imports, linking, traps, SIMD)
- Assertions: ~500+

## wasmtime Reference

- `cranelift/wasm/src/environ/mod.rs` — `heaps` array (one per memory)
- Memory base pointer loaded per-access from `VMContext::memories[idx]`
- `cranelift/codegen/src/isa/aarch64/lower.rs` — heap addr computation
