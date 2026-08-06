#!/usr/bin/env bash
# scripts/check_api_export_analysis.sh — every src/api/*.zig that carries a
# `pub export fn` MUST be force-analysed by the comptime block in src/zwasm.zig.
#
# Zig only emits `export` symbols from files the analysis pass visits; a lazy
# `pub const` re-export through api/wasm.zig does NOT visit the file, so a file
# missing from the comptime block silently drops ALL its exports from
# libzwasm.a while include/*.h keeps declaring them — and its tests never run
# (the comptime block is also what pulls in-file tests into the test build),
# so it can even fail to compile unnoticed (issue #161: 81 symbols across
# ref_base / config / host_info / module_serialize).
#
# Source-only (grep, no build), wired into gate_commit.sh so it runs at
# commit time on any OS. The built-archive side of the same invariant
# (declared header symbol present in libzwasm.a) lives in
# scripts/test_extlink.sh (CI extended leg) — that is what gates the merge.
#
# Usage: bash scripts/check_api_export_analysis.sh [--gate]
#   --gate: exit 1 on violation (default: same; flag kept for family symmetry)
set -euo pipefail
cd "$(dirname "$0")/.."

# Only the top-level `comptime { ... }` block counts: a `_ = @import` inside
# the `test { ... }` loader is analysed in test builds only, not the lib build.
comptime_block=$(sed -n '/^comptime {/,/^}/p' src/zwasm.zig)

fail=0
for f in src/api/*.zig; do
    grep -q '^pub export fn' "$f" || continue
    rel="${f#src/}"
    if ! grep -qF "_ = @import(\"$rel\");" <<<"$comptime_block"; then
        echo "[check_api_export_analysis] $f has pub export fn but no '_ = @import(\"$rel\");' in src/zwasm.zig's comptime block" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "[check_api_export_analysis] FAIL — add the file to the comptime force-analyse block in src/zwasm.zig" >&2
    exit 1
fi
echo "[check_api_export_analysis] OK"
