# CLI Reference

## Commands

### `zwasm run`

Execute a WebAssembly module.

```bash
zwasm run [options] <file.wasm|.wat> [args...]
```

By default, calls `_start` (WASI entry point). Use `--invoke` to call a different function.

**Examples:**

```bash
# Run a WASI module
zwasm run --allow-all hello.wasm

# Call a specific function with arguments
zwasm run --invoke add math.wasm 2 3

# Run a WAT text file
zwasm run program.wat

# With WASI filesystem access
zwasm run --allow-read --dir ./data app.wasm

# With environment variables
zwasm run --allow-env --env HOME=/tmp app.wasm

# Link multiple modules
zwasm run --link math=math.wasm --invoke compute app.wasm 42

# Resource limits
zwasm run --fuel 1000000 --max-memory 16777216 untrusted.wasm
```

### `zwasm inspect`

Show a module's imports and exports.

```bash
zwasm inspect [--json] <file.wasm|.wat>
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
zwasm features
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
echo -e "add 2 3\nmul 4 5" | zwasm run --batch --invoke add math.wasm
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error (trap, stack overflow, etc.) |
| 2 | Invalid module or validation error |
| 126 | File not found |
