#!/usr/bin/env bash
# D-134 Rosetta-2 retry wrapper for the OrbStack test-all gate.
#
# Per `.dev/lessons/2026-05-17-d134-rosetta-2-signal-translation-limit.md`,
# OrbStack's `my-ubuntu-amd64` machine runs x86_64 binaries
# through Apple's Rosetta 2 dynamic translation. Long-running
# JIT workloads (specifically `zwasm-spec-wasm-2-0-assert` at
# 24,000+ fixtures) hit a Rosetta signal-delivery race that
# terminates the process with SIGSEGV before our guest-side
# `sigaction(.SEGV, ...)` handler can fire. The crash is
# deterministic in position but stochastic in outcome — roughly
# 30% green / 70% SEGV per direct run.
#
# This wrapper executes `zig build test-all` and, on failure
# matching the D-134 fingerprint (spec-wasm-2-0-assert step +
# SIGSEGV signal termination), retries up to ${MAX_RETRIES}.
# Any non-D-134 failure surfaces immediately. All retries
# failing surfaces with the original error.
#
# Usage: bash scripts/orb_test_all_with_d134_retry.sh [LOG_PATH]
#   LOG_PATH defaults to /tmp/orb.log.
#
# Exits 0 on first green attempt; otherwise propagates the
# final failure's exit code (always non-zero on failure paths).
#
# Why per-attempt full `test-all`, not per-step retry: Zig's
# build system caches successful runs across invocations
# (incremental), so re-running `test-all` after a partial fail
# only re-executes the failed step(s). Wall-clock cost of a
# retry is ~2-5 s (cached build) + the runner's actual
# execution time.

# Intentionally `set -u` only (no `-e`, no `-o pipefail`):
# the script captures `orb run`'s exit code via `$?` after the
# command, which `set -e` would short-circuit. A future editor
# adding a piped invocation must re-evaluate this choice.
set -u

# WARNING (post-ADR-0067, 2026-05-17): the fingerprint match
# below uses two whole-log `grep -q` checks. If a future run
# produces BOTH strings from unrelated steps (e.g. another
# runner SEGVs while the spec-wasm-2-0-assert step also has
# an unrelated "failure" line), this classifier will
# false-positive and retry a non-D-134 regression. Anchor the
# match to the spec-wasm-2-0-assert step window (e.g. `awk`
# between its start banner and failure line) before
# re-introducing this wrapper to a hot gate path.

LOG_PATH="${1:-/tmp/orb.log}"
MACHINE="${ORB_MACHINE:-my-ubuntu-amd64}"
MAX_RETRIES="${D134_MAX_RETRIES:-5}"
REPO_PATH="${REPO_PATH:-/Users/shota.508/Documents/MyProducts/zwasm_from_scratch}"

attempt=1
last_exit=1
while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
    echo "[d134-retry] attempt ${attempt}/${MAX_RETRIES} (machine=${MACHINE})" >&2
    orb run -m "${MACHINE}" bash -c \
        "cd ${REPO_PATH} && zig build test-all --summary all" \
        >"${LOG_PATH}" 2>&1
    last_exit=$?
    if [ "${last_exit}" -eq 0 ]; then
        echo "[d134-retry] green on attempt ${attempt}" >&2
        exit 0
    fi

    # Classify failure: D-134 fingerprint = spec-wasm-2-0-assert
    # step + "process terminated with signal SEGV".
    if ! grep -q "zwasm-spec-wasm-2-0-assert failure" "${LOG_PATH}" \
        || ! grep -q "process terminated with signal SEGV" "${LOG_PATH}"; then
        echo "[d134-retry] non-D-134 failure; surfacing (exit ${last_exit})" >&2
        echo "[d134-retry] tail of ${LOG_PATH}:" >&2
        tail -25 "${LOG_PATH}" >&2
        exit "${last_exit}"
    fi

    echo "[d134-retry] D-134 fingerprint matched (Rosetta SEGV); retrying" >&2
    attempt=$((attempt + 1))
done

echo "[d134-retry] FAILED after ${MAX_RETRIES} attempts — D-134 may be a real regression" >&2
echo "[d134-retry] tail of ${LOG_PATH}:" >&2
tail -25 "${LOG_PATH}" >&2
exit "${last_exit}"
