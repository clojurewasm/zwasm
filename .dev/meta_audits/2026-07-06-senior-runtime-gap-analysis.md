# Senior-runtime gap analysis — zwasm v2.1.0 vs wasmtime/wasmer/WAMR/WasmEdge/wazero/wasm3/extism

> **Doc-state**: ACTIVE — survey report (read-only findings; no code
> changes). Drives the `G-senior-gap` debt front (D-507..D-513) + the
> handover NEXT queue. Complements `.dev/proposal_watch.md` (spec-side)
> with performance + usability lenses, with local measurements.

Date: 2026-07-06. Method: reference clones refreshed to HEAD (wasmtime
bed982ee 48.0-dev / wasmer dcd3261 7.2.0 / WAMR 9bc0cda 2.4.3 / WasmEdge
c5883b8 0.17.0 / wazero c0f3a4e 1.12 / wasm3 d77cd81 / extism ea21512),
4 parallel repo-survey agents with file-level citations, plus LOCAL
EXPERIMENTS (nix binaries wasmtime 45.0.0 / wasmer 7.1.0 / wazero 1.12.0;
zwasm v2.1.0 ReleaseSafe; hyperfine; wasm-tools probes). Read-only — no
zwasm changes. Detailed per-runtime digests: see the agent outputs
summarized inline; every claim below carries repo-file or measured
evidence.

## 0. Measured reality (this machine, arm64 macOS, hyperfine)

### Compute-heavy (shootout corpus, mean ms, 5 runs + 2 warmup)

| bench    | zwasm-jit | wasmtime | wasmer | wazero | zwasm/wasmtime |
|----------|-----------|----------|--------|--------|----------------|
| base64   | 695       | 55.7     | 57.0   | 80.5   | **12.5x** |
| heapsort | 1952      | 641      | 655    | 930    | 3.0x |
| keccak   | 37.3      | 9.2      | 9.3    | 7.5    | 4.1x |
| matrix   | 381       | 96.9     | 92.8   | 198    | 3.9x |
| fib2     | 1268      | 723      | 733    | 798    | 1.75x |

### Startup-dominated (c_hello_wasi, 10 runs)

| runtime      | mean ms |
|--------------|---------|
| zwasm-interp | **3.4** |
| zwasm-jit    | **5.2** |
| wasmtime     | 7.3     |
| wasmer       | 9.6     |
| wazero       | 16.4    |

### AOT artifact (matrix, precompiled)

zwasm .cwasm 376ms vs wasmtime .cwasm 88ms — same ~4x ratio as JIT:
the gap is **codegen quality**, not compile mode.

Interpretation: the optimizing-tier absence costs 1.7–12x on sustained
compute (base64 = bulk/SIMD-friendly inner loops is worst). zwasm wins
the latency/lean axis: fastest cold-start of all five configurations,
and small binary. This is exactly the "lightweight-yet-fast" trade —
today we have lightweight-and-fast-start, not fast-compute.

### Spec probes (local, wasm-tools-built modules)

- threads opcodes: `(memory 1 1 shared)` + `i32.atomic.load` +
  `memory.atomic.wait32` RUN on zwasm (both engines; wait32 correctly
  returned 1/not-equal). wasmtime default REJECTS shared memory
  (needs `-W threads`). → zwasm has single-agent atomics; the missing
  piece is MULTI-AGENT execution (spawn, cross-thread wait/notify,
  shared Memory object across instances), not the opcode set.
- wide-arithmetic: `i64.add128` computes correctly on zwasm (6/8 halves).
- custom-page-sizes: `(memory 65536 65536 (pagesize 1))` → memory.size
  65536 on zwasm, identical to wasmtime `-W custom-page-sizes`.

## 1. Spec/proposal gaps

### zwasm LACKS (with who has it)

| gap | who has it | status there | zwasm posture |
|-----|-----------|--------------|----------------|
| Threads multi-agent execution (spawn/shared-Memory-across-instances; wasi-threads; lib-pthread) | wasmtime (flag, tier-2), WAMR (lib-pthread + wasi-threads + thread-mgr), wasmer (WASIX thread_spawn/futex) | shipped/flag | v0.2.0 intent (proposal_watch); opcodes ALREADY implemented single-agent (ADR-0168) |
| WASI 0.3 / CM-async (streams/futures/async funcs) | wasmtime: in-tree preview (`component-model-async` feature, crates/wasi/src/p3/) | EXPERIMENTAL | post-v0.2.0 (D-335); wasmtime is the only mover |
| Stack-switching (wasmfx) | wasmtime only (x86_64-linux, tier-3) | EXPERIMENTAL | DEFER (D-300) — correct call, format unstable |
| Shared-everything-threads | wasmtime knob exists, unimplemented | EXP | watch only |
| Branch-hinting CONSUMPTION (bias JIT layout) | wasmtime (flag, tier-3), WAMR (`WASM_ENABLE_BRANCH_HINTS`) | flag | zwasm accepts+ignores (conformant); QoI item |
| Legacy exception-handling (old try/catch opcodes) | wasmtime (legacy knob), WAMR (legacy only!) | shipped | zwasm has modern try_table only — fine unless old toolchains matter |

