# C API & Cross-Language Integration

The [Embedding Guide](./embedding-guide.md) showed how to use zwasm from Zig. But zwasm is also a C library — any language with a C FFI can load and run WebAssembly modules through it. This chapter covers the C API: building the shared library, calling it from C and Python, and working with host functions, WASI, and memory.

## Building the library

```bash
zig build lib                              # Build libzwasm (.dylib / .so / .a)
zig build lib -Doptimize=ReleaseSafe       # Optimized build
```

This produces:

| Output | Path |
|--------|------|
| Shared library | `zig-out/lib/libzwasm.dylib` (macOS) or `libzwasm.so` (Linux) |
| Static library | `zig-out/lib/libzwasm.a` |
| C header | `include/zwasm.h` |

The header file `include/zwasm.h` is the single source of truth for the C API. All types are opaque pointers; all functions use the `zwasm_` prefix.

## Quickstart: C

Load a module, invoke an exported function, and read the result:

```c
#include <stdio.h>
#include "zwasm.h"

/* Wasm module: (func (export "f") (result i32) (i32.const 42)) */
static const uint8_t WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b
};

int main(void) {
    zwasm_module_t *mod = zwasm_module_new(WASM, sizeof(WASM));
    if (!mod) {
        fprintf(stderr, "Error: %s\n", zwasm_last_error_message());
        return 1;
    }

    uint64_t results[1] = {0};
    if (!zwasm_module_invoke(mod, "f", NULL, 0, results, 1)) {
        fprintf(stderr, "Invoke error: %s\n", zwasm_last_error_message());
        zwasm_module_delete(mod);
        return 1;
    }

    printf("f() = %llu\n", (unsigned long long)results[0]);

    zwasm_module_delete(mod);
    return 0;
}
```

Build and run:

```bash
zig build lib && zig build c-test
./zig-out/bin/example_c_hello
# f() = 42
```

## Quickstart: Python (ctypes)

The same workflow using Python's built-in `ctypes` module — no compiled bindings required:

```python
import ctypes, os

lib = ctypes.CDLL("zig-out/lib/libzwasm.dylib")  # or .so on Linux

# Declare function signatures
lib.zwasm_module_new.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.zwasm_module_new.restype = ctypes.c_void_p
lib.zwasm_module_delete.argtypes = [ctypes.c_void_p]
lib.zwasm_module_delete.restype = None
lib.zwasm_module_invoke.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32,
    ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32,
]
lib.zwasm_module_invoke.restype = ctypes.c_bool
lib.zwasm_last_error_message.argtypes = []
lib.zwasm_last_error_message.restype = ctypes.c_char_p

# Same Wasm bytes as the C example
wasm = bytes([
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f,
    0x03, 0x02, 0x01, 0x00,
    0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,
    0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
])

mod = lib.zwasm_module_new(wasm, len(wasm))
assert mod, f"Error: {lib.zwasm_last_error_message().decode()}"

results = (ctypes.c_uint64 * 1)(0)
ok = lib.zwasm_module_invoke(mod, b"f", None, 0, results, 1)
assert ok, f"Invoke error: {lib.zwasm_last_error_message().decode()}"

print(f"f() = {results[0]}")  # f() = 42

lib.zwasm_module_delete(mod)
```

Run:

```bash
zig build lib
python3 examples/python/basic.py
```

## Quickstart: Rust (FFI)

Rust can call the same C API via `extern "C"` bindings:

```rust
#[link(name = "zwasm")]
unsafe extern "C" {
    fn zwasm_module_new(wasm_ptr: *const u8, len: usize) -> *mut zwasm_module_t;
    fn zwasm_module_invoke(
        module: *mut zwasm_module_t, name: *const std::ffi::c_char,
        args: *const u64, nargs: u32, results: *mut u64, nresults: u32,
    ) -> bool;
    fn zwasm_module_delete(module: *mut zwasm_module_t);
}
```

Build and run (requires Rust 1.85+ for edition 2024):

```bash
zig build shared-lib
cd examples/rust && cargo run
# f() = 42
```

See `examples/rust/` for the full working example.

