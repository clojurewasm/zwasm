# test/realworld — three runners over the toolchain corpus

`test/realworld/wasm/` holds 50+ pre-compiled `.wasm` fixtures
emitted by C / C++ / Rust / TinyGo / Go / emcc toolchains. Three
runners exercise the corpus from different angles:

| Runner            | Step                              | Verifies                                                                  |
|-------------------|-----------------------------------|---------------------------------------------------------------------------|
| `runner.zig`      | `zig build test-realworld`        | parse + validate + lower (no execute)                                     |
| `run_runner.zig`  | `zig build test-realworld-run`    | parse + execute via `cli_run.runWasm`; reports exit code per fixture      |
| `diff_runner.zig` | `zig build test-realworld-diff`   | wasmtime stdout vs `cli_run.runWasmCaptured` byte compare; gate at 30+    |

## Argv convention

All three execution-side runners pass `argv[0] = entry.name`
(the fixture's basename) and `argc = 1` to the WASI host. This
matches the byte-for-byte expectation of `cli_run.runWasm`'s
default invocation by `zwasm run <basename>.wasm`, and aligns
with how the diff_runner achieves byte-parity with `wasmtime
run <basename>.wasm`.

Note: `wasmtime run` itself uses the **basename** of the file
it was given (not the absolute path) when populating WASI argv.
Concretely: `wasmtime run /abs/path/to/foo.wasm` puts `foo.wasm`
at `argv[0]`. Our runners deliberately mirror that to keep the
diff gate honest.

If a future fixture relies on absolute-path argv (e.g. emits
`__file__`-style introspection), adjust the runner's argv
construction explicitly — silent discrepancy between runners
is forbidden. See debt entry **D-019** for the historical
note on this convention.

## Adding a fixture

1. Drop `.wasm` into `test/realworld/wasm/<toolchain>_<scenario>.wasm`
   (the `<toolchain>_` prefix groups by emitter — `c_`, `cpp_`,
   `rust_`, `tinygo_`, `go_`).
2. The three runners pick it up automatically.
3. If the fixture exits non-zero deliberately (e.g. `proc_exit(N)`
   for some non-zero N), document expected behaviour in the
   commit message.

## Excluded categories

- **WASI gap**: Go fixtures depending on functions not yet in
  v2's WASI host. `run_runner` reports `SKIP-WASI`.
- **Validator gap**: TinyGo / Go fixtures hitting typing-rule
  gaps in v2's validator. `run_runner` reports `SKIP-VALIDATOR`
  (10 fixtures — see ROADMAP §9.6 outstanding-spec-gaps).
- **No entry**: fixtures without a known entry export. Currently
  none.

These exclusions are honest gaps, not workarounds — they have
debt entries (or section IDs in ROADMAP §9.6) and removal
conditions tied to specific validator / WASI work items.

## See also

- `cli_run.runWasm` / `cli_run.runWasmCaptured` (`src/cli/run.zig`)
- `.dev/debt.md` D-007 (`RunOpts` struct refactor when envv /
  preopens are added) and D-019 (this argv convention).
- ADR-0012 §3 — test/ taxonomy.
