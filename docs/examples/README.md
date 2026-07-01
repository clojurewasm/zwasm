# Examples

Runnable embeddings of zwasm across its host surfaces. See the top-level
[README](../../README.md) (§Embedding) and [`docs/tutorial.md`](../tutorial.md)
for the full walkthrough.

| Example | Surface | What it shows |
|---------|---------|---------------|
| [`zig_host/`](zig_host/) | Zig facade | Native embedding via the `zwasm` module — `Engine` / `Module` / `Instance` / `typedFunc` (`hello.zig`), plus a JIT-engine variant (`jit_engine.zig`). |
| [`zig_dep/`](zig_dep/) | Zig package | A standalone downstream project that depends on zwasm through `build.zig.zon` and imports the `zwasm` module — the shape an external consumer uses. |
| [`c_host/`](c_host/) | C API | Embedding through the standard `wasm.h` C ABI plus the `zwasm.h` / `wasi.h` extensions (`hello.c`), linking `libzwasm`. |
| [`rust_host/`](rust_host/) | C API (from Rust) | The same `wasm.h` C ABI declared and driven from Rust (`hello.rs`), demonstrating drop-in wasm-c-api compatibility. |

## Running

From the repository root:

```sh
zig build run-zig-host     # build + run the native Zig host example
zig build run-rust-host    # build + run the Rust host example (needs a native Rust toolchain)
```

The `zig_dep/` example is its own project — build it from inside its directory
(`cd docs/examples/zig_dep && zig build`). The `c_host/` example links the C API
library; see the tutorial for the compile/link invocation.
