#!/bin/bash
# Build all TinyGo benchmarks to wasm.
# Requires: tinygo (brew install tinygo or nix)
# Usage: bash bench/tinygo/build.sh
#
# Sources:
#   arith.go, fib.go, tak.go, sieve.go — original for zwasm benchmarks
#   fib_loop.go, gcd.go — ported from ClojureWasm bench/tinygo/
#   nqueens.go, mfr.go, list_build.go, real_work.go, string_ops.go
#     — ported from ClojureWasm bench/benchmarks/ (diverse workload patterns)
#
# Build flags: -gc=leaking -scheduler=none minimizes wasm size (~9KB vs ~22KB)

set -euo pipefail
cd "$(dirname "$0")"

OUTDIR="../wasm"

build_one() {
  local name="$1" src="$2"
  shift 2
  local out="${OUTDIR}/tgo_${name}.wasm"
  echo -n "  $name -> tgo_${name}.wasm ... "
  tinygo build -o "$out" -target=wasi -no-debug -gc=leaking -scheduler=none -opt=2 "$@" "$src"
  echo "$(wc -c < "$out" | tr -d ' ') bytes"
}

build_one arith arith.go
build_one fib fib.go
build_one fib_loop fib_loop.go
build_one gcd gcd.go
build_one tak tak.go
# sieve needs more initial memory for 1M elements
build_one sieve sieve.go -ldflags "-extldflags --initial-memory=2097152"
# New diverse-workload benchmarks (ported from ClojureWasm)
build_one nqueens nqueens.go
build_one string_ops string_ops.go
# mfr/list_build use linear memory scratch (small arrays, default 128KB is enough)
build_one mfr mfr.go
build_one list_build list_build.go
# real_work needs 32MB for 2M+ records (12 bytes each)
build_one real_work real_work.go -ldflags "-extldflags --initial-memory=33554432"

echo "Done."
