# zwasm Error Reference

Catalog of all error types in the public API and internal subsystems.

## Error Layers

```
Format (leb128)  →  Decode (module)  →  Validate  →  Predecode/Regalloc  →  Runtime (vm)
   Overflow         InvalidWasm        TypeMismatch    UnsupportedSimd      Trap
   EndOfStream      MalformedModule    UnknownLabel    InvalidIR            StackOverflow
                                                                            OOB, etc.
```

## 1. WasmError (vm.zig:35)

The primary runtime error type. Returned from `Vm.invoke()`, `Vm.callFunction()`.

### Trap errors (spec-defined)
| Variant | Meaning |
|---------|---------|
| Trap | Explicit `unreachable` instruction |
| StackOverflow | Call depth exceeded 1024 |
| DivisionByZero | Integer division by zero |
| IntegerOverflow | Integer truncation overflow (trunc_sat) |
| InvalidConversion | Float-to-int conversion out of range |
| OutOfBoundsMemoryAccess | Memory load/store outside bounds |
| UndefinedElement | Table element is null or uninitialized |
| MismatchedSignatures | call_indirect type mismatch |
| Unreachable | Unreachable code executed |
| WasmException | Exception thrown via throw/throw_ref |

### Resource errors
| Variant | Meaning |
|---------|---------|
| OutOfMemory | Allocator failed |
| MemoryLimitExceeded | Memory grow exceeded limit |
| TableLimitExceeded | Table grow exceeded limit |
| FuelExhausted | Instruction fuel limit hit |

### Index errors
| Variant | Meaning |
|---------|---------|
| FunctionIndexOutOfBounds | Function index invalid |
| MemoryIndexOutOfBounds | Memory index invalid |
| TableIndexOutOfBounds | Table index invalid |
| GlobalIndexOutOfBounds | Global index invalid |
| ElemIndexOutOfBounds | Element segment index invalid |
| DataIndexOutOfBounds | Data segment index invalid |
| BadFunctionIndex | Store function address invalid |
| BadMemoryIndex | Store memory address invalid |
| BadTableIndex | Store table address invalid |
| BadGlobalIndex | Store global address invalid |
| BadElemAddr | Element segment address invalid |
| BadDataAddr | Data segment address invalid |
| InvalidTypeIndex | Type index out of range |

### Decode/instantiation errors
| Variant | Meaning |
|---------|---------|
| InvalidWasm | Invalid binary format |
| InvalidInitExpr | Invalid constant expression |
| ImportNotFound | Required import not provided |
| ModuleNotDecoded | Module.decode() not called |
| FunctionCodeMismatch | Function section count != code section count |
| EndOfStream | Unexpected end of binary |
| Overflow | LEB128 value overflow |
| OutOfBounds | Generic out-of-bounds |
| FileNotFound | File not found (CLI) |

### Stack errors
| Variant | Meaning |
|---------|---------|
| StackUnderflow | Value stack underflow |
| LabelStackUnderflow | Label stack underflow |
| OperandStackUnderflow | Operand stack underflow |

### Internal
| Variant | Meaning |
|---------|---------|
| JitRestart | JIT compilation triggered (not user-visible) |

## 2. ValidateError (validate.zig:39)

Returned from module validation. Caught during `Module.decode()` → `validateModule()`.

| Variant | Meaning |
|---------|---------|
| TypeMismatch | Operand type mismatch |
| InvalidAlignment | Memory alignment invalid |
| InvalidLaneIndex | SIMD lane out of range |
| UnknownLocal | Local index out of range |
| UninitializedLocal | Local used before set |
| UnknownGlobal | Global index out of range |
| UnknownFunction | Function index out of range |
| UnknownType | Type index out of range |
| UnknownTable | Table index out of range |
| UnknownMemory | Memory index out of range |
| UnknownLabel | Branch label out of range |
| UnknownDataSegment | Data segment index out of range |
| UnknownElemSegment | Element segment index out of range |
| ImmutableGlobal | Attempt to set immutable global |
| InvalidResultArity | Result count mismatch |
| ConstantExprRequired | Non-constant expression in init |
| DataCountRequired | DataCount section missing |
| IllegalOpcode | Opcode not allowed in context |
| DuplicateExportName | Duplicate export name |
| DuplicateStartSection | Multiple start sections |

## 3. Subsystem Errors

### PredecodeError (predecode.zig:64)
| Variant | Meaning |
|---------|---------|
| UnsupportedSimd | SIMD instruction not handled by IR |
| InvalidWasm | Invalid bytecode structure |

### ConvertError (regalloc.zig:138)
| Variant | Meaning |
|---------|---------|
| Unsupported | IR pattern not supported for register allocation |
| InvalidIR | Malformed intermediate representation |

### WatError (wat.zig:14)
| Variant | Meaning |
|---------|---------|
| WatNotEnabled | WAT parser disabled at compile time (-Dwat=false) |
| InvalidWat | WAT syntax error |

## 4. Public API Error Surfaces

### WasmModule.load() (types.zig)
Returns inferred error union. Common errors:
- InvalidWasm, FunctionCodeMismatch (decode)
- ValidateError variants (validation)
- OutOfMemory (allocation)

### Instance.instantiate() (instance.zig)
Returns inferred error union. Common errors:
- ImportNotFound, InvalidTypeIndex (linking)
- OutOfBoundsMemoryAccess (data/element segment init)
- OutOfMemory (allocation)

### Vm.invoke() (vm.zig)
Returns `WasmError!void`. Any WasmError variant possible.
Most common runtime errors:
- Trap, OutOfBoundsMemoryAccess, StackOverflow
- MismatchedSignatures, UndefinedElement
- WasmException (if module uses exception handling)
