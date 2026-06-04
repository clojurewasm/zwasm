# C-API surface audit (§16.2) — 2026-06-04

> **Doc-state**: ACTIVE

Audit of `include/wasm.h` + `src/api/` against the upstream **wasm-c-api**
standard (the interface wasmtime/wasmer follow; ADR-0004 pin). Reference clones
updated to latest first (this area moves fast): `OSS/wasm-c-api` HEAD `9d6b937`
2026-03-19 (the base spec itself is stable; the churn is in runtime-specific
*extensions*, not the base header), `OSS/wasmtime`/`wasmer`/`wazero` early-June.

## Headline

- **Our `include/wasm.h` is byte-identical to upstream latest** (`diff -q` clean,
  737 lines). We ship the verbatim standard — correct posture (wasmtime vendors a
  verbatim copy; wasmer symlinks the submodule header). Do NOT fork/trim it.
- **But the implementation is incomplete: 129 of 293 standard extern functions
  are declared-but-unimplemented.** A C consumer calling e.g. `wasm_func_type()`
  link-errors. Live count: `bash scripts/capi_surface_gap.sh` (293 owed / 164
  impl / 129 gap). Exports are literal `export fn wasm_*` only (no `@export` /
  comptime generator), so the diff is authoritative.

## Industry stance (how runtimes engage with the C-API)

- **wasmtime** — verbatim upstream `wasm.h` + large `wasmtime.h` extension
  (config richness, async, fuel/epoch, linker, GC refs, serialize, dual
  error+trap returns). Implements 100% of standard `wasm.h`.
- **wasmer** — submodule `wasm.h` + `wasmer.h` (backend select, WASI unstable).
  Implements 100% of standard; EXNREF parsed but "not supported".
- **wazero** — **NO C-API at all** (pure-Go, cgo-free is a selling point). A
  top-tier runtime deliberately skipping the C-API for a native-language
  embedding API — validates zwasm v2's Zig-native-first API as primary.
- **wasm3** — custom `wasm3.h` (M3 namespace), not wasm-c-api.
- **Decision**: implement the **full standard `wasm.h` surface** (the bar for a
  serious C-API). Do NOT add wasmtime's 60+ extension headers — a
  slimmed-but-complete standard-compliant C-API fits the lightweight-yet-fast +
  あるべき論 bar (ADR-0156). v128 absent from `wasm_val_t` stays absent (industry
  consensus; lesson `c_api-v128-spec-boundary`).

## Gap categories + sequencing (129)

| Cat | ~n | Group | Design decision? | Plan |
|-----|----|-------|------------------|------|
| A | 6  | type accessors: `wasm_{func,global,table,memory}_type`, `wasm_func_{param,result}_arity` | none (reuse `module_introspect` builders) | **chunk 1** |
| B | ~30| per-type vec ops (functype/globaltype/tabletype/memorytype/tagtype `_vec_*` + extern/frame/import/export `_vec_copy`) | none (vec.zig generic) | chunk 2 |
| C | 3  | `wasm_config_new/_delete`, `wasm_engine_new_with_config` | minor (opaque config) | chunk 3 |
| D | 2  | `wasm_val_copy`, `wasm_val_delete` | minor (ref payload) | chunk 3 |
| E | ~71| ref-cast (`_as_ref`/`ref_as_*`), `_same`, `_copy`, host_info trio across 9 ref types | **yes — uniform ref model + per-object host_info slot** | D-253; informed by §16.5 dogfooding |
| F | 12 | `wasm_tagtype_*` (EH proposal; our runtime supports EH) | medium | after E |
| G | 5  | `wasm_module_serialize/_deserialize/_share/_obtain`, `wasm_shared_module_delete` | **yes — artifact persistence + shared modules** | heaviest; own ADR |

A–D are the no-/low-design-decision subset (close now). E is the D-253 bulk
(foreign+host_info + funcref cross-cast already done). G is the heavyweight.

## Tracking

Bundle `16.2-capi-completion` (handover). Debt: D-253 (E subset), D-269 (this
audit / full gap). Progress = `scripts/capi_surface_gap.sh` gap count → 0.
