#!/usr/bin/env bash
# Pre-merge gate. Runs the commit gate plus three-host test:
#   - zig build test-all on Mac native
#   - zig build test-all on `ubuntunote` Linux x86_64 SSH host
#     (per ADR-0067; native, not OrbStack-Rosetta)
#   - zig build test-all on `windowsmini` SSH host (if reachable)
#
# Phase 0 / early phases: missing ubuntunote SSH or unreachable
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
#   - test-wasmtime-misc-basic   (§9.6 / 6.B per ADR-0012; was test-v1-carry-over)
#   - test-realworld       (§9.6 / 6.1 chunk a; 50 fixtures, parse)
#   - test-realworld-run   (§9.6 / 6.1 chunk b; 50 fixtures, run)
#   - test-spec / test-spec-wasm-2.0 / test-c-api / test-wasi-p1
# The "ClojureWasm guest" half of A13 lands when §9.6 / 6.3 wires
# its `build.zig.zon` `path = ...` end-to-end. Until then this
# gate is A13 minus ClojureWasm — every other A13 layer is
# enforced on every push to `main`.
#
# Exits non-zero on any host that built but had a failed test, on
# any commit-gate failure, or on missing tools (orb / ssh) where
# the corresponding host would be required by the current phase.

set -euo pipefail
cd "$(dirname "$0")/.."

SKIPPED_HOSTS=()

echo "[gate_merge] Running commit gate first ..."
bash scripts/gate_commit.sh

echo "[gate_merge] zig build test-all on Mac native ..."
zig build test-all

# Build-option DCE / level-separation enforcement (ADR-0073 + ADR-0130 / D-230).
# `--gate` builds the 6 `-Dwasm × -Dwasi` combos and `nm`-greps that no
# higher-level feature symbol leaks into a lower-level binary; exits non-zero on
# any leak. Home here (merge gate, `main`-push only) — 6 ReleaseSafe builds are
# too slow for per-commit. Was historically wired only into the never-called
# `check_subrow_exit.sh` (lesson 2026-06-02-detection-without-enforcement-dead-gate).
echo "[gate_merge] build-option DCE / level-separation check (6 combos) ..."
bash scripts/check_build_dce.sh --gate

# D-245 regression — host→JIT callee-saved preservation only fails in
# ReleaseSafe (Debug-only unit tests miss it). Home here (merge gate) since it
# needs a full ReleaseSafe build; per-commit would be too slow.
echo "[gate_merge] --engine=jit ReleaseSafe smoke (D-245) ..."
bash scripts/check_jit_releasesafe.sh

# §12.3 — the AOT pipeline (producer/loader/runner) must cross-compile for
# non-host targets. Home here (merge gate): 3 cross-builds are ~30-60s each,
# too slow per-commit. Compile-only (no exec); cross-ARCH emission stays
# deferred per ADR-0039 (Alt D). The "cross-produced .cwasm runs on target"
# half is the per-host `runCwasm` round-trip in the test-all runs below.
echo "[gate_merge] AOT cross-compile portability (§12.3) ..."
bash scripts/check_aot_cross_compile.sh

# The Linux/Windows SSH hosts default to the maintainer's aliases; override
# with ZWASM_UBUNTU_HOST / ZWASM_WINDOWS_HOST to run the gate on your own hosts.
UBUNTU_HOST="${ZWASM_UBUNTU_HOST:-ubuntunote}"
WINDOWS_HOST="${ZWASM_WINDOWS_HOST:-windowsmini}"

# ---- native Linux x86_64 via SSH ----
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$UBUNTU_HOST" "echo ok" >/dev/null 2>&1; then
    echo "[gate_merge] zig build test-all on $UBUNTU_HOST (native x86_64) ..."
    bash scripts/run_remote_ubuntu.sh test-all
else
    SKIPPED_HOSTS+=("$UBUNTU_HOST (Linux x86_64) — SSH unreachable; see .dev/ubuntunote_setup.md")
    echo "[gate_merge] WARN: $UBUNTU_HOST SSH unreachable; skipping Linux gate." >&2
fi

# ---- Windows x86_64 via SSH ----
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$WINDOWS_HOST" "echo ok" >/dev/null 2>&1; then
    echo "[gate_merge] zig build test-all on $WINDOWS_HOST SSH ..."
    bash scripts/run_remote_windows.sh test-all
else
    SKIPPED_HOSTS+=("$WINDOWS_HOST (Windows x86_64) — SSH unreachable; see .dev/windows_ssh_setup.md")
    echo "[gate_merge] WARN: $WINDOWS_HOST SSH unreachable; skipping Windows gate." >&2
fi

if [ -f scripts/sync_versions.sh ]; then
    echo "[gate_merge] sync_versions ..."
    bash scripts/sync_versions.sh
fi

# Final skipped-hosts summary. Bootstrap-friendly WARN-and-continue
# is acceptable in Phase 0 / early phases; from Phase 8 onward (per
# ADR-0067 + project release-gate discipline) a complete 3-host
# gate is required for any push to `main`. The user / CI evaluates
# the policy threshold; this script just records what happened.
if [ "${#SKIPPED_HOSTS[@]}" -gt 0 ]; then
    echo
    echo "[gate_merge] SUMMARY — hosts skipped (non-zero count = incomplete merge gate):" >&2
    for h in "${SKIPPED_HOSTS[@]}"; do
        echo "  - $h" >&2
    done
    echo "[gate_merge] Phase 0 / early: WARN-only is acceptable; Phase 8+: required hosts must be green." >&2
fi

echo "[gate_merge] All gates passed (with WARNs noted above where applicable)."
