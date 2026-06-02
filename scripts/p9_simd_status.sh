#!/usr/bin/env bash
# Live SIMD spec test status for §9.9 — single source of truth for
# "what's failing right now". Re-run any time; output is always
# authoritative.
#
# This exists because handover.md / debt.yaml should NOT carry numeric
# predictions about FAIL counts (per .claude/rules/no_handover_predictions.md);
# the rule was codified after §9.9-g-13 surfaced a drift case where
# the prior handover predicted "16 cmp fails are alias-case" but the
# actual fails were `i*x*.ne` family.
#
# Usage:
#   bash scripts/p9_simd_status.sh               # both hosts
#   bash scripts/p9_simd_status.sh --ubuntu-only # skip Mac (faster)
#   bash scripts/p9_simd_status.sh --mac-only    # skip ubuntunote (local-only)

set -uo pipefail

LOG_DIR="${TMPDIR:-/tmp}"
UBUNTU_LOG="${LOG_DIR}/p9-ubuntu-simd.log"
MAC_LOG="${LOG_DIR}/p9-mac-simd.log"

want_mac=1
want_ubuntu=1
case "${1:-}" in
  --ubuntu-only|--orb-only) want_mac=0 ;;
  --mac-only) want_ubuntu=0 ;;
  -h|--help)
    sed -n '2,15p' "$0"
    exit 0 ;;
  "") ;;
  *)
    echo "unknown arg: $1" >&2
    exit 2 ;;
esac

# Mac aarch64 host (foreground; cheap if cached).
if [ "$want_mac" = 1 ]; then
  echo "=== Mac aarch64 simd_assert (host) ==="
  if zig build test-spec-simd > "$MAC_LOG" 2>&1; then
    mac_rc=0
  else
    mac_rc=$?
  fi
  if [ "$mac_rc" -ne 0 ]; then
    echo "(zig build test-spec-simd exited $mac_rc — compile or runner failure; tail below)"
  fi
  if grep -E "simd_assert_runner:" "$MAC_LOG" > /dev/null; then
    grep -E "simd_assert_runner:" "$MAC_LOG"
  else
    echo "(runner output not found in log — likely compile failure; tail $MAC_LOG below)"
    tail -5 "$MAC_LOG"
  fi
  echo
fi

# ubuntunote (native Linux x86_64 via SSH per ADR-0067).
if [ "$want_ubuntu" = 1 ]; then
  echo "=== ubuntunote Linux x86_64 simd_assert ==="
  if ! ssh -o ConnectTimeout=3 -o BatchMode=yes ubuntunote true 2>/dev/null; then
    echo "(ubuntunote unreachable; skipping ubuntunote section)"
  else
    if bash scripts/run_remote_ubuntu.sh test-spec-simd > "$UBUNTU_LOG" 2>&1; then
      ubuntu_rc=0
    else
      ubuntu_rc=$?
    fi
    if [ "$ubuntu_rc" -ne 0 ]; then
      echo "(run_remote_ubuntu.sh test-spec-simd exited $ubuntu_rc — see [run_remote_ubuntu] FAIL line in tail)"
    fi

    if grep -E "simd_assert_runner:" "$UBUNTU_LOG" > /dev/null; then
      grep -E "simd_assert_runner:" "$UBUNTU_LOG"
    else
      echo "(runner output not found / aborted; tail $UBUNTU_LOG below)"
      tail -3 "$UBUNTU_LOG"
    fi
    echo

    echo "=== ubuntunote FAIL breakdown by manifest ==="
    grep -E "^FAIL " "$UBUNTU_LOG" | awk '{print $2}' | sed 's/:$//' \
      | sort | uniq -c | sort -rn

    echo
    echo "=== Sample FAIL per manifest (1 each) ==="
    for cat in $(grep -E "^FAIL " "$UBUNTU_LOG" | awk '{print $2}' \
                 | sed 's/:$//' | sort -u); do
      grep -m1 "^FAIL  ${cat}" "$UBUNTU_LOG"
    done
    echo
  fi
fi

# Active `now` debt entries (so the loop knows which to discharge).
# One-line summary per entry for at-a-glance scanning; full body lives
# in .dev/debt.yaml (status enum: now|blocked-by|resolved|partial|note).
echo "=== Currently \`now\` debt entries (one-line summaries) ==="
yq -r '.entries[] | select(.status == "now") | .id + ": " + (.description | sub("\. .*$"; "."))' .dev/debt.yaml \
  | cut -c1-140

echo
echo "Logs: Mac=$MAC_LOG ubuntunote=$UBUNTU_LOG"
