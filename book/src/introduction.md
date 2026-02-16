# zwasm

A standalone WebAssembly runtime written in Zig. Runs Wasm modules as a CLI tool or embeds as a Zig library.

## Features

- **Full Wasm 3.0 support**: Core spec + 9 proposals (GC, exception handling, tail calls, SIMD, threads, and more)
- **62,158 spec tests passing**: 100% on macOS ARM64 and Linux x86_64
- **4-tier execution**: Interpreter with register IR and ARM64/x86_64 JIT compilation
- **WASI Preview 1**: 46 syscalls with deny-by-default capability model
- **Small footprint**: 1.28 MB binary, 3.57 MB runtime memory
- **Library and CLI**: Use as a `zig build` dependency or run modules from the command line
- **WAT support**: Run `.wat` text format files directly

## Quick Start

```bash
# Run a WebAssembly module
zwasm hello.wasm

# Invoke a specific function
zwasm math.wasm --invoke add 2 3

# Run a WAT text file
zwasm program.wat
```

See [Getting Started](./getting-started.md) for installation instructions.
