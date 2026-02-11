# Branch Hinting

Status: Wasm 3.0 | Repo: memory64 (proposals/branch-hinting/) | Complexity: trivial
zwasm: todo | Est. LOC: ~80 | Opcodes: 0 new (custom section only)

## What It Adds

A custom section `metadata.code.branch_hint` that provides likely/unlikely
hints for `br_if` and `if` instructions. Engines can use these hints for
code layout optimization (improving instruction cache hits) and register
allocation. Hints are purely advisory — no semantic change.

## New Opcodes

None. This proposal only defines a custom section format.

## New Types

None.

## Custom Section Format

Section name: `metadata.code.branch_hint`
Must appear before the code section. Contains:

```
vec(function_hints)
  function_hints := func_index:u32  vec(branch_hint)
  branch_hint    := byte_offset:u32  size:u32(=1)  value:u32
                    value 0 = likely NOT taken
                    value 1 = likely taken
```

Function indices must be in increasing order. Byte offsets within each
function must be in increasing order. Only `br_if` and `if` instructions
are valid hint targets.

## Key Semantic Changes

- No semantic changes — hints are advisory only
- Engines may ignore hints entirely (conformant behavior)
- Text format annotation: `(@metadata.code.branch_hint "\00" | "\01")`

## Dependencies

None.

## Implementation Strategy

1. Parse `metadata.code.branch_hint` custom section in `module.zig`
2. Store hints in a compact per-function lookup (byte_offset -> hint)
3. In JIT codegen (`jit.zig`), use hints for code layout:
   - likely-taken: fall-through to taken path
   - likely-not-taken: fall-through to not-taken path
4. Interpreter can ignore hints (no benefit for interpreter)

## Files to Modify

| File | Changes |
|------|---------|
| module.zig | Parse branch_hint custom section |
| jit.zig | Use hints for conditional branch layout |
| spec-support.md | Note branch-hinting support |

## Tests

- Spec: No dedicated test file (custom sections are optional)
- Validation: hints on non-branch instructions should be ignored

## wasmtime Reference

- `cranelift/wasm/src/sections_translator.rs` — custom section parsing
- Cranelift uses `block_hints` for code layout in `MachBuffer`