## API reference

Functions are grouped by domain. All signatures live in `include/zwasm.h`.

### Error handling

| Function | Description |
|----------|-------------|
| `zwasm_last_error_message()` | Last error as a null-terminated string. Returns `""` if no error. Thread-local. |

### Runtime configuration

| Function | Description |
|----------|-------------|
| `zwasm_config_new()` | Create a runtime config handle. |
| `zwasm_config_delete(config)` | Free a runtime config handle. |
| `zwasm_config_set_allocator(config, alloc_fn, free_fn, ctx)` | Set custom allocator callbacks for runtime bookkeeping memory. |
| `zwasm_config_set_fuel(config, fuel)` | Set instruction fuel limit. |
| `zwasm_config_set_timeout(config, timeout_ms)` | Set wall-clock timeout in milliseconds. |
| `zwasm_config_set_max_memory(config, max_memory_bytes)` | Set linear-memory growth ceiling in bytes. |
| `zwasm_config_set_force_interpreter(config, force_interpreter)` | Disable RegIR/JIT and force interpreter-only execution. |
| `zwasm_config_set_cancellable(config, enabled)` | Enable/disable periodic JIT cancellation checks. |

### Module lifecycle

| Function | Description |
|----------|-------------|
| `zwasm_module_new(wasm_ptr, len)` | Create module from binary bytes. Returns `NULL` on error. |
| `zwasm_module_new_wasi(wasm_ptr, len)` | Create WASI module with default capabilities. |
| `zwasm_module_new_wasi_configured(wasm_ptr, len, config)` | Create WASI module with custom config. |
| `zwasm_module_new_with_imports(wasm_ptr, len, imports)` | Create module with host function imports. |
| `zwasm_module_new_configured(wasm_ptr, len, config)` | Create module with optional runtime config. |
| `zwasm_module_new_wasi_configured2(wasm_ptr, len, wasi_config, config)` | Create WASI module with both WASI config and runtime config. |
| `zwasm_module_delete(module)` | Free all module resources. |
| `zwasm_module_validate(wasm_ptr, len)` | Validate binary without instantiation. |

### Function invocation

| Function | Description |
|----------|-------------|
| `zwasm_module_invoke(module, name, args, nargs, results, nresults)` | Invoke an exported function by name. |
| `zwasm_module_invoke_start(module)` | Invoke `_start` (WASI entry point). |
| `zwasm_module_cancel(module)` | Request cancellation of a currently running invocation (thread-safe). |

### Export introspection

| Function | Description |
|----------|-------------|
| `zwasm_module_export_count(module)` | Number of exported functions. |
| `zwasm_module_export_name(module, idx)` | Name of the idx-th export. |
| `zwasm_module_export_param_count(module, idx)` | Parameter count of an export. |
| `zwasm_module_export_result_count(module, idx)` | Result count of an export. |

### Memory access

| Function | Description |
|----------|-------------|
| `zwasm_module_memory_data(module)` | Direct pointer to linear memory. Invalidated by growth. |
| `zwasm_module_memory_size(module)` | Current memory size in bytes. |
| `zwasm_module_memory_read(module, offset, len, out_buf)` | Safe bounded read. |
| `zwasm_module_memory_write(module, offset, data, len)` | Safe bounded write. |

### WASI configuration

| Function | Description |
|----------|-------------|
| `zwasm_wasi_config_new()` | Create a config handle. |
| `zwasm_wasi_config_delete(config)` | Free a config handle. |
| `zwasm_wasi_config_set_argv(config, argc, argv)` | Set command-line arguments. |
| `zwasm_wasi_config_set_env(config, count, keys, key_lens, vals, val_lens)` | Set environment variables. |
| `zwasm_wasi_config_preopen_dir(config, host_path, host_len, guest_path, guest_len)` | Map a host directory. |

### Host function imports

| Function | Description |
|----------|-------------|
| `zwasm_import_new()` | Create an import collection. |
| `zwasm_import_delete(imports)` | Free an import collection. |
| `zwasm_import_add_fn(imports, module, name, callback, env, params, results)` | Register a host function. |

