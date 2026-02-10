#!/bin/bash
# Build all TinyGo benchmarks to wasm.
# Requires: tinygo (brew install tinygo or nix)
# Usage: bash bench/tinygo/build.sh

set -euo pipefail
cd "$(dirname "$0")"

OUTDIR="../wasm"

build_one() {
  local name="$1" src="$2"
  shift 2
  local out="${OUTDIR}/tgo_${name}.wasm"
  echo -n "  $name -> tgo_${name}.wasm ... "
  tinygo build -o "$out" -target=wasi -no-debug -opt=2 "$@" "$src"
  echo "$(wc -c < "$out" | tr -d ' ') bytes"
}

build_one arith arith.go
build_one fib fib.go
build_one tak tak.go
# sieve needs more initial memory for 1M elements
build_one sieve sieve.go -ldflags "-extldflags --initial-memory=2097152"

echo "Done."
