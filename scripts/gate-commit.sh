#!/usr/bin/env bash
# scripts/gate-commit.sh — single entrypoint for the Commit Gate.
#
# Mirrors the checklist in CLAUDE.md (`### Commit Gate Checklist`)
# items 1-8 in order. Item 0 (TDD discipline) and item 8b (decisions
# / checklist / spec-support / memo updates) are human-only and not
# executed here.
#
# Designed to run identically on:
#   - macOS / Linux inside the Nix devshell (direnv-managed)
#   - Windows under Git for Windows bash, with toolchain provisioned
#     by scripts/windows/install-tools.ps1
#
# Usage:
#   bash scripts/gate-commit.sh                 # all default steps
#   bash scripts/gate-commit.sh --skip=spec     # skip a step (repeatable)
#   bash scripts/gate-commit.sh --only=tests    # run a single step
#   bash scripts/gate-commit.sh --bench         # add the optional bench step
#
# Exit codes: 0 when every executed step passed, 1 on first failure.
# A summary line is always printed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/versions.sh
source "$SCRIPT_DIR/lib/versions.sh"

cd "$ZWASM_REPO_ROOT"

# --- Argument parsing ---

SKIP_LIST=""
ONLY=""
RUN_BENCH=0
for arg in "$@"; do
    case "$arg" in
        --skip=*) SKIP_LIST="$SKIP_LIST ${arg#--skip=}" ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --bench)  RUN_BENCH=1 ;;
        --help|-h)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *)
            echo "gate-commit: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# --- Devshell awareness (Linux/Mac only) ---

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) HOST_KIND="windows" ;;
    Darwin)               HOST_KIND="macos"   ;;
    Linux)                HOST_KIND="linux"   ;;
    *)                    HOST_KIND="other"   ;;
esac

if [ "$HOST_KIND" != "windows" ] && [ -z "${IN_NIX_SHELL:-}" ]; then
    if command -v nix >/dev/null 2>&1 && [ -f "$ZWASM_REPO_ROOT/flake.nix" ]; then
        echo "WARN: not in nix devshell (IN_NIX_SHELL unset). Tools may not match flake.nix pins." >&2
        echo "      Run: direnv allow   (or)   nix develop" >&2
    fi
fi

# Steps CI cannot run on a given host — match the `if: runner.os != X`
# guards in .github/workflows/ci.yml so local `gate-commit.sh` lines up
# with what CI will actually verify. Plan C tracks closing each gap;
# host-specific skips are added here when (and only when) the
# corresponding CI guard is still in place.

# --- Step framework ---

STEPS_RUN=0
STEPS_PASSED=0
STEPS_FAILED=0
FAILED_NAMES=""

should_run() {
    local name="$1"
    if [ -n "$ONLY" ]; then
        [ "$ONLY" = "$name" ]
        return
    fi
    case " $SKIP_LIST " in
        *" $name "*) return 1 ;;
    esac
    return 0
}

run_step() {
    local name="$1"
    shift
    if ! should_run "$name"; then
        printf '  [SKIP] %s\n' "$name"
        return 0
    fi
    STEPS_RUN=$((STEPS_RUN + 1))
    printf '\n=== [%s] %s ===\n' "$name" "$*"
    if "$@"; then
        STEPS_PASSED=$((STEPS_PASSED + 1))
        printf '  [PASS] %s\n' "$name"
    else
        STEPS_FAILED=$((STEPS_FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES $name"
        printf '  [FAIL] %s\n' "$name"
    fi
}

# --- Steps (mirroring CLAUDE.md Commit Gate items 1-8) ---

step_tests()        { zig build test; }
step_spec()         { python3 test/spec/run_spec.py --build --summary; }
step_e2e() {
    # CI clones wasmtime tests/misc_testsuite per run; locally we cache
    # it under .cache/ (gitignored) so subsequent invocations are fast.
    local default_dir="$ZWASM_REPO_ROOT/.cache/wasmtime"
    if [ -z "${WASMTIME_MISC_DIR:-}" ]; then
        if [ ! -d "$default_dir/tests/misc_testsuite" ]; then
            echo "  e2e: wasmtime misc_testsuite missing; cloning to $default_dir"
            mkdir -p "$default_dir"
            git clone --depth 1 --filter=blob:none --sparse \
                https://github.com/bytecodealliance/wasmtime.git "$default_dir"
            ( cd "$default_dir" && git sparse-checkout set tests/misc_testsuite )
        fi
        export WASMTIME_MISC_DIR="$default_dir/tests/misc_testsuite"
    fi
    python3 test/e2e/run_e2e.py --convert --summary
}
step_realworld() {
    # build_all.py is idempotent (skips up-to-date wasms); chain it so
    # run_compat.py always finds artefacts. CI runs them as separate
    # steps because each gets its own caching/log section.
    python3 test/realworld/build_all.py && python3 test/realworld/run_compat.py
}
step_ffi()          { bash test/c_api/run_ffi_test.sh --build; }
step_bench_quick()  { bash bench/run_bench.sh --quick; }
step_minimal()      { zig build test -Djit=false -Dcomponent=false -Dwat=false; }

# Steps 1-5 are unconditional, 6 is opt-in, 8 is the minimal build.
# (Step 7 — size & memory budget — is verified in CI; checking it here
# would require a ReleaseSafe build per invocation, which is too slow
# for the developer loop.)
run_step tests       step_tests
run_step spec        step_spec
run_step e2e         step_e2e
run_step realworld   step_realworld
run_step ffi         step_ffi
if [ "$RUN_BENCH" -eq 1 ]; then
    run_step bench   step_bench_quick
fi
run_step minimal     step_minimal

# --- Summary ---

echo
echo "=== Commit Gate summary ==="
printf '  ran=%d  passed=%d  failed=%d  host=%s\n' \
    "$STEPS_RUN" "$STEPS_PASSED" "$STEPS_FAILED" "$HOST_KIND"
if [ "$STEPS_FAILED" -gt 0 ]; then
    printf '  failed steps:%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
