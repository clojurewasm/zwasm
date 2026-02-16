# CLI Reference

## Commands

### `zwasm run`

Execute a WebAssembly module.

```bash
zwasm run [options] <file.wasm|.wat> [args...]
zwasm run <file.wasm|.wat> [options] [args...]
```

By default, calls `_start` (WASI entry point). Use `--invoke` to call a specific exported function. Options can appear before or after the file path.

**Examples:**

```bash
# Run a WASI module (calls _start)
zwasm run --allow-all hello.wasm

# Run a WAT text format file (no compilation needed)
zwasm run program.wat

# Call a specific exported function
zwasm run math.wasm --invoke add 2 3
zwasm run --invoke add math.wasm 2 3    # options before file also OK
```

#### Argument types

Function arguments are type-aware: zwasm uses the function's type signature
to parse integers, floats, and negative numbers correctly.

```bash
# Integers
zwasm run math.wat --invoke add 2 3          # → 5

# Negative numbers (no -- needed)
zwasm run math.wat --invoke negate -5        # → -5
zwasm run math.wat --invoke abs -42          # → 42

# Floating-point
zwasm run math.wat --invoke double 3.14      # → 6.28
zwasm run math.wat --invoke half -6.28       # → -3.14

# 64-bit integers
zwasm run math.wat --invoke fib 50           # → 12586269025
```

Results are displayed in their natural format:
- i32/i64: signed decimal (e.g. `-1`, not `4294967295`)
- f32/f64: decimal (e.g. `3.14`, not raw bits)

Argument count is validated against the function signature:

```bash
zwasm run math.wat --invoke add 2             # error: 'add' expects 2 arguments, got 1
```

#### WASI modules

WASI modules use `_start` and receive string arguments via `args_get`.
Use `--` to separate WASI args from zwasm options:

```bash
# String args passed to the WASI module
zwasm run --allow-all app.wasm -- hello world
zwasm run --allow-read --dir ./data app.wasm -- input.txt

# Environment variables
zwasm run --allow-env --env HOME=/tmp --env USER=alice app.wasm
```

#### Multi-module linking

```bash
# Link an import module and call a function
zwasm run app.wasm --link math=math.wasm --invoke compute 42
```

#### Resource limits

```bash
# Limit instructions (fuel metering) and memory
zwasm run --fuel 1000000 --max-memory 16777216 untrusted.wasm
```

### `zwasm inspect`

Show a module's imports and exports.

```bash
zwasm inspect [--json] <file.wasm|.wat>
```

```bash
# Human-readable
zwasm inspect examples/wat/01_hello_add.wat

# JSON output (for scripting)
zwasm inspect --json math.wasm
```

**Options:**
- `--json` — Output in JSON format

### `zwasm validate`

Check if a module is valid without executing it.

```bash
zwasm validate <file.wasm|.wat>
```

### `zwasm features`

List supported WebAssembly proposals.

```bash
zwasm features [--json]
```

### `zwasm version`

Print the version string.

### `zwasm help`

Show usage information.

## Run options

### Execution

| Flag | Description |
|------|-------------|
| `--invoke <func>` | Call `<func>` instead of `_start` |
| `--batch` | Batch mode: read invocations from stdin |
| `--link name=file` | Link a module as import source (repeatable) |

### WASI capabilities

| Flag | Description |
|------|-------------|
| `--allow-all` | Grant all WASI capabilities |
| `--allow-read` | Grant filesystem read |
| `--allow-write` | Grant filesystem write |
| `--allow-env` | Grant environment variable access |
| `--allow-path` | Grant path operations (open, mkdir, unlink) |
| `--dir <path>` | Preopen a host directory (repeatable) |
| `--env KEY=VALUE` | Set a WASI environment variable (repeatable) |

### Resource limits

| Flag | Description |
|------|-------------|
| `--max-memory <N>` | Memory ceiling in bytes (limits `memory.grow`) |
| `--fuel <N>` | Instruction fuel limit (traps when exhausted) |

### Debugging

| Flag | Description |
|------|-------------|
| `--profile` | Print execution profile (opcode frequency, call counts) |
| `--trace=CATS` | Trace categories: `jit,regir,exec,mem,call` (comma-separated) |
| `--dump-regir=N` | Dump register IR for function index N |
| `--dump-jit=N` | Dump JIT disassembly for function index N |

## Batch mode

With `--batch`, zwasm reads invocation commands from stdin, one per line:

```
add 2 3
mul 4 5
fib 10
```

```bash
echo -e "add 2 3\nmul 4 5" | zwasm run math.wasm --batch --invoke add
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error (trap, stack overflow, etc.) |
| 2 | Invalid module or validation error |
| 126 | File not found |
