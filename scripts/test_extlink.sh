#!/usr/bin/env bash
# scripts/test_extlink.sh — verify libzwasm.a links with a NON-zig system
# linker (cc/gcc/clang), the path external C/Rust consumers actually use.
#
# `zig build test-c-api` links the lib via zig's own driver, which auto-pulls
# libm + bundled compiler-rt and never surfaces the system-linker gaps a real
# downstream hits. This test uses the documented external link line:
#
#     cc -Iinclude hello.c libzwasm.a -lm [-Wl,-z,noexecstack on Linux]
#
# Catches regressions like a new undefined symbol beyond libm, or a PIC/reloc
# break. The `.note.GNU-stack` exec-stack warning on Linux is expected and
# benign (Zig upstream limitation, D-312) — mitigated by `-z noexecstack`.
set -euo pipefail
cd "$(dirname "$0")/.."

CC="${CC:-cc}"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

echo "[test_extlink] zig build static-lib"
zig build static-lib

LDFLAGS=(-lm)
if [ "$(uname -s)" = "Linux" ]; then LDFLAGS+=(-Wl,-z,noexecstack); fi

echo "[test_extlink] $CC external link (system linker, not zig)"
"$CC" -std=c11 -Izig-out/include docs/examples/c_host/hello.c \
    zig-out/lib/libzwasm.a "${LDFLAGS[@]}" -o "$out/hello"

echo "[test_extlink] run"
"$out/hello"
rc=$?
if [ "$rc" -ne 0 ]; then echo "[test_extlink] FAIL: exit $rc"; exit 1; fi
echo "[test_extlink] OK"
