#!/usr/bin/env bash
# scripts/check_aot_cross_compile.sh — §12.3 cross-compile gate.
#
# Verifies the AOT pipeline (producer + loader + standalone runner)
# CROSS-COMPILES cleanly for non-host targets. Per ADR-0039 (Alternative
# D rejected) cross-ARCH code *emission* is deferred: the emit backend is
# comptime `builtin.target.cpu.arch`-pinned. So §12.3's "cross-compile
# works" = the whole zwasm exe (incl. the AOT producer/loader for the
# target's arch) cross-compiles via `zig build -Dtarget=<t>`. The
# resulting binary, run ON the target host, produces + runs a native
# `.cwasm` (the "cross-produced .cwasm runs on the target" half is the
# per-host `runCwasm` round-trip exercised by the 3-host gate).
#
# This is a compile-only check: `zig build -Dtarget=<t>` builds + links
# the exe but never executes it, so a foreign target compiles cleanly on
# the Mac host (a test-step run would fail "host unable to execute target
# binaries" — expected, not a compile failure, hence we use the exe step).
#
# Usage:  bash scripts/check_aot_cross_compile.sh
#   Exit 0 if every target cross-compiles; 1 on the first failure.
#
# Phase-12 verification + phase-boundary check (not per-commit — each
# cross-build is ~30-60s). The committed log lands at /tmp/aot_xc_<t>.log.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGETS=(
  "x86_64-linux"
  "aarch64-linux"
  "x86_64-windows-gnu"
)

# macOS has no native `timeout(1)` and GitHub macos runners ship without
# coreutils (locally it comes from the nix devshell / homebrew), so resolve
# a bound-runner portably and fall back to running unbounded.
TIMEOUT_CMD=""
if command -v timeout > /dev/null 2>&1; then
  TIMEOUT_CMD="timeout"
elif command -v gtimeout > /dev/null 2>&1; then
  TIMEOUT_CMD="gtimeout"
fi

run_bounded() {
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" 360 "$@"
  else
    "$@"
  fi
}

rc=0
for t in "${TARGETS[@]}"; do
  log="/tmp/aot_xc_${t}.log"
  printf '[check_aot_cross_compile] zig build -Dtarget=%s ... ' "$t"
  if run_bounded zig build "-Dtarget=${t}" > "$log" 2>&1; then
    echo "OK"
  else
    echo "FAIL (see $log)"
    grep -iE '\.zig:[0-9]+:[0-9]+: error|error: ' "$log" | head -5 || true
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  echo "[check_aot_cross_compile] OK — AOT pipeline cross-compiles for ${#TARGETS[@]} targets (§12.3)."
else
  echo "[check_aot_cross_compile] FAIL — a target did not cross-compile."
fi
exit "$rc"
