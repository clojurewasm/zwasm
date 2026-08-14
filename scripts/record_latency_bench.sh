#!/usr/bin/env bash
# scripts/record_latency_bench.sh — append one steady-state per-call latency
# entry to bench/results/latency_history.yaml (ADR-0209 D2).
#
#   bash scripts/record_latency_bench.sh --reason "<tag>: <gist>"
#
# Separate from run_bench.sh on purpose. That script drives `hyperfine` over
# whole processes and records milliseconds into history.yaml; this one runs an
# in-process measurement and records nanoseconds. Same append-only discipline
# (ROADMAP A9), different schema, different file — the precedent is
# size_history.yaml (ADR-0204) and skip_impl_history.yaml (ADR-0050).
#
# Needs no hyperfine and no dev shell: the runner is plain Zig.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
[ -f build.zig.zon ] && [ -d src/engine ] || {
    echo "[record_latency] '$repo_root' is not the zwasm repo root" >&2
    exit 1
}

REASON=""
BUILD_MODE="ReleaseFast"
while [ $# -gt 0 ]; do
    case "$1" in
        --reason) REASON="${2:-}"; shift 2 ;;
        --reason=*) REASON="${1#--reason=}"; shift ;;
        --build-mode) BUILD_MODE="${2:-}"; shift 2 ;;
        *) echo "[record_latency] unknown argument '$1'" >&2; exit 1 ;;
    esac
done
[ -n "$REASON" ] || {
    echo "[record_latency] --reason is required; it is what makes the row readable later" >&2
    exit 1
}

HIST=bench/results/latency_history.yaml
[ -f "$HIST" ] || {
    echo "[record_latency] $HIST is missing; it is committed, not generated" >&2
    exit 1
}

# ReleaseFast by default: the comparators in every other bench ship optimized,
# and a Debug measurement of a per-call constant is not comparable with
# anything. Overridable so a ReleaseSafe delta can be recorded deliberately.
echo "[record_latency] building ($BUILD_MODE)..." >&2
zig build -Doptimize="$BUILD_MODE" >&2

echo "[record_latency] measuring..." >&2
body="$(zig build -Doptimize="$BUILD_MODE" bench-latency)"

# `date -u +%Y-%m-%dT%H:%M:%SZ` rather than `date -Iseconds`: the latter is a
# GNU extension and BSD/macOS date has no `-I` at all.
{
    echo ""
    echo "- date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  commit: $(git rev-parse HEAD)"
    echo "  reason: \"${REASON//\"/\\\"}\""
    echo "$body"
} >> "$HIST"

echo "[record_latency] appended to $HIST" >&2
