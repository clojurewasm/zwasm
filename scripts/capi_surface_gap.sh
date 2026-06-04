#!/usr/bin/env bash
# capi_surface_gap.sh — live wasm-c-api surface completeness checker (§16.2).
#
# Our include/wasm.h is the verbatim upstream wasm-c-api standard (byte-identical
# to OSS/wasm-c-api). wasmtime + wasmer ship 100% of it; a C consumer calling a
# declared-but-unimplemented function gets a link error. This script reports the
# gap between DECLARED (header, macros expanded) and IMPLEMENTED (export fn) so
# the §16.2 completion bundle can track progress without a hand-maintained list
# that rots (cf. lesson no-handover-predictions: live counts beat stale prose).
#
# Mac-host audit tool (needs clang -E for macro expansion). Not part of the gate.
# Usage: scripts/capi_surface_gap.sh [--list]   (--list prints the gap symbols)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hdr="$root/include/wasm.h"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# DECLARED: every wasm_* function name reachable after preprocessing, minus the
# static-inline convenience helpers the header itself provides (no impl owed).
printf '#include "wasm.h"\n' > "$tmp/probe.c"
clang -E -I"$root/include" "$tmp/probe.c" 2>/dev/null \
  | grep -oE "\bwasm_[a-z0-9_]+\b[[:space:]]*\(" \
  | grep -oE "wasm_[a-z0-9_]+" | sort -u > "$tmp/declared.txt"
grep -oE "static inline [^{;]*\bwasm_[a-z0-9_]+[[:space:]]*\(" "$hdr" \
  | grep -oE "wasm_[a-z0-9_]+[[:space:]]*\($" | grep -oE "wasm_[a-z0-9_]+" \
  | sort -u > "$tmp/inline.txt"
comm -23 "$tmp/declared.txt" "$tmp/inline.txt" > "$tmp/owed.txt"

# IMPLEMENTED: literal `export fn wasm_*` across src/ (the only export idiom; no
# @export / comptime generators — verified §16.2).
grep -rhoE "export fn (wasm_[a-z0-9_]+)" "$root/src" \
  | sed -E 's/export fn //' | sort -u > "$tmp/impl.txt"

comm -23 "$tmp/owed.txt" "$tmp/impl.txt" > "$tmp/gap.txt"

owed=$(wc -l < "$tmp/owed.txt" | tr -d ' ')
impl_owed=$(comm -12 "$tmp/owed.txt" "$tmp/impl.txt" | wc -l | tr -d ' ')
gap=$(wc -l < "$tmp/gap.txt" | tr -d ' ')
echo "wasm-c-api standard surface (extern, impl owed): $owed"
echo "  implemented: $impl_owed"
echo "  GAP (declared, unimplemented): $gap"

if [ "${1:-}" = "--list" ]; then
  echo "--- gap symbols ---"
  cat "$tmp/gap.txt"
fi
