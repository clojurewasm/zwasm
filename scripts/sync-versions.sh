#!/usr/bin/env bash
# scripts/sync-versions.sh — verify .github/versions.lock matches flake.nix.
#
# Two pins live in flake.nix today: Zig and WASI SDK. Other tools come
# from nixpkgs at the flake.lock revision and do not embed an
# explicit version literal in flake.nix, so they are checked
# best-effort or skipped here. When Plan B's flake.nix extension lands
# (explicit pins for wasm-tools / wasmtime / hyperfine), add them to
# CHECKS below.
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

echo
if [ "$mismatches" -eq 0 ]; then
    echo "sync-versions: OK"
    exit 0
fi
echo "sync-versions: $mismatches mismatch(es). Fix versions.lock or flake.nix and re-run." >&2
exit 1
