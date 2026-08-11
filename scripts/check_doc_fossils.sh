#!/usr/bin/env bash
# Doc-fossil guard (sweep S5(b)) — the doc-truth job's third leg.
#
# Two mechanized fossil classes the 2026-08 sweep found live instances of:
#
# 1. VERSION fossils: a hardcoded zwasm version string in the always-current
#    docs (README, docs/**, .github/**) that does not match build.zig.zon's
#    `.version`. Historical files are exempt: CHANGELOG (a ledger),
#    .dev/decisions + .dev/lessons + .dev/phase_log + .dev/archive +
#    .dev/meta_audits (dated records), and migration_v1_to_v2.md's v1 rows.
#    The class instance: docs recommending a `v2.0.0-rc.1` pin long after
#    stable shipped.
#
# 2. DEAD SCRIPT references: a `scripts/<name>.sh` mention in living docs
#    (README, docs/**, .claude/**, .dev/*.md top level) whose target does
#    not exist — the deleted-campaign-script class (e.g. docs instructing
#    `should_gate_windows.sh` after its removal).
#
# Modes:
#   bash scripts/check_doc_fossils.sh          informational
#   bash scripts/check_doc_fossils.sh --gate   exit 1 on findings

set -euo pipefail
MODE="${1:-info}"
cd "$(dirname "$0")/.."

findings=0
current_version=$(grep -oE '\.version = "[^"]+"' build.zig.zon | sed -E 's/.*"([^"]+)"/\1/')
if [ -z "$current_version" ]; then
    echo "[check_doc_fossils] FAIL — cannot read .version from build.zig.zon" >&2
    exit 1
fi

# --- 1) version fossils -----------------------------------------------------
# PRERELEASE version strings (v2.x.y-rc.N / -alpha.N / -beta.N) in living docs
# are always fossils once the stable line ships (a stable "vX.Y.Z" can be a
# permanent historical fact — "v2.0.0 is the first stable release" never rots —
# so bare stable versions are NOT flagged).
while IFS=: read -r file line content; do
    [ -z "$file" ] && continue
    for v in $(echo "$content" | grep -oE 'v2\.[0-9]+\.[0-9]+-(rc|alpha|beta)\.[0-9]+' | sort -u); do
        echo "VERSION-FOSSIL: $file:$line — prerelease pin '$v' (current is v$current_version)" >&2
        findings=$((findings + 1))
    done
done < <(grep -rnE 'v2\.[0-9]+\.[0-9]+-(rc|alpha|beta)\.[0-9]+' README.md docs .github --include='*.md' 2>/dev/null || true)

# --- 2) dead script references ---------------------------------------------
while IFS=: read -r file line content; do
    [ -z "$file" ] && continue
    # Historical docs (retired campaign machinery kept as reference) are exempt.
    if head -5 "$file" 2>/dev/null | grep -qE 'RETIRED|Loop-era doc|ARCHIVED'; then continue; fi
    # Negated mentions — a doc RECORDING a deletion or striking a name
    # through is not a live instruction to run it.
    case "$content" in *DELETED* | *deleted\ * | *~~*) continue ;; esac
    for sref in $(echo "$content" | grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|py)' | sort -u); do
        if [ ! -f "$sref" ]; then
            echo "DEAD-SCRIPT-REF: $file:$line — '$sref' does not exist" >&2
            findings=$((findings + 1))
        fi
    done
done < <(grep -rnE 'scripts/[A-Za-z0-9_./-]+\.(sh|py)' README.md docs .claude .dev/*.md --include='*.md' 2>/dev/null || true)

if [ "$findings" -gt 0 ]; then
    echo >&2
    echo "[check_doc_fossils] $findings fossil(s) — update the doc to current reality (or move a historical doc under .dev/archive/)" >&2
    [ "$MODE" = "--gate" ] && exit 1
fi
echo "[check_doc_fossils] OK (version v$current_version)" >&2
exit 0
