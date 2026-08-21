// compute_mix.ts — deterministic compute kernels over AssemblyScript's
// default (incremental-GC) runtime, printed via @assemblyscript/wasi-shim's
// console.log (fd_write). The corpus value is the emitter: AssemblyScript
// compiles through Binaryen, a code generator no other fixture family
// (LLVM: c/cpp/rust/zig/emcc; Go SSA: go; TinyGo/LLVM: tinygo) covers.
//
// Kernels are chosen so the module exercises u64 arithmetic + formatting,
// linear-memory typed arrays, branchy loops, IEEE-exact f64 (sqrt), and
// UTF-16 string building — all with externally checkable or
// engine-independent results. No time, randomness, or environment input.

// Iterative Fibonacci — u64 add/rotate chain; fib(90) is the largest line
// the u64 decimal formatter sees. Known value: 2880067194370816120.
function fibIter(n: i32): u64 {
  let a: u64 = 0;
  let b: u64 = 1;
  for (let i = 0; i < n; i++) {
    const t = a + b;
    a = b;
    b = t;
  }
  return a;
}

// Sieve of Eratosthenes over a Uint8Array — linear-memory stores + nested
// loops. pi(10000) = 1229 (externally checkable).
function sieveCount(limit: i32): i32 {
  const composite = new Uint8Array(limit);
  let count = 0;
  for (let i = 2; i < limit; i++) {
    if (!composite[i]) {
      count++;
      for (let j = i * i; j < limit; j += i) composite[j] = 1;
    }
  }
  return count;
}

// LCG-filled buffer (Numerical Recipes constants) — the deterministic
// stand-in for "input data"; no wasi random_get involved.
function makeBuf(n: i32): Uint8Array {
  const buf = new Uint8Array(n);
  let state: u32 = 0x12345678;
  for (let i = 0; i < n; i++) {
    state = state * 1664525 + 1013904223;
    buf[i] = <u8>(state >> 24);
  }
  return buf;
}

// FNV-1a 64-bit — u64 xor/mul over every byte; the checksum both engines
// must reproduce bit-for-bit.
function fnv1a(buf: Uint8Array): u64 {
  let h: u64 = 0xcbf29ce484222325;
  for (let i = 0; i < buf.length; i++) {
    h ^= buf[i];
    h *= 0x100000001b3;
  }
  return h;
}

// Sum of square roots — f64.sqrt is IEEE-exact (correctly rounded), so the
// accumulated sum and its Ryu-formatted decimal are engine-independent.
function sqrtSum(n: i32): f64 {
  let s: f64 = 0;
  for (let i = 1; i <= n; i++) {
    s += Math.sqrt(<f64>i);
  }
  return s;
}

console.log("fib(90) = " + fibIter(90).toString());
console.log("primes below 10000 = " + sieveCount(10000).toString());
console.log("fnv1a(lcg[4096]) = 0x" + fnv1a(makeBuf(4096)).toString(16));
console.log("sum sqrt(1..1000) = " + sqrtSum(1000).toString());

// String building through the GC'd string heap (UTF-16 internally,
// converted to UTF-8 by the shim at the fd_write boundary).
let squares = "";
for (let i = 0; i < 8; i++) {
  if (i > 0) squares += ",";
  squares += (i * i).toString();
}
console.log("squares = " + squares);
