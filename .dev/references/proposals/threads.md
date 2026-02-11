# Threads

Status: Phase 4 (not yet ratified) | Repo: threads | Complexity: very_high
zwasm: todo | Est. LOC: ~1500 | Opcodes: ~68 new

## What It Adds

Shared linear memory with atomic operations, wait/notify synchronization,
and a memory fence instruction. Enables multi-threaded Wasm execution when
combined with a host threading model. All atomic opcodes use the 0xFE prefix.

## New Opcodes

### Control (4)

| Opcode | Instruction | Signature |
|--------|-------------|-----------|
| 0xFE 0x00 | memory.atomic.notify | [i32 i32] -> [i32] |
| 0xFE 0x01 | memory.atomic.wait32 | [i32 i32 i64] -> [i32] |
| 0xFE 0x02 | memory.atomic.wait64 | [i32 i64 i64] -> [i32] |
| 0xFE 0x03 | atomic.fence | [] -> [] |

### Atomic Loads (7)

| Opcode | Instruction | Signature |
|--------|-------------|-----------|
| 0xFE 0x10 | i32.atomic.load | [i32] -> [i32] |
| 0xFE 0x11 | i64.atomic.load | [i32] -> [i64] |
| 0xFE 0x12 | i32.atomic.load8_u | [i32] -> [i32] |
| 0xFE 0x13 | i32.atomic.load16_u | [i32] -> [i32] |
| 0xFE 0x14 | i64.atomic.load8_u | [i32] -> [i64] |
| 0xFE 0x15 | i64.atomic.load16_u | [i32] -> [i64] |
| 0xFE 0x16 | i64.atomic.load32_u | [i32] -> [i64] |

### Atomic Stores (7)

| Opcode | Instruction | Signature |
|--------|-------------|-----------|
| 0xFE 0x17 | i32.atomic.store | [i32 i32] -> [] |
| 0xFE 0x18 | i64.atomic.store | [i32 i64] -> [] |
| 0xFE 0x19 | i32.atomic.store8 | [i32 i32] -> [] |
| 0xFE 0x1A | i32.atomic.store16 | [i32 i32] -> [] |
| 0xFE 0x1B | i64.atomic.store8 | [i32 i64] -> [] |
| 0xFE 0x1C | i64.atomic.store16 | [i32 i64] -> [] |
| 0xFE 0x1D | i64.atomic.store32 | [i32 i64] -> [] |

### Atomic RMW (42 = 7 ops x 6 widths)

Operations: add, sub, and, or, xor, xchg (exchange)
Widths: i32 (full, 8_u, 16_u), i64 (full, 8_u, 16_u, 32_u)

| Range | Operation |
|-------|-----------|
| 0xFE 0x1E-0x24 | *.atomic.rmw*.add_u |
| 0xFE 0x25-0x2B | *.atomic.rmw*.sub_u |
| 0xFE 0x2C-0x32 | *.atomic.rmw*.and_u |
| 0xFE 0x33-0x39 | *.atomic.rmw*.or_u |
| 0xFE 0x3A-0x40 | *.atomic.rmw*.xor_u |
| 0xFE 0x41-0x47 | *.atomic.rmw*.xchg_u |

All RMW: read old value, apply op, store new value, return old value.

### Atomic Compare-Exchange (7)

| Range | Operation |
|-------|-----------|
| 0xFE 0x48-0x4E | *.atomic.rmw*.cmpxchg_u |

cmpxchg: if mem[addr] == expected, write new; return old value.

## New Types

| Type | Description |
|------|-------------|
| shared memory | Memory with `shared` flag in limits |

Binary encoding extends limits:
- 0x03 n:u32 m:u32 → shared memory with min n, max m (max required)

## Key Semantic Changes

1. **Shared memory**: `(memory 1 10 shared)` — accessible from multiple threads
2. **Alignment**: Atomic ops MUST be naturally aligned (misalignment traps)
3. **Sequential consistency**: All atomic ops are sequentially consistent
4. **wait32/wait64**: Block until notified or timeout. Returns 0 (notified),
   1 (value mismatch), 2 (timeout). Traps on non-shared memory.
5. **notify**: Wake up to N waiters at address. Returns count woken.
   Works on non-shared memory (returns 0, no waiters possible).
6. **fence**: Memory barrier, no memory operand. Synchronizes across memories.
7. **memory.grow**: Sequentially consistent on shared memory.
8. **Data init**: Non-atomic byte-by-byte on shared memory during instantiation.

## Dependencies

None for core atomics. Interacts with memory64 (i64 addresses for atomics).

## Implementation Strategy

For a single-threaded runtime like zwasm, atomics can be implemented as
regular memory operations (no contention). Shared memory flag accepted
but threading not actually provided.

1. Add 68 opcodes to `opcode.zig` (0xFE prefix)
2. Decode: memarg + alignment check (must be natural)
3. Shared memory flag in limits decoding
4. Implement atomics as regular load/store in `vm.zig` (single-threaded)
5. wait: return 1 (not-equal) or 2 (timeout=0) always (no real waiters)
6. notify: return 0 always (no real waiters)
7. fence: no-op (single-threaded)
8. JIT: same as regular memory ops (no threading = no barriers needed)

Full threading support (future):
- Zig `std.Thread` for Wasm threads
- Shared memory backed by shared mapping
- Use Zig atomic builtins for atomic ops
- Futex for wait/notify

## Files to Modify

| File | Changes |
|------|---------|
| opcode.zig | Add ~68 atomic opcodes (0xFE prefix) |
| types.zig | Shared flag on memory type |
| module.zig | Decode atomics, shared memory limits, alignment validation |
| predecode.zig | IR for atomic ops |
| vm.zig | Execute atomics (as regular ops initially) |
| jit.zig | Atomic codegen (regular ops initially) |
| spec-support.md | Update |

## Tests

- Spec: threads/test/core/threads/ — 13 test files
  (atomic.wast, wait_notify.wast, thread.wast, memory ordering tests)
- Assertions: ~200+ (alignment traps, shared validation, RMW correctness)

## wasmtime Reference

- `cranelift/codegen/src/isa/aarch64/lower.rs` — atomic load/store/RMW
  (LDADD, LDSET, CAS, LDAXR/STLXR for exclusives)
- `crates/runtime/src/threads/` — shared memory, parking lot for wait/notify
- ARM64 uses LSE atomics when available, otherwise LL/SC loops
