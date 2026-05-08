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
#   bash scripts/run_bench.sh --windows-subset    # 5-fixture fast subset
#                                                 # (§9.8 / 8.3) — for use on
#                                                 # windowsmini SSH host where
#                                                 # the full inventory takes
#                                                 # 5+ hours; ~250-400ms/fixture
#                                                 # × 5 × 3-runs ≈ 6s total.
#                                                 # Subset: shootout/nestedloop
#                                                 # + tinygo/{arith,fib,sieve,tak}
#                                                 # (all <30ms on Linux baseline;
#                                                 # ~12x slower on Win = under 1s).
#   bash scripts/run_bench.sh --phase-record \
#        --reason='<phase-tag>: <gist>'           # ALSO append to history.yaml
#
# Per ADR-0012 §7: recent.yaml gitignored, history.yaml committed
# at phase boundaries only.
#
# `--phase-record` writes one history.yaml entry tagged with the
# current commit + arch + the supplied --reason. Without
# --phase-record, recent.yaml is overwritten in place.
#
# CI (.github/workflows/bench.yml) invokes this script with
# `--quick --phase-record --reason="CI: ..."` on each push to
# zwasm-from-scratch; the per-arch entry is then extracted via
# scripts/append_bench_to_history.sh and aggregated into one bot
# commit. Local users do not call append_bench_to_history.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
PHASE_RECORD=0
WINDOWS_SUBSET=0
BENCH=""
REASON=""
DIFF_REF=""
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --phase-record) PHASE_RECORD=1 ;;
        --windows-subset) WINDOWS_SUBSET=1; QUICK=1 ;;
        --bench=*) BENCH="${arg#--bench=}" ;;
        --reason=*) REASON="${arg#--reason=}" ;;
        --diff=*) DIFF_REF="${arg#--diff=}" ;;
        --diff)  ;;  # next iteration provides ref via positional pickup; see below
    esac
done
# §9.8a / 8a.3 — `--diff <ref>` (space-separated form). The
# `case` loop above only handles `--diff=<ref>`; pick up the
# space-separated form by walking $@ pairwise.
prev=""
for arg in "$@"; do
    if [ "$prev" = "--diff" ] && [ -z "$DIFF_REF" ]; then
        DIFF_REF="$arg"
    fi
    prev="$arg"
done

# §9.8 / 8.3 — Windows subset: 5 fast fixtures (all <30ms on Linux
# baseline). At Mac:Win ~12x ratio observed in Phase 7 close, this
# is ~250-400ms/fixture × 3 quick-runs ≈ 6s total. Use on
# windowsmini SSH host where the full 26-fixture inventory takes
# 5+ hours and is incompatible with inline gate cadence.
WINDOWS_SUBSET_NAMES=(
    "shootout/nestedloop"
    "tinygo/arith"
    "tinygo/fib"
    "tinygo/sieve"
    "tinygo/tak"
)

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
    if [ "$WINDOWS_SUBSET" -eq 1 ]; then
        in_subset=0
        for sub in "${WINDOWS_SUBSET_NAMES[@]}"; do
            if [ "$sub" = "$name" ]; then in_subset=1; break; fi
        done
        if [ "$in_subset" -eq 0 ]; then continue; fi
    fi
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

# §9.8a / 8a.3 — `--diff <ref>` mode: produce a markdown delta
# table comparing recent.yaml against the history.yaml entry at
# `<ref>`. Output goes to stdout (caller redirects). Per
# ADR-0032 + LOOP.md Step 5b.
if [ -n "$DIFF_REF" ]; then
    HIST=bench/results/history.yaml
    if [ ! -f "$HIST" ]; then
        echo "[run_bench] --diff requires $HIST; absent." >&2
        exit 2
    fi
    target_sha=$(git rev-parse --verify "$DIFF_REF^{commit}" 2>/dev/null || true)
    if [ -z "$target_sha" ]; then
        echo "[run_bench] --diff: cannot resolve ref '$DIFF_REF' to a commit" >&2
        exit 2
    fi
    # Extract the FIRST history.yaml entry whose `commit:` matches
    # the resolved SHA (or its prefix). yq's filter selects all
    # matching entries; we keep position 0.
    baseline_tmp=$(mktemp)
    trap 'rm -f "$baseline_tmp"' EXIT
    yq "[.[] | select(.commit | test(\"^${target_sha:0:12}\"))][0:1]" "$HIST" > "$baseline_tmp"
    if [ ! -s "$baseline_tmp" ] || [ "$(yq '. | length' "$baseline_tmp")" = "0" ]; then
        echo "[run_bench] --diff: no history.yaml entry matches commit prefix ${target_sha:0:12}" >&2
        exit 2
    fi
    bash scripts/record_bench_delta.sh "$baseline_tmp" "$RECENT" "vs $DIFF_REF (${target_sha:0:12})"
fi
