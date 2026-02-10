// Run a wasm exported function from CLI.
// Usage: node bench/run_wasm.mjs <file.wasm> <func> [args...]
//        bun  bench/run_wasm.mjs <file.wasm> <func> [args...]

import { readFileSync } from "node:fs";

const [,, wasmPath, funcName, ...rawArgs] = process.argv;
if (!wasmPath || !funcName) {
  console.error("Usage: node run_wasm.mjs <file.wasm> <func> [args...]");
  process.exit(1);
}

const bytes = readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {});
const fn = instance.exports[funcName];
if (typeof fn !== "function") {
  console.error(`Export "${funcName}" is not a function`);
  process.exit(1);
}

const args = rawArgs.map(Number);
const result = fn(...args);
console.log(result);
