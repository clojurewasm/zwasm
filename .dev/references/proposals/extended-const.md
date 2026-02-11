# Extended Constant Expressions

Status: Wasm 3.0 | Repo: memory64 (proposals/extended-const/) | Complexity: trivial
zwasm: todo | Est. LOC: ~50 | Opcodes: 0 new (extends const expr validation)

## What It Adds

Allows `i32.add`, `i32.sub`, `i32.mul` and their i64 counterparts in constant
expressions (global initializers and data/element segment offsets). Previously,
constant expressions could only use `*.const`, `ref.null`, `ref.func`, and
`global.get`.

## New Opcodes

None. The following **existing** opcodes become valid in constant expressions:

| Opcode | Description |
|--------|-------------|
| i32.add | 32-bit integer addition |
| i32.sub | 32-bit integer subtraction |
| i32.mul | 32-bit integer multiplication |
| i64.add | 64-bit integer addition |
| i64.sub | 64-bit integer subtraction |
| i64.mul | 64-bit integer multiplication |

## New Types

None.

## Key Semantic Changes

- Global initializers can now compute `global.get($base) + i32.const(offset)`
- Data segment offsets can reference imported globals with arithmetic
- Primary use case: dynamic linking (`__memory_base + CONST_OFFSET`)
- No runtime behavior change — only validation relaxation

## Dependencies

None.

## Implementation Strategy

1. In `module.zig` constant expression validator, add i32.add/sub/mul and
   i64.add/sub/mul to the allowed opcode set
2. In constant expression evaluator (also `module.zig`), execute these
   opcodes using the existing arithmetic logic
3. No changes to runtime execution or IR

## Files to Modify

| File | Changes |
|------|---------|
| module.zig | Allow 6 arithmetic opcodes in const expr validation + evaluation |
| spec-support.md | Note extended-const support |

## Tests

- Spec: Embedded in existing global/data init tests (no dedicated file)
- Assertions: ~20 (arithmetic in initializers)

## wasmtime Reference

- `cranelift/wasm/src/environ/mod.rs` — `eval_const_expr`
- Straightforward: evaluate arithmetic during module instantiation