## Value encoding

Wasm values are passed as `uint64_t` arrays. The encoding matches the raw Wasm value representation:

| Wasm type | C encoding | Notes |
|-----------|-----------|-------|
| `i32` | Zero-extended to `uint64_t` | Upper 32 bits are zero |
| `i64` | Direct `uint64_t` | No conversion needed |
| `f32` | IEEE 754 bits, zero-extended | Use `memcpy` to a `float`, not a cast |
| `f64` | IEEE 754 bits as `uint64_t` | Use `memcpy` to a `double`, not a cast |

Example — passing an `f64` argument:

```c
double val = 3.14;
uint64_t arg;
memcpy(&arg, &val, sizeof(arg));

uint64_t result[1];
zwasm_module_invoke(mod, "sqrt", &arg, 1, result, 1);

double out;
memcpy(&out, &result[0], sizeof(out));
```

## Host functions

A host function is a C callback that the Wasm module can call as an import.

Callback signature:

```c
typedef bool (*zwasm_host_fn_callback_t)(
    void *env,              /* User context pointer */
    const uint64_t *args,   /* Input parameters */
    uint64_t *results       /* Output buffer */
);
```

Working example — a `print_i32` host function:

```c
#include <stdio.h>
#include "zwasm.h"

static bool print_i32(void *env, const uint64_t *args, uint64_t *results) {
    (void)env;
    (void)results;
    printf("wasm says: %d\n", (int32_t)args[0]);
    return true;
}

int main(void) {
    zwasm_imports_t *imports = zwasm_import_new();
    zwasm_import_add_fn(imports, "env", "print_i32", print_i32, NULL, 1, 0);

    zwasm_module_t *mod = zwasm_module_new_with_imports(wasm_bytes, wasm_len, imports);
    /* ... invoke, then cleanup ... */
    zwasm_module_delete(mod);
    zwasm_import_delete(imports);
}
```

The `env` pointer lets you pass arbitrary context (a struct, file handle, etc.) to the callback without globals.

## WASI programs

Use a `zwasm_wasi_config_t` for argv/env/preopens, and optionally combine it with `zwasm_config_t` for fuel/timeout/memory limits:

```c
/* Create and configure WASI */
zwasm_wasi_config_t *wasi_config = zwasm_wasi_config_new();

const char *argv[] = {"myapp", "--verbose"};
zwasm_wasi_config_set_argv(wasi_config, 2, argv);

zwasm_wasi_config_preopen_dir(wasi_config, "/tmp/data", 9, "/data", 5);

/* Optional runtime config */
zwasm_config_t *config = zwasm_config_new();
zwasm_config_set_fuel(config, 1000000);
zwasm_config_set_timeout(config, 1000);
zwasm_config_set_max_memory(config, 256 * 1024 * 1024);

/* Create module with both configs */
zwasm_module_t *mod = zwasm_module_new_wasi_configured2(
    wasm_bytes, wasm_len, wasi_config, config
);

/* Run the program */
zwasm_module_invoke_start(mod);

/* Cleanup */
zwasm_module_delete(mod);
zwasm_config_delete(config);
zwasm_wasi_config_delete(wasi_config);
```

For simple WASI programs that only need default capabilities (stdio, clock, random):

```c
zwasm_module_t *mod = zwasm_module_new_wasi(wasm_bytes, wasm_len);
zwasm_module_invoke_start(mod);
zwasm_module_delete(mod);
```

## Thread safety

- **Error buffer**: `zwasm_last_error_message()` returns a thread-local buffer. Safe to call from multiple threads.
- **Modules**: A `zwasm_module_t` is **not** thread-safe. Do not invoke functions on the same module from multiple threads concurrently. Create separate module instances per thread instead.
- **Cancellation**: `zwasm_module_cancel()` is the only thread-safe operation and may be called from another thread to interrupt a running invocation.

## Next steps

- [Build Configuration](./build-configuration.md) — customize which features are compiled in
- `examples/c/`, `examples/python/`, and `examples/rust/` — working examples in the repository
- `include/zwasm.h` — the complete C header with doc comments
