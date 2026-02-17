# Comparison

How zwasm compares to other WebAssembly runtimes.

## Overview

| Feature | zwasm | wasmtime | wasm3 | wasmer |
|---------|-------|----------|-------|--------|
| Language | Zig | Rust | C | Rust/C |
| Binary size | 1.3 MB | 56 MB | ~100 KB | 30+ MB |
| Memory (fib) | 3.5 MB | 12 MB | ~1 MB | 15+ MB |
| Execution | Interp + JIT | AOT/JIT | Interpreter | AOT/JIT |
| Wasm 3.0 | Full | Full | Partial | Partial |
| GC proposal | Yes | Yes | No | No |
| SIMD | Full (256 ops) | Full | Partial | Full |
| WASI | P1 (46 syscalls) | P1 + P2 | P1 (partial) | P1 + P2 |
| Platforms | macOS, Linux | macOS, Linux, Windows | Many (no JIT) | macOS, Linux, Windows |

## When to choose zwasm

**Small footprint**: When binary size and memory usage matter. zwasm is 44x smaller than wasmtime.

**Zig ecosystem**: When embedding in a Zig application. zwasm integrates as a native `zig build` dependency with zero C dependencies.

**Spec completeness**: When you need full Wasm 3.0 support including GC, SIMD, threads, and exception handling in a small runtime.

**Fast startup**: The interpreter starts executing immediately. JIT compilation happens in the background for hot functions.

## When to choose alternatives

**Maximum throughput**: wasmtime's Cranelift AOT compiler produces highly optimized native code. For long-running compute-heavy workloads, wasmtime may be faster.

**Windows support**: zwasm currently supports macOS and Linux. For Windows, use wasmtime or wasmer.

**Minimal size**: wasm3 is ~100 KB and runs on microcontrollers. If you need the absolute smallest runtime without JIT, wasm3 may be a better fit.

**WASI Preview 2**: wasmtime has the most complete WASI P2 implementation. zwasm's P2 support is via a P1 adapter layer.
