#!/usr/bin/env bash
# run_ffi_test.sh — Build libzwasm shared lib and run FFI test suite
#
# Uses `zig cc` instead of system `gcc` so the script works identically
# on macOS / Linux / Windows (Git Bash) without depending on a host C
# compiler. The Windows runner does not ship gcc, and `zig cc` already
# carries clang + the bundled libc headers.
#
# Usage:
#   bash test/c_api/run_ffi_test.sh [--build]
#
# Options:
#   --build   Rebuild the shared library before testing (default: skip if exists)

set -euo pipefail
cd "$(dirname "$0")/../.."

BUILD=false
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=true ;;
    esac
done

UNAME_S=$(uname -s 2>/dev/null || echo unknown)
case "$UNAME_S" in
    MINGW*|MSYS*|CYGWIN*) HOST_OS=Windows ;;
    Darwin)               HOST_OS=Darwin  ;;
    Linux)                HOST_OS=Linux   ;;
    *)                    HOST_OS=Other   ;;
esac

case "$HOST_OS" in
    Darwin)
        LIB="zig-out/lib/libzwasm.dylib"
        BIN_EXT=""
        EXTRA_LDFLAGS="-lpthread"
        TMP_DIR="/tmp"
        ;;
    Windows)
        # Zig installs the DLL to bin/ on Windows, with the import lib
        # alongside in lib/. The test program loads the DLL at runtime
        # via LoadLibraryA, so we only need the .dll path.
        LIB="zig-out/bin/zwasm.dll"
        BIN_EXT=".exe"
        # No -lpthread on Windows: threading uses Win32 CreateThread
        # via the test_ffi.c #ifdef branch.
        EXTRA_LDFLAGS=""
        TMP_DIR="${TEMP:-/tmp}"
        ;;
    *)
        LIB="zig-out/lib/libzwasm.so"
        BIN_EXT=""
        EXTRA_LDFLAGS="-ldl -lpthread"
        TMP_DIR="/tmp"
        ;;
esac

if $BUILD || [ ! -f "$LIB" ]; then
    echo "Building shared library..."
    zig build shared-lib
fi

echo "Compiling FFI test (zig cc)..."
TMPBIN="${TMP_DIR}/zwasm_ffi_test_${RANDOM}${BIN_EXT}"
rm -f "$TMPBIN"
# shellcheck disable=SC2086
zig cc -O0 -g -o "$TMPBIN" test/c_api/test_ffi.c $EXTRA_LDFLAGS

echo ""
EXIT=0
"$TMPBIN" "$LIB" || EXIT=$?
rm -f "$TMPBIN"

exit $EXIT
