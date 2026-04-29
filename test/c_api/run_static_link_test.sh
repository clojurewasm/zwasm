#!/usr/bin/env bash
# run_static_link_test.sh — Test linking libzwasm.a from non-Zig toolchains
#
# Simulates real-world usage: build static lib with PIC + compiler_rt,
# then link via `zig cc` (portable across Mac/Linux/Windows; replaces
# the previous platform-specific `cc`). On Linux we additionally cover
# the `-pie` path. The Rust static-link test runs everywhere a working
# cargo + rustc are available; on Windows MSVC ABI it is skipped because
# `examples/rust/build.rs` still uses `cargo:rustc-link-lib=c|m` /
# `-Wl,-rpath`, which are POSIX-only (tracked as Plan C-c).
#
# Usage:
#   bash test/c_api/run_static_link_test.sh [--build]
#
# Options:
#   --build   Force rebuild of static library (default: skip if exists)

set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD=false
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=true ;;
    esac
done

PASS=0
FAIL=0
TOTAL=0

UNAME_S=$(uname -s 2>/dev/null || echo unknown)
case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) HOST_OS=Windows ;;
    Darwin)               HOST_OS=Darwin  ;;
    Linux)                HOST_OS=Linux   ;;
    *)                    HOST_OS=Other   ;;
esac

if [ "$HOST_OS" = "Windows" ]; then
    # Zig produces `zwasm.lib` (MSVC convention, no `lib` prefix) for
    # `addLibrary({.linkage = .static})` on Windows.
    LIB="zig-out/lib/zwasm.lib"
    BIN_EXT=".exe"
    TMP_DIR="${TEMP:-/tmp}"
else
    LIB="zig-out/lib/libzwasm.a"
    BIN_EXT=""
    TMP_DIR="/tmp"
fi

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"; }

# --- Build static library with PIC + compiler_rt ---
if $BUILD || [ ! -f "$LIB" ]; then
    echo "Building static library (PIC + compiler_rt)..."
    zig build static-lib -Dpic=true -Dcompiler-rt=true
fi

echo ""
echo "=== Static Link Tests (host=$HOST_OS) ==="
echo ""

# --- Test 1: C direct link with `zig cc` ---
echo "[1/3] C direct link (zig cc)"
TMPBIN="${TMP_DIR}/zwasm_static_${RANDOM}${BIN_EXT}"
rm -f "$TMPBIN"
if zig cc -o "$TMPBIN" examples/c/hello.c -Iinclude "$LIB" 2>/tmp/zwasm_cc_err.txt; then
    OUTPUT=$("$TMPBIN" 2>&1)
    if [ "$OUTPUT" = "f() = 42" ]; then
        pass "zig cc link + run"
    else
        fail "zig cc link ok but output='$OUTPUT' (expected 'f() = 42')"
    fi
else
    fail "zig cc link failed: $(cat /tmp/zwasm_cc_err.txt)"
fi
rm -f "$TMPBIN" /tmp/zwasm_cc_err.txt

# --- Test 2: C direct link with `zig cc -pie` (Linux only) ---
if [ "$HOST_OS" = "Linux" ]; then
    echo "[2/3] C direct link (zig cc -pie)"
    TMPBIN="${TMP_DIR}/zwasm_static_pie_${RANDOM}${BIN_EXT}"
    rm -f "$TMPBIN"
    if zig cc -pie -o "$TMPBIN" examples/c/hello.c -Iinclude "$LIB" 2>/tmp/zwasm_cc_pie_err.txt; then
        OUTPUT=$("$TMPBIN" 2>&1)
        if [ "$OUTPUT" = "f() = 42" ]; then
            pass "zig cc PIE link + run"
        else
            fail "zig cc PIE link ok but output='$OUTPUT' (expected 'f() = 42')"
        fi
    else
        fail "zig cc PIE link failed: $(cat /tmp/zwasm_cc_pie_err.txt)"
    fi
    rm -f "$TMPBIN" /tmp/zwasm_cc_pie_err.txt
else
    echo "[2/3] C direct link (zig cc -pie)"
    echo "  SKIP: PIE only exercised on Linux"
fi

# --- Test 3: Rust static link (cargo) ---
echo "[3/3] Rust static link (cargo)"
if [ "$HOST_OS" = "Windows" ]; then
    echo "  SKIP: Rust example build.rs is POSIX-only (Plan C-c will fix)"
elif command -v cargo >/dev/null 2>&1; then
    # Clean to avoid stale cached dylib-linked binary
    cargo clean --manifest-path examples/rust/Cargo.toml 2>/dev/null || true
    if ZWASM_STATIC=1 cargo build --manifest-path examples/rust/Cargo.toml 2>/tmp/zwasm_cargo_err.txt; then
        OUTPUT=$(ZWASM_STATIC=1 cargo run --manifest-path examples/rust/Cargo.toml 2>&1)
        if echo "$OUTPUT" | grep -q "f() = 42"; then
            pass "cargo static link + run"
        else
            fail "cargo build ok but output='$OUTPUT' (expected 'f() = 42')"
        fi
    else
        fail "cargo build failed: $(cat /tmp/zwasm_cargo_err.txt)"
    fi
    rm -f /tmp/zwasm_cargo_err.txt
else
    echo "  SKIP: cargo not found"
fi

# --- Summary ---
echo ""
echo "=== Summary: $PASS passed, $FAIL failed (of $TOTAL) ==="

exit $FAIL
