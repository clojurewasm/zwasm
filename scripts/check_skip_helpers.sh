#!/usr/bin/env bash
# scripts/check_skip_helpers.sh — Enforce ADR-0122 test-skip categorization.
#
# Per ADR-0122 (2026-05-27), test-time `error.SkipZigTest` must route
# through `src/test_support/skip.zig` helpers in two categories:
#   - skip.phaseEnd(.win64)     — Phase-end batch deferral
#   - skip.blocker(.@"D-NNN")   — Blocker-paired debt review
# Arch-pinned tests use `comptime` early-return (no skip count).
# Build-flag gates (`!enabled` / `!trace.enabled` / `!run_jit`) are EXEMPT.
#
# Behaviors:
#   1. raw-skip count gate: error if `error.SkipZigTest` appears outside
#      skip.zig + the migration grace baseline.
#   2. blocker enum vs debt.yaml pairing: every `skip.blocker(.@"D-NNN")`
#      arg must have a row in `.dev/debt.yaml`.
#   3. SIBLING-AT marker: every `if (comptime ... != .ARCH) return;`
#      under src/engine/codegen/ must have a paired SIBLING-AT comment
#      whose path exists.
#
# Usage:
#   bash scripts/check_skip_helpers.sh           # report mode (exit 0)
#   bash scripts/check_skip_helpers.sh --gate    # exit 1 on violation

set -u

GATE_MODE=0
if [[ "${1:-}" == "--gate" ]]; then
  GATE_MODE=1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RC=0
findings=()

# ============================================================
# Check 1: raw error.SkipZigTest outside skip.zig + build-flag exempt
# ============================================================

# Grep for raw skip sites, exclude:
#   - the skip.zig helper itself (allowed)
#   - build-flag gates (!enabled / !trace.enabled / !run_jit / !run\b)
RAW_BASELINE=0  # migration target post-cycle-A. Update with ADR amendment.
raw_count=$(
  grep -rn "return error\.SkipZigTest" src/ test/ 2>/dev/null \
    | grep -v "test_support/skip\.zig" \
    | grep -vE "!enabled|!trace\.enabled|!run_jit|!run\b" \
    | wc -l \
    | tr -d ' '
)

if (( raw_count > RAW_BASELINE )); then
  findings+=("[raw-skip] $raw_count raw error.SkipZigTest sites (baseline=$RAW_BASELINE) outside skip.zig + build-flag exempt")
  if (( GATE_MODE )); then RC=1; fi
fi

# ============================================================
# Check 2: skip.blocker(.@"D-NNN") args must pair to .dev/debt.yaml entries
# ============================================================

mapfile -t blocker_args < <(
  grep -rhEn 'skip\.blocker\(\.@"D-[0-9]+"\)' src/ test/ 2>/dev/null \
    | grep -oE 'D-[0-9]+' \
    | sort -u
)

for d in "${blocker_args[@]}"; do
  if ! D_ID="$d" yq -e '.entries[] | select(.id == env(D_ID))' .dev/debt.yaml >/dev/null 2>&1; then
    findings+=("[blocker-pairing] skip.blocker(.@\"${d}\") used but no entry in .dev/debt.yaml")
    if (( GATE_MODE )); then RC=1; fi
  fi
done

# Also: every variant in Blocker enum should be used at least once
# (orphan enum = unused). Info-only finding.
mapfile -t enum_variants < <(
  grep -oE '@"D-[0-9]+"' src/test_support/skip.zig | sort -u | tr -d '@"'
)
for v in "${enum_variants[@]}"; do
  if ! grep -rq "skip\.blocker(\.@\"${v}\")" src/ test/ 2>/dev/null; then
    findings+=("[blocker-orphan] Blocker.@\"${v}\" declared in skip.zig but no call site uses it (info)")
  fi
done

# ============================================================
# Check 3: SIBLING-AT marker presence + resolution
# ============================================================

# Find every "if (comptime ... != .ARCH) return;" pattern (or similar arch-pinned
# comptime early-return) and verify a SIBLING-AT comment within 3 lines above.
mapfile -t comptime_sites < <(
  grep -rnE 'if \(comptime [^)]*(\.os\.tag|\.cpu\.arch|abi\.current_cc)[^)]*\) return;' \
    src/ test/ 2>/dev/null \
    | grep -v "test_support/skip\.zig"
)

for site in "${comptime_sites[@]}"; do
  file="${site%%:*}"
  rest="${site#*:}"
  lineno="${rest%%:*}"
  # Scope: only flag comptime guards INSIDE test blocks. Approximate
  # by checking that `const testing = std.testing` or `test "` appears
  # before the match line in the same file. Impl-side comptime guards
  # (e.g. `pub fn install() void { if (comptime ...) return; }`) are
  # not in scope of ADR-0122 D3.
  prelude=$(sed -n "1,$((lineno - 1))p" "$file" 2>/dev/null)
  if ! echo "$prelude" | grep -qE 'const testing = std\.testing|^test "'; then
    continue
  fi
  # Look at 3 lines above for SIBLING-AT comment
  start=$((lineno - 4))
  (( start < 1 )) && start=1
  context=$(sed -n "${start},${lineno}p" "$file" 2>/dev/null)
  if ! echo "$context" | grep -q "SIBLING-AT:"; then
    findings+=("[sibling-at] $file:$lineno comptime arch guard lacks SIBLING-AT: comment (per ADR-0122 D3)")
    if (( GATE_MODE )); then RC=1; fi
  else
    # Verify the referenced path exists
    sibling_path=$(echo "$context" | grep -oE "SIBLING-AT: [^[:space:]]+" | head -1 | awk '{print $2}')
    if [[ -n "$sibling_path" ]] && [[ ! -e "$sibling_path" ]]; then
      # Strip ":NNN" line-number suffix if any
      bare_path="${sibling_path%:*}"
      if [[ ! -e "$bare_path" ]]; then
        findings+=("[sibling-at-dead] $file:$lineno cites SIBLING-AT: $sibling_path (path missing)")
        if (( GATE_MODE )); then RC=1; fi
      fi
    fi
  fi
done

# ============================================================
# Check 4 (info): Win64 phase-end batch count widget
# ============================================================

win64_count=$(
  grep -rEn 'skip\.phaseEnd\(\.win64\)' src/ test/ 2>/dev/null \
    | wc -l \
    | tr -d ' '
)
findings+=("[info] Win64 phase-end batch = $win64_count tests")

# ============================================================
# Report
# ============================================================

if (( ${#findings[@]} > 0 )); then
  for f in "${findings[@]}"; do echo "$f"; done
fi

if (( GATE_MODE && RC != 0 )); then
  echo "[check_skip_helpers] GATE FAILED — fix the above and re-run." >&2
  exit 1
fi

echo "[check_skip_helpers] OK"
exit 0
