#!/usr/bin/env bash
# scripts/check_split_smell.sh — informational smell checker for file
# extractions per ADR-0099. Surfaces negative conditions (N1-N4) without
# gating commits.
#
# Wired into:
#   - gate_commit.sh (informational; non-failing)
#   - audit_scaffolding §J (extension)
#
# Usage:
#   bash scripts/check_split_smell.sh         # findings to stderr
#   bash scripts/check_split_smell.sh --json  # machine-readable

# Note: deliberately NOT using `set -e` — informational checks should
# tolerate grep no-match exits (which return 1).
set -u

cd "$(dirname "$0")/.."

MODE="${1:-text}"
findings=0
# n1_hits = files that triggered N1 (so N3 can narrow to those siblings)
declare -a n1_files=()

emit_finding() {
    local cat="$1" file="$2" detail="$3"
    if [ "$MODE" = "--json" ]; then
        printf '{"category":"%s","file":"%s","detail":"%s"}\n' "$cat" "$file" "$detail"
    else
        printf '[%s] %s — %s\n' "$cat" "$file" "$detail" >&2
    fi
    findings=$((findings + 1))
}

# Helper: is file a test sibling (governed by different discipline)?
is_test_sibling() {
    case "$1" in
        *_test.zig|*_tests.zig) return 0 ;;
        *) return 1 ;;
    esac
}

# Helper: is file a per-op file (governed by ADR-0074 / Zone split)?
# Per-op-files are intentionally small (~20-40 LOC) by design.
is_per_op_file() {
    case "$1" in
        src/instruction/wasm_*/*) return 0 ;;
        src/engine/codegen/*/ops/wasm_*/*) return 0 ;;
        src/engine/codegen/*/ops/wasi/*) return 0 ;;
        src/feature/*/ops/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Helper: is file an emit_test (governed by ADR-0030 / ADR-0054)?
# These are test-file-splits with their own discipline.
is_emit_test_file() {
    case "$1" in
        */emit_test*.zig) return 0 ;;
        *) return 1 ;;
    esac
}

# ----------------------------------------------------------------------
# N1 — Helper-circular import
# Child file `foo_bar.zig` imports `foo.zig` (same dir) AND calls
# `foo.<lowercase-fn-name>(`. Type aliases are uppercase by Zig
# convention, so lowercase = function call.
# ----------------------------------------------------------------------
n1_check() {
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        is_test_sibling "$f" && continue
        local dir base parent_short
        dir=$(dirname "$f")
        base=$(basename "$f" .zig)
        parent_short="${base%%_*}"
        if [ "$base" = "$parent_short" ]; then continue; fi
        if [ ! -f "$dir/${parent_short}.zig" ]; then continue; fi

        local calls
        calls=$(grep -oE "\\b${parent_short}\\.[a-z][a-zA-Z0-9_]*\\(" "$f" 2>/dev/null | sort -u | head -5)
        if [ -n "${calls:-}" ]; then
            local call_list
            call_list=$(echo "$calls" | tr '\n' ',' | sed 's/,$//')
            emit_finding "N1-helper-circular" "$f" "child imports ${parent_short}.zig and calls helpers: ${call_list}"
            n1_files+=("$f")
        fi
    done < <(find src -name '*.zig' -type f 2>/dev/null)
}

