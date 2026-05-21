#!/usr/bin/env bash
# SIBLING-PUB marker audit (per ADR-0094).
#
# Cross-file struct-method extraction in Zig 0.16 (no
# `usingnamespace`) requires pub-ifying helpers only used by a
# sibling file. The SIBLING-PUB marker declares which sibling
# files are authorized to call the pub decl; this script verifies
# no other file is calling it.
#
# Marker syntax (placed on the line IMMEDIATELY preceding the
# `pub fn|const|var` decl):
#
#     // SIBLING-PUB: validator_simd.zig (per ADR-0083 extraction)
#     pub fn pushType(self: *Validator, t: ValType) Error!void {
#
# Comma-separated list for multi-sibling cases:
#
#     // SIBLING-PUB: foo_simd.zig, foo_int.zig (per ADR-XXXX)
#     pub fn helper(...) ...
#
# Modes:
#   bash scripts/check_sibling_pub.sh           informational
#   bash scripts/check_sibling_pub.sh --gate    exit 1 on violation
#
# Caller detection: scan files that `@import` the declaring file
# (basename match). Within those importing files, any `.NAME(`
# from a file not in the authorized list triggers a violation.
# The @import filter eliminates false positives where another
# file independently defines a fn with the same name (e.g.,
# `op_mod.emit()` vs `lowerer.emit()`).
#
# Tests under test/ are exempt (mirrors zone_check.sh).

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-info}"
violations=0
total_markers=0

while IFS= read -r marker_line; do
    [ -z "$marker_line" ] && continue
    file="${marker_line%%:*}"
    rest="${marker_line#*:}"
    lineno="${rest%%:*}"

    auth_text=$(printf '%s\n' "$marker_line" \
        | sed -nE 's|.*// SIBLING-PUB:[[:space:]]*([^(]*).*|\1|p' \
        | sed -E 's|[[:space:]]+$||')

    if [ -z "$auth_text" ]; then
        echo "WARN: $file:$lineno — SIBLING-PUB marker is missing authorized-files list" >&2
        continue
    fi

    next_lineno=$((lineno + 1))
    decl_line=$(sed -n "${next_lineno}p" "$file" 2>/dev/null || true)

    # Use `/` delimiter — BSD sed treats `|` inside `s|...|` as
    # the delimiter, breaking the alternation group.
    name=$(printf '%s\n' "$decl_line" \
        | sed -nE 's/^[[:space:]]*pub (fn|const|var) ([a-zA-Z_][a-zA-Z0-9_]*).*/\2/p')

    if [ -z "$name" ]; then
        echo "WARN: $file:$lineno — SIBLING-PUB marker but next line is not a pub fn/const/var: $decl_line" >&2
        continue
    fi

    total_markers=$((total_markers + 1))

    declaring_basename=$(basename "$file")

    # Stage 1: find files that @import the declaring file (basename
    # match — handles `@import("lower.zig")`, `@import("../ir/lower.zig")`,
    # etc.).
    importing_files=$(grep -rlE "@import\\([\"][^\"]*${declaring_basename}[\"]\\)" src/ --include="*.zig" 2>/dev/null || true)

    # Stage 2: within each importing file, look for `.<name>(` calls.
    while IFS= read -r importer; do
        [ -z "$importer" ] && continue
        # Skip the declaring file itself.
        [ "$importer" = "$file" ] && continue

        importer_basename=$(basename "$importer")
        ok=0
        for auth in $(printf '%s' "$auth_text" | tr ',' ' '); do
            if [ "$importer_basename" = "$auth" ]; then
                ok=1
                break
            fi
        done

        if [ "$ok" -eq 1 ]; then
            continue
        fi

        # Unauthorized importer — check for actual call sites.
        call_sites=$(grep -nE "\\.${name}\\(" "$importer" 2>/dev/null || true)
        if [ -n "$call_sites" ]; then
            if [ "$violations" -eq 0 ]; then
                echo "[check_sibling_pub] violations:" >&2
            fi
            while IFS= read -r site; do
                [ -z "$site" ] && continue
                echo "  $file declares '$name' SIBLING-PUB for [$auth_text], unauthorized: $importer:$site" >&2
                violations=$((violations + 1))
            done <<< "$call_sites"
        fi
    done <<< "$importing_files"
done < <(grep -rn "// SIBLING-PUB:" src/ --include="*.zig" 2>/dev/null || true)

echo "[check_sibling_pub] markers: $total_markers, violations: $violations" >&2

if [ "$MODE" = "--gate" ] && [ "$violations" -gt 0 ]; then
    exit 1
fi
exit 0
