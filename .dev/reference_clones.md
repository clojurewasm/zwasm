# Read-only reference clones

Pointed to from `CLAUDE.md` and mirrored in
`.claude/settings.json` (`additionalDirectories` /
`Edit(...)` / `Write(...)` allow-lists). Never edit or commit
from any of these paths — they are reference material, not
project state.

| Path                                             | What it is                                                             |
|--------------------------------------------------|------------------------------------------------------------------------|
| `~/Documents/MyProducts/zwasm/`                  | zwasm v1 (current main, ClojureWasm consumer) — **read, never copy**   |
| `~/Documents/MyProducts/ClojureWasmFromScratch/` | CW v2 — procedural template that this project mirrors                  |
| `~/Documents/OSS/wasmtime/`                      | wasmtime + cranelift (winch / regalloc2 reference)                     |
| `~/Documents/OSS/zware/`                         | Zig idiomatic interpreter                                              |
| `~/Documents/OSS/wasm3/`                         | wasm3 (M3 IR + tail-call dispatch interpreter)                         |
| `~/Documents/OSS/wasmer/`                        | wasmer (singlepass / multi-backend)                                    |
| `~/Documents/OSS/wazero/`                        | wazero (Go, dual-engine)                                               |
| `~/Documents/OSS/wasm-c-api/`                    | wasm-c-api standard ABI                                                |
| `~/Documents/OSS/regalloc2/`                     | cranelift register allocator                                           |
| `~/Documents/OSS/wasm-tools/`                    | `wasm-tools smith` (fuzz corpus), `validate`, ...                      |
| `~/Documents/OSS/sightglass/`                    | Bytecode Alliance bench suite                                          |
| `~/Documents/OSS/wasm-micro-runtime/`            | WAMR (lightweight runtime reference)                                   |
| `~/Documents/OSS/cap-std/`                       | Capability-based std for Rust                                          |
| `~/Documents/OSS/wit-bindgen/`                   | Component Model bindgen (post-v0.1.0 reference)                        |
| `~/Documents/OSS/WasmEdge/`                      | WasmEdge (cloud-native runtime; AOT strategy reference)                |
| `~/Documents/OSS/wasi-rs/`                       | Rust WASI binding (host idiom + C ABI consumer reference)              |
| `~/Documents/OSS/dynasm-rs/`                     | DynASM (Rust port; copy-and-patch reference, post-v0.1.0)              |
| `~/Documents/OSS/poop/`                          | Andrew Kelley's perf-bench tool (Zig)                                  |
| `~/Documents/OSS/hyperfine/`                     | Hyperfine source (bench tool used in `bench/`)                         |
| `~/Documents/OSS/extism/`                        | Extism (multi-language Wasm host SDK reference)                        |
| `~/Documents/OSS/WebAssembly/spec/`              | reference interpreter (OCaml) + spec text                              |
| `~/Documents/OSS/WebAssembly/testsuite/`         | spec testsuite                                                         |
| `~/Documents/OSS/WebAssembly/<proposal>/`        | per-proposal spec + tests (multi-value, simd, gc, eh, ...)             |
| `~/Documents/OSS/zig/`                           | Zig 0.16 stdlib source                                                 |
