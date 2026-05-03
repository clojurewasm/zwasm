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
# Phase 14+ folds the same logic into CI; the local gate stays as
# the first line of defense.
#
# §A13 enforcement (Phase 6+ / §9.6 / 6.5): `test-all` aggregates
# every layer in ROADMAP §A13's "v1 regression suite" definition
# that v2 has stood up so far:
#   - test-v1-carry-over   (§9.6 / 6.0; vendored v1 regression bundle)
#   - test-realworld       (§9.6 / 6.1 chunk a; 50 fixtures, parse)
#   - test-realworld-run   (§9.6 / 6.1 chunk b; 50 fixtures, run)
#   - test-spec / test-spec-wasm-2.0 / test-c-api / test-wasi-p1
# The "ClojureWasm guest" half of A13 lands when §9.6 / 6.3 wires
# its `build.zig.zon` `path = ...` end-to-end. Until then this
# gate is A13 minus ClojureWasm — every other A13 layer is
# enforced on every push to `zwasm-from-scratch`.
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
        echo "             (Phase 0 / early: WARN only; Phase 8+ this is required.)" >&2
    fi
else
    echo "[gate_merge] WARN: orb not installed; skipping Linux native gate." >&2
fi

# ---- Windows x86_64 via SSH (windowsmini) ----
if ssh -o ConnectTimeout=5 -o BatchMode=yes windowsmini "echo ok" >/dev/null 2>&1; then
    echo "[gate_merge] zig build test-all on windowsmini SSH ..."
    bash scripts/run_remote_windows.sh test-all
else
    echo "[gate_merge] WARN: windowsmini SSH unreachable; skipping Windows gate." >&2
    echo "             See .dev/windows_ssh_setup.md." >&2
    echo "             (Phase 0 / early: WARN only; Phase 8+ this is required.)" >&2
fi

if [ -f scripts/sync_versions.sh ]; then
    echo "[gate_merge] sync_versions ..."
    bash scripts/sync_versions.sh
fi

echo "[gate_merge] All gates passed (with WARNs noted above where applicable)."
