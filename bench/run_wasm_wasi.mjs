// Run a WASI command-style .wasm (_start) from CLI.
// Usage: node bench/run_wasm_wasi.mjs <file.wasm>
//        bun  bench/run_wasm_wasi.mjs <file.wasm>
//
// For shootout benchmarks that use _start entry point with printf output.
// Uses Node.js/Bun built-in WASI implementation.

import { readFileSync } from "node:fs";
import { WASI } from "node:wasi";

const [,, wasmPath] = process.argv;
if (!wasmPath) {
  console.error("Usage: node run_wasm_wasi.mjs <file.wasm>");
  process.exit(1);
}

const wasi = new WASI({
  version: "preview1",
  args: [wasmPath],
  env: {},
});

const bytes = readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: wasi.wasiImport,
});

wasi.start(instance);
