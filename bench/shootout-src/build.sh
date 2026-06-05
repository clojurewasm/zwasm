#!/usr/bin/env bash
# Build the sightglass shootout benchmarks (C → wasm32-wasi) for the
# zwasm v2 bench corpus (ADR-0163 A breadth expansion). Mac host only;
# the emitted .wasm is committed + run on every host by the edge-runner.
#
# Source provenance: PROVENANCE.txt. Sources are upstream Bytecode
# Alliance sightglass (Apache-2.0), curated (no-op sightglass.h;
# ackermann hardcoded M=3,N=11) — externally-authored artifacts, so the
# no-copy-from-v1 rule does not apply (cf. the spec testsuite).
#
# Recipe matches v1 (zig cc, no wasi-sdk needed). zig is on PATH in the
# default + .#gen dev shells.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../runners/wasm/shootout"
mkdir -p "$OUT_DIR"

# Only the fixtures NOT already vendored as .wasm at §9.6 (those 9 —
# base64/fib2/gimli/heapsort/keccak/matrix/memmove/nestedloop/sieve —
# stay as-is). These 10 add crypto / dispatch / parsing / PRNG breadth.
SOURCES=(ackermann ctype ed25519 minicsv random ratelimit seqhash switch xblabla20 xchacha20)

CFLAGS="-target wasm32-wasi -O2 -I$SCRIPT_DIR -lc -Wl,--strip-all"
built=0; failed=0
for name in "${SOURCES[@]}"; do
    src="$SCRIPT_DIR/${name}.c"
    out="$OUT_DIR/${name}.wasm"
    [ -f "$src" ] || { echo "SKIP: $src not found"; continue; }
    if zig cc $CFLAGS "$src" -o "$out" 2>/dev/null; then
        echo "  OK: ${name}.wasm ($(wc -c < "$out") bytes)"
        built=$((built + 1))
    else
        echo "FAIL: ${name}.wasm"; zig cc $CFLAGS "$src" -o "$out" 2>&1 | head -5 || true
        failed=$((failed + 1))
    fi
done
echo ""; echo "Built: $built / ${#SOURCES[@]}, Failed: $failed"
