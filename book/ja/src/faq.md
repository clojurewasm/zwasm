# FAQ & Troubleshooting

## General

### What Wasm proposals does zwasm support?

All 9 Wasm 3.0 proposals plus threads, wide arithmetic, and custom page sizes. See [Spec Coverage](./spec-coverage.md) for details.

### Does zwasm support Windows?

Not currently. zwasm runs on macOS (ARM64) and Linux (x86_64, aarch64). The JIT and memory guard pages use POSIX APIs (mmap, mprotect, signal handlers).

### Can I use zwasm without JIT?

Yes. The interpreter handles all functions by default. JIT is only triggered for hot functions. There is no way to disable JIT for specific functions, but functions that are called fewer than ~8 times will always use the interpreter.

### What is the WAT parser?

zwasm can run `.wat` text format files directly: `zwasm run program.wat`. The WAT parser can be disabled at compile time with `-Dwat=false` to reduce binary size.

## Troubleshooting

### "trap: out-of-bounds memory access"

The Wasm module tried to read or write memory outside its linear memory bounds. This is a bug in the Wasm module, not in zwasm. Check that the module's memory is large enough for its data.

### "trap: call stack overflow (depth > 1024)"

Recursive function calls exceeded the 1024 depth limit. This is typically caused by infinite recursion in the Wasm module.

### "required import not found"

The module requires an import that was not provided. Use `zwasm inspect` to see what imports the module needs, then provide them with `--link` or host functions.

### "invalid wasm binary"

The file is not a valid WebAssembly binary. Check that it starts with the magic bytes `\0asm` and version `\01\00\00\00`. WAT files should use the `.wat` extension.

### Slow performance

- Make sure you build with `zig build -Doptimize=ReleaseSafe`. Debug builds are 5-10x slower.
- Hot functions (called many times) are JIT-compiled automatically. Short-running programs may not benefit from JIT.
- Use `--profile` to see opcode frequency and call counts.

### High memory usage

- Every Wasm module with linear memory allocates guard pages (~4 GiB virtual, not physical). This is normal and shows up as large VSIZE but small RSS.
- Use `--max-memory` to cap the actual memory a module can allocate.
