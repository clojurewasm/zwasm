# Embedding Guide

How to embed zwasm as a library in your application.

## Zig Embedding

zwasm is a Zig package. Add it to your `build.zig.zon`:

```zig
.dependencies = .{
    .zwasm = .{
        .url = "https://github.com/clojurewasm/zwasm/archive/v1.6.1.tar.gz",
        .hash = "...",
    },
},
```

### Basic Usage

```zig
const std = @import("std");
const zwasm = @import("zwasm");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const wasm_bytes = try std.fs.cwd().readFileAlloc(allocator, "module.wasm", 10 * 1024 * 1024);
    defer allocator.free(wasm_bytes);

    var module = try zwasm.WasmModule.load(allocator, wasm_bytes);
    defer module.deinit();

    var args = [_]u64{ 10, 20 };
    var results = [_]u64{0};
    try module.invoke("add", &args, &results);
    std.debug.print("result: {}\n", .{results[0]});
}
```

### Allocator Ownership

`WasmModule.load(allocator, bytes)` propagates the allocator to all internal
components (Store, Module, Instance, VM, GC heap). The caller owns the
allocator and must keep it alive until `module.deinit()` completes.

This is the Zig-idiomatic approach — the host decides the memory strategy:

```zig
// Arena: batch-free after module lifetime
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
var module = try zwasm.WasmModule.load(arena.allocator(), wasm_bytes);
// No need to call module.deinit() — arena handles it

// GPA: detect leaks in debug builds
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
var module = try zwasm.WasmModule.load(gpa.allocator(), wasm_bytes);
defer module.deinit();
```

## C Embedding

zwasm provides a C API via `include/zwasm.h`. Build the shared library:

```bash
zig build lib              # produces libzwasm (.dll/.lib, .dylib/.a, or .so/.a)
```

### Basic Usage

```c
#include "zwasm.h"
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    FILE *f = fopen("module.wasm", "rb");
    fseek(f, 0, SEEK_END);
    size_t len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(len);
    fread(buf, 1, len, f);
    fclose(f);

    zwasm_module_t *mod = zwasm_module_new(buf, len);
    free(buf);
    if (!mod) {
        fprintf(stderr, "Error: %s\n", zwasm_last_error_message());
        return 1;
    }

    uint64_t args[] = {10, 20};
    uint64_t results[1];
    if (zwasm_module_invoke(mod, "add", args, 2, results, 1)) {
        printf("result: %llu\n", results[0]);
    }

    zwasm_module_delete(mod);
    return 0;
}
```

### Custom Allocator

Inject your own allocator via `zwasm_config_t`:

```c
void *my_alloc(void *ctx, size_t size, size_t alignment) {
    // Your allocator logic here
    return aligned_alloc(alignment, size);
}

void my_free(void *ctx, void *ptr, size_t size, size_t alignment) {
    free(ptr);
}

int main(void) {
    zwasm_config_t *config = zwasm_config_new();
    zwasm_config_set_allocator(config, my_alloc, my_free, NULL);

    zwasm_module_t *mod = zwasm_module_new_configured(wasm_ptr, len, config);
    // ... use module ...
    zwasm_module_delete(mod);
    zwasm_config_delete(config);
}
```

Pass `NULL` for config to use the default internal allocator:

```c
zwasm_module_t *mod = zwasm_module_new_configured(wasm_ptr, len, NULL);
// equivalent to zwasm_module_new(wasm_ptr, len)
```

The custom allocator controls **internal bookkeeping only** (module metadata,
function tables, GC heap, VM state). Wasm linear memory (`memory.grow`) is
separately managed per the Wasm spec.

### Execution Controls (Fuel, Timeout, Cancellation)

`zwasm_config_t` also controls runtime limits and execution behavior:

