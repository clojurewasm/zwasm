#!/usr/bin/env bash
# Zone dependency checker for zwasm v2.
#
# Enforces the layering rules in .claude/rules/zone_deps.md (post-ADR-0023):
#   Zone 0 (support/, platform/) must NOT import from any higher zone.
#   Zone 1 (ir/, runtime/, parse/, validate/, feature/, diagnostic/) must NOT import from Zone 2+.
#   Zone 2 (interp/, engine/, wasi/) must NOT import from Zone 3.
#   Cross-arch engine/codegen/arm64/ <-> engine/codegen/x86_64/ imports are forbidden (A3).
#
# Modes:
#   bash scripts/zone_check.sh           informational; always exits 0
#   bash scripts/zone_check.sh --strict  exit 1 on any violation
#   bash scripts/zone_check.sh --gate    exit 1 if violations exceed BASELINE
#
# Test blocks (everything after the first `test "..."` line in a file)
# are skipped — test code may legitimately cross zones.

set -euo pipefail

BASELINE=0
MODE="${1:-info}"

cd "$(dirname "$0")/.."

zone_of() {
    local path="$1"
    case "$path" in
        src/support/*|src/platform/*)                                                       echo 0 ;;
        src/ir/*|src/runtime/*|src/parse/*|src/validate/*|src/feature/*|src/diagnostic/*|src/instruction/*) echo 1 ;;
        src/interp/*|src/wasi/*|src/engine/*)                                               echo 2 ;;
        src/api/*|src/cli/*|src/main.zig)                                                    echo 3 ;;
        *)                                                   echo "x" ;;
    esac
}

# Returns the arch sub-zone (arm64 / x86 / "") for cross-arch checks.
arch_of() {
    local path="$1"
    case "$path" in
        src/engine/codegen/arm64/*)  echo "arm64" ;;
        src/engine/codegen/x86_64/*) echo "x86" ;;
        *)                           echo "" ;;
    esac
}

violations_file=$(mktemp)
trap "rm -f $violations_file" EXIT

# `find` returns 0 even when no files match; `|| true` is for safety.
files="$(find src -name '*.zig' 2>/dev/null || true)"

for file in $files; do
    src_zone=$(zone_of "$file")
    [ "$src_zone" = "x" ] && continue
    src_arch=$(arch_of "$file")

    awk '/^test "/{exit} {print NR ":" $0}' "$file" \
        | { grep -E '@import\("[^"]+\.zig"\)' || true; } \
        | while IFS=: read -r lineno content; do
            import_path=$(echo "$content" | sed -nE 's/.*@import\("([^"]+)"\).*/\1/p')
            [ -z "$import_path" ] && continue
            case "$import_path" in
                std|builtin|build_options) continue ;;
            esac

            file_dir=$(dirname "$file")
            resolved=$(cd "$file_dir" 2>/dev/null && cd "$(dirname "$import_path")" 2>/dev/null && pwd)/$(basename "$import_path")
            rel=$(realpath --relative-to="$(pwd)" "$resolved" 2>/dev/null || echo "$resolved")

            tgt_zone=$(zone_of "$rel")
            [ "$tgt_zone" = "x" ] && continue
            tgt_arch=$(arch_of "$rel")

            if [ "$src_zone" -lt "$tgt_zone" ]; then
                echo "$file:$lineno: zone $src_zone imports zone $tgt_zone ($import_path)" \
                    >> "$violations_file"
            fi

            if [ -n "$src_arch" ] && [ -n "$tgt_arch" ] && [ "$src_arch" != "$tgt_arch" ]; then
                echo "$file:$lineno: cross-arch import $src_arch -> $tgt_arch ($import_path)" \
                    >> "$violations_file"
            fi
        done
done

count=$(wc -l < "$violations_file" | tr -d ' ')

if [ "$count" -gt 0 ]; then
    cat "$violations_file"
    echo
    echo "$count zone violation(s) found."
fi

case "$MODE" in
    --strict)
        if [ "$count" -gt 0 ]; then exit 1; fi
        ;;
    --gate)
        if [ "$count" -gt "$BASELINE" ]; then
            echo "Gate failed: $count > BASELINE=$BASELINE" >&2
            exit 1
        fi
        ;;
    *)
        echo "(informational mode: exit 0 regardless of violations)"
        ;;
esac

exit 0
