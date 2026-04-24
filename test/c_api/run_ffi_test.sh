#!/usr/bin/env bash
# run_ffi_test.sh — Build libzwasm shared lib and run FFI test suite
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

# Detect platform
if [[ "$(uname)" == "Darwin" ]]; then
    LIB="zig-out/lib/libzwasm.dylib"
else
    LIB="zig-out/lib/libzwasm.so"
fi

# Build shared library if requested or missing
if $BUILD || [ ! -f "$LIB" ]; then
    echo "Building shared library..."
    zig build shared-lib
fi

# Compile test binary
echo "Compiling FFI test..."
gcc -o /tmp/zwasm_ffi_test test/c_api/test_ffi.c -ldl -pthread -O0 -g

# Run
echo ""
/tmp/zwasm_ffi_test "$LIB"
EXIT=$?

# Cleanup
rm -f /tmp/zwasm_ffi_test

exit $EXIT