### zwasm LEADS (verified in their trees — worth knowing)

- **GC + function-references**: wasmer 7.2 has NO GC/func-refs fields in
  `lib/types/src/features.rs`; wazero has no GC at all; wasm3/zware none.
  Only wasmtime/WAMR/WasmEdge are peers.
- **Relaxed-SIMD + modern EH**: WAMR = UNIMPLEMENTED (legacy EH,
  interp-only) per `doc/stability_wasm_proposals.md`. zwasm ships both.
- **Multi-memory on all engines**: WAMR interp-only.
- **WASI 0.2 / Component Model default-ON**: wasmer is WASIX-centric (no
  CM-first story), wazero preview1-only, WAMR/WasmEdge partial/in-progress.
  Peer = wasmtime only.
- **100% Wasm 3.0 incl. memory64+table64 on JIT** (as of v2.1.0/D-475).

## 2. Performance-architecture gaps (all measured or file-cited)

Ranked by measured/likely impact:

1. **No optimizing compiler tier** — wasmtime Cranelift (e-graph/ISLE +
   regalloc2, `cranelift_opt_level`), wasmer Cranelift/LLVM, wazero
   wazevo SSA, WAMR LLVM-JIT/AOT + multi-tier (Fast-JIT→LLVM tier-up).
   Measured cost: 1.7–12x (table above). NOTE: ROADMAP currently pins
   "single-pass, no optimising tier" — closing this is a §-level
   ROADMAP/ADR decision, not a task.
2. **Explicit bounds checks vs guard-page/signal elision** — wasmtime
   `memory_reservation`/`memory_guard_size`/`signals_based_traps`
   (config.rs:1862/1945/3151); WAMR Segue (GS-segment base). This is the
   single biggest *within-single-pass* perf lever zwasm could adopt
   without an optimizing tier. (Likely a large slice of the fib2 1.75x
   floor.)
3. **Copy-on-write memory images + pooling allocator** — wasmtime
   `memory_init_cow` (config.rs:2218), `PoolingAllocationConfig` (~21
   knobs) → microsecond-class re-instantiation for serverless density.
   zwasm has none; matters only if embedding density becomes a target.
