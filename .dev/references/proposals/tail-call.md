# Tail Call

Status: Wasm 3.0 | Repo: tail-call | Complexity: medium
zwasm: todo | Est. LOC: ~200 | Opcodes: 2 new

## What It Adds

Guaranteed tail call elimination via two new instructions. The callee reuses
the caller's stack frame, enabling unbounded mutual recursion without stack
overflow. Cross-module tail calls are guaranteed by the spec.

## New Opcodes

| Opcode | Binary | Signature | Description |
|--------|--------|-----------|-------------|
| return_call | 0x12 | [t3* t1*] -> [t4*] | Tail call to function by index |
| return_call_indirect | 0x13 | [t3* t1* i32] -> [t4*] | Tail call via table lookup |

Both instructions are **stack-polymorphic**: they pop call operands, unwind
the stack frame (like `return`), push operands back, then delegate to the
regular call semantics.

## New Types

None. The CG resolved that tail-callable functions do NOT need distinct types.

## Key Semantic Changes

- Caller and callee types can differ (parameter types need not match)
- Stack frame is popped before the callee is invoked
- Callee may be dynamic (call_indirect variant)
- Cross-module tail calls guaranteed; host function tail calls are not
- function-references proposal will later add `return_call_ref` (0x15)

## Dependencies

- None for core tail-call
- function-references: adds `return_call_ref` (implement later)

## Implementation Strategy

1. Add opcodes to `opcode.zig` (0x12, 0x13)
2. Decode in `module.zig` — same immediates as call/call_indirect
3. Validate in `module.zig` — stack-polymorphic typing, check return type match
4. Predecode in `predecode.zig` — emit tail-call IR variants
5. Execute in `vm.zig` — pop current frame, set up callee params, jump
   (instead of pushing new frame)
6. JIT in `jit.zig` — reuse frame: move args to param slots, jump to callee
   entry (not call). For call_indirect, resolve table first then tail-jump.

## Files to Modify

| File | Changes |
|------|---------|
| opcode.zig | Add return_call (0x12), return_call_indirect (0x13) |
| module.zig | Decode + validate tail call instructions |
| predecode.zig | New IR opcodes for tail call variants |
| vm.zig | Execute: frame reuse instead of push |
| jit.zig | Tail-jump codegen (no link register save) |
| spec-support.md | Update opcode count |

## Tests

- Spec: tail-call/test/core/return_call.wast, return_call_indirect.wast
- Assertions: ~100+ (mutual recursion, type mismatch, indirect)

## wasmtime Reference

- `cranelift/codegen/src/isa/aarch64/lower.rs` — tail call lowering
- `cranelift/wasm/src/code_translator.rs` — `translate_return_call`
- Cranelift uses `return_call` IR opcode with special ABI handling
