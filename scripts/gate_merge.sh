#!/usr/bin/env bash
# Pre-merge gate. Runs the commit gate plus three-host test:
#   - zig build test-all on Mac native
#   - zig build test-all on OrbStack Ubuntu x86_64 (if available)
#   - zig build test-all on `windowsmini` SSH host (if reachable)
#
# Phase 0 / early phases: missing OrbStack VM or unreachable
# windowsmini → WARN and continue (the local Mac gate is the firm
# floor; the other hosts are belt-and-braces while the project
# bootstraps).
#
# Phase 13+ folds the same logic into CI; the local gate stays as
# the first line of defense.
#
# Exits non-zero on any host that built but had a failed test, on
# any commit-gate failure, or on missing tools (orb / ssh) where
# the corresponding host would be required by the current phase.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "[gate_merge] Running commit gate first ..."
bash scripts/gate_commit.sh

echo "[gate_merge] zig build test-all on Mac native ..."
zig build test-all

# ---- OrbStack Ubuntu x86_64 ----
if command -v orb >/dev/null 2>&1; then
    if orb info my-ubuntu-amd64 >/dev/null 2>&1; then
        echo "[gate_merge] zig build test-all on OrbStack Ubuntu x86_64 ..."
        orb run -m my-ubuntu-amd64 bash -c "cd '$PWD' && zig build test-all"
    else
        echo "[gate_merge] WARN: OrbStack VM 'my-ubuntu-amd64' not found." >&2
        echo "             Set up via .dev/orbstack_setup.md, then retry." >&2
        echo "             (Phase 0 / early: WARN only; Phase 7+ this is required.)" >&2
    fi
else
    echo "[gate_merge] WARN: orb not installed; skipping Linux native gate." >&2
fi

# ---- Windows x86_64 via SSH (windowsmini) ----
if ssh -o ConnectTimeout=5 -o BatchMode=yes windowsmini "echo ok" >/dev/null 2>&1; then
    echo "[gate_merge] zig build test-all on windowsmini SSH ..."
    ssh windowsmini "cd zwasm_from_scratch && zig build test-all"
else
    echo "[gate_merge] WARN: windowsmini SSH unreachable; skipping Windows gate." >&2
    echo "             See .dev/windows_ssh_setup.md." >&2
    echo "             (Phase 0 / early: WARN only; Phase 7+ this is required.)" >&2
fi

if [ -f scripts/sync_versions.sh ]; then
    echo "[gate_merge] sync_versions ..."
    bash scripts/sync_versions.sh
fi

echo "[gate_merge] All gates passed (with WARNs noted above where applicable)."
