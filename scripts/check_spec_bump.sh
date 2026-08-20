#!/usr/bin/env bash
# Spec-bump: alert when WebAssembly/{spec,testsuite} upstream advances
# beyond the vendoring pin (`.dev/spec_pin.yaml`) — the cue to update the OSS
# clones, re-run regen_spec_*.sh, and exercise any new conformance tests.
# On-demand tool (its nightly.yml automation was retired 2026-08-19,
# ADR-0211 D1 / D-593). Note --gate compares against upstream HEAD, a moving
# target — it goes red again after every pin bump by design.
#
#   bash scripts/check_spec_bump.sh [--gate]
#     default : report drift, exit 0.
#     --gate  : exit 1 on drift.
#
# Network: one `git ls-remote` per repo. An unreachable upstream WARNs (does
# not fail) so a transient network blip doesn't turn into a false red.
set -euo pipefail
cd "$(dirname "$0")/.."

GATE=0
[ "${1:-}" = "--gate" ] && GATE=1

PIN=.dev/spec_pin.yaml
[ -f "$PIN" ] || { echo "[check_spec_bump] missing $PIN" >&2; exit 2; }

drift=0
for repo in spec testsuite; do
  pinned=$(grep -E "^${repo}:" "$PIN" | grep -oE '[0-9a-f]{40}' | head -1 || true)
  if [ -z "$pinned" ]; then
    echo "[check_spec_bump] no pinned SHA for '$repo' in $PIN" >&2
    exit 2
  fi
  upstream=$(timeout 30 git ls-remote "https://github.com/WebAssembly/${repo}.git" HEAD 2>/dev/null | grep -oE '^[0-9a-f]{40}' | head -1 || true)
  if [ -z "$upstream" ]; then
    echo "[check_spec_bump] WARN: WebAssembly/${repo} upstream unreachable — skipping" >&2
    continue
  fi
  if [ "$pinned" = "$upstream" ]; then
    echo "[check_spec_bump] OK   WebAssembly/${repo} at ${pinned:0:12}"
  else
    echo "[check_spec_bump] DRIFT WebAssembly/${repo}: pinned ${pinned:0:12} -> upstream ${upstream:0:12} — re-vendor + run new tests, then bump $PIN" >&2
    drift=1
  fi
done

if [ "$drift" = 1 ] && [ "$GATE" = 1 ]; then
  exit 1
fi
exit 0
