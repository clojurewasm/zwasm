# 0136 — `zwasm run --engine=jit`: a JIT-execute CLI path (compute-only)

- **Status**: Accepted (2026-06-03; autonomous per ADR-0132 spirit — unblocks §11.3 + closes a v0.1.0 gap)
- **Date**: 2026-06-03
- **Author**: claude (autonomous; §11.3 SIMD-gap bundle)
- **Tags**: CLI, engine pipeline, JIT, SIMD, §11.3, D-244, WASI-under-JIT
- **Amends**: ROADMAP §4.3 (engine pipeline — adds a runtime engine-selection seam to the CLI);
  `src/cli/main.zig` (argparse), `src/cli/run.zig` (dispatch); D-244

## Context

`zwasm run` routes through the C-API (`run.zig` → `instance.zig wasm_func_call` →
`dispatch.run`) — the **interpreter**, which has **no SIMD execution** (SIMD is JIT-only by
design; the interp per-op SIMD handlers are `NotMigrated` stubs, `simd_assert_runner` is
JIT-execute — D-244). `build_options.engine_mode` (interp/jit/both) is **discarded at
runtime** (`main.zig:179 _ = build_options.engine_mode`), so the CLI is interp-only and traps
`Unreachable` on any SIMD op. Two consequences:

1. **§11.3 (SIMD per-op gap analysis) is blocked**: it must bench zwasm's *JIT* SIMD against
   wasmtime/wazero/wasmer, but there is no CLI/bench path that JIT-executes a module.
2. **Standalone v0.1.0 product gap**: the CLI cannot run SIMD (a wasm-2.0 feature) at all,
   despite the binary advertising `wasm-level: v3_0`.

The JIT-execute machinery already exists and is production (used by the spec SIMD runner):
`engine.runner.compileWasm(alloc, bytes) → CompiledWasm` + `runVoidExport(alloc, bytes,
export_name)` / `runI32Export` (`src/engine/runner.zig:238-369`), built on
`setup.setupRuntime` + `codegen/shared/entry.callX*`. It is **compute-only**: WASI under the
JIT is skeleton-stubbed (`src/wasi/jit_dispatch.zig` — `fd_write` bounds-checks but does not
write stdout; `proc_exit` traps without carrying an exit code; the real I/O + exit-code
plumbing is the deferred "d-3" follow-up).

## Decision

Add a **`zwasm run --engine=<interp|jit>` flag** (default `interp` = the current C-API path —
no behaviour change for existing invocations). `--engine=jit` routes to a new slim
`run.zig` path that calls `runner.compileWasm` + `runVoidExport` (or `--invoke <name>` →
the named export) and surfaces success/trap as exit 0/1.

**Scope (deliberately compute-only for now):**

- `--engine=jit` runs the entry's compute to completion; SIMD / pure-compute modules work.
- **WASI I/O + exit-code under JIT is OUT OF SCOPE here** — a `--engine=jit` run of a realworld
  WASI tool will compute but not produce stdout / honour `proc_exit`'s code (it traps). That
  plumbing is the pre-existing "d-3" JIT-WASI follow-up, tracked separately; `--engine=jit`
  documents the limitation in `--help` and is intended for compute/bench use. The interp path
  remains the default and the full-WASI path.
- Default stays `interp`: realworld WASI CLI use is unaffected.

This is the **non-workaround** choice: it exposes the real JIT executor through the CLI
(fixing the compute-SIMD gap as a genuine product capability) rather than a bench-only private
harness. §11.3's SIMD micro-benches are compute-only, so `--engine=jit` is exactly sufficient
to bench zwasm JIT SIMD via `run_bench.sh` (the `cmd="$ZWASM run --engine=jit $wasm"` form).

### Changes

1. `src/cli/main.zig`: parse `--engine <interp|jit>` in the `run` flag loop (alongside
   `--invoke` / `--dir`); thread the choice into the run dispatch.
2. `src/cli/run.zig`: add `runWasmJit(alloc, io, bytes, invoke_name) !u8` — `compileWasm` +
   `runVoidExport`/named-export; map JIT errors → exit 1, success → 0. `--engine=jit` with
   `--dir` is rejected (no WASI-under-JIT yet).
3. A CLI/integration test: a SIMD `_start` module runs (exit 0) via `--engine=jit` and traps
   (exit ≠ 0) via the default interp — the red→green observable.

## Consequences

- **D-244 partially discharged**: compute SIMD (and any compute module) is now runnable via the
  CLI (`--engine=jit`). The residual (WASI I/O + exit-code under JIT) stays in D-244 / the d-3
  follow-up.
- **§11.3 unblocked**: `run_bench.sh` can bench zwasm JIT SIMD by invoking `run --engine=jit`
  on the SIMD micro-bench corpus (compute-only fixtures, no WASI).
- Zone-legal: `cli/` (Zone 3) → `engine/` (Zone 2) import is allowed; no cross-arch import.
- The default-interp invariant means no realworld / WASI regression; the new path is opt-in.
