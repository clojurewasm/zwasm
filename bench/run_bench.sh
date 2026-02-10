#!/bin/bash
# zwasm benchmark script
# Usage: bash bench/run_bench.sh [--quick]

set -e
cd "$(dirname "$0")/.."

QUICK=false
if [ "$1" = "--quick" ]; then
    QUICK=true
fi

echo "Building zwasm (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

echo ""
echo "=== zwasm fib(35) benchmark ==="
if [ "$QUICK" = true ]; then
    hyperfine --warmup 1 --runs 1 './zig-out/bin/fib_bench 35'
else
    hyperfine --warmup 2 --runs 5 './zig-out/bin/fib_bench 35'
fi
