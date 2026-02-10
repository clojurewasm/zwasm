# zwasm

A Zig-native WebAssembly runtime library. Small, fast, embeddable.

> **Status**: Pre-alpha. Extracting from [ClojureWasm](https://github.com/clojurewasm/ClojureWasm)'s battle-tested Wasm interpreter (~11K LOC, 461 opcodes).

## Features

- **461 opcodes**: Full MVP + SIMD (236 v128 instructions)
- **Predecoded IR**: Fixed-width instruction format for cache-friendly dispatch
- **Superinstructions**: 11 fused opcodes for reduced dispatch overhead
- **WASI Preview 1**: ~77% syscall coverage
- **Allocator-parameterized**: Caller controls memory allocation strategy
- **Zero dependencies**: Pure Zig, no libc required

## Build

```bash
zig build        # Build library
zig build test   # Run tests
```

## License

MIT
