// Run a wasm exported function from CLI with optional WASI support.
// Usage: node bench/run_wasm.mjs <file.wasm> <func> [args...]
//        bun  bench/run_wasm.mjs <file.wasm> <func> [args...]
//
// Handles both pure wasm (no imports) and WASI modules (TinyGo etc.).
// For WASI modules, provides minimal stubs — sufficient for benchmarks
// that only use exported functions without WASI I/O.

import { readFileSync } from "node:fs";

const [,, wasmPath, funcName, ...rawArgs] = process.argv;
if (!wasmPath || !funcName) {
  console.error("Usage: node run_wasm.mjs <file.wasm> <func> [args...]");
  process.exit(1);
}

const bytes = readFileSync(wasmPath);

// Minimal WASI stubs for modules that import wasi_snapshot_preview1
// but don't actually use I/O (e.g., TinyGo benchmarks invoked via --invoke).
const wasiStubs = {
  args_get: () => 0,
  args_sizes_get: (argc_ptr, argv_buf_size_ptr) => {
    // Return 0 args
    const mem = new DataView(instance.exports.memory.buffer);
    mem.setUint32(argc_ptr, 0, true);
    mem.setUint32(argv_buf_size_ptr, 0, true);
    return 0;
  },
  environ_get: () => 0,
  environ_sizes_get: (count_ptr, size_ptr) => {
    const mem = new DataView(instance.exports.memory.buffer);
    mem.setUint32(count_ptr, 0, true);
    mem.setUint32(size_ptr, 0, true);
    return 0;
  },
  clock_time_get: (id, precision, time_ptr) => {
    const mem = new DataView(instance.exports.memory.buffer);
    mem.setBigUint64(time_ptr, BigInt(Date.now()) * 1000000n, true);
    return 0;
  },
  fd_write: (fd, iovs, iovs_len, nwritten_ptr) => {
    // Silently discard output
    const mem = new DataView(instance.exports.memory.buffer);
    let total = 0;
    for (let i = 0; i < iovs_len; i++) {
      total += mem.getUint32(iovs + i * 8 + 4, true);
    }
    mem.setUint32(nwritten_ptr, total, true);
    return 0;
  },
  fd_read: () => 0,
  fd_close: () => 0,
  fd_seek: () => 0,
  fd_fdstat_get: () => 0,
  fd_prestat_get: () => 8, // EBADF — no preopens
  fd_prestat_dir_name: () => 8,
  proc_exit: (code) => { process.exit(code); },
  random_get: (buf, len) => {
    const mem = new Uint8Array(instance.exports.memory.buffer);
    for (let i = 0; i < len; i++) mem[buf + i] = Math.random() * 256 | 0;
    return 0;
  },
};

let instance;
try {
  const result = await WebAssembly.instantiate(bytes, {});
  instance = result.instance;
} catch (e) {
  // Needs WASI imports
  const result = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: wasiStubs,
  });
  instance = result.instance;
}

const fn = instance.exports[funcName];
if (typeof fn !== "function") {
  console.error(`Export "${funcName}" is not a function`);
  process.exit(1);
}

const args = rawArgs.map(Number);
const result = fn(...args);
console.log(result);
