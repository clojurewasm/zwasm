#!/usr/bin/env bash
# bench_watch.sh — gross-regression detector (ADR-0211 D2).
#
# Builds HEAD and the latest `v*` release tag in the same invocation, runs the
# 5-fixture watch subset on both binaries back-to-back on the SAME machine
# (one hyperfine call per fixture, comparing the two commands), and exits 1
# when HEAD is >= 2.0x slower on >= 2 fixtures. Same-run A/B means there is no
# baseline file to persist or trust, and machine identity / thermal state
# cancel out of the ratio.
#
# This is a sky-is-falling detector, not a gate: it is wired to a scheduled
# workflow (bench_watch.yml), never to a PR. The exit-1 exists because a
# failed scheduled run is GitHub's notification channel (it emails the user
# who last modified the cron line). Threshold rationale — same-host noise is
# ~7% with 2x first-run outliers (ADR-0209; bench/results/latency_history.yaml
# header) — so single-fixture or percent-class alerts would cry wolf.
#
# Writes a markdown table to $GITHUB_STEP_SUMMARY when set (plain stdout
# otherwise), and a ::warning:: annotation per breaching fixture.
#
# Local use: bash scripts/bench_watch.sh   (needs hyperfine + jq + git tags)
# Env: BENCH_WATCH_RUNS (default 5), BENCH_WATCH_WARMUP (default 2),
#      BENCH_WATCH_BASE (override the base ref; default: latest v* tag).

set -euo pipefail
cd "$(dirname "$0")/.."

THRESHOLD_X="2.0"
MIN_BREACHES=2
RUNS="${BENCH_WATCH_RUNS:-5}"
WARMUP="${BENCH_WATCH_WARMUP:-2}"

# The run_bench.sh windows-subset list: 5 fast (<30ms) fixtures. Kept as a
# literal here rather than parsed out of run_bench.sh — the two lists may
# diverge on purpose (this one is a canary set, not a bench inventory).
FIXTURES=(
    "shootout/nestedloop"
    "tinygo/arith"
    "tinygo/fib"
    "tinygo/sieve"
    "tinygo/tak"
)

for tool in hyperfine jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[bench_watch] $tool not on PATH; aborting." >&2
        exit 2
    fi
done

BASE_REF="${BENCH_WATCH_BASE:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)}"
if [ -z "$BASE_REF" ]; then
    echo "[bench_watch] no v* tag reachable (shallow clone? fetch tags first); aborting." >&2
    exit 2
fi
HEAD_SHA="$(git rev-parse --short HEAD)"
echo "[bench_watch] HEAD=$HEAD_SHA base=$BASE_REF runs=$RUNS warmup=$WARMUP threshold=${THRESHOLD_X}x min_breaches=$MIN_BREACHES"

WORK="$(mktemp -d)"
trap 'git worktree remove --force "$WORK/base" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

echo "[bench_watch] building HEAD (ReleaseFast)..."
zig build -Doptimize=ReleaseFast
cp ./zig-out/bin/zwasm "$WORK/zwasm-head"

echo "[bench_watch] building $BASE_REF (ReleaseFast)..."
git worktree add --detach "$WORK/base" "$BASE_REF" >/dev/null
# Best-effort dep-store reuse so the base build does not re-fetch packages.
if [ -d zig-pkg ]; then cp -R zig-pkg "$WORK/base/zig-pkg"; fi
(cd "$WORK/base" && zig build -Doptimize=ReleaseFast)
cp "$WORK/base/zig-out/bin/zwasm" "$WORK/zwasm-base"

summary="$WORK/summary.md"
{
    echo "## bench_watch: HEAD ($HEAD_SHA) vs $BASE_REF"
    echo ""
    echo "runs=$RUNS warmup=$WARMUP; breach = HEAD/base >= ${THRESHOLD_X}x; alert at >= $MIN_BREACHES breaches."
    echo ""
    echo "| fixture | base mean (ms) | HEAD mean (ms) | ratio | verdict |"
    echo "|---|---|---|---|---|"
} > "$summary"

breaches=0
for fx in "${FIXTURES[@]}"; do
    wasm="bench/runners/wasm/${fx}.wasm"
    if [ ! -f "$wasm" ]; then
        echo "[bench_watch] missing fixture $wasm; aborting (the canary set must be complete)." >&2
        exit 2
    fi
    json="$WORK/$(echo "$fx" | tr '/' '_').json"
    # -N (no shell): the canary fixtures run in single-digit ms, where the
    # shell-startup calibration is the dominant noise source.
    hyperfine -N --warmup "$WARMUP" --runs "$RUNS" --export-json "$json" \
        --command-name head --command-name base \
        "$WORK/zwasm-head run $wasm" \
        "$WORK/zwasm-base run $wasm" >/dev/null
    head_ms="$(jq -r '.results[] | select(.command == "head") | .mean * 1000' "$json")"
    base_ms="$(jq -r '.results[] | select(.command == "base") | .mean * 1000' "$json")"
    ratio="$(jq -rn --argjson h "$head_ms" --argjson b "$base_ms" '$h / $b')"
    breach="$(jq -rn --argjson r "$ratio" --argjson t "$THRESHOLD_X" '$r >= $t')"
    verdict="ok"
    if [ "$breach" = "true" ]; then
        verdict="**>= ${THRESHOLD_X}x slower**"
        breaches=$((breaches + 1))
        echo "::warning::bench_watch: $fx is ${ratio}x slower than $BASE_REF"
    fi
    printf '| %s | %.2f | %.2f | %.2fx | %s |\n' \
        "$fx" "$base_ms" "$head_ms" "$ratio" "$verdict" >> "$summary"
done

{
    echo ""
    if [ "$breaches" -ge "$MIN_BREACHES" ]; then
        echo "**ALERT: $breaches fixtures >= ${THRESHOLD_X}x slower — investigate (ROADMAP §12.1: a regression triggers investigation, not a block).**"
    else
        echo "No alert ($breaches breach(es), threshold $MIN_BREACHES)."
    fi
} >> "$summary"

cat "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$breaches" -ge "$MIN_BREACHES" ]; then
    exit 1
fi
echo "[bench_watch] OK"
