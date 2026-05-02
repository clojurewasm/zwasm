#!/usr/bin/env bash
# Record per-merge bench numbers into bench/history.yaml.
# Tags each row with arch:{aarch64-darwin, x86_64-linux, x86_64-windows}.
#
# Phase 0-10: stub. Phase 11+ wires hyperfine against bench/runners/*.wasm.
#
# Usage:
#   bash scripts/record_merge_bench.sh             # full mode
#   bash scripts/record_merge_bench.sh --quick     # quick mode (3 runs + 1 warmup) — for doc-only merges

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

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

echo "[record_merge_bench] arch=$arch, commit=$short, quick=$QUICK"
echo "[record_merge_bench] subject: $subject"

# TODO(p11): wire actual hyperfine runs against bench/runners/*.wasm
# and append rows to bench/history.yaml. For Phase 0-10, this is a stub.

cat <<EOF >> bench/history.yaml
# - date: $date
#   commit: $commit
#   arch: $arch
#   reason: "Record benchmark for $subject"
#   runs: $([ $QUICK -eq 1 ] && echo 3 || echo 5)
#   benches: []   # populated by hyperfine, Phase 11+
EOF

echo "[record_merge_bench] history.yaml updated (stub)."
