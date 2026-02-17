# zwasm Usage Guide

## CLI

### Running Wasm modules

```bash
# Run a WASI module (calls _start) — `run` is optional
zwasm module.wasm

# Pass arguments
zwasm module.wasm -- arg1 arg2

# Run a WAT text format module
zwasm module.wat

# Call a specific exported function instead of _start
zwasm module.wasm --invoke fib
```

### WASI security

zwasm uses deny-by-default WASI capabilities. Modules get no filesystem or
environment access unless explicitly granted.

```bash
# Grant filesystem read access
zwasm module.wasm --allow-read

# Grant specific directory access
zwasm module.wasm --dir /path/to/data

# Grant all capabilities
zwasm module.wasm --allow-all

# Set environment variables (accessible without --allow-env)
zwasm module.wasm --env KEY=VALUE
```

Available capability flags:

| Flag             | Description                              |
|------------------|------------------------------------------|
| `--allow-read`   | Filesystem read access                   |
| `--allow-write`  | Filesystem write access                  |
| `--allow-env`    | Environment variable access              |
| `--allow-path`   | Path operations (open, mkdir, unlink)    |
| `--allow-all`    | All WASI capabilities                    |
| `--sandbox`      | Deny all + fuel 1B + memory 256MB        |

### Resource limits

```bash
# Sandbox mode: deny all capabilities, fuel 1B, memory 256MB
zwasm module.wasm --sandbox

# Sandbox with selective access
zwasm module.wasm --sandbox --allow-read --dir ./data

# Limit memory growth (bytes)
zwasm module.wasm --max-memory 67108864  # 64MB ceiling

# Limit execution (instruction fuel)
zwasm module.wasm --fuel 1000000
```

### Linking modules

```bash
# Link another Wasm module as import source
zwasm app.wasm --link math=math.wasm
zwasm app.wasm --link env=helpers.wasm --link io=io.wasm
```

### Component Model

zwasm auto-detects Component Model binaries and runs them:

```bash
# Run a component (auto-detected from binary header)
zwasm component.wasm
```

### Feature listing

```bash
# Show all supported Wasm proposals
zwasm features

# Machine-readable JSON output
zwasm features --json
```

### Inspect and validate

```bash
# Show exports, imports, memory sections
zwasm inspect module.wasm

# JSON output
zwasm inspect --json module.wasm

# Validate without running
zwasm validate module.wasm
```

### Debugging

```bash
# Trace execution categories (comma-separated)
zwasm module.wasm --trace=jit,regir,exec,mem,call

# Dump Register IR for function index N
zwasm module.wasm --dump-regir=5

# Dump JIT disassembly for function index N
zwasm module.wasm --dump-jit=5

# Execution profile (opcode frequency, call counts)
zwasm module.wasm --profile
```

### Batch mode

Read function invocations from stdin, one per line:

```bash
echo '{"func":"add","args":[1,2]}' | zwasm module.wasm --batch
```

---

## Library (Zig dependency)

### Adding zwasm to your project

In `build.zig.zon`:

```zig
.dependencies = .{
    .zwasm = .{
        .url = "https://github.com/clojurewasm/zwasm/archive/v1.0.0.tar.gz",
        .hash = "...",  // zig build will report the correct hash
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

### Basic usage

```zig
const zwasm = @import("zwasm");
const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Load from binary
    var module = try zwasm.WasmModule.load(allocator, wasm_bytes);
    defer module.deinit();

    // Invoke an exported function
    var args = [_]u64{35};
    var results = [_]u64{0};
    try module.invoke("fib", &args, &results);
    // results[0] contains the return value
}
```

### Loading from WAT

```zig
var module = try zwasm.WasmModule.loadFromWat(allocator, wat_source);
defer module.deinit();
```

Requires `-Dwat=true` (default). Disable with `-Dwat=false` to reduce binary size.

### WASI modules

```zig
// Basic WASI — defaults to cli_default capabilities (stdio, clock, random, proc_exit)
var module = try zwasm.WasmModule.loadWasi(allocator, wasm_bytes);
defer module.deinit();
try module.invoke("_start", &.{}, &.{});

// With full access (filesystem, env, etc.)
var module = try zwasm.WasmModule.loadWasiWithOptions(allocator, wasm_bytes, .{
    .caps = zwasm.Capabilities.all,
});

// With selective options
var module = try zwasm.WasmModule.loadWasiWithOptions(allocator, wasm_bytes, .{
    .args = &.{ "myapp", "--verbose" },
    .env_keys = &.{"HOME"},
    .env_vals = &.{"/tmp"},
    .preopen_paths = &.{"/data"},
    .caps = .{ .allow_read = true, .allow_write = false },
});
defer module.deinit();
```

### Cross-module linking

```zig
// Load a library module
var math_mod = try zwasm.WasmModule.load(allocator, math_bytes);
defer math_mod.deinit();

// Load the main module, importing from the library
var imports = [_]zwasm.ImportEntry{.{
    .module = "math",
    .source = .{ .wasm_module = math_mod },
}};
var app = try zwasm.WasmModule.loadWithImports(allocator, app_bytes, &imports);
defer app.deinit();
```

### Host functions

```zig
const zwasm = @import("zwasm");

fn myHostFn(ctx: *anyopaque, id: usize) !void {
    // ctx is the VM instance, id is the context value from HostFnEntry
    _ = ctx;
    _ = id;
}

var host_fns = [_]zwasm.HostFnEntry{.{
    .name = "log",
    .callback = @ptrCast(&myHostFn),
    .context = 0,
}};

var imports = [_]zwasm.ImportEntry{.{
    .module = "env",
    .source = .{ .host_fns = &host_fns },
}};

var module = try zwasm.WasmModule.loadWithImports(allocator, wasm_bytes, &imports);
defer module.deinit();
```

### Memory access

```zig
// Read bytes from linear memory
const data = try module.memoryRead(allocator, offset, length);
defer allocator.free(data);

// Write bytes to linear memory
try module.memoryWrite(offset, data);
```

### Import inspection

Inspect a module's imports before instantiation:

```zig
const imports = try zwasm.inspectImportFunctions(allocator, wasm_bytes);
defer allocator.free(imports);

for (imports) |imp| {
    std.debug.print("{s}.{s}: {d} params, {d} results\n", .{
        imp.module, imp.name, imp.param_count, imp.result_count,
    });
}
```

### Exit code

```zig
try module.invoke("_start", &.{}, &.{});
if (module.getWasiExitCode()) |code| {
    std.process.exit(@intCast(code));
}
```

---

## Build options

```bash
zig build                          # Debug build
zig build -Doptimize=ReleaseSafe   # ReleaseSafe (~1.1MB binary)
zig build -Doptimize=ReleaseFast   # ReleaseFast (max speed)
zig build -Dwat=false              # Disable WAT parser (smaller binary)
zig build test                     # Run all tests
zig build test -- "test name"      # Run specific test
```
