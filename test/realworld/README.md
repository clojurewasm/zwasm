# test/realworld — four runners over the toolchain corpus

`test/realworld/wasm/` holds 50+ pre-compiled `.wasm` fixtures
emitted by C / C++ / Rust / TinyGo / Go / emcc / Zig toolchains. The
`emcc_` prefix marks emscripten-emitted modules (`-sSTANDALONE_WASM` → WASI;
the embenchen benchmark reproduction), distinct from bare-clang `c_`. Four
runners exercise the corpus from different angles:

| Runner                | Step                                | Verifies                                                                  |
|-----------------------|-------------------------------------|---------------------------------------------------------------------------|
| `runner.zig`          | `zig build test-realworld`          | parse + validate + lower (no execute)                                     |
| `run_runner.zig`      | `zig build test-realworld-run`      | parse + execute via `cli_run.runWasm`; reports exit code per fixture      |
| `diff_runner.zig`     | `zig build test-realworld-diff`     | wasmtime stdout vs `cli_run.runWasmCaptured` byte compare; gate at 30+       |
| `diff_runner.zig --jit` | `zig build test-realworld-diff-jit` | the above PLUS wasmtime vs `--engine jit` byte compare; gates on mismatch, on a skip, and on any fixture the lane failed to account for |
| `run_runner_jit.zig`  | `zig build test-realworld-run-jit`  | JIT **compilation** of every fixture (`compileWasm`) — no execution        |

`test-all` depends on `test-realworld-diff-jit`, not on `test-realworld-diff`:
same runner, same shared lane, plus the gating JIT lane — one dependency, no
double run of the shared lane.

**Careful about which engine each runner uses.** `runWasm` / `runWasmCaptured`
take default `Limits`, i.e. `engine = .auto`, and `.auto` tries the JIT first
and reaches the interp only where the JIT cannot instantiate. So neither
`run_runner.zig` nor `diff_runner.zig`'s shared lane is an interp check —
measured 2026-08-16, 7 of the 56 fixtures provably do not take the interp under
the default (the interp needs >3s where the default finishes; `emcc_fannkuch`
is 9.76s vs 0.12s). Only `--engine interp` forces it, and nothing in `test-all`
does. `test/realworld` therefore has no interp result-check today.

**Which runners answer "does JIT-emitted code compute the right answer?"** —
`diff_runner.zig --jit` (56 fixtures vs wasmtime), and in `test-all` also
`run_edge_realworld_p10` (8 fixtures in `p10/` vs static `.expect`) and
`run_aot_diff` (56 of its 63 vs the `.cwasm` lane). They differ by oracle:
an independent runtime, a checked-in expectation, and zwasm itself.
`run_runner_jit.zig` answers none of them — it only says the backend encoded
every fixture.

## Argv convention

Every execution-side runner passes `argv[0] = entry.name`
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
2. All the runners pick it up automatically — including the gating
   `--jit` lane, so a fixture the JIT cannot run turns `test-all` red.
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
- `.dev/debt.yaml` D-007 (`RunOpts` struct refactor when envv /
  preopens are added) and D-019 (this argv convention).
- ADR-0012 §3 — test/ taxonomy.