# ----------------------------------------------------------------------
# N3 — Shallow module
# Two scopes:
#  (a) any file that already triggered N1 (= confirmed extraction sibling)
#  (b) any file matching `<parent>_<suffix>.zig` naming where
#      `<parent>.zig` exists in same directory (= naming-pattern sibling)
# Then: substantive code < 100 LOC → flag.
# Test-only files (_test.zig / _tests.zig) excluded.
# ----------------------------------------------------------------------
n3_check() {
    # Collect candidates (union of n1_files and naming-pattern siblings)
    local -A candidates_seen=()
    local f

    # (a) files already in n1
    for f in "${n1_files[@]:-}"; do
        [ -z "$f" ] && continue
        candidates_seen["$f"]=1
    done

    # (b) naming-pattern siblings (exclude per-op + emit_test files —
    # those follow separate disciplines per ADR-0074 / ADR-0030)
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        is_test_sibling "$f" && continue
        is_per_op_file "$f" && continue
        is_emit_test_file "$f" && continue
        local dir base parent_short
        dir=$(dirname "$f")
        base=$(basename "$f" .zig)
        parent_short="${base%%_*}"
        if [ "$base" = "$parent_short" ]; then continue; fi
        if [ ! -f "$dir/${parent_short}.zig" ]; then continue; fi
        candidates_seen["$f"]=1
    done < <(find src -name '*.zig' -type f 2>/dev/null)

    # Apply substantive-LOC filter
    for f in "${!candidates_seen[@]}"; do
        local subst
        subst=$(awk '
            /^[[:space:]]*$/ { next }
            /^[[:space:]]*\/\// { next }
            /^test "/ { in_test=1; next }
            in_test == 1 { if (/^}/) in_test=0; next }
            { print }
        ' "$f" | wc -l | tr -d ' ')
        if [ "$subst" -lt 100 ]; then
            # Note if also flagged N1 (joint finding) or pattern-only
            local note=""
            local was_n1=""
            for n1f in "${n1_files[@]:-}"; do
                [ "$n1f" = "$f" ] && was_n1="yes" && break
            done
            if [ -n "$was_n1" ]; then
                note=" (also N1)"
            else
                note=" (naming-pattern sibling)"
            fi
            emit_finding "N3-shallow" "$f" "substantive=$subst LOC < 100${note} — likely shallow module"
        fi
    done
}

# ----------------------------------------------------------------------
# N4 — Test fixture duplication
# Same `fn test*Foo(` defined in 2+ files
# ----------------------------------------------------------------------
n4_check() {
    local dup_helpers
    dup_helpers=$(grep -rhE '^[[:space:]]*fn[[:space:]]+test[A-Z][a-zA-Z0-9_]*\(' src/ 2>/dev/null \
        | sed -E 's/.*fn[[:space:]]+(test[A-Z][a-zA-Z0-9_]*)\(.*/\1/' \
        | sort | uniq -d)

    while IFS= read -r helper; do
        [ -z "$helper" ] && continue
        local files
        files=$(grep -rln "^[[:space:]]*fn[[:space:]]\\+${helper}(" src/ 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        emit_finding "N4-test-dup" "$files" "duplicated test helper: ${helper}"
    done <<< "$dup_helpers"
}

# ----------------------------------------------------------------------
# Hub-emptiness — informational signal that a file might be over-split
# ----------------------------------------------------------------------
hub_check() {
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        is_test_sibling "$f" && continue
        local total reexp pct
        total=$(wc -l < "$f" | tr -d ' ')
        [ "$total" -eq 0 ] && continue
        reexp=$(grep -cE '^pub const [A-Za-z_][A-Za-z0-9_]* = [a-z_]+(_mod)?\.[A-Za-z_][A-Za-z0-9_]*;' "$f" 2>/dev/null)
        if [ "$reexp" -gt 5 ]; then
            pct=$((reexp * 100 / total))
            if [ "$pct" -gt 30 ]; then
                emit_finding "hub-emptiness" "$f" "$reexp re-exports = ${pct}% of $total LOC — review for over-split"
            fi
        fi
    done < <(find src -name '*.zig' -type f 2>/dev/null)
}

# Run checks (informational only; order: N1 first so N3 can use n1_files)
n1_check
n3_check
n4_check
hub_check

if [ "$MODE" != "--json" ]; then
    echo "" >&2
    if [ "$findings" -gt 0 ]; then
        echo "[check_split_smell] $findings finding(s) — review per ADR-0099" >&2
    else
        echo "[check_split_smell] no findings" >&2
    fi
fi

# Informational only — always exit 0
exit 0