```c
zwasm_config_t *config = zwasm_config_new();

zwasm_config_set_fuel(config, 1000000);
zwasm_config_set_timeout(config, 5000);        // milliseconds
zwasm_config_set_max_memory(config, 64 * 1024 * 1024);
zwasm_config_set_force_interpreter(config, false);

// Default is true. Set false to remove periodic JIT cancel checks
// when you prioritize peak throughput over cancellability.
zwasm_config_set_cancellable(config, true);

zwasm_module_t *mod = zwasm_module_new_configured(wasm_ptr, len, config);
```

Fuel applies to module startup and invocation. If a module has a start function,
it runs under the configured fuel budget, and the remaining fuel is carried into
subsequent invocations.

### WASI + Custom Allocator

```c
zwasm_wasi_config_t *wasi = zwasm_wasi_config_new();
zwasm_config_t *config = zwasm_config_new();
zwasm_config_set_allocator(config, my_alloc, my_free, NULL);

zwasm_module_t *mod = zwasm_module_new_wasi_configured2(wasm_ptr, len, wasi, config);
// ... use module ...
zwasm_module_delete(mod);
zwasm_wasi_config_delete(wasi);
zwasm_config_delete(config);
```

## GC-Managed Host Pattern

When embedding zwasm in a host with its own garbage collector (e.g., a language
runtime), use this pattern:

1. **Use a non-GC allocator** for zwasm (e.g., system malloc, page allocator).
   Do NOT inject the host's GC allocator — zwasm's internal structures are
   opaque and must not be moved or collected mid-execution.

2. **Add a finalizer** to the host's wrapper object that calls `module.deinit()`
   (Zig) or `zwasm_module_delete()` (C) when the wrapper is collected.

3. **Only trace the wrapper** in the host GC, not zwasm internals.

```
Host GC heap                        Non-GC allocator
  ┌──────────────┐                   ┌──────────────────────┐
  │ WasmWrapper   │ ──ref──────────► │ zwasm.WasmModule      │
  │  (GC-traced)  │                  │  Store, VM, GcHeap    │
  │  finalizer:   │                  │  (opaque, not traced) │
  │   .deinit()   │                  └──────────────────────┘
  └──────────────┘
```

This avoids dual-GC lifecycle mismatch while ensuring zwasm memory is properly
released when the host no longer needs the module.

## Python ctypes

```python
import ctypes

import sys
_ext = {"win32": ".dll", "darwin": ".dylib"}.get(sys.platform, ".so")
lib = ctypes.CDLL(f"./libzwasm{_ext}")

# Load module
with open("module.wasm", "rb") as f:
    wasm = f.read()
buf = (ctypes.c_uint8 * len(wasm))(*wasm)
mod = lib.zwasm_module_new(buf, len(wasm))

# Invoke function
args = (ctypes.c_uint64 * 2)(10, 20)
results = (ctypes.c_uint64 * 1)()
lib.zwasm_module_invoke(mod, b"add", args, 2, results, 1)
print(f"result: {results[0]}")

lib.zwasm_module_delete(mod)
```

## API Reference

See `include/zwasm.h` for the complete C API with documentation comments.
Key function groups:

| Group | Functions |
|-------|-----------|
| Config | `zwasm_config_new`, `zwasm_config_delete`, `zwasm_config_set_allocator`, `zwasm_config_set_fuel`, `..._set_timeout`, `..._set_max_memory`, `..._set_force_interpreter`, `..._set_cancellable` |
| Module | `zwasm_module_new`, `zwasm_module_new_configured`, `zwasm_module_delete` |
| WASI | `zwasm_module_new_wasi`, `zwasm_module_new_wasi_configured2` |
| Invoke | `zwasm_module_invoke`, `zwasm_module_invoke_start`, `zwasm_module_cancel` |
| Memory | `zwasm_module_memory_data`, `zwasm_module_memory_size`, `_read`, `_write` |
| Exports | `zwasm_module_export_count`, `_name`, `_param_count`, `_result_count` |
| Imports | `zwasm_import_new`, `zwasm_import_add_fn`, `zwasm_import_delete` |
| Error | `zwasm_last_error_message` |
