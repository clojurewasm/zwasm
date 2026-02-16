---
paths:
  - "src/jit.zig"
  - "src/vm.zig"
  - "src/regalloc.zig"
---

# Debug Trace Rules

## Available CLI Tools

```bash
# Trace categories (comma-separated): jit, regir, exec, mem, call
zwasm run module.wasm --trace=jit,exec --invoke func args...

# Dump RegIR for a specific function index (one-shot)
zwasm run module.wasm --dump-regir=N --invoke func args...

# Dump JIT disassembly for a specific function (one-shot)
zwasm run module.wasm --dump-jit=N --invoke func args...

# Combine all
zwasm run module.wasm --trace=jit,regir,exec --dump-regir=5 --dump-jit=5 --invoke func args...
```

## Debugging Workflows

| Symptom                  | First step                        | Then                              |
|--------------------------|-----------------------------------|-----------------------------------|
| **Wrong result**         | `--trace=exec --dump-regir=N`     | Check RegIR correctness           |
| **JIT bail**             | `--trace=jit`                     | Check unsupported opcode          |
| **JIT wrong result**     | `--dump-jit=N`                    | Disassemble, compare with RegIR   |
| **Performance gap**      | `--trace=exec`                    | Verify JIT tier for hot functions  |
| **Memory corruption**    | `--trace=mem`                     | Check grow/fill/copy params       |

## Key Rule

**Use these CLI tools instead of inserting `std.debug.print` statements.**
The trace infrastructure is zero-cost when disabled (single null check per call).
