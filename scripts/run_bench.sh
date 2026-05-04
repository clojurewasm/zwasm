#!/usr/bin/env bash
# scripts/run_bench.sh — interactive bench runner via hyperfine.
#
# Builds zwasm in ReleaseSafe and runs each fixture in
# bench/runners/wasm/{shootout,tinygo,handwritten}/*.wasm + the
# 5 cljw_*.wasm guests from test/realworld/wasm/ (per §9.6 / 6.G).
# Writes results to bench/results/recent.yaml.
#
# Usage:
#   bash scripts/run_bench.sh                     # full (5 runs + 3 warmup)
#   bash scripts/run_bench.sh --quick             # quick (3 runs + 1 warmup)
#   bash scripts/run_bench.sh --bench=<name>      # single bench by name
#   bash scripts/run_bench.sh --phase-record \
#        --reason='<phase-tag>: <gist>'           # ALSO append to history.yaml
#
# Per ADR-0012 §7: recent.yaml gitignored, history.yaml committed
# at phase boundaries only.
#
# `--phase-record` writes one history.yaml entry tagged with the
# current commit + arch + the supplied --reason. Without
# --phase-record, recent.yaml is overwritten in place.

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
PHASE_RECORD=0
BENCH=""
REASON=""
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --phase-record) PHASE_RECORD=1 ;;
        --bench=*) BENCH="${arg#--bench=}" ;;
        --reason=*) REASON="${arg#--reason=}" ;;
    esac
done

if ! command -v hyperfine >/dev/null 2>&1; then
    echo "[run_bench] hyperfine not on PATH; aborting (the dev shell pins it via flake.nix)." >&2
    exit 1
fi

echo "[run_bench] building ReleaseSafe..."
zig build -Doptimize=ReleaseSafe >&2

ZWASM=./zig-out/bin/zwasm
if [ ! -x "$ZWASM" ]; then
    echo "[run_bench] $ZWASM not present after build" >&2
    exit 1
fi

# Bench inventory: layer/name → wasm path. Layer is the
# directory hierarchy (per ADR-0012 §4 file-naming-by-hierarchy).
BENCHES=(
    # Sightglass shootout (pre-built without bench::start/end harness)
    "shootout/fib2:bench/runners/wasm/shootout/fib2.wasm"
    "shootout/sieve:bench/runners/wasm/shootout/sieve.wasm"
    "shootout/nestedloop:bench/runners/wasm/shootout/nestedloop.wasm"
    "shootout/matrix:bench/runners/wasm/shootout/matrix.wasm"
    "shootout/heapsort:bench/runners/wasm/shootout/heapsort.wasm"
    "shootout/base64:bench/runners/wasm/shootout/base64.wasm"
    "shootout/gimli:bench/runners/wasm/shootout/gimli.wasm"
    "shootout/memmove:bench/runners/wasm/shootout/memmove.wasm"
    "shootout/keccak:bench/runners/wasm/shootout/keccak.wasm"
    # TinyGo WASI guests
    "tinygo/arith:bench/runners/wasm/tinygo/arith.wasm"
    "tinygo/fib:bench/runners/wasm/tinygo/fib.wasm"
    "tinygo/fib_loop:bench/runners/wasm/tinygo/fib_loop.wasm"
    "tinygo/gcd:bench/runners/wasm/tinygo/gcd.wasm"
    "tinygo/list_build:bench/runners/wasm/tinygo/list_build.wasm"
    "tinygo/mfr:bench/runners/wasm/tinygo/mfr.wasm"
    "tinygo/nqueens:bench/runners/wasm/tinygo/nqueens.wasm"
    "tinygo/real_work:bench/runners/wasm/tinygo/real_work.wasm"
    "tinygo/sieve:bench/runners/wasm/tinygo/sieve.wasm"
    "tinygo/string_ops:bench/runners/wasm/tinygo/string_ops.wasm"
    "tinygo/tak:bench/runners/wasm/tinygo/tak.wasm"
    # Hand-written
    "handwritten/nbody:bench/runners/wasm/handwritten/nbody.wasm"
    # ClojureWasm v1 (vendored at §9.6 / 6.G into test/realworld/wasm/)
    "cljw/fib:test/realworld/wasm/cljw_fib.wasm"
    "cljw/gcd:test/realworld/wasm/cljw_gcd.wasm"
    "cljw/arith:test/realworld/wasm/cljw_arith.wasm"
    "cljw/sieve:test/realworld/wasm/cljw_sieve.wasm"
    "cljw/tak:test/realworld/wasm/cljw_tak.wasm"
)

