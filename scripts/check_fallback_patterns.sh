#!/usr/bin/env bash
# scripts/check_fallback_patterns.sh — Anti-fallback / anti-silent-degradation
# pattern detector.
#
# Greps `src/**/*.zig` for forbidden silent-degradation patterns per
# `.claude/rules/no_fallback_on_failure.md`:
#
#   - `catch {}`                          (= fully silent error swallow)
#   - `catch |err| return null`           (= silent fallthrough)
#   - `catch |err| return undefined`      (= silent fallthrough)
#
# Warn-only patterns (manual review):
#   - `catch |err| .<lowercase_default_value>` (e.g. `.empty`, `.none`)
#
# Exemption: a `// EXEMPT-FALLBACK: <reason>` comment on the immediately-
# preceding line whitelists the site. The reason text should cite an
# ADR or a debt-row.
#
# Phase 9 completion master plan §7.4 / ADR-0071 + ADR-0050 amend.
#
# Modes:
#   --gate    : exit non-zero on any FAIL (pre-commit gate)
#   --report  : exit 0; print full inventory

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,23p' "$0"
  exit 0
fi

MODE="${1:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL_SITES=()
WARN_SITES=()
EXEMPT_SITES=()

is_exempt() {
  local file="$1" line="$2"
  [ "$line" -lt 2 ] && return 1
  local prev
  prev=$(sed -n "$((line-1))p" "$file" 2>/dev/null || true)
  case "$prev" in
    *"EXEMPT-FALLBACK"*) return 0 ;;
  esac
  return 1
}

scan_pattern() {
  local label="$1" severity="$2" pattern="$3"
  local match file line
  while IFS= read -r match; do
    [ -z "$match" ] && continue
    file="${match%%:*}"
    line=$(echo "$match" | cut -d: -f2)
    if is_exempt "$file" "$line"; then
      EXEMPT_SITES+=("$label  $file:$line  (EXEMPT-FALLBACK)")
      continue
    fi
    if [ "$severity" = "fail" ]; then
      FAIL_SITES+=("$label  $match")
    else
      WARN_SITES+=("$label  $match")
    fi
  done < <(grep -rnE "$pattern" --include='*.zig' src/ 2>/dev/null || true)
}

# FAIL: fully-silent catch {}
scan_pattern "catch{}" fail 'catch[[:space:]]*\{[[:space:]]*\}'

# FAIL: catch |err| return null  /  return undefined
scan_pattern "catch-return-null" fail 'catch[[:space:]]*\|[^|]+\|[[:space:]]+return[[:space:]]+(null|undefined)'

# WARN: catch |err| .<lowercase_default> (default-value fallthrough)
scan_pattern "catch-default-value" warn 'catch[[:space:]]*\|[^|]+\|[[:space:]]+\.[a-z_]+(_default|_empty|_zero|_none)\b'

echo "=== fallback pattern check (per .claude/rules/no_fallback_on_failure.md) ==="
echo "fail:    ${#FAIL_SITES[@]}"
echo "warn:    ${#WARN_SITES[@]}"
echo "exempt:  ${#EXEMPT_SITES[@]}"
echo ""

if [ "${#FAIL_SITES[@]}" -gt 0 ]; then
  echo "--- forbidden sites (FAIL) ---"
  for s in "${FAIL_SITES[@]}"; do echo "  $s"; done
  echo ""
fi
if [ "${#WARN_SITES[@]}" -gt 0 ]; then
  echo "--- suspicious sites (WARN — manual review) ---"
  for s in "${WARN_SITES[@]}"; do echo "  $s"; done
  echo ""
fi
if [ "${#EXEMPT_SITES[@]}" -gt 0 ] && [ "$MODE" != "--gate" ]; then
  echo "--- exempt sites (// EXEMPT-FALLBACK marker; manual audit recommended) ---"
  for s in "${EXEMPT_SITES[@]}"; do echo "  $s"; done
  echo ""
fi

if [ "$MODE" = "--gate" ] && [ "${#FAIL_SITES[@]}" -gt 0 ]; then
  echo "[check_fallback_patterns] FAIL — silent error-swallow patterns present"
  echo "[check_fallback_patterns] Fix: propagate error, OR whitelist with"
  echo "                          // EXEMPT-FALLBACK: <reason citing ADR or debt row>"
  exit 1
fi

echo "[check_fallback_patterns] OK"
exit 0
