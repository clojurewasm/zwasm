# FAQ & Troubleshooting

## General

### What Wasm proposals does zwasm support?

All 9 Wasm 3.0 proposals plus threads, wide arithmetic, and custom page sizes. See [Spec Coverage](./spec-coverage.md) for details.

### Does zwasm support Windows?

Yes. zwasm runs on macOS (ARM64), Linux (x86_64 / aarch64) and Windows (x86_64). On POSIX targets the JIT and memory guard pages use mmap / mprotect / signal handlers; on Windows they use VirtualAlloc / VirtualProtect / vectored exception handlers via `kernel32.dll`. CI runs the full test suite on all three target triples; real-world program coverage on Windows is currently 25/25 (the C and C++ subset of the 50-program suite — Go, Rust, and TinyGo provisioning on Windows is tracked as W52).

### Can I use zwasm from C, Python, or other languages?

Yes. zwasm provides a C API (`libzwasm`) that any FFI-capable language can use. Build with `zig build lib` to produce the shared library, then call `zwasm_*` functions via your language's FFI mechanism (e.g., Python `ctypes`, Rust `extern "C"`, Go `cgo`). See [C API & Cross-Language Integration](./c-api.md).

### Can I reduce the binary size?

Yes. Use build-time feature flags to strip features you do not need: `-Djit=false` (no JIT, ≈ −150 KB on Linux), `-Dwat=false` (no WAT parser, ≈ −150 KB). `-Dcomponent=false` is currently a no-op on its own because the Component Model code path is already dead-code-eliminated when not exercised; combining all three produces a ~1.26 MB minimal Linux binary (≈ −19 %). On Mac the equivalent minimal build is around 0.92 MB. See [Build Configuration](./build-configuration.md).

### Can I use zwasm without JIT?

Yes. The register-IR interpreter handles all functions by default. JIT is only triggered once a function reaches `HOT_THRESHOLD = 3` (3 calls or 3 back-edges in a hot loop). To build without JIT entirely, pass `-Djit=false` — this removes the JIT compiler from the binary and saves about 150 KB on the Linux x86_64 build (≈10 %). Short-running scripts that don't tier up will perform identically to the no-JIT build.

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
