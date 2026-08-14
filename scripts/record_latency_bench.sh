#!/usr/bin/env bash
# scripts/record_latency_bench.sh — append one steady-state per-call latency
# entry to bench/results/latency_history.yaml (ADR-0209 D2).
#
#   bash scripts/record_latency_bench.sh --reason "<tag>: <gist>"
#
# Separate from run_bench.sh on purpose. That script drives `hyperfine` over
# whole processes and records milliseconds into history.yaml; this one runs an
# in-process measurement and records nanoseconds. Same append-only discipline
# (ROADMAP A9), different schema, different file. `size_history.yaml`
# (`6717fe366`) and `skip_impl_history.yaml` (`05377cf6a`) are the existing
# separate-schema series; neither shipped under an ADR of its own, so this
# follows a shape the repo settled into rather than a written rule. Reasoning
# in ADR-0209 D2.
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
        --reason)
            [ $# -ge 2 ] && [ -n "${2:-}" ] || {
                echo "[record_latency] --reason needs a value" >&2
                exit 1
            }
            REASON="$2"; shift 2 ;;
        --reason=*) REASON="${1#--reason=}"; shift ;;
        --build-mode)
            # Guarded like --reason above: bare `${2:-}` + `shift 2` would leave
            # BUILD_MODE empty, run `zig build -Doptimize=` and surface zig's
            # error instead of this script's, and `shift 2` on one remaining
            # argument fails under `set -e` with no message at all.
            [ $# -ge 2 ] && [ -n "${2:-}" ] || {
                echo "[record_latency] --build-mode needs a value (Debug / ReleaseSafe / ReleaseFast / ReleaseSmall)" >&2
                exit 1
            }
            BUILD_MODE="$2"; shift 2 ;;
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

# The runner's YAML reaches this substitution only because `has_side_effects`
# on the Run step (build.zig) resolves its stdio to inherit. That coupling is
# implicit: drop the flag and zig caches the step, leaving `body` empty and this
# script silently appending a row with no measurements in it.
[ -n "$body" ] || {
    echo "[record_latency] the runner produced no output; nothing appended" >&2
    exit 1
}

# `date -u +%Y-%m-%dT%H:%M:%SZ` rather than `date -Iseconds`: the latter is a
# GNU extension and BSD/macOS date has no `-I` at all.
{
    echo ""
    echo "- date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "  commit: $(git rev-parse HEAD)"
    # Escape backslashes BEFORE quotes, or a reason containing `\` yields a
    # YAML double-quoted scalar with an unintended escape (`a\b` parses back as
    # a backspace, not the two characters typed).
    esc="${REASON//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    echo "  reason: \"$esc\""
    echo "$body"
} >> "$HIST"

echo "[record_latency] appended to $HIST" >&2
