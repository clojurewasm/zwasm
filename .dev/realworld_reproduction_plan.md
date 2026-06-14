# Real-world toolchain / benchmark reproduction — work plan

> **Doc-state**: ACTIVE — the authoritative work sequence for the post-D-238 agenda
> (user-directed 2026-06-14). The handover ACTIVE AGENDA points here; this plan's
> ordering supersedes ROADMAP §9 lookup for these tasks.

## Why

Running real programs from mainstream wasm toolchains through zwasm + diffing against
reference runtimes (wasmtime/wasmer) is high-value: it reproduces what real users do
and surfaces JIT miscompiles + unimplemented ops + WASI gaps that synthetic tests miss.
Proven 2026-06-14: running the existing 50-fixture corpus under `ZWASM_SPEC_ENGINE=jit`
showed interp 55/55 but **JIT 35 pass / 11 trap / 9 compile-gap** — i.e. ~20 real
programs work in interp but fail under JIT. That signal is the seed of Phase B.

## User decisions (2026-06-14)

- **Ordering**: do **Phase A (Tier 3+2) QUICKLY to get it working**, THEN **Phase B
  (Tier 1) with sustained, settle-in effort**. The loop judges the fine order.
- **cljw guest-wasm RETIRED** — cw v0 (`ClojureWasm`) is the frozen wasm-emitter; cw v1
  (`ClojureWasmFromScratch`) is a tree-walk evaluator with no plan to emit wasm. cljw
  tests zwasm **consumer-side** (its own dogfooding). zwasm carries no cljw fixtures.
- **Tool install**: the user will help when a toolchain needs provisioning.

## wasm-target language scope (2026 landscape, research-grounded)

Already in `nix develop .#gen`: Rust (wasm32-wasip1/p2), C/C++ (clang+lld / emcc),
TinyGo, Go (GOOS=wasip1), clang wasm32/wasm64. Reference runtimes on PATH: wasmtime,
wasmer (+ hyperfine for bench). Expansion targets by value × feasibility:

| Lang | wasm status (2026) | what it stresses in zwasm | add effort |
|---|---|---|---|
| Rust / C / C++ | gold standard (have) | baseline | done |
| **AssemblyScript** | production, wasm-core, **WASI dropped** | numeric/compute, distinct compiler idiom | easy (npm) |
| **Zig** | mature wasm32-wasi | self-language, dogfood-adjacent | easy (have toolchain) |
| **Go standard (wasip1)** | mature but fat (8–12 MB) + demanding ops | **the 9 `go_*` JIT UnsupportedOp gaps** | have (gen) |
| **Kotlin/Wasm · Dart** | WasmGC (all browsers 2024) | **zwasm GC on REAL programs — untested surface** | medium |
| **MoonBit · Grain** | wasm-native, clean small output, rising | modern langs, tidy codegen | medium |
| .NET/C# · Swift · Python | heavy / interpreter | lower priority real-world | later |

## Phase A — reproduction infrastructure (QUICK; get it working)

Order = autonomous-Mac-side first, then user-assisted host installs.

- **A1 (Tier 2, autonomous) — corpus diversity.** Add AssemblyScript + Zig generators
  to the `.#gen` fixture pipeline; generate small real programs (compute + WASI), drop
  into `test/realworld/wasm/`, run through zwasm interp + byte-diff wasmtime. Then
  investigate a WasmGC lang (Kotlin/Wasm or Dart) to exercise zwasm's GC on real code.
  - **DONE (Zig half, 2026-06-14 `5c044967`)**: `zig_{hello,fib,prime_sieve}` — Zig
    wasm32-wasi (toolchain already pinned in `.#gen`); interp 53/53, byte-diff 53/53 vs
    wasmtime, JIT-run clean. Recipe in `src/zig` + `src/PROVENANCE.md`. Found+fixed a
    `diff_runner` green-path summary-flush bug (`6995bbd3`) en route.
  - **DEFERRED → D-324**: AssemblyScript (needs `asc` provisioning + AS dropped WASI ⇒ a
    call-export harness, not the WASI-stdout runners) and the WasmGC lang (Kotlin/Wasm /
    Dart SDK + GC return-value harness). Both are user-assisted installs.
- **A2 (Tier 2, autonomous) — embenchen (D-026/D-082).** emcc is in `.#gen`. Reproduce
  the classic Emscripten benchmark; the find is the emscripten env-stub host-import gap
  — implement enough `env`/emscripten imports to instantiate + run, triage from there.
- **A3 (Tier 2, autonomous) — 3-way differential.** wasmtime + wasmer both on PATH. Wire
  a zwasm vs wasmtime vs wasmer comparison over the corpus (correctness + hyperfine
  perf). Surfaces zwasm divergences a single-reference diff would miss.
- **A4 (Tier 3, user-assisted) — remote toolchain provisioning.** D-254 (native rust on
  ubuntunote + windowsmini → 3-host rust differential; user chose resolution (a)).
  D-249 (hyperfine on windowsmini for Win bench). Ask the user when install is needed.

## Phase B — deep JIT bug-hunt (SUSTAINED; settle in)

- **B1 (Tier 1) — D-283: JIT-realworld trap/compile-gap triage + fix.** The live signal
  (cljw-excluded, from `ZWASM_JIT_RUN=1` on the 50-fixture corpus):
  - **6 RUN-TRAP** (interp-passes, JIT-traps ⇒ JIT miscompile or JIT-WASI gap):
    `tinygo_fib`, `tinygo_hello`, `tinygo_json`, `tinygo_sort`, `rust_file_io`,
    `c_sha256_hash`.
  - **9 COMPILE-OP** (JIT `UnsupportedOp` ⇒ unimplemented JIT op): ALL `go_*`
    (`go_hello_wasi`, `go_string_builder`, `go_crypto_sha256`, `go_json_marshal`,
    `go_map_ops`, `go_math_big`, `go_regex`, `go_sort_benchmark`, `go_error_handling`).
  Multi-cycle: root-cause each cluster (start with the trustworthy standard-toolchain
  ones — tinygo/rust/c traps + the Go op-gaps), fix the JIT miscompiles + implement the
  missing ops, add boundary fixtures per fix. Exit: enable `ZWASM_JIT_RUN=1` by default
  for the runnable set + the corpus runs JIT-clean (matching interp). Plus whatever new
  traps Phase A's diverse fixtures surface.

## First action on resume

Phase A1: `nix develop .#gen` → confirm the gen pipeline, add an AssemblyScript hello +
a Zig hello, generate + diff vs wasmtime. (`test/realworld/` runners + the `.#gen`
flake devshell are the entry points.)