mkdir -p bench/results
RECENT=bench/results/recent.yaml

if [ $QUICK -eq 1 ]; then
    RUNS=3; WARMUP=1
else
    RUNS=5; WARMUP=3
fi

case "$(uname -s -m)" in
    "Darwin arm64")    arch="aarch64-darwin" ;;
    "Linux x86_64")    arch="x86_64-linux" ;;
    "MINGW"*|"MSYS"*)  arch="x86_64-windows" ;;
    *)                 arch="$(uname -s -m | tr ' ' -)" ;;
esac

commit=$(git rev-parse HEAD)
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# header
{
    echo "# bench/results/recent.yaml"
    echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/run_bench.sh"
    echo "# Schema in bench/README.md."
    echo "- date: $date"
    echo "  commit: $commit"
    echo "  arch: $arch"
    echo "  reason: \"local recent run (runs=$RUNS warmup=$WARMUP)\""
    echo "  runs: $RUNS"
    echo "  warmup: $WARMUP"
    echo "  benches:"
} > "$RECENT"

ran_any=0
for entry in "${BENCHES[@]}"; do
    name="${entry%%:*}"
    wasm="${entry#*:}"
    if [ -n "$BENCH" ] && [ "$name" != "$BENCH" ]; then
        continue
    fi
    if [ ! -f "$wasm" ]; then
        echo "[run_bench] missing $wasm — skipping $name" >&2
        continue
    fi
    echo "[run_bench] $name ($wasm)"
    json=$(mktemp)
    hyperfine --warmup "$WARMUP" --runs "$RUNS" \
        --shell=none \
        --export-json "$json" \
        "$ZWASM run $wasm" >/dev/null 2>&1 || {
        echo "    (failed; logging null)" >&2
        rm -f "$json"
        cat <<EOF >> "$RECENT"
    - name: $name
      mean_ms: null
      stddev_ms: null
      min_ms: null
      max_ms: null
EOF
        continue
    }
    mean=$(grep -oE '"mean": [0-9.]+' "$json" | head -1 | awk '{print $2 * 1000}')
    stddev=$(grep -oE '"stddev": [0-9.]+' "$json" | head -1 | awk '{print $2 * 1000}')
    min=$(grep -oE '"min": [0-9.]+' "$json" | head -1 | awk '{print $2 * 1000}')
    max=$(grep -oE '"max": [0-9.]+' "$json" | head -1 | awk '{print $2 * 1000}')
    rm -f "$json"
    cat <<EOF >> "$RECENT"
    - name: $name
      mean_ms: $(printf "%.2f" "$mean")
      stddev_ms: $(printf "%.2f" "$stddev")
      min_ms: $(printf "%.2f" "$min")
      max_ms: $(printf "%.2f" "$max")
EOF
    ran_any=1
done

if [ $ran_any -eq 0 ]; then
    echo "[run_bench] no benchmarks ran (BENCH=$BENCH not in inventory)" >&2
    exit 2
fi

echo "[run_bench] wrote $RECENT"

if [ $PHASE_RECORD -eq 1 ]; then
    HIST=bench/results/history.yaml
    if [ -z "$REASON" ]; then
        REASON="phase boundary (auto): $(git log -1 --format='%s')"
    fi
    {
        echo ""
        echo "- date: $date"
        echo "  commit: $commit"
        echo "  arch: $arch"
        echo "  reason: \"$REASON\""
        echo "  runs: $RUNS"
        echo "  warmup: $WARMUP"
        echo "  benches:"
        # copy benches from recent.yaml (everything indented 4 spaces)
        awk '/^  benches:/,EOF' "$RECENT" | tail -n +2
    } >> "$HIST"
    echo "[run_bench] appended phase-record entry to $HIST"
fi
