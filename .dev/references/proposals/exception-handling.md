# Exception Handling

Status: Wasm 3.0 | Repo: exception-handling | Complexity: high
zwasm: todo | Est. LOC: ~800 | Opcodes: 3 new + 4 catch clause forms

## What It Adds

Structured exception handling with typed tags. `try_table` blocks catch
exceptions via labeled catch clauses. `throw` raises exceptions with
typed payloads. `throw_ref` rethrows caught exceptions. Introduces `exnref`
reference type and a new Tag section (section 13).

## New Opcodes

| Opcode | Binary | Signature | Description |
|--------|--------|-----------|-------------|
| try_table | 0x1f | [t1*] -> [t2*] | Structured try block with catch clauses |
| throw | 0x08 | [t1* t*] -> [t2*] | Throw exception (stack-polymorphic) |
| throw_ref | 0x0a | [t1* exnref] -> [t2*] | Rethrow from reference (stack-polymorphic) |

Catch clause sub-opcodes (within try_table encoding):

| Code | Form | Stack at label |
|------|------|---------------|
| 0x00 | catch tag label | [tag params...] |
| 0x01 | catch_ref tag label | [tag params... exnref] |
| 0x02 | catch_all label | [] |
| 0x03 | catch_all_ref label | [exnref] |

## New Types

| Type | Binary | Description |
|------|--------|-------------|
| exnref | -0x17 | Exception reference, `(ref null exn)` |
| tag | section 13 | Tag type: function signature with empty results |

Tag section format:
```
section 13: count:u32 (tag_type)^count
tag_type:   attribute:u8(=0) type_index:u32
```

Section order: ... Memory(5) → **Tag(13)** → Global(6) ...
Tags can be imported/exported (external kind = 4).

## Key Semantic Changes

1. **try_table**: Structured control (like block) with catch clauses.
   If exception thrown in body, stack unwinds to try_table entry,
   catch clauses checked in order. First match branches to label
   with appropriate values on stack. Unmatched: implicit rethrow.

2. **throw**: Pops tag parameter values, creates exception, unwinds stack.
   Stack-polymorphic (like unreachable). Tag type must have empty results.

3. **throw_ref**: Pops exnref, rethrows. Null exnref traps.
   Exception identity preserved (same exnref can be rethrown multiple times).

4. **Tag identity**: Tags are unique per module instance. Imported/exported
   tags alias the same tag across modules (matching by identity, not structure).

5. **Traps are NOT caught**: RuntimeError, stack overflow, OOM are not
   exceptions. Only `throw`-created exceptions are catchable.

6. **Exception propagation**: Unwinds call stack until enclosing try_table
   found. If none found, embedder handles (typically terminates).

## Dependencies

None for core exception handling.
GC proposal extends exnref into the heap type hierarchy (exn, noexn).

## Implementation Strategy

1. Add Tag section parsing in `module.zig` (section 13, before globals)
2. Tag import/export support (external kind 4)
3. New opcodes in `opcode.zig` (0x08, 0x0a, 0x1f)
4. try_table decoding: blocktype + vector of catch clauses
5. Exception value: allocate on heap with tag reference + payload values
6. Throw mechanism in `vm.zig`:
   - Unwind frame stack looking for try_table frames
   - Match catch clauses against exception tag
   - Branch to label with appropriate stack values
7. exnref: reference type pointing to caught exception
8. JIT: exception-aware codegen with landing pads

## Files to Modify

| File | Changes |
|------|---------|
| types.zig | Add exnref type, tag type |
| opcode.zig | Add try_table (0x1f), throw (0x08), throw_ref (0x0a) |
| module.zig | Parse Tag section, decode try_table with catch clauses |
| predecode.zig | IR for try_table/throw/throw_ref |
| vm.zig | Exception creation, stack unwinding, catch dispatch |
| jit.zig | Landing pad codegen, exception propagation |
| instance.zig | Tag instantiation, import/export |
| spec-support.md | Update |

## Tests

- Spec: exception-handling/test/core/ — 4 dedicated files:
  tag.wast, throw.wast, throw_ref.wast, try_table.wast
- Also: unwind.wast (stack unwinding behavior)
- Assertions: ~300+ (catch matching, nested try, cross-module tags)

## wasmtime Reference

- `cranelift/wasm/src/code_translator.rs` — `translate_try_table`
- `cranelift/codegen/src/isa/aarch64/` — landing pad generation
- wasmtime uses native platform exception handling (setjmp/longjmp or
  structured exceptions) for stack unwinding
