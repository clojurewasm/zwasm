#!/usr/bin/env bash
# OPTIONAL local pre-PR pre-flight that MIRRORS CI. Runs the commit gate plus a
# three-host test:
#   - zig build test-all on Mac native
#   - zig build test-all on `ubuntunote` Linux x86_64 SSH host
#     (per ADR-0067; native, not OrbStack-Rosetta)
#   - zig build test-all on `windowsmini` SSH host (if reachable)
#
# `main` is ruleset-protected (no direct pushes) — changes land via a
# develop/<slug> branch → PR → CI. The AUTHORITATIVE 3-OS merge gate is the
# server-side `ci-required` status check on the PR. This script is a
# convenience: it mirrors that same `scripts/ci_gate.sh` matrix on real
# hardware so a maintainer CAN verify locally before opening a PR — but it is
# not required, and green here is not a substitute for green ci-required.
#
# Missing ubuntunote SSH or unreachable windowsmini → WARN and continue (the
# local Mac gate is the firm floor).
#
# `test-all` aggregates every layer in ROADMAP §A13's "v1 regression suite"
# definition that v2 has stood up:
#   - test-wasmtime-misc-basic   (§9.6 / 6.B per ADR-0012; was test-v1-carry-over)
#   - test-realworld       (§9.6 / 6.1 chunk a; 50 fixtures, parse)
#   - test-realworld-run   (§9.6 / 6.1 chunk b; 50 fixtures, run)
#   - test-spec / test-spec-wasm-2.0 / test-c-api / test-wasi-p1
# The same layers run in CI's ci-required matrix, which is what actually gates
# a merge to `main`; this local run just previews that outcome.
#
# Exits non-zero on any host that built but had a failed test, on any
# commit-gate failure, or on missing tools (ssh) — as a local preview signal,
# not a merge gate.

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

# Final skipped-hosts summary. This is an OPTIONAL local pre-flight — a skipped
# host just means this preview is incomplete, NOT that a merge is blocked. The
# authoritative 3-OS gate is CI's `ci-required` check on the PR; run the missing
# host(s) locally only if you want a fuller local preview before opening one.
if [ "${#SKIPPED_HOSTS[@]}" -gt 0 ]; then
    echo
    echo "[gate_merge] SUMMARY — hosts skipped (incomplete local preview; CI ci-required still gates the merge):" >&2
    for h in "${SKIPPED_HOSTS[@]}"; do
        echo "  - $h" >&2
    done
fi

echo "[gate_merge] Local pre-flight complete (with WARNs noted above where applicable) — CI ci-required is the authoritative merge gate."
