#!/usr/bin/env bash
# check_debt_yaml.sh — lint the debt.yaml SSOT (D-227 / ADR-0129).
#
# Adapts the ClojureWasmFromScratch YAML-debt validation to this project's
# delete-on-discharge model: it validates the LEDGER's own integrity (parse,
# required fields, status enum, blocked-by⇒last_reviewed, unique IDs) + scans
# for phantom `D-NEW*` placeholders — it does NOT try to resolve every cited
# D-NNN (resolved debts are deleted here by design; git retains them).
#
#   bash scripts/check_debt_yaml.sh           # informational, exit 0
#   bash scripts/check_debt_yaml.sh --gate    # exit 1 on any violation
#
# Discipline reference: .claude/rules/yaml_ssot_yq.md.
set -euo pipefail
cd "$(dirname "$0")/.."

GATE=0
[[ "${1:-}" == "--gate" ]] && GATE=1
DEBT=.dev/debt.yaml
viol=0
ok()   { echo "[check_debt_yaml] OK — $1"; }
fail() { echo "[check_debt_yaml] FAIL — $1" >&2; viol=$((viol + 1)); }

if [[ ! -f "$DEBT" ]]; then
  echo "[check_debt_yaml] FAIL — $DEBT missing" >&2; exit 1
fi

# 1. Parses (a malformed block scalar makes this error).
if ! yq -e '.entries | type == "!!seq"' "$DEBT" >/dev/null 2>&1; then
  echo "[check_debt_yaml] FAIL — $DEBT does not parse or has no .entries list" >&2; exit 1
fi
n=$(yq -r '.entries | length' "$DEBT")
ok "$DEBT parses; $n entries"

# 2. Required fields present + non-null on every entry.
missing=$(yq -r '.entries[] | select((has("id") and has("layer") and has("status") and has("description") and has("first_raised") and has("last_reviewed") and has("refs")) | not) | .id // "<no-id>"' "$DEBT")
[[ -n "$missing" ]] && fail "entries missing a required field: $missing"

# 3. status enum.
badstatus=$(yq -r '.entries[] | select(.status | test("^(now|blocked-by|resolved|partial|note)$") | not) | .id + "=" + .status' "$DEBT")
[[ -n "$badstatus" ]] && fail "entries with non-enum status (now|blocked-by|resolved|partial|note): $badstatus"

# 4. blocked-by ⇒ last_reviewed mandatory (the staleness-sweep input).
noreview=$(yq -r '.entries[] | select(.status == "blocked-by" and (.last_reviewed == "")) | .id' "$DEBT")
[[ -n "$noreview" ]] && fail "blocked-by entries missing last_reviewed (mandatory): $noreview"

# 5. unique IDs.
dupes=$(yq -r '.entries[].id' "$DEBT" | sort | uniq -d)
[[ -n "$dupes" ]] && fail "duplicate IDs: $dupes"

# 6. phantom D-NEW* placeholders anywhere in the live tree (never-filed stubs).
phantom=$(grep -rIoE 'D-NEW[A-Z0-9-]*' \
  --include='*.zig' --include='*.md' --include='*.sh' --include='*.yaml' \
  src .claude scripts .dev 2>/dev/null \
  | grep -v '.dev/decisions/' | grep -v '.dev/lessons/' | grep -v '.dev/archive/' \
  | grep -vE 'check_debt_yaml\.sh|yaml_ssot_yq\.md|gate_commit\.sh|audit_scaffolding/' \
  | sort -u || true)
[[ -n "$phantom" ]] && fail "phantom D-NEW* placeholders (file them or remove): $phantom"

if [[ "$viol" -gt 0 ]]; then
  echo "[check_debt_yaml] $viol violation(s)"
  [[ "$GATE" -eq 1 ]] && exit 1
else
  ok "schema valid ($n entries; status enum, blocked-by review-dates, unique IDs, no phantoms)"
fi
exit 0
