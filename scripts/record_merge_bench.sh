#!/usr/bin/env bash
# Record bench numbers. Without --phase-record writes to
# `bench/results/recent.yaml` (gitignored, per-commit). With
# --phase-record appends to `bench/results/history.yaml`
# (committed, append-only, phase boundaries only) per
# ADR-0012 §7 + §9.6 / 6.H. Tags each row with
# arch:{aarch64-darwin, x86_64-linux, x86_64-windows}.
#
# Phase 0-10: stub. Phase 11+ wires hyperfine against bench/runners/*.wasm.
#
# Usage:
#   bash scripts/record_merge_bench.sh                   # write to recent.yaml
#   bash scripts/record_merge_bench.sh --quick           # quick mode (3 runs + 1 warmup)
#   bash scripts/record_merge_bench.sh --phase-record    # append to history.yaml (phase boundary)

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
PHASE_RECORD=0
for arg in "$@"; do
    case "$arg" in
        --quick) QUICK=1 ;;
        --phase-record) PHASE_RECORD=1 ;;
    esac
done

if [ $PHASE_RECORD -eq 1 ]; then
    target=bench/results/history.yaml
else
    target=bench/results/recent.yaml
    mkdir -p bench/results
fi

case "$(uname -s -m)" in
    "Darwin arm64")    arch="aarch64-darwin" ;;
    "Linux x86_64")    arch="x86_64-linux" ;;
    "MINGW"*|"MSYS"*)  arch="x86_64-windows" ;;
    *)                 arch="unknown" ;;
esac

commit=$(git rev-parse HEAD)
short=$(git rev-parse --short HEAD)
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
subject=$(git log -1 --format='%s')

echo "[record_merge_bench] arch=$arch, commit=$short, quick=$QUICK, phase-record=$PHASE_RECORD"
echo "[record_merge_bench] target=$target"
echo "[record_merge_bench] subject: $subject"

# TODO(p11): wire actual hyperfine runs against bench/runners/*.wasm
# and append rows to $target. For Phase 0-10, this is a stub.

cat <<EOF >> "$target"
# - date: $date
#   commit: $commit
#   arch: $arch
#   reason: "Record benchmark for $subject"
#   runs: $([ $QUICK -eq 1 ] && echo 3 || echo 5)
#   benches: []   # populated by hyperfine, Phase 11+
EOF

echo "[record_merge_bench] $target updated (stub)."
