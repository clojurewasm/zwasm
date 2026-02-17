# CLI Reference

## Commands

### `zwasm run` / `zwasm <file>`

Execute a WebAssembly module. The `run` subcommand is optional — `zwasm file.wasm` is equivalent to `zwasm run file.wasm`.

```bash
zwasm <file.wasm|.wat> [options] [args...]
zwasm run <file.wasm|.wat> [options] [args...]
```

By default, calls `_start` (WASI entry point). Use `--invoke` to call a specific exported function.

**Examples:**

```bash
# Run a WASI module (calls _start)
zwasm hello.wasm --allow-all

# Run a WAT text format file (no compilation needed)
zwasm program.wat

# Call a specific exported function
zwasm math.wasm --invoke add 2 3
```

#### Argument types

Function arguments are type-aware: zwasm uses the function's type signature
to parse integers, floats, and negative numbers correctly.

```bash
# Integers
zwasm math.wat --invoke add 2 3          # → 5

# Negative numbers (no -- needed)
zwasm math.wat --invoke negate -5        # → -5
zwasm math.wat --invoke abs -42          # → 42

# Floating-point
zwasm math.wat --invoke double 3.14      # → 6.28
zwasm math.wat --invoke half -6.28       # → -3.14

# 64-bit integers
zwasm math.wat --invoke fib 50           # → 12586269025
```

Results are displayed in their natural format:
- i32/i64: signed decimal (e.g. `-1`, not `4294967295`)
- f32/f64: decimal (e.g. `3.14`, not raw bits)

Argument count is validated against the function signature:

```bash
zwasm math.wat --invoke add 2             # error: 'add' expects 2 arguments, got 1
```

#### WASI modules

WASI modules use `_start` and receive string arguments via `args_get`.
Use `--` to separate WASI args from zwasm options:

```bash
# String args passed to the WASI module
zwasm app.wasm --allow-all -- hello world
zwasm app.wasm --allow-read --dir ./data -- input.txt

# Environment variables (injected vars accessible without --allow-env)
zwasm app.wasm --env HOME=/tmp --env USER=alice

# Sandbox mode: deny all + fuel 1B + memory 256MB
zwasm untrusted.wasm --sandbox
zwasm untrusted.wasm --sandbox --allow-read --dir ./data
```

#### Multi-module linking

```bash
# Link an import module and call a function
zwasm app.wasm --link math=math.wasm --invoke compute 42
```

#### Resource limits

```bash
# Limit instructions (fuel metering) and memory
zwasm untrusted.wasm --fuel 1000000 --max-memory 16777216
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
| `--sandbox` | Deny all capabilities + fuel 1B + memory 256MB |
| `--allow-all` | Grant all WASI capabilities |
| `--allow-read` | Grant filesystem read |
| `--allow-write` | Grant filesystem write |
| `--allow-env` | Grant environment variable access |
| `--allow-path` | Grant path operations (open, mkdir, unlink) |
| `--dir <path>` | Preopen a host directory (repeatable) |
| `--env KEY=VALUE` | Set a WASI environment variable (always accessible) |

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
echo -e "add 2 3\nmul 4 5" | zwasm math.wasm --batch --invoke add
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error (trap, stack overflow, etc.) |
| 2 | Invalid module or validation error |
| 126 | File not found |
