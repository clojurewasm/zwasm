#!/usr/bin/env bash
# File-size GROWTH ratchet (sweep S5(a), ADR-0099 companion).
#
# The absolute caps in file_size_check.sh are ADVISORY (ADR-0099 amended
# 2026-07-03) — which is exactly how component_wasi_p2.zig grew 2228→5470
# lines silently. This ratchet gates the DELTA instead of the absolute:
# a .zig file that is ALREADY over its effective hard cap may not grow
# further in a change, unless the same change adds or edits its
# FILE-SIZE-EXEMPT marker line (= the growth was re-justified, not silent).
#
# Cap resolution mirrors file_size_check.sh: hard 2000; a FILE-SIZE-EXEMPT
# marker citing an ADR raises it to 2500; `(cap=N)` overrides; `(cap=UNCAPPED)`
# and AUTO-GENERATED files are never ratcheted.
#
# Base selection:
#   RATCHET_BASE=<git-ref>   compare HEAD-tree paths against this ref
#                            (CI: the PR merge-base, e.g. origin/main)
#   default                  compare the working tree / index against HEAD
#                            (pre-commit shape)
#
# Modes:
#   bash scripts/file_growth_ratchet.sh          informational
#   bash scripts/file_growth_ratchet.sh --gate   exit 1 on ratchet violation

set -euo pipefail

MODE="${1:-info}"
BASE="${RATCHET_BASE:-HEAD}"
HARD_CAP=2000
EXEMPT_CAP=2500

cd "$(dirname "$0")/.."

if ! git rev-parse --verify --quiet "$BASE^{commit}" > /dev/null 2>&1; then
    # A shallow CI checkout may lack the base ref — say so loudly and skip
    # (the ratchet needs history; set RATCHET_BASE or deepen the fetch).
    echo "[file_growth_ratchet] SKIP — base '$BASE' is not resolvable in this checkout" >&2
    exit 0
fi

effective_cap_of() {
    # $1 = file content on stdin? No — bash: pass content via a temp file.
    local file="$1"
    local marker
    marker=$(head -5 "$file" 2>/dev/null | grep -E '^// FILE-SIZE-EXEMPT:.*ADR-[0-9]+' | head -1 || true)
    if head -3 "$file" 2>/dev/null | grep -q 'AUTO-GENERATED'; then
        echo "skip"
        return
    fi
    if [ -n "$marker" ]; then
        if echo "$marker" | grep -q '(cap=UNCAPPED)'; then
            echo "skip"
            return
        fi
        local cap_extract
        cap_extract=$(echo "$marker" | sed -nE 's/.*\(cap=([0-9]+)\).*/\1/p' || true)
        if [ -n "$cap_extract" ] && [ "$cap_extract" -gt "$EXEMPT_CAP" ]; then
            echo "$cap_extract"
            return
        fi
        echo "$EXEMPT_CAP"
        return
    fi
    echo "$HARD_CAP"
}

violations=0
tmp_old=$(mktemp)
trap 'rm -f "$tmp_old"' EXIT

while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in src/*.zig | src/**/*.zig) ;; *) continue ;; esac
    [ -f "$f" ] || continue # deleted file — never a growth

    if ! git cat-file -e "$BASE:$f" 2>/dev/null; then
        continue # new file — absolute caps (file_size_check) own it
    fi
    git show "$BASE:$f" > "$tmp_old"
    old_lines=$(wc -l < "$tmp_old" | tr -d ' ')
    new_lines=$(wc -l < "$f" | tr -d ' ')
    [ "$new_lines" -le "$old_lines" ] && continue # shrink/steady is always fine

    old_cap=$(effective_cap_of "$tmp_old")
    [ "$old_cap" = "skip" ] && continue
    [ "$old_lines" -le "$old_cap" ] && continue # was under cap — absolute checks own it

    # Already-over-cap file grew. A changed FILE-SIZE-EXEMPT marker line in
    # this diff = deliberate re-justification; otherwise it is silent growth.
    old_marker=$(head -5 "$tmp_old" | grep -E '^// FILE-SIZE-EXEMPT:' | head -1 || true)
    new_marker=$(head -5 "$f" | grep -E '^// FILE-SIZE-EXEMPT:' | head -1 || true)
    if [ -n "$new_marker" ] && [ "$new_marker" != "$old_marker" ]; then
        echo "RATCHET-EXEMPT: $f ($old_lines → $new_lines) — over-cap growth re-justified by an updated FILE-SIZE-EXEMPT marker" >&2
        continue
    fi

    echo "RATCHET: $f ($old_lines → $new_lines, cap=$old_cap) — an already-over-cap file grew without an updated FILE-SIZE-EXEMPT marker" >&2
    violations=$((violations + 1))
done < <(git diff --name-only "$BASE" -- 'src/*.zig' 'src/**/*.zig'; git diff --name-only --cached -- 'src/*.zig' 'src/**/*.zig')

if [ "$violations" -gt 0 ]; then
    echo >&2
    echo "[file_growth_ratchet] $violations over-cap file(s) grew silently — split per ADR-0099 P/N, or update the FILE-SIZE-EXEMPT marker with the re-justification" >&2
    if [ "$MODE" = "--gate" ]; then
        exit 1
    fi
fi
echo "[file_growth_ratchet] OK (base=$BASE)" >&2
exit 0
