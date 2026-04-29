#!/usr/bin/env bash
# scripts/sync-versions.sh — verify .github/versions.lock matches flake.nix.
#
# Four pins live in flake.nix today: Zig, WASI SDK, wasm-tools, wasmtime
# (the last two added in W50 PR-A). Hyperfine has no aarch64-darwin
# prebuilt asset upstream, so it is still resolved via nixpkgs and not
# checked here.
#
# Exit codes:
#   0  versions.lock is consistent with flake.nix
#   1  mismatch found (printed); manually update one side or the other
#   2  invocation error (missing file, etc.)
#
# Usage:
#   bash scripts/sync-versions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/versions.sh
source "$SCRIPT_DIR/lib/versions.sh"

FLAKE="$ZWASM_REPO_ROOT/flake.nix"
if [ ! -f "$FLAKE" ]; then
    echo "sync-versions: $FLAKE not found" >&2
    exit 2
fi

mismatches=0

check() {
    local name="$1" lock_value="$2" flake_value="$3"
    if [ "$lock_value" = "$flake_value" ]; then
        printf '  [OK]   %-22s %s\n' "$name" "$lock_value"
    else
        printf '  [MISS] %-22s versions.lock=%s flake.nix=%s\n' \
            "$name" "$lock_value" "$flake_value"
        mismatches=$((mismatches + 1))
    fi
}

# Zig: every URL in flake.nix carries the version twice (path + filename).
# Pull the first occurrence — if the four arch entries disagree, that is
# already a separate flake.nix bug we want to surface.
flake_zig="$(grep -oE 'ziglang\.org/download/[0-9]+\.[0-9]+\.[0-9]+/' "$FLAKE" \
    | head -1 \
    | sed -E 's|.*/([0-9]+\.[0-9]+\.[0-9]+)/|\1|')"
check ZIG_VERSION "$ZIG_VERSION" "$flake_zig"

# WASI SDK: URL pattern is .../wasi-sdk-<MAJOR>/wasi-sdk-<MAJOR>.0-<arch>...
flake_wasi="$(grep -oE 'wasi-sdk/releases/download/wasi-sdk-[0-9]+' "$FLAKE" \
    | head -1 \
    | sed -E 's|.*wasi-sdk-||')"
check WASI_SDK_VERSION "$WASI_SDK_VERSION" "$flake_wasi"

# wasm-tools: URL pattern is .../wasm-tools/releases/download/v<X.Y.Z>/...
flake_wasm_tools="$(grep -oE 'wasm-tools/releases/download/v[0-9]+\.[0-9]+\.[0-9]+' "$FLAKE" \
    | head -1 \
    | sed -E 's|.*/v||')"
check WASM_TOOLS_VERSION "$WASM_TOOLS_VERSION" "$flake_wasm_tools"

# wasmtime: URL pattern is .../wasmtime/releases/download/v<X.Y.Z>/...
flake_wasmtime="$(grep -oE 'wasmtime/releases/download/v[0-9]+\.[0-9]+\.[0-9]+' "$FLAKE" \
    | head -1 \
    | sed -E 's|.*/v||')"
check WASMTIME_VERSION "$WASMTIME_VERSION" "$flake_wasmtime"

echo
if [ "$mismatches" -eq 0 ]; then
    echo "sync-versions: OK"
    exit 0
fi
echo "sync-versions: $mismatches mismatch(es). Fix versions.lock or flake.nix and re-run." >&2
exit 1
