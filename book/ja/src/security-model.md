# Security Model

zwasm enforces a clear boundary between guest (WebAssembly module) and host (embedding application or CLI).

## Trust boundary

```
+-------------------+    WASI capabilities    +------------------+
|   Guest (Wasm)    | <-- deny-by-default --> |  Host (Zig/CLI)  |
|                   |                         |                  |
| Linear memory     |    Imports/exports      | Native memory    |
| Table entries     | <-- validated types --> | Filesystem, env  |
| Global variables  |                         | Network, OS APIs |
+-------------------+                         +------------------+
```

A valid Wasm module, no matter how adversarial, cannot:

- Read or write host memory outside its own linear memory
- Call host functions not explicitly imported
- Bypass WASI capability restrictions
- Execute code outside its validated instruction stream
- Overflow the call stack or value stack without trapping

## Defense layers

### Module decoding

All binary input is bounds-checked. Resource limits prevent excessive allocation:

- Section counts: 100-100,000 per section type
- Per-function locals: 50,000 max (saturating arithmetic for overflow)
- Block nesting depth: 500
- LEB128 reads bounds-checked against binary slice

### Validation

Full Wasm 3.0 type checking before any code executes. 62,158 spec tests verify correctness.

### Linear memory isolation

- Every load/store uses u33 arithmetic (address + offset) to prevent 32-bit overflow
- Guard pages: 4 GiB + 64 KiB PROT_NONE region catches all out-of-bounds access
- Signal handler converts memory faults to Wasm traps

### JIT security

- **W^X**: Code pages are RW during compilation, then switched to RX before execution. Never simultaneously writable and executable.
- All branch targets validated against the register IR
- Signal handler translates faults in JIT code to Wasm traps

### WASI capabilities

Deny-by-default model with 8 capability flags:

| Flag | Controls |
|------|----------|
| `allow-read` | Filesystem read |
| `allow-write` | Filesystem write |
| `allow-env` | Environment variables |
| `allow-path` | Path operations (open, mkdir, unlink) |
| `allow-clock` | Clock access |
| `allow-random` | Random number generation |
| `allow-proc` | Process operations |
| `allow-all` | All of the above |

32 of 46 WASI functions check capabilities before executing. The remaining 14 are safe operations (args size queries, fd_close, etc.).

**Library API defaults** (`loadWasi()`): `cli_default` — only stdio, clock, random, and proc_exit. Embedders needing full access use `loadWasiWithOptions(.{ .caps = .all })`.

**`--sandbox` mode**: Denies all capabilities, sets fuel to 1 billion instructions and memory ceiling to 256MB. Combine with `--allow-*` flags for selective access:

```bash
zwasm untrusted.wasm --sandbox --allow-read --dir ./data
```

**`--env KEY=VALUE`**: Injected environment variables are always accessible to the guest, even without `--allow-env`. The `--allow-env` flag controls access to host environment passthrough.

### Stack protection

- Call depth limit: 1024 (checked on every call)
- Operand stack: fixed-size array, bounds-checked
- Label stack: bounds-checked

## What zwasm does NOT protect against

- **Timing side channels**: No constant-time guarantees
- **Resource exhaustion**: A module can loop forever (use `--fuel` to mitigate)
- **Host function bugs**: If your host functions have vulnerabilities, Wasm code can trigger them
- **Spectre/Meltdown**: No hardware-level mitigations
- **Information leakage via timing**: JIT compilation time may vary with code structure

## Recommendations

- Build with `ReleaseSafe` for production (Zig's bounds checks + overflow detection)
- Use `--fuel` for untrusted modules to prevent infinite loops
- Use `--max-memory` to cap memory usage
- Grant only the WASI capabilities the module needs
- See [SECURITY.md](https://github.com/clojurewasm/zwasm/blob/main/SECURITY.md) for vulnerability reporting
