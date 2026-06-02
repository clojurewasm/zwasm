#!/usr/bin/env bash
# check_doc_state.sh — verify Doc-state markers on .dev/*.md files.
#
# Per ADR-0118 D2 + .claude/rules/doc_state_marker.md (stub).
# Codifies the 2026-05-22 audit finding (Agent 3): 4 close-plan docs
# accumulated without lifecycle markers → claim drift between docs.
#
# Modes:
#   bash scripts/check_doc_state.sh             # informational, exit 0
#   bash scripts/check_doc_state.sh --gate      # exit 1 on missing markers
#
# Exempt files (always-active rulebook docs):
EXEMPT=(
  "ROADMAP.md"
  "handover.md"
  "debt.yaml"
  "proposal_watch.md"
  "lessons/INDEX.md"
)

set -u

mode="${1:-info}"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root" || exit 2

missing=()
total=0

is_exempt() {
  local rel="$1"
  # decisions/ have their own Status: lifecycle (per rule body).
  case "$rel" in
    .dev/decisions/*) return 0 ;;
    .dev/lessons/*) return 0 ;;  # individual lessons exempt; INDEX.md exempt below
  esac
  for ex in "${EXEMPT[@]}"; do
    if [[ "$rel" == ".dev/$ex" ]]; then return 0; fi
  done
  return 1
}

while IFS= read -r f; do
  rel="${f#./}"
  if is_exempt "$rel"; then continue; fi
  total=$((total + 1))
  # Look for Doc-state: marker in first 10 lines (within the top blockquote).
  if ! head -10 "$f" | grep -qE '^\s*>\s*\*\*Doc-state\*\*:|^\s*>\s*Doc-state:'; then
    missing+=("$rel")
  fi
done < <(find .dev -maxdepth 4 -type f -name '*.md' 2>/dev/null)

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "[check_doc_state] OK — $total file(s) checked, all have Doc-state markers"
  exit 0
fi

echo "[check_doc_state] FAIL — ${#missing[@]} of $total files missing Doc-state marker:"
for m in "${missing[@]}"; do echo "  - $m"; done
echo ""
echo "Fix: add a top blockquote line like:"
echo "  > **Doc-state**: ACTIVE | ARCHIVED-IN-PLACE | ARCHIVED | SUPERSEDED-BY"
echo "See .claude/rules/doc_state_marker.md."

if [[ "$mode" == "--gate" ]]; then exit 1; fi
exit 0
