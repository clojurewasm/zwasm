# CLI reference

The `zwasm` binary is deliberately minimal — `run` + `compile`, the
wasmtime/wazero-aligned shape for a runtime. Validation is
programmatic (C-API `wasm_module_validate` / Zig `Engine.compile`);
wat↔wasm conversion and module introspection are `wasm-tools` / `wabt`'s
job, not a runtime's. Dispatch source:
[`src/cli/main.zig`](../../src/cli/main.zig).

## Commands

```
zwasm                                     # version + build-options banner
zwasm run <file.wasm|.cwasm> [args...]    # run a module
zwasm compile <file.wasm> -o <out.cwasm>  # compile to a .cwasm AOT artifact
zwasm --version | -V                      # version + build identity (wasm/wasi/engine)
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
| `--invoke <name>[=a,b,…]` | run the named export instead of `_start`/`main`. Zero-arg form → result surfaces as the exit code. `=args` (comma-separated, parsed by param type i32/i64/f32/f64) → typed results print bare, one per line, on stdout. Works on both the interpreter and the JIT (D-477) |
| `--engine <interp\|jit>`   | **default (omitted) = `auto`** — prefers the JIT, falls back to the interpreter. `--engine interp` / `jit` force one. BOTH do full WASI; `jit` additionally executes SIMD-128                                                              |
| `--dir <host>[:<guest>]`   | preopen a host directory for WASI (colon separator; guest path mirrors host when omitted)                                                                                                                                                    |
| `--env KEY=VAL`            | set a WASI environment variable for the guest (repeatable; bare `KEY` sets empty)                                                                                                                                                            |
| `--fuel <N>`               | trap (`all fuel consumed`) after a deterministic budget. Units are engine-specific by design: interp counts instructions, jit counts function entries + loop iterations                                                                     |
| `--timeout <ms>`           | interrupt the guest (`interrupted` trap) after a wall-clock deadline — both engines                                                                                                                                                         |
| `--max-memory <bytes>`     | refuse `memory.grow` past this many bytes (64 KiB page granularity); the spec `-1` failure, not a trap                                                                                                                                       |
| `--max-table-elements <N>` | cap a module's **declared initial** table element count at load time (D-332); a module whose initial table exceeds `N` is refused. (Runtime `table.grow` past a table's own declared max already returns the spec `-1`.)                     |

The sandboxing flags (`--fuel`/`--timeout`/`--max-memory`/`--max-table-elements`) apply to `.wasm`
runs on both engines; a `.cwasm` or component run combined with them is
refused loudly (exit 2) rather than running unsandboxed.

### `compile`

Reads a `.wasm`, runs the JIT pipeline, and writes a `.cwasm` v0.1 AOT
artifact to the `-o` / `--output` path. `zwasm run
<file.cwasm>` executes it.

## Engine selection

- `.cwasm` input → AOT-loaded directly (full WASI).
- `.wasm` input → **`auto` by default** (prefers the JIT, transparently falls
  back to the interpreter). `--engine interp` forces the interpreter;
  `--engine jit` forces the JIT (full WASI, plus SIMD execution). `auto` is the
  default only — it is not a spellable `--engine` value.

## Exit codes

| Code | Meaning                                                                                          |
|------|--------------------------------------------------------------------------------------------------|
| `0`  | Success — guest returned normally, or called `proc_exit(0)`                                     |
| `N`  | Guest called `proc_exit(N)` (the guest's own status surfaces verbatim)                           |
| `1`  | Guest trapped (OOB access, `unreachable`, integer divide-by-zero, fuel/timeout, …), OR a file read / load failure, OR any `compile` error (incl. a `compile` usage error) |
| `2`  | Usage error at dispatch — unknown subcommand, or a `run` flag parse error / a requested limit refused (loud). (`compile` usage errors exit `1`, not `2`.)                 |
| `70` | Internal zwasm fault — a fatal signal/panic caught by the diagnostic fault handler              |

Source of truth: the `run` exit-code mapping (`src/cli/run.zig`) +
`main.zig`'s dispatch (`2`) and internal-fault handler (`70`).

## Environment

- `ZWASM_DEBUG=<categories>` — `dbg.zig` category filter.
- `ZWASM_DIAG=<channels>` — diagnostic trace ringbuffer drain.

## Not shipped

`validate` / `inspect` / `features` / `wat` / `wasm` are deliberately
absent. (`--env`, `--fuel`, `--timeout`, `--max-memory`,
`--max-table-elements` and `--invoke NAME=ARGS` arg-marshalling +
typed-result printing have all shipped — see the `run` table.)