4. **Compilation cache** — wasmtime on-disk cache (`Config::cache`,
   crates/cache/) + incremental Cranelift cache; wazero
   `NewCompilationCacheWithDir` (cache.go:34-114). zwasm recompiles every
   run (visible in hello: 5.2ms JIT vs 3.4 interp — compile is ~2ms even
   on trivial modules; on big modules it's the whole story). Cheap,
   high-value, ROADMAP-compatible.
5. **Parallel compilation** — wasmtime `parallel_compilation`
   (config.rs:2150); wazero experimental compilation workers. zwasm
   compiles serially.
6. **Epoch interruption** — wasmtime `epoch_interruption` (config.rs:765):
   near-zero-cost deadline vs zwasm's per-poll flag + fuel. zwasm's
   ADR-0179(a) epoch-counter design note already anticipated this.
7. **Cross-arch AOT** — wasmtime `compile --target` + `-Ccranelift-*`;
   wasmer `compile --target <triple>`; WAMR wamrc targets
   x86/arm/aarch64/thumb/xtensa/mips/riscv{32,64} + XIP + `--cpu-features`.
   zwasm .cwasm is host-arch only.
8. **Static PGO** — WAMR `wamrc --enable-llvm-pgo` + `--gen-prof-file`
   (doc/perf_tune.md:55-81). Requires LLVM tier; N/A short-term.
9. **Fast-interpreter tier** — WAMR fast-interp (threaded pre-transform,
   ~2x interp speed); wasm3 M3 MUSTTAIL continuation-passing +
   register-file + op-fusion (docs/Interpreter.md:44-80). zwasm's interp
   is a correctness oracle by design — optional learning only.
10. **Pulley-style portable bytecode backend** — wasmtime's tier-3
    any-target fallback. Interesting existence proof; not a fit.

## 3. Usability / tooling / ecosystem gaps

### Debugging & observability (zwasm: none of these)

- **DWARF native debugging** (gdb/lldb JIT interface): wasmtime
  `Config::debug_info` + crates/jit-debug + gdbstub; WAMR full
  LLDB/GDB-remote debug-engine incl. interp source-debugging
  (core/iwasm/libraries/debug-engine/).
- **Profiling**: wasmtime `ProfilingStrategy::{PerfMap,JitDump,VTune}` +
  guest profiler (samply); WAMR linux-perf integration + memory
  profiling; wazero FunctionListener (Before/After/Abort + StackIterator,
  experimental/listener.go:35-96) as a tracing hook surface.
- **Coredump on trap** (wasmtime `coredump_on_trap`), **wmemcheck**
  (valgrind-like), `wasmtime explore` (wasm↔disasm HTML), `objdump`.
- zwasm has a good internal debug toolkit (debug_jit_auto) but exposes
  nothing to EMBEDDERS/users.

### Serving / cloud (different product tier — deliberate zwasm non-goals so far)

- `wasmtime serve` (wasi:http proxy world) — one-command HTTP host.
- wasmer: registry (`wasmer run author/pkg`), webc, Edge deploy/app/ssh,
  binfmt_misc, create-exe (currently disabled upstream), journal/snapshot
  time-travel for WASIX.
- WasmEdge: OCI/Kubernetes shims (crun/containerd/runwasi), DB drivers,
  full plugin ecosystem — wasi-nn with llama.cpp/MLX/Whisper/StableDiffusion
  /ffmpeg/OpenCV/zlib/eBPF; the LLM-inference runtime story.
- WAMR: RTOS/embedded matrix (Zephyr/NuttX/ESP-IDF/RT-Thread/VxWorks/SGX),
  56-85KB footprints, XIP, built-in libc for no-WASI targets.

### Embedding surface

- **Async host functions / async store** — wasmtime `async_support`,
  `call_async`, ResourceLimiterAsync. zwasm C/Zig APIs are sync-only.
- **Programmable resource limits** — wasmtime `ResourceLimiter` trait
  (callbacks on grow) vs zwasm's static caps.
- **Per-opcode metering** — wasmer metering middleware
  (`Fn(&Operator)->u64` weights) vs zwasm's coarse fuel units.
- **Language bindings** — wasmtime: Rust/C/C++ official + Python/Go/.NET/
  Ruby; wasmer ~10+; WAMR Go/Python/Rust; WasmEdge Rust/Java/JS; extism
  ~14 host SDKs. zwasm: C + Zig only.
- **Framework layer (extism pattern)** — manifest (URL/path/data + hash),
  capability config (allowed_hosts/paths/timeout), built-in host funcs
  (http/kv/var/log), typed calls, thread-safe CancelHandle. A shell like
  this sits ABOVE the runtime C API; zwasm has nothing equivalent —
  though cljw is effectively zwasm's one bespoke framework consumer.
- **wast runner as user-facing CLI** (`wasmtime wast`), `settings`
  introspection dump.

### Infra practices

- **In-repo differential fuzz harness** — wazero's Rust libFuzzer with
  compiler-vs-interp differential oracle (fuzz_targets/no_diff.rs);
  wasmtime's fuzz/差分 (differential.rs). zwasm ran fuzz CAMPAIGNS
  (smith_v4, fuzz-loader) but has no committed always-on differential
  fuzz target; its interp-as-oracle design is a perfect fit for one.

## 4. Recommendation sketch (NOT scheduled work — for user triage)

ROADMAP-compatible (no §-level deviation, clear value):
1. **Guard-page/signal bounds elision** (perf lever within single-pass;
   biggest legal speedup available; wasmtime/WAMR precedents).
2. **On-disk compilation cache** (wazero-style keyed dir; kills the
   recompile tax; also makes AOT less necessary for CLI users).
3. **Epoch-based interruption** (ADR-0179(a) already sketches it).
4. **Threads completion** (v0.2.0 already the stated intent; opcodes done
   single-agent — remaining = shared Memory across instances + spawn +
   wasi-threads; Win64/ABI-heavy).
5. **Embedder observability hooks** (function listeners / trap coredump /
   perf jitdump emit) — cheap goodwill for the embedding story.
6. **Differential fuzz target in-repo** (interp oracle vs JIT; wazero
   pattern) — locks in the correctness plateau.
7. **Cross-arch AOT targets** (compile --target; the codegen is already
   arch-parameterized; mostly plumbing + linker/reloc formats).

ROADMAP-§-level decisions (need ADR/user ratification first):
8. **Optimizing tier** (measured 1.7–12x; contradicts the standing
   "single-pass only" pin — the numbers above are the evidence base for
   revisiting or re-affirming it).
9. **WASI 0.3 / CM-async** (post-v0.2.0 per proposal_watch; wasmtime
   preview exists to crib from).
10. Product-tier questions (serve/HTTP, registry, plugins, bindings
    beyond C/Zig) — scope philosophy, not engineering gaps.

## Appendix: raw artifacts

- hyperfine JSONs: scratchpad bench/ (session-local)
- probe wat/wasm: /tmp/{threads_probe,wait_probe,cps,wa}.wat
- agent digests: wasmtime/wasmer/WAMR+WasmEdge/wazero-group (4 agents,
  file-level citations embedded above)
