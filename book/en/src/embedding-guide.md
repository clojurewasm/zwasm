# Embedding Guide

Use zwasm as a Zig library to load and execute WebAssembly modules in your application.

## Setup

Add zwasm to your `build.zig.zon`:

```zig
.dependencies = .{
    .zwasm = .{
        .url = "https://github.com/clojurewasm/zwasm/archive/refs/tags/v1.1.0.tar.gz",
        .hash = "...",  // zig build will provide the correct hash
    },
},
```

In `build.zig`:

```zig
const zwasm_dep = b.dependency("zwasm", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zwasm", zwasm_dep.module("zwasm"));
```

## Basic usage

```zig
const zwasm = @import("zwasm");
const WasmModule = zwasm.WasmModule;

// Load a module from bytes
const mod = try WasmModule.load(allocator, wasm_bytes);
defer mod.deinit();

// Call an exported function
var args = [_]u64{ 10, 20 };
var results = [_]u64{0};
try mod.invoke("add", &args, &results);

const sum: i32 = @bitCast(@as(u32, @truncate(results[0])));
```

## Loading variants

| Method | Use case |
|--------|----------|
| `load(alloc, bytes)` | Basic module, no WASI |
| `loadFromWat(alloc, wat_src)` | Load from WAT text format |
| `loadWasi(alloc, bytes)` | Module with WASI (cli_default caps) |
| `loadWasiWithOptions(alloc, bytes, opts)` | WASI with custom config |
| `loadWithImports(alloc, bytes, imports)` | Module with host functions |
| `loadWasiWithImports(alloc, bytes, imports, opts)` | Both WASI and host functions |
| `loadWithFuel(alloc, bytes, fuel)` | With instruction fuel limit |

## Host functions

Provide native Zig functions as Wasm imports:

```zig
const zwasm = @import("zwasm");

fn hostLog(ctx_ptr: *anyopaque, context: usize) anyerror!void {
    _ = context;
    const vm: *zwasm.Vm = @ptrCast(@alignCast(ctx_ptr));

    // Pop argument from operand stack
    const value = vm.popOperandI32();
    std.debug.print("log: {}\n", .{value});

    // Push return value (if function returns one)
    // try vm.pushOperand(@bitCast(@as(i32, result)));
}

const imports = [_]zwasm.ImportEntry{
    .{
        .module = "env",
        .source = .{ .host_fns = &.{
            .{ .name = "log", .callback = hostLog, .context = 0 },
        }},
    },
};

const mod = try WasmModule.loadWithImports(allocator, wasm_bytes, &imports);
```

## WASI configuration

```zig
// loadWasi() defaults to cli_default caps (stdio, clock, random, proc_exit).
// Use loadWasiWithOptions for full access or custom capabilities:
const opts = zwasm.WasiOptions{
    .args = &.{ "my-app", "--verbose" },
    .env_keys = &.{"HOME"},
    .env_vals = &.{"/tmp"},
    .preopen_paths = &.{"./data"},
    .caps = zwasm.Capabilities.all,
};

const mod = try WasmModule.loadWasiWithOptions(allocator, wasm_bytes, opts);
```

## Memory access

Read from and write to the module's linear memory:

```zig
// Read 100 bytes starting at offset 0
const data = try mod.memoryRead(allocator, 0, 100);
defer allocator.free(data);

// Write data at offset 256
try mod.memoryWrite(256, &.{ 0x48, 0x65, 0x6C, 0x6C, 0x6F });
```

## Module linking

Link multiple modules together:

```zig
// Load the "math" module and register its exports
const math_mod = try WasmModule.load(allocator, math_bytes);
defer math_mod.deinit();
try math_mod.registerExports("math");

// Load another module that imports from "math"
const imports = [_]zwasm.ImportEntry{
    .{ .module = "math", .source = .{ .wasm_module = math_mod } },
};
const app_mod = try WasmModule.loadWithImports(allocator, app_bytes, &imports);
defer app_mod.deinit();
```

## Inspecting imports

Check what a module needs before instantiation:

```zig
const import_infos = try zwasm.inspectImportFunctions(allocator, wasm_bytes);
defer allocator.free(import_infos);

for (import_infos) |info| {
    std.debug.print("{s}.{s}: {d} params, {d} results\n", .{
        info.module, info.name, info.param_count, info.result_count,
    });
}
```


## Resource limits and Config options

In Zig, resource and execution options are grouped in `WasmModule.Config` and passed to `loadWithOptions`.
This allows you to control:

- **fuel**: Instruction count limit (prevents infinite loops)
- **timeout_ms**: Wall-clock timeout (milliseconds)
- **max_memory_bytes**: Maximum linear memory size
- **force_interpreter**: Disable JIT, always use interpreter

Example (Zig):

```zig
const zwasm = @import("zwasm");
const Config = zwasm.WasmModule.Config;

var config = Config{
    .fuel = 1_000_000, // Trap after 1M instructions
    .timeout_ms = 1000, // 1 second wall-clock timeout
    .max_memory_bytes = 16 * 1024 * 1024, // 16MB
    .force_interpreter = false,
};
const mod = try WasmModule.loadWithOptions(allocator, wasm_bytes, config);
```

**fuel**: If set, the module will trap with `error.FuelExhausted` after the specified number of instructions. Use this for untrusted or potentially infinite-looping code.

**cancellation**: `mod.cancel()` can be called from another thread to interrupt an in-progress invocation.

**timeout_ms**: If set, execution will be interrupted after the given wall-clock time.

All options are optional; defaults are safe for most use cases. See the C API section for equivalent `zwasm_config_t` usage.

## Error handling

All loading and execution methods return error unions. Key error types:

- **`error.InvalidWasm`** — Binary format is invalid
- **`error.ImportNotFound`** — Required import not provided
- **`error.Trap`** — Unreachable instruction executed
- **`error.StackOverflow`** — Call depth exceeded 1024
- **`error.OutOfBoundsMemoryAccess`** — Memory access out of bounds
- **`error.OutOfMemory`** — Allocator failed
- **`error.FuelExhausted`** — Instruction fuel limit hit
- **`error.Canceled`** — Execution canceled by host via `cancel()`
- **`error.TimeoutExceeded`** — Execution interrupted by wall-clock timeout

See [Error Reference](../docs/errors.md) for the complete list.

## Allocator control

zwasm takes a `std.mem.Allocator` at load time and uses it for all internal allocations. You control the allocator:

```zig
// Use the general purpose allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const mod = try WasmModule.load(gpa.allocator(), wasm_bytes);

// Or use an arena for batch cleanup
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const mod = try WasmModule.load(arena.allocator(), wasm_bytes);
```

## API stability

Types and functions are classified into three stability levels:

- **Stable**: Covered by SemVer. Will not break in minor/patch releases. Includes: `WasmModule`, `WasmFn`, `WasmValType`, `ExportInfo`, `ImportEntry`, `HostFnEntry`, `WasiOptions`, and all their public methods.

- **Experimental**: May change in minor releases. Includes: `runtime.Store`, `runtime.Module`, `runtime.Instance`, `loadLinked`, WIT-related functions.

- **Internal**: Not accessible to library consumers. All types in source files other than `types.zig`.

See [docs/api-boundary.md](https://github.com/clojurewasm/zwasm/blob/main/docs/api-boundary.md) for the complete list.

> **Using a non-Zig language?** zwasm also exposes a C API (`libzwasm`) that works with any FFI-capable language — C, Python, Rust, Go, and more. See [C API & Cross-Language Integration](./c-api.md).
