# CLI reference

The `zwasm` binary is deliberately minimal — `run` + `compile`, the
wasmtime/wazero-aligned shape for a runtime (ADR-0159). Validation is
programmatic (C-API `wasm_module_validate` / Zig `Engine.compile`);
wat↔wasm conversion and module introspection are `wasm-tools` / `wabt`'s
job, not a runtime's. Dispatch source:
[`src/cli/main.zig`](../../src/cli/main.zig).

## Commands

```
zwasm                                     # version + build-options banner
zwasm run <file.wasm|.cwasm> [args...]    # run a module
zwasm compile <file.wasm> -o <out.cwasm>  # compile to a .cwasm AOT artifact
zwasm --version | -V                      # version
zwasm --help | -h | help                  # usage
```

An unrecognised first token is an error (exit 2) — the surface is
explicit; there is no bare-file shortcut.

### `run`

Drives a WASI module's `_start` / `main` and exits with the guest's
`proc_exit` code. A `.cwasm` (CWAS magic) loads + runs directly (no
parse/compile).

| Flag                       | Effect                                                                                                                                                                                                                                       |
|----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--invoke <name>[=a,b,…]` | run the named export instead of `_start`/`main`. Zero-arg form → result surfaces as the exit code. `=args` (comma-separated, parsed by param type i32/i64/f32/f64) → typed results print bare, one per line, on stdout. Interp engine only |
| `--engine <interp\|jit>`   | `interp` (default) or `jit` — BOTH do full WASI (D-244); `jit` additionally executes SIMD-128                                                                                                                                               |
| `--dir <host>[:<guest>]`   | preopen a host directory for WASI (colon separator; guest path mirrors host when omitted)                                                                                                                                                    |
| `--env KEY=VAL`            | set a WASI environment variable for the guest (repeatable; bare `KEY` sets empty)                                                                                                                                                            |
| `--fuel <N>`               | trap (`all fuel consumed`) after a deterministic budget. Units are engine-specific by design: interp counts instructions, jit counts function entries + loop iterations (ADR-0179)                                                           |
| `--timeout <ms>`           | interrupt the guest (`interrupted` trap) after a wall-clock deadline — both engines                                                                                                                                                         |
| `--max-memory <bytes>`     | refuse `memory.grow` past this many bytes (64 KiB page granularity); the spec `-1` failure, not a trap                                                                                                                                       |

The sandboxing flags (`--fuel`/`--timeout`/`--max-memory`) apply to `.wasm`
runs on both engines; a `.cwasm` or component run combined with them is
refused loudly (exit 2) rather than running unsandboxed.

### `compile`

Reads a `.wasm`, runs the JIT pipeline, and writes a `.cwasm` v0.1 AOT
artifact (ADR-0039) to the `-o` / `--output` path. `zwasm run
<file.cwasm>` executes it.

## Engine selection

- `.cwasm` input → AOT-loaded directly (full WASI, D-251).
- `.wasm` input → interpreter by default; `--engine jit` opts into the JIT
  (full WASI via D-244, plus SIMD execution).

## Environment

- `ZWASM_DEBUG=<categories>` — `dbg.zig` category filter.
- `ZWASM_DIAG=<channels>` — diagnostic trace ringbuffer drain.

## Not shipped

`validate` / `inspect` / `features` / `wat` / `wasm` are deliberately
absent (ADR-0159). (`--env`, `--fuel`, `--timeout`, `--max-memory` and
`--invoke NAME=ARGS` arg-marshalling + typed-result printing have all
shipped — see the `run` table.)
