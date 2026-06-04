# C-API survey — how wasmtime / wasmer / wazero engage the C embedding API

**Date**: 2026-06-05
**Citing**: standing user directive ("wasmtime / wasmer / wazero などは C API とどう向き合っているかも
しっかりサーベイ"); also the STOP_BUCKETS "autonomous prep paths → reference-repo enrichment" walk for the
deferred-surface decisions ([[D-269]], [[D-273]]) before any bucket-3 assessment. Clones: `~/Documents/OSS/`
(all three present). zwasm ships the standard **wasm-c-api** (`include/wasm.h`) at gap 0 (293/293, §16.2).

## The three verdicts

1. **Callable funcref-from-table ([[D-269]]) — CHALLENGE (the weakest defer).** In both wasmtime and wasmer
   this is *first-class standard wasm-c-api*, NOT a richer extra: `wasm_table_get → wasm_ref_t* →
   wasm_ref_as_func → wasm_func_call` (upstream `wasm.h:473 / :363 / :445`); wasmtime's typed layer fills a
   `wasmtime_val_t.of.funcref` (`wasmtime/val.h:254`) directly callable by `wasmtime_func_call`. So a host
   doing the *standard* path on a table-derived ref expects a callable func. zwasm's table funcref is an
   opaque `?u64` (D-269) — this defer is below the standard, unlike the other two.
2. **CLI `--invoke` + resource flags ([[D-273]]) — VALIDATE (convenience).** `--invoke` (wasmtime
   `run.rs:51`, wasmer `run/mod.rs:98`+`:519` result-print) and `--fuel`/`--timeout`/`--epoch`/`--env`
   (wasmtime `cli-flags/src/lib.rs:342/345/389`, wasmer `run/wasi.rs:94`) are CLI sugar over the embedder
   API, not C-API requirements. wazero ships exactly `compile`+`run`, no `-invoke`. `run`+`compile` (ADR-0159)
   is a legitimate minimal CLI.
3. **Surface philosophy — VALIDATE strongly.** Every C-API runtime layers (c): standard `wasm.h` PLUS a
   richer own API — wasmtime `wasmtime/*.h` (fuel `store.h:167`, epoch `:224`, serialize `module.h:110`,
   backtrace `trap.h:187`), wasmer `unstable/` (metering, wasi_config). zwasm's "gap-0 wasm-c-api core +
   defer the extras until a consumer needs them" mirrors the field exactly. wazero is pure-Go (no C-API) —
   C-API richness is a CGo-runtime concern, orthogonal to zwasm's C-API-first stance.

## Actionable takeaway

The survey *re-prioritises* D-269: it is a standard-wasm-c-api **behavioral** gap (symbols all exist —
gap=0 — but the table→ref→func→call path may not work), not the "wasmtime-parity nicety, don't-pre-build"
it was filed as. NARROWED question for the fix chunk: `wasm_ref_as_func` (`extern_new.zig:378`) already
decodes a raw payload via `refAsFuncEntity` into a callable Func — does the **table-slot funcref encoding**
(`tab.refs[idx].ref`, `instance.zig:1282`) decode through it? A red C conformance test
(`test/c_api_conformance/`: table.get → ref_as_func → func_call) settles it. D-273 + surface-philosophy
defers are validated as fairly-deferred richer-API extras (ADR-0159 holds).
