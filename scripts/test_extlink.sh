#!/usr/bin/env bash
# scripts/test_extlink.sh — verify libzwasm.a links with a NON-zig system
# linker (cc/gcc/clang), the path external C/Rust consumers actually use.
#
# `zig build test-c-api` links the lib via zig's own driver, which auto-pulls
# libm + its own compiler-rt and never surfaces the system-linker gaps a real
# downstream hits. This test uses the documented external link line:
#
#     zig build static-lib -Dcompiler-rt=true
#     cc -Iinclude hello.c libzwasm.a -lm [-Wl,-z,noexecstack on Linux]
#
# Catches regressions like a new undefined symbol beyond libm, or a PIC/reloc
# break. The `.note.GNU-stack` exec-stack warning on Linux is expected and
# benign (Zig upstream limitation, D-312) — mitigated by `-z noexecstack`.
#
# `-Dcompiler-rt=true` is load-bearing, not decoration: Zig's implicit
# bundle_compiler_rt default only covers exe + dynamic lib, so without the flag
# the archive leaves `__zig_probe_stack` (x86_64-macos — no non-Zig provider
# exists, hence the hard failure in issue #153) and the `__divti3`-class
# builtins undefined.
set -euo pipefail
cd "$(dirname "$0")/.."

CC="${CC:-cc}"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

echo "[test_extlink] zig build static-lib -Dcompiler-rt=true"
zig build static-lib -Dcompiler-rt=true

echo "[test_extlink] archive carries compiler-rt"
if ! ar t zig-out/lib/libzwasm.a | grep -q '^compiler_rt\.o$'; then
    echo "[test_extlink] FAIL: compiler_rt.o missing from libzwasm.a"
    ar t zig-out/lib/libzwasm.a
    exit 1
fi

# Every `pub export fn` in src/api/ must land in the archive. Zig only emits
# export symbols from files the analysis pass visits, so a file missing from
# src/zwasm.zig's comptime force-analyse block silently drops ALL its exports
# while the header keeps declaring them (issue #161: 46 ref_base + 35
# config/host_info/module_serialize symbols were unlinkable).
nm -g zig-out/lib/libzwasm.a 2>/dev/null |
    awk 'NF >= 3 && $2 != "U" { sub(/^_/, "", $3); print $3 }' | sort -u > "$out/archive_syms.txt"

echo "[test_extlink] all src/api pub-export symbols present in the archive"
missing=$(comm -23 \
    <(grep -h '^pub export fn' src/api/*.zig | sed -E 's/^pub export fn ([A-Za-z0-9_]+).*/\1/' | sort -u) \
    "$out/archive_syms.txt")
if [ -n "$missing" ]; then
    echo "[test_extlink] FAIL: exported fns missing from libzwasm.a (file absent from the src/zwasm.zig comptime block?):"
    echo "$missing"
    exit 1
fi

# Stronger, consumer-side statement of the same invariant: every function the
# INSTALLED headers declare must be linkable. Preprocess each installed header
# and require every declared wasm_*/wasi_*/zwasm_* function in the archive,
# minus the `static inline` helpers the headers define themselves. Catches a
# declared-but-never-implemented symbol, which the src-side check above cannot.
echo "[test_extlink] all installed-header declarations present in the archive"
for h in zig-out/include/*.h; do
    "$CC" -E -P -Izig-out/include "$h" 2>/dev/null
done > "$out/pp.h"
fn_names() { grep -oE '\b(wasm|wasi|zwasm)_[a-z0-9_]+ *\(' | sed -E 's/ *\($//' | sort -u; }
fn_names < "$out/pp.h" > "$out/hdr_all.txt"
grep -A1 'static *inline' "$out/pp.h" | fn_names > "$out/hdr_inline.txt"
hdr_missing=$(comm -23 <(comm -23 "$out/hdr_all.txt" "$out/hdr_inline.txt") "$out/archive_syms.txt")
if [ -n "$hdr_missing" ]; then
    echo "[test_extlink] FAIL: header-declared fns missing from libzwasm.a:"
    echo "$hdr_missing"
    exit 1
fi

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
