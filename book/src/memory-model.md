# Memory Model

## Linear memory

Each Wasm module instance has up to one linear memory (or multiple with the multi-memory proposal). Linear memory is a contiguous byte array accessed by Wasm load/store instructions.

### Allocation

- Initial size specified in the module (e.g., 1 page = 64 KiB)
- `memory.grow` extends the memory by the requested number of pages
- Maximum size can be specified in the module or limited by `--max-memory`

### Guard pages

zwasm allocates a 4 GiB + 64 KiB PROT_NONE region beyond the linear memory. Any out-of-bounds access lands in this guard region and is caught by the signal handler, which converts the fault to a Wasm trap. This avoids per-instruction bounds checks for most memory operations.

### Addressing

All memory addresses use u33 arithmetic (32-bit address + 32-bit offset) to prevent overflow. This ensures that `address + offset` never wraps around to access valid memory.

## GC heap

The GC proposal introduces managed heap objects (structs, arrays, i31ref). These live in a separate arena managed by zwasm:

- **Arena allocator**: Objects are allocated from a pre-allocated arena
- **Adaptive threshold**: GC collection triggers based on allocation pressure
- **Reference encoding**: GC references on the operand stack use tagged u64 values

GC objects are not accessible from linear memory and vice versa. They exist in a separate address space.

## Allocator parameterization

zwasm takes a `std.mem.Allocator` at load time. All internal allocations (module metadata, register IR, tables, etc.) go through this allocator. The linear memory itself uses `mmap` directly for guard page support.

This means you can:
- Use a general-purpose allocator for normal usage
- Use an arena allocator for batch processing (load, run, free everything)
- Use a tracking allocator to monitor memory usage
- Use a fixed-buffer allocator for embedded/constrained environments

## Memory limits

| Resource | Default limit | CLI flag |
|----------|--------------|----------|
| Linear memory | Module-defined max | `--max-memory <bytes>` |
| Call stack depth | 1024 | Not configurable |
| Operand stack | Fixed size | Not configurable |
| GC heap | Unbounded (arena) | Not configurable |
